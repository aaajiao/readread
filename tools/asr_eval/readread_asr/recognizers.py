"""The ASR and speaker models, ported verbatim from the lab: faster-whisper large-v3-turbo (CTranslate2, CPU int8),
SenseVoice-Small int8 through sherpa-onnx, and the 3D-Speaker CAM++ embedding for voice drift."""
from __future__ import annotations

import json
import os
import time

from .audio import SR, chunk_at_silences


# --------------------------------------------------------------------------------------------------------------
# ASR / speaker wrappers
# --------------------------------------------------------------------------------------------------------------
WHISPER_SETTINGS = dict(task="transcribe", beam_size=5, best_of=5, patience=1.0,
                        temperature=[0.0, 0.2, 0.4, 0.6, 0.8, 1.0], compression_ratio_threshold=2.4,
                        log_prob_threshold=-1.0, no_speech_threshold=0.6, condition_on_previous_text=False,
                        initial_prompt=None, prefix=None, hotwords=None, vad_filter=False, word_timestamps=False,
                        without_timestamps=False)


class Whisper:
    name = "whisper"

    def __init__(self, model_dir, threads):
        from faster_whisper import WhisperModel
        t0 = time.time()
        self.model = WhisperModel(model_dir, device="cpu", compute_type="int8", cpu_threads=threads, num_workers=1)
        self.load_s = time.time() - t0
        self.id = f"faster-whisper-large-v3-turbo|int8|cpu|t{threads}"
        self.settings_key = json.dumps(WHISPER_SETTINGS, sort_keys=True)

    def transcribe(self, audio, lang):
        t0 = time.time()
        segs, info = self.model.transcribe(audio, language=lang, **WHISPER_SETTINGS)
        segs = list(segs)
        dt = time.time() - t0
        joiner = "" if lang == "zh" else " "
        text = joiner.join(s.text.strip() for s in segs).strip()
        seg_out = [{"start": round(s.start, 2), "end": round(s.end, 2), "text": s.text, "temperature": s.temperature,
                    "avg_logprob": round(s.avg_logprob, 3), "compression_ratio": round(s.compression_ratio, 3),
                    "no_speech_prob": round(s.no_speech_prob, 3)} for s in segs]
        return {"text": text, "segments": seg_out, "decode_s": round(dt, 3),
                "fallback_segments": sum(1 for s in segs if (s.temperature or 0) > 0),
                "temperatures": sorted({s.temperature for s in segs}),
                "no_speech_segments": sum(1 for s in segs if s.no_speech_prob > 0.6),
                "max_compression_ratio": round(max((s.compression_ratio for s in segs), default=0.0), 3)}


class SenseVoice:
    name = "sensevoice"

    def __init__(self, model_dir, threads, language="zh"):
        import sherpa_onnx
        t0 = time.time()
        self.rec = sherpa_onnx.OfflineRecognizer.from_sense_voice(
            model=os.path.join(model_dir, "model.int8.onnx"), tokens=os.path.join(model_dir, "tokens.txt"),
            num_threads=threads, use_itn=True, language=language, debug=False, provider="cpu")
        self.load_s = time.time() - t0
        self.language = language
        self.id = f"sensevoice-small-int8-2024-07-17|itn|{language}|t{threads}"
        self.settings_key = json.dumps({"language": language, "use_itn": True, "max_chunk_s": 25.0})

    def transcribe(self, audio, lang):
        t0 = time.time()
        chunks = chunk_at_silences(audio)
        streams = []
        for a, b in chunks:
            st = self.rec.create_stream()
            st.accept_waveform(SR, audio[a:b])
            streams.append(st)
        self.rec.decode_streams(streams)
        dt = time.time() - t0
        texts = [st.result.text.strip() for st in streams]
        joiner = "" if lang == "zh" else " "
        return {"text": joiner.join(texts).strip(), "chunks": [round((b - a) / SR, 2) for a, b in chunks],
                "lang_tags": [getattr(st.result, "lang", "") for st in streams], "decode_s": round(dt, 3)}


class SpeakerEmbedder:
    def __init__(self, model_path, threads=2):
        import sherpa_onnx
        t0 = time.time()
        self.ex = sherpa_onnx.SpeakerEmbeddingExtractor(sherpa_onnx.SpeakerEmbeddingExtractorConfig(
            model=model_path, num_threads=threads, debug=False, provider="cpu"))
        self.load_s = time.time() - t0
        self.name = os.path.basename(model_path)

    def embed(self, x):
        import numpy as np
        st = self.ex.create_stream()
        st.accept_waveform(sample_rate=SR, waveform=x)
        st.input_finished()
        if not self.ex.is_ready(st):
            return None
        e = np.array(self.ex.compute(st), dtype=np.float64)
        return e / (np.linalg.norm(e) + 1e-12)
