import Foundation

/// Plays a `ReadingDocument` unit by unit: synthesizes the current unit first and prefetches
/// a few ahead (one request at a time), keeps the audio in a cache so Next/Previous are
/// instant, applies speed instantly by rate and re-synthesizes only after the slider rests,
/// and remembers where each document was left.
///
/// States: idle (nothing playing), buffering (wants to play, audio not there yet), playing,
/// paused, failed(message), finished. User edits (`userSet…`) and programmatic restores
/// (`restore(settings:)`) are separate, so restoring preferences never restarts audio (H2, R4-27).
@MainActor
@Observable
final class PlaybackController {
    enum State: Equatable {
        case idle
        case buffering
        case playing
        case paused
        case failed(String)
        case finished
    }

    /// Units synthesized ahead of the current one.
    static let prefetchAhead = 3
    /// The slider must rest this long before prefetched audio is re-synthesized (H6).
    static let speedDebounce: Duration = .milliseconds(300)
    /// A unit change is written to the positions file after this long without another.
    static let positionSaveDelay: Duration = .seconds(2)
    /// Measured speech rates at speed 1.0, for progress until real durations are known.
    static let charactersPerSecond: [SpeechLanguage: Double] = [.zh: 5.2, .en: 15.4]

    private(set) var document: ReadingDocument?
    private(set) var state: State = .idle
    private(set) var currentUnit = 0
    /// The error behind `.failed`, for the banner (TTSError.isResourcesMissing / isServerFailure).
    private(set) var lastError: (any Error)?
    /// Counts failures, so a dismissed banner comes back for the next one.
    private(set) var failureCount = 0
    private(set) var settings = PlaybackSettings()
    /// The word timings of the unit loaded in the output (playing or paused), placed on its
    /// display text; nil before its audio plays and for an engine without token timings (the
    /// reading view then highlights the sentence alone).
    private(set) var wordTimeline: LoadedWordTimeline?
    /// Changes whenever a real duration replaces an estimate, so `progress` is re-read.
    private var durationRevision = 0

    private(set) var synthesizer: any SpeechSynthesizer
    @ObservationIgnored private let output: any AudioOutput
    @ObservationIgnored private let positions: (any ReadingPositionStoring)?
    @ObservationIgnored private let nowPlaying: (any NowPlayingPublishing)?
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored let cache: SynthesisCache

    private struct InFlight {
        let id: Int
        let key: SynthesisKey
        let task: Task<Void, Never>
    }

    @ObservationIgnored private var inFlight: InFlight?
    @ObservationIgnored private var requestCounter = 0
    /// The unit loaded in the output (playing or paused), and the speed its audio was made at.
    @ObservationIgnored private var loadedUnit: Int? {
        didSet {
            if let wordTimeline, wordTimeline.unit != loadedUnit { self.wordTimeline = nil }
        }
    }
    @ObservationIgnored private var loadedSynthSpeed = 1.0
    /// Playing or buffering, as opposed to paused/stopped.
    @ObservationIgnored private var wantsPlayback = false
    @ObservationIgnored private var speedSettled = true
    @ObservationIgnored private var speedTask: Task<Void, Never>?
    @ObservationIgnored private var positionTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    /// Prefetches that failed: not requested again until their unit is needed.
    @ObservationIgnored private var failedPrefetches: Set<SynthesisKey> = []
    /// Seconds at speed 1.0, pause included: real ones once synthesized, else estimates.
    @ObservationIgnored private var knownDurations: [Int: Double] = [:]
    @ObservationIgnored private var estimates: [Double] = []
    /// The progress last shown: a real duration replacing a smaller estimate ahead grows the
    /// total, which must not move the bar back. Reset when the position changes otherwise.
    @ObservationIgnored private var progressShown = 0.0

