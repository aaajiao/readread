"""The server with --engine qwen, without MLX: tts_server.py runs with tests/fakes first on sys.path (conftest's
FAKES_LAUNCHER), so MLX and mlx-audio are stand-ins whose model streams a tone per sentence (tests/fakes/fake_qwen.py)
and logs every call to FAKE_QWEN_LOG. Engine selection, the READY and /health fields, voices, synth_speed, stdout
protection, the one MLX thread, offline Hugging Face, warm-up, retries, cancellation and the shutdown paths; and that
neither engine imports the other's libraries. All of them bind a port on 127.0.0.1; none needs model files.
"""

from __future__ import annotations

import base64
import json
import re
import signal
import socket
import threading
import time
from pathlib import Path

import pytest
from conftest import FAKES, FAKES_LAUNCHER, ServerProcess, launcher, make_fake_models, make_qwen_models, wait_exit
from fakes import fake_qwen
from test_server_http import error, fatal, synthesis_line, wait_for, wav_frames

from readread_tts import engine_qwen
from readread_tts.engine_qwen import MODELS

# --- helpers ----------------------------------------------------------------------------------------------


def qwen_server(workdir: Path, models: str, preload: str | None = "zh,en", *, model: str | None = None,
                env: dict | None = None, wait: bool = True, launch: list[str] | None = None) -> ServerProcess:
    """A server with --engine qwen over the fakes; the fake model logs to <workdir>/fake.jsonl."""
    args = ["--engine", "qwen", *(["--model", model] if model else []), "--models-dir", models]
    environment = {"FAKE_QWEN_LOG": str(workdir / "fake.jsonl"), **(env or {})}
    return ServerProcess(workdir, models, preload, args=args, env=environment, wait=wait,
                         launcher=FAKES_LAUNCHER if launch is None else launch)


def events(server: ServerProcess, kind: str) -> list[dict]:
    path = server.workdir / "fake.jsonl"
    if not path.exists():
        return []
    records = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]
    return [r for r in records if r["event"] == kind]


def generations(server: ServerProcess, text: str | None = None) -> list[dict]:
    return [g for g in events(server, "generate") if text is None or g["text"] == text]


def synthesize(server: ServerProcess, **body) -> dict:
    status, headers, data = server.request("POST", "/synthesize", body)
    assert status == 200, data[:500]
    result = json.loads(data)
    frames, rate, channels, width = wav_frames(base64.b64decode(result["audio"]))
    assert (rate, channels, width) == (24000, 1, 2)
    assert abs(frames / 24000 - result["duration"]) <= 0.0005
    return result


def check_spans(result: dict) -> None:
    """Each sentence is the fake's speech plus the 30 ms lead and 40 ms tail the trims keep; 250 ms between them."""
    spans = result["sentences"]
    for s in spans:
        assert s["end"] - s["start"] == pytest.approx(0.07 + fake_qwen.speech_seconds(s["text"]), abs=0.002), s
    for a, b in zip(spans, spans[1:]):
        assert b["start"] - a["end"] == pytest.approx(0.25, abs=0.0015)
    assert spans[0]["start"] == 0 and spans[-1]["end"] == pytest.approx(result["duration"], abs=0.0015)


def start_raw_synthesis(server: ServerProcess, text: str, voice: str, request_id: str) -> socket.socket:
    body = json.dumps({"text": text, "voice": voice, "request_id": request_id}).encode("utf-8")
    s = socket.create_connection(("127.0.0.1", server.port), timeout=60)
    s.sendall((f"POST /synthesize HTTP/1.1\r\nHost: 127.0.0.1:{server.port}\r\nAuthorization: Bearer {server.token}"
               f"\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\n\r\n").encode() + body)
    return s


SENTENCE = "今天天气很好，我们一起去公园散步吧。"  # 50 speech tokens: 14 streamed chunks
LONG_ZH = SENTENCE * 30


@pytest.fixture(scope="session")
def qwen_models(tmp_path_factory) -> str:
    return make_qwen_models(tmp_path_factory.mktemp("qwen-models"))


