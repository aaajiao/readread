import Foundation

/// Where a document was left: its unit index, valid only while the content hash matches.
struct ReadingPosition: Codable, Equatable, Sendable {
    let unit: Int
    let contentHash: String
    let date: Date
}

/// Saved reading positions, by `ReadingDocument.positionKey` (R3-14 resume).
@MainActor
protocol ReadingPositionStoring: AnyObject {
    func position(for key: String) -> ReadingPosition?
    func save(_ position: ReadingPosition, for key: String)
    func removePosition(for key: String)
}

/// `positions.json` in Application Support (READREAD_POSITIONS_FILE overrides it): the last
/// 200 documents. Written atomically; a corrupt file is ignored and replaced on the next save.
@MainActor
final class ReadingPositionStore: ReadingPositionStoring {
    static let maximumEntries = 200

    let fileURL: URL
    private var positions: [String: ReadingPosition]?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func defaultFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> URL {
        if let path = environment["READREAD_POSITIONS_FILE"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: homeDirectory)
            .appending(path: "Library/Application Support/ReadRead/positions.json")
    }

    private struct File: Codable {
        var version = 1
        var positions: [String: ReadingPosition]
    }

    func position(for key: String) -> ReadingPosition? {
        load()[key]
    }

    func save(_ position: ReadingPosition, for key: String) {
        var all = load()
        all[key] = position
        if all.count > Self.maximumEntries {
            let kept = all.sorted { $0.value.date > $1.value.date }.prefix(Self.maximumEntries)
            all = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        positions = all
        write(all)
    }

    func removePosition(for key: String) {
        var all = load()
        guard all.removeValue(forKey: key) != nil else { return }
        positions = all
        write(all)
    }

    private func load() -> [String: ReadingPosition] {
        if let positions { return positions }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: fileURL)).flatMap { try? decoder.decode(File.self, from: $0) }?.positions ?? [:]
        positions = loaded
        return loaded
    }

    private func write(_ all: [String: ReadingPosition]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(File(positions: all)).write(to: fileURL, options: .atomic)
        } catch {
            // A position that cannot be saved is not worth interrupting reading for.
        }
    }
}
