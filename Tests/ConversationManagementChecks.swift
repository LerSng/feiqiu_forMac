import AppKit
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers

@main
struct ConversationManagementChecks {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feiq-conversations-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await checkPersistence(root.appendingPathComponent("persistence"))
        try await checkConversations(root.appendingPathComponent("conversations"))
        try await checkTransfers(root.appendingPathComponent("transfers"))
        try await checkUnreadableSettings(root.appendingPathComponent("unreadable"))
        print("Conversation management checks passed")
    }

    private static func checkPersistence(_ root: URL) async throws {
        let history = makeHistory(root)
        let preferences = DefaultConversationSettingsRepository(historyService: history)
        precondition(preferences.loadError == nil && preferences.snapshot.isEmpty)
        let peer = makePeer("192.0.2.30", name: "原昵称")
        history.saveMessage(ChatMessage(direction: .incoming, text: "保留历史", senderName: peer.name, recipientName: "我"),
                            for: peer, unreadCount: 4)
        var settings = ConversationSettings(isPinned: true, isMuted: true, remark: "  本地备注\n姓名  ",
                                             tags: [" 工作 ", "工作", "Project", "project", ""], isBlocked: true)
        let saved: ConversationSettings = try await receive { preferences.save(settings, for: peer.id, completion: $0) }
        precondition(saved.remark == "本地备注 姓名" && saved.tags == ["工作", "Project"])
        let snapshot: ChatHistorySnapshot = try await receive { history.loadSnapshot(completion: $0) }
        precondition(snapshot.totalMessageCount == 1 && snapshot.unreadCountsByPeer[peer.id] == nil)
        var renamed = peer
        renamed.name = "对方修改昵称"
        history.savePeer(renamed)
        let reopened = DefaultConversationSettingsRepository(historyService: makeHistory(root))
        precondition(reopened.settings(for: peer.id) == saved, "Presence and restart must not overwrite local settings")

        for invalid in [ConversationSettings(remark: String(repeating: "名", count: 81)),
                        ConversationSettings(tags: (0..<11).map { "标签\($0)" }),
                        ConversationSettings(tags: [String(repeating: "a", count: 25)])] {
            do {
                let _: ConversationSettings = try await receive { preferences.save(invalid, for: peer.id, completion: $0) }
                preconditionFailure("Invalid metadata must be rejected")
            } catch is ConversationSettingsError {}
        }
        precondition(preferences.settings(for: peer.id) == saved)
        try executeSQL(root.appendingPathComponent("history.sqlite"),
                       "CREATE TRIGGER reject_settings BEFORE UPDATE ON conversation_settings BEGIN SELECT RAISE(ABORT, 'test write failure'); END;")
        settings.remark = "不能写入"
        do {
            let _: ConversationSettings = try await receive { preferences.save(settings, for: peer.id, completion: $0) }
            preconditionFailure("Failed persistence must not update the active policy")
        } catch is ChatHistoryStoreError {}
        precondition(preferences.settings(for: peer.id) == saved)
        let persistedAfterFailure = try history.loadConversationSettings()
        precondition(persistedAfterFailure[peer.id] == saved)
        try executeSQL(root.appendingPathComponent("history.sqlite"), "DROP TRIGGER reject_settings;")
        let _: ConversationSettings = try await receive { preferences.save(ConversationSettings(), for: peer.id, completion: $0) }
        let resetSettings = try history.loadConversationSettings()
        precondition(preferences.snapshot.isEmpty && resetSettings.isEmpty)
        let remaining = try await messages(history, for: peer.id)
        precondition(remaining.count == 1 && remaining[0].text == "保留历史")
    }

    @MainActor
    private static func checkConversations(_ root: URL) async throws {
        let history = makeHistory(root)
        let transport = ManagementTransport()
        let notifications = ManagementNotifications()
        let storage = LocalChatAttachmentStorageService(rootURL: root)
        let first = makePeer("192.0.2.10", name: "张三")
        let second = makePeer("192.0.2.11", name: "李四")
        let third = makePeer("192.0.2.12", name: "王五")
        let group = ChatGroup(name: "测试群", memberIDs: [first.id, second.id], ownerName: "本机")
        for peer in [first, second, third] { history.savePeer(peer) }
        history.saveGroup(group)
        let repository = makeRepository(history: history, storage: storage, transport: transport, notifications: notifications)
        let model = ChatViewModel(repository: repository, settingsRepository: ManagementAppSettings())
        try await waitUntil("history load") { model.peers.count == 3 && model.groups.count == 1 && model.isRunning }
        transport.deliver(packet(1, from: second, command: .answerEntry), from: second)
        try await waitUntil("online contact") { model.peers.contains { $0.id == second.id && $0.isOnline } }
        model.toggleConversationPin(third.id)
        try await waitForSettings(model, third.id)
        precondition(model.peers.first?.id == third.id && !model.peers[0].isOnline, "Pinned offline contacts must stay above online ones")
        model.toggleConversationPin(group.id)
        try await waitForSettings(model, group.id)
        let _: Void = try await receive {
            model.saveConversationDetails(third.id, remark: "产品负责人", tags: " 工作 ，项目 A,工作 ", completion: $0)
        }
        precondition(model.displayName(for: third) == "产品负责人" && third.name == "王五")
        precondition(model.conversationSettings(for: third.id).tags == ["工作", "项目 A"])
        model.searchText = "负责人"
        precondition(model.filteredPeers.map(\.id) == [third.id])
        model.searchText = "工作"
        precondition(model.filteredPeers.map(\.id) == [third.id])
        model.searchText = ""
        model.selectedConversationTag = "项目 A"
        precondition(model.filteredPeers.map(\.id) == [third.id] && model.filteredGroups.isEmpty)
        model.searchText = "不存在"
        precondition(model.filteredPeers.isEmpty)
        model.searchText = ""
        model.selectedConversationTag = nil
        model.selectPeer(second.id)

        model.toggleConversationMute(third.id)
        try await waitForSettings(model, third.id)
        let shakeID = model.windowShakeID
        transport.deliver(packet(2, from: third, text: "免打扰也保存"), from: third)
        transport.deliver(packet(3, from: third, command: .shake), from: third)
        transport.deliver(packet(4, from: third, command: .remoteAssistanceRequest), from: third)
        try await waitUntil("muted unread") { model.unreadCount(for: third.id) == 2 }
        precondition(notifications.received.value.isEmpty && model.windowShakeID == shakeID && model.remoteAssistanceRequest == nil)
        let mutedHistory = try await messages(history, for: third.id)
        precondition(mutedHistory.count == 2)
        model.toggleConversationMute(third.id)
        try await waitForSettings(model, third.id)
        transport.deliver(packet(5, from: third, text: "恢复提醒"), from: third)
        try await waitUntil("restored notification") { notifications.received.value.count == 1 }
        precondition(notifications.received.value[0].sender == "产品负责人")
        precondition(model.displayName(for: model.peers.first { $0.id == third.id }!) == "产品负责人")

        let inline = packet(6, from: third, text: "/~#>11223344<B~")
        transport.deliver(inline, from: third)
        try await waitUntil("inline placeholder") { model.unreadCount(for: third.id) == 4 }
        let beforeBlock = try await messages(history, for: third.id)
        let beforeNotifications = notifications.received.value.count
        model.setConversationBlocked(true, for: third.id)
        try await waitForSettings(model, third.id)
        precondition(model.unreadCount(for: third.id) == 0)
        model.showsBlockedConversationsOnly = true
        precondition(model.filteredPeers.map(\.id) == [third.id] && model.filteredGroups.isEmpty)
        model.showsBlockedConversationsOnly = false
        let blockedPacket = packet(7, from: third, text: "不应收到")
        let acknowledgementCount = transport.acknowledgements.value
        transport.deliver(blockedPacket, from: third)
        transport.deliver(filePacket(8, from: third), from: third)
        transport.onInlineImage?(makeImage(), "11223344", 0, inline, third.ipAddress)
        transport.deliver(packet(9, from: third, command: .shake), from: third)
        transport.deliver(packet(10, from: third, command: .inputting), from: third)
        transport.deliver(packet(11, from: third, command: .remoteAssistanceRequest), from: third)
        try await waitUntil("blocked acknowledgements") { transport.acknowledgements.value == acknowledgementCount + 2 }
        try await Task.sleep(for: .milliseconds(60))
        let afterBlock = try await messages(history, for: third.id)
        precondition(afterBlock == beforeBlock)
        precondition(transport.downloadCount.value == 0 && notifications.received.value.count == beforeNotifications)
        precondition(model.remoteAssistanceRequest == nil && !model.isPeerTyping(third.id))
        let savedImages = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Images").path)
        precondition(savedImages.isEmpty)

        model.selectPeer(third.id)
        model.draft = "保留的草稿"
        let sentCount = transport.sent.value.count
        model.sendDraft()
        let provider = NSItemProvider(item: makeImage() as NSData, typeIdentifier: UTType.png.identifier)
        precondition(!model.sendDroppedAttachments([provider]) && model.draft == "保留的草稿")
        precondition(!model.canSendShake)
        repository.sendMessage(ChatMessage(direction: .outgoing, text: "禁止发送", senderName: "我", recipientName: third.name),
                               to: third, unreadCount: 0)
        repository.sendShake(to: third)
        repository.updateTyping(isTyping: true, for: third)
        precondition(transport.sent.value.count == sentCount && transport.shakes.value == 0 && transport.typing.value == 0)
        do {
            let _: ChatMessage = try await receive {
                repository.sendFile(from: root.appendingPathComponent("missing.txt"), to: third, unreadCount: 0, completion: $0)
            }
            preconditionFailure("Blocked file sends must fail before reading their source")
        } catch ConversationSettingsError.blocked {}

        model.setConversationBlocked(false, for: third.id)
        try await waitForSettings(model, third.id)
        model.selectPeer(second.id)
        transport.deliver(blockedPacket, from: third)
        try await waitUntil("duplicate acknowledgement") { transport.acknowledgements.value == acknowledgementCount + 3 }
        try await Task.sleep(for: .milliseconds(40))
        precondition(model.unreadCount(for: third.id) == 0, "Unblocking must not replay recently discarded packets")
        transport.deliver(packet(12, from: third, text: "解除后新消息"), from: third)
        try await waitUntil("unblocked message") { model.unreadCount(for: third.id) == 1 }
        model.setConversationBlocked(true, for: third.id)
        try await waitForSettings(model, third.id)

        model.toggleConversationMute(group.id)
        try await waitForSettings(model, group.id)
        let groupNotifications = notifications.received.value.count
        transport.deliver(packet(13, from: first, text: "群聊免打扰"), from: first)
        try await waitUntil("muted group") { model.unreadCount(for: group.id) == 1 }
        precondition(notifications.received.value.count == groupNotifications)
        try await waitUntil("group relay") { transport.sent.value.count == sentCount + 1 }
        precondition(transport.sent.value.last?.address == second.ipAddress)
        model.setConversationBlocked(true, for: group.id)
        try await waitForSettings(model, group.id)
        let firstUnread = model.unreadCount(for: first.id)
        transport.deliver(packet(14, from: first, text: "成员私聊仍保留"), from: first)
        try await waitUntil("private message with blocked group") { model.unreadCount(for: first.id) == firstUnread + 1 }
        precondition(model.unreadCount(for: group.id) == 0 && transport.sent.value.count == sentCount + 1)
        precondition(notifications.received.value.count == groupNotifications + 1, "Blocking a group must not mute member private chats")
        let groupHistory = try await messages(history, for: group.id)
        precondition(groupHistory.count == 1)
        let relayedText = DefaultGroupProtocolService().makeRelayText(groupName: group.name, senderName: "群成员", text: "已屏蔽群消息")
        let relayAcknowledgements = transport.acknowledgements.value
        transport.deliver(packet(16, from: first, text: relayedText), from: first)
        try await waitUntil("blocked relay acknowledgement") { transport.acknowledgements.value == relayAcknowledgements + 1 }
        try await Task.sleep(for: .milliseconds(30))
        precondition(model.unreadCount(for: first.id) == firstUnread + 1, "A blocked relay must not reappear as a private message")
        repository.sendGroupMessage(ChatMessage(direction: .outgoing, text: "不可发到屏蔽群", senderName: "我", recipientName: group.name),
                                    to: group, members: [first, second])
        precondition(transport.sent.value.count == sentCount + 1)

        model.setConversationBlocked(false, for: group.id)
        try await waitForSettings(model, group.id)
        model.setConversationBlocked(true, for: second.id)
        try await waitForSettings(model, second.id)
        repository.sendGroupMessage(ChatMessage(direction: .outgoing, text: "跳过屏蔽成员", senderName: "我", recipientName: group.name),
                                    to: group, members: [first, second])
        precondition(transport.sent.value.count == sentCount + 2 && transport.sent.value.last?.address == first.ipAddress)

        model.setConversationBlocked(true, for: group.id)
        try await waitForSettings(model, group.id)
        let historyBeforeRestart = try await messages(history, for: first.id)

        let restartedTransport = ManagementTransport()
        let restartedNotifications = ManagementNotifications()
        restartedTransport.onStart = {
            restartedTransport.deliver(packet(15, from: third, text: "启动瞬间也应屏蔽"), from: third)
            restartedTransport.deliver(packet(17, from: first, text: relayedText), from: first)
        }
        let restartedRepository = makeRepository(history: makeHistory(root), storage: storage,
                                                  transport: restartedTransport, notifications: restartedNotifications)
        let restarted = ChatViewModel(repository: restartedRepository, settingsRepository: ManagementAppSettings())
        try await waitUntil("restored preferences") { restarted.peers.count == 3 && restarted.isRunning }
        try await waitUntil("startup packet filtering") { restartedTransport.acknowledgements.value == 2 }
        precondition(restarted.conversationSettings(for: third.id).isBlocked && restarted.conversationSettings(for: third.id).isPinned)
        precondition(restarted.conversationSettings(for: group.id).isMuted && restarted.displayName(for: third) == "产品负责人")
        precondition(restarted.unreadCount(for: third.id) == 0 && restartedNotifications.received.value.isEmpty)
        let historyAfterRestart = try await messages(history, for: first.id)
        precondition(historyAfterRestart == historyBeforeRestart)
        restartedTransport.onStart = nil
    }

    @MainActor
    private static func checkTransfers(_ root: URL) async throws {
        let history = makeHistory(root)
        let storage = LocalChatAttachmentStorageService(rootURL: root)
        let transport = ManagementTransport()
        let peer = makePeer("192.0.2.40", name: "传输联系人")
        let group = ChatGroup(name: "文件群", memberIDs: [peer.id], ownerName: "本机")
        history.savePeer(peer)
        history.saveGroup(group)
        let repository = makeRepository(history: history, storage: storage, transport: transport, notifications: ManagementNotifications())
        let model = ChatViewModel(repository: repository, settingsRepository: ManagementAppSettings())
        try await waitUntil("transfer model") { model.peers.count == 1 && model.groups.count == 1 && model.isRunning }
        transport.deliver(packet(20, from: peer, command: .answerEntry), from: peer)
        try await waitUntil("transfer peer online") { model.peers.first?.isOnline == true }
        repository.fileTransferCenter.setPaused(true)
        let source = root.appendingPathComponent("original.txt")
        try Data("原文件必须保留".utf8).write(to: source)
        let attachment = try storage.prepareOutgoingFile(from: source)
        let message = ChatMessage(direction: .outgoing, text: "文件", senderName: "我", recipientName: group.name, attachments: [attachment])
        repository.sendGroupMessage(message, to: group, members: [peer])
        try await waitUntil("queued transfer") { model.fileTransferSnapshot.transfers.count == 1 }
        let identifier = model.fileTransferSnapshot.transfers[0].id
        precondition(model.fileTransferSnapshot.transfers[0].conversationID == group.id)
        model.setConversationBlocked(true, for: group.id)
        try await waitForSettings(model, group.id)
        try await waitUntil("cancel queued group transfer") { model.fileTransferSnapshot.transfers[0].state == .cancelled }
        repository.fileTransferCenter.setPaused(false)
        repository.fileTransferCenter.retry(identifier)
        try await waitUntil("blocked retry") { model.fileTransferSnapshot.transfers[0].state == .failed }
        precondition(transport.uploadCount.value == 0)
        model.setConversationBlocked(false, for: group.id)
        try await waitForSettings(model, group.id)
        repository.fileTransferCenter.retry(identifier)
        try await waitUntil("active transfer") { transport.uploadCount.value == 1 && model.fileTransferSnapshot.transfers[0].state.isActive }
        model.setConversationBlocked(true, for: peer.id)
        try await waitForSettings(model, peer.id)
        try await waitUntil("cancel active peer transfer") { model.fileTransferSnapshot.transfers[0].state == .cancelled }
        precondition(transport.cancelledUploads.value == 1)
        repository.fileTransferCenter.retry(identifier)
        try await waitUntil("peer retry blocked") { model.fileTransferSnapshot.transfers[0].state == .failed }
        precondition(transport.uploadCount.value == 1 && attachment.isAvailable && FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    private static func checkUnreadableSettings(_ root: URL) async throws {
        let history = makeHistory(root)
        let peer = makePeer("192.0.2.50", name: "错误数据")
        try executeSQL(root.appendingPathComponent("history.sqlite"),
                       "INSERT INTO conversation_settings VALUES ('192.0.2.50', 'invalid json');")
        let transport = ManagementTransport()
        let repository = makeRepository(history: history, storage: LocalChatAttachmentStorageService(rootURL: root),
                                        transport: transport, notifications: ManagementNotifications())
        let model = ChatViewModel(repository: repository, settingsRepository: ManagementAppSettings())
        precondition(repository.conversationSettingsLoadError != nil && model.conversationManagementError != nil)
        precondition(transport.startCount.value == 0, "A corrupt block list must not silently enable communication")
        repository.sendMessage(ChatMessage(direction: .outgoing, text: "不应发送", senderName: "我", recipientName: peer.name),
                               to: peer, unreadCount: 0)
        precondition(transport.sent.value.isEmpty)
        do {
            let _: ConversationSettings = try await receive {
                repository.saveConversationSettings(ConversationSettings(), for: peer.id, completion: $0)
            }
            preconditionFailure("Unreadable settings must not be silently overwritten")
        } catch {}
    }

    private static func makeHistory(_ root: URL) -> SQLiteChatHistoryService {
        SQLiteChatHistoryService(store: ChatHistoryStore(databaseURL: root.appendingPathComponent("history.sqlite"),
                                                         legacyURL: root.appendingPathComponent("missing.json")))
    }

    private static func makeRepository(history: ChatHistoryService, storage: ChatAttachmentStorageService,
                                       transport: ManagementTransport, notifications: NotificationService) -> DefaultChatRepository {
        DefaultChatRepository(networkService: transport, historyService: history,
                              attachmentStorageService: storage, notificationService: notifications)
    }

    private static func makePeer(_ address: String, name: String) -> FeiQPeer {
        FeiQPeer(id: address, name: name, hostName: "remote-" + address, ipAddress: address, group: "",
                 lastSeen: Date(), isOnline: true)
    }

    private static func packet(_ number: UInt64, from peer: FeiQPeer, text: String = "", command: FeiQCommand = .sendMessage) -> FeiQPacket {
        FeiQPacket(packetNumber: number, senderName: peer.name, senderHost: peer.hostName, command: command, additionalText: text)
    }

    private static func filePacket(_ number: UInt64, from peer: FeiQPeer) -> FeiQPacket {
        let attachment = FeiQFileAttachment(fileID: "1", fileName: "secret.txt", fileSize: 8, modifiedAt: 1, fileAttributes: 1)
        return FeiQPacket(packetNumber: number, senderName: peer.name, senderHost: peer.hostName,
                          command: FeiQCommand.sendMessage.rawValue | FeiQPacket.fileAttachOption,
                          additionalData: FeiQAttachmentCodec.encode(message: "文件", attachments: [attachment], preferUTF8: false))
    }

    private static func makeImage() -> Data {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func messages(_ history: ChatHistoryService, for identifier: String) async throws -> [ChatMessage] {
        let page: ChatHistoryPage = try await receive { history.loadRecentMessages(for: identifier, limit: 60, completion: $0) }
        return page.messages
    }

    private static func receive<Value>(_ operation: (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in operation { continuation.resume(with: $0) } }
    }

    private static func executeSQL(_ url: URL, _ sql: String) throws {
        var database: OpaquePointer?
        precondition(sqlite3_open(url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "ConversationManagementChecks", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
        }
    }

    @MainActor
    private static func waitForSettings(_ model: ChatViewModel, _ identifier: String) async throws {
        try await waitUntil("settings save") { !model.savingConversationIDs.contains(identifier) }
        precondition(model.conversationManagementError == nil)
    }

    @MainActor
    private static func waitUntil(_ description: String, _ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out: " + description)
    }
}

private final class ManagementValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func update(_ operation: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; operation(&stored) }
}

private final class ManagementTransport: FeiQNetworkServiceProtocol {
    struct Sent { let address: String; let text: String }
    let sent = ManagementValue<[Sent]>([])
    let acknowledgements = ManagementValue(0)
    let downloadCount = ManagementValue(0)
    let uploadCount = ManagementValue(0)
    let cancelledUploads = ManagementValue(0)
    let startCount = ManagementValue(0)
    let shakes = ManagementValue(0)
    let typing = ManagementValue(0)
    var onStart: (() -> Void)?
    var onInlineImage: ((Data, String, Int, FeiQPacket, String) -> Void)?
    var onPacket: ((FeiQPacket, String, FeiQTransport, UInt16) -> Void)?
    var onLog: ((String) -> Void)?
    var onStateChange: ((Bool) -> Void)?
    func start(name: String, host: String, group: String) { startCount.update { $0 += 1 }; onStateChange?(true); onStart?() }
    func stop() { onStateChange?(false) }
    func updateIdentity(name: String, host: String, group: String) {}
    func announce() {}
    func replyToEntry(from ipAddress: String) {}
    func sendTyping(isTyping: Bool, to ipAddress: String) { typing.update { $0 += 1 } }
    func sendShake(to ipAddress: String) { shakes.update { $0 += 1 } }
    func sendText(_ text: String, to ipAddress: String, recipientName: String?) { sent.update { $0.append(Sent(address: ipAddress, text: text)) } }
    func sendFileMessage(_ text: String, attachments: [ChatAttachment], to ipAddress: String, recipientName: String?) {
        sent.update { $0.append(Sent(address: ipAddress, text: text)) }
    }
    func acknowledge(_ packet: FeiQPacket, to ipAddress: String) { acknowledgements.update { $0 += 1 } }
    func deliver(_ packet: FeiQPacket, from peer: FeiQPeer) { onPacket?(packet, peer.ipAddress, .udp, 2425) }
    func downloadFile(_ attachment: FeiQFileAttachment, packetNumber: UInt64, from ipAddress: String,
                      to destinationURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        downloadCount.update { $0 += 1 }
        completion(.failure(FeiQFileTransferError.fileNotFound))
    }
    func uploadFile(_ attachment: ChatAttachment, text: String, to ipAddress: String, recipientName: String?,
                    progress: @escaping (FileTransferProgress) -> Void, completion: @escaping (Result<Void, Error>) -> Void) -> FileTransferCancellation {
        let cancellation = FileTransferCancellation()
        cancellation.onCancel { [cancelledUploads] in
            cancelledUploads.update { $0 += 1 }
            completion(.failure(FeiQFileTransferError.cancelled))
        }
        uploadCount.update { $0 += 1 }
        progress(FileTransferProgress(bytesTransferred: 0, state: .waitingForPeer))
        return cancellation
    }
}

private final class ManagementNotifications: NotificationService {
    struct Notice { let sender: String; let conversationID: String }
    let received = ManagementValue<[Notice]>([])
    var onNotificationSelected: ((String) -> Void)?
    func requestAuthorization() {}
    func notifyIncomingMessage(from sender: String, text: String, conversationID: String) {
        received.update { $0.append(Notice(sender: sender, conversationID: conversationID)) }
    }
}

private final class ManagementAppSettings: AppSettingsRepository {
    func load() -> AppSettings {
        AppSettings(identity: FeiQIdentity(nickname: "本机", hostName: "local-test", groupName: ""), chatLoadAnimationMode: .instant)
    }
    func save(_ settings: AppSettings) {}
}
