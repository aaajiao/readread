import Foundation

/// What the user asked to read.
enum ReadingInput: Sendable, Equatable {
    case url(URL)
    case file(URL)
    /// Text to read as it is (pasted prose, never sent anywhere).
    case text(String)
}

/// The URL field accepts URLs, share text with a link in it, file paths and plain text
/// (R3-06, R4-06). Only something that is clearly a web address goes to defuddle.md;
/// anything else is read directly.
enum InputParser {
    /// Share text ("【标题】 https://… 复制链接打开") counts as a link when this little else is in it.
    static let maximumShareTextAround = 140

    static func parse(
        _ raw: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> ReadingInput? {
        var input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        let singleLine = !input.contains(where: \.isNewline)
        if singleLine { input = unwrap(input) }

        if input.lowercased().hasPrefix("file://") {
            if let url = URL(string: input), url.isFileURL { return .file(url) }
            return .text(input)
        }
        if singleLine, let path = localPath(input), fileExists(path) {
            return .file(URL(fileURLWithPath: path))
        }
        if !input.contains(where: \.isWhitespace) {
            if let url = webURL(input) { return .url(url) }
            // Share text without a space: "原文链接：https://…".
            if input.range(of: "http", options: .caseInsensitive) != nil, let url = shareLink(in: input) { return .url(url) }
            return .text(input)
        }
        if let url = shareLink(in: input) { return .url(url) }
        return .text(input)
    }

    /// <…>, "…", '…' and Terminal-style escaped spaces around a dragged URL or path.
    static func unwrap(_ input: String) -> String {
        var text = input
        for (open, close) in [("<", ">"), ("\"", "\""), ("'", "'"), ("“", "”")] where text.count >= 2 {
            if text.hasPrefix(open), text.hasSuffix(close) {
                text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            }
        }
        return text
    }

    /// An absolute or ~ path; Terminal escapes (`My\ File.md`) are undone.
    static func localPath(_ input: String) -> String? {
        guard input.hasPrefix("/") || input.hasPrefix("~/") || input == "~" else { return nil }
        let unescaped = input.replacingOccurrences(of: "\\ ", with: " ")
        return (unescaped as NSString).expandingTildeInPath
    }

    /// One token that is a web address: http(s)://…, or a bare host (example.com/path,
    /// localhost:8080, 192.168.1.10/wiki) which gets https (http for local addresses).
    static func webURL(_ token: String) -> URL? {
        let lower = token.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: token), let host = url.host(), !host.isEmpty else { return nil }
            return url
        }
        if lower.contains("://") || lower.hasPrefix("mailto:") { return nil }
        let hostPart = String(token.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        guard isHostLike(hostPart), hasWebSuffix(hostPart, hasPath: hostPart.count < token.count) else { return nil }
        let scheme = isLocalHost(hostPart.split(separator: ":").first.map(String.init) ?? hostPart) ? "http" : "https"
        guard let url = URL(string: "\(scheme)://\(token)"), let host = url.host(), !host.isEmpty else { return nil }
        return url
    }

