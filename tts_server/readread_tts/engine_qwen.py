"""The Qwen3-TTS engine (--engine qwen): Qwen3-TTS-12Hz CustomVoice 8-bit on the GPU through MLX (mlx-audio 0.6.0).

It is optional and lives outside the app: scripts/install-hq.sh builds its venv (requirements-hq.lock) and puts the
model folder in $READREAD_HQ_HOME/models. One model, 1.7b (--model's only value, and its default). Two voices,
preset speakers of the CustomVoice model: "serena" reads Chinese (and the English words in it), "aiden" reads
English. The model has no speed control, so synthesis always runs at speed 1.0 and the client changes the playback
rate (synth_speed in the response).

Per sentence (sentences.clean/split as for Kokoro): frontend_zh.normalize or frontend_en.normalize, a terminal stop for
lines without one (it steadies the length of short headings), then one streaming generation. Generation is always
streamed, also for one whole sentence: non-streaming decoding lets MLX's buffer cache grow to 9-15 GB, streaming stays
near 4 GB. The seed comes from a hash of voice and text, so a sentence always comes back as the same audio. A
generation is capped at 12.5 * (0.5 * len(text) + 3) tokens (12.5 tokens per second of audio) and is retried with
another seed when it runs away (longer than 2.5 times a rough expected length plus 1 s, or hitting the cap) or ends
far too early (shorter than 0.3 times the expected length). Silence around each sentence is trimmed like Kokoro's
tail; sentences are joined with 250 ms of silence. Only sentence timings are reported (tokens is empty).

All MLX work runs on one long-lived thread (MLX keeps per-thread state; the HTTP server serves each connection on a
thread of its own). Cancellation is checked between streamed chunks (every 0.32 s of audio) and between sentences.
Importing this module imports neither MLX nor mlx-audio; Engine.load() does. It switches Hugging Face to offline mode
for the whole process: the model is local, and nothing at runtime may reach the network.
"""

from __future__ import annotations

import hashlib
import logging
import os
import queue
import re
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from . import audio, frontend_en, frontend_zh, sentences
from .engine import QWEN_MODELS, SENTENCE_GAP_S, SILENT_S, Cancelled, Synthesis, Voice, VoiceError, package_versions

# Read by huggingface_hub and transformers when they are imported, which only Engine.load() does.
OFFLINE_ENV = {"HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1"}
os.environ.update(OFFLINE_ENV)

log = logging.getLogger("readread.engine")

ROUTES = ("zh", "en")
# --model -> the model folder in --models-dir (the Hugging Face repo name; scripts/lib/versions.sh pins the revision).
MODELS = {"1.7b": "Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit"}
# The files the engine reads and their sizes in bytes. install-hq.sh verifies their sha256 (scripts/lib/versions.sh);
# the server only checks that they are there with the right size.
MODEL_FILES = {
    "1.7b": {"config.json": 6058, "model.safetensors": 2393308931, "model.safetensors.index.json": 71786,
             "generation_config.json": 245, "merges.txt": 1671839, "preprocessor_config.json": 127,
             "tokenizer_config.json": 7344, "vocab.json": 2776833, "speech_tokenizer/config.json": 2336,
             "speech_tokenizer/configuration.json": 76, "speech_tokenizer/model.safetensors": 682293092,
             "speech_tokenizer/preprocessor_config.json": 234},
}
VOICES = {"zh": ["serena"], "en": ["aiden"]}
_ROUTE_OF = {voice: route for route, voices in VOICES.items() for voice in voices}
LANG_CODES = {"zh": "chinese", "en": "english"}  # mlx-audio's language names

FRAME_HZ = 12.5  # codec tokens per second of audio (Qwen3-TTS-Tokenizer-12Hz)
STREAM_INTERVAL_S = 0.32  # audio per streamed chunk: 4 tokens
MAX_ATTEMPTS = 3  # the first generation and up to two retries with other seeds
RUNAWAY_FACTOR, RUNAWAY_EXTRA_S = 2.5, 1.0
SHORT_FACTOR = 0.3
CACHE_LIMIT = 1 << 30  # bytes MLX may keep in its buffer cache
_WARMUP = {"zh": ("你好。", "serena"), "en": ("Hello.", "aiden")}

_FINAL = "。！？.!?…"
_CLOSERS = "\"'”’」』）)]】》"
_CLAUSE = "，、：；,:;"
_HAN_RE = re.compile(r"[㐀-鿿豈-﫿]")
_WORD_RE = re.compile(r"[A-Za-z]+")
_DIGIT_RE = re.compile(r"\d")


