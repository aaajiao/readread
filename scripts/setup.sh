#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# Sets up the development environment that `swift run ReadRead` and the Python tests use:
#
#   ./scripts/setup.sh                 # READREAD_HOME defaults to ~/.readread
#
#   $READREAD_HOME/python/      standalone CPython (python-build-standalone, sha256-verified)
#   $READREAD_HOME/env/         venv: tts_server/requirements.lock + requirements-dev.txt, hash-checked
#   $READREAD_HOME/models/      the four Kokoro model files, sha256-verified
#   $READREAD_HOME/tts_server   symlink to <repo>/tts_server, so the app runs the repo's server code
#   $READREAD_HOME/defuddle/    the Defuddle page reader (defuddle.full.js + LICENSE, npm, sha256-verified),
#                               which `swift run ReadRead` injects into an offscreen web view to read
#                               pages on this Mac (the app bundle carries its own copy)
#
# Idempotent: python/ and env/ record the inputs they were built from and are rebuilt only when
# those change (Python release, lock files) or when env/ no longer holds exactly the locked
# distributions; model files are re-verified on every run and are taken from build/cache/models
# (APFS clone or hardlink, no extra copy) when valid copies are there; defuddle/ is re-verified on
# every run and reinstalled from the cached npm tarball when any file differs from its pin.
#
# Environment: READREAD_HOME (unset means ~/.readread; set but empty is an error, so an unset
# variable in READREAD_HOME=$X never falls back to the real one); READREAD_BUILD_CACHE (download
# cache, default <repo>/build/cache); READREAD_MODELS_SEED (extra colon-separated dirs holding
# verified model copies).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/defuddle.sh
. "$SCRIPT_DIR/lib/defuddle.sh"

if [ "${READREAD_HOME+set}" = set ] && [ -z "$READREAD_HOME" ]; then
    rr_die "READREAD_HOME is set but empty; unset it to use ~/.readread, or give it a path"
fi
RR_HOME="${READREAD_HOME:-$HOME/.readread}"
case "$RR_HOME" in
/?*) ;;
*) rr_die "READREAD_HOME must be an absolute path (got '$RR_HOME')" ;;
esac
START_TIME=$(date +%s)
PY="$RR_HOME/python/bin/python3"
ENV_PY="$RR_HOME/env/bin/python3"

echo "=== ReadRead dev setup: $RR_HOME ==="
rr_require_apple_silicon
rr_require_cmds curl tar openssl
[ -f "$RR_LOCK_FILE" ] && [ -f "$RR_DEV_LOCK_FILE" ] || rr_die "missing lock files (run ./scripts/lock-deps.sh)"
rr_check_lock_current "$RR_REPO_DIR/tts_server/requirements.in" "$RR_LOCK_FILE"
DEV_MISSING=$(printf '%s\n' "$RR_DEV_REQUIREMENTS" | tr ' ' '\n' | rr_pins_missing - "$RR_DEV_LOCK_FILE")
[ -z "$DEV_MISSING" ] || rr_die "$RR_DEV_LOCK_FILE is out of date: it does not pin these from RR_DEV_REQUIREMENTS:
$DEV_MISSING
  Run ./scripts/lock-deps.sh to regenerate it."
mkdir -p "$RR_HOME"

# ── 1. Standalone Python ─────────────────────────────────────────────
rr_step 1/5 "Standalone Python"
PY_STAMP="$RR_PY_VERSION+$RR_PY_RELEASE $RR_PY_SHA256"
if [ -x "$PY" ] && [ "$(cat "$RR_HOME/python/.readread-python" 2>/dev/null)" = "$PY_STAMP" ]; then
    rr_note "CPython $RR_PY_VERSION ($RR_PY_RELEASE) already installed"
else
    TARBALL=$(rr_python_tarball)
    if [ -e "$RR_HOME/python" ]; then rr_note "replacing $RR_HOME/python (different or unknown version)"; fi
    rr_extract_python "$TARBALL" "$RR_HOME/python"
    printf '%s\n' "$PY_STAMP" >"$RR_HOME/python/.readread-python"
    rr_note "installed CPython $RR_PY_VERSION ($RR_PY_RELEASE)"
fi

