"""Shared fixtures for the TTS server tests.

Fast tests need only the Python dependencies. Tests that need the four Kokoro model files take the
`models_dir` fixture and are skipped unless READREAD_MODELS_DIR points at them:

    READREAD_MODELS_DIR=~/.readread/models ~/.readread/env/bin/python -m pytest -q tts_server/tests

The Qwen engine's tests run without MLX against tests/fakes (a stand-in for MLX and mlx-audio); the ones with the
real models (test_qwen_models.py) start servers from the HQ venv and are skipped unless READREAD_HQ_HOME points at
an install of scripts/install-hq.sh.
"""

from __future__ import annotations

import http.client
import json
import os
import secrets
import select
import signal
import subprocess
import sys
import time
import warnings
from collections import defaultdict
from pathlib import Path

import pytest

SERVER_DIR = Path(__file__).resolve().parent.parent
FIXTURES = Path(__file__).resolve().parent / "fixtures"
FAKES = Path(__file__).resolve().parent / "fakes"
sys.path.insert(0, str(SERVER_DIR))
warnings.filterwarnings("ignore", category=SyntaxWarning)  # jieba's regexes

from readread_tts import engine_kokoro as engine_module  # noqa: E402
from readread_tts import engine_qwen  # noqa: E402

# Probe outcomes per kind, printed at the end of the run: {kind: [passed, total]}.
PROBE_TALLY: dict[str, list[int]] = defaultdict(lambda: [0, 0])


def pytest_terminal_summary(terminalreporter) -> None:
    if PROBE_TALLY:
        tally = ", ".join(f"{kind} {ok}/{total}" for kind, (ok, total) in sorted(PROBE_TALLY.items()))
        terminalreporter.write_line(f"frontend probes (kokoro11zh-misaki rows): {tally}")


@pytest.fixture(scope="session")
def cache_dir(tmp_path_factory) -> str:
    from readread_tts import espeak

    path = str(tmp_path_factory.mktemp("cache"))
    espeak.prepare(path)
    return path


@pytest.fixture(scope="session")
def en_us(cache_dir):
    from readread_tts.frontend_en import EnglishG2P

    return EnglishG2P(british=False)


@pytest.fixture(scope="session")
def en_gb(cache_dir):
    from readread_tts.frontend_en import EnglishG2P

    return EnglishG2P(british=True)


@pytest.fixture(scope="session")
def builtin_lexicon(cache_dir):
    from readread_tts import frontend_zh
    from readread_tts.lexicon import Lexicon

    return Lexicon(str(SERVER_DIR / "readread_tts" / "lexicon_zh.json"), None, frontend_zh.t2s)


@pytest.fixture(scope="session")
def zh_g2p(en_us, builtin_lexicon, cache_dir):
    from readread_tts.frontend_zh import ChineseG2P

    return ChineseG2P(en_us, builtin_lexicon, cache_dir)


@pytest.fixture(scope="session")
def probe_tally() -> dict[str, list[int]]:
    return PROBE_TALLY


@pytest.fixture(scope="session")
def models_dir() -> str:
    path = os.environ.get("READREAD_MODELS_DIR")
    if not path:
        pytest.skip("READREAD_MODELS_DIR is not set")
    problems = engine_module.check_models(path)
    if problems:
        pytest.fail("; ".join(problems))
    return path


@pytest.fixture(scope="session")
def engine(models_dir, cache_dir):
    eng = engine_module.Engine(models_dir, cache_dir, None)
    with eng.lock:
        eng.load("zh")
        eng.load("en")
    return eng


# --- the server as a subprocess, launched the way the app launches it ----------------------------------

