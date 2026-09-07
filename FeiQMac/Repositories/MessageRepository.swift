//
//  MessageRepository.swift
//  FeiQMac
//
//  消息历史的业务仓储：封装 SQLite 历史服务，统一处理消息保存、分页读取、删除和未读数。
//

import Foundation

protocol MessageRepository: AnyObject {
    var locationDescription: String { get }

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
