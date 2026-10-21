#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# Installs the optional high-quality engine, Qwen3-TTS on the GPU through MLX, outside the app:
#
#   ./scripts/install-hq.sh [--json-progress]               install, update or repair
#   ./scripts/install-hq.sh --check [--json-progress]       verify (exit status 0 or 1)
#   ./scripts/install-hq.sh --uninstall [--json-progress]   remove $READREAD_HQ_HOME
#
#   $READREAD_HQ_HOME/python/        standalone CPython (scripts/lib/versions.sh, sha256-verified)
#   $READREAD_HQ_HOME/venv/          tts_server/requirements-hq.lock, hash-checked (pip --require-hashes)
#   $READREAD_HQ_HOME/models/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit/   the one model (RR_HQ_MODELS: the best
#                                    one, no model choice): every file at the Hugging Face revision pinned
#                                    in versions.sh, size- and sha256-verified
#   $READREAD_HQ_HOME/install.json   {"version":1,"python","lock_sha256","models":{"1.7b":{"revision",...}},
#                                    "installed_at"}, written last, after the checks below passed. Before its first
#                                    change to python/, venv/ or a model file an install run moves an existing one
#                                    aside to install.json.prev (removed when it finishes): a run that stops on the
#                                    way never leaves a record of an install whose venv or model files it was
#                                    replacing, and one that changed nothing leaves install.json as it was.
#
# The app then runs the server from that venv (<server_dir>: the app bundle's or the repo's tts_server/):
#   $READREAD_HQ_HOME/venv/bin/python3 -I -B <server_dir>/tts_server.py --engine qwen --model 1.7b \
#       --models-dir $READREAD_HQ_HOME/models [--preload zh,en]
#
# Idempotent: python/ and venv/ record the inputs they were built from and are rebuilt only when those change
# (or when venv/ no longer holds exactly the locked distributions, or a file in either no longer matches its
# sha256: python/'s manifest, the RECORD pip wrote for each distribution); model files are re-verified on every run,
# a corrupt one is downloaded again, and an interrupted download resumes from its .part file. An install ends
# with an import check and a one-sentence Chinese synthesis through the real server (READY -> POST /synthesize
# -> stdin EOF -> exit 0); install.json lists the model only after that passed.
#
# --json-progress  one JSON object per line on stdout: {"event":"step","name":..,"index":N,"count":N},
#                  {"event":"download","file":..,"done":N,"total":N}, then {"event":"done",..} or
#                  {"event":"error","message":..}. Human-readable text goes to stderr.
# --check          verify an existing install (python/ against the manifest written when it was extracted, every
#                  venv/ file against the sha256 pip recorded and the venv's distributions against the lock, every
#                  model file's size and sha256, imports) without changing anything; exit status 0 or 1.
#                  install.json must list the model. Another model's install.json entry or models/ folder
#                  (older versions of this script could add a second, smaller model) is ignored here.
# --uninstall      remove $READREAD_HQ_HOME, only if it holds nothing but what this script creates (inside python/,
#                  venv/ and python.partial/ too: only the names it creates there). Once the removal runs, SIGINT,
#                  SIGTERM and SIGHUP no longer stop it: it is not resumable, so it finishes.
# --model 1.7b     accepted for older command lines: 1.7b is the one model, always installed and checked.
# An install, too, refuses a READREAD_HQ_HOME that holds anything else: it only ever replaces its own python/,
# venv/ and .tmp. A models/ folder of another model counts as something else for both (their message says so).
#
# Environment: READREAD_HQ_HOME (default ~/Library/Application Support/ReadRead/hq; set but empty is an error);
# READREAD_BUILD_CACHE (Python tarball and pip cache, default <repo>/build/cache); READREAD_TTS_SERVER_DIR
# (the server the smoke run starts, default <repo>/tts_server). Downloads need the network (pypi.org,
# files.pythonhosted.org, github.com, huggingface.co and its CDN); the smoke run needs the GPU (Metal).
# Exit status: 0 on success, 1 on failure, 2 on a usage error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

STEPS_INSTALL=6
READY_TIMEOUT=300 # s; the first read of a 3 GB model from a cold disk takes ~20 s, plus Metal shader compiles
SYNTH_TIMEOUT=180
EXIT_TIMEOUT=5
DOWNLOAD_TRIES=5
SMOKE_TEXT="你好，欢迎使用高质量语音朗读。"

# ── Arguments and output ─────────────────────────────────────────────
JSON=0
for arg in "$@"; do
    if [ "$arg" = --json-progress ]; then JSON=1; fi
done
if [ "$JSON" = 1 ]; then
    exec 3>&1 1>&2 # fd 3 carries the JSON events; everything else goes to stderr
else
    exec 3>/dev/null
fi

json_str() { # <text>: a JSON string literal (control characters other than \t \n \r dropped)
    local s
    s=$(printf '%s' "$1" | LC_ALL=C tr -d '\000-\010\013\014\016-\037')
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\t'/\\t}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    printf '"%s"' "$s"
}
emit() { if [ "$JSON" = 1 ]; then printf '%s\n' "$1" >&3 || true; fi; }

usage() {
    sed -n '3,7s/^#  *//p' "$0" >&2
}
usage_error() {
    printf 'install-hq.sh: %s\n' "$1" >&2
    usage
    emit "{\"event\":\"error\",\"message\":$(json_str "usage: $1")}"
    exit 2
}

MODE=install
while [ $# -gt 0 ]; do
    case "$1" in
    --model | --model=*) # older versions offered a choice; --model 1.7b (the one model) still means it
        if [ "$1" = --model ]; then
            [ $# -ge 2 ] || usage_error "--model needs a value"
            model_arg=$2
            shift 2
        else
            model_arg=${1#--model=}
            shift
        fi
        [ "$model_arg" = "$RR_HQ_MODELS" ] ||
            usage_error "--model $model_arg: there is one model, $RR_HQ_MODELS, and install-hq.sh always installs it"
        ;;
    --json-progress) shift ;;
    --check | --uninstall)
        [ "$MODE" = install ] || usage_error "--check and --uninstall exclude each other"
        MODE=${1#--}
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *) usage_error "unknown argument: $1" ;;
    esac
done
MODELS=$RR_HQ_MODELS # what an install installs and --check verifies

