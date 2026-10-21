import SwiftUI

/// The `readread-unit://<index>` links that make every sentence of the reading view a tap
/// target: a tap reads from that sentence on (R4-16).
enum ReadingLink {
    static let scheme = "readread-unit"

    static func url(unit: Int) -> URL {
        URL(string: "\(scheme)://\(unit)")!
    }

    /// The unit index of a reading link; nil for any other URL.
    static func unit(from url: URL) -> Int? {
        guard url.scheme == scheme, let host = url.host(), let unit = Int(host), unit >= 0 else { return nil }
        return unit
    }
}

/// When the reading view scrolls to the sentence being read (R4-16). It follows unless the user
/// scrolled (by hand: dragging, the wheel, the trackpad); then it waits until "Back to Current",
/// a sentence the user picks (tap, ←/→), or the next sentence that starts while the one being
/// read is still in view (the user only nudged the text). In view means the sentence's own part
/// of its row (`RowShare`), not just some of the row: a row can be taller than the view.
struct AutoFollow: Equatable {
    /// Settings › Reading › Follow the sentence being read.
    var enabled: Bool
    /// The user scrolled away: following waits.
    private(set) var suspended = false

    init(enabled: Bool) {
        self.enabled = enabled
    }

    /// Following now (and scrolling with the reading).
    var isFollowing: Bool { enabled && !suspended }

    /// A scroll phase of the reading view. Programmatic scrolls are `.animating` (or no phase at
    /// all); a hand on the trackpad, the wheel or the scroll bar is `.interacting`, a fling
    /// after it `.decelerating`.
    mutating func scrollPhaseChanged(to phase: ScrollPhase) {
        if phase == .interacting || phase == .decelerating { suspended = true }
    }

    /// "Back to Current": scroll there and follow again (also when following is off).
    mutating func backToCurrent() {
        suspended = false
    }

    /// The user chose a sentence (tap, ←/→, the transport buttons). Returns whether to scroll.
    mutating func jumped() -> Bool {
        suspended = false
        return enabled
    }

    /// A new sentence started; `inView` = it or the one before it is on screen. Returns whether
    /// to scroll to it.
    mutating func unitChanged(inView: Bool) -> Bool {
        if suspended, inView { suspended = false }
        return isFollowing
    }

    /// The "Back to Current" button shows while the sentence being read is off screen and the
    /// view does not follow it.
    func showsBackToCurrent(currentInView: Bool) -> Bool {
        !currentInView && !isFollowing
    }
}

/// Where to scroll for a unit: a short row is centred; a long one (taller than the view) is
/// placed so the unit's share of it stays in view.
enum ReadingScroll {
    /// Rows longer than this many characters may not fit the view.
    static let longBlock = 280

    static func anchor(unitRange: Range<Int>, blockLength: Int) -> UnitPoint {
        guard blockLength > longBlock else { return .center }
        let middle = Double(unitRange.lowerBound + unitRange.upperBound) / 2
        return UnitPoint(x: 0.5, y: min(1, max(0, middle / Double(blockLength))))
    }
}

/// What the reading view lays out, one `Text` each (H11): every block, a long one cut between
/// its units into rows of about `rowLength` characters. A word change redraws only the row being
/// read, and its cost grows with the row's length: a novel pasted as Markdown is one paragraph of
/// hundreds of thousands of characters, which no `Text` lays out again at 20 Hz. The rows of a
/// block follow each other as lines of one paragraph.
struct ReadingRows: Sendable {
    struct Row: Equatable, Sendable {
        let block: Int
        /// Where the row starts in its block's text (Character offset); its units' ranges are
        /// the block's.
        let offset: Int
        /// Characters.
        let length: Int
        /// Indices into `ReadingDocument.units`.
        let units: Range<Int>
        let text: String

        /// After the block's first row: no paragraph space above it.
        var continuesBlock: Bool { offset > 0 }

        /// A unit's span of the row, from its span of the block.
        func local(_ range: Range<Int>) -> Range<Int> {
            (range.lowerBound - offset)..<(range.upperBound - offset)
        }
    }

    /// A block up to this many characters is one row.
    static let wholeBlock = 1_500
    /// The rows of a longer one are cut after the unit that reaches this many.
    static let rowLength = 1_000

    let rows: [Row]
    /// The row of each unit.
    private let rowOfUnit: [Int]

