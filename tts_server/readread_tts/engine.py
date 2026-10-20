"""Routing, model sessions and synthesis.

Two routes, chosen by the voice id prefix: "zh" (zf_/zm_; Kokoro v1.1-zh + the Chinese front end) and
"en" (af_/am_ US, bf_/bm_ GB; Kokoro v1.0 + misaki English). A route's ONNX session and G2P objects are
created on first use (or at start with --preload) and stay resident: dropping a session does not give
the memory back on macOS. Each sentence is one model call; its trailing pause is trimmed to 40 ms and
sentences are joined with 250 ms of silence. A sentence over the model's 510 phonemes is synthesized one
kokoro batch per call, joined the way kokoro joins them, so a cancellation is noticed between batches too;
a run without spaces is first given word breaks at '/' so no batch is cut inside a syllable.

The Engine is not thread-safe. Callers hold Engine.lock around load() and synthesize(): espeak-ng and
the G2P objects keep global state, and one synthesis at a time is all the CPU can usefully run.
"""

from __future__ import annotations

import logging
import os
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, field

import numpy as np

from . import audio, espeak, frontend_en, frontend_zh, sentences
from .g2p import align

log = logging.getLogger("readread.engine")

ROUTES = ("zh", "en")
MODEL_FILES = {"zh": ("kokoro-v1.1-zh.fp16.onnx", "voices-v1.1-zh.bin"),
               "en": ("kokoro-v1.0.fp16.onnx", "voices-v1.0.bin")}
# The exact files of kokoro-onnx release model-files-v1.1. The size tells the v1.0 re-export (which
# reports durations) from the older 177464787-byte export, which does not.
MODEL_SIZES = {"kokoro-v1.1-zh.fp16.onnx": 163528759, "voices-v1.1-zh.bin": 53815880,
               "kokoro-v1.0.fp16.onnx": 163527961, "voices-v1.0.bin": 28214398}
VOICE_PREFIXES = {"zf_": ("zh", False), "zm_": ("zh", False), "af_": ("en", False), "am_": ("en", False),
                  "bf_": ("en", True), "bm_": ("en", True)}
SENTENCE_GAP_S = 0.25
SILENT_S = 0.15
MAX_PHONEMES = 510  # kokoro_onnx.config.MAX_PHONEME_LENGTH
# The pauses kokoro puts after a batch that ends with a sentence or clause mark (create_timed's defaults).
_BATCH_SENTENCE_PAUSE_S = 0.25
_BATCH_CLAUSE_PAUSE_S = 0.1
_WARMUP = {"zh": ("你好，hello。", "zf_001"), "en": ("Hello Zorblat.", "af_heart")}
_LEXICON = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lexicon_zh.json")


class Cancelled(Exception):
    """The client went away; the synthesis was abandoned."""


