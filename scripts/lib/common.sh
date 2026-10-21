# shellcheck shell=bash source-path=SCRIPTDIR
# Shared helpers for build-app.sh, setup.sh and lock-deps.sh. Source it, don't run it.
# Written for the stock macOS /bin/bash (3.2): no associative arrays, no mapfile.
# Functions check their own steps (|| rr_die / return 1): bash ignores set -e inside a function
# that is called from an if/&&/|| condition, so errexit alone is not enough.

set -euo pipefail

RR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RR_REPO_DIR="$(cd "$RR_LIB_DIR/../.." && pwd)"
# shellcheck source=versions.sh
. "$RR_LIB_DIR/versions.sh"

# Download/build cache shared by build-app.sh and setup.sh (gitignored).
RR_CACHE_DIR="${READREAD_BUILD_CACHE:-$RR_REPO_DIR/build/cache}"
# shellcheck disable=SC2034 # read by the scripts that source this file
RR_LOCK_FILE="$RR_REPO_DIR/tts_server/requirements.lock"
# shellcheck disable=SC2034 # read by the scripts that source this file
RR_DEV_LOCK_FILE="$RR_REPO_DIR/tts_server/requirements-dev.txt"
# The optional Qwen3-TTS engine's lock (install-hq.sh; never bundled).
# shellcheck disable=SC2034 # read by the scripts that source this file
RR_HQ_LOCK_FILE="$RR_REPO_DIR/tts_server/requirements-hq.lock"

# ── Output ───────────────────────────────────────────────────────────
# RR_STEP_LABEL names the step in progress, for an EXIT trap's failure message.
RR_STEP_LABEL=""
rr_step() {
    # shellcheck disable=SC2034 # read by build-app.sh's EXIT trap
    RR_STEP_LABEL="[$1] $2"
    printf '\n[%s] %s\n' "$1" "$2"
}
rr_note() { printf '  %s\n' "$*"; }
rr_warn() { printf '  WARNING: %s\n' "$*" >&2; }
rr_die() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

rr_require_cmds() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || rr_die "required command not found: $cmd"
    done
}

rr_require_apple_silicon() {
    [ "$(uname -s)" = "Darwin" ] || rr_die "ReadRead builds on macOS only"
    [ "$(uname -m)" = "arm64" ] || rr_die "ReadRead is Apple Silicon only (uname -m: $(uname -m))"
}

# ── Files and checksums ──────────────────────────────────────────────
rr_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

rr_sha256_string() { printf '%s' "$1" | shasum -a 256 | awk '{print $1}'; }

rr_size() { stat -f %z "$1"; }

# Logical bytes of all regular files under a directory (what a copy or zip carries).
rr_tree_bytes() {
    find "$1" -type f -print0 | xargs -0 stat -f %z | awk '{s += $1} END {printf "%d\n", s}'
}

rr_mb() { awk -v b="$1" 'BEGIN {printf "%.1f", b / 1000000}'; }

# rr_file_ok <path> <bytes> <sha256>: the file exists and matches both.
rr_file_ok() {
    [ -f "$1" ] || return 1
    [ "$(rr_size "$1")" = "$2" ] || return 1
    [ "$(rr_sha256 "$1")" = "$3" ]
}

# rr_tree_manifest <dir>: one sorted line per file under <dir> with its sha256 (symlinks as
# "link <path> -> <target>"), so adding, removing or editing any file changes the output.
rr_tree_manifest() {
    (
        cd "$1" || exit 1
        find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 || exit 1
        find . -type l -print0 | LC_ALL=C sort -z | while IFS= read -r -d '' link; do
            printf 'link %s -> %s\n' "$link" "$(readlink "$link")"
        done
    )
}

# APFS clone when possible (instant, no extra space), else hardlink, else a plain copy.
rr_clone_file() {
    rm -f "$2"
    if cp -c "$1" "$2" 2>/dev/null; then
        echo cloned
    elif ln "$1" "$2" 2>/dev/null; then
        echo hardlinked
    else
        cp "$1" "$2" || return 1
        echo copied
    fi
}

# rr_download <url> <dest> <bytes> <sha256>
# curl → <dest>.part → sha256 check → atomic rename. A mismatch deletes the part and fails.
# A transfer slower than 10 kB/s for 60 s counts as stalled (curl exit 28) and is retried like any
# other error, so a connection that hangs open cannot block the build forever.
rr_download() {
    local url=$1 dest=$2 size=$3 sha=$4 part got progress=-sS
    part="$dest.part"
    if [ -t 2 ]; then progress=--progress-bar; fi
    mkdir -p "$(dirname "$dest")" || rr_die "cannot create $(dirname "$dest")"
    rm -f "$part"
    rr_note "downloading $(basename "$dest") ($(rr_mb "$size") MB): $url"
    if ! curl -fL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 30 \
        --speed-limit 10000 --speed-time 60 "$progress" -o "$part" "$url"; then
        rm -f "$part"
        rr_die "download failed: $url"
    fi
    got=$(rr_sha256 "$part")
    if [ "$got" != "$sha" ]; then
        local got_size
        got_size=$(rr_size "$part")
        rm -f "$part"
        rr_die "checksum mismatch for $url
  expected: $size bytes, sha256 $sha
  got:      $got_size bytes, sha256 $got
  The partial download was deleted; nothing was cached."
    fi
    mv -f "$part" "$dest" || rr_die "cannot move $part into place"
}