    init(_ document: ReadingDocument) {
        var rows: [Row] = []
        var rowOfUnit = [Int](repeating: 0, count: document.units.count)
        for (index, block) in document.blocks.enumerated() {
            for row in Self.rows(of: block, at: index, units: document.units) {
                for unit in row.units where rowOfUnit.indices.contains(unit) { rowOfUnit[unit] = rows.count }
                rows.append(row)
            }
        }
        self.rows = rows
        self.rowOfUnit = rowOfUnit
    }

    func row(of unit: Int) -> Int? {
        rowOfUnit.indices.contains(unit) ? rowOfUnit[unit] : nil
    }

    /// Whether `unit` is in view: its row is one of `visibleRows` (nil: not reported yet, so it
    /// counts) and, when the row reported its visible part, the unit's share of the row is in it.
    func shows(_ unit: SpeechUnit, visibleRows: Set<Int>?, shares: [Int: RowShare]) -> Bool {
        guard let index = row(of: unit.id) else { return false }
        if let visibleRows, !visibleRows.contains(index) { return false }
        guard let share = shares[index] else { return true }
        return share.shows(rows[index].local(unit.range), length: rows[index].length)
    }

    /// A block's rows: whole, or cut at the start of the unit after the one that takes a row
    /// to `rowLength` characters (a unit is never cut).
    static func rows(of block: ReadingBlock, at index: Int, units: [SpeechUnit]) -> [Row] {
        let text = block.text
        let length = text.count
        let blockUnits = block.units.clamped(to: 0..<units.count)
        guard length > wholeBlock, blockUnits.count > 1 else {
            return [Row(block: index, offset: 0, length: length, units: blockUnits, text: text)]
        }
        var cuts: [(offset: Int, unit: Int)] = [(0, blockUnits.lowerBound)]
        for unit in blockUnits.dropLast() {
            let next = units[unit + 1].range.lowerBound
            if units[unit].range.upperBound - cuts[cuts.count - 1].offset >= rowLength, next < length,
               next > cuts[cuts.count - 1].offset {
                cuts.append((next, unit + 1))
            }
        }
        var rows: [Row] = []
        var start = text.startIndex
        for (number, cut) in cuts.enumerated() {
            let endOffset = number + 1 < cuts.count ? cuts[number + 1].offset : length
            let endUnit = number + 1 < cuts.count ? cuts[number + 1].unit : blockUnits.upperBound
            let end = text.index(start, offsetBy: endOffset - cut.offset, limitedBy: text.endIndex) ?? text.endIndex
            rows.append(Row(block: index, offset: cut.offset, length: endOffset - cut.offset, units: cut.unit..<endUnit,
                            text: String(text[start..<end])))
            start = end
        }
        return rows
    }
}

/// `ReadingRows` of the document on screen, made once per document.
@MainActor
final class ReadingRowsCache {
    private var key: String?
    private var cached: ReadingRows?

    func rows(for document: ReadingDocument) -> ReadingRows {
        let key = "\(document.contentHash) \(document.blocks.count) \(document.units.count)"
        if let cached, self.key == key { return cached }
        let rows = ReadingRows(document)
        self.key = key
        cached = rows
        return rows
    }
}

/// The part of a row inside the scroll view, as fractions of the row's height (0 = its top), in
/// steps of 1/100. A unit's place in its row is estimated from its characters (a paragraph's
/// lines fill evenly), as `ReadingScroll.anchor` places it.
struct RowShare: Equatable {
    var top: Double
    var bottom: Double

    init(top: Double, bottom: Double) {
        self.top = top
        self.bottom = bottom
    }

    /// From the row's height and the scroll view's bounds in the row's coordinates; nil when none
    /// of the row is visible.
    init?(height: Double, visible: CGRect?) {
        guard let visible, height > 0 else { return nil }
        let top = max(0, Double(visible.minY)) / height
        let bottom = min(height, Double(visible.maxY)) / height
        guard bottom > top else { return nil }
        self.top = (top * 100 + 1e-9).rounded(.down) / 100
        self.bottom = (bottom * 100 - 1e-9).rounded(.up) / 100
    }

    /// Whether some of a span of `range` (Character offsets) of a row `length` long is in view.
    func shows(_ range: Range<Int>, length: Int) -> Bool {
        guard length > 0 else { return true }
        let start = Double(range.lowerBound) / Double(length)
        let end = Double(max(range.upperBound, range.lowerBound + 1)) / Double(length)
        return end > top && start < bottom
    }