# --- engine selection and start-up failures: one FATAL line, exit status 3 --------------------------------

def test_model_needs_the_qwen_engine(server_dir, fake_models):
    message = fatal(ServerProcess(server_dir, fake_models, args=["--model", "1.7b", "--models-dir", fake_models]))
    assert message == "bad arguments: --model applies only to --engine qwen"


@pytest.mark.parametrize("args, word", [(["--engine", "piper"], "piper"), (["--engine", "qwen", "--model", "3b"], "3b"),
                                        (["--engine"], "--engine")])
def test_fatal_on_bad_engine_arguments(server_dir, qwen_models, args, word):
    message = fatal(ServerProcess(server_dir, qwen_models, args=[*args, "--models-dir", qwen_models]))
    assert message.startswith("bad arguments: ") and word in message


def test_fatal_on_a_missing_models_dir(server_dir, tmp_path):
    message = fatal(qwen_server(server_dir, str(tmp_path / "nowhere")))
    assert message == f"models directory not found: {tmp_path / 'nowhere'} (run ./scripts/install-hq.sh)"


def test_fatal_on_a_model_that_is_not_installed(server_dir, tmp_path):
    (tmp_path / "m").mkdir()
    message = fatal(qwen_server(server_dir, str(tmp_path / "m")))
    assert message == f"model folder not found: {tmp_path / 'm' / MODELS['1.7b']} (run ./scripts/install-hq.sh)"


def test_fatal_on_a_wrong_model_file(server_dir, tmp_path):
    models = make_qwen_models(tmp_path / "m", ["1.7b"])
    config = Path(models) / MODELS["1.7b"] / "config.json"
    with open(config, "wb") as f:
        f.truncate(5)
    message = fatal(qwen_server(server_dir, models))
    assert message == f"{config} is 5 bytes, expected 6058 (re-run ./scripts/install-hq.sh)"


def test_fatal_without_the_mlx_packages(server_dir, qwen_models):
    launch = launcher(FAKES, hide=["mlx_audio", "safetensors"])
    message = fatal(qwen_server(server_dir, qwen_models, launch=launch))
    assert message == "missing Python packages: mlx_audio, safetensors (run ./scripts/install-hq.sh)"


def test_a_venv_without_numpy_names_the_package(server_dir, qwen_models):
    # engine_qwen imports numpy itself: the packages are checked before it is imported (an interrupted pip run leaves
    # a venv with only some of them), so this is the named FATAL, not a bare ModuleNotFoundError.
    message = fatal(qwen_server(server_dir, qwen_models, launch=launcher(FAKES, hide=["numpy"])))
    assert message == "missing Python packages: numpy (run ./scripts/install-hq.sh)"


@pytest.mark.parametrize("env, expected", [
    ({"FAKE_QWEN_LOAD_FAIL": "1"}, "loading the models failed: RuntimeError: fake load failure"),
    ({"FAKE_QWEN_NO_TOKENIZER": "1"}, "loading the models failed: RuntimeError: mlx-audio could not load the "
                                      "tokenizer from {folder} (see the warning above)"),
])
def test_fatal_when_the_model_does_not_load(server_dir, qwen_models, env, expected):
    message = fatal(qwen_server(server_dir, qwen_models, "zh", env=env))
    assert message == expected.format(folder=Path(qwen_models) / MODELS["1.7b"])


# --- a running server: 1.7b, both routes preloaded ----------------------------------------------------------

@pytest.fixture(scope="module")
def qwen(qwen_models, tmp_path_factory):
    # Offline settings and HF_HOME from the parent must not survive: the engine sets its own before any import.
    workdir = tmp_path_factory.mktemp("s")
    env = {"HF_HUB_OFFLINE": "0", "TRANSFORMERS_OFFLINE": "0", "HF_HUB_DISABLE_TELEMETRY": "0",
           "HF_HOME": str(workdir / "hf-elsewhere")}
    srv = qwen_server(workdir, qwen_models, env=env)
    assert srv.port, srv.line + srv.log()
    srv.models = qwen_models
    yield srv
    srv.stop()