# ── Failure reporting, signals, the lock ─────────────────────────────
ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/rr-hq-error.XXXXXX") || {
    echo "ERROR: mktemp failed" >&2
    exit 1
}
CURL_PID=""
SRV_PID=""
CHILD_PID="" # a background job the script waits on (pip, the Python download; see run_child)
LOCKED=0
HQ=""
DONE=0 # set by finish(), right before a successful exit

# common.sh's rr_die, plus the message for the JSON error event (it may run in a subshell, hence the file).
rr_die() {
    printf '\nERROR: %s\n' "$*" >&2
    printf '%s' "$*" >"$ERR_FILE"
    exit 1
}
# common.sh's rr_step, plus the JSON step event.
rr_step() {
    # shellcheck disable=SC2034 # read by on_exit
    RR_STEP_LABEL="[$1] $2"
    printf '\n[%s] %s\n' "$1" "$2"
    emit "{\"event\":\"step\",\"name\":$(json_str "$2"),\"index\":${1%/*},\"count\":${1#*/}}"
}

# run_child <command...>: run it in the background and wait for it, so that a signal is handled at once
# (bash runs a trap only after a foreground child exits) and stop_children can stop it. A failing command's
# rr_die message is in $ERR_FILE already: the caller exits with `|| exit 1`.
run_child() {
    local status=0
    "$@" &
    CHILD_PID=$!
    wait "$CHILD_PID" || status=$?
    CHILD_PID=""
    return "$status"
}
descendants() { # <pid>: its child processes, recursively
    local child
    for child in $(pgrep -P "$1" 2>/dev/null || true); do
        printf '%s\n' "$child"
        descendants "$child"
    done
}

stop_children() {
    local tree job
    # A signal can arrive between `cmd &` and the `X_PID=$!` after it (bash runs the trap in between):
    # every background job of this shell goes too, with its descendants, not only the recorded ones.
    for job in $(jobs -p 2>/dev/null || true); do
        if [ "$job" != "$CHILD_PID" ] && [ "$job" != "$CURL_PID" ] && [ "$job" != "$SRV_PID" ]; then
            tree=$(descendants "$job")
            # shellcheck disable=SC2086 # a list of pids
            kill -TERM "$job" $tree 2>/dev/null || true
            wait "$job" 2>/dev/null || true
        fi
    done
    if [ -n "$CHILD_PID" ]; then
        tree=$(descendants "$CHILD_PID") # before the kill: orphans would be out of reach
        # shellcheck disable=SC2086 # a list of pids
        kill -TERM "$CHILD_PID" $tree 2>/dev/null || true
        wait "$CHILD_PID" 2>/dev/null || true
        CHILD_PID=""
    fi
    if [ -n "$CURL_PID" ]; then
        kill -TERM "$CURL_PID" 2>/dev/null || true
        wait "$CURL_PID" 2>/dev/null || true
        CURL_PID=""
    fi
    if [ -n "$SRV_PID" ]; then
        exec 4>&- # stdin EOF: the server exits by itself
        sleep 1
        kill -TERM "$SRV_PID" 2>/dev/null || true
        wait "$SRV_PID" 2>/dev/null || true
        SRV_PID=""
    fi
}
release_lock() {
    if [ "$LOCKED" = 1 ]; then
        if [ "$(lock_pid)" = "$$" ]; then rm -f "$HQ/.lock"; fi
        LOCKED=0
    fi
}
on_exit() {
    local status=$? message=""
    trap - INT TERM HUP
    stop_children
    release_lock
    if [ "$status" = 0 ] && [ "$DONE" != 1 ]; then
        status=1 # an exit without finish(): bash 3.2 even exits 0 after a syntax error it meets at run time
        printf '\nERROR: install-hq.sh stopped before it finished%s\n' "${RR_STEP_LABEL:+ (in $RR_STEP_LABEL)}" >&2
    fi
    if [ "$status" != 0 ] && [ "$status" != 2 ]; then
        message=$(cat "$ERR_FILE" 2>/dev/null || true)
        if [ -z "$message" ]; then message="install-hq.sh failed${RR_STEP_LABEL:+ in $RR_STEP_LABEL} (exit status $status)"; fi
    fi
    rm -f "$ERR_FILE" || true # before the event: nothing is left behind whatever happens to it
    if [ -n "$message" ]; then emit "{\"event\":\"error\",\"message\":$(json_str "$message")}"; fi
    exit "$status"
}
finish() { # <done event>: the last thing a successful run does
    DONE=1
    emit "$1"
}
trap on_exit EXIT
trap 'rr_die "interrupted by a signal (run again to resume)"' INT TERM HUP

# ── The HQ home ──────────────────────────────────────────────────────
if [ "${READREAD_HQ_HOME+set}" = set ] && [ -z "$READREAD_HQ_HOME" ]; then
    rr_die "READREAD_HQ_HOME is set but empty; unset it to use the default, or give it a path"
