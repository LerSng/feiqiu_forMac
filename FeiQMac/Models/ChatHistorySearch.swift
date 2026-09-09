import Foundation

enum ChatHistoryMessageKind: String, CaseIterable, Identifiable, Sendable {
    case all
    case text
    case image
    case file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .text: return "文本"
        case .image: return "图片"
        case .file: return "文件"
        }
    }

    var attachmentKind: ChatAttachmentKind? {
        switch self {
        case .all, .text: return nil
        case .image: return .image
        case .file: return .file
        }
    }
}

struct ChatHistorySearchQuery: Equatable, Sendable {
    var conversationID: String?
    var text = ""
    var kind: ChatHistoryMessageKind = .all
    var startDate: Date?
    var endDate: Date?

    var keyword: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func dateBounds(calendar: Calendar = .current) throws -> (start: Date?, end: Date?) {
        let start = startDate.map { calendar.startOfDay(for: $0) }
        let lastDay = endDate.map { calendar.startOfDay(for: $0) }
        if let start, let lastDay, start > lastDay {
            throw ChatHistorySearchError.invalidDateRange
        }
        let end = lastDay.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
        return (start, end)
    }
}

struct ChatHistorySearchCursor: Equatable, Sendable {
    let date: Date
    let messageID: UUID
}

struct ChatHistorySearchResult: Identifiable, Hashable, Sendable {
    let conversationID: String
    let conversationName: String
    let isGroup: Bool
    let message: ChatMessage

    var id: UUID { message.id }

    var cursor: ChatHistorySearchCursor {
        ChatHistorySearchCursor(date: message.date, messageID: message.id)
    }
}

struct ChatHistorySearchPage: Sendable {
    let results: [ChatHistorySearchResult]
    let hasMore: Bool
}

struct ChatHistoryContext: Sendable {
    let messages: [ChatMessage]
    let hasEarlier: Bool
    let hasLater: Bool
}

enum ChatHistorySearchError: LocalizedError {
    case invalidDateRange
    case messageUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidDateRange:
            return "开始日期不能晚于结束日期"
        case .messageUnavailable:
            return "原消息已被删除或会话不存在，请刷新搜索结果"
        }
    }
}