    init(
        synthesizer: any SpeechSynthesizer,
        output: any AudioOutput,
        positions: (any ReadingPositionStoring)? = nil,
        nowPlaying: (any NowPlayingPublishing)? = nil,
        cacheCapacity: Int = 40,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.synthesizer = synthesizer
        self.output = output
        self.positions = positions
        self.nowPlaying = nowPlaying
        self.cache = SynthesisCache(capacity: cacheCapacity)
        self.sleep = sleep
        self.now = now
        output.onFinished = { [weak self] id in self?.outputFinished(id) }
        output.onFailure = { [weak self] error in self?.fail(error) }
        nowPlaying?.onCommand = { [weak self] command in self?.handle(command) }
    }

    // MARK: - Reading

    var engineStatus: SpeechEngineStatus { synthesizer.status }

    /// Seconds into the loaded unit's audio, in synthesized time (the time token timings use).
    /// Not observed: the reading view samples it while the unit plays.
    var playbackTime: Double { output.currentTime }

    /// Readable units (the ones with a language), for "x / N".
    var readableCount: Int { document?.units.lazy.filter { $0.language != nil }.count ?? 0 }

    /// 1-based position of the current unit among the readable ones.
    var readablePosition: Int {
        guard let document, document.units.indices.contains(currentUnit) else { return 0 }
        return document.units[...currentUnit].lazy.filter { $0.language != nil }.count
    }

    /// 0…1 by audio time: real durations where known, estimates elsewhere; 1 when finished.
    /// It only moves forward while playing on (see `progressShown`).
    var progress: Double {
        _ = durationRevision
        guard let document, !document.units.isEmpty else { return 0 }
        if state == .finished { return 1 }
        let total = totalDuration
        guard total > 0 else { return 0 }
        var elapsed = 0.0
        for index in 0..<min(currentUnit, document.units.count) { elapsed += duration(of: index) }
        if loadedUnit == currentUnit {
            elapsed += min(output.currentTime * loadedSynthSpeed, duration(of: currentUnit))
        }
        progressShown = max(progressShown, min(1, elapsed / total))
        return progressShown
    }

    /// Open `document` at its saved position (when the content hash still matches). A document
    /// still open (a drop, the clipboard or Services replace it) gets its position saved first, as
    /// `close()` would; one read to the end has none.
    func open(_ document: ReadingDocument, settings: PlaybackSettings, autoplay: Bool) {
        if self.document != nil, state != .finished { savePositionNow() }
        tearDown()
        cache.removeAll()
        failedPrefetches.removeAll()
        knownDurations.removeAll()
        self.document = document
        self.settings = settings
        output.userSpeed = settings.speed
        lastError = nil
        recomputeEstimates()
        var start = firstReadable(from: 0) ?? 0
        if let saved = positions?.position(for: document.positionKey), saved.contentHash == document.contentHash,
           document.units.indices.contains(saved.unit), let unit = firstReadable(from: saved.unit) {
            start = unit
        }
        currentUnit = start
        progressShown = 0
        setState(.idle)
        if autoplay { play() }
    }

    func play() {
        guard document != nil else { return }
        if retryTask != nil {
            // The server is restarting: read once it is back (the retry starts the unit).
            wantsPlayback = true
            setState(.buffering)
            return
        }
        switch state {
        case .playing, .buffering:
            return
        case .finished:
            currentUnit = firstReadable(from: 0) ?? 0
            progressShown = 0
        case .failed:
            lastError = nil
            failedPrefetches.removeAll()
        case .idle, .paused:
            break
        }
        guard isReadable(currentUnit) || firstReadable(from: currentUnit) != nil else {
            finish()
            return
        }
        if !isReadable(currentUnit), let unit = firstReadable(from: currentUnit) { currentUnit = unit }
        wantsPlayback = true
        if state == .paused, loadedUnit == currentUnit {
            do {
                try output.resume()
                setState(.playing)
            } catch {
                fail(error)
            }
            return
        }
        startCurrentUnit()
    }

    func pause() {
        switch state {
        case .playing, .buffering:
            // Buffering too: the engine may still run after the last unit (it keeps the Mac
            // from idle sleep while it does).
            output.pause()
        default:
            return
        }
        wantsPlayback = false
        setState(.paused)
    }