fi
HQ="${READREAD_HQ_HOME:-${HOME:?}/Library/Application Support/ReadRead/hq}"
while [ "${HQ%/}" != "$HQ" ]; do HQ=${HQ%/}; done
case "$HQ" in
/?*/?*) ;;
*) rr_die "READREAD_HQ_HOME must be an absolute path at least two levels deep (got '${READREAD_HQ_HOME:-}')" ;;
esac
case "$HQ/" in
*/./* | */../* | *//* | *$'\n'*) rr_die "READREAD_HQ_HOME must be a plain absolute path without . or .. (got '$HQ')" ;;
esac
HOME_DIR=${HOME%/}
case "$HOME_DIR/" in
"$HQ"/*) rr_die "READREAD_HQ_HOME ($HQ) is your home directory or contains it; refusing" ;;
esac
# The same by identity: on a case-insensitive volume /Users/ME is the home directory /Users/me too.
if [ -d "$HQ" ] && [ -n "$HOME_DIR" ]; then
    ancestor=$HOME_DIR
    while :; do
        if [ -e "$ancestor" ] && [ "$ancestor" -ef "$HQ" ]; then rr_die "READREAD_HQ_HOME ($HQ) is your home directory or contains it; refusing"; fi
        [ "$ancestor" != / ] && [ "$ancestor" != . ] || break
        ancestor=$(dirname "$ancestor")
    done
fi
if [ -L "$HQ" ]; then rr_die "READREAD_HQ_HOME ($HQ) is a symlink; give the directory it points to"; fi
if [ -e "$HQ" ] && [ ! -d "$HQ" ]; then rr_die "READREAD_HQ_HOME ($HQ) exists and is not a directory"; fi

PY="$HQ/python/bin/python3"
VENV_PY="$HQ/venv/bin/python3"
PY_STAMP="$RR_PY_VERSION+$RR_PY_RELEASE $RR_PY_SHA256"
SERVER_DIR="${READREAD_TTS_SERVER_DIR:-$RR_REPO_DIR/tts_server}"

# The lock is a symlink $HQ/.lock -> <pid>: created atomically with its pid (an older run's .lock/pid
# directory is still understood).
lock_pid() {
    local pid=""
    if [ -L "$HQ/.lock" ]; then
        pid=$(readlink "$HQ/.lock" 2>/dev/null || true)
    elif [ -d "$HQ/.lock" ]; then
        pid=$(cat "$HQ/.lock/pid" 2>/dev/null || true)
    fi
    case "$pid" in "" | *[!0-9]*) pid="" ;; esac
    printf '%s' "$pid"
}
take_lock() {
    local pid
    mkdir -p "$HQ" || rr_die "cannot create $HQ"
    # ln -n: never into an existing .lock (ln would put the link inside a directory, or the one a link names).
    if [ -e "$HQ/.lock" ] || [ -L "$HQ/.lock" ] || ! ln -sn "$$" "$HQ/.lock" 2>/dev/null; then
        pid=$(lock_pid)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            rr_die "another install-hq.sh (pid $pid) is working on $HQ"
        fi
        rr_warn "removing the stale lock of a run that is gone (pid ${pid:-unknown})"
        rm -rf "$HQ/.lock"
        ln -sn "$$" "$HQ/.lock" 2>/dev/null || rr_die "cannot lock $HQ (another run took it just now)"
    fi
    [ "$(lock_pid)" = "$$" ] || rr_die "cannot lock $HQ (another run took it just now)"
    LOCKED=1
}
check_not_locked() {
    local pid
    pid=$(lock_pid)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then rr_die "install-hq.sh (pid $pid) is working on $HQ right now"; fi
}

# ── Models: names and pinned files ───────────────────────────────────
hq_key() { printf '%s' "$1" | tr '.b' '_B'; } # 1.7b -> 1_7B (the versions.sh variable infix)
hq_repo() {
    local var
    var="RR_HQ_$(hq_key "$1")_REPO"
    printf '%s\n' "${!var}"
}
hq_revision() {
    local var
    var="RR_HQ_$(hq_key "$1")_REVISION"
    printf '%s\n' "${!var}"
}
hq_dir() {
    local repo
    repo=$(hq_repo "$1")
    printf '%s\n' "${repo##*/}"
}
hq_files() { # <model>: "path bytes sha256" lines
    local var
    var="RR_HQ_$(hq_key "$1")_FILES"
    printf '%s\n' "${!var}" | awk 'NF == 3'
}
hq_model_bytes() { hq_files "$1" | awk '{s += $2} END {printf "%d\n", s}'; }

# hq_verified <file> <bytes> <sha256>: the file (not a symlink) matches.
hq_verified() {
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    [ "$(rr_size "$1")" = "$2" ] || return 1
    [ "$(rr_sha256 "$1")" = "$3" ]
}

emit_download() { # <label> <done> <total>
    emit "{\"event\":\"download\",\"file\":$(json_str "$1"),\"done\":$2,\"total\":$3}"
}

# hq_curl <url> <part> <bytes> <label>: one curl run that appends to <part> (resuming it); in JSON mode the
# part's size is reported every half second. Returns curl's status.
hq_curl() {
    local url=$1 part=$2 total=$3 label=$4 progress=-sS status=0
    if [ "$JSON" = 0 ] && [ -t 2 ]; then progress=--progress-bar; fi
    curl -fL -C - --connect-timeout 30 --speed-limit 10000 --speed-time 60 "$progress" -o "$part" "$url" 3>&- &
    CURL_PID=$!
    if [ "$JSON" = 1 ]; then
        while kill -0 "$CURL_PID" 2>/dev/null; do
            emit_download "$label" "$(rr_size "$part" 2>/dev/null || echo 0)" "$total"
            sleep 0.5
        done
    fi
    wait "$CURL_PID" || status=$?
    CURL_PID=""
    return "$status"
}

# hq_download <url> <dest> <bytes> <sha256> <label>: resumable download into <dest>.part, verified, then moved
# into place. A part that turns out wrong is deleted and the file downloaded once more from scratch.
hq_download() {
    local url=$1 dest=$2 size=$3 sha=$4 label=$5 part="$2.part" have try round status got
    mkdir -p "$(dirname "$dest")" || rr_die "cannot create $(dirname "$dest")"
    for round in 1 2; do
        try=0
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
                rr_note "$label: resuming at $(rr_mb "$have") of $(rr_mb "$size") MB"
            else
                rr_note "$label: downloading $(rr_mb "$size") MB from $url"
            fi
            emit_download "$label" "$have" "$size"
            status=0
            hq_curl "$url" "$part" "$size" "$label" || status=$?
            if [ "$status" = 0 ]; then break; fi
            if [ "$status" = 33 ]; then rm -f "$part"; fi # the server cannot resume: start over
            if [ "$try" -ge "$DOWNLOAD_TRIES" ]; then
                rr_die "download failed (curl exit $status): $url; run install-hq.sh again to resume"
            fi
            rr_warn "$label: curl exit $status; retrying"
            sleep 2
        done
        got=$(rr_size "$part")
        emit_download "$label" "$got" "$size"
        if [ "$got" = "$size" ] && [ "$(rr_sha256 "$part")" = "$sha" ]; then
            mv -f "$part" "$dest" || rr_die "cannot move $part into place"
            hq_verified "$dest" "$size" "$sha" || rr_die "$dest changed while it was moved into place"
            return 0
        fi
        rm -f "$part"
        if [ "$round" = 1 ]; then rr_warn "$label: the download ($got bytes) does not match the pinned sha256; starting over"; fi
    done
    rr_die "checksum mismatch for $url
  expected: $size bytes, sha256 $sha
  The download was deleted; nothing was installed."
}

