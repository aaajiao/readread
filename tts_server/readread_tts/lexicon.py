"""Override lexicon for Chinese readings, applied after misaki's tone sandhi.

Two JSON files share one format: the built-in readread_tts/lexicon_zh.json, and the user's file
($READREAD_USER_LEXICON, default ~/Library/Application Support/ReadRead/lexicon_zh.json), whose entries
apply after the built-in ones. The user file may be missing; it is re-read whenever its modification
time or size changes, and a file that does not parse is ignored (with an error in the log).

    {
      "version": 1,
      "entries": [
        {"text": "行行长", "pinyin": "hang2 hang2 zhang3"},
        {"text": "还回去", "pinyin": "huan2 hui2 qu4", "before": "(按时|要|把.{1,12})"},
        {"text": "一", "pinyin": "yi1", "after": "月", "note": "一月 = January"}
      ]
    }

text    the characters to match (Traditional is converted to Simplified, as the input is).
pinyin  one tone-numbered syllable per character of text, separated by spaces; tone 5 is neutral,
        "ü" may be written "v", erhua as "dianr3"; "*" keeps misaki's reading of that character.
        Write the reading as spoken, with tone sandhi inside the entry already applied; third-tone
        sandhi against the neighbouring characters is re-applied automatically.
before  optional regular expression (Python syntax) that must match the text right before the
        match, e.g. "(按时|准时)" or a lookbehind such as "(?<![队班])".
after   optional regular expression that must match at the text right after the match,
        e.g. "(?!到|了)".
note    free text, ignored.

Matching sees the sentence after normalization, so numbers are already Chinese numerals and
punctuation is ASCII (，-> ","). Later entries win where several cover the same character; an entry is
skipped where any of its characters has no syllable of its own (erhua merges 儿 into the previous one).
Invalid entries are skipped with a warning naming the entry.
"""

from __future__ import annotations

import json
import logging
import os
import re
import threading
from dataclasses import dataclass
from typing import Any

from . import zhuyin

log = logging.getLogger("readread.lexicon")


@dataclass(frozen=True)
class Entry:
    text: str
    syllables: tuple[str | None, ...]  # misaki symbols per character, None = keep
    before: re.Pattern[str] | None
    after: re.Pattern[str] | None

    @classmethod
    def parse(cls, raw: Any, t2s) -> Entry:
        if not isinstance(raw, dict):
            raise ValueError("not a JSON object")
        text, pinyin = raw.get("text"), raw.get("pinyin")
        if not isinstance(text, str) or not text.strip():
            raise ValueError('"text" must be a non-empty string')
        if not isinstance(pinyin, str):
            raise ValueError('"pinyin" must be a string')
        text = t2s(text.strip())
        parts = pinyin.split()
        if len(parts) != len(text):
            raise ValueError(f'"pinyin" has {len(parts)} syllables for the {len(text)} characters of {text!r}')
        syllables = tuple(None if p == "*" else zhuyin.encode(p) for p in parts)
        if all(s is None for s in syllables):
            raise ValueError('"pinyin" is all "*"')
        return cls(text, syllables, _compile(raw, "before", t2s, r"(?:{})\Z"), _compile(raw, "after", t2s, "{}"))

    def matches(self, text: str, start: int) -> bool:
        if self.before is not None and not self.before.search(text, 0, start):
            return False
        return self.after is None or self.after.match(text, start + len(self.text)) is not None


def _compile(raw: dict, key: str, t2s, template: str) -> re.Pattern[str] | None:
    value = raw.get(key)
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError(f'"{key}" must be a string')
    try:
        return re.compile(template.format(t2s(value)))
    except (re.error, OverflowError, RecursionError) as error:  # a{4294967296} overflows
        raise ValueError(f'"{key}" is not a valid regular expression: {error}') from None


def load(path: str, t2s) -> list[Entry]:
    """Parse one lexicon file (UTF-8, with or without a BOM). Raises if the file as a whole is unusable
    (OSError, ValueError, RecursionError for absurdly nested JSON); a bad entry is only skipped."""
    with open(path, encoding="utf-8-sig") as f:
        data = json.load(f)
    if not isinstance(data, dict) or data.get("version") != 1 or not isinstance(data.get("entries"), list):
        raise ValueError('expected {"version": 1, "entries": [...]}')
    entries = []
    for number, raw in enumerate(data["entries"], 1):
        try:
            entries.append(Entry.parse(raw, t2s))
        except Exception as error:  # whatever is wrong with one entry, the others still apply
            text = raw.get("text") if isinstance(raw, dict) else None
            log.warning("%s: entry %d (%r) skipped: %s", path, number, text, error)
    return entries


