"""Synthesis of the corpus through the real ReadRead TTS server (HTTP API v2).

The server starts the way the app starts it (TTSServerProcess.launchConfiguration): `<python> -I -B tts_server.py
--models-dir <dir>` (plus `--engine qwen` for the optional engine), a fresh 64-hex READREAD_TOKEN in a clean
environment, READY or FATAL on stdout, stderr appended to <run>/tts-server.log, stdin held open until the end (EOF
stops it). Two differences keep a run independent of the machine's app state: the server's READREAD_CACHE_DIR is the
ASR home's tts/ (espeak-ng's limit applies: its espeak-ng-data link must fit in 150 bytes), and READREAD_USER_LEXICON
names a file that does not exist, so the user's pronunciation overrides never apply.

After READY, one short warm-up request per language loads that route (not recorded). Then every passage sentence is
one POST /synthesize (format json, speed 1.0, the passage's language); a heading gets a terminal stop first, as the
app's reader adds one (SpeechChunker.withTerminalStop). The response's WAV is written unchanged as
sentences/<sample>/NN.wav, and the sample is those WAVs joined with 0.25 s of silence (0.5 s after a heading) as
samples/<sample>.wav, the lab's protocol. manifest.jsonl gets one line per sample with the lab's fields, and
synthesis.json records what synthesized: server code hash, /health, the model files, the voices.
"""
from __future__ import annotations

import base64
import hashlib
import http.client
import json
import os
import plistlib
import queue
import secrets
import subprocess
import threading
import time
import wave

from .corpus import PASSAGES

GAP_S, HEADING_GAP_S = 0.25, 0.5
ESPEAK_MAX_PATH_BYTES = 150  # tts_server/readread_tts/espeak.py: MAX_PATH_BYTES
START_TIMEOUT_S = {"kokoro": 180.0, "qwen": 900.0}  # the app waits 90 s for Kokoro; Qwen loads 2-3 GB first
REQUEST_TIMEOUT_S = 900.0
STOP_WAIT_S = 5.0
# SpeechChunker.terminalMarks and .closers: a heading that already ends in one of these is sent as it is.
TERMINAL_MARKS = set("。！？；….!?;：:")
CLOSERS = set("”’\"'」』）)】》〉］]〕")
WARMUP = {"zh": "你好。", "en": "Hello."}
NOTES = ("one POST /synthesize per passage sentence (format json, speed 1.0, headings with a terminal stop); "
         "per_sentence_synth_s = the server's frontend + synth time, per_sentence_request_s = the client's wall time; "
         "sentences joined with 0.25 s of silence, 0.5 s after a heading")


class SynthesisError(RuntimeError):
    pass


def with_terminal_stop(text: str, lang: str) -> str:
    """SpeechChunker.withTerminalStop: a heading is read as a phrase of its own."""
    if not text:
        return text
    if text[-1] in TERMINAL_MARKS:
        return text
    if text[-1] in CLOSERS and len(text) > 1 and text[-2] in TERMINAL_MARKS:
        return text
    return text + ("。" if lang == "zh" else ".")


def server_code_sha256(server_dir: str) -> str:
    """sha256 over the server's .py and .json files (tests and caches excluded), so results name the code."""
    h = hashlib.sha256()
    files = []
    for root, dirs, names in os.walk(server_dir):
        dirs[:] = sorted(d for d in dirs if d not in ("tests", "__pycache__") and not d.startswith("."))
        for name in names:
            if name.endswith((".py", ".json")):
                files.append(os.path.relpath(os.path.join(root, name), server_dir))
    for rel in sorted(files):
        h.update(rel.encode() + b"\0")
        with open(os.path.join(server_dir, rel), "rb") as f:
            h.update(f.read())
        h.update(b"\0")
    return h.hexdigest()


