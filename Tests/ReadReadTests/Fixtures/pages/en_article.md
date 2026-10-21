---
title: "Talking Machines: A Short History"
site: "Example Journal"
source: "https://journal.example.org/talking-machines"
domain: "journal.example.org"
language: "en"
word_count: 870
---

Talking Machines
================

*By J. R. R. Smith, Ph.D. — 12 March 2024*

People have tried to build machines that speak for more than 250 years. In 1779, Christian Kratzenstein built resonators that produced the five long vowels (in IPA: \[aː\], \[eː\], \[iː\], \[oː\] and \[uː\]).[^vowels] Wolfgang von Kempelen's "acoustic-mechanical speech machine" followed in 1791.[1]

Early electronic systems
------------------------

Bell Labs demonstrated the **Voder** at the 1939 New York World's Fair. An operator played it like an organ — with a wrist bar, ten keys and a foot pedal — and it took about a year to learn. Dr. Homer Dudley, its inventor, also built the vocoder (see [Fig. 3](#fig-3)).

> "The Voder was a curiosity; the vocoder was the real invention."
> — an imaginary historian, in *A Made-Up History of Sound* (p. 42)

In the 1960s, John Larry Kelly Jr. and Louis Gerstman used an IBM 704 to sing "Daisy Bell". Arthur C. Clarke saw the demo at Bell Labs and used the idea in *2001: A Space Odyssey*.

## The 1970s and 1980s

- Texas Instruments' Speak &amp; Spell (1978) used linear predictive coding.
- DECtalk (1984) grew out of Dennis Klatt's research.
- The MITalk system, i.e. the work of Allen, Hunnicutt and Klatt, became a book.

Imagine a speech chip that cost $50 in 1980 and less than $5 by 1990. Say version v1.2.3 of an engine runs on a phone at 3.14 times real time.

### Formants and concatenation

A formant synthesizer computes the spectrum from rules; the transfer function of a simple resonator is $H(z) = \frac{1}{1 - a z^{-1}}$, which we will not need here. Concatenative systems instead glue recorded units together:

$$
y[n] = \sum_{k} w_k \, x_k[n - d_k]
$$

Unit selection, popular in the 2000s, picks the best sequence from a large database of recorded speech; see [the overview](https://en.wikipedia.org/wiki/Speech_synthesis#Unit_selection_synthesis "Unit selection") for details.

## Neural voices

Modern systems such as WaveNet (2016) and Tacotron produce speech that is hard to tell from a person.<sup>[2]</sup> Open models now run offline: Kokoro has 82 million parameters, and a reader can use it for both Chinese and English.

Reading Chinese inside English text needs care. The writer Lu Xun (Chinese: 鲁迅; 1881–1936) is a good test, as is the game Pokémon (Japanese: ポケモン). A good reader says the Chinese name in Chinese and skips the Japanese one.

| Year | System | Method |
|------|--------|--------|
| 1939 | Voder | manual |
| 1984 | DECtalk | formant |
| 2016 | WaveNet | neural |

Some sentences are long, and a reader has to split them somewhere sensible, for example at a comma, a semicolon or a dash, because a sentence that goes on and on without a real pause — like this one, which keeps adding clauses about vowels, resonators, organs, wrist bars, foot pedals, speech chips and phones — would otherwise take far too long before the first sound comes out of the speaker.

Questions? Mail <editor@journal.example.org> or visit https://journal.example.org/contact.

## See also

- [Speech synthesis](https://en.wikipedia.org/wiki/Speech_synthesis)
- [Vocoder](https://en.wikipedia.org/wiki/Vocoder)

## References

[^vowels]: Kratzenstein's resonators won a prize of the Imperial Academy
    in St. Petersburg.

    A second paragraph of the note.

1. von Kempelen, W. (1791). *Mechanismus der menschlichen Sprache*.
2. van den Oord, A. et al. (2016). *WaveNet: A generative model for raw audio*.
