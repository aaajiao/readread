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

# ── Defuddle (npm, MIT): the page reader the app runs in an offscreen web view ──
# The npm tarball of defuddle 0.19.5. RR_DEFUDDLE_INTEGRITY is npm's dist.integrity (sha512 of the
# tarball), checked against https://registry.npmjs.org/defuddle/0.19.5 on 2026-10-21; the sha256
# values were computed from that verified tarball. Installed: the browser build with Markdown
# conversion (the package's "./full" export, a UMD bundle that defines the global `Defuddle`) and the
# license, into Contents/Resources/defuddle/ (build-app.sh) and $READREAD_HOME/defuddle/ (setup.sh).
RR_DEFUDDLE_VERSION="0.19.5"
RR_DEFUDDLE_TARBALL="defuddle-${RR_DEFUDDLE_VERSION}.tgz"
RR_DEFUDDLE_URL="https://registry.npmjs.org/defuddle/-/${RR_DEFUDDLE_TARBALL}"
RR_DEFUDDLE_SIZE=659138
RR_DEFUDDLE_SHA256="1cbe156e923f38be0e3dc36bb22d1e20d708349b17fd26bb8136b221451f4ae4"
RR_DEFUDDLE_INTEGRITY="sha512-WpgFv5TWA8s8bWRXMb+tosdEbdeZwgrKYw+BQiuTQfQc4XdCm69Yq/76Lzgvr0ALC1VxZcMWwjNGGgIstcxUtw=="
# path in the tarball  bytes  sha256  installed name
RR_DEFUDDLE_FILES="
package/dist/index.full.js 768702 742844b87a8b1f7fe93f00dcf4ecac243444e298562433995382e23b0f0e55eb defuddle.full.js
package/LICENSE 1076 c63e6774d9c9da3de01428e0809080c4758de3636c8e9e6fe51525c9ab4cd092 LICENSE
"

# Minimum macOS for the app (Info.plist LSMinimumSystemVersion; also the wheel target in lock-deps.sh).
RR_MIN_MACOS="26.0"

# ── Optional high-quality engine: Qwen3-TTS through MLX (install-hq.sh) ──
# Installed outside the app into $READREAD_HQ_HOME (python/ = the CPython above, venv/ from
# tts_server/requirements-hq.lock, models/<repo name>/). Each model is a Hugging Face repo at a
# pinned commit, downloaded from https://huggingface.co/<repo>/resolve/<revision>/<file>. Bytes and
# sha256 per file come from the HF API (/api/models/<repo>/revision/<revision>?blobs=true): lfs.sha256
# for the weights; the small files were fetched at that revision, matched against the API's git
# blob id, then hashed (2026-10-20). speech_tokenizer/model.safetensors is byte-identical in both
# repos, so install-hq.sh stores it once and hardlinks it.
RR_HQ_MODELS="1.7b 0.6b"
RR_HQ_DEFAULT_MODEL="1.7b"
RR_HQ_1_7B_REPO="mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit"
RR_HQ_1_7B_REVISION="41d3337e8b7f2843a75841595fc14e4b9a7a4b96"
# path  bytes  sha256
RR_HQ_1_7B_FILES="
README.md 1118 50fe8f13fc95466beb50a96ae743e40573512754e80330373a043f4bd34d6212
config.json 6058 43f29f9ab55cf387bd2ce1d07e9d95a5ca8974fa2fda4e2b45c13ae64aad3bfa
generation_config.json 245 f1b90b4513f3b34c62851049e2492d7b4c5940daf1276f89c82b8ef04127f3aa
merges.txt 1671839 599bab54075088774b1733fde865d5bd747cbcc7a547c5bc12610e874e26f5e3
model.safetensors 2393308931 b696f4bf45f54497b6de758981e76f1410bd68af05a657477dee466b0202df1a
model.safetensors.index.json 71786 2551ed02dc288b90cd6b7ec98652433f08ef2ae98fb3eda5248a4b9e5b47d08b
preprocessor_config.json 127 efdde1022ea9d76928bf7a9cd53139138f5ba2e466e837f08f6105ab1af1c119
speech_tokenizer/config.json 2336 ee65bb901c876664ab8707c487157aa1a6ee57c65969b28fb5ec9dc211e68167
speech_tokenizer/configuration.json 76 6bc26d64eb5024b4d1dab5a52371958b429256d6c9d59787f1f5294a54e0cebd
speech_tokenizer/model.safetensors 682293092 836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258
speech_tokenizer/preprocessor_config.json 234 fcb3805e597e786d4067706e602f6688524640f8d3396790e2e09b5942fcbdfb
tokenizer_config.json 7344 dc3c31c3bdaedd5016382bb3cbe07323026775ad51f5a4fb564505992ae4a670
vocab.json 2776833 ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910
"
RR_HQ_0_6B_REPO="mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit"
RR_HQ_0_6B_REVISION="049ef77fe8816b536193c0c25f9a214d17921282"
RR_HQ_0_6B_FILES="
README.md 1068 43eb391246ca355e5eaa3fa74b8f9a433dd48d68cdec1e04321f9c1b2c9fd855
config.json 6058 2eea3665564268139c3beb8d497fd3c2e4524e9eed5452836cdf1de96ed3cdbd
generation_config.json 245 f1b90b4513f3b34c62851049e2492d7b4c5940daf1276f89c82b8ef04127f3aa
merges.txt 1671839 599bab54075088774b1733fde865d5bd747cbcc7a547c5bc12610e874e26f5e3
model.safetensors 1286743170 3bcb2c4a127e6243e81a30b7126c7865f686d3559de4f938e5d3b150c6a9560d
model.safetensors.index.json 71447 0c92041960fa189cf35ae538c8d9ca07c468edddd0c9bb52274c5d4d287a860b
preprocessor_config.json 127 efdde1022ea9d76928bf7a9cd53139138f5ba2e466e837f08f6105ab1af1c119
speech_tokenizer/config.json 2336 ee65bb901c876664ab8707c487157aa1a6ee57c65969b28fb5ec9dc211e68167
speech_tokenizer/configuration.json 76 6bc26d64eb5024b4d1dab5a52371958b429256d6c9d59787f1f5294a54e0cebd
speech_tokenizer/model.safetensors 682293092 836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258
speech_tokenizer/preprocessor_config.json 234 fcb3805e597e786d4067706e602f6688524640f8d3396790e2e09b5942fcbdfb
tokenizer_config.json 7344 dc3c31c3bdaedd5016382bb3cbe07323026775ad51f5a4fb564505992ae4a670
vocab.json 2776833 ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910
"
# Bump when the way the HQ venv is installed changes, to rebuild existing venvs.
RR_HQ_RECIPE=1
