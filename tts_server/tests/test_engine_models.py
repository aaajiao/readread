"""Synthesis with the real models (skipped unless READREAD_MODELS_DIR is set): one model call per sentence,
trimmed sentence tails, 250 ms gaps, token timings, long sentences, cancellation, front-end failures."""

from __future__ import annotations

import numpy as np
import pytest

from readread_tts import audio
from readread_tts.engine import MAX_PHONEMES, SENTENCE_GAP_S, Cancelled, VoiceError, soft_breaks

SR = audio.SAMPLE_RATE
FRAME = int(0.005 * SR)


@pytest.fixture
def calls(engine, monkeypatch):
    """Phoneme strings handed to create_timed, per route, while the test runs."""
    seen: list[tuple[str, str]] = []
    for name, route in engine._routes.items():
        original = route.kokoro.create_timed

        def spy(phonemes, *args, _name=name, _original=original, **kwargs):
            seen.append((_name, phonemes))
            return _original(phonemes, *args, **kwargs)

        monkeypatch.setattr(route.kokoro, "create_timed", spy)
    return seen


def frames_db(x: np.ndarray, peak: float) -> np.ndarray:
    n = -(-len(x) // FRAME)
    padded = np.zeros(n * FRAME)
    padded[:len(x)] = x
    rms = np.sqrt((padded.reshape(n, FRAME) ** 2).mean(axis=1))
    return 20 * np.log10(np.maximum(rms, 1e-12) / peak)


def test_voice_resolution(engine):
    assert engine.resolve("zf_001").route == "zh"
    assert engine.resolve("af_heart").british is False
    assert engine.resolve("bm_george").british is True
    with pytest.raises(VoiceError) as info:
        engine.resolve("zf_xiaobei")
    assert info.value.code == "unknown_voice"
    with pytest.raises(VoiceError) as info:
        engine.resolve("zf_001", "en")
    assert info.value.code == "voice_language_mismatch"


def test_one_model_call_per_sentence(engine, calls):
    text = "第一句话。第二句话！第三句话？"
    result = engine.synthesize(text, engine.resolve("zf_001"))
    assert [route for route, _ in calls] == ["zh"] * 3
    assert len(result.sentences) == 3
    calls.clear()
    engine.synthesize("One. Two! Three? Four.", engine.resolve("af_heart"))
    assert [route for route, _ in calls] == ["en"] * 4


def test_the_accent_follows_the_voice(engine, calls):
    engine.synthesize("A tomato.", engine.resolve("af_heart"))
    engine.synthesize("A tomato.", engine.resolve("bf_emma"))
    assert "təmˈATO" in calls[0][1] and "təmˈɑːtQ" in calls[1][1]


@pytest.mark.parametrize("voice, sentence", [
    ("zf_001", "今天天气很好，我们一起去公园散步吧。"),
    ("zm_009", "你真的要走吗？"),
    ("zf_032", "太好了！"),
    ("af_heart", "The quick brown fox jumps over the lazy dog."),
    ("am_michael", "Are you sure about that?"),
    ("bf_emma", "What a lovely day!"),
])
def test_sentence_tail_is_trimmed_without_cutting_speech(engine, voice, sentence):
    v = engine.resolve(voice)
    route = engine._routes[v.route]
    from readread_tts import frontend_en, frontend_zh

    if v.route == "zh":
        phonemes = engine._chinese_g2p().phonemize(frontend_zh.normalize(sentence))
    else:
        phonemes = engine._english_g2p(v.british).phonemize(frontend_en.normalize(sentence))
    raw, rate, _ = route.kokoro.create_timed(phonemes.text, voice=route.kokoro.get_voice_style(voice), speed=1.0,
                                             is_phonemes=True)
    raw = np.asarray(raw, dtype=np.float32)
    trimmed = audio.trim_tail(raw, rate)
    peak = float(np.sqrt((np.pad(raw, (0, -len(raw) % FRAME)).reshape(-1, FRAME) ** 2).mean(axis=1)).max())
    cut = frames_db(raw[len(trimmed):], peak)
    assert len(cut) == 0 or cut.max() < -40, f"cut a frame at {cut.max():.1f} dB"
    kept = frames_db(trimmed, peak)
    speech_end = (np.flatnonzero(kept > -50)[-1] + 1) * FRAME
    assert len(trimmed) - speech_end <= int(0.040 * SR) + FRAME
    assert len(raw) - len(trimmed) > int(0.15 * SR)  # kokoro's ~0.25 s pause is gone


def test_sentences_are_joined_with_250_ms_of_silence(engine):
    result = engine.synthesize("Hello there. How are you?", engine.resolve("af_heart"))
    (a, b), (c, d) = ((s["start"], s["end"]) for s in result.sentences)
    assert a == 0.0 and abs(c - b - SENTENCE_GAP_S) <= 0.0015 and abs(d - result.duration) <= 0.0015
    gap = result.audio[int(round(b * SR)) + 1:int(round(c * SR)) - 1]
    assert len(gap) >= int(0.24 * SR) and not gap.any()


@pytest.mark.parametrize("voice, text", [
    ("zf_001", "，".join(["这是一个很长的句子"] * 40) + "。"),
    ("af_heart", ", ".join(["this is a rather long clause without an end"] * 20) + "."),
])
def test_a_sentence_over_510_phonemes(engine, calls, voice, text):
    result = engine.synthesize(text, engine.resolve(voice))
    assert len(result.sentences) == 1 and len(calls) > 1  # one call per kokoro batch
    assert all(len(phonemes) <= MAX_PHONEMES for _, phonemes in calls)
    starts = [t["start"] for t in result.tokens]
    assert starts == sorted(starts)
    assert all(0 <= t["start"] <= t["end"] <= result.duration for t in result.tokens)
    spoken = [w for w in text.replace("，", " ").replace(",", " ").replace("。", " ").replace(".", " ").split()]
    if voice.startswith("a"):
        assert [t["text"] for t in result.tokens] == spoken  # every word timed, across the batch cuts
    else:
        assert "".join(t["text"] for t in result.tokens) == "".join(spoken)
    assert result.tokens[-1]["end"] > result.duration - 1.0


def test_a_run_without_marks_is_cut_at_word_boundaries(engine, calls):
    text = "这是一个很长的句子没有任何标点符号" * 40 + "。"
    result = engine.synthesize(text, engine.resolve("zf_001"))
    assert len(result.sentences) == 1 and len(calls) > 1
    for _, phonemes in calls[:-1]:
        assert len(phonemes) <= MAX_PHONEMES and phonemes[-1].isdigit()  # a whole syllable, tone included
    assert "".join(t["text"] for t in result.tokens) == text[:-1]


def test_soft_breaks():
    assert soft_breaks("ab/cd/ef gh", limit=4) == "ab cd ef gh"
    assert soft_breaks("ab/cd/ef", limit=5) == "ab/cd ef"  # only as many breaks as needed
    assert soft_breaks("ㄋㄧ3ㄏㄠ3ㄇㄚ5", limit=5) == "ㄋㄧ3 ㄏㄠ3 ㄇㄚ5"  # after a tone digit
    assert soft_breaks("abcdefgh", limit=3) == "abc def gh"
    assert soft_breaks("short/run", limit=510) == "short/run"


def test_cancellation_between_sentences(engine, calls):
    checks = iter([False, True])
    with pytest.raises(Cancelled):
        engine.synthesize("一。二。三。", engine.resolve("zf_001"), cancelled=lambda: next(checks))
    assert len(calls) == 1


def test_cancellation_between_the_batches_of_a_long_sentence(engine, calls):
    checks = iter([False, True])  # before the sentence, then before its second batch
    with pytest.raises(Cancelled):
        engine.synthesize("这是一个很长的句子没有任何标点符号" * 40 + "。", engine.resolve("zf_001"),
                          cancelled=lambda: next(checks))
    assert len(calls) == 1


def test_a_sentence_the_front_end_fails_on_is_skipped(engine, calls, monkeypatch):
    from readread_tts import frontend_en

    original = frontend_en.normalize

    def normalize(text):
        if "boom" in text:
            raise OverflowError("boom")
        return original(text)

    monkeypatch.setattr(frontend_en, "normalize", normalize)
    result = engine.synthesize("One. The boom. Three.", engine.resolve("af_heart"))
    assert [s["text"] for s in result.sentences] == ["One.", "Three."] and len(calls) == 2
    with pytest.raises(OverflowError):  # nothing left to say: the error is not hidden as silence
        engine.synthesize("The boom.", engine.resolve("af_heart"))


def test_nothing_speakable(engine, calls):
    result = engine.synthesize("--- • • • 🎉", engine.resolve("af_heart"))
    assert result.silent and result.duration == 0.15 and result.tokens == [] and calls == []
