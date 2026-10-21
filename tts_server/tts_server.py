#!/usr/bin/env python3
"""ReadRead TTS server, HTTP API v2 (entry point; the code lives in readread_tts/).

The app launches it as

    <python> -I -B tts_server.py --models-dir <dir> [--preload zh|en|zh,en]
    <hq python> -I -B tts_server.py --engine qwen [--model 1.7b] --models-dir <dir> [--preload ...]

with READREAD_TOKEN (64 hex characters) in the environment; READREAD_CACHE_DIR and
READREAD_USER_LEXICON override where caches and the user lexicon live. The default engine is Kokoro
(the bundled runtime); --engine qwen runs Qwen3-TTS from the venv of scripts/install-hq.sh. stdout
carries exactly one line, `READY {"port":..,"pid":..,"api":2,"loaded":[..],"engine":..}` once the
server listens on 127.0.0.1 and the preloaded routes are warm, or `FATAL {"message":..}` followed by
exit status 3. Everything else, stray prints included, goes to stderr. The server exits when stdin
reaches EOF (the app is gone) and within a second of SIGTERM or SIGINT, also in the middle of a
synthesis.
"""

from __future__ import annotations

import os
import sys

# The handshake keeps the real stdout; fd 1 is pointed at stderr so nothing else can reach it.
_HANDSHAKE_FD = os.dup(1)
os.dup2(2, 1)

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # -I leaves the script's directory off sys.path

import argparse  # noqa: E402
import importlib.metadata  # noqa: E402
import importlib.util  # noqa: E402
import json  # noqa: E402
import logging  # noqa: E402
import re  # noqa: E402
import shutil  # noqa: E402
import signal  # noqa: E402
import tempfile  # noqa: E402
import threading  # noqa: E402
import time  # noqa: E402
import warnings  # noqa: E402

log = logging.getLogger("readread")

# Imported by the server or by the libraries it drives, per engine; checked up front for a clear FATAL message.
REQUIRED_MODULES = {
    "kokoro": ("numpy", "onnxruntime", "kokoro_onnx", "misaki", "phonemizer", "espeakng_loader", "spacy",
               "en_core_web_sm", "opencc", "num2words", "cn2an", "jieba", "pypinyin", "pypinyin_dict"),
    "qwen": ("numpy", "mlx", "mlx_audio", "transformers", "tokenizers", "huggingface_hub", "safetensors", "misaki",
             "opencc", "num2words", "pypinyin"),
}
INSTALLER = {"kokoro": "./scripts/setup.sh", "qwen": "./scripts/install-hq.sh"}
_scratch: str | None = None
_ready = False


def _emit(line: str) -> None:
    os.write(_HANDSHAKE_FD, line.encode("ascii") + b"\n")


def _exit(status: int) -> None:
    if _scratch:
        shutil.rmtree(_scratch, ignore_errors=True)
    try:
        sys.stderr.flush()
    except (OSError, ValueError):
        pass
    os._exit(status)


def fatal(message: str) -> None:
    log.error("FATAL: %s", message)
    _emit("FATAL " + json.dumps({"message": message}, separators=(",", ":")))
    _exit(3)


class _Parser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        fatal(f"bad arguments: {message}")


def _parse_args() -> argparse.Namespace:
    from readread_tts.engine import ENGINES, QWEN_MODELS

    parser = _Parser(prog="tts_server.py", description="ReadRead TTS server (HTTP API v2)")
    parser.add_argument("--engine", choices=ENGINES, default="kokoro", help="kokoro (default) or qwen")
    parser.add_argument("--model", choices=QWEN_MODELS, help="the Qwen3-TTS model (qwen only; 1.7b, the only one, "
                        "is the default)")
    parser.add_argument("--models-dir", required=True, help="kokoro: directory holding the four Kokoro model "
                        "files; qwen: directory holding the Qwen3-TTS model folder")
    parser.add_argument("--preload", default="", help='routes to load before READY: "zh", "en" or "zh,en"')
    args = parser.parse_args()
    if args.engine != "qwen" and args.model is not None:
        fatal("bad arguments: --model applies only to --engine qwen")
    if args.engine == "qwen" and args.model is None:
        args.model = QWEN_MODELS[0]
    routes = [r.strip() for r in args.preload.split(",") if r.strip()]
    unknown = [r for r in routes if r not in ("zh", "en")]
    if unknown:
        fatal(f"bad arguments: unknown --preload route {unknown[0]!r} (expected zh, en or zh,en)")
    args.preload = [r for r in ("zh", "en") if r in routes]
    return args


def _on_signal(signum: int, _frame) -> None:
    # Runs in the main thread, which only waits (serve_forever / join): exit at once, mid-synthesis too.
    # Written directly, in the log's format, so a logging lock held by another thread cannot delay it.
    now = time.time()
    stamp = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now)) + f".{int(now % 1 * 1000):03d}"
    os.write(2, f"{stamp} INFO readread: received {signal.Signals(signum).name}, exiting\n".encode())
    _exit(0)


def _watch_stdin() -> None:
    """The app keeps our stdin open for as long as it wants us; EOF means it is gone."""
    try:
        while os.read(0, 4096):
            pass
    except OSError as error:
        log.warning("stdin watchdog off (%s)", error)
        return
    log.info("stdin closed, exiting")
    _exit(0)


