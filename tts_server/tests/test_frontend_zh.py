"""Chinese front end: normalization, misaki equivalence, the lab's probe set and the override lexicon."""

from __future__ import annotations

import json

import pytest
from conftest import FIXTURES

from readread_tts import zhuyin
from readread_tts.frontend_zh import CJK_RE, normalize, t2s
from readread_tts.sentences import clean, split

PROBE_DATA = json.loads((FIXTURES / "frontend_probes.json").read_text(encoding="utf-8"))
VOCAB = set(PROBE_DATA["vocab_v1.1-zh"])


def han_readings(g2p, text: str) -> list[tuple[str, str | None]]:
    """(Han character, tone-numbered pinyin or None) along the text, through the server's own steps."""
    out: list[tuple[str, str | None]] = []
    for sentence in split(clean(text), "zh"):
        for tk in g2p.phonemize(normalize(sentence)).tokens:
            if not CJK_RE.search(tk.text):
                continue
            syllables = zhuyin.split_syllables(tk.phonemes) if tk.phonemes else None
            if syllables is not None and len(syllables) == len(tk.text):
                out += [(c, zhuyin.decode(s)) for c, s in zip(tk.text, syllables)]
            else:
                out += [(c, None) for c in tk.text if CJK_RE.match(c)]
    return out


def reading(g2p, text: str, part: str) -> str:
    seq = han_readings(g2p, text)
    hans = "".join(c for c, _ in seq)
    k = hans.find(t2s(part))
    assert k >= 0, f"{part!r} not found in {hans!r}"
    return " ".join(p or "?" for _, p in seq[k:k + len(part)])


# --- normalization ------------------------------------------------------------------------------------

