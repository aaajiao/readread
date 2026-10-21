# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Development: standalone CPython 3.12.15 + a venv from the hashed lock + the four model files + the pinned Defuddle
# page reader in $READREAD_HOME (default ~/.readread), plus a symlink to this repo's tts_server/ (so the dev app runs
# the checkout's server code; re-run setup.sh after switching to another checkout). Idempotent.
./scripts/setup.sh
swift build
swift run ReadRead                  # the menu bar app, using the dev environment (English UI: the zh-Hans strings
                                    # are copied into the app bundle only)
swift run ReadRead --self-test      # headless end-to-end check, prints one JSON line, exit 0 = ok
swift run ReadRead --self-test --engine qwen   # the same for the Qwen engine of $READREAD_HQ_HOME (GPU: run outside
                                    # any sandbox): READY engine/model, voices, zh + en at synth_speed 1.0, playback
                                    # at 1.25 through the time-stretch; exit 1 without a usable install, 2 for a bad
                                    # --engine

# Every check with a summary table, logs in build/check/: shellcheck, both lock checks, pytest (with the model tests
# when the dev environment has the models), swift build --build-tests -Xswiftc -warnings-as-errors, swift test
./scripts/check.sh                  # --fast: no model tests; --smoke: also build-app.sh and its smoke test

# Tests
swift test
READREAD_UPDATE_SNAPSHOTS=1 swift test --filter GoldenDocumentTests   # rewrite Fixtures/snapshots, then review the diff
READREAD_TEST_APPLE_SPEECH=1 swift test --filter AppleSpeechSynthesizerTests   # also the real system voices
# Real web views (outside any sandbox) with the Defuddle of READREAD_TEST_DEFUDDLE (a file) or $READREAD_HOME/defuddle
READREAD_TEST_DEFUDDLE=~/.readread/defuddle/defuddle.full.js READREAD_TEST_WEBKIT=1 \
  swift test --filter "LocalExtractorTests|DocumentReaderTests|SelfTestTests"
READREAD_RENDER_UI=1 READREAD_RENDER_DIR=<dir> swift test --filter UIRenderTests   # the panel and Settings as PNGs,
                                    # and the reading view's main-thread time on a 1 MB Markdown novel
# The README's screenshots (docs/screenshots/readme-*.png), the bottom bar showing that version
READREAD_RENDER_UI=1 READREAD_RENDER_DIR=docs/screenshots READREAD_RENDER_VERSION=0.5.0 \
  swift test --filter UIRenderTests/testTheReadmeScreenshots
~/.readread/env/bin/python3 -B -m pytest -q -p no:cacheprovider tts_server/tests      # fast tests
READREAD_MODELS_DIR=~/.readread/models ~/.readread/env/bin/python3 -B -m pytest -q -p no:cacheprovider tts_server/tests
# The Qwen engine with its real model (Metal: run outside any sandbox), from an install-hq.sh install
READREAD_HQ_HOME=<hq dir> ~/.readread/env/bin/python3 -B -m pytest -q -p no:cacheprovider \
  tts_server/tests/test_qwen_models.py
# The same from Swift (QwenEngineTests, outside any sandbox): TTSService.qwen reads zh + en and stops; HQInstaller runs
# --check of that install and an install into an empty temp home cancelled at its first download
READREAD_TEST_QWEN=1 READREAD_TEST_HQ_INSTALLER=1 READREAD_HQ_HOME=<hq dir> swift test --filter QwenEngineTests
# A complete install through HQInstaller (about 3.5 GB of downloads) into an empty dir, then one sentence from it;
# READREAD_TEST_HQ_SCRIPT=<install-hq.sh> runs another script (e.g. build/ReadRead.app's)
READREAD_TEST_HQ_FULL_INSTALL=1 READREAD_HQ_HOME=<empty dir> swift test --filter QwenEngineTests/testAFullInstallThenOneSentence

# Distribution: self-contained, ad-hoc signed build/ReadRead.app (about 0.8 GB). Ends with the smoke test.
./scripts/build-app.sh
./scripts/smoke-test.sh build/ReadRead.app      # the smoke test on its own

# ASR round trip of the voices (a developer tool: never bundled, not part of check.sh). A fixed zh + en corpus through
# the real server, transcribed by Whisper large-v3-turbo and SenseVoice, scored, compared with
# tools/asr_eval/baseline.json. Own venv and about 1.8 GB of models in $READREAD_ASR_HOME (default
# ~/Library/Caches/ReadRead/asr-eval).
tools/asr_eval/asr_eval.sh --check                            # the dev environment's server
tools/asr_eval/asr_eval.sh --app build/ReadRead.app --check   # a built app's bundled server

# Python dependencies: edit tts_server/requirements.in (or requirements-hq.in), then regenerate the hashed
# locks (needs uv)
./scripts/lock-deps.sh              # --check: fail if the committed locks are stale
tools/asr_eval/lock.sh              # the ASR tool's lock (tools/asr_eval/requirements.in); also --check

