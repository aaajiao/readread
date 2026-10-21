import Foundation

/// Every way the TTS engine can fail, carrying the real message (server FATAL
/// text, HTTP error JSON, log tail) so the UI can show it verbatim.
enum TTSError: LocalizedError, Equatable {
    /// Python, the server or the model files are not where we looked.
    case resourcesMissing([String])
    /// `Process.run()` failed.
    case launchFailed(String)
    /// The server printed `FATAL {"message": …}` before READY.
    case serverFatal(String)
    /// The server exited before READY without a FATAL line.
    case exitedDuringStartup(status: Int32, detail: String)
    case startTimeout(seconds: Int)
    /// READY was malformed or announced an unsupported API.
    case protocolError(String)
    /// The server exited unexpectedly after READY.
    case crashed(status: Int32, detail: String)
    /// Too many crashes in a short time; automatic restarts are off until Retry.
    case gaveUp(lastError: String, logPath: String)
    /// The server answered with its error JSON.
    case server(status: Int, code: String, message: String)
    /// Non-JSON HTTP error.
    case http(status: Int, body: String)
    /// The server could not be reached (refused, connection lost).
    case connectionFailed(String)
    /// No answer within the request timeout (the server is wedged).
    case requestTimedOut(seconds: Int)
    /// 200, but the body was not what API v2 promises.
    case badResponse(String)

    /// True when files are genuinely missing, i.e. the "run ./scripts/setup.sh"
    /// hint applies.
    var isResourcesMissing: Bool {
        if case .resourcesMissing = self { return true }
        return false
    }

    /// Server lifecycle failures, which Retry fixes by restarting the server.
    var isServerFailure: Bool {
        switch self {
        case .resourcesMissing, .launchFailed, .serverFatal, .exitedDuringStartup,
             .startTimeout, .protocolError, .crashed, .gaveUp, .connectionFailed, .requestTimedOut:
            return true
        case .server, .http, .badResponse:
            return false
        }
    }

    /// English text with zh-Hans translations (R4-25); what the server or the system said stays
    /// as it is. Interpolations are strings only, so each key is exactly the one in
    /// Localizable.strings.
    var errorDescription: String? {
        switch self {
        case .resourcesMissing(let items):
            return String(localized: "Voice engine files are missing:") + "\n"
                + items.map { "• \($0)" }.joined(separator: "\n")
        case .launchFailed(let message):
            return String(localized: "Could not launch the TTS server: \(message)")
        case .serverFatal(let message):
            return String(localized: "TTS server failed to start: \(message)")
        case .exitedDuringStartup(let status, let detail):
            return String(localized: "TTS server exited during startup (\(Self.describe(status: status))).")
                + (detail.isEmpty ? "" : "\n\(detail)")
        case .startTimeout(let seconds):
            return String(localized: "TTS server did not become ready within \(String(seconds)) s.")
        case .protocolError(let message):
            return String(localized: "TTS server protocol error: \(message)")
        case .crashed(let status, let detail):
            return String(localized: "TTS server stopped unexpectedly (\(Self.describe(status: status))).")
                + (detail.isEmpty ? "" : "\n\(detail)")
        case .gaveUp(let lastError, let logPath):
            return String(localized: "TTS server crashed repeatedly, so automatic restart is off. Last error: \(lastError)")
                + "\n" + String(localized: "Log: \(logPath)")
        case .server(_, let code, let message):
            return String(localized: "TTS error (\(code)): \(message)")
        case .http(let status, let body):
            return body.isEmpty
                ? String(localized: "TTS server returned HTTP \(String(status)).")
                : String(localized: "TTS server returned HTTP \(String(status)): \(body)")
        case .connectionFailed(let message):
            return String(localized: "Could not reach the TTS server: \(message)")
        case .requestTimedOut(let seconds):
            return String(localized: "The TTS server did not answer within \(String(seconds)) s.")
        case .badResponse(let message):
            return String(localized: "Unexpected response from the TTS server: \(message)")
        }
    }

    /// "exit status 3" or "signal 9" from a raw termination status.
    /// Negative values encode signals (see `ProcessExit.encodedStatus`).
    static func describe(status: Int32) -> String {
        status < 0
            ? String(localized: "signal \(String(-status))")
            : String(localized: "exit status \(String(status))")
    }
}
