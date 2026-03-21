import Foundation

struct ExtractedContent: Sendable {
    let title: String
    let text: String
    let language: String
    let domain: String
    let wordCount: Int
}

enum WebExtractorError: LocalizedError {
    case invalidURL
    case fetchFailed(Int)
    case noContent
    case fileReadFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .fetchFailed(let code): return "Failed to fetch content (HTTP \(code))"
        case .noContent: return "No readable content found"
        case .fileReadFailed: return "Failed to read file"
        }
    }
}

enum WebExtractor {

    /// Fetch readable content from a URL via Defuddle API
    static func extractFromURL(_ url: URL) async throws -> ExtractedContent {
        // Build defuddle.md URL: strip protocol from original URL
        var path = url.absoluteString
        for prefix in ["https://", "http://"] {
            if path.hasPrefix(prefix) {
                path = String(path.dropFirst(prefix.count))
                break
            }
        }

        guard let defuddleURL = URL(string: "https://defuddle.md/\(path)") else {
            throw WebExtractorError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: defuddleURL)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw WebExtractorError.fetchFailed(httpResponse.statusCode)
        }

        guard let markdown = String(data: data, encoding: .utf8), !markdown.isEmpty else {
            throw WebExtractorError.noContent
        }

        let (metadata, body) = parseFrontmatter(markdown)
        let plainText = stripMarkdown(body)

        guard !plainText.isEmpty else {
            throw WebExtractorError.noContent
        }

        return ExtractedContent(
            title: metadata["title"] ?? url.host() ?? "Untitled",
            text: plainText,
            language: metadata["language"] ?? "en",
            domain: metadata["domain"] ?? url.host() ?? "",
            wordCount: Int(metadata["word_count"] ?? "0") ?? plainText.split(separator: " ").count
        )
    }

    /// Read a local text or markdown file
    static func readFile(_ url: URL) async throws -> ExtractedContent {
        let gotAccess = url.startAccessingSecurityScopedResource()
        defer {
            if gotAccess { url.stopAccessingSecurityScopedResource() }
        }

        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            throw WebExtractorError.fileReadFailed
        }

        let fileName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.lowercased()

        let plainText: String
        if ext == "md" || ext == "markdown" {
            let (_, body) = parseFrontmatter(content)
            plainText = stripMarkdown(body)
        } else {
            plainText = content
        }

        return ExtractedContent(
            title: fileName,
            text: plainText.trimmingCharacters(in: .whitespacesAndNewlines),
            language: "",
            domain: "",
            wordCount: plainText.split(separator: " ").count
        )
    }

    // MARK: - Parsing

    private static func parseFrontmatter(_ content: String) -> (metadata: [String: String], body: String) {
        guard content.hasPrefix("---\n") else {
            return ([:], content)
        }

        let withoutPrefix = String(content.dropFirst(4))
        guard let endRange = withoutPrefix.range(of: "\n---\n") else {
            return ([:], content)
        }

        let yaml = String(withoutPrefix[..<endRange.lowerBound])
        let body = String(withoutPrefix[endRange.upperBound...])

        var metadata: [String: String] = [:]
        for line in yaml.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                var value = parts[1].trimmingCharacters(in: .whitespaces)
                // Remove surrounding quotes
                if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                metadata[key] = value
            }
        }

        return (metadata, body)
    }

    private static func stripMarkdown(_ markdown: String) -> String {
        var text = markdown

        // Remove images
        text = text.replacingOccurrences(
            of: #"!\[.*?\]\(.*?\)"#, with: "", options: .regularExpression)

        // Convert links to just the link text
        text = text.replacingOccurrences(
            of: #"\[([^\]]+)\]\(.*?\)"#, with: "$1", options: .regularExpression)

        // Remove fenced code blocks
        text = text.replacingOccurrences(
            of: #"```[\s\S]*?```"#, with: "", options: .regularExpression)

        // Remove inline code
        text = text.replacingOccurrences(
            of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)

        // Remove heading markers
        text = text.replacingOccurrences(
            of: #"(?m)^#{1,6}\s+"#, with: "", options: .regularExpression)

        // Remove bold/italic
        text = text.replacingOccurrences(
            of: #"\*{1,3}(.+?)\*{1,3}"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"_{1,3}(.+?)_{1,3}"#, with: "$1", options: .regularExpression)

        // Remove blockquote markers
        text = text.replacingOccurrences(
            of: #"(?m)^>\s*"#, with: "", options: .regularExpression)

        // Remove horizontal rules
        text = text.replacingOccurrences(
            of: #"(?m)^[\-\*_]{3,}\s*$"#, with: "", options: .regularExpression)

        // Remove unordered list markers
        text = text.replacingOccurrences(
            of: #"(?m)^[\-\*\+]\s+"#, with: "", options: .regularExpression)

        // Remove ordered list markers
        text = text.replacingOccurrences(
            of: #"(?m)^\d+\.\s+"#, with: "", options: .regularExpression)

        // Remove HTML tags
        text = text.replacingOccurrences(
            of: #"<[^>]+>"#, with: "", options: .regularExpression)

        // Collapse excessive newlines
        text = text.replacingOccurrences(
            of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
