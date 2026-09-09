import AppKit
import Foundation
import SQLite3

@main
enum PeerIdentityChecks {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feiq-peer-identity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await checkIdentity(root.appendingPathComponent("identity.sqlite"))
        try await checkLegacyMigration(root.appendingPathComponent("legacy.sqlite"))
        try await checkRouting(root.appendingPathComponent("routing"))
        print("Peer identity checks passed")
    }

    private static func checkIdentity(_ databaseURL: URL) async throws {
        let history = makeHistory(databaseURL)
        let session = DefaultSessionRepository(historyService: history)
        let firstPacket = packet(1, host: "WINDOWS-PC", identifier: "AABBCCDDEEFF0011")
        let first = session.upsertPeer(packet: firstPacket, ipAddress: "192.0.2.10")
        let moved = session.upsertPeer(packet: packet(2, host: "RENAMED-PC", identifier: "aabbccddeeff0011"), ipAddress: "192.0.2.20")
        precondition(first.id == moved.id && moved.ipAddress == "192.0.2.20" && moved.deviceIdentifier == "AABBCCDDEEFF0011")
        precondition(first.id != first.ipAddress, "New conversation identifiers must not depend on an IP address")
        precondition(session.markPeerOffline(packet: firstPacket, ipAddress: "192.0.2.10") == nil)
        let snapshot: ChatHistorySnapshot = try await receive { history.loadSnapshot(completion: $0) }
        let reopened = makeHistory(databaseURL)
        let persisted: ChatHistorySnapshot = try await receive { reopened.loadSnapshot(completion: $0) }
        precondition(snapshot.peers.count == 1 && persisted.peers.first?.deviceIdentifier == moved.deviceIdentifier)
        let restarted = DefaultSessionRepository(historyService: reopened)
        restarted.restore(persisted.peers)
        let again = restarted.upsertPeer(packet: packet(3, host: "THIRD-NAME", identifier: "AABBCCDDEEFF0011"), ipAddress: "192.0.2.30")
        precondition(again.id == first.id)
        let replacement = restarted.upsertPeer(packet: packet(4, host: "THIRD-NAME", identifier: "1122334455667788"), ipAddress: "192.0.2.30")
        precondition(replacement.id != again.id, "Reused addresses and equal hostnames must not override a different device identifier")
        precondition(restarted.peers(withIDs: [again.id]).first?.isOnline == false)
        precondition(restarted.markPeerOffline(packet: packet(5, host: "THIRD-NAME", identifier: "AABBCCDDEEFF0011"), ipAddress: "192.0.2.30")?.id != replacement.id)

        let legacy = peer("192.0.2.40", host: "Legacy-PC", name: "对方昵称")
        let fallback = DefaultSessionRepository(historyService: history)
        fallback.restore([legacy])
        let withAccount = fallback.upsertPeer(packet: packet(6, host: " legacy-pc. ", name: "Administrator", command: .sendMessage), ipAddress: "192.0.2.41")
        precondition(withAccount.id == legacy.id && withAccount.displayName == legacy.displayName)
        let unrelated = fallback.upsertPeer(packet: packet(7, host: "OTHER-PC", name: legacy.name), ipAddress: "192.0.2.42")
        precondition(unrelated.id != legacy.id, "Nickname equality alone must never merge contacts")
        let unidentified = fallback.upsertPeer(packet: packet(8, host: "", name: legacy.name), ipAddress: "192.0.2.43")
        precondition(unidentified.id != legacy.id)
        precondition(PeerIdentity.deviceIdentifier("00000000") == nil)
        let oldJSON = Data("{\"id\":\"old\",\"name\":\"name\",\"hostName\":\"host\",\"ipAddress\":\"192.0.2.1\",\"group\":\"\",\"lastSeen\":0,\"isOnline\":false}".utf8)
        let decoded = try JSONDecoder().decode(FeiQPeer.self, from: oldJSON)
        precondition(decoded.deviceIdentifier == nil)
    }

    private static func checkLegacyMigration(_ databaseURL: URL) async throws {
        try execute(databaseURL, """
            CREATE TABLE conversations(peer_id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL DEFAULT '',
                host_name TEXT NOT NULL DEFAULT '', ip_address TEXT NOT NULL DEFAULT '', group_name TEXT NOT NULL DEFAULT '',
                last_seen REAL NOT NULL DEFAULT 0, is_online INTEGER NOT NULL DEFAULT 0, unread_count INTEGER NOT NULL DEFAULT 0,
                conversation_kind TEXT NOT NULL DEFAULT 'peer');
            """)
        let history = makeHistory(databaseURL)
        let oldest = peer("192.0.2.50", host: "DESKTOP-ZHANG", name: "张三", lastSeen: Date(timeIntervalSince1970: 10))
        let duplicate = peer("192.0.2.60", host: "desktop-zhang", name: "张三", lastSeen: Date(timeIntervalSince1970: 20))
        let unrelated = peer("192.0.2.70", host: "OTHER-DESKTOP", name: "张三")
        let image = attachment("deleted-image", kind: .image)
        let first = ChatMessage(direction: .incoming, text: "换 IP 之前", senderName: "张三", date: Date(timeIntervalSince1970: 1), attachments: [image])
        let second = ChatMessage(direction: .incoming, text: "换 IP 之后", senderName: "张三", date: Date(timeIntervalSince1970: 2), attachments: [attachment("file")])
        history.saveMessage(first, for: oldest, unreadCount: 2)
        history.saveMessage(second, for: duplicate, unreadCount: 3)
        history.savePeer(unrelated)
        let group = ChatGroup(name: "工作群", memberIDs: [oldest.id, duplicate.id, unrelated.id], ownerName: "我")
        history.saveGroup(group)
        let _: Void = try await receive { history.saveConversationSettings(.init(isPinned: true, remark: "同事", tags: ["工作"]), for: oldest.id, completion: $0) }
        let _: Void = try await receive { history.saveConversationSettings(.init(isMuted: true, tags: ["项目"]), for: duplicate.id, completion: $0) }
        let _: ChatMessage = try await receive {
            history.removeImage(attachmentID: image.id, messageID: first.id, conversationID: oldest.id,
                                deleteUnreferencedFile: { _ in }, completion: $0)
        }
        let settings = try history.loadConversationSettings()
        let snapshot: ChatHistorySnapshot = try await receive { history.loadSnapshot(completion: $0) }
        precondition(Set(snapshot.peers.map(\.id)) == [oldest.id, unrelated.id])
        precondition(snapshot.peers.first { $0.id == oldest.id }?.ipAddress == duplicate.ipAddress)
        precondition(snapshot.groups.first?.memberIDs == [oldest.id, unrelated.id])
        precondition(snapshot.totalMessageCount == 2 && snapshot.unreadCountsByPeer[oldest.id] == 5)
        precondition(settings[oldest.id]?.isPinned == true && settings[oldest.id]?.isMuted == true)
        precondition(settings[oldest.id]?.tags == ["工作", "项目"] && settings[duplicate.id] == nil)
        let messages: ChatHistoryPage = try await receive { history.loadRecentMessages(for: oldest.id, limit: 60, completion: $0) }
        precondition(Set(messages.messages.map(\.id)) == [first.id, second.id])
        precondition(messages.messages.first { $0.id == first.id }?.attachments.isEmpty == true)
        let tombstones: Int = try await receive { completion in
            history.withMaintenanceDatabase(requiresRestart: false, operation: { database, _ in
                try MaintenanceDatabase.count("deleted_message_images", in: database)
            }, completion: completion)
        }
        precondition(tombstones == 1)
        let again: ChatHistorySnapshot = try await receive { makeHistory(databaseURL).loadSnapshot(completion: $0) }
        precondition(again.peers.count == 2 && again.totalMessageCount == 2)
    }

    @MainActor
    private static func checkRouting(_ root: URL) async throws {
        let history = makeHistory(root.appendingPathComponent("history.sqlite"))
        let transport = IdentityTransport()
        let original = peer("192.0.2.80", host: "CHAT-PC", name: "联系人", identifier: "AABBCCDD00112233")
        let message = ChatMessage(direction: .incoming, text: "历史消息", senderName: original.name)
        history.saveMessage(message, for: original, unreadCount: 0)
        let group = ChatGroup(name: "群聊", memberIDs: [original.id], ownerName: "我")
        history.saveGroup(group)
        let storage = LocalChatAttachmentStorageService(rootURL: root)
        let repository = DefaultChatRepository(networkService: transport, historyService: history, attachmentStorageService: storage,
                                                notificationService: IdentityNotifications())
        let model = ChatViewModel(repository: repository, settingsRepository: IdentitySettings())
        try await waitUntil { model.peers.count == 1 && model.isRunning }
        model.selectPeer(original.id)
        try await waitUntil { model.messages(for: original.id).count == 1 && !model.isLoadingMessages }
        model.draft = "未发送草稿"
        transport.deliver(packet(10, host: "CHAT-PC", identifier: original.deviceIdentifier), address: "192.0.2.81")
        try await waitUntil { model.selectedPeer?.ipAddress == "192.0.2.81" }
        precondition(model.selectedPeerID == original.id && model.peers.count == 1 && model.draft == "未发送草稿")
        precondition(model.messages(for: original.id).first?.id == message.id)
        model.sendDraft()
        precondition(transport.sentAddresses.last == "192.0.2.81")
        repository.sendMessage(ChatMessage(direction: .outgoing, text: "图片", attachments: [attachment("image", kind: .image)]), to: original, unreadCount: 0)
        precondition(transport.sentAddresses.last == "192.0.2.81")
        repository.sendGroupMessage(ChatMessage(direction: .outgoing, text: "群消息"), to: group, members: [original])
        precondition(transport.sentAddresses.last == "192.0.2.81")

        repository.fileTransferCenter.setPaused(true)
        repository.sendMessage(ChatMessage(direction: .outgoing, text: "文件", attachments: [attachment("outgoing-file")]), to: original, unreadCount: 0)
        try await waitUntil { model.fileTransferSnapshot.queuedCount == 1 }
        transport.deliver(packet(11, host: "CHAT-PC", identifier: original.deviceIdentifier), address: "192.0.2.82")
        try await waitUntil { model.selectedPeer?.ipAddress == "192.0.2.82" }
        repository.fileTransferCenter.setPaused(false)
        try await waitUntil { model.fileTransferSnapshot.failedCount == 1 }
        precondition(transport.uploadAddresses == ["192.0.2.82"])
        transport.deliver(packet(12, host: "CHAT-PC", identifier: original.deviceIdentifier), address: "192.0.2.83")
        try await waitUntil { model.selectedPeer?.ipAddress == "192.0.2.83" }
        model.retryFileTransfer(model.fileTransferSnapshot.transfers[0].id)
        try await waitUntil { model.fileTransferSnapshot.transfers[0].state == .completed }
        precondition(transport.uploadAddresses == ["192.0.2.82", "192.0.2.83"])
        precondition(model.fileTransferSnapshot.transfers[0].ipAddress == "192.0.2.83")

        let _: ConversationSettings = try await receive { repository.saveConversationSettings(.init(isBlocked: true), for: original.id, completion: $0) }
        transport.deliver(packet(13, host: "CHAT-PC", identifier: original.deviceIdentifier, command: .sendMessage, text: "屏蔽消息"), address: "192.0.2.84")
        try await waitUntil { model.selectedPeer?.ipAddress == "192.0.2.84" && transport.acknowledgements == 1 }
        precondition(!model.messages(for: original.id).contains { $0.text == "屏蔽消息" })
        transport.deliver(packet(14, host: "NEW-PC", identifier: "FFEEDDCC00112233", command: .sendMessage, text: "新设备使用旧 IP"), address: original.ipAddress)
        try await waitUntil { model.peers.count == 2 && transport.acknowledgements == 2 }
        let replacement = model.peers.first { $0.id != original.id }!
        let stored: ChatHistoryPage = try await receive { history.loadRecentMessages(for: replacement.id, limit: 60, completion: $0) }
        precondition(stored.messages.contains { $0.text == "新设备使用旧 IP" })
        let snapshot: ChatHistorySnapshot = try await receive { history.loadSnapshot(completion: $0) }
        precondition(snapshot.peers.first { $0.id == original.id }?.ipAddress == "192.0.2.84", "Delayed saves must not restore the old address")
        model.stopNetwork()
    }

    private static func makeHistory(_ url: URL) -> SQLiteChatHistoryService {
        SQLiteChatHistoryService(store: ChatHistoryStore(databaseURL: url, legacyURL: url.appendingPathExtension("missing")))
    }

    private static func peer(_ address: String, host: String, name: String, lastSeen: Date = Date(), identifier: String? = nil) -> FeiQPeer {
        FeiQPeer(id: address, name: name, hostName: host, ipAddress: address, group: "", lastSeen: lastSeen, isOnline: true, deviceIdentifier: identifier)
    }

    private static func packet(_ number: UInt64, host: String, name: String = "联系人", identifier: String? = nil,
                               command: FeiQCommand = .answerEntry, text: String = "") -> FeiQPacket {
        FeiQPacket(packetNumber: number, senderName: name, senderHost: host, command: command, additionalText: text,
                   versionIdentifier: identifier.map { "1_lbt6_0#128#\($0)#0#0#0#4001#9" } ?? "1")
    }

    private static func attachment(_ identifier: String, kind: ChatAttachmentKind = .file) -> ChatAttachment {
        ChatAttachment(id: identifier, kind: kind, fileName: "附件", fileSize: 1, modifiedAt: 0,
                       fileAttributes: 1, localPath: "", mimeType: kind == .image ? "image/png" : "text/plain")
    }

    private static func receive<Value>(_ operation: (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in operation { continuation.resume(with: $0) } }
    }

    @MainActor
    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out waiting for peer identity state")
    }

    private static func execute(_ url: URL, _ sql: String) throws {
        let database = try MaintenanceDatabase.open(url, readOnly: false)
        defer { sqlite3_close(database) }
        try MaintenanceDatabase.execute(sql, in: database)
    }
}