def test_ready_line(qwen):
    assert re.fullmatch(r'READY \{"port":\d+,"pid":\d+,"api":2,"loaded":\["zh","en"\],"engine":"qwen",'
                        r'"model":"1\.7b"\}', qwen.line)
    assert json.loads(qwen.line[6:])["pid"] == qwen.proc.pid


def test_health(qwen):
    status, headers, body = qwen.request("GET", "/health")
    assert status == 200 and headers["content-type"] == "application/json; charset=utf-8"
    data = json.loads(body)
    assert {k: data[k] for k in ("status", "api", "pid", "loaded", "engine", "model")} == {
        "status": "ok", "api": 2, "pid": qwen.proc.pid, "loaded": ["zh", "en"], "engine": "qwen", "model": "1.7b"}
    assert set(data["versions"]) == {"mlx", "mlx_audio", "transformers", "misaki", "python"}
    assert {data["versions"][k] for k in ("mlx", "mlx_audio", "transformers")} == {"0.0.0+fake"}


def test_voices(qwen):
    status, _, body = qwen.request("GET", "/voices")
    assert status == 200 and json.loads(body) == {"zh": ["serena"], "en": ["aiden"]}


@pytest.mark.parametrize("body, code", [
    ({"text": "你好", "voice": "zf_001"}, "unknown_voice"),  # a Kokoro voice
    ({"text": "hello", "voice": "Aiden"}, "unknown_voice"),  # ids are exact
    ({"text": "hello", "voice": "ryan"}, "unknown_voice"),  # a speaker of the model, but not served
    ({"text": "你好", "voice": "serena", "lang": "en"}, "voice_language_mismatch"),
    ({"text": "hello", "voice": "aiden", "lang": "zh"}, "voice_language_mismatch"),
])
def test_voice_errors(qwen, body, code):
    assert error(qwen.request("POST", "/synthesize", body))[:2] == (400, code)


def test_chinese_json(qwen):
    result = synthesize(qwen, text="银行行长说，我们会重复检查。\n你得多听几遍！", voice="serena", lang="zh",
                        request_id="zh-json-1", speed=1.5)
    assert {k: result[k] for k in ("request_id", "voice", "lang", "speed", "synth_speed", "sample_rate", "silent",
                                   "tokens")} == {
        "request_id": "zh-json-1", "voice": "serena", "lang": "zh", "speed": 1.5, "synth_speed": 1.0,
        "sample_rate": 24000, "silent": False, "tokens": []}
    assert [s["text"] for s in result["sentences"]] == ["银行行长说，我们会重复检查。", "你得多听几遍！"]
    assert set(result["timing_ms"]) == {"frontend", "synth"}
    check_spans(result)


def test_english_json_goes_through_the_shared_front_end(qwen):
    result = synthesize(qwen, text="Hello world. Version 2.4.1 is out\n\nGetting Started", voice="aiden", lang="en-gb")
    assert result["lang"] == "en" and result["synth_speed"] == 1.0 and result["tokens"] == []
    assert [s["text"] for s in result["sentences"]] == ["Hello world.", "Version 2 point 4 point 1 is out.",
                                                        "Getting Started."]  # terminal stops added
    check_spans(result)


def test_wav(qwen):
    status, headers, body = qwen.request("POST", "/synthesize", {"text": "Hello there.", "voice": "aiden",
                                                                 "format": "wav", "speed": 0.8})
    assert status == 200 and headers["content-type"] == "audio/wav"
    assert headers["x-readread-synth-speed"] == "1.0"
    frames, rate, channels, width = wav_frames(body)
    assert (rate, channels, width) == (24000, 1, 2)
    assert headers["x-readread-duration"] == f"{frames / 24000:.3f}"


@pytest.mark.parametrize("text", ["", "   ", "---", "🎉🎉"])
def test_nothing_to_say_is_150_ms_of_silence(qwen, text):
    result = synthesize(qwen, text=text, voice="serena")
    assert result["silent"] is True and result["duration"] == 0.15 and result["synth_speed"] == 1.0
    assert result["sentences"] == [] and result["tokens"] == []