# hq_install_model <model>: every pinned file of the model, verified.
hq_install_model() {
    local m=$1 dir path size sha dest fetched=0 kept=0
    dir="$HQ/models/$(hq_dir "$m")"
    rr_note "$m: $(hq_repo "$m") at $(hq_revision "$m") -> $dir"
    while read -r -u 9 path size sha; do
        dest="$dir/$path"
        if hq_verified "$dest" "$size" "$sha"; then
            kept=$((kept + 1))
            continue
        fi
        mark_unfinished # this model file changes
        if [ -e "$dest" ] || [ -L "$dest" ]; then
            rr_warn "$(hq_dir "$m")/$path does not match its pinned size and sha256 (corrupt or changed): replacing it"
            rm -f "$dest" || rr_die "cannot remove $dest"
        fi
        hq_download "https://huggingface.co/$(hq_repo "$m")/resolve/$(hq_revision "$m")/$path" "$dest" "$size" "$sha" \
            "$(hq_dir "$m")/$path"
        fetched=$((fetched + 1))
    done 9<<<"$(hq_files "$m")"
    rr_note "$m: $kept files already verified, $fetched downloaded; $(rr_mb "$(hq_model_bytes "$m")") MB, every file sha256-verified"
}

# Bytes still to download for the given models (.part bytes are done).
hq_missing_bytes() {
    local m path size sha dest have total=0
    for m in "$@"; do
        while read -r path size sha; do
            dest="$HQ/models/$(hq_dir "$m")/$path"
            if [ -f "$dest" ] && [ "$(rr_size "$dest")" = "$size" ]; then continue; fi
            have=0
            if [ -f "$dest.part" ]; then have=$(rr_size "$dest.part"); fi
            total=$((total + size - have))
        done <<<"$(hq_files "$m")"
    done
    printf '%d\n' "$total"
}

# ── Python and the venv ──────────────────────────────────────────────
# python_manifest: the sha256 of every file and the target of every symlink in python/ (bytecode and the
# markers aside: Python itself writes __pycache__ there). Written at extraction as .readread-manifest.
python_manifest() {
    (
        cd "$HQ/python" || exit 1
        find . -name __pycache__ -prune -o -type f ! -name .readread-python ! -name .readread-manifest -print0 |
            LC_ALL=C sort -z | xargs -0 shasum -a 256 || exit 1
        find . -name __pycache__ -prune -o -type l -print0 | LC_ALL=C sort -z | while IFS= read -r -d '' link; do
            printf 'link %s -> %s\n' "$link" "$(readlink "$link")"
        done
    )
}
python_ok() {
    local changed
    [ -x "$PY" ] && [ "$(cat "$HQ/python/.readread-python" 2>/dev/null)" = "$PY_STAMP" ] || return 1
    if [ ! -f "$HQ/python/.readread-manifest" ]; then
        printf '  python/ has no manifest (.readread-manifest) to check its files against\n' >&2
        return 1
    fi
    changed=$(python_manifest | diff "$HQ/python/.readread-manifest" - | grep '^[<>]' | head -4) || true
    if [ -n "$changed" ]; then
        printf '  python/ differs from its manifest (< recorded, > now):\n%s\n' "$(printf '%s\n' "$changed" | sed 's/^/    /')" >&2
        return 1
    fi
    "$PY" -I -B -c 'import sys' 2>/dev/null
}
# Ours to replace: python/ with its stamp (or the bare python-build-standalone layout an interrupted install
# leaves), venv/ with its stamp or a pyvenv.cfg whose home is $HQ/python/bin; either without a single file.
no_files() { [ -z "$(find "$1" \( -type f -o -type l \) -print 2>/dev/null | head -1)" ]; } # <dir>
hq_owns_python() {
    local entry
    [ -e "$HQ/python/.readread-python" ] && return 0
    no_files "$HQ/python" && return 0
    [ -x "$HQ/python/bin/python3" ] || return 1
    for entry in "$HQ/python"/* "$HQ/python"/.[!.]*; do
        [ -e "$entry" ] || continue
        case "${entry##*/}" in bin | include | lib | share | .readread-manifest | .DS_Store) ;; *) return 1 ;; esac
    done
}
hq_owns_venv() {
    local home
    [ -e "$HQ/venv/.readread-hq-venv" ] && return 0
    no_files "$HQ/venv" && return 0 # an interrupted venv creation, before its pyvenv.cfg
    home=$(sed -n 's/^home *= *//p' "$HQ/venv/pyvenv.cfg" 2>/dev/null | head -1)
    [ -n "$home" ] && [ -d "$HQ/python/bin" ] && [ "$home" -ef "$HQ/python/bin" ]
}
# What python/, venv/ and python.partial/ hold at their top level when this script made them (python-build-standalone's
# layout and the markers; a venv's layout, where wheels may add share/ or etc/; the extraction's python/).
PYTHON_ENTRIES=(bin include lib share .readread-python .readread-manifest .DS_Store)
VENV_ENTRIES=(bin include lib share etc pyvenv.cfg .readread-hq-venv .gitignore .DS_Store)
# foreign_entries <dir> <allowed name>...: prints each top-level entry of <dir> that is none of them, as
# <dir name>/<entry>; a <dir> that is not a directory (or is a symlink) is printed itself.
foreign_entries() {
    local dir=$1 entry
    shift
    if [ ! -d "$dir" ] || [ -L "$dir" ]; then
        printf '%s\n' "${dir##*/}"
        return 0
    fi
    for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        case " $* " in *" ${entry##*/} "*) ;; *) printf '%s/%s\n' "${dir##*/}" "${entry##*/}" ;; esac
    done
}

