import AppKit
import Foundation

@main
enum DownloadCenterChecks {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feiq-download-center-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await checkHistory(root: root)
        try await checkRefreshAndNavigation(root: root)
        try await checkSearchState()
        print("Download center checks passed")
    }

    private static func checkHistory(root: URL) async throws {
        let service = makeHistory(root.appendingPathComponent("query.sqlite"))
        let peer = makePeer("peer-'one", name: "联系人甲")
        let other = makePeer("peer-two", name: "联系人乙")
        let group = ChatGroup(name: "项目群", memberIDs: [peer.id], ownerName: "我")
        let day = Calendar.current.startOfDay(for: Date())
        let image = attachment("image", kind: .image, name: "设计图.png")
        let file = attachment("file", name: "report%_O'Brien\\v2.pdf")
        let first = message(1, date: day, attachments: [image, file])
        let grouped = message(2, date: day.addingTimeInterval(1), attachments: [image, file])
        let outgoing = message(3, date: day.addingTimeInterval(2), attachments: [file], direction: .outgoing)
        let earlier = message(4, date: day.addingTimeInterval(-1), attachments: [file])
        service.saveMessage(first, for: peer, unreadCount: 0)
        service.saveMessage(grouped, for: group, unreadCount: 0)
        service.saveMessage(outgoing, for: peer, unreadCount: 0)
        service.saveMessage(earlier, for: other, unreadCount: 0)
        let _: Void = try await receive { service.saveConversationSettings(.init(remark: "采购负责人"), for: peer.id, completion: $0) }
        let initial = try await search(service)
        precondition(initial.results.count == 5 && initial.results.allSatisfy { $0.direction == .incoming })
        precondition(initial.results.filter { $0.conversationID == peer.id }.allSatisfy { $0.conversationName == "采购负责人" })
        precondition(initial.results.filter(\.isGroup).allSatisfy { $0.conversationName == group.displayName })
        precondition(initial.results.allSatisfy { !$0.attachment.isAvailable })
        for (query, count) in [
            (ChatAttachmentHistoryQuery(direction: nil), 6),
            (.init(direction: .outgoing), 1),
            (.init(kind: .image), 2),
            (.init(kind: .file), 3),
            (.init(conversationID: peer.id), 2),
            (.init(conversationID: group.id), 2),
            (.init(text: "采购负责人"), 2),
            (.init(text: "联系人甲"), 2),
            (.init(text: "项目群"), 2),
            (.init(text: "%_"), 3),
            (.init(text: "O'Brien\\v2"), 3),
            (.init(text: "REPORT", kind: .image), 0),
            (.init(text: "仅消息正文"), 0),
            (.init(text: "' OR 1=1 --"), 0),
            (.init(startDate: day, endDate: day), 4)
        ] {
            let page = try await search(service, query: query)
            precondition(page.results.count == count, "Unexpected attachment matches: \(query)")
        }
        do {
            _ = try await search(service, query: .init(startDate: day.addingTimeInterval(86_400), endDate: day))
            preconditionFailure("Reversed date range must fail")
        } catch ChatHistorySearchError.invalidDateRange {}

        let bundle = message(5, date: day.addingTimeInterval(3), attachments: (0..<241).map { attachment("batch-\($0)") })
        service.saveMessage(bundle, for: peer, unreadCount: 0)
        for index in 0..<205 {
            service.saveMessage(message(1000 + index, date: day, attachments: [file]), for: other, unreadCount: 0)
        }
        var results: [ChatAttachmentHistoryResult] = []
        var cursor: ChatAttachmentHistoryCursor?
        repeat {
            let page = try await search(service, cursor: cursor, limit: 17)
            precondition(page.results.count <= 17 && (!page.hasMore || page.nextCursor != cursor))
            results += page.results
            cursor = page.hasMore ? page.nextCursor : nil
        } while cursor != nil
        precondition(results.count == 451 && Set(results.map(\.id)).count == results.count)
        precondition(results.prefix(241).map(\.attachmentIndex) == Array(0..<241))
        let capped = try await search(service, limit: Int.max)
        precondition(capped.results.count == 200 && capped.hasMore)
        let reopened = makeHistory(root.appendingPathComponent("query.sqlite"))
        let restored = try await search(reopened, query: .init(conversationID: group.id))
        precondition(restored.results.count == 2)

        let _: [ChatAttachment] = try await receive { service.deleteMessage(id: grouped.id, conversationID: group.id, completion: $0) }
        let afterDelete = try await search(service, query: .init(conversationID: group.id))
        precondition(afterDelete.results.isEmpty)
        let _: ChatMessage = try await receive {
            service.removeImage(attachmentID: image.id, messageID: first.id, conversationID: peer.id,
                                deleteUnreferencedFile: { _ in }, completion: $0)
        }
        let afterRemoval = try await search(service, query: .init(kind: .image))
        precondition(afterRemoval.results.isEmpty)
        let imported = message(9000, date: day, attachments: [image])
        let archive = ChatHistoryArchive(peers: [other], groups: [], messages: [.init(conversationID: other.id, message: imported)])
        let _: ChatHistoryImportSummary = try await receive { service.importArchive(archive, completion: $0) }
        let afterImport = try await search(service, query: .init(kind: .image))
        precondition(afterImport.results.map(\.messageID) == [imported.id])
    }

    @MainActor
    private static func checkRefreshAndNavigation(root: URL) async throws {
        _ = NSApplication.shared
        let service = makeHistory(root.appendingPathComponent("refresh.sqlite"))
        let peer = makePeer("refresh-peer", name: "刷新联系人")
        service.savePeer(peer)
        let repository = DefaultChatRepository(networkService: DownloadTestTransport(), historyService: service,
                                                attachmentStorageService: LocalChatAttachmentStorageService(rootURL: root),
                                                notificationService: DownloadTestNotifications())
        let model = ChatViewModel(repository: repository, settingsRepository: DownloadTestSettings())
        try await waitUntil { model.peers.contains { $0.id == peer.id } }
        let history = model.attachmentHistory
        history.start()
        try await waitUntil { !history.isSearching }
        let stored = message(8000, date: Date(), attachments: [attachment("refresh-image", kind: .image)])
        repository.persistMessage(stored, for: peer, unreadCount: 0)
        try await waitUntil { history.results.map(\.messageID) == [stored.id] }
        let result = history.results[0]
        model.showingFileTransfers = true
        model.revealHistoryAttachment(result)
        try await waitUntil { !model.isLocatingHistoryMessage }
        precondition(!model.showingFileTransfers && model.highlightedMessageID == stored.id && model.selectedPeerID == peer.id)

        let _: Void = try await receive { repository.deleteMessage(stored, conversationID: peer.id, completion: $0) }
        try await waitUntil { history.results.isEmpty && !history.isSearching }
        model.showingFileTransfers = true
        model.revealHistoryAttachment(result)
        try await waitUntil { !model.isLocatingHistoryMessage }
        precondition(model.showingFileTransfers && model.historyNavigationError != nil)

        let imported = message(8001, date: Date(), attachments: [attachment("imported-file")])
        let preview = ChatHistoryImportPreview(sourceURL: root.appendingPathComponent("archive.txt"),
                                               archive: .init(peers: [peer], groups: [], messages: [.init(conversationID: peer.id, message: imported)]),
                                               missingAttachmentCount: 1)
        let _: ChatHistoryImportSummary = try await receive { repository.importHistory(preview, completion: $0) }
        try await waitUntil { history.results.map(\.messageID) == [imported.id] }
        let _: ConversationSettings = try await receive {
            repository.saveConversationSettings(.init(remark: "已修改备注"), for: peer.id, completion: $0)
        }
        try await waitUntil { history.results.first?.conversationName == "已修改备注" }
        history.stop()
        model.cancelHistoryNavigation()
    }

    @MainActor
    private static func checkSearchState() async throws {
        let provider = DownloadSearchProvider()
        let history = AttachmentHistoryViewModel(search: provider.search)
        let first = ChatAttachmentHistoryResult(conversationID: "peer", conversationName: "联系人", isGroup: false,
                                                messageID: UUID(), attachment: attachment("first"), attachmentIndex: 0,
                                                date: Date(), senderName: "发送者", direction: .incoming)
        history.start()
        history.query.text = "新查询"
        history.searchNow()
        precondition(provider.requests.count == 2)
        provider.requests[1].completion(.success(.init(results: [first], hasMore: true, nextCursor: first.cursor)))
        provider.requests[0].completion(.failure(ChatHistorySearchError.messageUnavailable))
        try await waitUntil { !history.isSearching }
        precondition(history.results.count == 1 && history.errorMessage == nil)
        history.loadMore()
        history.loadMore()
        precondition(provider.requests.count == 3 && provider.requests[2].cursor == first.cursor)
        provider.requests[2].completion(.failure(ChatHistorySearchError.messageUnavailable))
        try await waitUntil { !history.isSearching }
        precondition(history.hasMore && history.results.count == 1 && history.errorMessage != nil)
        history.retry()
        provider.requests[3].completion(.success(.init(results: [first], hasMore: false, nextCursor: first.cursor)))
        try await waitUntil { !history.isSearching }
        precondition(history.results.count == 1 && !history.hasMore)
        history.refresh()
        history.refresh()
        try await waitUntil { provider.requests.count == 5 }
        precondition(history.results.count == 1 && provider.requests[4].cursor == nil)
        history.stop()
        provider.requests[4].completion(.success(.init(results: [], hasMore: false, nextCursor: nil)))
        try await Task.sleep(for: .milliseconds(40))
        precondition(history.results.count == 1 && !history.isSearching)
        history.refresh()
        precondition(provider.requests.count == 5)
        history.query.startDate = Date().addingTimeInterval(172_800)
        history.query.endDate = Date()
        history.start()
        precondition(provider.requests.count == 5 && history.errorMessage != nil)
        history.stop()
    }

    private static func makeHistory(_ databaseURL: URL) -> SQLiteChatHistoryService {
        SQLiteChatHistoryService(store: ChatHistoryStore(databaseURL: databaseURL, legacyURL: databaseURL.appendingPathExtension("missing")))
    }

    private static func makePeer(_ identifier: String, name: String) -> FeiQPeer {
        FeiQPeer(id: identifier, name: name, hostName: "host", ipAddress: "192.0.2.1", group: "", lastSeen: Date(), isOnline: false)
    }

    private static func attachment(_ identifier: String, kind: ChatAttachmentKind = .file, name: String = "附件.txt") -> ChatAttachment {
        ChatAttachment(id: identifier, kind: kind, fileName: name, fileSize: 10, modifiedAt: 0, fileAttributes: 1,
                       localPath: "", mimeType: kind == .image ? "image/png" : "text/plain")
    }

    private static func message(_ identifier: Int, date: Date, attachments: [ChatAttachment],
                                direction: ChatMessageDirection = .incoming) -> ChatMessage {
        ChatMessage(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", identifier))!, direction: direction,
                    text: "仅消息正文", senderName: "发送者", date: date, attachments: attachments)
    }

    private static func search(_ service: ChatHistoryService, query: ChatAttachmentHistoryQuery = .init(),
                               cursor: ChatAttachmentHistoryCursor? = nil, limit: Int = 200) async throws -> ChatAttachmentHistoryPage {
        try await receive { service.searchAttachments(matching: query, before: cursor, limit: limit, completion: $0) }
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
        preconditionFailure("Timed out waiting for download center state")
    }
}

