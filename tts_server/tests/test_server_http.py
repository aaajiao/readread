"""The server as the app runs it: a subprocess with the READY/FATAL handshake, HTTP API v2, shutdown paths.

Tests without models use sparse stand-in model files (the start-up checks only look at sizes); the rest
need READREAD_MODELS_DIR. All of them bind a port on 127.0.0.1.
"""

from __future__ import annotations

import base64
import io
import json
import re
import signal
import socket
import threading
import time
import wave

import pytest
from conftest import ServerProcess, make_fake_models, wait_exit

# --- helpers ----------------------------------------------------------------------------------------------


def error(response) -> tuple[int, str, str]:
    status, headers, body = response
    assert headers["content-type"] == "application/json; charset=utf-8"
    data = json.loads(body)
    assert set(data) == {"error"} and set(data["error"]) == {"code", "message"}
    return status, data["error"]["code"], data["error"]["message"]


def raw(server: ServerProcess, head: str, body: bytes = b"", *, half_close: bool = False, timeout: float = 10):
    """Send bytes as they are; returns (status, headers, body, closed by the server)."""
    with socket.create_connection(("127.0.0.1", server.port), timeout=timeout) as s:
        s.sendall(head.replace("\n", "\r\n").encode("latin-1") + body)
        if half_close:
            s.shutdown(socket.SHUT_WR)
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
        head_bytes, _, rest = data.partition(b"\r\n\r\n")
        lines = head_bytes.decode("latin-1").split("\r\n")
        headers = {k.lower(): v.strip() for k, _, v in (line.partition(":") for line in lines[1:])}
        length = int(headers.get("content-length", 0))
        while len(rest) < length:
            chunk = s.recv(65536)
            if not chunk:
                break
            rest += chunk
        try:
            closed = s.recv(1) == b""
        except ConnectionResetError:
            closed = True
        except socket.timeout:
            closed = False
    return int(lines[0].split()[1]), headers, rest, closed


def auth(server: ServerProcess) -> str:
    return f"Host: 127.0.0.1:{server.port}\nAuthorization: Bearer {server.token}\n"


def wav_frames(data: bytes) -> tuple[int, int, int, int]:
    with wave.open(io.BytesIO(data)) as w:
        return w.getnframes(), w.getframerate(), w.getnchannels(), w.getsampwidth()


def wait_for(predicate, timeout: float, step: float = 0.05) -> bool:
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            return True
        time.sleep(step)
    return predicate()


def synthesis_line(server: ServerProcess, request_id: str) -> str | None:
    for line in server.log().splitlines():
        if f"synthesize request_id={request_id} " in line:
            return line
    return None


# --- start-up failures: one FATAL line on stdout, exit status 3 ---------------------------------------------

def fatal(server: ServerProcess) -> str:
    assert server.line.startswith("FATAL "), server.line + server.log()
    assert wait_exit(server.proc, 10) is not None
    assert server.proc.returncode == 3
    assert server.proc.stdout.read() == b""  # nothing after the FATAL line
    message = json.loads(server.line[len("FATAL "):])["message"]
    server.stop()
    return message


def test_fatal_without_a_token(server_dir, fake_models):
    message = fatal(ServerProcess(server_dir, fake_models, env={"READREAD_TOKEN": None}))
    assert message == "READREAD_TOKEN must be set to 64 hexadecimal characters"


def test_fatal_with_a_short_token(server_dir, fake_models):
    assert "READREAD_TOKEN" in fatal(ServerProcess(server_dir, fake_models, env={"READREAD_TOKEN": "abc123"}))


def test_fatal_on_a_missing_models_dir(server_dir, tmp_path):
    message = fatal(ServerProcess(server_dir, str(tmp_path / "nowhere")))
    assert message == f"models directory not found: {tmp_path / 'nowhere'}"


def test_fatal_on_a_wrong_model_file(server_dir, fake_models):
    with open(f"{fake_models}/kokoro-v1.0.fp16.onnx", "wb") as f:
        f.truncate(177464787)  # the old export, without duration output
    message = fatal(ServerProcess(server_dir, fake_models))
    assert "kokoro-v1.0.fp16.onnx is 177464787 bytes, expected 163527961" in message