    func toggle() {
        if state == .playing || state == .buffering { pause() } else { play() }
    }

    /// Stop playing; the position stays (Play starts the current sentence again). After the
    /// end, Play starts from the beginning.
    func stop() {
        guard document != nil else { return }
        wantsPlayback = false
        cancelInFlight()
        cancelRetry()
        output.stop()
        loadedUnit = nil
        lastError = nil
        if state == .finished {
            currentUnit = firstReadable(from: 0) ?? 0
            progressShown = 0
        } else {
            savePositionNow()
        }
        setState(.idle)
    }

    func close() {
        guard document != nil else { return }
        stop()
        tearDown()
        cache.removeAll()
        document = nil
        currentUnit = 0
        progressShown = 0
        setState(.idle)
        nowPlaying?.clear()
    }

    func next() {
        guard let target = nextReadable(after: currentUnit) else { return }
        jump(to: target)
    }

    func previous() {
        guard let target = previousReadable(before: currentUnit) else { return }
        jump(to: target)
    }

    func seek(to unit: Int) {
        guard let document, !document.units.isEmpty else { return }
        let clamped = min(max(0, unit), document.units.count - 1)
        guard let target = firstReadable(from: clamped) ?? previousReadable(before: clamped) else { return }
        jump(to: target)
    }

