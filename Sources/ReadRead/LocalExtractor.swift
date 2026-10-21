import CryptoKit
import Foundation
import WebKit

/// Why a page could not be read on this Mac.
enum LocalExtractorError: LocalizedError, Equatable {
    /// The Defuddle build is not installed (setup.sh installs it; the app has it in its Resources).
    case bundleMissing
    case loadFailed(String)
    /// The page's own server answered with an error.
    case httpStatus(Int)
    /// The link leads to something else than a web page (its MIME type).
    case notAPage(String)
    case unsupportedAddress(String)
    /// Nothing loaded within the hard limit.
    case timedOut
    case tooManyRedirects
    case webContentTerminated
    case tooLarge
    /// Defuddle found no content.
    case noContent
    case scriptFailed(String)
    /// The page's HTML was still arriving at the hard limit: what came of it, to read but not to keep.
    case incomplete(WebPage)

    var errorDescription: String? {
        switch self {
        case .bundleMissing:
            return String(localized: "ReadRead's page reader (Defuddle) is not installed: run ./scripts/setup.sh, or use the app build-app.sh builds.",
                          table: "Content")
        case .loadFailed(let reason):
            return String(format: String(localized: "The page could not be loaded: %@", table: "Content"), reason)
        case .httpStatus(let code):
            return String(format: String(localized: "The page's server answered HTTP %lld.", table: "Content"), code)
        case .notAPage(let type):
            return String(format: String(localized: "This link is not a web page (%@). Download the file and open it in ReadRead.",
                                         table: "Content"), type.isEmpty ? "?" : type)
        case .unsupportedAddress(let address):
            return String(format: String(localized: "ReadRead does not open this kind of address: %@", table: "Content"), address)
        case .timedOut:
            return String(localized: "The page did not load within 15 seconds.", table: "Content")
        case .tooManyRedirects:
            return String(localized: "The page redirected too many times.", table: "Content")
        case .webContentTerminated:
            return String(localized: "The web view reading the page stopped unexpectedly.", table: "Content")
        case .tooLarge:
            return String(localized: "The page is too large to read.", table: "Content")
        case .noContent:
            return String(localized: "Defuddle found nothing to read on the page.", table: "Content")
        case .scriptFailed(let reason):
            return String(format: String(localized: "Defuddle could not read the page: %@", table: "Content"), reason)
        case .incomplete:
            return String(localized: "The page was still loading after 15 seconds: only its first part was read.", table: "Content")
        }
    }
}

/// Reads a page on this Mac (R3-06, R3-13): an offscreen `WKWebView` (never in a window) with a
/// non-persistent data store loads it, waits until the network is quiet (hard limit 15 s), then
/// the bundled Defuddle (`DefuddleBundle`) turns the document into Markdown in an isolated
/// JavaScript world, which the page's own scripts cannot see (within `scriptLimit`, 10 s more at
/// most). No popups, downloads, autoplay, Web Speech or frames from the network; images, media,
/// fonts and pings are not loaded. A web page sees a visible document that gets animation frames,
/// as in a browser tab. A local .html file loads nothing from the network and its scripts do not
/// run; one without a charset is decoded by `TextDecoding` first. HTML still arriving at the hard
/// limit is read but thrown as `.incomplete`. Each read gets its own web view and content
/// process, which ends with the read. Cancelling the task stops the load.
@MainActor
enum LocalExtractor {
    struct Options: Sendable {
        /// From the start of the load to the extraction, whatever the page still does.
        var hardLimit: Duration = .seconds(15)
        /// No new resource and no new element for this long: the network is idle.
        var quietPeriod: Duration = .milliseconds(600)
        /// Longest wait for quiet after the load event.
        var settleLimit: Duration = .seconds(4)
        /// Without a load event (a resource that never ends): read a quiet document after this.
        var stalledLoadLimit: Duration = .seconds(5)
        var pollInterval: Duration = .milliseconds(150)
        /// Injecting Defuddle and running it.
        var scriptLimit: Duration = .seconds(10)
        /// Main-frame navigations (redirects included) one read follows.
        var maximumNavigations = 8
        /// Larger documents are not handed to Defuddle.
        var maximumElements = 300_000
        /// The Markdown is cut (at a paragraph) beyond this.
        var maximumCharacters = 3_000_000
        /// A main resource announced as larger than this is not loaded.
        var maximumDocumentBytes: Int64 = 64_000_000
        /// Where WebKit compiles the content rules; nil = no rules (then a local file is not read).
        var rulesDirectory: URL?
        /// A web page may load only from these hosts (not their subdomains), every other load is
        /// blocked: the live test. nil (the app) = any host.
        var allowedHosts: [String]?
    }