@pytest.mark.parametrize("text, expected", [
    ("2026-1-5", "二零二六年一月五日。"),
    ("2026/10/20", "二零二六年十月二十日。"),
    ("2026-10", "二零二六年十月。"),
    ("9:30-10:15", "九点半到十点十五分。"),
    ("下午3:05:07", "下午三点零五分零七秒。"),
    ("15:00", "十五点。"),
    ("1,234,567元", "一百二十三万四千五百六十七元。"),
    ("人口12345678人", "人口一千二百三十四万五千六百七十八人。"),
    ("共10000000人", "共一千万人。"),
    ("¥3.5亿", "三点五亿元。"),
    ("US$5", "五美元。"),
    ("HK$100", "一百港元。"),
    ("€100", "一百欧元。"),
    ("£2.5", "二点五英镑。"),
    ("5%-10%", "百分之五到百分之十。"),
    ("5-10%", "百分之五到百分之十。"),
    ("3‰", "千分之三。"),
    ("2020-2024年", "二零二零到二零二四年。"),
    ("2020–2024", "二零二零到二零二四。"),
    ("零下-5℃", "零下五度。"),
    ("体温98.6°F", "体温华氏九十八点六度。"),
    ("坡度30°", "坡度三十度。"),
    ("100km/h", "一百公里每小时。"),
    ("5kg", "五公斤。"),
    ("銀行行長", "银行行长。"),
    ("共１２３人", "共一百二十三人。"),
    ("你好", "你好。"),
    ("“用耳朵阅读”", "“用耳朵阅读”"),
    ("第1章 风起云涌", "第一章，风起云涌。"),
    ("它们 很好", "它们，很好。"),
    # mixed-script spacing around numbers is not a pause, and the number keeps its measure word
    ("共有 100 名学生", "共有一百名学生。"),
    ("增长 50%", "增长百分之五十。"),
    ("售价 $999", "售价九百九十九美元。"),
    ("约 3.5 亿元", "约三点五亿元。"),
    ("跑了 5 km 后", "跑了五公里后。"),
    # Latin runs go to the English G2P untouched; "5s" in a product name is not seconds
    ("新款 iPhone 17 Pro，起售价为¥7999", "新款 iPhone 17 Pro，起售价为七千九百九十九元。"),
    ("iPhone 5s", "iPhone 5s."),
    # counts: TextNormalizer reads 3+ digits as a code unless one of its own measure words follows
    ("这款手机支持120Hz刷新率，重量为200g", "这款手机支持一百二十赫兹刷新率，重量为二百克。"),
    ("他的体重是120公斤，一年访问了1500次", "他的体重是一百二十公斤，一年访问了一千五百次。"),
    ("增长了200倍", "增长了二百倍。"),
    ("共售出2500台", "共售出两千五百台。"),
    ("第120届广交会", "第一百二十届广交会。"),
    ("面积达12000平方米", "面积达一万二千平方米。"),
    ("发表了108篇论文", "发表了一百零八篇论文。"),
    ("成交1000股", "成交一千股。"),
    ("约120m²", "约一百二十平方米。"),
    ("120kg", "一百二十公斤。"),
    ("5kg-10kg", "五到十公斤。"),
    ("120-150公斤", "一百二十到一百五十公斤。"),
    ("第3-5章", "第三到五章。"),
    ("得分为120", "得分为一百二十。"),
    ("比分是120比115", "比分是一百二十比一百一十五。"),
    ("售价5999", "售价五千九百九十九。"),
    ("超过1000人", "超过一千人。"),
    ("存储空间120GB", "存储空间一百二十GB。"),
    ("已有120年历史", "已有一百二十年历史。"),
    ("他工作了24年", "他工作了二十四年。"),
    ("中华上下5000年", "中华上下五千年。"),
    ("2014赛季", "二零一四赛季。"),
    ("100多年", "一百多年。"),
    # codes and years stay digit by digit
    ("拨打120急救", "拨打幺二零急救。"),
    ("996工作制", "九九六工作制。"),
    ("1461次列车", "幺四六幺次列车。"),
    ("住在1503号", "住在幺五零三号。"),
    ("101路公交", "幺零幺路公交。"),
    ("98年的夏天", "九八年的夏天。"),
    ("公元前221年", "公元前二二一年。"),
    ("2024年10月", "二零二四年十月。"),
    # Latin terms with digits: cn2an would read the hyphen as 负
    ("GPT-4模型", "GPT 4模型。"),
    ("COVID-19疫情", "COVID 19疫情。"),
    ("Llama-3-8B模型", "Llama 3 8B模型。"),
    ("F-35战机", "F 35战机。"),
    # TextNormalizer's own traditional-to-simplified map is off (it turned 榜 into 搒)
    ("排行榜榜首", "排行榜榜首。"),
    # symbols
    ("使用C#语言", "使用C sharp语言。"),
    ("C++语言", "C plus plus语言。"),
    ("1+1=2", "一加一等于二。"),
    ("x=y+z", "x等于y加z。"),
    ("2^10等于1024", "二的十次方等于一千零二十四。"),
    ("7×24小时", "七乘二十四小时。"),
    ("10÷2=5", "十除以二等于五。"),
    # 2 before a measure word, and at the head of 千/万/亿, is 两; TextNormalizer says 二
    ("我有2个苹果，买了2本书", "我有两个苹果，买了两本书。"),
    ("等了2天，每周2次，过了2年", "等了两天，每周两次，过了两年。"),
    ("下午2点见，2:30开会", "下午两点见，两点半开会。"),
    ("增长了2倍，2个月", "增长了两倍，两个月。"),
    ("这件衣服2000元，约2万人", "这件衣服两千元，约两万人。"),
    ("人口2亿，22000人，12000元", "人口两亿，两万二千人，一万二千元。"),
    ("1-2个工作日，2~3天", "一到两个工作日，两到三天。"),
    ("体重2kg，¥2，$2万", "体重两公斤，两元，两万美元。"),
    # ... but not where 二 belongs to the word, in ordinals, dates, fractions or bare numbers
    ("2月2日，住在2楼2号", "二月二日，住在二楼二号。"),
    ("2年级，第2名，2次方，2分之1", "二年级，第二名，二次方，二分之一。"),
    ("1+1=2，2比1，2.5个", "一加一等于二，二比一，二点五个。"),
    ("十二万，2G网络", "十二万，二G网络。"),
    ("比分是3-2", "比分是三比二。"),
])
def test_normalize(text, expected):
    assert normalize(text) == expected


@pytest.mark.parametrize("text, expected", [
    ("面积120㎡，距离5㎞。", ["面积一百二十平方米，距离五公里。"]),
    ("重5㎏,容量500㎖.", ["重五公斤，容量五百毫升。"]),
    ("2^10等于1024。", ["二的十次方等于一千零二十四。"]),
])
def test_clean_split_normalize(text, expected):
    assert [normalize(s) for s in split(clean(text), "zh")] == expected


def test_digit_runs_stay_fast():
    # TextNormalizer's quantifier pattern is quadratic in a digit run (3.5 s for 4000 digits); long runs are
    # read digit by digit before it sees them.
    import time

    started = time.perf_counter()
    out = normalize("号码" + "1234567890" * 400 + "。")
    assert time.perf_counter() - started < 1.0
    assert out.startswith("号码幺二三四五六七八九零幺二")


@pytest.mark.parametrize("text, spoken", [
    ("GPT-4模型很强大。", ["GPT", "四", "模型", "很", "强大"]),
    ("COVID-19疫情期间。", ["COVID", "十九", "疫情", "期间"]),
    ("使用C#语言。", ["使用", "C", "sharp", "语言"]),
])
def test_latin_terms_are_not_read_negative(zh_g2p, text, spoken):
    tokens = [t.text for t in zh_g2p.phonemize(normalize(text)).tokens if t.spoken]
    assert tokens == spoken


