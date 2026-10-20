"""Phoneme strings that remember which G2P token each symbol came from.

Both front ends build a Phonemes value: the exact string handed to kokoro's create_timed(is_phonemes=True),
plus, per symbol, the index of the token (word) it belongs to. align() maps kokoro's per-phoneme timings
back onto those tokens.
"""

from __future__ import annotations

from collections.abc import Iterable, Sequence
from dataclasses import dataclass, field
from typing import Protocol


@dataclass
class Token:
    text: str  # surface text of the word (or punctuation mark)
    phonemes: str
    spoken: bool  # False for punctuation-only tokens


@dataclass
class Phonemes:
    text: str  # whitespace collapsed exactly as kokoro collapses it, so indices line up
    owners: list[int]  # per character of text: index into tokens, -1 for separators
    tokens: list[Token] = field(default_factory=list)

    def speakable(self, vocab: Iterable[str]) -> bool:
        """True if some spoken token has a symbol the model knows."""
        vocab = set(vocab)
        return any(o >= 0 and self.tokens[o].spoken and c in vocab for c, o in zip(self.text, self.owners))


class Builder:
    def __init__(self) -> None:
        self._chars: list[str] = []
        self._owners: list[int] = []
        self.tokens: list[Token] = []

    def token(self, text: str, phonemes: str) -> None:
        index = len(self.tokens)
        self.tokens.append(Token(text, phonemes, any(c.isalpha() for c in phonemes)))
        for c in phonemes:
            self._chars.append(c)
            self._owners.append(-1 if c.isspace() else index)

    def sep(self, chars: str) -> None:
        for c in chars:
            self._chars.append(c)
            self._owners.append(-1)

    def build(self) -> Phonemes:
        """Collapse whitespace the way kokoro's _prepare does (" ".join(s.split()))."""
        text: list[str] = []
        owners: list[int] = []
        pending = False
        for c, o in zip(self._chars, self._owners):
            if c.isspace():
                pending = bool(text)
                continue
            if pending:
                text.append(" ")
                owners.append(-1)
                pending = False
            text.append(c)
            owners.append(o)
        return Phonemes("".join(text), owners, self.tokens)


class Timing(Protocol):
    phoneme: str
    start: float
    end: float


def align(phonemes: Phonemes, timings: Sequence[Timing], vocab: Iterable[str]) -> list[tuple[Token, float, float]]:
    """(token, start, end) for every spoken token that received timings, in order.

    kokoro reports one timing per symbol it knows, batch by batch; splitting a long string into
    batches drops the spaces at the cuts, so the timings are a subsequence of the known symbols and
    a greedy walk pairs them up exactly.
    """
    vocab = set(vocab)
    known = [(c, o) for c, o in zip(phonemes.text, phonemes.owners) if c in vocab]
    spans: dict[int, list[float]] = {}
    k = 0
    for t in timings:
        while k < len(known) and known[k][0] != t.phoneme:
            k += 1
        if k == len(known):
            break
        owner = known[k][1]
        k += 1
        if owner < 0 or not phonemes.tokens[owner].spoken:
            continue
        span = spans.get(owner)
        if span is None:
            spans[owner] = [t.start, t.end]
        else:
            span[0] = min(span[0], t.start)
            span[1] = max(span[1], t.end)
    return [(phonemes.tokens[i], s, e) for i, (s, e) in sorted(spans.items())]