def test_fatal_on_bad_arguments(server_dir, fake_models):
    assert "--models-dir" in fatal(ServerProcess(server_dir, fake_models, args=[]))


def test_fatal_on_an_unknown_preload_route(server_dir, fake_models):
    assert "unknown --preload route 'ja'" in fatal(ServerProcess(server_dir, fake_models, "zh,ja"))


def test_fatal_on_a_cache_dir_espeak_cannot_use(server_dir, fake_models, tmp_path):
    deep = str(tmp_path / ("d" * 120))
    assert "too long for espeak-ng" in fatal(ServerProcess(server_dir, fake_models, env={"READREAD_CACHE_DIR": deep}))


# Runs tts_server.py with a module hidden from the import system, as if it were not installed.
HIDE = """
import importlib.machinery, runpy, sys
hidden = set(sys.argv[1].split(","))
class Hiding(importlib.machinery.PathFinder):
    @classmethod
    def find_spec(cls, name, path=None, target=None):
        return None if name.partition(".")[0] in hidden else super().find_spec(name, path, target)
sys.meta_path[:] = [Hiding if f is importlib.machinery.PathFinder else f for f in sys.meta_path]
sys.argv = sys.argv[2:]
runpy.run_path(sys.argv[0], run_name="__main__")
"""


def test_fatal_without_the_spacy_model(server_dir, fake_models):
    message = fatal(ServerProcess(server_dir, fake_models, launcher=["-c", HIDE, "en_core_web_sm"]))
    assert message == "missing Python packages: en_core_web_sm (run ./scripts/setup.sh)"


# --- HTTP without models ----------------------------------------------------------------------------------

@pytest.fixture(scope="module")
def server(tmp_path_factory):
    srv = ServerProcess(tmp_path_factory.mktemp("s"), make_fake_models(tmp_path_factory.mktemp("m")))
    assert srv.port, srv.line + srv.log()
    yield srv
    srv.stop()


def test_ready_line(server):
    assert re.fullmatch(r'READY \{"port":\d+,"pid":\d+,"api":2,"loaded":\[\]\}', server.line)
    assert json.loads(server.line[6:])["pid"] == server.proc.pid


def test_health(server):
    status, headers, body = server.request("GET", "/health")
    assert status == 200 and headers["content-type"] == "application/json; charset=utf-8"
    assert headers["server"] == "ReadRead/2"  # no Python version
    data = json.loads(body)
    assert {k: data[k] for k in ("status", "api", "pid", "loaded")} == \
        {"status": "ok", "api": 2, "pid": server.proc.pid, "loaded": []}
    assert set(data["versions"]) == {"kokoro_onnx", "misaki", "onnxruntime", "python"}
    assert "unknown" not in data["versions"].values()


@pytest.mark.parametrize("value", [None, "", "Bearer", "Bearer wrong", "bearer {token}", "Bearer {token}0",
                                   "Basic {token}", "Bearer  {token}"])
def test_unauthorized(server, value):
    header = None if value is None else value.format(token=server.token)
    status, code, _ = error(server.request("GET", "/health", headers={"Authorization": header}))
    assert (status, code) == (401, "unauthorized")


def test_the_token_is_checked_before_anything_else(server):
    response = server.request("POST", "/nowhere", b"x", headers={"Authorization": "Bearer x", "Host": "evil"})
    assert error(response)[:2] == (401, "unauthorized")


@pytest.mark.parametrize("host", ["example.com", "127.0.0.1", "127.0.0.1:1", "evil.127.0.0.1:{port}", "",
                                  "[::1]:{port}"])
def test_forbidden_host(server, host):
    status, code, message = error(server.request("GET", "/health", headers={"Host": host.format(port=server.port)}))
    assert (status, code) == (403, "forbidden")
    assert str(server.port) in message


@pytest.mark.parametrize("host", ["127.0.0.1:{port}", "localhost:{port}", "LOCALHOST:{port}"])
def test_loopback_hosts(server, host):
    assert server.request("GET", "/health", headers={"Host": host.format(port=server.port)})[0] == 200