    /// After a failure: restart the server when it was the problem, then read the failed
    /// unit again.
    func retry() {
        guard case .failed = state else { return }
        let restart = (lastError as? TTSError)?.isServerFailure ?? false
        guard restart else {
            play()
            return
        }
        lastError = nil
        failedPrefetches.removeAll()
        wantsPlayback = true
        setState(.buffering)
        let synthesizer = self.synthesizer
        retryTask = Task { [weak self] in
            do {
                try await synthesizer.restart()
            } catch {
                guard !Task.isCancelled else { return }
                self?.retryTask = nil
                self?.fail(error)
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            if self.state == .buffering, self.wantsPlayback {
                self.startCurrentUnit()
            } else {
                self.pump()
            }
        }
    }

    // MARK: - User edits and programmatic restores

    /// The slider: the rate changes now; prefetched audio is re-synthesized once it rests.
    func userSetSpeed(_ speed: Double) {
        let normalized = SynthesisRequest.normalizedSpeed(speed)
        guard normalized != settings.speed else { return }
        settings.speed = normalized
        output.userSpeed = normalized
        publishNowPlaying()
        guard synthesizer.honoursSpeed else { return }
        speedSettled = false
        speedTask?.cancel()
        let sleep = self.sleep
        speedTask = Task { [weak self] in
            do { try await sleep(Self.speedDebounce) } catch { return }
            guard !Task.isCancelled else { return }
            self?.speedTask = nil
            self?.speedSettled = true
            self?.pump()
        }
    }

    /// A new voice for its language: that language's cached audio goes; the current unit
    /// restarts with it while playing and stays paused while paused (R1-08, R4-08).
    func userSetVoice(_ voice: Voice) {
        let old = settings.voice(for: voice.language)
        guard old.id != voice.id else { return }
        settings.voices[voice.language] = voice
        cache.removeAll { $0.voiceID == old.id }
        failedPrefetches = failedPrefetches.filter { $0.voiceID != old.id }
        if let inFlight, inFlight.key.voiceID == old.id { cancelInFlight() }
        let current = document.flatMap { $0.units.indices.contains(currentUnit) ? $0.units[currentUnit] : nil }
        if current?.language(under: settings.languageChoice) == voice.language {
            restartCurrentUnitForNewAudio()
        } else {
            pump()
        }
    }

    func userSetLanguageChoice(_ choice: LanguageChoice) {
        guard choice != settings.languageChoice else { return }
        let before = key(for: currentUnit)
        settings.languageChoice = choice
        failedPrefetches.removeAll()
        recomputeEstimates()
        progressShown = 0
        if let inFlight, key(for: inFlight.key.unit) != inFlight.key { cancelInFlight() }
        if key(for: currentUnit) != before {
            restartCurrentUnitForNewAudio()
        } else {
            pump()
        }
    }

    /// Settings from preferences: no restart, nothing saved; later units use them.
    func restore(settings newSettings: PlaybackSettings) {
        settings = newSettings
        output.userSpeed = newSettings.speed
        speedTask?.cancel()
        speedTask = nil
        speedSettled = true
        recomputeEstimates()
        progressShown = 0
        if let inFlight, key(for: inFlight.key.unit) != inFlight.key { cancelInFlight() }
        pump()
        publishNowPlaying()
    }

    /// Another engine (the system voice, later the HQ engine): its own cache entries.
    func setSynthesizer(_ synthesizer: any SpeechSynthesizer) {
        guard synthesizer !== self.synthesizer else { return }
        cancelInFlight()
        cancelRetry()
        self.synthesizer.setPlaybackActive(false)
        self.synthesizer = synthesizer
        cache.removeAll()
        failedPrefetches.removeAll()
        synthesizer.setPlaybackActive(state == .playing || state == .buffering)
        if state == .buffering, wantsPlayback { startCurrentUnit() } else { pump() }
    }

    /// App termination.
    func shutdown() {
        stop()
        synthesizer.shutdown()
    }

    // MARK: - Internals

    private func setState(_ newState: State) {
        if state != newState { state = newState }
        synthesizer.setPlaybackActive(newState == .playing || newState == .buffering)
        publishNowPlaying()
    }

    private func tearDown() {
        wantsPlayback = false
        cancelInFlight()
        cancelRetry()
        speedTask?.cancel()
        speedTask = nil
        speedSettled = true
        positionTask?.cancel()
        positionTask = nil
        output.stop()
        loadedUnit = nil
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
    }

    private func fail(_ error: any Error) {
        wantsPlayback = false
        cancelInFlight()
        output.stop()
        loadedUnit = nil
        lastError = error
        failureCount += 1
        setState(.failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
    }

    /// The end: the output stops too (a running engine keeps the Mac from idle sleep).
    private func finish() {
        wantsPlayback = false
        cancelInFlight()
        output.stop()
        loadedUnit = nil
        positionTask?.cancel()
        positionTask = nil
        if let document { positions?.removePosition(for: document.positionKey) }
        setState(.finished)
    }

    private func jump(to target: Int) {
        cancelRetry()
        output.stop()
        loadedUnit = nil
        currentUnit = target
        progressShown = 0
        cancelInFlightOutsideWindow()
        schedulePositionSave()
        switch state {
        case .playing, .buffering:
            wantsPlayback = true
            startCurrentUnit()
        case .paused:
            pump()
            publishNowPlaying()
        case .failed:
            lastError = nil
            setState(.paused)
            pump()
        case .finished:
            setState(.idle)
        case .idle:
            publishNowPlaying()
        }
    }

    /// The current unit's audio changed (voice or language): playing → play it again with the
    /// new audio; paused → stay paused, prefetching it.
    private func restartCurrentUnitForNewAudio() {
        switch state {
        case .playing, .buffering:
            output.stop()
            loadedUnit = nil
            startCurrentUnit()
        case .paused:
            if loadedUnit == currentUnit {
                output.stop()
                loadedUnit = nil
            }
            pump()
        default:
            break
        }
    }

    /// Play the current unit from cached audio, or buffer and request it.
    private func startCurrentUnit() {
        guard wantsPlayback, let document, document.units.indices.contains(currentUnit) else { return }
        guard let result = audio(for: currentUnit) else {
            loadedUnit = nil
            setState(.buffering)
            pump()
            return
        }
        let unit = document.units[currentUnit]
        do {
            try output.play(AudioItem(id: currentUnit, wav: result.wav, synthSpeed: result.synthSpeed, pause: unit.pauseAfter))
        } catch {
            // Bad audio: forget it, so Retry synthesizes it again.
            cache.removeAll { $0.unit == currentUnit }
            fail(error)
            return
        }
        loadedUnit = currentUnit
        loadedSynthSpeed = result.synthSpeed
        wordTimeline = result.tokens.isEmpty ? nil : LoadedWordTimeline(
            unit: currentUnit,
            timeline: WordTimeline(tokens: result.tokens, displayText: document.displayText(of: unit)))
        setState(.playing)
        pump()
    }

    private func outputFinished(_ id: Int) {
        guard id == loadedUnit, id == currentUnit else { return }
        loadedUnit = nil
        guard let next = nextReadable(after: currentUnit) else {
            finish()
            return
        }
        currentUnit = next
        schedulePositionSave()
        if wantsPlayback {
            startCurrentUnit()
        } else {
            pump()
            publishNowPlaying()
        }
    }

    private func handle(_ command: NowPlayingCommand) {
        switch command {
        case .play: play()
        case .pause: pause()
        case .toggle: toggle()
        case .next: next()
        case .previous: previous()
        }
    }

    // MARK: - Synthesis

    private func isActive() -> Bool {
        switch state {
        case .playing, .buffering, .paused: true
        case .idle, .failed, .finished: false
        }
    }

    /// One request at a time: the current unit when it has no audio (and is not playing
    /// already), then (once the speed rests) the next `prefetchAhead` readable units.
    private func pump() {
        guard inFlight == nil, retryTask == nil, isActive(), let target = nextSynthesisTarget(),
              let key = key(for: target), let document else { return }
        let unit = document.units[target]
        guard let language = unit.language(under: settings.languageChoice) else { return }
        let request = SynthesisRequest(text: unit.speakText, voice: settings.voice(for: language), speed: key.speed)
        let synthesizer = self.synthesizer
        requestCounter += 1
        let id = requestCounter
        let task = Task { [weak self] in
            let outcome: Result<SynthesisResult, any Error>
            do {
                outcome = .success(try await synthesizer.synthesize(request))
            } catch {
                outcome = .failure(error)
            }
            self?.synthesisFinished(id: id, key: key, outcome: outcome)
        }
        inFlight = InFlight(id: id, key: key, task: task)
    }

    private func nextSynthesisTarget() -> Int? {
        if isReadable(currentUnit), loadedUnit != currentUnit, audio(for: currentUnit) == nil {
            // A current unit that failed is requested again only to play it (Play, Retry),
            // never again and again while paused.
            guard let key = key(for: currentUnit), failedPrefetches.contains(key), !(state == .buffering && wantsPlayback) else {
                return currentUnit
            }
        }
        guard speedSettled else { return nil }
        var index = currentUnit
        for _ in 0..<Self.prefetchAhead {
            guard let next = nextReadable(after: index) else { break }
            index = next
            if let key = key(for: next), !cache.contains(key), !failedPrefetches.contains(key) { return next }
        }
        return nil
    }

    private func synthesisFinished(id: Int, key: SynthesisKey, outcome: Result<SynthesisResult, any Error>) {
        guard let inFlight, inFlight.id == id else { return }  // cancelled or replaced
        self.inFlight = nil
        switch outcome {
        case .success(let result):
            cache.insert(result, for: key)
            failedPrefetches.remove(key)
            if let unit = document?.units[key.unit] {
                knownDurations[key.unit] = result.duration * result.synthSpeed + unit.pauseAfter
                durationRevision += 1
            }
            if key.unit == currentUnit, state == .buffering, wantsPlayback {
                startCurrentUnit()
                return
            }
        case .failure(let error):
            // The current unit failed: the banner says so, also when paused meanwhile (paused
            // during buffering, or after a jump from a failure on a dead engine).
            if key.unit == currentUnit, state == .buffering || state == .paused {
                fail(error)
                return
            }
            failedPrefetches.insert(key)
        }
        pump()
    }

    private func cancelInFlight() {
        inFlight?.task.cancel()
        inFlight = nil
    }

    /// Jumps cancel a request for a unit that is no longer current or prefetched.
    private func cancelInFlightOutsideWindow() {
        guard let inFlight else { return }
        var windowEnd = currentUnit
        for _ in 0..<Self.prefetchAhead {
            guard let next = nextReadable(after: windowEnd) else { break }
            windowEnd = next
        }
        if inFlight.key.unit < currentUnit || inFlight.key.unit > windowEnd { cancelInFlight() }
    }

    /// The cache key for a unit under the current settings and engine; nil for a skipped unit.
    private func key(for index: Int) -> SynthesisKey? {
        guard let document, document.units.indices.contains(index),
              let language = document.units[index].language(under: settings.languageChoice) else { return nil }
        let speed = synthesizer.honoursSpeed ? settings.speed : 1.0
        return SynthesisKey(unit: index, voiceID: settings.voice(for: language).id,
                            speed: SynthesisRequest.normalizedSpeed(speed), engineID: synthesizer.engineID)
    }

    /// Audio for a unit: at the current speed, else at the nearest other speed (time-stretched).
    private func audio(for index: Int) -> SynthesisResult? {
        guard let key = key(for: index) else { return nil }
        if let exact = cache.result(for: key) { return exact }
        return cache.nearest(unit: index, voiceID: key.voiceID, engineID: key.engineID, speed: key.speed)?.result
    }

    // MARK: - Units

    private func isReadable(_ index: Int) -> Bool {
        guard let document, document.units.indices.contains(index) else { return false }
        return document.units[index].language(under: settings.languageChoice) != nil
    }

    private func firstReadable(from index: Int) -> Int? {
        guard let document else { return nil }
        var candidate = max(0, index)
        while candidate < document.units.count {
            if isReadable(candidate) { return candidate }
            candidate += 1
        }
        return nil
    }

    private func nextReadable(after index: Int) -> Int? {
        firstReadable(from: index + 1)
    }

    private func previousReadable(before index: Int) -> Int? {
        var candidate = index - 1
        while candidate >= 0 {
            if isReadable(candidate) { return candidate }
            candidate -= 1
        }
        return nil
    }

    // MARK: - Progress and Now Playing

    private func recomputeEstimates() {
        guard let document else {
            estimates = []
            return
        }
        estimates = document.units.map { unit in
            guard let language = unit.language(under: settings.languageChoice) else { return 0 }
            let rate = Self.charactersPerSecond[language] ?? 10
            return Double(unit.speakText.count) / rate + unit.pauseAfter
        }
        durationRevision += 1
    }

    private func duration(of index: Int) -> Double {
        knownDurations[index] ?? (estimates.indices.contains(index) ? estimates[index] : 0)
    }

    private var totalDuration: Double {
        guard let document else { return 0 }
        var total = 0.0
        for index in document.units.indices { total += duration(of: index) }
        return total
    }

    private func publishNowPlaying() {
        guard let nowPlaying else { return }
        guard let document else {
            nowPlaying.clear()
            return
        }
        let total = totalDuration
        let infoState: NowPlayingInfo.State = switch state {
        case .playing, .buffering: .playing
        case .paused: .paused
        case .idle, .failed, .finished: .stopped
        }
        nowPlaying.update(NowPlayingInfo(
            title: document.title,
            artist: document.sourceLabel,
            elapsed: progress * total,
            duration: total,
            rate: state == .playing ? settings.speed : 0,
            state: infoState
        ))
    }

    // MARK: - Positions

    private func schedulePositionSave() {
        guard positions != nil else { return }
        positionTask?.cancel()
        let sleep = self.sleep
        positionTask = Task { [weak self] in
            do { try await sleep(Self.positionSaveDelay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.savePositionNow()
        }
    }

    private func savePositionNow() {
        positionTask?.cancel()
        positionTask = nil
        guard let positions, let document else { return }
        positions.save(ReadingPosition(unit: currentUnit, contentHash: document.contentHash, date: now()),
                       for: document.positionKey)
    }
}

/// A unit's word timeline, with the unit it belongs to.
struct LoadedWordTimeline: Equatable, Sendable {
    let unit: Int
    let timeline: WordTimeline
}
