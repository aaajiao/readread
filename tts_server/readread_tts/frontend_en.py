"""English front end: normalization for misaki, then misaki.en.G2P (spaCy tagger + lexicon, espeak-ng for
words it does not know). The accent is a property of the voice: b* voices get british=True.

normalize() only rewrites what misaki reads wrongly or not at all; it leaves numbers, currency
($ € £), percentages, years and decades to misaki, which handles them.
"""

from __future__ import annotations

import re

from . import espeak
from .g2p import Builder, Phonemes
from .sentences import SENTENCE_STARTERS

SPACY_MODEL = "en_core_web_sm"
TERMINAL = ".!?…:;,。！？；：，、\"”’)）」』]"

_MONTHS = ("January", "February", "March", "April", "May", "June", "July", "August", "September",
           "October", "November", "December")
_MONTH_NAMES = {m: m for m in _MONTHS} | {
    "Jan": "January", "Feb": "February", "Mar": "March", "Apr": "April", "Jun": "June", "Jul": "July",
    "Aug": "August", "Sep": "September", "Sept": "September", "Oct": "October", "Nov": "November",
    "Dec": "December"}
_MONTH_ALT = "|".join(sorted(_MONTH_NAMES, key=len, reverse=True))
_FULL_MONTH_ALT = "|".join(_MONTHS)

_ABBREVIATIONS = [(re.compile(p), r) for p, r in [
    (r"\bDr\.(?=\s+[A-Z])", "Doctor"), (r"\bMr\.(?=\s+[A-Z])", "Mister"), (r"\bMrs\.(?=\s+[A-Z])", "Missus"),
    (r"\bMs\.(?=\s+[A-Z])", "Miz"), (r"\bProf\.(?=\s+[A-Z])", "Professor"),
    (r"\bMt\.(?=\s+[A-Z])", "Mount"),
    (r"\be\.g\.(?=[\s,;:]|$)", "for example"), (r"\bi\.e\.(?=[\s,;:]|$)", "that is"),
    (r"\betc\.(?=\s*[,;:])", "et cetera"), (r"\betc\.(?=\s+[a-z])", "et cetera"), (r"\betc\.$", "et cetera."),
    (r"\bvs\.(?=\s)", "versus"),
    (r"\bU\.S\.A\.(?=\s+[a-z])", "USA"), (r"\bU\.S\.(?=\s+[a-z])", "US"), (r"\bU\.K\.(?=\s+[a-z])", "UK"),
    (r"\bU\.S\.A\.", "USA."), (r"\bU\.S\.", "US."), (r"\bU\.K\.", "UK."),
    (r"\ba\.m\.", "A M"), (r"\bp\.m\.", "P M"),
]]
_ST_RE = re.compile(r"\bSt\.(?!\w)")
_PREVIOUS_WORD_RE = re.compile(r"([A-Za-z]+)\s+$")
_NON_SPACE_RE = re.compile(r"\S")
_STREET_AFTER_RE = re.compile(r"\s*$|\s*[,;:!?)]|\s+[a-z\d]|\s+(?:"
                              + "|".join(sorted(SENTENCE_STARTERS, key=len, reverse=True)) + r")\b")
