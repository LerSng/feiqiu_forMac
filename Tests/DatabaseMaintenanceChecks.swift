import AppKit
import Foundation
import SQLite3

@main
enum DatabaseMaintenanceChecks {
    private struct Fixture {
        let root: URL
        let history: SQLiteChatHistoryService
        let maintenance: DatabaseMaintenanceService
        let storage: LocalChatAttachmentStorageService

        init(_ root: URL) {
            self.root = root
            storage = LocalChatAttachmentStorageService(rootURL: root)
            history = SQLiteChatHistoryService(store: ChatHistoryStore(databaseURL: root.appendingPathComponent("history.sqlite"),
                legacyURL: root.appendingPathComponent("missing.json")))
            maintenance = DatabaseMaintenanceService(databaseAccess: history, attachmentDirectory: root)
        }
    }

    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feiq-maintenance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await checkCleanup(Fixture(root.appendingPathComponent("cleanup")))
        let backup = try await checkBackupAndRestore(root)
        try await checkAuthorization(Fixture(root.appendingPathComponent("authorization")), backup: backup)
        print("Database maintenance checks passed")
    }

    private static func checkCleanup(_ fixture: Fixture) async throws {
        let day = Calendar.current.startOfDay(for: Date())
        let oldDate = day.addingTimeInterval(-100 * 86400)
        let shared = try write("Images/shared.png", in: fixture, bytes: 11)
        let old = try write("Files/old.txt", in: fixture, bytes: 3)
        let orphan = try write("Files/orphan.txt", in: fixture, bytes: 5, date: oldDate)
        let draft = try write("Files/draft.txt", in: fixture, bytes: 7, date: oldDate)
        let recent = try write("Files/recent.txt", in: fixture, bytes: 13)
        let external = fixture.root.appendingPathComponent("original.txt")
        try Data("原文件".utf8).write(to: external)
        let link = fixture.root.appendingPathComponent("Files/link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        let nested = fixture.root.appendingPathComponent("Files/nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try Data([1]).write(to: nested.appendingPathComponent("keep.txt"))
        let peer = makePeer()
        let first = ChatMessage(direction: .incoming, text: "文字必须保留", date: oldDate,
            attachments: [shared, old, attachment("missing", path: fixture.root.appendingPathComponent("Files/missing.txt").path),
                          attachment("external", path: external.path)])
        fixture.history.saveMessage(first, for: peer, unreadCount: 0)
        fixture.history.saveMessage(ChatMessage(direction: .incoming, text: "新引用", date: day.addingTimeInterval(-86400), attachments: [shared]), for: peer, unreadCount: 0)
        let report: DatabaseStorageReport = try await receive { fixture.maintenance.scan(completion: $0) }
        precondition(report.imageCount == 1 && report.imageBytes == 11 && report.fileCount == 4 && report.fileBytes == 28)
        precondition(report.unreferencedFileCount == 3 && report.unreferencedBytes == 25 && report.missingAttachmentCount == 2)
        precondition(report.messageCount == 2 && report.databaseBytes > 0 && report.skippedEntryCount == 2)
        let policy = AttachmentCleanupPolicy(before: day.addingTimeInterval(-30 * 86400), includesUnreferencedFiles: true)
        let preview: AttachmentCleanupPreview = try await receive { fixture.maintenance.previewCleanup(policy: policy, protectedPaths: [draft.localPath], completion: $0) }
        precondition(Set(preview.files.map(\.relativePath)) == ["Files/old.txt", "Files/orphan.txt"])
        precondition(preview.protectedFileCount == 1 && preview.affectedMessageCount == 1 && preview.byteCount == 8)
        let _: Error = await failure { fixture.maintenance.previewCleanup(policy: .init(before: day.addingTimeInterval(86400)), protectedPaths: [], completion: $0) }
        try Data([1, 2, 3, 4]).write(to: old.localURL)
        let stale = await failure { fixture.maintenance.cleanup(preview, protectedPaths: [draft.localPath], completion: $0) }
        guard case DatabaseMaintenanceError.stalePreview = stale else { preconditionFailure("Changed files require a new preview") }
        precondition(orphan.isAvailable && old.isAvailable)
        let fresh: AttachmentCleanupPreview = try await receive { fixture.maintenance.previewCleanup(policy: policy, protectedPaths: [draft.localPath], completion: $0) }
        let summary: AttachmentCleanupSummary = try await receive { fixture.maintenance.cleanup(fresh, protectedPaths: [draft.localPath], completion: $0) }
        precondition(summary.removedFileCount == 2 && summary.removedBytes == 9 && summary.failures.isEmpty)
        precondition(!old.isAvailable && !orphan.isAvailable && shared.isAvailable && draft.isAvailable && recent.isAvailable)
        precondition(FileManager.default.fileExists(atPath: external.path) && FileManager.default.fileExists(atPath: nested.path))
        let messages: ChatHistoryPage = try await receive { fixture.history.loadRecentMessages(for: peer.id, limit: 60, completion: $0) }
        precondition(messages.messages.first { $0.id == first.id }?.text == first.text)
        precondition(messages.messages.first { $0.id == first.id }?.attachments == first.attachments)
        let after: DatabaseStorageReport = try await receive { fixture.maintenance.scan(completion: $0) }
        precondition(after.missingAttachmentCount == 3 && after.fileCount == 2)
        let linkedRecord = MaintenanceFileRecord(relativePath: "Files/link.txt", byteCount: 1, modifiedAt: .distantPast, identity: "not-a-file")
        do {
            try MaintenanceFileAccess.remove(linkedRecord, in: fixture.maintenance.attachmentDirectory)
            preconditionFailure("Symbolic links must never be cleaned as regular attachments")
        } catch {}
        precondition(FileManager.default.fileExists(atPath: external.path))
        for unsafe in ["../outside", "Files/../outside", "/Files/a", "Files/a/b", "Images\\a", "Files/", "Files/.."] {
            precondition(!MaintenanceFileAccess.isSafeRelativePath(unsafe))
        }
    }

    private static func checkBackupAndRestore(_ root: URL) async throws -> DatabaseBackupPreview {
        let source = Fixture(root.appendingPathComponent("source"))
        let peer = makePeer()
        let image = try write("Images/photo.png", in: source, bytes: 1024)
        let file = try write("Files/large.txt", in: source, bytes: 2 * 1024 * 1024 + 17)
        let missing = attachment("missing", path: source.root.appendingPathComponent("Files/missing.txt").path)
        let message = ChatMessage(direction: .incoming, text: "备份消息", attachments: [image, file, missing])
        let group = ChatGroup(name: "备份群", memberIDs: [peer.id], ownerName: "我")
        source.history.saveMessage(message, for: peer, unreadCount: 2)
        source.history.saveMessage(ChatMessage(direction: .incoming, text: "共享图片", attachments: [image]), for: group, unreadCount: 1)
        let _: Void = try await receive { source.history.saveConversationSettings(.init(isPinned: true, isMuted: true, remark: "重要联系人", tags: ["工作"]), for: peer.id, completion: $0) }
        source.history.saveMessage(ChatMessage(direction: .outgoing, text: "WAL 中的最新消息"), for: peer, unreadCount: 2)
        let backup: DatabaseBackupPreview = try await receive { source.maintenance.createBackup(in: root, completion: $0) }
        let databaseHeader = try Data(contentsOf: backup.directory.appendingPathComponent("Database.sqlite"))
        precondition(Array(databaseHeader[18...19]) == [1, 1], "Portable backups must use rollback journaling")
        precondition(backup.manifest.messageCount == 3 && backup.manifest.conversationCount == 2)
        precondition(backup.manifest.files.count == 2 && backup.manifest.missingAttachmentCount == 1)
        let checked: DatabaseBackupPreview = try await receive { source.maintenance.inspectBackup(at: backup.directory, completion: $0) }
        FileHandle.standardError.write(Data("Maintenance: backup verified\n".utf8))
        precondition(checked.manifestHash == backup.manifestHash)
        let portable = try MaintenanceDatabase.open(backup.directory.appendingPathComponent("Database.sqlite"), readOnly: true)
        let records = try MaintenanceDatabase.attachments(in: portable)
        sqlite3_close(portable)
        precondition(records.flatMap(\.attachments).allSatisfy { $0.localPath.isEmpty || MaintenanceFileAccess.isSafeRelativePath($0.localPath) })
        let _: Error = await failure { source.maintenance.createBackup(in: source.root, completion: $0) }

        let destination = Fixture(root.appendingPathComponent("destination"))
        let originalFile = try write("Files/original.txt", in: destination, bytes: 19)
        let originalMessage = ChatMessage(direction: .incoming, text: "恢复前的消息", attachments: [originalFile])
        destination.history.saveMessage(originalMessage, for: makePeer("before-restore"), unreadCount: 0)
        let tampered = backup.directory.appendingPathComponent(backup.manifest.files[0].relativePath)
        let originalBytes = try Data(contentsOf: tampered)
        try Data("tampered".utf8).write(to: tampered)
        let _: Error = await failure { destination.maintenance.restoreBackup(backup, completion: $0) }
        let before: DatabaseStorageReport = try await receive { destination.maintenance.scan(completion: $0) }
        precondition(before.messageCount == 1 && originalFile.isAvailable && !destination.maintenance.requiresRestart)
        try originalBytes.write(to: tampered)
        let _: Void = try await receive { completion in
            destination.history.withMaintenanceDatabase(requiresRestart: false, operation: { database, _ in
                let snapshot = try MaintenanceDatabase.open(backup.directory.appendingPathComponent("Database.sqlite"), readOnly: true)
                defer { sqlite3_close(snapshot) }
                try MaintenanceDatabase.execute("CREATE TRIGGER reject_restore BEFORE INSERT ON messages BEGIN SELECT RAISE(ABORT, 'fixture'); END", in: database)
                do {
                    try MaintenanceDatabase.replaceContents(of: database, from: snapshot, paths: [:])
                    preconditionFailure("Failed inserts must roll back a restore transaction")
                } catch {}
                try MaintenanceDatabase.execute("DROP TRIGGER reject_restore", in: database)
                precondition(tryCount(database, "messages") == 1)
            }, completion: completion)
        }
        let restored: DatabaseRestoreSummary = try await receive { destination.maintenance.restoreBackup(backup, completion: $0) }
        FileHandle.standardError.write(Data("Maintenance: restore completed\n".utf8))
        precondition(restored.messageCount == 3 && restored.attachmentCount == 2 && originalFile.isAvailable)
        precondition(destination.maintenance.requiresRestart)
        let rejected = await failure { destination.history.saveConversationSettings(.init(isBlocked: true), for: peer.id, completion: $0) }
        guard case DatabaseMaintenanceError.restartRequired = rejected else { preconditionFailure("Old state must not write into a restored database") }
        let reopened = Fixture(destination.root)
        let snapshot: ChatHistorySnapshot = try await receive { reopened.history.loadSnapshot(completion: $0) }
        precondition(snapshot.totalMessageCount == 3 && snapshot.groups.first?.id == group.id)
        precondition(snapshot.peers.first?.deviceIdentifier == peer.deviceIdentifier && snapshot.peers.allSatisfy { !$0.isOnline })
        let settings = try reopened.history.loadConversationSettings()
        precondition(settings[peer.id]?.remark == "重要联系人" && settings[peer.id]?.isPinned == true)
        let page: ChatHistoryPage = try await receive { reopened.history.loadRecentMessages(for: peer.id, limit: 60, completion: $0) }
        let attachments = page.messages.flatMap(\.attachments)
        precondition(attachments.filter(\.isAvailable).count == 2 && attachments.filter { $0.localPath.isEmpty }.count == 1)
        precondition(attachments.filter(\.isAvailable).allSatisfy { $0.localPath.hasPrefix(reopened.maintenance.attachmentDirectory.path + "/") })
        let safety: DatabaseBackupPreview = try await receive { reopened.maintenance.inspectBackup(at: restored.safetyBackupURL, completion: $0) }
        FileHandle.standardError.write(Data("Maintenance: safety backup verified\n".utf8))
        precondition(safety.manifest.messageCount == 1 && safety.manifest.files.count == 1)
        let report: DatabaseStorageReport = try await receive { reopened.maintenance.scan(completion: $0) }
        precondition(report.safetyBackupBytes > 0 && report.unreferencedFileCount == 1)

        let malicious = root.appendingPathComponent("malicious.feiqbackup")
        try FileManager.default.copyItem(at: backup.directory, to: malicious)
        let manifestURL = malicious.appendingPathComponent("manifest.json")
        let maliciousManifest = DatabaseBackupManifest(id: UUID(), createdAt: Date(), database: backup.manifest.database,
            files: [.init(relativePath: "../outside", byteCount: 0, sha256: String(repeating: "0", count: 64))],
            messageCount: 3, conversationCount: 2, missingAttachmentCount: 0)
        try JSONEncoder().encode(maliciousManifest).write(to: manifestURL)
        let _: Error = await failure { reopened.maintenance.inspectBackup(at: malicious, completion: $0) }
        try FileManager.default.removeItem(at: manifestURL)
        try FileManager.default.createSymbolicLink(at: manifestURL, withDestinationURL: backup.directory.appendingPathComponent("manifest.json"))
        let _: Error = await failure { reopened.maintenance.inspectBackup(at: malicious, completion: $0) }
        return backup
    }

    @MainActor
    private static func checkAuthorization(_ fixture: Fixture, backup: DatabaseBackupPreview) async throws {
        let transport = MaintenanceTransport()
        fixture.history.savePeer(makePeer())
        let repository = DefaultChatRepository(networkService: transport, historyService: fixture.history,
            attachmentStorageService: fixture.storage, notificationService: MaintenanceNotifications())
        let model = ChatViewModel(repository: repository, settingsRepository: MaintenanceSettings())
        try await waitUntil { model.isRunning && model.peers.count == 1 }
        model.openDatabaseMaintenance()
        let maintenance = model.databaseMaintenance!
        maintenance.loadStatistics()
        try await waitUntil { !maintenance.isBusy }
        precondition(maintenance.statistics != nil)
        maintenance.previewCleanup()
        precondition(!maintenance.isBusy && maintenance.errorMessage != nil && !model.isMaintainingDatabase)
        model.stopNetwork()
        try await waitUntil { !model.isRunning && transport.hasPendingStop }
        maintenance.previewCleanup()
        try await waitUntil { !maintenance.isBusy }
        precondition(maintenance.cleanupPreview == nil && maintenance.errorMessage != nil, "A stopped UI must still wait for the network barrier")
        transport.finishStop()
        maintenance.previewCleanup()
        try await waitUntil { !maintenance.isBusy }
        precondition(maintenance.cleanupPreview != nil && !model.isMaintainingDatabase)
        maintenance.inspectBackup(at: backup.directory)
        try await waitUntil { !maintenance.isBusy }
        precondition(maintenance.backupPreview != nil)
        model.draft = "未发送的草稿"
        maintenance.performRestore()
        precondition(!maintenance.isBusy && maintenance.errorMessage?.contains("草稿") == true)
        model.draft = ""
        repository.fileTransferCenter.enqueue(attachment: attachment("queued", path: ""), direction: .incoming,
            peerName: "测试", ipAddress: "192.0.2.1", operation: { _, _ in FileTransferCancellation() })
        try await waitUntil { model.fileTransferSnapshot.unfinishedCount == 1 }
        maintenance.performRestore()
        precondition(!maintenance.isBusy && !model.requiresDatabaseRestart)
        model.cancelAllFileTransfers()
        try await waitUntil { model.fileTransferSnapshot.unfinishedCount == 0 }
        maintenance.performRestore()
        precondition(model.isMaintainingDatabase)
        model.startNetwork()
        try await waitUntil { !maintenance.isBusy }
        precondition(maintenance.requiresRestart && model.requiresDatabaseRestart && model.isDatabaseUnavailable && !model.isRunning)
        model.startNetwork()
        precondition(!model.isRunning)
    }

    private static func makePeer(_ identifier: String = "maintenance-peer") -> FeiQPeer {
        FeiQPeer(id: identifier, name: "联系人", hostName: "REMOTE-PC", ipAddress: "192.0.2.1", group: "",
                 lastSeen: Date(), isOnline: true, deviceIdentifier: "AABBCCDDEEFF0011")
    }

    private static func attachment(_ identifier: String, path: String, bytes: Int = 1, kind: ChatAttachmentKind = .file) -> ChatAttachment {
        ChatAttachment(id: identifier, kind: kind, fileName: URL(fileURLWithPath: path).lastPathComponent,
                       fileSize: Int64(bytes), modifiedAt: 0, fileAttributes: 1, localPath: path,
                       mimeType: kind == .image ? "image/png" : "text/plain")
    }

    private static func write(_ path: String, in fixture: Fixture, bytes: Int, date: Date? = nil) throws -> ChatAttachment {
        let url = fixture.root.appendingPathComponent(path)
        try Data(repeating: 42, count: bytes).write(to: url)
        if let date { try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path) }
        return attachment(UUID().uuidString, path: url.path, bytes: bytes, kind: path.hasPrefix("Images/") ? .image : .file)
    }

    private static func tryCount(_ database: OpaquePointer, _ table: String) -> Int {
        do { return try MaintenanceDatabase.count(table, in: database) }
        catch { preconditionFailure(error.localizedDescription) }
    }

    private static func receive<Value>(_ operation: (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in operation { continuation.resume(with: $0) } }
    }

    private static func failure<Value>(_ operation: (@escaping (Result<Value, Error>) -> Void) -> Void) async -> Error {
        do { _ = try await receive(operation); preconditionFailure("Unsafe maintenance operation unexpectedly succeeded") }
        catch { return error }
    }

    @MainActor
    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<700 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out waiting for maintenance state")
    }
}

