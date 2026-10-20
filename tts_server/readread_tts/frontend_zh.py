"""Chinese front end: normalization, then misaki ZHG2P v1.1 with the override lexicon.

normalize() turns a sentence into what should be read: full-width digits/letters to half-width, OpenCC
Traditional -> Simplified, a pre-pass for what misaki's (PaddleSpeech) TextNormalizer gets wrong
(currency, thousands separators, Y-M-D dates, time and year ranges, percent ranges, units, counts, math
symbols, 两 for 2 before a measure word or 千/万/亿: 两个, 两点, 两千; it says 二个, 二点, 二千), then
TextNormalizer on everything except Latin runs, with the punctuation Kokoro uses for
prosody protected from it. A space between two Han characters is read as a short pause; spaces between
Han characters and numbers (共有 100 名, 增长 50%) are mixed-script spacing and are dropped.

TextNormalizer reads every number of three or more digits digit by digit (as a code: 幺二零) unless one
of its measure words follows. The pre-pass therefore writes out counts itself: before the measure words
and units it does not know (公斤, 次, 倍, 台, 平方米, 赫兹, ...), after 第, in scores (120比115) and
after words that announce a quantity (约, 超过, 售价为, ...). Bare numbers stay codes (拨打120, 996, 101路).

ChineseG2P.phonemize() follows ZHG2P.__call__ step by step so it can keep misaki's tokens, rewrite their
readings with the lexicon and record which word each symbol belongs to.
"""

from __future__ import annotations

import logging
import re
import threading
import unicodedata

from .g2p import Builder, Phonemes

CJK = "㐀-䶿一-鿿豈-﫿"
CJK_RE = re.compile(f"[{CJK}]")
LATIN_RUN_RE = re.compile(r"[A-Za-z][A-Za-z0-9]*(?:[ \-'.+&/][A-Za-z0-9]+)*(?:\++|(?<![A-Za-z][A-Za-z])#)?")
TERMINAL = ".!?…:;,。！？；：，、\"”’)）」』]"
# ZHG2P's split of a sentence into English and Chinese segments (misaki/zh.py).
_SEGMENT_RE = re.compile(r"([A-Za-z \'-]*[A-Za-z][A-Za-z \'-]*)|([^A-Za-z]+)")
_CJK_SPACE_RE = re.compile(f"(?<=[{CJK}])\\s+(?=[{CJK}])")
_PAUSE = ""  # stands for a space between two Han characters of the source until the end
# Mixed-script spacing around numbers: TextNormalizer only reads 100 as a count next to its measure word.
_SPACE_BEFORE_NUMBER_RE = re.compile(f"(?<=[{CJK}])[ \\t]+(?=[-+]?(?:\\d|[$¥￥€£₩₹₽]|(?:HK|US|NT|S|A|C)\\$))")
_SPACE_AFTER_NUMBER_RE = re.compile(f"(?<=[\\d%‰℃°])[ \\t]+(?=[{CJK}])")
# Inside a Latin run (sent to the English G2P, its digits to cn2an): GPT-4, COVID-19, Llama-3-8B. cn2an
# reads "-4" as 负四, so the hyphen before a digit becomes a space.
_LATIN_HYPHEN_DIGIT_RE = re.compile(r"(?<=[A-Za-z0-9])-(?=\d)")
# ZHG2P only sends [A-Za-z '-] to the English G2P, so the other symbols of a run are spelled out.
_LATIN_PLUS_RE = re.compile(r"\+(?=[A-Za-z0-9])")
_LATIN_TRAILING_PLUS_RE = re.compile(r"(?<=[A-Za-z0-9])(\++)$")
_LATIN_SHARP_RE = re.compile(r"(?<=[A-Za-z])#$")  # C#, F#

# TextNormalizer deletes these, but Kokoro reads them as pauses and intonation.
_PROTECT = {c: chr(0xE000 + i) for i, c in enumerate("“”‘’…—《》（）「」『』【】()")}
_UNPROTECT = {v: k for k, v in _PROTECT.items()}

_init_lock = threading.Lock()
_tools: dict = {}


