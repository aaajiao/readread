"""The evaluation corpus: three Chinese and two English passages, the word probes that must survive the round trip,
and the normalization rules the scoring applies (written into every results.json).

Ported verbatim from the October 2026 lab (keep/lab/eval_asr.py, scoring v2.1). A changed passage or probe changes
what every number means: write a new baseline (asr_eval.sh --write-baseline) in the same change.
"""
from __future__ import annotations

# --------------------------------------------------------------------------------------------------------------
# Shared test passages (verbatim). Each entry: (text, is_heading). Headings get 500 ms of silence after them.
# --------------------------------------------------------------------------------------------------------------
PASSAGES = {
    "zh_main": ("zh", [
        ("2026年10月20日，苹果公司发布了新款 iPhone 17 Pro，起售价为¥7999。", False),
        ("据报道，这款手机一周内的销量增长了50%，总销售额超过3.5亿元。", False),
        ("银行行长在接受采访时说：“我们会重复检查每一笔交易，觉得没有问题再放行。”", False),
        ("很多开发者已经在 GitHub 上分享了基于 ChatGPT API 的应用。", False),
        ("会议定于2026-11-05上午10:30召开，报名请拨打010-12345678。", False),
        ("第一章 风起云涌", True),
        ("他睡觉前总喜欢听一段音乐，然后把明天要做的事情在脑子里重新过一遍，直到困意慢慢地涌上来。", False),
    ]),
    "zh_hant": ("zh", [
        ("這是一段繁體中文。", False),
        ("銀行行長說，他覺得音樂和睡覺一樣重要，而且不想重複同樣的錯誤。", False),
    ]),
    "zh_long": ("zh", [
        ("过去十年，智能手机彻底改变了人们获取信息的方式。", False),
        ("早上醒来，很多人做的第一件事就是打开手机，浏览新闻、查看天气，或者回复工作群里的消息。", False),
        ("根据一项2025年的调查，中国网民平均每天使用手机的时间超过5个小时。", False),
        ("与此同时，长时间盯着屏幕也带来了视力下降、睡眠不足等问题。", False),
        ("于是，“用耳朵阅读”逐渐流行起来。", False),
        ("有声书、播客和文字转语音工具，让人们可以在通勤、做饭或者散步的时候继续“读”文章。", False),
        ("早期的合成声音生硬、机械，听久了很容易疲劳；而今天的神经网络模型已经能够模仿真人的语调和停顿。", False),
        ("不过，中文语音合成仍然面临一些独特的挑战，比如多音字：“长大”的“长”和“长城”的“长”读音并不一样。", False),
        ("他还说，借来的书一定要按时还回去，这样大家才能了解彼此的需要。", False),
        ("再比如中英文混排：一篇讲 Python 编程的文章里，可能同时出现 list、dictionary 和“列表”“字典”。", False),
        ("你得多听几遍，才能得到真正的答案。", False),
        ("只有把这些细节都处理好，听众才会觉得声音自然、可信。", False),
    ]),
    "en_main": ("en", [
        ("On October 20, 2026, Dr. Smith told reporters in the U.S. that version 2.4.1 improves battery life by 2.5% "
         "and costs $3.50 per month.", False),
        ("More than 1,234,567 people have already downloaded it from example.com.", False),
        ("Getting Started", True),
        ("The quick brown fox jumps over the lazy dog.", False),
        ("In 1779, nobody could have imagined that a machine would one day read this sentence aloud — but here we are.",
         False),
    ]),
    "en_long": ("en", [
        ("For most of human history, reading was something you did with your eyes.", False),
        ("That began to change in the 1930s, when the first \"talking books\" were recorded on vinyl records for blind "
         "readers.", False),
        ("Today, audiobooks are a multi-billion-dollar industry, and text-to-speech software can read almost anything "
         "aloud.", False),
        ("Early synthetic voices were famously robotic; they mispronounced names, ignored punctuation, and never paused "
         "to breathe.", False),
        ("Modern neural models are different.", False),
        ("They learn rhythm and intonation from thousands of hours of recorded speech, so a well-trained voice can "
         "sound surprisingly human.", False),
        ("Still, a few details give them away: numbers like 3.14 or 1,500, abbreviations such as e.g. and etc., and "
         "words like \"read\".", False),
        ("I read the article yesterday, and I will read it again tomorrow.", False),
        ("Getting these details right is what separates a voice you tolerate from a voice you enjoy.", False),
    ]),
}

