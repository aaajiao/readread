"""The Qwen engine with the real models: the real server, started from the HQ venv of scripts/install-hq.sh the way the
app starts it, for each model install.json lists. Skipped unless READREAD_HQ_HOME points at an install; needs the GPU
(Metal, so run it outside any sandbox). pytest itself runs in the dev env; only the servers use the HQ venv:

    READREAD_HQ_HOME=~/Library/Application\\ Support/ReadRead/hq ~/.readread/env/bin/python -m pytest -q \\
        tts_server/tests/test_qwen_models.py
"""

from __future__ import annotations

import base64
import ctypes
import json
import os
import signal
import socket
import subprocess
import threading
import time
from pathlib import Path

import pytest
from conftest import ServerProcess, wait_exit
from test_server_http import error, synthesis_line, wav_frames

from readread_tts import engine_qwen
from readread_tts.engine import QWEN_MODELS

GB = 1 << 30
ZH = "2026年10月20日，苹果发布了 iPhone 17 Pro，起售价为¥7999。"
EN = "The quick brown fox jumps over the lazy dog. Version 2.4.1 shipped on March 3rd!"
LONG_ZH = "今天天气很好，我们一起去公园散步吧。" * 12
ZH_SENTENCES = [
    "清晨的阳光透过窗帘洒进房间。", "他每天坐地铁上班，单程大约四十分钟。",
    "这家餐厅的招牌菜是红烧肉和清蒸鱼。", "会议推迟到下周三下午两点举行。",
    "研究人员在实验中发现了一种新的蛋白质结构。", "图书馆周末开放时间是上午九点到晚上八点。",
    "她把旧照片整理成了一本相册，送给了奶奶。", "据统计，今年前三季度的出口额同比增长了5.2%。",
    "小猫蜷缩在沙发角落里睡着了。", "如果明天下雨，我们就把野餐改到室内。",
]
EN_SENTENCES = [
    "The museum reopened last spring after a two-year renovation.",
    "Please remember to water the plants while I am away.",
    "Researchers found that short walks improve concentration.",
    "The train to Boston leaves at a quarter past seven.",
    "She spent the afternoon reading on the balcony.", "Our team shipped the update on Friday evening.",
    "A light breeze carried the smell of fresh bread down the street.",
    "He asked whether the library would be open on Sunday.",
    "The recipe calls for two cups of flour and a pinch of salt.",
    "After the storm, the sky turned a brilliant shade of orange.",
]


def hq_home() -> Path:
    path = os.environ.get("READREAD_HQ_HOME")
    if not path:
        pytest.skip("READREAD_HQ_HOME is not set")
    home = Path(path)
    # A scratch READREAD_HQ_HOME (test isolation) holds no install: skip, as without one.
    if not (home / "install.json").is_file():
        pytest.skip(f"no HQ install in {home} (./scripts/install-hq.sh)")
    return home


def start(workdir: Path, model: str, preload: str | None = "zh,en") -> ServerProcess:
    home = hq_home()
    models = str(home / "models")
    return ServerProcess(workdir, models, preload, python=str(home / "venv" / "bin" / "python3"),
                         args=["--engine", "qwen", "--model", model, "--models-dir", models])


@pytest.fixture(scope="module", params=QWEN_MODELS)
def hq(request, tmp_path_factory):
    home, model = hq_home(), request.param
    listed = json.loads((home / "install.json").read_text(encoding="utf-8"))["models"]
    if model not in listed:
        pytest.skip(f"model {model} is not installed in {home} (./scripts/install-hq.sh --model {model})")
    problems = engine_qwen.check_models(str(home / "models"), model)
    assert not problems, problems
    started = time.monotonic()
    srv = start(tmp_path_factory.mktemp("q"), model)
    srv.ready_s = time.monotonic() - started
    assert srv.port, srv.line + srv.log()
    srv.model = model
    yield srv
    srv.stop()


def synthesize(server: ServerProcess, **body) -> dict:
    started = time.monotonic()
    status, headers, data = server.request("POST", "/synthesize", body, timeout=300)
    assert status == 200, data[:500]
    result = json.loads(data)
    result["wall_s"] = time.monotonic() - started
    frames, rate, channels, width = wav_frames(base64.b64decode(result["audio"]))
    assert (rate, channels, width) == (24000, 1, 2)
    assert abs(frames / 24000 - result["duration"]) <= 0.0005
    return result


def sane(seconds: float, text: str) -> bool:
    """A plausible spoken length: well inside the bounds past which the engine retries."""
    expected = engine_qwen.expected_seconds(text)
    return 0.4 * expected <= seconds <= 2.0 * expected + 0.5