def _get(name: str):
    """Lazily built shared helpers (thread-safe): OpenCC, TextNormalizer, misaki number helpers."""
    tool = _tools.get(name)
    if tool is None:
        with _init_lock:
            if not _tools:
                import opencc
                from misaki.zh_normalization import num
                from misaki.zh_normalization import text_normalization as tn_module

                # TextNormalizer starts with its own Traditional -> Simplified table, which also rewrites
                # simplified characters (榜 -> 搒, 琊 -> 玡, 甯 -> 宁). OpenCC has already converted the
                # text, so the table is switched off; nothing else in the process uses it.
                tn_module.tranditional_to_simplified = _same
                _tools.update(cc=opencc.OpenCC("t2s"), tn=tn_module.TextNormalizer(), num=num)
            tool = _tools[name]
    return tool


def _same(text: str) -> str:
    return text


def t2s(text: str) -> str:
    return _get("cc").convert(text)


# ---------------------------------------------------------------------------------------------------
# Pre-pass. Every rule writes Chinese numerals (or digits TextNormalizer reads correctly) directly.

def _num(digits: str) -> str:
    """Cardinal reading, decimals and a sign included: 1299.50 -> 一千二百九十九点五, -3 -> 负三. A whole part of
    more than 32 digits is no count; it is read digit by digit (num2str recurses once per 万 group)."""
    digits = digits.replace(",", "")
    sign = "负" if digits.startswith("-") else ""
    body = digits.lstrip("+-")
    whole, point, fraction = body.partition(".")
    if len(whole) > 32:
        return sign + _digits(whole, alt_one=True) + (f"点{_digits(fraction)}" if point else "")
    return sign + _LEADING_TWO_RE.sub("两", _get("num").num2str(body))


def _digits(digits: str, alt_one: bool = False) -> str:
    """Digit-by-digit reading: years (2026 -> 二零二六), codes with alt_one (110 -> 幺幺零)."""
    return _get("num").verbalize_digit(digits, alt_one=alt_one)


_N = r"\d+(?:\.\d+)?"
_RANGE_SEP = r"\s*([-–—~～至到])\s*"
# A number that starts with 2 before 千, 万 or 亿 says 两 (两千, 两万二千, 两亿); 十二万 and 第二千 keep 二.
_LEADING_TWO_RE = re.compile(r"(?<![零〇一二三四五六七八九十百千万亿两点第])二(?=[千万亿])")
# A lone 2 before these measure words is 两 (两个, 两天, 两点半, 两倍, 一到两公斤). Left out because 二 is part
# of the word: 2月, 2日, 2号, 2楼, 2层, 2路, 2班, 2期, 2级, 2年级, 2代, 2手, 2等, 2声, 2两, 2次方, 2分之1.
_LIANG_WORDS = (
    "个", "位", "名", "人", "口", "户", "家", "只", "头", "匹", "条", "件", "张", "本", "册", "块", "片", "颗", "粒",
    "根", "支", "枝", "把", "台", "辆", "架", "艘", "部", "份", "套", "双", "对", "副", "种", "类", "样", "项", "款",
    "次(?![方元])", "遍", "回", "趟", "下", "番", "倍", "成", "折", "天", "周", "星期", "年(?![级代])", "小时", "钟头",
    "分(?!之)", "秒", "岁", "点(?![\\d零一二三四五六七八九十])", "斤", "公斤", "千克", "克", "吨", "米", "公里", "千米",
    "厘米", "毫米", "寸", "尺", "升", "毫升", "平方", "立方", "亩", "公顷", "元", "角", "毛", "杯", "瓶", "碗", "盒",
    "箱", "袋", "包", "桶", "壶", "罐", "盘", "首", "篇", "段", "句", "页", "章", "节", "课", "门", "间", "座", "栋",
    "幢", "所", "届", "集", "轮", "局", "场", "步", "眼", "笔", "起", "例", "批", "处", "股", "百", "千", "万", "亿",
)
_LIANG_AFTER_RE = re.compile(rf"\s*(?:{'|'.join(_LIANG_WORDS)})")


def _range(a: str, sep: str | None, b: str | None, liang: bool = False) -> str:
    """一百二十到一百五十 for 120-150 (至 stays 至); a single number if there is no second one. With `liang`
    (one of _LIANG_WORDS follows), a plain 2 is 两: 两公斤, 一到两倍."""
    def say(n: str) -> str:
        return "两" if liang and n == "2" else _num(n)

    if b is None:
        return say(a)
    return f"{say(a)}{'至' if sep == '至' else '到'}{say(b)}"


def _liang_after(m: re.Match[str]) -> bool:
    return bool(_LIANG_AFTER_RE.match(m.string, m.end()))


