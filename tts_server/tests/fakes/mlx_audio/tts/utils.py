"""Fake mlx_audio.tts.utils: load_model() returns a fake_qwen.FakeModel and, like mlx-audio, prints on stdout.

FAKE_QWEN_LOAD_DELAY (seconds) makes the load slow; FAKE_QWEN_LOAD_FAIL makes it raise.
"""

import json
import os
import sys
import threading
import time
from pathlib import Path

import fake_qwen


def load_model(model_path, lazy=False, strict=True, **kwargs):
    if not isinstance(model_path, Path):
        raise TypeError("pass a Path: a str would be looked up on the Hugging Face Hub")
    print(f"Loaded speech tokenizer from {model_path / 'speech_tokenizer'}")  # mlx-audio does this on stdout
    os.write(1, b"fd 1 write from the fake model loader\n")
    sys.stdout.flush()
    delay = float(os.environ.get("FAKE_QWEN_LOAD_DELAY") or 0)
    if delay:
        time.sleep(delay)
    if os.environ.get("FAKE_QWEN_LOAD_FAIL"):
        raise RuntimeError("fake load failure")
    path = os.environ.get("FAKE_QWEN_LOG")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps({"event": "load", "path": str(model_path), "thread": threading.current_thread().name,
                                "offline": {k: os.environ.get(k) for k in ("HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE",
                                                                         "HF_HUB_DISABLE_TELEMETRY", "HF_HOME")}})
                    + "\n")
    return fake_qwen.FakeModel()
