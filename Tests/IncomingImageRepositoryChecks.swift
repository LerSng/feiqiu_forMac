// Standalone receive-path checks with a fake transport and temporary SQLite.
// No LAN traffic, app launch or real notifications.
import Foundation

private final class TestTransport: FeiQNetworkServiceProtocol {
    var downloadData: Data?
    var onInlineImage: ((Data, String, Int, FeiQPacket, String) -> Void)?
    var onPacket: ((FeiQPacket, String, FeiQTransport, UInt16) -> Void)?
    var onLog: ((String) -> Void)?
    var onStateChange: ((Bool) -> Void)?
    func start(name: String, host: String, group: String) {}
    func stop() {}
    func updateIdentity(name: String, host: String, group: String) {}
    func announce() {}
    func replyToEntry(from ipAddress: String) {}
    func sendTyping(isTyping: Bool, to ipAddress: String) {}
    func sendShake(to ipAddress: String) {}
    func sendText(_ text: String, to ipAddress: String, recipientName: String?) {}
    func sendFileMessage(_ text: String, attachments: [ChatAttachment], to ipAddress: String, recipientName: String?) {}
    func acknowledge(_ packet: FeiQPacket, to ipAddress: String) {}
    func downloadFile(
        _ attachment: FeiQFileAttachment, packetNumber: UInt64,
        from ipAddress: String, to destinationURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        if attachment.fileID == "1", let downloadData {
            do {
                try downloadData.write(to: destinationURL, options: .atomic)
                completion(.success(()))
            } catch { completion(.failure(error)) }
        } else {
            completion(.failure(FeiQFileTransferError.fileNotFound))
        }
    }

    func downloadFile(
        _ attachment: FeiQFileAttachment, packetNumber: UInt64,
        from ipAddress: String, port: UInt16, to destinationURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        downloadFile(
            attachment,
            packetNumber: packetNumber,
            from: ipAddress,
            to: destinationURL,
            completion: completion
        )
    }
}

private final class SilentNotifications: NotificationService {
    var onNotificationSelected: ((String) -> Void)?
    func requestAuthorization() {}
    func notifyIncomingMessage(from sender: String, text: String, conversationID: String) {}
}

private final class ReceivedEvents {
    private let condition = NSCondition()
    private var values: [(message: ChatMessage, peer: FeiQPeer, isNew: Bool)] = []

    func record(_ message: ChatMessage, peer: FeiQPeer, isNew: Bool) {
        condition.lock()
        values.append((message, peer, isNew))
        condition.broadcast()
        condition.unlock()
    }

    func waitFor(_ predicate: (ChatMessage) -> Bool) -> ChatMessage {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while !values.contains(where: { predicate($0.message) }) {
            precondition(condition.wait(until: deadline), "receive event timed out")
        }
        return values.last(where: { predicate($0.message) })!.message
    }

    var snapshot: [(message: ChatMessage, peer: FeiQPeer, isNew: Bool)] {
        condition.lock()
        defer { condition.unlock() }
        return values
    }
}

