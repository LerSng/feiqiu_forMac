import CryptoKit
import Darwin
import Foundation

enum MaintenanceFileAccess {
    static let backupExtension = "feiqbackup"

    static func isSafeRelativePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && ["Images", "Files"].contains(String(parts[0]))
            && !parts[1].isEmpty && parts[1] != "." && parts[1] != ".."
            && !path.contains("\\") && !path.contains("\0")
    }

    static func validateDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw DatabaseMaintenanceError.unsafePath(url.lastPathComponent)
        }
    }

    static func record(at url: URL, relativePath: String) throws -> MaintenanceFileRecord {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            throw DatabaseMaintenanceError.unsafePath(relativePath)
        }
        return record(info, relativePath: relativePath)
    }

    private static func record(_ info: stat, relativePath: String) -> MaintenanceFileRecord {
        let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
        let created = Date(timeIntervalSince1970: Double(info.st_birthtimespec.tv_sec) + Double(info.st_birthtimespec.tv_nsec) / 1e9)
        return MaintenanceFileRecord(
            relativePath: relativePath, byteCount: Int64(info.st_size), modifiedAt: max(modified, created),
            identity: "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
        )
    }

    static func scanManagedFiles(in root: URL) throws -> (files: [MaintenanceFileRecord], skipped: Int) {
        try validateDirectory(root)
        var files: [MaintenanceFileRecord] = []
        var skipped = 0
        for name in ["Images", "Files"] {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try validateDirectory(directory)
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let relative = name + "/" + url.lastPathComponent
                if isSafeRelativePath(relative), let file = try? record(at: url, relativePath: relative) {
                    files.append(file)
                } else {
                    skipped += 1
                }
            }
        }
        return (files.sorted { $0.relativePath < $1.relativePath }, skipped)
    }

    static func relativePath(for path: String, in root: URL) -> String? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let original = URL(fileURLWithPath: path).standardizedFileURL
        let url = original.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(original.lastPathComponent)
        let prefix = root.path + "/"
        guard url.path.hasPrefix(prefix) else { return nil }
        let relative = String(url.path.dropFirst(prefix.count))
        return isSafeRelativePath(relative) ? relative : nil
    }

    static func copyAndHash(from source: URL, to destination: URL?, expected: MaintenanceFileRecord) throws -> String {
        let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw DatabaseMaintenanceError.unsafePath(expected.relativePath) }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              record(before, relativePath: expected.relativePath) == expected else {
            throw DatabaseMaintenanceError.changedFile(expected.relativePath)
        }
        var output: FileHandle?
        if let destination {
            try validateDirectory(destination.deletingLastPathComponent())
            let outputDescriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard outputDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            output = FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: true)
        }
        defer { try? output?.close() }
        var hasher = SHA256()
        var bytes: Int64 = 0
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
            bytes += Int64(data.count)
            guard bytes <= expected.byteCount else { throw DatabaseMaintenanceError.changedFile(expected.relativePath) }
            hasher.update(data: data)
            try output?.write(contentsOf: data)
        }
        var after = stat()
        guard bytes == expected.byteCount, fstat(descriptor, &after) == 0,
              record(after, relativePath: expected.relativePath) == expected,
              try record(at: source, relativePath: expected.relativePath) == expected else {
            throw DatabaseMaintenanceError.changedFile(expected.relativePath)
        }
        try output?.synchronize()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func read(_ url: URL, expected: MaintenanceFileRecord, maximumBytes: Int) throws -> Data {
        guard expected.byteCount >= 0, expected.byteCount <= maximumBytes else {
            throw DatabaseMaintenanceError.invalidBackup("文件大小超出读取限制")
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw DatabaseMaintenanceError.unsafePath(expected.relativePath) }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              record(info, relativePath: expected.relativePath) == expected else {
            throw DatabaseMaintenanceError.changedFile(expected.relativePath)
        }
        var data = Data()
        while let chunk = try input.read(upToCount: min(1024 * 1024, maximumBytes - data.count + 1)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= expected.byteCount else { throw DatabaseMaintenanceError.changedFile(expected.relativePath) }
        }
        guard data.count == expected.byteCount, fstat(descriptor, &info) == 0,
              record(info, relativePath: expected.relativePath) == expected,
              try record(at: url, relativePath: expected.relativePath) == expected else {
            throw DatabaseMaintenanceError.changedFile(expected.relativePath)
        }
        return data
    }

    static func remove(_ file: MaintenanceFileRecord, in root: URL) throws {
        guard isSafeRelativePath(file.relativePath) else { throw DatabaseMaintenanceError.unsafePath(file.relativePath) }
        let rootDescriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootDescriptor >= 0 else { throw DatabaseMaintenanceError.unsafePath(root.lastPathComponent) }
        defer { close(rootDescriptor) }
        let parts = file.relativePath.split(separator: "/").map(String.init)
        let directory = openat(rootDescriptor, parts[0], O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw DatabaseMaintenanceError.unsafePath(parts[0]) }
        defer { close(directory) }
        var info = stat()
        guard fstatat(directory, parts[1], &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFREG, record(info, relativePath: file.relativePath) == file else {
            throw DatabaseMaintenanceError.changedFile(file.relativePath)
        }
        guard unlinkat(directory, parts[1], 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    static func recursiveByteCount(in directory: URL) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        try validateDirectory(directory)
        var total: Int64 = 0
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                total += try recursiveByteCount(in: child)
            } else if let file = try? record(at: child, relativePath: child.lastPathComponent) {
                total += file.byteCount
            }
        }
        return total
    }
}
