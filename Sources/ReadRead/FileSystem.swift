import Foundation

/// The file operations the TTS lifecycle and the HQ installer need (path resolution, log
/// rotation, install.json), behind a seam so tests can run against a fake tree.
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
    /// The whole file when it is at most `maxBytes` long; nil when it is longer, missing,
    /// unreadable or not a regular file.
    func contents(atPath path: String, maxBytes: Int) -> Data?
    /// `path` with its symlinks resolved, or `path` itself when that fails.
    func resolvingSymlinks(atPath path: String) -> String
}

extension FileSystem {
    /// For trees without links or partial reads (test fakes): the tail, when it is the whole file.
    func contents(atPath path: String, maxBytes: Int) -> Data? {
        guard let size = fileSize(atPath: path), size <= UInt64(max(0, maxBytes)) else { return nil }
        return readTail(atPath: path, maxBytes: maxBytes)
    }

    func resolvingSymlinks(atPath path: String) -> String { path }
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

    func contents(atPath path: String, maxBytes: Int) -> Data? {
        // O_NONBLOCK: opening a FIFO under that name must not hang; only a regular file is read,
        // and never more than maxBytes + 1 bytes of it (a file that grew past the limit is refused).
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= off_t(max(0, maxBytes)) else {
            return nil
        }
        guard let data = try? handle.read(upToCount: maxBytes + 1) ?? Data(), data.count <= maxBytes else { return nil }
        return data
    }

    func resolvingSymlinks(atPath path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
