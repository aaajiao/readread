import Foundation
import Synchronization

/// The pinned Defuddle build (scripts/lib/versions.sh, RR_DEFUDDLE_*) that `LocalExtractor` runs
/// in its web view: `Contents/Resources/defuddle/defuddle.full.js` in the app (build-app.sh), else
/// `$READREAD_HOME/defuddle/defuddle.full.js` (setup.sh).
enum DefuddleBundle {
    static let directoryName = "defuddle"
    static let scriptName = "defuddle.full.js"
    /// The pinned build is 768,702 bytes: a much larger file is not it.
    static let maximumScriptBytes = 8_000_000

    /// The places to look, in order.
    static func candidates(_ context: TTSServerPaths.Context) -> [URL] {
        var bases: [String] = []
        if let resources = context.bundleResources { bases.append(resources) }
        if let home = context.readreadHome { bases.append(home) }
        return bases.map {
            URL(fileURLWithPath: $0, isDirectory: true).appending(path: directoryName).appending(path: scriptName)
        }
    }

    /// The script's source from the first candidate that holds one; nil when none does.
    static func load(_ context: TTSServerPaths.Context) -> String? {
        locate(context)?.source
    }

    /// The first candidate that holds the script, and its source (the self test reports which).
    static func locate(_ context: TTSServerPaths.Context) -> (url: URL, source: String)? {
        for url in candidates(context) {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size <= maximumScriptBytes,
                  let data = try? Data(contentsOf: url),
                  let source = String(data: data, encoding: .utf8), source.contains("Defuddle")
            else { continue }
            return (url, source)
        }
        return nil
    }

    private static let loaded = Mutex<String?>(nil)

    /// `load(.live())`; a script once read is kept for the process, a missing one is looked for
    /// again next time (setup.sh may have installed it meanwhile).
    static func live() -> String? {
        if let script = loaded.withLock({ $0 }) { return script }
        guard let script = load(.live()) else { return nil }
        loaded.withLock { $0 = script }
        return script
    }
}
