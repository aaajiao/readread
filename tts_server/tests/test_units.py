"""Fast unit tests: pinyin conversion, phoneme ownership and alignment, audio helpers."""

from __future__ import annotations

import io
import wave
from dataclasses import dataclass

import numpy as np
import pytest

from readread_tts import audio, zhuyin
from readread_tts.g2p import Builder, align


# --- zhuyin -------------------------------------------------------------------------------------------

@pytest.mark.parametrize("pinyin, symbols", [
    ("hang2", "ㄏㄤ2"), ("yin2", "阴2"), ("dei3", "ㄉㄟ3"), ("le5", "ㄌㄜ5"), ("yi1", "ㄧ1"), ("zhi1", "ㄓ十1"),
    ("zi3", "ㄗㄭ3"), ("ri4", "ㄖ十4"), ("ju4", "ㄐㄩ4"), ("lv4", "ㄌㄩ4"), ("nü3", "ㄋㄩ3"), ("yuan2", "元2"),
    ("you3", "又3"), ("wei4", "为4"), ("er2", "ㄦ2"), ("dianr3", "ㄉ言R3"),
])
def test_encode_matches_misaki_symbols(pinyin, symbols):
    assert zhuyin.encode(pinyin) == symbols
    assert zhuyin.decode(symbols) == pinyin.replace("ü", "v")


@pytest.mark.parametrize("bad", ["hang", "hang6", "xx2", "hx2", "", "hang 2", "zh1"])
def test_encode_rejects_non_syllables(bad):
    with pytest.raises(ValueError):
        zhuyin.encode(bad)


def test_encode_agrees_with_misaki_on_a_sentence(zh_g2p):
    # Every syllable misaki produces must survive decode -> encode unchanged.
    from misaki.zh import ZHG2P

    _, tokens = zh_g2p._g2p.frontend(ZHG2P.map_punctuation("银行行长说，我们会重复检查每一笔交易，觉得没有问题再放行。"))
    for tk in tokens:
        for syllable in zhuyin.split_syllables(tk.phonemes or "") or []:
            assert zhuyin.encode(zhuyin.decode(syllable)) == syllable


# --- phoneme ownership and alignment ---------------------------------------------------------------------

@dataclass
class T:
    phoneme: str
    start: float
    end: float


def test_builder_collapses_whitespace_like_kokoro():
    b = Builder()
    b.sep("  ")
    b.token("Hi", "hˈI")
    b.sep(" \n ")
    b.token(",", ",")
    b.sep(" ")
    b.token("you", "jˈu")
    b.sep("  ")
    ph = b.build()
    raw = "  hˈI \n , jˈu  "
    assert ph.text == " ".join(raw.split())
    assert [ph.tokens[o].text if o >= 0 else None for o in ph.owners] == \
        ["Hi"] * 3 + [None, ","] + [None] + ["you"] * 3
    assert [t.spoken for t in ph.tokens] == [True, False, True]


def test_align_groups_timings_and_skips_spaces_dropped_at_batch_cuts():
    b = Builder()
    b.token("ab", "ab")
    b.sep(" ")
    b.token(".", ".")
    b.sep(" ")
    b.token("cd", "cd")
    ph = b.build()  # "ab . cd"
    # kokoro split it into "ab ." and "cd": the space between the batches has no timing.
    timings = [T("a", 0.0, 0.1), T("b", 0.1, 0.2), T(" ", 0.2, 0.25), T(".", 0.25, 0.3),
               T("c", 0.6, 0.7), T("d", 0.7, 0.8)]
    out = [(tok.text, s, e) for tok, s, e in align(ph, timings, set("abcd. "))]
    assert out == [("ab", 0.0, 0.2), ("cd", 0.6, 0.8)]


def test_align_ignores_symbols_outside_the_vocabulary():
    b = Builder()
    b.token("x", "a❓b")
    ph = b.build()
    out = align(ph, [T("a", 0.0, 0.1), T("b", 0.1, 0.3)], set("ab"))
    assert [(tok.text, s, e) for tok, s, e in out] == [("x", 0.0, 0.3)]


# --- audio ------------------------------------------------------------------------------------------------

def _frames_db(x: np.ndarray, frame: int = 120) -> np.ndarray:
    n = -(-len(x) // frame)
    padded = np.zeros(n * frame)
    padded[:len(x)] = x
    rms = np.sqrt((padded.reshape(n, frame) ** 2).mean(axis=1))
    return 20 * np.log10(np.maximum(rms, 1e-12) / rms.max())


SR = audio.SAMPLE_RATE
SPEECH_END = int(0.5 * SR) + int(0.03 * SR)  # end of the decay in _speech_with_tail


def _speech_with_tail(rng) -> np.ndarray:
    """0.5 s tone, a 30 ms decay from -34 to -54 dB, kokoro's spliced 0.2 s of zeros, then -56 dB noise."""
    t = np.arange(int(0.5 * SR)) / SR
    speech = 0.5 * np.sin(2 * np.pi * 220 * t)
    decay = 0.5 * np.sin(2 * np.pi * 220 * t[:int(0.03 * SR)]) * np.linspace(0.02, 0.002, int(0.03 * SR))
    zeros = np.zeros(int(0.2 * SR))
    noise = rng.normal(0, 0.5 * 10 ** (-56 / 20), int(0.04 * SR))
    return np.concatenate([speech, decay, zeros, noise]).astype(np.float32)


def test_trim_tail_keeps_speech_and_at_most_40_ms_after_it():
    x = _speech_with_tail(np.random.default_rng(1))
    y = audio.trim_tail(x)
    loud_end = (np.flatnonzero(_frames_db(x) > -40)[-1] + 1) * 120
    assert len(y) >= loud_end  # nothing above -40 dB is cut ...
    np.testing.assert_array_equal(y[:SPEECH_END - 120], x[:SPEECH_END - 120])  # ... or faded
    speech_end = (np.flatnonzero(_frames_db(y) > -50)[-1] + 1) * 120
    assert len(y) - speech_end <= int(0.040 * SR) + 120
    assert len(y) <= SPEECH_END + int(0.040 * SR)  # the pause and the noise after it are gone
    assert abs(y[-1]) < 1e-4  # the kept tail fades out


def test_trim_tail_leaves_short_audio_alone_and_handles_silence():
    x = (0.3 * np.sin(np.arange(2400) / 5)).astype(np.float32)
    assert len(audio.trim_tail(x)) == len(x)
    assert len(audio.trim_tail(np.zeros(24000, dtype=np.float32))) == int(0.040 * SR)
    assert len(audio.trim_tail(np.zeros(0, dtype=np.float32))) == 0


def test_wav_is_pcm16_mono_24k():
    x = np.array([0.0, 0.5, -0.5, 1.5, -2.0, np.nan], dtype=np.float32)
    data = audio.to_wav(x)
    with wave.open(io.BytesIO(data)) as w:
        assert (w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()) == (1, 2, 24000, 6)
        samples = np.frombuffer(w.readframes(6), dtype="<i2")
    assert samples.tolist() == [0, 16384, -16384, 32767, -32767, 0]
    assert len(audio.silence(0.15)) == 3600