    /// Whether the span lies above the part in view.
    func isAbove(_ range: Range<Int>, length: Int) -> Bool {
        length > 0 && Double(range.upperBound) / Double(length) <= top
    }
}

/// The visible part of each row the scroll view has on screen, kept outside SwiftUI's state: it
/// changes as the user scrolls, and only the decisions that follow read it.
@MainActor
final class RowVisibility {
    var shares: [Int: RowShare] = [:]
}

// MARK: - The reading view

/// Reading mode's text and transport: the blocks (lazy, H11), the progress bar and the buttons.
struct ReadingView: View {
    @Bindable var appState: AppState
    let document: ReadingDocument

    var body: some View {
        VStack(spacing: 8) {
            ReadingList(appState: appState, document: document)
                .id(document.positionKey)
                .frame(maxHeight: .infinity)
            TransportBar(appState: appState)
                .padding(.horizontal)
                .padding(.bottom, 10)
        }
    }
}

/// The rows of the document (`ReadingRows`); only the current one redraws while a sentence plays.
struct ReadingList: View {
    @Bindable var appState: AppState
    let document: ReadingDocument
    @State private var follow: AutoFollow
    @State private var layout = ReadingRowsCache()
    /// Rows on screen; nil until the scroll view reports them (treated as "in view").
    @State private var visibleRows: Set<Int>?
    @State private var visibility = RowVisibility()
    /// The sentence being read is within the visible part of its row (Back to Current).
    @State private var currentSentenceVisible = true

    init(appState: AppState, document: ReadingDocument) {
        self.appState = appState
        self.document = document
        _follow = State(initialValue: AutoFollow(enabled: appState.autoFollow))
    }

    private var player: PlaybackController { appState.player }

