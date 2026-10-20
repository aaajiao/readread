import Foundation

/// `ReadRead --self-test`: headless end-to-end check of the voice engine through
/// the real lifecycle code. Starts the server, checks that every `Voice.all` id is
/// in the server's `GET /voices` for its language, synthesizes one zh (zf_001),
/// one US English (af_heart) and one UK English (bf_emma) text, stops the server,
/// confirms every child it launched exited, and prints one JSON line to stdout.
/// Each text has English inside it or an out-of-vocabulary word (the espeak-ng
/// fallback) and digits; every word must come back timed, the audio must be about
/// as long as a known-good build makes it, and the server log must show no broken
/// espeak-ng data. Exit status 0 on success, 1 otherwise. Diagnostics go to stderr.
@MainActor
enum SelfTest {
    struct Case {
        let voice: String
        let text: String
        /// Seconds of audio a known-good build makes of `text` at speed 1.0.
        let expectedDuration: Double
    }

    static let cases: [Case] = [
        // Durations measured 2026-10-20 on the dev environment: 7.185 s, 4.415 s, 3.545 s.
        Case(voice: "zf_001", text: "你好，欢迎使用 ReadRead 朗读。这台电脑重1.5公斤，售价5999元。",
             expectedDuration: 7.2),
        Case(voice: "af_heart", text: "Hello from ReadRead. This blorptastic self test costs 12 dollars.",
             expectedDuration: 4.4),
        Case(voice: "bf_emma", text: "The weather in London is rather lovely today, says the flumbrous cat.",
             expectedDuration: 3.5),
    ]
    /// The audio may be this much shorter or longer than `expectedDuration`
    /// (scripts/smoke-test.sh allows the same band).
    static let durationBand: ClosedRange<Double> = 0.8...1.4
    /// Server log lines that mean the espeak-ng fallback is broken (its data is
    /// missing or unreadable), which otherwise only drops the words it should read.
    /// scripts/smoke-test.sh (ESPEAK_ERRORS) looks for the same ones.
    static let logMarkers = ["Can't read dictionary file", "words count mismatch"]
    static let overallTimeout: Duration = .seconds(300)

    struct CaseResult: Encodable {
        let voice: String
        let lang: String
        let accent: String
        var ok = false
        var ms = 0
        var duration: Double?
        var sampleRate: Int?
        var wavBytes: Int?
        var sentences: Int?
        var tokens: Int?
        /// Words of the text no timed token covers.
        var untimed: [String]?
        var error: String?
    }

    struct ServerInfo: Encodable {
        let pid: Int32
        let port: Int
        let loaded: [String]
        let startMs: Int
    }

    struct Paths: Encodable {
        let source: String
        let python: String
        let serverDir: String
        let modelsDir: String
    }

    /// `Voice.all` against the server's `GET /voices`.
    struct CatalogCheck: Encodable {
        let voices: Int
        let missing: [String]
    }

    struct Report: Encodable {
        var ok = false
        var mode = "self-test"
        var version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        var gitDescribe = Bundle.main.infoDictionary?["ReadReadGitDescribe"] as? String
        var paths: Paths?
        var log: String?
        var server: ServerInfo?
        var health: HealthInfo?
        var catalog: CatalogCheck?
        var results: [CaseResult] = []
        /// Server log lines with a `logMarkers` entry.
        var logProblems: [String] = []
        var stopped = false
        var childExited = false
        var error: String?
    }

    /// Shared with the watchdog, which may have to print the report itself.
    final class ReportBox {
        var report = Report()
    }

    static func run() async -> Int32 {
        let server = TTSServerProcess(environment: .live())
        let service = TTSService(server: server)
        let box = ReportBox()
        box.report.log = server.logPath

        let watchdog = Task { @MainActor in
            do { try await Task.sleep(for: overallTimeout) } catch { return }
            box.report.error = "self-test timed out after \(overallTimeout)"
            server.stopSynchronously()
            emit(box.report)
            exit(1)
        }
        defer { watchdog.cancel() }

        await perform(server: server, service: service, box: box)
        emit(box.report)
        return box.report.ok ? 0 : 1
    }