def check_models(models_dir: str, model: str) -> list[str]:
    """Human-readable problems with the model folder of `model` in models_dir (empty if every file is there with the
    right size)."""
    if not os.path.isdir(models_dir):
        return [f"models directory not found: {models_dir} (run ./scripts/install-hq.sh)"]
    folder = os.path.join(models_dir, MODELS[model])
    if not os.path.isdir(folder):
        return [f"model folder not found: {folder} (run ./scripts/install-hq.sh)"]
    problems = []
    for name, size in MODEL_FILES[model].items():
        path = os.path.join(folder, name)
        if not os.path.isfile(path):
            problems.append(f"missing model file {path}")
        elif os.path.getsize(path) != size:
            problems.append(f"{path} is {os.path.getsize(path)} bytes, expected {size}")
    if problems:
        problems[-1] += " (re-run ./scripts/install-hq.sh)"
    return problems


def terminal_stop(text: str) -> str:
    """text ending with a sentence-final mark: kept when it has one (also inside closing quotes or brackets); a
    trailing clause mark becomes 。 (with Han characters) or "."; otherwise one is appended."""
    s = text.rstrip()
    body = s.rstrip(_CLOSERS)
    if not body or body[-1] in _FINAL:
        return s
    stop = "。" if _HAN_RE.search(s) else "."
    if body == s:
        s = s.rstrip(_CLAUSE).rstrip()
    return s + stop


def text_seed(text: str, voice: str) -> int:
    """The sampling seed of a sentence: a hash of voice and text, so the same sentence always sounds the same."""
    return int.from_bytes(hashlib.sha1(f"{voice}|{text}".encode()).digest()[:4], "little") & 0x7FFFFFFF


def next_seed(seed: int) -> int:
    return (seed * 1103515245 + 12345) & 0x7FFFFFFF


def expected_seconds(text: str) -> float:
    """A rough spoken length, only used to recognize runaway or truncated generations."""
    return (0.25 * len(_HAN_RE.findall(text)) + 0.32 * len(_WORD_RE.findall(text))
            + 0.28 * len(_DIGIT_RE.findall(text)) + 0.3)


def max_tokens(text: str) -> int:
    return int(FRAME_HZ * (0.5 * len(text) + 3))


@dataclass
class _Attempt:
    audio: np.ndarray  # trimmed
    duration: float  # seconds generated, before trimming
    seed: int
    tokens: int
    runaway: bool  # stopped past the length limit, or at the token cap without an end of speech


# transformers logs this on every load of the model (mlx-audio reads its config, whose model_type transformers does
# not know, through the generic config class). It is expected, and in the log tail of a crash message it would read
# like the cause; nothing else from transformers is dropped.
EXPECTED_CONFIG_WARNING = "You are using a model of type `qwen3_tts` to instantiate a model of type ``."