class ServerProcess:
    def __init__(self, workdir: Path, models_dir: str, preload: str | None = None, *,
                 args: list[str] | None = None, env: dict[str, str | None] | None = None,
                 launcher: list[str] | None = None, wait: bool = True, python: str | None = None) -> None:
        """args replaces --models-dir; env entries override (None removes); launcher goes between the
        interpreter flags and the script (a -c wrapper); python replaces this interpreter (the HQ venv's)."""
        # HOME is an empty directory of its own, so a write outside the cache directory shows up there.
        for name in ("tmp", "home"):
            (workdir / name).mkdir(parents=True, exist_ok=True)
        self.workdir = workdir
        self.token = secrets.token_hex(32)
        self.log_path = workdir / "stderr.log"
        environment = {
            "READREAD_TOKEN": self.token, "ORT_DISABLE_TELEMETRY": "1", "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONIOENCODING": "utf-8", "READREAD_CACHE_DIR": str(workdir / "cache"),
            "READREAD_USER_LEXICON": str(workdir / "support" / "lexicon_zh.json"),
            "HOME": str(workdir / "home"), "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
            "TMPDIR": str(workdir / "tmp"),
        }
        environment.update(env or {})
        environment = {k: v for k, v in environment.items() if v is not None}
        command = [python or sys.executable, "-I", "-B", *(launcher or []), str(SERVER_DIR / "tts_server.py")]
        command += args if args is not None else ["--models-dir", models_dir]
        if preload:
            command += ["--preload", preload]
        with open(self.log_path, "wb") as log:
            self.proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
                                         env=environment)
        self.line = self.read_line(120) if wait else ""
        self.port = json.loads(self.line[len("READY "):])["port"] if self.line.startswith("READY ") else None

    def read_line(self, timeout: float) -> str:
        ready, _, _ = select.select([self.proc.stdout], [], [], timeout)
        return self.proc.stdout.readline().decode("utf-8").strip() if ready else ""

    def request(self, method: str, path: str, body=None, headers: dict | None = None, *,
                content_type: str | None = "application/json", timeout: float = 120):
        """(status, lower-cased headers, body). A header given as None is left out."""
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=timeout)
        h = {"Authorization": f"Bearer {self.token}"}
        if body is not None and not isinstance(body, bytes):
            body = json.dumps(body).encode("utf-8")
        if body is not None and content_type:
            h["Content-Type"] = content_type
        h.update(headers or {})
        h = {k: v for k, v in h.items() if v is not None}
        try:
            connection.request(method, path, body=body, headers=h)
            response = connection.getresponse()
            data = response.read()
            return response.status, {k.lower(): v for k, v in response.getheaders()}, data
        finally:
            connection.close()

    def log(self) -> str:
        return self.log_path.read_text(encoding="utf-8", errors="replace")

    def stop(self) -> None:
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(5)
        for stream in (self.proc.stdin, self.proc.stdout):
            if stream and not stream.closed:
                stream.close()


def wait_exit(proc: subprocess.Popen, timeout: float) -> float | None:
    """Seconds until proc exited, or None if it is still running after timeout."""
    start = time.monotonic()
    while time.monotonic() - start < timeout:
        if proc.poll() is not None:
            return time.monotonic() - start
        time.sleep(0.02)
    return None


@pytest.fixture
def server_dir(tmp_path_factory) -> Path:
    """A short directory for one server process: espeak-ng needs <dir>/cache/espeak-ng-data under 150 bytes."""
    return tmp_path_factory.mktemp("s")


def make_fake_models(path: Path) -> str:
    """Sparse files of the right sizes: enough for the start-up checks, for tests that never load a model."""
    path.mkdir(parents=True, exist_ok=True)
    for name, size in engine_module.MODEL_SIZES.items():
        with open(path / name, "wb") as f:
            f.truncate(size)
    return str(path)


@pytest.fixture
def fake_models(tmp_path) -> str:
    return make_fake_models(tmp_path / "fake-models")


def make_qwen_models(path: Path, models=("1.7b", "0.6b")) -> str:
    """Sparse Qwen3-TTS model folders of the right sizes (enough for the start-up checks; the fake model reads none)."""
    for model in models:
        for name, size in engine_qwen.MODEL_FILES[model].items():
            target = path / engine_qwen.MODELS[model] / name
            target.parent.mkdir(parents=True, exist_ok=True)
            with open(target, "wb") as f:
                f.truncate(size)
    return str(path)


_LAUNCHER = """
import importlib.abc, importlib.machinery, runpy, sys
first, record, watched, hidden = sys.argv[1:5]
watched, hidden = set(filter(None, watched.split(","))), set(filter(None, hidden.split(",")))
if first:
    sys.path.insert(0, first)
class Watch(importlib.abc.MetaPathFinder):
    def find_spec(self, name, path=None, target=None):
        if name in watched or name.partition(".")[0] in watched:
            with open(record, "a", encoding="utf-8") as f:
                f.write(name + "\\n")
        return None
class Hiding(importlib.machinery.PathFinder):
    @classmethod
    def find_spec(cls, name, path=None, target=None):
        return None if name.partition(".")[0] in hidden else super().find_spec(name, path, target)
sys.meta_path[:] = [Hiding if f is importlib.machinery.PathFinder else f for f in sys.meta_path]
sys.meta_path.insert(0, Watch())
sys.argv = sys.argv[5:]
runpy.run_path(sys.argv[0], run_name="__main__")
"""


def launcher(first: Path | None = None, record: Path | None = None, watch=(), hide=()) -> list[str]:
    """A -c wrapper for ServerProcess: `first` goes first on sys.path; every lookup of a module in `watch` (top-level
    or full names) is appended to the file `record`, whether the module exists or not; the top-level packages in
    `hide` cannot be found, as if they were not installed."""
    return ["-c", _LAUNCHER, str(first or ""), str(record or ""), ",".join(watch), ",".join(hide)]


# tests/fakes first on sys.path: MLX, mlx-audio and the Hugging Face packages are stand-ins (fakes/fake_qwen.py).
FAKES_LAUNCHER = launcher(FAKES)
