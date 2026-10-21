"""ReadRead TTS server package (HTTP API v2). Two engines: Kokoro (v1.1-zh for Chinese, v1.0 for English; the
default, bundled with the app) and Qwen3-TTS through MLX (optional, installed by scripts/install-hq.sh).

Modules: server (HTTP handler), engine (the interface both engines implement, shared types), engine_kokoro (routing,
sessions, synthesis), engine_qwen (the Qwen3-TTS engine), frontend_zh / frontend_en (normalization and G2P),
sentences (clean-up and splitting), lexicon (Chinese reading overrides, lexicon_zh.json), zhuyin (pinyin <-> misaki
symbols), g2p (token-aware phoneme strings), espeak (short espeak-ng data path), audio (trims, silence, WAV).
"""

API_VERSION = 2
