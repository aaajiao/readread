import Foundation

/// The file operations the TTS lifecycle needs (path resolution, log rotation),
/// behind a seam so tests can run against a fake tree.
@MainActor
protocol FileSystem {
    func fileExists(atPath path: String) -> Bool
    func directoryExists(atPath path: String) -> Bool
    func isExecutableFile(atPath path: String) -> Bool
    func fileSize(atPath path: String) -> UInt64?
    func createDirectory(atPath path: String) throws
    func moveItem(atPath source: String, toPath destination: String) throws
    func removeItem(atPath path: String) throws
    /// Open (creating if needed) for appending; every write goes to the end.
    func openForAppending(atPath path: String) throws -> FileHandle
    /// The last `maxBytes` of a file, or nil if it can't be read.
    func readTail(atPath path: String, maxBytes: Int) -> Data?
}

struct LocalFileSystem: FileSystem {
    func fileExists(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }

    func directoryExists(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    func isExecutableFile(atPath path: String) -> Bool {
        fileExists(atPath: path) && FileManager.default.isExecutableFile(atPath: path)
    }

    /// The size of what the path names: stat() follows symlinks (attributesOfItem
    /// would report the size of a link itself, so a linked model file looked truncated).
    func fileSize(atPath path: String) -> UInt64? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return UInt64(info.st_size)
    }

    func createDirectory(atPath path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func moveItem(atPath source: String, toPath destination: String) throws {
        try FileManager.default.moveItem(atPath: source, toPath: destination)
    }

    func removeItem(atPath path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }

    func openForAppending(atPath path: String) throws -> FileHandle {
        // O_APPEND so the app's notes and the child's stderr never overwrite each
        // other; O_CLOEXEC so the descriptor only reaches the child as its fd 2.
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSFilePathErrorKey: path,
                NSLocalizedDescriptionKey: "Cannot open \(path): \(String(cString: strerror(errno)))",
            ])
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func readTail(atPath path: String, maxBytes: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        return try? handle.readToEnd()
    }
}