def check_sentences(result: dict) -> None:
    spans = result["sentences"]
    assert spans and result["tokens"] == [] and result["silent"] is False
    for s in spans:
        assert sane(s["end"] - s["start"], s["text"]), s
    for a, b in zip(spans, spans[1:]):
        assert b["start"] - a["end"] == pytest.approx(0.25, abs=0.0015)
    assert spans[-1]["end"] == pytest.approx(result["duration"], abs=0.0015)


class _RusageInfoV2(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        "user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups", "pageins", "wired_size", "resident_size",
        "phys_footprint", "proc_start_abstime", "proc_exit_abstime", "child_user_time", "child_system_time",
        "child_pkg_idle_wkups", "child_interrupt_wkups", "child_pageins", "child_elapsed_abstime",
        "diskio_bytesread", "diskio_byteswritten")]


def memory(pid: int) -> tuple[int, int]:
    """(RSS, physical footprint) in bytes. The footprint counts the GPU buffers MLX keeps in unified memory."""
    info = _RusageInfoV2()
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    if libproc.proc_pid_rusage(pid, 2, ctypes.byref(info)) != 0:  # RUSAGE_INFO_V2
        raise OSError(ctypes.get_errno(), f"proc_pid_rusage({pid}) failed")
    return info.resident_size, info.phys_footprint


# --- the server ------------------------------------------------------------------------------------------------

def test_ready(hq):
    assert json.loads(hq.line[6:]) == {"port": hq.port, "pid": hq.proc.pid, "api": 2, "loaded": ["zh", "en"],
                                       "engine": "qwen", "model": hq.model}
    print(f"{hq.model}: start -> READY (both routes warm) in {hq.ready_s:.2f} s")


def test_health(hq):
    data = json.loads(hq.request("GET", "/health")[2])
    assert {k: data[k] for k in ("status", "api", "loaded", "engine", "model")} == {
        "status": "ok", "api": 2, "loaded": ["zh", "en"], "engine": "qwen", "model": hq.model}
    assert {k: data["versions"][k] for k in ("mlx", "mlx_audio", "transformers", "misaki")} == {
        "mlx": "0.32.4", "mlx_audio": "0.6.0", "transformers": "5.20.2", "misaki": "0.9.4"}
    assert data["versions"]["python"] == "3.12.15"


def test_voices(hq):
    assert json.loads(hq.request("GET", "/voices")[2]) == {"zh": ["serena"], "en": ["aiden"]}
    assert error(hq.request("POST", "/synthesize", {"text": "你好", "voice": "vivian"}))[:2] == (400, "unknown_voice")
    assert error(hq.request("POST", "/synthesize", {"text": "Hi", "voice": "aiden", "lang": "zh"}))[:2] == (
        400, "voice_language_mismatch")


def test_chinese(hq):
    result = synthesize(hq, text=ZH, voice="serena", lang="zh", speed=1.3)
    assert result["speed"] == 1.3 and result["synth_speed"] == 1.0 and result["lang"] == "zh"
    # frontend_zh writes out the date and the price; "iPhone 17 Pro", a Latin run, goes to the model as it is.
    assert [s["text"] for s in result["sentences"]] == [
        "二零二六年十月二十日，苹果发布了 iPhone 17 Pro，起售价为七千九百九十九元。"]
    check_sentences(result)
    print(f"{hq.model} zh: {result['sentences'][0]['text']} -> {result['duration']:.2f} s in {result['wall_s']:.2f} s")


def test_english(hq):
    result = synthesize(hq, text=EN, voice="aiden", lang="en")
    assert result["synth_speed"] == 1.0 and result["lang"] == "en" and len(result["sentences"]) == 2
    check_sentences(result)
    print(f"{hq.model} en: {[s['text'] for s in result['sentences']]} -> {result['duration']:.2f} s in "
          f"{result['wall_s']:.2f} s")


def test_the_same_text_comes_back_as_the_same_audio(hq):
    for text, voice in (("你好，欢迎使用高质量语音朗读。", "serena"), ("Good morning, and welcome back.", "aiden")):
        first, again = (synthesize(hq, text=text, voice=voice)["audio"] for _ in range(2))
        assert first == again, text


def test_wav(hq):
    status, headers, body = hq.request("POST", "/synthesize", {"text": "Hello there.", "voice": "aiden",
                                                               "format": "wav", "speed": 1.5}, timeout=300)
    assert status == 200 and headers["content-type"] == "audio/wav"
    assert headers["x-readread-synth-speed"] == "1.0"
    frames, rate, channels, width = wav_frames(body)
    assert (rate, channels, width) == (24000, 1, 2) and 0.3 < frames / 24000 < 3.0


