"""The engine interface the HTTP server drives, and the types every engine shares.

Two engines implement it: "kokoro" (engine_kokoro: Kokoro ONNX, bundled with the app, the default) and "qwen"
(engine_qwen: Qwen3-TTS through MLX, installed separately by scripts/install-hq.sh). tts_server.py picks one
with --engine. Importing an engine module is cheap and needs neither engine's libraries: those are imported when
a model loads, so the bundled Kokoro runtime (which has no MLX) never touches the Qwen engine's dependencies.

An engine is not thread-safe. Callers hold Engine.lock around load() and synthesize().
"""

from __future__ import annotations

import threading
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Protocol

if TYPE_CHECKING:
    import numpy as np

ENGINES = ("kokoro", "qwen")
QWEN_MODELS = ("1.7b",)  # --model for --engine qwen: one model, also the default
SENTENCE_GAP_S = 0.25  # silence between two sentences of one synthesis
SILENT_S = 0.15  # what text with nothing to say comes back as


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
    british: bool = False


@dataclass
class Synthesis:
    audio: np.ndarray  # float32 mono at sample_rate
    sample_rate: int
    silent: bool
    sentences: list[dict] = field(default_factory=list)  # {"text", "start", "end"}
    tokens: list[dict] = field(default_factory=list)  # {"text", "start", "end"}
    frontend_ms: float = 0.0
    synth_ms: float = 0.0
    # The speed the audio was rendered at: the requested one when the engine applies it (kokoro), 1.0 when the
    # client has to change the rate itself (qwen).
    synth_speed: float = 1.0

    @property
    def duration(self) -> float:
        return len(self.audio) / self.sample_rate


class Engine(Protocol):
    """What server.Server needs from an engine."""

    name: str  # one of ENGINES
    model: str | None  # the model variant, for engines that have several ("1.7b"); else None
    lock: threading.Lock

    def versions(self) -> dict[str, str]:
        """Versions of the libraries doing the work, for GET /health."""

    def voice_lists(self) -> dict[str, list[str]]:
        """{"zh": [...], "en": [...]}, without loading a model."""

    def resolve(self, voice_id: str, lang: str | None = None) -> Voice:
        """The voice for a request, or VoiceError("unknown_voice" | "voice_language_mismatch")."""

    def loaded(self) -> list[str]:
        """The routes ("zh", "en") that are ready to synthesize without a load first."""

    def load(self, route: str) -> None:
        """Make a route ready (model, front end, one warm-up synthesis). Idempotent."""

    def synthesize(self, text: str, voice: Voice, speed: float = 1.0,
                   cancelled: Callable[[], bool] | None = None) -> Synthesis:
        """Synthesize text sentence by sentence; raises Cancelled once cancelled() turns true."""


def package_versions(**distributions: str) -> dict[str, str]:
    """{key: installed version of the distribution, or "unknown"}, plus "python"."""
    import platform
    from importlib.metadata import PackageNotFoundError, version

    def get(name: str) -> str:
        try:
            return version(name)
        except PackageNotFoundError:
            return "unknown"

    return {key: get(name) for key, name in distributions.items()} | {"python": platform.python_version()}
