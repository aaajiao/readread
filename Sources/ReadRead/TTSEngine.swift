import Foundation

enum TTSError: LocalizedError {
    case pythonNotFound
    case modelNotFound
    case scriptNotFound
    case serverStartFailed(String)
    case serverNotReady
    case synthesizeFailed(String)

    var errorDescription: String? {
        switch self {
        case .pythonNotFound:
            return "Python not found. Rebuild with: ./scripts/build-app.sh"
        case .modelNotFound:
            return "Model files not found. Rebuild with: ./scripts/build-app.sh"
        case .scriptNotFound:
            return "TTS server script not found"
        case .serverStartFailed(let msg):
            return "TTS server failed to start: \(msg)"
        case .serverNotReady:
            return "TTS server is not running"
        case .synthesizeFailed(let msg):
            return msg
        }
    }
}

@MainActor
final class TTSEngine {
    private var process: Process?
    private var serverPort: Int?
    private let portFilePath: String

    var isReady: Bool { serverPort != nil && (process?.isRunning ?? false) }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path()
        self.portFilePath = "\(home).readread/tts-port"
    }

    func start() async throws {
        let fm = FileManager.default

        // Resolve paths: app bundle first, then ~/.readread/ fallback
        let python = resolve(
            bundle: "python/bin/python3",
            fallback: "~/.readread/env/bin/python3"
        )
        guard fm.fileExists(atPath: python) else {
            throw TTSError.pythonNotFound
        }

        let models = resolveDir(
            bundle: "models",
            fallback: "~/.readread/models"
        )
        let hasModel = fm.fileExists(atPath: "\(models)/kokoro-v1.0.onnx")
            || fm.fileExists(atPath: "\(models)/kokoro-v1.0.fp16.onnx")
            || fm.fileExists(atPath: "\(models)/kokoro-v1.0.int8.onnx")
        guard hasModel && fm.fileExists(atPath: "\(models)/voices-v1.0.bin") else {
            throw TTSError.modelNotFound
        }

        let script = resolve(
            bundle: "tts_server.py",
            fallback: "~/.readread/tts_server.py",
            extra: "\(fm.currentDirectoryPath)/tts_server/tts_server.py"
        )
        guard fm.fileExists(atPath: script) else {
            throw TTSError.scriptNotFound
        }

        // Ensure port file directory exists
        let portDir = (portFilePath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: portDir, withIntermediateDirectories: true)
        try? fm.removeItem(atPath: portFilePath)

        // Launch TTS server
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [
            script,
            "--model-dir", models,
            "--port-file", portFilePath,
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.standardError

        try proc.run()
        self.process = proc

        // Wait for server (model loading can take 10-30s)
        for _ in 0..<120 {
            try await Task.sleep(for: .milliseconds(500))

            if let portStr = try? String(contentsOfFile: portFilePath, encoding: .utf8),
               let port = Int(portStr.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                self.serverPort = port
                if await healthCheck() { return }
            }

            if !proc.isRunning {
                throw TTSError.serverStartFailed(
                    "Process exited with code \(proc.terminationStatus)"
                )
            }
        }

        proc.terminate()
        throw TTSError.serverStartFailed("Timeout — model may be too large for this machine")
    }

    func stop() {
        process?.terminate()
        process = nil
        serverPort = nil
        try? FileManager.default.removeItem(atPath: portFilePath)
    }

    func synthesize(text: String, voice: String, speed: Double, lang: String) async throws -> Data {
        guard let port = serverPort else {
            throw TTSError.serverNotReady
        }

        let url = URL(string: "http://127.0.0.1:\(port)/synthesize")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "text": text,
            "voice": voice,
            "speed": speed,
            "lang": lang,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TTSError.synthesizeFailed("No response from TTS server")
        }
        guard httpResponse.statusCode == 200 else {
            // Extract error message from response body (JSON or HTML)
            let message: String
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = json["error"] as? String {
                message = err
            } else {
                let body = String(data: data, encoding: .utf8) ?? ""
                if let range = body.range(of: "Message: "),
                   let end = body[range.upperBound...].range(of: "</p>") {
                    message = String(body[range.upperBound..<end.lowerBound])
                } else {
                    message = "HTTP \(httpResponse.statusCode)"
                }
            }
            throw TTSError.synthesizeFailed("TTS error: \(message)")
        }

        return data
    }

    // MARK: - Path Resolution

    /// Find a file: check app bundle Resources first, then fallback path(s)
    private func resolve(bundle: String, fallback: String, extra: String? = nil) -> String {
        let fm = FileManager.default

        // 1. Inside app bundle
        if let resources = Bundle.main.resourcePath {
            let bundled = "\(resources)/\(bundle)"
            if fm.fileExists(atPath: bundled) { return bundled }
        }

        // 2. Fallback (~/.readread/...)
        let expanded = NSString(string: fallback).expandingTildeInPath
        if fm.fileExists(atPath: expanded) { return expanded }

        // 3. Extra (e.g. CWD for development)
        if let extra, fm.fileExists(atPath: extra) { return extra }

        return expanded
    }

    /// Find a directory: check app bundle Resources first, then fallback
    private func resolveDir(bundle: String, fallback: String) -> String {
        let fm = FileManager.default

        if let resources = Bundle.main.resourcePath {
            let bundled = "\(resources)/\(bundle)"
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: bundled, isDirectory: &isDir), isDir.boolValue {
                return bundled
            }
        }

        return NSString(string: fallback).expandingTildeInPath
    }

    // MARK: - Health Check

    nonisolated private func healthCheck() async -> Bool {
        guard let port = await serverPort,
              let url = URL(string: "http://127.0.0.1:\(port)/health")
        else { return false }

        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