    /// `<cache>/webkit-rules` for the compiled content rules.
    nonisolated static func liveOptions(
        environment: [String: String] = ProcessInfo.processInfo.environment, homeDirectory: String = NSHomeDirectory()
    ) -> Options {
        let cache = RuntimeDirectories(environment: environment, homeDirectory: homeDirectory).cacheDirectory
        return Options(rulesDirectory: URL(fileURLWithPath: cache, isDirectory: true).appending(path: "webkit-rules"))
    }

    /// The page at an http or https `url`, with the installed Defuddle.
    nonisolated static func readLive(_ url: URL) async throws -> WebPage {
        guard let script = DefuddleBundle.live() else { throw LocalExtractorError.bundleMissing }
        return try await read(url, script: script, options: liveOptions())
    }

    /// A local .html file with the installed Defuddle.
    nonisolated static func readLive(fileURL: URL) async throws -> WebPage {
        guard let script = DefuddleBundle.live() else { throw LocalExtractorError.bundleMissing }
        return try await read(fileURL: fileURL, script: script, options: liveOptions())
    }

    static func read(_ url: URL, script: String, options: Options) async throws -> WebPage {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw LocalExtractorError.unsupportedAddress(url.absoluteString)
        }
        var rules = [await contentRules(.web, directory: options.rulesDirectory)].compactMap { $0 }
        if let hosts = options.allowedHosts {
            guard let allowed = await hostRules(hosts, directory: options.rulesDirectory) else {
                throw LocalExtractorError.loadFailed(String(localized: "WebKit content rules are unavailable", table: "Content"))
            }
            rules.append(allowed)
        }
        let session = PageSession(kind: .web, script: script, options: options, rules: rules)
        return try await session.run(source: url) { webView in
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                    timeoutInterval: Double(options.hardLimit.components.seconds)))
        }
    }

    /// The file's directory is readable (its images and style sheets), nothing else is. A file
    /// WebKit would misread (`undeclaredText`) is loaded as its decoded text, at its own address.
    static func read(fileURL: URL, script: String, options: Options) async throws -> WebPage {
        let directory = fileURL.deletingLastPathComponent()
        guard let rules = await contentRules(.local, directory: options.rulesDirectory) else {
            throw LocalExtractorError.loadFailed(String(localized: "WebKit content rules are unavailable", table: "Content"))
        }
        let text = try await decodedIfUndeclared(fileURL)
        try Task.checkCancellation()
        let session = PageSession(kind: .file(directory: directory.standardizedFileURL), script: script, options: options,
                                  rules: [rules])
        return try await session.run(source: fileURL) { webView in
            if let text {
                webView.load(Data(text.utf8), mimeType: "text/html", characterEncodingName: "utf-8", baseURL: fileURL)
            } else {
                webView.loadFileURL(fileURL, allowingReadAccessTo: directory)
            }
        }
    }

    /// The file read and checked off the main actor (it may be 32 MB); a file that cannot be read
    /// is left to WebKit, which says why.
    @concurrent
    nonisolated static func decodedIfUndeclared(_ fileURL: URL) async throws -> String? {
        let xml = ["xhtml", "xht"].contains(fileURL.pathExtension.lowercased())
        guard !xml, let data = try? Data(contentsOf: fileURL) else { return nil }  // XML is UTF-8 unless it says otherwise
        return try undeclaredText(of: data)
    }

    /// An HTML file's text when WebKit would misread its bytes: without a byte order mark, a
    /// `<meta>` charset or an XML declaration's encoding in its first 1,024 bytes (where browsers
    /// look), bytes beyond ASCII are read as Latin-1, so a Chinese page saved without its HTTP
    /// header becomes mojibake. `TextDecoding` reads such a file instead (and refuses Korean and
    /// Japanese as for a text file). nil: WebKit reads the file as it is.
    nonisolated static func undeclaredText(of data: Data) throws -> String? {
        guard data.contains(where: { $0 >= 0x80 || $0 == 0 }) else { return nil }
        let head = data.prefix(1_024)
        if head.starts(with: [0xEF, 0xBB, 0xBF]) || head.starts(with: [0xFE, 0xFF]) || head.starts(with: [0xFF, 0xFE]) { return nil }
        let markup = String(decoding: head, as: UTF8.self).lowercased()
        if markup.hasPrefix("<?xml"), let end = markup.range(of: "?>"),
           markup[..<end.lowerBound].contains("encoding") {
            return nil  // WebKit honours it in HTML too
        }
        var rest = markup[...]
        while let meta = rest.range(of: "<meta") {
            let tag = rest[meta.upperBound...].prefix { $0 != ">" }
            if tag.contains("charset") { return nil }
            rest = rest[tag.endIndex...]
        }
        return try TextDecoding.decode(data).text
    }

    /// HTML in memory, without network or page scripts (the self test).
    static func read(html: String, script: String, options: Options) async throws -> WebPage {
        let rules = await contentRules(.local, directory: options.rulesDirectory)
        let session = PageSession(kind: .html, script: script, options: options, rules: [rules].compactMap { $0 })
        return try await session.run(source: nil) { webView in
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    // MARK: - Content rules

    enum RuleSet: String {
        case web = "readread-web-1"
        case local = "readread-local-1"
    }

    static let blockedResources = #"{"trigger":{"url-filter":".*","resource-type":["image","media","font","svg-document","ping","popup"]},"action":{"type":"block"}}"#
    static let rulesJSON: [RuleSet: String] = [
        .web: "[\(blockedResources)]",
        .local: "[\(blockedResources),"
            + #"{"trigger":{"url-filter":"^https?:"},"action":{"type":"block"}},"#
            + #"{"trigger":{"url-filter":"^wss?:"},"action":{"type":"block"}},"#
            + #"{"trigger":{"url-filter":"^ftp:"},"action":{"type":"block"}}]"#,
    ]

    private static var compiled: [RuleSet: WKContentRuleList] = [:]

    /// Compiled once per process into `directory`; nil when there is none or WebKit refuses.
    static func contentRules(_ set: RuleSet, directory: URL?) async -> WKContentRuleList? {
        if let list = compiled[set] { return list }
        guard let directory, let json = rulesJSON[set] else { return nil }
        let list = await compile(json, identifier: set.rawValue, directory: directory)
        if let list { compiled[set] = list }
        return list
    }

    /// Everything blocked but loads from `hosts` (`Options.allowedHosts`).
    static func hostRules(_ hosts: [String], directory: URL?) async -> WKContentRuleList? {
        guard let directory else { return nil }
        var rules: [[String: Any]] = [["trigger": ["url-filter": ".*"], "action": ["type": "block"]]]
        for host in hosts {
            let pattern = "^https?://" + NSRegularExpression.escapedPattern(for: host.lowercased()) + "[:/]"
            rules.append(["trigger": ["url-filter": pattern], "action": ["type": "ignore-previous-rules"]])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        let identifier = "readread-hosts-" + SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        return await compile(String(decoding: data, as: UTF8.self), identifier: identifier, directory: directory)
    }

    private static func compile(_ json: String, identifier: String, directory: URL) async -> WKContentRuleList? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let store = WKContentRuleListStore(url: directory) else { return nil }
        return await withCheckedContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    // MARK: - Scripts

    /// At document start, in the isolated world: count resource loads (the resource timing
    /// buffer stops at 250 entries, an observer does not).
    static let observerScript = """
        (() => {
          let count = 0;
          Object.defineProperty(globalThis, '__readreadResources', { get: () => count, configurable: true });
          try {
            new PerformanceObserver(list => { count += list.getEntries().length; })
              .observe({ type: 'resource', buffered: true });
          } catch (e) { count = -1; }
        })();
        """

    /// At document start, in the page's own world and frames (web pages: their scripts run): what
    /// a page in a browser tab sees. A web view in no window is "hidden" and draws no frames, so a
    /// page that waits to be visible or renders in `requestAnimationFrame` would show only its
    /// placeholder ("Loading…"); its frames become 16 ms timers. Web Speech does nothing: a page
    /// must not speak over ReadRead while it is read.
    static let pageWorldScript = """
        (() => {
          try {
            Object.defineProperty(Document.prototype, 'visibilityState', { get: () => 'visible', configurable: true });
            Object.defineProperty(Document.prototype, 'hidden', { get: () => false, configurable: true });
          } catch (e) {}
          const frames = new Map();
          let last = 0;
          window.requestAnimationFrame = callback => {
            const id = ++last;
            frames.set(id, setTimeout(() => { frames.delete(id); callback(performance.now()); }, 16));
            return id;
          };
          window.cancelAnimationFrame = id => { clearTimeout(frames.get(id)); frames.delete(id); };
          try {
            if (typeof SpeechSynthesis === 'function') SpeechSynthesis.prototype.speak = function () {};
          } catch (e) {}
        })();
        """

    /// What changes while a page is still loading: its state, its resources, its elements.
    static let probeScript = """
        JSON.stringify([document.readyState, globalThis.__readreadResources ?? -1,
          performance.getEntriesByType('resource').length, document.getElementsByTagName('*').length])
        """

    /// The Defuddle call, after the full bundle (`dist/index.full.js` of the pinned npm package:
    /// Markdown conversion and math included) was evaluated in the same isolated world, where it
    /// defines the global `Defuddle` class:
    /// `new Defuddle(document, { url: location.href, markdown: true, useAsync: false }).parse()`.
    /// `url` resolves the page's relative links, `markdown` makes `content` Markdown (what
    /// defuddle.md returns too), `useAsync: false` keeps Defuddle from asking third-party APIs
    /// for content (its README: only `parseAsync()` does, for pages without usable HTML).
    /// From the response (title, author, site, published, domain, content, …) the script returns
    /// those six as a JSON string, `content` cut at a paragraph past `maximumCharacters`, or
    /// `{error}`: "tooLarge" over `maximumElements`, else the exception's message.
    static func extractScript(_ options: Options) -> String {
        """
        (() => {
          try {
            if (typeof Defuddle !== 'function') return JSON.stringify({ error: 'Defuddle did not load' });
            if (document.getElementsByTagName('*').length > \(options.maximumElements)) return JSON.stringify({ error: 'tooLarge' });
            const r = new Defuddle(document, { url: location.href, markdown: true, useAsync: false }).parse();
            const s = v => typeof v === 'string' ? v : '';
            let content = s(r.content);
            const max = \(options.maximumCharacters);
            if (content.length > max) {
              const cut = content.lastIndexOf('\\n\\n', max);
              content = content.slice(0, cut > max / 2 ? cut : max);
            }
            return JSON.stringify({ title: s(r.title), site: s(r.site), author: s(r.author),
              published: s(r.published), domain: s(r.domain), content });
          } catch (e) {
            return JSON.stringify({ error: String((e && e.message) || e) });
          }
        })()
        """
    }

    static func plainTextScript(_ options: Options) -> String {
        """
        (() => {
          const t = document.body ? document.body.textContent : '';
          return JSON.stringify({ plain: true, content: t.length > \(options.maximumCharacters) ? t.slice(0, \(options.maximumCharacters)) : t });
        })()
        """
    }

    /// The safari-like user agent suffix: some sites serve a reduced page to unknown browsers.
    nonisolated static var applicationName: String {
        "Version/\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).0 Safari/605.1.15"
    }
}

/// What the extraction script returns.
private struct Extracted: Decodable {
    var error: String?
    var title: String?
    var site: String?
    var author: String?
    var published: String?
    var domain: String?
    var content: String?
    var plain: Bool?
}

/// One page in one web view; `run` loads, waits, extracts and closes it.
@MainActor
private final class PageSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    enum Kind: Equatable {
        case web
        case file(directory: URL)
        case html
    }

    static let world = WKContentWorld.world(name: "ReadRead")
    static let pageTypes: Set<String> = ["text/html", "application/xhtml+xml", "text/plain"]

    let kind: Kind
    let script: String
    let options: LocalExtractor.Options
    let webView: WKWebView

    private var committed = false
    private var finishedAt: ContinuousClock.Instant?
    private var failure: LocalExtractorError?
    private var mimeType: String?
    private var mainFrameNavigations = 0

    init(kind: Kind, script: String, options: LocalExtractor.Options, rules: [WKContentRuleList]) {
        self.kind = kind
        self.script = script
        self.options = options
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        // Detached from any window it would be suspended once idle, its scripts paused.
        configuration.preferences.inactiveSchedulingPolicy = WKPreferences.InactiveSchedulingPolicy.none
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.applicationNameForUserAgent = LocalExtractor.applicationName
        // A local file's or the self test's own scripts never run; Defuddle (injected) does.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = kind == .web
        for list in rules { configuration.userContentController.add(list) }
        configuration.userContentController.addUserScript(WKUserScript(
            source: LocalExtractor.observerScript, injectionTime: .atDocumentStart, forMainFrameOnly: true,
            in: Self.world))
        if kind == .web {
            configuration.userContentController.addUserScript(WKUserScript(
                source: LocalExtractor.pageWorldScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 2000), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// Start the load, wait for the document to settle (the hard limit bounds the wait, probes
    /// included), extract it; the web view is closed after.
    func run(source: URL?, start: (WKWebView) -> Void) async throws -> WebPage {
        defer { close() }
        let began = ContinuousClock.now
        let deadline = began + options.hardLimit
        start(webView)
        var signature = ""
        var changedAt = began
        var cutOff = false
        while true {
            try await Task.sleep(for: options.pollInterval)
            if let failure { throw failure }
            let now = ContinuousClock.now
            guard committed else {
                if now >= deadline { throw LocalExtractorError.timedOut }
                continue
            }
            if now >= deadline {
                cutOff = signature.contains("\"loading\"")  // its HTML is still arriving
                break
            }
            if let probe = try? await evaluate(LocalExtractor.probeScript, limit: min(.seconds(2), deadline - now),
                                               onTimeout: .timedOut),
               probe != signature {
                signature = probe
                changedAt = .now
            }
            try Task.checkCancellation()
            if let failure { throw failure }
            let quiet = ContinuousClock.now - changedAt
            if let finishedAt {
                if quiet >= options.quietPeriod || now - finishedAt >= options.settleLimit { break }
            } else if !signature.contains("\"loading\""), quiet >= options.quietPeriod * 3,
                      now - began >= options.stalledLoadLimit {
                break  // the load event waits for something slow; the document is there
            }
        }
        let page = try await extract(source: source)
        if cutOff { throw LocalExtractorError.incomplete(page) }
        return page
    }

    /// Injecting Defuddle and running it share one `scriptLimit`.
    private func extract(source: URL?) async throws -> WebPage {
        let plain = mimeType == "text/plain"
        let slow = LocalExtractorError.scriptFailed(
            String(format: String(localized: "it took longer than %lld seconds", table: "Content"),
                   options.scriptLimit.components.seconds))
        let deadline = ContinuousClock.now + options.scriptLimit
        if !plain {
            _ = try await evaluate(script + "\n;0", limit: options.scriptLimit, onTimeout: slow)
        }
        let call = plain ? LocalExtractor.plainTextScript(options) : LocalExtractor.extractScript(options)
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero else { throw slow }
        guard let json = try await evaluate(call, limit: remaining, onTimeout: slow),
              let result = try? JSONDecoder().decode(Extracted.self, from: Data(json.utf8))
        else { throw LocalExtractorError.scriptFailed(String(localized: "it returned no result", table: "Content")) }
        if let error = result.error {
            throw error == "tooLarge" ? LocalExtractorError.tooLarge : LocalExtractorError.scriptFailed(error)
        }
        let content = TextDecoding.sanitize(result.content ?? "")
        guard MarkdownCleaner.Inline.isSpeakable(content) else { throw LocalExtractorError.noContent }
        func value(_ text: String?) -> String? {
            let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let site = value(result.site)
        let title = value(result.title).map { WebExtractor.stripSiteSuffix($0, site: site ?? "") }.flatMap(value)
        let domain = value(result.domain) ?? source?.host(percentEncoded: false) ?? ""
        return WebPage(title: title, markdown: content, domain: WebExtractor.displayDomain(domain),
                       author: value(result.author), site: site, published: value(result.published),
                       isPlainText: result.plain == true)
    }

    /// The web view stops and its content process ends: nothing else interrupts a page script
    /// that never returns, which would keep a core busy until ReadRead quits. WebKit has no public
    /// call for it; its own `_killWebContentProcessAndResetState` is used where it exists (on
    /// macOS 27 `_killWebContentProcess` leaves the process running). The process is this read's
    /// alone: each read has its own data store, and each data store its own content process.
    private func close() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeAllUserScripts()
        webView.configuration.userContentController.removeAllContentRuleLists()
        let kill = NSSelectorFromString("_killWebContentProcessAndResetState")
        if webView.responds(to: kill) { _ = webView.perform(kill) }
    }

    /// The script's string result (nil for another type), or `onTimeout` after `limit`.
    private func evaluate(_ source: String, limit: Duration, onTimeout: LocalExtractorError) async throws -> String? {
        let waiter = ScriptWaiter()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, any Error>) in
                waiter.continuation = continuation
                waiter.timer = Task { @MainActor [weak waiter] in
                    try? await Task.sleep(for: limit)
                    waiter?.finish(.failure(onTimeout))
                }
                webView.evaluateJavaScript(source, in: nil, in: Self.world) { result in
                    waiter.finish(result.map { $0 as? String })
                }
            }
        } onCancel: {
            Task { @MainActor in waiter.finish(.failure(CancellationError())) }
        }
    }

    // MARK: - Navigation

    /// Fail the read, unless a document is already there (a later redirect is just not followed).
    private func refuse(_ error: LocalExtractorError) {
        if !committed, failure == nil { failure = error }
    }

    private func allowsMainFrame(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" { return true }
        switch kind {
        case .web:
            return scheme == "http" || scheme == "https"
        case .file(let directory):
            guard url.isFileURL else { return false }
            let path = url.standardizedFileURL.path(percentEncoded: false)
            let root = directory.path(percentEncoded: false)
            return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        case .html:
            return false
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, !navigationAction.shouldPerformDownload,
              let frame = navigationAction.targetFrame  // nil: a new window
        else { return .cancel }
        guard frame.isMainFrame else {
            // Frames (ads, embeds) only from about:, data: or blob:, never from the network.
            return ["about", "data", "blob"].contains(url.scheme?.lowercased() ?? "") ? .allow : .cancel
        }
        mainFrameNavigations += 1
        if mainFrameNavigations > options.maximumNavigations {
            refuse(.tooManyRedirects)
            return .cancel
        }
        guard allowsMainFrame(url) else {
            refuse(.unsupportedAddress(url.absoluteString))
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard navigationResponse.isForMainFrame else { return .allow }
        let response = navigationResponse.response
        let type = response.mimeType?.lowercased() ?? ""
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            refuse(.httpStatus(http.statusCode))
            return .cancel
        }
        if response.expectedContentLength > options.maximumDocumentBytes {
            refuse(.tooLarge)
            return .cancel
        }
        guard Self.pageTypes.contains(type), navigationResponse.canShowMIMEType else {
            refuse(.notAPage(type))
            return .cancel
        }
        mimeType = type
        return .allow
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        committed = true
        finishedAt = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if committed { finishedAt = .now }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        // After the commit: the document is there, partly loaded; read what it holds.
        if committed, finishedAt == nil { finishedAt = .now }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        let nsError = error as NSError
        let cancelled = (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
            || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102)  // frame load interrupted by a policy change
        // A cancelled load was refused above (failure set) or replaced by the next navigation.
        if !cancelled { refuse(.loadFailed(error.localizedDescription)) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failure = .webContentTerminated
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }
}

/// One script result or the timeout, whichever comes first; cancellation ends it too.
@MainActor
private final class ScriptWaiter {
    var continuation: CheckedContinuation<String?, any Error>?
    var timer: Task<Void, Never>?

    func finish(_ result: Result<String?, any Error>) {
        timer?.cancel()
        timer = nil
        continuation?.resume(with: result)
        continuation = nil
    }
}
