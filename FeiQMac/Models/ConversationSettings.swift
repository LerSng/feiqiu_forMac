import Foundation

struct ConversationSettings: Codable, Equatable, Sendable {
    var isPinned = false
    var isMuted = false
    var remark = ""
    var tags: [String] = []
    var isBlocked = false

    var isDefault: Bool { self == ConversationSettings() }
    var suppressesAlerts: Bool { isMuted || isBlocked }

    func validated() throws -> ConversationSettings {
        var settings = self
        settings.remark = remark.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.remark.count <= 80 else { throw ConversationSettingsError.remarkTooLong }
        var seen = Set<String>()
        settings.tags = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        guard settings.tags.count <= 10 else { throw ConversationSettingsError.tooManyTags }
        guard settings.tags.allSatisfy({ $0.count <= 24 && !$0.contains(where: \.isNewline) }) else {
            throw ConversationSettingsError.tagTooLong
        }
        return settings
    }

    static func parseTags(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",，、\n\r"))
    }
}

struct ConversationSettingsTarget: Identifiable {
    let id: String
    let originalName: String
    let isGroup: Bool
}

enum ConversationSettingsError: LocalizedError {
    case remarkTooLong
    case tooManyTags
    case tagTooLong
    case unavailable
    case blocked

    var errorDescription: String? {
        switch self {
        case .remarkTooLong: return "备注名称最多 80 个字符"
        case .tooManyTags: return "每个会话最多添加 10 个标签"
        case .tagTooLong: return "每个标签最多 24 个字符，且不能包含换行"
        case .unavailable: return "会话不存在或会话设置尚未成功加载"
        case .blocked: return "此会话已屏蔽，请解除屏蔽后再发送"
        }
    }
}
