"""Audio helpers: trailing-silence trim, silence, PCM16 WAV encoding."""

from __future__ import annotations

import io
import wave

import numpy as np

SAMPLE_RATE = 24000
TAIL_S = 0.040  # silence kept after the last speech frame of a sentence
_FRAME_S = 0.005
_CERTAIN_DB = -40.0  # frames this far below the loudest frame are certainly speech ...
_SPEECH_DB = -50.0  # ... and frames down to here still are, if they follow speech closely
_DECAY_S = 0.1  # how far past the last certain frame a quieter one still counts as its decay
_FADE_S = 0.010


def trim_tail(audio: np.ndarray, sample_rate: int = SAMPLE_RATE, tail: float = TAIL_S) -> np.ndarray:
    """Cut the silence after the last speech frame down to `tail` seconds.

    kokoro-onnx pads every sentence-final mark to a 0.25 s pause by splicing digital silence into the
    quiet stretch after the speech, which leaves a little low-level noise beyond it. Speech ends at
    the last frame within 50 dB of the loudest one, looked for no further than 0.1 s past the last
    frame within 40 dB, so the noise after the splice never counts. Only the kept tail is faded.
    """
    n = len(audio)
    if n == 0:
        return audio.astype(np.float32, copy=False)
    frame = max(1, int(_FRAME_S * sample_rate))
    count = -(-n // frame)
    padded = np.zeros(count * frame, dtype=np.float64)
    padded[:n] = audio
    rms = np.sqrt((padded.reshape(count, frame) ** 2).mean(axis=1))
    peak = float(rms.max())
    keep = int(round(tail * sample_rate))
    if peak <= 0.0:
        return np.zeros(min(n, keep), dtype=np.float32)
    certain = int(np.flatnonzero(rms > peak * 10 ** (_CERTAIN_DB / 20))[-1])
    limit = min(count, certain + 1 + int(round(_DECAY_S / _FRAME_S)))
    speech = int(np.flatnonzero(rms[:limit] > peak * 10 ** (_SPEECH_DB / 20))[-1])
    speech_end = min(n, (speech + 1) * frame)
    end = min(n, speech_end + keep)
    out = np.array(audio[:end], dtype=np.float32)
    fade = min(int(_FADE_S * sample_rate), end - speech_end)
    if fade > 0:
        out[end - fade:] *= np.linspace(1.0, 0.0, fade, dtype=np.float32)
    return out


def silence(seconds: float, sample_rate: int = SAMPLE_RATE) -> np.ndarray:
    return np.zeros(int(round(seconds * sample_rate)), dtype=np.float32)


def to_wav(audio: np.ndarray, sample_rate: int = SAMPLE_RATE) -> bytes:
    """PCM16 mono WAV bytes."""
    pcm = np.clip(np.nan_to_num(audio), -1.0, 1.0)
    pcm = np.round(pcm * 32767.0).astype("<i2")
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sample_rate)
        w.writeframes(pcm.tobytes())
    return buf.getvalue()
