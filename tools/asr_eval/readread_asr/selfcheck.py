"""The scoring's self-check, ported from the lab (no models, no server): normalization unit cases, every reference
hits its own probes, "correct reading" transcripts score 0, the v2/v2.1 rules, a misreading is caught, exact-zero runs
are classified; then the baseline comparison's own cases (baseline.selfcheck)."""
from __future__ import annotations

import os
import tempfile

from . import baseline
from .audio import digital_zero_runs
from .corpus import PASSAGES
from .scoring import norm_en_tokens, norm_zh, probe_check, ref_units, score, strip_hallucinations, zh_units


# --------------------------------------------------------------------------------------------------------------
# self-check (normalization unit tests; no models needed)
# --------------------------------------------------------------------------------------------------------------
CORRECT_READINGS = {
    "zh_main": [
        "二零二六年十月二十日，苹果公司发布了新款iPhone十七Pro，起售价为七千九百九十九元。据报道，这款手机一周内的销量增长了百分之五十，"
        "总销售额超过三点五亿元。银行行长在接受采访时说：“我们会重复检查每一笔交易，觉得没有问题再放行。”很多开发者已经在GitHub上分享了"
        "基于ChatGPT API的应用。会议定于二零二六年十一月五日上午十点三十分召开，报名请拨打零一零一二三四五六七八。第一章，风起云涌。"
        "他睡觉前总喜欢听一段音乐，然后把明天要做的事情在脑子里重新过一遍，直到困意慢慢地涌上来。",
        "2026年10月20日,苹果公司发布了新款iPhone 17 Pro,起售价为7999元。据报道,这款手机一周内的销量增长了50%,总销售额超过3.5亿元。"
        "银行行长在接受采访时说,我们会重复检查每一笔交易,觉得没有问题再放行。很多开发者已经在GitHub上分享了基于ChatGPT API的应用。"
        "会议定于2026年11月5日上午10点30分召开,报名请拨打010-12345678。第一章 风起云涌 他睡觉前总喜欢听一段音乐,然后把明天要做的"
        "事情在脑子里重新过一遍,直到困意慢慢地涌上来。",
        "2026年10月20日苹果公司发布了新款iPhone 17 Pro起售价为人民币7999块。据报道这款手机一周内的销量增长了百分之50总销售额超过3.5亿元"
        "银行行长在接受采访时说我们会重复检查每一笔交易觉得没有问题再放行很多开发者已经在GitHub上分享了基于Chat GPT API的应用"
        "会议定于2026年11月5号上午十点半召开报名请拨打010 1234 5678第1章风起云涌他睡觉前总喜欢听一段音乐然后把明天要做的事情在脑子里"
        "重新过一遍直到困意慢慢地涌上来",
    ],
    "zh_hant": ["这是一段繁体中文。银行行长说，他觉得音乐和睡觉一样重要，而且不想重复同样的错误。",
                "這是一段繁體中文。銀行行長說，他覺得音樂和睡覺一樣重要，而且不想重複同樣的錯誤。"],
    "zh_long": [
        "过去10年，智能手机彻底改变了人们获取信息的方式。早上醒来，很多人做的第一件事就是打开手机，浏览新闻、查看天气，或者回复工作群里的"
        "消息。根据一项二零二五年的调查，中国网民平均每天使用手机的时间超过五个小时。与此同时，长时间盯着屏幕也带来了视力下降、睡眠不足等"
        "问题。于是，用耳朵阅读逐渐流行起来。有声书、播客和文字转语音工具，让人们可以在通勤、做饭或者散步的时候继续读文章。早期的合成声音"
        "生硬、机械，听久了很容易疲劳；而今天的神经网络模型已经能够模仿真人的语调和停顿。不过，中文语音合成仍然面临一些独特的挑战，比如多音"
        "字：长大的长和长城的长读音并不一样。他还说，借来的书一定要按时还回去，这样大家才能了解彼此的需要。再比如中英文混排：一篇讲Python"
        "编程的文章里，可能同时出现list、dictionary和列表、字典。你得多听几遍，才能得到真正的答案。只有把这些细节都处理好，听众才会觉得"
        "声音自然、可信。"],
    "en_main": [
        "On October twentieth, twenty twenty-six, Doctor Smith told reporters in the United States that version two point "
        "four point one improves battery life by two point five percent and costs three dollars and fifty cents per month. "
        "More than one million two hundred thirty-four thousand five hundred sixty-seven people have already downloaded it "
        "from example dot com. Getting started. The quick brown fox jumps over the lazy dog. In seventeen seventy-nine, "
        "nobody could have imagined that a machine would one day read this sentence aloud, but here we are.",
        "On October 20th, 2026, Dr. Smith told reporters in the U.S. that version 2.4.1 improves battery life by 2.5% and "
        "costs $3.50 per month. More than 1,234,567 people have already downloaded it from example.com. Getting started. "
        "The quick brown fox jumps over the lazy dog. In 1779, nobody could have imagined that a machine would one day "
        "read this sentence aloud, but here we are."],
    "en_long": [
        "For most of human history, reading was something you did with your eyes. That began to change in the nineteen "
        "thirties, when the first talking books were recorded on vinyl records for blind readers. Today, audiobooks are a "
        "multi-billion-dollar industry, and text-to-speech software can read almost anything aloud. Early synthetic voices "
        "were famously robotic; they mispronounced names, ignored punctuation, and never paused to breathe. Modern neural "
        "models are different. They learn rhythm and intonation from thousands of hours of recorded speech, so a "
        "well-trained voice can sound surprisingly human. Still, a few details give them away: numbers like three point "
        "one four or one thousand five hundred, abbreviations such as for example and et cetera, and words like read. I "
        "read the article yesterday, and I will read it again tomorrow. Getting these details right is what separates a "
        "voice you tolerate from a voice you enjoy.",
        "For most of human history, reading was something you did with your eyes. That began to change in the 1930s, "
        "when the first talking books were recorded on vinyl records for blind readers. Today, audiobooks are a "
        "multibillion-dollar industry, and text-to-speech software can read almost anything aloud. Early synthetic "
        "voices were famously robotic. They mispronounced names, ignored punctuation, and never paused to breathe. "
        "Modern neural models are different. They learn rhythm and intonation from thousands of hours of recorded "
        "speech. So a well-trained voice can sound surprisingly human. Still, a few details give them away, numbers "
        "like 3.14 or 1,500, abbreviations such as e.g. and etc., and words like read. I read the article yesterday, "
        "and I will read it again tomorrow. Getting these details right is what separates a voice you tolerate from a "
        "voice you enjoy."],
}
UNIT_CASES_ZH = [("七千九百九十九", "7999"), ("十一月五日", "11月5日"), ("百分之五十", "50%"), ("三点五亿元", "3.5亿元"),
                 ("上午十点半", "上午10点30分"), ("十点三十", "10点30分"), ("10点30", "10点30分"), ("10:30", "10点30分"),
                 ("二零二六年", "2026年"), ("零一零一二三四五六七八", "01012345678"), ("五个小时", "5个小时"),
                 ("一千五百", "1500"), ("一千五", "1500"), ("两万五", "25000"), ("一百零五", "105"), ("十分重要", "十分重要"),
                 ("有一点", "有一点"), ("一周内", "一周内"), ("第一章", "第1章"), ("万一", "万一"), ("千万", "千万"),
                 ("三点一四", "3.14"), ("二〇二六年", "2026年"), ("百分之三点五", "3.5%"), ("下午三点", "下午3点"),
                 ("2026-11-05", "20261105"), ("ref:2026-11-05", "2026年11月5日"), ("11月05日", "11月5日"), ("¥7999", "7999元"), ("十二万", "12万"),
                 ("一千二百三十四万五千六百七十八", "12345678"), ("過去十年", "过去10年"), ("ＧｉｔＨｕｂ", "github")]
