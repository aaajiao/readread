import Foundation

/// Sends a request and returns the body and response; injectable for tests.
typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

/// HTTP API v2 client for one ready server. Stateless; cheap to create per call.
struct TTSClient: Sendable {
    /// URLSession's idle timeout: the server sends nothing until a request is
    /// synthesized, and requests are capped at `AppState.maxRequestCharacters`.
    static let requestTimeout: TimeInterval = 120

    let endpoint: ServerEndpoint
    let transport: HTTPTransport

    init(endpoint: ServerEndpoint, transport: @escaping HTTPTransport = TTSClient.urlSessionTransport) {
        self.endpoint = endpoint
        self.transport = transport
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]  // loopback only, never a proxy
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = 10 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// URLSession's async API cancels the underlying task when the calling Swift
    /// task is cancelled.
    static let urlSessionTransport: HTTPTransport = { request in
        try await session.data(for: request)
    }

    // MARK: - Endpoints

    func synthesize(_ request: SynthesisRequest) async throws -> SynthesisResult {
        let (data, _) = try await send(makeSynthesizeRequest(request))
        return try Self.decodeSynthesis(data)
    }

    func health() async throws -> HealthInfo {
        let (data, _) = try await send(makeRequest(path: "health", method: "GET"))
        do {
            return try JSONDecoder().decode(HealthInfo.self, from: data)
        } catch {
            throw TTSError.badResponse("health: \(error.localizedDescription)")
        }
    }

    /// GET /voices: the voice ids the model files provide, by language code
    /// (`{"zh": […], "en": […]}`). `Voice.all` must be a subset (see `Voice.missing(from:)`).
    func voices() async throws -> [String: [String]] {
        let (data, _) = try await send(makeRequest(path: "voices", method: "GET"))
        do {
            return try JSONDecoder().decode([String: [String]].self, from: data)
        } catch {
            throw TTSError.badResponse("voices: \(error.localizedDescription)")
        }
    }

    // MARK: - Requests

    func makeRequest(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: endpoint.baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = Self.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func makeSynthesizeRequest(_ request: SynthesisRequest) throws -> URLRequest {
        struct Body: Encodable {
            let text: String
            let voice: String
            let lang: String
            let speed: Double
            let request_id: String
            let format: String
        }
        var urlRequest = makeRequest(path: "synthesize", method: "POST")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(Body(
            text: request.text,
            voice: request.voiceID,
            lang: request.language.rawValue,
            speed: request.speed,
            request_id: request.requestID,
            format: "json"
        ))
        return urlRequest
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw Self.mapTransportError(error)
        } catch is CancellationError {
            throw CancellationError()
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw TTSError.badResponse("not an HTTP response")
        }
        guard http.statusCode == 200 else {
            throw Self.error(status: http.statusCode, body: data)
        }
        return (data, http)
    }

    // MARK: - Mapping

    static func mapTransportError(_ error: URLError) -> TTSError {
        switch error.code {
        case .timedOut:
            return .requestTimedOut(seconds: Int(requestTimeout))
        default:
            return .connectionFailed("\(error.localizedDescription) (URLError \(error.code.rawValue))")
        }
    }

    /// `{"error":{"code":…,"message":…}}` → `.server` with the server's message;
    /// anything else → `.http` with the start of the body.
    static func error(status: Int, body: Data) -> TTSError {
        struct Envelope: Decodable {
            struct Detail: Decodable {
                let code: String?
                let message: String?
            }
            let error: Detail
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: body),
           let message = envelope.error.message ?? envelope.error.code {
            return .server(status: status, code: envelope.error.code ?? "http_\(status)", message: message)
        }
        let text = String(decoding: body.prefix(500), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .http(status: status, body: text)
    }

    static func decodeSynthesis(_ data: Data) throws -> SynthesisResult {
        struct RawSpan: Decodable {
            let text: String?
            let start: Double?
            let end: Double?
            var span: TimedSpan? {
                guard let text, let start, let end else { return nil }
                return TimedSpan(text: text, start: start, end: end)
            }
        }
        struct Response: Decodable {
            let requestId: String?
            let sampleRate: Int
            let duration: Double
            let audio: String
            let silent: Bool?
            let sentences: [RawSpan]?
            let tokens: [RawSpan]?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response: Response
        do {
            response = try decoder.decode(Response.self, from: data)
        } catch {
            throw TTSError.badResponse("synthesize: \(error.localizedDescription)")
        }
        guard let wav = Data(base64Encoded: response.audio), isWAV(wav) else {
            throw TTSError.badResponse("synthesize: audio is not base64-encoded WAV")
        }
        return SynthesisResult(
            wav: wav,
            duration: response.duration,
            sampleRate: response.sampleRate,
            silent: response.silent ?? false,
            sentences: (response.sentences ?? []).compactMap(\.span),
            tokens: (response.tokens ?? []).compactMap(\.span),
            requestID: response.requestId
        )
    }

    static func isWAV(_ data: Data) -> Bool {
        data.count >= 12
            && data.prefix(4) == Data("RIFF".utf8)
            && data.dropFirst(8).prefix(4) == Data("WAVE".utf8)
    }
}

/// GET /health.
struct HealthInfo: Codable, Equatable, Sendable {
    let status: String
    let api: Int
    let pid: Int?
    let loaded: [String]?
    let versions: [String: String]?
}