# hq_foreign [all]: prints what in $HQ this script did not create, one entry per line (nothing: all ours). With
# "all", the files in the model folders too (they go with --uninstall; an install only touches the pinned ones).
# A folder in models/ other than the model's is named as UNUSED_MODEL: older versions of this script could add
# a second model there, which this one neither installs nor removes.
UNUSED_MODEL="a model folder this version does not use"
hq_foreign() {
    local entry m dirs
    [ -d "$HQ" ] || return 0
    dirs=" $(for m in $RR_HQ_MODELS; do hq_dir "$m"; done | tr '\n' ' ') "
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        case "${entry##*/}" in
        python)
            if hq_owns_python; then
                foreign_entries "$HQ/python" "${PYTHON_ENTRIES[@]}"
            else
                printf 'python/ (not a Python this script installed)\n'
            fi
            ;;
        venv)
            if hq_owns_venv; then
                foreign_entries "$HQ/venv" "${VENV_ENTRIES[@]}"
            else
                printf 'venv/ (not a venv of %s/python)\n' "$HQ"
            fi
            ;;
        python.partial) foreign_entries "$HQ/python.partial" python .DS_Store ;; # the extraction: python/ only
        models | install.json | install.json.tmp | install.json.prev | .lock | .tmp | .DS_Store) ;;
        *) printf '%s\n' "${entry##*/}" ;;
        esac
    done <<<"$(find "$HQ" -mindepth 1 -maxdepth 1 -print)"
    if [ -d "$HQ/models" ]; then
        while IFS= read -r entry; do
            [ -n "$entry" ] || continue
            case "$dirs" in
            *" ${entry##*/} "*) ;;
            *)
                if [ "${entry##*/}" = .DS_Store ]; then
                    :
                elif [ -d "$entry" ] && [ ! -L "$entry" ]; then
                    printf 'models/%s (%s)\n' "${entry##*/}" "$UNUSED_MODEL"
                else
                    printf 'models/%s\n' "${entry##*/}"
                fi
                ;;
            esac
        done <<<"$(find "$HQ/models" -mindepth 1 -maxdepth 1 -print)"
        if [ "${1:-}" = all ]; then
            for m in $RR_HQ_MODELS; do
                [ -d "$HQ/models/$(hq_dir "$m")" ] || continue
                {
                    hq_files "$m" | awk '{print "P " $1}'
                    (cd "$HQ/models/$(hq_dir "$m")" && find . \( -type f -o -type l \) -print) | sed 's|^\./|F |'
                } | awk -v dir="models/$(hq_dir "$m")/" '
                    substr($0, 1, 2) == "P " { p = substr($0, 3); ok[p] = 1; ok[p ".part"] = 1; next }
                    { path = substr($0, 3); name = path; sub(/.*\//, "", name); if (!(path in ok) && name != ".DS_Store") print dir path }'
            done
        fi
    fi
    if [ -d "$HQ/.tmp" ]; then
        while IFS= read -r entry; do
            [ -n "$entry" ] || continue
            case "${entry##*/}" in hf | smoke-* | .DS_Store) ;; *) printf '.tmp/%s\n' "${entry##*/}" ;; esac
        done <<<"$(find "$HQ/.tmp" -mindepth 1 -maxdepth 1 -print)"
    fi
}
# refuse_foreign <what we were about to do> [all]: dies when $HQ holds anything hq_foreign names.
refuse_foreign() {
    local list count hint=""
    list=$(hq_foreign "${2:-}")
    [ -n "$list" ] || return 0
    count=$(printf '%s\n' "$list" | wc -l | tr -d ' ')
    case "$list" in
    *"($UNUSED_MODEL)"*) hint=" ReadRead uses only the $RR_HQ_MODELS model now: delete the other model's folder (an older version installed it), then run this again." ;;
    esac
    list=$(printf '%s\n' "$list" | head -8 | paste -sd ',' - | sed 's/,/, /g')
    if [ "$count" -gt 8 ]; then list="$list and $((count - 8)) more"; fi
    rr_die "$HQ holds files install-hq.sh did not create ($list); $1$hint"
}

venv_stamp() {
    rr_sha256_string "python=$PY_STAMP lock=$(rr_sha256 "$RR_HQ_LOCK_FILE") sdist=$RR_SDIST_PACKAGES backend=$RR_BUILD_BACKEND recipe=$RR_HQ_RECIPE"
}
# The venv holds exactly the locked distributions (plus pip) at their locked versions, and pip check is clean.
venv_matches_lock() {
    "$VENV_PY" -I -B -c '
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
# Every installed file against the sha256 pip recorded for it (RECORD).
import base64, hashlib
for d in distributions():
    for f in d.files or []:
        if f.hash is None or f.hash.mode != "sha256":
            continue
        digest = hashlib.sha256()
        try:
            with open(f.locate(), "rb") as data:
                for chunk in iter(lambda: data.read(1 << 20), b""):
                    digest.update(chunk)
        except OSError:
            problems.append(f"{f} is missing")
            continue
        if base64.urlsafe_b64encode(digest.digest()).rstrip(b"=").decode() != f.hash.value:
            problems.append(f"{f} was modified")
if problems:
    sys.exit("  venv/ does not match the lock: " + "; ".join(problems[:6]) + (" ..." if len(problems) > 6 else ""))
' "$RR_HQ_LOCK_FILE" || return 1
    local check
    check=$(rr_pip "$VENV_PY" check 2>&1) || {
        printf '  venv/ fails pip check: %s\n' "$check" >&2
        return 1
    }
}
venv_ok() {
    [ -x "$VENV_PY" ] && [ "$(cat "$HQ/venv/.readread-hq-venv" 2>/dev/null)" = "$(venv_stamp)" ] &&
        "$VENV_PY" -I -c 'import sys' 2>/dev/null && venv_matches_lock
}

# The modules the qwen engine imports, offline, with Hugging Face's cache pointed at a scratch dir.
check_imports() {
    local hf="$1"
    mkdir -p "$hf" || return 1
    HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 HF_HUB_DISABLE_TELEMETRY=1 HF_HOME="$hf" "$VENV_PY" -I -B -W ignore -c '
import mlx.core, mlx_audio, mlx_audio.tts.utils, mlx_audio.tts.models.qwen3_tts
import transformers, tokenizers, huggingface_hub, safetensors, numpy
import misaki.zh_normalization, opencc, num2words, pypinyin
from importlib.metadata import version
print("  imports ok: " + ", ".join("%s %s" % (d, version(d)) for d in ("mlx", "mlx-metal", "mlx-audio", "transformers", "numpy")))
' 3>&-
}

