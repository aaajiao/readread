"""Text clean-up and sentence splitting, shared by both languages.

clean() drops what should never be read aloud (emoji and other pictographs, footnote markers, table rules
and bullets); split() cuts the cleaned text into the sentences that are synthesized one model call each;
is_speakable() tells whether a sentence has anything to say at all.

Chinese text often uses half-width punctuation (好的,我们走.). For "zh", split() writes an ASCII , ; : ! ?
that touches a Han character in its full-width form, and a sentence-final "." as 。, so the sentence is
split and misaki gives the clause marks the space kokoro's chunker and prosody rely on.
"""

from __future__ import annotations

import re
import unicodedata

# Symbols (So, Sk) that carry a reading; every other So/Sk character (emoji, dingbats, ...) is dropped.
# A '^' that is left is a power (see _CARET_RE).
_KEEP = frozenset("°℃℉^")
_DROP_CATEGORIES = frozenset({"So", "Sk", "Cf", "Co", "Cs", "Cn", "Me"})
# CJK compatibility squares (㎡ ㎞ ㎏ ㏄ ㋀ ...) are So too; they are read as their NFKC form (km, kg, cc,
# 1月), with the powers of area and volume units as superscripts so the unit rules see m², not m2.
_SQUARES = ((0x32C0, 0x32CB), (0x3358, 0x33FF))
_SQUARE_UNITS = {"㎟": "mm²", "㎠": "cm²", "㎡": "m²", "㎢": "km²", "㎣": "mm³", "㎤": "cm³", "㎥": "m³",
                 "㎦": "km³", "㎨": "m/s²", "㍷": "dm²", "㍸": "dm³"}
# '^' stays as a power between a base and a number (2^10, mc^2, x^-1); anywhere else it is a space.
# The '^' of a footnote marker ([^1]) is left for _FOOTNOTE_RE.
_CARET_RE = re.compile(r"(?<![A-Za-z0-9)）\[])\^|(?<!\[)\^(?![-+−]?\d)")
_ARROWS = ((0x2190, 0x21FF), (0x27F0, 0x27FF), (0x2900, 0x297F), (0x2B00, 0x2BFF))
_NEWLINES = frozenset("\n\r\x0b\x0c\x85\u2028\u2029")

_FOOTNOTE_RE = re.compile(r"\[\^?\d{1,3}\]|\[citation needed\]", re.IGNORECASE)
# Markdown leftovers: rules (---, ***, ===), table bars, bullets, emphasis marks.
_DECORATION_RE = re.compile(r"[-=_*~#]{3,}|[|•*_]")
_SPACES_RE = re.compile(r"[^\S\n]+")
_BLANK_LINES_RE = re.compile(r"\n{2,}")

_CLOSERS = "\"'”’」』）)]】》>"
_ZH_END = "。！？!?；;"
_ZH_SPLIT_RE = re.compile(f"[{re.escape(_ZH_END)}]+[{re.escape(_CLOSERS)}]*")
_CJK = "㐀-䶿一-鿿豈-﫿"
_CJK_RE = re.compile(f"[{_CJK}]")
_FULL_WIDTH = str.maketrans(",;:!?", "，；：！？")
# Half-width marks with a Han character on either side; the spaces around them go with them.
_ZH_ASCII_MARKS_RE = re.compile(f"(?<=[{_CJK}])[ \t]*[,;:!?]+[ \t]*|[ \t]*[,;:!?]+[ \t]*(?=[{_CJK}])")
_ZH_PERIOD_RE = re.compile(r"(?<![.])\.(?![.])")
# English candidates: a run of sentence marks, optional closing quotes/brackets, then whitespace or the end.
# CJK sentence marks always end a sentence, even without a following space.
_EN_SPLIT_RE = re.compile(r"[.!?]+[\"'”’)\]]*(?=\s|$)|[。！？；]+[”’」』）]*")
_WORD_BEFORE_RE = re.compile(r"([A-Za-z][A-Za-z.]*)\.$")
_WORD_REACH = 64  # how far back the word before a "." is looked for (a search from 0 is quadratic)

# Abbreviations that are never the end of a sentence (they precede a name or a phrase) ...
_NEVER_FINAL = frozenset({
    "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "mt", "gen", "gov", "sen", "rep", "capt", "lt",
    "col", "sgt", "rev", "hon", "e.g", "i.e", "cf", "vs", "viz",
})
# Words that start sentences and are never names: "Main St. Then ..." ends a sentence at Street, while
# "St. Louis" is Saint (frontend_en reads St. the same way).
SENTENCE_STARTERS = frozenset({
    "The", "A", "An", "This", "That", "These", "Those", "There", "Then", "It", "He", "She", "We", "They", "I",
    "You", "My", "Our", "Your", "His", "Her", "Its", "Their", "But", "And", "So", "If", "When", "After",
    "Before", "In", "On", "At", "From", "To", "For", "With", "As",
})
_FIRST_WORD_RE = re.compile(r"[A-Za-z]+")
# ... and ones that only precede a number ("No. 5", "Fig. 3").
_BEFORE_NUMBER = frozenset({"no", "nos", "fig", "figs", "vol", "pp", "p", "art", "sec", "ch", "eq"})