_ELLIPSIS_RE = re.compile(r"\.{3,}")
_ISO_DATE_RE = re.compile(r"(?<![\d-])(\d{4})-(\d{2})-(\d{2})(?![\d-])")
_MONTH_DAY_RE = re.compile(rf"\b({_MONTH_ALT})\.?\s+(\d{{1,2}})(?:st|nd|rd|th)?\b(?!:\d|\.\d)")
_DAY_MONTH_RE = re.compile(rf"\b(?:([Tt]he)\s+)?(\d{{1,2}})(?:st|nd|rd|th)?\s+(?:of\s+)?({_FULL_MONTH_ALT})\b")
_TIME_RE = re.compile(r"(?<![\d:])([01]?\d|2[0-3]):([0-5]\d)(?![\d:])(?=(\s?[AaPp]\.?\s?[Mm]\b)?)")
_AMPM_RE = re.compile(r"(?<=\d)\s?([AaPp])[Mm]\b")
_PHONE_RE = re.compile(r"(?<![\d-])(?:\((\d{3})\)\s?|(\d{3})-)?(\d{3})-(\d{4})(?![\d-])")
_DIGIT_CHAIN_RE = re.compile(r"(?<![\w.-])\d+(?:-\d+){2,}(?![\w-])")
# num2words overflows past 307 digits, and nobody reads out a 16-digit number: digit by digit (with or
# without thousands separators).
_LONG_DIGITS_RE = re.compile(r"\d{1,3}(?:,\d{3}){5,}(?!\d)|\d{16,}")
_POWER_RE = re.compile(r"(?<=[A-Za-z0-9)])\^([-+−]?)(\d+(?:\.\d+)?)")
_VERSION_V_RE = re.compile(r"\bv(\d+(?:\.\d+)+)\b")
_VERSION_RE = re.compile(r"\b(\d+(?:\.\d+){2,})\b")
# example.com, www.example.com, Node.js: a dot between a word and a lower-case word is read "dot".
_DOT_RE = re.compile(r"(?<=[A-Za-z0-9])\.(?=[a-z][a-z0-9]+\b)")
_UNITS = {
    "km/h": ("kilometer per hour", "kilometers per hour"), "mph": ("mile per hour", "miles per hour"),
    "m/s": ("meter per second", "meters per second"), "km": ("kilometer", "kilometers"),
    "cm": ("centimeter", "centimeters"), "mm": ("millimeter", "millimeters"), "m": ("meter", "meters"),
    "kg": ("kilogram", "kilograms"), "mg": ("milligram", "milligrams"), "g": ("gram", "grams"),
    "lb": ("pound", "pounds"), "lbs": ("pound", "pounds"), "oz": ("ounce", "ounces"),
    "ml": ("milliliter", "milliliters"), "mL": ("milliliter", "milliliters"), "L": ("liter", "liters"),
    "KB": ("kilobyte", "kilobytes"), "kB": ("kilobyte", "kilobytes"), "MB": ("megabyte", "megabytes"),
    "GB": ("gigabyte", "gigabytes"), "TB": ("terabyte", "terabytes"), "ms": ("millisecond", "milliseconds"),
    "min": ("minute", "minutes"), "hr": ("hour", "hours"), "hrs": ("hour", "hours"),
    "kWh": ("kilowatt hour", "kilowatt hours"), "kW": ("kilowatt", "kilowatts"),
    "km²": ("square kilometer", "square kilometers"), "m²": ("square meter", "square meters"),
    "cm²": ("square centimeter", "square centimeters"), "mm²": ("square millimeter", "square millimeters"),
    "m³": ("cubic meter", "cubic meters"), "cm³": ("cubic centimeter", "cubic centimeters"),
    "mAh": ("milliamp hour", "milliamp hours"), "°C": ("degree Celsius", "degrees Celsius"),
    "℃": ("degree Celsius", "degrees Celsius"), "°F": ("degree Fahrenheit", "degrees Fahrenheit"),
    "℉": ("degree Fahrenheit", "degrees Fahrenheit"),
}
# Never starting after a comma or a dot: inside 1,1,1,... every start would rescan the rest (quadratic).
_UNIT_RE = re.compile(r"(?<![\w.,])(\d+(?:[.,]\d+)*)\s?("
                      + "|".join(re.escape(u) for u in sorted(_UNITS, key=len, reverse=True))
                      + r")(?![A-Za-z0-9])")
# 5-10, 5–10, 5 – 10; a hyphen with spaces around it is not a range (5 - 3), nor is ABC-123-456.
_RANGE_RE = re.compile(r"(?<![\w.,-])(\d+(?:\.\d+)?%?)(?:\s?[–—]\s?|-)(?=\d)")
_HASH_NUMBER_RE = re.compile(r"#(?=\d)")
_YEN_RE = re.compile(r"[¥￥]\s?(\d[\d,]*(?:\.\d+)?)")
_RUPEE_RE = re.compile(r"₹\s?(\d[\d,]*(?:\.\d+)?)")
_WON_RE = re.compile(r"₩\s?(\d[\d,]*(?:\.\d+)?)")
_RUBLE_RE = re.compile(r"₽\s?(\d[\d,]*(?:\.\d+)?)")
_FRACTION_RE = re.compile(r"(?<![\d/.])([1-9])/([2-9]|10)(?![\d/])")
_FRACTION_NAMES = {2: ("half", "halves"), 4: ("quarter", "quarters")}


def _words(n: int, ordinal: bool = False) -> str:
    from num2words import num2words

    return num2words(n, to="ordinal" if ordinal else "cardinal")


def _iso_date(m: re.Match[str]) -> str:
    year, month, day = m.group(1), int(m.group(2)), int(m.group(3))
    if not (1 <= month <= 12 and 1 <= day <= 31):
        return m.group(0)
    return f"{_MONTHS[month - 1]} {_words(day, True)}, {year}"


def _month_day(m: re.Match[str]) -> str:
    day = int(m.group(2))
    if not 1 <= day <= 31:
        return m.group(0)
    return f"{_MONTH_NAMES[m.group(1)]} {_words(day, True)}"


def _day_month(m: re.Match[str]) -> str:
    day = int(m.group(2))
    if not 1 <= day <= 31:
        return m.group(0)
    return f"{m.group(1) or 'the'} {_words(day, True)} of {m.group(3)}"


def _time(m: re.Match[str]) -> str:
    hour, minute = m.group(1), m.group(2)
    if minute == "00":
        return hour if m.group(3) else f"{hour} o'clock"
    if minute.startswith("0"):
        return f"{hour} oh {minute[1]}"
    return f"{hour} {minute}"


def _saint_or_street(m: re.Match[str]) -> str:
    """Street after a name inside the sentence (Wall St. Journal), or before the end, a mark, a lower-case
    word or a word that starts a sentence (Main St. Then ...); Saint before a name (St. Louis)."""
    after = m.string[m.end():m.end() + 64]
    word = _PREVIOUS_WORD_RE.search(m.string, max(0, m.start() - 64), m.start())
    if (word and word.group(1).istitle() and word.group(1) not in SENTENCE_STARTERS
            and word.start() > _NON_SPACE_RE.search(m.string).start()):  # not the first word
        return "Street"
    if _STREET_AFTER_RE.match(after):
        return "Street"
    return "Saint" if after[:1].isspace() and after.lstrip()[:1].isupper() else m.group()