# rr_provision <name> <url> <bytes> <sha256> <dest_dir> [seed_dir ...]
# Keeps a verified <dest_dir>/<name>: reuse it if it matches, else take a matching copy from a seed
# dir (clone/hardlink), else download. A cached file with the wrong hash is replaced, never used.
rr_provision() {
    local name=$1 url=$2 size=$3 sha=$4 dir=$5 seed how
    shift 5
    local dest="$dir/$name"
    mkdir -p "$dir" || rr_die "cannot create $dir"
    if [ -e "$dest" ]; then
        if rr_file_ok "$dest" "$size" "$sha"; then
            rr_note "$name: cached, sha256 ok"
            return 0
        fi
        rr_warn "$name in $dir does not match the pinned sha256 (stale or corrupt): replacing it"
        rm -f "$dest" || rr_die "cannot remove $dest"
    fi
    for seed in "$@"; do
        [ -n "$seed" ] && [ -f "$seed/$name" ] || continue
        if rr_file_ok "$seed/$name" "$size" "$sha"; then
            how=$(rr_clone_file "$seed/$name" "$dest.part") || rr_die "cannot copy $seed/$name"
            mv -f "$dest.part" "$dest" || rr_die "cannot move $dest.part into place"
            rr_note "$name: $how from $seed, sha256 ok"
            return 0
        fi
        rr_note "$name: ignoring $seed/$name (does not match the pinned sha256)"
    done
    rr_download "$url" "$dest" "$size" "$sha"
    rr_note "$name: downloaded, sha256 ok"
}

# rr_provision_models <dest_dir> [seed_dir ...]: the four Kokoro model files. Seed dirs come from
# the arguments plus READREAD_MODELS_SEED (colon-separated), e.g. a verified copy elsewhere on disk.
rr_provision_models() {
    local dir=$1 name size sha seed
    shift
    local seeds=("$@")
    while read -r seed; do
        if [ -n "$seed" ]; then seeds+=("$seed"); fi
    done <<<"$(printf '%s' "${READREAD_MODELS_SEED:-}" | tr ':' '\n')"
    while read -r -u 9 name size sha; do
        [ -n "$name" ] || continue
        rr_provision "$name" "$RR_MODEL_BASE_URL/$name" "$size" "$sha" "$dir" ${seeds[@]+"${seeds[@]}"}
    done 9<<<"$RR_MODELS"
}

rr_model_names() { awk 'NF == 3 {print $1}' <<<"$RR_MODELS"; }

# ── Standalone Python ────────────────────────────────────────────────
# Prints the path of the verified python-build-standalone tarball (downloading it if needed).
rr_python_tarball() {
    rr_provision "$RR_PY_ASSET" "$RR_PY_URL" "$RR_PY_SIZE" "$RR_PY_SHA256" "$RR_CACHE_DIR/downloads" >&2
    printf '%s\n' "$RR_CACHE_DIR/downloads/$RR_PY_ASSET"
}

# rr_extract_python <tarball> <dest>: <dest> becomes the tarball's python/ prefix (replaced atomically).
rr_extract_python() {
    local tarball=$1 dest=$2
    local tmp="$dest.partial"
    rm -rf "$tmp" || rr_die "cannot remove $tmp"
    mkdir -p "$tmp" || rr_die "cannot create $tmp"
    tar -xzf "$tarball" -C "$tmp" || rr_die "cannot extract $tarball"
    [ -x "$tmp/python/bin/python3" ] || rr_die "unexpected layout in $tarball (no python/bin/python3)"
    rm -rf "$dest" || rr_die "cannot remove the old $dest"
    mv "$tmp/python" "$dest" || rr_die "cannot move the Python runtime to $dest"
    rmdir "$tmp" || rr_die "cannot remove $tmp"
}

# ── pip, isolated from user/global configuration ─────────────────────
rr_pip() {
    local py=$1
    shift
    (
        local v
        while read -r v; do
            if [ -n "$v" ]; then unset "$v"; fi
        done <<<"$(env | sed -n 's/^\(PIP_[A-Za-z0-9_]*\)=.*/\1/p; s/^\(PYTHON[A-Za-z0-9_]*\)=.*/\1/p')"
        export PIP_CONFIG_FILE=/dev/null PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_INPUT=1 PYTHONNOUSERSITE=1
        export PIP_CACHE_DIR="$RR_CACHE_DIR/pip"
        # Not on fd 3: install-hq.sh's JSON stream (a pip build subprocess must not hold it open).
        exec "$py" -I -B -m pip "$@" 3>&-
    )
}

