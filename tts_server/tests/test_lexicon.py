"""Override lexicon: entry parsing, matching, third-tone sandhi repair and the user file."""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass

import pytest

from readread_tts import zhuyin
from readread_tts.lexicon import Entry, Lexicon, load


def same(text: str) -> str:
    return text


@dataclass
class Tok:
    """The fields of misaki's MToken that the lexicon reads and writes."""
    text: str
    phonemes: str | None
    tag: str = "n"


def tokens(*words: tuple[str, str]) -> list[Tok]:
    """("银行", "yin2 hang2"), ... -> tokens with misaki symbols; ("，", None) for punctuation."""
    out = []
    for text, pinyin in words:
        if pinyin is None:
            out.append(Tok(text, text, "x"))
        else:
            out.append(Tok(text, "".join(zhuyin.encode(p) for p in pinyin.split())))
    return out


def pinyin_of(toks: list[Tok]) -> list[str]:
    return [" ".join(zhuyin.decode(s) for s in zhuyin.split_syllables(t.phonemes)) if t.tag != "x" else t.text
            for t in toks]


def write(path, entries, version=1) -> str:
    path.write_text(json.dumps({"version": version, "entries": entries}, ensure_ascii=False), encoding="utf-8")
    return str(path)


def lexicon_with(tmp_path, entries) -> Lexicon:
    return Lexicon(write(tmp_path / "lex.json", entries), None, same)


# --- parsing ---------------------------------------------------------------------------------------------

@pytest.mark.parametrize("raw, message", [
    ("行", "not a JSON object"),
    ({"pinyin": "hang2"}, '"text" must be a non-empty string'),
    ({"text": "  ", "pinyin": "hang2"}, '"text" must be a non-empty string'),
    ({"text": "行", "pinyin": 2}, '"pinyin" must be a string'),
    ({"text": "行长", "pinyin": "hang2"}, '"pinyin" has 1 syllables for the 2 characters'),
    ({"text": "行", "pinyin": "hong9"}, "not a tone-numbered pinyin syllable"),
    ({"text": "行", "pinyin": "*"}, 'all "*"'),
    ({"text": "行", "pinyin": "hang2", "before": "("}, '"before" is not a valid regular expression'),
    ({"text": "行", "pinyin": "hang2", "before": "a{4294967296}"}, '"before" is not a valid regular expression'),
    ({"text": "行", "pinyin": "hang2", "after": ["到"]}, '"after" must be a string'),
])
def test_invalid_entries(raw, message):
    with pytest.raises(ValueError, match=message.replace("(", r"\(").replace("*", r"\*")):
        Entry.parse(raw, same)


def test_entry_is_converted_to_simplified():
    entry = Entry.parse({"text": "銀行行長", "pinyin": "yin2 hang2 hang2 zhang3", "before": "(?<!長)"},
                        lambda s: s.replace("銀", "银").replace("長", "长"))
    assert entry.text == "银行行长"
    assert entry.before.pattern == "(?:(?<!长))\\Z"
    assert entry.syllables == tuple(zhuyin.encode(p) for p in ("yin2", "hang2", "hang2", "zhang3"))


def test_star_keeps_misakis_reading():
    entry = Entry.parse({"text": "行长", "pinyin": "* zhang3"}, same)
    assert entry.syllables[0] is None


def test_builtin_lexicon_parses_completely(builtin_lexicon):
    with open(os.path.join(os.path.dirname(__file__), "..", "readread_tts", "lexicon_zh.json"), encoding="utf-8") as f:
        raw = json.load(f)
    assert len(builtin_lexicon.entries()) == len(raw["entries"])


def test_file_level_errors(tmp_path):
    with pytest.raises(ValueError, match="version"):
        load(write(tmp_path / "a.json", [], version=2), same)
    (tmp_path / "b.json").write_text("{not json", encoding="utf-8")
    with pytest.raises(ValueError):
        load(str(tmp_path / "b.json"), same)
    with pytest.raises(OSError):
        load(str(tmp_path / "missing.json"), same)
    (tmp_path / "c.json").write_text("[" * 100000, encoding="utf-8")
    with pytest.raises(RecursionError):
        load(str(tmp_path / "c.json"), same)


def test_a_file_saved_with_a_bom_loads(tmp_path):
    path = tmp_path / "bom.json"
    path.write_text(json.dumps({"version": 1, "entries": [{"text": "行", "pinyin": "xing2"}]}), encoding="utf-8-sig")
    assert [e.text for e in load(str(path), same)] == ["行"]


def test_invalid_entry_is_skipped_with_a_warning(tmp_path, caplog):
    path = write(tmp_path / "lex.json", [{"text": "行", "pinyin": "hx2"}, {"text": "行", "pinyin": "xing2"}])
    with caplog.at_level(logging.WARNING, logger="readread.lexicon"):
        entries = load(path, same)
    assert [e.text for e in entries] == ["行"]
    assert "entry 1 ('行') skipped" in caplog.text


# --- matching --------------------------------------------------------------------------------------------

def test_context_and_later_entries_win(tmp_path):
    lex = lexicon_with(tmp_path, [
        {"text": "行", "pinyin": "hang2", "before": "银"},
        {"text": "行", "pinyin": "xing2", "after": "人"},
        {"text": "银行", "pinyin": "* heng2"},
    ])
    toks = tokens(("银行", "yin2 hang5"), ("行人", "hang2 ren2"))
    lex.apply(toks)
    assert pinyin_of(toks) == ["yin2 heng2", "xing2 ren2"]