def model_files(models_dir: str) -> list:
    """Name and size of every file in the models directory (qwen: one level of model folders)."""
    out = []
    for root, dirs, names in os.walk(models_dir):
        dirs[:] = sorted(d for d in dirs if not d.startswith("."))
        for name in sorted(names):
            if not name.startswith("."):
                p = os.path.join(root, name)
                out.append({"file": os.path.relpath(p, models_dir), "bytes": os.path.getsize(p)})
    return out


def app_version(server_dir: str):
    """CFBundleShortVersionString (CFBundleVersion) when the server is a built app's Contents/Resources/tts_server."""
    plist = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(server_dir))), "Info.plist")
    try:
        with open(plist, "rb") as f:
            info = plistlib.load(f)
    except (OSError, plistlib.InvalidFileException):
        return None
    return f"{info.get('CFBundleShortVersionString')} ({info.get('CFBundleVersion')})"


class Server:
    """One TTS server child process and its token."""

    def __init__(self, python, server_dir, models_dir, engine, cache_dir, home, log_path, user_lexicon):
        link = os.path.join(cache_dir, "espeak-ng-data")
        if len(os.fsencode(link)) > ESPEAK_MAX_PATH_BYTES:
            raise SynthesisError(f"the TTS cache path {link} is {len(os.fsencode(link))} bytes, more than espeak-ng's "
                                 f"{ESPEAK_MAX_PATH_BYTES}: use a shorter READREAD_ASR_HOME")
        os.makedirs(cache_dir, exist_ok=True)
        tmp = os.path.join(home, "tmp")
        os.makedirs(tmp, exist_ok=True)
        self.engine = engine
        self.token = secrets.token_hex(32)
        args = [python, "-I", "-B", os.path.join(server_dir, "tts_server.py"), "--models-dir", models_dir]
        if engine == "qwen":
            args += ["--engine", "qwen"]
        env = {"READREAD_TOKEN": self.token, "ORT_DISABLE_TELEMETRY": "1", "PYTHONDONTWRITEBYTECODE": "1",
               "PYTHONIOENCODING": "utf-8", "READREAD_CACHE_DIR": cache_dir, "READREAD_USER_LEXICON": user_lexicon,
               "HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "TMPDIR": tmp}
        self.log_path = log_path
        self._log = open(log_path, "ab")
        self.args = args
        self.proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self._log, env=env,
                                     cwd=home)
        self.ready = self._handshake(START_TIMEOUT_S[engine])
        self.port = self.ready["port"]

    def _handshake(self, timeout):
        lines = queue.Queue()
        threading.Thread(target=lambda: lines.put(self.proc.stdout.readline()), daemon=True).start()
        try:
            line = lines.get(timeout=timeout).decode("utf-8", "replace").strip()
        except queue.Empty:
            self.stop()
            raise SynthesisError(f"the TTS server sent no READY within {timeout:.0f} s; see {self.log_path}") from None
        if line.startswith("READY "):
            return json.loads(line[6:])
        self.stop()
        if line.startswith("FATAL "):
            try:
                message = json.loads(line[6:]).get("message")
            except ValueError:
                message = line[6:]
            raise SynthesisError(f"the TTS server failed to start: {message} (exit status {self.proc.returncode}); "
                                 f"see {self.log_path}")
        raise SynthesisError(f"the TTS server exited without READY (exit status {self.proc.returncode}); "
                             f"see {self.log_path}")

    def request(self, method, path, body=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=REQUEST_TIMEOUT_S)
        try:
            headers = {"Authorization": f"Bearer {self.token}"}
            data = None
            if body is not None:
                data = json.dumps(body, ensure_ascii=False).encode("utf-8")
                headers["Content-Type"] = "application/json"
            conn.request(method, path, body=data, headers=headers)
            resp = conn.getresponse()
            raw = resp.read()
        except (OSError, http.client.HTTPException) as e:
            status = self.proc.poll()
            gone = f"the server exited with status {status}" if status is not None else "the server is still running"
            raise SynthesisError(f"{method} {path}: {type(e).__name__}: {e} ({gone}; see {self.log_path})") from None
        finally:
            conn.close()
        try:
            payload = json.loads(raw)
        except ValueError:
            raise SynthesisError(f"{method} {path}: HTTP {resp.status}, not JSON ({raw[:200]!r})") from None
        if resp.status != 200:
            err = payload.get("error", {}) if isinstance(payload, dict) else {}
            raise SynthesisError(f"{method} {path}: HTTP {resp.status} {err.get('code')}: {err.get('message')}")
        return payload

    def stop(self):
        if self._log.closed:
            return
        if self.proc.poll() is None:
            try:
                self.proc.stdin.close()  # the server exits on stdin EOF
            except OSError:
                pass
            try:
                self.proc.wait(timeout=STOP_WAIT_S)
            except subprocess.TimeoutExpired:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    self.proc.wait()
        self._log.close()


