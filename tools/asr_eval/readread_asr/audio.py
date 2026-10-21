"""Audio helpers, ported verbatim from the lab: decoding to 16 kHz mono float32, silence analysis, runs of exact
zeros, and cutting long audio at silences for SenseVoice."""
from __future__ import annotations

SR = 16000


# --------------------------------------------------------------------------------------------------------------
# audio helpers
# --------------------------------------------------------------------------------------------------------------
def load_audio(path: str):
    import numpy as np
    import soundfile as sf
    import soxr
    info = sf.info(path)
    a, sr = sf.read(path, dtype="float32", always_2d=True)
    mono = a.mean(axis=1).astype(np.float32)
    a16 = mono if sr == SR else soxr.resample(mono, sr, SR, quality="HQ").astype(np.float32)
    return a16, {"sample_rate": info.samplerate, "channels": info.channels, "subtype": info.subtype,
                 "seconds": round(info.frames / info.samplerate, 4) if info.samplerate else 0.0}


def frame_db(x, win=0.02, hop=0.01):
    import numpy as np
    n, h = int(SR * win), int(SR * hop)
    if len(x) < n:
        return np.array([-120.0])
    fr = np.lib.stride_tricks.sliding_window_view(x, n)[::h]
    rms = np.sqrt(np.mean(fr.astype(np.float64) ** 2, axis=1))
    return 20 * np.log10(rms + 1e-12)


def silence_analysis(x, min_run_s=0.15):
    import numpy as np
    hop = 0.01
    db = frame_db(x)
    thr = max(-60.0, float(np.percentile(db, 95)) - 40.0)
    sil = db < thr
    runs, i, nfr = [], 0, len(sil)
    while i < nfr:
        if sil[i]:
            j = i
            while j < nfr and sil[j]:
                j += 1
            runs.append((i * hop, min(len(x) / SR, j * hop + 0.02 - 0.01)))
            i = j
        else:
            i += 1
    total = len(x) / SR
    nz = np.flatnonzero(~sil)
    lead = float(nz[0] * hop) if len(nz) else total
    trail_end = float(min(total, nz[-1] * hop + 0.02)) if len(nz) else 0.0
    internal = [(a, b) for a, b in runs if a > lead + 1e-6 and b < trail_end - 1e-6 and (b - a) >= min_run_s]
    return {"threshold_db": round(thr, 1), "leading_s": round(lead, 3), "trailing_s": round(total - trail_end, 3),
            "speech_s": round(float((~sil).sum()) * hop, 3),
            "internal": [(round(a, 3), round(b - a, 3)) for a, b in internal],
            "trim": (int(lead * SR), int(trail_end * SR))}


def digital_zero_runs(path, min_s=0.3, edge_s=0.1):
    """Runs of exactly-zero samples (native sample values, before resampling) of >= min_s seconds. A TTS never
    produces exact digital silence inside speech by itself; such runs mark e.g. NaN output written as zeros.
    'leading' / 'trailing' = the run starts within edge_s of the file start / ends within edge_s of its end
    (v2.1; v2 required the exact first / last sample). Edge runs are padding and are not flagged as digital_silence."""
    import numpy as np
    import soundfile as sf
    x, sr = sf.read(path, dtype="int16", always_2d=True)
    z = np.all(x == 0, axis=1)
    if not z.any():
        return []
    d = np.diff(np.concatenate(([0], z.astype(np.int8), [0])))
    starts, ends = np.flatnonzero(d == 1), np.flatnonzero(d == -1)
    out = []
    for a, b in zip(starts, ends):
        if (b - a) / sr >= min_s:
            edge = int(round(edge_s * sr))
            out.append({"at_s": round(a / sr, 3), "dur_s": round((b - a) / sr, 3), "leading": bool(a <= edge),
                        "trailing": bool(b >= len(z) - edge)})
    return out


def chunk_at_silences(x, max_s=25.0, min_gap_s=0.2):
    total = len(x) / SR
    if total <= max_s:
        return [(0, len(x))]
    sa = silence_analysis(x, min_run_s=min_gap_s)
    mids = [a + d / 2 for a, d in sa["internal"]]
    cuts, start = [], 0.0
    while total - start > max_s:
        cand = [m for m in mids if start + 5.0 < m <= start + max_s]
        cut = cand[-1] if cand else start + max_s
        cuts.append(cut)
        start = cut
    bounds = [0.0] + cuts + [total]
    return [(int(a * SR), int(b * SR)) for a, b in zip(bounds[:-1], bounds[1:])]