@pytest.mark.parametrize("path", ["/", "/nope", "/synthesize/", "/health/x", "/../health"])
def test_not_found(server, path):
    assert error(server.request("GET", path))[:2] == (404, "not_found")


def test_query_strings_are_ignored(server):
    assert server.request("GET", "/health?verbose=1")[0] == 200


@pytest.mark.parametrize("method, path, allow", [("POST", "/health", "GET"), ("GET", "/synthesize", "POST"),
                                                 ("DELETE", "/voices", "GET"), ("PUT", "/synthesize", "POST")])
def test_wrong_method(server, method, path, allow):
    response = server.request(method, path)
    assert error(response)[:2] == (400, "bad_request")
    assert response[1]["allow"] == allow


@pytest.mark.parametrize("content_type", [None, "text/plain", "application/x-www-form-urlencoded",
                                          "application/jsonx"])
def test_unsupported_media_type(server, content_type):
    response = server.request("POST", "/synthesize", {"text": "hi", "voice": "af_heart"}, content_type=content_type)
    assert error(response)[:2] == (415, "unsupported_media_type")
    assert response[1].get("connection") == "close"  # the unread body must not be parsed as a request


def test_json_content_type_with_parameters_is_accepted(server):
    response = server.request("POST", "/synthesize", {}, content_type="Application/JSON; charset=utf-8")
    assert error(response)[:2] == (400, "bad_request")


def test_text_over_4000_characters_is_too_large(server):
    status, code, message = error(server.request("POST", "/synthesize", {"text": "字" * 4001, "voice": "zf_001"}))
    assert (status, code) == (413, "too_large")
    assert "4000" in message


def test_body_over_1_mib_is_refused_unread(server):
    head = (f"POST /synthesize HTTP/1.1\n{auth(server)}Content-Type: application/json\n"
            f"Content-Length: {(1 << 20) + 1}\n\n")
    status, headers, body, closed = raw(server, head)  # the body is never sent: the answer comes first
    assert status == 413 and json.loads(body)["error"]["code"] == "too_large"
    assert closed


@pytest.mark.parametrize("body, message", [
    (b"{not json", "not valid JSON"),
    (b"\xff\xfe{}", "not valid JSON"),
    (b"[" * 50000, "not valid JSON: maximum recursion depth exceeded"),
    (b"[]", "must be a JSON object"),
    (b'"text"', "must be a JSON object"),
    (b"{}", '"text" is required'),
    (b'{"text": 5, "voice": "zf_001"}', '"text" is required'),
    (b'{"text": "hi"}', '"voice" is required'),
    (b'{"text": "hi", "voice": ""}', '"voice" is required'),
    (b'{"text": "hi", "voice": 7}', '"voice" is required'),
    (b'{"text": "hi", "voice": "zf_001", "speed": 0.49}', '"speed"'),
    (b'{"text": "hi", "voice": "zf_001", "speed": 2.01}', '"speed"'),
    (b'{"text": "hi", "voice": "zf_001", "speed": "1"}', '"speed"'),
    (b'{"text": "hi", "voice": "zf_001", "speed": true}', '"speed"'),
    (b'{"text": "hi", "voice": "zf_001", "speed": NaN}', '"speed"'),
    (b'{"text": "hi", "voice": "zf_001", "speed": 1e999}', '"speed"'),
    (b'{"text": "hi", "voice": "zf_001", "speed": 1' + b"0" * 400 + b"}", '"speed"'),
    (b'{"text": "hi", "voice": "zf_001", "format": "mp3"}', '"format"'),
    (b'{"text": "hi", "voice": "zf_001", "lang": "ja"}', '"lang"'),
    (b'{"text": "hi", "voice": "zf_001", "lang": "EN"}', '"lang"'),
    (b'{"text": "hi", "voice": "zf_001", "request_id": 5}', '"request_id"'),
    (b'{"text": "hi", "voice": "zf_001", "request_id": "' + b"x" * 129 + b'"}', '"request_id"'),
    (b'{"text": "hi", "voice": "zf_001", "request_id": "\\ud800"}', '"request_id"'),
])
def test_bad_request(server, body, message):
    status, code, text = error(server.request("POST", "/synthesize", body))
    assert (status, code) == (400, "bad_request")
    assert message in text


