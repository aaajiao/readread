import Foundation

/// The production `SpeechSynthesizer`: starts the Python server on demand,
/// sends v2 requests, and recovers once from a server that died under a request.
/// The server's flavor makes it the Kokoro engine or the Qwen one.
@MainActor
final class TTSService: SpeechSynthesizer {
    let server: TTSServerProcess
    private let transport: HTTPTransport
    /// Counts `stop()` and `shutdown()`: a request still in flight when the server was stopped on
    /// purpose fails, and never starts another server (stop() is final until the next request).
    private var stops = 0

    init(server: TTSServerProcess, transport: @escaping HTTPTransport = TTSClient.urlSessionTransport) {
        self.server = server
        self.transport = transport
    }

    static func live() -> TTSService {
        TTSService(server: TTSServerProcess(environment: .live()))
    }

    /// The Qwen engine of `installation` on a lifecycle of its own (its policy and log); the app's
    /// `QwenEngineFactory`.
    static func qwen(installation: HQInstallation) -> TTSService {
        qwen(installation: installation, environment: .live())
    }

    static func qwen(installation: HQInstallation, environment: ServerEnvironment) -> TTSService {
        TTSService(server: TTSServerProcess(environment: environment, flavor: .qwen(installation)))
    }

    /// "kokoro", or `QwenModel.engineID`.
    var engineID: String { server.flavor.engineID }

    /// Qwen synthesizes at speed 1.0 only: the player time-stretches, a speed change never
    /// re-synthesizes.
    var honoursSpeed: Bool { server.flavor.honoursSpeed }

    func synthesize(_ request: SynthesisRequest) async throws -> SynthesisResult {
        server.beginRequest()
        defer { server.endRequest() }
        let stopsBefore = stops
        var retried = false
        while true {
            let endpoint = try await server.ensureRunning(preload: [request.language])
            do {
                return try await TTSClient(endpoint: endpoint, transport: transport).synthesize(request)
            } catch let error as TTSError {
                switch error {
                case .connectionFailed where !retried && !Task.isCancelled:
                    // stop() ended the server under this request: no new one for it.
                    guard stops == stopsBefore else { throw CancellationError() }
                    // Most likely the server died under us: let the lifecycle record
                    // the crash, then try once more on a fresh server.
                    retried = true
                    await server.recoverFromConnectionFailure(endpoint, error: error)
                    guard stops == stopsBefore else { throw CancellationError() }
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

    /// Chosen again in Settings: a server that failed to start (FATAL) or crashed too often starts
    /// afresh on the next request.
    func resetFailure() {
        server.resetFailure()
    }

    func setPlaybackActive(_ active: Bool) {
        server.setPlaybackActive(active)
    }

    /// Stop the server now and wait for it to exit (SIGTERM, SIGKILL after the grace period)
    /// without blocking the main thread; the next request starts it again, a request in flight
    /// fails (`CancellationError`) without starting one. Switching engines stops the one left
    /// behind this way (Qwen gives back 3–4 GB).
    func stop() async {
        stops += 1
        await server.stop()
    }

    func shutdown() {
        stops += 1
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