def _read_wav(path):
    with wave.open(path, "rb") as w:
        if w.getnchannels() != 1 or w.getsampwidth() != 2:
            raise SynthesisError(f"{path}: not 16-bit mono ({w.getnchannels()} channels, {w.getsampwidth()} bytes)")
        return w.getframerate(), w.readframes(w.getnframes())


def _log(message: str) -> None:
    print(message, flush=True)  # stdout is a pipe or a file: show progress as it happens


def synthesize_corpus(*, source, python, server_dir, models_dir, engine, voices, out_dir, cache_dir, home,
                      log=_log) -> dict:
    """Synthesizes every passage of each voice's language into out_dir; returns synthesis.json's content."""
    t_start = time.time()
    os.makedirs(os.path.join(out_dir, "samples"), exist_ok=True)
    manifest_path = os.path.join(out_dir, "manifest.jsonl")
    if os.path.exists(manifest_path):
        raise SynthesisError(f"{out_dir} already holds a run (manifest.jsonl); give a new --out")
    no_lexicon = os.path.join(out_dir, "no-user-lexicon.json")  # never created: the server reads no overrides
    info = {"source": source, "engine": engine, "server_code_sha256": server_code_sha256(server_dir),
            "server_dir": os.path.abspath(server_dir), "python": python, "models_dir": os.path.abspath(models_dir),
            "model_files": model_files(models_dir), "voices": list(voices), "user_lexicon": None,
            "protocol": NOTES, "started": time.strftime("%Y-%m-%d %H:%M:%S")}
    if source == "app":
        info["app_version"] = app_version(server_dir)
    server = Server(python, server_dir, models_dir, engine, cache_dir, home,
                    os.path.join(out_dir, "tts-server.log"), no_lexicon)
    log(f"[asr_eval] TTS server up: {' '.join(server.args[1:])} (READY {json.dumps(server.ready)})")
    try:
        info["ready"] = server.ready
        info["health"] = server.request("GET", "/health")
        available = server.request("GET", "/voices")
        info["voices_available"] = available
        route_of = {}
        for v in voices:
            routes = [r for r, ids in available.items() if v in ids]
            if not routes:
                raise SynthesisError(f"voice {v!r} is not one of the server's voices: {available}")
            route_of[v] = routes[0]
        for route in sorted(set(route_of.values())):
            first = next(v for v in voices if route_of[v] == route)
            t0 = time.time()
            server.request("POST", "/synthesize", {"text": WARMUP[route], "voice": first, "lang": route,
                                                   "speed": 1.0, "request_id": f"asr-warmup-{route}", "format": "json"})
            log(f"[asr_eval] warm-up {route} ({first}): {time.time() - t0:.1f} s")
        samples = []
        with open(manifest_path, "w", encoding="utf-8") as manifest:
            for v in voices:
                for tid, (lang, sentences) in PASSAGES.items():
                    if lang != route_of[v]:
                        continue
                    rec = _synthesize_sample(server, info, v, tid, lang, sentences, out_dir, source)
                    manifest.write(json.dumps(rec, ensure_ascii=False) + "\n")
                    manifest.flush()
                    samples.append(rec)
                    log(f"[asr_eval] {tid:8} {v:10} {len(sentences):2d} sentences  {rec['audio_seconds']:6.1f} s audio"
                        f"  synth {rec['synth_seconds_total']:5.1f} s  rtf {rec['rtf']}")
    finally:
        server.stop()
    info["n_samples"] = len(samples)
    info["audio_seconds"] = round(sum(r["audio_seconds"] for r in samples), 2)
    info["synth_seconds"] = round(sum(r["synth_seconds_total"] for r in samples), 2)
    info["wall_s"] = round(time.time() - t_start, 1)
    with open(os.path.join(out_dir, "synthesis.json"), "w", encoding="utf-8") as f:
        json.dump(info, f, ensure_ascii=False, indent=1)
    return info


