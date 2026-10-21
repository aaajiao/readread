#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# ASR round-trip regression check of the TTS voices: a fixed Chinese and English corpus goes through the real ReadRead
# TTS server one sentence at a time, Whisper large-v3-turbo and SenseVoice-Small transcribe it, and the transcripts are
# scored (CER for Chinese, WER for English, word probes, speaker drift). See tools/asr_eval/README.md.
#
#   tools/asr_eval/asr_eval.sh [--app <ReadRead.app>] [--voices "<ids>"] [--check | --write-baseline] [--out <dir>]
#   tools/asr_eval/asr_eval.sh --engine qwen [--voices "serena aiden"] [--out <dir>]
#   tools/asr_eval/asr_eval.sh --rescore <run dir> [--check | --write-baseline]
#   tools/asr_eval/asr_eval.sh --setup | --selfcheck
#
#   (no mode)         set up if needed, synthesize, transcribe, score, print the tables
#   --check           the same, then compare with tools/asr_eval/baseline.json; exit 1 outside its tolerances
#   --write-baseline  the same, then write tools/asr_eval/baseline.json from this run (review the diff, commit it)
#   --setup           only build the venv and download or verify the models
#   --selfcheck       the scoring's and the comparison's unit cases (no models, no server)
#   --rescore <dir>   score an earlier run's audio again (after a scoring change; transcripts come from its cache)
#   --app <path>      synthesize with a built app's bundled python, server and models (default: the dev environment)
#   --engine qwen     the optional Qwen3-TTS engine of $READREAD_HQ_HOME (voices serena, aiden; Metal, so outside any
#                     sandbox); it has no baseline
#   --voices "<ids>"  default: zf_001 zf_032 zm_009 zm_055 af_heart bf_emma (qwen: serena aiden)
#   --threads <n>     CPU threads for Whisper and SenseVoice (default 4)
#   --out <dir>       the run directory (default $READREAD_ASR_HOME/runs/<time>-<source>)
#
# Environment: READREAD_ASR_HOME (default ~/Library/Caches/ReadRead/asr-eval) holds python/, env/, models/, home/ (the
# evaluator's and the server's HOME, HF_HOME, XDG_CACHE_HOME and TMPDIR), tts/ (the evaluation server's
# READREAD_CACHE_DIR; no user lexicon applies) and runs/. READREAD_HOME (default ~/.readread): the dev environment
# whose env/bin/python3, tts_server/ and models/ synthesize; READREAD_TTS_SERVER_DIR overrides its server code (and is
# the server for qwen, default <repo>/tts_server); READREAD_HQ_HOME (default ~/Library/Application Support/ReadRead/hq):
# the qwen install; READREAD_BUILD_CACHE: a build cache whose downloads/ may hold the CPython tarball already. Setup
# needs the network (pypi.org, files.pythonhosted.org, github.com and its release CDN, huggingface.co and its CDN); a
# run after it does not (HF_HUB_OFFLINE=1). Exit status: 0 ok, 1 failure or regression, 2 usage error.
set -euo pipefail

TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../scripts/lib/common.sh
. "$TOOL_DIR/../../scripts/lib/common.sh"
# shellcheck source=pins.sh
. "$TOOL_DIR/pins.sh"

LOCK_FILE="$TOOL_DIR/requirements.lock"
BASELINE="$TOOL_DIR/baseline.json"
DOWNLOAD_TRIES=5

usage() { sed -n '7,23s/^#   //p' "$0" >&2; }
usage_error() {
    printf 'asr_eval.sh: %s\n' "$1" >&2
    usage
    exit 2
}

# ── Arguments ────────────────────────────────────────────────────────
MODE=run
COMPARE=""
APP=""
ENGINE=kokoro
VOICES=""
THREADS=4
OUT=""
RESCORE=""
need_value() { [ "$2" -ge 2 ] || usage_error "$1 needs a value"; }
while [ $# -gt 0 ]; do
    case "$1" in
    --check | --write-baseline)
        [ -z "$COMPARE" ] || usage_error "--check and --write-baseline exclude each other"
        COMPARE=${1#--}
        shift
        ;;
    --setup | --selfcheck)
        MODE=${1#--}
        shift
        ;;
    --rescore)
        need_value "$1" $#
        MODE=rescore
        RESCORE=$2
        shift 2
        ;;
    --app)
        need_value "$1" $#
        APP=$2
        shift 2
        ;;
    --engine)
        need_value "$1" $#
        ENGINE=$2
        shift 2
        ;;
    --voices)
        need_value "$1" $#
        VOICES=$2
        shift 2
        ;;
    --threads)
        need_value "$1" $#
        THREADS=$2
        shift 2
        ;;
    --out)
        need_value "$1" $#
        OUT=$2
        shift 2
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *) usage_error "unknown argument: $1" ;;
    esac
