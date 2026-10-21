"""The Qwen engine without MLX: a fake model (tests/fakes/fake_qwen.py) behind a fake backend. Voices, the front end,
seeds, the token cap, retries, cancellation, sentence timings, synth_speed, warm-up, the one MLX thread, the model
checks, and the pins in scripts/lib/versions.sh."""

from __future__ import annotations

import hashlib
import logging
import os
import re
import subprocess
import sys
import threading

import numpy as np
import pytest
from conftest import SERVER_DIR, make_qwen_models
from fakes import fake_qwen

from readread_tts import audio, engine_qwen, frontend_en, frontend_zh, sentences
from readread_tts.engine import QWEN_MODELS, SENTENCE_GAP_S, Cancelled, VoiceError
from readread_tts.engine_qwen import (MAX_ATTEMPTS, MODEL_FILES, MODELS, expected_seconds, max_tokens, next_seed,
                                      terminal_stop, text_seed)

SR = audio.SAMPLE_RATE
REPO = SERVER_DIR.parent


class FakeBackend:
    """engine_qwen.MLXBackend's interface over a FakeModel; records which threads it is called on."""

    def __init__(self, fail_loads: int = 0) -> None:
        self.model = fake_qwen.FakeModel(delay=0)
        self.loads: list[str] = []
        self.seeds: list[int] = []
        self.cleared = 0
        self.threads: set[int] = set()
        self.fail_loads = fail_loads

    def load(self, path: str):
        self.threads.add(threading.get_ident())
        self.loads.append(path)
        if self.fail_loads:
            self.fail_loads -= 1
            raise RuntimeError("load failed")
        return self.model

    def seed(self, seed: int) -> None:
        self.threads.add(threading.get_ident())
        self.seeds.append(seed)
        fake_qwen.current_seed = seed

    def clear_cache(self) -> None:
        self.threads.add(threading.get_ident())
        self.cleared += 1


@pytest.fixture
def backend() -> FakeBackend:
    return FakeBackend()


@pytest.fixture
def engine(backend, tmp_path, monkeypatch):
    monkeypatch.setenv("HF_HOME", str(tmp_path / "hf-before"))  # the engine repoints it; restored afterwards
    return engine_qwen.Engine(str(tmp_path / "models"), "1.7b", str(tmp_path / "cache"), backend=backend)


def texts(backend: FakeBackend, skip_warmup: bool = True) -> list[str]:
    calls = backend.model.calls
    if skip_warmup:
        calls = [c for c in calls if c["text"] not in ("你好。", "Hello.")]
    return [c["text"] for c in calls]


def spoken(text: str, route: str) -> list[str]:
    """What the engine should hand the model for text: the shared front end per sentence."""
    normalize = frontend_zh.normalize if route == "zh" else frontend_en.normalize
    return [terminal_stop(normalize(s)) for s in sentences.split(sentences.clean(text), route)
            if sentences.is_speakable(s)]


# --- voices ---------------------------------------------------------------------------------------------

def test_voices(engine):
    assert engine.voice_lists() == {"zh": ["serena"], "en": ["aiden"]}
    assert engine.resolve("serena").route == "zh" and engine.resolve("aiden", "en-gb").route == "en"
    assert engine.resolve("aiden", "en").british is False


@pytest.mark.parametrize("voice, lang, code", [
    ("Serena", None, "unknown_voice"), ("ryan", None, "unknown_voice"), ("zf_001", None, "unknown_voice"),
    ("af_heart", "en", "unknown_voice"), ("", None, "unknown_voice"),
    ("serena", "en", "voice_language_mismatch"), ("serena", "en-us", "voice_language_mismatch"),
    ("aiden", "zh", "voice_language_mismatch"),
])
def test_voice_errors(engine, voice, lang, code):
    with pytest.raises(VoiceError) as error:
        engine.resolve(voice, lang)
    assert error.value.code == code


def test_voice_lists_are_copies(engine):
    engine.voice_lists()["zh"].append("x")
    assert engine.voice_lists()["zh"] == ["serena"]


# --- importing the module -------------------------------------------------------------------------------