def _scratch_dir(cache_dir: str) -> str:
    """Per-process temporary directory under the cache dir. phonemizer copies libespeak-ng into a fresh
    temporary directory per backend and only deletes it on garbage collection, which os._exit skips;
    directories left by processes that are gone are removed here."""
    root = os.path.join(cache_dir, "tmp")
    os.makedirs(root, exist_ok=True)
    for name in os.listdir(root):
        if name.isdigit() and int(name) != os.getpid() and not _alive(int(name)):
            shutil.rmtree(os.path.join(root, name), ignore_errors=True)
    path = os.path.join(root, str(os.getpid()))
    os.makedirs(path, exist_ok=True)
    return path


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def main() -> None:
    global _scratch, _ready
    logging.basicConfig(stream=sys.stderr, level=logging.INFO,
                        format="%(asctime)s.%(msecs)03d %(levelname)s %(name)s: %(message)s",
                        datefmt="%Y-%m-%d %H:%M:%S")
    logging.captureWarnings(True)
    warnings.filterwarnings("ignore", category=SyntaxWarning)  # jieba's regexes, when compiled from source

    args = _parse_args()
    token = os.environ.pop("READREAD_TOKEN", "")
    if not re.fullmatch(r"[0-9a-fA-F]{64}", token):
        fatal("READREAD_TOKEN must be set to 64 hexadecimal characters")
    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)
    threading.Thread(target=_watch_stdin, name="stdin-watchdog", daemon=True).start()
    log.info("ReadRead TTS server starting (api 2, pid %d, Python %s, engine %s%s)", os.getpid(),
             sys.version.split()[0], args.engine, f" {args.model}" if args.model else "")
    qwen = args.engine == "qwen"

    # The packages first (find_spec finds a top-level package without importing it): the engine modules import
    # numpy, so a venv without its packages would otherwise fail with a bare ModuleNotFoundError.
    missing = [m for m in REQUIRED_MODULES[args.engine] if importlib.util.find_spec(m) is None]
    if missing:
        fatal(f"missing Python packages: {', '.join(missing)} (run {INSTALLER[args.engine]})")
    # Neither engine module imports its engine's libraries; models load later, in the preload thread.
    if qwen:
        from readread_tts import engine_qwen as engine_module  # also switches Hugging Face to offline mode
    else:
        from readread_tts import engine_kokoro as engine_module

    models_dir = os.path.abspath(os.path.expanduser(args.models_dir))
    problems = engine_module.check_models(models_dir, args.model) if qwen else engine_module.check_models(models_dir)
    if problems:
        fatal("; ".join(problems))
    if not qwen:
        try:
            importlib.metadata.distribution("en_core_web_sm")  # what spaCy checks before it would download
        except importlib.metadata.PackageNotFoundError:
            fatal("the spaCy model en_core_web_sm is installed without its metadata; reinstall it")

    cache_dir = os.path.abspath(os.path.expanduser(
        os.environ.get("READREAD_CACHE_DIR") or "~/Library/Caches/ReadRead"))
    user_lexicon = os.path.abspath(os.path.expanduser(
        os.environ.get("READREAD_USER_LEXICON") or "~/Library/Application Support/ReadRead/lexicon_zh.json"))
    try:
        if not qwen:
            from readread_tts import espeak

            espeak.prepare(cache_dir)
        _scratch = tempfile.tempdir = _scratch_dir(cache_dir)
    except Exception as error:  # noqa: BLE001
        fatal(f"cannot set up the cache directory {cache_dir}: {error}")

    try:
        from readread_tts.server import Server

        if qwen:
            engine = engine_module.Engine(models_dir, args.model, cache_dir)
        else:
            engine = engine_module.Engine(models_dir, cache_dir, user_lexicon)
        server = Server(engine, token)
    except Exception as error:  # noqa: BLE001
        fatal(f"cannot start the HTTP server: {type(error).__name__}: {error}")
    if qwen:
        log.info("listening on 127.0.0.1:%d; engine qwen, model %s in %s; cache %s", server.port, args.model,
                 models_dir, cache_dir)
    else:
        log.info("listening on 127.0.0.1:%d; models %s; cache %s; user lexicon %s", server.port, models_dir,
                 cache_dir, user_lexicon)

    failure: list[BaseException] = []

    def preload() -> None:
        try:
            with engine.lock:
                for route in args.preload:
                    engine.load(route)
        except BaseException as error:  # noqa: BLE001 - reported as FATAL by the main thread
            log.exception("preload failed")
            failure.append(error)

    loader = threading.Thread(target=preload, name="preload", daemon=True)
    loader.start()
    while loader.is_alive():
        loader.join(0.2)  # in short steps, so SIGTERM is handled during a long model load
    if failure:
        fatal(f"loading the models failed: {type(failure[0]).__name__}: {failure[0]}")

    ready = {"port": server.port, "pid": os.getpid(), "api": 2, "loaded": engine.loaded(), "engine": engine.name}
    if engine.model is not None:
        ready["model"] = engine.model
    _emit("READY " + json.dumps(ready, separators=(",", ":")))
    _ready = True
    log.info("ready (loaded: %s)", ", ".join(engine.loaded()) or "nothing yet")
    server.serve_forever(poll_interval=0.5)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except BaseException as error:  # noqa: BLE001 - before READY this is a FATAL, after it a crash
        log.exception("unexpected error")
        if _ready:
            _exit(1)
        fatal(f"{type(error).__name__}: {error}")