private final class MaintenanceTransport: FeiQNetworkServiceProtocol {
    private let lock = NSLock()
    private var stopCompletion: (() -> Void)?
    var hasPendingStop: Bool { lock.withLock { stopCompletion != nil } }
    var onInlineImage: ((Data, String, Int, FeiQPacket, String) -> Void)?
    var onPacket: ((FeiQPacket, String, FeiQTransport, UInt16) -> Void)?
    var onLog: ((String) -> Void)?
    var onStateChange: ((Bool) -> Void)?
    func start(name: String, host: String, group: String) { onStateChange?(true) }
    func stop() { onStateChange?(false) }
    func stop(completion: @escaping () -> Void) { stop(); lock.withLock { stopCompletion = completion } }
    func finishStop() { let completion = lock.withLock { let pending = stopCompletion; stopCompletion = nil; return pending }; completion?() }
    func updateIdentity(name: String, host: String, group: String) {}
    func announce() {}
    func replyToEntry(from ipAddress: String) {}
    func sendTyping(isTyping: Bool, to ipAddress: String) {}
    func sendShake(to ipAddress: String) {}
    func sendText(_ text: String, to ipAddress: String, recipientName: String?) {}
    func sendFileMessage(_ text: String, attachments: [ChatAttachment], to ipAddress: String, recipientName: String?) {}
    func acknowledge(_ packet: FeiQPacket, to ipAddress: String) {}
    func downloadFile(_ attachment: FeiQFileAttachment, packetNumber: UInt64, from ipAddress: String,
                      to destinationURL: URL, completion: @escaping (Result<Void, Error>) -> Void) { completion(.failure(FeiQFileTransferError.fileNotFound)) }
}

private final class MaintenanceNotifications: NotificationService {
    var onNotificationSelected: ((String) -> Void)?
    func requestAuthorization() {}
    func notifyIncomingMessage(from sender: String, text: String, conversationID: String) {}
}

private final class MaintenanceSettings: AppSettingsRepository {
    func load() -> AppSettings { AppSettings(identity: .init(nickname: "本机", hostName: "LOCAL", groupName: ""), chatLoadAnimationMode: .instant) }
    func save(_ settings: AppSettings) {}
}