def test_importing_the_engine_needs_no_mlx_and_switches_hugging_face_offline():
    code = ("import os, sys; sys.path.insert(0, sys.argv[1]); import readread_tts.engine_qwen as q; "
            "heavy = sorted(m for m in sys.modules if m.partition('.')[0] in "
            "('mlx', 'mlx_audio', 'transformers', 'huggingface_hub', 'tokenizers', 'safetensors', 'torch', "
            "'onnxruntime', 'kokoro_onnx', 'spacy', 'misaki')); "
            "print(heavy, [os.environ.get(k) for k in ('HF_HUB_OFFLINE', 'TRANSFORMERS_OFFLINE', "
            "'HF_HUB_DISABLE_TELEMETRY')])")
    env = {k: v for k, v in os.environ.items() if not k.startswith(("HF_", "TRANSFORMERS_"))}
    out = subprocess.run([sys.executable, "-I", "-B", "-c", code, str(SERVER_DIR)], capture_output=True, text=True,
                         env=env, timeout=60)
    assert out.returncode == 0, out.stderr
    assert out.stdout.strip() == "[] ['1', '1', '1']"


# --- front end ------------------------------------------------------------------------------------------

@pytest.mark.parametrize("text, expected", [
    ("你好。", "你好。"), ("你好", "你好。"), ("如下：", "如下。"), ("首先，", "首先。"),
    ("他说：“你好”", "他说：“你好”。"), ("他说：“你好！”", "他说：“你好！”"), ("Getting Started", "Getting Started."),
    ("Hello,", "Hello."), ("Wait...", "Wait..."), ("Really?", "Really?"), ("(see above)", "(see above)."),
    ("第一章，风起云涌", "第一章，风起云涌。"),
    ("Version 2 point 4 point 1", "Version 2 point 4 point 1."), ("”", "”"), ("", ""),
])
def test_terminal_stop(text, expected):
    assert terminal_stop(text) == expected


def test_each_sentence_goes_through_the_shared_front_end(engine, backend):
    zh = "第一章 风起云涌\n2026年10月20日，苹果发布了 iPhone 17 Pro，起售价为¥7999。他說：「今天天氣很好」"
    engine.synthesize(zh, engine.resolve("serena"))
    assert texts(backend) == spoken(zh, "zh")
    assert texts(backend)[0] == "第一章，风起云涌。"  # the space is a pause; the heading gets its stop
    assert "说" in texts(backend)[-1]  # Traditional -> Simplified
    en = "Getting Started\nDr. Smith arrived on 2026-10-20 at 10:30 a.m. It costs $5."
    before = len(texts(backend))
    engine.synthesize(en, engine.resolve("aiden"))
    assert texts(backend)[before:] == spoken(en, "en")
    assert texts(backend)[before] == "Getting Started."
    by_voice = {c["voice"]: c["lang_code"] for c in backend.model.calls}
    assert by_voice == {"serena": "chinese", "aiden": "english"}


def test_a_sentence_the_front_end_fails_on_is_skipped(engine, backend, monkeypatch, caplog):
    original = frontend_en.normalize

    def normalize(text):
        if "boom" in text:
            raise ValueError("boom")
        return original(text)

    monkeypatch.setattr(frontend_en, "normalize", normalize)
    result = engine.synthesize("One. The boom. Three.", engine.resolve("aiden"))
    assert [s["text"] for s in result.sentences] == ["One.", "Three."]
    assert "sentence 2 (9 chars) skipped, the en front end failed: ValueError: boom" in caplog.text
    with pytest.raises(ValueError, match="boom"):
        engine.synthesize("The boom.", engine.resolve("aiden"))


@pytest.mark.parametrize("text", ["", "   ", "---", "• • •", "🎉🎉", "***\n___"])
def test_nothing_to_say_is_150_ms_of_silence(engine, backend, text):
    engine.load("zh")
    calls = len(backend.model.calls)
    result = engine.synthesize(text, engine.resolve("serena"))
    assert result.silent and result.duration == 0.15 and not result.audio.any()
    assert result.sentences == [] and result.tokens == [] and len(backend.model.calls) == calls


# --- generation -----------------------------------------------------------------------------------------

