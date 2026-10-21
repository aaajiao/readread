"""Normalization and scoring, ported verbatim from the October 2026 lab (keep/lab/eval_asr.py, scoring v2.1).

zh: CER over Z11 units (every CJK character, digit, '%' and '.' is one unit, every Latin word one unit), the
homophone-tolerant pinyin error rate (Z12) and the probes (Z13). en: WER over normalized tokens (E1-E13) and the
space-free en_cer. corpus.ZH_RULES and corpus.EN_RULES list the rules; H1 removes Whisper's end-of-audio
hallucinations before scoring. Reference, transcript and probe alternatives all go through the same normalization.
"""
from __future__ import annotations

import re
import unicodedata
from collections import Counter

from .corpus import PASSAGES, PROBES

SCORING_VERSION = ("v2.1 (v2: Z11/Z11b Latin-word units, Z12 pinyin error rate, Z13 homophone probes, E11 'dollars and M', "
                   "H1 Whisper hallucination removal, digital_silence + nan_output flags; v2.1: exact-zero runs within "
                   "0.1 s of a sentence edge -> edge_zero_run, not digital_silence; Z13 probes use the transcript's own "
                   "pinyin); ported unchanged from the October 2026 lab")

# --------------------------------------------------------------------------------------------------------------
# zh normalization
# --------------------------------------------------------------------------------------------------------------
_CN_DIGIT = {"零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
             "幺": 1}
_CN_SMALL = {"十": 10, "百": 100, "千": 1000}
_CN_BIG = {"万": 10 ** 4, "亿": 10 ** 8}
_DIGC = "零〇一二三四五六七八九两幺"
_RUN_RE = re.compile("[零〇一二三四五六七八九两幺十百千万亿]+")
_TIME_WORDS = ("上午", "下午", "早上", "早晨", "晚上", "中午", "凌晨", "傍晚", "夜里", "今天", "明天", "昨天")
_UNIT_NEXT = set("年月日号时点分秒个岁元块万亿%章节倍次")
_T2S = None


def _t2s(s: str) -> str:
    global _T2S
    if _T2S is None:
        from opencc import OpenCC
        _T2S = OpenCC("t2s")
    return _T2S.convert(s)


