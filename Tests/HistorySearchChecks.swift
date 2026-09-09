import AppKit
import Foundation
import SQLite3

@main
struct HistorySearchChecks {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feiq-history-search-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try checkDateBounds()
        try await checkFilters(root: root)
        try await checkArchiveAndNavigation(root: root)
        try await checkLegacyMigration(root: root)
        try await checkSearchState()
        print("History search checks passed")
    }

    private static func checkDateBounds() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        for (month, day, hours) in [(3, 8, 23), (11, 1, 25)] {
            let date = calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
            let bounds = try ChatHistorySearchQuery(startDate: date, endDate: date).dateBounds(calendar: calendar)
            precondition(bounds.end!.timeIntervalSince(bounds.start!) == Double(hours * 3600))
        }
        let date = Date()
        do {
            _ = try ChatHistorySearchQuery(startDate: date.addingTimeInterval(172800), endDate: date).dateBounds()
            preconditionFailure("Reversed dates must fail validation")
        } catch ChatHistorySearchError.invalidDateRange {}
    }

    private static func checkFilters(root: URL) async throws {
        let databaseURL = root.appendingPathComponent("filters.sqlite")
        let service = makeService(databaseURL: databaseURL)
        let peer = makePeer("peer-a'1", name: "甲")
        let otherPeer = makePeer("peer-b", name: "乙")
        let group = ChatGroup(name: "项目群", memberIDs: [peer.id], ownerName: "我")
        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        let image = attachment("image-a", kind: .image, name: "设计稿.PNG")
        let file = attachment("file-a", kind: .file, name: "季度报告.PDF")
        let fixtures = [
            message(1, text: "项目计划", date: day),
            message(2, text: "Hello HELLO 100%_路径\\O'Brien", date: day.addingTimeInterval(100), direction: .outgoing),
            message(3, text: "", date: nextDay.addingTimeInterval(-0.001), attachments: [image]),
            message(4, text: "", date: day.addingTimeInterval(200), attachments: [file]),
            message(5, text: "跨天消息", date: nextDay, attachments: [attachment("file-png", kind: .file, name: "照片.png")]),
            message(6, text: "前一天", date: day.addingTimeInterval(-1)),
            message(7, text: "项目计划他人", date: day, attachments: [image]),
            message(8, text: "项目计划群聊", date: day, attachments: [image, attachment("image-b", kind: .image, name: "照片.jpg"), file]),
            message(9, text: " \n\t", date: day),
            message(10, text: "损坏附件记录", date: day)
        ]
        for fixture in fixtures where fixture.id != fixtures[6].id && fixture.id != fixtures[7].id {
            service.saveMessage(fixture, for: peer, unreadCount: 0)
        }
        service.saveMessage(fixtures[6], for: otherPeer, unreadCount: 0)
        service.saveMessage(fixtures[7], for: group, unreadCount: 0)
        let initial = try await search(service)
        precondition(initial.results.count == fixtures.count && !initial.hasMore)
        try executeSQL("UPDATE messages SET attachments_json = '{broken' WHERE id = '\(fixtures[9].id.uuidString)'", at: databaseURL)

        try await expect(service, query: .init(text: "项目"), ids: [1, 7, 8])
        try await expect(service, query: .init(conversationID: peer.id, text: "项目"), ids: [1])
        try await expect(service, query: .init(conversationID: otherPeer.id), ids: [7])
        try await expect(service, query: .init(conversationID: "missing"), ids: [])
        try await expect(service, query: .init(kind: .text), ids: [1, 2, 5, 6, 7, 8, 10])
        try await expect(service, query: .init(kind: .image), ids: [3, 7, 8])
        try await expect(service, query: .init(kind: .file), ids: [4, 5, 8])
        try await expect(service, query: .init(text: "设计稿", kind: .image), ids: [3, 7, 8])
        try await expect(service, query: .init(text: "设计稿", kind: .file), ids: [])
        try await expect(service, query: .init(text: "季度报告", kind: .image), ids: [])
        try await expect(service, query: .init(text: "季度报告", kind: .text), ids: [])
        try await expect(service, query: .init(text: "pdf", kind: .file), ids: [4, 8])
        for keyword in ["hello", "%", "_", "\\", "O'Brien", "  HELLO\n"] {
            try await expect(service, query: .init(text: keyword), ids: [2])
        }
        for keyword in ["image", "metadata-only", "仅发送者", "' OR 1=1 --"] {
            try await expect(service, query: .init(text: keyword), ids: [])
        }
        try await expect(service, query: .init(text: " \n\t"), ids: Array(1...10))
        try await expect(service, query: .init(startDate: day, endDate: day), ids: [1, 2, 3, 4, 7, 8, 9, 10])
        try await expect(service, query: .init(conversationID: peer.id, kind: .image, startDate: day, endDate: day), ids: [3])
        try await expect(service, query: .init(startDate: day.addingTimeInterval(3600), endDate: day.addingTimeInterval(7200)), ids: [1, 2, 3, 4, 7, 8, 9, 10])
        try await expect(service, query: .init(startDate: nextDay), ids: [5])
        try await expect(service, query: .init(endDate: day.addingTimeInterval(-1)), ids: [6])
        do {
            _ = try await search(service, query: .init(startDate: nextDay, endDate: day))
            preconditionFailure("The store must reject reversed dates")
        } catch ChatHistorySearchError.invalidDateRange {}

        let groupPage = try await search(service, query: .init(conversationID: group.id))
        precondition(groupPage.results.count == 1 && groupPage.results[0].isGroup)
        precondition(groupPage.results[0].conversationName == group.displayName)
        let reopened = makeService(databaseURL: databaseURL)
        try await expect(reopened, query: .init(kind: .image), ids: [3, 7, 8])
        try executeSQL("UPDATE messages SET attachments_json = '[]' WHERE id = '\(fixtures[9].id.uuidString)'", at: databaseURL)

        let _: ChatMessage = try await receive {
            service.removeImage(attachmentID: image.id, messageID: fixtures[2].id, conversationID: peer.id,
                                deleteUnreferencedFile: { _ in }, completion: $0)
        }
        try await expect(service, query: .init(kind: .image), ids: [7, 8])
        let _: [ChatAttachment] = try await receive {
            service.deleteMessage(id: fixtures[3].id, conversationID: peer.id, completion: $0)
        }
        try await expect(service, query: .init(kind: .file), ids: [5, 8])
        do {
            let _: ChatHistoryContext = try await receive {
                service.loadMessageContext(for: peer.id, messageID: fixtures[3].id, limit: 60, completion: $0)
            }
            preconditionFailure("Deleted results must not open stale message context")
        } catch ChatHistorySearchError.messageUnavailable {}
        service.deleteGroup(group.id)
        try await expect(service, query: .init(conversationID: group.id), ids: [])
    }

    @MainActor
    private static func checkArchiveAndNavigation(root: URL) async throws {
        let service = makeService(databaseURL: root.appendingPathComponent("archive.sqlite"))
        let peer = makePeer("archive", name: "归档联系人")
        let otherPeer = makePeer("other-archive", name: "")
        let group = ChatGroup(name: "归档群", memberIDs: [peer.id], ownerName: "我")
        let messages: [ChatMessage] = (0..<305).map { index in
            let text = index == 0 ? "归档深处关键词" : "归档-\(index)"
            let timestamp = 1000.0 + Double(index / 2)
            return message(1000 + index, text: text, date: Date(timeIntervalSince1970: timestamp))
        }
        for stored in messages.reversed() { service.saveMessage(stored, for: peer, unreadCount: 0) }
        let foreign = message(2000, text: "归档外部", date: messages[100].date)
        service.saveMessage(foreign, for: otherPeer, unreadCount: 0)
        let groupMessage = message(2001, text: "归档群消息", date: messages[100].date)
        service.saveMessage(groupMessage, for: group, unreadCount: 0)

        var allResults: [ChatHistorySearchResult] = []
        var cursor: ChatHistorySearchCursor?
        repeat {
            let page = try await search(service, query: .init(text: "归档"), cursor: cursor, limit: 17)
            precondition(page.results.count <= 17 && page.results.last?.cursor != cursor)
            allResults += page.results
            cursor = page.hasMore ? page.results.last?.cursor : nil
        } while cursor != nil
        let expected: [ChatMessage] = (messages + [foreign, groupMessage]).sorted { first, second in
            if first.date != second.date { return first.date > second.date }
            return first.id.uuidString > second.id.uuidString
        }
        precondition(allResults.map(\.id) == expected.map(\.id), "Keyset pagination must not skip or repeat tied timestamps")
        precondition(allResults.first { $0.id == foreign.id }?.conversationName == "test-host")
        let recent: ChatHistoryPage = try await receive { service.loadRecentMessages(for: peer.id, limit: 60, completion: $0) }
        precondition(!recent.messages.contains { $0.id == messages[0].id })
        let oldest = try await search(service, query: .init(conversationID: peer.id, text: "深处关键词"))
        precondition(oldest.results.map(\.id) == [messages[0].id])
        let capped = try await search(service, query: .init(conversationID: peer.id), limit: Int.max)
        precondition(capped.results.count == 200 && capped.hasMore)

        let middle = allResults.first { $0.id == messages[150].id }!
        let context: ChatHistoryContext = try await receive {
            service.loadMessageContext(for: peer.id, messageID: middle.id, limit: 60, completion: $0)
        }
        precondition(context.messages.map(\.id) == Array(messages[120...180]).map(\.id))
        precondition(context.hasEarlier && context.hasLater)
        let earlier: ChatHistoryPage = try await receive {
            service.loadEarlierMessages(for: peer.id, before: context.messages.first!, limit: 60, completion: $0)
        }
        let later: ChatHistoryPage = try await receive {
            service.loadLaterMessages(for: peer.id, after: context.messages.last!, limit: 60, completion: $0)
        }
        precondition(earlier.messages.map(\.id) == Array(messages[60..<120]).map(\.id))
        precondition(later.messages.map(\.id) == Array(messages[181...240]).map(\.id))
        for (target, hasEarlier, hasLater) in [(messages.first!, false, true), (messages.last!, true, false)] {
            let edge: ChatHistoryContext = try await receive {
                service.loadMessageContext(for: peer.id, messageID: target.id, limit: 60, completion: $0)
            }
            precondition(edge.hasEarlier == hasEarlier && edge.hasLater == hasLater)
        }
        do {
            let _: ChatHistoryContext = try await receive {
                service.loadMessageContext(for: otherPeer.id, messageID: middle.id, limit: 60, completion: $0)
            }
            preconditionFailure("Context lookup must stay within the requested conversation")
        } catch ChatHistorySearchError.messageUnavailable {}

        _ = NSApplication.shared
        let repository = DefaultChatRepository(
            networkService: HistoryTestTransport(), historyService: service,
            attachmentStorageService: LocalChatAttachmentStorageService(rootURL: root),
            notificationService: HistoryTestNotifications()
        )
        let model = ChatViewModel(repository: repository, settingsRepository: HistoryTestSettings())
        try await waitUntil { model.peers.count == 2 && model.groups.count == 1 }
        model.selectPeer(peer.id)
        try await waitUntil { !model.isLoadingMessages && model.messages(for: peer.id).count == 60 }
        model.openHistorySearch(for: peer.id)
        precondition(model.historySearch?.query.conversationID == peer.id)
        model.revealHistoryMessage(middle)
        try await waitUntil { !model.isLocatingHistoryMessage && model.isBrowsingHistory }
        precondition(model.highlightedMessageID == middle.id && model.historySearch == nil)
        precondition(model.messages(for: peer.id).map(\.id) == context.messages.map(\.id))
        let live = message(3000, text: "浏览历史时到达", date: Date())
        repository.onEvent?(.messageReceived(message: live, peer: peer))
        try await waitUntil { model.unreadCount(for: peer.id) == 1 }
        precondition(!model.messages(for: peer.id).contains { $0.id == live.id }, "Live arrivals must not create a gap in historical context")
        while model.hasLaterMessages {
            model.loadLaterMessages(for: peer.id, after: model.messages(for: peer.id).last!)
            try await waitUntil { !model.isLoadingMessages }
        }
        precondition(model.messages(for: peer.id).last?.id == live.id)
        model.returnToLatestMessages()
        try await waitUntil { !model.isLoadingMessages }
        precondition(!model.isBrowsingHistory && model.highlightedMessageID == nil)
        precondition(model.messages(for: peer.id).count == 60 && model.messages(for: peer.id).last?.id == live.id)
        precondition(model.unreadCount(for: peer.id) == 0)

        model.openHistorySearch()
        model.revealHistoryMessage(middle)
        model.cancelHistoryNavigation()
        model.historySearch = nil
        try await Task.sleep(for: .milliseconds(40))
        precondition(!model.isBrowsingHistory, "Closing search must cancel pending navigation")
        model.openHistorySearch()
        model.revealHistoryMessage(allResults.first { $0.id == groupMessage.id }!)
        try await waitUntil { !model.isLocatingHistoryMessage }
        precondition(model.selectedGroupID == group.id && model.highlightedMessageID == groupMessage.id)
        model.selectPeer(otherPeer.id)
        try await waitUntil { !model.isLoadingMessages }
        precondition(!model.isBrowsingHistory && model.messages(for: otherPeer.id).map(\.id) == [foreign.id])
    }

    private static func checkLegacyMigration(root: URL) async throws {
        struct Archive: Encodable {
            let version = 1
            let peers: [FeiQPeer]
            let messagesByPeer: [String: [ChatMessage]]
        }
        let peer = makePeer("legacy", name: "旧联系人")
        let stored = message(4000, text: "迁移关键词", date: Date())
        let legacyURL = root.appendingPathComponent("legacy.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Archive(peers: [peer], messagesByPeer: [peer.id: [stored]])).write(to: legacyURL)
        let service = SQLiteChatHistoryService(store: ChatHistoryStore(
            databaseURL: root.appendingPathComponent("legacy.sqlite"), legacyURL: legacyURL
        ))
        let page = try await search(service, query: .init(text: "迁移关键词"))
        precondition(page.results.map(\.id) == [stored.id])
    }

    @MainActor
    private static func checkSearchState() async throws {
        let provider = ControlledHistorySearch()
        let model = HistorySearchViewModel(search: provider.search)
        let first = ChatHistorySearchResult(conversationID: "a", conversationName: "甲", isGroup: false,
                                            message: message(5000, text: "新查询", date: Date()))
        let second = ChatHistorySearchResult(conversationID: "b", conversationName: "乙", isGroup: false,
                                             message: message(5001, text: "后续结果", date: Date().addingTimeInterval(-1)))
        model.searchNow()
        model.query.text = "新查询"
        model.searchNow()
        precondition(provider.requests.count == 2)
        provider.requests[1].completion(.success(.init(results: [first], hasMore: true)))
        provider.requests[0].completion(.failure(ChatHistorySearchError.messageUnavailable))
        try await waitUntil { !model.isSearching }
        precondition(model.results.map(\.id) == [first.id] && model.errorMessage == nil)
        model.loadMore()
        model.loadMore()
        precondition(provider.requests.count == 3 && provider.requests[2].cursor == first.cursor)
        provider.requests[2].completion(.failure(ChatHistorySearchError.messageUnavailable))
        try await waitUntil { !model.isSearching }
        precondition(model.results.count == 1 && model.hasMore && model.errorMessage != nil)
        model.retry()
        precondition(provider.requests[3].cursor == first.cursor)
        provider.requests[3].completion(.success(.init(results: [first, second], hasMore: false)))
        try await waitUntil { !model.isSearching }
        precondition(model.results.map(\.id) == [first.id, second.id] && !model.hasMore)

        model.query.text = "一"
        model.query.text = "二"
        model.query.text = "三"
        precondition(provider.requests.count == 4 && model.results.isEmpty)
        try await waitUntil { provider.requests.count == 5 }
        precondition(provider.requests[4].query.text == "三" && provider.requests[4].cursor == nil)
        model.query.kind = .image
        model.searchNow()
        provider.requests[4].completion(.success(.init(results: [second], hasMore: false)))
        provider.requests[5].completion(.success(.init(results: [], hasMore: false)))
        try await waitUntil { !model.isSearching }
        precondition(model.results.isEmpty && model.query.kind == .image)

        model.searchNow()
        model.cancel()
        provider.requests[6].completion(.success(.init(results: [first], hasMore: false)))
        try await Task.sleep(for: .milliseconds(30))
        precondition(model.results.isEmpty && !model.isSearching)
        model.query.startDate = Date().addingTimeInterval(172800)
        model.query.endDate = Date()
        model.searchNow()
        precondition(provider.requests.count == 7 && model.errorMessage != nil && !model.isSearching)
        model.cancel()
    }

    private static func makeService(databaseURL: URL) -> SQLiteChatHistoryService {
        SQLiteChatHistoryService(store: ChatHistoryStore(
            databaseURL: databaseURL, legacyURL: databaseURL.appendingPathExtension("missing.json")
        ))
    }

    private static func makePeer(_ identifier: String, name: String) -> FeiQPeer {
        FeiQPeer(id: identifier, name: name, hostName: "test-host", ipAddress: "192.0.2.1", group: "", lastSeen: Date(), isOnline: false)
    }

    private static func message(_ identifier: Int, text: String, date: Date,
                                attachments: [ChatAttachment] = [], direction: ChatMessageDirection = .incoming) -> ChatMessage {
        ChatMessage(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", identifier))!,
                    direction: direction, text: text, senderName: "仅发送者", date: date, attachments: attachments)
    }

    private static func attachment(_ identifier: String, kind: ChatAttachmentKind, name: String) -> ChatAttachment {
        ChatAttachment(id: identifier, kind: kind, fileName: name, fileSize: 100, modifiedAt: 0, fileAttributes: 1,
                       localPath: "/missing/metadata-only/\(identifier)", mimeType: kind == .image ? "image/png" : "application/pdf")
    }

    private static func search(_ service: ChatHistoryService, query: ChatHistorySearchQuery = .init(),
                               cursor: ChatHistorySearchCursor? = nil, limit: Int = 200) async throws -> ChatHistorySearchPage {
        try await receive { service.searchMessages(matching: query, before: cursor, limit: limit, completion: $0) }
    }

    private static func expect(_ service: ChatHistoryService, query: ChatHistorySearchQuery, ids: [Int]) async throws {
        let page = try await search(service, query: query)
        let expected = Set(ids.map { message($0, text: "", date: Date()).id })
        precondition(Set(page.results.map(\.id)) == expected, "Unexpected matches for \(query)")
        precondition(page.results.count == expected.count, "Multiple matching attachments must not duplicate a message")
    }

    private static func receive<Value>(_ operation: (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in operation { continuation.resume(with: $0) } }
    }

    @MainActor
    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out waiting for asynchronous history state")
    }

    private static func executeSQL(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        precondition(sqlite3_open(url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        precondition(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
    }
}

@MainActor
private final class ControlledHistorySearch {
    struct Request {
        let query: ChatHistorySearchQuery
        let cursor: ChatHistorySearchCursor?
        let completion: (Result<ChatHistorySearchPage, Error>) -> Void
    }
    var requests: [Request] = []

    func search(_ query: ChatHistorySearchQuery, _ cursor: ChatHistorySearchCursor?, _ limit: Int,
                completion: @escaping (Result<ChatHistorySearchPage, Error>) -> Void) {
        precondition(limit == 60)
        requests.append(Request(query: query, cursor: cursor, completion: completion))
    }
}

private final class HistoryTestTransport: FeiQNetworkServiceProtocol {
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

private final class HistoryTestNotifications: NotificationService {
    var onNotificationSelected: ((String) -> Void)?
    func requestAuthorization() {}
    func notifyIncomingMessage(from sender: String, text: String, conversationID: String) {}
}

private final class HistoryTestSettings: AppSettingsRepository {
    func load() -> AppSettings {
        AppSettings(identity: FeiQIdentity(nickname: "测试", hostName: "test", groupName: ""), chatLoadAnimationMode: .instant)
    }
    func save(_ settings: AppSettings) {}
}