def test_the_seed_is_a_hash_of_voice_and_text(engine, backend):
    first = engine.synthesize("今天天气很好。", engine.resolve("serena"))
    again = engine.synthesize("今天天气很好。", engine.resolve("serena"))
    other = engine.synthesize("Today is fine.", engine.resolve("aiden"))
    seeds = [c["seed"] for c in backend.model.calls if c["text"] in ("今天天气很好。", "Today is fine.")]
    assert seeds[0] == seeds[1] == int.from_bytes(hashlib.sha1("serena|今天天气很好。".encode()).digest()[:4],
                                                  "little") & 0x7FFFFFFF
    assert seeds[2] == text_seed("Today is fine.", "aiden") != seeds[0]
    assert np.array_equal(first.audio, again.audio) and not np.array_equal(first.audio[:SR], other.audio[:SR])
    assert next_seed(seeds[0]) == (seeds[0] * 1103515245 + 12345) & 0x7FFFFFFF


def test_every_generation_streams_with_the_token_cap(engine, backend):
    text = "银行行长说，我们会重复检查每一笔交易。Then English."
    engine.synthesize(text, engine.resolve("serena"))
    for call in backend.model.calls:
        assert call["stream"] is True and call["streaming_interval"] == 0.32 and call["verbose"] is False
        assert call["max_tokens"] == int(12.5 * (0.5 * len(call["text"]) + 3)) == max_tokens(call["text"])
        assert call["extra"] == []  # no speed, no instruct
    assert max_tokens("你好。") == 56


def test_a_runaway_is_cut_short_and_retried_with_another_seed(engine, backend, caplog):
    text = "这是一个普通的句子 zzrunawayonce。"
    result = engine.synthesize(text, engine.resolve("serena"))
    calls = [c for c in backend.model.calls if "zzrunawayonce" in c["text"]]
    assert [c["seed"] for c in calls] == [text_seed(calls[0]["text"], "serena"),
                                         next_seed(text_seed(calls[0]["text"], "serena"))]
    limit = 2.5 * expected_seconds(calls[0]["text"]) + 1.0
    assert calls[0]["closed"] and calls[0]["tokens"] < calls[0]["max_tokens"]  # stopped at the limit, not the cap
    assert limit <= calls[0]["tokens"] * 0.08 <= limit + 0.32 + 1e-9
    assert calls[1]["finished"] and not calls[1]["closed"]
    assert result.duration < limit
    assert "gave a runaway" in caplog.text and "retrying with another seed" in caplog.text


def test_hitting_the_token_cap_counts_as_a_runaway(engine, backend):
    # Short text: the cap (12.5 * (0.5 * len + 3) tokens) comes before 2.5x the expected length + 1 s.
    text = "zzrunawayonce" + "啊" * 100 + "。"
    engine.synthesize(text, engine.resolve("serena"))
    calls = [c for c in backend.model.calls if "zzrunawayonce" in c["text"]]
    assert calls[0]["tokens"] == calls[0]["max_tokens"] and calls[0]["max_tokens"] * 0.08 < (
        2.5 * expected_seconds(calls[0]["text"]) + 1.0)
    assert len(calls) == 2 and calls[1]["finished"]


def test_too_little_audio_is_retried(engine, backend, caplog):
    result = engine.synthesize("zzshortonce 今天天气很好，我们一起去公园散步吧。", engine.resolve("serena"))
    calls = [c for c in backend.model.calls if "zzshortonce" in c["text"]]
    assert len(calls) == 2 and calls[0]["tokens"] == fake_qwen.SHORT_TOKENS
    assert result.duration > 1.0 and "too little audio" in caplog.text


def test_when_every_attempt_fails_the_most_plausible_is_used(engine, backend, caplog):
    result = engine.synthesize("zzrunaway 你好。", engine.resolve("serena"))
    calls = [c for c in backend.model.calls if "zzrunaway" in c["text"]]
    assert len(calls) == MAX_ATTEMPTS
    assert [c["seed"] for c in calls[1:]] == [next_seed(calls[0]["seed"]), next_seed(next_seed(calls[0]["seed"]))]
    assert result.duration > 0 and "no plausible generation in 3 attempts" in caplog.text
    engine.synthesize("zzshort 今天天气很好，我们一起去公园散步吧。", engine.resolve("serena"))
    assert len([c for c in backend.model.calls if "zzshort" in c["text"].split()]) == MAX_ATTEMPTS


