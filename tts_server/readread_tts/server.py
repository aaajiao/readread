"""HTTP API v2: GET /health, GET /voices, POST /synthesize (tts_server/README.md has the details), for either
engine (readread_tts.engine).

Every request needs the bearer token and a loopback Host header; every error is JSON,
{"error": {"code": ..., "message": ...}}. One synthesis runs at a time (Engine.lock). A synthesis whose
client disconnects while it waits for the lock or between sentences is dropped without a response and
logged as cancelled.
"""

from __future__ import annotations

import base64
import hmac
import json
import logging
import math
import os
import re
import select
import socket
import socketserver
import uuid
from dataclasses import dataclass
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

from . import audio
from .engine import Cancelled, Engine, Synthesis, VoiceError

log = logging.getLogger("readread.http")

API_VERSION = 2
MAX_TEXT = 4000  # characters
MAX_BODY = 1 << 20  # bytes
STATUS = {"bad_request": 400, "unauthorized": 401, "forbidden": 403, "not_found": 404, "too_large": 413,
          "unsupported_media_type": 415, "unknown_voice": 400, "voice_language_mismatch": 400, "internal": 500}
_CODE_FOR_STATUS = {401: "unauthorized", 403: "forbidden", 404: "not_found", 413: "too_large",
                    415: "unsupported_media_type", 500: "internal"}
_UNSAFE = re.compile(r"[^\x21-\x7e]")  # for header values and log fields
_CONTROL = re.compile(r"[\x00-\x1f\x7f]")