# ── 2. Virtual environment ───────────────────────────────────────────
rr_step 2/5 "Virtual environment"
ENV_STAMP=$(rr_sha256_string "python=$PY_STAMP lock=$(rr_sha256 "$RR_LOCK_FILE") dev=$(rr_sha256 "$RR_DEV_LOCK_FILE") sdist=$RR_SDIST_PACKAGES recipe=$RR_RUNTIME_RECIPE")
# The stamp says which locks env/ was built from; this checks it still holds them: every locked
# distribution at its locked version, nothing else but pip, and a clean `pip check`.
env_matches_locks() {
    "$ENV_PY" -I -B -c '
import re, sys
from importlib.metadata import distributions
def norm(name):
    return re.sub(r"[-_.]+", "-", name).lower()
want = {}
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as lock:
        for line in lock:
            m = re.match(r"([A-Za-z0-9][A-Za-z0-9._-]*)(?:\[[^\]]*\])?\s*(?:==\s*([^\s;\\]+)|@\s*\S)", line)
            if m:
                want[norm(m.group(1))] = m.group(2)  # None for a URL pin
have = {norm(d.metadata["Name"]): d.version for d in distributions() if d.metadata["Name"]}
problems = [f"{n} is not installed" for n in sorted(set(want) - set(have))]
problems += [f"{n} is {have[n]}, the lock pins {v}" for n, v in sorted(want.items()) if v and n in have and have[n] != v]
problems += [f"{n} {have[n]} is not in the locks" for n in sorted(set(have) - set(want) - {"pip"})]
if problems:
    sys.exit("  env/ does not match the locks: " + "; ".join(problems[:6]) + (" ..." if len(problems) > 6 else ""))
' "$RR_LOCK_FILE" "$RR_DEV_LOCK_FILE" || return 1
    local check
    check=$(rr_pip "$ENV_PY" check 2>&1) || {
        printf '  env/ fails pip check: %s\n' "$check" >&2
        return 1
    }
}
if [ -x "$ENV_PY" ] && [ "$(cat "$RR_HOME/env/.readread-env" 2>/dev/null)" = "$ENV_STAMP" ] &&
    "$ENV_PY" -I -c 'import sys' 2>/dev/null && env_matches_locks; then
    rr_note "env is up to date with requirements.lock and requirements-dev.txt (installed set and pip check verified)"
else
    if [ -e "$RR_HOME/env" ]; then rr_note "rebuilding $RR_HOME/env (inputs changed or incomplete)"; fi
    rm -rf "$RR_HOME/env"
    "$PY" -I -m venv "$RR_HOME/env"
    rr_install_lock "$ENV_PY" "$RR_LOCK_FILE"
    rr_note "dev tools: $(grep -c '^[A-Za-z]' "$RR_DEV_LOCK_FILE") packages from requirements-dev.txt"
    rr_pip "$ENV_PY" install --quiet --progress-bar off --no-warn-script-location \
        --require-hashes --no-deps --only-binary :all: -r "$RR_DEV_LOCK_FILE"
    rr_pip "$ENV_PY" check
    rr_check_runtime_imports "$ENV_PY"
    printf '%s\n' "$ENV_STAMP" >"$RR_HOME/env/.readread-env"
fi

# ── 3. Model files ───────────────────────────────────────────────────
rr_step 3/5 "Model files"
rr_provision_models "$RR_HOME/models" "$RR_CACHE_DIR/models"

# ── 4. Server code ───────────────────────────────────────────────────
rr_step 4/5 "Server code"
LINK="$RR_HOME/tts_server"
TARGET="$RR_REPO_DIR/tts_server"
if [ -L "$LINK" ]; then
    if [ "$(readlink "$LINK")" != "$TARGET" ]; then ln -sfn "$TARGET" "$LINK"; fi
elif [ -e "$LINK" ]; then
    rr_die "$LINK exists and is not a symlink; move it away and re-run"
else
    ln -s "$TARGET" "$LINK"
fi
rr_note "$LINK -> $(readlink "$LINK")"
for legacy in tts_server.py tts-port; do
    if [ -e "$RR_HOME/$legacy" ]; then
        rr_note "note: $RR_HOME/$legacy is left over from the old setup and no longer used (safe to delete)"
    fi
done

# ── 5. Defuddle page reader ──────────────────────────────────────────
rr_step 5/5 "Defuddle page reader"
DEFUDDLE_DIR="$RR_HOME/defuddle"
if rr_defuddle_installed "$DEFUDDLE_DIR"; then
    rr_note "Defuddle $RR_DEFUDDLE_VERSION already installed, every file matches its sha256"
else
    if [ -e "$DEFUDDLE_DIR" ]; then rr_note "replacing $DEFUDDLE_DIR (a file differs from the pin, or is missing or extra)"; fi
    rr_install_defuddle "$DEFUDDLE_DIR"
    rr_note "installed Defuddle $RR_DEFUDDLE_VERSION: $(cd "$DEFUDDLE_DIR" && find . -type f | sed 's|^\./||' | sort | tr '\n' ' ')"
fi

echo ""
echo "=== Setup complete ($(($(date +%s) - START_TIME)) s) ==="
echo "  Python:   $ENV_PY ($("$ENV_PY" -I -c 'import platform; print(platform.python_version())'))"
echo "  Server:   $LINK/tts_server.py"
echo "  Models:   $RR_HOME/models"
echo "  Defuddle: $DEFUDDLE_DIR (page reader $RR_DEFUDDLE_VERSION)"
echo ""
# The app finds this environment through READREAD_HOME when it is not the default ~/.readread.
RUN_ENV=""
if [ "$RR_HOME" != "$HOME/.readread" ]; then RUN_ENV="READREAD_HOME=$RR_HOME "; fi
echo "  Run the app:        ${RUN_ENV}swift run ReadRead"
echo "  Headless check:     ${RUN_ENV}swift run ReadRead --self-test"
echo "  Run Python tests:   $ENV_PY -B -m pytest -q -p no:cacheprovider tts_server/tests"
echo "                      (prefix READREAD_MODELS_DIR=$RR_HOME/models to include the model tests)"
