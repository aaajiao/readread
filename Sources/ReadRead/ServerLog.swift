import Foundation

/// The server's stderr log: `tts-server.log`, appended across launches and
/// rotated to `tts-server.log.1` once it reaches 5 MB.
@MainActor
struct ServerLog {
    static let rotationBytes: UInt64 = 5 * 1024 * 1024

    let path: String
    let fileSystem: any FileSystem

    var rotatedPath: String { path + ".1" }

    /// Rotate if needed and open for appending. The handle becomes the child's
    /// stderr; the app also writes short lifecycle notes through it.
    func prepareForLaunch() throws -> FileHandle {
        try fileSystem.createDirectory(atPath: (path as NSString).deletingLastPathComponent)
        rotateIfNeeded()
        return try fileSystem.openForAppending(atPath: path)
    }

    func rotateIfNeeded() {
        guard let size = fileSystem.fileSize(atPath: path), size >= Self.rotationBytes else { return }
        if fileSystem.fileExists(atPath: rotatedPath) {
            try? fileSystem.removeItem(atPath: rotatedPath)
        }
        try? fileSystem.moveItem(atPath: path, toPath: rotatedPath)
    }

    /// Last `count` non-empty lines, for error messages.
    func tail(lines count: Int, maxBytes: Int = 16 * 1024) -> [String] {
        guard let data = fileSystem.readTail(atPath: path, maxBytes: maxBytes) else { return [] }
        let lines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(lines.suffix(count))
    }

    /// Local time with its UTC offset, like the server's own (local) timestamps.
    static func note(_ message: String, to handle: FileHandle?) {
        guard let handle else { return }
        let stamp = Date.now.ISO8601Format(.init(timeZone: .current))
        try? handle.write(contentsOf: Data("[\(stamp)] [app] \(message)\n".utf8))
    }
}