    var body: some View {
        let rows = layout.rows(for: document)
        let current = unit(at: player.currentUnit)
        let currentRow = current.flatMap { rows.row(of: $0.id) }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows.rows.indices, id: \.self) { index in
                        row(rows.rows[index], index: index, current: current, currentRow: currentRow)
                            // Paragraphs further apart than the lines inside them (line spacing
                            // 0.38 em); a block's later rows continue it as its next lines.
                            .padding(.top, index == 0 ? 0 : rows.rows[index].continuesBlock
                                ? appState.fontSize * 0.38 : (appState.fontSize * 0.9).rounded())
                            .id(index)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 8)
            }
            .onScrollPhaseChange { _, phase in
                follow.scrollPhaseChanged(to: phase)
            }
            .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.02) { ids in
                visibleRows = Set(ids)
            }
            .onChange(of: player.currentUnit) { old, new in
                guard let unit = unit(at: new), let newRow = rows.row(of: unit.id) else { return }
                let previous = self.unit(at: old)
                let previousRow = previous.flatMap { rows.row(of: $0.id) } ?? newRow
                // The new sentence, or the one before it, still in view: the user only nudged the text.
                let inView = isInView(unit, rows: rows) || previous.map { isInView($0, rows: rows) } ?? false
                currentSentenceVisible = isSentenceVisible(unit, rows: rows)
                guard follow.unitChanged(inView: inView) else { return }
                if newRow != previousRow || rows.rows[newRow].length > ReadingScroll.longBlock {
                    scroll(proxy, to: unit, rows: rows, animated: true)
                }
            }
            .onChange(of: appState.navigationCount) {
                if follow.jumped() { scroll(proxy, to: unit(at: player.currentUnit), rows: rows, animated: true) }
            }
            .onChange(of: appState.autoFollow) { _, enabled in
                follow.enabled = enabled
            }
            .onChange(of: appState.fontSize) {
                if follow.isFollowing { scroll(proxy, to: unit(at: player.currentUnit), rows: rows, animated: false) }
            }
            .onAppear {
                scroll(proxy, to: current, rows: rows, animated: false)
            }
            .overlay(alignment: .bottom) {
                backToCurrentButton(proxy, current: current, rows: rows)
            }
            .environment(\.openURL, OpenURLAction { url in
                guard let unit = ReadingLink.unit(from: url) else { return .systemAction }
                appState.seek(to: unit)
                return .handled
            })
        }
    }

    private func unit(at index: Int) -> SpeechUnit? {
        document.units.indices.contains(index) ? document.units[index] : nil
    }

    private func isInView(_ unit: SpeechUnit, rows: ReadingRows) -> Bool {
        rows.shows(unit, visibleRows: visibleRows, shares: visibility.shares)
    }

    /// The unit's share of its row is in the row's visible part (true while that is unknown).
    private func isSentenceVisible(_ unit: SpeechUnit, rows: ReadingRows) -> Bool {
        rows.shows(unit, visibleRows: nil, shares: visibility.shares)
    }

    @ViewBuilder
    private func row(_ row: ReadingRows.Row, index: Int, current: SpeechUnit?, currentRow: Int?) -> some View {
        let units = document.units[row.units]
        let kind = document.blocks[row.block].kind
        Group {
            if let current, currentRow == index {
                CurrentBlockText(player: player, kind: kind, row: row, units: units, unit: current, fontSize: appState.fontSize)
            } else {
                BlockText(kind: kind, text: row.text, offset: row.offset, units: units,
                          emphasis: (currentRow ?? 0) > index ? .past : .upcoming, sentence: nil, word: nil,
                          fontSize: appState.fontSize)
                    .equatable()
            }
        }
        .onGeometryChange(for: RowShare?.self) { proxy in
            RowShare(height: proxy.size.height, visible: proxy.bounds(of: .scrollView))
        } action: { share in
            visibility.shares[index] = share
            guard let current, currentRow == index else { return }
            let visible = share.map { $0.shows(row.local(current.range), length: row.length) } ?? false
            if visible != currentSentenceVisible { currentSentenceVisible = visible }
        }
    }

    @ViewBuilder
    private func backToCurrentButton(_ proxy: ScrollViewProxy, current: SpeechUnit?, rows: ReadingRows) -> some View {
        if let current, let currentRow = rows.row(of: current.id) {
            let inView = (visibleRows.map { $0.contains(currentRow) } ?? true) && currentSentenceVisible
            if follow.showsBackToCurrent(currentInView: inView) {
                Button {
                    follow.backToCurrent()
                    scroll(proxy, to: current, rows: rows, animated: true)
                } label: {
                    Label("Back to Current", systemImage: isAbove(current, row: currentRow, rows: rows) ? "arrow.up" : "arrow.down")
                        .font(.caption)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .padding(.bottom, 8)
                .help("Scroll to the sentence being read and follow it again")
            }
        }
    }

    /// The sentence is above what the view shows.
    private func isAbove(_ unit: SpeechUnit, row index: Int, rows: ReadingRows) -> Bool {
        if visibleRows?.contains(index) == true, let share = visibility.shares[index] {
            let row = rows.rows[index]
            return share.isAbove(row.local(unit.range), length: row.length)
        }
        return visibleRows?.min().map { index < $0 } ?? false
    }

    private func scroll(_ proxy: ScrollViewProxy, to unit: SpeechUnit?, rows: ReadingRows, animated: Bool) {
        guard let unit, let index = rows.row(of: unit.id) else { return }
        let row = rows.rows[index]
        let anchor = ReadingScroll.anchor(unitRange: row.local(unit.range), blockLength: row.length)
        if animated {
            withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(index, anchor: anchor) }
        } else {
            proxy.scrollTo(index, anchor: anchor)
        }
    }
}

/// The row being read: the sentence, and the word from the engine's token timings, sampled at
/// most 20 times a second while it plays (only this view redraws).
struct CurrentBlockText: View {
    /// Word highlight refreshes per second at most.
    static let refreshRate = 20.0

    let player: PlaybackController
    let kind: ReadingBlock.Kind
    let row: ReadingRows.Row
    let units: ArraySlice<SpeechUnit>
    let unit: SpeechUnit
    let fontSize: Double

    var body: some View {
        if let timeline = player.wordTimeline, timeline.unit == unit.id, !timeline.timeline.words.isEmpty {
            TimelineView(.animation(minimumInterval: 1 / Self.refreshRate, paused: player.state != .playing)) { _ in
                text(word: timeline.timeline.word(at: player.playbackTime).map { shifted($0.range) })
            }
        } else {
            text(word: nil)
        }
    }

    private func text(word: Range<Int>?) -> some View {
        BlockText(kind: kind, text: row.text, offset: row.offset, units: units, emphasis: .current, sentence: unit.range,
                  word: word, fontSize: fontSize)
            .equatable()
    }