# Each probe = acceptable alternatives (matched after normalization).
PROBES = {
    "zh_main": "iphone | 17 | pro | 7999/七千九百九十九 | 50%/百分之五十 | 3.5亿/三点五亿 | 银行行长 | 重复 | github | chatgpt | "
               "api | 2026 | 11月5日/11-05/十一月五日/11月05日 | 10:30/十点半/十点三十/10点30 | 010 | 12345678 | 风起云涌 | "
               "睡觉 | 音乐",
    "zh_hant": "繁体中文 | 银行行长 | 音乐 | 睡觉 | 重复",
    "zh_long": "2025 | 5个小时/五个小时 | 视力 | 睡眠 | 用耳朵阅读 | 有声书 | 播客 | 通勤 | 神经网络 | 多音字 | 长大 | 长城 | 还回去 | "
               "了解 | python | list | dictionary | 列表 | 字典 | 答案 | 可信",
    "en_main": "october 20 | 2026 | dr smith/doctor smith | us/u s/united states | 2.4.1/2 4 1/two point four point one | "
               "2.5/2 point 5 | 3.50/3 50/three fifty | 1234567/1 234 567 | example.com/example dot com | getting started | "
               "1779/17 79 | lazy dog",
    "en_long": "1930s/nineteen thirties | talking books | vinyl | multi billion/multibillion | robotic | punctuation | "
               "neural | intonation | 3.14/3 point 14/three point one four | 1500/1,500/fifteen hundred | eg/e g/for example | "
               "etc/et cetera | read the article yesterday | tolerate | enjoy",
}
PROBES = {k: [[a.strip() for a in p.split("/")] for p in v.split(" | ")] for k, v in PROBES.items()}

