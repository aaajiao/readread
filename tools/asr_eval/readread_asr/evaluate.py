"""Evaluation of one run directory, ported from the October 2026 lab (keep/lab/eval_asr.py).

Every sample of the run's manifest.jsonl is transcribed by Whisper (zh and en) and SenseVoice (zh), scored against
its passage (scoring.score) and checked for internal silences, transcript length, repetition, Whisper fallbacks and
hallucinations, exact-zero runs, the concatenation and per-sentence speaking rates; every per-sentence WAV is
embedded with CAM++ for voice drift. Transcripts are cached in <run>/asr_cache.json (key: ASR id + settings + file
path, size and mtime), so a re-score after a scoring change does not transcribe again. Writes results.json (meta,
aggregates, one record per sample) and results.csv, and prints the per-sample and per-voice tables.

Changes from the lab: the manifest is the run's own manifest.jsonl (the lab globbed manifest_*.jsonl; both match),
the log prefix, one rapidfuzz import at the top of evaluate() instead of two in branches, and args.extra_meta (the
synthesis and model provenance) merged into results.json's meta.
"""
from __future__ import annotations

import csv
import glob
import hashlib
import json
import os
import platform
import re
import resource
import statistics
import sys
import time
from collections import defaultdict

from .audio import SR, digital_zero_runs, load_audio, silence_analysis
from .corpus import EN_RULES, PASSAGES, PROBES, ZH_RULES
from .recognizers import WHISPER_SETTINGS, SenseVoice, SpeakerEmbedder, Whisper
from .scoring import SCORING_VERSION, hyp_units, norm_en_tokens, ref_units, score, strip_hallucinations, zh_units


# --------------------------------------------------------------------------------------------------------------
# cache
# --------------------------------------------------------------------------------------------------------------
class Cache:
    def __init__(self, path, enabled=True):
        self.path, self.enabled, self.data = path, enabled, {}
        if enabled and os.path.exists(path):
            try:
                with open(path, encoding="utf-8") as f:
                    self.data = json.load(f)
            except Exception:
                self.data = {}

    @staticmethod
    def key(asr, path, lang):
        st = os.stat(path)
        raw = json.dumps([asr.id, asr.settings_key, os.path.abspath(path), st.st_size, st.st_mtime_ns, lang])
        return hashlib.sha1(raw.encode()).hexdigest()

    def get(self, k):
        return self.data.get(k) if self.enabled else None

    def put(self, k, v):
        if self.enabled:
            self.data[k] = v

    def save(self):
        if self.enabled:
            tmp = self.path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(self.data, f, ensure_ascii=False)
            os.replace(tmp, self.path)