# ── The smoke run: the real server, one Chinese sentence ─────────────
new_token() { od -An -N32 -tx1 /dev/urandom | tr -d ' \n'; }
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }
json_get() { plutil -extract "$2" raw -o - "$1" 2>/dev/null || true; }
show_log() { # <file>
    if [ -s "$1" ]; then
        echo "      --- last lines of $1 ---" >&2
        tail -n 20 "$1" | sed 's/^/      /' >&2
    fi
}

# smoke <model>: READY, then POST /synthesize (serena, zh), then stdin EOF; dies on any failure.
smoke() {
    local m=$1 dir token t0 line port code duration ready_ms synth_ms written status=0
    dir="$HQ/.tmp/smoke-$m"
    rm -rf "$dir"
    mkdir -p "$dir/home" "$dir/cache" "$dir/tmp" || rr_die "cannot create $dir"
    token=$(new_token)
    mkfifo "$dir/stdin" || rr_die "mkfifo failed in $dir"
    # The server's stdin is a FIFO held open on fd 4; closing fd 4 is the app going away.
    env -i HOME="$dir/home" PATH=/usr/bin:/bin LANG=en_US.UTF-8 TMPDIR="$dir/tmp" READREAD_TOKEN="$token" \
        READREAD_CACHE_DIR="$dir/cache" READREAD_USER_LEXICON="$dir/lexicon_zh.json" \
        "$VENV_PY" -I -B "$SERVER_DIR/tts_server.py" --engine qwen --model "$m" --models-dir "$HQ/models" \
        --preload zh <"$dir/stdin" >"$dir/stdout" 2>"$dir/stderr.log" 3>&- &
    SRV_PID=$!
    exec 4>"$dir/stdin"
    t0=$(now_ms)
    while ! [ -s "$dir/stdout" ]; do
        if ! kill -0 "$SRV_PID" 2>/dev/null; then
            show_log "$dir/stderr.log"
            rr_die "smoke test ($m): the server exited before READY (log: $dir/stderr.log)"
        fi
        if [ $(($(now_ms) - t0)) -gt $((READY_TIMEOUT * 1000)) ]; then
            show_log "$dir/stderr.log"
            rr_die "smoke test ($m): no READY within $READY_TIMEOUT s (log: $dir/stderr.log)"
        fi
        sleep 0.2
    done
    sleep 0.1
    ready_ms=$(($(now_ms) - t0))
    line=$(head -n 1 "$dir/stdout")
    case "$line" in
    "READY "*) ;;
    *)
        show_log "$dir/stderr.log"
        rr_die "smoke test ($m): the server said: $line"
        ;;
    esac
    printf '%s' "${line#READY }" >"$dir/ready.json"
    port=$(json_get "$dir/ready.json" port)
    if [ -z "$port" ] || [ "$(json_get "$dir/ready.json" engine)" != qwen ] || [ "$(json_get "$dir/ready.json" model)" != "$m" ]; then
        rr_die "smoke test ($m): unexpected READY line: $line"
    fi
    rr_note "smoke test ($m): READY after $ready_ms ms: $line"
    printf '{"text":"%s","voice":"serena","lang":"zh","format":"json","request_id":"install-hq-smoke"}' "$SMOKE_TEXT" \
        >"$dir/request.json"
    t0=$(now_ms)
    code=$(curl -sS --noproxy '*' --max-time "$SYNTH_TIMEOUT" -o "$dir/response.json" -w '%{http_code}' -X POST \
        -H "Authorization: Bearer $token" -H 'Content-Type: application/json' --data-binary "@$dir/request.json" \
        "http://127.0.0.1:$port/synthesize" 3>&- 4>&-) || code=000
    synth_ms=$(($(now_ms) - t0))
    if [ "$code" != 200 ]; then
        show_log "$dir/stderr.log"
        rr_die "smoke test ($m): POST /synthesize answered HTTP $code: $(head -c 300 "$dir/response.json" 2>/dev/null)"
    fi
    duration=$(json_get "$dir/response.json" duration)
    if ! awk -v d="${duration:-0}" 'BEGIN {exit !(d >= 1.0 && d <= 12.0)}' ||
        [ "$(json_get "$dir/response.json" silent)" != false ] ||
        [ "$(json_get "$dir/response.json" sample_rate)" != 24000 ] ||
        ! awk -v s="$(json_get "$dir/response.json" synth_speed)" 'BEGIN {exit !(s == 1)}'; then
        rr_die "smoke test ($m): implausible synthesis (duration ${duration:-?} s): $(head -c 300 "$dir/response.json")"
    fi
    rr_note "smoke test ($m): $SMOKE_TEXT -> $duration s of audio in $synth_ms ms"
    exec 4>&-
    t0=$(now_ms)
    while kill -0 "$SRV_PID" 2>/dev/null && [ $(($(now_ms) - t0)) -lt $((EXIT_TIMEOUT * 1000)) ]; do sleep 0.1; done
    if kill -0 "$SRV_PID" 2>/dev/null; then
        rr_die "smoke test ($m): the server is still running $EXIT_TIMEOUT s after stdin EOF"
    fi
    wait "$SRV_PID" || status=$?
    SRV_PID=""
    [ "$status" = 0 ] || rr_die "smoke test ($m): the server exited with status $status after stdin EOF"
    if [ "$(wc -l <"$dir/stdout" | tr -d ' ')" != 1 ]; then
        rr_die "smoke test ($m): stdout carried more than the READY line"
    fi
    written=$(find "$dir/home" -mindepth 1 -print | head -5)
    if [ -n "$written" ]; then
        rr_die "smoke test ($m): the server wrote into its HOME: $(printf '%s' "$written" | tr '\n' ' ')"
    fi
    rr_note "smoke test ($m): the server exited $(($(now_ms) - t0)) ms after stdin EOF (status 0)"
    rm -rf "$dir"
}

