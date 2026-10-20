# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Development: standalone CPython 3.12.15 + a venv from the hashed lock + the four model files in
# $READREAD_HOME (default ~/.readread), plus a symlink to this repo's tts_server/ (so the dev app runs the
# checkout's server code; re-run setup.sh after switching to another checkout). Idempotent.
./scripts/setup.sh
swift build
swift run ReadRead                  # the menu bar app, using the dev environment
swift run ReadRead --self-test      # headless end-to-end check, prints one JSON line, exit 0 = ok

# Tests
swift test
~/.readread/env/bin/python3 -B -m pytest -q -p no:cacheprovider tts_server/tests      # fast tests
READREAD_MODELS_DIR=~/.readread/models ~/.readread/env/bin/python3 -B -m pytest -q -p no:cacheprovider tts_server/tests

# Distribution: self-contained, ad-hoc signed build/ReadRead.app (about 0.8 GB). Ends with the smoke test.
./scripts/build-app.sh
./scripts/smoke-test.sh build/ReadRead.app      # the smoke test on its own

# Python dependencies: edit tts_server/requirements.in, then regenerate the hashed locks (needs uv)
./scripts/lock-deps.sh              # --check: fail if the committed locks are stale
```

- Pinned inputs live in `scripts/lib/versions.sh` (CPython release, model files, all with sha256) and
  `tts_server/requirements.lock` (every package hash-pinned). `setup.sh` and `build-app.sh` install the same lock
  with `pip --require-hashes --no-deps`.
- Build cache: `build/cache/` (`downloads/`, `models/`, `runtime/<key>/`, `pip/`). The runtime key hashes the Python
  release and the lock, so editing the lock rebuilds it. Delete `build/cache/` to force fresh, verified downloads.
- `build-app.sh` fails on any error, builds in `build/.staging/ReadRead.app`, signs inside out (ad-hoc, no
  `--deep`), runs `smoke-test.sh`, and only then replaces `build/ReadRead.app`; a failed build leaves the old app
  and keeps its own as `build/ReadRead.app.failed`. The smoke test checks the bundled server (READY, auth, zh + en
  synthesis as JSON: duration near a known-good build's, every word timed, no espeak-ng data errors in its stderr,
  exit on stdin EOF), `--self-test` from the bundle, the bundle unchanged at runtime, the server from a
  ≥160-character bundle path, and `codesign --verify`. This build is the release gate (personal use: no release
  script, zip step or CI).
- A cached runtime is reused only while its files match the sha256 manifest written when it was built; `setup.sh`
  rebuilds `env/` when it no longer holds exactly the locked distributions. Both scripts refuse a
  `requirements.lock` that does not pin what `requirements.in` asks for (run `lock-deps.sh`).
- To keep test runs away from the real `~/.readread` and `~/Library/{Logs,Caches,Application Support}/ReadRead`,
  point `READREAD_HOME`, `READREAD_LOG_DIR`, `READREAD_CACHE_DIR` and `READREAD_USER_LEXICON` at scratch
  directories (the smoke test does this itself). The Python HTTP tests, the smoke test and `--self-test` start
  servers on 127.0.0.1.

## Architecture

ReadRead is a macOS menu bar reader for Mandarin Chinese and English (Apple Silicon only, macOS 26+), with two
processes:

**Swift app** (menu bar UI) → HTTP on 127.0.0.1 with a per-launch bearer token → **Python child process**
(`tts_server/`, Kokoro through kokoro-onnx 0.6.1)

### Swift Side (Sources/ReadRead/)

- `main.swift` — Entry point. `--self-test` runs `SelfTest` headless; otherwise `SingleInstance` hands off to a running
  copy, then `ReadReadApp.main()`.
- `ReadReadApp.swift` — AppDelegate: NSStatusItem (icon from `Bundle.main`, SF Symbol fallback under `swift run`) +
  FloatingPanel. Does not start the server; stops it on quit.
- `AppState.swift` — `@Observable @MainActor` reading pipeline: fetch URL / open file (prewarming the server) →
  detect zh/en → split into chunks (paragraphs grouped up to ~200 characters; a longer paragraph is its own chunk,
  cut at sentence ends to at most 3000 characters) → synthesize each chunk through `SpeechSynthesizer` → play
  sequentially, synthesizing the next chunk while the current one plays. Playback
  controls, error state (an error leaves it paused on the failed chunk; Play or Retry synthesizes it again, and
  Retry restarts the server when the server was the problem).
- `SpeechSynthesizer.swift` — `SpeechLanguage` {zh, en}, `SynthesisRequest` / `SynthesisResult` (WAV, duration,
  sentence and token timings) and the `SpeechSynthesizer` protocol that AppState depends on.
- `TTSService.swift` — The production `SpeechSynthesizer`: starts the server on demand, sends requests through
  `TTSClient`, retries once on a fresh server when the old one died under a request.
- `TTSServerProcess.swift` — Server lifecycle (main actor): lazy start, prewarm, READY/FATAL handshake, 90 s start
  timeout, crash detection with lazy restart and backoff, no auto-restart after 3 crashes in 2 minutes (the error
  names the log), idle shutdown after 15 minutes without synthesis while nothing plays, stop = close stdin + SIGTERM,
  SIGKILL after 2 s. Every side effect goes through `ServerEnvironment` (launcher, file system, clock, sleep, token).
- `TTSServerPaths.swift` — Finds python, server code and models (app bundle `Contents/Resources` first, then
  `$READREAD_HOME/{env/bin/python3,tts_server,models}`, then `<cwd>/tts_server`), checking model sizes;
  `RuntimeDirectories` (log, cache, user lexicon, with the env overrides).
- `ProcessLauncher.swift` — `Process` launcher: stdin pipe held open for the child's lifetime, stdout pipe for the
  handshake, stderr appended to the log file.
- `ServerHandshake.swift` (READY/FATAL parsing), `ServerLog.swift` (`tts-server.log`, rotated at 5 MB to `.1`),
  `TTSClient.swift` (API v2 over URLSession; error JSON → `TTSError` with the server's message), `TTSError.swift`,
  `VoicePreferences.swift`, `SelfTest.swift`, `SingleInstance.swift`, `FileSystem.swift` (file-operation seam).
- `WebExtractor.swift` — Fetches content via `https://defuddle.md/{url-without-protocol}`, parses YAML frontmatter,
  strips markdown to plain text. Also reads local UTF-8 .md/.txt files. URL fetches retry transient failures (network
  errors, 5xx, 429) up to `maxAttempts` (3) with exponential backoff; deterministic failures (4xx other than 429,
  decode/empty) fail immediately. `fetchWithRetry` takes injectable `fetch`/`sleep` closures so the retry policy is
  unit-tested without real network.