def test_the_mlx_cache_is_cleared_after_every_generation(engine, backend):
    engine.synthesize("一。二。", engine.resolve("serena"))
    assert backend.cleared == len(backend.model.calls) == 3  # warm-up + 2 sentences


# --- cancellation ---------------------------------------------------------------------------------------

def test_cancellation_between_streamed_chunks(engine, backend):
    engine.load("zh")
    checks = iter([False, False, True])
    cleared = backend.cleared
    with pytest.raises(Cancelled):
        engine.synthesize("今天天气很好，我们一起去公园散步吧。" * 3, engine.resolve("serena"),
                          cancelled=lambda: next(checks))
    last = backend.model.calls[-1]
    assert last["chunks"] == 2 and last["closed"]  # stopped after the second chunk; the stream was closed
    assert backend.cleared == cleared + 1 and len(backend.model.calls) == 2


def test_cancellation_between_sentences(engine, backend):
    engine.load("zh")
    calls = backend.model.calls
    with pytest.raises(Cancelled):
        engine.synthesize("一。二。三。", engine.resolve("serena"),
                          cancelled=lambda: sum(c["finished"] for c in calls) >= 2)
    assert texts(backend) == ["一。"] and calls[-1]["finished"]


# --- the result -----------------------------------------------------------------------------------------

def test_sentence_timings_and_no_tokens(engine):
    result = engine.synthesize("今天天气很好。我们走吧！\nGo.", engine.resolve("serena"))
    assert [s["text"] for s in result.sentences] == ["今天天气很好。", "我们走吧！", "Go."]
    assert result.tokens == [] and result.sample_rate == SR and not result.silent
    spans = [(s["start"], s["end"]) for s in result.sentences]
    assert spans[0][0] == 0.0 and abs(spans[-1][1] - result.duration) <= 0.001
    for (_, end), (start, _) in zip(spans, spans[1:]):
        assert abs(start - end - SENTENCE_GAP_S) <= 0.0015
    for (start, end), text in zip(spans, ["今天天气很好。", "我们走吧！", "Go."]):
        speech = fake_qwen.speech_seconds(text)
        assert speech <= end - start <= speech + 0.03 + 0.04 + 0.006  # the kept lead and tail
    assert result.frontend_ms > 0 and result.synth_ms > 0


def test_silence_around_each_sentence_is_trimmed(engine):
    result = engine.synthesize("好。", engine.resolve("serena"))
    lead = np.flatnonzero(np.abs(result.audio) > 0.01)[0] / SR
    tail = (len(result.audio) - np.flatnonzero(np.abs(result.audio) > 0.01)[-1]) / SR
    assert 0.02 <= lead <= 0.035 and 0.03 <= tail <= 0.046  # of 0.24 s generated on either side


def test_synth_speed_is_always_one(engine):
    result = engine.synthesize("你好，世界。", engine.resolve("serena"), speed=1.7)
    assert result.synth_speed == 1.0
    assert engine.synthesize("你好，世界。", engine.resolve("serena"), speed=0.5).duration == result.duration


# --- loading and threads --------------------------------------------------------------------------------

def test_warm_up_per_route_and_one_model_load(engine, backend):
    assert engine.loaded() == [] and backend.loads == []
    engine.load("zh")
    assert backend.loads == [os.path.join(engine.model_path)] and engine.loaded() == ["zh"]
    assert [(c["text"], c["voice"], c["lang_code"]) for c in backend.model.calls] == [("你好。", "serena", "chinese")]
    engine.load("zh")
    engine.load("en")
    assert len(backend.loads) == 1 and engine.loaded() == ["zh", "en"]
    assert backend.model.calls[-1]["text"] == "Hello." and backend.model.calls[-1]["voice"] == "aiden"
    assert engine.model_path.endswith(os.path.join("models", "Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit"))


def test_a_route_loads_on_demand(engine, backend):
    engine.synthesize("Hello there.", engine.resolve("aiden"))
    assert engine.loaded() == ["en"]
    assert [c["text"] for c in backend.model.calls] == ["Hello.", "Hello there."]