def test_a_cancelled_synthesis_leaves_the_engine_as_it_was(hq):
    before = synthesize(hq, text="你好，世界。", voice="serena")["audio"]
    body = json.dumps({"text": LONG_ZH, "voice": "serena", "request_id": f"gone-{hq.model}"}).encode()
    s = socket.create_connection(("127.0.0.1", hq.port), timeout=60)
    s.sendall((f"POST /synthesize HTTP/1.1\r\nHost: 127.0.0.1:{hq.port}\r\nAuthorization: Bearer {hq.token}\r\n"
               f"Content-Type: application/json\r\nContent-Length: {len(body)}\r\n\r\n").encode() + body)
    time.sleep(2.0)  # a few sentences in
    s.close()
    started = time.monotonic()
    after = synthesize(hq, text="你好，世界。", voice="serena")
    assert after["audio"] == before
    assert time.monotonic() - started < 5.0
    assert synthesis_line(hq, f"gone-{hq.model}").endswith("status=cancelled")


def test_memory_after_20_sentences(hq):
    peak = [0, 0]
    done = threading.Event()

    def watch() -> None:
        while not done.is_set():
            rss, footprint = memory(hq.proc.pid)
            peak[0], peak[1] = max(peak[0], rss), max(peak[1], footprint)
            time.sleep(0.1)

    watcher = threading.Thread(target=watch, daemon=True)
    watcher.start()
    try:
        for zh, en in zip(ZH_SENTENCES, EN_SENTENCES):
            check_sentences(synthesize(hq, text=zh, voice="serena"))
            check_sentences(synthesize(hq, text=en, voice="aiden"))
    finally:
        done.set()
        watcher.join()
    time.sleep(1.0)
    rss, footprint = memory(hq.proc.pid)
    ps_rss = int(subprocess.run(["/bin/ps", "-o", "rss=", "-p", str(hq.proc.pid)], capture_output=True, text=True,
                                check=True).stdout) * 1024
    print(f"{hq.model}: after 20 sentences RSS {rss / GB:.2f} GB (ps {ps_rss / GB:.2f}), footprint "
          f"{footprint / GB:.2f} GB; peak RSS {peak[0] / GB:.2f} GB, peak footprint {peak[1] / GB:.2f} GB")
    assert rss < 6 * GB and ps_rss < 6 * GB and footprint < 6 * GB


def test_nothing_written_outside_the_cache_dir(hq):
    assert list((hq.workdir / "home").iterdir()) == []
    assert list((hq.workdir / "tmp").iterdir()) == []
    assert not (hq.workdir / "support").exists()


def test_sigterm_mid_synthesis_exits_within_1_s(hq):
    # The module's server goes here: the last test of the model that uses it running.
    holder: dict = {}

    def run() -> None:
        try:
            holder["r"] = hq.request("POST", "/synthesize", {"text": LONG_ZH, "voice": "serena"}, timeout=60)
        except OSError as e:
            holder["error"] = e

    client = threading.Thread(target=run, daemon=True)
    client.start()
    time.sleep(2.0)
    assert hq.proc.poll() is None and "r" not in holder  # still synthesizing
    started = time.monotonic()
    hq.proc.send_signal(signal.SIGTERM)
    elapsed = wait_exit(hq.proc, 1.0)
    assert elapsed is not None, "still running 1 s after SIGTERM"
    assert hq.proc.returncode == 0
    client.join(10)
    assert "r" not in holder  # the client got no response, only a closed connection
    print(f"{hq.model}: exited {time.monotonic() - started:.3f} s after SIGTERM mid-synthesis")


def test_stdin_eof_mid_synthesis_exits(hq, tmp_path_factory):
    hq.stop()  # gone already (the test above); one model in memory at a time
    srv = start(tmp_path_factory.mktemp("q"), hq.model, "zh")
    try:
        assert srv.port, srv.line + srv.log()
        thread = threading.Thread(target=lambda: _quiet(srv.request, "POST", "/synthesize",
                                                        {"text": LONG_ZH, "voice": "serena"}), daemon=True)
        thread.start()
        time.sleep(2.0)
        assert srv.proc.poll() is None
        started = time.monotonic()
        srv.proc.stdin.close()
        assert wait_exit(srv.proc, 2.0) is not None, "still running 2 s after stdin closed"
        assert srv.proc.returncode == 0 and "stdin closed, exiting" in srv.log()
        print(f"{hq.model}: exited {time.monotonic() - started:.3f} s after stdin EOF mid-synthesis")
    finally:
        srv.stop()


def _quiet(function, *args) -> None:
    try:
        function(*args, timeout=60)
    except OSError:
        pass