UNIT_CASES_EN = [("twenty twenty-six", "2026"), ("seventeen seventy nine", "1779"), ("the nineteen thirties", "the 1930s"),
                 ("two point four point one", "2.4.1"), ("3 point 14", "3.14"), ("fifteen hundred", "1500"),
                 ("1,500", "1500"), ("$3.50", "3.50 dollars"), ("three dollars and fifty cents", "3.50 dollars"),
                 ("2.5%", "2.5 percent"), ("Dr. Smith", "doctor smith"), ("the U.S.", "the us"),
                 ("e.g. and etc.", "eg and etc"), ("example.com", "example dot com"), ("October 20th", "october 20"),
                 ("multi-billion-dollar", "multi billion dollars"), ("1,234,567", "1234567"),
                 ("one million two hundred thirty-four thousand five hundred sixty-seven", "1234567")]


def selfcheck() -> int:
    bad = 0
    print("== unit cases zh")
    for a, want in UNIT_CASES_ZH:
        got = norm_zh(a[4:], ref=True) if a.startswith("ref:") else norm_zh(a)
        ok = got == want
        bad += not ok
        print(f"  {'ok ' if ok else 'BAD'} {a!r} -> {got!r}" + ("" if ok else f" (want {want!r})"))
    print("== unit cases en")
    for a, want in UNIT_CASES_EN:
        got = " ".join(norm_en_tokens(a))
        ok = got == want
        bad += not ok
        print(f"  {'ok ' if ok else 'BAD'} {a!r} -> {got!r}" + ("" if ok else f" (want {want!r})"))
    print("== references hit all their own probes")
    for tid, (lang, sents) in PASSAGES.items():
        ref_text = ("" if lang == "zh" else " ").join(t for t, _ in sents)
        pc = probe_check(tid, ref_text, lang)
        ok = not pc["missed"]
        bad += not ok
        print(f"  {'ok ' if ok else 'BAD'} {tid}: {pc['n_hit']}/{pc['n_total']}" + ("" if ok else f" missed {pc['missed']}"))
        ru = ref_units(tid)[0]
        sc = score(tid, lang, ref_text)
        print(f"  info {tid}: written reference scored as if it were a transcript: {sc['metric']}={sc['error_rate']}"
              f" (non-zero only where reference-only rules apply)")
        print(f"      normalized ref: {('' if lang == 'zh' else ' ').join(ru)}")
    print("== correct-reading transcripts score 0 and hit every probe")
    for tid, texts in CORRECT_READINGS.items():
        lang = PASSAGES[tid][0]
        for t in texts:
            sc = score(tid, lang, t)
            ok = sc["error_rate"] == 0 and not sc["probes"]["missed"]
            bad += not ok
            print(f"  {'ok ' if ok else 'BAD'} {tid}: {sc['metric']}={sc['error_rate']} probes "
                  f"{sc['probes']['n_hit']}/{sc['probes']['n_total']}"
                  + ("" if ok else f"\n      edits {sc['edits']}\n      missed {sc['probes']['missed']}"))
    print("== v2: Z11 units (Latin word = 1 unit)")
    for a, want in [("在 GitHub 上", ["在", "github", "上"]), ("ChatGPT API的", ["chatgpt", "api", "的"]),
                    ("iPhone 17 Pro", ["iphone", "1", "7", "pro"]), ("¥7999", ["7", "9", "9", "9", "元"]),
                    ("3.5亿", ["3", ".", "5", "亿"]), ("list、dictionary和", ["list", "dictionary", "和"])]:
        got = zh_units(a, ref=True)
        ok = got == want
        bad += not ok
        print(f"  {'ok ' if ok else 'BAD'} {a!r} -> {got!r}" + ("" if ok else f" (want {want!r})"))
    t = CORRECT_READINGS["zh_main"][1].replace("2026年10月20日", "two thousand twenty six年ten月twenty日")
    sc = score("zh_main", "zh", t)
    ok = 0 < sc["error_rate"] < 0.05 and sc["char_error_rate"] > 2.5 * sc["error_rate"]   # 8 units vs 26 letters
    bad += not ok
    print(f"  {'ok ' if ok else 'BAD'} English number words for a zh date: cer(Z11)={sc['error_rate']} "
          f"char_error_rate(v1 units)={sc['char_error_rate']}")
    print("== v2: Z12 homophone-tolerant pinyin error rate")
    cases = [("zh_main", CORRECT_READINGS["zh_main"][1].replace("第一章", "第一张").replace("慢慢地", "慢慢的"), 0.0),
             ("zh_hant", "这是一段繁体中文。银刑刑长说，她觉得音乐和税觉一样重要，而且不想重负同样的错误。", None),
             ("zh_long", CORRECT_READINGS["zh_long"][0], 0.0)]
    for tid, t, want in cases:
        sc = score(tid, "zh", t)
        ok = (sc["per"] == want) if want is not None else (0 < sc["per_toneless"] < sc["error_rate"])
        bad += not ok
        print(f"  {'ok ' if ok else 'BAD'} {tid}: cer={sc['error_rate']} per={sc['per']} per_toneless="
              f"{sc['per_toneless']}" + ("" if want is None else f" (want per={want})"))
    print("== v2: Z11b Latin re-segmentation, Z13 homophone probes, E11 'and 50'")
    t = CORRECT_READINGS["zh_main"][1].replace("ChatGPT API", "chat gPTAPI")
    sc = score("zh_main", "zh", t)
    ok = sc["error_rate"] == 0 and not sc["probes"]["missed"]
    bad += not ok
    print(f"  {'ok ' if ok else 'BAD'} 'chat gPTAPI' re-split -> cer={sc['error_rate']} missed={sc['probes']['missed']}")
    t = CORRECT_READINGS["zh_long"][0].replace("长城的长", "长程的长")
    sc = score("zh_long", "zh", t)
    ok = sc["probes"]["missed"] == [] and sc["probes"]["pinyin_only"] == ["长城"] and sc["per"] == 0
    bad += not ok
    print(f"  {'ok ' if ok else 'BAD'} 长程 (chang2 cheng2) for 长城 = homophone hit: probes {sc['probes']['n_hit']}/"
          f"{sc['probes']['n_total']} pinyin_only={sc['probes']['pinyin_only']} cer={sc['error_rate']} per={sc['per']}")
    t = CORRECT_READINGS["zh_long"][0].replace("长城的长", "长成的长")
    sc = score("zh_long", "zh", t)
    ok = sc["probes"]["missed"] == ["长城"] and sc["probes"]["pinyin_only"] == [] and sc["per"] == 0
    bad += not ok
    print(f"  {'ok ' if ok else 'BAD'} v2.1: 长成 (zhang3 cheng2) for 长城 = probe miss, PER lenient: "
          f"missed={sc['probes']['missed']} per={sc['per']}")
    t = "这是一段繁体中文。银行行长说，他觉得阴乐和税觉一样重要，而且不想重负同样的错误。"
    sc = score("zh_hant", "zh", t)
    ok = sorted(sc["probes"]["missed"]) == sorted(["音乐", "睡觉", "重复"]) and sc["probes"]["pinyin_only"] == []
    bad += not ok
    print(f"  {'ok ' if ok else 'BAD'} v2.1: 阴乐 / 税觉 / 重负 = probe misses: missed={sc['probes']['missed']} "
          f"per_toneless={sc['per_toneless']}")
    t = CORRECT_READINGS["zh_long"][0].replace("长城的长", "掌城的长")
    sc = score("zh_long", "zh", t)
    ok = "长城" in sc["probes"]["missed"] and sc["per"] > 0
    bad += not ok
    print(f"  {'ok ' if ok else 'BAD'} 掌城 (zhang3) for 长城 stays a miss: missed={sc['probes']['missed']} per={sc['per']}")
    got = " ".join(norm_en_tokens("costs three dollars and fifty per month"))
    ok = got == "costs 3.50 dollars per month"
    bad += not ok
    print(f"  {'ok ' if ok else 'BAD'} 'three dollars and fifty' -> {got!r}")
    print("== v2: H1 Whisper hallucination removal")
    fake = {"text": "直到困意慢慢地涌上来字幕志愿者 李宗盛", "segments": [
        {"start": 51.3, "end": 53.5, "text": "直到困意慢慢地涌上来"}, {"start": 53.5, "end": 83.5, "text": "字幕志愿者 李宗盛"}]}
    txt, rem = strip_hallucinations(fake, "zh", speech_end_s=60.0)
    ok = txt == "直到困意慢慢地涌上来" and len(rem) == 1 and rem[0]["why"] == "phrase"
    bad += not ok
    print(f"  {'ok ' if ok else 'BAD'} phrase segment removed -> {txt!r} {rem}")
    fake2 = {"text": "Here we are. Thank you.", "segments": [
        {"start": 20.0, "end": 22.0, "text": " Here we are."}, {"start": 24.1, "end": 30.0, "text": " Thank you."}]}
    txt, rem = strip_hallucinations(fake2, "en", speech_end_s=22.3)
    ok = txt == "Here we are." and len(rem) == 1 and rem[0]["why"] == "after_speech_end"
    bad += not ok
    print(f"  {'ok ' if ok else 'BAD'} segment after speech end removed -> {txt!r} {rem}")
    print("== a misreading is caught (zh_main read with '负' for hyphens and digits for the phone number)")
    t = CORRECT_READINGS["zh_main"][1].replace("2026年11月5日上午10点30分", "二千零二十六负十一负五上午十三十").replace(
        "010-12345678", "十负一千二百三十四万五千六百七十八")
    sc = score("zh_main", "zh", t)
    ok = sc["error_rate"] > 0 and "11月5日/11-05/十一月五日/11月05日" in sc["probes"]["missed"] and "010" in sc["probes"]["missed"]
    bad += not ok
    print(f"  {'ok ' if ok else 'BAD'} cer={sc['error_rate']} missed={sc['probes']['missed']} edits={sc['edits']}")
    print("== v2.1: exact-zero runs: edge (within 0.1 s of start/end) vs internal")
    import numpy as np
    import soundfile as sf
    sr = 24000
    noise = lambda s: (np.random.default_rng(0).integers(-300, 300, int(s * sr)) | 1).astype(np.int16)  # never 0
    x = np.concatenate([np.zeros(int(0.033 * sr), np.int16) + 5, np.zeros(int(1.3 * sr), np.int16), noise(1.0),
                        np.zeros(int(0.9 * sr), np.int16), noise(1.0), np.zeros(int(1.2 * sr), np.int16),
                        np.zeros(int(0.02 * sr), np.int16) + 5])
    with tempfile.TemporaryDirectory() as td:   # in TMPDIR, which asr_eval.sh keeps inside the ASR home
        p = os.path.join(td, "z.wav")
        sf.write(p, x, sr, subtype="PCM_16")
        runs = digital_zero_runs(p, 0.3)
    kinds = [("lead" if r["leading"] else "") + ("trail" if r["trailing"] else "") or "internal" for r in runs]
    ok = kinds == ["lead", "internal", "trail"] and abs(runs[1]["dur_s"] - 0.9) < 0.01
    print(f"  {'ok ' if ok else 'BAD'} runs={[(r['at_s'], r['dur_s']) for r in runs]} kinds={kinds}")
    bad += not ok
    bad += baseline.selfcheck()
    print(f"selfcheck: {'PASS' if not bad else f'{bad} FAILURES'}")
    return 1 if bad else 0