def test_an_entry_applies_only_where_every_character_has_a_syllable(tmp_path):
    lex = lexicon_with(tmp_path, [{"text": "点儿", "pinyin": "dian3 er5"}])
    toks = [Tok("一点儿", zhuyin.encode("yi4") + zhuyin.encode("dianr3"))]  # erhua merged 儿 into 点
    before = toks[0].phonemes
    lex.apply(toks)
    assert toks[0].phonemes == before


def test_english_and_punctuation_tokens_are_never_rewritten(tmp_path):
    lex = lexicon_with(tmp_path, [{"text": "行", "pinyin": "hang2"}])
    toks = [Tok("行", "lˈIn", "eng"), Tok("，", "，", "x")]
    lex.apply(toks)
    assert [t.phonemes for t in toks] == ["lˈIn", "，"]


# --- third-tone sandhi around an override ---------------------------------------------------------------------

def test_new_third_tone_makes_a_third_tone_before_it_second(tmp_path):
    lex = lexicon_with(tmp_path, [{"text": "得", "pinyin": "dei3", "before": "你"}])
    toks = tokens(("你", "ni3"), ("得", "de5"), ("多", "duo1"))
    lex.apply(toks)
    assert pinyin_of(toks) == ["ni2", "dei3", "duo1"]


def test_new_third_tone_before_a_third_tone_becomes_second(tmp_path):
    lex = lexicon_with(tmp_path, [{"text": "得", "pinyin": "dei3", "after": "走"}])
    toks = tokens(("得", "de5"), ("走", "zou3"))
    lex.apply(toks)
    assert pinyin_of(toks) == ["dei2", "zou3"]


def test_removed_third_tone_restores_the_dictionary_tone_before_it(builtin_lexicon):
    # 很长时间: misaki read 很长 as hen2 zhang3; with 长 = chang2, 很 is hen3 again.
    toks = tokens(("很", "hen2"), ("长时间", "zhang3 shi2 jian1"))
    builtin_lexicon.apply(toks)
    assert pinyin_of(toks) == ["hen3", "chang2 shi2 jian1"]


def test_removed_third_tone_leaves_a_real_second_tone_alone(builtin_lexicon):
    toks = tokens(("没", "mei2"), ("长时间", "zhang3 shi2 jian1"))
    builtin_lexicon.apply(toks)
    assert pinyin_of(toks) == ["mei2", "chang2 shi2 jian1"]


# --- the user file ----------------------------------------------------------------------------------------

def test_user_file_is_optional_and_reloaded_when_it_changes(tmp_path, builtin_lexicon, caplog):
    builtin = str(tmp_path / "builtin.json")
    write(tmp_path / "builtin.json", [{"text": "行", "pinyin": "hang2", "before": "银"}])
    user = tmp_path / "user.json"
    lex = Lexicon(builtin, str(user), same)
    assert [e.text for e in lex.entries()] == ["行"]  # no user file yet: fine

    write(user, [{"text": "朝阳", "pinyin": "zhao1 yang2"}])
    toks = tokens(("朝阳", "chao2 yang2"))
    lex.apply(toks)
    assert pinyin_of(toks) == ["zhao1 yang2"]

    write(user, [{"text": "朝阳", "pinyin": "chao2 yang2"}, {"text": "银行", "pinyin": "yin2 xing2"}])
    toks = tokens(("朝阳", "zhao1 yang2"), ("银行", "yin2 hang2"))
    lex.apply(toks)
    assert pinyin_of(toks) == ["chao2 yang2", "yin2 xing2"]  # user entries apply after the built-in ones

    with caplog.at_level(logging.ERROR, logger="readread.lexicon"):
        user.write_text("{broken", encoding="utf-8")
        assert [e.text for e in lex.entries()] == ["行"]
    assert "ignored" in caplog.text

    # whatever breaks the file, it is ignored once (the old entries do not stay) and never fails a request
    write(user, [{"text": "朝阳", "pinyin": "zhao1 yang2"}])
    assert [e.text for e in lex.entries()] == ["行", "朝阳"]
    caplog.clear()
    with caplog.at_level(logging.ERROR, logger="readread.lexicon"):
        user.write_text("[" * 100000, encoding="utf-8")
        assert [e.text for e in lex.entries()] == ["行"]
        assert [e.text for e in lex.entries()] == ["行"]
    assert caplog.text.count("ignored: RecursionError") == 1
    write(user, [{"text": "朝阳", "pinyin": "zhao1 yang2", "after": "a{4294967296}"},
                 {"text": "银行", "pinyin": "yin2 xing2"}])
    assert [e.text for e in lex.entries()] == ["行", "银行"]

    user.unlink()
    assert [e.text for e in lex.entries()] == ["行"]


def test_user_entries_reach_the_chinese_g2p(tmp_path, en_us, cache_dir):
    from readread_tts.frontend_zh import ChineseG2P, normalize, t2s

    builtin = write(tmp_path / "builtin.json", [])
    user = tmp_path / "user.json"
    g2p = ChineseG2P(en_us, Lexicon(builtin, str(user), t2s), cache_dir)
    text = normalize("朝阳区很大。")
    plain = g2p.phonemize(text).text
    assert zhuyin.encode("zhao1") not in plain
    write(user, [{"text": "朝阳区", "pinyin": "zhao1 yang2 qu1"}])
    assert zhuyin.encode("zhao1") in g2p.phonemize(text).text
    user.unlink()
    assert g2p.phonemize(text).text == plain
