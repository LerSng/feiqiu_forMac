import Foundation

struct ChatAttachmentHistoryQuery: Equatable, Sendable {
    var conversationID: String?
    var text = ""
    var direction: ChatMessageDirection? = .incoming
    var kind: ChatAttachmentKind?
    var startDate: Date?
    var endDate: Date?

    var keyword: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    func dateBounds(calendar: Calendar = .current) throws -> (start: Date?, end: Date?) {
        try ChatHistorySearchQuery(startDate: startDate, endDate: endDate).dateBounds(calendar: calendar)
    }
}

struct ChatAttachmentHistoryCursor: Equatable, Sendable {
    let date: Date
    let messageID: UUID
    let attachmentIndex: Int
}

struct ChatAttachmentHistoryResult: Identifiable, Hashable, Sendable {
    let conversationID: String
    let conversationName: String
    let isGroup: Bool
    let messageID: UUID
    let attachment: ChatAttachment
    let attachmentIndex: Int
    let date: Date
    let senderName: String
    let direction: ChatMessageDirection

    var id: String { "\(messageID.uuidString):\(attachmentIndex)" }

    var cursor: ChatAttachmentHistoryCursor {
        ChatAttachmentHistoryCursor(date: date, messageID: messageID, attachmentIndex: attachmentIndex)
    }
}

struct ChatAttachmentHistoryPage: Sendable {
    let results: [ChatAttachmentHistoryResult]
    let hasMore: Bool
    let nextCursor: ChatAttachmentHistoryCursor?
}
