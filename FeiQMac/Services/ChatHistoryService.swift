import Foundation

protocol ChatHistoryService: DatabaseMaintenanceAccess {
    var locationDescription: String { get }

    func loadConversationSettings() throws -> [String: ConversationSettings]
    func saveConversationSettings(_ settings: ConversationSettings, for conversationID: String,
                                  completion: @escaping (Result<Void, Error>) -> Void)

    func loadArchive(
        matching query: ChatHistorySearchQuery,
        completion: @escaping (Result<ChatHistoryArchive, Error>) -> Void
    )
    func importArchive(
        _ archive: ChatHistoryArchive,
        completion: @escaping (Result<ChatHistoryImportSummary, Error>) -> Void
    )

    func searchAttachments(
        matching query: ChatAttachmentHistoryQuery,
        before cursor: ChatAttachmentHistoryCursor?,
        limit: Int,
        completion: @escaping (Result<ChatAttachmentHistoryPage, Error>) -> Void
    )
    func searchMessages(
        matching query: ChatHistorySearchQuery,
        before cursor: ChatHistorySearchCursor?,
        limit: Int,
        completion: @escaping (Result<ChatHistorySearchPage, Error>) -> Void
    )
    func loadMessageContext(
        for conversationID: String,
        messageID: UUID,
        limit: Int,
        completion: @escaping (Result<ChatHistoryContext, Error>) -> Void
    )
    func loadLaterMessages(
        for conversationID: String,
        after message: ChatMessage,
        limit: Int,
        completion: @escaping (Result<ChatHistoryPage, Error>) -> Void
    )

    func loadConversationImages(
        for conversationID: String,
        completion: @escaping (Result<[ChatHistoryImage], Error>) -> Void
    )

    func loadSnapshot(
        completion: @escaping (Result<ChatHistorySnapshot, Error>) -> Void
    )
    func loadRecentMessages(
        for peerID: String,
        limit: Int,
        completion: @escaping (Result<ChatHistoryPage, Error>) -> Void
    )
    func loadEarlierMessages(
        for peerID: String,
        before message: ChatMessage,
        limit: Int,
        completion: @escaping (Result<ChatHistoryPage, Error>) -> Void
    )
    func loadReceivedFiles(
        for peerID: String,
        limit: Int,
        completion: @escaping (Result<[ChatReceivedFile], Error>) -> Void
    )
    func savePeer(_ peer: FeiQPeer)
    func saveGroup(_ group: ChatGroup)
    func deleteGroup(_ groupID: String)
    func removeImage(
        attachmentID: String, messageID: UUID, conversationID: String,
        deleteUnreferencedFile: @escaping (ChatAttachment) throws -> Void,
        completion: @escaping (Result<ChatMessage, Error>) -> Void
    )
    func deleteMessage(
        id: UUID,
        conversationID: String,
        completion: @escaping (Result<[ChatAttachment], Error>) -> Void
    )
    func saveMessage(
        _ message: ChatMessage,
        for peer: FeiQPeer,
        unreadCount: Int
    )
    func saveMessage(
        _ message: ChatMessage,
        for group: ChatGroup,
        unreadCount: Int
    )
    func setUnreadCount(_ count: Int, for peerID: String)
}

final class SQLiteChatHistoryService: ChatHistoryService {
    private let store: ChatHistoryStore

    var locationDescription: String {
        store.locationDescription
    }

    init(store: ChatHistoryStore) {
        self.store = store
    }

    var maintenanceRequiresRestart: Bool { store.maintenanceRequiresRestart }

    func withMaintenanceDatabase<Value>(requiresRestart: Bool,
        operation: @escaping (OpaquePointer, URL) throws -> Value,
        completion: @escaping (Result<Value, Error>) -> Void
    ) {
        store.withMaintenanceDatabase(requiresRestart: requiresRestart, operation: operation, completion: completion)
    }

    func loadConversationSettings() throws -> [String: ConversationSettings] {
        try store.loadConversationSettings()
    }

    func saveConversationSettings(_ settings: ConversationSettings, for conversationID: String,
                                  completion: @escaping (Result<Void, Error>) -> Void) {
        store.saveConversationSettings(settings, for: conversationID, completion: completion)
    }

    func loadArchive(
        matching query: ChatHistorySearchQuery,
        completion: @escaping (Result<ChatHistoryArchive, Error>) -> Void
    ) {
        store.loadArchive(matching: query, completion: completion)
    }

    func importArchive(
        _ archive: ChatHistoryArchive,
        completion: @escaping (Result<ChatHistoryImportSummary, Error>) -> Void
    ) {
        store.importArchive(archive, completion: completion)
    }

