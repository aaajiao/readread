# ReadRead

<!-- Screenshot_readread00.png shows v0.1.0 (its voice picker is on 小晓, a voice that no longer exists);
     put it back here once it has been retaken from the current build. -->

A macOS menu bar app that reads web pages, local files and pasted text aloud in Mandarin Chinese or English, using
offline text-to-speech.

Paste a URL, a file path or some text (or open a file), click Read, and listen. The app extracts the article text,
drops what is not meant to be read aloud (footnote and citation markers, reference lists, code blocks, tables, link
targets, emoji), tells Chinese from English sentence by sentence and reads each with your voice for its language,
highlighting the sentence being read.

## Features

- **Web pages** — paste a URL (or share text with a link in it); the article is extracted by
  [Defuddle](https://defuddle.md). The URL is sent to defuddle.md; speech is synthesized on your Mac. Addresses on
  your local network are not sent there (paste the page's text instead).
- **Local files and text** — `.txt` and `.md` files in UTF-8, UTF-16, GB18030/GBK, Big5 or Windows-1252 (hard-wrapped
  text and one-paragraph-per-line novels both read as paragraphs), a file path pasted into the field, or any text
  pasted to be read as it is
- **Sentence by sentence** — previous and next sentence, click a paragraph to read from it, a progress bar, and
  Now Playing with its play/pause and next/previous commands. A speed change is heard at once.
- **Picks up where you left off** — each document reopens at the sentence you stopped at (as long as its text has not
  changed); the positions of the last 200 documents are kept in `~/Library/Application Support/ReadRead/positions.json`
- **Chinese, English or both** — every sentence is read in its own language, or a menu reads the whole document as
  Chinese or as English
- **Offline TTS** — Kokoro (82M) through [kokoro-onnx](https://github.com/thewh1teagle/kokoro-onnx): the v1.1-zh
  model for Chinese (English words inside Chinese text included), the v1.0 model for English
- **31 voices** — 4 Chinese, 19 American English, 8 British English (British voices get British pronunciation)
- **Chinese pronunciation** — numbers, dates, ranges and Traditional characters are normalized first, and an
  override lexicon fixes polyphones the G2P gets wrong. Add your own readings in
  `~/Library/Application Support/ReadRead/lexicon_zh.json` ([format](tts_server/README.md#override-lexicon-chinese-readings)).
- **System voice fallback** — when the voice engine cannot run, **Use System Voice** reads on with a macOS voice
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
swift run ReadRead --self-test      # headless check: starts the TTS server, reads zh, en-US and en-GB, plays a
                                    # short document through the audio pipeline (offline), prints JSON

swift test
~/.readread/env/bin/python3 -B -m pytest -q -p no:cacheprovider tts_server/tests
```

Prefix the pytest command with `READREAD_MODELS_DIR=~/.readread/models` to include the tests that load the models.
`Tests/ReadReadTests/Fixtures/` holds real pages and text files with reviewed snapshots of what the text pipeline makes
of them; after a deliberate change to it, `READREAD_UPDATE_SNAPSHOTS=1 swift test --filter GoldenDocumentTests`
rewrites the snapshots for review in `git diff`.

## How it works

Two processes: the Swift menu bar app (SwiftUI + AppKit) and a local Python TTS server (`tts_server/`, HTTP on
127.0.0.1 with a per-launch token). The app starts the server when you first read something (warming it up while the
page downloads), restarts it after a crash, and stops it after 15 idle minutes or when you quit; while it runs it
uses about 2 GB of memory.

The text is cleaned of markup and split into sentences (a long one is cut at a comma or a space, at about 120 Chinese
or 220 English characters); each sentence is one request to the server and one audio buffer. The sentence being read
is synthesized first and the next three while it plays; the audio stays cached, so going back is instant. Playback
runs through AVAudioEngine with a time-pitch unit, so a new speed is heard at once while the sentences ahead are
synthesized again at that speed.

The server log is `~/Library/Logs/ReadRead/tts-server.log`; error messages have a **Show Log** button.

## High-quality engine (in progress)

`./scripts/install-hq.sh` installs an optional second engine, Qwen3-TTS (1.7B or 0.6B, 8-bit) on the GPU through
[MLX](https://github.com/ml-explore/mlx), outside the app: a standalone Python, a hash-locked venv and the model files,
all verified, in `~/Library/Application Support/ReadRead/hq` (about 3.8 GB with the 1.7B model). The TTS server can
already run it ([`--engine qwen`](tts_server/README.md#qwen3-tts-engine---engine-qwen)); the app does not use it yet
(planned for v0.5.0).

## Tech stack

- Swift 6 / SwiftUI / AppKit / AVFoundation, no external Swift dependencies
- Python 3.12 (bundled standalone build), kokoro-onnx 0.6.1 with onnxruntime, [misaki](https://github.com/hexgrad/misaki)
  G2P for Chinese and English, espeak-ng for English words misaki does not know
- Kokoro v1.1-zh and v1.0 fp16 ONNX models
- Optional: Qwen3-TTS 12Hz CustomVoice 8-bit through [mlx-audio](https://github.com/Blaizzy/mlx-audio), installed
  separately

## License

MIT