ZH_RULES = [
    "Z1 Unicode NFKC: full-width ASCII/digits/punctuation -> half-width (１２％ -> 12%, ￥ -> ¥, ： -> :).",
    "Z2 lowercase Latin letters (iPhone -> iphone).",
    "Z3 Traditional -> Simplified with OpenCC t2s (opencc-python-reimplemented).",
    "Z4 Arabic dates/times: in the REFERENCE only, YYYY-MM-DD or YYYY/MM/DD -> Y年M月D日 (leading zeros dropped; a "
    "transcript that literally contains 2026-11-5 means the hyphens were read out, e.g. as 负, so it is not repaired); "
    "everywhere, H:MM -> H点MM分 (the colon is never pronounced).",
    "Z5 百分之X -> X% (X Chinese numeral, optional 点 decimal, or Arabic).",
    "Z6 clock times: H点半 -> H点30分; H点M分 -> H点MM分; H点M without 分 when M contains 十, when H and M are Arabic "
    "(10点30), or right after a time word (上午/下午/早上/晚上/中午/凌晨/...); H点钟 -> H点. Chinese numerals inside -> Arabic.",
    "Z7 Chinese decimals: X点DDD (DDD pure digit characters, no 十) -> X.DDD (三点五亿 -> 3.5亿).",
    "Z8 Chinese numeral runs (零〇一二三四五六七八九两幺十百千万亿): a run with 十/百/千/万/亿 -> its integer value "
    "(七千九百九十九 -> 7999, 十一 -> 11, 一千五 -> 1500); a run ending in 万/亿 keeps that unit (五万 -> 5万); a run of >= 2 "
    "pure digit characters -> digit string keeping leading zeros (二零二六 -> 2026, 零一零 -> 010); a single numeral only "
    "after 第 or before a unit/measure character (年月日号时点分秒个岁元块万亿%章节倍次), except 十分 (='very') and "
    "一点 outside a time context; runs without any digit/十 (千万, 万一) are left alone.",
    "Z9 X月Y号 -> X月Y日; 月0Y日 -> 月Y日; N块/N块钱 -> N元; ¥N -> N元; 人民币N -> N.",
    "Z10 drop everything except CJK ideographs, a-z, 0-9, % and '.' between digits (punctuation, spaces, hyphens, "
    "colons, quotes all removed).",
    "Z11 (v2) scoring units = mixed error rate: each CJK character, digit, '%' and '.' is one unit, each Latin word "
    "(a-z run, split at the removed spaces/punctuation) is ONE unit; the E13 spacing repair applies to Latin words "
    "(Chat GPT -> chatgpt). v1 counted every Latin letter, so an English word read aloud for a number "
    "('two thousand twenty six' for 2026) cost ~20 errors; it is still reported as char_error_rate.",
    "Z12 (v2) secondary metric per / per_toneless: homophone-tolerant pinyin error rate. Reference pinyin = "
    "pypinyin 0.55 TONE3 per sentence + REF_PINYIN_OVERRIDES (长时间 chang2, “长城”的“长” chang2, 还回去 huan2, "
    "你得 dei3, 慢慢地 de5); a transcript Han character equal to its aligned reference character takes the reference "
    "reading, any other takes pypinyin's; Levenshtein over syllables. Homophone spellings by the ASR (章/张, 他/她) "
    "cost nothing; misreadings (行 hang2 -> 刑 xing2) still count.",
    "Z11b (v2) a run of consecutive Latin words in a transcript whose letters can be segmented entirely into "
    "reference Latin words is re-split that way (chat gptapi -> chatgpt api); spelling must already match.",
    "Z13 (v2.1) probes: besides the character match, a probe counts as hit when its tone-numbered pinyin (from the "
    "curated reference pinyin) occurs in the transcript's OWN pinyin (pypinyin in the transcript's context), i.e. the "
    "ASR wrote an exact homophone (自典 for 字典, 长程 for 长城). Such hits are listed in probes.pinyin_only; "
    "probes.n_hit_chars is the v1 count. v2 let identical characters borrow the reference reading, which credited "
    "重负 (zhong4 fu4) for 重複, 阴乐 (le4) for 音樂, 税觉 (jue2) for 睡覺 and 长成 (zhang3) for 长城.",
    "H1 (v2) Whisper only: segments that are only a known subtitle-credit / thanks-for-watching phrase (字幕志愿者 X, "
    "字幕由...提供, 请不吝点赞..., thanks for watching) or that start at/after the end of speech are removed before "
    "scoring and raise whisper_hallucination; the raw text stays in 'text'.",
]
EN_RULES = [
    "E1 Unicode NFKC, lowercase, curly quotes -> straight.",
    "E2 domains: name.com/.org/.net/.io/.ai/... -> 'name dot com'.",
    "E3 currency: $N -> 'N dollars' (also EUR/GBP).",
    "E4 '%' -> ' percent'; 'per cent' -> 'percent'.",
    "E5 thousands separators removed (1,234,567 -> 1234567).",
    "E6 hyphens, dashes and slashes -> space; '&' -> 'and'; apostrophes deleted (don't -> dont).",
    "E7 periods deleted unless between digits (u.s. -> us, e.g. -> eg, dr. -> dr; 2.4.1 and 3.14 kept); other "
    "punctuation -> space.",
    "E8 phrases: dr -> doctor; 'u s' / 'united states' -> us; 'e g' / 'for example' -> eg; 'i e' -> ie; "
    "'et cetera' / 'etcetera' -> etc.",
    "E9 spoken years: <eleven..twenty> <two-digit number words | oh N> -> 4-digit year (twenty twenty six -> 2026, "
    "seventeen seventy nine -> 1779); spoken decades (nineteen thirties -> 1930s).",
    "E10 remaining number words -> digits with text2num alpha2digit(lang='en', threshold=0) (one day -> 1 day, "
    "fifteen hundred -> 1500, three point one four -> 3.14, first -> 1st); a scale word (hundred/thousand/million/"
    "billion, plurals) not preceded by a number word or digit stays a word (multi billion, thousands of hours).",
    "E11 'N point M' -> N.M (2.4 point 1 -> 2.4.1, 3 point 14 -> 3.14); ordinal suffixes dropped (20th -> 20); "
    "'N dollars and M cents' / 'N dollars and M' (v2) / 'N dollars MM' -> 'N.MM dollars'; dollar -> dollars.",
    "E12 split on whitespace -> tokens.",
    "E13 (WER only, reference-aware spacing) a transcript token equal to two ADJACENT reference tokens joined is "
    "split (multibillion -> multi billion); two adjacent transcript tokens whose concatenation is a reference token "
    "are joined. Only spacing changes; spelling must already match. en_cer is space-free anyway.",
    "NOTE en probes '2 4 1' and '1 234 567' are task-given alternatives; they also accept a pause-separated "
    "digit-group reading (Whisper writes '2, 4, 1' / '1, 234, 567' when the TTS says 'two, four, one'). WER and "
    "'edits' still count such readings as errors.",
]