@pytest.mark.parametrize("head, body, half_close, message", [
    ("Transfer-Encoding: chunked\n", b"", False, "chunked request bodies are not supported"),
    ("", b"", False, "Content-Length is required"),
    ("Content-Length: abc\n", b"", False, "invalid Content-Length"),
    ("Content-Length: -1\n", b"", False, "invalid Content-Length"),
    ("Content-Length: 100\n", b'{"text": "hi"', True, "the body ended before Content-Length bytes"),
])
def test_bad_framing(server, head, body, half_close, message):
    request = f"POST /synthesize HTTP/1.1\n{auth(server)}Content-Type: application/json\nConnection: close\n{head}\n"
    status, _, data, _ = raw(server, request, body, half_close=half_close)
    assert status == 400
    assert message in json.loads(data)["error"]["message"]


@pytest.mark.parametrize("request_line", ["GARBAGE", "BREW /health HTTP/1.1", "GET /health HTTP/2.0",
                                          "GET /health HTTP/1.1 extra"])
def test_protocol_errors_are_json_too(server, request_line):
    status, headers, body, closed = raw(server, f"{request_line}\n{auth(server)}\n")
    assert status == 400 and headers["content-type"] == "application/json; charset=utf-8"
    assert json.loads(body)["error"]["code"] == "bad_request"
    assert closed


def test_an_unread_body_closes_the_connection(server):
    status, headers, _ = server.request("GET", "/health", b"leftover")
    assert status == 200 and headers.get("connection") == "close"


def test_internal_errors_are_json(server):
    # The stand-in voice files are not valid .npz archives.
    status, code, message = error(server.request("GET", "/voices"))
    assert (status, code) == (500, "internal")
    assert "internal error on GET /voices" in server.log()


def test_connections_are_kept_alive(server):
    import http.client

    connection = http.client.HTTPConnection("127.0.0.1", server.port, timeout=10)
    try:
        for _ in range(3):
            connection.request("GET", "/health", headers={"Authorization": f"Bearer {server.token}"})
            response = connection.getresponse()
            response.read()
            assert response.status == 200
    finally:
        connection.close()


def test_one_log_line_per_request_and_nothing_on_stdout(server):
    server.request("GET", "/health", headers={"X-Test": "log"})
    server.request("POST", "/synthesize", {"voice": "zf_001", "request_id": "log-1"})
    assert wait_for(lambda: synthesis_line(server, "log-1") is not None, 5)
    assert re.search(r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3} INFO readread\.http: GET /health 200$",
                     server.log(), re.M)
    assert re.fullmatch(r"\S+ \S+ INFO readread\.http: synthesize request_id=log-1 voice=zf_001 chars=0 "
                        r"sentences=0 frontend_ms=0 synth_ms=0 audio_s=0\.00 status=bad_request",
                        synthesis_line(server, "log-1"))
    assert server.read_line(0.2) == ""  # stdout carried the READY line and nothing since


# --- shutdown --------------------------------------------------------------------------------------------

def test_stdin_eof_exits_within_2_s(server_dir, fake_models):
    srv = ServerProcess(server_dir, fake_models)
    assert srv.port
    scratch = server_dir / "cache" / "tmp" / str(srv.proc.pid)
    assert scratch.is_dir()
    srv.proc.stdin.close()
    elapsed = wait_exit(srv.proc, 2.0)
    assert elapsed is not None, "still running 2 s after stdin closed"
    assert srv.proc.returncode == 0
    assert "stdin closed, exiting" in srv.log()
    assert not scratch.exists()
    srv.stop()


@pytest.mark.parametrize("signum", [signal.SIGTERM, signal.SIGINT])
def test_signal_exits_within_1_s(server_dir, fake_models, signum):
    srv = ServerProcess(server_dir, fake_models)
    assert srv.port
    srv.proc.send_signal(signum)
    assert wait_exit(srv.proc, 1.0) is not None
    assert srv.proc.returncode == 0
    assert re.search(rf"^\S+ \S+ INFO readread: received {signum.name}, exiting$", srv.log(), re.M)
    srv.stop()


