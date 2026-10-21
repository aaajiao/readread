"""The committed baseline (tools/asr_eval/baseline.json) and the --check comparison.

The baseline keeps, per sample (voice/text_id), what a later run must stay close to: each ASR's error count and the
reference size N (Chinese: CER units, English: WER words), the probes each ASR heard, the voice drift (the minimum
leave-one-out cosine), the audio duration and the sample's flags. The tolerances live in the file, so loosening one
is a reviewed change; --write-baseline keeps the tolerances of the file it replaces.

  errors     at most max(min_units, floor(fraction * N)) more errors per ASR: zh 1.5 % of the CER units, en 2 % of
             the words, and at least one error either way (zh_hant has 36 units: 1.5 % of it is less than one)
  probes     at most `probes_fewer` (1) fewer probe hits per ASR
  drift      loo_min drops by at most `drift_drop` (0.10) and stays >= `drift_floor` (0.50), unless the baseline
             itself was below the floor
  duration   audio seconds within `audio_ratio` (10 %) of the baseline
  flags      no flag of a `serious_flags` kind that the baseline sample did not have
  reference  the same N and scoring version (otherwise the corpus or the scoring changed: write a new baseline)

A baseline sample of a voice the run includes must be in the run, transcribed without errors. Voices the run does
not include are skipped and reported; samples the baseline does not have are listed as new, not compared (with a
warning: write the baseline for their voices).

--write-baseline replaces the samples of the run's voices. A voice the run left out (--voices <subset>) keeps its
samples from the file it replaces, which must have the same format and scoring version (otherwise it refuses: run
every voice); `kept_voices` names each kept voice with the date of the run its samples came from.
"""
from __future__ import annotations

import json
import os
import time

FORMAT = 1
ASRS = ("whisper", "sensevoice")
SERIOUS_FLAGS = ["missing_file", "decode_error", "unknown_text_id", "lang_mismatch", "format", "long_silence",
                 "len_ratio_low", "len_ratio_high", "repetition", "sentence_count", "sentence_dir_missing",
                 "concat_mismatch", "sentence_rate", "voice_drift", "digital_silence", "nan_output"]
DEFAULT_TOLERANCES = {
    "errors": {"zh": {"fraction": 0.015, "min_units": 1}, "en": {"fraction": 0.02, "min_units": 1}},
    "probes_fewer": 1,
    "drift_drop": 0.10,
    "drift_floor": 0.50,
    "audio_ratio": 0.10,
    "serious_flags": SERIOUS_FLAGS,
}
ABOUT = ("ASR round-trip baseline of the ReadRead TTS voices (tools/asr_eval). Written by asr_eval.sh --write-baseline; "
         "asr_eval.sh --check compares a run with it. Tolerances: see tools/asr_eval/README.md.")


def flag_kind(flag: str) -> str:
    return flag.split("(", 1)[0]


def sample_key(rec: dict) -> str:
    return f"{rec['voice']}/{rec['text_id']}"


def summarize(rec: dict) -> dict:
    """What the baseline keeps of one results.json sample."""
    out = {"lang": rec["lang"], "audio_s": (rec.get("audio") or {}).get("seconds"), "flags": list(rec["flags"])}
    for asr in ASRS:
        r = rec.get(asr)
        if r and r.get("error_rate") is not None:
            out[asr] = {"errors": r["S"] + r["D"] + r["I"], "n": r["N"], "error_rate": r["error_rate"],
                        "probes": r["probes"]["n_hit"], "probes_total": r["probes"]["n_total"],
                        "missed": r["probes"]["missed"]}
    if rec.get("probes_union"):
        out["probes_either"] = rec["probes_union"]["n_hit"]
    if rec.get("drift"):
        out["drift_loo_min"] = rec["drift"]["loo_min_cos"]
    return out


def build(results: dict, tolerances: dict | None = None) -> dict:
    meta = results["meta"]
    syn = meta.get("synthesis") or {}
    models = (meta.get("asr_models") or {}).get("models") or {}
    return {
        "format": FORMAT,
        "about": ABOUT,
        "created": time.strftime("%Y-%m-%d"),
        "scoring_version": meta["scoring_version"],
        "asr": {"models": {k: f"{v.get('repo')}@{v.get('revision')}" for k, v in models.items()},
                "versions": meta.get("versions"), "threads": meta.get("threads")},
        "synthesis": {"source": syn.get("source"), "engine": syn.get("engine"),
                      "server_code_sha256": syn.get("server_code_sha256"),
                      "server_versions": (syn.get("health") or {}).get("versions"),
                      "model_files": syn.get("model_files"), "voices": syn.get("voices"), "protocol": syn.get("protocol")},
        "tolerances": tolerances or DEFAULT_TOLERANCES,
        "samples": {sample_key(r): summarize(r) for r in sorted(results["samples"], key=sample_key)},
    }