class VoiceError(ValueError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code  # "unknown_voice" or "voice_language_mismatch"


@dataclass(frozen=True)
class Voice:
    id: str
    route: str  # "zh" | "en"
    british: bool


@dataclass
class Synthesis:
    audio: np.ndarray  # float32 mono at sample_rate
    sample_rate: int
    silent: bool
    sentences: list[dict] = field(default_factory=list)  # {"text", "start", "end"}
    tokens: list[dict] = field(default_factory=list)  # {"text", "start", "end"}
    frontend_ms: float = 0.0
    synth_ms: float = 0.0

    @property
    def duration(self) -> float:
        return len(self.audio) / self.sample_rate


@dataclass
class _Route:
    kokoro: object
    vocab: frozenset[str]
    styles: dict[str, np.ndarray] = field(default_factory=dict)


@dataclass(frozen=True)
class _Timing:
    phoneme: str
    start: float
    end: float


def soft_breaks(phonemes: str, limit: int = MAX_PHONEMES) -> str:
    """A space at a word boundary ('/', misaki zh v1.1) in every run of more than `limit` symbols without
    whitespace, so kokoro's chunker cuts there instead of slicing blindly; after a tone digit if a stretch
    has no '/', and at the limit only if it has neither."""
    runs = []
    for run in phonemes.split(" "):
        pieces, start = [], 0
        while len(run) - start > limit:
            cut = run.rfind("/", start + 1, start + limit + 1)
            if cut > start:
                pieces.append(run[start:cut])
                start = cut + 1
                continue
            cut = next((j for j in range(start + limit, start, -1) if run[j - 1].isdigit()), start + limit)
            pieces.append(run[start:cut])
            start = cut
        pieces.append(run[start:])
        runs.append(" ".join(pieces))
    return " ".join(runs)


def check_models(models_dir: str) -> list[str]:
    """Human-readable problems with the model directory (empty if all four files are right)."""
    if not os.path.isdir(models_dir):
        return [f"models directory not found: {models_dir}"]
    problems = []
    for name, size in MODEL_SIZES.items():
        path = os.path.join(models_dir, name)
        if not os.path.isfile(path):
            problems.append(f"missing model file {path}")
        elif os.path.getsize(path) != size:
            problems.append(f"{path} is {os.path.getsize(path)} bytes, expected {size} (wrong or old export; "
                            "re-run ./scripts/setup.sh)")
    return problems


class Engine:
    def __init__(self, models_dir: str, cache_dir: str, user_lexicon: str | None) -> None:
        self.models_dir = models_dir
        self.cache_dir = cache_dir
        self.user_lexicon = user_lexicon
        self.lock = threading.Lock()  # held by callers around load() and synthesize()
        self._routes: dict[str, _Route] = {}
        self._english: dict[bool, frontend_en.EnglishG2P] = {}
        self._chinese: frontend_zh.ChineseG2P | None = None
        self._voices: dict[str, list[str]] | None = None
        self._voices_lock = threading.Lock()

    # --- voices -------------------------------------------------------------------------------------

    def voice_lists(self) -> dict[str, list[str]]:
        """{"zh": [...], "en": [...]} read from the voice files' names, without loading any model."""
        with self._voices_lock:
            if self._voices is None:
                lists = {}
                for route, prefixes in (("zh", ("zf_", "zm_")), ("en", ("af_", "am_", "bf_", "bm_"))):
                    with np.load(os.path.join(self.models_dir, MODEL_FILES[route][1])) as voices:
                        lists[route] = sorted(v for v in voices.files if v.startswith(prefixes))
                self._voices = lists
            return self._voices

    def resolve(self, voice_id: str, lang: str | None = None) -> Voice:
        """The voice for a request; lang ("zh", "en", "en-us", "en-gb") must agree with its family."""
        route, british = VOICE_PREFIXES.get(voice_id[:3], (None, False))
        if route is None or voice_id not in self.voice_lists()[route]:
            raise VoiceError("unknown_voice", f"unknown voice {voice_id!r}; GET /voices lists the available ones")
        if lang is not None and (lang == "zh") != (route == "zh"):
            raise VoiceError("voice_language_mismatch", f"voice {voice_id!r} speaks {route}, not {lang}")
        return Voice(voice_id, route, british)

    # --- loading ------------------------------------------------------------------------------------

    def loaded(self) -> list[str]:
        return [r for r in ROUTES if r in self._routes]

    def load(self, route: str) -> None:
        """Create the route's session and G2P objects and run one warm-up synthesis. Idempotent."""
        if route in self._routes:
            return
        started = time.perf_counter()
        espeak.activate()
        kokoro = self._kokoro(route)
        if route == "zh":
            self._chinese_g2p()
        else:
            self._english_g2p(False)
            self._english_g2p(True).tokens("Hello Zorblat.")
        self._routes[route] = _Route(kokoro, frozenset(kokoro.tokenizer.vocab))
        text, voice = _WARMUP[route]
        if voice not in self.voice_lists()[route]:
            voice = self.voice_lists()[route][0]
        try:
            self.synthesize(text, self.resolve(voice))
        except BaseException:
            del self._routes[route]
            raise
        log.info("route %s ready in %.2f s", route, time.perf_counter() - started)

    def _kokoro(self, route: str):
        import onnxruntime as rt
        from kokoro_onnx import Kokoro

        rt.set_default_logger_severity(3)  # graph optimization warns about every fp16 constant
        logging.getLogger("kokoro_onnx").handlers.clear()  # its own stderr handler; let records propagate
        model, voices = (os.path.join(self.models_dir, name) for name in MODEL_FILES[route])
        options = rt.SessionOptions()
        options.log_severity_level = 3
        # Memory patterns are planned per input shape and kept: with them, both routes grew to 3.5 GB RSS after
        # two ~25 s sentences, without them to 2.6 GB, at the same speed (measured 2026-10-20, audit R2-10).
        options.enable_mem_pattern = False
        session = rt.InferenceSession(model, sess_options=options, providers=["CPUExecutionProvider"])
        kokoro = Kokoro.from_session(session, voices, espeak_config=espeak.kokoro_config())
        espeak.reset()  # the Tokenizer just pointed phonemizer at the long path again
        if not kokoro.has_timings:
            raise RuntimeError(f"{model} reports no durations; the model-files-v1.1 export is required")
        return kokoro

    def _english_g2p(self, british: bool) -> frontend_en.EnglishG2P:
        g2p = self._english.get(british)
        if g2p is None:
            g2p = self._english[british] = frontend_en.EnglishG2P(british)
        return g2p

    def _chinese_g2p(self) -> frontend_zh.ChineseG2P:
        if self._chinese is None:
            from .lexicon import Lexicon

            lexicon = Lexicon(_LEXICON, self.user_lexicon, frontend_zh.t2s)
            self._chinese = frontend_zh.ChineseG2P(self._english_g2p(False), lexicon, self.cache_dir)
        return self._chinese

    # --- synthesis ----------------------------------------------------------------------------------

    def synthesize(self, text: str, voice: Voice, speed: float = 1.0,
                   cancelled: Callable[[], bool] | None = None) -> Synthesis:
        """Synthesize text sentence by sentence. Raises Cancelled when cancelled() turns true between
        sentences (or between the batches of a long one). Text with nothing to say comes back as 150 ms of
        silence with silent=True. A sentence the front end fails on is logged and skipped; if nothing is
        left to say, the first such error is raised."""
        if voice.route not in self._routes:
            log.info("loading route %s on demand", voice.route)
            self.load(voice.route)
        route = self._routes[voice.route]
        style = route.styles.get(voice.id)
        if style is None:
            style = route.styles[voice.id] = route.kokoro.get_voice_style(voice.id)
        lang = "zh" if voice.route == "zh" else "en"
        sr = audio.SAMPLE_RATE
        gap = audio.silence(SENTENCE_GAP_S, sr)
        result = Synthesis(np.zeros(0, dtype=np.float32), sr, silent=False)
        parts: list[np.ndarray] = []
        offset = 0
        failure: Exception | None = None
        for number, sentence in enumerate(sentences.split(sentences.clean(text), lang), 1):
            if not sentences.is_speakable(sentence):
                continue
            if cancelled is not None and cancelled():
                raise Cancelled
            t0 = time.perf_counter()
            try:
                if voice.route == "zh":
                    normalized = frontend_zh.normalize(sentence)
                    phonemes = self._chinese_g2p().phonemize(normalized)
                else:
                    normalized = frontend_en.normalize(sentence)
                    phonemes = self._english_g2p(voice.british).phonemize(normalized)
            except Exception as error:  # one unreadable sentence must not fail the whole text
                log.warning("sentence %d (%d chars) skipped, the %s front end failed: %s: %s", number,
                            len(sentence), voice.route, type(error).__name__, str(error)[:200])
                failure = failure or error
                continue
            finally:
                result.frontend_ms += (time.perf_counter() - t0) * 1000
            t1 = time.perf_counter()
            if not phonemes.speakable(route.vocab):
                continue
            samples, timings = self._speak(route, phonemes.text, style, speed, cancelled)
            samples = audio.trim_tail(samples, sr)
            result.synth_ms += (time.perf_counter() - t1) * 1000
            if parts:
                parts.append(gap)
                offset += len(gap)
            start, length = offset / sr, len(samples) / sr
            result.sentences.append({"text": normalized, "start": _ms(start), "end": _ms(start + length)})
            for token, a, b in align(phonemes, timings, route.vocab):
                result.tokens.append({"text": token.text, "start": _ms(start + min(a, length)),
                                      "end": _ms(start + min(b, length))})
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

    def _speak(self, route: _Route, phonemes: str, style: np.ndarray, speed: float,
               cancelled: Callable[[], bool] | None) -> tuple[np.ndarray, list[_Timing]]:
        """One sentence's audio and phoneme timings: one create_timed call, or one per kokoro batch."""
        if len(phonemes) <= MAX_PHONEMES:
            samples, _, timings = route.kokoro.create_timed(phonemes, voice=style, speed=speed, is_phonemes=True)
            return np.asarray(samples, dtype=np.float32), timings
        from kokoro_onnx.chunker import pause_after, split_phonemes

        sr = audio.SAMPLE_RATE
        batches = split_phonemes(soft_breaks(phonemes), MAX_PHONEMES)
        parts: list[np.ndarray] = []
        timings: list[_Timing] = []
        offset = 0
        for k, batch in enumerate(batches):
            if k and cancelled is not None and cancelled():
                raise Cancelled
            samples, _, batch_timings = route.kokoro.create_timed(batch, voice=style, speed=speed,
                                                                  is_phonemes=True)
            samples = np.asarray(samples, dtype=np.float32)
            if k < len(batches) - 1:  # kokoro trims each batch and pauses after its last mark
                samples = audio.trim_tail(samples, sr)
                pause = pause_after(batch, _BATCH_SENTENCE_PAUSE_S, _BATCH_CLAUSE_PAUSE_S)
                samples = np.concatenate([samples, audio.silence(pause, sr)])
            start, length = offset / sr, len(samples) / sr
            timings += [_Timing(t.phoneme, start + min(t.start, length), start + min(t.end, length))
                        for t in batch_timings]
            parts.append(samples)
            offset += len(samples)
        return np.concatenate(parts), timings


def _ms(seconds: float) -> float:
    return round(seconds, 3)
