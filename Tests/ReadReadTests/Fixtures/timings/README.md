# Token timing fixtures

Real `POST /synthesize` responses (`format: json`) of the dev TTS server (v0.3.0 server code, Kokoro v1.1-zh and
v1.0 fp16), recorded on 2026-10-21 for `WordTimelineTests`. `audio` is emptied (the tests insert a header-only WAV)
and `input_text` holds the text that was sent; everything else is what the server returned.

| File | Voice | What it covers |
|---|---|---|
| `zh_numbers_english.json` | `zf_001` | Dates, a count and money read as Chinese numbers (`2024年` → `二零二`, `四年`), English words inside Chinese |
| `zh_plain.json` | `zm_009` | Plain Chinese: tokens are whole words, punctuation has none |
| `en_sentence.json` | `af_heart` | Normalized English: `21` → `the twenty-first of`, `Dr.` → `Doctor`; `3.5`, `e-book`, `2024` as written |
| `en_gb_sentence.json` | `bf_emma` | British voice; a time read as `4`, `30`, `P`, `M` |

The texts were written for the tests (MIT, like the repository).
