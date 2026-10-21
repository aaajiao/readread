# Writes the EPUB fixtures and the Korean, Japanese and short Chinese text fixtures
# (python3 -I make_epubs.py <directory>), with Python's own zipfile and codecs. Fixed timestamps
# keep the archives byte for byte the same. The expected texts are in DocumentReaderTests.swift
# and TextDecodingTests.swift.
import os
import sys
import zipfile

out = sys.argv[1] if len(sys.argv) > 1 else "."
STAMP = (2026, 10, 1, 12, 0, 0)

CONTAINER = """<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>
"""

OPF = """<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="id">urn:uuid:9b2f0c1e-0000-4000-8000-readreadtest</dc:identifier>
    <dc:title>The Fixture Book</dc:title>
    <dc:language>en</dc:language>
  </metadata>
  <manifest>
    <item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ch1" href="Text/chapter%201.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="Text/ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="notes" href="Text/notes.xhtml" media-type="application/xhtml+xml"/>
    <item id="css" href="style.css" media-type="text/css"/>
  </manifest>
  <spine>
    <itemref idref="cover" linear="no"/>
    <itemref idref="nav"/>
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
    <itemref idref="notes"/>
  </spine>
</package>
"""

XHTML_HEAD = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="{lang}">
<head><title>{title}</title><link rel="stylesheet" href="../style.css"/><style>p {{ margin: 0 }}</style></head>
<body>
"""

COVER = XHTML_HEAD.format(lang="en", title="Cover") + "<p>COVER PAGE TEXT that is not linear.</p></body></html>\n"
NAV = XHTML_HEAD.format(lang="en", title="Contents") + """<nav epub:type="toc"><ol><li><a href="Text/chapter%201.xhtml">Chapter One</a></li></ol></nav>
<p>NAVIGATION DOCUMENT TEXT.</p></body></html>
"""
CHAPTER1 = XHTML_HEAD.format(lang="en", title="Chapter One") + """<section epub:type="chapter">
<h1>Chapter One: The Voice</h1>
<p>The machine spoke its first sentence&nbsp;in a quiet room<sup><a epub:type="noteref" href="#fn1" id="r1">1</a></sup>, and everybody listened&#8212;even the cat&hellip;</p>
<p>Its maker wrote the words in a notebook,
which is kept in a museum today.<a href="notes.xhtml#n2" role="doc-noteref">[2]</a></p>
<aside epub:type="footnote" id="fn1"><p>FOOTNOTE TEXT that is not read.</p></aside>
<ul><li>It said hello.</li><li>It said <em>goodbye</em>.</li></ul>
<blockquote><p>A voice without a body is still a voice.</p></blockquote>
<p>The old word <ruby>漢字<rt>kanji</rt></ruby> stayed, the reading went.</p>
<p>A short poem:<br/>the first line,<br/>the second line.</p>
<script>document.write("SCRIPT TEXT")</script>
<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><text>SVG TEXT</text></svg>
<p>Water is H<sub>2</sub>O, and E = mc<sup>2</sup> is a formula.</p>
</section>
</body></html>
"""
CHAPTER2 = XHTML_HEAD.format(lang="zh-CN", title="第二章") + """<h2>第二章　声音</h2>
<p>语音合成是通过机械的、电子的方法
产生人造语音的技术。</p>
<p>它把文字转换成可以听懂的声音。</p>
</body></html>
"""
NOTES = XHTML_HEAD.format(lang="en", title="Notes") + """<section epub:type="endnotes" role="doc-endnotes">
<h2>Notes</h2><ol><li id="n2">ENDNOTE TEXT that is not read.</li></ol>
</section>
</body></html>
"""
MALFORMED = """<html><head><title>Broken</title></head><body>
<h1>Broken Markup</h1>
<p>This chapter is not well-formed XML: the paragraph is never closed
<p>and this one uses an HTML entity &nbsp; and a bare <br> tag.
</body></html>
"""
FONT_ENCRYPTION = """<?xml version="1.0" encoding="UTF-8"?>
<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
  <enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
    <enc:CipherData><enc:CipherReference URI="OEBPS/font.otf"/></enc:CipherData></enc:EncryptedData>
</encryption>
"""
DRM_ENCRYPTION = """<?xml version="1.0" encoding="UTF-8"?>
<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
  <enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
    <enc:CipherData><enc:CipherReference URI="OEBPS/Text/chapter%201.xhtml"/></enc:CipherData></enc:EncryptedData>