# write_install_json <model>...: install.json listing these models, written atomically.
write_install_json() {
    local m specs=()
    for m in "$@"; do
        specs+=("$m|$(hq_repo "$m")|$(hq_revision "$m")|$(hq_dir "$m")|$(hq_files "$m" | wc -l | tr -d ' ')|$(hq_model_bytes "$m")")
    done
    "$PY" -I -B -c '
import json, os, sys
path, python, lock_sha, now, *specs = sys.argv[1:]
models = {}
for spec in specs:
    key, repo, revision, folder, files, size = spec.split("|")
    models[key] = {"repo": repo, "revision": revision, "dir": folder, "files": int(files), "bytes": int(size)}
data = {"version": 1, "python": python, "lock_sha256": lock_sha, "models": models, "installed_at": now}
with open(path + ".tmp", "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(path + ".tmp", path)
' "$HQ/install.json" "$RR_PY_VERSION+$RR_PY_RELEASE" "$(rr_sha256 "$RR_HQ_LOCK_FILE")" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${specs[@]}" 3>&- || rr_die "cannot write $HQ/install.json"
}

# ── --uninstall ──────────────────────────────────────────────────────
if [ "$MODE" = uninstall ]; then
    rr_step 1/1 "Uninstall $HQ"
    if [ ! -e "$HQ" ]; then
        rr_note "nothing to remove: $HQ does not exist"
        finish '{"event":"done","removed":false}'
        exit 0
    fi
    take_lock # no install may start while the tree goes
    refuse_foreign "not removing anything. Delete it yourself if it is really the HQ install." all
    size=$(du -sk "$HQ" | awk '{print $1}')
    # A removal stopped half way cannot be resumed and would leave a broken install: from here on a signal
    # is ignored (rm inherits that) and the run finishes with its done event. SIGKILL still ends it.
    trap '' INT TERM HUP
    rm -rf "$HQ" || rr_die "could not remove all of $HQ"
    LOCKED=0 # it went with the tree
    [ ! -e "$HQ" ] || rr_die "$HQ is still there after rm -rf"
    rr_note "removed $HQ ($(awk -v k="$size" 'BEGIN {printf "%.1f", k / 1000}') MB)"
    finish '{"event":"done","removed":true}'
    exit 0
fi

# ── --check ──────────────────────────────────────────────────────────
if [ "$MODE" = check ]; then
    [ -d "$HQ" ] || rr_die "no HQ install at $HQ"
    check_not_locked
    problems=""
    problem() {
        problems="$problems
  - $1"
        rr_warn "$1"
    }
    rr_step 1/4 "install.json"
    if ! listed=$(perl -MJSON::PP -e '
        local $/;
        open(my $f, "<", $ARGV[0]) or die "cannot read $ARGV[0]\n";
        my $d = JSON::PP->new->decode(<$f>);
        die "its version is not 1\n" unless ref $d eq "HASH" && ($d->{version} // 0) == 1;
        die "it has no models object\n" unless ref $d->{models} eq "HASH";
        print join(" ", sort keys %{$d->{models}}), "\n", ($d->{lock_sha256} // ""), "\n";
    ' "$HQ/install.json" 2>&1); then
        unfinished=""
        if [ ! -e "$HQ/install.json" ] && [ -e "$HQ/install.json.prev" ]; then
            unfinished=" (an install or repair stopped before it finished: run install-hq.sh again)"
        fi
        problem "install.json is missing or unreadable: $(printf '%s' "$listed" | tail -1)$unfinished"
        listed=""
    fi
    listed_models=$(printf '%s\n' "$listed" | sed -n 1p)
    listed_lock=$(printf '%s\n' "$listed" | sed -n 2p)
    for m in $MODELS; do # another model's entry (an older version's) is not checked
        case " $listed_models " in *" $m "*) ;; *) problem "install.json does not list model $m" ;; esac
    done
    if [ -n "$listed" ] && [ "$listed_lock" != "$(rr_sha256 "$RR_HQ_LOCK_FILE")" ]; then
        problem "install.json records another requirements-hq.lock (the venv is out of date; run install-hq.sh)"
    fi
    rr_note "model: $MODELS (install.json lists: ${listed_models:-nothing})"
    rr_step 2/4 "Python and venv"
    if python_ok; then rr_note "CPython $RR_PY_VERSION ($RR_PY_RELEASE), every file as extracted: ok"; else problem "python/ is missing, modified or not CPython $RR_PY_VERSION+$RR_PY_RELEASE"; fi
    if venv_ok; then rr_note "venv matches requirements-hq.lock (installed set, every file's sha256, pip check): ok"; else problem "venv/ is missing, incomplete, modified or built from other inputs"; fi
    rr_step 3/4 "Model files (size and sha256)"
    for m in $MODELS; do
        bad=0
        while read -r path size sha; do
            if ! hq_verified "$HQ/models/$(hq_dir "$m")/$path" "$size" "$sha"; then
                problem "$(hq_dir "$m")/$path is missing or does not match its pinned size and sha256"
                bad=$((bad + 1))
            fi
        done <<<"$(hq_files "$m")"
        if [ "$bad" = 0 ]; then rr_note "$m: all $(hq_files "$m" | wc -l | tr -d ' ') files verified ($(rr_mb "$(hq_model_bytes "$m")") MB)"; fi
    done
    rr_step 4/4 "Imports"
    hf_scratch=$(mktemp -d "${TMPDIR:-/tmp}/rr-hq-hf.XXXXXX") || rr_die "mktemp failed"
    if [ -x "$VENV_PY" ] && check_imports "$hf_scratch"; then :; else problem "the qwen engine's modules do not import"; fi
    rm -rf "$hf_scratch"
    if [ -n "$problems" ]; then rr_die "the HQ install at $HQ has problems:$problems"; fi
    echo ""
    echo "=== HQ install OK: $HQ (model: $MODELS) ==="
    finish "{\"event\":\"done\",\"home\":$(json_str "$HQ"),\"models\":[$(for m in $MODELS; do printf '"%s",' "$m"; done | sed 's/,$//')]}"
    exit 0
fi

# ── Install ──────────────────────────────────────────────────────────
START_TIME=$(date +%s)
echo "=== ReadRead HQ engine (Qwen3-TTS): $HQ, model: $MODELS ==="
rr_require_apple_silicon
rr_require_cmds curl tar plutil perl mkfifo
[ -f "$SERVER_DIR/tts_server.py" ] && [ -f "$SERVER_DIR/readread_tts/engine_qwen.py" ] ||
    rr_die "no Qwen-capable server in $SERVER_DIR (set READREAD_TTS_SERVER_DIR)"
rr_check_lock_current "$RR_REPO_DIR/tts_server/requirements-hq.in" "$RR_HQ_LOCK_FILE"
# Only what this script created is ever replaced or deleted (python/, venv/, .tmp below): checked before the lock
# goes in (nothing is written into a folder that is not ours) and again, for good, once it is held.
FOREIGN_HINT="not installing there. Choose an empty or new READREAD_HQ_HOME."
if [ -d "$HQ" ]; then
    check_not_locked
    refuse_foreign "$FOREIGN_HINT"
fi
take_lock
refuse_foreign "$FOREIGN_HINT"
# mark_unfinished, called before the first change to python/, venv/ or a model file: from then until step 6
# install.json is install.json.prev. A run that stops after a change (cancelled, a download or pip failing) leaves an
# install that reads as unfinished (the app: damaged, Repair), never the record of a finished install whose venv or
# model files it was replacing; one that stops before it changed anything leaves the install as it was.
mark_unfinished() {
    if [ -e "$HQ/install.json" ] || [ -L "$HQ/install.json" ]; then
        mv -f "$HQ/install.json" "$HQ/install.json.prev" || rr_die "cannot move $HQ/install.json aside"
    fi
}
rm -rf "$HQ/.tmp"
mkdir -p "$HQ/.tmp" "$HQ/models" || rr_die "cannot create $HQ"

# Enough disk space for what is missing (python and the venv about 700 MB, plus the model files).
# shellcheck disable=SC2086 # $MODELS is a list of model names
NEED=$(hq_missing_bytes $MODELS)
PYTHON_OK=0
if python_ok; then PYTHON_OK=1; fi
if [ "$PYTHON_OK" = 0 ] || [ ! -x "$VENV_PY" ]; then NEED=$((NEED + 700000000)); fi
FREE=$(($(df -Pk "$HQ" | awk 'NR == 2 {print $4}') * 1024))
if [ "$NEED" -gt 0 ] && [ $((NEED + 500000000)) -gt "$FREE" ]; then
    rr_die "not enough disk space on the volume of $HQ: about $(rr_mb "$NEED") MB needed (plus 500 MB to spare), $(rr_mb "$FREE") MB free"
fi

rr_step 1/$STEPS_INSTALL "Standalone Python"
if [ "$PYTHON_OK" = 1 ]; then
    rr_note "CPython $RR_PY_VERSION ($RR_PY_RELEASE) already installed"
else
    if ! rr_file_ok "$RR_CACHE_DIR/downloads/$RR_PY_ASSET" "$RR_PY_SIZE" "$RR_PY_SHA256"; then
        emit_download "$RR_PY_ASSET" 0 "$RR_PY_SIZE"
    fi
    run_child rr_python_tarball >/dev/null || exit 1 # in the background: a signal stops the download at once
    TARBALL="$RR_CACHE_DIR/downloads/$RR_PY_ASSET"
    emit_download "$RR_PY_ASSET" "$RR_PY_SIZE" "$RR_PY_SIZE"
    if [ -e "$HQ/python" ]; then rr_note "replacing $HQ/python (different or unknown version, or modified files)"; fi
    mark_unfinished
    rr_extract_python "$TARBALL" "$HQ/python"
    python_manifest >"$HQ/python/.readread-manifest" || rr_die "cannot list $HQ/python"
    printf '%s\n' "$PY_STAMP" >"$HQ/python/.readread-python"
    rr_note "installed CPython $RR_PY_VERSION ($RR_PY_RELEASE)"
fi

rr_step 2/$STEPS_INSTALL "Virtual environment (requirements-hq.lock)"
if venv_ok; then
    rr_note "venv is up to date with requirements-hq.lock (installed set, every file's sha256 and pip check verified)"
else
    if [ -e "$HQ/venv" ]; then rr_note "rebuilding $HQ/venv (inputs changed, incomplete or modified)"; fi
    mark_unfinished
    rm -rf "$HQ/venv"
    "$PY" -I -m venv "$HQ/venv" 3>&- || rr_die "cannot create the venv in $HQ/venv"
    # In the background: a signal stops pip at once. (rr_pip closes fd 3 for pip, so no pip process holds
    # the JSON stream open; this shell keeps it for the error event.)
    run_child rr_install_lock "$VENV_PY" "$RR_HQ_LOCK_FILE" || exit 1
    venv_matches_lock || rr_die "the new venv does not match requirements-hq.lock"
    venv_stamp >"$HQ/venv/.readread-hq-venv"
    rr_note "installed $(grep -c '^[A-Za-z]' "$RR_HQ_LOCK_FILE") locked packages"
fi

rr_step 3/$STEPS_INSTALL "Model files"
for m in $MODELS; do
    hq_install_model "$m"
done

rr_step 4/$STEPS_INSTALL "Import check"
check_imports "$HQ/.tmp/hf" || rr_die "the qwen engine's modules do not import from $HQ/venv"

rr_step 5/$STEPS_INSTALL "Smoke test: one Chinese sentence through the server"
for m in $MODELS; do
    smoke "$m"
done

rr_step 6/$STEPS_INSTALL "install.json"
# shellcheck disable=SC2086 # $MODELS is a list of model names
write_install_json $MODELS
rm -f "$HQ/install.json.prev" || rr_warn "cannot remove $HQ/install.json.prev"
rm -rf "$HQ/.tmp"
rr_note "$HQ/install.json lists: $("$PY" -I -c 'import json, sys; print(", ".join(json.load(open(sys.argv[1]))["models"]))' "$HQ/install.json")"

echo ""
echo "=== HQ engine installed ($(($(date +%s) - START_TIME)) s): $HQ ==="
echo "  python/  $(du -sh "$HQ/python" | awk '{print $1}')   venv/  $(du -sh "$HQ/venv" | awk '{print $1}')   models/  $(du -sh "$HQ/models" | awk '{print $1}')"
echo "  Run the server: READREAD_TOKEN=\$(openssl rand -hex 32) \"$VENV_PY\" -I -B \"$SERVER_DIR/tts_server.py\" \\"
echo "      --engine qwen --model $MODELS --models-dir \"$HQ/models\" --preload zh,en"
finish "{\"event\":\"done\",\"home\":$(json_str "$HQ"),\"models\":[$(for m in $MODELS; do printf '"%s",' "$m"; done | sed 's/,$//')]}"
