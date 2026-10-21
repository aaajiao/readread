# HTML fixtures

Saved-page stand-ins, written by hand for `LocalExtractorTests` (Defuddle in the web view, gated by
`READREAD_TEST_WEBKIT=1`) and `DocumentReaderTests` (the system's HTML reader when Defuddle is not installed).
No page here was fetched from a site, and the tests never use the network: `tracking.html`'s addresses are
filled in with the port of a test server on 127.0.0.1.

| File | What it checks |
|---|---|
| `article.html` | An English article inside site navigation, a byline, a footnote section and a site footer: the article only, its title without the site name ("The Talking Machine - Fixture Weekly"), author, site and date from the metadata; its own script, which would add a sentence and rename the page, never runs |
| `zh_article.html` | A Chinese article with a site header and footer: the title without the site name (“语音合成简史_测试周刊”), the 参考资料 section dropped |
| `tracking.html` | A page whose style sheet, script, image, frame and background image are on a server (`PORT` is replaced by the test): read from a file, none of them is requested, and the text is still read |

## License

The text written for the tests is MIT, like the repository. The first sentences of `article.html` and
`zh_article.html` are adapted from Wikipedia, "Speech synthesis" (<https://en.wikipedia.org/wiki/Speech_synthesis>)
and 维基百科，“语音合成” (<https://zh.wikipedia.org/wiki/语音合成>), under
[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).
