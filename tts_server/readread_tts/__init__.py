"""ReadRead TTS server package (HTTP API v2): Kokoro v1.1-zh for Chinese, Kokoro v1.0 for English.

Modules: server (HTTP handler), engine (routing, sessions, synthesis), frontend_zh / frontend_en
(normalization and G2P), sentences (clean-up and splitting), lexicon (Chinese reading overrides,
lexicon_zh.json), zhuyin (pinyin <-> misaki symbols), g2p (token-aware phoneme strings), espeak
(short espeak-ng data path), audio (trim, silence, WAV).
"""

API_VERSION = 2
