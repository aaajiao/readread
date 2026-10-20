# shellcheck shell=bash
# shellcheck disable=SC2034 # settings only, read by the scripts that source lib/common.sh
# Pinned inputs shared by build-app.sh, setup.sh and lock-deps.sh (sourced via lib/common.sh).
# Every download is verified against the sha256 below before it is used or cached.

# ── Standalone CPython (astral-sh/python-build-standalone) ───────────
# misaki 0.9.4 requires Python < 3.13, so the runtime stays on 3.12.x.
RR_PY_VERSION="3.12.15"
RR_PY_RELEASE="20261013"
RR_PY_ASSET="cpython-${RR_PY_VERSION}+${RR_PY_RELEASE}-aarch64-apple-darwin-install_only.tar.gz"
RR_PY_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${RR_PY_RELEASE}/${RR_PY_ASSET}"
RR_PY_SIZE=25180390
RR_PY_SHA256="ba32036ad8f4c434d97a1ee7feef8b7edc0fac16777639b97e39c74a108e4440"

# ── Python dependency policy (tts_server/requirements.lock) ──────────
# Everything installs from wheels, except these pure-Python packages that publish only an sdist.
# They are built offline (--no-build-isolation) with the setuptools pinned in the lock, so the
# whole install is hash-checked. lock-deps.sh resolves with the same policy, so a new sdist-only
# dependency fails there instead of silently building at install time.
RR_SDIST_PACKAGES="docopt jieba"
RR_BUILD_BACKEND="setuptools"
# Dev-only tools for the setup.sh environment (never bundled); lock-deps.sh hashes them into
# tts_server/requirements-dev.txt, constrained by requirements.lock.
RR_DEV_REQUIREMENTS="pytest==9.1.1"
# Bump when the way the runtime is installed changes, to invalidate cached runtimes.
RR_RUNTIME_RECIPE=1

# ── Model files (kokoro-onnx release model-files-v1.1) ───────────────
RR_MODEL_BASE_URL="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1"
# name  bytes  sha256
RR_MODELS="
kokoro-v1.1-zh.fp16.onnx 163528759 a628ea5d6fbde96d1a85f691a6a00847829937f9e488021ba2c5359bc6ea08b5
voices-v1.1-zh.bin 53815880 14cb6186c99e4f6016871405f62046c5df863ae27465cbdc4ee08be7dd703acd
kokoro-v1.0.fp16.onnx 163527961 f3a290d384fbb27966d462905c71a46cef9e5fd00516b40df32a0b4afe77ac96
voices-v1.0.bin 28214398 bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d
"

# Minimum macOS for the app (Info.plist LSMinimumSystemVersion; also the wheel target in lock-deps.sh).
RR_MIN_MACOS="26.0"