- `ContentView.swift` — SwiftUI panel UI. Also defines `Voice` / `VoiceAccent` and `Voice.all`, the app's voice list.
- `FloatingPanel.swift` — NSPanel subclass: borderless, floating, non-activating, transparent background for SwiftUI
  material.
- `AudioPlayerService.swift` — AVAudioPlayer wrapper (`AudioPlaying`) with async `playAndWait()`; fails when playback
  cannot start, finishes on decode errors.

### Python Side (tts_server/)

- `tts_server.py` — Entry point: arguments, token, cache and temp directories, bind, `--preload`, READY/FATAL,
  stdin-EOF watchdog, SIGTERM/SIGINT.
- `readread_tts/` — `server` (HTTP API v2), `engine` (routing, ONNX sessions, synthesis), `frontend_zh`,
  `frontend_en`, `sentences` (clean-up and splitting), `lexicon` + `lexicon_zh.json` (built-in overrides), `zhuyin`,
  `g2p`, `espeak` (short espeak-ng data path), `audio` (trim, silence, WAV).
- Routes by voice id prefix. `zf_`/`zm_` → Kokoro v1.1-zh fp16; front end = normalizer (dates, times, ranges,
  currency, units), OpenCC Traditional → Simplified, misaki `ZHG2P(version="1.1")` with misaki English for Latin
  words, then the override lexicon. `af_`/`am_` (US) and `bf_`/`bm_` (UK, `british=True`) → Kokoro v1.0 fp16 re-export
  from `model-files-v1.1` (it reports durations); front end = normalizer, then `misaki.en.G2P` with the espeak-ng
  fallback for unknown words.
