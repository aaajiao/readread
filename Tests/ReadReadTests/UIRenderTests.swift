import AppKit
import SwiftUI
import XCTest

@testable import ReadRead

/// Offscreen renders of the panel, the voice list and the Settings window, for a person to look
/// at (verification of the UI, R4-07 … R4-25). Opt in:
///
///     READREAD_RENDER_UI=1 READREAD_RENDER_DIR=<dir> swift test --filter UIRenderTests
///
/// Each view is hosted in an NSHostingView inside an NSWindow that is never ordered in (nothing
/// appears on screen), over a drawn backdrop (the panel is glass: something has to be behind it),
/// and captured with `cacheDisplay(in:to:)` (ImageRenderer cannot draw AppKit-backed controls).
/// The app state runs on fakes: no server, no audio, no network, no user defaults. The PNGs are
/// checked only for having content; whether they look right is for the person reading them.
@MainActor
final class UIRenderTests: XCTestCase {
    private var directory: URL!
    private var scratch: URL!

    override func setUp() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["READREAD_RENDER_UI"] == "1",
                          "set READREAD_RENDER_UI=1 and READREAD_RENDER_DIR=<dir> to render the UI to PNGs")
        let path = try XCTUnwrap(environment["READREAD_RENDER_DIR"], "READREAD_RENDER_DIR: where the PNGs go")
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scratch = try makeTemporaryDirectory()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    // MARK: - The panel
    //
    // `<name>-glass.png` is the whole panel (ContentView) on its glass. Offscreen, everything the
    // glass draws vibrant (secondary text, some icons) comes out as dark as primary text, in light
    // and dark appearance alike, so the other renders show the panel's content (PanelContent) on
    // the window background: there the hierarchy of the text, the dimming and dark mode show.

    func testInputMode() async throws {
        let harness = try Harness(scratch: scratch)
        try await render("input-glass", size: Self.panel) { ContentView(appState: harness.state) }
        try await render("input", size: Self.panel) { Self.flat(harness.state) }
        try await render("input-dark", size: Self.panel, appearance: .darkAqua) { Self.flat(harness.state) }
    }

    func testInputModeWithALoadError() async throws {
        let harness = try Harness(scratch: scratch)
        let url = try XCTUnwrap(URL(string: "https://example.com/long-read"))
        harness.loader.fail(.url(url), with: LoadError.quota)
        harness.state.urlInput = "https://example.com/long-read"
        harness.state.submit()
        await waitUntil { harness.state.errorMessage != nil }
        try await render("input-error", size: Self.panel) { Self.flat(harness.state) }
    }

    func testReadingChinese() async throws {
        let harness = try Harness(scratch: scratch, fixtures: ["zh_plain"])
        try await harness.open(markdown: Self.chineseArticle, title: "秋天的公园", domain: "example.com")
        try await harness.playFixtureSentence("zh_plain", at: 2.3)  // 一起
        try await render("reading-playing-zh-glass", size: Self.panel) { ContentView(appState: harness.state) }
        try await render("reading-playing-zh", size: Self.panel) { Self.flat(harness.state) }
        try await render("reading-playing-zh-dark", size: Self.panel, appearance: .darkAqua) { Self.flat(harness.state) }

        harness.state.perform(.togglePlayPause)
        await waitUntil { harness.state.player.state == .paused }
        try await render("reading-paused-zh", size: Self.panel) { Self.flat(harness.state) }
    }

    func testReadingChineseInLargeText() async throws {
        let harness = try Harness(scratch: scratch, fixtures: ["zh_plain"], fontSize: 20)
        try await harness.open(markdown: Self.chineseArticle, title: "秋天的公园", domain: "example.com")
        try await harness.playFixtureSentence("zh_plain", at: 3.4)  // 散步
        try await render("reading-playing-zh-large", size: Self.panel) { Self.flat(harness.state) }
        try await render("reading-playing-zh-large-resized", size: CGSize(width: 560, height: 720)) {
            Self.flat(harness.state)
        }
    }

    func testReadingEnglish() async throws {
        let harness = try Harness(scratch: scratch, fixtures: ["en_sentence"])
        try await harness.open(markdown: Self.englishArticle, title: "Reading Aloud in London", domain: "example.org")
        try await harness.playFixtureSentence("en_sentence", at: 3.6)  // Smith
        try await render("reading-playing-en", size: Self.panel) { Self.flat(harness.state) }
        try await render("reading-playing-en-dark", size: Self.panel, appearance: .darkAqua) { Self.flat(harness.state) }
    }

    /// A 1 MB novel pasted as Markdown, one paragraph per line, which Markdown joins into one
    /// block of some 340,000 characters (F3): the next sentence and a jump to the middle hold the
    /// main thread for milliseconds, not the second each took while the block was one `Text`.
    /// Also renders `reading-novel.png` (the block's rows read as one paragraph).
    func testAHugeMarkdownBlockStaysResponsive() async throws {
        let lines = try Fixtures.text("text/zh_novel_singlenl.txt").split(separator: "\n").filter { !$0.isEmpty }
        var markdown = ""
        while markdown.utf8.count < 1_000_000 { markdown += lines.joined(separator: "\n") + "\n" }
        let harness = try Harness(scratch: scratch)
        try await harness.open(markdown: markdown, title: "长篇小说", domain: "example.com")
        let document = try XCTUnwrap(harness.state.document)
        let longest = document.blocks.map(\.text.count).max() ?? 0
        XCTAssertGreaterThan(longest, 300_000, "the Markdown path joins the lines into one block")

        let frame = CGRect(origin: .zero, size: Self.panel)
        let hosting = NSHostingView(rootView: Self.flat(harness.state).frame(width: frame.width, height: frame.height))
        hosting.sizingOptions = []
        hosting.frame = frame
        let window = RenderWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil }
        XCTAssertFalse(window.isVisible, "never on screen")
        func update() -> Duration {
            let start = ContinuousClock.now
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            return ContinuousClock.now - start
        }
        for _ in 0..<10 {
            _ = update()
            try await Task.sleep(for: .milliseconds(20))
        }
        // The longest the main actor is held while sentences change (SwiftUI updates on its turn).
        let meter = Task { @MainActor () -> Duration in
            var longest = Duration.zero
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                let now = ContinuousClock.now
                longest = max(longest, now - last)
                last = now
            }
            return longest
        }
        var next: [Duration] = []
        for _ in 0..<12 {
            let before = harness.state.player.currentUnit
            harness.state.perform(.nextSentence)
            XCTAssertEqual(harness.state.player.currentUnit, before + 1)
            next.append(update())
            try await Task.sleep(for: .milliseconds(30))
        }
        harness.state.seek(to: document.units.count / 2)
        let jump = update()
        try await Task.sleep(for: .milliseconds(100))
        let jumpSettled = update()
        meter.cancel()
        let stall = await meter.value
        let median = next.sorted()[next.count / 2]
        print("NOVEL: longest block \(longest) characters, \(document.units.count) units; next sentence + layout: median \(median), "
              + "max \(next.max() ?? .zero); jump to the middle + layout \(jump) (then \(jumpSettled)); main actor held \(stall) at most")
        XCTAssertLessThan(median, .milliseconds(50))
        XCTAssertLessThan(jump, .milliseconds(500))
        XCTAssertLessThan(stall, .milliseconds(500), "the main actor was held for \(stall)")
        try await render("reading-novel", size: Self.panel) { Self.flat(harness.state) }
    }

    /// The panel's content without the glass, on the window background.
    private static func flat(_ state: AppState) -> some View {
        PanelContent(appState: state)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    func testAnErrorBannerInReadingMode() async throws {
        let harness = try Harness(scratch: scratch)
        harness.synth.failures[0] = TTSError.crashed(status: -9, detail: """
            Traceback (most recent call last):
              File "readread_tts/engine.py", line 212, in synthesize
                audio = session.run(None, inputs)
            onnxruntime.capi.onnxruntime_pybind11_state.RuntimeException: [ONNXRuntimeError] : 6 : \
            RUNTIME_EXCEPTION : Non-zero status code returned while running Expand node.
            """)
        harness.state.urlInput = "今天天气很好，我们一起去公园散步吧。公园里的银杏叶已经变黄了。"
        harness.state.submit()
        await waitUntil { harness.state.player.state.isFailed }
        XCTAssertTrue(harness.state.offersSystemVoice)
        try await render("error-banner", size: Self.panel) { Self.flat(harness.state) }
    }

    // MARK: - Voices and Settings

    func testTheVoiceLists() async throws {
        let harness = try Harness(scratch: scratch)
        harness.state.selectVoice(try XCTUnwrap(Voice.voices(for: .en).first { $0.id == "bf_emma" }))
        try await render("voice-picker-en", size: CGSize(width: 250, height: 320)) {
            VoiceListView(appState: harness.state, language: .en)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        try await render("voice-picker-zh", size: CGSize(width: 250, height: 150)) {
            VoiceListView(appState: harness.state, language: .zh)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    func testEverySettingsTab() async throws {
        let harness = try Harness(scratch: scratch)
        harness.loginItem.status = .requiresApproval
        harness.state.refreshLoginItemStatus()
        for tab in SettingsTab.allCases {
            try await render("settings-\(tab.rawValue)", size: SettingsView.size(for: tab)) {
                SettingsView(appState: harness.state, tab: tab)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        try await render("settings-voices-dark", size: SettingsView.size(for: .voices), appearance: .darkAqua) {
            SettingsView(appState: harness.state, tab: .voices)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    // MARK: - Content

    static let panel = ReadingPreferences.defaultPanelSize

    static let chineseArticle = """
        今天天气很好，我们一起去公园散步吧。公园里的银杏叶已经变黄了，风一吹，叶子就像金色的蝴蝶一样飞舞。

        我们沿着湖边慢慢地走，看见几位老人在亭子里下棋，孩子们在草地上放风筝。远处传来一阵阵笑声。

        走累了，我们在长椅上坐下来，喝一口热茶，看着夕阳慢慢落下。这样的下午简单又安静，让人觉得生活其实很美好。

        回家的路上，街边的小店亮起了灯。卖烤红薯的老爷爷笑着招呼我们，香味飘满了整条街。

        晚上，我把今天拍的照片整理好，发给远方的朋友。她回复说，明年秋天也想来这里走一走。
        """

    static let englishArticle = """
        On 21 October 2024, Dr. Smith read 3.5 chapters of the e-book aloud in London. The audience listened \
        quietly while the rain tapped on the tall windows of the old library.

        Afterwards, several listeners asked how long it had taken to prepare. "About a week," she said, \
        "mostly choosing the passages."

        The next reading is planned for the spring, when the garden behind the library opens again.
        """

    private enum LoadError: LocalizedError {
        case quota
        var errorDescription: String? {
            "defuddle.md answered HTTP 429: the free quota (1,000 pages a month) is used up. Try again next month, or switch Settings › Reading › Read web pages to “On this Mac first”."
        }
    }

    // MARK: - Rendering

    /// Renders `content` at `size` to `<directory>/<name>.png` and checks the image has text in it.
    private func render(_ name: String, size: CGSize, appearance appearanceName: NSAppearance.Name = .aqua,
                        @ViewBuilder _ content: () -> some View) async throws {
        let dark = appearanceName == .darkAqua
        let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
        let frame = CGRect(origin: .zero, size: size)
        let hosting = NSHostingView(rootView: content()
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light))
        hosting.sizingOptions = []
        hosting.frame = frame
        hosting.appearance = appearance
        let backdrop = Backdrop(frame: frame)
        backdrop.addSubview(hosting)
        let window = RenderWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = backdrop
        defer { window.contentView = nil }
        XCTAssertFalse(window.isVisible, "never on screen")

        // SwiftUI lays out, runs onAppear (the scroll to the current sentence) and settles.
        for _ in 0..<20 {
            backdrop.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
        backdrop.layoutSubtreeIfNeeded()
        backdrop.displayIfNeeded()

        let bitmap = try XCTUnwrap(backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds))
        // Dynamic colours resolve against the drawing appearance, not the window's.
        appearance.performAsCurrentDrawingAppearance {
            backdrop.cacheDisplay(in: backdrop.bounds, to: bitmap)
        }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appending(path: "\(name).png"))
        XCTAssertGreaterThan(Self.textPixelShare(bitmap, dark: dark), 0.0002,
                             "\(name).png has (almost) no text: the view did not draw")
    }

    /// Reports itself key and main, so controls draw as in the panel the user is typing in (a
    /// window never ordered in is neither).
    private final class RenderWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
    }

    /// The share of sampled pixels that are text-dark (light appearance) or text-light (dark).
    private static func textPixelShare(_ bitmap: NSBitmapImageRep, dark: Bool) -> Double {
        var samples = 0
        var text = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                samples += 1
                let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
                if dark ? luminance > 0.85 : luminance < 0.2 { text += 1 }
            }
        }
        return samples == 0 ? 0 : Double(text) / Double(samples)
    }

    /// A stand-in for the desktop behind the panel.
    private final class Backdrop: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let gradient = NSGradient(colors: [
                NSColor(srgbRed: 0.33, green: 0.45, blue: 0.62, alpha: 1),
                NSColor(srgbRed: 0.66, green: 0.52, blue: 0.58, alpha: 1),
            ])
            gradient?.draw(in: bounds, angle: 35)
        }
    }

    // MARK: - App state on fakes

    @MainActor
    private final class Harness {
        let synth = FakeSynthesizer()
        let system = FakeSynthesizer()
        let output = FakeAudioOutput()
        let previewOutput = FakeAudioOutput()
        let store = MemoryPreferences()
        let loader = FakeDocumentLoader()
        let pasteboard = FakePasteboard()
        let workspace = FakeWorkspace()
        let loginItem = FakeLoginItem()
        let state: AppState
        /// The fixture texts and their real token timings (Fixtures/timings).
        private var fixtures: [String: SynthesisResult] = [:]
        private var fixtureTexts: [String: String] = [:]

        init(scratch: URL, fixtures names: [String] = [], fontSize: Double? = nil) throws {
            if let fontSize { store.set(fontSize, forKey: "font_size") }
            system.engineID = "apple"
            system.status = .ready
            synth.status = .ready
            loginItem.status = .enabled
            for name in names {
                let data = try Fixtures.data("timings/\(name).json")
                var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let text = try XCTUnwrap(json["input_text"] as? String)
                json["audio"] = minimalWAV.base64EncodedString()
                fixtures[text] = try TTSClient.decodeSynthesis(JSONSerialization.data(withJSONObject: json), requestedSpeed: 1)
                fixtureTexts[name] = text
            }
            let fixtures = self.fixtures
            synth.handler = { request in
                if let result = fixtures[request.text] { return result }
                return FakeSynthesizer.result(text: request.text, duration: 2, requestID: request.requestID)
            }
            let sleeper = TestSleeper()
            sleeper.setDefault(.immediate)
            let system = self.system
            state = AppState(
                engine: synth, output: output, defaults: store, loadDocument: loader.load,
                positions: MemoryPositions(), nowPlaying: nil, systemVoice: { system },
                sleep: { try await sleeper.sleep($0) },
                pasteboard: pasteboard, workspace: workspace, loginItem: loginItem, previewOutput: previewOutput,
                directories: RuntimeDirectories(
                    logDirectory: scratch.appending(path: "logs").path,
                    cacheDirectory: scratch.appending(path: "cache").path,
                    userLexicon: scratch.appending(path: "support/lexicon_zh.json").path))
        }

        /// Loads a web page and waits until its first sentence plays.
        func open(markdown: String, title: String, domain: String) async throws {
            let url = "https://\(domain)/article"
            loader.set("# \(title)\n\n\(markdown)", title: title, domain: domain, for: url)
            state.urlInput = url
            state.submit()
            await waitUntil { self.state.player.state == .playing }
        }

        /// Reads the fixture's sentence, `time` seconds into it (the word spoken then is lit).
        func playFixtureSentence(_ name: String, at time: Double) async throws {
            let text = try XCTUnwrap(fixtureTexts[name])
            let document = try XCTUnwrap(state.document)
            let unit = try XCTUnwrap(document.units.firstIndex { $0.speakText == text },
                                     "no unit reads \(text): \(document.units.map(\.speakText))")
            state.seek(to: unit)
            await waitUntil { self.state.player.currentUnit == unit && self.state.player.state == .playing }
            await waitUntil { self.state.player.wordTimeline?.unit == unit }
            output.currentTime = time
        }
    }
}