class BaselineError(Exception):
    """The baseline cannot be written from this run."""


def voice_of(key: str) -> str:
    return key.split("/", 1)[0]


def write(results: dict, path: str) -> dict:
    """Writes the baseline at `path` from a run: the run's voices get its samples, the other voices of the file it
    replaces keep theirs (see the module doc). Raises BaselineError when those cannot be kept."""
    old = None
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            old = json.load(f)
    data = build(results, (old or {}).get("tolerances"))
    run_voices = {r["voice"] for r in results["samples"]}
    kept = {k: v for k, v in ((old or {}).get("samples") or {}).items() if voice_of(k) not in run_voices}
    if kept:
        kept_voices = sorted({voice_of(k) for k in kept})
        if old.get("format") != FORMAT or old.get("scoring_version") != data["scoring_version"]:
            raise BaselineError(
                f"{path} has samples of voices this run left out ({' '.join(kept_voices)}), written with another "
                f"format or scoring version, so they cannot be kept: run every voice to write the baseline")
        dates = old.get("kept_voices") or {}
        data["samples"] = dict(sorted({**kept, **data["samples"]}.items()))
        data["kept_voices"] = {v: dates.get(v, old.get("created")) for v in kept_voices}
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
        f.write("\n")
    os.replace(tmp, path)
    return data


def allowed_extra(tol: dict, lang: str, n: int) -> int:
    t = tol["errors"][lang]
    return max(int(t["min_units"]), int(t["fraction"] * n))


def compare(results: dict, base: dict) -> dict:
    """Checks a run's results against a baseline; returns {"ok", "rows", "skipped_voices", "notes"}."""
    tol = base["tolerances"]
    serious = set(tol["serious_flags"])
    run = {sample_key(r): r for r in results["samples"]}
    run_voices = {r["voice"] for r in results["samples"]}
    notes, rows = [], []
    if base.get("format") != FORMAT:
        notes.append(f"FAIL baseline format {base.get('format')!r}, this tool writes {FORMAT}")
    if base.get("scoring_version") != results["meta"]["scoring_version"]:
        notes.append("FAIL the baseline was scored with another scoring version: write a new baseline")
    skipped = sorted({voice_of(k) for k in base["samples"]} - run_voices)
    for key, b in sorted(base["samples"].items()):
        if voice_of(key) not in run_voices:
            continue
        r = run.get(key)
        row = {"sample": key, "base": b, "problems": []}
        rows.append(row)
        if r is None:
            row["problems"].append("missing from the run")
            continue
        now = summarize(r)
        row["now"] = now
        if r.get("errors"):
            row["problems"].append("errors: " + "; ".join(r["errors"]))
        for asr in ASRS:
            bb = b.get(asr)
            if not bb:
                continue
            nn = now.get(asr)
            if not nn:
                row["problems"].append(f"{asr}: no scored transcript")
                continue
            if nn["n"] != bb["n"]:
                row["problems"].append(f"{asr}: the reference has {nn['n']} units, the baseline's {bb['n']} "
                                       f"(corpus or scoring changed: write a new baseline)")
                continue
            extra = allowed_extra(tol, b["lang"], bb["n"])
            if nn["errors"] > bb["errors"] + extra:
                row["problems"].append(f"{asr}: {nn['errors']} errors ({100 * nn['error_rate']:.1f} %), baseline "
                                       f"{bb['errors']} ({100 * bb['error_rate']:.1f} %), allowed +{extra}")
            if nn["probes"] < bb["probes"] - tol["probes_fewer"]:
                lost = [p for p in nn["missed"] if p not in bb["missed"]]
                row["problems"].append(f"{asr}: probes {nn['probes']}/{nn['probes_total']}, baseline "
                                       f"{bb['probes']}/{bb['probes_total']}; newly missed: {' | '.join(lost)}")
        if "drift_loo_min" in b:
            d, bd = now.get("drift_loo_min"), b["drift_loo_min"]
            if d is None:
                row["problems"].append("drift: not measured")
            elif d < bd - tol["drift_drop"]:
                row["problems"].append(f"drift: loo_min {d:.2f}, baseline {bd:.2f}, allowed -{tol['drift_drop']:.2f}")
            elif d < tol["drift_floor"] <= bd:
                row["problems"].append(f"drift: loo_min {d:.2f} is below {tol['drift_floor']:.2f}")
        if b.get("audio_s") and now.get("audio_s"):
            ratio = now["audio_s"] / b["audio_s"]
            if abs(ratio - 1) > tol["audio_ratio"]:
                row["problems"].append(f"duration: {now['audio_s']:.1f} s, baseline {b['audio_s']:.1f} s "
                                       f"(x{ratio:.2f}, allowed +-{100 * tol['audio_ratio']:.0f} %)")
        new_kinds = {flag_kind(f) for f in now["flags"]} - {flag_kind(f) for f in b["flags"]}
        for f in now["flags"]:
            if flag_kind(f) in new_kinds & serious:
                row["problems"].append(f"new flag: {f}")
    new = sorted(set(run) - set(base["samples"]))
    compared = len(rows)
    if not compared:
        notes.append("FAIL nothing compared: the run has none of the baseline's voices")
    ok = not any(n.startswith("FAIL") for n in notes) and not any(row["problems"] for row in rows)
    return {"ok": ok, "rows": rows, "new_samples": new, "skipped_voices": skipped, "notes": notes,
            "n_compared": compared, "n_failed": sum(1 for row in rows if row["problems"])}


