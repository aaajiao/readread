#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# Regenerates the hashed Python locks for the TTS server with uv (https://docs.astral.sh/uv/):
#   tts_server/requirements.in  (top-level pins, edit this)  →  tts_server/requirements.lock
#   RR_DEV_REQUIREMENTS in scripts/lib/versions.sh             →  tts_server/requirements-dev.txt
#   tts_server/requirements-hq.in (the optional Qwen3-TTS engine) → tts_server/requirements-hq.lock
# Target: the pinned CPython 3.12 on macOS arm64 (scripts/lib/versions.sh). The locks carry the
# hashes of every published file of each pinned version; build-app.sh and setup.sh install them
# with pip --require-hashes --no-deps (see rr_install_lock in scripts/lib/common.sh), and
# install-hq.sh installs the HQ lock the same way. The dev and HQ locks are constrained by
# requirements.lock, so a package they share with it keeps its pin there.
#
# usage: scripts/lock-deps.sh [--check] [uv pip compile options, e.g. --upgrade-package spacy]
#   Existing pins are kept unless an --upgrade/--upgrade-package option asks otherwise.
#   --check  regenerate into a temp dir and fail if the committed locks differ (no files written).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

CHECK=0
if [ "${1:-}" = "--check" ]; then
    CHECK=1
    shift
fi

rr_require_cmds uv
# Run from the repo root: uv writes the input paths into the lock annotations.
cd "$RR_REPO_DIR"
IN_FILE="tts_server/requirements.in"
LOCK_REL="tts_server/requirements.lock"
HQ_IN_FILE="tts_server/requirements-hq.in"
[ -f "$IN_FILE" ] || rr_die "missing $IN_FILE"
[ -f "$HQ_IN_FILE" ] || rr_die "missing $HQ_IN_FILE"

OUT_DIR="$RR_REPO_DIR/tts_server"
if [ "$CHECK" = 1 ]; then
    OUT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rr-lock-check.XXXXXX")
    trap 'rm -rf "$OUT_DIR"' EXIT
    # Seed the temp outputs with the committed locks so uv keeps their pins.
    cp "$RR_LOCK_FILE" "$OUT_DIR/requirements.lock" 2>/dev/null || true
    cp "$RR_DEV_LOCK_FILE" "$OUT_DIR/requirements-dev.txt" 2>/dev/null || true
    cp "$RR_HQ_LOCK_FILE" "$OUT_DIR/requirements-hq.lock" 2>/dev/null || true
fi

# Same install policy as rr_install_lock: wheels only, except the known sdist-only packages.
BINARY_POLICY=(--only-binary :all:)
for pkg in $RR_SDIST_PACKAGES; do
    BINARY_POLICY+=(--no-binary "$pkg")
done
# Wheels must run on the app's minimum macOS.
export MACOSX_DEPLOYMENT_TARGET="$RR_MIN_MACOS"
COMMON=(--generate-hashes --python-version "$RR_PY_VERSION" --python-platform aarch64-apple-darwin
    --custom-compile-command "./scripts/lock-deps.sh" --quiet "${BINARY_POLICY[@]}")

echo "Locking tts_server/requirements.in for CPython $RR_PY_VERSION, macOS arm64 >= $RR_MIN_MACOS..."
uv pip compile "$IN_FILE" "${COMMON[@]}" -o "$OUT_DIR/requirements.lock" "$@"

echo "Locking dev tools ($RR_DEV_REQUIREMENTS), constrained by requirements.lock..."
# uv reads the top-level dev spec from stdin; the runtime lock pins anything both need.
# (--check constrains by the committed lock; its own diff above catches a stale runtime lock.)
printf '%s\n' "$RR_DEV_REQUIREMENTS" |
    uv pip compile - "${COMMON[@]}" -c "$LOCK_REL" -o "$OUT_DIR/requirements-dev.txt" "$@"

echo "Locking tts_server/requirements-hq.in (Qwen3-TTS engine), constrained by requirements.lock..."
uv pip compile "$HQ_IN_FILE" "${COMMON[@]}" -c "$LOCK_REL" -o "$OUT_DIR/requirements-hq.lock" "$@"

if grep -qi '^phonemizer-fork' "$OUT_DIR/requirements.lock"; then
    rr_die "phonemizer-fork entered the lock (it clashes with phonemizer; was misaki[en] added?)"
fi
# The qwen route imports none of the Kokoro runtime (an import-set probe decided the HQ inputs).
KOKORO_ONLY=$(grep -i -o -E '^(onnxruntime|kokoro-onnx|spacy|en-core-web-sm|phonemizer|phonemizer-fork|espeakng-loader)( |==|@)' \
    "$OUT_DIR/requirements-hq.lock" | tr -d ' =@' | tr '\n' ' ' || true)
if [ -n "$KOKORO_ONLY" ]; then
    rr_die "requirements-hq.lock pulls in Kokoro-only packages: $KOKORO_ONLY(check what in requirements-hq.in needs them)"
fi

echo "  requirements.lock:     $(grep -c '^[A-Za-z]' "$OUT_DIR/requirements.lock") packages"
echo "  requirements-dev.txt:  $(grep -c '^[A-Za-z]' "$OUT_DIR/requirements-dev.txt") packages"
echo "  requirements-hq.lock:  $(grep -c '^[A-Za-z]' "$OUT_DIR/requirements-hq.lock") packages"

if [ "$CHECK" = 1 ]; then
    status=0
    for f in requirements.lock requirements-dev.txt requirements-hq.lock; do
        if ! diff -u "$RR_REPO_DIR/tts_server/$f" "$OUT_DIR/$f"; then
            echo "DRIFT: tts_server/$f is out of date; run ./scripts/lock-deps.sh" >&2
            status=1
        fi
    done
    if [ "$status" = 0 ]; then echo "Locks are up to date."; fi
    exit "$status"
fi
echo "Wrote tts_server/requirements.lock, tts_server/requirements-dev.txt and tts_server/requirements-hq.lock"