class _DropExpectedConfigWarning(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        return not record.getMessage().startswith(EXPECTED_CONFIG_WARNING)


_DROP_EXPECTED_CONFIG_WARNING = _DropExpectedConfigWarning()


def quiet_expected_warnings() -> None:
    """Drop transformers' warning about the model's config type (idempotent; imports nothing)."""
    logging.getLogger("transformers.configuration_utils").addFilter(_DROP_EXPECTED_CONFIG_WARNING)


class MLXBackend:
    """The real model: MLX and mlx-audio, imported when the model loads."""

    def load(self, path: str):
        import mlx.core as mx
        from mlx_audio.tts.utils import load_model

        quiet_expected_warnings()
        mx.set_cache_limit(CACHE_LIMIT)
        model = load_model(Path(path))  # a Path is never looked up on the Hub
        # mlx-audio logs a failure to load either tokenizer as a warning and carries on without it.
        for part in ("tokenizer", "speech_tokenizer"):
            if getattr(model, part, None) is None:
                raise RuntimeError(f"mlx-audio could not load the {part.replace('_', ' ')} from {path} "
                                   "(see the warning above)")
        if model.sample_rate != audio.SAMPLE_RATE:
            raise RuntimeError(f"{path} produces {model.sample_rate} Hz audio, expected {audio.SAMPLE_RATE}")
        missing = [v for v in _ROUTE_OF if v not in model.get_supported_speakers()]
        if missing:
            raise RuntimeError(f"{path} has no speaker {', '.join(missing)}")
        return model

    def seed(self, seed: int) -> None:
        import mlx.core as mx

        mx.random.seed(seed)

    def clear_cache(self) -> None:
        import mlx.core as mx

        mx.clear_cache()


class _Worker:
    """Runs calls on one long-lived thread and hands back their result or exception."""

    def __init__(self, name: str) -> None:
        self._name = name
        self._jobs: queue.SimpleQueue = queue.SimpleQueue()
        self._thread: threading.Thread | None = None
        self._start_lock = threading.Lock()

    def call(self, function: Callable, *args):
        if threading.current_thread() is self._thread:
            return function(*args)
        with self._start_lock:
            if self._thread is None:
                self._thread = threading.Thread(target=self._run, name=self._name, daemon=True)
                self._thread.start()
        done = threading.Event()
        box: dict = {}
        self._jobs.put((function, args, done, box))
        done.wait()
        if "error" in box:
            raise box["error"]
        return box["result"]

    def _run(self) -> None:
        while True:
            function, args, done, box = self._jobs.get()
            try:
                box["result"] = function(*args)
            except BaseException as error:  # noqa: BLE001 - handed to the caller
                box["error"] = error
            finally:
                done.set()


class Engine:
    name = "qwen"

    def __init__(self, models_dir: str, model: str, cache_dir: str, backend=None) -> None:
        if model not in QWEN_MODELS:
            raise ValueError(f"unknown model {model!r}")
        self.model = model
        self.model_path = os.path.join(models_dir, MODELS[model])
        self.cache_dir = cache_dir
        self.lock = threading.Lock()  # held by callers around load() and synthesize()
        self._backend = backend or MLXBackend()
        self._worker = _Worker("mlx")
        self._tts = None  # the loaded model
        self._warm: set[str] = set()
        # Whatever Hugging Face code still wants to cache goes into our cache directory, never ~/.cache/huggingface.
        os.environ["HF_HOME"] = os.path.join(cache_dir, "hf")

    def versions(self) -> dict[str, str]:
        return package_versions(mlx="mlx", mlx_audio="mlx-audio", transformers="transformers", misaki="misaki")

    # --- voices -------------------------------------------------------------------------------------

    def voice_lists(self) -> dict[str, list[str]]:
        return {route: list(voices) for route, voices in VOICES.items()}

    def resolve(self, voice_id: str, lang: str | None = None) -> Voice:
        """The voice for a request; lang ("zh", "en", "en-us", "en-gb") must agree with its language."""
        route = _ROUTE_OF.get(voice_id)
        if route is None:
            raise VoiceError("unknown_voice", f"unknown voice {voice_id!r}; GET /voices lists the available ones")
        if lang is not None and (lang == "zh") != (route == "zh"):
            raise VoiceError("voice_language_mismatch", f"voice {voice_id!r} speaks {route}, not {lang}")
        return Voice(voice_id, route)

    # --- loading ------------------------------------------------------------------------------------

    def loaded(self) -> list[str]:
        return [r for r in ROUTES if r in self._warm]

    def load(self, route: str) -> None:
        """Load the model (once) and run one warm-up synthesis for the route. Idempotent."""
        self._worker.call(self._load, route)

    def _load(self, route: str) -> None:
        if route in self._warm:
            return
        started = time.perf_counter()
        if self._tts is None:
            self._tts = self._backend.load(self.model_path)
            log.info("model %s loaded from %s in %.2f s", self.model, self.model_path, time.perf_counter() - started)
        self._warm.add(route)
        text, voice = _WARMUP[route]
        try:
            self._synthesize(text, self.resolve(voice), None)
        except BaseException:
            self._warm.discard(route)
            raise
        log.info("route %s ready in %.2f s", route, time.perf_counter() - started)

    # --- synthesis ----------------------------------------------------------------------------------

    def synthesize(self, text: str, voice: Voice, speed: float = 1.0,
                   cancelled: Callable[[], bool] | None = None) -> Synthesis:
        """Synthesize text sentence by sentence at speed 1.0 (`speed` is the client's to apply: synth_speed is
        1.0). Raises Cancelled when cancelled() turns true between sentences or streamed chunks. Text with nothing to
        say comes back as 150 ms of silence with silent=True. A sentence the front end fails on is logged and
        skipped; if nothing is left to say, the first such error is raised."""
        return self._worker.call(self._synthesize, text, voice, cancelled)

    def _synthesize(self, text: str, voice: Voice, cancelled: Callable[[], bool] | None) -> Synthesis:
        if voice.route not in self._warm:
            log.info("loading route %s on demand", voice.route)
            self._load(voice.route)
        sr = audio.SAMPLE_RATE
        gap = audio.silence(SENTENCE_GAP_S, sr)
        result = Synthesis(np.zeros(0, dtype=np.float32), sr, silent=False, synth_speed=1.0)
        parts: list[np.ndarray] = []
        offset = 0
        failure: Exception | None = None
        for number, sentence in enumerate(sentences.split(sentences.clean(text), voice.route), 1):
            if not sentences.is_speakable(sentence):
                continue
            if cancelled is not None and cancelled():
                raise Cancelled
            t0 = time.perf_counter()
            try:
                normalized = (frontend_zh.normalize(sentence) if voice.route == "zh"
                              else frontend_en.normalize(sentence))
                spoken = terminal_stop(normalized)
            except Exception as error:  # one unreadable sentence must not fail the whole text
                log.warning("sentence %d (%d chars) skipped, the %s front end failed: %s: %s", number,
                            len(sentence), voice.route, type(error).__name__, str(error)[:200])
                failure = failure or error
                continue
            finally:
                result.frontend_ms += (time.perf_counter() - t0) * 1000
            if not sentences.is_speakable(spoken):
                continue
            t1 = time.perf_counter()
            samples = self._speak(spoken, voice, cancelled, number)
            result.synth_ms += (time.perf_counter() - t1) * 1000
            if parts:
                parts.append(gap)
                offset += len(gap)
            start, length = offset / sr, len(samples) / sr
            result.sentences.append({"text": spoken, "start": round(start, 3), "end": round(start + length, 3)})
            parts.append(samples)
            offset += len(samples)
        if failure is not None and not parts:
            raise failure
        if not parts:
            result.audio = audio.silence(SILENT_S, sr)
            result.silent = True
        else:
            result.audio = np.concatenate(parts)
        return result

    def _speak(self, text: str, voice: Voice, cancelled: Callable[[], bool] | None, number: int) -> np.ndarray:
        """One sentence's trimmed audio: the first generation that is neither a runaway nor far too short, else the
        most plausible of MAX_ATTEMPTS."""
        expected = expected_seconds(text)
        limit = RUNAWAY_FACTOR * expected + RUNAWAY_EXTRA_S
        cap = max_tokens(text)
        seed = text_seed(text, voice.id)
        attempts: list[_Attempt] = []
        for _ in range(MAX_ATTEMPTS):
            attempt = self._generate(text, voice, seed, cap, limit, cancelled)
            attempts.append(attempt)
            if not attempt.runaway and attempt.duration >= SHORT_FACTOR * expected:
                break
            log.warning("sentence %d (%d chars): seed %d gave %s (%.2f s of audio, %d tokens, cap %d, expected about "
                        "%.2f s)%s", number, len(text), seed, "a runaway" if attempt.runaway else "too little audio",
                        attempt.duration, attempt.tokens, cap, expected,
                        "; retrying with another seed" if len(attempts) < MAX_ATTEMPTS else "")
            seed = next_seed(seed)
        else:
            attempt = min(attempts, key=lambda a: (a.runaway, abs(np.log((a.duration + 0.1) / (expected + 0.1)))))
            log.warning("sentence %d: no plausible generation in %d attempts; using seed %d (%.2f s)", number,
                        MAX_ATTEMPTS, attempt.seed, attempt.duration)
        return attempt.audio

    def _generate(self, text: str, voice: Voice, seed: int, cap: int, limit: float,
                  cancelled: Callable[[], bool] | None) -> _Attempt:
        """One streaming generation; stops early once it is longer than `limit` seconds."""
        self._backend.seed(seed)
        stream = self._tts.generate(text=text, voice=voice.id, lang_code=LANG_CODES[voice.route], stream=True,
                                    streaming_interval=STREAM_INTERVAL_S, max_tokens=cap, verbose=False)
        chunks: list[np.ndarray] = []
        samples = tokens = 0
        runaway = False
        try:
            for chunk in stream:
                piece = np.asarray(chunk.audio, dtype=np.float32).reshape(-1)
                chunks.append(piece)
                samples += len(piece)
                tokens += int(chunk.token_count)
                if cancelled is not None and cancelled():
                    raise Cancelled
                if samples > limit * audio.SAMPLE_RATE:
                    runaway = True
                    break
        finally:
            stream.close()  # an abandoned stream skips mlx-audio's own clean-up
            self._backend.clear_cache()
        generated = np.concatenate(chunks) if chunks else np.zeros(0, dtype=np.float32)
        trimmed = audio.trim_tail(audio.trim_head(generated))
        return _Attempt(trimmed, samples / audio.SAMPLE_RATE, seed, tokens, runaway or tokens >= cap)