def test_bang_keeps_its_reading(zh_g2p):
    assert reading(zh_g2p, "这首歌登上了排行榜榜首。", "排行榜") == "pai2 hang2 bang3"


# --- equivalence with misaki ------------------------------------------------------------------------------

EQUIVALENCE = [
    "银行行长在接受采访时说：“我们会重复检查每一笔交易，觉得没有问题再放行。”",
    "很多开发者已经在 GitHub 上分享了基于 ChatGPT API 的应用。",
    "再比如中英文混排：一篇讲 Python 编程的文章里，可能同时出现 list、dictionary 和“列表”“字典”。",
    "2026年10月20日，苹果公司发布了新款 iPhone 17 Pro，起售价为¥7999。",
    "会议定于2026-11-05上午10:30召开，报名请拨打010-12345678。",
    "他说（大概）是《三体》——没错……对吧？",
    "一点儿也不难，哪儿都能去。",
]


@pytest.fixture
def zh_plain(zh_g2p):
    """The session's ChineseG2P with the override lexicon switched off."""
    saved = zh_g2p.lexicon
    zh_g2p.lexicon = None
    yield zh_g2p
    zh_g2p.lexicon = saved


@pytest.mark.parametrize("text", EQUIVALENCE)
def test_phonemize_matches_misaki_without_the_lexicon(zh_plain, text):
    n = normalize(text)
    assert zh_plain.phonemize(n).text == " ".join(zh_plain(n).split())


def test_phonemize_records_the_word_of_every_symbol(zh_g2p):
    ph = zh_g2p.phonemize(normalize("我们在 GitHub 上见。"))
    assert "".join(t.text for t in ph.tokens if t.spoken) == "我们在GitHub上见"
    assert [t.text for t in ph.tokens if not t.spoken] == ["."]
    assert len(ph.owners) == len(ph.text)
    assert all(o == -1 for c, o in zip(ph.text, ph.owners) if c.isspace())
    for i, token in enumerate(ph.tokens):
        owned = "".join(c for c, o in zip(ph.text, ph.owners) if o == i)
        assert owned == "".join(token.phonemes.split())


# --- the lab's probe set (frontend_probes.json, route kokoro11zh-misaki) ------------------------------------

XFAIL = {
    ("zh_long", 12, "只有"): "只有把这些细节: misaki applies 有把 third-tone sandhi first (zhi2 you2 ba3); reading "
                             "zhi2 you3 needs prosodic grouping the front end does not model",
}


def _sandhi_surface(expected: str) -> str:
    """The lab accepted a correct 3-3 sandhi surface form of a citation-form expectation (了解 -> liao2 jie3)."""
    syllables = expected.split()
    for j in range(len(syllables) - 1):
        if syllables[j].endswith("3") and syllables[j + 1].endswith("3"):
            syllables[j] = syllables[j][:-1] + "2"
    return " ".join(syllables)


def evaluate(g2p, probe: dict) -> tuple[bool, str]:
    sentence, kind = probe["sentence"], probe["kind"]
    seq = han_readings(g2p, sentence)
    hans = "".join(c for c, _ in seq)
    if kind in ("polyphone", "sandhi"):
        whole = "都处理好" if probe["probe"].startswith("都 (in ") else t2s(probe["probe"])
        k = hans.find(whole)
        if k < 0:
            return False, f"{whole!r} not in {hans!r}"
        got = [p or "?" for _, p in seq[k:k + len(whole)]][:len(probe["expected"].split())]
        got_text = " ".join(got)
        accepted = {probe["expected"]} | ({_sandhi_surface(probe["expected"])} if kind == "polyphone" else set())
        return got_text in accepted, f"{probe['probe']}: got {got_text}, expected {probe['expected']}"
    if kind == "number":
        left, right = probe["left"], probe["right"]
        a = hans.find(left) + len(left) if left else 0
        b = hans.find(right, a) if right else len(hans)
        region = seq[a:b] if (not left or hans.find(left) >= 0) and b >= a else []
        text = "".join(c for c, _ in region)
        pinyin = " ".join(p or "?" for _, p in region)
        ok = text in probe["accepted"] and pinyin == probe["expected_pinyin"]
        return ok, f"{probe['probe']}: got {text} [{pinyin}], expected one of {probe['accepted']} " \
                   f"[{probe['expected_pinyin']}]"
    # english: every word gets English phonemes the v1.1-zh model knows
    ph = g2p.phonemize(normalize(sentence))
    problems = []
    for word in probe["words"]:
        tokens = [t for t in ph.tokens if t.text == word]
        if not tokens or not tokens[0].spoken:
            problems.append(f"{word}: no spoken token")
        elif set(tokens[0].phonemes) - VOCAB - {" "}:
            problems.append(f"{word}: {tokens[0].phonemes!r} has symbols outside the vocab")
    if probe["probe"] == "iPhone 17 Pro" and "十七" not in hans:
        problems.append("17 is not read as 十七")
    return not problems, "; ".join(problems)