def test_a_second_server_sweeps_scratch_dirs_of_dead_ones(server_dir, fake_models):
    stale = server_dir / "cache" / "tmp" / "999999"
    stale.mkdir(parents=True)
    (stale / "libespeak-ng.dylib").write_bytes(b"x")
    srv = ServerProcess(server_dir, fake_models)
    assert srv.port
    assert not stale.exists()
    srv.stop()


# --- with models ----------------------------------------------------------------------------------------

APP_VOICES = {
    "zh": ["zf_001", "zf_032", "zm_009", "zm_055"],
    "en": ["af_heart", "af_alloy", "af_aoede", "af_bella", "af_jessica", "af_kore", "af_nicole", "af_nova", "af_river",
           "af_sarah", "af_sky", "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael", "am_onyx",
           "am_puck", "bf_alice", "bf_emma", "bf_isabella", "bf_lily", "bm_daniel", "bm_fable", "bm_george",
           "bm_lewis"],
}


@pytest.fixture(scope="module")
def model_server(models_dir, tmp_path_factory):
    srv = ServerProcess(tmp_path_factory.mktemp("s"), models_dir, "zh,en")
    assert srv.port, srv.line + srv.log()
    yield srv
    srv.stop()


def synthesize(server: ServerProcess, **body) -> dict:
    status, headers, data = server.request("POST", "/synthesize", body)
    assert status == 200, data[:500]
    assert headers["content-type"] == "application/json; charset=utf-8"
    result = json.loads(data)
    assert headers["x-readread-request-id"] == result["request_id"]
    frames, rate, channels, width = wav_frames(base64.b64decode(result["audio"]))
    assert (rate, channels, width) == (24000, 1, 2)
    assert abs(frames / 24000 - result["duration"]) <= 0.0005
    return result


def check_timings(result: dict) -> None:
    duration = result["duration"]
    spans = [(s["start"], s["end"]) for s in result["sentences"]]
    for a, b in spans:
        assert 0 <= a < b <= duration
    for (_, b), (c, _) in zip(spans, spans[1:]):
        assert abs(c - b - 0.25) <= 0.0015  # 250 ms between sentences
    previous_end = 0.0
    for t in result["tokens"]:
        assert previous_end - 1e-6 <= t["start"] <= t["end"] <= duration
        assert any(a - 1e-6 <= t["start"] and t["end"] <= b + 1e-6 for a, b in spans)
        previous_end = t["end"]


def test_ready_after_preloading_both_routes(model_server):
    assert json.loads(model_server.line[6:])["loaded"] == ["zh", "en"]
    assert json.loads(model_server.request("GET", "/health")[2])["loaded"] == ["zh", "en"]


def test_voices(model_server):
    status, _, body = model_server.request("GET", "/voices")
    voices = json.loads(body)
    assert status == 200 and set(voices) == {"zh", "en"}
    assert len(voices["zh"]) == 100 and len(voices["en"]) == 28
    for lang, prefixes in (("zh", ("zf_", "zm_")), ("en", ("af_", "am_", "bf_", "bm_"))):
        assert voices[lang] == sorted(voices[lang])
        assert all(v.startswith(prefixes) for v in voices[lang])
        assert set(APP_VOICES[lang]) <= set(voices[lang])


@pytest.mark.parametrize("body, code", [
    ({"text": "你好", "voice": "zf_xiaobei"}, "unknown_voice"),
    ({"text": "hello", "voice": "jf_alpha"}, "unknown_voice"),  # in voices-v1.0.bin, but Japanese is not served
    ({"text": "hello", "voice": "x"}, "unknown_voice"),
    ({"text": "你好", "voice": "zf_001", "lang": "en"}, "voice_language_mismatch"),
    ({"text": "hello", "voice": "af_heart", "lang": "zh"}, "voice_language_mismatch"),
    ({"text": "hello", "voice": "bm_george", "lang": "zh"}, "voice_language_mismatch"),
])
def test_voice_errors(model_server, body, code):
    assert error(model_server.request("POST", "/synthesize", body))[:2] == (400, code)


