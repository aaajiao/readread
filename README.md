# ReadRead

<!-- Screenshot_readread00.png shows v0.1.0 (its voice picker is on 小晓, a voice that no longer exists);
     put it back here once it has been retaken from the current build. -->

A macOS menu bar app that reads web pages and local files aloud in Mandarin Chinese or English, using offline
text-to-speech.

Paste a URL (or open a file), click Read, and listen. The app extracts the article text, detects whether it is Chinese
or English, picks your voice for that language and starts reading, highlighting the passage being read.

## Features

- **Web pages** — paste a URL; the article is extracted by [Defuddle](https://defuddle.md). The URL is sent to
  defuddle.md; speech is synthesized on your Mac.
- **Local files** — UTF-8 `.txt` and `.md` files
- **Offline TTS** — Kokoro (82M) through [kokoro-onnx](https://github.com/thewh1teagle/kokoro-onnx): the v1.1-zh
  model for Chinese (English words inside Chinese text included), the v1.0 model for English
- **31 voices** — 4 Chinese, 19 American English, 8 British English (British voices get British pronunciation)
- **Chinese pronunciation** — numbers, dates, ranges and Traditional characters are normalized first, and an
  override lexicon fixes polyphones the G2P gets wrong. Add your own readings in
  `~/Library/Application Support/ReadRead/lexicon_zh.json` ([format](tts_server/README.md#override-lexicon-chinese-readings)).
- **Self-contained** — the `.app` bundles Python, both models and every dependency

## Requirements

- Apple Silicon Mac
- macOS 26 or later

## Build

```bash
./scripts/build-app.sh      # → build/ReadRead.app (about 0.8 GB), then smoke-tests it
open build/ReadRead.app
```

The first build downloads a standalone Python, the Python packages pinned in `tts_server/requirements.lock` and the
four model files, all sha256-verified, and caches them in `build/cache/`. To install, move `build/ReadRead.app` to
`/Applications`. The app is signed ad hoc for the Mac that built it; it is not notarized.

The build assembles and smoke-tests the app in `build/.staging/` and replaces `build/ReadRead.app` only when every
check has passed; a failed build leaves the previous `build/ReadRead.app` alone and keeps what it made as
`build/ReadRead.app.failed`. ReadRead is a personal-use app, so this build and its smoke test are the whole release
process: there is no release script, zip packaging or CI.

## Development

```bash
./scripts/setup.sh                  # Python, packages and models in ~/.readread (or $READREAD_HOME)
swift run ReadRead                  # the app from source
swift run ReadRead --self-test      # headless check: starts the TTS server, reads zh, en-US and en-GB, prints JSON

swift test
~/.readread/env/bin/python3 -B -m pytest -q -p no:cacheprovider tts_server/tests
```

Prefix the pytest command with `READREAD_MODELS_DIR=~/.readread/models` to include the tests that load the models.

## How it works

Two processes: the Swift menu bar app (SwiftUI + AppKit) and a local Python TTS server (`tts_server/`, HTTP on
127.0.0.1 with a per-launch token). The app starts the server when you first read something (warming it up while the
page downloads), restarts it after a crash, and stops it after 15 idle minutes or when you quit; while it runs it
uses about 2 GB of memory. Text goes to the server paragraph by paragraph (short ones grouped to about 200
characters); the server splits each passage into sentences and synthesizes them one by one, and the next passage is
synthesized while the current one plays.

The server log is `~/Library/Logs/ReadRead/tts-server.log`; error messages have a **Show Log** button.

## Tech stack

- Swift 6 / SwiftUI / AppKit, no external Swift dependencies
- Python 3.12 (bundled standalone build), kokoro-onnx 0.6.1 with onnxruntime, [misaki](https://github.com/hexgrad/misaki)
  G2P for Chinese and English, espeak-ng for English words misaki does not know
- Kokoro v1.1-zh and v1.0 fp16 ONNX models

## License

MIT