    private static func perform(server: TTSServerProcess, service: TTSService, box: ReportBox) async {
        let clock = ContinuousClock()
        let started = clock.now
        let logOffset = LocalFileSystem().fileSize(atPath: server.logPath) ?? 0
        let endpoint: ServerEndpoint
        do {
            diagnostic("starting TTS server…")
            endpoint = try await server.ensureRunning(preload: [.zh, .en])
        } catch {
            box.report.error = message(for: error)
            box.report.paths = server.resolvedPaths.map(paths(_:))
            await server.stop()
            box.report.stopped = server.phase != .ready
            box.report.childExited = childrenExited(server: server)
            return
        }
        box.report.paths = server.resolvedPaths.map(paths(_:))
        box.report.server = ServerInfo(
            pid: endpoint.pid, port: endpoint.port, loaded: endpoint.loaded,
            startMs: milliseconds(clock.now - started))
        diagnostic("server ready: pid \(endpoint.pid), port \(endpoint.port), loaded \(endpoint.loaded)")

        var healthOK = false
        do {
            let health = try await TTSClient(endpoint: endpoint).health()
            box.report.health = health
            healthOK = health.status == "ok" && health.api == ServerHandshake.supportedAPI
        } catch {
            box.report.error = "health: \(message(for: error))"
        }

        var catalogOK = false
        do {
            let missing = Voice.missing(from: try await TTSClient(endpoint: endpoint).voices()).map(\.id)
            box.report.catalog = CatalogCheck(voices: Voice.all.count, missing: missing)
            catalogOK = missing.isEmpty
            diagnostic(catalogOK
                ? "all \(Voice.all.count) app voices are in the server's /voices"
                : "app voices missing from the server's /voices: \(missing.joined(separator: ", "))")
        } catch {
            if box.report.error == nil { box.report.error = "voices: \(message(for: error))" }
        }

        for testCase in cases {
            guard let voice = Voice.voice(id: testCase.voice) else { continue }
            var result = CaseResult(voice: voice.id, lang: voice.language.rawValue, accent: voice.accent.label)
            let begin = clock.now
            do {
                let audio = try await service.synthesize(SynthesisRequest(text: testCase.text, voice: voice, speed: 1.0))
                result.ms = milliseconds(clock.now - begin)
                result.duration = audio.duration
                result.sampleRate = audio.sampleRate
                result.wavBytes = audio.wav.count
                result.sentences = audio.sentences.count
                result.tokens = audio.tokens.count
                let untimed = untimedWords(testCase.text, tokens: audio.tokens, duration: audio.duration)
                result.untimed = untimed
                let band = durationBand.lowerBound * testCase.expectedDuration
                    ... durationBand.upperBound * testCase.expectedDuration
                result.ok = TTSClient.isWAV(audio.wav) && band.contains(audio.duration) && !audio.silent
                    && audio.sampleRate == 24_000 && untimed.isEmpty
                if !result.ok {
                    result.error = "implausible audio (duration \(audio.duration) s, expected "
                        + "\(testCase.expectedDuration) s; silent \(audio.silent); untimed words \(untimed))"
                }
            } catch {
                result.ms = milliseconds(clock.now - begin)
                result.error = message(for: error)
            }
            diagnostic("\(voice.id): \(result.ok ? "ok" : "FAILED") in \(result.ms) ms\(result.error.map { " – \($0)" } ?? "")")
            box.report.results.append(result)
        }

        box.report.logProblems = logProblems(path: server.logPath, since: logOffset)
        for line in box.report.logProblems { diagnostic("server log: \(line)") }

        diagnostic("stopping server…")
        await server.stop()
        box.report.stopped = server.phase == .stopped
        box.report.childExited = server.lastExit?.pid == endpoint.pid && childrenExited(server: server)
        box.report.ok = box.report.error == nil && healthOK && catalogOK
            && box.report.results.count == cases.count && box.report.results.allSatisfy(\.ok)
            && box.report.logProblems.isEmpty && box.report.stopped && box.report.childExited
    }

    /// Every server the lifecycle launched (a replaced or timed-out one too) has
    /// exited, and its pid is gone (reaped).
    private static func childrenExited(server: TTSServerProcess) -> Bool {
        guard !server.isProcessRunning else { return false }
        return server.launchedPIDs.allSatisfy { kill($0, 0) == -1 && errno == ESRCH }
    }

    /// Words of `text` (Latin words and ideographs) that no token with a time
    /// span inside the audio (end after start) covers. Digits are left out: they
    /// come back as words.
    static func untimedWords(_ text: String, tokens: [TimedSpan], duration: Double) -> [String] {
        let timed = tokens.filter { 0 <= $0.start && $0.start < $0.end && $0.end <= duration + 0.05 }
        let covered = timed.map(\.text).joined()
        var words: [String] = []
        var latin = ""
        for character in text + " " {
            if character.isASCII && character.isLetter {
                latin.append(character)
                continue
            }
            if !latin.isEmpty { words.append(latin) }
            latin = ""
            if character.unicodeScalars.allSatisfy({ $0.properties.isIdeographic }) { words.append(String(character)) }
        }
        return words.filter { !covered.contains($0) }
    }

    /// Lines of the server log written since `offset` (all of it if it was
    /// rotated since) that contain one of `logMarkers`.
    static func logProblems(path: String, since offset: UInt64) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end >= offset ? offset : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).map(String.init).filter { line in
            logMarkers.contains { line.contains($0) }
        }
    }

    private static func paths(_ paths: TTSServerPaths) -> Paths {
        Paths(source: paths.source.rawValue, python: paths.python,
              serverDir: paths.serverDirectory, modelsDir: paths.modelsDirectory)
    }

    private static func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int((duration.timeInterval * 1000).rounded())
    }

    private static func emit(_ report: Report) {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let line = (try? encoder.encode(report)).map { String(decoding: $0, as: UTF8.self) }
            ?? #"{"ok":false,"error":"could not encode report"}"#
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    private static func diagnostic(_ text: String) {
        FileHandle.standardError.write(Data("[self-test] \(text)\n".utf8))
    }
}
