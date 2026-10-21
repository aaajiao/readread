# Format fixtures

One file (or more) per `ReadableFileType` that is not plain text or Markdown, for `DocumentReaderTests`, and the
encoding cases of `TextDecodingTests`. Every file was made on a Mac for these tests; none is a downloaded
document. `make_formats.sh` regenerates all of them (macOS only; the EPUBs are written with fixed timestamps, the
PDFs carry the date they were made):

```bash
Tests/ReadReadTests/Fixtures/formats/make_formats.sh
```

The expected texts are in `DocumentReaderTests.swift` and `TextDecodingTests.swift`; after regenerating, run
`swift test --filter "DocumentReaderTests|TextDecodingTests"`.

| File | Made with | What it checks |
|---|---|---|
| `source.html` | Written by hand | The page the textutil documents are converted from |
| `sample.rtf`, `sample.rtfd/`, `sample.doc`, `sample.docx`, `sample.odt` | `/usr/bin/textutil -convert <format> source.html` | One document from every format: title, headings, bulleted and numbered lists (Word's list markers dropped), table cells, Chinese text, the References section dropped |
| `paper.pdf` | `make_pdfs.swift` (Core Text; every line placed by hand) | Headings by font size, hyphenated line ends joined, a paragraph running on across a page break, a bulleted list, the running header and "Page N of 3" footers removed, References dropped |
| `zh.pdf` | `make_pdfs.swift` | Chinese lines broken inside words joined without spaces, first-line indents, "第 N 页" footers, a word processor's title ("Microsoft Word - 语音合成.docx") replaced by the first heading |
| `columns.pdf` | `make_pdfs.swift` (two justified columns, Core Text's line breaks) | Lines measured against their own column: whole paragraphs, one running on from the foot of the left column to the top of the right one, indented paragraphs after one that ended at a column's foot (also over the page), "con-" + "catenating" joined, "text-" + "to-speech" keeping its hyphen |
| `zh_columns.pdf` | `make_pdfs.swift` | The same in Chinese: justified lines broken inside words joined across the column break |
| `encrypted.pdf` | `make_pdfs.swift` (user password `secret`) | `DocumentReadError.passwordProtected` |
| `owner_password.pdf` | `make_pdfs.swift` (owner password only) | Readable: an owner password restricts printing and copying, not reading |
| `scan.pdf` | `make_pdfs.swift` (shapes, no text) | `DocumentReadError.noTextLayer` |
| `book.epub` | `make_epubs.py` (Python's `zipfile`, fixed timestamps) | Spine order; the non-linear cover, the navigation document and the endnotes skipped; footnotes and note markers dropped; ruby readings, script and SVG text skipped; a poem's line breaks and sub/superscripts kept; Chinese text wrapped in the source joined; the ideographic space (U+3000) in a heading kept; a chapter whose file name has a space |
| `fonts.epub` | `make_epubs.py` | An `encryption.xml` that only obfuscates a font (the IDPF algorithm): no DRM, read as usual |
| `drm.epub` | `make_epubs.py` | An `encryption.xml` that encrypts a chapter (AES): `DocumentReadError.drmProtected` |
| `malformed.epub` | `make_epubs.py` | A chapter that is not well-formed XML, made well-formed by libxml2's HTML parser (`XMLDocument`'s tidy option) and read with its structure |
| `no_container.epub` | `make_epubs.py` | No `META-INF/container.xml` |
| `missing_spine.epub` | `make_epubs.py` | A spine whose documents are not in the archive |
| `html_inside.doc`, `rtf_inside.doc` | `make_formats.sh` (textutil) | HTML and RTF saved as .doc (office suites' and web sites' exports): read as what they hold |
| `unsafe.epub` | `make_epubs.py` | An entry named `../escape.txt`: refused before anything is unpacked |
| `symlink.epub` | `make_epubs.py` | An entry that is a symbolic link (to `/etc/passwd`): refused before anything is unpacked |
| `korean_euckr.txt`, `korean_cp949.txt` | `make_epubs.py` (Python codecs) | Korean text (EUC-KR, CP949) refused with its own message |
| `japanese_short.txt`, `japanese_cp932.txt` | `make_epubs.py` | Japanese text refused with its own message (short Shift_JIS, CP932) |
| `gbk_short.txt`, `gb18030_short.txt`, `big5_short.txt` | `make_epubs.py` | A few Chinese characters in GBK, GB18030 and Big5 still read as Chinese, not as Korean or Japanese |
| `gbk_spaced_words.txt` | `make_epubs.py` | Four Chinese words in GBK whose CP949 reading is all Hangul (快乐 老家 客人 父母): still Chinese, not refused as Korean |
| `big5_no_punctuation.txt` | `make_epubs.py` | 點符號 in Big5, which also reads as Han characters in GB18030 (翴才腹): Big5 wins the tie |
| `gbk.html` | `make_epubs.py` | A page saved in GBK with `<meta charset="gbk">` |
| `utf8_nometa.html`, `gbk_nometa.html` | `make_epubs.py` | A Chinese page saved in UTF-8 and in GBK without any charset declaration (which WebKit would read as Latin-1): decoded by `TextDecoding` before the web view gets it |

## License

These files are not covered by the repository's MIT license as a whole. The text written for the tests is MIT,
like the repository. Some sentences are quoted or adapted from two Wikipedia articles and keep their license,
[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/):

| Files | Source |
|---|---|
| `source.html` and the `sample.*` documents made from it, `paper.pdf`, `columns.pdf` | Wikipedia, "Speech synthesis" (<https://en.wikipedia.org/wiki/Speech_synthesis>), the opening and History sections |
| `source.html` and the `sample.*` documents, `zh.pdf`, `zh_columns.pdf`, `book.epub` (and the other EPUBs, which share its chapters) | 维基百科，“语音合成” (<https://zh.wikipedia.org/wiki/语音合成>), the opening section |
