"""Clean-up and sentence splitting."""

from __future__ import annotations

import pytest

from readread_tts.sentences import clean, is_speakable, split


def sentences(text: str, lang: str) -> list[str]:
    return split(clean(text), lang)


@pytest.mark.parametrize("text, expected", [
    ("Pi is 3.14. That is all.", ["Pi is 3.14.", "That is all."]),
    ("Version 2.4.1 is out. Get it now!", ["Version 2.4.1 is out.", "Get it now!"]),
    ("Dr. Smith met Mr. Jones in the U.S. last year. Then he left.",
     ["Dr. Smith met Mr. Jones in the U.S. last year.", "Then he left."]),
    ("Use fruit, e.g. Apples, i.e. Fuji. Done.", ["Use fruit, e.g. Apples, i.e. Fuji.", "Done."]),
    ("Wait... what? Yes.", ["Wait... what?", "Yes."]),
    ("I see... Then he left.", ["I see... Then he left."]),
    ("Hmm… OK. Fine.", ["Hmm… OK.", "Fine."]),
    ("Visit example.com today. Thanks.", ["Visit example.com today.", "Thanks."]),
    ("J. K. Rowling wrote it. It sold.", ["J. K. Rowling wrote it.", "It sold."]),
    ("Room No. 5 is open. Go.", ["Room No. 5 is open.", "Go."]),
    ("I said no. Then I left.", ["I said no.", "Then I left."]),
    ('He said "Stop." She left.', ['He said "Stop."', "She left."]),
    ("Really?! Yes!", ["Really?!", "Yes!"]),
    ("Hello world. 你好。再见", ["Hello world.", "你好。", "再见"]),
    ("Getting Started\nThe quick brown fox.", ["Getting Started", "The quick brown fox."]),
    # St. ends a sentence (Street) only before a word that starts one
    ("Main St. Then go home.", ["Main St.", "Then go home."]),
    ("Visit St. Louis today. Bye.", ["Visit St. Louis today.", "Bye."]),
])
def test_english(text, expected):
    assert sentences(text, "en") == expected


@pytest.mark.parametrize("text, expected", [
    ("你好。我很好！你呢？", ["你好。", "我很好！", "你呢？"]),
    ("他说：“好。”然后走了。", ["他说：“好。”", "然后走了。"]),
    ("第一项；第二项;第三项", ["第一项；", "第二项；", "第三项"]),
    ("真的吗?!是的", ["真的吗？！", "是的"]),
    ("价格是3.5元，版本2.4.1。", ["价格是3.5元，版本2.4.1。"]),
    ("等等……好吧。", ["等等……好吧。"]),
    ("第一章 风起云涌\n他睡觉前总喜欢听音乐。", ["第一章 风起云涌", "他睡觉前总喜欢听音乐。"]),
    # half-width punctuation in Chinese text is written full-width, and a sentence-final "." splits
    ("你好,世界.我很好!你呢?", ["你好，世界。", "我很好！", "你呢？"]),
    ("注意 : 这个很重要;那个也是.", ["注意：这个很重要；", "那个也是。"]),
    ("我喜欢 Python. 它很好用。", ["我喜欢 Python。", "它很好用。"]),
    ("增长了3.我们", ["增长了3。", "我们"]),
    ("他说 OK. 然后走了", ["他说 OK。", "然后走了"]),
    # ... but not in numbers, versions, domains, abbreviations, initials, list numbers, ellipses or English
    ("价格是3.5元,版本2.4.1.", ["价格是3.5元，版本2.4.1。"]),
    ("时间是10:30,地点在北京.", ["时间是10:30，地点在北京。"]),
    ("访问example.com获取.然后", ["访问example.com获取。", "然后"]),
    ("我用的是.NET框架.", ["我用的是.NET框架。"]),
    ("Dr. 王说:好的.", ["Dr. 王说：好的。"]),
    ("美国(U.S.)政府.", ["美国(U.S.)政府。"]),
    ("J. K. 罗琳写的.", ["J. K. 罗琳写的。"]),
    ("1.首先 2.其次", ["1.首先 2.其次"]),
    ("等等...好吧.", ["等等...好吧。"]),
    ("我说 Hello, world 然后", ["我说 Hello, world 然后"]),
    # a line without Han characters is split the English way
    ("Hello world. This is a test.", ["Hello world.", "This is a test."]),
])
def test_chinese(text, expected):
    assert sentences(text, "zh") == expected


@pytest.mark.parametrize("text, expected", [
    ("Great 🎉 news 👍🏽!", "Great news !"),
    ("A → B", "A B"),
    ("See note[1] and[^2] here [citation needed].", "See note and here ."),
    ("| a | b |\n|---|---|", "a b"),
    ("• one\n• two", "one\ntwo"),
    ("**bold** and _it_", "bold and it"),
    ("零下5℃，45°", "零下5℃，45°"),
    ("tab\there\r\nnext\u2028line", "tab here\nnext\nline"),
    ("zero\u200bwidth\ufeff", "zerowidth"),
    # CJK unit squares read as their units; '^' stays only as a power
    ("面积120㎡，体积3㎥，5㎞，2㎏，500㎖，㏄，㋀", "面积120m²，体积3m³，5km，2kg，500ml，cc，1月"),
    ("2^10 and mc^2 and 10^-3", "2^10 and mc^2 and 10^-3"),
    ("^_^ hi ^ there^", "hi there"),
])
def test_clean(text, expected):
    assert clean(text) == expected


@pytest.mark.parametrize("text", ["", "   ", "---", "• • •", "|", "🎉🎉", "***", "“”", "...", "()"])
def test_unspeakable(text):
    assert not any(is_speakable(s) for s in sentences(text, "en") + sentences(text, "zh"))


@pytest.mark.parametrize("text", ["a", "你", "7", "①"])
def test_speakable(text):
    assert is_speakable(text)