def test_a_failed_load_is_raised_and_tried_again(tmp_path, monkeypatch):
    monkeypatch.setenv("HF_HOME", str(tmp_path / "hf"))
    backend = FakeBackend(fail_loads=1)
    engine = engine_qwen.Engine(str(tmp_path), "1.7b", str(tmp_path / "cache"), backend=backend)
    with pytest.raises(RuntimeError, match="load failed"):
        engine.load("zh")
    assert engine.loaded() == []
    engine.load("zh")
    assert engine.loaded() == ["zh"] and len(backend.loads) == 2


def test_every_model_call_runs_on_the_one_mlx_thread(engine, backend):
    results = []
    workers = [threading.Thread(target=lambda: results.append(engine.synthesize("一。", engine.resolve("serena"))))
               for _ in range(3)]
    for w in workers:
        w.start()
    for w in workers:
        w.join(30)
    assert len(results) == 3
    threads = backend.threads | backend.model.threads
    assert len(threads) == 1 and threads.isdisjoint({w.ident for w in workers} | {threading.get_ident()})


def test_errors_on_the_mlx_thread_reach_the_caller(engine, backend, monkeypatch):
    def broken(*args, **kwargs):
        raise MemoryError("out of memory")

    engine.load("zh")
    monkeypatch.setattr(backend.model, "generate", broken)
    with pytest.raises(MemoryError, match="out of memory"):
        engine.synthesize("你好。", engine.resolve("serena"))


def test_the_engine_points_hugging_face_at_its_cache(engine, tmp_path):
    assert os.environ["HF_HOME"] == str(tmp_path / "cache" / "hf")
    assert {k: os.environ[k] for k in engine_qwen.OFFLINE_ENV} == {
        "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1"}


def test_versions_names_the_mlx_stack(engine):
    assert set(engine.versions()) == {"mlx", "mlx_audio", "transformers", "misaki", "python"}
    assert engine.name == "qwen" and engine.model == "1.7b"


def test_an_unknown_model_is_refused(tmp_path):
    with pytest.raises(ValueError, match="unknown model"):
        engine_qwen.Engine(str(tmp_path), "3b", str(tmp_path))


# --- model files and pins -------------------------------------------------------------------------------

def test_check_models(tmp_path):
    models = make_qwen_models(tmp_path / "models", ["1.7b"])
    assert engine_qwen.check_models(models, "1.7b") == []
    assert engine_qwen.check_models(str(tmp_path / "nowhere"), "1.7b") == [
        f"models directory not found: {tmp_path / 'nowhere'} (run ./scripts/install-hq.sh)"]
    (tmp_path / "empty").mkdir()
    assert engine_qwen.check_models(str(tmp_path / "empty"), "1.7b") == [
        f"model folder not found: {tmp_path / 'empty' / MODELS['1.7b']} (run ./scripts/install-hq.sh)"]
    weights = tmp_path / "models" / MODELS["1.7b"] / "model.safetensors"
    with open(weights, "wb") as f:
        f.truncate(100)
    (tmp_path / "models" / MODELS["1.7b"] / "vocab.json").unlink()
    problems = engine_qwen.check_models(models, "1.7b")
    assert problems[0] == f"{weights} is 100 bytes, expected 2393308931"
    assert problems[1].startswith("missing model file ") and problems[1].endswith(
        "vocab.json (re-run ./scripts/install-hq.sh)")


def versions_sh() -> dict[str, str]:
    """The RR_HQ_* settings of scripts/lib/versions.sh (simple NAME="value" lines, values may span lines)."""
    text = (REPO / "scripts" / "lib" / "versions.sh").read_text(encoding="utf-8")
    return dict(re.findall(r'^(RR_HQ_\w+)="([^"]*)"', text, re.M))


def test_the_engine_agrees_with_the_pins_in_versions_sh():
    pins = versions_sh()
    assert pins["RR_HQ_MODELS"].split() == list(QWEN_MODELS) == list(MODELS) == ["1.7b"]  # one model, the default
    # No pins of another model are left (versions.sh once pinned a second one).
    assert {name for name in pins if name.endswith("_REPO")} == {"RR_HQ_1_7B_REPO"}
    assert "RR_HQ_DEFAULT_MODEL" not in pins
    for model in QWEN_MODELS:
        key = model.replace(".", "_").upper()
        assert pins[f"RR_HQ_{key}_REPO"] == f"mlx-community/{MODELS[model]}"
        assert re.fullmatch(r"[0-9a-f]{40}", pins[f"RR_HQ_{key}_REVISION"])
        files = {path: int(size) for path, size, sha in (line.split() for line in pins[f"RR_HQ_{key}_FILES"].split("\n")
                                                         if line.strip())}
        assert files.pop("README.md") > 0  # downloaded with the rest, never read
        assert files == MODEL_FILES[model]