_CURRENCIES = [("HK$", "港元"), ("US$", "美元"), ("NT$", "新台币"), ("S$", "新加坡元"), ("A$", "澳元"),
               ("C$", "加元"), ("¥", "元"), ("￥", "元"), ("$", "美元"), ("€", "欧元"), ("£", "英镑"),
               ("₩", "韩元"), ("₹", "卢比"), ("₽", "卢布")]
_CURRENCY_WORD = dict(_CURRENCIES)
_CURRENCY_SYMBOL = "(" + "|".join(re.escape(s) for s, _ in _CURRENCIES) + ")"
_CURRENCY_RE = re.compile(_CURRENCY_SYMBOL + r"\s*(\d[\d,]*(?:\.\d+)?)"
                          + rf"(?:{_RANGE_SEP}{_CURRENCY_SYMBOL}?\s*(\d[\d,]*(?:\.\d+)?))?"
                          + r"\s*(千万|百万|万亿|万|亿)?")

_UNITS = {"km/h": "公里每小时", "m/s": "米每秒", "km²": "平方公里", "m²": "平方米", "cm²": "平方厘米",
          "mm²": "平方毫米", "m³": "立方米", "cm³": "立方厘米", "kWh": "千瓦时", "mAh": "毫安时", "kW": "千瓦",
          "km": "公里", "kg": "公斤", "cm": "厘米", "mm": "毫米", "ml": "毫升", "mL": "毫升", "mg": "毫克",
          "GHz": "吉赫兹", "MHz": "兆赫兹", "kHz": "千赫兹", "Hz": "赫兹", "ms": "毫秒", "min": "分钟", "m": "米",
          "g": "克", "L": "升", "s": "秒", "h": "小时"}
# Not after a Latin word ("iPhone 5s", "Galaxy S10" are names, not measures) or inside a Latin run. A range
# may repeat the unit (5kg-10kg): left alone, TextNormalizer would read the "-10" as 负十.
_NOT_IN_LATIN = r"(?<![A-Za-z\d,.\-])(?<![A-Za-z] )"
_UNIT_ALT = "|".join(re.escape(u) for u in sorted(_UNITS, key=len, reverse=True))
_UNIT_RE = re.compile(_NOT_IN_LATIN + rf"(\d[\d,]*(?:\.\d+)?)(?:\s?(?:{_UNIT_ALT}))?"
                      rf"(?:{_RANGE_SEP}(\d[\d,]*(?:\.\d+)?))?\s?({_UNIT_ALT})(?![A-Za-z0-9²³])")
# Units that stay Latin (the English G2P reads them) but make the number before them a count: 120GB.
_LATIN_UNITS = ("TB", "GB", "MB", "KB", "kB", "PB", "Gbps", "Mbps", "Kbps", "kbps", "bps", "fps", "FPS", "GW",
                "MW", "kV", "mV", "mA", "Ah", "Wh", "MWh", "GWh", "dB", "nm", "μm", "um", "px", "ppi", "dpi",
                "rpm", "cc", "W", "V", "A", "G", "T", "M", "K")
_LATIN_UNIT_ALT = "|".join(re.escape(u) for u in sorted(_LATIN_UNITS, key=len, reverse=True))
_LATIN_UNIT_RE = re.compile(_NOT_IN_LATIN + rf"({_N})(?:\s?(?:{_LATIN_UNIT_ALT}))?(?:{_RANGE_SEP}({_N}))?"
                            rf"(?=\s?(?:{_LATIN_UNIT_ALT})(?![A-Za-z0-9]))")
