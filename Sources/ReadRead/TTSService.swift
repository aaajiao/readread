import Foundation

/// The production `SpeechSynthesizer`: starts the Python server on demand,
/// sends v2 requests, and recovers once from a server that died under a request.
@MainActor
final class TTSService: SpeechSynthesizer {
    let server: TTSServerProcess
    private let transport: HTTPTransport

    init(server: TTSServerProcess, transport: @escaping HTTPTransport = TTSClient.urlSessionTransport) {
        self.server = server
        self.transport = transport
    }

    static func live() -> TTSService {
        TTSService(server: TTSServerProcess(environment: .live()))
    }

    func synthesize(_ request: SynthesisRequest) async throws -> SynthesisResult {
        server.beginRequest()
        defer { server.endRequest() }
        var retried = false
        while true {
            let endpoint = try await server.ensureRunning(preload: [request.language])
            do {
                return try await TTSClient(endpoint: endpoint, transport: transport).synthesize(request)
            } catch let error as TTSError {
                switch error {
                case .connectionFailed where !retried && !Task.isCancelled:
                    // Most likely the server died under us: let the lifecycle record
                    // the crash, then try once more on a fresh server.
                    retried = true
                    await server.recoverFromConnectionFailure(endpoint, error: error)
                case .requestTimedOut:
                    // Wedged: replace it so the next request gets a fresh server.
                    await server.recoverFromConnectionFailure(endpoint, error: error)
                    throw error
                default:
                    throw error
                }
            }
        }
    }

    func prewarm(for language: SpeechLanguage) {
        server.prewarm(preload: [language])
    }

    func restart() async throws {
        try await server.restart()
    }

    func setPlaybackActive(_ active: Bool) {
        server.setPlaybackActive(active)
    }

    func shutdown() {
        server.stopSynchronously()
    }

    var status: SpeechEngineStatus {
        switch server.phase {
        case .stopped, .crashed: return .idle
        case .starting: return .starting
        case .ready: return .ready
        case .failed: return .failed(server.lastError?.errorDescription ?? String(localized: "TTS server failed"))
        }
    }

    var logFileURL: URL? {
        URL(fileURLWithPath: server.logPath)
    }
}
