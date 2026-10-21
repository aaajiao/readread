"""Fake mlx.core for server tests without MLX: what engine_qwen.MLXBackend calls."""

import json
import os
import types

import fake_qwen


def _log(event: str, **fields) -> None:
    path = os.environ.get("FAKE_QWEN_LOG")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps({"event": event, **fields}) + "\n")


def _seed(value: int) -> None:
    fake_qwen.current_seed = value


random = types.SimpleNamespace(seed=_seed)


def set_cache_limit(limit: int) -> int:
    _log("set_cache_limit", limit=limit)
    return 0


def clear_cache() -> None:
    _log("clear_cache")