# Optional high-quality engine (Qwen3-TTS 1.7B on the GPU through MLX), installed outside the app into
# $READREAD_HQ_HOME (default ~/Library/Application Support/ReadRead/hq). The app runs this script from Settings ›
# Advanced › High-quality mode (its bundled copy, HQInstaller); one model, no model choice (--model takes only 1.7b).
./scripts/install-hq.sh [--json-progress]   # also --check, --uninstall
```

- Pinned inputs live in `scripts/lib/versions.sh` (CPython release, model files, the Qwen model's revision and files
  (`RR_HQ_MODELS="1.7b"`, `RR_HQ_1_7B_*`), the Defuddle npm tarball with npm's sha512 integrity and the two files taken
  from it, all with sha256) and `tts_server/requirements.lock` (every package hash-pinned; `requirements-hq.lock` for
  the HQ venv, constrained by it). `setup.sh` and `build-app.sh` install the same lock with `pip --require-hashes
  --no-deps`; `install-hq.sh` installs the HQ lock the same way. `scripts/lib/defuddle.sh` downloads, verifies and
  installs Defuddle (`defuddle.full.js` + `LICENSE`) for both. The ASR tool pins its models in `tools/asr_eval/pins.sh`.
- Build cache: `build/cache/` (`downloads/`, `models/`, `runtime/<key>/`, `pip/`). The runtime key hashes the Python
  release and the lock, so editing the lock rebuilds it. Delete `build/cache/` to force fresh, verified downloads.
- `build-app.sh` fails on any error, builds in `build/.staging/ReadRead.app`, signs inside out (ad-hoc, no `--deep`),
  runs `smoke-test.sh`, and only then replaces `build/ReadRead.app`; a failed build leaves the old app and keeps its own
  as `build/ReadRead.app.failed`. It copies the icons, every `Sources/ReadRead/Resources/*.lproj/*.strings` and the
  pinned Defuddle files into `Contents/Resources`, and (its "v0.5.0 installer" block, `INSTALLER_FILES`) install-hq.sh
  with exactly what it reads (`scripts/lib/{common,versions}.sh`, `tts_server/requirements-hq.{in,lock}`) into
  `Contents/Resources/installer/` in the repo's layout, so the script's `RR_REPO_DIR` is that folder; common.sh refuses
  to run from inside a `*.app/Contents/` without `READREAD_BUILD_CACHE` (the default cache would be in the signed
  bundle). Its Info.plist heredoc declares the localizations (en, zh-Hans), the Services item, the document types (one
  per `ReadableFileType`, Viewer / Alternate) and ATS (local networking plus `NSAllowsArbitraryLoadsInWebContent`: the
  page reader's web view may open http:// pages; URLSession stays under ATS). The smoke test checks the bundled Defuddle
  files against their pins, the bundled server (READY, auth, zh + en synthesis as JSON: duration near a known-good
  build's, every word timed, no espeak-ng data errors in its stderr, exit on stdin EOF), `--self-test` from the bundle
  (its page reader must be the bundle's own Defuddle), the bundled installer ((hq): exactly those files; `--help`;
  `--check --json-progress` on an empty HQ home exits 1 within 10 s with JSON events only, the last an error; the guard
  without `READREAD_BUILD_CACHE`), the bundle unchanged at runtime, the server from a ≥160-character bundle path,
  `codesign --verify`, and the Info.plist keys and zh-Hans.lproj files. This build is the release gate (no release
  script or CI): a GitHub release is the tag's build, zipped with `ditto -c -k --keepParent build/ReadRead.app
  ReadRead.app.zip` (keeps the signature and the bundle's symlinks), attached as `ReadRead.app.zip`.
- A cached runtime is reused only while its files match the sha256 manifest written when it was built; `setup.sh`
  rebuilds `env/` when it no longer holds exactly the locked distributions and reinstalls `defuddle/` when a file
  differs from its pin. Both scripts refuse a `requirements.lock` that does not pin what `requirements.in` asks for
  (run `lock-deps.sh`).
- To keep test runs away from the real `~/.readread` and `~/Library/{Logs,Caches,Application Support}/ReadRead`,
  point `READREAD_HOME`, `READREAD_LOG_DIR`, `READREAD_CACHE_DIR`, `READREAD_USER_LEXICON`, `READREAD_POSITIONS_FILE`,
  `READREAD_HQ_HOME` and `READREAD_ASR_HOME` at scratch directories (the smoke test sets the first four, `check.sh`
  points the runtime ones that are unset into a temp dir, `--self-test` writes no positions). The Python HTTP tests,
  the smoke test, the content tests' local HTTP server and `--self-test` start servers on 127.0.0.1. Swift tests use
  an injected `PreferencesStore` or a `UserDefaults(suiteName:)` suite, never `AppState()` (the real server, audio
  and `UserDefaults.standard`).

## Architecture

ReadRead is a macOS menu bar reader for Mandarin Chinese and English (Apple Silicon only, macOS 26+), with two
processes:

**Swift app** (menu bar UI, page and document readers) → HTTP on 127.0.0.1 with a per-launch bearer token →
**Python child process** (`tts_server/`, Kokoro through kokoro-onnx 0.6.1)

Optional high-quality mode: the same server code as a second child process with a lifecycle of its own,
`--engine qwen` (Qwen3-TTS 1.7B through MLX on the GPU) from the HQ install's venv (`install-hq.sh`, outside the
bundle), when Settings chose it and install.json says the install is usable. The two never share a process or a log.

Web pages are read in the app, by the pinned Defuddle 0.19.5 (`defuddle.full.js`, npm, MIT) in an offscreen
WKWebView, with `https://defuddle.md` as the fallback (or, per Settings, the only reader).

### Swift Side (Sources/ReadRead/)

App and UI:

- `main.swift` — Entry point. `--self-test [--engine kokoro|qwen]` runs `SelfTest` headless on `RunLoop.main.run()`
  (the self test's web view crashes the process under `dispatchMain()`); otherwise `SingleInstance` hands off to a
  running copy, then `ReadReadApp.main()`.
- `AppState.swift` — `AppState`, the app's state (`@Observable`): the input and the one document load at a time, the
  player, the error banner and notices, the preferences, what Settings changes, and the engine it reads with: Kokoro
  (`engine`), Qwen (`engineKind`, from the `QwenEngineFactory`, made per `HQInstallation` and replaced when it
  changes) only while `installer.installState` is `.installed` (a stored qwen choice falls back to Kokoro once, with
  a notice, and the `engine` key is removed), the system voice standing in for either. `setEngine` (a user edit)
  switches the player (`setSynthesizer`), stops the engine left behind (`stop()`) and prewarms the new one; it is a
  fresh attempt (`resetFailure()` on the chosen engine) and a failed reading whose banner is up goes on from the
  failed sentence with it. Any engine switch dismisses a player failure on screen (the left engine's: its offers,
  setup hint and log are not the new one's). `runInstaller` / `cancelInstaller` / `installerFinished` drive
  `HQInstalling` (install and uninstall leave Qwen for Kokoro and stop its server first; a finished install selects
  Qwen; one that fails or is cancelled gives a Qwen choice back while Qwen can still be chosen; results under
  Settings' High-quality mode, or as the panel's notice while Settings is closed; a fallback found as Settings opens,
  `refreshForSettings`, always under High-quality mode), `highQualityStatus` and `highQualityRemoval` (Uninstall…,
  Remove Downloaded Files… or nothing) for that section. `NoHQInstaller` (tests).
- `ReadReadApp.swift` — `AppDelegate`, the `AppShell` (panel, Settings, `isSettingsVisible`, activation, quit): the
  status item, the `FloatingPanel`, the Settings window, and the ways in from other apps: Services
  (`@objc(readAloud:userData:error:)`, the Info.plist's `NSMessage`), Open With (`application(_:open:)`, also files
  given at launch), reopen and a second launch (`SingleInstance.showPanelRequest`) show the panel. Does not start the
  server; `AppState.shutdown()` on quit (both servers, the installer: SIGTERM, SIGKILL after 2 s).
- `StatusItem.swift` — `StatusItemModel` (icon, a small waveform while reading, an ellipsis while buffering, tooltip
  with the document, the menu: Play/Pause, Previous/Next Sentence, Stop, Open File…, Read Clipboard, Settings…, Quit)
  and `StatusItemController` (left click toggles the panel, right or ⌃-click opens the menu, drops are read). Icon
  from `Bundle.main`, an SF Symbol under `swift run`.
- `FloatingPanel.swift` — NSPanel subclass: borderless, floating, non-activating (typing does not take the focus from
  the frontmost app; a full-screen app keeps its Space), on every Space, transparent for the SwiftUI glass, resizable
  from its grip (`PanelResize`, `PanelResizeGrip`) within `ReadingPreferences` bounds. Every key press goes through
  `KeyRouter` first: an accessory app's main menu does not route keys to a non-activating panel.
- `KeyRouting.swift` — `AppCommand` (keyboard, status menu and buttons; `AppState.perform` runs it, window commands
  go to the `AppShell`) and `KeyRouter`, the panel's one keyboard map: Space play/pause and ← → previous/next
  sentence (reading mode, outside the text field), Esc and ⌘W hide, ⌘V reads the clipboard outside the text field
  (pastes inside it), ⌘O, ⌘,, ⌘Q, ⌘+ ⌘− ⌘0 text size; in the text field ⌘X ⌘C ⌘V ⌘A ⌘Z ⇧⌘Z edit; while an input
  method composes, every key is its. A held key repeats only what `repeatsWhileHeld` (sentences, text size, edits);
  the other commands' auto-repeats are swallowed (`Routing.swallow`). Settings › General lists it (`ShortcutHelp`).
- `ContentView.swift` — the panel: `PanelContent` (input or reading mode, banners, bottom bar) on Liquid Glass,
  drops anywhere on it; `InputView`, `BottomBar` (engine status, "High-quality mode" with Qwen, or the system voice,
  version, Settings, Quit), `MessageBanner` (the full, selectable error or notice; Show More for long ones, Copy, Use
  Kokoro after a Qwen failure, Use System Voice when Kokoro cannot run, Show Log of the engine reading, Retry) and
  `SetupBanner` (Kokoro's files only).
- `ReadingView.swift` — reading mode: `ReadingList` (lazy rows, `ReadingRows`: every block, one over 1,500 characters
  cut between its units into rows of about 1,000 that read as lines of one paragraph, so the row being read stays
  small even in a Markdown novel's one block of 350,000 characters; every sentence a `readread-unit://<index>` link,
  a tap reads from there), `CurrentBlockText` (only the current row redraws; the word from
  `PlaybackController.wordTimeline`, sampled at most 20 times a second), `AutoFollow` (scrolls with the reading until
  the user scrolls by hand; Back to Current, a chosen sentence, or the next sentence starting while the current one
  is in view resumes it; in view = the sentence's share of its row is in the row's visible part, `RowShare` from the
  row's geometry, as a row can be taller than the view), `ReadingScroll`, `ReadingHeader` (title, the source as a
  link or Show in Finder, Close),
  `TransportBar` (progress, previous / play-pause / next, "x / N", text size, stop), `ReadingSettingsSection` (voice
  with ▶, the language menu, speed).
- `SettingsView.swift` — the Settings window (⌘,), `SettingsTab`: General (launch at login, shortcuts, Services and
  drops), Voices (a voice with ▶ and a speed per language; Qwen's one voice per language as a label), Reading (text
  size, following, `ExtractionMode`), Advanced (the Engine radio picker, Kokoro (standard) / Qwen3-TTS (high quality),
  disabled as a whole while only Kokoro can be chosen, with a hint why; the active engine's status and Restart
  Engine; `HighQualityModeSection`: what it is, then per `HighQualityStatus` Install (an inline confirmation: size,
  sources, disk space), `InstallerProgressView` (step bar, the file's bytes) with Cancel, the installed model's size
  and date with Verify and Uninstall… (confirmed inline), Repair, Try Again and Show Installer Log, Uninstall… or
  Remove Downloaded Files… also after a failure or a cancel (and the latter beside Install for what an unfinished
  first install left), nothing to repair or remove without an HQ home; `HQFormat`; the
  engine and installer logs, the pronunciation file, Clear Cached Articles). What a Settings action did, or why it
  failed, shows under its own section (`AppState.settingsNotice`, `SettingsNotice`), not in the panel's banner,
  which may be hidden.
  `SettingsWindowController`: a plain NSWindow with NSTabViewController toolbar tabs, brought forward with the app
  (an accessory app's SwiftUI Settings scene does not reliably come forward).
- `Voice.swift` — `VoiceAccent`, `Voice` with `Voice.all` (Kokoro's voice list, picker order), `voices(for:in:)` and
  `VoiceGroup` (中文 / English (US) / English (UK); `groups(for:in:)` of a catalog).
- `HQEngine.swift` — the types of the high-quality engine both halves share: `EngineKind` (kokoro | qwen, the
  `engine` key), `QwenModel` (the one model: id "1.7b", its folder, engineID "qwen-1.7b"), `Voice.qwen` (serena zh,
  aiden en) and `Voice.catalog(for:)`, `HQInstallation`, `HQInstallState`, `InstallerOperation`, `InstallerEvent`,
  `InstallerProgress`, `InstallerState`, the `HQInstalling` protocol and `QwenEngineFactory`.
- `HQInstallation.swift` — the HQ home (`$READREAD_HQ_HOME`, `~` expanded, else `~/Library/Application
  Support/ReadRead/hq`; set but empty = no home, `HQInstallState.hasNoHome`) and install.json → `HQInstallState`: no
  file = notInstalled, unless install.json.prev is there (an install or repair that did not finish: damaged); over
  1 MB, not JSON, version ≠ 1, no "1.7b" entry, no `models/<QwenModel.folder>/`, no executable `venv/bin/python3` or
  no `completionStamps` (`python/.readread-python`, `venv/.readread-hq-venv`, written once each is complete) =
  damaged (the message says which; other model keys are ignored). `hasLeftovers`: python/, python.partial/, venv/ or
  the model folder of an install that never finished. Reads at most 1 MB, never runs a process.
- `HQInstaller.swift` — `HQInstaller` (`@Observable`, the live `HQInstalling`): `InstallerEvent.parse` (junk → nil);
  the script (an explicit path, else the bundle's `Contents/Resources/installer/scripts/install-hq.sh`, the checkout's
  next to `$READREAD_HOME/tts_server`'s symlink target, `<cwd>/scripts/install-hq.sh`) run as `/bin/bash <script>
  [--check|--uninstall] --json-progress` through the `ProcessLauncher` in a clean environment (HOME, a fixed PATH,
  LANG, `TMPDIR=<cache>/installer-tmp`, `READREAD_HQ_HOME`, `READREAD_BUILD_CACHE=<cache>/hq-build`,
  `READREAD_TTS_SERVER_DIR` = the app's server code); stdout events → `state` (step, download bytes); stderr →
  `hq-install.log` with a header and an end line per run. Exit 0 after a done event = finished, an error event =
  failed with its message, `cancel()` (SIGTERM) = cancelled, anything else = failed naming the status and the log;
  then `refresh()` (also `hasLeftoverFiles`), then `onFinish`. Cancel and `shutdown()` (SIGTERM, SIGKILL after 2 s)
  signal the script's process group (`terminateGroup` / `killGroup`: bash defers its trap while a foreground command
  runs, and nothing is left behind); `installer-tmp` is emptied before a run and removed after it.
- `VoicePicker.swift` — `VoicePickerButton` (opens the grouped `VoiceListView`, ▶ on every row; the voice's name
  alone when the engine has one voice for the language),
  `VoicePreviewButton`, `SpeedControl` (a slider, or − 1.0× + in input mode), `VoiceSettingsGrid` (both languages'
  voice and speed: input mode and Settings › Voices).
- `VoicePreview.swift` — `VoicePreviewer`: a fixed short sample per language through the current engine at speed 1.0,
  kept per (engine, voice) in memory and as a WAV in `$READREAD_CACHE_DIR/previews/`; it plays on its own output and
  the document pauses meanwhile.
- `ReadingPreferences.swift` — `font_size`, `auto_follow`, `panel_width`, `panel_height` (the store of the voice
  preferences); `PanelPlacement` (under the status item, inside the screen's visible frame).
- `LaunchAtLogin.swift` — `LoginItemControlling`; `MainAppLoginItem` is `SMAppService.mainApp` (`status(for:)`:
  `.notFound`, a fresh install or one removed in Login Items, is off, not an error).
- `DropPayload.swift` — `PasteboardItems` (file URLs, links, text: drops, the clipboard, Services), `DropResolver`
  (a readable file first, then a web link, then text through `InputParser`, except text that only names the files,
  as Finder's ⌘C puts beside them; `.unsupportedFile`),
  `PasteboardAccess` / `SystemPasteboard`, `ItemProviderReader` (SwiftUI drops).
- `SelfTest.swift` — `--self-test`: first the page reader (the bundle's or `$READREAD_HOME`'s Defuddle reads a page
  held in memory in an offscreen web view, no network, into exactly the expected title and units), then server start,
  catalog, zh / en-US / en-GB synthesis with timings, and a playback check (a fixture document through
  `DocumentBuilder`, three units synthesized and rendered through an offline `AudioQueuePlayer`: no gap or cut
  between units). Prints one JSON line (`extraction` names the script it used); `ok` needs every part.
  `--self-test --engine qwen` instead: the install of `$READREAD_HQ_HOME` read as the app reads it, the Qwen server
  started with `--preload zh,en` (READY engine "qwen", model "1.7b"), `Voice.qwen` ⊆ `/voices`, serena and aiden
  (`synth_speed` 1.0, durations within 0.7–1.4× of the measured 7.2 s and 4.8 s, no tokens), the playback check at
  1.25 (rendered ≈ audio / 1.25), stop, the child exited; 480 s overall; the JSON adds `"engine":"qwen"`,
  `"model":"1.7b"` and `"hq"`.

Text pipeline (input → `ReadingDocument`):

- `ReadingDocument.swift` — the shared model: `DocumentSource` (url / file / text), `LanguageChoice`, `ReadingBlock`
  (display paragraph, its unit range), `SpeechUnit` (block, Character range for highlighting, `speakText`, language or
  nil = skipped, kind title/heading/sentence, `pauseAfter` 0.25 s, 0.5 s after the title, a heading or a block end),
  `ReadingDocument` (`contentHash` = sha256 of the speak texts, `positionKey`).
- `InputParser.swift` — the field's text → `ReadingInput` (`.url`, `.file`, `.text`): http(s) URLs and bare hosts
  (https; http for local addresses), share text with a link and little else around it, existing file paths (`/`,
  `~`, `file://`, Terminal escapes), anything else is text to read. `isLocalNetwork` (localhost and the names for
  local use: .local, .lan, .internal, .home.arpa, .test, .example, .invalid, fritz.box, …; private, loopback and
  link-local IPv4 in every spelling inet_aton reads (127.1, 0x7f.1), IPv6 ULA / link-local / site-local / :: / ::1
  and IPv4-mapped; single-label hosts): those pages are read on this Mac only, never sent to defuddle.md.
- `ReadableFileType.swift` — `ReadableFileType`, the formats ReadRead opens (plain text, Markdown, HTML, RTF, RTFD,
  .docx, .doc, .odt, PDF, EPUB): extensions, type identifiers, `of(url)` (another extension whose type conforms to
  public.plain-text is plain text). The one list behind the file picker, drops, Open With and `DocumentReader`.
  `ExtractionMode` (`local`: this Mac first; `remote`: defuddle.md only), read at each fetch.
- `DocumentLoader.swift` — `@concurrent load(_:)`: fetch (`WebPageFetcher`) or read (`DocumentReader`), clean,
  build, checking cancellation between the steps; `DocumentError.nothingToRead` (empty, markup only, or only scripts
  ReadRead does not read), `.localNetwork` (a local page and no Defuddle to read it) and `.pageUnreadable` (both
  readers' reasons). Pasted text that looks like Markdown goes through the Markdown cleaner.
- `WebPageFetcher.swift` — URL → `WebPage` as `ExtractionMode` says: `LocalExtractor` first, defuddle.md when it fails
  or Defuddle is not installed; or defuddle.md only. A page read here only in part (`.incomplete`) or with fewer
  than 200 characters to read (`isShort`: perhaps a placeholder) is asked of defuddle.md too, the longer page wins,
  and the local one is not cached. Local-network pages only ever here. `ArticleCache` first (in defuddle.md mode
  only the entries defuddle.md made count).
- `LocalExtractor.swift` — the page reader (main actor): an offscreen `WKWebView` (never in a window) with a
  non-persistent data store loads the page, waits until the network is quiet (hard limit 15 s), and runs Defuddle in
  an isolated JavaScript world the page's scripts cannot see → Markdown and metadata. No popups, downloads, autoplay
  or frames from the network; images, media, fonts and pings are blocked by content rules (compiled into
  `$READREAD_CACHE_DIR/webkit-rules/`). A web page sees a visible document whose `requestAnimationFrame` runs on
  16 ms timers (a web view in no window is hidden and draws no frames) and whose Web Speech does nothing
  (`pageWorldScript`). The hard limit bounds the wait, probes included; injecting and running Defuddle share
  `scriptLimit` (10 s); HTML still arriving at the hard limit is read and thrown as `.incomplete(page)`. A local
  .html file loads nothing from the network and its scripts do not run; one with bytes beyond ASCII and no charset
  in its first 1,024 bytes (`undeclaredText`) is decoded by `TextDecoding` and loaded as UTF-8 (WebKit would read
  Latin-1). One web view and data store per read, so one content process, which `close()` ends
  (`_killWebContentProcessAndResetState`, WebKit SPI, where it exists): a page script that never returns would keep
  a core busy until ReadRead quits. Cancelling the task stops the load. `LocalExtractorError` (`bundleMissing`,
  `timedOut`, `noContent`, `incomplete`, …).
- `DefuddleBundle.swift` — the pinned `defuddle.full.js`: `Contents/Resources/defuddle/` in the app, else
  `$READREAD_HOME/defuddle/`; a file counts when it is non-empty, at most 8 MB, UTF-8 and names Defuddle. `locate`
  also gives its path.
- `ArticleCache.swift` — pages read before: `<cache>/articles/<sha256 of the URL without its fragment>.json` (the
  `WebPage`, which reader made it, the date), 30 days, the directory under 50 MB (oldest first), unreadable entries
  removed. Settings' Clear Cached Articles is `removeAll()` (the directory renamed away first, then deleted: a page
  stored meanwhile cannot make it fail).
- `WebExtractor.swift` — `WebPage` {title without the site suffix, markdown, domain, author / site / published
  (shown, never read), `isPlainText`}, Codable for the cache. `extractFromURL` → `https://defuddle.md/{url-without-
  scheme}` (frontmatter split off) on an ephemeral session (no cookies, no URL cache, 30 s per request): network
  errors and 5xx retried with exponential backoff up to `maxAttempts` (3), 502 (defuddle.md could not fetch the page)
  only once, 429 never (`quotaExceeded`: 1,000 free pages a month); other answers keep the service's text
  (`serviceStatus`). `readFile` → `LocalFile` {title from frontmatter or the file name, body, isMarkdown; `blocks` for
  the document formats}, any encoding `TextDecoding` knows, 32 MB limit. `fetchWithRetry` takes injectable
  `fetch`/`sleep` closures, `extractFromURL` a `fetch`.
- `DocumentReader.swift` — a file → `LocalFile` by its `ReadableFileType`: text and Markdown through
  `WebExtractor.readFile`; HTML through the local Defuddle (no network, no page scripts; a page still loading at the
  hard limit is read as far as it came), else the system's HTML reader (its importer on the main thread up to
  256 KB, `AttributedTextReader.readLargeHTML` off it above); a .doc that holds HTML as HTML; RTF, RTFD, Word and
  OpenDocument through `AttributedTextReader`; PDF through `PDFTextReader`; EPUB through `EPUBReader` (unpacked under
  `<cache>/epub/`). Size limits per format (HTML 32 MB, RTF and .doc 64, .docx and .odt 128, RTFD and PDF 256, EPUB
  512 and 1 GB unpacked), at most 32 million characters kept; `finish` cleans the blocks as plain text is cleaned
  and drops a web page's boilerplate sections, but only the citation sections (`citationHeadings`: References,
  参考文献 …) of the user's own documents, whose Notes are read. An unknown extension is read as text.
  `DocumentReadError` (tooLarge, unreadable, passwordProtected, noTextLayer, drmProtected, invalidEPUB,
  unpackedTooLarge).
- `AttributedTextReader.swift` — `NSAttributedString` → blocks: list items (markers dropped), headings by style or a
  clearly larger (or short, all-bold) font, attachments dropped, table cells as paragraphs. A .doc is read as what it
  holds (`docContent`: Word 97–2003, RTF, HTML, a .docx, Word 2003 XML, else the importer's guess). HTML: the
  importer (main thread) up to `importerLimit` (256 KB), larger through `readLargeHTML` (libxml2's HTML parser and
  `XHTMLBlockParser`).
- `PDFTextReader.swift` — PDFKit's lines → blocks: running headers, footers and page numbers dropped, lines joined
  into paragraphs (also across a page break and a column break; each line measured against its own column),
  line-end hyphens joined (kept before a compound's next part: text-to-speech), CJK lines joined without a space,
  single lines in a clearly larger font as headings.
- `EPUBReader.swift` — the ZIP central directory checked first (`ZipDirectory`: entry count, unpacked size, no
  absolute names, `..`, links, ZIP64 or encrypted entries), `/usr/bin/ditto` unpacks into a directory of its own
  (watched: size limit, two minutes), checked again, removed afterwards; DRM is refused (font obfuscation is fine).
  container.xml → the OPF (`SimpleXML`): its title and spine (linear="no" items and the navigation document skipped);
  `XHTMLBlockParser` keeps headings, paragraphs, list items and quotes, and skips the head, scripts, styles, nav, SVG,
  MathML, ruby annotations, footnotes and endnotes with their markers; a chapter that is not well-formed is made so
  by libxml2's HTML parser first (`blocks(ofHTML:)`, also for large HTML files), off the main thread. A spine none
  of whose documents is in the file, or content that unpacks past the limit (`unpackedTooLarge`), is refused.
- `TextDecoding.swift` — bytes → text: BOM, UTF-16 by NUL density, strict (or nearly strict) UTF-8; Korean (EUC-KR,
  CP949) and Japanese (Shift_JIS with kana, or mostly GBK's rare-character area) files are refused
  (`unsupportedLanguage`; a few kanji alone stay ambiguous and read as Chinese, and so does short Hangul-looking
  text without Korean word endings, which short spaced GBK can be); then GB18030 / Big5 (CP950) / UTF-16 with few
  NULs / Windows-1252 scored for plausibility (a GB18030 / Big5 tie goes to the reading with fewer rare characters);
  CRLF and CR → LF, control characters dropped.
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
  changes at once, prefetched units are re-synthesized after the slider rests 300 ms (never for an engine whose
  `honoursSpeed` is false: Qwen and the system voice make audio at 1.0 only), older audio plays time-stretched
  meanwhile. A new voice drops that voice's audio; a voice or language change restarts the current sentence while
  playing and keeps it paused while paused; so does `setSynthesizer(_:voices:)` (another engine, with its voices:
  Qwen's one per language). `restore(settings:)` (preferences) never restarts audio. Pause while buffering stays
  paused. A failure stops on the failed unit (Retry restarts the server when it
  was the problem). Progress by audio time (real durations, else estimates from 5.2 zh / 15.4 en characters per
  second). `wordTimeline` (the loaded unit's token timings on its display text) and `playbackTime` (the output's
  time, not observed) drive the word highlight. Positions: saved 2 s after the unit changes and on stop/close (and
  when another document opens over this one), removed at the end, restored on open while the content hash matches.
- `WordTimeline.swift` — the engine's token timings → words of the unit's display text, in synthesized time (so
  time-stretched audio needs no conversion): sequential matching on the surface (case, width and accents ignored,
  Traditional folded to Simplified, a Latin token only on word boundaries); tokens that do not match (numbers spelled
  out, expanded abbreviations) are spread over the words between their matched neighbours. No tokens (the system
  voice) → no words; the sentence alone is highlighted.
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
  sentence and token timings, `synthSpeed`), the `SpeechSynthesizer` protocol (`engineID`, `honoursSpeed`,
  `stop() async`: stop the server now, it starts again on demand; the default calls `shutdown()`).
- `TTSService.swift` — The production `SpeechSynthesizer`: starts the server on demand, sends requests through
  `TTSClient`, retries once on a fresh server when the old one died under a request (never after a `stop()` or
  `shutdown()` since the request began: it fails with `CancellationError`). `live()` is Kokoro's;
  `qwen(installation:)` (the app's `QwenEngineFactory`) runs a `.qwen` server lifecycle of its own (`engineID`
  "qwen-1.7b", `honoursSpeed` false); `stop()` awaits the server's exit off the main thread; `resetFailure()`.
- `TTSServerProcess.swift` — Server lifecycle (main actor), one per `ServerFlavor` (`.kokoro`,
  `.qwen(HQInstallation)`): lazy start, prewarm, READY/FATAL handshake (READY's `engine` / `model` must be the
  flavor's: Kokoro accepts none or "kokoro", Qwen needs "qwen" and "1.7b"; a mismatch is a protocol error naming
  both; a Qwen FATAL before READY is `hqUnavailable` with the server's message), crash detection with lazy restart
  and backoff, no auto-restart after 3 crashes in 2 minutes (the error names the log; `restart()` and
  `resetFailure()` forget it), stop = close stdin + SIGTERM, SIGKILL after 2 s (the server stays in `terminating`
  until its exit: it counts as running, and a second stop() waits for it too). `ServerPolicy`: Kokoro 90 s start
  timeout and an idle shutdown after 15 minutes without synthesis while nothing plays; `.qwen` 180 s and 5 minutes
  (checked every 30 s).
  Kokoro launches `-I -B <server>/tts_server.py --models-dir <models> [--preload …]`, Qwen adds `--engine qwen
  --model 1.7b` and uses `<hq>/models`; the same clean environment. Every side effect goes through
  `ServerEnvironment` (launcher, file system, clock, sleep, token).
- `TTSServerPaths.swift` — Finds python, server code and models (app bundle `Contents/Resources` first, then
  `$READREAD_HOME/{env/bin/python3,tts_server,models}`, then `<cwd>/tts_server`), checking model sizes; `resolveQwen`:
  the HQ venv's python and `<hq>/models/<QwenModel.folder>` (missing → `TTSError.hqUnavailable`) with the same server
  code candidates; `RuntimeDirectories` (log, cache, user lexicon, with the env overrides; the Qwen and installer
  logs, `installer-tmp`, `hq-build`).
- `ProcessLauncher.swift` — `Process` launcher: stdin pipe held open for the child's lifetime, stdout pipe for the
  handshake, stderr appended to the log file (also install-hq.sh's runs); `terminateGroup` / `killGroup` signal the
  child's process group (`Process` makes the child its leader; the child alone otherwise).
- `ServerHandshake.swift` (READY/FATAL parsing; `ReadyInfo` with optional `engine`, `model`), `ServerLog.swift` (a
  child's stderr log, rotated at 5 MB to `.1`: `tts-server.log`, `tts-server-qwen.log`, `hq-install.log`),
  `TTSClient.swift` (API v2 over URLSession; error JSON → `TTSError` with the server's message; `synth_speed`, else
  the requested speed), `TTSError.swift` (English text with zh-Hans translations; what the server or the system said
  stays as it is; `hqUnavailable`: the HQ install cannot run the server, which `isServerFailure` but never
  `isResourcesMissing`, and its message sends the user to Settings › Advanced › High-quality mode),
  `VoicePreferences.swift` (the voices, speeds, last language and `engine` keys), `SingleInstance.swift`,
  `FileSystem.swift` (file-operation seam; `contents(atPath:maxBytes:)`, `resolvingSymlinks`).

Resources (`Sources/ReadRead/Resources/`, excluded from the target, copied by `build-app.sh`): the icons and
`zh-Hans.lproj/` — `Localizable.strings` (the UI), `Content.strings` (page, file and format messages:
`String(localized: "…", table: "Content")`), `Engine.strings` (the high-quality engine's, install.json's and the
installer's messages: `table: "Engine"`), `ServicesMenu.strings` (the Services item's title).

### Python Side (tts_server/)

- `tts_server.py` — Entry point: arguments (`--engine kokoro|qwen`, `--model 1.7b`, the only model), token, cache and
  temp directories, bind, `--preload`, READY/FATAL, stdin-EOF watchdog, SIGTERM/SIGINT.
- `readread_tts/` — `server` (HTTP API v2), `engine` (the interface both engines implement), `engine_kokoro`
  (routing, ONNX sessions, synthesis), `engine_qwen` (the optional Qwen3-TTS engine), `frontend_zh`, `frontend_en`,
  `sentences` (clean-up and splitting), `lexicon` + `lexicon_zh.json` (built-in overrides), `zhuyin`, `g2p`,
  `espeak` (short espeak-ng data path), `audio` (trim, silence, WAV).
- The Qwen engine (`--engine qwen`, run from the HQ venv of `install-hq.sh`, not in the app bundle): Qwen3-TTS-12Hz
  1.7B CustomVoice 8-bit (`QWEN_MODELS = ("1.7b",)`: one model, no choice) on the GPU through MLX; voices `serena`
  (zh) and `aiden` (en); streaming generation only, a per-sentence seed, `synth_speed` always 1.0 (the player
  time-stretches). Details in `tts_server/README.md`. The app runs it from the bundle's server code with the HQ
  venv's python (`TTSService.qwen`, a `.qwen` lifecycle) when Settings › Advanced › Engine is Qwen3-TTS.
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

### Developer tools (tools/)

- `tools/asr_eval/` — the ASR round trip (`asr_eval.sh`, Python package `readread_asr/`): a fixed corpus (three
  Chinese, two English passages) through the real server one sentence at a time (the dev environment, `--app` a built
  bundle, or `--engine qwen`), Whisper large-v3-turbo and SenseVoice-Small transcribe it, scored by CER / WER, word
  probes (numbers, dates, polyphones, English inside Chinese), speaker drift (CAM++) and anomalies; `--check`
  compares with `baseline.json`, `--write-baseline` rewrites it, `--rescore` re-scores a run, `--selfcheck` runs the
  scoring's unit cases. Setup (its own CPython from versions.sh, a hash-locked venv, models pinned in `pins.sh`) needs
  the network once; runs are offline (`HF_HUB_OFFLINE=1`, nothing in `~/.cache/huggingface`). Reference:
  `tools/asr_eval/README.md`.

### Server Protocol (API v2)

- Launch: `<python> -I -B tts_server.py --models-dir <dir> [--preload zh|en|zh,en]` with `READREAD_TOKEN`
  (64 hex characters, new per launch), `READREAD_CACHE_DIR` and `READREAD_USER_LEXICON` in a clean environment. The
  HQ engine: `<hq venv python> -I -B tts_server.py --engine qwen --model 1.7b --models-dir <hq>/models
  [--preload …]`, the same environment (the app always passes `--model 1.7b`, the only model and the default).
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

1. The user pastes a URL, a path or text, opens or drops a file, reads the clipboard, or another app sends text, a
   link or a file (Services, Open With) → `InputParser.parse` / `DropResolver` → `AppState.load`, which (with Qwen
   chosen) reads install.json again, prewarms the active engine's server with the last language's model and runs
   `DocumentLoader.load` off the main actor.
2. A page: `WebPageFetcher` (`ArticleCache`, else `LocalExtractor` with Defuddle on this Mac, else defuddle.md, as
   `ExtractionMode` says) → Markdown → `MarkdownCleaner`. A file: `DocumentReader` (text and Markdown in any encoding
   → `MarkdownCleaner` / `PlainTextCleaner`; the other formats → cleaned blocks). Blocks → `DocumentBuilder`
   (`SpeechChunker` + `LanguageDetector`) → `ReadingDocument`.
3. `PlaybackController.open` starts at the saved position (content hash matching), with the voice and speed of
   the document language.
4. For the current unit and then 3 ahead: `TTSService.synthesize()` (Kokoro's server, or the Qwen one in
   high-quality mode) → `POST /synthesize` → WAV + timings, kept in `SynthesisCache`; the server reads each unit
   sentence by sentence.
5. `AudioQueuePlayer` plays one unit with its pause; when it finishes, the next one (already synthesized) starts.
   The reading view highlights the sentence and the word (`WordTimeline`) and follows it.

### Runtime Locations

- Logs in `~/Library/Logs/ReadRead/`, override `READREAD_LOG_DIR`, each rotated at 5 MB to `<name>.1`:
  `tts-server.log` (Kokoro's server; Show Log opens the log of the engine reading), `tts-server-qwen.log` (the Qwen
  server), `hq-install.log` (every install-hq.sh run's stderr, with a header and an end line per run; Settings ›
  Advanced › Installer log).
- Reading positions: `~/Library/Application Support/ReadRead/positions.json` (`{"version":1,"positions":{key:
  {"unit","contentHash","date"}}}`, the newest 200), override `READREAD_POSITIONS_FILE`.
- HQ engine install: `~/Library/Application Support/ReadRead/hq/{python,venv,models,install.json}` (install.json is
  `install.json.prev` while an install or repair changes the install), override `READREAD_HQ_HOME` (set but empty:
  no home, never the default; written only by `install-hq.sh`, which the app runs; the app only reads install.json
  and stats).
- Cache: `~/Library/Caches/ReadRead/` (`espeak-ng-data` symlink, `jieba.cache`, `tmp/<pid>/`, `articles/` (the
  article cache), `webkit-rules/` (compiled content rules), `epub/` (a book being read, removed after), `previews/`
  (voice samples), `hq-build/` (install-hq.sh's `READREAD_BUILD_CACHE`: the Python tarball and pip's cache, kept
  for a resume or repair), `installer-tmp/` (install-hq.sh's TMPDIR, only while it runs)), override
  `READREAD_CACHE_DIR`. Its
  `espeak-ng-data` path must stay within 150 bytes (espeak-ng's path buffer); the server refuses longer ones with a
  FATAL. The page reader's web view keeps no website data (a
  non-persistent data store).
- User pronunciation overrides: `~/Library/Application Support/ReadRead/lexicon_zh.json`, override
  `READREAD_USER_LEXICON`; same format as the built-in `readread_tts/lexicon_zh.json` —
  `{"version": 1, "entries": [{"text": "还回去", "pinyin": "huan2 hui2 qu4", "before": "<regex>", "after": "<regex>"}]}`
  (one tone-numbered syllable per character, `*` keeps misaki's reading; full rules in the `lexicon.py` docstring).
  User entries apply after the built-in ones; the file is re-read when it changes, and a missing file is fine.
  Settings › Advanced › Show in Finder creates it empty when there is none.
- Preferences: the app's UserDefaults (`com.readread.app`; keys under Important Conventions). Launch at login: the
  app itself as a login item (`SMAppService.mainApp`; System Settings › General › Login Items & Extensions).
- Dev environment: `$READREAD_HOME` (default `~/.readread`), Defuddle in `$READREAD_HOME/defuddle/`. ASR tool:
  `$READREAD_ASR_HOME` (default `~/Library/Caches/ReadRead/asr-eval`). The app bundle is never written at runtime.

### UI States

The panel has two distinct modes:

- **Input mode** — logo and hint, a field for a URL, a file path or text (with a read-the-clipboard button), Read
  (disabled while loading; a spinner and Cancel appear beside it), Open File… (every `ReadableFileType`), and below
  them the voice (▶ to preview) and speed of both languages (with Qwen: its one voice per language, ▶ still there)
- **Reading mode** — header (title, the source as a link or Show in Finder, close button), the blocks with the
  current sentence and word highlighted (tap a sentence to read from it; the view follows the reading, Back to
  Current after scrolling by hand), a progress bar, previous / play-pause (a spinner while buffering) / next, "x / N",
  text size A A, stop, then the voice picker (grouped, ▶ per voice; Qwen's voice as a label) for the document
  language, the language menu (Auto / 中文 / English) and the speed slider

Both accept drops and show an error banner with the full, selectable error text plus Show More (long ones), Copy,
Show Log and Retry (the setup hint only when Kokoro's files are missing, "Use System Voice" when the Kokoro server
cannot run, "Use Kokoro" when Qwen failed), and the bottom bar: "Starting voice engine…" or "Starting the
high-quality engine…", "High-quality mode" while Qwen is the engine (or the system-voice status with "Use Kokoro"),
the version, Settings and Quit. The Settings window has the tabs General, Voices, Reading and Advanced (the engine
and High-quality mode: not installed, running with its progress, installed, damaged, failed, cancelled); the status
item has the icon (a waveform while reading) and its right-click menu.

## Important Conventions

- **Two languages: `zh` and `en`.** UK vs US English is a property of the voice, not of the language. The voice id
  prefix decides the pipeline on both sides (`Voice.route(forID:)` mirrors the server's routing). Korean and
  Japanese legacy-encoded text files are refused; Japanese and other scripts inside a document are shown and skipped.
- **The voice list is hardcoded only in `Voice.swift`** (`Voice.all`, picker order; `VoiceGroup` groups it), and
  Qwen's two voices only in `HQEngine.swift` (`Voice.qwen`; `Voice.catalog(for:)` gives an engine's). The Kokoro
  server does not hardcode voices — `GET /voices` lists the ids in the model's voice files. `Voice.all` must be a
  subset of `/voices` for each language: `--self-test` (and with it the build's smoke test) fails when an app voice
  is missing; `--self-test --engine qwen` checks `Voice.qwen` the same way.
- **One Qwen model** — the owner wants the best one only: `QwenModel` (1.7b), `RR_HQ_MODELS="1.7b"`, the server's
  `QWEN_MODELS`. There is no model picker and no smaller option; do not add one.
- **The file formats are listed only in `ReadableFileType`** — the file picker, drops, Open With and
  `DocumentReader` use it; `build-app.sh`'s `CFBundleDocumentTypes` must list the same identifiers in the same order
  (`InfoPlistTests` checks), always `LSHandlerRank` Alternate (ReadRead is never the default app).
- **Preferences** — `voice_zh`, `voice_en`, `speed_zh`, `speed_en` and `last_language` (the model to prewarm),
  `engine` (`kokoro` | `qwen`; absent = Kokoro, removed when a qwen choice falls back), `font_size`, `auto_follow`,
  `panel_width`, `panel_height` and `extraction_mode` (`local` | `remote`) in `UserDefaults`; a voice is saved under
  its own language (Kokoro's only: Qwen's come with the engine), the speed under the document's language (for both
  engines); the Auto / 中文 / English choice is not stored. v0.1.x keys are migrated once (`voice_en-us` →
  `voice_en`, dropped languages removed, unknown voice ids fall back to `Voice.defaultVoice(for:)`).
- **Web pages are read on this Mac first** — `LocalExtractor` with the pinned Defuddle; a page's address goes to
  defuddle.md only when that fails (or in the defuddle.md-only mode), never for a local-network address. Defuddle
  is bumped through `versions.sh` (version, URL, size, sha256, npm integrity, the files' sizes and sha256); after a
  bump run the WebKit tests (`READREAD_TEST_WEBKIT=1`) and `--self-test`, whose expected units come from it.
- **Language detection** is `LanguageDetector`'s script census per unit, on the text itself (not defuddle metadata,
  which can be wrong); units in other scripts are shown and skipped. Auto / 中文 / English overrides it per document.
- **One unit = one sentence** (a long one cut at about 120 zh / 220 en characters), one request, one buffer: the
  highlight, "x / N", next/previous and the positions file all count units. The server still splits a unit into its
  own sentences; its token timings give the word highlight.
- **Path resolution** checks the app bundle first, then `$READREAD_HOME`, then `<cwd>/tts_server` (Defuddle: the
  bundle, then `$READREAD_HOME/defuddle`; install-hq.sh: the bundle's `installer/`, the checkout behind
  `$READREAD_HOME/tts_server`, `<cwd>/scripts`); missing engine files give `TTSError.resourcesMissing`, the only
  error that shows the setup hint (Kokoro's; a missing or broken HQ install is `hqUnavailable`); a missing Defuddle
  sends pages to defuddle.md.
- **Localization** — English is the development language (no `en.lproj`); every UI literal has its line in
  `zh-Hans.lproj/Localizable.strings`, page, file and format messages (`table: "Content"`) in `Content.strings`, the
  high-quality engine's and installer's messages (`table: "Engine"`) in `Engine.strings`.
  `LocalizationCoverageTests`, `ContentStringsTests` and `HQInstallerTests` (Engine.strings) fail on a missing or
  unused line; interpolate strings only (the key is then `%@`), and use `Text(verbatim:)` for names, numbers and
  中文 / English. The owner's button text is exactly "安装高音质模式（约 3.5 GB）".
- **Keyboard** — `KeyRouter` is the panel's only keyboard map (the panel routes every key through it); keep
  `ShortcutHelp` (Settings › General) and the README's table in step with it.
- **No external Swift dependencies** — only Apple frameworks (SwiftUI, AppKit, AVFoundation, MediaPlayer, WebKit,
  PDFKit, ServiceManagement, CryptoKit, UniformTypeIdentifiers, Synchronization, Observation, CoreGraphics). Defuddle
  is a pinned JavaScript file, not a package.
- **No SwiftPM resources and no `Bundle.module`** — its accessor crashed the release app on other Macs. Icons and the
  `.lproj` strings are copied into `Contents/Resources` by `build-app.sh`, which refuses a binary that references
  `ReadRead_ReadRead.bundle`.
- **Swift 6 strict concurrency** — AppState, AppDelegate, PlaybackController, SynthesisCache, AudioQueuePlayer,
  ReadingPositionStore, NowPlayingController, AppleSpeechSynthesizer, TTSService, TTSServerProcess, LocalExtractor
  (WebKit), VoicePreviewer, StatusItemController, SettingsWindowController, ReadingPreferences, HQInstaller (and
  `HQInstalling`) are `@MainActor`;
  `DocumentLoader.load` is `@concurrent` (fetching, decoding and splitting a 1 MB file, reading a PDF or an EPUB
  stay off the main thread). Async suspension points (URLSession, Task.sleep, CheckedContinuation) keep the main
  thread unblocked.
- **Injection seams** — AppState takes a `SpeechSynthesizer` (Kokoro), the `QwenEngineFactory` (the app:
  `TTSService.qwen`; nil: no Qwen) and an `HQInstalling` (the app: `HQInstaller()`; nil: `NoHQInstaller`), an
  `AudioOutput`, a `PreferencesStore`, the
  `loadDocument` closure (default `DocumentLoader().load`), a `ReadingPositionStoring`, a `NowPlayingPublishing`, the
  system-voice factory, `fileExists`, `sleep`, a `PasteboardAccess`, a `WorkspaceOpening`, a `LoginItemControlling`,
  the preview's `AudioOutput`, `RuntimeDirectories` and `clearArticleCache`; `PlaybackController` the same
  synthesizer, output, positions, Now Playing, sleep and clock; `DocumentLoader` its `fetchPage` / `readFile`
  closures; `WebPageFetcher` its `mode`, `local`, `remote` and `ArticleCache`; `DocumentReader` the Defuddle source,
  the web view options, the EPUB directory and the limits; `LocalExtractor.Options` its limits and rules directory;
  `ArticleCache` its directory, clock and limits; the server lifecycle takes a `ServerEnvironment` (`ProcessLauncher`,
  `FileSystem`, clock, sleep, token), its `ServerFlavor` and a `ServerPolicy`; `HQInstaller` the script path, a
  `ServerEnvironment` and the shutdown grace period; `HQInstallation.read` a `FileSystem`; `TTSClient` takes an
  `HTTPTransport`; `WebExtractor.fetchWithRetry` takes
  `fetch`/`sleep` closures and `extractFromURL` a `fetch`; `AppleSpeechSynthesizer` takes the installed-voice list.
  Tests run without Python, network, WebKit or audio this way (`AudioQueuePlayer`'s offline mode renders real audio
  without a device).
- **The bundled interpreter is isolated** — the server runs with `-I -B` and a minimal environment; bytecode is
  precompiled as unchecked-hash `.pyc`, so nothing in the signed bundle changes at runtime.
- **Dependencies** — misaki is installed as `misaki[zh]` only; `misaki[en]` would pull phonemizer-fork, which clashes
  with phonemizer 3.4.0. Add or bump Python packages through `requirements.in` + `lock-deps.sh` (the ASR tool:
  `tools/asr_eval/requirements.in` + `tools/asr_eval/lock.sh`).
- `LSUIElement=true` in Info.plist hides the app from the Dock. Version: `CFBundleShortVersionString` from the latest
  `v*` tag, `CFBundleVersion` from `git rev-list --count HEAD`.
- **Tests** — Swift: `Tests/ReadReadTests/` (XCTest, `swift test`); `Fixtures/` (real pages, text files, encodings
  made by `make_encodings.py`, one file per document format made by `formats/make_formats.sh`, reviewed
  `snapshots/` of whole documents) is read by path (`Fixtures` in TestSupport), excluded from the target, never a
  SwiftPM resource. Opt-in tests: `READREAD_TEST_WEBKIT=1` (real web views; Defuddle from `READREAD_TEST_DEFUDDLE` or
  `$READREAD_HOME/defuddle`), `READREAD_TEST_LIVE=1` (a few live pages, both readers; `READREAD_TEST_LIVE_DUMP=<dir>`),
  `READREAD_RENDER_UI=1` + `READREAD_RENDER_DIR` (offscreen PNGs of the panel and Settings, never on screen; with
  `READREAD_RENDER_VERSION` also the README's screenshots, `readme-*.png` for `docs/screenshots/`),
  `READREAD_TEST_REALTIME_AUDIO=1`, `READREAD_TEST_APPLE_SPEECH=1`, `READREAD_TEST_SUMMARY=<file>` (what each format
  fixture and live page became), `READREAD_TEST_QWEN=1` and `READREAD_TEST_HQ_INSTALLER=1` with `READREAD_HQ_HOME` =
  an install (`QwenEngineTests`: the real Qwen server; the real install-hq.sh `--check`, and an install cancelled at
  its first download), `READREAD_TEST_HQ_FULL_INSTALL=1` with `READREAD_HQ_HOME` = an empty dir (+
  `READREAD_TEST_HQ_SCRIPT`; about 3.5 GB of downloads); WebKit, rendering, the audio device and the GPU need to run
  outside a sandbox. `UIRenderTests` renders English and, for the high-quality states and the panel with Qwen,
  Chinese: the test builds a bundle holding only `zh-Hans.lproj`, points `+[NSBundle mainBundle]` at it for the
  render (`method_setImplementation`, restored after; checked on a sample string first), never the app's lookups.
  `TextPipelinePropertyTests` checks seeded generated inputs against `PipelineInvariants`;
  `TextPipelineKnownIssueTests` keeps known text-pipeline gaps as `XCTExpectFailure` (a fix makes it fail: then
  drop the expectation). `InfoPlistTests` parses `build-app.sh`'s Info.plist heredoc. Python: `tts_server/tests/`
  (pytest; fake MLX packages in `tests/fakes/` for the Qwen engine without a GPU). For logic that touches the
  network, audio, WebKit or the Python subprocess, inject the side-effecting work so tests run without real I/O.
