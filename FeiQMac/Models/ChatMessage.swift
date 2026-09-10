import Foundation

enum ChatMessageDirection: String, Codable, Sendable {
    case incoming
    case outgoing
}

enum ChatAttachmentKind: String, Codable, Hashable, Sendable {
    case image
    case file

    var systemImageName: String {
        switch self {
        case .image:
            return "photo"
        case .file:
            return "doc"
        }
    }
}

struct ChatAttachmentGroup: Identifiable, Equatable {
    static let maximumImageCount = 9

    let attachments: [ChatAttachment]

    var id: String { attachments.first?.id ?? "" }
    var isImageGroup: Bool { attachments.first?.isImage == true }

    static func makeGroups(from attachments: [ChatAttachment]) -> [ChatAttachmentGroup] {
        var groups: [ChatAttachmentGroup] = []
        var images: [ChatAttachment] = []
        for attachment in attachments {
            if attachment.isImage {
                images.append(attachment)
                if images.count == maximumImageCount {
                    groups.append(ChatAttachmentGroup(attachments: images))
                    images.removeAll(keepingCapacity: true)
                }
            } else {
                if !images.isEmpty {
                    groups.append(ChatAttachmentGroup(attachments: images))
                    images.removeAll(keepingCapacity: true)
                }
                groups.append(ChatAttachmentGroup(attachments: [attachment]))
            }
        }
        if !images.isEmpty { groups.append(ChatAttachmentGroup(attachments: images)) }
        return groups
    }
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

    /// IP Messenger stores the low byte of file attributes as the file kind.
    /// Directories are intentionally not downloaded by the first file-transfer
    /// implementation; they need the separate GETDIRFILES stream protocol.
    var isDirectory: Bool {
        (fileAttributes & 0xFF) == 0x02
    }

    var isRegularFile: Bool {
        !isDirectory && (fileAttributes & 0xFF) != 0x03
    }
}

/// A locally available attachment rendered by the chat UI and persisted with
/// the message. The local path points to the app's managed attachment
/// directory, not to the sender's original path.
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
        !localPath.isEmpty && FileManager.default.fileExists(atPath: localPath)
    }

    var isImage: Bool {
        kind == .image
    }

    var isFile: Bool {
        kind == .file
    }

    var systemImageName: String {
        kind.systemImageName
    }

    var fileExtensionLabel: String? {
        let normalizedName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = (normalizedName as NSString).pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty ? nil : suffix.uppercased()
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
        mimeType: String,
        kind: ChatAttachmentKind? = nil
    ) {
        self.init(
            id: descriptor.fileID,
            kind: kind ?? (descriptor.isImage ? .image : .file),
            fileName: descriptor.fileName,
            fileSize: descriptor.fileSize,
            modifiedAt: descriptor.modifiedAt,
            fileAttributes: descriptor.fileAttributes,
            localPath: localPath,
            mimeType: mimeType
        )
    }
}

struct ChatHistoryImage: Identifiable, Hashable, Sendable {
    let messageID: UUID
    let attachment: ChatAttachment
    let attachmentIndex: Int
    let date: Date
    let senderName: String
    let direction: ChatMessageDirection

    var id: String { messageID.uuidString + ":" + attachment.id }

    static func images(in message: ChatMessage) -> [ChatHistoryImage] {
        message.attachments.enumerated().compactMap { index, attachment in
            guard attachment.isImage else { return nil }
            return ChatHistoryImage(
                messageID: message.id, attachment: attachment, attachmentIndex: index,
                date: message.date, senderName: message.senderName, direction: message.direction
            )
        }
    }

    static func precedes(_ first: ChatHistoryImage, _ second: ChatHistoryImage) -> Bool {
        if first.date != second.date { return first.date < second.date }
        if first.messageID != second.messageID { return first.messageID.uuidString < second.messageID.uuidString }
        return first.attachmentIndex < second.attachmentIndex
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

    func removingImages(withIDs imageIDs: Set<String>) -> ChatMessage {
        let remaining = attachments.filter { !($0.isImage && imageIDs.contains($0.id)) }
        guard remaining.count != attachments.count else { return self }
        return ChatMessage(
            id: id, direction: direction,
            text: remaining.isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "[图片已删除]" : text,
            senderName: senderName, recipientName: recipientName,
            date: date, attachments: remaining
        )
    }
}
