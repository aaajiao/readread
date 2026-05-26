# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Development: set up Python env + models in ~/.readread/, then build Swift
./scripts/setup.sh
swift build
swift run ReadRead

# Run the Swift unit tests
swift test

# Distribution: fully self-contained .app bundle (~508MB)
./scripts/build-app.sh
open build/ReadRead.app
```

Build cache lives in `build/cache/` (standalone Python, models). Delete it to force re-download.

## Architecture

ReadRead is a macOS menu bar TTS reader with two processes:

**Swift app** (menu bar UI) → HTTP → **Python subprocess** (kokoro-onnx TTS)

### Swift Side (Sources/ReadRead/)

- `ReadReadApp.swift` — Entry point. AppDelegate creates NSStatusItem + FloatingPanel, starts TTS server.
- `AppState.swift` — `@Observable @MainActor` state machine. Owns the reading pipeline: fetch URL → extract text → split into chunks → synthesize each chunk → play audio sequentially. Handles playback controls (play/pause/stop/skip).
- `TTSEngine.swift` — Manages Python subprocess lifecycle. Resolves paths with fallback chain: app bundle Resources → `~/.readread/` → CWD. Discovers server port by polling a port file. All synthesis via HTTP POST to `127.0.0.1:{port}/synthesize`.
- `WebExtractor.swift` — Fetches content via `https://defuddle.md/{url-without-protocol}`, parses YAML frontmatter, strips markdown to plain text. Also reads local .md/.txt files. URL fetches retry transient failures (network errors, 5xx, 429) up to `maxAttempts` (3) with exponential backoff; deterministic failures (4xx other than 429, decode/empty) fail immediately. `fetchWithRetry` takes injectable `fetch`/`sleep` closures so the retry policy is unit-tested without real network.
- `ContentView.swift` — SwiftUI panel UI. Also defines the `Voice` model (list of available voices).
- `FloatingPanel.swift` — NSPanel subclass: borderless, floating, non-activating, transparent background for SwiftUI material.
- `AudioPlayerService.swift` — AVAudioPlayer wrapper using `CheckedContinuation` for async `playAndWait()`.

### Python Side (tts_server/)

- `tts_server.py` — HTTP server wrapping kokoro-onnx. Endpoints: `/health`, `/voices`, `/synthesize` (POST).
  - English/Hindi/Italian/Portuguese use espeak for phonemization (handled by kokoro directly).
  - Chinese/Japanese/Spanish/French use misaki G2P backends (loaded lazily), then pass phonemes to kokoro with `is_phonemes=True`.
  - Splits text into sentences (max 200 chars) server-side to stay within the model's 510-token limit.

### Key Data Flow

1. User pastes URL → `WebExtractor.extractFromURL()` calls defuddle.md API
2. `AppState.splitIntoChunks()` breaks text into ~200-char paragraphs
3. For each chunk: `TTSEngine.synthesize()` POSTs JSON to Python server → receives WAV bytes
4. `AudioPlayerService.playAndWait()` plays WAV, suspends until done, then next chunk

Audio pre-fetches the next chunk while the current one plays to minimize gaps between paragraphs.

### UI States

The panel has two distinct modes:

- **Input mode** — centered logo, URL text field, Read button, Open File button
- **Reading mode** — header (title + source + close button), scrolling text with highlighted current chunk, playback controls, voice/speed settings

## Important Conventions

- **The voice list is hardcoded only in `ContentView.swift`** (`Voice.all`). `tts_server.py` does NOT hardcode voices — its `/voices` endpoint derives them at runtime from `kokoro.voices.keys()`. When adding a voice to `Voice.all`, just ensure the model actually provides that voice id; there is no second list to edit.
- **Per-language preferences** — voice and speed are saved to `UserDefaults` keyed by language code (`voice_{lang}`, `speed_{lang}`). On language detection, saved preferences are restored; otherwise falls back to `defaultVoice(for:)`.
- **Language detection** uses Apple's NaturalLanguage framework on actual text content (not defuddle metadata, which can be wrong).
- **Path resolution** in TTSEngine checks app bundle first for self-contained distribution, falls back to `~/.readread/` for development.
- **No external Swift dependencies** — only Apple frameworks (SwiftUI, AppKit, AVFoundation, NaturalLanguage).
- **Swift 6 strict concurrency** — AppState, TTSEngine, AudioPlayerService are all `@MainActor`. Async suspension points (URLSession, Task.sleep, CheckedContinuation) keep the main thread unblocked.
- `LSUIElement=true` in Info.plist hides the app from the Dock.
- **Tests** live in `Tests/ReadReadTests/` (XCTest, run with `swift test`). For logic that touches the network, audio, or the Python subprocess, inject the side-effecting work as closures (see `WebExtractor.fetchWithRetry`) so tests run without real I/O.
