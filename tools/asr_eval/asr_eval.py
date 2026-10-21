#!/usr/bin/env python3
"""Entry point of the ASR round-trip evaluation; run it through asr_eval.sh, which gives it its venv, an isolated
interpreter (-I -B) and an offline environment whose caches all live in READREAD_ASR_HOME."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I leaves the script's directory off sys.path

from readread_asr.cli import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
