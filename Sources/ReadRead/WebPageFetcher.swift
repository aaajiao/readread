import Foundation

/// A web address → `WebPage`, the way Settings says (`ExtractionMode`): on this Mac first
/// (`LocalExtractor`), through defuddle.md when that fails or is not installed, or reads only part
/// of the page (`LocalExtractorError.incomplete`, or fewer than `shortPage` characters to read,
/// perhaps a placeholder such as "Loading…"; the longer of the two is read then); or through
/// defuddle.md only. A page on the local network is only ever read on this Mac: defuddle.md cannot
/// reach it, and its address stays here (R3-06). Pages read before come from `ArticleCache`; a
/// page read only in part, or short, is not kept, so the next open reads it again.
struct WebPageFetcher: Sendable {
    /// Read at each fetch: a change in Settings applies to the next page.
    var mode: @Sendable () -> ExtractionMode
    /// Throws `LocalExtractorError.bundleMissing` when Defuddle is not installed.
    var local: @Sendable (URL) async throws -> WebPage
    var remote: @Sendable (URL) async throws -> WebPage
    var cache: ArticleCache?

    static func live() -> WebPageFetcher {
        WebPageFetcher(
            mode: { ExtractionMode.current() },
            local: { try await LocalExtractor.readLive($0) },
            remote: { try await WebExtractor.extractFromURL($0) },
            cache: .live())
    }

    /// Fewer characters to read than this: perhaps not the article yet.
    static let shortPage = 200

    func fetch(_ url: URL) async throws -> WebPage {
        let mode = self.mode()
        let localOnly = InputParser.isLocalNetwork(url)
        // In defuddle.md mode a page this Mac read is read again, by defuddle.md.
        if let entry = cache?.entry(for: url),
           localOnly || mode == .localFirst || entry.extractor == ArticleCache.Extractor.remote {
            return entry.page
        }
        let (page, extractor) = try await read(url, mode: mode, localOnly: localOnly)
        try Task.checkCancellation()
        if let extractor { cache?.store(page, for: url, extractor: extractor) }
        return page
    }

    /// The page and who read it, nil when it is not to be kept.
    private func read(_ url: URL, mode: ExtractionMode, localOnly: Bool) async throws -> (WebPage, String?) {
        if localOnly {
            do {
                let page = try await local(url)
                return (page, Self.isShort(page) ? nil : ArticleCache.Extractor.local)
            } catch LocalExtractorError.incomplete(let partial) {
                return (partial, nil)
            } catch LocalExtractorError.bundleMissing {
                throw DocumentError.localNetwork(url.host(percentEncoded: false) ?? url.absoluteString)
            }
        }
        if mode == .remoteOnly { return (try await remote(url), ArticleCache.Extractor.remote) }
        var partial: WebPage?
        var localError: (any Error)?
        do {
            let page = try await local(url)
            if !Self.isShort(page) { return (page, ArticleCache.Extractor.local) }
            partial = page
        } catch LocalExtractorError.incomplete(let page) {
            partial = page
        } catch LocalExtractorError.bundleMissing {
            return (try await remote(url), ArticleCache.Extractor.remote)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            localError = error
        }
        do {
            let page = try await remote(url)
            if let partial, partial.markdown.utf8.count > page.markdown.utf8.count { return (partial, nil) }
            return (page, ArticleCache.Extractor.remote)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let partial { return (partial, nil) }
            throw DocumentError.pageUnreadable(local: localError?.localizedDescription ?? "", remote: error.localizedDescription)
        }
    }

    /// Fewer than `shortPage` characters left once the page is cleaned for reading.
    static func isShort(_ page: WebPage) -> Bool {
        guard page.markdown.utf8.count < shortPage * 100 else { return false }
        let blocks = page.isPlainText ? PlainTextCleaner.blocks(page.markdown) : MarkdownCleaner.blocks(page.markdown)
        return blocks.reduce(0) { $0 + $1.text.count } < shortPage
    }
}