    /// From the unit's display text to the block's text.
    private func shifted(_ range: Range<Int>) -> Range<Int> {
        (range.lowerBound + unit.range.lowerBound)..<(range.upperBound + unit.range.lowerBound)
    }
}

/// One row of text (a block, or part of a long one): every sentence a link (tap = read from
/// there), the current sentence and word highlighted. Equatable, so a row whose inputs did not
/// change is not redrawn.
struct BlockText: View, Equatable {
    enum Emphasis: Equatable {
        case current
        case past
        case upcoming
    }

    let kind: ReadingBlock.Kind
    let text: String
    /// Where `text` starts in its block: the spans below are the block's (Character offsets).
    let offset: Int
    let units: ArraySlice<SpeechUnit>
    let emphasis: Emphasis
    /// The current unit's span of the block's text.
    let sentence: Range<Int>?
    /// The current word's span of the block's text.
    let word: Range<Int>?
    let fontSize: Double

    static let sentenceHighlight = Color.accentColor.opacity(0.2)
    static let wordHighlight = Color.accentColor.opacity(0.42)

    var body: some View {
        Text(Self.attributed(text, units: units, sentence: sentence, word: word, offset: offset))
            .font(Self.font(kind, size: fontSize))
            .lineSpacing(fontSize * 0.38)
            // Dimmed with the hierarchical styles, which stay legible on glass (R4-22); links
            // take the tint, so it dims with the text.
            .foregroundStyle(emphasis == .current ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .tint(emphasis == .current ? Color.primary : Color.secondary)
            .opacity(emphasis == .past ? 0.8 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, kind == .listItem || kind == .quote ? 26 : 14)
            .padding(.trailing, 14)
            .accessibilityHint(Text("Choose a sentence to read from there"))
    }

    static func font(_ kind: ReadingBlock.Kind, size: Double) -> Font {
        switch kind {
        case .title: .system(size: size + 2, weight: .semibold)
        case .heading: .system(size: size + 1, weight: .semibold)
        case .quote: .system(size: size).italic()
        case .paragraph, .listItem: .system(size: size)
        }
    }

    /// The text with a reading link on every unit's span, the sentence's background and the
    /// word's (stronger) one; the spans are offsets into the block, which `text` starts `offset`
    /// characters into. Ranges outside the text are ignored.
    static func attributed(_ text: String, units: ArraySlice<SpeechUnit>, sentence: Range<Int>?,
                           word: Range<Int>?, offset: Int = 0) -> AttributedString {
        func local(_ range: Range<Int>) -> Range<Int> { (range.lowerBound - offset)..<(range.upperBound - offset) }
        var string = AttributedString(text)
        var finder = IndexFinder(string)
        for unit in units where !unit.range.isEmpty {
            if let span = finder.span(local(unit.range)) { string[span].link = ReadingLink.url(unit: unit.id) }
        }
        if let sentence, let span = finder.span(local(sentence)) { string[span].backgroundColor = sentenceHighlight }
        if let word, let span = finder.span(local(word)) { string[span].backgroundColor = wordHighlight }
        return string
    }

    /// Character offsets → AttributedString indices, walking on from the last offset found
    /// (units come in order, so a block is walked about once).
    private struct IndexFinder {
        let characters: AttributedString.CharacterView
        var cursor: AttributedString.Index
        var cursorOffset = 0

        init(_ string: AttributedString) {
            characters = string.characters
            cursor = characters.startIndex
        }

        mutating func index(at offset: Int) -> AttributedString.Index? {
            guard offset >= 0 else { return nil }
            if offset < cursorOffset {
                cursor = characters.startIndex
                cursorOffset = 0
            }
            guard let index = characters.index(cursor, offsetBy: offset - cursorOffset, limitedBy: characters.endIndex)
            else { return nil }
            cursor = index
            cursorOffset = offset
            return index
        }

        mutating func span(_ range: Range<Int>) -> Range<AttributedString.Index>? {
            guard !range.isEmpty, let start = index(at: range.lowerBound), let end = index(at: range.upperBound) else {
                return nil
            }
            return start..<end
        }
    }
}

// MARK: - Header and transport

/// Title, source (a real link for web pages, Show in Finder for files; R4-10, H12) and Close.
struct ReadingHeader: View {
    @Bindable var appState: AppState
    let document: ReadingDocument

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: document.title)
                    .font(.headline)
                    .lineLimit(2)
                    .textSelection(.enabled)
                source
            }
            Spacer(minLength: 4)
            Button {
                appState.closeDocument()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Close and return to input")
            .accessibilityLabel(Text("Close the document"))
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var source: some View {
        switch document.source {
        case .url(let url):
            if !document.sourceLabel.isEmpty {
                Link(destination: url) {
                    Text(verbatim: document.sourceLabel)
                }
                .font(.caption)
                .pointerStyle(.link)
                .help(Text(verbatim: url.absoluteString))
            }
        case .file(let url):
            Button {
                appState.revealInFinder(url)
            } label: {
                Label {
                    Text(verbatim: document.sourceLabel)
                } icon: {
                    Image(systemName: "doc")
                }
            }
            .buttonStyle(.link)
            .font(.caption)
            .pointerStyle(.link)
            .help("Show in Finder")
        case .text:
            EmptyView()
        }
    }
}

