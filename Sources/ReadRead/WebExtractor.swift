import Foundation

/// A page as defuddle.md returns it, its frontmatter split off.
struct WebPage: Sendable, Equatable {
    /// The page title without the site's suffix (" - Wikipedia"); nil when there is none.
    let title: String?
    let markdown: String
    /// The domain for the header (www. dropped).
    let domain: String
}

/// A local text or Markdown file, decoded.
struct LocalFile: Sendable, Equatable {
    /// The frontmatter title, else the file name without its extension.
    let title: String
    /// False when `title` is only the file name (it is shown, not read aloud).
    let titleFromMetadata: Bool
    /// The file name with its extension, for the header.
    let fileName: String
    let body: String
    let isMarkdown: Bool
}

enum WebExtractorError: LocalizedError, Equatable {
    case invalidURL
    case fetchFailed(Int)
    /// defuddle.md answered with its error JSON (`{"error":"Timed out fetching page after 10s"}`).
    case service(String)
    case fileReadFailed(String)
    case fileTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .fetchFailed(let code): return "Failed to fetch content (HTTP \(code))"
        case .service(let message): return "defuddle.md could not extract the page: \(message)"
        case .fileReadFailed(let reason): return "Failed to read file: \(reason)"
        case .fileTooLarge(let bytes):
            return "The file is too large to read (\(bytes / 1_000_000) MB; the limit is \(WebExtractor.maxFileBytes / 1_000_000) MB)."
        }
    }
}

enum WebExtractor {

    /// Total number of fetch attempts before giving up (1 initial + retries).
    static let maxAttempts = 3
    /// Larger files are refused rather than decoded and chunked on the spot.
    static let maxFileBytes = 32_000_000
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]

    /// Fetch a page through the Defuddle API: https://defuddle.md/{url without its scheme}.
    static func extractFromURL(
        _ url: URL,
        fetch: @Sendable (URL) async throws -> Data = { try await fetchWithRetry(from: $0) }
    ) async throws -> WebPage {
        guard let defuddleURL = defuddleURL(for: url) else { throw WebExtractorError.invalidURL }
        let data = try await fetch(defuddleURL)
        try Task.checkCancellation()
        // defuddle.md always answers in UTF-8: no guessing (a stray control character would
        // otherwise make the legacy heuristics read the page as GB18030).
        let text = TextDecoding.sanitize(String(decoding: data, as: UTF8.self))
        if let message = serviceError(text) { throw WebExtractorError.service(message) }
        let split = Frontmatter.split(text)
        let site = split.metadata["site"] ?? ""
        let title = split.metadata["title"].map { stripSiteSuffix($0, site: site) }.flatMap { $0.isEmpty ? nil : $0 }
        let domain = split.metadata["domain"].flatMap { $0.isEmpty ? nil : $0 } ?? url.host() ?? ""
        return WebPage(title: title, markdown: split.body, domain: displayDomain(domain))
    }

    static func defuddleURL(for url: URL) -> URL? {
        var path = url.absoluteString
        for prefix in ["https://", "http://"] where path.lowercased().hasPrefix(prefix) {
            path = String(path.dropFirst(prefix.count))
            break
        }
        return URL(string: "https://defuddle.md/\(path)")
    }

    /// `{"error": "…"}` instead of Markdown.
    static func serviceError(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
              let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
              let error = object["error"] else { return nil }
        return (error as? String) ?? ((error as? [String: Any])?["message"] as? String) ?? "\(error)"
    }

    /// "Speech synthesis - Wikipedia" → "Speech synthesis" when the suffix names the site.
    static func stripSiteSuffix(_ title: String, site: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in [" - ", " | ", " – ", " — ", " :: ", " · ", "_"] {
            guard let range = trimmed.range(of: separator, options: .backwards) else { continue }
            let suffix = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
            let siteName = site.lowercased()
            let namesSite = !siteName.isEmpty && (suffix == siteName || suffix.contains(siteName) || siteName.contains(suffix))
            let isWiki = suffix.contains("wikipedia") || suffix.contains("维基百科") || suffix.contains("維基百科")
            let head = trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            if (namesSite || isWiki), !head.isEmpty, !suffix.isEmpty { return head }
        }
        return trimmed
    }

    static func displayDomain(_ domain: String) -> String {
        domain.lowercased().hasPrefix("www.") ? String(domain.dropFirst(4)) : domain
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

    // MARK: - Files

    /// Read a local text or Markdown file in any encoding `TextDecoding` knows (H10).
    static func readFile(_ url: URL) async throws -> LocalFile {
        let gotAccess = url.startAccessingSecurityScopedResource()
        defer {
            if gotAccess { url.stopAccessingSecurityScopedResource() }
        }
        let data: Data
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if size > maxFileBytes { throw WebExtractorError.fileTooLarge(size) }
            data = try Data(contentsOf: url)
        } catch let error as WebExtractorError {
            throw error
        } catch {
            throw WebExtractorError.fileReadFailed(error.localizedDescription)
        }
        try Task.checkCancellation()
        let text = try TextDecoding.decode(data).text
        let fileName = url.lastPathComponent
        let baseName = url.deletingPathExtension().lastPathComponent
        guard markdownExtensions.contains(url.pathExtension.lowercased()) else {
            return LocalFile(title: baseName, titleFromMetadata: false, fileName: fileName, body: text, isMarkdown: false)
        }
        let split = Frontmatter.split(text)
        let title = split.metadata["title"].flatMap { $0.isEmpty ? nil : $0 }
        return LocalFile(title: title ?? baseName, titleFromMetadata: title != nil, fileName: fileName,
                         body: split.body, isMarkdown: true)
    }
}