def test_the_same_text_comes_back_as_the_same_audio(qwen):
    first = synthesize(qwen, text="今天天气很好。", voice="serena")["audio"]
    again = synthesize(qwen, text="今天天气很好。", voice="serena")["audio"]
    other = synthesize(qwen, text="今天天气不好。", voice="serena")["audio"]  # as long, another seed
    assert first == again and first != other
    seeds = {g["seed"] for g in generations(qwen, "今天天气很好。")}
    assert seeds == {engine_qwen.text_seed("今天天气很好。", "serena")}


def test_a_runaway_is_retried_with_another_seed(qwen):
    text = "Read zzrunawayonce now."
    result = synthesize(qwen, text=text, voice="aiden", request_id="runaway-1")
    first, second = generations(qwen, text)
    assert first["seed"] == engine_qwen.text_seed(text, "aiden")
    assert second["seed"] == engine_qwen.next_seed(first["seed"])
    assert first["closed"] and not first["finished"]  # cut short well before max_tokens
    assert first["tokens"] < first["max_tokens"] and second["finished"]
    assert result["sentences"][0]["end"] == pytest.approx(0.07 + fake_qwen.speech_seconds(text), abs=0.002)
    assert re.search(r"WARNING readread\.engine: sentence 1 \(23 chars\): seed \d+ gave a runaway .*; retrying with "
                     r"another seed$", qwen.log(), re.M)


def test_every_generation_streams_with_the_token_cap_on_the_mlx_thread(qwen):
    synthesize(qwen, text="第一句。第二句话。", voice="serena")
    synthesize(qwen, text="One. Two words.", voice="aiden")
    gens = generations(qwen)
    assert len(gens) >= 6
    for g in gens:
        assert g["thread"] == "mlx" and g["stream"] is True and g["streaming_interval"] == 0.32
        assert g["verbose"] is False and g["extra"] == []
        assert g["max_tokens"] == engine_qwen.max_tokens(g["text"])
        assert g["lang_code"] == {"serena": "chinese", "aiden": "english"}[g["voice"]]
    assert len(events(qwen, "clear_cache")) == len(gens)  # after every generation, also an abandoned one


def test_one_model_load_and_a_warm_up_per_route_before_ready(qwen):
    loads = events(qwen, "load")
    assert len(loads) == 1 and loads[0]["thread"] == "mlx"
    assert loads[0]["path"] == str(Path(qwen.models) / MODELS["1.7b"])
    assert [e["limit"] for e in events(qwen, "set_cache_limit")] == [1 << 30]
    assert [(g["text"], g["voice"]) for g in generations(qwen)[:2]] == [("你好。", "serena"), ("Hello.", "aiden")]
    log = qwen.log()
    assert log.index("route zh ready in") < log.index("route en ready in") < log.index("ready (loaded: zh, en)")


def test_hugging_face_is_offline_with_its_cache_in_ours(qwen):
    assert events(qwen, "load")[0]["offline"] == {
        "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1",
        "HF_HOME": str(qwen.workdir / "cache" / "hf")}


def test_prints_never_reach_the_handshake(qwen):
    log = qwen.log()  # mlx-audio's prints (the fake's too) land on stderr
    assert "Loaded speech tokenizer from" in log and "fd 1 write from the fake model loader" in log
    assert "fake generate: " in log
    assert qwen.read_line(0.2) == ""  # stdout carried the READY line and nothing since


def test_one_log_line_per_synthesis(qwen):
    synthesize(qwen, text="你好。再见。", voice="serena", request_id="log-q1")
    assert re.fullmatch(r"\S+ \S+ INFO readread\.http: synthesize request_id=log-q1 voice=serena chars=6 sentences=2 "
                        r"frontend_ms=\d+ synth_ms=\d+ audio_s=\d+\.\d\d status=ok", synthesis_line(qwen, "log-q1"))


