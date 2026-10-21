#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# Regenerates tools/asr_eval/requirements.lock, the hashed lock of the ASR evaluator's venv, with uv
# (https://docs.astral.sh/uv/) from tools/asr_eval/requirements.in. Target: the CPython 3.12 pinned in
# scripts/lib/versions.sh on macOS arm64, wheels only; asr_eval.sh installs it with pip --require-hashes --no-deps.
#
# usage: tools/asr_eval/lock.sh [--check] [uv pip compile options, e.g. --upgrade-package numpy]
#   --check  regenerate into a temp dir and fail if the committed lock differs (no files written).
set -euo pipefail

TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../scripts/lib/common.sh
. "$TOOL_DIR/../../scripts/lib/common.sh"

CHECK=0
if [ "${1:-}" = "--check" ]; then
    CHECK=1
    shift
fi

rr_require_cmds uv
# From the repo root: uv writes the input path into the lock's annotations.
cd "$RR_REPO_DIR"
IN_FILE="tools/asr_eval/requirements.in"
LOCK_FILE="tools/asr_eval/requirements.lock"
[ -f "$IN_FILE" ] || rr_die "missing $IN_FILE"

OUT="$RR_REPO_DIR/$LOCK_FILE"
if [ "$CHECK" = 1 ]; then
    OUT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rr-asr-lock-check.XXXXXX")
    trap 'rm -rf "$OUT_DIR"' EXIT
    OUT="$OUT_DIR/requirements.lock"
    # Seed the temp output with the committed lock so uv keeps its pins.
    cp "$LOCK_FILE" "$OUT" 2>/dev/null || true
fi

export MACOSX_DEPLOYMENT_TARGET="$RR_MIN_MACOS"
echo "Locking $IN_FILE for CPython $RR_PY_VERSION, macOS arm64 >= $RR_MIN_MACOS (wheels only)..."
uv pip compile "$IN_FILE" --generate-hashes --python-version "$RR_PY_VERSION" --python-platform aarch64-apple-darwin \
    --only-binary :all: --custom-compile-command "./tools/asr_eval/lock.sh" --quiet -o "$OUT" "$@"
echo "  requirements.lock: $(grep -c '^[A-Za-z]' "$OUT") packages"

if [ "$CHECK" = 1 ]; then
    if ! diff -u "$LOCK_FILE" "$OUT"; then
        echo "DRIFT: $LOCK_FILE is out of date; run ./tools/asr_eval/lock.sh" >&2
        exit 1
    fi
    echo "The lock is up to date."
    exit 0
fi
echo "Wrote $LOCK_FILE"
