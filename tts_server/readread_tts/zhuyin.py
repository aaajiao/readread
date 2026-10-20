"""Conversion between tone-numbered pinyin and misaki v1.1 Chinese phoneme symbols.

misaki's ZHFrontend spells a syllable as the ZH_MAP symbol of its initial (if any), the
symbol of its final, an optional "R" for erhua and the tone digit (5 = neutral tone):
银行 -> "阴2ㄏㄤ2", 一点儿 -> "ㄧ4ㄉ言R3". The override lexicon is written in pinyin, so
readings are converted here in both directions. Finals follow pypinyin's strict style
(you -> iou, wei -> uei, yu -> v), with misaki's ii / iii for the -i of zi/ci/si and
zhi/chi/shi/ri.
"""

from __future__ import annotations

import re
from functools import lru_cache

# One syllable: everything up to and including its tone digit.
SYLLABLE_RE = re.compile(r"[^1-5]*[1-5]")
PINYIN_RE = re.compile(r"[a-zü]+[1-5]")

_INITIALS = ("b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h",
             "zh", "ch", "sh", "r", "z", "c", "s", "j", "q", "x")
# Symbols ZH_MAP uses for punctuation, tones and erhua rather than initials or finals.
_NON_PHONE = set(";:,.!?/—…\"()“” 12345R")


@lru_cache(maxsize=1)
def _maps() -> tuple[dict[str, str], dict[str, str]]:
    """(pinyin part -> symbol, symbol -> pinyin part) from misaki's own table."""
    from misaki.zh_frontend import ZH_MAP

    forward = {k: v for k, v in ZH_MAP.items() if k not in _NON_PHONE}
    return forward, {v: k for k, v in forward.items()}


def split_syllables(phonemes: str) -> list[str] | None:
    """Split one word's symbols into syllables, or None if it holds anything else."""
    syllables = SYLLABLE_RE.findall(phonemes)
    return syllables if "".join(syllables) == phonemes else None


@lru_cache(maxsize=4096)
def encode(pinyin: str) -> str:
    """Tone-numbered pinyin ("hang2", "dianr3") -> misaki symbols ("ㄏㄤ2").

    Raises ValueError for anything that is not a Mandarin syllable.
    """
    from pypinyin.contrib.tone_convert import to_finals_tone3, to_initials

    py = pinyin.strip().lower().replace("u:", "ü")
    if not PINYIN_RE.fullmatch(py):
        raise ValueError(f"not a tone-numbered pinyin syllable: {pinyin!r}")
    tone = py[-1]
    base = py[:-1]
    erhua = base.endswith("r") and base != "er"
    if erhua:
        base = base[:-1]
    # pypinyin drops a neutral-tone digit, so the syllable is split with tone 1 standing in.
    initial = to_initials(base + "1", strict=True)
    final = to_finals_tone3(base + "1", strict=True)[:-1]
    if final == "i" and initial in ("z", "c", "s"):
        final = "ii"
    elif final == "i" and initial in ("zh", "ch", "sh", "r"):
        final = "iii"
    forward, _ = _maps()
    if (initial and initial not in _INITIALS) or final not in forward or final in _INITIALS:
        raise ValueError(f"not a Mandarin syllable: {pinyin!r}")
    symbols = (forward[initial] if initial else "") + forward[final] + ("R" if erhua else "") + tone
    # Reject spellings pypinyin silently reinterprets (e.g. "hx2") by decoding them again.
    if decode(symbols) != (base + ("r" if erhua else "") + tone).replace("ü", "v"):
        raise ValueError(f"not a Mandarin syllable: {pinyin!r}")
    return symbols


def decode(symbols: str) -> str:
    """misaki symbols of one syllable ("ㄏㄤ2") -> tone-numbered pinyin ("hang2")."""
    _, inverse = _maps()
    initial, final, erhua, tone = "", "", False, ""
    for ch in symbols:
        if ch in "12345":
            tone = ch
        elif ch == "R":
            erhua = True
        elif ch in inverse:
            part = inverse[ch]
            if part in _INITIALS and not initial and not final:
                initial = part
            else:
                final = part
    if not tone:
        raise ValueError(f"no tone digit in {symbols!r}")
    return _spell(initial, final) + ("r" if erhua else "") + tone


def _spell(initial: str, final: str) -> str:
    """Initial + strict-style final -> the usual pinyin spelling (ü written as v)."""
    if final in ("ii", "iii"):
        final = "i"
    if not initial:
        return {
            "i": "yi", "in": "yin", "ing": "ying", "ia": "ya", "ian": "yan", "iang": "yang",
            "iao": "yao", "ie": "ye", "iong": "yong", "iou": "you", "u": "wu", "ua": "wa",
            "uai": "wai", "uan": "wan", "uang": "wang", "uei": "wei", "uen": "wen",
            "ueng": "weng", "uo": "wo", "v": "yu", "ve": "yue", "van": "yuan", "vn": "yun",
        }.get(final, final)
    if initial in ("j", "q", "x"):
        final = {"v": "u", "ve": "ue", "van": "uan", "vn": "un"}.get(final, final)
    final = {"iou": "iu", "uei": "ui", "uen": "un"}.get(final, final)
    return initial + final