_FAHRENHEIT_RE = re.compile(r"(-?\d+(?:\.\d+)?)\s?°F")
_CELSIUS_RE = re.compile(r"(?<=\d)\s?°C")
_DEGREE_RE = re.compile(r"(?<=\d)°(?![CF])")
_THOUSANDS_RE = re.compile(r"(?<![\d.,])\d{1,3}(?:,\d{3})+(?:\.\d+)?(?![\d,])")
_PERCENT_RANGE_RE = re.compile(r"(?<![\d.])(\d+(?:\.\d+)?)%?\s*[-–—~～]\s*(\d+(?:\.\d+)?)%")
_PERMILLE_RE = re.compile(r"(\d+(?:\.\d+)?)‰")
_YMD_RE = re.compile(r"(?<!\d)([12]\d{3})([-/.])(\d{1,2})\2(\d{1,2})(?!\d)")
_YM_RE = re.compile(r"(?<!\d)([12]\d{3})([-/])(\d{1,2})(?![\d/-])")
_T = r"([01]?\d|2[0-3])[:：]([0-5]\d)(?:[:：]([0-5]\d))?"
_TIME_RANGE_RE = re.compile(rf"(?<![\d:：]){_T}\s*[-–—~～至到]\s*{_T}(?![\d:：])")
_TIME_RE = re.compile(rf"(?<![\d:：]){_T}(?![\d:：])")
_YEAR_RANGE_RE = re.compile(r"(?<!\d)([12]\d{3})\s*[-–—~～]\s*([12]\d{3})(?!\d)")
_DASH_RE = re.compile(r"(?<=\d)\s*[–—]\s*(?=\d)")
_BELOW_ZERO_RE = re.compile(r"零下\s*-\s*(?=\d)")
# No number has this many digits: read them one by one up front, which also keeps every later pattern
# fast (TextNormalizer's quantifier pattern is quadratic in the run: 3.5 s for 4000 digits).
_LONG_NUMBER_RE = re.compile(r"(\d*)(\.?)(\d{33,})")
_POWER_RE = re.compile(r"(?<=[\dA-Za-z)）])\^([-+]?)(\d+(?:\.\d+)?)")
_PLUS_RE = re.compile(r"(?<=[\dA-Za-z])\s*\+\s*(?=[\dA-Za-z])")  # 1+1, a+b; not C++ or Disney+
_TIMES_RE = re.compile(r"(?<=\d)\s*×\s*(?=\d)")
_DIVIDED_RE = re.compile(r"(?<=\d)\s*÷\s*(?=\d)")
_EQUALS_RE = re.compile(r"(?<=[\w)）])\s*=\s*(?=[\w(（-])")
# A year before these is read digit by digit (2024款, 2014赛季), and with 一, not the 幺 of codes.
_YEAR_CONTEXT_RE = re.compile(r"(?<![\d.])(19\d{2}|20\d{2})(?=赛季|财年|学年|款|届|级|版)")
# A number of years rather than a year: TextNormalizer reads every NN年 and NNNN年 as a year (工作了24年 ->
# 二四年, 上下5000年 -> 五零零零年). Numbers above 2100 are always counted; smaller ones when the words
# around them say so. 1000 to 2100 stays a year unless a word of length comes first (长达1000年).
_YEARS_RE = re.compile(r"(?<![\d.])(\d{2,})(?=\s*年)")
_YEARS_BEFORE_RE = re.compile(r"(?:了|有|近|约|长达|历时|整整|足足|多达|将近|不到|不足|过去|最近|这|那|每|头|满|逾|达|共)"
                              r"\s*$")
_YEARS_STRONG_BEFORE_RE = re.compile(r"(?:近|长达|历时|整整|足足|多达|将近|逾)\s*$")
_YEARS_AFTER_RE = re.compile(r"\s*年(?:多|来|之久|以上|以内|左右|有余|历史|的历史|光景|时间|的时间|间|里|级)")
_ORDINAL_RE = re.compile(rf"第\s*({_N})(?:{_RANGE_SEP}第?\s*({_N}))?")
_SCORE_RE = re.compile(rf"(?<![\d.])({_N})\s*比\s*({_N})(?![\d.])")
# Measure words and units TextNormalizer does not know (its COM_QUANTIFIERS has 米, 个, 元, ...).
# Not here, so the number stays a code: 号, 路, 室, 房, 楼, and 年 (TextNormalizer reads 2024年 itself).
_MEASURE_WORDS = (
    "平方公里", "平方千米", "平方厘米", "平方毫米", "平方米", "平米", "平方", "立方米", "立方厘米", "立方", "公顷", "亩",
    "公斤", "克拉", "克", "英里", "海里", "英尺", "英寸", "码", "磅", "盎司", "加仑", "赫兹", "兆赫", "千赫", "吉赫",
    "千字节", "兆字节", "字节", "比特", "像素", "帧", "兆", "千瓦时", "千瓦", "瓦特", "瓦", "伏特", "伏", "安培",
    "毫安时", "毫安", "焦耳", "千焦", "卡路里", "千卡", "大卡", "卡", "分贝", "帕", "倍", "次(?!列车)", "遍", "趟",
    "番", "轮", "回合", "局", "届", "期", "集", "章", "节", "篇", "部", "款", "项", "台", "栋", "幢", "股", "票",
    "例", "起", "宗", "份", "种", "类", "样", "门", "架", "枚", "间", "批", "处", "字", "句", "行", "列", "题",
)
_COUNT_RE = re.compile(rf"(?<![A-Za-z\d.\-])({_N})(?:{_RANGE_SEP}({_N}))?(\s*[多余几+])?"
                       rf"(?=\s*(?:{'|'.join(_MEASURE_WORDS)}))")
