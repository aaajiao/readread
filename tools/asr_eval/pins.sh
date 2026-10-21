# shellcheck shell=bash
# shellcheck disable=SC2034 # settings only, read by asr_eval.sh
# The ASR evaluator's models, each a Hugging Face repo at a pinned commit, downloaded on first use from
# https://huggingface.co/<repo>/resolve/<revision>/<file> into $READREAD_ASR_HOME/models/<dir>/ and checked against
# the bytes and sha256 below on every run. Bytes and sha256 come from the HF API
# (/api/models/<repo>/revision/<revision>?blobs=true): lfs.sha256 for the large files; the small ones were fetched at
# that revision, matched against the API's git blob id, then hashed (2026-10-21).
# They are the files the October 2026 lab measured with (keep/lab/_report/asrSetup.json): Whisper's model.bin is
# sha256 e76620f8…, SenseVoice's model.int8.onnx and tokens.txt are byte-identical to the ones in the sherpa-onnx
# release tarball sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2 (sha256 7d1efa21…), and the CAM++
# speaker model is sha256 aa3cfc16….

ASR_MODELS="whisper sensevoice speaker"

# faster-whisper large-v3-turbo in CTranslate2 format: what faster-whisper 1.2.1 downloads for "large-v3-turbo"
# (mobiuslabsgmbh/faster-whisper-large-v3-turbo, which now redirects to this repo). Run on the CPU with int8.
ASR_WHISPER_REPO="dropbox-dash/faster-whisper-large-v3-turbo"
ASR_WHISPER_REVISION="0a363e9161cbc7ed1431c9597a8ceaf0c4f78fcf"
ASR_WHISPER_DIR="faster-whisper-large-v3-turbo"
# path  bytes  sha256
ASR_WHISPER_FILES="
config.json 2263 b0253ea6c0d3bea6b1e19e91a02acfd3b53f4467362efcb5a3e6b16c9b3a9b7e
model.bin 1617884929 e76620f83d5f5b69efd3d87e3dc180c1bd21df9fbebacfd4335e5e1efcc018da
preprocessor_config.json 340 7ccc62c6f2765af1f3b46c00c9b5894426835a05021c8b9c01eecb6dfb542711
tokenizer.json 2710337 297b13372ac43916285644fb9687add3cc62ee2a1adb60da3dc25cc94c1871fd
vocabulary.json 1068114 c69260f2ab26d659b7c398f9a2b2b48ed0df16c3b47d7326782fd9cba71690c1
"

# SenseVoice-Small int8 (FunAudioLLM, exported for sherpa-onnx), the 2024-07-17 package: punctuation and ITN. (The
# 2025-09-09 package is a Cantonese fine-tune without either.)
ASR_SENSEVOICE_REPO="csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
ASR_SENSEVOICE_REVISION="2365baeacb507f821a0c8120fcee3d484dba7a07"
ASR_SENSEVOICE_DIR="sensevoice-small-int8-2024-07-17"
ASR_SENSEVOICE_FILES="
model.int8.onnx 239233841 c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51
tokens.txt 315894 f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc
"

# 3D-Speaker CAM++ trained on Chinese and English, 16 kHz, 192-dim embeddings: the voice drift metric.
ASR_SPEAKER_REPO="csukuangfj/speaker-embedding-models"
ASR_SPEAKER_REVISION="0743f301363dec56491a490f6d6cbc9d67f9a3bf"
ASR_SPEAKER_DIR="campplus-zh-en"
ASR_SPEAKER_FILES="
3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx 28281164 aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2
"

# Bump when the way the venv is built changes, to rebuild existing ones.
ASR_ENV_RECIPE=1
