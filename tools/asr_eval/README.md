# ASR round-trip evaluation

`tools/asr_eval/asr_eval.sh` checks that the TTS voices still say what the text says. A fixed corpus of three Chinese
and two English passages goes through the real ReadRead TTS server one sentence at a time. Two speech recognizers
transcribe the audio, and the transcripts are scored against the text:

- CER for Chinese and WER for English.
- Word probes: numbers, dates, polyphones, English words inside Chinese text.
- Speaker drift across sentences.
- Silences, length, repetition and per-sentence anomalies.

`--check` compares a run with the committed `baseline.json`. The tool was ported from the October 2026 TTS lab
(`eval_asr.py`, scoring v2.1) and is unchanged except for the synthesis step, which now runs the real server.

It is a developer tool and is never bundled. It needs Apple Silicon and either the dev environment
(`./scripts/setup.sh`) or a built app.

## Setup

```bash
tools/asr_eval/asr_eval.sh --setup        # also runs automatically before every run; the network is only needed once
```

Setup installs into `$READREAD_ASR_HOME`, which defaults to `~/Library/Caches/ReadRead/asr-eval`. Measured sizes:

| Path | Size | What |
|---|---|---|
| `python/` | 71 MB | The standalone CPython pinned in `scripts/lib/versions.sh` (sha256-checked). It is cloned from `$READREAD_BUILD_CACHE/downloads` when the build cache already has it; the tarball is kept in `downloads/` (24 MB). |
| `env/` | 270 MB | A venv holding exactly `requirements.lock`: 33 packages, wheels only, hash-pinned (`pip --require-hashes --no-deps`, then `pip check`). `pip/` (73 MB) is pip's download cache and can be deleted. |
| `models/` | 1.8 GB | Three models from Hugging Face. Each is pinned to a commit in `pins.sh`, and every file's size and sha256 are checked on every run. Downloads are resumable. |
| `home/` | | The evaluator's `HOME`, `HF_HOME`, `XDG_CACHE_HOME` and `TMPDIR`, which are also the TTS server's `HOME` and `TMPDIR`. |
| `tts/` | 9 MB | The evaluation server's `READREAD_CACHE_DIR`: the espeak-ng-data link and `jieba.cache`. |
| `runs/` | 67 MB per run | One directory per run (see Run). |

The three models:

| Model | Hugging Face repo, commit | Files | Size |
|---|---|---|---|
| Whisper large-v3-turbo, CTranslate2 | `dropbox-dash/faster-whisper-large-v3-turbo` at `0a363e9` (where faster-whisper 1.2.1's `large-v3-turbo` resolves) | 5 | 1.5 GB |
| SenseVoice-Small int8, 2024-07-17 | `csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17` at `2365bae` | 2 | 228 MB |
| 3D-Speaker CAM++ zh+en | `csukuangfj/speaker-embedding-models` at `0743f30` | 1 | 27 MB |

These are the same files the lab measured with. Nothing goes to `~/.cache/huggingface`.

Network access is needed only for setup:

- `pypi.org` and `files.pythonhosted.org` for the venv.
- `github.com` and its release CDN for CPython.
- `huggingface.co` and its CDN for the models.

After setup, every run is offline:

- The evaluator runs as `env -i … python -I -B` with `HF_HUB_OFFLINE=1`.
- Its environment holds only the variables listed above.

## Run

```bash
tools/asr_eval/asr_eval.sh --check                       # dev environment ($READREAD_HOME); exit 1 outside the baseline
tools/asr_eval/asr_eval.sh --app build/ReadRead.app --check   # a built app's bundled python, server and models
tools/asr_eval/asr_eval.sh --voices "zf_001 af_heart"    # some voices; no --check: only the tables
tools/asr_eval/asr_eval.sh --selfcheck                   # the scoring's and the comparison's unit cases (seconds)
```

- **Voices.** The default voices are zf_001, zf_032, zm_009 and zm_055 (Chinese) and af_heart and bf_emma (English).
  Each voice reads every passage of its language: 16 samples and 12.3 minutes of audio.
- **Time.** A full run took about 6 minutes on an M-series Mac whose load average was around 10:
  - Synthesis: 1.5 minutes (Kokoro RTF about 0.12).
  - Whisper on the CPU (int8, `--threads 4`, RTF 0.25): about 3 minutes.
  - SenseVoice and CAM++: seconds.
  - The sha256 check of the models: a few seconds.
- **Sandbox.** The TTS server listens on 127.0.0.1, so a sandboxed shell must allow binding to a local port.
- **One run at a time.** Each `$READREAD_ASR_HOME` holds a lock (`.lock/`, with the owner's pid) while setup, a run
  or `--selfcheck` uses it. A second invocation stops with the owner's pid; a lock whose process is gone is removed.
- **Where the server code comes from.** `READREAD_HOME`'s `env/bin/python3`, `tts_server/` and `models/` synthesize.
  `READREAD_TTS_SERVER_DIR` names other server code.

A run directory, `runs/<time>-<source>/` or `--out <dir>`, holds these files:

| File | Contents |
|---|---|
| `manifest.jsonl` | One line per sample. |
| `samples/<text_id>__<voice>.wav` | The sentences joined: 0.25 s of silence between them, 0.5 s after a heading. |
| `sentences/<text_id>__<voice>/NN.wav` | The server's WAVs, unchanged. |
| `tts-server.log` | The server's stderr. |
| `synthesis.json` | What synthesized: a hash of the server code, `/health` with package versions, the model files and the voices. |
| `asr_cache.json` | The transcripts. |
| `results.json`, `results.csv` | Every number, flag, edit and transcript. |
| `comparison.json` | The `--check` result. |

The output is three tables:

- Per sample: Whisper and SenseVoice error rates, probes, drift and flags.
- Per voice: zh CER, PER, en WER, probes and drift.
- With `--check`, the comparison: each value is shown as now (baseline).

`--rescore <run dir>` scores a run again without synthesizing or transcribing, using the cached transcripts. Use it
after a scoring change.

### Synthesis protocol

The server is started the way the app starts it (`TTSServerProcess.launchConfiguration`):

- `python -I -B tts_server.py --models-dir …`
- A fresh 64-hex `READREAD_TOKEN`.
- A clean environment.
- The READY/FATAL handshake.
- Stdin held open until the end.

There are two differences from the app:

- The server gets the ASR home's `tts/` as its cache.
- `READREAD_USER_LEXICON` names a file that does not exist, so your own pronunciation overrides never change the
  numbers.

After one warm-up request per language, each passage sentence is one `POST /synthesize` with format `json`, speed
1.0 and the passage's language. A heading gets a terminal stop first, as the app's reader adds one
(`SpeechChunker.withTerminalStop`).

### Recognition and scoring

These are unchanged from the lab. `readread_asr/` holds the details: `recognizers.py`, `scoring.py`, and `corpus.py`,
whose `ZH_RULES` and `EN_RULES` are also copied into every `results.json`.

- **Whisper.** faster-whisper 1.2.1, run on the CPU with int8:
  - The language is forced to the passage's language.
  - Beam search 5, temperature fallback, no prompt, no VAD.
  - Hallucinated segments at the end of the audio are removed before scoring (rule H1).
- **SenseVoice.** sherpa-onnx 1.13.8, language `zh`, with punctuation and number normalization (ITN). It runs on the
  Chinese samples, cut at silences into chunks of at most 25 s.
- **Speaker drift.** The CAM++ embedding of every sentence. `drift_loo_min` is the lowest cosine similarity between a
  sentence and the mean of the other sentences.
- **Chinese CER.** Counted in Z11 units: every Han character, digit, `%` and `.` is one unit, and every Latin word is
  one unit. Both reference and transcript are normalized: Traditional is converted to Simplified, numbers to Arabic
  numerals, and dates and times to one form. The tool also reports a homophone-tolerant pinyin error rate.
- **English WER.** Counted over normalized words.
- **Probes.** A probe counts as heard when any of its spellings occurs in the normalized transcript. A Chinese probe
  also counts when its exact pinyin occurs.

## The baseline and `--check`

`baseline.json` keeps, per sample (`voice/text_id`):

- Each ASR's error count and reference size N.
- The probes each ASR heard.
- `drift_loo_min`.
- The audio duration.
- The sample's flags.

`--check` fails a sample when any of these rules breaks. The tolerances are stored in the file itself, so loosening
one is a reviewed change:

| Check | Tolerance |
|---|---|
| Errors (per ASR) | At most `max(1, floor(fraction × N))` more errors than the baseline: zh `fraction` 0.015 (1.5 % of the CER units), en 0.02 (2 % of the words). The minimum of one error covers zh_hant, which has 36 units. |
| Probes (per ASR) | At most 1 fewer hit. |
| Drift | `drift_loo_min` drops by at most 0.10 and stays ≥ 0.50, unless the baseline itself was below 0.50. |
| Duration | Within ±10 % of the baseline. |
| Flags | No new flag of a serious kind: `long_silence`, `len_ratio_low`/`high`, `repetition`, `sentence_count`, `concat_mismatch`, `sentence_rate`, `voice_drift`, `digital_silence`, `format`, `missing_file`, `decode_error` and the like. Informational flags such as `whisper_fallback` or `whisper_hallucination` never fail. |
| Reference | The same N and scoring version. Anything else means the corpus or scoring changed, and a new baseline is needed. |

These rules also apply:

- A transcription error fails the sample.
- So does a baseline sample that is missing from the run.
- Voices the run does not include are skipped and listed.
- Samples the baseline does not have are listed as new and not compared, with a warning that names the
  `--write-baseline` run that adds them.

The tolerances absorb small differences from several sources:

- Kokoro itself. Both ONNX graphs draw random numbers for the vocoder's noise source (`RandomNormalLike`,
  `RandomUniformLike`), so no two runs give the same samples. Measured over two runs of the same server: every
  sentence WAV differed, and 16 of 112 sentences changed length after trimming, by at most 35 ms.
- Threads and machines.
- Whisper's temperature fallback.

Three `--check` runs against the committed baseline stayed within these bounds. Two used the dev environment and one a
built app with the same server code; each had 16 samples.

- Errors: at most 2 more or 2 fewer per sample and ASR, against an allowed 3 more on zh_main and 5 more on zh_long.
- Probes: unchanged.
- Drift: at most 0.015 apart.
- Audio: at most 0.07 % apart.
- Flags: informational Whisper flags came and went, with different hallucinated phrases.

A regression larger than that noise fails: a dropped or repeated sentence, several misread numbers or dates, a new
long pause, or a voice changing mid-passage. A single misread word or polyphone can stay within the tolerances. The
per-sample table's missed probes show it, so read that table too.

### Updating the baseline

1. Write the new baseline from a fresh run. This replaces the samples of the run's voices and keeps the file's
   tolerances:

   ```bash
   tools/asr_eval/asr_eval.sh --write-baseline
   ```

   Write a new baseline when a change to the server, the models or the corpus is meant to change the numbers. With
   `--voices "<ids>"`, only those voices' samples are replaced: the other voices keep theirs, and `kept_voices` in
   the file names each kept voice with the date of its run. That needs the file's scoring version to be the run's;
   otherwise the write is refused and every voice has to run.
2. Read `git diff tools/asr_eval/baseline.json`. Every changed count should have a reason in the change you are
   making.
3. Commit the baseline together with that change.

After a scoring-only change, write the baseline from an existing run instead:

```bash
tools/asr_eval/asr_eval.sh --rescore <run dir> --write-baseline
```

To change a tolerance, edit `tolerances` in `baseline.json` by hand.

### The optional Qwen3-TTS engine

```bash
READREAD_HQ_HOME=… tools/asr_eval/asr_eval.sh --engine qwen      # voices serena (zh) and aiden (en)
```

This synthesizes with the install of `scripts/install-hq.sh`: its `venv/` and `models/`, run with the repo's
`tts_server/`. Qwen runs on the GPU through MLX, so it must run outside any sandbox. It has no baseline.

## Updating the pins

- **Python packages.** Edit `requirements.in`, then run `tools/asr_eval/lock.sh`. It writes the hashed
  `requirements.lock` for the pinned CPython on macOS arm64. `lock.sh --check` fails on a stale lock, and
  `scripts/check.sh` runs it. The next run rebuilds `env/`.
- **Models.** Each model in `pins.sh` lists its repo, its commit, and the path, bytes and sha256 of every file. Take
  the sha256 values from `https://huggingface.co/api/models/<repo>/revision/<commit>?blobs=true`. For files stored in
  LFS, that is `lfs.sha256`. Small files have no LFS entry: download them and hash them yourself. A mismatching file
  is replaced on the next run.
- **Recognizers.** A new model or a new recognizer version changes the numbers, so write a new baseline in the same
  change.

## Files

| File | Role |
|---|---|
| `asr_eval.sh` | Setup, the isolated environment, the run modes. |
| `pins.sh` | The model pins. |
| `requirements.in`, `requirements.lock` | The venv's packages. |
| `lock.sh` | Writes `requirements.lock`. |
| `asr_eval.py` | The entry point. |
| `readread_asr/cli.py` | The `run`, `evaluate` and `selfcheck` commands. |
| `readread_asr/synth.py` | The server and the per-sentence synthesis. |
| `readread_asr/corpus.py` | The passages, probes and normalization rules. |
| `readread_asr/scoring.py` | Normalization, alignment and probes. |
| `readread_asr/audio.py` | Decoding, silences, exact-zero runs. |
| `readread_asr/recognizers.py` | Whisper, SenseVoice, CAM++. |
| `readread_asr/evaluate.py` | One run: flags, drift, results.json, the tables. |
| `readread_asr/baseline.py` | `baseline.json`, `--check`. |
| `readread_asr/selfcheck.py` | Unit cases. |
| `baseline.json` | The committed baseline. |