# Words after which a bare number is a quantity: 超过1000, 约120, 售价为5999, 得分为120, 等于1024.
_QUANTITY_CONTEXT_RE = re.compile(
    r"(约等于|等于|大约|约|总共|共计|一共|共|总计|合计|累计|达到|高达|多达|长达|达|超过|超出|突破|不到|不足|将近|接近|近|逾|"
    r"仅有|只有|仅|至少|最少|最多|增至|降至|升至|跌至|涨至|增加到|减少到|提高到|降低到|下降到|上升到|增长到|"
    r"得分|总分|比分|分数|评分|起售价|售价|价格|定价|单价|报价|起价|人口|总数|数量|数目|排名)"
    rf"(为|是|了|有|约|达|到|至)?\s*({_N})(?:{_RANGE_SEP}({_N}))?"
    r"(?![\d.,%‰℃°/:：A-Za-z\-–—~～])(?!\s*(?:年|号|路|室|房|楼))")
# 2 before one of _LIANG_WORDS, alone or in a range (1-2个, 2~3天). Not an ordinal (第2) and not part of a
# number, a date, a time, a fraction or a Latin run.
_NOT_AFTER = r"(?<![\d.,\-–—~～/:：第A-Za-z])(?<![A-Za-z] )(?<!第 )"
_TWO_RE = re.compile(rf"{_NOT_AFTER}2(?![\d.,:：/])(?={_LIANG_AFTER_RE.pattern})")
_TWO_RANGE_RE = re.compile(rf"{_NOT_AFTER}(\d+)\s*([-–—~～至到])\s*(\d+)(?![\d.,:：/])(?={_LIANG_AFTER_RE.pattern})")
_quantifier_re: re.Pattern[str] | None = None
_big_count_re: re.Pattern[str] | None = None


def _quantifiers() -> tuple[re.Pattern[str], re.Pattern[str]]:
    global _quantifier_re, _big_count_re
    if _big_count_re is None:
        q = _get("num").COM_QUANTIFIERS
        _quantifier_re = re.compile(rf"\s*[多余几+]?{q}")
        # 7-8 digit counts before a measure word; TextNormalizer would read them as phone numbers.
        _big_count_re = re.compile(rf"(?<![\d.])[1-9]\d{{6,7}}(?=[多余几+]?{q})")
    return _quantifier_re, _big_count_re


def _long_number(m: re.Match[str]) -> str:
    whole, point, digits = m.groups()
    if point:  # the fraction of a decimal: 三点一四一五九...
        return f"{_num(whole) if whole else '零'}点{_digits(digits)}"
    return _digits(whole + digits, alt_one=True)


def _currency(m: re.Match[str]) -> str:
    # The number is spelled out here: TextNormalizer only reads 元 and 美元 as measure words.
    symbol, a, sep, _, b, scale = m.groups()
    return f"{_range(a, sep, b, liang=True)}{scale or ''}{_CURRENCY_WORD[symbol]}"


def _unit(m: re.Match[str]) -> str:
    a, sep, b, unit = m.groups()
    return _range(a, sep, b, liang=True) + _UNITS[unit]


def _count(m: re.Match[str]) -> str:
    a, sep, b, more = m.groups()
    more = (more or "").strip()
    return _range(a, sep, b, _liang_after(m)) + ("多" if more == "+" else more)


def _quantity(m: re.Match[str]) -> str:
    context, link, a, sep, b = m.groups()
    if context == "比分" and b is not None:  # 比分是3-2: a score, not a range
        return f"{context}{link or ''}{_num(a)}比{_num(b)}"
    return context + (link or "") + _range(a, sep, b, _liang_after(m))


def _two_range(m: re.Match[str]) -> str:
    a, sep, b = m.groups()
    return _range(a, sep, b, liang=True) if "2" in (a, b) else m.group(0)


def _power(m: re.Match[str]) -> str:
    return f"的{'负' if m.group(1) == '-' else ''}{_num(m.group(2))}次方"


