import Foundation

enum ChatMessageDirection: String, Codable, Sendable {
    case incoming
    case outgoing
}

struct ChatMessage: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let direction: ChatMessageDirection
    let text: String
    let senderName: String
    let recipientName: String
    let date: Date

    init(
        id: UUID = UUID(),
        direction: ChatMessageDirection,
        text: String,
        senderName: String = "",
        recipientName: String = "",
        date: Date = Date()
    ) {
        self.id = id
        self.direction = direction
        self.text = text
        self.senderName = senderName
        self.recipientName = recipientName
        self.date = date
    }
}