    /// example.com, zh.wikipedia.org, 例子.中国, localhost, 192.168.1.10, each with an optional port.
    static func isHostLike(_ host: String) -> Bool {
        let pattern = #"^(?:localhost|(?:\d{1,3}\.){3}\d{1,3}|(?:[\p{L}\p{N}](?:[\p{L}\p{N}-]{0,62}[\p{L}\p{N}])?\.)+(?:\p{L}{2,63}|xn--[a-z0-9-]{1,59}))(?::\d{1,5})?$"#
        return host.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Top-level domains a host typed without a scheme may end in: any two-letter ASCII one
    /// (country codes), these, xn--, and the Chinese ones below. Everything else with a dot
    /// ("今天天气很好.明天也好", notes.txt) is text, never sent to defuddle.md (R3-06).
    static let genericTLDs: Set<String> = [
        "com", "net", "org", "edu", "gov", "mil", "int", "info", "biz", "name", "pro", "mobi", "asia", "tel", "travel",
        "jobs", "museum", "aero", "coop", "cat", "post", "app", "dev", "page", "blog", "news", "wiki", "xyz", "top",
        "site", "online", "tech", "store", "shop", "cloud", "club", "live", "life", "space", "website", "link", "one",
        "art", "design", "studio", "agency", "media", "group", "today", "world", "network", "email", "games", "game",
        "fun", "ltd", "vip", "work", "works", "xin", "wang", "ink", "red", "kim", "moe", "icu", "fyi", "guru", "tools",
        "zone", "team", "social", "video", "tube", "photo", "photos", "pics", "press", "pub", "rocks", "run", "science",
        "software", "solutions", "systems", "technology", "academy", "center", "city", "codes", "company", "cool",
        "digital", "education", "expert", "finance", "global", "guide", "help", "host", "law", "money", "ninja", "plus",
        "services", "show", "style", "chat", "cafe", "camp", "bio", "best", "click", "energy", "careers",
    ]
    static let chineseTLDs: Set<String> = [
        "中国", "中國", "公司", "网络", "網絡", "香港", "台湾", "台灣", "澳门", "澳門", "新加坡", "在线", "中文网", "网址",
        "网站", "商城", "集团", "手机", "移动", "网店", "信息", "我爱你", "政务", "公益",
    ]
    /// Country codes that are also file extensions: README.md and run.sh are text unless a
    /// path follows (example.md/docs).
    static let fileExtensionTLDs: Set<String> = ["md", "sh", "py", "rs", "pl", "so", "ps", "mk", "ml", "cc", "mm"]

    /// Whether `host` (with an optional port) ends in a top-level domain from the lists above.
    /// Without a path, a capital in it ("Mr.Li", "ASP.NET") makes it a word, not a host.
    static func hasWebSuffix(_ host: String, hasPath: Bool) -> Bool {
        let parts = host.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts.first ?? "")
        if parts.count == 2 { return true }  // a port: localhost:8080, box.example:3000
        if name.lowercased() == "localhost" || name.range(of: #"^(?:\d{1,3}\.){3}\d{1,3}$"#, options: .regularExpression) != nil {
            return true
        }
        guard name.contains("."), let tld = name.split(separator: ".").last.map(String.init) else { return false }
        let lower = tld.lowercased()
        if lower.hasPrefix("xn--") { return true }
        guard tld.unicodeScalars.allSatisfy(\.isASCII) else { return chineseTLDs.contains(tld) }
        if !hasPath, tld != lower || fileExtensionTLDs.contains(lower) { return false }
        return lower.count == 2 || genericTLDs.contains(lower)
    }

    /// The first http(s) link in share text, when the text around it is short. Text glued to
    /// its end ("…rsync.html复制链接打开", "…/AbC，复制本条信息") is not part of it.
    static func shareLink(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let source = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
            let matched = source.substring(with: match.range)
            guard matched.lowercased().hasPrefix("http") else { continue }
            let link = trimShareGlue(matched)
            guard source.length - (link as NSString).length <= maximumShareTextAround else { return nil }
            if link == matched { return url }
            guard let trimmed = URL(string: link), let host = trimmed.host(), !host.isEmpty else { return nil }
            return trimmed
        }
        return nil
    }

    /// `link` up to CJK punctuation, or up to a non-ASCII character right after an ASCII
    /// letter or digit (a Chinese path segment after a slash stays: /wiki/语音合成).
    static func trimShareGlue(_ link: String) -> String {
        var previous: Character?
        for (offset, character) in link.enumerated() {
            let scalar = character.unicodeScalars.first!.value
            let cjkPunctuation = (0x3000...0x303F).contains(scalar) || (0xFF00...0xFFEF).contains(scalar)
            let glued = !character.isASCII && (previous.map { $0.isASCII && ($0.isLetter || $0.isNumber) } ?? false)
            if cjkPunctuation || glued { return String(link.prefix(offset)) }
            previous = character
        }
        return link
    }

    /// Hosts defuddle.md cannot reach: localhost, *.local, *.lan, *.internal, *.home.arpa,
    /// private and link-local addresses, and single-label intranet names.
    static func isLocalNetwork(_ url: URL) -> Bool {
        guard let rawHost = url.host(percentEncoded: false)?.lowercased(), !rawHost.isEmpty else { return false }
        let host = rawHost.hasPrefix("[") ? String(rawHost.dropFirst().dropLast()) : rawHost
        return isLocalHost(host)
    }

    static func isLocalHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        for suffix in [".local", ".lan", ".internal", ".intranet", ".home.arpa", ".corp", ".home"] where host.hasSuffix(suffix) {
            return true
        }
        if host.contains(":") {  // IPv6
            return host == "::1" || host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80")
        }
        let octets = host.split(separator: ".").map { Int($0) }
        if octets.count == 4, octets.allSatisfy({ $0 != nil && (0...255).contains($0!) }) {
            let a = octets[0]!, b = octets[1]!
            return a == 10 || a == 127 || a == 0 || (a == 172 && (16...31).contains(b))
                || (a == 192 && b == 168) || (a == 169 && b == 254) || (a == 100 && (64...127).contains(b))
        }
        return !host.contains(".")
    }
}
