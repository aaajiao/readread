import Foundation
import Network
import Synchronization
import XCTest

@testable import ReadRead

// Helpers for the content tests (pages, files, formats): a local HTTP server and the gates of
// the tests that need WebKit or the network.

/// The WebKit tests run only with READREAD_TEST_WEBKIT=1 (outside the sandbox: WebKit starts its
/// own processes), with Defuddle from READREAD_TEST_DEFUDDLE (a file) or $READREAD_HOME/defuddle
/// (READREAD_HOME must be set: these tests never read the real ~/.readread).
enum WebKitTestGate {
    static var enabled: Bool { ProcessInfo.processInfo.environment["READREAD_TEST_WEBKIT"] == "1" }

    static func defuddleScript() throws -> String {
        guard enabled else { throw XCTSkip("set READREAD_TEST_WEBKIT=1 to run the WebKit tests") }
        let environment = ProcessInfo.processInfo.environment
        var candidates: [URL] = []
        if let file = environment["READREAD_TEST_DEFUDDLE"], !file.isEmpty { candidates.append(URL(fileURLWithPath: file)) }
        if let home = environment["READREAD_HOME"], !home.isEmpty {
            candidates.append(URL(fileURLWithPath: home).appending(path: "defuddle/defuddle.full.js"))
        }
        for url in candidates {
            if let script = try? String(contentsOf: url, encoding: .utf8) { return script }
        }
        throw XCTSkip("no Defuddle build: set READREAD_TEST_DEFUDDLE or READREAD_HOME (run setup.sh)")
    }
}

/// A value tests change while @Sendable closures read it (a mode, a clock).
final class Shared<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>

    init(_ value: Value) { storage = Mutex(value) }

    var value: Value {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

/// A small HTTP/1.1 server on 127.0.0.1 for the web view: fixed routes, optional delays, a route
/// that never answers or never finishes; it records every path asked for.
final class TestHTTPServer: @unchecked Sendable {
    struct Response: Sendable {
        var status = 200
        var headers: [String: String] = ["Content-Type": "text/html; charset=utf-8"]
        var body = Data()
        var delay: Duration = .zero
        /// Keep the connection open and never answer.
        var hangs = false
        /// Send only this many bytes of the body, then keep the connection open: the rest never comes.
        var sendsOnly: Int?

        static func html(_ text: String, delay: Duration = .zero) -> Response {
            Response(body: Data(text.utf8), delay: delay)
        }

        static func redirect(to location: String) -> Response {
            Response(status: 302, headers: ["Location": location, "Content-Type": "text/plain"], body: Data("moved".utf8))
        }
    }

    private let queue = DispatchQueue(label: "ReadReadTests.TestHTTPServer")
    private let listener: NWListener
    private let lock = NSLock()
    private var routes: [String: Response]
    private var requested: [String] = []
    private var open: [NWConnection] = []
    private(set) var port: UInt16 = 0

    init(routes: [String: Response] = [:]) throws {
        self.routes = routes
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
        if port == 0 { throw XCTSkip("could not listen on 127.0.0.1") }
    }

    deinit { stop() }

    func stop() {
        listener.cancel()
        let connections = lock.withLock { open }
        for connection in connections { connection.cancel() }
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    func set(_ path: String, _ response: Response) { lock.withLock { routes[path] = response } }

    var paths: [String] { lock.withLock { requested } }

    private func accept(_ connection: NWConnection) {
        lock.withLock { open.append(connection) }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.answer(String(decoding: buffer[..<end.lowerBound], as: UTF8.self), on: connection)
            } else if !complete, error == nil {
                self.receive(on: connection, buffer: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func answer(_ head: String, on connection: NWConnection) {
        let requestLine = head.split(separator: "\r\n").first.map(String.init) ?? ""
        let target = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let path = String(target.split(separator: "?", maxSplits: 1).first ?? "/")
        let response = lock.withLock { () -> Response in
            requested.append(path)
            return routes[path] ?? Response(status: 404, headers: ["Content-Type": "text/plain"], body: Data("not found".utf8))
        }
        if response.hangs { return }
        var lines = ["HTTP/1.1 \(response.status) \(HTTPURLResponse.localizedString(forStatusCode: response.status))",
                     "Content-Length: \(response.body.count)", "Connection: close", "Cache-Control: no-store"]
        for (name, value) in response.headers { lines.append("\(name): \(value)") }
        let head = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        let seconds = Double(response.delay.components.seconds) + Double(response.delay.components.attoseconds) / 1e18
        if let count = response.sendsOnly {
            queue.asyncAfter(deadline: .now() + seconds) {
                connection.send(content: head + response.body.prefix(count), completion: .contentProcessed { _ in })
            }
            return
        }
        queue.asyncAfter(deadline: .now() + seconds) {
            connection.send(content: head + response.body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

/// WebKit's content processes on this Mac (libproc) and the CPU they use: the gated test of a page
/// whose script never ends.
enum WebContentProcesses {
    static func list() -> Set<pid_t> {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return Set(pids.prefix(Int(filled)).filter { pid in
            var path = [CChar](repeating: 0, count: 4_096)
            guard pid > 0, proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
            return String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                .contains("com.apple.WebKit.WebContent")
        })
    }

    /// User and system time, in nanoseconds; nil once the process is gone.
    static func cpuTime(_ pid: pid_t) -> UInt64? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return (info.pti_total_user + info.pti_total_system) * UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))
    }

    /// Those of `pids` that used more than half a core over `interval`.
    static func busy(among pids: Set<pid_t>, over interval: Duration) async throws -> [pid_t] {
        let before = pids.compactMap { pid in cpuTime(pid).map { (pid, $0) } }
        try await Task.sleep(for: interval)
        let budget = (Double(interval.components.seconds) * 1e9 + Double(interval.components.attoseconds) / 1e9) / 2
        return before.compactMap { pid, then in
            guard let now = cpuTime(pid), now > then, Double(now - then) > budget else { return nil }
            return pid
        }.sorted()
    }
}