@main
enum IncomingImageRepositoryChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("feiq-receive-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appendingPathComponent("history.sqlite")
        let legacy = root.appendingPathComponent("missing.json")
        let history = SQLiteChatHistoryService(store: ChatHistoryStore(databaseURL: db, legacyURL: legacy))
        let storage = LocalChatAttachmentStorageService(rootURL: root)
        let transport = TestTransport()
        let repository = DefaultChatRepository(
            networkService: transport, historyService: history,
            attachmentStorageService: storage, notificationService: SilentNotifications(),
            inlineImageTimeout: 0.05, inlineImageRetention: 3
        )
        let events = ReceivedEvents()
        repository.onEvent = { event in
            switch event {
            case .messageReceived(let message, let peer):
                history.saveMessage(message, for: peer, unreadCount: 1)
                events.record(message, peer: peer, isNew: true)
            case .messageUpdated(let message, let peer):
                history.saveMessage(message, for: peer, unreadCount: 1)
                events.record(message, peer: peer, isNew: false)
            default: break
            }
        }
        let dib = Data([
            40,0,0,0, 1,0,0,0, 1,0,0,0, 1,0,24,0,
            0,0,0,0, 4,0,0,0, 0,0,0,0, 0,0,0,0,
            0,0,0,0, 0,0,0,0, 0,0,255,0
        ])
        let packet = FeiQPacket(packetNumber: 500, senderName: "Win", senderHost: "PC",
                                command: .sendMessage, additionalText: "前文/~#>11223344<B~")
        let ip = "192.0.2.10"
        transport.onPacket?(packet, ip, .udp, 2425)
        let waiting = events.waitFor { $0.text.contains("尚未接收完成") }
        let timeout = events.waitFor { $0.text.contains("接收不完整") }
        precondition(waiting.id == timeout.id, "soft timeout keeps message identity")
        transport.onInlineImage?(dib, "11223344", 0, packet, ip)
        let complete = events.waitFor { $0.text == "前文" && $0.attachments.count == 1 }
        precondition(complete.id == waiting.id && complete.date == waiting.date, "late arrival updates in place")
        precondition(events.snapshot.filter(\.isNew).count == 1, "completion does not create another unread event")

        // Loading through a second store proves attachment completion was
        // persisted, not merely substituted in the visible conversation.
        let peer = events.snapshot.first!.peer
        let saved = DispatchSemaphore(value: 0)
        history.loadRecentMessages(for: peer.id, limit: 60) { result in
            let messages = try! result.get().messages
            let stored = messages.first
            let sameMessage = messages.count == 1
                && stored?.id == complete.id
                && stored?.direction == complete.direction
                && stored?.text == complete.text
                && stored?.senderName == complete.senderName
                && stored?.recipientName == complete.recipientName
                && stored?.attachments == complete.attachments
                && abs((stored?.date.timeIntervalSince1970 ?? 0) - complete.date.timeIntervalSince1970) < 0.001
            precondition(sameMessage, "SQLite updates same row")
            saved.signal()
        }
        precondition(saved.wait(timeout: .now() + 5) == .success)
        let reopened = ChatHistoryStore(databaseURL: db, legacyURL: legacy)
        reopened.loadRecentMessages(for: peer.id, limit: 60) { result in
            let messages = try! result.get().messages
            let stored = messages.first
            let sameMessage = messages.count == 1
                && stored?.id == complete.id
                && stored?.direction == complete.direction
                && stored?.text == complete.text
                && stored?.senderName == complete.senderName
                && stored?.recipientName == complete.recipientName
                && stored?.attachments == complete.attachments
                && abs((stored?.date.timeIntervalSince1970 ?? 0) - complete.date.timeIntervalSince1970) < 0.001
            precondition(sameMessage, "completed attachment survives reopening")
            saved.signal()
        }
        precondition(saved.wait(timeout: .now() + 5) == .success)

        // Reverse arrival order: image bytes can precede the marker message.
        let second = FeiQPacket(packetNumber: 501, senderName: "Win", senderHost: "PC",
                                command: .sendMessage, additionalText: "后文/~#>55667788<B~")
        transport.onInlineImage?(dib, "55667788", 1, second, ip)
        transport.onPacket?(packet, ip, .udp, 2425)
        transport.onPacket?(second, ip, .udp, 2425)
        _ = events.waitFor { $0.text == "后文" && $0.attachments.count == 1 }
        precondition(events.snapshot.filter(\.isNew).count == 2, "duplicate marker is not a new message")

        let fixtureImage = try storage.saveInlineImage(dib, imageID: "01020304", isBitmap: true)
        transport.downloadData = try Data(contentsOf: fixtureImage.localURL)
        let descriptors = ["1", "2"].map {
            FeiQFileAttachment(fileID: $0, fileName: "photo\($0).jpg",
                               fileSize: fixtureImage.fileSize, modifiedAt: 1, fileAttributes: 1)
        }
        let partial = FeiQPacket(packetNumber: 503, senderName: "Win", senderHost: "PC",
                                command: FeiQCommand.sendMessage.rawValue | FeiQPacket.fileAttachOption,
                                additionalData: FeiQAttachmentCodec.encode(
                                    message: "多图", attachments: descriptors, preferUTF8: false))
        transport.onPacket?(partial, ip, .udp, 2425)
        let partialMessage = events.waitFor { $0.text.contains("1 张图片接收失败") }
        precondition(partialMessage.attachments.count == 1 && partialMessage.attachments[0].isAvailable,
                     "partial file transfer preserves valid image and reports failure")

        // A non-image attachment follows the same UDP metadata + TCP stream
        // path but must be persisted as a file and not rendered as an image.
        transport.downloadData = Data("hello".utf8)
        let regularDescriptor = FeiQFileAttachment(
            fileID: "1",
            fileName: "notes.txt",
            fileSize: 5,
            modifiedAt: 1,
            fileAttributes: 1
        )
        let regularPacket = FeiQPacket(
            packetNumber: 504,
            senderName: "Win",
            senderHost: "PC",
            command: FeiQCommand.sendMessage.rawValue | FeiQPacket.fileAttachOption,
            additionalData: FeiQAttachmentCodec.encode(
                message: "普通文件",
                attachments: [regularDescriptor],
                preferUTF8: false
            )
        )
        transport.onPacket?(regularPacket, ip, .udp, 2425)
        let regularMessage = events.waitFor {
            $0.text == "普通文件" && $0.attachments.count == 1
        }
        precondition(regularMessage.attachments[0].kind == .file,
                     "regular attachment is not treated as an image")
        precondition(regularMessage.attachments[0].isAvailable,
                     "regular attachment is saved locally")

        let broken = FeiQPacket(packetNumber: 502, senderName: "Win", senderHost: "PC",
                                command: .sendMessage, additionalText: "/~#>aabbccdd<B~")
        transport.onPacket?(broken, ip, .udp, 2425)
        transport.onInlineImage?(Data([1, 2, 3]), "aabbccdd", 0, broken, ip)
        _ = events.waitFor { $0.text.contains("无法解码") }
        _ = events.waitFor { $0.text.contains("接收已超时") }

        let originalImage = complete.attachments[0]
        let sharedMessage = ChatMessage(direction: .outgoing, text: "", attachments: [originalImage])
        history.saveMessage(sharedMessage, for: peer, unreadCount: 0)
        repository.deleteImage(attachmentID: originalImage.id, messageID: complete.id, conversationID: peer.id) { result in
            let updated = try! result.get()
            precondition(updated.text == "前文" && updated.attachments.isEmpty)
            precondition(originalImage.isAvailable, "another message still owns this file")
            saved.signal()
        }
        precondition(saved.wait(timeout: .now() + 5) == .success)
        repository.deleteImage(attachmentID: originalImage.id, messageID: sharedMessage.id, conversationID: peer.id) { result in
            let updated = try! result.get()
            precondition(updated.text == "[图片已删除]" && updated.attachments.isEmpty)
            precondition(!originalImage.isAvailable, "last reference deletes the managed file")
            saved.signal()
        }
        precondition(saved.wait(timeout: .now() + 5) == .success)
        history.saveMessage(complete, for: peer, unreadCount: 0)
        history.loadRecentMessages(for: peer.id, limit: 60) { result in
            let restored = try! result.get().messages.first { $0.id == complete.id }!
            precondition(restored.attachments.isEmpty, "late updates cannot resurrect a deleted image")
            saved.signal()
        }
        precondition(saved.wait(timeout: .now() + 5) == .success)
        reopened.loadRecentMessages(for: peer.id, limit: 60) { result in
            let messages = try! result.get().messages
            precondition(messages.first { $0.id == complete.id }?.attachments.isEmpty == true)
            precondition(messages.first { $0.id == sharedMessage.id }?.attachments.isEmpty == true)
            saved.signal()
        }
        precondition(saved.wait(timeout: .now() + 5) == .success)

        let rollbackImage = try storage.saveInlineImage(dib, imageID: "11001100", isBitmap: true)
        let rollbackMessage = ChatMessage(direction: .incoming, text: "保留", attachments: [rollbackImage])
        history.saveMessage(rollbackMessage, for: peer, unreadCount: 0)
        history.removeImage(
            attachmentID: rollbackImage.id, messageID: rollbackMessage.id, conversationID: peer.id,
            deleteUnreferencedFile: { _ in throw ChatAttachmentStorageError.unsafeDeletion }
        ) { result in
            guard case .failure = result else { preconditionFailure("unlink failure must fail deletion") }
            saved.signal()
        }
        precondition(saved.wait(timeout: .now() + 5) == .success)
        history.loadRecentMessages(for: peer.id, limit: 60) { result in
            let restored = try! result.get().messages.first { $0.id == rollbackMessage.id }
            let fieldsMatch = restored?.id == rollbackMessage.id
                && restored?.direction == rollbackMessage.direction
                && restored?.text == rollbackMessage.text
                && restored?.senderName == rollbackMessage.senderName
                && restored?.recipientName == rollbackMessage.recipientName
                && restored?.attachments == rollbackMessage.attachments
                && abs((restored?.date.timeIntervalSince1970 ?? 0) - rollbackMessage.date.timeIntervalSince1970) < 0.001
            precondition(fieldsMatch && rollbackImage.isAvailable, "failed deletion rolls back history")
            saved.signal()
        }
        precondition(saved.wait(timeout: .now() + 5) == .success)

        let outsideURL = root.appendingPathComponent("original.jpg")
        try Data([1, 2, 3]).write(to: outsideURL)
        let outsideImage = ChatAttachment(
            id: "outside", kind: .image, fileName: "original.jpg", fileSize: 3,
            modifiedAt: 0, fileAttributes: 1, localPath: outsideURL.path, mimeType: "image/jpeg"
        )
        do {
            try storage.deleteManagedImage(outsideImage)
            preconditionFailure("must refuse paths outside managed attachment directories")
        } catch ChatAttachmentStorageError.unsafeDeletion {}
        precondition(FileManager.default.fileExists(atPath: outsideURL.path))
        let linkURL = root.appendingPathComponent("Images/external.jpg")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outsideURL)
        let linkedImage = ChatAttachment(
            id: "link", kind: .image, fileName: "external.jpg", fileSize: 3,
            modifiedAt: 0, fileAttributes: 1, localPath: linkURL.path, mimeType: "image/jpeg"
        )
        do {
            try storage.deleteManagedImage(linkedImage)
            preconditionFailure("must refuse symlinks to original files")
        } catch ChatAttachmentStorageError.unsafeDeletion {}
        let draftImage = try storage.saveInlineImage(dib, imageID: "22002200", isBitmap: true)
        repository.deleteDraftImage(draftImage) { result in
            try! result.get()
            precondition(!draftImage.isAvailable)
            saved.signal()
        }
        precondition(saved.wait(timeout: .now() + 5) == .success)

        let removableImage = try storage.saveInlineImage(dib, imageID: "33003300", isBitmap: true)
        let removableMessage = ChatMessage(
            direction: .incoming,
            text: "整条消息删除",
            senderName: peer.displayName,
            recipientName: "Mac",
            attachments: [removableImage]
        )
        history.saveMessage(removableMessage, for: peer, unreadCount: 0)
        repository.deleteMessage(removableMessage, conversationID: peer.id) { result in
            try! result.get()
            precondition(!removableImage.isAvailable, "deleting a message removes its unreferenced attachment")
            saved.signal()
        }
        precondition(saved.wait(timeout: .now() + 5) == .success)
        history.loadRecentMessages(for: peer.id, limit: 60) { result in
            let messages = try! result.get().messages
            precondition(!messages.contains(where: { $0.id == removableMessage.id }), "deleted message survives no reload")
            saved.signal()
        }
        precondition(saved.wait(timeout: .now() + 5) == .success)
        withExtendedLifetime(repository) {}
        print("Incoming image repository checks passed")
    }
}
