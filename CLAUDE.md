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
READREAD_UPDATE_SNAPSHOTS=1 swift test --filter GoldenDocumentTests   # rewrite Fixtures/snapshots, then review the diff
READREAD_TEST_APPLE_SPEECH=1 swift test --filter AppleSpeechSynthesizerTests   # also the real system voices
~/.readread/env/bin/python3 -B -m pytest -q -p no:cacheprovider tts_server/tests      # fast tests
READREAD_MODELS_DIR=~/.readread/models ~/.readread/env/bin/python3 -B -m pytest -q -p no:cacheprovider tts_server/tests
# The Qwen engine with its real models (Metal: run outside any sandbox), from an install-hq.sh install
READREAD_HQ_HOME=<hq dir> ~/.readread/env/bin/python3 -B -m pytest -q -p no:cacheprovider \
  tts_server/tests/test_qwen_models.py

# Distribution: self-contained, ad-hoc signed build/ReadRead.app (about 0.8 GB). Ends with the smoke test.
./scripts/build-app.sh
./scripts/smoke-test.sh build/ReadRead.app      # the smoke test on its own

# Python dependencies: edit tts_server/requirements.in (or requirements-hq.in), then regenerate the hashed
# locks (needs uv)
./scripts/lock-deps.sh              # --check: fail if the committed locks are stale

# Optional high-quality engine (Qwen3-TTS on the GPU through MLX), installed outside the app into
# $READREAD_HQ_HOME (default ~/Library/Application Support/ReadRead/hq). The app UI for it comes in v0.5.0.
./scripts/install-hq.sh [--model 1.7b|0.6b|both] [--json-progress]   # also --check, --uninstall
```

- Pinned inputs live in `scripts/lib/versions.sh` (CPython release, model files, the Qwen model revisions and
  files, all with sha256) and `tts_server/requirements.lock` (every package hash-pinned; `requirements-hq.lock` for
  the HQ venv, constrained by it). `setup.sh` and `build-app.sh` install the same lock with
  `pip --require-hashes --no-deps`; `install-hq.sh` installs the HQ lock the same way.
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
  point `READREAD_HOME`, `READREAD_LOG_DIR`, `READREAD_CACHE_DIR`, `READREAD_USER_LEXICON`, `READREAD_POSITIONS_FILE`
  and `READREAD_HQ_HOME` at scratch directories (the smoke test sets the first four; `--self-test` writes no
  positions). The Python HTTP tests, the smoke test and `--self-test` start servers on 127.0.0.1.

## Architecture

ReadRead is a macOS menu bar reader for Mandarin Chinese and English (Apple Silicon only, macOS 26+), with two
processes:

**Swift app** (menu bar UI) → HTTP on 127.0.0.1 with a per-launch bearer token → **Python child process**
(`tts_server/`, Kokoro through kokoro-onnx 0.6.1)

### Swift Side (Sources/ReadRead/)

App and UI:

- `main.swift` — Entry point. `--self-test` runs `SelfTest` headless; otherwise `SingleInstance` hands off to a running
  copy, then `ReadReadApp.main()`.
- `ReadReadApp.swift` — AppDelegate: NSStatusItem (icon from `Bundle.main`, SF Symbol fallback under `swift run`) +
  FloatingPanel. Does not start the server; `AppState.shutdown()` on quit.
- `AppState.swift` — `@Observable @MainActor`: the input field and one document load at a time (`InputParser` →
  `DocumentLoader`, off the main actor; a new load cancels the running one, Return is ignored while loading, Cancel
  stops it, the server prewarms meanwhile), the `PlaybackController`, the error banner (a failed load, else an
  undismissed player failure; the setup hint for missing engine files; "Use System Voice" when the server cannot run)
  and the preferences: a voice per language, a speed per document language (`VoicePreferences`), the language choice
  (Auto / 中文 / English) per document for this run only. User edits (`selectVoice`, `setSpeed`,
  `setLanguageChoice`) are methods, not `onChange` side effects.
- `ContentView.swift` — SwiftUI panel UI. Also defines `Voice` / `VoiceAccent` and `Voice.all`, the app's voice list.
- `FloatingPanel.swift` — NSPanel subclass: borderless, floating, non-activating, transparent background for SwiftUI
  material.
- `SelfTest.swift` — `--self-test`: server start, catalog, zh / en-US / en-GB synthesis with timings, and a playback
  check (a fixture document through `DocumentBuilder`, three units synthesized and rendered through an offline
  `AudioQueuePlayer`: no gap or cut between units). Prints one JSON line.

Text pipeline (input → `ReadingDocument`):

- `ReadingDocument.swift` — the shared model: `DocumentSource` (url / file / text), `LanguageChoice`, `ReadingBlock`
  (display paragraph, its unit range), `SpeechUnit` (block, Character range for highlighting, `speakText`, language or
  nil = skipped, kind title/heading/sentence, `pauseAfter` 0.25 s, 0.5 s after the title, a heading or a block end),
  `ReadingDocument` (`contentHash` = sha256 of the speak texts, `positionKey`).
- `InputParser.swift` — the field's text → `ReadingInput` (`.url`, `.file`, `.text`): http(s) URLs and bare hosts
  (https; http for local addresses), share text with a link and little else around it, existing file paths (`/`,
  `~`, `file://`, Terminal escapes), anything else is text to read. `isLocalNetwork` (localhost, `*.local`, private
  addresses, single-label hosts) — those pages are not sent to defuddle.md.
