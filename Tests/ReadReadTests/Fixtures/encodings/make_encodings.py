# Regenerates the encoding fixtures (python3 -I make_encodings.py .), each with Python's own
# codecs so the Swift decoder is checked against an independent encoder. Based on the
# prototype's mkenc.py; the expected texts are in TextDecodingTests.swift.
import os
import sys

d = sys.argv[1]
zh = "第一章　风起\n　　天色渐暗，城门外的老槐树下站着一个少年。他叫林风，今年十六岁。\n　　“你终于来了。”一个苍老的声音从身后传来。\n第二章　夜行\n　　夜色如墨，林风沿着山路一直向北走去。\n"
zh_trad = "第一章　風起\n　　天色漸暗，城門外的老槐樹下站著一個少年。\n"
zh_trad_long = "第二章　夜行\n　　夜色如墨，林風沿著山路一直向北走去。他沒有回頭，因為他知道，身後的城門已經關上了。\n"
en = "Café naïve résumé — “smart quotes” and €5.\n"
# Every non-ASCII byte followed by a letter: GB18030 reads each pair as a Han character.
en_apostrophes = "I don’t know. It’s fine.\n\nIt’s a long story—really. We’ll see what’s next.\n\nThe author didn’t say.\n"
de_midword = "Die Brücke über den Fluss führt nach Zürich. Müller und Jürgen gehen hinüber.\n\nNotes on façade design.\n"
files = {
    "gb18030.txt": zh.encode("gb18030"),
    "gbk.txt": zh.encode("gbk"),
    "big5.txt": zh_trad.encode("big5"),
    "big5_long.txt": (zh_trad + zh_trad_long).encode("cp950"),
    "utf16le_bom.txt": b"\xff\xfe" + zh.encode("utf-16-le"),
    "utf16be_bom.txt": b"\xfe\xff" + zh.encode("utf-16-be"),
    "utf16le.txt": ("Plain ASCII heavy text, " + zh).encode("utf-16-le"),
    "utf16be.txt": ("Plain ASCII heavy text, " + zh).encode("utf-16-be"),
    "utf8_bom.txt": b"\xef\xbb\xbf" + zh.encode("utf-8"),
    "utf8.txt": zh.encode("utf-8"),
    "cp1252.txt": en.encode("cp1252"),
    "cp1252_apostrophes.txt": en_apostrophes.encode("cp1252"),
    "cp1252_midword.txt": de_midword.encode("cp1252"),
    "utf16le_zh.txt": zh.encode("utf-16-le"),
    "utf16be_zh.txt": zh.encode("utf-16-be"),
    "shift_jis.txt": "これは日本語のテキストです。吾輩は猫である。\n".encode("shift_jis"),
    "crlf_utf8.txt": "Para one line one.\r\nPara one line two.\r\n\r\nPara two.\r\n".encode("utf-8"),
    "cr_gbk.txt": "第一行。\r第二行。\r".encode("gbk"),
}
for name, data in files.items():
    with open(os.path.join(d, name), "wb") as f:
        f.write(data)
    print(name, len(data))