def _years(m: re.Match[str]) -> str:
    n = m.group(1)
    if n.startswith("0"):
        return n
    before = m.string[max(0, m.start() - 4):m.start()]
    if before.endswith(("自", "从", "于", "在", "到", "至")):  # 从98年起: a year
        return n
    if len(n) == 4 and 1000 <= int(n) <= 2100:
        counted = _YEARS_STRONG_BEFORE_RE.search(before) or m.string.startswith(("年历史", "年的历史", "年之久"),
                                                                                m.end())
    else:
        counted = (len(n) >= 4 or _YEARS_BEFORE_RE.search(before)
                   or _YEARS_AFTER_RE.match(m.string, m.end()))
    return _num(n) if counted else n


def _ymd(m: re.Match[str]) -> str:
    month, day = int(m.group(3)), int(m.group(4))
    if not (1 <= month <= 12 and 1 <= day <= 31):
        return m.group(0)
    return f"{_digits(m.group(1))}年{_num(str(month))}月{_num(str(day))}日"


def _ym(m: re.Match[str]) -> str:
    month = int(m.group(3))
    return f"{_digits(m.group(1))}年{_num(str(month))}月" if 1 <= month <= 12 else m.group(0)


def _say_time(hour: str, minute: str, second: str | None) -> str:
    def part(v: str) -> str:
        return ("零" if v.startswith("0") else "") + _num(v.lstrip("0"))

    out = f"{'两' if int(hour) == 2 else _num(hour)}点"
    if int(minute):
        out += "半" if int(minute) == 30 and not (second and int(second)) else f"{part(minute)}分"
    if second and int(second):
        out += f"{part(second)}秒"
    return out


def _time_range(m: re.Match[str]) -> str:
    return f"{_say_time(*m.group(1, 2, 3))}到{_say_time(*m.group(4, 5, 6))}"


def _time(m: re.Match[str]) -> str:
    return _say_time(*m.group(1, 2, 3))


def _year_range(m: re.Match[str]) -> str:
    a, b = int(m.group(1)), int(m.group(2))
    rest = m.string[m.end():]
    if b <= a:
        return m.group(0)
    if rest.startswith("年"):
        if not (1000 <= a and b <= 2100):
            return m.group(0)
    elif not (1900 <= a and b <= 2100) or _quantifiers()[0].match(rest):
        return m.group(0)
    return f"{_digits(m.group(1))}到{_digits(m.group(2))}"


def prepass(text: str) -> str:
    text = _LONG_NUMBER_RE.sub(_long_number, text.replace("−", "-"))
    text = _BELOW_ZERO_RE.sub("零下", text)
    text = _POWER_RE.sub(_power, text)
    text = _PLUS_RE.sub("加", text)
    text = _TIMES_RE.sub("乘", text)
    text = _DIVIDED_RE.sub("除以", text)
    text = _EQUALS_RE.sub("等于", text)
    text = _CURRENCY_RE.sub(_currency, text)
    text = _FAHRENHEIT_RE.sub(r"华氏\1度", text)
    text = _CELSIUS_RE.sub("℃", text)
    text = _DEGREE_RE.sub("度", text)
    text = _UNIT_RE.sub(_unit, text)
    text = _LATIN_UNIT_RE.sub(lambda m: _range(*m.groups()), text)  # the unit itself stays for the English G2P
    text = _PERCENT_RANGE_RE.sub(lambda m: f"百分之{_num(m.group(1))}到百分之{_num(m.group(2))}", text)
    text = _PERMILLE_RE.sub(lambda m: f"千分之{_num(m.group(1))}", text)
    text = _THOUSANDS_RE.sub(lambda m: _num(m.group()), text)
    text = _YMD_RE.sub(_ymd, text)
    text = _YM_RE.sub(_ym, text)
    text = _TIME_RANGE_RE.sub(_time_range, text)
    text = _TIME_RE.sub(_time, text)
    text = _YEAR_RANGE_RE.sub(_year_range, text)
    text = _DASH_RE.sub("-", text)
    text = _YEAR_CONTEXT_RE.sub(lambda m: _digits(m.group(1)), text)
    text = _ORDINAL_RE.sub(lambda m: "第" + _range(*m.groups()), text)
    text = _YEARS_RE.sub(_years, text)
    text = _SCORE_RE.sub(lambda m: f"{_num(m.group(1))}比{_num(m.group(2))}", text)
    text = _TWO_RANGE_RE.sub(_two_range, text)
    text = _TWO_RE.sub("两", text)
    text = _COUNT_RE.sub(_count, text)
    text = _QUANTITY_CONTEXT_RE.sub(_quantity, text)
    return _quantifiers()[1].sub(lambda m: _num(m.group()), text)


