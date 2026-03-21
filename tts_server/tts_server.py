#!/usr/bin/env python3
"""ReadRead TTS Server — local HTTP server wrapping kokoro-onnx."""

import argparse
import io
import json
import os
import re
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler

import numpy as np
import soundfile as sf
from kokoro_onnx import Kokoro

kokoro: Kokoro | None = None
SAMPLE_RATE = 24000

# Lazy-loaded G2P backends for non-English languages
_g2p_cache: dict = {}


def get_g2p(lang: str):
    """Get or create a misaki G2P instance for the given language."""
    if lang in _g2p_cache:
        return _g2p_cache[lang]

    g2p = None
    if lang == "zh":
        from misaki.zh import ZHG2P
        g2p = ZHG2P()
    elif lang == "ja":
        from misaki.ja import JAG2P
        g2p = JAG2P()
    elif lang == "es":
        from misaki.es import ESG2P
        g2p = ESG2P()
    elif lang == "fr":
        from misaki.fr import FRG2P
        g2p = FRG2P()

    if g2p is not None:
        _g2p_cache[lang] = g2p
    return g2p


# Languages that espeak handles natively
ESPEAK_LANGS = {"en-us", "en-gb", "hi", "it", "pt"}

# Split text into sentences
_SENTENCE_RE = re.compile(
    r'(?<=[.!?。！？；\n])\s*|(?<=，)\s*(?=.{20,})'
)


def split_sentences(text: str, max_len: int = 200) -> list[str]:
    """Split text into short segments safe for the model's 510-token limit."""
    parts = _SENTENCE_RE.split(text)
    segments: list[str] = []
    current = ""

    for part in parts:
        part = part.strip()
        if not part:
            continue
        if len(current) + len(part) > max_len and current:
            segments.append(current)
            current = part
        else:
            current = f"{current} {part}".strip() if current else part

    if current:
        segments.append(current)

    return segments if segments else [text]


def synthesize(text: str, voice: str, speed: float, lang: str):
    """Synthesize text to audio, splitting into sentences to stay within token limits."""
    sentences = split_sentences(text)

    all_audio: list[np.ndarray] = []

    for sentence in sentences:
        if not sentence.strip():
            continue
        samples, sr = _synthesize_one(sentence, voice, speed, lang)
        all_audio.append(samples)

    if not all_audio:
        return np.zeros(0, dtype=np.float32), SAMPLE_RATE

    return np.concatenate(all_audio), SAMPLE_RATE


def _synthesize_one(text: str, voice: str, speed: float, lang: str):
    """Synthesize a single short segment."""
    if lang in ESPEAK_LANGS:
        return kokoro.create(text, voice=voice, speed=speed, lang=lang)
    else:
        g2p = get_g2p(lang)
        if g2p is None:
            return kokoro.create(text, voice=voice, speed=speed, lang=lang)

        phonemes, _ = g2p(text)
        return kokoro.create(
            phonemes, voice=voice, speed=speed, lang=lang, is_phonemes=True
        )


class TTSHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self._json_response(200, {"status": "ok"})
        elif self.path == "/voices":
            voices = [
                {"id": "af_heart", "name": "Heart", "lang": "en-us", "gender": "F"},
                {"id": "af_bella", "name": "Bella", "lang": "en-us", "gender": "F"},
                {"id": "af_sarah", "name": "Sarah", "lang": "en-us", "gender": "F"},
                {"id": "af_nicole", "name": "Nicole", "lang": "en-us", "gender": "F"},
                {"id": "am_michael", "name": "Michael", "lang": "en-us", "gender": "M"},
                {"id": "am_adam", "name": "Adam", "lang": "en-us", "gender": "M"},
                {"id": "bf_emma", "name": "Emma", "lang": "en-gb", "gender": "F"},
                {"id": "bm_george", "name": "George", "lang": "en-gb", "gender": "M"},
                {"id": "zf_xiaobei", "name": "Xiaobei", "lang": "zh", "gender": "F"},
                {"id": "zm_yunjian", "name": "Yunjian", "lang": "zh", "gender": "M"},
                {"id": "jf_alpha", "name": "Alpha", "lang": "ja", "gender": "F"},
                {"id": "ff_siwis", "name": "Siwis", "lang": "fr", "gender": "F"},
            ]
            self._json_response(200, voices)
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path != "/synthesize":
            self.send_error(404)
            return

        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length))

            text = body.get("text", "")
            voice = body.get("voice", "af_heart")
            speed = float(body.get("speed", 1.0))
            lang = body.get("lang", "en-us")

            if not text:
                self.send_error(400, "No text provided")
                return

            samples, sample_rate = synthesize(text, voice, speed, lang)

            buf = io.BytesIO()
            sf.write(buf, samples, sample_rate, format="WAV")
            audio_data = buf.getvalue()

            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(len(audio_data)))
            self.end_headers()
            self.wfile.write(audio_data)

        except Exception as e:
            msg = str(e)
            print(f"Synthesis error: {msg}", file=sys.stderr)
            import traceback
            traceback.print_exc(file=sys.stderr)
            self._json_response(500, {"error": msg})

    def _json_response(self, code, data):
        payload = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format, *args):
        pass  # suppress per-request logging


def find_model(model_dir: str) -> str:
    for name in [
        "kokoro-v1.0.fp16.onnx",
        "kokoro-v1.0.onnx",
        "kokoro-v1.0.int8.onnx",
    ]:
        path = os.path.join(model_dir, name)
        if os.path.exists(path):
            return path
    return ""


def main():
    parser = argparse.ArgumentParser(description="ReadRead TTS Server")
    parser.add_argument(
        "--model-dir",
        default=os.path.expanduser("~/.readread/models"),
    )
    parser.add_argument(
        "--port-file",
        default=os.path.expanduser("~/.readread/tts-port"),
    )
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()

    model_path = find_model(args.model_dir)
    if not model_path:
        print(f"ERROR: No model file found in {args.model_dir}", file=sys.stderr)
        sys.exit(1)

    voices_path = os.path.join(args.model_dir, "voices-v1.0.bin")
    if not os.path.exists(voices_path):
        print(
            f"ERROR: voices-v1.0.bin not found in {args.model_dir}",
            file=sys.stderr,
        )
        sys.exit(1)

    print(f"Loading model: {os.path.basename(model_path)}", file=sys.stderr)
    global kokoro
    kokoro = Kokoro(model_path, voices_path)
    print("Model loaded.", file=sys.stderr)

    server = HTTPServer(("127.0.0.1", args.port), TTSHandler)
    port = server.server_address[1]

    # Write port file so the Swift app can discover us
    os.makedirs(os.path.dirname(args.port_file), exist_ok=True)
    with open(args.port_file, "w") as f:
        f.write(str(port))

    print(f"TTS server listening on 127.0.0.1:{port}", file=sys.stderr)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        try:
            os.remove(args.port_file)
        except OSError:
            pass


if __name__ == "__main__":
    main()