def test_nothing_written_outside_the_cache_dir(qwen):
    assert list((qwen.workdir / "home").iterdir()) == []
    assert list((qwen.workdir / "tmp").iterdir()) == []
    assert not (qwen.workdir / "hf-elsewhere").exists()
    assert not (qwen.workdir / "support").exists()


# --- cancellation: a slow fake (50 ms per streamed chunk) ------------------------------------------------------

@pytest.fixture(scope="module")
def slow(qwen_models, tmp_path_factory):
    srv = qwen_server(tmp_path_factory.mktemp("s"), qwen_models, "zh", env={"FAKE_QWEN_DELAY": "0.05"})
    assert srv.port, srv.line + srv.log()
    yield srv
    srv.stop()


def test_a_client_that_disconnects_cancels_its_synthesis_between_chunks(slow):
    s = start_raw_synthesis(slow, LONG_ZH, "serena", "gone-q1")
    time.sleep(1.5)  # 0.7 s per sentence: into the third
    s.close()
    started = time.monotonic()
    result = synthesize(slow, text="你好。", voice="serena", request_id="after-gone-q1")
    elapsed = time.monotonic() - started
    assert elapsed < 1.5, f"the next request waited {elapsed:.1f} s"
    line = synthesis_line(slow, "gone-q1")
    assert line is not None and line.endswith("status=cancelled")
    gens = generations(slow, SENTENCE)
    assert 2 <= len(gens) <= 4 and gens[-1]["closed"] and not gens[-1]["finished"]  # stopped mid-stream
    assert all(g["finished"] for g in gens[:-1])
    assert result["silent"] is False


def test_a_client_that_disconnects_while_waiting_never_runs(slow):
    holder: dict = {}
    first = threading.Thread(target=lambda: holder.update(
        r=slow.request("POST", "/synthesize", {"text": SENTENCE * 3, "voice": "serena", "request_id": "busy-q1"})))
    first.start()
    time.sleep(0.5)
    waiting = start_raw_synthesis(slow, "等一下。", "serena", "waiting-q1")
    time.sleep(0.5)
    waiting.close()
    assert wait_for(lambda: synthesis_line(slow, "waiting-q1") is not None, 2.0)
    assert synthesis_line(slow, "waiting-q1").endswith("sentences=0 frontend_ms=0 synth_ms=0 audio_s=0.00 "
                                                        "status=cancelled")
    first.join(30)
    assert holder["r"][0] == 200
    assert generations(slow, "等一下。") == []


# --- --model given, routes on demand, shutdown --------------------------------------------------------------

def test_model_1_7b_given_with_routes_loaded_on_demand(qwen_models, server_dir):
    srv = qwen_server(server_dir, qwen_models, None, model="1.7b")  # what the app passes; also the default
    try:
        assert json.loads(srv.line[6:]) == {"port": srv.port, "pid": srv.proc.pid, "api": 2, "loaded": [],
                                            "engine": "qwen", "model": "1.7b"}
        assert events(srv, "load") == []  # nothing loads before it is needed
        assert synthesize(srv, text="Good morning.", voice="aiden")["lang"] == "en"
        health = json.loads(srv.request("GET", "/health")[2])
        assert health["loaded"] == ["en"] and health["model"] == "1.7b"
        loads = events(srv, "load")
        assert len(loads) == 1 and loads[0]["path"] == str(Path(qwen_models) / MODELS["1.7b"])
        assert [g["text"] for g in generations(srv)] == ["Hello.", "Good morning."]  # the route's warm-up first
        assert "loading route en on demand" in srv.log()
    finally:
        srv.stop()


@pytest.mark.parametrize("how, limit", [("sigterm", 1.0), ("sigint", 1.0), ("stdin", 2.0)])
def test_shutdown_mid_synthesis(qwen_models, server_dir, how, limit):
    srv = qwen_server(server_dir, qwen_models, "zh", env={"FAKE_QWEN_DELAY": "0.2"})  # 2.8 s per sentence
    try:
        assert srv.port, srv.line + srv.log()
        s = start_raw_synthesis(srv, LONG_ZH, "serena", "term-q1")
        time.sleep(1.0)
        if how == "stdin":
            srv.proc.stdin.close()
        else:
            srv.proc.send_signal(signal.SIGTERM if how == "sigterm" else signal.SIGINT)
        elapsed = wait_exit(srv.proc, limit)
        assert elapsed is not None, f"still running {limit} s after {how}"
        assert srv.proc.returncode == 0
        assert generations(srv, SENTENCE) == []  # gone in the middle of the first sentence's generation
        s.close()
    finally:
        srv.stop()


