//
//  MessageRepository.swift
//  FeiQMac
//
//  消息历史的业务仓储：封装 SQLite 历史服务，统一处理消息保存、分页读取、删除和未读数。
//

import Foundation

protocol MessageRepository: DatabaseMaintenanceAccess {
    var locationDescription: String { get }

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
    func removeImage(
        attachmentID: String,
        messageID: UUID,
        conversationID: String,
        deleteUnreferencedFile: @escaping (ChatAttachment) throws -> Void,
        completion: @escaping (Result<ChatMessage, Error>) -> Void
    )
    func deleteMessage(
        id: UUID,
        conversationID: String,
        completion: @escaping (Result<[ChatAttachment], Error>) -> Void
    )
    func setUnreadCount(_ count: Int, for conversationID: String)

    func loadSnapshot(
        completion: @escaping (Result<ChatHistorySnapshot, Error>) -> Void
    )
    func loadRecentMessages(
        for conversationID: String,
        limit: Int,
        completion: @escaping (Result<ChatHistoryPage, Error>) -> Void
    )
    func loadEarlierMessages(
        for conversationID: String,
        before message: ChatMessage,
        limit: Int,
        completion: @escaping (Result<ChatHistoryPage, Error>) -> Void
    )
    func loadReceivedFiles(
        for conversationID: String,
        limit: Int,
        completion: @escaping (Result<[ChatReceivedFile], Error>) -> Void
    )
}

final class DefaultMessageRepository: MessageRepository {
    private let historyService: ChatHistoryService

    var locationDescription: String {
        historyService.locationDescription
    }

    init(historyService: ChatHistoryService) {
        self.historyService = historyService
    }

    var maintenanceRequiresRestart: Bool { historyService.maintenanceRequiresRestart }

    func withMaintenanceDatabase<Value>(requiresRestart: Bool,
        operation: @escaping (OpaquePointer, URL) throws -> Value,
        completion: @escaping (Result<Value, Error>) -> Void
    ) {
        historyService.withMaintenanceDatabase(requiresRestart: requiresRestart, operation: operation, completion: completion)
    }

    func loadArchive(
        matching query: ChatHistorySearchQuery,
        completion: @escaping (Result<ChatHistoryArchive, Error>) -> Void
    ) {
        historyService.loadArchive(matching: query, completion: completion)
    }

    func importArchive(
        _ archive: ChatHistoryArchive,
        completion: @escaping (Result<ChatHistoryImportSummary, Error>) -> Void
    ) {
        historyService.importArchive(archive, completion: completion)
    }

    func searchAttachments(
        matching query: ChatAttachmentHistoryQuery,
        before cursor: ChatAttachmentHistoryCursor?,
        limit: Int,
        completion: @escaping (Result<ChatAttachmentHistoryPage, Error>) -> Void
    ) {
        historyService.searchAttachments(matching: query, before: cursor, limit: limit, completion: completion)
    }

    func searchMessages(
        matching query: ChatHistorySearchQuery,
        before cursor: ChatHistorySearchCursor?,
        limit: Int,
        completion: @escaping (Result<ChatHistorySearchPage, Error>) -> Void
    ) {
        historyService.searchMessages(matching: query, before: cursor, limit: limit, completion: completion)
    }

    func loadMessageContext(
        for conversationID: String,
        messageID: UUID,
        limit: Int,
        completion: @escaping (Result<ChatHistoryContext, Error>) -> Void
    ) {
        historyService.loadMessageContext(for: conversationID, messageID: messageID, limit: limit, completion: completion)
    }

    func loadLaterMessages(
        for conversationID: String,
        after message: ChatMessage,
        limit: Int,
        completion: @escaping (Result<ChatHistoryPage, Error>) -> Void
    ) {
        historyService.loadLaterMessages(for: conversationID, after: message, limit: limit, completion: completion)
    }

    func saveMessage(
        _ message: ChatMessage,
        for peer: FeiQPeer,
        unreadCount: Int
    ) {
        historyService.saveMessage(message, for: peer, unreadCount: unreadCount)
    }

    func saveMessage(
        _ message: ChatMessage,
        for group: ChatGroup,
        unreadCount: Int
    ) {
        historyService.saveMessage(message, for: group, unreadCount: unreadCount)
    }

    func removeImage(
        attachmentID: String,
        messageID: UUID,
        conversationID: String,
        deleteUnreferencedFile: @escaping (ChatAttachment) throws -> Void,
        completion: @escaping (Result<ChatMessage, Error>) -> Void
    ) {
        historyService.removeImage(
            attachmentID: attachmentID,
            messageID: messageID,
            conversationID: conversationID,
            deleteUnreferencedFile: deleteUnreferencedFile,
            completion: completion
        )
    }

    func deleteMessage(
        id: UUID,
        conversationID: String,
        completion: @escaping (Result<[ChatAttachment], Error>) -> Void
    ) {
        historyService.deleteMessage(
            id: id,
            conversationID: conversationID,
            completion: completion
        )
    }

    func setUnreadCount(_ count: Int, for conversationID: String) {
        historyService.setUnreadCount(count, for: conversationID)
    }

    func loadSnapshot(
        completion: @escaping (Result<ChatHistorySnapshot, Error>) -> Void
    ) {
        historyService.loadSnapshot(completion: completion)
    }

    func loadRecentMessages(
        for conversationID: String,
        limit: Int,
        completion: @escaping (Result<ChatHistoryPage, Error>) -> Void
    ) {
        historyService.loadRecentMessages(
            for: conversationID,
            limit: limit,
            completion: completion
        )
    }

    func loadEarlierMessages(
        for conversationID: String,
        before message: ChatMessage,
        limit: Int,
        completion: @escaping (Result<ChatHistoryPage, Error>) -> Void
    ) {
        historyService.loadEarlierMessages(
            for: conversationID,
            before: message,
            limit: limit,
            completion: completion
        )
    }

    func loadConversationImages(
        for conversationID: String,
        completion: @escaping (Result<[ChatHistoryImage], Error>) -> Void
    ) {
        historyService.loadConversationImages(for: conversationID, completion: completion)
    }

    func loadReceivedFiles(
        for conversationID: String,
        limit: Int,
        completion: @escaping (Result<[ChatReceivedFile], Error>) -> Void
    ) {
        historyService.loadReceivedFiles(
            for: conversationID,
            limit: limit,
            completion: completion
        )
    }
}