def _probe_params():
    for p in PROBE_DATA["probes"]:
        key = (p["text_id"], p["sentence_no"], p["probe"])
        marks = [pytest.mark.xfail(strict=True, reason=XFAIL[key])] if key in XFAIL else []
        yield pytest.param(p, id=f"{p['kind']}-{p['text_id']}.{p['sentence_no']}-{p['probe']}", marks=marks)


def test_probe_set_is_the_chosen_route():
    assert len(PROBE_DATA["probes"]) == 59
    assert len(VOCAB) == 171


@pytest.mark.parametrize("probe", list(_probe_params()))
def test_lab_probe(zh_g2p, probe_tally, probe):
    ok, detail = evaluate(zh_g2p, probe)
    tally = probe_tally[probe["kind"]]
    tally[0] += ok
    tally[1] += 1
    assert ok, detail


# --- override lexicon: fixes and the readings it must leave alone --------------------------------------------

@pytest.mark.parametrize("text, part, expected", [
    ("银行行长在接受采访时说。", "银行行长", "yin2 hang2 hang2 zhang3"),
    ("銀行行長說，他覺得音樂很重要。", "银行行长", "yin2 hang2 hang2 zhang3"),
    ("长时间盯着屏幕。", "长时间", "chang2 shi2 jian1"),
    ("他很长时间没来了。", "很长时间", "hen3 chang2 shi2 jian1"),
    ("借来的书一定要按时还回去。", "还回去", "huan2 hui2 qu4"),
    ("你把书还回去。", "还回去", "huan2 hui2 qu4"),
    ("你得多听几遍。", "你得", "ni2 dei3"),
    ("你得知道这件事。", "你得知道", "ni2 dei3 zhi1 dao4"),
    ("你得了解他。", "你得了解", "ni2 dei3 liao2 jie3"),
    ("大家都得去。", "都得去", "dou1 dei3 qu4"),
    ("我们得走了。", "得走", "dei2 zou3"),
    ("他得了冠军。", "他得了", "ta1 de2 le5"),
    ("十一月很冷。", "十一月", "shi2 yi1 yue4"),
    ("11月11日", "十一月十一日", "shi2 yi1 yue4 shi2 yi1 ri4"),
    ("一九九一年", "一九九一年", "yi1 jiu3 jiu3 yi1 nian2"),
    ("一千一百个", "一千一百", "yi4 qian1 yi4 bai3"),
    ("一万人", "一万", "yi2 wan4"),
    ("1.5倍", "一点五倍", "yi1 dian3 wu3 bei4"),
    ("下午1点半", "一点半", "yi1 dian3 ban4"),
    ("一点钟", "一点钟", "yi1 dian3 zhong1"),
    ("十月一日", "十月一日", "shi2 yue4 yi1 ri4"),
    ("一月份", "一月份", "yi1 yue4 fen4"),
    ("重新过一遍", "重新过一遍", "chong2 xin1 guo4 yi2 bian4"),
])
def test_override(zh_g2p, text, part, expected):
    assert reading(zh_g2p, text, part) == expected


@pytest.mark.parametrize("text, part, expected", [
    ("你还回去吗？", "还回去", "hai2 hui2 qu5"),
    ("队长时间观念很强。", "队长时间", "dui4 zhang3 shi2 jian1"),
    ("你得到了。", "你得到", "ni3 de2 dao4"),
    ("才能得到真正的答案。", "得到", "de2 dao4"),
    ("他得病了。", "得病", "de2 bing4"),
    ("你还得清吗？", "还得清", "hai2 de5 qing1"),
    ("二十一个人来了。", "二十一", "er4 shi2 yi1"),
    ("一个人", "一个", "yi2 ge5"),
    ("一百个", "一百", "yi4 bai3"),
    ("十点一刻", "十点一刻", "shi2 dian3 yi2 ke4"),
    ("一点一点地", "一点一点", "yi4 dian3 yi4 dian3"),
    ("三点一四", "三点一四", "san1 dian3 yi1 si4"),
    ("第一名", "第一", "di4 yi1"),
    ("万一下雨", "万一", "wan4 yi1"),
    ("统一", "统一", "tong3 yi1"),
    ("觉得没有问题再放行。", "放行", "fang4 xing2"),
])
def test_left_alone(zh_g2p, text, part, expected):
    assert reading(zh_g2p, text, part) == expected
