"""English front end: normalization for misaki, misaki G2P per accent, offline spaCy model."""

from __future__ import annotations

import pytest

from readread_tts import frontend_en
from readread_tts.frontend_en import normalize


@pytest.mark.parametrize("text, expected", [
    # decimals, currency, percentages, years and decades are misaki's own business
    ("Pi is 3.14", "Pi is 3.14."),
    ("It costs $5.99", "It costs $5.99."),
    ("It's 50%", "It's 50%."),
    ("in the 1990s", "in the 1990s."),
    # versions
    ("Get v2.4.1 now", "Get version 2 point 4 point 1 now."),
    ("Version 2.4.1 is out", "Version 2 point 4 point 1 is out."),
    # abbreviations
    ("Dr. Smith and Mr. Jones", "Doctor Smith and Mister Jones."),
    ("e.g. apples, i.e. fruit", "for example apples, that is fruit."),
    ("the U.S. economy", "the US economy."),
    ("Born in the U.S.", "Born in the US."),
    ("St. Louis", "Saint Louis."),
    ("Mt. Everest", "Mount Everest."),
    ("apples, pears, etc.", "apples, pears, et cetera."),
    ("us vs. them", "us versus them."),
    # dates: month-day ordinals
    ("October 20", "October twentieth."),
    ("Oct. 20th", "October twentieth."),
    ("on Oct 3", "on October third."),
    ("20 October", "the twentieth of October."),
    ("the 1st of May", "the first of May."),
    ("2026-10-20", "October twentieth, 2026."),
    # times
    ("10:30 am", "10 30 A M."),
    ("9:00", "9 o'clock."),
    ("9:05 PM", "9 oh 5 P M."),
    # currency misaki does not know
    ("¥500", "500 yen."),
    ("₹200", "200 rupees."),
    # domains and file names
    ("Visit example.com or www.github.io", "Visit example dot com or www dot github dot io."),
    ("Node.js rocks", "Node dot js rocks."),
    # units, ranges, numbers
    ("5 km", "5 kilometers."),
    ("1 km", "1 kilometer."),
    ("5-10 people", "5 to 10 people."),
    ("#1 hit", "number 1 hit."),
    ("1/2 cup", "one half cup."),
    ("2/3 done", "two thirds done."),
    ("Call 555-123-4567", "Call 5 5 5, 1 2 3, 4 5 6 7."),
    ("(555) 123-4567", "5 5 5, 1 2 3, 4 5 6 7."),
    ("Call 1-800-555-1234 today", "Call 1, 8 0 0, 5 5 5, 1 2 3 4 today."),
    ("It is 5 - 3", "It is 5 - 3."),
    ("5–10 and 5 – 10", "5 to 10 and 5 to 10."),
    ("Order ABC-123-456", "Order ABC-123-456."),
    ("Card 4111111111111111", "Card 4 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1."),
    ("Version v2.0", "Version 2 point 0."),
    # powers and squared units (clean() turns ㎡ into m²)
    ("It is 2^10 bytes", "It is 2 to the power of 10 bytes."),
    ("E = mc^2", "E = mc squared."),
    ("10^-3", "10 to the power of minus 3."),
    ("120 m²", "120 square meters."),
    ("3 m³", "3 cubic meters."),
    # St. after a name or before the end of the sentence is Street
    ("Main St.", "Main Street."),
    ("The Wall St. Journal", "The Wall Street Journal."),
    ("I live on Baker St. in London", "I live on Baker Street in London."),
    ("We met at St. Mary's", "We met at Saint Mary's."),
    ("₩1000 or ₽250", "1000 won or 250 rubles."),
    # ellipses and the terminal mark
    ("Wait...", "Wait…"),
    ("Hello", "Hello."),
    ("Hello!", "Hello!"),
])
def test_normalize(text, expected):
    assert normalize(text) == expected


@pytest.mark.parametrize("word, us, gb", [
    ("tomato", "təmˈATO", "təmˈɑːtQ"),
    ("schedule", "skˈɛʤˌul", "ʃˈɛdjuːl"),
])
def test_accent_follows_the_voice(en_us, en_gb, word, us, gb):
    assert en_us(word) == us
    assert en_gb(word) == gb


@pytest.mark.parametrize("text, contains", [
    ("It costs $5.99.", ["fˈIv", "dˈɑləɹz", "nˈIndi", "sˈɛnts"]),
    ("Pi is 3.14.", ["θɹˈi", "pYnt", "wˈʌn", "fˈɔɹ"]),
    ("October twentieth.", ["ɑktˈObəɹ", "twˈɛntiəθ"]),
    ("Visit example dot com.", ["dˈɑt", "kˈɑm"]),
    ("Doctor Smith.", ["dˈɑktəɹ", "smˈɪθ"]),
])
def test_us_phonemes(en_us, text, contains):
    phonemes = en_us(text)
    for part in contains:
        assert part in phonemes


def test_unknown_words_go_through_espeak(en_us, en_gb):
    # misaki's lexicon has no "Zorblat"; espeak-ng (through the short data path) spells it.
    assert en_us("Zorblat.").startswith("zˈɔɹbl")
    assert en_gb("Zorblat.").startswith("zˈɔːbl")


def test_tokens_keep_the_surface_words(en_us):
    words = [w for w, p, _ in en_us.tokens("It costs $5.99.")]
    assert words == ["It", "costs", "$", "5.99", "."]
    ph = en_us.phonemize("It costs $5.99.")
    assert [t.text for t in ph.tokens if t.spoken] == ["It", "costs", "5.99"]
    assert ph.text == " ".join(en_us("It costs $5.99.").split())


def test_spacy_model_is_never_downloaded(monkeypatch):
    import spacy.cli
    import spacy.util

    monkeypatch.setattr(spacy.util, "is_package", lambda name: False)
    with pytest.raises(RuntimeError, match="en_core_web_sm is not installed"):
        frontend_en.require_spacy_model()
    with pytest.raises(RuntimeError, match="refusing to download"):
        spacy.cli.download("en_core_web_sm")


def test_a_huge_number_is_read_digit_by_digit(en_us):
    # num2words overflows past 307 digits (OverflowError), which used to fail the whole request with a 500.
    words = [t.text for t in en_us.phonemize(normalize("7" * 400)).tokens if t.spoken]
    assert words == ["7"] * 400
