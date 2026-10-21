# ReadRead TTS server (HTTP API v2)

A local HTTP server that the ReadRead app starts as a child process. It runs one of two engines: Kokoro (the default,
bundled with the app, described first) or Qwen3-TTS (`--engine qwen`, the optional high-quality engine; see
[Qwen3-TTS engine](#qwen3-tts-engine---engine-qwen)). Kokoro has two routes, chosen by voice id:

| voices | model | front end |
|---|---|---|
| `zf_*`, `zm_*` | Kokoro v1.1-zh fp16 | normalizer, then misaki `ZHG2P(version="1.1")` with misaki English for Latin words, then the override lexicon |
| `af_*`, `am_*` (US), `bf_*`, `bm_*` (UK) | Kokoro v1.0 fp16 (model-files-v1.1 re-export) | normalizer, then `misaki.en.G2P(british=…)` with the espeak-ng fallback |

Each sentence is one model call; a sentence over the model's 510 phonemes is cut at word boundaries into kokoro's
batches, one call each, with kokoro's pauses between them. A sentence's trailing pause is trimmed to 40 ms, and
sentences are joined with 250 ms of silence. A sentence the front end fails on is logged and skipped.
Code layout: `tts_server.py` (entry point) and `readread_tts/` (`server`, `engine` (the interface both engines
implement), `engine_kokoro`, `engine_qwen`, `frontend_zh`, `frontend_en`, `sentences`, `lexicon` + `lexicon_zh.json`,
`zhuyin`, `g2p`, `espeak`, `audio`).

## Running it

```sh
READREAD_TOKEN=$(openssl rand -hex 32) \
  ~/.readread/env/bin/python3 -I -B tts_server/tts_server.py --models-dir ~/.readread/models --preload zh,en
```

- `--models-dir` must hold the four files from kokoro-onnx release `model-files-v1.1`; their sizes are checked.
  `--preload` loads routes (session, G2P, one warm-up synthesis) before READY. Other routes load on first use.
- Environment: `READREAD_TOKEN` (required, 64 hex characters), `READREAD_CACHE_DIR` (default
  `~/Library/Caches/ReadRead`), `READREAD_USER_LEXICON` (default `~/Library/Application Support/ReadRead/lexicon_zh.json`).
- `--engine kokoro|qwen` picks the engine (default `kokoro`); `--model 1.7b` names the Qwen model, the only one and
  the default (qwen only; with kokoro it is a FATAL bad argument, and so is any other model).
- stdout carries exactly one line: `READY {"port":…,"pid":…,"api":2,"loaded":["zh","en"],"engine":"kokoro"}` (qwen
  adds `"model":"1.7b"`), or
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

- `GET /health` returns `{"status":"ok","api":2,"pid":…,"loaded":[…],"versions":{"kokoro_onnx":…,"misaki":…,"onnxruntime":…,"python":…},"engine":"kokoro"}`;
  for qwen, `versions` names `mlx`, `mlx_audio`, `transformers`, `misaki` and `python`, and `"model"` follows `"engine"`.
- `GET /voices` returns `{"zh":[all zf_/zm_ ids],"en":[all af_/am_/bf_/bm_ ids]}`, sorted, without loading a model
  (qwen: `{"zh":["serena"],"en":["aiden"]}`).
- `POST /synthesize` needs `Content-Type: application/json` (415) and a body of at most 1 MiB (413):
  - `text`: required, at most 4000 characters (413).
  - `voice`: required.
  - `lang`: optional. `zh`, `en`, `en-us` or `en-gb`; it must match the voice family.
  - `speed`: 0.5 to 2.0. Default 1.0.
  - `request_id`: optional, at most 128 characters. It is echoed back.
  - `format`: `json` (default) or `wav`.

  - `json` returns `{"request_id","sample_rate":24000,"duration","audio":<base64 PCM16 mono WAV>,"silent","voice","lang","speed","synth_speed","sentences":[{"text","start","end"}],"tokens":[{"text","start","end"}],"timing_ms":{"frontend","synth"}}`.
    Sentence `text` is the normalized sentence. Tokens are the G2P words with their spoken time span (qwen: always
    `[]`). All times are in seconds within the returned audio.
  - `synth_speed` is the speed the audio was synthesized at: the requested `speed` for kokoro, always 1.0 for qwen,
    whose model has no speed control. The client plays the audio at `speed / synth_speed`.
  - `wav` returns the WAV itself, with `X-ReadRead-Duration` and `X-ReadRead-Synth-Speed`.
  - Text with nothing to say (empty, `---`, `• • •`, emoji only) returns 150 ms of silence, `"silent": true`.

One synthesis runs at a time. A request whose client disconnects, either while waiting for its turn or between
sentences, is dropped without a response and logged with `status=cancelled`.

Sentences split at `。！？!?；;` and line breaks. In Chinese text, a half-width `, ; : ! ?` next to a Han character is
read as its full-width form and a sentence-final `.` as `。` (not inside numbers, versions, domains, abbreviations or
list numbers like `1.`); a line without Han characters is split the English way. For English they also split at
`. ! ?`, except after decimals, versions, domains, abbreviations (`Dr.`, `U.S.`, `e.g.`), initials and ellipses
(`St.` ends a sentence only before a word that starts one: "Main St. Then"). Footnote markers, table rules, bullets,
emoji and arrows are dropped before splitting.

## Qwen3-TTS engine (`--engine qwen`)

Qwen3-TTS-12Hz-1.7B-CustomVoice, 8-bit, on the GPU through MLX (mlx 0.32.4, mlx-audio 0.6.0). It is optional and not
in the app bundle: `scripts/install-hq.sh` puts a CPython, a venv and the model files into `$READREAD_HQ_HOME`
(default `~/Library/Application Support/ReadRead/hq`), and the server runs from that venv:

```sh
HQ=~/Library/Application\ Support/ReadRead/hq
READREAD_TOKEN=$(openssl rand -hex 32) "$HQ/venv/bin/python3" -I -B tts_server/tts_server.py \
  --engine qwen --model 1.7b --models-dir "$HQ/models" --preload zh,en
```

- The app runs it exactly so, as a child process with a lifecycle of its own (never shared with Kokoro's server):
  the HQ venv's python with the app's own server code (`Contents/Resources/tts_server`, or the dev environment's),
  the same clean environment and stdin pipe as Kokoro, `--preload` for the language about to be read. It reads
  install.json first (never running anything) to know whether the install is usable (install.json.prev without
  install.json, or python/ or venv/ without the stamp written once it is complete, counts as damaged), and requires
  READY to say `"engine":"qwen","model":"1.7b"`; a FATAL before READY is shown with the server's message and where to
  repair the install (Settings › Advanced › High-quality mode). The lifecycle differs from Kokoro's in three ways:
  a 180 s start timeout (a first read of 3 GB from a cold disk plus Metal shader compiles), an idle exit 5 minutes
  after the last synthesis while nothing plays (checked every 30 s), and its own log, `tts-server-qwen.log`.
  Choosing Kokoro again stops it at once. Settings › Advanced › High-quality mode runs install-hq.sh (below).
- One model, `1.7b` (the best one: there is no model choice). `--models-dir` holds its folder,
  `Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit/`; the server checks the size of every file it reads, install-hq.sh also
  their sha256.
- Voices: `serena` reads Chinese (and the English words in it), `aiden` reads English. Any other id is `unknown_voice`;
  a `lang` that disagrees with the voice is `voice_language_mismatch`.
- Per sentence (split as for Kokoro): `frontend_zh.normalize` or `frontend_en.normalize`, a terminal stop for a line
  without one, then one generation. The seed is a hash of voice and text, so the same sentence comes back as the
  same audio. Generation always streams (non-streaming decoding lets MLX's buffer cache grow to 9-15 GB) and is
  capped at 12.5 x (0.5 x characters + 3) tokens; a generation longer than 2.5 x a rough expected length + 1 s (cut
  off as soon as it gets there), or shorter than 0.3 x that length, is retried with another seed, up to 3 attempts.
  Silence around each sentence is trimmed (30 ms kept before, 40 ms after); sentences are joined with 250 ms.
- One MLX thread does all model work (MLX keeps per-thread state). Cancellation is checked between streamed chunks
  (every 0.32 s of audio) and between sentences; SIGTERM, SIGINT and stdin EOF exit as for Kokoro, mid-synthesis too.
- `--preload` loads the model once and runs one warm-up sentence per route before READY.
- Offline: the engine sets `HF_HUB_OFFLINE=1`, `TRANSFORMERS_OFFLINE=1` and `HF_HUB_DISABLE_TELEMETRY=1` when it is
  imported, before any Hugging Face import, and points `HF_HOME` into the cache directory. Importing `engine_qwen`
  imports no MLX, so the Kokoro runtime (which has none) can import the package; a missing package is a FATAL that
  names `./scripts/install-hq.sh` (checked before the engine module is imported, which imports numpy). mlx-audio
  prints on stdout; that goes to stderr like every other stray print. transformers' warning about the model's type
  (`qwen3_tts` loaded as a config of no type, on every load, harmless) is filtered out of the log.
- Measured on an M4 Max (load average 4-5, page cache warm): start -> READY with `--preload zh,en` 1.7 s; RTF 0.22
  for both languages; a typical sentence in 0.6-0.8 s; after 20 sentences RSS 3.1 GB, physical footprint 3.3 GB,
  peak footprint 4.2 GB.

### install-hq.sh

```sh
./scripts/install-hq.sh [--json-progress]               # install, update or repair
./scripts/install-hq.sh --check [--json-progress]       # verify; exit status 0 or 1
./scripts/install-hq.sh --uninstall [--json-progress]   # remove $READREAD_HQ_HOME
```

- Layout: `python/` (the standalone CPython pinned in `scripts/lib/versions.sh`), `venv/` (`requirements-hq.lock`,
  `pip --require-hashes`), `models/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit/` (every file at the Hugging Face revision
  pinned in versions.sh, size and sha256 checked), `install.json` (`{"version":1,"python","lock_sha256","models":
  {"1.7b":{"repo","revision","dir","files","bytes"}},"installed_at"}`, written last). Before its first change to
  python/, venv/ or a model file, an install or repair moves an existing install.json to `install.json.prev`, and
  removes that once it wrote install.json again: a run that stops after a change (cancelled, a download or pip
  failing) leaves an install that reads as unfinished, never the record of a finished one whose venv or model files
  it was replacing (`--check` then says so); one that stops before it changed anything leaves install.json as it was.
- There is one model, so there is nothing to choose: `--model 1.7b` is still accepted (older command lines), any other
  `--model` is a usage error (exit status 2).
- Idempotent: python/ and venv/ are rebuilt only when their inputs change or one of their files no longer matches
  its sha256 (python/ against the manifest `.readread-manifest` written when it was extracted, venv/ against the
  RECORD pip wrote for each distribution), every model file is verified on every run, a corrupt one is downloaded
  again, and an interrupted download resumes from its `.part`. A run ends with an import check and one Chinese
  sentence through the real server (READY, `/synthesize`, stdin EOF); install.json lists the model only after that
  passed.
- `--check` makes the same checks without changing anything (python/, venv/ with `pip check` and the lock's
  distribution set, every model file's size and sha256, the imports) and exits 0 or 1. install.json must list
  `1.7b`; an entry or a `models/` folder of another model (older versions of this script could add a smaller one) is
  ignored. An install and `--uninstall` count such a folder as something the script did not create and refuse, with
  a message that says to delete it first.
- One run at a time per `$READREAD_HQ_HOME`: the lock is `.lock`, a symlink to the run's pid (a lock whose process
  is gone is taken over with a warning); `--uninstall` takes it too, `--check` refuses while an install holds it.
  SIGINT, SIGTERM and SIGHUP stop a run at once, pip and downloads included, with an error event; run it again to
  resume. A command the script runs in the foreground (the venv check, the import check, an extraction) holds that
  off until it ends, so the app signals the script's whole process group. Once `--uninstall` has begun removing the
  folder it ignores these signals and finishes, with its done event (a removal stopped half way could not be
  resumed).
- `--json-progress`: one JSON object per line on stdout (`{"event":"step","name","index","count"}`,
  `{"event":"download","file","done","total"}`, then `{"event":"done",…}` or `{"event":"error","message"}`); the
  human-readable text goes to stderr.
- `--uninstall` removes `$READREAD_HQ_HOME` only if it holds nothing but what the script creates (inside python/,
  venv/ and python.partial/ too, by the names it creates there: a file of yours among them is named in the refusal),
  and never a path that is relative, shallower than two levels, a symlink, or the home directory or one of its
  parents (compared by identity, so another spelling of the same folder on a case-insensitive volume counts). An
  install, too, refuses a folder that holds anything else, before it writes there: it only ever replaces its own
  python/, venv/ and `.tmp`.
- Environment: `READREAD_HQ_HOME`, `READREAD_BUILD_CACHE` (the Python tarball and pip cache, default `build/cache`),
  `READREAD_TTS_SERVER_DIR` (the server the smoke run starts, default `tts_server/`). The model is about 3.1 GB,
  python/ and venv/ about 0.7 GB.
- In the app: build-app.sh copies the script with what it reads (`scripts/lib/common.sh`, `scripts/lib/versions.sh`,
  `tts_server/requirements-hq.in` and `.lock`) into `Contents/Resources/installer/`, in the repository's layout. The
  app (`HQInstaller`) runs it as `/bin/bash <installer>/scripts/install-hq.sh [--check|--uninstall] --json-progress` in
  a clean environment (`HOME`, `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `LANG`,
  `TMPDIR=~/Library/Caches/ReadRead/installer-tmp`, `READREAD_HQ_HOME`,
  `READREAD_BUILD_CACHE=~/Library/Caches/ReadRead/hq-build`, `READREAD_TTS_SERVER_DIR` = the app's server code),
  turns the JSON events into Settings' progress, appends stderr to `~/Library/Logs/ReadRead/hq-install.log`, and
  cancels with SIGTERM to the script's process group (on quit, SIGKILL to it after 2 s); `installer-tmp` is emptied
  before a run and removed after it. Run from inside an app bundle without `READREAD_BUILD_CACHE` (the bundle's path
  as given or with its symlinks resolved, in any letter case), common.sh refuses (exit 1): the default build cache
  would be inside the signed bundle.

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
READREAD_HQ_HOME=~/Library/Application\ Support/ReadRead/hq ~/.readread/env/bin/python3 -B -m pytest -q \
  -p no:cacheprovider tts_server/tests/test_qwen_models.py                                  # Qwen, the real model
```

The HTTP tests start real server processes on 127.0.0.1. The tests that need the model files are skipped unless
`READREAD_MODELS_DIR` is set. `tests/fixtures/frontend_probes.json` holds the 59 front-end probes from the engine
selection lab, and the run ends with their tally per kind.

The Qwen engine's fast tests need no MLX: `test_engine_qwen.py` drives the engine with a fake model
(`tests/fakes/fake_qwen.py`), and `test_server_qwen.py` runs the real server with `tests/fakes` first on `sys.path`,
where stand-ins for MLX, mlx-audio and the Hugging Face packages live. `test_qwen_models.py` starts the server from
the HQ venv with the 1.7b model; it is skipped unless `READREAD_HQ_HOME` points at an install, and needs the GPU
(Metal is not available inside a sandbox). `test_install_hq_bundle.py` runs install-hq.sh laid out as in the app
bundle (under a temporary `X.app/Contents/Resources/installer`): the guard, a `--check` that writes nothing there,
the refusal of another model's folder, and the `--model` arguments.
