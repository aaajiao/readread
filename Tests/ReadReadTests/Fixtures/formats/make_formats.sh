#!/bin/bash
# Regenerates every fixture in this directory (run it from anywhere; macOS only):
#   textutil      source.html → sample.rtf, sample.rtfd, sample.doc, sample.docx, sample.odt, and the .doc files
#                                that hold HTML or RTF: html_inside.doc, rtf_inside.doc
#   make_pdfs.swift            → paper.pdf, zh.pdf, encrypted.pdf, owner_password.pdf, scan.pdf, columns.pdf,
#                                zh_columns.pdf
#   make_epubs.py              → *.epub, the Korean, Japanese and short Chinese .txt files and the GBK and
#                                no-charset .html pages
# The expected texts are in DocumentReaderTests.swift and TextDecodingTests.swift.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
for format in rtf rtfd doc docx odt; do
    rm -rf "sample.$format"
    /usr/bin/textutil -convert "$format" -output "sample.$format" source.html
    echo "sample.$format"
done
# What office suites and web sites save as .doc: HTML or RTF under that name.
/usr/bin/textutil -convert html -output html_inside.doc source.html
/usr/bin/textutil -convert rtf -output rtf_inside.doc source.html
echo html_inside.doc rtf_inside.doc
swift make_pdfs.swift "$DIR"
python3 -I make_epubs.py "$DIR"
