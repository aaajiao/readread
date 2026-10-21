"""A stand-in for mlx-audio's Qwen3-TTS model, for tests that run without MLX.

FakeModel.generate() takes mlx-audio's arguments and streams chunks of int(streaming_interval * 12.5) codec tokens,
1920 samples (80 ms at 24 kHz) per token: 3 tokens of near-silence, the speech, 3 more of near-silence. The seed is
whatever mlx.core.random.seed() (fakes/mlx/core.py) or a test's backend last set. Marker words in the text (Latin
words, which both front ends pass through unchanged) script the outcome:

    zzrunaway       never ends: tokens until max_tokens
    zzrunawayonce   a runaway for the sentence's first seed only (sha1 of "voice|text", as the engine derives it)
    zzshort         ends at once: 2 tokens of near-silence, no speech
    zzshortonce     ends at once for the first seed only
    otherwise       3 speech tokens per Han character, 1 per other character but spaces (markers not counted)

The speech is a tone whose pitch depends on the seed, so different seeds give different audio and the same seed
the same audio. FAKE_QWEN_DELAY (seconds) sleeps before each chunk; FAKE_QWEN_LOG names a file that gets one JSON
line per generation (its arguments, the seed, how it ended, the thread).
"""

from __future__ import annotations

import hashlib
import json
import os
import threading
import time
from dataclasses import dataclass

import numpy as np

SAMPLE_RATE = 24000
TOKEN_SAMPLES = 1920
LEAD_TOKENS = TAIL_TOKENS = 3
TOKENS_PER_HAN = 3
SHORT_TOKENS = 2
SPEAKERS = ["serena", "vivian", "uncle_fu", "ryan", "aiden", "ono_anna", "sohee", "eric", "dylan"]
RUNAWAY, RUNAWAY_ONCE, SHORT, SHORT_ONCE = "zzrunaway", "zzrunawayonce", "zzshort", "zzshortonce"

current_seed = 0


def first_seed(text: str, voice: str) -> int:
    return int.from_bytes(hashlib.sha1(f"{voice}|{text}".encode()).digest()[:4], "little") & 0x7FFFFFFF


def speech_tokens(text: str, voice: str, seed: int) -> int | None:
    """Speech tokens for one generation: None for a runaway, -1 for one that ends at once."""
    first = seed == first_seed(text, voice)
    if RUNAWAY in text.replace(RUNAWAY_ONCE, "") or (RUNAWAY_ONCE in text and first):
        return None
    if SHORT in text.replace(SHORT_ONCE, "") or (SHORT_ONCE in text and first):
        return -1
    plain = text
    for marker in (RUNAWAY_ONCE, SHORT_ONCE, RUNAWAY, SHORT):
        plain = plain.replace(marker, "")
    return sum(TOKENS_PER_HAN if "\u3400" <= ch <= "\u9fff" else 1 for ch in plain if not ch.isspace())


def speech_seconds(text: str) -> float:
    """Seconds of speech (without the near-silence around it) the fake makes of a normal text."""
    return speech_tokens(text, "", -1) * TOKEN_SAMPLES / SAMPLE_RATE


def _log(record: dict) -> None:
    path = os.environ.get("FAKE_QWEN_LOG")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")


@dataclass
class Chunk:
    audio: np.ndarray
    token_count: int
    sample_rate: int = SAMPLE_RATE
    is_streaming_chunk: bool = True
    is_final_chunk: bool = False


class FakeModel:
    sample_rate = SAMPLE_RATE

    def __init__(self, delay: float | None = None) -> None:
        self.delay = float(os.environ.get("FAKE_QWEN_DELAY") or 0) if delay is None else delay
        self.tokenizer = None if os.environ.get("FAKE_QWEN_NO_TOKENIZER") else object()
        self.speech_tokenizer = object()
        self.calls: list[dict] = []  # one per generate(): its arguments, the seed, and how it ended
        self.threads: set[int] = set()

    def get_supported_speakers(self) -> list[str]:
        return list(SPEAKERS)

    def generate(self, text, voice=None, lang_code="auto", stream=False, streaming_interval=2.0, max_tokens=None,
                 verbose=False, **kwargs):
        call = {"text": text, "voice": voice, "lang_code": lang_code, "stream": stream,
                "streaming_interval": streaming_interval, "max_tokens": max_tokens, "verbose": verbose,
                "extra": sorted(kwargs), "seed": current_seed, "chunks": 0, "tokens": 0, "finished": False,
                "closed": False}
        self.calls.append(call)
        self.threads.add(threading.get_ident())
        print(f"fake generate: {len(text)} chars", flush=True)  # mlx-audio prints too; never onto the handshake
        return self._stream(call)

    def _stream(self, call: dict):
        text, voice, seed, cap = call["text"], call["voice"], call["seed"], call["max_tokens"]
        speech = speech_tokens(text, voice, seed)
        if speech is None:
            total = cap
        elif speech < 0:
            total, speech = min(cap, SHORT_TOKENS), 0
        else:
            total = min(cap, LEAD_TOKENS + speech + TAIL_TOKENS)
        per_chunk = max(1, int(call["streaming_interval"] * 12.5))
        pitch = 180.0 + seed % 200
        produced = 0
        try:
            while produced < total:
                n = min(per_chunk, total - produced)
                if self.delay:
                    time.sleep(self.delay)
                self.threads.add(threading.get_ident())
                t = np.arange(produced * TOKEN_SAMPLES, (produced + n) * TOKEN_SAMPLES) / SAMPLE_RATE
                tokens = np.arange(produced, produced + n).repeat(TOKEN_SAMPLES)
                speaking = tokens >= LEAD_TOKENS
                if speech is not None:
                    speaking &= tokens < LEAD_TOKENS + speech
                floor = np.random.default_rng(seed + produced).normal(0.0, 3e-5, len(t))
                piece = np.where(speaking, 0.3 * np.sin(2 * np.pi * pitch * t), floor).astype(np.float32)
                produced += n
                call["chunks"] += 1
                call["tokens"] = produced
                yield Chunk(piece, n, is_final_chunk=produced >= total)
            call["finished"] = True
        finally:
            call["closed"] = not call["finished"]
            _log({"event": "generate", **call, "thread": threading.current_thread().name})