private final class IdentityTransport: FeiQNetworkServiceProtocol {
    private let lock = NSLock()
    private var sent: [String] = []
    private var uploads: [String] = []
    private var acknowledged = 0
    var sentAddresses: [String] { lock.withLock { sent } }
    var uploadAddresses: [String] { lock.withLock { uploads } }
    var acknowledgements: Int { lock.withLock { acknowledged } }
    var onInlineImage: ((Data, String, Int, FeiQPacket, String) -> Void)?
    var onPacket: ((FeiQPacket, String, FeiQTransport, UInt16) -> Void)?
    var onLog: ((String) -> Void)?
    var onStateChange: ((Bool) -> Void)?
    func start(name: String, host: String, group: String) { onStateChange?(true) }
    func stop() { onStateChange?(false) }
    func updateIdentity(name: String, host: String, group: String) {}
    func announce() {}
    func replyToEntry(from ipAddress: String) {}
    func sendTyping(isTyping: Bool, to ipAddress: String) {}
    func sendShake(to ipAddress: String) {}
    func sendText(_ text: String, to ipAddress: String, recipientName: String?) { lock.withLock { sent.append(ipAddress) } }
    func sendFileMessage(_ text: String, attachments: [ChatAttachment], to ipAddress: String, recipientName: String?) { lock.withLock { sent.append(ipAddress) } }
    func acknowledge(_ packet: FeiQPacket, to ipAddress: String) { lock.withLock { acknowledged += 1 } }
    func deliver(_ packet: FeiQPacket, address: String) { onPacket?(packet, address, .udp, 2425) }
    func downloadFile(_ attachment: FeiQFileAttachment, packetNumber: UInt64, from ipAddress: String,
                      to destinationURL: URL, completion: @escaping (Result<Void, Error>) -> Void) { completion(.failure(FeiQFileTransferError.fileNotFound)) }
    func uploadFile(_ attachment: ChatAttachment, text: String, to ipAddress: String, recipientName: String?,
                    progress: @escaping (FileTransferProgress) -> Void, completion: @escaping (Result<Void, Error>) -> Void) -> FileTransferCancellation {
        let count = lock.withLock { uploads.append(ipAddress); return uploads.count }
        completion(count == 1 ? .failure(FeiQFileTransferError.peerTimedOut) : .success(()))
        return FileTransferCancellation()
    }
}

private final class IdentityNotifications: NotificationService {
    var onNotificationSelected: ((String) -> Void)?
    func requestAuthorization() {}
    func notifyIncomingMessage(from sender: String, text: String, conversationID: String) {}
}

private final class IdentitySettings: AppSettingsRepository {
    func load() -> AppSettings { AppSettings(identity: .init(nickname: "本机", hostName: "LOCAL", groupName: ""), chatLoadAnimationMode: .instant) }
    func save(_ settings: AppSettings) {}
}