- The server splits text into sentences and makes one model call per sentence (one per kokoro batch, cut at word
  boundaries, for a sentence over 510 phonemes); each sentence's trailing pause is trimmed to 40 ms and sentences
  are joined with 250 ms of silence. In Chinese, half-width `, ; : ! ?` next to Han characters are read full width
  and a sentence-final `.` as `。`. A sentence the front end fails on is logged and skipped. Text with nothing to say
  returns 150 ms of silence with `"silent": true`.
- Both ONNX sessions stay resident once loaded (dropping them returns no memory on macOS). Routes not preloaded
  load on first use.
- `tts_server/README.md` is the reference for the CLI, the HTTP API and the lexicon format; `tts_server/tests/` is
  the pytest suite (model tests are skipped unless `READREAD_MODELS_DIR` is set).

### Server Protocol (API v2)

- Launch: `<python> -I -B tts_server.py --models-dir <dir> [--preload zh|en|zh,en]` with `READREAD_TOKEN`
  (64 hex characters, new per launch), `READREAD_CACHE_DIR` and `READREAD_USER_LEXICON` in a clean environment.
- stdout carries exactly one line: `READY {"port":…,"pid":…,"api":2,"loaded":["zh","en"]}` once it listens and the
  preloaded routes are warm, or `FATAL {"message":"…"}` and exit status 3. Everything else goes to stderr, which the
  app appends to the log.
- `GET /health`, `GET /voices` (`{"zh":[…],"en":[…]}`, read from the voice files), `POST /synthesize`
  (`text` ≤ 4000 characters, `voice`, optional `lang`, `speed` 0.5–2.0, `request_id`, `format` json|wav; json returns
  base64 WAV plus sentence and token timings). Bearer token (401), loopback Host header (403), JSON-only bodies
  (415); every error is `{"error":{"code","message"}}`. One synthesis at a time; a client that disconnects cancels.
- The server exits on stdin EOF (the app is gone) and within 1 s of SIGTERM/SIGINT, also mid-synthesis.

### Key Data Flow

1. User pastes URL → `WebExtractor.extractFromURL()` calls the defuddle.md API (or `readFile()` for a local file);
   `prewarm` starts the server with the last language's model meanwhile.
2. `AppState.detectLanguage()` picks zh or en from the text; the saved voice and speed for that language apply.
3. `AppState.splitIntoChunks()` breaks the text into chunks of whole paragraphs (~200 characters, ≤ 3000).
4. For each chunk: `TTSService.synthesize()` → `POST /synthesize` → WAV + timings; the server reads it sentence by
   sentence.
5. `AudioPlayerService.playAndWait()` plays the WAV, suspends until done, then the next chunk, which was already
   synthesized while this one played.

### Runtime Locations

- Server log: `~/Library/Logs/ReadRead/tts-server.log` (rotated at 5 MB to `tts-server.log.1`; Show Log opens it),
  override `READREAD_LOG_DIR`.
