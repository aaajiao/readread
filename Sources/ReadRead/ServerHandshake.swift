import Foundation

/// The server's single stdout line once it is serving:
/// `READY {"port":<int>,"pid":<int>,"api":2,"loaded":["zh"],"engine":"kokoro"}`; the Qwen
/// server adds `"model":"1.7b"`. A server older than the engine field sends neither.
struct ReadyInfo: Codable, Equatable, Sendable {
    let port: Int
    let pid: Int
    let api: Int
    let loaded: [String]
    /// "kokoro" or "qwen".
    let engine: String?
    /// The Qwen model ("1.7b"); nil for Kokoro.
    let model: String?

    private enum CodingKeys: String, CodingKey { case port, pid, api, loaded, engine, model }

    init(port: Int, pid: Int, api: Int, loaded: [String], engine: String? = nil, model: String? = nil) {
        self.port = port
        self.pid = pid
        self.api = api
        self.loaded = loaded
        self.engine = engine
        self.model = model
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        port = try c.decode(Int.self, forKey: .port)
        pid = try c.decode(Int.self, forKey: .pid)
        api = try c.decode(Int.self, forKey: .api)
        loaded = try c.decodeIfPresent([String].self, forKey: .loaded) ?? []
        engine = try c.decodeIfPresent(String.self, forKey: .engine)
        model = try c.decodeIfPresent(String.self, forKey: .model)
    }
}

/// Parses the stdout handshake: `READY {…}` on success, `FATAL {"message":…}`
/// on a startup failure. Anything else is junk and is ignored.
enum ServerHandshake {
    static let supportedAPI = 2

    enum Message: Equatable {
        case ready(ReadyInfo)
        case fatal(String)
        /// A READY line we can't use (bad JSON, bad port, wrong API version).
        case invalidReady(String)
        case junk(String)
    }

    static func parse(line rawLine: String) -> Message {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if let payload = payload(of: line, keyword: "READY") {
            guard let data = payload.data(using: .utf8),
                  let info = try? JSONDecoder().decode(ReadyInfo.self, from: data)
            else {
                return .invalidReady("malformed READY line: \(line.prefix(200))")
            }
            guard (1...65535).contains(info.port) else {
                return .invalidReady("READY announced invalid port \(info.port)")
            }
            guard info.api == supportedAPI else {
                return .invalidReady(
                    "server speaks API \(info.api), this app needs API \(supportedAPI); rebuild or re-run setup")
            }
            return .ready(info)
        }
        if let payload = payload(of: line, keyword: "FATAL") {
            struct Fatal: Decodable { let message: String }
            if let data = payload.data(using: .utf8),
               let fatal = try? JSONDecoder().decode(Fatal.self, from: data),
               !fatal.message.isEmpty {
                return .fatal(fatal.message)
            }
            let raw = payload.trimmingCharacters(in: .whitespaces)
            return .fatal(raw.isEmpty ? "unknown startup error" : raw)
        }
        return .junk(line)
    }

    /// "READY {…}" → "{…}"; also accepts a bare keyword.
    private static func payload(of line: String, keyword: String) -> String? {
        guard line.hasPrefix(keyword) else { return nil }
        let rest = line.dropFirst(keyword.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }
}

/// Splits a byte stream into lines. Bytes are buffered until a newline arrives,
/// so lines (and multi-byte UTF-8 characters) split across reads come out whole.
struct LineBuffer {
    /// A runaway line without newlines is cut here rather than growing forever.
    static let maxLineBytes = 64 * 1024

    private var pending = Data()

    mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(Self.decode(pending[pending.startIndex..<newline]))
            pending = Data(pending[pending.index(after: newline)...])
        }
        if pending.count > Self.maxLineBytes {
            lines.append(Self.decode(pending))
            pending = Data()
        }
        return lines
    }

    /// The trailing partial line at EOF, if any.
    mutating func finish() -> String? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : Self.decode(pending)
    }

    private static func decode(_ bytes: Data) -> String {
        var line = String(decoding: bytes, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        return line
    }
}
