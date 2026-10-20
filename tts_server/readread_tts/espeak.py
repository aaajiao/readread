"""espeak-ng setup for misaki's English fallback (out-of-vocabulary words).

espeak-ng keeps its data path in a 160-byte buffer, and misaki.espeak points phonemizer at
espeakng_loader's data directory inside site-packages as soon as it is imported; in a deep install that
path does not fit. The data is therefore reached through a short symlink,
$READREAD_CACHE_DIR/espeak-ng-data, refreshed at every start.

phonemizer 3.4 resolves symlinks in EspeakWrapper.data_path, so handing it the link would bring the long
path back. The link goes into ESPEAK_DATA_PATH instead, which espeak-ng reads itself when it is
initialised with a NULL path, and phonemizer's data path is cleared before every backend is created.
kokoro's Tokenizer sets that path again whenever a Kokoro object is built, hence reset().
"""

from __future__ import annotations

import os
import threading

MAX_PATH_BYTES = 150  # espeak-ng's path_home is char[160] and file names are appended to it

_lock = threading.Lock()
_link: str | None = None
_active = False


def prepare(cache_dir: str) -> str:
    """Create or refresh the data-path symlink in cache_dir; returns its path. File system only."""
    global _link
    import espeakng_loader

    link = os.path.join(cache_dir, "espeak-ng-data")
    size = len(os.fsencode(link))
    if size > MAX_PATH_BYTES:
        raise RuntimeError(f"cache directory path is too long for espeak-ng ({size} bytes, at most "
                           f"{MAX_PATH_BYTES}): {link}")
    target = espeakng_loader.get_data_path()
    os.makedirs(cache_dir, exist_ok=True)
    try:
        current = os.readlink(link)
    except FileNotFoundError:
        current = None
    except OSError as error:
        raise RuntimeError(f"{link} exists and is not a symlink; remove it") from error
    if current != target:
        tmp = f"{link}.{os.getpid()}.tmp"
        if os.path.lexists(tmp):
            os.unlink(tmp)
        os.symlink(target, tmp)
        os.replace(tmp, link)  # atomic, so a concurrent start never sees a missing link
    _link = link
    return link


def activate() -> None:
    """Point espeak-ng at the link. Idempotent; call after prepare(), before any espeak backend."""
    global _active
    if _link is None:
        raise RuntimeError("espeak.prepare() was not called")
    with _lock:
        if _active:
            return
        os.environ["ESPEAK_DATA_PATH"] = _link
        for var in ("PHONEMIZER_ESPEAK_DATA_PATH", "PHONEMIZER_ESPEAK_LIBRARY"):
            os.environ.pop(var, None)
        import misaki.espeak  # noqa: F401  (sets the library, and the long data path, at import)

        _reset()
        _active = True


def _reset() -> None:
    from phonemizer.backend.espeak.wrapper import EspeakWrapper

    EspeakWrapper.set_data_path(None)


def reset() -> None:
    """Clear phonemizer's data path again (after building a Kokoro object)."""
    with _lock:
        _reset()


def fallback(british: bool):
    """misaki's EspeakFallback for en-gb or en-us, initialised from the short path."""
    from misaki.espeak import EspeakFallback

    activate()
    with _lock:
        _reset()
        return EspeakFallback(british=british)


def kokoro_config():
    """EspeakConfig for Kokoro objects (kokoro only uses espeak to phonemize raw text, which we never do)."""
    import espeakng_loader
    from kokoro_onnx import EspeakConfig

    activate()
    return EspeakConfig(lib_path=espeakng_loader.get_library_path(), data_path=_link)
