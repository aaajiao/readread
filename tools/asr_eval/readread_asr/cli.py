"""Commands of asr_eval.py (asr_eval.sh runs them in the tool's own venv, isolated and offline):

  run        synthesize the corpus through the TTS server into --out, then evaluate it
  evaluate   score an existing run directory again (transcripts come from its asr_cache.json)
  selfcheck  the scoring's and the comparison's unit cases (no models, no server)

run and evaluate take --check <baseline.json> (exit 1 outside its tolerances) or --write-baseline <baseline.json>.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

# The lab's evaluation options that asr_eval keeps at the lab's values (eval_asr.py's defaults).
LAB_DEFAULTS = dict(only=None, no_cache=False, no_whisper=False, no_sensevoice=False, no_drift=False,
                    sensevoice_en=False, sv_language="zh", per_sentence_asr=False, dur_low=0.70, dur_high=1.40,
                    silence_s=1.5, len_low=0.85, len_high=1.15, drift_flag=0.50, zero_run_s=0.75)


def _parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="asr_eval.py", description=__doc__.split("\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="command", required=True)

    def asr_options(p):
        p.add_argument("--whisper-model", required=True, help="faster-whisper-large-v3-turbo directory")
        p.add_argument("--sensevoice-model", required=True, help="SenseVoice-Small int8 directory")
        p.add_argument("--speaker-model", dest="spk_model", required=True, help="CAM++ .onnx file")
        p.add_argument("--models-manifest", help="models.json of asr_eval.sh --setup (pins, for results.json)")
        p.add_argument("--threads", type=int, default=4, help="CPU threads for Whisper and SenseVoice")
        g = p.add_mutually_exclusive_group()
        g.add_argument("--check", metavar="BASELINE", help="compare with this baseline; exit 1 outside it")
        g.add_argument("--write-baseline", metavar="BASELINE", help="write this baseline from the run")

    run = sub.add_parser("run", help="synthesize the corpus, then evaluate it")
    run.add_argument("--source", required=True, choices=["dev", "app", "qwen"])
    run.add_argument("--tts-python", required=True, help="the python that runs tts_server.py")
    run.add_argument("--server-dir", required=True, help="the directory holding tts_server.py")
    run.add_argument("--tts-models", required=True, help="the server's --models-dir")
    run.add_argument("--tts-cache", required=True, help="the server's READREAD_CACHE_DIR")
    run.add_argument("--home", required=True, help="HOME (and TMPDIR parent) of the server")
    run.add_argument("--engine", choices=["kokoro", "qwen"], default="kokoro")
    run.add_argument("--voices", nargs="+", required=True)
    run.add_argument("--out", required=True, help="the run directory (must not hold a run yet)")
    asr_options(run)

    ev = sub.add_parser("evaluate", help="score a run directory again")
    ev.add_argument("--out", required=True, help="a run directory (manifest.jsonl)")
    asr_options(ev)

    sub.add_parser("selfcheck", help="unit cases of the scoring and the comparison")
    return ap


def _evaluate(args) -> dict:
    from .evaluate import evaluate

    ns = argparse.Namespace(**LAB_DEFAULTS)
    ns.samples_dir = ns.out_dir = os.path.abspath(args.out)
    for k in ("whisper_model", "sensevoice_model", "spk_model", "threads"):
        setattr(ns, k, getattr(args, k))
    extra = {}
    syn = os.path.join(ns.out_dir, "synthesis.json")
    if os.path.exists(syn):
        with open(syn, encoding="utf-8") as f:
            extra["synthesis"] = json.load(f)
    if args.models_manifest:
        with open(args.models_manifest, encoding="utf-8") as f:
            extra["asr_models"] = json.load(f)
    ns.extra_meta = extra
    return evaluate(ns)


def _compare(args, results) -> int:
    from . import baseline

    if args.write_baseline:
        try:
            data = baseline.write(results, args.write_baseline)
        except baseline.BaselineError as e:
            print(f"[asr_eval] not writing the baseline: {e}", file=sys.stderr)
            return 1
        kept = data.get("kept_voices") or {}
        also = (f" ({len(results['samples'])} from this run; kept from the previous file: "
                + ", ".join(f"{v} of {d}" for v, d in kept.items()) + ")") if kept else ""
        print(f"\n[asr_eval] wrote {args.write_baseline}: {len(data['samples'])} samples{also}; review the diff and "
              f"commit it")
        return 0
    if args.check:
        with open(args.check, encoding="utf-8") as f:
            base = json.load(f)
        report = baseline.compare(results, base)
        baseline.print_report(report, args.check)
        path = os.path.join(os.path.abspath(args.out), "comparison.json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(report, f, ensure_ascii=False, indent=1)
        print(f"[asr_eval] wrote {path}")
        return 0 if report["ok"] else 1
    return 0


def main(argv=None) -> int:
    args = _parser().parse_args(argv)
    if args.command == "selfcheck":
        from .selfcheck import selfcheck

        return selfcheck()
    if args.command == "run":
        from .synth import SynthesisError, synthesize_corpus

        if args.check:  # fail before the long part when the baseline cannot be read
            with open(args.check, encoding="utf-8") as f:
                json.load(f)
        try:
            synthesize_corpus(source=args.source, python=args.tts_python, server_dir=args.server_dir,
                              models_dir=args.tts_models, engine=args.engine, voices=args.voices,
                              out_dir=os.path.abspath(args.out), cache_dir=args.tts_cache, home=args.home)
        except SynthesisError as e:
            print(f"[asr_eval] synthesis failed: {e}", file=sys.stderr)
            return 1
    results = _evaluate(args)
    failed = [f"{r['voice']}/{r['text_id']}: {'; '.join(r['errors'])}" for r in results["samples"] if r["errors"]]
    for line in failed:
        print(f"[asr_eval] ERROR {line}", file=sys.stderr)
    if failed and args.write_baseline:
        print(f"[asr_eval] not writing {args.write_baseline}: {len(failed)} samples failed", file=sys.stderr)
        return 1
    status = _compare(args, results)
    return 1 if failed else status