done
case "$ENGINE" in kokoro | qwen) ;; *) usage_error "unknown engine '$ENGINE' (kokoro or qwen)" ;; esac
case "$THREADS" in "" | *[!0-9]*) usage_error "--threads takes a number" ;; esac
if [ "$ENGINE" = qwen ] && [ -n "$COMPARE" ]; then usage_error "the qwen engine has no baseline (--check/--write-baseline are for kokoro)"; fi
if [ "$ENGINE" = qwen ] && [ -n "$APP" ]; then usage_error "--app synthesizes with the bundled Kokoro; qwen runs from READREAD_HQ_HOME"; fi
if [ "$MODE" = rescore ] && { [ -n "$APP" ] || [ "$ENGINE" != kokoro ] || [ -n "$VOICES" ] || [ -n "$OUT" ]; }; then
    usage_error "--rescore scores the run directory as it is (no --app, --engine, --voices or --out)"
fi
if [ -z "$VOICES" ]; then
    if [ "$ENGINE" = qwen ]; then VOICES="serena aiden"; else VOICES="zf_001 zf_032 zm_009 zm_055 af_heart bf_emma"; fi
fi

# ── The ASR home ─────────────────────────────────────────────────────
if [ "${READREAD_ASR_HOME+set}" = set ] && [ -z "$READREAD_ASR_HOME" ]; then
    rr_die "READREAD_ASR_HOME is set but empty; unset it to use the default, or give it a path"
