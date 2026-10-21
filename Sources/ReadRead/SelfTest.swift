import AVFoundation
import Foundation

/// `ReadRead --self-test`: headless end-to-end check of the page reader and the voice
/// engine through the real code. First the installed Defuddle build (the bundle's, else
/// `$READREAD_HOME/defuddle`) reads a page held in memory in an offscreen web view, as the
/// app reads a web page on this Mac (no network, no page scripts), and the text pipeline
/// makes its document. Then it starts the server, checks that every `Voice.all` id is
/// in the server's `GET /voices` for its language, synthesizes one zh (zf_001),
/// one US English (af_heart) and one UK English (bf_emma) text, reads a zh + en
/// Markdown fixture through the text pipeline and plays its first three units back to
/// back through `AudioQueuePlayer` in offline rendering (no audio device), stops the
/// server, confirms every child it launched exited, and prints one JSON line to stdout.
/// Each text has English inside it or an out-of-vocabulary word (the espeak-ng
/// fallback) and digits; every word must come back timed, the audio must be about
/// as long as a known-good build makes it, and the server log must show no broken
/// espeak-ng data. Nothing is written outside the log and cache directories (no reading
/// positions; the web view's content rules go to `<cache>/webkit-rules`). Exit status 0 on
/// success, 1 otherwise. Diagnostics go to stderr. main.swift runs the main run loop for it
/// (WebKit needs one; `dispatchMain()` would starve the web view).
///
/// `--self-test --engine qwen` checks the high-quality engine instead: the Qwen server from the
/// install in `$READREAD_HQ_HOME` (install.json read as the app reads it), started with both
/// routes preloaded and its READY engine and model checked, `Voice.qwen` in its `GET /voices`, one
/// zh (serena) and one en (aiden) text at speed 1.0 (`synth_speed` 1.0, a duration near the one
/// the real install makes; no word timings: Qwen reports none), and the fixture's first units
/// played offline at `qwenPlaybackSpeed` (made at 1.0, time-stretched by the player: the output
/// lasts their audio and pauses divided by the speed). Then it stops the server and confirms the
/// child exited. The page reader is not checked again. Exit status 2 for a bad `--engine`.
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

    /// `--engine qwen`: the first two texts read by the Qwen voices. Durations measured 2026-10-21
    /// on the 1.7b install (7.175 s, 4.845 s; the same in every run: the sampling seed comes
    /// from voice and text).
    static let qwenCases: [Case] = [
        Case(voice: "serena", text: cases[0].text, expectedDuration: 7.2),
        Case(voice: "aiden", text: cases[1].text, expectedDuration: 4.8),
    ]
    /// Qwen samples its speech: on another Mac or MLX build the same seed may take another path.
    /// Runaway (2.5×) and cut-off (0.3×) generations, which the engine retries, stay outside.
    static let qwenDurationBand: ClosedRange<Double> = 0.7...1.4
    /// The Qwen playback check's speed: the audio comes at 1.0 and the player stretches it.
    static let qwenPlaybackSpeed = 1.25
    /// Time-stretched playback may end this much earlier or later than its audio and pauses
    /// divided by the speed: no sample-by-sample comparison is possible then, so this is the only
    /// check against a gap or a cut. Measured 2026-10-21: 4 ms on the 1.7b install's audio at
    /// 1.25×, under 20 ms with test tones; the bound is `playbackTolerance`'s.
    static let stretchedPlaybackTolerance = 0.05
    /// A cold Qwen start alone may take 180 s (`ServerPolicy.qwen`).
    static let qwenOverallTimeout: Duration = .seconds(480)

    /// The playback check's document: a title (also its first heading), a footnote and a
    /// table (neither read), Chinese with an English paragraph.
    static let fixtureTitle = "ReadRead 朗读自检"
    static let fixtureMarkdown = """
        # ReadRead 朗读自检

        这是一段中文测试文字，用来检查从文本到声音的整个朗读流程。[^1]

        Then one English sentence.

        | 列 | 值 |
        | --- | --- |
        | 甲 | 1 |

        最后一句话在表格后面。

        [^1]: 这条脚注不会被读出来。
        """
    /// The units the check expects the pipeline to make of `fixtureMarkdown`, in order.
    static let fixtureUnits: [(text: String, language: SpeechLanguage)] = [
        ("ReadRead 朗读自检。", .zh),
        ("这是一段中文测试文字，用来检查从文本到声音的整个朗读流程。", .zh),
        ("Then one English sentence.", .en),
        ("最后一句话在表格后面。", .zh),
    ]
    /// How many of them are synthesized and played.
    static let playedUnits = 3
    /// Played audio may differ from the units' durations plus their pauses by this much.
    static let playbackTolerance = 0.05
    /// Server log lines that mean the espeak-ng fallback is broken (its data is
    /// missing or unreadable), which otherwise only drops the words it should read.
    /// scripts/smoke-test.sh (ESPEAK_ERRORS) looks for the same ones.
    static let logMarkers = ["Can't read dictionary file", "words count mismatch"]
    static let overallTimeout: Duration = .seconds(300)

    /// The page reader check's page (`LocalExtractor.read(html:)`: loaded without a base URL,
    /// its scripts off, every network load blocked).
    static let extractionHTML = """
        <html lang="en"><head><title>Self Test</title></head><body><article><h1>Self Test</h1>
        <p>ReadRead reads this sentence on this Mac, with the bundled Defuddle and nothing from the network.</p>
        <p>It is a second sentence in a second paragraph.</p></article></body></html>
        """
    static let extractionTitle = "Self Test"
    /// The units the page must become: the title (Defuddle drops the heading that repeats it),
    /// then the two sentences, all English.
    static let extractionUnits = [
        "Self Test.",
        "ReadRead reads this sentence on this Mac, with the bundled Defuddle and nothing from the network.",
        "It is a second sentence in a second paragraph.",
    ]

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
        /// `synth_speed` (`--engine qwen` only: it must be 1.0).
        var synthSpeed: Double?
        var error: String?
    }

    /// `--engine qwen`: the install the server ran from.
    struct HQInfo: Encodable {
        let home: String
        let modelBytes: Int64
        let installedAt: String?
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

    /// The fixture document and its offline playback.
    struct PlaybackCheck: Encodable {
        var ok = false
        /// The document came out as `fixtureUnits` (title first, footnote and table dropped).
        var documentOK = false
        var units: [String] = []
        var languages: [String] = []
        /// The playback speed, when not 1.0.
        var speed: Double?
        /// Σ (unit duration + pause) of the played units, by the server's durations, over the
        /// rate each one plays at (speed / synth_speed).
        var expectedSeconds: Double?
        /// Where the played audio ends in the output (the last audible sample, then the rest of
        /// the last unit and its pause).
        var renderedSeconds: Double?
        /// From the first to the last audible sample.
        var audibleSeconds: Double?
        /// Largest difference between the output and the units' samples laid end to end (not
        /// measured when the player time-stretches).
        var maxDifference: Double?
        var error: String?
    }

    /// `extractionHTML` read on this Mac and turned into a document.
    struct ExtractionCheck: Encodable {
        var ok = false
        /// The Defuddle build that read it: `Contents/Resources/defuddle/defuddle.full.js` in the
        /// app, else `$READREAD_HOME/defuddle/defuddle.full.js`.
        var script: String?
        var ms = 0
        var title: String?
        /// The speak texts of the document made of the page.
        var units: [String] = []
        var error: String?
    }

    struct Report: Encodable {
        var ok = false
        var mode = "self-test"
        var version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        var gitDescribe = Bundle.main.infoDictionary?["ReadReadGitDescribe"] as? String
        /// `--engine qwen` only: what the server's READY line named ("qwen", "1.7b").
        var engine: String?
        var model: String?
        var hq: HQInfo?
        var paths: Paths?
        var log: String?
        var extraction: ExtractionCheck?
        var server: ServerInfo?
        var health: HealthInfo?
        var catalog: CatalogCheck?
        var results: [CaseResult] = []
        var playback: PlaybackCheck?
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

    struct ArgumentError: Error, Equatable {
        let message: String
    }

    /// The engine the self test's arguments (the process's, after the executable) name:
    /// `--engine kokoro|qwen` or `--engine=…`, Kokoro without one. Other arguments are left alone.
    static func engine(arguments: [String]) throws(ArgumentError) -> EngineKind {
        var engine = EngineKind.kokoro
        var index = arguments.startIndex
        while index < arguments.endIndex {
            var value: String?
            if arguments[index] == "--engine" {
                index += 1
                guard index < arguments.endIndex else { throw ArgumentError(message: "--engine needs a value: kokoro or qwen") }
                value = arguments[index]
            } else if arguments[index].hasPrefix("--engine=") {
                value = String(arguments[index].dropFirst("--engine=".count))
            }
            if let value {
                guard let kind = EngineKind(rawValue: value) else {
                    throw ArgumentError(message: "unknown engine \(value) for --engine (kokoro or qwen)")
                }
                engine = kind
            }
            index += 1
        }
        return engine
    }

    /// `--self-test [--engine kokoro|qwen]`: the exit status (2 for a bad argument).
    static func run(arguments: [String]) async -> Int32 {
        let engine: EngineKind
        do {
            engine = try self.engine(arguments: arguments)
        } catch {
            var report = Report()
            report.error = error.message
            emit(report)
            return 2
        }
        switch engine {
        case .kokoro: return await run()
        case .qwen: return await runQwen(environment: .live())
        }
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

    /// `--self-test --engine qwen`, from the install `environment` names (`$READREAD_HQ_HOME`).
    static func runQwen(environment: ServerEnvironment) async -> Int32 {
        let box = ReportBox()
        // What is started; the lifecycle fails the start unless READY names the same.
        box.report.engine = EngineKind.qwen.rawValue
        box.report.model = QwenModel.id
        let context = environment.pathContext
        let state = HQInstallation.state(
            environment: context.environment, homeDirectory: context.homeDirectory, fileSystem: environment.fileSystem)
        guard case .installed(let installation) = state else {
            let home = HQInstallation.home(environment: context.environment, homeDirectory: context.homeDirectory)
            switch state {
            case .damaged(let message): box.report.error = "the high-quality install at \(home ?? "?") is damaged: \(message)"
            default: box.report.error = "no high-quality install at \(home ?? "?") (install.json not found)"
            }
            emit(box.report)
            return 1
        }
        box.report.hq = HQInfo(home: installation.home, modelBytes: installation.modelBytes,
                               installedAt: installation.installedAt.map { $0.ISO8601Format() })
        let service = TTSService.qwen(installation: installation, environment: environment)
        let server = service.server
        box.report.log = server.logPath

        let watchdog = Task { @MainActor in
            do { try await Task.sleep(for: qwenOverallTimeout) } catch { return }
            box.report.error = "self-test timed out after \(qwenOverallTimeout)"
            server.stopSynchronously()
            emit(box.report)
            exit(1)
        }
        defer { watchdog.cancel() }

        await performQwen(server: server, service: service, box: box)
        emit(box.report)
        return box.report.ok ? 0 : 1
    }

    private static func perform(server: TTSServerProcess, service: TTSService, box: ReportBox) async {
        // The page reader needs no server: checked first, reported even when the server fails.
        diagnostic("reading a page with Defuddle in an offscreen web view…")
        let extraction = await checkExtraction()
        box.report.extraction = extraction
        diagnostic("page reader: \(extraction.ok ? "ok" : "FAILED") in \(extraction.ms) ms"
            + (extraction.script.map { " with \($0)" } ?? "") + (extraction.error.map { " – \($0)" } ?? ""))

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

        let playback = await checkPlayback(service: service)
        diagnostic("playback: \(playback.ok ? "ok" : "FAILED")"
            + (playback.renderedSeconds.map { String(format: ", rendered %.3f s", $0) } ?? "")
            + (playback.expectedSeconds.map { String(format: ", expected %.3f s", $0) } ?? "")
            + (playback.error.map { " – \($0)" } ?? ""))
        box.report.playback = playback

        box.report.logProblems = logProblems(path: server.logPath, since: logOffset)
        for line in box.report.logProblems { diagnostic("server log: \(line)") }

        diagnostic("stopping server…")
        await server.stop()
        box.report.stopped = server.phase == .stopped
        box.report.childExited = server.lastExit?.pid == endpoint.pid && childrenExited(server: server)
        box.report.ok = box.report.error == nil && healthOK && catalogOK
            && box.report.extraction?.ok == true
            && box.report.results.count == cases.count && box.report.results.allSatisfy(\.ok)
            && box.report.playback?.ok == true
            && box.report.logProblems.isEmpty && box.report.stopped && box.report.childExited
    }

    private static func performQwen(server: TTSServerProcess, service: TTSService, box: ReportBox) async {
        let clock = ContinuousClock()
        let started = clock.now
        let logOffset = LocalFileSystem().fileSize(atPath: server.logPath) ?? 0
        let endpoint: ServerEndpoint
        do {
            diagnostic("starting the Qwen TTS server (\(QwenModel.id))…")
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
        box.report.engine = endpoint.engine
        box.report.model = endpoint.model
        box.report.server = ServerInfo(
            pid: endpoint.pid, port: endpoint.port, loaded: endpoint.loaded,
            startMs: milliseconds(clock.now - started))
        diagnostic("server ready: pid \(endpoint.pid), port \(endpoint.port), loaded \(endpoint.loaded), "
            + "engine \(endpoint.engine ?? "?"), model \(endpoint.model ?? "?")")
        let readyOK = endpoint.engine == EngineKind.qwen.rawValue && endpoint.model == QwenModel.id
            && Set(endpoint.loaded) == ["zh", "en"]

        var healthOK = false
        do {
            let health = try await TTSClient(endpoint: endpoint).health()
            box.report.health = health
            healthOK = health.status == "ok" && health.api == ServerHandshake.supportedAPI
                && health.engine == EngineKind.qwen.rawValue && health.model == QwenModel.id
        } catch {
            box.report.error = "health: \(message(for: error))"
        }

        var catalogOK = false
        do {
            let missing = Voice.missing(from: try await TTSClient(endpoint: endpoint).voices(), in: Voice.qwen).map(\.id)
            box.report.catalog = CatalogCheck(voices: Voice.qwen.count, missing: missing)
            catalogOK = missing.isEmpty
            diagnostic(catalogOK
                ? "both Qwen voices are in the server's /voices"
                : "Qwen voices missing from the server's /voices: \(missing.joined(separator: ", "))")
        } catch {
            if box.report.error == nil { box.report.error = "voices: \(message(for: error))" }
        }

        for testCase in qwenCases {
            guard let voice = Voice.qwen.first(where: { $0.id == testCase.voice }) else { continue }
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
                result.synthSpeed = audio.synthSpeed
                let band = qwenDurationBand.lowerBound * testCase.expectedDuration
                    ... qwenDurationBand.upperBound * testCase.expectedDuration
                result.ok = TTSClient.isWAV(audio.wav) && band.contains(audio.duration) && !audio.silent
                    && audio.sampleRate == 24_000 && audio.synthSpeed == 1.0
                if !result.ok {
                    result.error = "implausible audio (duration \(audio.duration) s, expected "
                        + "\(testCase.expectedDuration) s; silent \(audio.silent); synth_speed \(audio.synthSpeed))"
                }
            } catch {
                result.ms = milliseconds(clock.now - begin)
                result.error = message(for: error)
            }
            diagnostic("\(voice.id): \(result.ok ? "ok" : "FAILED") in \(result.ms) ms\(result.error.map { " – \($0)" } ?? "")")
            box.report.results.append(result)
        }

        let playback = await checkPlayback(service: service, speed: qwenPlaybackSpeed) { language in
            Voice.qwen.first { $0.language == language } ?? Voice.defaultVoice(for: language)
        }
        diagnostic("playback at \(qwenPlaybackSpeed)×: \(playback.ok ? "ok" : "FAILED")"
            + (playback.renderedSeconds.map { String(format: ", rendered %.3f s", $0) } ?? "")
            + (playback.expectedSeconds.map { String(format: ", expected %.3f s", $0) } ?? "")
            + (playback.error.map { " – \($0)" } ?? ""))
        box.report.playback = playback

        box.report.logProblems = logProblems(path: server.logPath, since: logOffset)
        for line in box.report.logProblems { diagnostic("server log: \(line)") }

        diagnostic("stopping server…")
        await service.stop()
        box.report.stopped = server.phase == .stopped
        box.report.childExited = server.lastExit?.pid == endpoint.pid && childrenExited(server: server)
        box.report.ok = box.report.error == nil && readyOK && healthOK && catalogOK
            && box.report.results.count == qwenCases.count && box.report.results.allSatisfy(\.ok)
            && box.report.playback?.ok == true
            && box.report.logProblems.isEmpty && box.report.stopped && box.report.childExited
    }

    /// Read `extractionHTML` with the installed Defuddle build (`DefuddleBundle`) as the app
    /// reads a web page on this Mac (`LocalExtractor`, an offscreen web view), then build its
    /// document: it must come out as `extractionUnits`.
    static func checkExtraction(context: TTSServerPaths.Context = .live()) async -> ExtractionCheck {
        var check = ExtractionCheck()
        guard let defuddle = DefuddleBundle.locate(context) else {
            check.error = message(for: LocalExtractorError.bundleMissing)
            return check
        }
        check.script = defuddle.url.path(percentEncoded: false)
        let options = LocalExtractor.liveOptions(environment: context.environment, homeDirectory: context.homeDirectory)
        let clock = ContinuousClock()
        let begin = clock.now
        do {
            let page = try await LocalExtractor.read(html: extractionHTML, script: defuddle.source, options: options)
            check.ms = milliseconds(clock.now - begin)
            check.title = page.title
            let document = DocumentBuilder.fromMarkdown(page.markdown, title: page.title, source: .text, sourceLabel: "")
            check.units = document.units.map(\.speakText)
            check.ok = page.title == extractionTitle && check.units == extractionUnits
                && document.units.allSatisfy { $0.language == .en }
            if !check.ok {
                check.error = "the page became \(check.units) (title \(page.title ?? "none"), languages "
                    + "\(document.units.map { $0.language?.rawValue ?? "-" }))"
            }
        } catch {
            check.ms = milliseconds(clock.now - begin)
            check.error = message(for: error)
        }
        return check
    }

    /// Build the fixture document, synthesize its first `playedUnits` units (with `voice`'s voice
    /// for each language, at `speed`) and play them back to back offline at `speed`: the output
    /// must last as long as their audio plus their pauses, each over the rate it plays at (speed /
    /// synth_speed: 1 when the engine made it at the speed, the speed when it made it at 1.0).
    static func checkPlayback(
        service: any SpeechSynthesizer, speed: Double = 1.0,
        voice: (SpeechLanguage) -> Voice = { Voice.defaultVoice(for: $0) }
    ) async -> PlaybackCheck {
        var check = PlaybackCheck()
        if speed != 1.0 { check.speed = speed }
        let document = DocumentBuilder.fromMarkdown(fixtureMarkdown, title: fixtureTitle, source: .text, sourceLabel: "")
        check.units = document.units.map(\.speakText)
        check.languages = document.units.map { $0.language?.rawValue ?? "-" }
        check.documentOK = document.title == fixtureTitle && document.units.first?.kind == .title
            && check.units == fixtureUnits.map(\.text) && document.units.map(\.language) == fixtureUnits.map(\.language)
        guard check.documentOK else {
            check.error = "the fixture became \(check.units) \(check.languages)"
            return check
        }
        var items: [AudioItem] = []
        var expected = 0.0
        do {
            for unit in document.units.prefix(playedUnits) {
                guard let language = unit.language else { continue }
                let request = SynthesisRequest(text: unit.speakText, voice: voice(language), speed: speed)
                let result = try await service.synthesize(request)
                if !service.honoursSpeed && result.synthSpeed != 1.0 {
                    check.error = "\(service.engineID) made audio at speed \(result.synthSpeed), not 1.0"
                    return check
                }
                items.append(AudioItem(id: unit.id, wav: result.wav, synthSpeed: result.synthSpeed, pause: unit.pauseAfter))
                expected += (result.duration + unit.pauseAfter) / playbackRate(userSpeed: speed, synthSpeed: result.synthSpeed)
            }
            check.expectedSeconds = expected
            let rendered = try renderOffline(items, userSpeed: speed)
            check.renderedSeconds = rendered.seconds
            check.audibleSeconds = rendered.audibleSeconds
            check.maxDifference = rendered.maxDifference.map(Double.init)
            let tolerance = rendered.maxDifference == nil ? stretchedPlaybackTolerance : playbackTolerance
            check.ok = abs(rendered.seconds - expected) <= tolerance && rendered.audibleSeconds > expected / 2
                && (rendered.maxDifference ?? 0) < 0.01
            if !check.ok {
                check.error = String(format: "rendered %.3f s (audible %.3f s, max difference %@), expected %.3f s",
                                     rendered.seconds, rendered.audibleSeconds,
                                     rendered.maxDifference.map { String(format: "%.4f", $0) } ?? "not measured", expected)
            }
        } catch {
            check.error = message(for: error)
        }
        return check
    }

    /// The time-pitch rate `AudioQueuePlayer` plays a unit at: userSpeed / synthSpeed, clamped
    /// as the player clamps it.
    static func playbackRate(userSpeed: Double, synthSpeed: Double) -> Double {
        min(4, max(0.25, userSpeed / max(synthSpeed, 0.1)))
    }

    /// Play `items` one after the other through an offline `AudioQueuePlayer` at `userSpeed` (the
    /// next one starts when the previous one finishes, as `PlaybackController` does) and measure
    /// where the audio landed in the output: `seconds` is the position of the last audible sample
    /// plus what follows it in the units (the rest of the last one and its pause, at its rate), so
    /// a gap or a cut between units shows; `maxDifference` compares the output with the units'
    /// samples and pauses laid end to end, when every unit plays at rate 1 (nil when the player
    /// time-stretches: the samples differ by design).
    static func renderOffline(
        _ items: [AudioItem], userSpeed: Double = 1.0
    ) throws -> (seconds: Double, audibleSeconds: Double, maxDifference: Float?) {
        guard let first = items.first, let last = items.last else { return (0, 0, 0) }
        let rate = AudioQueuePlayer.sampleRate
        var expected: [Float] = []
        for item in items {
            expected += try WAVDecoder.decode(item.wav).samples
            expected += [Float](repeating: 0, count: Int((item.pause * rate).rounded()))
        }
        let rates = items.map { playbackRate(userSpeed: userSpeed, synthSpeed: $0.synthSpeed) }
        let stretched = rates.contains { abs($0 - 1) >= 0.001 }
        let player = try AudioQueuePlayer(offlineMaximumFrameCount: 4_096)
        player.userSpeed = userSpeed
        var next = 1
        var finished = false
        var playError: (any Error)?
        player.onFinished = { [unowned player] _ in
            guard next < items.count else {
                finished = true
                return
            }
            do {
                try player.play(items[next])
            } catch {
                playError = error
            }
            next += 1
        }
        let slowest = rates.min() ?? 1
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let output = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(expected.count) / slowest + 4 * rate)),
              let channel = output.floatChannelData?[0] else {
            throw AudioOutputError.engine("could not allocate the output buffer")
        }
        try player.play(first)
        while !finished, playError == nil, output.frameLength + 1_024 <= output.frameCapacity {
            try player.render(1_024, into: output)
        }
        if let playError { throw playError }
        guard finished else { throw AudioOutputError.engine("playback did not finish") }
        try player.render(AVAudioFrameCount(rate), into: output)  // the last unit's tail
        let threshold: Float = 0.001
        let rendered = Int(output.frameLength)
        guard let lastExpected = expected.lastIndex(where: { abs($0) > threshold }),
              let firstOutput = (0..<rendered).first(where: { abs(channel[$0]) > threshold }),
              let lastOutput = (0..<rendered).last(where: { abs(channel[$0]) > threshold }) else {
            throw AudioOutputError.engine("the output is silent")
        }
        let worst: Float? = stretched
            ? nil
            : (0..<min(expected.count, rendered)).reduce(Float(0)) { max($0, abs(channel[$1] - expected[$1])) }
        let tail = Double(expected.count - lastExpected) / playbackRate(userSpeed: userSpeed, synthSpeed: last.synthSpeed)
        return ((Double(lastOutput) + tail) / rate, Double(lastOutput - firstOutput) / rate, worst)
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