</encryption>
"""


def write_epub(name, files, extra=()):
    """files: [(name, text)], mimetype first and stored; extra: [(ZipInfo, bytes)] written as given."""
    path = os.path.join(out, name)
    with zipfile.ZipFile(path, "w") as z:
        info = zipfile.ZipInfo("mimetype", STAMP)
        info.compress_type = zipfile.ZIP_STORED
        z.writestr(info, "application/epub+zip")
        for entry, text in files:
            info = zipfile.ZipInfo(entry, STAMP)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            z.writestr(info, text.encode("utf-8"))
        for info, data in extra:
            z.writestr(info, data)
    print(name, os.path.getsize(path))


BOOK = [
    ("META-INF/container.xml", CONTAINER),
    ("OEBPS/content.opf", OPF),
    ("OEBPS/cover.xhtml", COVER),
    ("OEBPS/nav.xhtml", NAV),
    ("OEBPS/Text/chapter 1.xhtml", CHAPTER1),
    ("OEBPS/Text/ch2.xhtml", CHAPTER2),
    ("OEBPS/Text/notes.xhtml", NOTES),
    ("OEBPS/style.css", "body { font-family: serif }\n"),
]
write_epub("book.epub", BOOK)
write_epub("fonts.epub", BOOK + [("META-INF/encryption.xml", FONT_ENCRYPTION)])
write_epub("drm.epub", BOOK + [("META-INF/encryption.xml", DRM_ENCRYPTION)])
write_epub("malformed.epub", [(n, MALFORMED if n.endswith("ch2.xhtml") else t) for n, t in BOOK])
write_epub("no_container.epub", [(n, t) for n, t in BOOK if n != "META-INF/container.xml"])
# The spine lists documents that are not in the archive.
write_epub("missing_spine.epub", [(n, t) for n, t in BOOK if not n.startswith("OEBPS/Text/") and n != "OEBPS/cover.xhtml"])

escape = zipfile.ZipInfo("../escape.txt", STAMP)
write_epub("unsafe.epub", BOOK, extra=[(escape, b"outside")])
link = zipfile.ZipInfo("OEBPS/link.xhtml", STAMP)
link.create_system = 3
link.external_attr = 0o120777 << 16
write_epub("symlink.epub", BOOK, extra=[(link, b"/etc/passwd")])

NOMETA_PAGE = ("<!DOCTYPE html>\n<html lang=\"zh-CN\"><head><title>没有声明编码的网页</title></head>\n"
               "<body><article><h1>没有声明编码的网页</h1><p>这个网页保存的时候没有写明编码，读的时候要先认出它用的是哪一种编码。"
               "语音合成是通过机械的、电子的方法产生人造语音的技术。</p><p>第二段文字让这篇文章不止一句话。</p></article></body></html>\n")

# Text in encodings ReadRead refuses (Korean, Japanese) or must not misread (short Chinese).
texts = {
    "korean_euckr.txt": ("한국어 텍스트입니다. 이 파일은 EUC-KR로 저장되었습니다.\n"
                         "읽기 프로그램은 한국어를 지원하지 않습니다.\n").encode("euc-kr"),
    "korean_cp949.txt": "똠방각하 똑똑한 사람들이 모였습니다. 오늘은 날씨가 좋습니다.\n".encode("cp949"),
    "japanese_short.txt": "こんにちは。\n".encode("shift_jis"),
    "japanese_cp932.txt": "①お知らせ：本日は晴天なり。～ご注意ください～\n".encode("cp932"),
    "gbk_short.txt": "你好，世界。\n".encode("gbk"),
    "gb18030_short.txt": "欢迎使用。\n".encode("gb18030"),
    "big5_short.txt": "電腦說話。\n".encode("big5"),
    # Chinese spaced into words whose CP949 reading is all Hangul (快乐 老家 is 우있 일소), and
    # Big5 without punctuation, which reads as Han characters in GB18030 too (點符號: 翴才腹).
    "gbk_spaced_words.txt": "快乐 老家 客人 父母\n".encode("gbk"),
    "big5_no_punctuation.txt": "點符號\n".encode("big5"),
    # A saved page in GBK, as older Chinese sites served them.
    "gbk.html": ("<!DOCTYPE html>\n<html lang=\"zh-CN\"><head><meta charset=\"gbk\"><title>编码测试</title></head>\n"
                 "<body><h1>编码测试</h1><p>这个网页用国标扩展编码保存，读的时候要先转换成统一码。</p></body></html>\n").encode("gbk"),
    # Pages saved without a charset (the server sent it only in its HTTP header): a browser would
    # read their bytes as Latin-1.
    "utf8_nometa.html": NOMETA_PAGE.encode("utf-8"),
    "gbk_nometa.html": NOMETA_PAGE.encode("gbk"),
}
for name, data in texts.items():
    with open(os.path.join(out, name), "wb") as f:
        f.write(data)
    print(name, len(data))