@pytest.mark.parametrize("voice, lang", [("af_heart", "en"), ("af_heart", "en-gb"), ("bf_emma", "en-us"),
                                         ("zf_032", "zh"), ("zm_009", None)])
def test_language_codes(model_server, voice, lang):
    text = "你好。" if voice.startswith("z") else "Hello."
    assert synthesize(model_server, text=text, voice=voice, lang=lang)["lang"] == ("zh" if voice[0] == "z" else "en")


@pytest.mark.parametrize("text", ["", "   ", "---", "• • •", "|", "🎉🎉", "***\n___"])
def test_nothing_to_say_is_150_ms_of_silence(model_server, text):
    result = synthesize(model_server, text=text, voice="zf_001")
    assert result["silent"] is True and result["duration"] == 0.15
    assert result["sentences"] == [] and result["tokens"] == []
    audio = base64.b64decode(result["audio"])
    assert set(audio[44:]) == {0}


def test_chinese_json(model_server):
    result = synthesize(model_server, text="银行行长说，我们会重复检查。\n你得多听几遍！", voice="zf_001",
                        request_id="zh-json-1", speed=1.0)
    assert result["request_id"] == "zh-json-1" and result["voice"] == "zf_001" and result["lang"] == "zh"
    assert result["speed"] == 1.0 and result["sample_rate"] == 24000 and result["silent"] is False
    assert [s["text"] for s in result["sentences"]] == ["银行行长说，我们会重复检查。", "你得多听几遍！"]
    assert "".join(t["text"] for t in result["tokens"]) == "银行行长说我们会重复检查你得多听几遍"
    assert set(result["timing_ms"]) == {"frontend", "synth"} and result["timing_ms"]["synth"] > 0
    check_timings(result)


def test_english_json(model_server):
    result = synthesize(model_server, text="Hello world. Version 2.4.1 is out!", voice="af_heart")
    assert [s["text"] for s in result["sentences"]] == ["Hello world.", "Version 2 point 4 point 1 is out!"]
    assert [t["text"] for t in result["tokens"]] == ["Hello", "world", "Version", "2", "point", "4", "point", "1",
                                                     "is", "out"]
    assert re.fullmatch(r"[0-9a-f]{12}", result["request_id"])  # generated when the client sends none
    check_timings(result)


def test_mixed_chinese_and_english_tokens(model_server):
    result = synthesize(model_server, text="很多开发者在 GitHub 上分享代码。", voice="zm_055")
    assert "GitHub" in [t["text"] for t in result["tokens"]]
    check_timings(result)


def test_wav(model_server):
    status, headers, body = model_server.request(
        "POST", "/synthesize", {"text": "I can't schedule a tomato tasting.", "voice": "bf_emma", "format": "wav",
                                "request_id": "wav 1\n"})
    assert status == 200 and headers["content-type"] == "audio/wav"
    frames, rate, channels, width = wav_frames(body)
    assert (rate, channels, width) == (24000, 1, 2)
    assert headers["x-readread-duration"] == f"{frames / 24000:.3f}"
    assert headers["x-readread-request-id"] == "wav_1_"  # header-safe


def test_speed(model_server):
    text = "今天天气很好，我们一起去公园散步吧。"
    slow = synthesize(model_server, text=text, voice="zf_001", speed=0.5)["duration"]
    fast = synthesize(model_server, text=text, voice="zf_001", speed=2.0)["duration"]
    assert fast < slow * 0.5


LONG_ZH = "今天天气很好，我们一起去公园散步吧。" * 30


def start_raw_synthesis(server: ServerProcess, text: str, request_id: str) -> socket.socket:
    body = json.dumps({"text": text, "voice": "zf_001", "request_id": request_id}).encode("utf-8")
    s = socket.create_connection(("127.0.0.1", server.port), timeout=60)
    s.sendall((f"POST /synthesize HTTP/1.1\r\nHost: 127.0.0.1:{server.port}\r\nAuthorization: Bearer {server.token}"
               f"\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\n\r\n").encode() + body)
    return s