def _keep_char(ch: str) -> str:
    """The character itself, '' to drop it, a space/newline to stand in for it, or what a square reads as."""
    if ch in _NEWLINES:
        return "\n"
    if ch == "\t":
        return " "
    code = ord(ch)
    if any(lo <= code <= hi for lo, hi in _ARROWS):
        return " "
    if any(lo <= code <= hi for lo, hi in _SQUARES):
        return _SQUARE_UNITS.get(ch) or unicodedata.normalize("NFKC", ch).replace("∕", "/")
    if 0xFE00 <= code <= 0xFE0F or 0xE0100 <= code <= 0xE01EF:  # variation selectors
        return ""
    category = unicodedata.category(ch)
    if category == "Cc" or (category in _DROP_CATEGORIES and ch not in _KEEP):
        return ""
    return ch


def clean(text: str) -> str:
    """Remove unspeakable decoration; keeps line breaks, collapses other whitespace."""
    text = _CARET_RE.sub(" ", text.replace("\r\n", "\n"))
    text = "".join(_keep_char(ch) for ch in text)
    text = _FOOTNOTE_RE.sub("", text)
    text = _DECORATION_RE.sub(" ", text)
    text = _SPACES_RE.sub(" ", text)
    text = "\n".join(line.strip() for line in text.split("\n"))
    return _BLANK_LINES_RE.sub("\n", text).strip()


def is_speakable(sentence: str) -> bool:
    """True if the sentence holds at least one letter, CJK character or digit."""
    return any(unicodedata.category(ch)[0] in "LN" for ch in sentence)


def split(text: str, lang: str) -> list[str]:
    """Split cleaned text into sentences. lang "zh" splits at 。！？!?；;, at a sentence-final "." (see
    _zh_marks) and at line breaks, and a line without Han characters the English way; "en" at sentence
    ends that are not decimals, versions, domains, abbreviations or ellipses, at CJK sentence marks and
    at line breaks."""
    out: list[str] = []
    for line in text.split("\n"):
        pieces = _split_zh(line) if lang == "zh" else _split_en(line)
        out += [p for p in (piece.strip() for piece in pieces) if p]
    return out


def _split_zh(line: str) -> list[str]:
    if not _CJK_RE.search(line):
        return _split_en(line)
    line = _zh_marks(line)
    pieces, start = [], 0
    for m in _ZH_SPLIT_RE.finditer(line):
        pieces.append(line[start:m.end()])
        start = m.end()
    pieces.append(line[start:])
    return pieces


def _zh_marks(line: str) -> str:
    """Half-width punctuation in a Chinese line written the full-width way (see the module docstring)."""
    line = _ZH_ASCII_MARKS_RE.sub(lambda m: m.group().strip(" \t").translate(_FULL_WIDTH), line)
    return _ZH_PERIOD_RE.sub(lambda m: "。" if _zh_full_stop(line, m.start()) else ".", line)


def _zh_full_stop(line: str, i: int) -> bool:
    """Whether the "." at line[i] ends a sentence: after a Han character or a closing mark, before a space,
    a Han character or the end; after a digit or a word, only before a Han character or the end, and
    never after an abbreviation or an initial (Dr., U.S., J.). Never inside 3.5, v2.4.1 or example.com."""
    before, after = line[i - 1:i], line[i + 1:i + 2]
    following = line[i + 1:].lstrip(" \t")[:1]
    if after.isalnum() and not _CJK_RE.match(after):
        return False
    if _CJK_RE.match(before) or before in _CLOSERS or before in "。！？；，：":
        return True
    if following and not _CJK_RE.match(following):
        return False
    if before.isdigit():  # 增长了3.我们; but "1.首先 2.其次" are list numbers
        start = len(line[:i].rstrip("0123456789"))
        return start > 0 and not line[start - 1].isspace()
    word = _WORD_BEFORE_RE.search(line, max(0, i - _WORD_REACH), i + 1)
    if word is None:
        return bool(before.strip())
    w = word.group(1)
    return not (w.lower() in _NEVER_FINAL or "." in w or (len(w) == 1 and w.isupper()))


def _split_en(line: str) -> list[str]:
    pieces, start = [], 0
    for m in _EN_SPLIT_RE.finditer(line):
        if _ends_sentence(line, m):
            pieces.append(line[start:m.end()])
            start = m.end()
    pieces.append(line[start:])
    return pieces


def _ends_sentence(line: str, m: re.Match[str]) -> bool:
    marks = m.group().rstrip(_CLOSERS)
    if not marks or marks[0] not in ".!?":
        return True  # CJK sentence mark
    if ".." in marks:
        return False  # ellipsis
    rest = line[m.end():].lstrip()
    if rest[:1].islower():
        return False  # "the U.S. economy", "wait... what", "a.m. and"
    if marks != ".":
        return True
    word = _WORD_BEFORE_RE.search(line, max(0, m.start() - _WORD_REACH), m.start() + 1)
    if word is None:
        return True
    w = word.group(1).lower()
    if w in _NEVER_FINAL:
        return False
    if w == "st":
        following = _FIRST_WORD_RE.match(rest)
        return following is not None and following.group() in SENTENCE_STARTERS
    if w in _BEFORE_NUMBER and rest[:1].isdigit():
        return False
    # A single capital letter is an initial ("J. K. Rowling"), not the end of a sentence.
    return not (len(word.group(1)) == 1 and word.group(1).isupper())
