# ReadRead

<!-- Screenshot_readread00.png shows v0.1.0 (its voice picker is on 小晓, a voice that no longer exists);
     put it back here once it has been retaken from the current build. -->

A macOS menu bar app that reads web pages, documents and pasted text aloud in Mandarin Chinese or English, using
offline text-to-speech.

Paste a URL, a file path or some text, open or drop a file, or send a selection from any app with Services, and
listen. The app extracts the article text, drops what is not meant to be read aloud (footnote and citation markers,
reference lists, code blocks, tables, link targets, emoji), tells Chinese from English sentence by sentence and reads
each with your voice for its language, highlighting the sentence and the word being read.

## Features

- **Web pages, read on your Mac** — the page loads in a hidden web view and the bundled
  [Defuddle](https://github.com/kepano/defuddle) extracts the article. When that fails, the page's address goes to
  [defuddle.md](https://defuddle.md) instead (see [Privacy](#privacy)). Pages on your local network work too. A page
  read once opens again at once for 30 days.
- **Documents** — plain text and Markdown, HTML, RTF and RTFD, Word (`.docx`, `.doc`), OpenDocument (`.odt`), PDF
  (with a text layer) and EPUB (without DRM); see [Formats](#formats). Text files can be UTF-8, UTF-16, GB18030/GBK,
  Big5 or Windows-1252 (hard-wrapped text and one-paragraph-per-line novels both read as paragraphs).
- **From anywhere** — the panel's field (a URL, a path, or text read as it is), Open File… (⌘O), drag and drop onto
  the panel or the menu bar icon, the clipboard (⌘V, or Read Clipboard in the menu bar icon's menu), **Services ›
  Read Aloud with ReadRead** (用 ReadRead 朗读) for selected text or a link in any app, and **Open With › ReadRead**
  in Finder (ReadRead is never made the default app for a file type).
- **Sentence by sentence** — the sentence being read is highlighted, and the word being spoken within it; click a
  sentence to read from there; previous and next sentence, a progress bar, and Now Playing with its play/pause and
  next/previous commands. A speed change is heard at once.
- **Follows the reading** — the text scrolls with the sentence being read; scroll by hand and it waits until you
  press **Back to Current** (回到当前), pick a sentence, or the next sentence starts while the current one is still in
  view. Text size A−/A+ (⌘− / ⌘+ / ⌘0), and the panel can be resized; both are remembered.
- **Picks up where you left off** — each document reopens at the sentence you stopped at (as long as its text has not
  changed); the positions of the last 200 documents are kept in `~/Library/Application Support/ReadRead/positions.json`
- **Chinese, English or both** — every sentence is read in its own language, or a menu reads the whole document as
  Chinese or as English
- **31 voices** — 4 Chinese, 19 American English, 8 British English (British voices get British pronunciation),
  grouped 中文 / English (US) / English (UK) in the picker, each with ▶ for a short sample. Each language has its own
  voice and speed, and both are shown before a text loads, so nothing changes unseen.
- **Offline TTS** — Kokoro (82M) through [kokoro-onnx](https://github.com/thewh1teagle/kokoro-onnx): the v1.1-zh
  model for Chinese (English words inside Chinese text included), the v1.0 model for English
- **Chinese pronunciation** — numbers, dates, ranges and Traditional characters are normalized first, and an
  override lexicon fixes polyphones the G2P gets wrong. Add your own readings in
  `~/Library/Application Support/ReadRead/lexicon_zh.json` ([format](tts_server/README.md#override-lexicon-chinese-readings));
  Settings › Advanced shows (and creates) the file.
- **A menu bar app** — the 🤓 icon shows a small waveform while reading, its tooltip names the document, and a
  right-click (or ⌃-click) opens Play/Pause, Previous, Next, Stop, Open File…, Read Clipboard, Settings… and Quit.
  The panel opens under it on every Space, also next to full-screen apps, without taking the focus from the app you
  are in. Launch at login is in Settings › General.
- **Settings window** (⌘,) — General (launch at login, shortcuts, Services), Voices (a voice with ▶ and a speed per
  language), Reading (text size, following, how web pages are read), Advanced (engine status and Restart Engine,
  the log, the pronunciation file, Clear Cached Articles)
- **English or Chinese interface** — the app follows the system language (Simplified Chinese translation included)
- **System voice fallback** — when the voice engine cannot run, **Use System Voice** reads on with a macOS voice
- **Self-contained** — the `.app` bundles Python, both models, Defuddle and every dependency

## Keyboard shortcuts

In the panel:

| Keys | Action |
|---|---|
| Space | Play or pause (reading, outside the text field) |
| ← → | Previous or next sentence (reading, outside the text field) |
| ⌘V | Read the clipboard (outside the text field; inside it, ⌘V pastes) |
| ⌘O | Open a file |
| ⌘+ ⌘− ⌘0 | Larger, smaller, default text size |
| ⌘, | Settings |
| Esc, ⌘W | Hide the panel |
| ⌘Q | Quit ReadRead |

A keyboard shortcut for **Read Aloud with ReadRead** can be set in System Settings › Keyboard › Keyboard Shortcuts ›
Services.

## Formats

| Format | Extensions | Read with | Limit |
|---|---|---|---|
| Plain text | `.txt`, `.text` (and other text types: `.log`, `.csv`, `.srt` …) | ReadRead's decoder | 32 MB |
| Markdown | `.md`, `.markdown`, `.mdown`, `.mkd` | ReadRead's decoder | 32 MB |
| HTML | `.html`, `.htm`, `.xhtml` | Defuddle in a web view that loads nothing from the network and runs none of the page's scripts; else the system's HTML reader | 32 MB |
| RTF, RTFD | `.rtf`, `.rtfd` | the system's document reader | 64 MB, 256 MB |
| Word | `.docx`, `.doc` | the system's document reader | 128 MB, 64 MB |
| OpenDocument | `.odt` | the system's document reader | 128 MB |
| PDF | `.pdf` | PDFKit: running headers, footers and page numbers dropped, lines joined into paragraphs, hyphenated words joined | 256 MB |
| EPUB | `.epub` | unpacked into a temporary folder (checked first: size, entry count, no paths outside it), read in spine order without navigation and footnotes, removed afterwards | 512 MB (1 GB unpacked) |

A PDF with a password, a scanned PDF without a text layer and an EPUB with DRM are refused with a message that says
so. Text files in Korean (EUC-KR) or Japanese (Shift_JIS) are refused too: ReadRead reads Chinese and English only.

## Privacy

- Speech is synthesized on your Mac; no text is sent anywhere to be read aloud.
- Files are read on your Mac. An HTML file is read without loading anything from the network.
- Web pages are read on your Mac first: a hidden web view loads the page (with no cookies or storage kept, and no
  images, media or fonts), and the bundled Defuddle extracts the article. The page's own site, and whatever its
  scripts load, see the visit as they would in a browser.
- If that fails (no article found, a timeout, an error) or reads very little (under 200 characters, or only the part
  of a page that arrived within 15 seconds), **the page's address is sent to defuddle.md**, which fetches and
  extracts the page on its servers; its free service reads 1,000 pages a month. Settings › Reading › "With
  defuddle.md only" sends every address there instead.
- Local addresses (`localhost`, `*.local`, `*.lan`, `*.home.arpa`, `*.test`, `fritz.box`, private, loopback and link-local
  IP addresses in any spelling, single-label hosts) are never sent to defuddle.md, in either setting. A public-looking
  name that only your own DNS resolves to a private address is not recognized as local.
- Pages that were read are kept for 30 days in `~/Library/Caches/ReadRead/articles/` (not a page read only in part,
  or one that short); Settings › Advanced › Clear Cached Articles removes them.

## Requirements

- Apple Silicon Mac
- macOS 26 or later

## Build

```bash
./scripts/build-app.sh      # → build/ReadRead.app (about 0.8 GB), then smoke-tests it
open build/ReadRead.app
```

The first build downloads a standalone Python, the Python packages pinned in `tts_server/requirements.lock`, the four
model files and the Defuddle npm package, all checksum-verified, and caches them in `build/cache/`. To install, move
`build/ReadRead.app` to `/Applications`. The app is signed ad hoc for the Mac that built it; it is not notarized.

The build assembles and smoke-tests the app in `build/.staging/` and replaces `build/ReadRead.app` only when every
check has passed; a failed build leaves the previous `build/ReadRead.app` alone and keeps what it made as
`build/ReadRead.app.failed`. ReadRead is a personal-use app, so this build and its smoke test are the whole release
process: there is no release script, zip packaging or CI.

## Development

```bash
./scripts/setup.sh                  # Python, packages, models and Defuddle in ~/.readread (or $READREAD_HOME)
swift run ReadRead                  # the app from source
swift run ReadRead --self-test      # headless check: reads a page with Defuddle in a hidden web view, starts the
                                    # TTS server, reads zh, en-US and en-GB, plays a short document through the
                                    # audio pipeline (offline), prints JSON

./scripts/check.sh                  # every check, with a summary table (below)
swift test
~/.readread/env/bin/python3 -B -m pytest -q -p no:cacheprovider tts_server/tests
```

Prefix the pytest command with `READREAD_MODELS_DIR=~/.readread/models` to include the tests that load the models.
`Tests/ReadReadTests/Fixtures/` holds real pages, text files and self-made documents in every format, with reviewed
snapshots of what the text pipeline makes of the pages and texts; after a deliberate change to it,
`READREAD_UPDATE_SNAPSHOTS=1 swift test --filter GoldenDocumentTests` rewrites the snapshots for review in `git diff`.

### Checks

`scripts/check.sh` runs shellcheck on `scripts/` and `tools/` (when it is installed), checks that the hashed locks
are current (`lock-deps.sh --check`, `tools/asr_eval/lock.sh --check`; these need `uv` and pypi.org), runs pytest
(with the model tests when the dev environment has the models), `swift build --build-tests -Xswiftc
-warnings-as-errors` (any warning fails it) and `swift test`, and prints a summary table; it exits 1 when a check
failed. `--fast` skips the model tests, `--smoke` adds `build-app.sh` and its smoke test. Logs go to `build/check/`.
Runtime locations that are not overridden point into a temporary directory for the run.

Some tests run only when asked, because they need the audio device, WebKit, a window server or the network
(WebKit, rendering and the audio device also need to run outside a sandbox):

| Variable | Tests |
|---|---|
| `READREAD_TEST_WEBKIT=1` | the page reader in a real web view (local pages and files); Defuddle from `READREAD_TEST_DEFUDDLE` (a file) or `$READREAD_HOME/defuddle` |
| `READREAD_TEST_LIVE=1` | with `READREAD_TEST_WEBKIT=1`: a few real web pages, on this Mac and through defuddle.md (`READREAD_TEST_LIVE_DUMP=<dir>` keeps their Markdown and units) |
| `READREAD_RENDER_UI=1` `READREAD_RENDER_DIR=<dir>` | renders the panel and the Settings tabs offscreen to PNGs |
| `READREAD_TEST_REALTIME_AUDIO=1` | plays silence on the audio device |
| `READREAD_TEST_APPLE_SPEECH=1` | synthesizes with the system voices |
| `READREAD_TEST_SUMMARY=<file>` | writes what every format fixture (and each live page) became |

### ASR round trip

`tools/asr_eval/asr_eval.sh` checks that the voices still say what the text says: a fixed Chinese and English corpus
goes through the real TTS server sentence by sentence, two speech recognizers (Whisper large-v3-turbo and
SenseVoice) transcribe it, and the transcripts are scored (CER, WER, word probes, speaker drift). `--check` compares
the run with the committed `tools/asr_eval/baseline.json`; `--app build/ReadRead.app` tests a built app's bundled
server. It has its own venv and about 1.8 GB of models in `~/Library/Caches/ReadRead/asr-eval`
(`READREAD_ASR_HOME`), downloaded once and checked on every run; a full run takes about 6 minutes. It is not part of
`check.sh`. See [tools/asr_eval/README.md](tools/asr_eval/README.md).

## How it works

Two processes: the Swift menu bar app (SwiftUI + AppKit) and a local Python TTS server (`tts_server/`, HTTP on
127.0.0.1 with a per-launch token). The app starts the server when you first read something (warming it up while the
page downloads), restarts it after a crash, and stops it after 15 idle minutes or when you quit; while it runs it
uses about 2 GB of memory.

A web page is loaded in a web view that is never shown, with a fresh, non-persistent data store; once the page has
settled (at most 15 seconds), Defuddle runs in a separate script world, which the page's own scripts cannot see, and
returns the article as Markdown. Documents become paragraphs and headings through the system's readers, PDFKit or
the EPUB reader. Either way the text is cleaned of markup and split into sentences (a long one is cut at a comma or a
space, at about 120 Chinese or 220 English characters); each sentence is one request to the server and one audio
buffer. The sentence being read is synthesized first and the next three while it plays; the audio stays cached, so
going back is instant. The server returns the time of every word, which drives the word highlight. Playback runs
through AVAudioEngine with a time-pitch unit, so a new speed is heard at once while the sentences ahead are
synthesized again at that speed.

The server log is `~/Library/Logs/ReadRead/tts-server.log`; error messages have a **Show Log** button and a **Copy**
button.

## High-quality engine (in progress)

`./scripts/install-hq.sh` installs an optional second engine, Qwen3-TTS (1.7B or 0.6B, 8-bit) on the GPU through
[MLX](https://github.com/ml-explore/mlx), outside the app: a standalone Python, a hash-locked venv and the model files,
all verified, in `~/Library/Application Support/ReadRead/hq` (about 3.8 GB with the 1.7B model). The TTS server can
already run it ([`--engine qwen`](tts_server/README.md#qwen3-tts-engine---engine-qwen)); the app does not use it yet
(planned for v0.5.0).

## Tech stack

- Swift 6 / SwiftUI / AppKit / AVFoundation / WebKit / PDFKit, no external Swift dependencies
- [Defuddle](https://github.com/kepano/defuddle) 0.19.5 (MIT; its browser build with Markdown conversion, from npm,
  pinned by checksum) for web pages and HTML files
- Python 3.12 (bundled standalone build), kokoro-onnx 0.6.1 with onnxruntime, [misaki](https://github.com/hexgrad/misaki)
  G2P for Chinese and English, espeak-ng for English words misaki does not know
- Kokoro v1.1-zh and v1.0 fp16 ONNX models
- Optional: Qwen3-TTS 12Hz CustomVoice 8-bit through [mlx-audio](https://github.com/Blaizzy/mlx-audio), installed
  separately

## License

MIT. The app bundle also carries Defuddle's MIT license (`Contents/Resources/defuddle/LICENSE`).