- `DocumentLoader.swift` — `@concurrent load(_:)`: fetch or read, clean, build, checking cancellation between the
  steps; `DocumentError.nothingToRead` (empty, markup only, or only scripts ReadRead does not read) and
  `.localNetwork`. Pasted text that looks like Markdown goes through the Markdown cleaner.
- `WebExtractor.swift` — `extractFromURL` → `WebPage` {title without the site suffix, markdown, domain} via
  `https://defuddle.md/{url-without-scheme}` (frontmatter split off; defuddle's error JSON becomes its message);
  `readFile` → `LocalFile` {title from frontmatter or the file name, body, isMarkdown}, any encoding `TextDecoding`
  knows, 32 MB limit. URL fetches retry transient failures (network errors, 5xx, 429) up to `maxAttempts` (3) with
  exponential backoff; `fetchWithRetry` takes injectable `fetch`/`sleep` closures, `extractFromURL` a `fetch`.
- `TextDecoding.swift` — bytes → text: BOM, strict UTF-8, then GB18030 / Big5 (CP950) / UTF-16 without BOM (by NUL
  density) / Windows-1252 scored for plausibility (GB18030 is skipped when the bytes are mostly GBK's rare-character
  area, i.e. Shift_JIS); CRLF and CR → LF.
- `Frontmatter.swift` — YAML-like frontmatter only at the start, every line YAML-like, quoted values unescaped.
- `MarkdownCleaner.swift` — Markdown → blocks (heading / paragraph / listItem / quote) of speakable text: drops code
  blocks (inline code keeps its text), tables, HTML, images, URLs, footnote and citation markers, footnote definitions,
  reference/notes/see-also sections (en + zh titles, after some content), emoji; links → their text; entities, escapes,
  `<br>`; emphasis only at word boundaries for `_`; bullets, arrows, stars and checks → separators. `TextPattern` = a
  shared NSRegularExpression (compiled with `try!`; `MarkdownCleanerTests.testEveryPatternCompiles` touches every one).
- `PlainTextCleaner.swift` — .txt → blocks: blank lines separate paragraphs; a single newline is a break (a novel with
  one paragraph per line) unless the line was wrapped (long without closing punctuation, or, in a hard-wrapped
  text, any Latin-script line near the detected wrap column).
- `SpeechChunker.swift` — block text → units: sentences (zh 。！？；… with closing quotes; en . ! ? with rules for
  abbreviations, initials, decimals, versions, domains), long ones cut evenly at clause punctuation, then
  whitespace, at about 120 zh / 220 en characters; headings and the title get a stop in `speakText`.
- `LanguageDetector.swift` — script census per unit: Han ≥ 0.3 of the letters → zh, Latin without Han → en, less
  Han or only digits → the document language, Japanese (kana) or other scripts outweighing Han + Latin → nil
  (shown, skipped). The document language is the character-weighted majority of the zh and en units (a tie is zh).
  No NaturalLanguage.
- `DocumentBuilder.swift` — blocks → document: the title first, alone (unless the body starts with it), then every
  block's units with their languages.

Playback:

- `PlaybackController.swift` — `@Observable @MainActor` state machine (idle, buffering, playing, paused, failed,
  finished): synthesizes the current unit first, then prefetches 3 ahead, one request at a time; `SynthesisCache`
  keeps the audio so next / previous / seek are instant; jumps cancel work outside the window. Speed: the rate
  changes at once, prefetched units are re-synthesized after the slider rests 300 ms, older audio plays
  time-stretched meanwhile. A new voice drops that voice's audio; a voice or language change restarts the current
  sentence while playing and keeps it paused while paused. `restore(settings:)` (preferences) never restarts
  audio. Pause while buffering stays paused. A failure stops on the failed unit (Retry restarts the server when it
  was the problem). Progress by audio time (real durations, else estimates from 5.2 zh / 15.4 en characters per
  second). Positions: saved 2 s after the unit changes and on stop/close, removed at the end, restored on open
  while the content hash matches.
- `PlaybackSettings.swift` — a voice per language, one speed, the language choice.
- `SynthesisCache.swift` — `SynthesisKey` (unit, voice, speed, engine) → result, LRU of 40; `nearest` speed.
- `AudioOutput.swift` — the `AudioOutput` protocol and `AudioItem` (unit id, WAV, synthSpeed, pause).
- `AudioQueuePlayer.swift` — the production output: AVAudioEngine → AVAudioPlayerNode → AVAudioUnitTimePitch → main
  mixer, one unit scheduled at a time with its pause appended, rate = userSpeed / synthSpeed. `.offline` mode
  (manual rendering) for tests and `--self-test`.
- `WAVDecoder.swift` — PCM16 WAV → float samples (header validated), buffers with the pause, resampling.
- `ReadingPositionStore.swift` — `positions.json`: unit + content hash + date per `positionKey`, newest 200, atomic
  writes, a corrupt file is ignored.
- `NowPlayingController.swift` — MPNowPlayingInfoCenter + MPRemoteCommandCenter (play, pause, toggle, next/previous
  sentence).
- `AppleSpeechSynthesizer.swift` — the system-voice fallback (`SpeechSynthesizer`, engine id `apple`):
  AVSpeechSynthesizer.write → 24 kHz PCM16 WAV at speed 1.0 (`honoursSpeed` false: the player time-stretches);
  zh: a premium or enhanced zh-CN voice, else Tingting; en: Ava (premium, then enhanced), else Samantha.

Speech engine (the Python server):

- `SpeechSynthesizer.swift` — `SpeechLanguage` {zh, en}, `SynthesisRequest` / `SynthesisResult` (WAV, duration,
  sentence and token timings, `synthSpeed`), the `SpeechSynthesizer` protocol (`engineID`, `honoursSpeed`).
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
  `TTSClient.swift` (API v2 over URLSession; error JSON → `TTSError` with the server's message; `synth_speed`, else
  the requested speed), `TTSError.swift`, `VoicePreferences.swift`, `SingleInstance.swift`, `FileSystem.swift`
  (file-operation seam).

### Python Side (tts_server/)

- `tts_server.py` — Entry point: arguments (`--engine kokoro|qwen`, `--model 1.7b|0.6b`), token, cache and temp
  directories, bind, `--preload`, READY/FATAL, stdin-EOF watchdog, SIGTERM/SIGINT.
- `readread_tts/` — `server` (HTTP API v2), `engine` (the interface both engines implement), `engine_kokoro`
  (routing, ONNX sessions, synthesis), `engine_qwen` (the optional Qwen3-TTS engine), `frontend_zh`, `frontend_en`,
  `sentences` (clean-up and splitting), `lexicon` + `lexicon_zh.json` (built-in overrides), `zhuyin`, `g2p`,
  `espeak` (short espeak-ng data path), `audio` (trim, silence, WAV).
- The Qwen engine (`--engine qwen`, run from the HQ venv of `install-hq.sh`, not in the app bundle): Qwen3-TTS-12Hz
  CustomVoice 8-bit (1.7b default, 0.6b smaller) on the GPU through MLX; voices `serena` (zh) and `aiden` (en);
  streaming generation only, a per-sentence seed, `synth_speed` always 1.0 (the player time-stretches). Details in
  `tts_server/README.md`. The Swift half (engine setting, second server lifecycle, installer UI) is v0.5.0.
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
- `tts_server/README.md` is the reference for the CLI, the HTTP API, the Qwen engine, `install-hq.sh` and the
  lexicon format; `tts_server/tests/` is the pytest suite (Kokoro model tests are skipped unless
  `READREAD_MODELS_DIR` is set, Qwen model tests unless `READREAD_HQ_HOME` points at an install).

### Server Protocol (API v2)

- Launch: `<python> -I -B tts_server.py --models-dir <dir> [--preload zh|en|zh,en]` with `READREAD_TOKEN`
  (64 hex characters, new per launch), `READREAD_CACHE_DIR` and `READREAD_USER_LEXICON` in a clean environment. The
  HQ engine: `<hq venv python> -I -B tts_server.py --engine qwen [--model 1.7b|0.6b] --models-dir <hq>/models`.
- stdout carries exactly one line: `READY {"port":…,"pid":…,"api":2,"loaded":["zh","en"],"engine":"kokoro"}` (qwen
  adds `"model"`) once it listens and the preloaded routes are warm, or `FATAL {"message":"…"}` and exit status 3.
  Everything else goes to stderr, which the app appends to the log (one `synthesize request_id=… voice=… chars=…
  … status=…` line per synthesis request).
- `GET /health` (with `engine`), `GET /voices` (`{"zh":[…],"en":[…]}`, read from the voice files), `POST /synthesize`
  (`text` ≤ 4000 characters, `voice`, optional `lang`, `speed` 0.5–2.0, `request_id`, `format` json|wav; json returns
  base64 WAV plus sentence and token timings and `synth_speed`, the speed the audio was made at). Bearer token
  (401), loopback Host header (403), JSON-only bodies (415); every error is `{"error":{"code","message"}}`. One
  synthesis at a time; a client that disconnects cancels.
- The server exits on stdin EOF (the app is gone) and within 1 s of SIGTERM/SIGINT, also mid-synthesis.

### Key Data Flow

1. The user pastes a URL, a path or text (or opens a file) → `InputParser.parse` → `AppState.load`, which prewarms
   the server with the last language's model and runs `DocumentLoader.load` off the main actor.
2. `WebExtractor` fetches through defuddle.md (or reads the file, any encoding) → `MarkdownCleaner` /
   `PlainTextCleaner` → blocks → `DocumentBuilder` (`SpeechChunker` + `LanguageDetector`) → `ReadingDocument`.
3. `PlaybackController.open` starts at the saved position (content hash matching), with the voice and speed of
   the document language.
4. For the current unit and then 3 ahead: `TTSService.synthesize()` → `POST /synthesize` → WAV + timings, kept in
   `SynthesisCache`; the server reads each unit sentence by sentence.
5. `AudioQueuePlayer` plays one unit with its pause; when it finishes, the next one (already synthesized) starts.

### Runtime Locations

- Server log: `~/Library/Logs/ReadRead/tts-server.log` (rotated at 5 MB to `tts-server.log.1`; Show Log opens it),
  override `READREAD_LOG_DIR`.
- Reading positions: `~/Library/Application Support/ReadRead/positions.json` (`{"version":1,"positions":{key:
  {"unit","contentHash","date"}}}`, the newest 200), override `READREAD_POSITIONS_FILE`.
- HQ engine install: `~/Library/Application Support/ReadRead/hq/{python,venv,models,install.json}`, override
  `READREAD_HQ_HOME` (written only by `install-hq.sh`).
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

- **Input mode** — centered logo, a field for a URL, a file path or text (with a paste button), Read button
  (disabled while loading; a spinner and Cancel appear beside it), Open File button (plain text, .md, .markdown)
- **Reading mode** — header (title + source + close button), the blocks with the current sentence highlighted (tap a
  block to read from it; the view follows the sentence), a progress bar, previous / play-pause (a spinner while
  buffering) / next / stop and "x / N", the voice picker for the document language, the language menu
  (Auto / 中文 / English) and the speed slider

Both show an error banner with the full, selectable error text plus Show Log and Retry (the setup hint only when
engine files are missing, "Use System Voice" when the server cannot run), and "Starting voice engine…" (or the
system-voice status with "Use Kokoro") in the bottom bar.

## Important Conventions

- **Two languages: `zh` and `en`.** UK vs US English is a property of the voice, not of the language. The voice id
  prefix decides the pipeline on both sides (`Voice.route(forID:)` mirrors the server's routing).
- **The voice list is hardcoded only in `ContentView.swift`** (`Voice.all`, picker order). The server does not
  hardcode voices — `GET /voices` lists the ids in the model's voice files. `Voice.all` must be a subset of
  `/voices` for each language: `--self-test` (and with it the build's smoke test) fails when an app voice is missing.
- **Per-language preferences** — `voice_zh`, `voice_en`, `speed_zh`, `speed_en` and `last_language` (the model to
  prewarm) in `UserDefaults`; a voice is saved under its own language, the speed under the document's language; the
  Auto / 中文 / English choice is not stored. v0.1.x keys are migrated once (`voice_en-us` → `voice_en`, dropped
  languages removed, unknown voice ids fall back to `Voice.defaultVoice(for:)`).
- **Language detection** is `LanguageDetector`'s script census per unit, on the text itself (not defuddle metadata,
  which can be wrong); units in other scripts are shown and skipped. Auto / 中文 / English overrides it per document.
- **One unit = one sentence** (a long one cut at about 120 zh / 220 en characters), one request, one buffer: the
  highlight, "x / N", next/previous and the positions file all count units. The server still splits a unit into its
  own sentences.
- **Path resolution** checks the app bundle first, then `$READREAD_HOME`, then `<cwd>/tts_server`; missing files give
  `TTSError.resourcesMissing`, the only error that shows the setup hint.
- **No external Swift dependencies** — only Apple frameworks (SwiftUI, AppKit, AVFoundation, MediaPlayer, CryptoKit,
  UniformTypeIdentifiers).
- **No SwiftPM resources and no `Bundle.module`** — its accessor crashed the release app on other Macs. Icons are
  copied into `Contents/Resources` by `build-app.sh`, which refuses a binary that references `ReadRead_ReadRead.bundle`.
- **Swift 6 strict concurrency** — AppState, PlaybackController, SynthesisCache, AudioQueuePlayer,
  ReadingPositionStore, NowPlayingController, AppleSpeechSynthesizer, TTSService and TTSServerProcess are
  `@MainActor`; `DocumentLoader.load` is `@concurrent` (fetching, decoding and splitting a 1 MB file stay off the
  main thread). Async suspension points (URLSession, Task.sleep, CheckedContinuation) keep the main thread unblocked.
- **Injection seams** — AppState takes a `SpeechSynthesizer`, an `AudioOutput`, a `PreferencesStore`, a
  `DocumentLoader` (its `fetchPage`/`readFile` closures), a `ReadingPositionStoring`, a `NowPlayingPublishing`, the
  system-voice factory, `fileExists` and `sleep`; `PlaybackController` the same synthesizer, output, positions, Now
  Playing, sleep and clock; the server lifecycle takes a `ServerEnvironment` (`ProcessLauncher`, `FileSystem`, clock,
  sleep, token); `TTSClient` takes an `HTTPTransport`; `WebExtractor.fetchWithRetry` takes `fetch`/`sleep` closures
  and `extractFromURL` a `fetch`; `AppleSpeechSynthesizer` takes the installed-voice list. Tests run without Python,
  network or audio this way (`AudioQueuePlayer`'s offline mode renders real audio without a device).
- **The bundled interpreter is isolated** — the server runs with `-I -B` and a minimal environment; bytecode is
  precompiled as unchecked-hash `.pyc`, so nothing in the signed bundle changes at runtime.
- **Dependencies** — misaki is installed as `misaki[zh]` only; `misaki[en]` would pull phonemizer-fork, which clashes
  with phonemizer 3.4.0. Add or bump Python packages through `requirements.in` + `lock-deps.sh`.
- `LSUIElement=true` in Info.plist hides the app from the Dock. Version: `CFBundleShortVersionString` from the latest
  `v*` tag, `CFBundleVersion` from `git rev-list --count HEAD`.
- **Tests** — Swift: `Tests/ReadReadTests/` (XCTest, `swift test`); `Fixtures/` (real pages, text files, encodings
  made by `make_encodings.py`, reviewed `snapshots/` of whole documents) is read by path (`Fixtures` in
  TestSupport), excluded from the target, never a SwiftPM resource. Python: `tts_server/tests/` (pytest; fake MLX
  packages in `tests/fakes/` for the Qwen engine without a GPU). For logic that touches the network, audio, or the
  Python subprocess, inject the side-effecting work so tests run without real I/O.
