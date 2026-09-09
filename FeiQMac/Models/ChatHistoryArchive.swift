import Foundation

enum ChatHistoryExportFormat: String, CaseIterable, Identifiable, Sendable {
    case txt
    case markdown
    case html

    var id: String { rawValue }
    var title: String {
        switch self {
        case .txt: return "TXT"
        case .markdown: return "Markdown"
        case .html: return "HTML"
        }
    }
    var fileExtension: String {
        self == .markdown ? "md" : rawValue
    }
}

enum ChatHistoryArchiveMode: String, CaseIterable, Identifiable {
    case export
    case `import`

    var id: String { rawValue }
    var title: String { self == .export ? "导出" : "导入" }
}

struct ChatArchivedMessage: Codable, Hashable, Sendable {
    let conversationID: String
    var message: ChatMessage
}

struct ChatHistoryArchive: Codable, Sendable {
    var version = 1
    var exportedAt = Date()
    var peers: [FeiQPeer]
    var groups: [ChatGroup]
    var messages: [ChatArchivedMessage]
    var attachmentDirectory: String?

    func validate() throws {
        guard version == 1 else { throw ChatHistoryArchiveError.unsupportedVersion }
        let peerIDs = Set(peers.map(\.id))
        let groupIDs = Set(groups.map(\.id))
        let conversationIDs = peerIDs.union(groupIDs)
        guard peerIDs.count == peers.count, groupIDs.count == groups.count,
              peerIDs.isDisjoint(with: groupIDs), !conversationIDs.contains(""),
              exportedAt.timeIntervalSince1970.isFinite else {
            throw ChatHistoryArchiveError.invalidArchive("联系人或群聊数据无效")
        }
        var knownMessages: [UUID: ChatArchivedMessage] = [:]
        for record in messages {
            guard conversationIDs.contains(record.conversationID),
                  record.message.date.timeIntervalSince1970.isFinite,
                  Set(record.message.attachments.map(\.id)).count == record.message.attachments.count,
                  record.message.attachments.allSatisfy({ !$0.id.isEmpty && $0.fileSize >= 0 }) else {
                throw ChatHistoryArchiveError.invalidArchive("消息或附件元数据无效")
            }
            if let previous = knownMessages[record.message.id], previous != record {
                throw ChatHistoryArchiveError.invalidArchive("同一消息 ID 对应不同的消息")
            }
            knownMessages[record.message.id] = record
        }
    }

    var conversationNames: [String: String] {
        var names = Dictionary(uniqueKeysWithValues: peers.map { ($0.id, $0.displayName) })
        for group in groups { names[group.id] = group.displayName }
        return names
    }
}

struct ChatHistoryImportPreview: Identifiable, Sendable {
    let id = UUID()
    let sourceURL: URL
    let archive: ChatHistoryArchive
    let missingAttachmentCount: Int
}

struct ChatHistoryImportSummary: Sendable {
    let insertedMessageIDs: Set<UUID>
    let skippedMessageCount: Int
    let addedPeerCount: Int
    let addedGroupCount: Int
    var missingAttachmentCount = 0
    var cleanupWarning: String?

    var importedMessageCount: Int { insertedMessageIDs.count }
}

struct ChatHistoryExportSummary: Sendable {
    let fileURL: URL
    let messageCount: Int
    let attachmentCount: Int
    let missingAttachmentCount: Int
}

enum ChatHistoryArchiveError: LocalizedError {
    case unsupportedVersion
    case invalidArchive(String)
    case missingRecoveryData
    case unsafeAttachmentPath
    case attachmentChanged(String)
    case conflictingConversation
    case conflictingMessage
    case emptyExport
    case documentTooLarge

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "不支持此聊天记录版本，请使用相同或更新版本的飞秋 Mac"
        case .invalidArchive(let detail): return "聊天记录文件无效：\(detail)"
        case .missingRecoveryData: return "未找到恢复数据，请选择飞秋 Mac 导出的完整 TXT、Markdown 或 HTML 文件"
        case .unsafeAttachmentPath: return "附件路径不安全：只允许读取导出文件配套目录内的普通文件"
        case .attachmentChanged(let name): return "附件已被修改或大小不符：\(name)"
        case .conflictingConversation: return "导入的联系人 ID 与现有群聊冲突，未写入任何记录"
        case .conflictingMessage: return "消息 ID 与其他会话中的消息冲突，未写入任何记录"
        case .emptyExport: return "没有符合筛选条件的聊天记录可导出"
        case .documentTooLarge: return "记录文件超过 200 MB 限制，请按联系人或日期分批导出"
        }
    }
}
