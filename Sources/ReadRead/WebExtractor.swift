import Foundation

/// A web page as defuddle.md or the local reader (`LocalExtractor`) returns it: Markdown and the
/// metadata Defuddle found. Codable for the article cache.
struct WebPage: Sendable, Equatable, Codable {
    /// The page title without the site's suffix (" - Wikipedia"); nil when there is none.
    let title: String?
    let markdown: String
    /// The domain for the header (www. dropped).
    let domain: String
    /// Shown, never read; nil when the page names none.
    var author: String? = nil
    var site: String? = nil
    var published: String? = nil
    /// `markdown` is plain text (a text/plain page read on this Mac): the plain-text cleaner reads it.
    var isPlainText = false
}

/// A local file, decoded: text and Markdown as their `body`, the document formats (RTF, Word,
/// PDF, EPUB …) as cleaned `blocks` (see `DocumentReader`).
struct LocalFile: Sendable, Equatable {
    /// The frontmatter or document title, else the file name without its extension.
    let title: String
    /// False when `title` is only the file name (it is shown, not read aloud).
    let titleFromMetadata: Bool
    /// The file name with its extension, for the header.
    let fileName: String
    let body: String
    let isMarkdown: Bool
    /// The document's cleaned blocks; nil for text and Markdown, which the cleaners read from `body`.
    var blocks: [MarkdownCleaner.Block]? = nil
}

enum WebExtractorError: LocalizedError, Equatable {
    case invalidURL
    /// An HTTP status that came without a message.
    case fetchFailed(Int)
    /// defuddle.md answered with its error JSON (`{"error":"Timed out fetching page after 10s"}`).
    case service(String)
    /// The same with a status other than 200: the text is kept, not only the code (R3-07).
    case serviceStatus(Int, String)
    /// HTTP 429: defuddle.md's free quota is used up (never retried); its message if it sent one.
    case quotaExceeded(String?)
    case fileReadFailed(String)
    case fileTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "Invalid URL", table: "Content")
        case .fetchFailed(let code):
            return String(format: String(localized: "Failed to fetch content (HTTP %lld)", table: "Content"), code)
        case .service(let message):
            return String(format: String(localized: "defuddle.md could not extract the page: %@", table: "Content"), message)
        case .serviceStatus(let code, let message):
            return String(format: String(localized: "defuddle.md could not extract the page (HTTP %lld): %@", table: "Content"),
                          code, message)
        case .quotaExceeded(let message):
            let text = String(localized: "defuddle.md's free quota (1,000 pages a month) is used up; it reads pages again next month.",
                              table: "Content")
            guard let message, !message.isEmpty else { return text }
            return String(format: String(localized: "%@ (defuddle.md: %@)", table: "Content"), text, message)
        case .fileReadFailed(let reason):
            return String(format: String(localized: "Failed to read file: %@", table: "Content"), reason)
        case .fileTooLarge(let bytes):
            return String(format: String(localized: "The file is too large to read (%lld MB; the limit is %lld MB).", table: "Content"),
                          bytes / 1_000_000, WebExtractor.maxFileBytes / 1_000_000)
        }
    }
}

enum WebExtractor {

    /// Total number of fetch attempts before giving up (1 initial + retries).
    static let maxAttempts = 3
    /// One defuddle.md request, from the first byte sent to the last received (R3-07); its own
    /// fetch of the page gives up after 10 s.
    static let requestTimeout: TimeInterval = 30
    /// Larger files are refused rather than decoded and chunked on the spot.
    static let maxFileBytes = 32_000_000
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]

    /// No cookies and no disk cache (the article cache keeps pages), `requestTimeout` per request.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    /// Fetch a page through the Defuddle API: https://defuddle.md/{url without its scheme}.
    /// Cancelling the task cancels the request (and a backoff in between).
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
        func value(_ key: String) -> String? { split.metadata[key].flatMap { $0.isEmpty ? nil : $0 } }
        return WebPage(title: title, markdown: split.body, domain: displayDomain(domain),
                       author: value("author"), site: value("site"), published: value("published"))
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
    /// (see ``isRetryable(error:)`` / ``isRetryable(statusCode:attempt:)``); deterministic
    /// failures (4xx, 429 included, decode errors) throw immediately, with the text the service
    /// sent (see ``failure(status:body:)``).
    static func fetchWithRetry(
        from url: URL,
        maxAttempts: Int = WebExtractor.maxAttempts,
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        fetch: @Sendable (URL) async throws -> (Data, URLResponse) = {
            try await session.data(for: URLRequest(url: $0, timeoutInterval: requestTimeout))
        }
    ) async throws -> Data {
        var attempt = 1
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await fetch(url)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    if attempt < maxAttempts, isRetryable(statusCode: http.statusCode, attempt: attempt) {
                        try await sleep(backoff(forAttempt: attempt))
                        attempt += 1
                        continue
                    }
                    throw failure(status: http.statusCode, body: data)
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

    /// HTTP statuses worth another attempt after `attempt` (1-based) failed: 502 (defuddle.md
    /// could not fetch the page) once, other server errors (5xx) until `maxAttempts`. Never 429:
    /// the free quota is used up, and each retry would spend more of it.
    static func isRetryable(statusCode: Int, attempt: Int = 1) -> Bool {
        switch statusCode {
        case 502: attempt == 1
        case 500...599: true
        default: false
        }
    }

    /// The error for a final non-200 answer: 429 is the quota; otherwise the service's own text
    /// (its error JSON, or a short plain-text body) with the status, else the status alone.
    static func failure(status: Int, body: Data) -> WebExtractorError {
        let text = TextDecoding.sanitize(String(decoding: body.prefix(16 * 1024), as: UTF8.self))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var message = serviceError(text)
        if message == nil, !text.isEmpty, text.count <= 300, !text.hasPrefix("<"), !text.contains("\n") {
            message = text
        }
        if status == 429 { return .quotaExceeded(message) }
        if let message { return .serviceStatus(status, message) }
        return .fetchFailed(status)
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
