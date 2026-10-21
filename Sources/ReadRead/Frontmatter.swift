import Foundation

/// YAML-style frontmatter at the very start of a Markdown text (R3-11, R5-13). Only a block
/// that opens on the first line with `---` and closes with `---` or `...`, and whose every
/// line looks like YAML (`key: value`, a `- item`, an indented continuation, a comment or a
/// blank line), counts; anything else — an intro paragraph between two rules, say — is body.
/// Expects LF newlines (`TextDecoding.normalizeNewlines`); a leading BOM is ignored.
enum Frontmatter {
    struct Split: Equatable, Sendable {
        /// Lowercased keys; quoted values unescaped; a list becomes "a, b".
        let metadata: [String: String]
        let body: String
    }

    static func split(_ text: String) -> Split {
        let content = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return Split(metadata: [:], body: text)
        }
        lines.removeFirst()
        guard let close = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed == "---" || trimmed == "..."
        }) else {
            return Split(metadata: [:], body: text)
        }
        guard let metadata = parse(lines[..<close]) else { return Split(metadata: [:], body: text) }
        let body = lines[(close + 1)...].joined(separator: "\n")
        return Split(metadata: metadata, body: body)
    }

    // MARK: - Parsing

    /// nil when a line is not YAML-like, or there is no key at all.
    static func parse(_ lines: ArraySlice<Substring>) -> [String: String]? {
        // `key: value`; keys may hold letters of any script, digits, spaces, `_ . -`.
        let keyPattern = /([\p{L}\p{N}_][\p{L}\p{N}_ .\-]{0,39}?)[ \t]*:(?:[ \t]+(.*))?/
        var metadata: [String: String] = [:]
        var currentKey: String?
        var block: (key: String, folded: Bool, lines: [String])?

        func finishBlock() {
            guard let open = block else { return }
            let joined = open.lines.joined(separator: open.folded ? " " : "\n")
            metadata[open.key] = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            block = nil
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indented = line.first == " " || line.first == "\t"
            if block != nil {
                if trimmed.isEmpty || indented {
                    block?.lines.append(trimmed)
                    continue
                }
                finishBlock()
            }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if let match = line.wholeMatch(of: keyPattern) {
                let key = String(match.1).lowercased()
                let raw = match.2.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
                currentKey = key
                if raw == ">" || raw == ">-" || raw == "|" || raw == "|-" {
                    block = (key, raw.hasPrefix(">"), [])
                } else {
                    metadata[key] = unquote(raw)
                }
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed == "-", let key = currentKey {
                let item = unquote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                let existing = metadata[key] ?? ""
                metadata[key] = existing.isEmpty ? item : existing + ", " + item
                continue
            }
            if indented, let key = currentKey {
                // A plain multi-line value.
                let existing = metadata[key] ?? ""
                metadata[key] = existing.isEmpty ? trimmed : existing + " " + trimmed
                continue
            }
            return nil
        }
        finishBlock()
        return metadata.isEmpty && currentKey == nil ? nil : metadata
    }

    /// 'It''s' → It's; "say \"hi\"\n" → say "hi" + newline. Unquoted values stay as they are.
    static func unquote(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        var result = ""
        var escaping = false
        for character in value.dropFirst().dropLast() {
            if escaping {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        if escaping { result.append("\\") }
        return result
    }
}