def cn_to_int(s: str):
    """Positional Chinese numeral -> int (None if malformed). Colloquial trailing digit after 百/千/万/亿 without a
    零 scales one unit down (一千五 = 1500, 两万五 = 25000)."""
    if not s:
        return None
    total = group = 0
    digit = None
    last_small, last_big = 10 ** 4, 10 ** 13
    prev = None                       # 'd' digit, 'z' zero, 'u' small unit, 'b' big unit
    last_unit_val = None
    unit_before_digit = None
    for c in s:
        if c in "零〇":
            if prev == "d":
                return None
            prev = "z"
            continue
        if c in _CN_DIGIT:
            if prev == "d":
                return None
            digit = _CN_DIGIT[c]
            unit_before_digit = last_unit_val if prev in ("u", "b") else None
            prev = "d"
            continue
        if c in _CN_SMALL:
            u = _CN_SMALL[c]
            if u >= last_small:
                return None
            if digit is None:
                if u == 10 and prev in (None, "b", "z"):
                    digit = 1
                else:
                    return None
            group += digit * u
            digit = None
            last_small = last_unit_val = u
            prev = "u"
            continue
        if c in _CN_BIG:
            b = _CN_BIG[c]
            if b >= last_big:
                return None
            if digit is not None:
                group += digit
                digit = None
            if group == 0:
                return None
            total += group * b
            group = 0
            last_small, last_big = 10 ** 4, b
            last_unit_val = b
            prev = "b"
            continue
        return None
    if digit is not None:
        if unit_before_digit is not None and unit_before_digit >= 100:
            group += digit * (unit_before_digit // 10)
        else:
            group += digit
    return total + group


def _cn_int_str(s: str):
    """Integer part: pure digit characters -> digit string (keeps leading zeros); else positional value."""
    if s and all(c in _DIGC for c in s):
        return "".join(str(_CN_DIGIT[c]) for c in s)
    v = cn_to_int(s)
    return None if v is None else str(v)


def _cn_number_str(s: str):
    """Chinese numeral with optional 点 decimal -> Arabic string."""
    if "点" in s:
        a, b = s.split("点", 1)
        ia = _cn_int_str(a)
        if ia is None or not b or not all(c in _DIGC for c in b):
            return None
        return f"{int(ia)}.{''.join(str(_CN_DIGIT[c]) for c in b)}"
    return _cn_int_str(s)


def cn_run_to_arabic(run: str):
    if not any(c in _DIGC or c == "十" for c in run):
        return None
    if not any(c in "十百千万亿" for c in run):
        return "".join(str(_CN_DIGIT[c]) for c in run)
    v = cn_to_int(run)
    if v is None:
        return None
    if len(run) > 1 and run[-1] in _CN_BIG and v % _CN_BIG[run[-1]] == 0:
        return f"{v // _CN_BIG[run[-1]]}{run[-1]}"
    return str(v)


def _time_ctx(text: str, start: int) -> bool:
    return any(text[max(0, start - len(w)):start] == w for w in _TIME_WORDS)


_PCT_RE = re.compile(r"百分之([零〇一二三四五六七八九两十百千万亿]+(?:点[零〇一二三四五六七八九]+)?|\d+(?:\.\d+)?)")
_TIME_RE = re.compile(r"(?<![\d零〇一二三四五六七八九十两百千])(?P<h>[零〇一二三四五六七八九十两]{1,3}|\d{1,2})点"
                      r"(?:(?P<half>半)|(?P<m>[零〇一二三四五六七八九十]{1,3}|\d{1,2})(?P<f>分)?)?(?P<z>钟)?")
_DEC_RE = re.compile(r"(?<![零〇一二三四五六七八九两十百千])([零〇一二三四五六七八九两十百千]+)点([零〇一二三四五六七八九]+)")


def _sub_time(text: str) -> str:
    def rep(m):
        h, half, mm, f, z = m.group("h"), m.group("half"), m.group("m"), m.group("f"), m.group("z")
        arabic_hm = h.isdigit() and mm is not None and mm.isdigit() and len(mm) == 2
        is_time = bool(half or f or z or arabic_hm or (mm and "十" in mm) or _time_ctx(text, m.start()))
        if not is_time:
            return m.group(0)
        hv = int(h) if h.isdigit() else cn_to_int(h)
        if hv is None or hv > 24:
            return m.group(0)
        if half:
            mv = 30
        elif mm:
            mv = int(mm) if mm.isdigit() else cn_to_int(mm)
            if mv is None or mv >= 60:
                return m.group(0)
        else:
            mv = None
        return f"{hv}点{mv:02d}分" if mv is not None else f"{hv}点"
    return _TIME_RE.sub(rep, text)


def _sub_runs(text: str) -> str:
    out, pos = [], 0
    for m in _RUN_RE.finditer(text):
        s, e = m.span()
        run = m.group(0)
        prev = text[s - 1] if s > 0 else ""
        nxt = text[e] if e < len(text) else ""
        rep = None
        if len(run) == 1:
            if run in _DIGC or run == "十":
                ok = prev == "第" or nxt in _UNIT_NEXT
                if run == "十" and nxt == "分" and prev != "点":
                    ok = False                      # 十分 = 'very'
                if run == "一" and nxt == "点" and not _time_ctx(text, s):
                    ok = False                      # 一点儿 / 有一点 / 差一点
                if ok:
                    rep = cn_run_to_arabic(run)
        else:
            rep = cn_run_to_arabic(run)
        out.append(text[pos:s])
        out.append(rep if rep is not None else run)
        pos = e
    out.append(text[pos:])
    return "".join(out)


def _iso_date(m):
    y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
    if 1 <= mo <= 12 and 1 <= d <= 31:
        return f"{y}年{mo}月{d}日"
    return m.group(0)


def _pct_rep(m):
    v = m.group(1)
    num = v if v[0].isdigit() else _cn_number_str(v)
    return f"{num}%" if num is not None else m.group(0)


def _dec_rep(m):
    ip = _cn_int_str(m.group(1))
    if ip is None:
        return m.group(0)
    return f"{int(ip)}." + "".join(str(_CN_DIGIT[c]) for c in m.group(2))


def norm_zh(text: str, ref: bool = False, keep_space: bool = False) -> str:
    """keep_space=True: removed characters become spaces (Latin word boundaries survive, see zh_units)."""
    s = unicodedata.normalize("NFKC", text).lower()                                            # Z1 Z2
    s = _t2s(s)                                                                                # Z3
    if ref:   # reference only: an ASR writes 2026-11-05 when it hears the hyphens read out (负/杠), not for 年月日
        s = re.sub(r"(?<!\d)(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?!\d)", _iso_date, s)          # Z4
    s = re.sub(r"(?<!\d)(\d{1,2}):(\d{2})(?!\d)", lambda m: f"{int(m.group(1))}点{m.group(2)}分", s)
    s = _PCT_RE.sub(_pct_rep, s)                                                               # Z5
    s = _sub_time(s)                                                                           # Z6
    s = _DEC_RE.sub(_dec_rep, s)                                                               # Z7
    s = _sub_runs(s)                                                                           # Z8
    s = re.sub(r"(\d+月\d+)号", r"\1日", s)                                                     # Z9
    s = re.sub(r"月0(\d)日", r"月\1日", s)
    s = re.sub(r"(\d+(?:\.\d+)?)块钱?", r"\1元", s)
    s = re.sub(r"¥\s*(\d+(?:\.\d+)?)", r"\1元", s)
    s = re.sub(r"人民币(?=\d)", "", s)
    gap = " " if keep_space else ""
    s = re.sub(r"[^0-9a-z%.㐀-䶿一-鿿]", gap, s)                                # Z10
    s = re.sub(r"(?<!\d)\.|\.(?!\d)", gap, s)
    return s


def zh_units(text: str, ref: bool = False) -> list:
    """Z11 scoring units for zh (mixed error rate, as in Mandarin-English code-switching ASR): every CJK character,
    digit, '%' and '.' is one unit; every Latin word (maximal a-z run) is ONE unit, so an English word costs one
    error, not one per letter."""
    return re.findall(r"[a-z]+|[^\sa-z]", norm_zh(text, ref=ref, keep_space=True))


# --------------------------------------------------------------------------------------------------------------
# zh homophone-tolerant pinyin error rate (secondary metric)
# --------------------------------------------------------------------------------------------------------------
_HAN_RE = re.compile(r"[㐀-䶿一-鿿]")
# Curated citation readings where pypinyin 0.55 is wrong on these passages (the polyphones the probes test).
REF_PINYIN_OVERRIDES = {
    ("zh_main", 7, "地", 1): "de5",       # 慢慢地 (adverbial particle; pypinyin: di4)
    ("zh_long", 4, "长", 1): "chang2",    # 长时间 (pypinyin: zhang3)
    ("zh_long", 8, "长", 4): "chang2",    # “长城”的“长” (pypinyin: zhang3)
    ("zh_long", 9, "还", 2): "huan2",     # 还回去 (pypinyin: hai2)
    ("zh_long", 11, "得", 1): "dei3",     # 你得 (pypinyin: de2)
}
_REF_PY = {}


def pinyin_of_units(units: list) -> list:
    """Tone-numbered pinyin (pypinyin TONE3, neutral tone 5) for every Han unit, computed per run of Han units so
    phrase readings apply; digits / Latin words / % map to themselves."""
    from pypinyin import lazy_pinyin, Style
    out, i = list(units), 0
    while i < len(units):
        if _HAN_RE.fullmatch(units[i]):
            j = i
            while j < len(units) and _HAN_RE.fullmatch(units[j]):
                j += 1
            run = "".join(units[i:j])
            py = lazy_pinyin(run, style=Style.TONE3, neutral_tone_with_five=True)
            if len(py) != j - i:
                py = [lazy_pinyin(c, style=Style.TONE3, neutral_tone_with_five=True)[0] for c in run]
            out[i:j] = py
            i = j
        else:
            i += 1
    return out


def ref_pinyin(text_id: str) -> list:
    """Reference pinyin per reference unit (aligned 1:1 with ref_units), with REF_PINYIN_OVERRIDES applied."""
    if text_id not in _REF_PY:
        res = []
        for n, (t, _h) in enumerate(PASSAGES[text_id][1], 1):
            u = zh_units(t, ref=True)
            py = pinyin_of_units(u)
            seen = Counter()
            for k, c in enumerate(u):
                if _HAN_RE.fullmatch(c):
                    seen[c] += 1
                    o = REF_PINYIN_OVERRIDES.get((text_id, n, c, seen[c]))
                    if o:
                        py[k] = o
            res += py
        _REF_PY[text_id] = res
    return _REF_PY[text_id]


def _toneless(p: str) -> str:
    return p[:-1] if re.fullmatch(r"[a-z]+[1-5]", p) else p


def pinyin_error(text_id: str, ref: list, hyp: list) -> dict:
    """Z12 homophone-tolerant pinyin error rate: a hyp Han unit identical to its aligned reference unit takes the
    curated reference reading; any other hyp Han unit takes pypinyin's reading in the hyp's context; then
    Levenshtein over syllables. An ASR spelling a correctly spoken syllable with a homophone (第一张/第一章,
    他/她, 的/地, 再/在) costs nothing here, while a misreading the ASR spells with a different-sounding character
    (银行 -> 银刑) still counts. Lenient by design: an identical polyphonic character keeps the reference reading,
    so 税觉 / 重负 / 长成 cost nothing here although they suggest jue2 / zhong4 / zhang3 -- the probes (Z13 v2.1)
    judge those with the transcript's own reading.
    per = tone-numbered syllables; per_toneless = tones ignored (ASR transcripts are weak evidence for tones)."""
    from rapidfuzz.distance import Levenshtein
    rp = ref_pinyin(text_id)
    hp = pinyin_of_units(hyp)
    for op in Levenshtein.opcodes(ref, hyp):
        if op.tag == "equal":
            for k in range(op.src_end - op.src_start):
                hp[op.dest_start + k] = rp[op.src_start + k]
    n = len(rp)
    d = Levenshtein.distance(rp, hp)
    dt = Levenshtein.distance([_toneless(p) for p in rp], [_toneless(p) for p in hp])
    return {"per": round(d / n, 4) if n else None, "per_toneless": round(dt / n, 4) if n else None,
            "hyp_pinyin": hp}


def probe_pinyin(text_id: str, alt: str) -> list:
    """Z13: tone-numbered pinyin of a probe alternative, read from the curated reference pinyin where the
    alternative occurs in the reference (so overrides such as 还回去 huan2 apply), else from pypinyin."""
    u = zh_units(alt, ref=True)
    ref, _ = ref_units(text_id)
    rp = ref_pinyin(text_id)
    for i in range(len(ref) - len(u) + 1):
        if ref[i:i + len(u)] == u:
            return rp[i:i + len(u)]
    return pinyin_of_units(u)


# --------------------------------------------------------------------------------------------------------------
# Whisper end-of-audio hallucinations (H1)
# --------------------------------------------------------------------------------------------------------------
HALLUCINATION_PATTERNS = {
    "zh": [r"字幕志愿者\s*[㐀-䶿一-鿿·]{0,6}", r"(?:中文|本)?字幕(?:由|提供|制作|製作|翻译|校对)\S{0,30}",
           r"请不吝点赞\S*", r"(?:感谢|谢谢)(?:大家)?(?:观看|收看|收听)", r"明镜与点点栏目"],
    "en": [r"thanks? (?:you )?(?:so much )?for watching[.!]?", r"subtitles by \S+(?: \S+){0,4}",
           r"please subscribe\S*"],
}


def strip_hallucinations(res: dict, lang: str, speech_end_s=None):
    """H1: drop Whisper segments that consist only of a known subtitle-credit / 'thanks for watching' phrase
    (Whisper's classic output on trailing silence), or that start at or after the end of the audio's speech
    (trailing silence cannot contain words). Returns (text_to_score, removed_segments)."""
    segs = res.get("segments")
    if not segs:
        return res.get("text", ""), []
    keep, removed = [], []
    for s in segs:
        t = s["text"].strip()
        rest = t
        for p in HALLUCINATION_PATTERNS.get(lang, []):
            rest = re.sub(p, "", rest, flags=re.I)
        only_phrase = rest != t and not re.sub(r"[\W_]+", "", rest)
        after_speech = speech_end_s is not None and s["start"] >= speech_end_s - 0.1
        if t and (only_phrase or after_speech):
            removed.append({"text": t, "start": s["start"], "end": s["end"],
                            "why": "phrase" if only_phrase else "after_speech_end"})
        else:
            keep.append(t)
    joiner = "" if lang == "zh" else " "
    return joiner.join(keep).strip(), removed


# --------------------------------------------------------------------------------------------------------------
# en normalization
# --------------------------------------------------------------------------------------------------------------
_EN_TLD = "com|org|net|io|ai|edu|gov|co|cn|uk|de|app|dev|me|info"
_EN_PHRASES = [(" dr ", " doctor "), (" u s a ", " usa "), (" u s ", " us "), (" united states ", " us "),
               (" e g ", " eg "), (" for example ", " eg "), (" i e ", " ie "), (" et cetera ", " etc "),
               (" etcetera ", " etc "), (" per cent ", " percent ")]
_W_UNITS = "one|two|three|four|five|six|seven|eight|nine"
_W_TEENS = "ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen"
_W_TENS = "twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety"
_W_VAL = {w: i + 1 for i, w in enumerate(_W_UNITS.split("|"))}
_W_VAL.update({w: i + 10 for i, w in enumerate(_W_TEENS.split("|"))})
_W_VAL.update({w: (i + 2) * 10 for i, w in enumerate(_W_TENS.split("|"))})
_YEAR_RE = re.compile(rf"\b(eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty) "
                      rf"(?:(?P<t>{_W_TENS})(?: (?P<u>{_W_UNITS}))?|(?P<teen>{_W_TEENS})|oh (?P<oh>{_W_UNITS}))\b")
_DECADE_RE = re.compile(r"\b(seventeen|eighteen|nineteen|twenty) (twenties|thirties|forties|fifties|sixties|seventies|"
                        r"eighties|nineties)\b")
_DECADE = {"twenties": 20, "thirties": 30, "forties": 40, "fifties": 50, "sixties": 60, "seventies": 70,
           "eighties": 80, "nineties": 90}
_A2D = None


_SCALE_RE = re.compile(r"(hundreds?|thousands?|millions?|billions?|trillions?)")
_NUMWORDS = set(("zero " + _W_UNITS.replace("|", " ") + " " + _W_TEENS.replace("|", " ") + " " +
                 _W_TENS.replace("|", " ") + " hundred thousand million billion trillion a").split())


def _alpha2digit(s: str) -> str:
    global _A2D
    if _A2D is None:
        try:
            from text_to_num import alpha2digit
            _A2D = alpha2digit
        except Exception:                                   # text2num missing: rule E10 skipped
            _A2D = False
    if not _A2D:
        return s
    # a scale word not preceded by a number word/digit stays a word (multi billion, thousands of hours)
    toks = s.split()
    for i, t in enumerate(toks):
        if _SCALE_RE.fullmatch(t) and (i == 0 or (toks[i - 1] not in _NUMWORDS and not toks[i - 1][0].isdigit())):
            toks[i] = "qq" + t + "qq"
    s = " " + " ".join(toks) + " "
    import warnings
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        s = _A2D(s, "en", threshold=0)
    return re.sub(r"qq([a-z]+)qq", r"\1", s)


def _year_rep(m):
    cent = _W_VAL[m.group(1)]
    if m.group("t"):
        yy = _W_VAL[m.group("t")] + (_W_VAL[m.group("u")] if m.group("u") else 0)
    elif m.group("teen"):
        yy = _W_VAL[m.group("teen")]
    else:
        yy = _W_VAL[m.group("oh")]
    return f"{cent * 100 + yy}"


def norm_en_tokens(text: str) -> list:
    s = unicodedata.normalize("NFKC", text).lower()                                            # E1
    s = s.replace("’", "'").replace("‘", "'").replace("“", '"').replace("”", '"')
    s = re.sub(rf"\b([a-z0-9][a-z0-9-]*)\.({_EN_TLD})\b", r"\1 dot \2", s)                      # E2
    s = re.sub(r"\$\s?(\d+(?:,\d{3})*(?:\.\d+)?)", r"\1 dollars", s)                           # E3
    s = re.sub(r"€\s?(\d+(?:,\d{3})*(?:\.\d+)?)", r"\1 euros", s)
    s = re.sub(r"£\s?(\d+(?:,\d{3})*(?:\.\d+)?)", r"\1 pounds", s)
    s = s.replace("%", " percent ")                                                            # E4
    while True:                                                                                # E5
        s2 = re.sub(r"(?<=\d),(?=\d{3}(?!\d))", "", s)
        if s2 == s:
            break
        s = s2
    s = re.sub(r"[-‐‑‒–—―/]", " ", s).replace("&", " and ").replace("'", "")  # E6
    s = re.sub(r"(?<!\d)\.|\.(?!\d)", "", s)                                                   # E7
    s = re.sub(r"[^\w\s.]|_", " ", s)
    s = " " + " ".join(s.split()) + " "
    for _ in range(2):                                                                         # E8
        for a, b in _EN_PHRASES:
            s = s.replace(a, b)
    s = _DECADE_RE.sub(lambda m: f"{_W_VAL[m.group(1)]}{_DECADE[m.group(2)]}s", s)              # E9
    s = _YEAR_RE.sub(_year_rep, s)
    s = _alpha2digit(s)                                                                        # E10
    while True:                                                                                # E11
        s2 = re.sub(r"(?<!\S)(\d+(?:\.\d+)*) point (\d+)(?!\S)", r"\1.\2", s)
        if s2 == s:
            break
        s = s2
    s = re.sub(r"\b(\d+)(?:st|nd|rd|th)\b", r"\1", s)
    s = re.sub(r"(?<!\S)(\d+) dollars? and (\d{1,2})(?: cents?)?(?!\S)",          # v2: 'and 50' w/o cents
               lambda m: f"{m.group(1)}.{int(m.group(2)):02d} dollars", s)
    s = re.sub(r"(?<!\S)(\d+) dollars? (\d{2})(?!\S)", r"\1.\2 dollars", s)
    s = re.sub(r"(?<!\S)dollar(?!\S)", "dollars", s)
    return s.split()                                                                           # E12


# --------------------------------------------------------------------------------------------------------------
# scoring
# --------------------------------------------------------------------------------------------------------------
def ref_units(text_id: str):
    """Normalized reference units (chars for zh, tokens for en) + sentence index (1-based) per unit."""
    lang, sents = PASSAGES[text_id]
    units, sidx = [], []
    for n, (t, _h) in enumerate(sents, 1):
        u = zh_units(t, ref=True) if lang == "zh" else norm_en_tokens(t)
        units += u
        sidx += [n] * len(u)
    return units, sidx


def hyp_units(text: str, lang: str):
    return zh_units(text) if lang == "zh" else norm_en_tokens(text)


def compound_fix(ref: list, hyp: list) -> list:
    """E13: reference-aware spacing repair for English tokens (multibillion <-> multi billion)."""
    vocab = set(ref)
    joined = {ref[i] + ref[i + 1]: (ref[i], ref[i + 1]) for i in range(len(ref) - 1)}
    out = []
    for t in hyp:
        if t not in vocab and t in joined:
            out += list(joined[t])
        else:
            out.append(t)
    res, i = [], 0
    while i < len(out):
        if i + 1 < len(out) and out[i] + out[i + 1] in vocab and (out[i] not in vocab or out[i + 1] not in vocab):
            res.append(out[i] + out[i + 1])
            i += 2
        else:
            res.append(out[i])
            i += 1
    return res


def zh_latin_resegment(ref: list, hyp: list) -> list:
    """Z11b: a run of consecutive Latin-word units in a zh transcript is re-split along the reference's Latin
    words when its letters, joined, can be segmented entirely into reference Latin words ('chat gptapi' ->
    chatgpt api, 'listdictionary' -> list dictionary). Spelling must already match; only word spacing changes."""
    vocab = {u for u in ref if re.fullmatch(r"[a-z]+", u)}
    if not vocab:
        return hyp

    def seg(s):
        best = {0: []}
        for i in range(1, len(s) + 1):
            for j in range(max(0, i - 24), i):
                if j in best and s[j:i] in vocab:
                    best[i] = best[j] + [s[j:i]]
                    break
        return best.get(len(s))
    out, i = [], 0
    while i < len(hyp):
        if re.fullmatch(r"[a-z]+", hyp[i]):
            j = i
            while j < len(hyp) and re.fullmatch(r"[a-z]+", hyp[j]):
                j += 1
            run = hyp[i:j]
            sg = seg("".join(run))
            out += sg if sg else run
            i = j
        else:
            out.append(hyp[i])
            i += 1
    return out


def align(ref, hyp, sidx, lang, n_sent):
    from rapidfuzz.distance import Levenshtein
    S = D = I = 0
    per = {n: {"n": n, "ref_units": 0, "S": 0, "D": 0, "I": 0} for n in range(1, n_sent + 1)}
    for n in sidx:
        per[n]["ref_units"] += 1
    edits, cur = [], None
    joiner = "" if lang == "zh" else " "
    ops = Levenshtein.opcodes(ref, hyp)
    for op in ops:
        tag, i1, i2, j1, j2 = op.tag, op.src_start, op.src_end, op.dest_start, op.dest_end
        if tag == "equal":
            if cur:
                edits.append(cur)
                cur = None
            continue
        nr, nh = i2 - i1, j2 - j1
        s_ = min(nr, nh)
        d_ = max(0, nr - nh)
        i_ = max(0, nh - nr)
        S += s_
        D += d_
        I += i_
        if nr:
            for k in range(i1, i2):
                kk = k - i1
                per[sidx[k]]["S" if kk < s_ else "D"] += 1
            if i_:
                per[sidx[i2 - 1]]["I"] += i_
        else:
            anchor = sidx[i1 - 1] if i1 > 0 else (sidx[0] if sidx else 1)
            per[anchor]["I"] += i_
        sent = sidx[i1] if i1 < len(sidx) else (sidx[-1] if sidx else 1)
        if cur is None:
            cur = {"sentence": sent, "ref": [], "hyp": []}
        cur["ref"] += ref[i1:i2]
        cur["hyp"] += hyp[j1:j2]
    if cur:
        edits.append(cur)
    for e in edits:
        e["ref"] = joiner.join(e["ref"])
        e["hyp"] = joiner.join(e["hyp"])
    N = len(ref)
    for p in per.values():
        p["err"] = p["S"] + p["D"] + p["I"]
        p["rate"] = round(p["err"] / p["ref_units"], 4) if p["ref_units"] else None
    return {"S": S, "D": D, "I": I, "N": N, "error_rate": round((S + D + I) / N, 4) if N else None,
            "per_sentence": list(per.values()), "edits": edits}


def _contains(seq: list, sub: list) -> bool:
    return bool(sub) and any(seq[i:i + len(sub)] == sub for i in range(len(seq) - len(sub) + 1))


def probe_check(text_id: str, hyp_text: str, lang: str, hyp_py=None):
    """zh: substring match on the space-free normalized transcript; with hyp_py (Z13) a probe also counts as hit
    when its tone-numbered pinyin occurs in the transcript's own pinyin (an exact homophone spelling, e.g. 长程 or
    自典 for 长城 / 字典, means the syllables were heard as intended; 长成 = zhang3 cheng2 is not one).
    'pinyin_only' lists such hits; n_hit_chars = v1 count."""
    hit, missed, py_only = [], [], []
    if lang == "zh":
        h = norm_zh(hyp_text)
        for alts in PROBES.get(text_id, []):
            ok = any(norm_zh(a) and norm_zh(a) in h for a in alts)
            if not ok and hyp_py is not None and text_id in PASSAGES and any(
                    _contains(hyp_py, probe_pinyin(text_id, a)) for a in alts):
                py_only.append("/".join(alts))
                ok = True
            (hit if ok else missed).append("/".join(alts))
        return {"n_hit": len(hit), "n_total": len(hit) + len(missed), "hit": hit, "missed": missed,
                "pinyin_only": py_only, "n_hit_chars": len(hit) - len(py_only)}
    else:
        h = " " + " ".join(norm_en_tokens(hyp_text)) + " "
        for alts in PROBES.get(text_id, []):
            ok = any(norm_en_tokens(a) and (" " + " ".join(norm_en_tokens(a)) + " ") in h for a in alts)
            (hit if ok else missed).append("/".join(alts))
    return {"n_hit": len(hit), "n_total": len(hit) + len(missed), "hit": hit, "missed": missed}


def max_extra_repeats(ref, hyp, n, joiner):
    def grams(u):
        return Counter(tuple(u[i:i + n]) for i in range(len(u) - n + 1))
    gr, gh = grams(ref), grams(hyp)
    best, which = 0, None
    for g, c in gh.items():
        extra = c - gr.get(g, 0)
        if extra > best:
            best, which = extra, g
    return best, ("" if which is None else joiner.join(which))


def score(text_id: str, lang: str, hyp_text: str) -> dict:
    from rapidfuzz.distance import Levenshtein
    ref, sidx = ref_units(text_id)
    hyp = compound_fix(ref, hyp_units(hyp_text, lang))      # E13 / Z11: spacing repair for Latin words
    if lang == "zh":
        hyp = zh_latin_resegment(ref, hyp)                    # Z11b
    n_sent = len(PASSAGES[text_id][1])
    a = align(ref, hyp, sidx, lang, n_sent)
    out = {"metric": "cer" if lang == "zh" else "wer", "normalized": ("" if lang == "zh" else " ").join(hyp)}
    out.update(a)
    out["len_ratio"] = round(len(hyp) / len(ref), 4) if ref else None
    rc, hc = "".join(ref), "".join(hyp)
    # en: space-free character error rate; zh: the per-character CER of the setup version (every Latin letter is
    # one unit), kept for comparison
    out["char_error_rate"] = round(Levenshtein.distance(rc, hc) / len(rc), 4) if rc else None
    hyp_py = None
    if lang == "zh":
        pe = pinyin_error(text_id, ref, hyp)
        pe.pop("hyp_pinyin")
        out.update(pe)
        # Z13 (v2.1): probes use the transcript's OWN reading (pypinyin in the transcript's context), not the
        # reference readings borrowed by identical characters: 重负 for 重複 is zhong4 fu4, 阴乐 for 音樂 yin1 le4,
        # 税觉 for 睡覺 shui4 jue2, 长成 for 长城 zhang3 cheng2 -- the ASR heard a different word, so the probe misses.
        hyp_py = pinyin_of_units(hyp)
    rep, gram = max_extra_repeats(ref, hyp, 4 if lang == "zh" else 3, "" if lang == "zh" else " ")
    out["max_extra_ngram_repeats"] = rep
    out["most_repeated_ngram"] = gram
    out["probes"] = probe_check(text_id, hyp_text, lang, hyp_py=hyp_py)
    return out