/// Progress, Previous / Play-Pause / Next, the position, text size and Stop.
struct TransportBar: View {
    @Bindable var appState: AppState

    private var player: PlaybackController { appState.player }

    var body: some View {
        VStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                ProgressView(value: player.progress)
                    .progressViewStyle(.linear)
                    .accessibilityLabel(Text("Reading progress"))
            }

            HStack(spacing: 18) {
                Button { appState.perform(.previousSentence) } label: {
                    Image(systemName: "backward.fill")
                }
                .help("Previous sentence (←)")
                .accessibilityLabel(Text("Previous sentence"))

                Button { appState.perform(.togglePlayPause) } label: {
                    playPauseIcon
                }
                .help(isActive ? Text("Pause (Space)") : Text("Play (Space)"))
                .accessibilityLabel(isActive ? Text("Pause") : Text("Play"))

                Button { appState.perform(.nextSentence) } label: {
                    Image(systemName: "forward.fill")
                }
                .help("Next sentence (→)")
                .accessibilityLabel(Text("Next sentence"))

                Spacer(minLength: 4)

                if player.readableCount > 0 {
                    Text(verbatim: "\(player.readablePosition) / \(player.readableCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityLabel(Text("Sentence \(String(player.readablePosition)) of \(String(player.readableCount))"))
                }

                HStack(spacing: 10) {
                    Button { appState.perform(.smallerText) } label: {
                        Image(systemName: "textformat.size.smaller")
                    }
                    .disabled(!appState.canShrinkText)
                    .help("Smaller text (⌘−)")
                    .accessibilityLabel(Text("Smaller text"))

                    Button { appState.perform(.largerText) } label: {
                        Image(systemName: "textformat.size.larger")
                    }
                    .disabled(!appState.canEnlargeText)
                    .help("Larger text (⌘+)")
                    .accessibilityLabel(Text("Larger text"))
                }

                Button { appState.perform(.stop) } label: {
                    Image(systemName: "stop.fill")
                }
                .help("Stop (the position is kept)")
                .accessibilityLabel(Text("Stop"))
            }
            .buttonStyle(.borderless)
        }
    }

    private var isActive: Bool { player.state == .playing || player.state == .buffering }

    @ViewBuilder
    private var playPauseIcon: some View {
        switch player.state {
        case .buffering:
            ZStack {
                Image(systemName: "pause.circle.fill").font(.title).opacity(0.25)
                ProgressView().controlSize(.small)
            }
        case .playing:
            Image(systemName: "pause.circle.fill").font(.title)
        default:
            Image(systemName: "play.circle.fill").font(.title)
        }
    }
}

/// Reading mode's voice (of the document's language), language choice and speed, in aligned
/// rows (R4-18).
struct ReadingSettingsSection: View {
    @Bindable var appState: AppState

    var body: some View {
        let language = appState.settingsLanguage
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Text("Voice")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    VoicePickerButton(appState: appState, language: language)
                    VoicePreviewButton(appState: appState, voice: appState.voice(for: language))
                    Picker("Language", selection: Binding(
                        get: { appState.languageChoice },
                        set: { appState.setLanguageChoice($0) }
                    )) {
                        Text("Auto").tag(LanguageChoice.auto)
                        Text(verbatim: "中文").tag(LanguageChoice.zh)
                        Text(verbatim: "English").tag(LanguageChoice.en)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                    .help("Read the document as detected, or all in Chinese or English")
                }
            }
            GridRow {
                Text("Speed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SpeedControl(appState: appState, language: language, style: .slider)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}
