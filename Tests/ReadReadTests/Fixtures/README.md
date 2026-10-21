# Test fixtures

Inputs for the text-pipeline tests (`GoldenDocumentTests` and others), read by path; `snapshots/` holds the reviewed
output (`READREAD_UPDATE_SNAPSHOTS=1 swift test --filter GoldenDocumentTests` rewrites it).

These files are not covered by the repository's MIT license as a whole. Third-party text keeps its own license, and
so does its snapshot in `snapshots/`:

| File | Source | License |
|---|---|---|
| `pages/en_wikipedia.md` | Wikipedia, "Speech synthesis" (<https://en.wikipedia.org/wiki/Speech_synthesis>), as converted to Markdown by defuddle.md | [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) |
| `pages/zh_wikipedia.md` | 维基百科，“语音合成” (<https://zh.wikipedia.org/wiki/语音合成>), as converted to Markdown by defuddle.md | [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) |
| `text/en_crlf.txt`, `text/en_hardwrap.txt` | The English Wikipedia article above, as plain text (one with CRLF line ends, one hard-wrapped) | [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) |
| `text/zh_novel_singlenl.txt` | The Chinese Wikipedia article above, laid out as a novel (chapter headings, one paragraph per line) | [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) |
| `pages/hn.md` | Invented; it only copies the layout of defuddle.md's Hacker News pages | MIT, like the repository |
| `pages/zh_tech_blog.md`, `pages/en_article.md` | Written for the tests (v0.4.0) in the shape of defuddle.md output: an invented blog post and article. Sites, authors, addresses, the quotation and its book are made up; the history in the article is common knowledge retold, not copied text | MIT, like the repository |
| `text/zh_dialogue.txt`, `text/en_notes.txt` | Written for the tests (v0.4.0): a short invented story with dialogue and invented meeting notes | MIT, like the repository |
| `encodings/*` | Written for the tests; `encodings/make_encodings.py` generates every file | MIT, like the repository |