    static func makeDefault() -> SQLiteChatHistoryService {
        let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let directoryURL = documentsURL.appendingPathComponent(
            "飞秋 Mac",
            isDirectory: true
        )
        let databaseURL = directoryURL.appendingPathComponent(
            "ChatHistory.sqlite",
            isDirectory: false
        )
        let legacyURL = directoryURL.appendingPathComponent(
            "ChatHistory.json",
            isDirectory: false
        )

        return SQLiteChatHistoryService(
            store: ChatHistoryStore(
                databaseURL: databaseURL,
                legacyURL: legacyURL
            )
        )
    }

    func loadSnapshot(
        completion: @escaping (Result<ChatHistorySnapshot, Error>) -> Void
    ) {
        store.loadSnapshot(completion: completion)
    }

    func loadRecentMessages(
        for peerID: String,
        limit: Int,
        completion: @escaping (Result<ChatHistoryPage, Error>) -> Void
    ) {
        store.loadRecentMessages(
            for: peerID,
            limit: limit,
            completion: completion
        )
    }

    func loadEarlierMessages(
        for peerID: String,
        before message: ChatMessage,
        limit: Int,
        completion: @escaping (Result<ChatHistoryPage, Error>) -> Void
    ) {
        store.loadEarlierMessages(
            for: peerID,
            before: message,
            limit: limit,
            completion: completion
        )
    }

    func loadConversationImages(
        for conversationID: String,
        completion: @escaping (Result<[ChatHistoryImage], Error>) -> Void
    ) {
        store.loadConversationImages(for: conversationID, completion: completion)
    }

    func loadReceivedFiles(
        for peerID: String,
        limit: Int,
        completion: @escaping (Result<[ChatReceivedFile], Error>) -> Void
    ) {
        store.loadReceivedFiles(
            for: peerID,
            limit: limit,
            completion: completion
        )
    }

    func searchAttachments(
        matching query: ChatAttachmentHistoryQuery,
        before cursor: ChatAttachmentHistoryCursor?,
        limit: Int,
        completion: @escaping (Result<ChatAttachmentHistoryPage, Error>) -> Void
    ) {
        store.searchAttachments(matching: query, before: cursor, limit: limit, completion: completion)
    }

    func searchMessages(
        matching query: ChatHistorySearchQuery,
        before cursor: ChatHistorySearchCursor?,
        limit: Int,
        completion: @escaping (Result<ChatHistorySearchPage, Error>) -> Void
    ) {
        store.searchMessages(matching: query, before: cursor, limit: limit, completion: completion)
    }

    func loadMessageContext(
        for conversationID: String,
        messageID: UUID,
        limit: Int,
        completion: @escaping (Result<ChatHistoryContext, Error>) -> Void
    ) {
        store.loadMessageContext(for: conversationID, messageID: messageID, limit: limit, completion: completion)
    }

    func loadLaterMessages(
        for conversationID: String,
        after message: ChatMessage,
        limit: Int,
        completion: @escaping (Result<ChatHistoryPage, Error>) -> Void
    ) {
        store.loadLaterMessages(for: conversationID, after: message, limit: limit, completion: completion)
    }

    func savePeer(_ peer: FeiQPeer) {
        store.savePeer(peer)
    }

    func saveGroup(_ group: ChatGroup) {
        store.saveGroup(group)
    }

    func deleteGroup(_ groupID: String) {
        store.deleteGroup(groupID)
    }

    func removeImage(
        attachmentID: String, messageID: UUID, conversationID: String,
        deleteUnreferencedFile: @escaping (ChatAttachment) throws -> Void,
        completion: @escaping (Result<ChatMessage, Error>) -> Void
    ) {
        store.removeImage(
            attachmentID: attachmentID, messageID: messageID, conversationID: conversationID,
            deleteUnreferencedFile: deleteUnreferencedFile, completion: completion
        )
    }

    func deleteMessage(
        id: UUID,
        conversationID: String,
        completion: @escaping (Result<[ChatAttachment], Error>) -> Void
    ) {
        store.deleteMessage(
            id: id,
            conversationID: conversationID,
            completion: completion
        )
    }

    func saveMessage(
        _ message: ChatMessage,
        for peer: FeiQPeer,
        unreadCount: Int
    ) {
        store.saveMessage(
            message,
            for: peer,
            unreadCount: unreadCount
        )
    }

    func saveMessage(
        _ message: ChatMessage,
        for group: ChatGroup,
        unreadCount: Int
    ) {
        store.saveMessage(
            message,
            for: group,
            unreadCount: unreadCount
        )
    }

    func setUnreadCount(_ count: Int, for peerID: String) {
        store.setUnreadCount(count, for: peerID)
    }
}