@pytest.mark.parametrize("how, limit", [("sigterm", 1.0), ("stdin", 2.0)])
def test_shutdown_while_the_model_loads(qwen_models, server_dir, how, limit):
    srv = qwen_server(server_dir, qwen_models, "zh,en", env={"FAKE_QWEN_LOAD_DELAY": "30"}, wait=False)
    try:
        assert wait_for(lambda: "Loaded speech tokenizer from" in srv.log(), 15)  # inside load_model
        if how == "sigterm":
            srv.proc.send_signal(signal.SIGTERM)
        else:
            srv.proc.stdin.close()
        assert wait_exit(srv.proc, limit) is not None
        assert srv.proc.returncode == 0
        assert srv.proc.stdout.read() == b""  # neither READY nor FATAL
    finally:
        srv.stop()


# --- neither engine imports the other's libraries ------------------------------------------------------------

QWEN_ONLY = ["mlx", "mlx_audio", "mlx_lm", "mlx_metal", "transformers", "tokenizers", "huggingface_hub", "safetensors",
             "readread_tts.engine_qwen"]
# frontend_en imports readread_tts.espeak, which loads espeakng_loader only when Kokoro's English G2P asks for it.
KOKORO_ONLY = ["onnxruntime", "kokoro_onnx", "spacy", "en_core_web_sm", "phonemizer", "espeakng_loader", "jieba",
               "cn2an", "readread_tts.engine_kokoro"]


@pytest.mark.parametrize("models", ["fake", "real"])
def test_the_kokoro_server_never_imports_the_qwen_stack(request, server_dir, models):
    real = models == "real"
    models_dir = request.getfixturevalue("models_dir") if real else make_fake_models(server_dir / "m")
    record = server_dir / "imports.txt"
    # tests/fakes first on sys.path: an import of MLX by mistake would even succeed, and still be recorded.
    # espeakng_loader, which espeak.prepare() imports at start-up, shows that the watch works.
    srv = ServerProcess(server_dir, models_dir, "zh,en" if real else None,
                        launcher=launcher(FAKES, record, [*QWEN_ONLY, "espeakng_loader"]))
    try:
        assert srv.port, srv.line + srv.log()
        assert json.loads(srv.request("GET", "/health")[2])["engine"] == "kokoro"
        if real:
            for body in ({"text": "2026年10月20日，苹果发布了 iPhone 17 Pro。", "voice": "zf_001"},
                         {"text": "Version 2.4.1 is out.", "voice": "af_heart"}):
                assert srv.request("POST", "/synthesize", body)[0] == 200
    finally:
        srv.stop()
    assert set(record.read_text(encoding="utf-8").split()) == {"espeakng_loader"}


def test_the_qwen_server_never_imports_the_kokoro_stack(qwen_models, server_dir):
    record = server_dir / "imports.txt"
    # mlx_audio shows that the watch works.
    srv = qwen_server(server_dir, qwen_models, launch=launcher(FAKES, record, [*KOKORO_ONLY, "mlx_audio"]))
    try:
        assert srv.port, srv.line + srv.log()
        for body in ({"text": "2026年10月20日，苹果发布了 iPhone 17 Pro，起售价为¥7999。", "voice": "serena"},
                     {"text": "Dr. Smith paid $3.50 at 10:30 a.m. on Jan. 5th, 2026.", "voice": "aiden"}):
            assert srv.request("POST", "/synthesize", body)[0] == 200
    finally:
        srv.stop()
    assert set(record.read_text(encoding="utf-8").split()) == {"mlx_audio", "mlx_audio.tts", "mlx_audio.tts.utils"}