def _cell(x, key, fmt):
    v = (x or {}).get(key)
    return "-" if v is None else fmt(v)


def print_report(report: dict, path: str) -> None:
    print(f"\n=== check against {path} (errors/N per ASR; probes hit; drift = loo_min; audio s; now (baseline)) ===")
    hdr = (f"{'voice':10} {'text_id':8} {'W errors':>15} {'SV errors':>15} {'W probes':>11} {'SV probes':>11} "
           f"{'drift':>11} {'audio':>13}  result")
    print(hdr)
    print("-" * len(hdr))
    for row in report["rows"]:
        b, n = row["base"], row.get("now") or {}

        def pair(asr, key):
            nb, nn = b.get(asr) or {}, n.get(asr) or {}
            if not nb and not nn:
                return "-"
            if key == "errors":
                return f"{nn.get('errors', '-')}/{nn.get('n', '-')} ({nb.get('errors', '-')})"
            return f"{nn.get('probes', '-')}/{nn.get('probes_total', '-')} ({nb.get('probes', '-')})"
        voice, tid = row["sample"].split("/", 1)
        drift = f"{_cell(n, 'drift_loo_min', '{:.2f}'.format)} ({_cell(b, 'drift_loo_min', '{:.2f}'.format)})"
        audio = f"{_cell(n, 'audio_s', '{:.1f}'.format)} ({_cell(b, 'audio_s', '{:.1f}'.format)})"
        print(f"{voice:10} {tid:8} {pair('whisper', 'errors'):>15} {pair('sensevoice', 'errors'):>15} "
              f"{pair('whisper', 'probes'):>11} {pair('sensevoice', 'probes'):>11} {drift:>11} {audio:>13}  "
              f"{'FAIL' if row['problems'] else 'ok'}")
        for p in row["problems"]:
            print(f"{'':12}- {p}")
    for note in report["notes"]:
        print(note)
    if report["skipped_voices"]:
        print(f"not in this run (skipped): {' '.join(report['skipped_voices'])}")
    if report["new_samples"]:
        new_voices = sorted({voice_of(k) for k in report["new_samples"]})
        print(f"WARNING {len(report['new_samples'])} samples are not in the baseline, so nothing checks them: "
              f"{' '.join(report['new_samples'])}")
        print(f"WARNING write them with: tools/asr_eval/asr_eval.sh --voices \"{' '.join(new_voices)}\" --write-baseline")
    print(f"check: {'PASS' if report['ok'] else 'FAIL'} ({report['n_compared']} samples compared, "
          f"{report['n_failed']} outside the tolerances)")


# --------------------------------------------------------------------------------------------------------------
# self-check of the comparison (no models)
# --------------------------------------------------------------------------------------------------------------
def _fake_results(**changes) -> dict:
    def asr(errors, n, probes, total, missed=()):
        return {"S": errors, "D": 0, "I": 0, "N": n, "error_rate": round(errors / n, 4),
                "probes": {"n_hit": probes, "n_total": total, "missed": list(missed)}}
    zh = {"voice": "zf_001", "text_id": "zh_main", "lang": "zh", "flags": ["whisper_fallback(n=1,T=[0.0, 0.2])"],
          "errors": [], "audio": {"seconds": 50.0}, "whisper": asr(1, 203, 18, 19, ["chatgpt"]),
          "sensevoice": asr(5, 203, 16, 19, ["chatgpt", "api", "github"]), "probes_union": {"n_hit": 19},
          "drift": {"loo_min_cos": 0.80}}
    en = {"voice": "af_heart", "text_id": "en_main", "lang": "en", "flags": [], "errors": [],
          "audio": {"seconds": 30.0}, "whisper": asr(0, 66, 12, 12), "drift": {"loo_min_cos": 0.85}}
    for path, value in changes.items():
        rec, *keys = path.split("__")
        target = zh if rec == "zh" else en
        for k in keys[:-1]:
            target = target[k]
        target[keys[-1]] = value
    meta = {"scoring_version": "test", "versions": {}, "threads": 4}
    return {"meta": meta, "samples": [zh, en]}