def _phone(m: re.Match[str]) -> str:
    return ", ".join(" ".join(group) for group in m.groups() if group)


def _digit_chain(m: re.Match[str]) -> str:
    """1-800-555-1234 and other chains of three or more digit groups: digit by digit, a pause per group."""
    return ", ".join(" ".join(group) for group in m.group().split("-"))


def _version_v(m: re.Match[str]) -> str:
    number = " point ".join(m.group(1).split("."))
    return number if m.string[:m.start()].rstrip().lower().endswith("version") else "version " + number


def _power(m: re.Match[str]) -> str:
    sign, exponent = m.groups()
    if not sign and exponent in ("2", "3"):
        return " squared" if exponent == "2" else " cubed"
    return f" to the power of {'minus ' if sign in ('-', '−') else ''}{exponent}"


def _unit(m: re.Match[str]) -> str:
    singular, plural = _UNITS[m.group(2)]
    return f"{m.group(1)} {singular if m.group(1) == '1' else plural}"


def _fraction(m: re.Match[str]) -> str:
    num, den = int(m.group(1)), int(m.group(2))
    if num >= den:
        return m.group(0)
    one, many = _FRACTION_NAMES.get(den) or (_words(den, True), _words(den, True) + "s")
    return f"{_words(num)} {one if num == 1 else many}"


def ensure_terminal(text: str) -> str:
    s = text.rstrip()
    if s and s[-1] not in TERMINAL:
        s += "."
    return s


def normalize(text: str) -> str:
    text = _LONG_DIGITS_RE.sub(lambda m: " ".join(m.group().replace(",", "")), text.strip())
    text = _ELLIPSIS_RE.sub("…", text)
    text = _ST_RE.sub(_saint_or_street, text)
    for pattern, replacement in _ABBREVIATIONS:
        text = pattern.sub(replacement, text)
    text = _ISO_DATE_RE.sub(_iso_date, text)
    text = _MONTH_DAY_RE.sub(_month_day, text)
    text = _DAY_MONTH_RE.sub(_day_month, text)
    text = _TIME_RE.sub(_time, text)
    text = _AMPM_RE.sub(lambda m: f" {m.group(1).upper()} M", text)
    text = _PHONE_RE.sub(_phone, text)
    text = _DIGIT_CHAIN_RE.sub(_digit_chain, text)
    text = _VERSION_V_RE.sub(_version_v, text)
    text = _VERSION_RE.sub(lambda m: " point ".join(m.group(1).split(".")), text)
    text = _DOT_RE.sub(" dot ", text)
    text = _POWER_RE.sub(_power, text)
    text = _UNIT_RE.sub(_unit, text)
    text = _RANGE_RE.sub(r"\1 to ", text)
    text = _HASH_NUMBER_RE.sub("number ", text)
    text = _YEN_RE.sub(r"\1 yen", text)
    text = _RUPEE_RE.sub(r"\1 rupees", text)
    text = _WON_RE.sub(r"\1 won", text)
    text = _RUBLE_RE.sub(r"\1 rubles", text)
    text = _FRACTION_RE.sub(_fraction, text)
    return ensure_terminal(text)


def require_spacy_model() -> None:
    """misaki.en.G2P downloads the spaCy model when it is missing; refuse instead (the server is offline)."""
    import spacy.cli
    import spacy.util

    def refuse(*_args, **_kwargs):
        raise RuntimeError(f"refusing to download the spaCy model {SPACY_MODEL}")

    spacy.cli.download = refuse
    if not spacy.util.is_package(SPACY_MODEL):
        raise RuntimeError(f"the spaCy model {SPACY_MODEL} is not installed (it is part of "
                           "tts_server/requirements.lock; run ./scripts/setup.sh)")


class EnglishG2P:
    """misaki.en.G2P(trf=False) with misaki's espeak-ng fallback; unknown symbols are dropped (unk="")."""

    def __init__(self, british: bool) -> None:
        from misaki import en

        require_spacy_model()
        self.british = british
        self._g2p = en.G2P(trf=False, british=british, fallback=espeak.fallback(british), unk="")

    def tokens(self, text: str) -> list[tuple[str, str, bool]]:
        """(surface text, phonemes, followed by a space) per misaki token."""
        if not text.strip():
            return []
        _, tokens = self._g2p(text)
        return [(t.text, t.phonemes or "", bool(t.whitespace)) for t in tokens]

    def __call__(self, text: str) -> str:
        """Phoneme string, joined the way kokoro's KPipeline joins tokens (misaki's en_callable)."""
        return "".join(p + (" " if space else "") for _, p, space in self.tokens(text)).strip()

    def phonemize(self, text: str) -> Phonemes:
        b = Builder()
        for word, phonemes, space in self.tokens(text):
            b.token(word, phonemes)
            if space:
                b.sep(" ")
        return b.build()