def test_a_client_that_disconnects_cancels_its_synthesis(model_server):
    s = start_raw_synthesis(model_server, LONG_ZH, "gone-1")
    time.sleep(1.5)  # well into the 30 sentences
    s.close()
    started = time.monotonic()
    result = synthesize(model_server, text="你好。", voice="zf_001", request_id="after-gone-1")
    elapsed = time.monotonic() - started
    assert elapsed < 3.0, f"the next request waited {elapsed:.1f} s"
    line = synthesis_line(model_server, "gone-1")
    assert line is not None and line.endswith("status=cancelled")
    assert model_server.log().index("request_id=gone-1 ") < model_server.log().index("request_id=after-gone-1 ")
    assert result["silent"] is False


def test_a_client_that_disconnects_while_waiting_never_runs(model_server):
    holder: dict = {}
    first = threading.Thread(target=lambda: holder.update(
        r=model_server.request("POST", "/synthesize", {"text": LONG_ZH[:180], "voice": "zf_001",
                                                       "request_id": "busy-1"})))
    first.start()
    time.sleep(0.5)
    waiting = start_raw_synthesis(model_server, "你好。", "waiting-1")
    time.sleep(0.5)
    waiting.close()
    assert wait_for(lambda: synthesis_line(model_server, "waiting-1") is not None, 2.0)
    assert synthesis_line(model_server, "waiting-1").endswith("sentences=0 frontend_ms=0 synth_ms=0 audio_s=0.00 "
                                                               "status=cancelled")
    assert synthesis_line(model_server, "busy-1") is None  # the first one is still running
    first.join(60)
    assert holder["r"][0] == 200


def test_nothing_written_outside_the_cache_dir(model_server):
    assert list((model_server.workdir / "home").iterdir()) == []
    assert list((model_server.workdir / "tmp").iterdir()) == []
    assert not (model_server.workdir / "support").exists()  # the user lexicon is only ever read


def test_lazy_route_then_shutdown_mid_synthesis(models_dir, server_dir):
    srv = ServerProcess(server_dir, models_dir, "zh")
    try:
        assert json.loads(srv.line[6:])["loaded"] == ["zh"]
        assert synthesize(srv, text="Hello there.", voice="am_adam")["lang"] == "en"  # loads the route on demand
        assert json.loads(srv.request("GET", "/health")[2])["loaded"] == ["zh", "en"]
        s = start_raw_synthesis(srv, LONG_ZH, "term-1")
        time.sleep(1.0)
        srv.proc.send_signal(signal.SIGTERM)
        assert wait_exit(srv.proc, 1.0) is not None, "still running 1 s after SIGTERM"
        assert srv.proc.returncode == 0
        s.close()
    finally:
        srv.stop()


@pytest.mark.parametrize("how", ["sigterm", "stdin"])
def test_shutdown_while_the_models_load(models_dir, server_dir, how):
    srv = ServerProcess(server_dir, models_dir, "zh,en", wait=False)
    try:
        assert wait_for(lambda: "ReadRead TTS server starting" in srv.log(), 10)
        time.sleep(0.5)  # importing and loading, well before READY
        assert srv.proc.poll() is None
        if how == "sigterm":
            srv.proc.send_signal(signal.SIGTERM)
        else:
            srv.proc.stdin.close()
        assert wait_exit(srv.proc, 1.0 if how == "sigterm" else 2.0) is not None
        assert srv.proc.returncode == 0
        assert srv.proc.stdout.read() == b""  # neither READY nor FATAL
    finally:
        srv.stop()


def test_stdin_eof_mid_synthesis(models_dir, server_dir):
    srv = ServerProcess(server_dir, models_dir, "zh")
    try:
        s = start_raw_synthesis(srv, LONG_ZH, "eof-1")
        time.sleep(1.0)
        srv.proc.stdin.close()
        assert wait_exit(srv.proc, 2.0) is not None, "still running 2 s after stdin closed"
        assert srv.proc.returncode == 0
        s.close()
    finally:
        srv.stop()
