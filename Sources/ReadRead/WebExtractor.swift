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

    /// Total number of fetch attempts before giving up (1 initial + retries).
    static let maxAttempts = 3

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

        let data = try await fetchWithRetry(from: defuddleURL)

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

    // MARK: - Fetching

    /// Fetch raw data from `url`, retrying transient failures with exponential backoff.
    ///
    /// `fetch` and `sleep` are injectable so the retry behavior can be tested
    /// without real network access. Retries apply only to transient failures
    /// (see ``isRetryable(error:)`` / ``isRetryable(statusCode:)``); deterministic
    /// failures (4xx other than 429, decode errors) throw immediately.
    static func fetchWithRetry(
        from url: URL,
        maxAttempts: Int = WebExtractor.maxAttempts,
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        fetch: @Sendable (URL) async throws -> (Data, URLResponse) = {
            try await URLSession.shared.data(from: $0)
        }
    ) async throws -> Data {
        var attempt = 1
        while true {
            do {
                let (data, response) = try await fetch(url)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    if attempt < maxAttempts, isRetryable(statusCode: http.statusCode) {
                        try await sleep(backoff(forAttempt: attempt))
                        attempt += 1
                        continue
                    }
                    throw WebExtractorError.fetchFailed(http.statusCode)
                }
                return data
            } catch let error as WebExtractorError {
                throw error  // already a final, non-retryable outcome
            } catch {
                if attempt < maxAttempts, isRetryable(error: error) {
                    try await sleep(backoff(forAttempt: attempt))
                    attempt += 1
                    continue
                }
                throw error
            }
        }
    }

    /// Backoff before the retry following the given (1-based) attempt: 0.5s, 1s, 2s, ...
    static func backoff(forAttempt attempt: Int) -> Duration {
        .milliseconds(500 * (1 << (attempt - 1)))
    }

    /// HTTP status codes worth retrying: rate limiting (429) and server errors (5xx).
    static func isRetryable(statusCode: Int) -> Bool {
        statusCode == 429 || (500...599).contains(statusCode)
    }

    /// Network errors worth retrying: timeouts and connectivity blips.
    static func isRetryable(error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .cannotConnectToHost, .networkConnectionLost,
            .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost:
            return true
        default:
            return false
        }
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

    static func parseFrontmatter(_ content: String) -> (metadata: [String: String], body: String) {
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

    static func stripMarkdown(_ markdown: String) -> String {
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

        // Remove horizontal rules — must run before the bold/italic step below,
        // otherwise whole-line `***`/`___` rules get consumed by the emphasis
        // regexes and are never recognized as rules.
        text = text.replacingOccurrences(
            of: #"(?m)^[\-\*_]{3,}\s*$"#, with: "", options: .regularExpression)

        // Remove bold/italic
        text = text.replacingOccurrences(
            of: #"\*{1,3}(.+?)\*{1,3}"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"_{1,3}(.+?)_{1,3}"#, with: "$1", options: .regularExpression)

        // Remove blockquote markers
        text = text.replacingOccurrences(
            of: #"(?m)^>\s*"#, with: "", options: .regularExpression)

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