- Cache: `~/Library/Caches/ReadRead/` (`espeak-ng-data` symlink, `jieba.cache`, `tmp/<pid>/`), override
  `READREAD_CACHE_DIR`. Its `espeak-ng-data` path must stay within 150 bytes (espeak-ng's path buffer); the server
  refuses longer ones with a FATAL.
- User pronunciation overrides: `~/Library/Application Support/ReadRead/lexicon_zh.json`, override
  `READREAD_USER_LEXICON`; same format as the built-in `readread_tts/lexicon_zh.json` —
  `{"version": 1, "entries": [{"text": "还回去", "pinyin": "huan2 hui2 qu4", "before": "<regex>", "after": "<regex>"}]}`
  (one tone-numbered syllable per character, `*` keeps misaki's reading; full rules in the `lexicon.py` docstring).
  User entries apply after the built-in ones; the file is re-read when it changes, and a missing file is fine.
- Dev environment: `$READREAD_HOME` (default `~/.readread`). The app bundle is never written at runtime.

### UI States

The panel has two distinct modes:

- **Input mode** — centered logo, URL text field, Read button, Open File button
- **Reading mode** — header (title + source + close button), scrolling text with highlighted current chunk, playback
  controls, voice/speed settings

Both show an error banner with the full, selectable error text plus Show Log and Retry (and the setup hint only when
engine files are missing), and "Starting voice engine…" in the bottom bar while the server starts.

## Important Conventions

- **Two languages: `zh` and `en`.** UK vs US English is a property of the voice, not of the language. The voice id
  prefix decides the pipeline on both sides (`Voice.route(forID:)` mirrors the server's routing).
- **The voice list is hardcoded only in `ContentView.swift`** (`Voice.all`, picker order). The server does not
  hardcode voices — `GET /voices` lists the ids in the model's voice files. `Voice.all` must be a subset of
  `/voices` for each language: `--self-test` (and with it the build's smoke test) fails when an app voice is missing.
- **Per-language preferences** — `voice_zh`, `voice_en`, `speed_zh`, `speed_en` in `UserDefaults`; a voice is saved
  under its own language. v0.1.x keys are migrated once (`voice_en-us` → `voice_en`, dropped languages removed,
  unknown voice ids fall back to `Voice.defaultVoice(for:)`).
- **Language detection** (interim) is `NLLanguageRecognizer` limited to Simplified/Traditional Chinese and English,
  run on the text itself (not defuddle metadata, which can be wrong).
- **Path resolution** checks the app bundle first, then `$READREAD_HOME`, then `<cwd>/tts_server`; missing files give
  `TTSError.resourcesMissing`, the only error that shows the setup hint.
- **No external Swift dependencies** — only Apple frameworks (SwiftUI, AppKit, AVFoundation, NaturalLanguage).
- **No SwiftPM resources and no `Bundle.module`** — its accessor crashed the release app on other Macs. Icons are
  copied into `Contents/Resources` by `build-app.sh`, which refuses a binary that references `ReadRead_ReadRead.bundle`.
- **Swift 6 strict concurrency** — AppState, TTSService, TTSServerProcess, AudioPlayerService are `@MainActor`.
  Async suspension points (URLSession, Task.sleep, CheckedContinuation) keep the main thread unblocked.
- **Injection seams** — AppState takes a `SpeechSynthesizer`, an `AudioPlaying` and a `PreferencesStore`; the server
  lifecycle takes a `ServerEnvironment` (`ProcessLauncher`, `FileSystem`, clock, sleep, token); `TTSClient` takes an
  `HTTPTransport`; `WebExtractor.fetchWithRetry` takes `fetch`/`sleep` closures. Tests run without Python, network or
  audio this way.
- **The bundled interpreter is isolated** — the server runs with `-I -B` and a minimal environment; bytecode is
  precompiled as unchecked-hash `.pyc`, so nothing in the signed bundle changes at runtime.
- **Dependencies** — misaki is installed as `misaki[zh]` only; `misaki[en]` would pull phonemizer-fork, which clashes
  with phonemizer 3.4.0. Add or bump Python packages through `requirements.in` + `lock-deps.sh`.
- `LSUIElement=true` in Info.plist hides the app from the Dock. Version: `CFBundleShortVersionString` from the latest
  `v*` tag, `CFBundleVersion` from `git rev-list --count HEAD`.
- **Tests** — Swift: `Tests/ReadReadTests/` (XCTest, `swift test`). Python: `tts_server/tests/` (pytest). For logic
  that touches the network, audio, or the Python subprocess, inject the side-effecting work so tests run without
  real I/O.
