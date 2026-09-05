import Foundation

enum ChatMessageDirection: String, Codable, Sendable {
    case incoming
    case outgoing
}

enum ChatAttachmentKind: String, Codable, Hashable, Sendable {
    case image
}

/// A file descriptor carried by the FeiQ/IP Messenger attachment section.
/// This is transport metadata and is not persisted as a chat message field.
struct FeiQFileAttachment: Hashable, Sendable {
    let fileID: String
    let fileName: String
    let fileSize: Int64
    let modifiedAt: Int64
    let fileAttributes: UInt32

    var isImage: Bool {
        let pathExtension = URL(fileURLWithPath: fileName)
            .pathExtension
            .lowercased()
        return ["jpg", "jpeg", "png", "gif", "bmp", "tif", "tiff", "webp", "heic", "heif"]
            .contains(pathExtension)
    }
}

/// A locally available attachment rendered by the chat UI and persisted with
/// the message. The local path points to the app's managed image directory,
/// not to the sender's original path.
struct ChatAttachment: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let kind: ChatAttachmentKind
    let fileName: String
    let fileSize: Int64
    let modifiedAt: Int64
    let fileAttributes: UInt32
    let localPath: String
    let mimeType: String

    var localURL: URL {
        URL(fileURLWithPath: localPath)
    }

    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: localPath)
    }

    var fileSizeDescription: String {
        ByteCountFormatter.string(
            fromByteCount: fileSize,
            countStyle: .file
        )
    }

    init(
        id: String,
        kind: ChatAttachmentKind,
        fileName: String,
        fileSize: Int64,
        modifiedAt: Int64,
        fileAttributes: UInt32,
        localPath: String,
        mimeType: String
    ) {
        self.id = id
        self.kind = kind
        self.fileName = fileName
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.fileAttributes = fileAttributes
        self.localPath = localPath
        self.mimeType = mimeType
    }

    init(
        descriptor: FeiQFileAttachment,
        localPath: String,
        mimeType: String
    ) {
        self.init(
            id: descriptor.fileID,
            kind: .image,
            fileName: descriptor.fileName,
            fileSize: descriptor.fileSize,
            modifiedAt: descriptor.modifiedAt,
            fileAttributes: descriptor.fileAttributes,
            localPath: localPath,
            mimeType: mimeType
        )
    }
}

struct ChatMessage: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let direction: ChatMessageDirection
    let text: String
    let senderName: String
    let recipientName: String
    let date: Date
    let attachments: [ChatAttachment]

    private enum CodingKeys: String, CodingKey {
        case id
        case direction
        case text
        case senderName
        case recipientName
        case date
        case attachments
    }

    init(
        id: UUID = UUID(),
        direction: ChatMessageDirection,
        text: String,
        senderName: String = "",
        recipientName: String = "",
        date: Date = Date(),
        attachments: [ChatAttachment] = []
    ) {
        self.id = id
        self.direction = direction
        self.text = text
        self.senderName = senderName
        self.recipientName = recipientName
        self.date = date
        self.attachments = attachments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        direction = try container.decode(ChatMessageDirection.self, forKey: .direction)
        text = try container.decode(String.self, forKey: .text)
        senderName = try container.decodeIfPresent(String.self, forKey: .senderName) ?? ""
        recipientName = try container.decodeIfPresent(String.self, forKey: .recipientName) ?? ""
        date = try container.decode(Date.self, forKey: .date)
        attachments = try container.decodeIfPresent(
            [ChatAttachment].self,
            forKey: .attachments
        ) ?? []
    }
}
