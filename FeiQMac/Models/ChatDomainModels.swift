import Foundation

struct FeiQIdentity: Equatable, Sendable {
    var nickname: String
    var hostName: String
    var groupName: String
}

struct AppSettings: Equatable, Sendable {
    var identity: FeiQIdentity
    var chatLoadAnimationMode: ChatLoadAnimationMode
}

struct ChatGroup: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var name: String
    var memberIDs: [String]
    var ownerName: String
    var createdAt: Date

    init(
        id: String = "group:\(UUID().uuidString)",
        name: String,
        memberIDs: [String],
        ownerName: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        var uniqueMemberIDs: [String] = []
        for memberID in memberIDs where !memberID.isEmpty {
            if !uniqueMemberIDs.contains(memberID) {
                uniqueMemberIDs.append(memberID)
            }
        }
        self.memberIDs = uniqueMemberIDs
        self.ownerName = ownerName
        self.createdAt = createdAt
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名群聊" : trimmed
    }

    var memberCount: Int {
        memberIDs.count
    }
}

struct ChatHistorySnapshot: Sendable {
    let peers: [FeiQPeer]
    let groups: [ChatGroup]
    let unreadCountsByPeer: [String: Int]
    let totalMessageCount: Int
}

struct ChatHistoryPage: Sendable {
    let messages: [ChatMessage]
    let hasMore: Bool
}

struct ChatReceivedFile: Identifiable, Hashable, Sendable {
    let id: String
    let attachment: ChatAttachment
    let receivedAt: Date
    let senderName: String
}

enum ChatRepositoryEvent: Sendable {
    case peerUpdated(FeiQPeer)
    case peerTyping(peer: FeiQPeer, isTyping: Bool)
    case peerShook(FeiQPeer)
    case messageReceived(message: ChatMessage, peer: FeiQPeer)
    case messageUpdated(message: ChatMessage, peer: FeiQPeer)
    case groupMessageReceived(message: ChatMessage, group: ChatGroup)
    case networkStateChanged(Bool)
    case log(String)
    case notificationSelected(conversationID: String)
}

enum ChatLoadAnimationMode: String, CaseIterable, Identifiable, Sendable {
    case converge
    case fade
    case slideUp
    case zoom
    case instant
    case random

    var id: String { rawValue }

    var title: String {
        switch self {
        case .converge:
            return "两侧汇聚"
        case .fade:
            return "淡入"
        case .slideUp:
            return "底部上浮"
        case .zoom:
            return "缩放进入"
        case .instant:
            return "立即显示"
        case .random:
            return "随机"
        }
    }

    var detail: String {
        switch self {
        case .converge:
            return "发送和接收的消息分别从两侧汇聚到聊天框。"
        case .fade:
            return "聊天记录以淡入效果出现。"
        case .slideUp:
            return "聊天记录从底部轻盈上浮出现。"
        case .zoom:
            return "聊天记录以轻微缩放效果出现。"
        case .instant:
            return "不播放进入动画，立即显示聊天记录。"
        case .random:
            return "每次切换好友时随机选择一种进入效果。"
        }
    }

    private static let concreteModes: [Self] = [
        .converge,
        .fade,
        .slideUp,
        .zoom,
        .instant
    ]

    func modeForPresentation() -> Self {
        guard self == .random else { return self }
        return Self.concreteModes.randomElement() ?? .converge
    }
}