fi
ASR="${READREAD_ASR_HOME:-${HOME:?}/Library/Caches/ReadRead/asr-eval}"
while [ "${ASR%/}" != "$ASR" ]; do ASR=${ASR%/}; done
case "$ASR" in
/?*/?*) ;;
*) rr_die "READREAD_ASR_HOME must be an absolute path at least two levels deep (got '$ASR')" ;;
esac
case "$ASR/" in
*/./* | */../* | *//* | *$'\n'* | *' '*) rr_die "READREAD_ASR_HOME must be a plain absolute path without spaces, . or .. (got '$ASR')" ;;
esac
case "${HOME%/}/" in
"$ASR"/*) rr_die "READREAD_ASR_HOME ($ASR) is your home directory or contains it; refusing" ;;
esac
if [ -e "$ASR" ] && [ ! -d "$ASR" ]; then rr_die "READREAD_ASR_HOME ($ASR) exists and is not a directory"; fi
PY="$ASR/python/bin/python3"
ENV_PY="$ASR/env/bin/python3"
PY_STAMP="$RR_PY_VERSION+$RR_PY_RELEASE $RR_PY_SHA256"

# One run at a time per ASR home: a lock directory holding the owner's pid.
LOCKED=0
release_lock() {
    if [ "$LOCKED" = 1 ]; then rm -rf "$ASR/.lock"; fi
    LOCKED=0
}
trap release_lock EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# kill -0 also fails with EPERM, for a live process this shell may not signal (another user's, or one outside a
# sandbox this shell runs in): only "no such process" means the owner is gone.
pid_alive() {
    local err
    err=$(kill -0 "$1" 2>&1) && return 0
    case "$err" in *ermitted*) return 0 ;; esac
    return 1
}
take_lock() {
    local pid
    mkdir -p "$ASR" || rr_die "cannot create $ASR"
    if ! mkdir "$ASR/.lock" 2>/dev/null; then
        pid=$(cat "$ASR/.lock/pid" 2>/dev/null || true)
        if [ -n "$pid" ] && pid_alive "$pid"; then rr_die "another asr_eval.sh (pid $pid) is using $ASR"; fi
        rr_warn "removing the stale lock of a run that is gone (pid ${pid:-unknown})"
        rm -rf "$ASR/.lock"
        mkdir "$ASR/.lock" 2>/dev/null || rr_die "cannot lock $ASR (another run took it just now)"
    fi
    LOCKED=1
    printf '%s\n' "$$" >"$ASR/.lock/pid"
}

# ── Setup: CPython, the venv, the models ─────────────────────────────
python_ok() {
    [ -x "$PY" ] && [ "$(cat "$ASR/python/.readread-python" 2>/dev/null)" = "$PY_STAMP" ] && "$PY" -I -B -c 'import sys' 2>/dev/null
}
env_stamp() { rr_sha256_string "python=$PY_STAMP lock=$(rr_sha256 "$LOCK_FILE") recipe=$ASR_ENV_RECIPE"; }
# The venv holds exactly the locked distributions (plus pip) at their locked versions.
env_matches_lock() {
    "$ENV_PY" -I -B -c '
import re, sys
from importlib.metadata import distributions
def norm(name):
    return re.sub(r"[-_.]+", "-", name).lower()
want = {}
with open(sys.argv[1], encoding="utf-8") as lock:
    for line in lock:
        m = re.match(r"([A-Za-z0-9][A-Za-z0-9._-]*)(?:\[[^\]]*\])?\s*==\s*([^\s;\\]+)", line)
        if m:
            want[norm(m.group(1))] = m.group(2)
have = {norm(d.metadata["Name"]): d.version for d in distributions() if d.metadata["Name"]}
problems = [f"{n} is not installed" for n in sorted(set(want) - set(have))]
problems += [f"{n} is {have[n]}, the lock pins {v}" for n, v in sorted(want.items()) if n in have and have[n] != v]
problems += [f"{n} {have[n]} is not in the lock" for n in sorted(set(have) - set(want) - {"pip"})]
if problems:
    sys.exit("  env/ does not match requirements.lock: " + "; ".join(problems[:6]))
' "$LOCK_FILE"
}
env_ok() {
    [ -x "$ENV_PY" ] && [ "$(cat "$ASR/env/.readread-asr-env" 2>/dev/null)" = "$(env_stamp)" ] && env_matches_lock
}

# asr_download <url> <dest> <bytes> <sha256>: resumable (curl -C - into <dest>.part), verified, then moved into place.
asr_download() {
    local url=$1 dest=$2 size=$3 sha=$4 part="$2.part" have try=0 status
    mkdir -p "$(dirname "$dest")" || rr_die "cannot create $(dirname "$dest")"
    while :; do
        have=0
        if [ -f "$part" ]; then have=$(rr_size "$part"); fi
        if [ "$have" -gt "$size" ]; then
            rm -f "$part"
            have=0
        fi
        [ "$have" -lt "$size" ] || break
        try=$((try + 1))
        if [ "$have" -gt 0 ]; then
            rr_note "$(basename "$dest"): resuming at $(rr_mb "$have") of $(rr_mb "$size") MB"
        else
            rr_note "$(basename "$dest"): downloading $(rr_mb "$size") MB from $url"
        fi
        status=0
        curl -fL -C - --connect-timeout 30 --speed-limit 10000 --speed-time 60 -sS -o "$part" "$url" || status=$?
        if [ "$status" = 0 ]; then break; fi
        if [ "$status" = 33 ]; then rm -f "$part"; fi # the server cannot resume: start over
        [ "$try" -lt "$DOWNLOAD_TRIES" ] || rr_die "download failed (curl exit $status): $url; run again to resume"
        rr_warn "$(basename "$dest"): curl exit $status; retrying"
        sleep 2
    done
    if [ "$(rr_size "$part")" != "$size" ] || [ "$(rr_sha256 "$part")" != "$sha" ]; then
        rm -f "$part"
        rr_die "checksum mismatch for $url (expected $size bytes, sha256 $sha); the download was deleted"
    fi
    mv -f "$part" "$dest" || rr_die "cannot move $part into place"
}

model_var() { # <model> <field>: the pins.sh setting ASR_<MODEL>_<FIELD>
    local var
    var="ASR_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')_$2"
    printf '%s\n' "${!var}"
}

setup_models() {
    local m repo revision dir path size sha dest fetched verified pinned
    for m in $ASR_MODELS; do
        repo=$(model_var "$m" REPO)
        revision=$(model_var "$m" REVISION)
        dir="$ASR/models/$(model_var "$m" DIR)"
        fetched=0
        verified=0
        # Process substitution, not a here-string: bash 3.2 writes a here-string to a temp file, and when it
        # cannot, the loop is skipped without an error. The count below catches any other short read.
        while read -r -u 9 path size sha; do
            [ -n "$path" ] || continue
            dest="$dir/$path"
            if [ -e "$dest" ] && ! rr_file_ok "$dest" "$size" "$sha"; then
                rr_warn "$m/$path does not match its pinned size and sha256: replacing it"
                rm -f "$dest" || rr_die "cannot remove $dest"
            fi
            if [ ! -e "$dest" ]; then
                asr_download "https://huggingface.co/$repo/resolve/$revision/$path" "$dest" "$size" "$sha"
                fetched=$((fetched + 1))
            fi
            verified=$((verified + 1))
        done 9< <(model_var "$m" FILES)
        pinned=$(model_var "$m" FILES | awk 'NF > 0' | wc -l | tr -d ' ')
        if [ "$pinned" = 0 ] || [ "$verified" != "$pinned" ]; then
            rr_die "$m: $verified of the $pinned pinned files were verified"
        fi
        rr_note "$m: $repo at ${revision:0:12}, all $verified files sha256-verified ($fetched downloaded) -> $dir"
    done
    # What was verified, for the results' metadata.
    {
        printf '{"verified_at":"%s","models":{' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        local first=1
        for m in $ASR_MODELS; do
            if [ "$first" = 0 ]; then printf ','; fi
            first=0
            printf '"%s":{"repo":"%s","revision":"%s","dir":"%s","files":{' "$m" "$(model_var "$m" REPO)" \
                "$(model_var "$m" REVISION)" "$(model_var "$m" DIR)"
            model_var "$m" FILES | awk 'NF == 3 {printf "%s\"%s\":{\"bytes\":%s,\"sha256\":\"%s\"}", (n++ ? "," : ""), $1, $2, $3}'
            printf '}}'
        done
        printf '}}\n'
    } >"$ASR/models/models.json.tmp" && mv -f "$ASR/models/models.json.tmp" "$ASR/models/models.json"
}

setup() {
    local stamp
    rr_require_apple_silicon
    rr_require_cmds curl tar
    rr_check_lock_current "$TOOL_DIR/requirements.in" "$LOCK_FILE"
    mkdir -p "$ASR/models" "$ASR/home/hf" "$ASR/home/cache" "$ASR/home/tmp" "$ASR/runs" || rr_die "cannot create $ASR"

    rr_step 1/3 "Standalone CPython $RR_PY_VERSION"
    if python_ok; then
        rr_note "already installed in $ASR/python"
    else
        [ ! -e "$ASR/python" ] || [ -f "$ASR/python/.readread-python" ] || [ -f "$ASR/python.partial/.readread-python" ] ||
            rr_die "$ASR/python exists but was not made by asr_eval.sh; move it away"
        rr_provision "$RR_PY_ASSET" "$RR_PY_URL" "$RR_PY_SIZE" "$RR_PY_SHA256" "$ASR/downloads" "$RR_CACHE_DIR/downloads"
        rm -rf "$ASR/python" "$ASR/env"
        rr_extract_python "$ASR/downloads/$RR_PY_ASSET" "$ASR/python"
        printf '%s\n' "$PY_STAMP" >"$ASR/python/.readread-python"
        rr_note "installed CPython $RR_PY_VERSION ($RR_PY_RELEASE) in $ASR/python"
    fi

    rr_step 2/3 "venv from tools/asr_eval/requirements.lock"
    if env_ok; then
        rr_note "up to date ($(grep -c '^[A-Za-z]' "$LOCK_FILE") locked packages)"
    else
        [ ! -e "$ASR/env" ] || [ -f "$ASR/env/pyvenv.cfg" ] || rr_die "$ASR/env exists but is not a venv; move it away"
        rm -rf "$ASR/env"
        "$PY" -I -m venv "$ASR/env" || rr_die "cannot create the venv in $ASR/env"
        # rr_pip's cache goes under the ASR home, not the build cache.
        stamp=$(env_stamp)
        RR_CACHE_DIR="$ASR" rr_pip "$ENV_PY" install --quiet --progress-bar off --no-warn-script-location \
            --require-hashes --no-deps --only-binary :all: -r "$LOCK_FILE" ||
            rr_die "pip could not install $LOCK_FILE (hash mismatch or network; see above)"
        RR_CACHE_DIR="$ASR" rr_pip "$ENV_PY" check || rr_die "pip check failed in $ASR/env"
        env_matches_lock || rr_die "the new venv does not match $LOCK_FILE"
        printf '%s\n' "$stamp" >"$ASR/env/.readread-asr-env"
        rr_note "installed $(grep -c '^[A-Za-z]' "$LOCK_FILE") locked packages"
    fi

    rr_step 3/3 "Models (pinned Hugging Face revisions, sha256)"
    setup_models
}

# The evaluator runs offline, isolated, with every cache inside the ASR home.
run_py() {
    env -i HOME="$ASR/home" PATH=/usr/bin:/bin LANG=en_US.UTF-8 TMPDIR="$ASR/home/tmp" HF_HOME="$ASR/home/hf" \
        XDG_CACHE_HOME="$ASR/home/cache" HF_HUB_OFFLINE=1 HF_HUB_DISABLE_TELEMETRY=1 ORT_DISABLE_TELEMETRY=1 \
        TOKENIZERS_PARALLELISM=false PYTHONHASHSEED=0 \
        "$ENV_PY" -I -B "$TOOL_DIR/asr_eval.py" "$@"
}

take_lock
if [ "$MODE" = selfcheck ]; then
    env_ok || rr_die "no up-to-date venv in $ASR/env; run tools/asr_eval/asr_eval.sh --setup first"
    run_py selfcheck
    exit $?
fi

echo "=== ReadRead ASR evaluation: $ASR ==="
setup
if [ "$MODE" = setup ]; then
    echo ""
    echo "=== Setup complete: python/ $(du -sh "$ASR/python" | awk '{print $1}'), env/ $(du -sh "$ASR/env" | awk '{print $1}'), models/ $(du -sh "$ASR/models" | awk '{print $1}') ==="
    exit 0
fi

MODEL_ARGS=(--whisper-model "$ASR/models/$ASR_WHISPER_DIR" --sensevoice-model "$ASR/models/$ASR_SENSEVOICE_DIR"
    --speaker-model "$ASR/models/$ASR_SPEAKER_DIR/$(model_var speaker FILES | awk 'NF == 3 {print $1; exit}')"
    --models-manifest "$ASR/models/models.json" --threads "$THREADS")
COMPARE_ARGS=()
if [ "$COMPARE" = check ]; then COMPARE_ARGS=(--check "$BASELINE"); fi
if [ "$COMPARE" = write-baseline ]; then COMPARE_ARGS=(--write-baseline "$BASELINE"); fi

if [ "$MODE" = rescore ]; then
    [ -f "$RESCORE/manifest.jsonl" ] || rr_die "$RESCORE has no manifest.jsonl (not a run directory)"
    RESCORE=$(cd "$RESCORE" && pwd)
    echo ""
    echo "=== Evaluation of $RESCORE ==="
    run_py evaluate --out "$RESCORE" "${MODEL_ARGS[@]}" ${COMPARE_ARGS[@]+"${COMPARE_ARGS[@]}"}
    exit $?
fi

# ── What synthesizes: the dev environment, a built app, or the qwen install ──
if [ -n "$APP" ]; then
    APP=$(cd "$APP" && pwd) || rr_die "no app at $APP"
    SOURCE="app"
    TTS_PY="$APP/Contents/Resources/python/bin/python3"
    SERVER_DIR="$APP/Contents/Resources/tts_server"
    MODELS_DIR="$APP/Contents/Resources/models"
elif [ "$ENGINE" = qwen ]; then
    HQ="${READREAD_HQ_HOME:-${HOME:?}/Library/Application Support/ReadRead/hq}"
    SOURCE="qwen"
    TTS_PY="$HQ/venv/bin/python3"
    SERVER_DIR="${READREAD_TTS_SERVER_DIR:-$RR_REPO_DIR/tts_server}"
    MODELS_DIR="$HQ/models"
else
    DEV="${READREAD_HOME:-${HOME:?}/.readread}"
    SOURCE="dev"
    TTS_PY="$DEV/env/bin/python3"
    SERVER_DIR="${READREAD_TTS_SERVER_DIR:-$DEV/tts_server}"
    MODELS_DIR="$DEV/models"
fi
[ -x "$TTS_PY" ] || rr_die "no python at $TTS_PY (dev: ./scripts/setup.sh; app: ./scripts/build-app.sh; qwen: ./scripts/install-hq.sh)"
[ -f "$SERVER_DIR/tts_server.py" ] || rr_die "no tts_server.py in $SERVER_DIR"
[ -d "$MODELS_DIR" ] || rr_die "no models directory at $MODELS_DIR"
if [ -z "$OUT" ]; then OUT="$ASR/runs/$(date +%Y%m%d-%H%M%S)-$SOURCE"; fi
[ ! -e "$OUT/manifest.jsonl" ] || rr_die "$OUT already holds a run; give a new --out (or --rescore it)"
mkdir -p "$OUT" || rr_die "cannot create $OUT"
OUT=$(cd "$OUT" && pwd)

echo ""
echo "=== Synthesis ($SOURCE: $SERVER_DIR) and evaluation -> $OUT ==="
# shellcheck disable=SC2086 # the voice list
run_py run --source "$SOURCE" --engine "$ENGINE" --tts-python "$TTS_PY" --server-dir "$SERVER_DIR" \
    --tts-models "$MODELS_DIR" --tts-cache "$ASR/tts" --home "$ASR/home" --voices $VOICES --out "$OUT" \
    "${MODEL_ARGS[@]}" ${COMPARE_ARGS[@]+"${COMPARE_ARGS[@]}"}