# --------------------------------------------------------------------------------------------------------------
# manifest handling
# --------------------------------------------------------------------------------------------------------------
def read_manifests(samples_dir):
    rows, problems, seen = [], [], set()
    for mf in sorted(glob.glob(os.path.join(samples_dir, "manifest*.jsonl"))):
        base = os.path.dirname(os.path.abspath(mf))
        with open(mf, encoding="utf-8") as f:
            for ln, line in enumerate(f, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    r = json.loads(line)
                except Exception as e:
                    problems.append(f"{os.path.basename(mf)}:{ln}: bad JSON ({e})")
                    continue
                if not isinstance(r, dict) or not r.get("file"):
                    problems.append(f"{os.path.basename(mf)}:{ln}: no 'file'")
                    continue
                fp = r["file"] if os.path.isabs(r["file"]) else os.path.join(base, r["file"])
                fp = os.path.abspath(fp)
                if fp in seen:
                    problems.append(f"{os.path.basename(mf)}:{ln}: duplicate file {fp} (later entry ignored)")
                    continue
                seen.add(fp)
                sd = r.get("sentence_dir")
                if sd:
                    sd = os.path.abspath(sd if os.path.isabs(sd) else os.path.join(base, sd))
                r2 = dict(r)
                r2["_file"], r2["_sentence_dir"], r2["_manifest"] = fp, sd, os.path.basename(mf)
                lang = str(r.get("lang") or "").lower()[:2]
                tid = r.get("text_id")
                r2["_lang_mismatch"] = None
                if tid in PASSAGES and lang != PASSAGES[tid][0]:
                    if lang in ("zh", "en"):
                        r2["_lang_mismatch"] = f"lang_mismatch(manifest {r.get('lang')} vs {tid})"
                    lang = PASSAGES[tid][0]          # the passage decides the language
                r2["_lang"] = lang
                rows.append(r2)
    return rows, problems


# --------------------------------------------------------------------------------------------------------------
# main evaluation
# --------------------------------------------------------------------------------------------------------------
def evaluate(args):
    import numpy as np
    from rapidfuzz.distance import Levenshtein
    t_start = time.time()
    load_start = os.getloadavg()
    rows, problems = read_manifests(args.samples_dir)
    if args.only:
        rx = re.compile(args.only)
        rows = [r for r in rows if rx.search(os.path.basename(r["_file"]))]
    print(f"[asr_eval] {len(rows)} samples from {args.samples_dir}; manifest problems: {len(problems)}", flush=True)
    for p in problems:
        print("   ", p)
    os.makedirs(args.out_dir, exist_ok=True)
    cache = Cache(os.path.join(args.out_dir, "asr_cache.json"), enabled=not args.no_cache)

    need_sv = not args.no_sensevoice and any(r["_lang"] == "zh" or args.sensevoice_en for r in rows)
    whisper = None if args.no_whisper else Whisper(args.whisper_model, args.threads)
    sv = SenseVoice(args.sensevoice_model, args.threads, args.sv_language) if need_sv else None
    sv_en = SenseVoice(args.sensevoice_model, args.threads, "en") if (need_sv and args.sensevoice_en) else None
    spk = None if args.no_drift else SpeakerEmbedder(args.spk_model, threads=2)
    speed = defaultdict(lambda: {"decode_s": 0.0, "audio_s": 0.0, "n": 0, "cached": 0})

    samples = []
    for k, r in enumerate(rows, 1):
        fp, lang, tid = r["_file"], r["_lang"], r.get("text_id")
        rec = {"file": fp, "sentence_dir": r["_sentence_dir"], "manifest": r["_manifest"], "lang": lang,
               "text_id": tid, "engine": r.get("engine"), "model": r.get("model"), "voice": r.get("voice"),
               "variant": r.get("variant"), "flags": [], "errors": [],
               "manifest_fields": {kk: r.get(kk) for kk in ("sample_rate", "audio_seconds", "synth_seconds_total",
                                                            "rtf", "first_sentence_synth_s", "peak_rss_mb",
                                                            "load_avg", "notes") if kk in r}}
        samples.append(rec)
        tag = f"[{k}/{len(rows)}] {os.path.basename(fp)}"
        if tid not in PASSAGES:
            rec["flags"].append("unknown_text_id")
        if r.get("_lang_mismatch"):
            rec["flags"].append(r["_lang_mismatch"])
        notes = r.get("notes") if isinstance(r.get("notes"), dict) else {}
        if notes.get("nan_output"):                    # synthesis lab reported NaN audio written as zeros
            zz = notes.get("nan_chunks_zeroed") or {}
            rec["flags"].append("nan_output(" + ",".join(f"s{int(k)}@{a:.2f}+{d:.2f}s" for k, v in sorted(zz.items())
                                                         for a, d in v) + ")")
        if not os.path.exists(fp):
            rec["errors"].append("missing file")
            rec["flags"].append("missing_file")
            print(tag, "MISSING", flush=True)
            continue
        try:
            audio, ainfo = load_audio(fp)
        except Exception as e:
            rec["errors"].append(f"audio decode failed: {e}")
            rec["flags"].append("decode_error")
            print(tag, "DECODE ERROR", e, flush=True)
            continue
        sa = silence_analysis(audio)
        long_sil = [(a, d) for a, d in sa["internal"] if d >= args.silence_s]
        rec["audio"] = dict(ainfo, speech_s=sa["speech_s"], leading_silence_s=sa["leading_s"],
                            trailing_silence_s=sa["trailing_s"], silence_threshold_db=sa["threshold_db"],
                            max_internal_silence_s=max((d for _, d in sa["internal"]), default=0.0),
                            internal_silences_ge_1s=[{"at_s": a, "dur_s": d} for a, d in sa["internal"] if d >= 1.0])
        if long_sil:
            rec["flags"].append(f"long_silence(n={len(long_sil)},max={max(d for _, d in long_sil):.2f}s)")
        fmt = []
        if ainfo["channels"] != 1:
            fmt.append(f"channels={ainfo['channels']}")
        if ainfo["subtype"] != "PCM_16":
            fmt.append(f"subtype={ainfo['subtype']}")
        if r.get("sample_rate") and int(r["sample_rate"]) != ainfo["sample_rate"]:
            fmt.append(f"sr={ainfo['sample_rate']}!=manifest {r['sample_rate']}")
        if fmt:
            rec["flags"].append("format(" + ",".join(fmt) + ")")
        if tid in PASSAGES:
            rec["reference"] = {"text": ("" if lang == "zh" else " ").join(t for t, _ in PASSAGES[tid][1]),
                                "units": len(ref_units(tid)[0])}

        asrs = []
        if whisper:
            asrs.append(whisper)
        if lang == "zh" and sv:
            asrs.append(sv)
        if lang == "en" and sv_en:
            asrs.append(sv_en)
        for asr in asrs:
            key = Cache.key(asr, fp, lang)
            res = cache.get(key)
            cached = res is not None
            if not cached:
                try:
                    res = asr.transcribe(audio, lang)
                except Exception as e:
                    rec["errors"].append(f"{asr.name} failed: {e}")
                    continue
                cache.put(key, res)
            sp = speed[asr.name]
            if cached:
                sp["cached"] += 1
            else:
                sp["decode_s"] += res["decode_s"]
                sp["audio_s"] += ainfo["seconds"]
                sp["n"] += 1
            out = {"asr_id": asr.id, "cached": cached}
            out.update(res)
            out["rtf"] = round(res["decode_s"] / ainfo["seconds"], 4) if ainfo["seconds"] else None
            text_scored = res["text"]
            if asr.name == "whisper":                                                          # H1
                text_scored, removed = strip_hallucinations(res, lang, sa["trim"][1] / SR)
                if removed:
                    out["hallucination_removed"] = removed
                    out["text_scored"] = text_scored
                    rec["flags"].append("whisper_hallucination(" + "; ".join(
                        f"'{x['text'][:30]}'@{x['start']:.1f}s" for x in removed) + ")")
            if tid in PASSAGES:
                sc = score(tid, lang, text_scored)
                out.update(sc)
                lr = sc["len_ratio"]
                if lr is not None and lr < args.len_low:
                    rec["flags"].append(f"len_ratio_low({asr.name}={lr:.2f})")
                if lr is not None and lr > args.len_high:
                    rec["flags"].append(f"len_ratio_high({asr.name}={lr:.2f})")
                if sc["max_extra_ngram_repeats"] >= 3:
                    rec["flags"].append(f"repetition({asr.name}:'{sc['most_repeated_ngram']}'"
                                        f"+{sc['max_extra_ngram_repeats']})")
            if asr.name == "whisper":
                if res.get("fallback_segments"):
                    rec["flags"].append(f"whisper_fallback(n={res['fallback_segments']},T={res['temperatures']})")
                if res.get("no_speech_segments"):
                    rec["flags"].append(f"no_speech_segment(n={res['no_speech_segments']})")
            rec[asr.name if asr is not sv_en else "sensevoice"] = out

        if "whisper" in rec and "sensevoice" in rec:
            w = rec["whisper"].get("normalized") or ""
            s_ = rec["sensevoice"].get("normalized") or ""
            if lang == "zh" and w:
                rec["asr_disagreement_cer"] = round(Levenshtein.distance(w, s_) / max(1, len(w)), 4)
            if tid in PASSAGES:
                ph = set(rec["whisper"]["probes"]["hit"]) | set(rec["sensevoice"]["probes"]["hit"])
                rec["probes_union"] = {"n_hit": len(ph), "n_total": rec["whisper"]["probes"]["n_total"],
                                       "missed": [p for p in rec["whisper"]["probes"]["missed"] if p not in ph]}

        # per-sentence files: counts, concat check, rates, drift, optional per-sentence ASR
        sd = r["_sentence_dir"]
        if sd and os.path.isdir(sd):
            sfiles = sorted(glob.glob(os.path.join(sd, "*.wav")),
                            key=lambda f: (int(re.search(r"\d+", os.path.basename(f)).group())
                                           if re.search(r"\d+", os.path.basename(f)) else 10 ** 9,
                                           os.path.basename(f)))
            n_pass = len(PASSAGES[tid][1]) if tid in PASSAGES else None
            rec["sentences"] = []
            if n_pass is not None and len(sfiles) != n_pass:
                rec["flags"].append(f"sentence_count({len(sfiles)}!={n_pass})")
            embs, emb_idx = [], []
            sent_audio = []
            for i, sfp in enumerate(sfiles, 1):
                try:
                    xs, si = load_audio(sfp)
                except Exception as e:
                    rec["errors"].append(f"sentence {i} decode failed: {e}")
                    continue
                ssa = silence_analysis(xs)
                a, b = ssa["trim"]
                ent = {"n": i, "seconds": si["seconds"], "speech_s": ssa["speech_s"],
                       "leading_silence_s": ssa["leading_s"], "trailing_silence_s": ssa["trailing_s"],
                       "max_internal_silence_s": max((d for _, d in ssa["internal"]), default=0.0)}
                zr = digital_zero_runs(sfp, 0.3)
                if zr:
                    ent["digital_zero_runs"] = zr
                if tid in PASSAGES and i <= len(PASSAGES[tid][1]):
                    t, _h = PASSAGES[tid][1][i - 1]
                    nu = len(zh_units(t, ref=True)) if lang == "zh" else len(norm_en_tokens(t))
                    ent["ref_units"] = nu
                    ent["units_per_s"] = round(nu / ssa["speech_s"], 3) if ssa["speech_s"] > 0 else None
                    ent["heading"] = _h
                rec["sentences"].append(ent)
                sent_audio.append((i, xs))
                if spk is not None:
                    seg = xs[a:b] if b - a > SR * 0.3 else xs
                    t0 = time.time()
                    e = spk.embed(seg.astype(np.float32))
                    speed["speaker"]["decode_s"] += time.time() - t0
                    speed["speaker"]["audio_s"] += len(seg) / SR
                    speed["speaker"]["n"] += 1
                    if e is not None:
                        embs.append(e)
                        emb_idx.append(i)
                        ent["embedded_speech_s"] = round(len(seg) / SR, 3)
            dz = [f"s{s['n']}@{z['at_s']:.2f}+{z['dur_s']:.2f}s" for s in rec["sentences"]
                  for z in s.get("digital_zero_runs", [])
                  if not (z["leading"] or z["trailing"]) and z["dur_s"] >= args.zero_run_s]
            if dz:
                rec["flags"].append("digital_silence(" + ",".join(dz) + ")")
            de = [f"s{s['n']} {'start' if z['leading'] else 'end'} {z['dur_s']:.2f}s" for s in rec["sentences"]
                  for z in s.get("digital_zero_runs", [])
                  if (z["leading"] or z["trailing"]) and z["dur_s"] >= args.zero_run_s]
            if de:
                rec["flags"].append("edge_zero_run(" + ",".join(de) + ")")
            # concat check
            if tid in PASSAGES and rec["sentences"] and len(sfiles) <= len(PASSAGES[tid][1]):
                # contract gaps; with fewer files than sentences, files are assumed to be sentences 1..n
                gaps = sum(0.5 if PASSAGES[tid][1][j][1] else 0.25 for j in range(len(sfiles) - 1))
                expect = sum(s["seconds"] for s in rec["sentences"]) + gaps
                diff = ainfo["seconds"] - expect
                rec["concat_check"] = {"expected_s": round(expect, 3), "actual_s": ainfo["seconds"],
                                       "diff_s": round(diff, 3)}
                if abs(diff) > 0.35:
                    rec["flags"].append(f"concat_mismatch({diff:+.2f}s)")
            rates = [s["units_per_s"] for s in rec["sentences"] if s.get("units_per_s") and not s.get("heading")]
            if len(rates) >= 3:
                med = statistics.median(rates)
                odd = [s["n"] for s in rec["sentences"] if s.get("units_per_s") and not s.get("heading")
                       and (s["units_per_s"] > 2 * med or s["units_per_s"] < 0.5 * med)]
                if odd:
                    rec["flags"].append(f"sentence_rate(s{','.join(map(str, odd))})")
            if len(embs) >= 2:
                E = np.stack(embs)
                m = E.mean(axis=0)
                m /= np.linalg.norm(m) + 1e-12
                cos = E @ m
                loo = []
                for j in range(len(E)):
                    o = E.sum(axis=0) - E[j]
                    o /= np.linalg.norm(o) + 1e-12
                    loo.append(float(E[j] @ o))
                for j, i in enumerate(emb_idx):
                    for s in rec["sentences"]:
                        if s["n"] == i:
                            s["cos_to_mean"] = round(float(cos[j]), 4)
                            s["cos_loo"] = round(loo[j], 4)
                            s["short"] = s["speech_s"] < 1.0
                jmin = int(np.argmin(cos))
                jl = int(np.argmin(loo))
                rec["drift"] = {"model": spk.name, "n": len(E), "mean_cos": round(float(cos.mean()), 4),
                                "min_cos": round(float(cos.min()), 4), "min_sentence": emb_idx[jmin],
                                "loo_mean_cos": round(float(np.mean(loo)), 4), "loo_min_cos": round(min(loo), 4),
                                "loo_min_sentence": emb_idx[jl]}
                if min(loo) < args.drift_flag:
                    rec["flags"].append(f"voice_drift(s{emb_idx[jl]},loo={min(loo):.2f})")
            if args.per_sentence_asr and tid in PASSAGES:
                rec["per_sentence_asr"] = {}
                for asr in asrs:
                    lst = []
                    for i, xs in sent_audio:
                        if i > len(PASSAGES[tid][1]):
                            continue
                        key = Cache.key(asr, sfiles[i - 1], lang)
                        res = cache.get(key)
                        if res is None:
                            res = asr.transcribe(xs, lang)
                            cache.put(key, res)
                        ref_t = PASSAGES[tid][1][i - 1][0]
                        ru = zh_units(ref_t, ref=True) if lang == "zh" else norm_en_tokens(ref_t)
                        hu = hyp_units(res["text"], lang)
                        d = Levenshtein.distance(ru, hu)
                        lst.append({"n": i, "text": res["text"], "err": d, "ref_units": len(ru),
                                    "rate": round(d / len(ru), 4) if ru else None})
                    rec["per_sentence_asr"][asr.name] = lst
        elif sd:
            rec["flags"].append("sentence_dir_missing")
        w = rec.get("whisper", {})
        s_ = rec.get("sensevoice", {})
        print(f"{tag}  {ainfo['seconds']:.1f}s  W {w.get('metric', '')}={w.get('error_rate')} "
              f"SV={s_.get('error_rate')}  drift_loo_min={rec.get('drift', {}).get('loo_min_cos')}", flush=True)
        if k % 5 == 0:
            cache.save()
    cache.save()

    # cross-sample duration checks
    by_tid = defaultdict(list)
    for rec in samples:
        if "audio" in rec and rec["text_id"] in PASSAGES:
            by_tid[rec["text_id"]].append(rec)
    for tid, recs in by_tid.items():
        durs = [x["audio"]["seconds"] for x in recs]
        med = statistics.median(durs)
        med_sp = statistics.median(x["audio"]["speech_s"] for x in recs)
        for x in recs:
            ratio = x["audio"]["seconds"] / med if med else None
            sp_ratio = x["audio"]["speech_s"] / med_sp if med_sp else None
            x["duration_ratio_to_median"] = round(ratio, 4) if ratio else None
            x["speech_ratio_to_median"] = round(sp_ratio, 4) if sp_ratio else None
            x["duration_median_s"] = round(med, 3)
            x["duration_group_n"] = len(recs)
            if len(recs) >= 2 and ratio and (ratio < args.dur_low or ratio > args.dur_high):
                x["flags"].append(f"duration_outlier(x{ratio:.2f} of median {med:.1f}s)")
            elif len(recs) >= 2 and sp_ratio and (sp_ratio < args.dur_low or sp_ratio > args.dur_high):
                x["flags"].append(f"duration_outlier(speech x{sp_ratio:.2f} of median {med_sp:.1f}s)")
        n_s = len(PASSAGES[tid][1])
        for i in range(1, n_s + 1):
            vals = [(x, s["seconds"]) for x in recs for s in x.get("sentences", []) if s["n"] == i]
            if len(vals) >= 3:
                med_i = statistics.median(v for _, v in vals)
                for x, v in vals:
                    if med_i and (v / med_i < 0.6 or v / med_i > 1.6):
                        x["flags"].append(f"sentence_duration(s{i}:x{v / med_i:.2f})")

    # aggregates per engine/model/voice/variant
    agg = defaultdict(lambda: {"n": 0, "zh_whisper_cer": [], "zh_sensevoice_cer": [], "en_whisper_wer": [],
                               "zh_whisper_per": [], "zh_sensevoice_per": [], "zh_whisper_cer_char": [],
                               "zh_sensevoice_cer_char": [], "probes_hit": 0, "probes_total": 0,
                               "probes_sv_hit": 0, "probes_sv_total": 0, "probes_union_hit": 0, "flags": 0,
                               "drift_loo_min": [], "text_ids": []})
    for rec in samples:
        g = agg[f"{rec['engine']}|{rec['model']}|{rec['voice']}|{rec['variant']}"]
        g["n"] += 1
        g["flags"] += len(rec["flags"])
        g["text_ids"].append(rec["text_id"])
        w = rec.get("whisper")
        if w and w.get("error_rate") is not None:
            (g["zh_whisper_cer"] if rec["lang"] == "zh" else g["en_whisper_wer"]).append(w["error_rate"])
            if rec["lang"] == "zh":
                g["zh_whisper_per"].append(w.get("per_toneless"))
                g["zh_whisper_cer_char"].append(w.get("char_error_rate"))
            g["probes_hit"] += w["probes"]["n_hit"]
            g["probes_total"] += w["probes"]["n_total"]
            g["probes_union_hit"] += (rec.get("probes_union") or w["probes"])["n_hit"]
        sv_ = rec.get("sensevoice")
        if sv_ and sv_.get("error_rate") is not None and rec["lang"] == "zh":
            g["zh_sensevoice_cer"].append(sv_["error_rate"])
            g["zh_sensevoice_per"].append(sv_.get("per_toneless"))
            g["zh_sensevoice_cer_char"].append(sv_.get("char_error_rate"))
            g["probes_sv_hit"] += sv_["probes"]["n_hit"]
            g["probes_sv_total"] += sv_["probes"]["n_total"]
        if rec.get("drift"):
            g["drift_loo_min"].append(rec["drift"]["loo_min_cos"])
    aggregates = []
    for key, g in sorted(agg.items()):
        e, m, v, var = key.split("|")
        aggregates.append({"engine": e, "model": m, "voice": v, "variant": var, "n_samples": g["n"],
                           "text_ids": g["text_ids"],
                           "zh_whisper_cer_mean": _mean(g["zh_whisper_cer"]),
                           "zh_sensevoice_cer_mean": _mean(g["zh_sensevoice_cer"]),
                           "zh_whisper_per_toneless_mean": _mean([x for x in g["zh_whisper_per"] if x is not None]),
                           "zh_sensevoice_per_toneless_mean": _mean([x for x in g["zh_sensevoice_per"]
                                                                     if x is not None]),
                           "zh_whisper_cer_char_mean": _mean([x for x in g["zh_whisper_cer_char"] if x is not None]),
                           "zh_sensevoice_cer_char_mean": _mean([x for x in g["zh_sensevoice_cer_char"]
                                                                 if x is not None]),
                           "en_whisper_wer_mean": _mean(g["en_whisper_wer"]),
                           "probes_whisper": f"{g['probes_hit']}/{g['probes_total']}",
                           "probes_sensevoice": (f"{g['probes_sv_hit']}/{g['probes_sv_total']}"
                                                 if g["probes_sv_total"] else None),
                           "probes_either_asr": f"{g['probes_union_hit']}/{g['probes_total']}",
                           "n_flags": g["flags"], "drift_loo_min": min(g["drift_loo_min"]) if g["drift_loo_min"] else None})

    peak_rss_mb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1e6 if sys.platform == "darwin" else 1e3)
    speed_out = {}
    for name, sp in speed.items():
        speed_out[name] = {"n_files": sp["n"], "audio_s": round(sp["audio_s"], 2), "decode_s": round(sp["decode_s"], 2),
                           "rtf": round(sp["decode_s"] / sp["audio_s"], 4) if sp["audio_s"] else None,
                           "sec_per_audio_min": round(60 * sp["decode_s"] / sp["audio_s"], 2) if sp["audio_s"] else None,
                           "cached_files_skipped": sp["cached"]}
    meta = {"created": time.strftime("%Y-%m-%d %H:%M:%S"), "scoring_version": SCORING_VERSION,
            "samples_dir": args.samples_dir, "n_samples": len(samples),
            "manifest_problems": problems, "platform": platform.platform(), "python": sys.version.split()[0],
            "versions": _versions(), "threads": args.threads,
            "models": {"whisper": args.whisper_model, "sensevoice": args.sensevoice_model, "speaker": args.spk_model},
            "whisper_settings": WHISPER_SETTINGS,
            "sensevoice_settings": {"language_zh": args.sv_language, "use_itn": True, "max_chunk_s": 25.0,
                                    "en_samples": bool(args.sensevoice_en)},
            "load_times_s": {"whisper": round(whisper.load_s, 2) if whisper else None,
                             "sensevoice": round(sv.load_s, 2) if sv else None,
                             "speaker": round(spk.load_s, 2) if spk else None},
            "speed": speed_out, "peak_rss_mb": round(peak_rss_mb, 1),
            "load_avg_start": [round(x, 2) for x in load_start],
            "load_avg_end": [round(x, 2) for x in os.getloadavg()], "wall_s": round(time.time() - t_start, 1),
            "thresholds": {"dur_low": args.dur_low, "dur_high": args.dur_high, "silence_s": args.silence_s,
                           "len_low": args.len_low, "len_high": args.len_high, "drift_flag": args.drift_flag},
            "normalization": {"zh": ZH_RULES, "en": EN_RULES}, "probes": PROBES}
    meta.update(getattr(args, "extra_meta", None) or {})
    out = {"meta": meta, "aggregates": aggregates, "samples": samples}
    jpath = os.path.join(args.out_dir, "results.json")
    with open(jpath, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
    cpath = os.path.join(args.out_dir, "results.csv")
    write_csv(cpath, samples)
    print_summary(samples, aggregates, meta)
    print(f"\n[asr_eval] wrote {jpath}\n[asr_eval] wrote {cpath}")
    return out


def _mean(v):
    return round(sum(v) / len(v), 4) if v else None


def _versions():
    import importlib.metadata as md
    out = {}
    for p in ("faster-whisper", "ctranslate2", "sherpa-onnx", "sherpa-onnx-core", "numpy", "soundfile", "soxr",
              "rapidfuzz", "opencc-python-reimplemented", "text2num", "onnxruntime", "pypinyin"):
        try:
            out[p] = md.version(p)
        except Exception:
            out[p] = None
    return out


CSV_COLS = ["file", "lang", "text_id", "engine", "model", "voice", "variant", "audio_s", "duration_ratio_to_median",
            "metric", "whisper_err", "whisper_en_cer", "sensevoice_err", "whisper_char_cer", "sensevoice_char_cer",
            "whisper_per", "sensevoice_per", "whisper_per_toneless", "sensevoice_per_toneless",
            "asr_disagreement_cer", "whisper_probes",
            "sensevoice_probes", "either_probes", "whisper_probes_pinyin_only", "sensevoice_probes_pinyin_only",
            "whisper_missed", "sensevoice_missed", "whisper_len_ratio",
            "sensevoice_len_ratio", "max_internal_silence_s", "whisper_fallback_segments", "drift_mean_cos",
            "drift_min_cos", "drift_loo_min_cos", "drift_loo_min_sentence", "whisper_rtf", "sensevoice_rtf", "flags",
            "whisper_text", "sensevoice_text"]


def write_csv(path, samples):
    with open(path, "w", encoding="utf-8", newline="") as f:
        wr = csv.DictWriter(f, fieldnames=CSV_COLS)
        wr.writeheader()
        for r in samples:
            w, s = r.get("whisper", {}), r.get("sensevoice", {})
            d = r.get("drift", {})
            wr.writerow({
                "file": r["file"], "lang": r["lang"], "text_id": r["text_id"], "engine": r["engine"],
                "model": r["model"], "voice": r["voice"], "variant": r["variant"],
                "audio_s": r.get("audio", {}).get("seconds"),
                "duration_ratio_to_median": r.get("duration_ratio_to_median"), "metric": w.get("metric"),
                "whisper_err": w.get("error_rate"),
                "whisper_en_cer": w.get("char_error_rate") if r["lang"] == "en" else None,
                "sensevoice_err": s.get("error_rate"),
                "whisper_char_cer": w.get("char_error_rate") if r["lang"] == "zh" else None,
                "sensevoice_char_cer": s.get("char_error_rate") if r["lang"] == "zh" else None,
                "whisper_per": w.get("per"), "sensevoice_per": s.get("per"),
                "whisper_per_toneless": w.get("per_toneless"), "sensevoice_per_toneless": s.get("per_toneless"),
                "asr_disagreement_cer": r.get("asr_disagreement_cer"),
                "whisper_probes": f"{w['probes']['n_hit']}/{w['probes']['n_total']}" if w.get("probes") else "",
                "sensevoice_probes": f"{s['probes']['n_hit']}/{s['probes']['n_total']}" if s.get("probes") else "",
                "either_probes": (f"{r['probes_union']['n_hit']}/{r['probes_union']['n_total']}"
                                  if r.get("probes_union") else ""),
                "whisper_probes_pinyin_only": " | ".join(w["probes"].get("pinyin_only", [])) if w.get("probes") else "",
                "sensevoice_probes_pinyin_only": " | ".join(s["probes"].get("pinyin_only", [])) if s.get("probes") else "",
                "whisper_missed": " | ".join(w["probes"]["missed"]) if w.get("probes") else "",
                "sensevoice_missed": " | ".join(s["probes"]["missed"]) if s.get("probes") else "",
                "whisper_len_ratio": w.get("len_ratio"), "sensevoice_len_ratio": s.get("len_ratio"),
                "max_internal_silence_s": r.get("audio", {}).get("max_internal_silence_s"),
                "whisper_fallback_segments": w.get("fallback_segments"), "drift_mean_cos": d.get("mean_cos"),
                "drift_min_cos": d.get("min_cos"), "drift_loo_min_cos": d.get("loo_min_cos"),
                "drift_loo_min_sentence": d.get("loo_min_sentence"), "whisper_rtf": w.get("rtf"),
                "sensevoice_rtf": s.get("rtf"), "flags": "; ".join(r["flags"]),
                "whisper_text": w.get("text_scored", w.get("text")), "sensevoice_text": s.get("text")})


def _pct(x):
    return "-" if x is None else f"{100 * x:.1f}"


def print_summary(samples, aggregates, meta):
    print("\n=== per sample (W = Whisper large-v3-turbo int8; SV = SenseVoice-Small int8; err = CER zh / WER en, %) ===")
    hdr = f"{'#':>3} {'text_id':8} {'engine':18} {'voice':22} {'variant':10} {'dur':>6} {'W err':>6} {'SV err':>6} " \
          f"{'W prb':>6} {'SV prb':>6} {'drift':>6}  flags"
    print(hdr)
    print("-" * len(hdr))
    for i, r in enumerate(samples, 1):
        w, s, d = r.get("whisper", {}), r.get("sensevoice", {}), r.get("drift", {})
        wp = f"{w['probes']['n_hit']}/{w['probes']['n_total']}" if w.get("probes") else "-"
        sp = f"{s['probes']['n_hit']}/{s['probes']['n_total']}" if s.get("probes") else "-"
        dm = f"{d['loo_min_cos']:.2f}" if d else "-"
        print(f"{i:>3} {str(r['text_id'])[:8]:8} {str(r['engine'])[:18]:18} {str(r['voice'])[:22]:22} "
              f"{str(r['variant'])[:10]:10} {r.get('audio', {}).get('seconds', 0):6.1f} {_pct(w.get('error_rate')):>6} "
              f"{_pct(s.get('error_rate')):>6} {wp:>6} {sp:>6} {dm:>6}  {'; '.join(r['flags'])[:120]}")
        if w.get("probes", {}).get("missed"):
            print(f"{'':>4}W missed: {' | '.join(w['probes']['missed'])}")
        if s.get("probes", {}).get("missed"):
            print(f"{'':>4}SV missed: {' | '.join(s['probes']['missed'])}")
    print("\n=== per engine/voice/variant (means over that group's text_ids; compare per text_id for rankings) ===")
    print(f"{'engine':18} {'voice':22} {'variant':10} {'n':>2} {'zh W CER':>8} {'zh SV CER':>9} {'W PERtl':>7} "
          f"{'SV PERtl':>8} {'en W WER':>8} {'probes W':>9} {'either':>8} {'flags':>5} {'drift':>6}")
    for a in aggregates:
        print(f"{a['engine'][:18]:18} {a['voice'][:22]:22} {a['variant'][:10]:10} {a['n_samples']:>2} "
              f"{_pct(a['zh_whisper_cer_mean']):>8} {_pct(a['zh_sensevoice_cer_mean']):>9} "
              f"{_pct(a['zh_whisper_per_toneless_mean']):>7} {_pct(a['zh_sensevoice_per_toneless_mean']):>8} "
              f"{_pct(a['en_whisper_wer_mean']):>8} {a['probes_whisper']:>9} {a['probes_either_asr']:>8} "
              f"{a['n_flags']:>5} {('-' if a['drift_loo_min'] is None else format(a['drift_loo_min'], '.2f')):>6}")
    print("\n=== ASR speed (this run; excludes cached files) ===")
    for name, sp in meta["speed"].items():
        print(f"{name:10} files={sp['n_files']:3d} audio={sp['audio_s']:8.1f}s decode={sp['decode_s']:7.1f}s "
              f"RTF={sp['rtf']}  -> {sp['sec_per_audio_min']} s per audio minute")
    print(f"load times {meta['load_times_s']}  peak RSS {meta['peak_rss_mb']} MB  load avg start {meta['load_avg_start']}"
          f" end {meta['load_avg_end']}  wall {meta['wall_s']} s")