def _synthesize_sample(server, info, voice, tid, lang, sentences, out_dir, source) -> dict:
    stem = f"{tid}__{voice}"
    sent_dir = os.path.join(out_dir, "sentences", stem)
    os.makedirs(sent_dir, exist_ok=True)
    rate = None
    frames, per_audio, per_synth, per_request, per_server_sentences = [], [], [], [], []
    for i, (text, heading) in enumerate(sentences, 1):
        body = {"text": with_terminal_stop(text, lang) if heading else text, "voice": voice, "lang": lang,
                "speed": 1.0, "request_id": f"asr-{tid}-{i:02d}-{voice}", "format": "json"}
        t0 = time.time()
        try:
            res = server.request("POST", "/synthesize", body)
        except SynthesisError as e:
            raise SynthesisError(f"{voice} {tid} sentence {i} ({text[:40]!r}): {e}") from None
        per_request.append(round(time.time() - t0, 3))
        wav = base64.b64decode(res["audio"])
        path = os.path.join(sent_dir, f"{i:02d}.wav")
        with open(path, "wb") as f:
            f.write(wav)
        sr, pcm = _read_wav(path)
        if rate is None:
            rate = sr
        elif sr != rate:
            raise SynthesisError(f"{voice} {tid}: sentence {i} is {sr} Hz, the earlier ones {rate} Hz")
        frames.append(pcm)
        per_audio.append(round(len(pcm) / 2 / sr, 3))
        timing = res.get("timing_ms") or {}
        per_synth.append(round((timing.get("frontend", 0) + timing.get("synth", 0)) / 1000, 3))
        per_server_sentences.append(len(res.get("sentences") or []))
        if res.get("silent"):
            raise SynthesisError(f"{voice} {tid} sentence {i}: the server found nothing to say in {text!r}")
    path = os.path.join(out_dir, "samples", f"{stem}.wav")
    n = 0
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        for i, pcm in enumerate(frames):
            w.writeframes(pcm)
            n += len(pcm) // 2
            if i < len(frames) - 1:
                gap = int(round((HEADING_GAP_S if sentences[i][1] else GAP_S) * rate))
                w.writeframes(b"\0\0" * gap)
                n += gap
    engine = info["ready"].get("engine", info["engine"])
    model = info["ready"].get("model")
    return {"file": os.path.relpath(path, out_dir), "sentence_dir": os.path.relpath(sent_dir, out_dir),
            "lang": lang, "text_id": tid, "engine": engine, "model": f"{engine} {model or lang}", "voice": voice,
            "variant": source, "sample_rate": rate, "audio_seconds": round(n / rate, 3),
            "synth_seconds_total": round(sum(per_synth), 3),
            "rtf": round(sum(per_synth) / max(sum(per_audio), 1e-9), 4),
            "first_sentence_synth_s": per_synth[0], "per_sentence_synth_s": per_synth,
            "per_sentence_audio_s": per_audio, "per_sentence_request_s": per_request,
            "per_sentence_server_sentences": per_server_sentences,
            "load_avg": [round(x, 2) for x in os.getloadavg()], "notes": NOTES}