def selfcheck() -> int:
    print("== baseline comparison (tolerances, flags, missing samples)")
    base = build(_fake_results())
    bad = 0
    cases = [
        ("identical run", _fake_results(), True),
        ("zh +3 Whisper errors on N=203 (allowed +3)", _fake_results(zh__whisper__S=4), True),
        ("zh +4 Whisper errors on N=203", _fake_results(zh__whisper__S=5), False),
        ("en +1 Whisper error on N=66 (allowed +1)", _fake_results(en__whisper__S=1), True),
        ("en +2 Whisper errors on N=66", _fake_results(en__whisper__S=2), False),
        ("1 probe fewer", _fake_results(zh__sensevoice__probes__n_hit=15), True),
        ("2 probes fewer", _fake_results(zh__sensevoice__probes__n_hit=14), False),
        ("drift 0.80 -> 0.71", _fake_results(zh__drift__loo_min_cos=0.71), True),
        ("drift 0.80 -> 0.69", _fake_results(zh__drift__loo_min_cos=0.69), False),
        ("audio +9 %", _fake_results(en__audio__seconds=32.7), True),
        ("audio +11 %", _fake_results(en__audio__seconds=33.3), False),
        ("new informational flag", _fake_results(en__flags=["whisper_hallucination('x'@1.0s)"]), True),
        ("new serious flag", _fake_results(en__flags=["long_silence(n=1,max=1.80s)"]), False),
        ("reference size changed", _fake_results(en__whisper__N=67), False),
        ("transcription error", _fake_results(zh__errors=["sensevoice failed: boom"]), False),
    ]
    for name, results, want in cases:
        got = compare(results, base)["ok"]
        ok = got == want
        bad += not ok
        print(f"  {'ok ' if ok else 'BAD'} {name}: {'pass' if got else 'fail'}" + ("" if ok else f" (want {want})"))
    only_en = _fake_results()
    only_en["samples"] = only_en["samples"][1:]
    rep = compare(only_en, base)
    ok = rep["ok"] and rep["skipped_voices"] == ["zf_001"] and rep["n_compared"] == 1
    bad += not ok
    print(f"  {'ok ' if ok else 'BAD'} a voice left out of the run is skipped: {rep['skipped_voices']}")
    missing = _fake_results()
    missing["samples"][0]["text_id"] = "zh_long"
    rep = compare(missing, base)
    ok = not rep["ok"] and rep["new_samples"] == ["zf_001/zh_long"]
    bad += not ok
    print(f"  {'ok ' if ok else 'BAD'} a baseline sample missing from the run fails; the extra one is new: "
          f"{rep['new_samples']}")
    other = _fake_results()
    other["meta"]["scoring_version"] = "other"
    ok = not compare(other, base)["ok"]
    bad += not ok
    print(f"  {'ok ' if ok else 'BAD'} another scoring version fails")
    bad += _selfcheck_write(only_en)
    return bad


def _selfcheck_write(only_en: dict) -> int:
    """--write-baseline of a subset of the voices keeps the others; a full run replaces every sample."""
    import tempfile

    bad = 0
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "baseline.json")
        write(_fake_results(), path)
        faster = json.loads(json.dumps(only_en))
        faster["samples"][0]["audio"]["seconds"] = 29.0
        data = write(faster, path)
        with open(path, encoding="utf-8") as f:
            on_disk = json.load(f)
        ok = (sorted(on_disk["samples"]) == ["af_heart/en_main", "zf_001/zh_main"]
              and on_disk["samples"]["af_heart/en_main"]["audio_s"] == 29.0
              and list(on_disk.get("kept_voices", {})) == ["zf_001"] and data == on_disk)
        bad += not ok
        print(f"  {'ok ' if ok else 'BAD'} writing one voice keeps the others: {sorted(on_disk['samples'])}, "
              f"kept {on_disk.get('kept_voices')}")
        ok = compare(_fake_results(), on_disk)["n_compared"] == 2
        bad += not ok
        print(f"  {'ok ' if ok else 'BAD'} a full check then compares every voice")
        write(_fake_results(), path)
        with open(path, encoding="utf-8") as f:
            ok = "kept_voices" not in json.load(f)
        bad += not ok
        print(f"  {'ok ' if ok else 'BAD'} a full run replaces every sample")
        other = json.loads(json.dumps(only_en))
        other["meta"]["scoring_version"] = "other"
        try:
            write(other, path)
            ok = False
        except BaselineError:
            ok = True
        with open(path, encoding="utf-8") as f:
            ok = ok and sorted(json.load(f)["samples"]) == ["af_heart/en_main", "zf_001/zh_main"]
        bad += not ok
        print(f"  {'ok ' if ok else 'BAD'} one voice with another scoring version is refused, the file unchanged")
    return bad