@MainActor
private final class DownloadSearchProvider {
    struct Request {
        let cursor: ChatAttachmentHistoryCursor?
        let completion: (Result<ChatAttachmentHistoryPage, Error>) -> Void
    }
    var requests: [Request] = []
    func search(_ query: ChatAttachmentHistoryQuery, _ cursor: ChatAttachmentHistoryCursor?, _ limit: Int,
                completion: @escaping (Result<ChatAttachmentHistoryPage, Error>) -> Void) {
        precondition(limit == 60)
        requests.append(Request(cursor: cursor, completion: completion))
    }
}

private final class DownloadTestTransport: FeiQNetworkServiceProtocol {
    var onInlineImage: ((Data, String, Int, FeiQPacket, String) -> Void)?
    var onPacket: ((FeiQPacket, String, FeiQTransport, UInt16) -> Void)?
    var onLog: ((String) -> Void)?
    var onStateChange: ((Bool) -> Void)?
    func start(name: String, host: String, group: String) {}
    func stop() {}
    func updateIdentity(name: String, host: String, group: String) {}
    func announce() {}
    func replyToEntry(from ipAddress: String) {}
    func sendTyping(isTyping: Bool, to ipAddress: String) {}
    func sendShake(to ipAddress: String) {}
    func sendText(_ text: String, to ipAddress: String, recipientName: String?) {}
    func sendFileMessage(_ text: String, attachments: [ChatAttachment], to ipAddress: String, recipientName: String?) {}
    func acknowledge(_ packet: FeiQPacket, to ipAddress: String) {}
    func downloadFile(_ attachment: FeiQFileAttachment, packetNumber: UInt64, from ipAddress: String,
                      to destinationURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(FeiQFileTransferError.fileNotFound))
    }
}

private final class DownloadTestNotifications: NotificationService {
    var onNotificationSelected: ((String) -> Void)?
    func requestAuthorization() {}
    func notifyIncomingMessage(from sender: String, text: String, conversationID: String) {}
}

private final class DownloadTestSettings: AppSettingsRepository {
    func load() -> AppSettings {
        AppSettings(identity: FeiQIdentity(nickname: "测试", hostName: "test", groupName: ""), chatLoadAnimationMode: .instant)
    }
    func save(_ settings: AppSettings) {}
}
