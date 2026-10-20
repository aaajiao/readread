# ReadRead TTS server (HTTP API v2)

A local HTTP server that the ReadRead app starts as a child process. Two Kokoro routes, chosen by voice id:

| voices | model | front end |
|---|---|---|
| `zf_*`, `zm_*` | Kokoro v1.1-zh fp16 | normalizer, then misaki `ZHG2P(version="1.1")` with misaki English for Latin words, then the override lexicon |
| `af_*`, `am_*` (US), `bf_*`, `bm_*` (UK) | Kokoro v1.0 fp16 (model-files-v1.1 re-export) | normalizer, then `misaki.en.G2P(british=…)` with the espeak-ng fallback |

Each sentence is one model call; a sentence over the model's 510 phonemes is cut at word boundaries into kokoro's
batches, one call each, with kokoro's pauses between them. A sentence's trailing pause is trimmed to 40 ms, and
sentences are joined with 250 ms of silence. A sentence the front end fails on is logged and skipped.
Code layout: `tts_server.py` (entry point) and `readread_tts/` (`server`, `engine`, `frontend_zh`, `frontend_en`,
`sentences`, `lexicon` + `lexicon_zh.json`, `zhuyin`, `g2p`, `espeak`, `audio`).

## Running it

```sh
READREAD_TOKEN=$(openssl rand -hex 32) \
  ~/.readread/env/bin/python3 -I -B tts_server/tts_server.py --models-dir ~/.readread/models --preload zh,en
```

- `--models-dir` must hold the four files from kokoro-onnx release `model-files-v1.1`; their sizes are checked.
  `--preload` loads routes (session, G2P, one warm-up synthesis) before READY. Other routes load on first use.
- Environment: `READREAD_TOKEN` (required, 64 hex characters), `READREAD_CACHE_DIR` (default
  `~/Library/Caches/ReadRead`), `READREAD_USER_LEXICON` (default `~/Library/Application Support/ReadRead/lexicon_zh.json`).
- stdout carries exactly one line: `READY {"port":…,"pid":…,"api":2,"loaded":["zh","en"]}`, or
  `FATAL {"message":"…"}` followed by exit status 3 (bad arguments, no token, missing or wrong model files, missing
  packages, unusable cache directory). Everything else goes to stderr as timestamped log lines, with one line per
  synthesis request (`request_id voice chars sentences frontend_ms synth_ms audio_s status`).
- The server exits when stdin reaches EOF, which means the app is gone. It also exits within a second of SIGTERM or
  SIGINT, even in the middle of a synthesis.
- It writes only into the cache directory: the `espeak-ng-data` symlink, `jieba.cache`, and `tmp/<pid>/` (removed at exit).

espeak-ng keeps its data path in a 160-byte buffer. It reaches its data through the short symlink
`$READREAD_CACHE_DIR/espeak-ng-data`, passed in `ESPEAK_DATA_PATH`. phonemizer 3.4 resolves symlinks in its own data
path setting and would bring the long path back.

## HTTP API

Every request needs `Authorization: Bearer <READREAD_TOKEN>` (401) and `Host: 127.0.0.1:<port>` or
`localhost:<port>` (403). Every error is JSON, `{"error":{"code":…,"message":…}}`:

| code | status |
|---|---|
| `bad_request` | 400 |
| `unknown_voice` | 400 |
| `voice_language_mismatch` | 400 |
| `unauthorized` | 401 |
| `forbidden` | 403 |
| `not_found` | 404 |
| `too_large` | 413 |
| `unsupported_media_type` | 415 |
| `internal` | 500 |

- `GET /health` returns `{"status":"ok","api":2,"pid":…,"loaded":[…],"versions":{"kokoro_onnx":…,"misaki":…,"onnxruntime":…,"python":…}}`.
- `GET /voices` returns `{"zh":[all zf_/zm_ ids],"en":[all af_/am_/bf_/bm_ ids]}`, sorted, without loading a model.
- `POST /synthesize` needs `Content-Type: application/json` (415) and a body of at most 1 MiB (413):
  - `text`: required, at most 4000 characters (413).
  - `voice`: required.
  - `lang`: optional. `zh`, `en`, `en-us` or `en-gb`; it must match the voice family.
  - `speed`: 0.5 to 2.0. Default 1.0.
  - `request_id`: optional, at most 128 characters. It is echoed back.
  - `format`: `json` (default) or `wav`.

  - `json` returns `{"request_id","sample_rate":24000,"duration","audio":<base64 PCM16 mono WAV>,"silent","voice","lang","speed","sentences":[{"text","start","end"}],"tokens":[{"text","start","end"}],"timing_ms":{"frontend","synth"}}`.
    Sentence `text` is the normalized sentence. Tokens are the G2P words with their spoken time span. All times are in seconds within the returned audio.
  - `wav` returns the WAV itself, with `X-ReadRead-Duration`.
  - Text with nothing to say (empty, `---`, `• • •`, emoji only) returns 150 ms of silence, `"silent": true`.

One synthesis runs at a time. A request whose client disconnects, either while waiting for its turn or between
sentences, is dropped without a response and logged with `status=cancelled`.

Sentences split at `。！？!?；;` and line breaks. In Chinese text, a half-width `, ; : ! ?` next to a Han character is
read as its full-width form and a sentence-final `.` as `。` (not inside numbers, versions, domains, abbreviations or
list numbers like `1.`); a line without Han characters is split the English way. For English they also split at
`. ! ?`, except after decimals, versions, domains, abbreviations (`Dr.`, `U.S.`, `e.g.`), initials and ellipses
(`St.` ends a sentence only before a word that starts one: "Main St. Then"). Footnote markers, table rules, bullets,
emoji and arrows are dropped before splitting.

## Override lexicon (Chinese readings)

`readread_tts/lexicon_zh.json` (built in) and the user file at `$READREAD_USER_LEXICON` use one format. Edits to the
user file apply to the next request, and entries in it apply after the built-in ones. The authoritative description
is the docstring of `readread_tts/lexicon.py`.

```json
{"version": 1, "entries": [
  {"text": "还回去", "pinyin": "huan2 hui2 qu4", "before": "(按时|要|把.{1,12})", "note": "give back"},
  {"text": "得", "pinyin": "dei3", "before": "你", "after": "(?!到|了)[一-鿿]"}
]}
```

- `pinyin` takes one tone-numbered syllable per character, with 5 for the neutral tone; `*` keeps misaki's reading.
  Third-tone sandhi against neighbouring characters is redone automatically.
- `before` is a Python regex that must match right before the text; `after` must match right after it.
- Matching sees the normalized sentence, so numbers are already Chinese numerals and Traditional text is already
  Simplified.
- An invalid entry is skipped with a warning. A user file that does not parse is ignored, and an error is logged.

## Tests

```sh
~/.readread/env/bin/python3 -B -m pytest -q -p no:cacheprovider tts_server/tests            # fast tests only
READREAD_MODELS_DIR=~/.readread/models ~/.readread/env/bin/python3 -B -m pytest -q -p no:cacheprovider tts_server/tests
```

The HTTP tests start real server processes on 127.0.0.1. The tests that need the model files are skipped unless
`READREAD_MODELS_DIR` is set. `tests/fixtures/frontend_probes.json` holds the 59 front-end probes from the engine
selection lab, and the run ends with their tally per kind.