# ---------------------------------------------------------------------------------------------------

def _fullwidth_to_half(text: str) -> str:
    # Only digits, letters and ％; full-width punctuation stays, misaki maps it itself.
    return "".join(unicodedata.normalize("NFKC", c) if ("０" <= c <= "９" or "Ａ" <= c <= "Ｚ" or "ａ" <= c <= "ｚ"
                                                        or c == "％") else c for c in text)


def _normalize_run(run: str) -> str:
    """TextNormalizer on a run without Latin letters, keeping the protected punctuation."""
    protected = "".join(_PROTECT.get(c, c) for c in run)
    out = _LEADING_TWO_RE.sub("两", _get("tn").normalize_sentence(protected))  # its own counts: 2000元
    return "".join(_UNPROTECT.get(c, c) for c in out)


def _latin(run: str) -> str:
    """A Latin run as the English G2P (and cn2an, for its digits) should get it."""
    run = _LATIN_HYPHEN_DIGIT_RE.sub(" ", run)
    run = _LATIN_TRAILING_PLUS_RE.sub(lambda m: " plus" * len(m.group(1)), run)
    run = _LATIN_PLUS_RE.sub(" plus ", run)
    return _LATIN_SHARP_RE.sub(" sharp", run)


def ensure_terminal(text: str) -> str:
    s = text.rstrip()
    if s and s[-1] not in TERMINAL:
        s += "。" if CJK_RE.search(s) else "."
    return s


def normalize(text: str) -> str:
    text = _CJK_SPACE_RE.sub(_PAUSE, t2s(_fullwidth_to_half(text)))
    text = _SPACE_AFTER_NUMBER_RE.sub("", _SPACE_BEFORE_NUMBER_RE.sub("", text))
    text = prepass(text)
    out, pos = [], 0
    for m in LATIN_RUN_RE.finditer(text):  # Latin runs go to the English G2P
        out.append(_normalize_run(text[pos:m.start()]))
        out.append(_latin(m.group()))
        pos = m.end()
    out.append(_normalize_run(text[pos:]))
    # Spaces left between Han characters came from numbers and units written out; the source ones are pauses.
    return ensure_terminal(_CJK_SPACE_RE.sub("", "".join(out)).replace(_PAUSE, "，"))


# ---------------------------------------------------------------------------------------------------

class ChineseG2P:
    """misaki ZHG2P(version="1.1") with English segments sent to `english` (an EnglishG2P, US)."""

    def __init__(self, english, lexicon=None, cache_dir: str | None = None) -> None:
        import jieba
        from misaki.zh import ZHG2P

        jieba.setLogLevel(logging.WARNING)
        jieba.default_logger.handlers.clear()  # it has its own stderr handler; let records propagate
        if cache_dir:
            jieba.dt.tmp_dir = cache_dir  # jieba.cache (the prefix dictionary) lives with our caches
        self._g2p = ZHG2P(version="1.1", en_callable=english)
        self._english = english
        self.lexicon = lexicon

    def __call__(self, text: str) -> str:
        """Plain misaki output, without overrides (reference for tests)."""
        return self._g2p(text)[0]

    def phonemize(self, text: str) -> Phonemes:
        import cn2an
        from misaki.zh import ZHG2P

        b = Builder()
        if not text.strip():
            return b.build()
        frontend = self._g2p.frontend
        text = ZHG2P.map_punctuation(cn2an.transform(text, "an2cn"))
        for i, (en, zh) in enumerate(_SEGMENT_RE.findall(text)):
            en, zh = en.strip(), zh.strip()
            if i:
                b.sep(" ")  # ZHG2P joins its segments with spaces
            if zh:
                _, tokens = frontend(zh)
                if self.lexicon is not None:
                    self.lexicon.apply(tokens)
                for tk in tokens:
                    b.token(tk.text, frontend.unk if tk.phonemes is None else tk.phonemes)
                    b.sep(tk.whitespace)
            else:
                for word, phonemes, space in self._english.tokens(en):
                    b.token(word, phonemes)
                    if space:
                        b.sep(" ")
        return b.build()