# rr_pins_missing <requirements> <lock>: prints each top-level pin of <requirements> (name==version or
# name @ url; extras and markers ignored, names PEP 503-normalized) that <lock> does not pin the same
# way. Offline and cheap; ./scripts/lock-deps.sh --check is the full check (it needs uv and the network).
rr_pins_missing() {
    awk '
        function norm(s) { sub(/\[.*$/, "", s); gsub(/[ \t]/, "", s); s = tolower(s); gsub(/[-_.]+/, "-", s); return s }
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        function key(line,   p) {
            sub(/[ \t]*\\$/, "", line); sub(/[ \t]+#.*$/, "", line); sub(/[ \t]*;.*$/, "", line)
            if ((p = index(line, " @ ")) > 0) return norm(substr(line, 1, p - 1)) " @ " trim(substr(line, p + 3))
            if ((p = index(line, "==")) > 0) return norm(substr(line, 1, p - 1)) "==" trim(substr(line, p + 2))
            return ""
        }
        FNR == NR { if ($0 ~ /^[A-Za-z0-9]/ && (k = key($0)) != "") want[++n] = k; next }
        $0 ~ /^[A-Za-z0-9]/ && (k = key($0)) != "" { have[k] = 1 }
        END { for (i = 1; i <= n; i++) if (!(want[i] in have)) print "  " want[i] }
    ' "$1" "$2"
}

# rr_check_lock_current <requirements> <lock>: fails unless <lock> pins everything <requirements> does.
rr_check_lock_current() {
    local missing
    [ -f "$1" ] || rr_die "missing $1"
    [ -f "$2" ] || rr_die "missing $2 (run ./scripts/lock-deps.sh)"
    missing=$(rr_pins_missing "$1" "$2") || rr_die "cannot compare $1 with $2"
    [ -z "$missing" ] || rr_die "$2 is out of date: it does not pin these from $1:
$missing
  Run ./scripts/lock-deps.sh to regenerate it."
}

# Print one package's requirement (with its --hash continuation lines) from a uv-generated lock.
rr_lock_block() {
    awk -v pkg="$2" '
        !found && tolower($0) ~ ("^" pkg "==") { found = 1 }
        found { print; if ($0 !~ /\\$/) exit }
    ' "$1"
}

# rr_install_lock <python> <lock> [extra pip install args...]
# Hash-checked, no dependency resolution, wheels only except RR_SDIST_PACKAGES, which are built
# without network access to build tools (--no-build-isolation) by the locked RR_BUILD_BACKEND.
rr_install_lock() {
    local py=$1 lock=$2
    shift 2
    [ -f "$lock" ] || rr_die "lock file not found: $lock"
    local backend_req sdists
    backend_req=$(mktemp "${TMPDIR:-/tmp}/rr-build-backend.XXXXXX") || rr_die "mktemp failed"
    rr_lock_block "$lock" "$RR_BUILD_BACKEND" >"$backend_req" || rr_die "cannot read $lock"
    grep -q -- '--hash=sha256:' "$backend_req" ||
        rr_die "$RR_BUILD_BACKEND is not pinned with hashes in $lock (needed to build: $RR_SDIST_PACKAGES)"
    sdists=$(printf '%s' "$RR_SDIST_PACKAGES" | tr ' ' ',')
    rr_note "pass 1/2: build backend ($(head -1 "$backend_req" | awk '{print $1}'))"
    if ! rr_pip "$py" install --quiet --progress-bar off --no-warn-script-location \
        --require-hashes --no-deps --only-binary :all: "$@" -r "$backend_req"; then
        rm -f "$backend_req"
        rr_die "pip could not install the build backend from $lock"
    fi
    rm -f "$backend_req"
    rr_note "pass 2/2: $(grep -c '^[A-Za-z]' "$lock") locked packages (sdist builds: $RR_SDIST_PACKAGES)"
    # Order matters: --only-binary :all: first, then the --no-binary exceptions.
    rr_pip "$py" install --quiet --progress-bar off --no-warn-script-location \
        --require-hashes --no-deps --only-binary :all: --no-binary "$sdists" --no-build-isolation "$@" -r "$lock" ||
        rr_die "pip could not install $lock (hash mismatch, network or build failure; see above)"
    rr_pip "$py" check || rr_die "pip check found inconsistent requirements after installing $lock"
}

# Imports every top-level runtime dependency of the TTS server (no bytecode written).
rr_check_runtime_imports() {
    "$1" -I -B -W ignore -c '
import kokoro_onnx, onnxruntime, numpy, soundfile
import misaki.zh, misaki.en, misaki.espeak, misaki.zh_frontend
import spacy, en_core_web_sm, opencc, jieba, jieba.posseg, pypinyin, pypinyin_dict, cn2an, num2words
import phonemizer, espeakng_loader
from importlib.metadata import version
print("  imports ok: kokoro-onnx %s, onnxruntime %s, misaki %s, spacy %s, numpy %s" % tuple(
    version(d) for d in ("kokoro-onnx", "onnxruntime", "misaki", "spacy", "numpy")))
'
}