class Lexicon:
    def __init__(self, builtin_path: str, user_path: str | None, t2s) -> None:
        self._t2s = t2s
        self._builtin = load(builtin_path, t2s)
        self._user_path = user_path
        self._user: list[Entry] = []
        self._stamp: tuple[int, int] | None = None
        self._lock = threading.Lock()
        log.info("built-in lexicon: %d entries", len(self._builtin))

    def entries(self) -> list[Entry]:
        self._refresh()
        return self._builtin + self._user

    def _refresh(self) -> None:
        if not self._user_path:
            return
        try:
            st = os.stat(self._user_path)
            stamp = (st.st_mtime_ns, st.st_size)
        except FileNotFoundError:
            stamp = None
        except OSError as error:
            log.error("user lexicon %s: %s", self._user_path, error)
            stamp = None
        with self._lock:
            if stamp == self._stamp:
                return
            if stamp is None:
                if self._user:
                    log.info("user lexicon %s removed", self._user_path)
                self._user = []
            else:
                try:
                    self._user = load(self._user_path, self._t2s)
                    log.info("user lexicon %s: %d entries", self._user_path, len(self._user))
                except Exception as error:  # a broken user file never fails a request
                    log.error("user lexicon %s ignored: %s: %s", self._user_path, type(error).__name__,
                              str(error)[:200])
                    self._user = []
            self._stamp = stamp  # only once this version of the file has been dealt with

    def apply(self, tokens: list) -> None:
        """Rewrite the phonemes of misaki MTokens (one segment of a sentence) in place."""
        entries = self.entries()
        if not entries:
            return
        chars: list[str] = []
        slots: list[tuple[int, int] | None] = []  # per character: (token, syllable) or None
        syllables: list[list[str] | None] = []
        for i, tk in enumerate(tokens):
            sy = None
            if tk.phonemes and tk.tag not in ("x", "eng"):
                sy = zhuyin.split_syllables(tk.phonemes)
                if sy is not None and len(sy) != len(tk.text):
                    sy = None
            syllables.append(sy)
            for j, ch in enumerate(tk.text):
                chars.append(ch)
                slots.append((i, j) if sy is not None else None)
        text = "".join(chars)

        new: dict[int, str] = {}
        for entry in entries:
            start = text.find(entry.text)
            while start >= 0:
                if entry.matches(text, start):
                    cover = [(start + k, s) for k, s in enumerate(entry.syllables) if s is not None]
                    if all(slots[p] is not None for p, _ in cover):
                        new.update(cover)
                start = text.find(entry.text, start + 1)
        if not new:
            return

        final = _resandhi(text, new, lambda p: syllables[slots[p][0]][slots[p][1]],
                          lambda p: 0 <= p < len(slots) and slots[p] is not None)
        for p, s in final.items():
            i, j = slots[p]
            syllables[i][j] = s
        for i in {slots[p][0] for p in final}:
            tokens[i].phonemes = "".join(syllables[i])


def _resandhi(text: str, new: dict[int, str], original, has_slot) -> dict[int, str]:
    """Redo third-tone sandhi where an override changed a tone next to characters it does not cover:
    a new tone 3 before a tone-3 neighbour becomes tone 2; an untouched tone 3 before a new tone 3 becomes
    tone 2; and an untouched tone 2 before a tone 3 the override removed goes back to tone 3 when that is
    its dictionary reading (很长时间: misaki read 很长 as hen2 zhang3, the override makes it chang2)."""
    final = dict(new)
    gained = sorted(p for p, s in new.items() if s.endswith("3") and not original(p).endswith("3"))
    lost = sorted(p for p, s in new.items() if original(p).endswith("3") and not s.endswith("3"))
    for p in gained:
        n = p + 1
        if has_slot(n) and n not in new and original(n).endswith("3"):
            final[p] = final[p][:-1] + "2"
    for p in gained:
        q = p - 1
        if final[p].endswith("3") and has_slot(q) and q not in new and original(q).endswith("3"):
            final[q] = original(q)[:-1] + "2"
    for p in lost:
        q = p - 1
        if has_slot(q) and q not in new and original(q).endswith("2") and _reads_tone3(text[q], original(q)):
            final[q] = original(q)[:-1] + "3"
    return final


def _reads_tone3(char: str, symbols: str) -> bool:
    """True if the dictionary has `char` with the reading of `symbols` in tone 3."""
    from pypinyin import Style, pinyin

    wanted = zhuyin.decode(symbols)[:-1] + "3"
    readings = pinyin(char, style=Style.TONE3, heteronym=True, neutral_tone_with_five=True)
    return bool(readings) and wanted.replace("v", "ü") in {r.replace("v", "ü") for r in readings[0]}