def test_install_hq_installs_the_server_dependencies():
    # The qwen route's imports (tts_server.py's REQUIRED_MODULES) are what requirements-hq.in pins, plus their deps.
    lock = (SERVER_DIR / "requirements-hq.lock").read_text(encoding="utf-8")
    pinned = {re.sub(r"[-_.]+", "-", m).lower() for m in re.findall(r"^([A-Za-z0-9][A-Za-z0-9._-]*)==", lock, re.M)}
    for module, dist in [("mlx", "mlx"), ("mlx_audio", "mlx-audio"), ("transformers", "transformers"),
                         ("tokenizers", "tokenizers"), ("huggingface_hub", "huggingface-hub"),
                         ("safetensors", "safetensors"), ("misaki", "misaki"), ("opencc", "opencc"),
                         ("num2words", "num2words"), ("pypinyin", "pypinyin"), ("numpy", "numpy")]:
        assert dist in pinned, module
    assert not pinned & {"onnxruntime", "kokoro-onnx", "spacy", "en-core-web-sm", "phonemizer-fork", "espeakng-loader"}
    assert re.search(r"^mlx==0\.32\.4 ", lock, re.M) and re.search(r"^mlx-audio==0\.6\.0 ", lock, re.M)


def test_audio_trim_head():
    lead = np.random.default_rng(1).normal(0, 3e-5, int(0.3 * SR)).astype(np.float32)
    tone = (0.3 * np.sin(2 * np.pi * 220 * np.arange(int(0.5 * SR)) / SR)).astype(np.float32)
    out = audio.trim_head(np.concatenate([lead, tone]))
    onset = np.flatnonzero(np.abs(out) > 0.01)[0] / SR
    assert 0.025 <= onset <= 0.031 and len(out) == pytest.approx(0.53 * SR, abs=0.006 * SR)
    assert np.allclose(out[-len(tone):], tone)  # the speech is untouched
    assert len(audio.trim_head(np.zeros(SR, dtype=np.float32))) == int(0.03 * SR)
    assert len(audio.trim_head(np.zeros(0, dtype=np.float32))) == 0
    assert np.array_equal(audio.trim_head(tone), tone)  # nothing to trim


def test_engine_logs_go_to_the_engine_logger(engine, caplog):
    caplog.set_level(logging.INFO, logger="readread.engine")
    engine.load("zh")
    assert "route zh ready in" in caplog.text and "model 1.7b loaded from" in caplog.text


def test_only_the_expected_config_warning_of_transformers_is_dropped():
    # transformers 5.x logs it on every load of the model (the real run's log line starts with "[transformers]"); it is
    # expected and would otherwise sit in the log tail of every Qwen crash message.
    engine_qwen.quiet_expected_warnings()
    engine_qwen.quiet_expected_warnings()
    logger = logging.getLogger("transformers.configuration_utils")
    assert logger.filters.count(engine_qwen._DROP_EXPECTED_CONFIG_WARNING) == 1, "added once"

    def passes(message: str) -> bool:
        return bool(logger.filter(logger.makeRecord(logger.name, logging.WARNING, __file__, 1, message, None, None)))

    assert not passes(engine_qwen.EXPECTED_CONFIG_WARNING + " This may be expected if you are loading a checkpoint "
                      "that shares a subset of the architecture (e.g., loading a `sam2_video` checkpoint into "
                      "`Sam2Model`), but is otherwise not supported and can yield errors. Please verify that the "
                      "checkpoint is compatible with the model you are instantiating.")
    assert passes("You are using a model of type `qwen3_tts` to instantiate a model of type `llama`. This may be "
                  "expected ...")
    assert passes("Could not locate the tokenizer configuration file")
