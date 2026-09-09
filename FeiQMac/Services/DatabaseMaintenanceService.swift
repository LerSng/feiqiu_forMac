import Foundation
import SQLite3

final class DatabaseMaintenanceService {
    let attachmentDirectory: URL
    private let databaseAccess: DatabaseMaintenanceAccess

    var requiresRestart: Bool { databaseAccess.maintenanceRequiresRestart }

    init(databaseAccess: DatabaseMaintenanceAccess, attachmentDirectory: URL) {
        self.databaseAccess = databaseAccess
        self.attachmentDirectory = attachmentDirectory.standardizedFileURL.resolvingSymlinksInPath()
    }

    func scan(completion: @escaping (Result<DatabaseStorageReport, Error>) -> Void) {
        databaseAccess.withMaintenanceDatabase(requiresRestart: false, operation: { [self] database, databaseURL in
            let references = try MaintenanceDatabase.attachments(in: database)
            let inventory = try MaintenanceFileAccess.scanManagedFiles(in: attachmentDirectory)
            let existing = Set(inventory.files.map(\.relativePath))
            var referenced: Set<String> = []
            var missing = 0
            for attachment in references.flatMap(\.attachments) {
                if let relative = MaintenanceFileAccess.relativePath(for: attachment.localPath, in: attachmentDirectory), existing.contains(relative) {
                    referenced.insert(relative)
                } else {
                    missing += 1
                }
            }
            let orphaned = inventory.files.filter { !referenced.contains($0.relativePath) }
            let images = inventory.files.filter { $0.relativePath.hasPrefix("Images/") }
            let files = inventory.files.filter { $0.relativePath.hasPrefix("Files/") }
            let databaseBytes = [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"].reduce(Int64(0)) { total, path in
                total + ((try? MaintenanceFileAccess.record(at: URL(fileURLWithPath: path), relativePath: "database").byteCount) ?? 0)
            }
            return DatabaseStorageReport(
                databaseBytes: databaseBytes, imageBytes: images.reduce(0) { $0 + $1.byteCount },
                fileBytes: files.reduce(0) { $0 + $1.byteCount },
                safetyBackupBytes: try MaintenanceFileAccess.recursiveByteCount(in: attachmentDirectory.appendingPathComponent("Backups")),
                imageCount: images.count, fileCount: files.count,
                messageCount: try MaintenanceDatabase.count("messages", in: database), missingAttachmentCount: missing,
                unreferencedFileCount: orphaned.count, unreferencedBytes: orphaned.reduce(0) { $0 + $1.byteCount },
                skippedEntryCount: inventory.skipped, scannedAt: Date()
            )
        }, completion: completion)
    }

    func previewCleanup(policy: AttachmentCleanupPolicy, protectedPaths: Set<String>,
                        completion: @escaping (Result<AttachmentCleanupPreview, Error>) -> Void) {
        databaseAccess.withMaintenanceDatabase(requiresRestart: false, operation: { [self] database, _ in
            try cleanupPreview(policy: policy, protectedPaths: protectedPaths, database: database)
        }, completion: completion)
    }

    func cleanup(_ preview: AttachmentCleanupPreview, protectedPaths: Set<String>,
                 completion: @escaping (Result<AttachmentCleanupSummary, Error>) -> Void) {
        databaseAccess.withMaintenanceDatabase(requiresRestart: false, operation: { [self] database, _ in
            try MaintenanceDatabase.execute("BEGIN IMMEDIATE", in: database)
            defer { try? MaintenanceDatabase.execute("ROLLBACK", in: database) }
            let current = try cleanupPreview(policy: preview.policy, protectedPaths: protectedPaths, database: database)
            guard current.files == preview.files, current.affectedMessageCount == preview.affectedMessageCount else {
                throw DatabaseMaintenanceError.stalePreview
            }
            var removed = 0
            var bytes: Int64 = 0
            var failures: [String] = []
            for file in current.files {
                do {
                    try MaintenanceFileAccess.remove(file, in: attachmentDirectory)
                    removed += 1
                    bytes += file.byteCount
                } catch {
                    failures.append(file.relativePath + "：" + error.localizedDescription)
                }
            }
            return AttachmentCleanupSummary(removedFileCount: removed, removedBytes: bytes, failures: failures)
        }, completion: completion)
    }

    private func cleanupPreview(policy: AttachmentCleanupPolicy, protectedPaths: Set<String>, database: OpaquePointer) throws -> AttachmentCleanupPreview {
        guard policy.before.timeIntervalSince1970.isFinite, policy.before <= Calendar.current.startOfDay(for: Date()) else {
            throw DatabaseMaintenanceError.invalidDate
        }
        let records = try MaintenanceDatabase.attachments(in: database)
        var latestReference: [String: Date] = [:]
        for record in records {
            for attachment in record.attachments {
                guard let path = MaintenanceFileAccess.relativePath(for: attachment.localPath, in: attachmentDirectory) else { continue }
                latestReference[path] = max(record.date, latestReference[path] ?? .distantPast)
            }
        }
        let protected = Set(protectedPaths.compactMap { MaintenanceFileAccess.relativePath(for: $0, in: attachmentDirectory) })
        let inventory = try MaintenanceFileAccess.scanManagedFiles(in: attachmentDirectory)
        let candidates = inventory.files.filter { file in
            if let latest = latestReference[file.relativePath] { return latest < policy.before }
            return policy.includesUnreferencedFiles && file.modifiedAt < policy.before
        }
        let files = candidates.filter { !protected.contains($0.relativePath) }
        let paths = Set(files.map(\.relativePath))
        let messages = records.filter { record in
            record.attachments.contains { attachment in
                MaintenanceFileAccess.relativePath(for: attachment.localPath, in: attachmentDirectory).map(paths.contains) ?? false
            }
        }.count
        return AttachmentCleanupPreview(policy: policy, files: files,
                                        protectedFileCount: candidates.count - files.count, affectedMessageCount: messages)
    }

    func createBackup(in directory: URL, completion: @escaping (Result<DatabaseBackupPreview, Error>) -> Void) {
        databaseAccess.withMaintenanceDatabase(requiresRestart: false, operation: { [self] database, databaseURL in
            let destination = directory.standardizedFileURL.resolvingSymlinksInPath()
            guard !isWithinDataDirectory(destination, databaseURL: databaseURL) else {
                throw DatabaseMaintenanceError.unsafePath("请将手动备份保存在应用数据目录之外")
            }
            return try DatabaseBackupService(attachmentDirectory: attachmentDirectory).create(in: destination, database: database)
        }, completion: completion)
    }

    func inspectBackup(at directory: URL, completion: @escaping (Result<DatabaseBackupPreview, Error>) -> Void) {
        databaseAccess.withMaintenanceDatabase(requiresRestart: false, operation: { [self] _, _ in
            try DatabaseBackupService(attachmentDirectory: attachmentDirectory).inspect(directory)
        }, completion: completion)
    }

    func restoreBackup(_ preview: DatabaseBackupPreview, completion: @escaping (Result<DatabaseRestoreSummary, Error>) -> Void) {
        databaseAccess.withMaintenanceDatabase(requiresRestart: true, operation: { [self] database, _ in
            try DatabaseBackupService(attachmentDirectory: attachmentDirectory).restore(preview, database: database)
        }, completion: completion)
    }

    private func isWithinDataDirectory(_ directory: URL, databaseURL: URL) -> Bool {
        [attachmentDirectory, databaseURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()].contains {
            directory.path == $0.path || directory.path.hasPrefix($0.path + "/")
        }
    }
}
