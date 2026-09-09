import Foundation
import SQLite3

final class DatabaseBackupService {
    private let attachmentDirectory: URL
    private let fileManager = FileManager.default

    init(attachmentDirectory: URL) {
        self.attachmentDirectory = attachmentDirectory
    }

    func create(in directory: URL, database: OpaquePointer) throws -> DatabaseBackupPreview {
        try MaintenanceFileAccess.validateDirectory(directory)
        try MaintenanceFileAccess.validateDirectory(attachmentDirectory)
        let identifier = UUID()
        let staging = directory.appendingPathComponent(".feiq-backup-" + identifier.uuidString, isDirectory: true)
        try createDirectories(at: staging)
        defer { try? fileManager.removeItem(at: staging) }
        let databaseURL = staging.appendingPathComponent("Database.sqlite")
        try MaintenanceDatabase.snapshot(database, to: databaseURL)
        var files: [DatabaseBackupManifest.File] = []
        var missingCount = 0
        var messageCount = 0
        var conversationCount = 0
        do {
            let copy = try MaintenanceDatabase.open(databaseURL, readOnly: false)
            defer { sqlite3_close(copy) }
            try MaintenanceDatabase.validate(copy)
            let records = try MaintenanceDatabase.attachments(in: copy)
            var paths: [String: String] = [:]
            var copied: Set<String> = []
            for attachment in records.flatMap(\.attachments) {
                guard let relative = MaintenanceFileAccess.relativePath(for: attachment.localPath, in: attachmentDirectory) else {
                    missingCount += 1
                    continue
                }
                let source = attachmentDirectory.appendingPathComponent(relative)
                try MaintenanceFileAccess.validateDirectory(source.deletingLastPathComponent())
                guard fileManager.fileExists(atPath: source.path) else {
                    missingCount += 1
                    continue
                }
                if copied.insert(relative).inserted {
                    let record = try MaintenanceFileAccess.record(at: source, relativePath: relative)
                    let digest = try MaintenanceFileAccess.copyAndHash(from: source, to: staging.appendingPathComponent(relative), expected: record)
                    files.append(.init(relativePath: relative, byteCount: record.byteCount, sha256: digest))
                }
                paths[attachment.localPath] = relative
            }
            try MaintenanceDatabase.rewriteAttachments(in: copy, records: records, paths: paths)
            messageCount = try MaintenanceDatabase.count("messages", in: copy)
            conversationCount = try MaintenanceDatabase.count("conversations", in: copy)
            try MaintenanceDatabase.execute("PRAGMA wal_checkpoint(TRUNCATE)", in: copy)
            try MaintenanceDatabase.execute("PRAGMA journal_mode = DELETE", in: copy)
        }
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: databaseURL.path + suffix)
            guard fileManager.fileExists(atPath: sidecar.path) else { continue }
            let file = try MaintenanceFileAccess.record(at: sidecar, relativePath: sidecar.lastPathComponent)
            guard suffix == "-shm" || file.byteCount == 0 else {
                throw DatabaseMaintenanceError.database("备份数据库日志尚未合并，未生成备份")
            }
            try fileManager.removeItem(at: sidecar)
        }
        let databaseFile = try MaintenanceFileAccess.record(at: databaseURL, relativePath: "Database.sqlite")
        let databaseHash = try MaintenanceFileAccess.copyAndHash(from: databaseURL, to: nil, expected: databaseFile)
        let manifest = DatabaseBackupManifest(
            id: identifier, createdAt: Date(),
            database: .init(relativePath: "Database.sqlite", byteCount: databaseFile.byteCount, sha256: databaseHash),
            files: files.sorted { $0.relativePath < $1.relativePath }, messageCount: messageCount,
            conversationCount: conversationCount, missingAttachmentCount: missingCount
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(manifest)
        try encoded.write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "飞秋备份-\(formatter.string(from: manifest.createdAt))-\(identifier.uuidString.prefix(8)).\(MaintenanceFileAccess.backupExtension)"
        let destination = directory.appendingPathComponent(name, isDirectory: true)
        try fileManager.moveItem(at: staging, to: destination)
        return DatabaseBackupPreview(directory: destination, manifest: manifest, manifestHash: MaintenanceFileAccess.hash(encoded))
    }

    func inspect(_ directory: URL) throws -> DatabaseBackupPreview {
        let preview = try readManifest(in: directory)
        let staging = fileManager.temporaryDirectory.appendingPathComponent("feiq-backup-check-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: staging) }
        let databaseURL = staging.appendingPathComponent("Database.sqlite")
        try verify(preview.manifest.database, in: directory, copyingTo: databaseURL)
        let database = try MaintenanceDatabase.open(databaseURL, readOnly: true)
        defer { sqlite3_close(database) }
        try validateDatabase(database, manifest: preview.manifest)
        for file in preview.manifest.files { try verify(file, in: directory, copyingTo: nil) }
        guard try readManifest(in: directory).manifestHash == preview.manifestHash else {
            throw DatabaseMaintenanceError.changedFile("manifest.json")
        }
        return preview
    }

    func restore(_ preview: DatabaseBackupPreview, database: OpaquePointer) throws -> DatabaseRestoreSummary {
        let current = try readManifest(in: preview.directory)
        guard current.manifestHash == preview.manifestHash else { throw DatabaseMaintenanceError.stalePreview }
        try MaintenanceFileAccess.validateDirectory(attachmentDirectory)
        for name in ["Images", "Files"] {
            try MaintenanceFileAccess.validateDirectory(attachmentDirectory.appendingPathComponent(name))
        }
        let staging = attachmentDirectory.appendingPathComponent(".feiq-restore-" + UUID().uuidString, isDirectory: true)
        try createDirectories(at: staging)
        defer { try? fileManager.removeItem(at: staging) }
        let databaseURL = staging.appendingPathComponent("Database.sqlite")
        try verify(current.manifest.database, in: current.directory, copyingTo: databaseURL)
        let source = try MaintenanceDatabase.open(databaseURL, readOnly: true)
        defer { sqlite3_close(source) }
        try validateDatabase(source, manifest: current.manifest)
        for file in current.manifest.files {
            try verify(file, in: current.directory, copyingTo: staging.appendingPathComponent(file.relativePath))
        }
        guard try readManifest(in: current.directory).manifestHash == current.manifestHash else {
            throw DatabaseMaintenanceError.changedFile("manifest.json")
        }
        let safetyDirectory = attachmentDirectory.appendingPathComponent("Backups", isDirectory: true)
        if !fileManager.fileExists(atPath: safetyDirectory.path) {
            try fileManager.createDirectory(at: safetyDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try MaintenanceFileAccess.validateDirectory(safetyDirectory)
        let safety = try create(in: safetyDirectory, database: database)
        var installed: [URL] = []
        var committed = false
        defer {
            if !committed {
                for url in installed { try? fileManager.removeItem(at: url) }
            }
        }
        var paths: [String: String] = [:]
        for file in current.manifest.files {
            let components = file.relativePath.split(separator: "/")
            let suffix = String(URL(fileURLWithPath: file.relativePath).pathExtension.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(12))
            let name = UUID().uuidString + (suffix.isEmpty ? "" : "." + suffix)
            let target = attachmentDirectory.appendingPathComponent(String(components[0])).appendingPathComponent(name)
            try MaintenanceFileAccess.validateDirectory(target.deletingLastPathComponent())
            try fileManager.moveItem(at: staging.appendingPathComponent(file.relativePath), to: target)
            installed.append(target)
            paths[file.relativePath] = target.path
        }
        try MaintenanceDatabase.replaceContents(of: database, from: source, paths: paths)
        committed = true
        return DatabaseRestoreSummary(messageCount: current.manifest.messageCount,
                                      attachmentCount: current.manifest.files.count, safetyBackupURL: safety.directory)
    }

    private func readManifest(in directory: URL) throws -> DatabaseBackupPreview {
        try MaintenanceFileAccess.validateDirectory(directory)
        let url = directory.appendingPathComponent("manifest.json")
        let file = try MaintenanceFileAccess.record(at: url, relativePath: "manifest.json")
        guard file.byteCount > 0, file.byteCount <= 32 * 1024 * 1024 else {
            throw DatabaseMaintenanceError.invalidBackup("清单为空或过大")
        }
        let data = try MaintenanceFileAccess.read(url, expected: file, maximumBytes: 32 * 1024 * 1024)
        let originalHash = MaintenanceFileAccess.hash(data)
        let manifest = try JSONDecoder().decode(DatabaseBackupManifest.self, from: data)
        guard manifest.version == 1, manifest.createdAt.timeIntervalSince1970.isFinite,
              manifest.database.relativePath == "Database.sqlite", manifest.database.byteCount > 0,
              manifest.messageCount >= 0, manifest.conversationCount >= 0, manifest.missingAttachmentCount >= 0,
              Set(manifest.files.map(\.relativePath)).count == manifest.files.count,
              manifest.files.allSatisfy({ MaintenanceFileAccess.isSafeRelativePath($0.relativePath) }),
              manifest.files.count <= 100_000 else {
            throw DatabaseMaintenanceError.invalidBackup("版本、条目或计数不匹配")
        }
        for file in [manifest.database] + manifest.files {
            guard file.byteCount >= 0, file.byteCount <= 32 * 1024 * 1024 * 1024,
                  file.sha256.count == 64, file.sha256.allSatisfy({ $0.isASCII && $0.isHexDigit }),
                  file.relativePath == "Database.sqlite" || MaintenanceFileAccess.isSafeRelativePath(file.relativePath) else {
                throw DatabaseMaintenanceError.invalidBackup("文件路径、大小或校验值无效")
            }
        }
        for suffix in ["-wal", "-shm", "-journal"] where fileManager.fileExists(atPath: directory.appendingPathComponent("Database.sqlite" + suffix).path) {
            throw DatabaseMaintenanceError.invalidBackup("备份包含未合并的 SQLite 日志：\(directory.lastPathComponent)/Database.sqlite\(suffix)")
        }
        return DatabaseBackupPreview(directory: directory, manifest: manifest, manifestHash: originalHash)
    }

    private func verify(_ entry: DatabaseBackupManifest.File, in directory: URL, copyingTo destination: URL?) throws {
        try MaintenanceFileAccess.validateDirectory(directory)
        let source = directory.appendingPathComponent(entry.relativePath)
        try MaintenanceFileAccess.validateDirectory(source.deletingLastPathComponent())
        let file = try MaintenanceFileAccess.record(at: source, relativePath: entry.relativePath)
        guard file.byteCount == entry.byteCount,
              try MaintenanceFileAccess.copyAndHash(from: source, to: destination, expected: file) == entry.sha256 else {
            throw DatabaseMaintenanceError.changedFile(entry.relativePath)
        }
    }

    private func validateDatabase(_ database: OpaquePointer, manifest: DatabaseBackupManifest) throws {
        try MaintenanceDatabase.validate(database)
        let attachments = try MaintenanceDatabase.attachments(in: database).flatMap(\.attachments)
        let paths = Set(attachments.map(\.localPath).filter { !$0.isEmpty })
        guard paths == Set(manifest.files.map(\.relativePath)),
              paths.allSatisfy(MaintenanceFileAccess.isSafeRelativePath),
              attachments.filter({ $0.localPath.isEmpty }).count == manifest.missingAttachmentCount,
              try MaintenanceDatabase.count("messages", in: database) == manifest.messageCount,
              try MaintenanceDatabase.count("conversations", in: database) == manifest.conversationCount else {
            throw DatabaseMaintenanceError.invalidBackup("数据库内容与清单不一致")
        }
    }

    private func createDirectories(at directory: URL) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for name in ["Images", "Files"] {
            try fileManager.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
    }
}