class ApiError(Exception):
    def __init__(self, code: str, message: str, headers: dict[str, str] | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.status = STATUS[code]
        self.headers = headers or {}


@dataclass(frozen=True)
class SynthesisRequest:
    text: str
    voice: str
    lang: str | None
    speed: float
    request_id: str
    format: str


def parse_synthesis(body: object) -> SynthesisRequest:
    """Validate a /synthesize body; null counts as absent for the optional fields."""
    if not isinstance(body, dict):
        raise ApiError("bad_request", "the body must be a JSON object")
    text = body.get("text")
    if not isinstance(text, str):
        raise ApiError("bad_request", '"text" is required and must be a string')
    if len(text) > MAX_TEXT:
        raise ApiError("too_large", f'"text" has {len(text)} characters; the limit is {MAX_TEXT}')
    voice = body.get("voice")
    if not isinstance(voice, str) or not voice:
        raise ApiError("bad_request", '"voice" is required and must be a non-empty string')
    lang = body.get("lang")
    if lang is not None and lang not in ("zh", "en", "en-us", "en-gb"):
        raise ApiError("bad_request", '"lang" must be "zh" or "en" ("en-us" and "en-gb" are accepted too)')
    speed = body.get("speed")
    speed = 1.0 if speed is None else _number(speed)
    if speed is None or not 0.5 <= speed <= 2.0:
        raise ApiError("bad_request", '"speed" must be a number from 0.5 to 2.0')
    request_id = body.get("request_id")
    if request_id is None:
        request_id = uuid.uuid4().hex[:12]
    elif not isinstance(request_id, str) or len(request_id) > 128 or not _encodable(request_id):
        raise ApiError("bad_request", '"request_id" must be a string of at most 128 characters')
    fmt = body.get("format")
    if fmt is None:
        fmt = "json"
    if fmt not in ("json", "wav"):
        raise ApiError("bad_request", '"format" must be "json" or "wav"')
    return SynthesisRequest(text, voice, lang, speed, request_id, fmt)


def _number(value: object) -> float | None:
    """A finite JSON number as float; None for anything else (booleans, strings, 1e999, huge integers)."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    try:
        number = float(value)
    except OverflowError:
        return None
    return number if math.isfinite(number) else None


def _encodable(text: str) -> bool:
    """False for strings with lone surrogates, which JSON allows but UTF-8 cannot carry back."""
    try:
        text.encode("utf-8")
    except UnicodeEncodeError:
        return False
    return True


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, engine: Engine, token: str) -> None:
        self.engine = engine
        self.auth = f"Bearer {token}".encode("ascii")
        self.versions = engine.versions()
        super().__init__(("127.0.0.1", 0), Handler)
        self.port = self.server_address[1]
        self.hosts = frozenset({f"127.0.0.1:{self.port}", f"localhost:{self.port}"})

    def server_bind(self) -> None:
        socketserver.TCPServer.server_bind(self)  # skip HTTPServer's reverse DNS lookup of the address
        self.server_name, self.server_port = self.server_address[:2]

    def handle_error(self, request, client_address) -> None:
        log.exception("unhandled error serving %s", client_address)


class Handler(BaseHTTPRequestHandler):
    server: Server
    protocol_version = "HTTP/1.1"
    # A malformed request line leaves the request version at this default; HTTP/0.9 would mean a bare body
    # without status line or headers, so even those errors get a proper HTTP/1.1 response.
    default_request_version = "HTTP/1.1"
    server_version = "ReadRead/2"
    timeout = 300  # seconds a kept-alive connection may idle or a client may stall

    def version_string(self) -> str:
        return self.server_version  # the default appends " Python/3.12.x"

    def do_GET(self) -> None:
        self._dispatch()

    do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = do_GET

    # --- plumbing -----------------------------------------------------------------------------------

    def _dispatch(self) -> None:
        self._body_read = False
        self._logged = False
        path = urlsplit(self.path).path
        status = 500
        try:
            self._authorize()
            endpoint = _ENDPOINTS.get(path)
            if endpoint is None:
                raise ApiError("not_found", f"no endpoint {path}")
            method, handler = endpoint
            if self.command != method:
                raise ApiError("bad_request", f"{path} takes {method} requests", {"Allow": method})
            status = handler(self)
        except ApiError as error:
            status = error.status
            self._error(error)
        except Cancelled:
            status = 499
            self.close_connection = True
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            status = 499
            self.close_connection = True
        except Exception as error:  # noqa: BLE001 - every failure becomes a JSON 500
            log.exception("internal error on %s %s", self.command, path)
            self._error(ApiError("internal", f"{type(error).__name__}: {error}"))
        if not self._logged:
            log.info("%s %s %s", self.command, _UNSAFE.sub("_", path)[:100], status)

    def _authorize(self) -> None:
        given = (self.headers.get("Authorization") or "").encode("latin-1", "replace")
        if not hmac.compare_digest(given, self.server.auth):
            raise ApiError("unauthorized", "missing or wrong bearer token")
        if (self.headers.get("Host") or "").strip().lower() not in self.server.hosts:
            port = self.server.port
            raise ApiError("forbidden", f"the Host header must be 127.0.0.1:{port} or localhost:{port}")

    def _unread_body(self) -> bool:
        if self._body_read:
            return False
        if self.headers.get("Transfer-Encoding"):
            return True
        try:
            return int(self.headers.get("Content-Length") or 0) != 0
        except ValueError:
            return True

    def _read_json(self) -> object:
        if self.headers.get("Transfer-Encoding"):
            raise ApiError("bad_request", "chunked request bodies are not supported; send Content-Length")
        raw = self.headers.get("Content-Length")
        if raw is None:
            raise ApiError("bad_request", "Content-Length is required")
        try:
            length = int(raw)
        except ValueError:
            length = -1
        if length < 0:
            raise ApiError("bad_request", f"invalid Content-Length {raw!r}")
        if length > MAX_BODY:
            raise ApiError("too_large", f"the body is {length} bytes; the limit is {MAX_BODY}")
        data = self.rfile.read(length)
        self._body_read = True
        if len(data) != length:
            self.close_connection = True
            raise ApiError("bad_request", "the body ended before Content-Length bytes")
        try:
            return json.loads(data.decode("utf-8"))
        except (UnicodeDecodeError, ValueError, RecursionError) as error:  # RecursionError: [[[[... too deep
            raise ApiError("bad_request", f"the body is not valid JSON: {error}") from None

    def _client_gone(self) -> bool:
        """True once the client has closed its end of the connection."""
        try:
            readable, _, _ = select.select([self.connection], [], [], 0)
            return bool(readable) and self.connection.recv(1, socket.MSG_PEEK) == b""
        except (OSError, ValueError):
            return True

    def _send(self, status: int, body: bytes, content_type: str, headers: dict[str, str] | None = None) -> None:
        if not self.close_connection and self._unread_body():
            self.close_connection = True  # the unread body would be parsed as the next request
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        if self.close_connection:
            self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _send_json(self, status: int, payload: dict, headers: dict[str, str] | None = None) -> None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self._send(status, body, "application/json; charset=utf-8", headers)

    def _error(self, error: ApiError) -> None:
        try:
            self._send_json(error.status, {"error": {"code": error.code, "message": str(error)}}, error.headers)
        except OSError:
            self.close_connection = True

    def send_error(self, code: int, message: str | None = None, explain: str | None = None) -> None:
        """Errors BaseHTTPRequestHandler raises itself (bad request line, unknown method, oversized
        headers, ...), as JSON; statuses outside the API's list become 400 bad_request."""
        self.close_connection = True
        text = message or HTTPStatus(code).phrase
        log.warning("protocol error %d from %s: %s", code, self.address_string(), _CONTROL.sub("_", text)[:200])
        if code not in _CODE_FOR_STATUS:
            code = 400
        try:
            self._send_json(code, {"error": {"code": _CODE_FOR_STATUS.get(code, "bad_request"), "message": text}})
        except OSError:
            pass

    def log_request(self, code="-", size="-") -> None:
        pass  # _dispatch logs one line per request

    def log_message(self, format: str, *args) -> None:  # noqa: A002 - BaseHTTPRequestHandler's signature
        log.warning("%s: %s", self.address_string(), format % args)

    # --- endpoints ----------------------------------------------------------------------------------

    def _health(self) -> int:
        engine = self.server.engine
        health = {"status": "ok", "api": API_VERSION, "pid": os.getpid(), "loaded": engine.loaded(),
                  "versions": self.server.versions, "engine": engine.name}
        if engine.model is not None:
            health["model"] = engine.model
        self._send_json(200, health)
        return 200

    def _voices(self) -> int:
        self._send_json(200, self.server.engine.voice_lists())
        return 200

    def _synthesize(self) -> int:
        engine = self.server.engine
        body: object = None
        request: SynthesisRequest | None = None
        result: Synthesis | None = None
        outcome = "internal"
        try:
            content_type = (self.headers.get("Content-Type") or "").split(";", 1)[0].strip().lower()
            if content_type != "application/json":
                raise ApiError("unsupported_media_type", "POST /synthesize needs Content-Type: application/json")
            body = self._read_json()
            request = parse_synthesis(body)
            try:
                voice = engine.resolve(request.voice, request.lang)
            except VoiceError as error:
                raise ApiError(error.code, str(error)) from None
            if self._client_gone():
                raise Cancelled
            while not engine.lock.acquire(timeout=0.1):
                if self._client_gone():
                    raise Cancelled
            try:
                result = engine.synthesize(request.text, voice, request.speed, cancelled=self._client_gone)
            finally:
                engine.lock.release()
            outcome = "ok"
        except Cancelled:
            outcome = "cancelled"
            raise
        except ApiError as error:
            outcome = error.code
            raise
        finally:
            _log_synthesis(body, request, result, outcome)
            self._logged = True

        wav = audio.to_wav(result.audio, result.sample_rate)
        headers = {"X-ReadRead-Request-Id": _UNSAFE.sub("_", request.request_id) or "-"}
        if request.format == "wav":
            headers["X-ReadRead-Duration"] = f"{result.duration:.3f}"
            headers["X-ReadRead-Synth-Speed"] = str(float(result.synth_speed))
            self._send(200, wav, "audio/wav", headers)
            return 200
        self._send_json(200, {
            "request_id": request.request_id,
            "sample_rate": result.sample_rate,
            "duration": round(result.duration, 3),
            "audio": base64.b64encode(wav).decode("ascii"),
            "silent": result.silent,
            "voice": voice.id,
            "lang": voice.route,
            "speed": request.speed,
            "synth_speed": float(result.synth_speed),
            "sentences": result.sentences,
            "tokens": result.tokens,
            "timing_ms": {"frontend": round(result.frontend_ms), "synth": round(result.synth_ms)},
        }, headers)
        return 200


_ENDPOINTS = {"/health": ("GET", Handler._health), "/voices": ("GET", Handler._voices),
              "/synthesize": ("POST", Handler._synthesize)}


def _log_synthesis(body: object, request: SynthesisRequest | None, result: Synthesis | None, outcome: str) -> None:
    """One line per synthesis request; for a request that failed validation the fields come from the body."""
    fields = body if isinstance(body, dict) else {}
    if request is not None:
        fields = {"request_id": request.request_id, "voice": request.voice, "text": request.text}

    def field(name: str, limit: int) -> str:
        value = fields.get(name)
        if not isinstance(value, str):
            return "-"
        return _UNSAFE.sub("_", value)[:limit] or "-"

    text = fields.get("text")
    log.info("synthesize request_id=%s voice=%s chars=%d sentences=%d frontend_ms=%d synth_ms=%d audio_s=%.2f "
             "status=%s", field("request_id", 64), field("voice", 32), len(text) if isinstance(text, str) else 0,
             len(result.sentences) if result else 0, round(result.frontend_ms) if result else 0,
             round(result.synth_ms) if result else 0, result.duration if result else 0.0, outcome)
