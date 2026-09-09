import AppKit
import Foundation

@MainActor
private final class DeferredImageHistory {
    var completion: ((Result<[ChatHistoryImage], Error>) -> Void)?
    private(set) var attempts = 0

    func load(_ completion: @escaping (Result<[ChatHistoryImage], Error>) -> Void) {
        attempts += 1
        self.completion = completion
    }

    func finish(_ result: Result<[ChatHistoryImage], Error>) {
        let callback = completion
        completion = nil
        callback?(result)
    }
}

@main
enum ImagePreviewChecks {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feiq-image-preview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        checkFitToViewport()
        let imageURL = try makeImage(in: root)
        checkCardWindow(imageURL: imageURL)
        try await checkConversationHistory(root: root, imageURL: imageURL)
        try await checkGalleryNavigation(imageURL: imageURL)
        try await checkGalleryUpdatesAndErrors(imageURL: imageURL)
        print("Image preview checks passed")
    }

    @MainActor
    private static func checkCardWindow(imageURL: URL) {
        let messages = (0..<240).map { message(Double($0), attachments: [attachment("shared-id", url: imageURL)]) }
        let gallery = ConversationImagePreviewModel(conversationID: "peer", message: messages[0],
                                                    attachmentID: "shared-id", loadedMessages: messages)
        precondition(gallery.visibleCards.map(\.offset) == [0, 1])
        for step in [1, -1] {
            for _ in 1..<messages.count {
                let previousID = gallery.selectedImageID
                gallery.move(by: step)
                let cards = gallery.visibleCards
                precondition(cards.count <= 3 && Set(cards.map(\.id)).count == cards.count,
                             "The carousel must only mount the current image and its immediate neighbors")
                precondition(cards.filter(\.isSelected).count == 1)
                precondition(cards.first(where: \.isSelected)?.id == gallery.selectedImageID)
                precondition(cards.first(where: { $0.offset == -step })?.id == previousID,
                             "The outgoing card must retain its identity as it slides to the opposite side")
            }
            let lastID = gallery.selectedImageID
            gallery.move(by: step)
            precondition(gallery.selectedImageID == lastID, "Card navigation must stop at each boundary")
        }
        precondition(gallery.visibleCards.map(\.offset) == [0, 1])
        let cards = gallery.visibleCards.map(\.id)
        gallery.move(by: 2)
        precondition(gallery.visibleCards.map(\.id) == cards, "Invalid steps must not skip card identities")
    }

    private static func checkFitToViewport() {
        let viewport = CGSize(width: 1024, height: 650)
        let sizes = [
            CGSize(width: 840, height: 660),
            CGSize(width: 4000, height: 1800),
            CGSize(width: 600, height: 1400),
            CGSize(width: 32, height: 24),
            CGSize(width: 100, height: 100)
        ]
        for size in sizes {
            for rotation in [0.0, 90, 180, 270, 360, 45, -90] {
                let fitted = ImagePreviewLayout.fittedImageSize(size, in: viewport, rotationDegrees: rotation)
                let radians = rotation * .pi / 180
                let bounds = CGSize(
                    width: fitted.width * abs(cos(radians)) + fitted.height * abs(sin(radians)),
                    height: fitted.width * abs(sin(radians)) + fitted.height * abs(cos(radians))
                )
                precondition(bounds.width <= viewport.width + 0.001 && bounds.height <= viewport.height + 0.001,
                             "fitting must keep the complete image inside the canvas")
                precondition(abs(bounds.width - viewport.width) < 0.001 || abs(bounds.height - viewport.height) < 0.001,
                             "the image must reach a canvas edge without extra inset")
                precondition(abs(fitted.width / fitted.height - size.width / size.height) < 0.001,
                             "fitting must preserve the image aspect ratio")
            }
        }
        let enlarged = ImagePreviewLayout.fittedImageSize(CGSize(width: 32, height: 24), in: viewport)
        precondition(enlarged.width > 32 && enlarged.height == viewport.height, "small images must also fill the viewport")
        precondition(ImagePreviewLayout.fittedImageSize(.zero, in: viewport) == .zero)
        precondition(ImagePreviewLayout.fittedImageSize(sizes[0], in: .zero) == .zero)
        precondition(ImagePreviewLayout.fittedImageSize(CGSize(width: CGFloat.nan, height: 10), in: viewport) == .zero)
        precondition(ImagePreviewLayout.fittedImageSize(sizes[0], in: viewport, rotationDegrees: .infinity) == .zero)
    }

    @MainActor
    private static func checkConversationHistory(root: URL, imageURL: URL) async throws {
        let databaseURL = root.appendingPathComponent("history.sqlite")
        let legacyURL = root.appendingPathComponent("missing.json")
        let store = ChatHistoryStore(databaseURL: databaseURL, legacyURL: legacyURL)
        let repository = DefaultMessageRepository(historyService: SQLiteChatHistoryService(store: store))
        let peer = FeiQPeer(id: "peer-a", name: "甲", hostName: "Mac-A", ipAddress: "192.0.2.1",
                            group: "", lastSeen: Date(), isOnline: true)
        let otherPeer = FeiQPeer(id: "peer-b", name: "乙", hostName: "Mac-B", ipAddress: "192.0.2.2",
                                 group: "", lastSeen: Date(), isOnline: true)
        let image = attachment("reused-id", url: imageURL)
        let secondImage = attachment("second", url: imageURL)
        let file = attachment("document", url: imageURL, kind: .file)
        var messages: [ChatMessage] = []
        for index in 0..<260 {
            let identifier = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
            let message = ChatMessage(
                id: identifier, direction: index.isMultiple(of: 2) ? .incoming : .outgoing,
                text: "message \(index)", senderName: index.isMultiple(of: 2) ? peer.name : "我",
                date: Date(timeIntervalSince1970: 1000 + Double(index / 2)),
                attachments: index == 0 ? [image, file, secondImage] : [image]
            )
            messages.append(message)
        }
        for message in messages.reversed() {
            repository.saveMessage(message, for: peer, unreadCount: 0)
        }
        repository.saveMessage(ChatMessage(direction: .incoming, text: "only text"), for: peer, unreadCount: 0)
        repository.saveMessage(ChatMessage(direction: .incoming, text: "", attachments: [file]), for: peer, unreadCount: 0)
        let foreign = ChatMessage(direction: .incoming, text: "different conversation", attachments: [image])
        repository.saveMessage(foreign, for: otherPeer, unreadCount: 0)
        let group = ChatGroup(name: "测试群", memberIDs: [peer.id], ownerName: "我")
        let groupMessage = ChatMessage(direction: .incoming, text: "group", attachments: [secondImage])
        repository.saveMessage(groupMessage, for: group, unreadCount: 0)

        let images = try await loadImages(repository, conversationID: peer.id)
        let expected = messages.flatMap(ChatHistoryImage.images)
        precondition(images == expected, "history must include both directions, all pages and attachment order")
        precondition(images.count == 261 && Set(images.map(\.id)).count == 261,
                     "attachment IDs reused in different messages must remain distinct")
        let groupImages = try await loadImages(repository, conversationID: group.id)
        precondition(groupImages.map(\.messageID) == [groupMessage.id], "group images must not leak into direct conversations")
        let otherImages = try await loadImages(repository, conversationID: otherPeer.id)
        precondition(otherImages.map(\.messageID) == [foreign.id], "image queries must be conversation scoped")

        let updated: ChatMessage = try await withCheckedThrowingContinuation { continuation in
            repository.removeImage(attachmentID: image.id, messageID: messages[0].id, conversationID: peer.id,
                                   deleteUnreferencedFile: { _ in }, completion: { continuation.resume(with: $0) })
        }
        precondition(updated.attachments == [file, secondImage])
        let _: [ChatAttachment] = try await withCheckedThrowingContinuation { continuation in
            repository.deleteMessage(id: messages[1].id, conversationID: peer.id,
                                     completion: { continuation.resume(with: $0) })
        }
        let remaining = try await loadImages(repository, conversationID: peer.id)
        precondition(remaining.count == 259 && remaining.first?.attachment == secondImage,
                     "removed images and deleted messages must disappear from history")
        let reopened = DefaultMessageRepository(historyService: SQLiteChatHistoryService(
            store: ChatHistoryStore(databaseURL: databaseURL, legacyURL: legacyURL)
        ))
        let restored = try await loadImages(reopened, conversationID: peer.id)
        precondition(restored == remaining, "image navigation history must survive reopening the database")
    }

    @MainActor
    private static func checkGalleryNavigation(imageURL: URL) async throws {
        let earlier = message(1, attachments: [attachment("same-id", url: imageURL)])
        let anchor = message(2, attachments: [attachment("same-id", url: imageURL), attachment("second", url: imageURL)])
        let later = message(3, attachments: [attachment("later", url: imageURL)])
        let loader = DeferredImageHistory()
        let gallery = ConversationImagePreviewModel(
            conversationID: "peer", message: anchor, attachmentID: "second", loadedMessages: [anchor, later],
            historyLoader: loader.load
        )
        gallery.start()
        gallery.start()
        precondition(gallery.currentIndex == 1 && gallery.currentImage?.attachment.id == "second")
        precondition(gallery.visibleCards.map(\.offset) == [-1, 0, 1])
        precondition(loader.attempts == 1 && gallery.isLoadingHistory)
        gallery.move(by: -1)
        let selection = gallery.selectedImageID
        loader.finish(.success([later, anchor, earlier].flatMap(ChatHistoryImage.images)))
        try await waitFor { !gallery.isLoadingHistory && !gallery.isLoadingImage }
        precondition(gallery.selectedImageID == selection && gallery.currentIndex == 1,
                     "loading older history must keep the clicked image selected")
        precondition(gallery.visibleCards.first(where: \.isSelected)?.id == selection,
                     "A history refresh must not change the selected card identity")
        precondition(gallery.image != nil && gallery.images.count == 4)
        gallery.move(by: -1)
        precondition(gallery.currentImage?.messageID == earlier.id && !gallery.canGoPrevious)
        gallery.move(by: -1)
        precondition(gallery.currentImage?.messageID == earlier.id, "navigation must not wrap past the first image")
        gallery.move(by: 1)
        gallery.move(by: 1)
        gallery.move(by: 1)
        gallery.move(by: 1)
        try await waitFor { !gallery.isLoadingImage }
        precondition(gallery.currentImage?.messageID == later.id && !gallery.canGoNext && gallery.image != nil,
                     "rapid navigation must settle on the final selection")
        let single = ConversationImagePreviewModel(attachment: anchor.attachments[0])
        single.start()
        try await waitFor { !single.isLoadingImage }
        precondition(single.conversationID == nil && single.images.count == 1 && single.image != nil,
                     "draft previews must remain standalone")
        precondition(single.visibleCards.count == 1 && single.visibleCards[0].isSelected)
    }

    @MainActor
    private static func checkGalleryUpdatesAndErrors(imageURL: URL) async throws {
        let first = attachment("first", url: imageURL)
        let second = attachment("second", url: imageURL)
        let anchor = message(10, attachments: [first, second])
        let removed = message(9, attachments: [first])
        let live = message(11, attachments: [first])
        let loader = DeferredImageHistory()
        let gallery = ConversationImagePreviewModel(
            conversationID: "peer", message: anchor, attachmentID: first.id, historyLoader: loader.load
        )
        gallery.start()
        gallery.update(anchor.removingImages(withIDs: [first.id]))
        gallery.removeMessage(removed.id)
        gallery.update(live)
        loader.finish(.success([removed, anchor].flatMap(ChatHistoryImage.images)))
        try await waitFor { !gallery.isLoadingHistory && !gallery.isLoadingImage }
        precondition(gallery.images.map(\.attachment.id) == [second.id, first.id],
                     "late history results must not restore removed images or erase newly received images")
        precondition(gallery.currentImage?.attachment.id == second.id, "removing the selected image selects the next one")
        gallery.removeMessage(anchor.id)
        gallery.removeMessage(live.id)
        precondition(gallery.currentImage == nil && !gallery.isLoadingImage && gallery.image == nil)
        precondition(gallery.visibleCards.isEmpty, "Deleted images must not leave stale carousel cards")

        let missing = message(12, attachments: [attachment("missing", url: imageURL.appendingPathExtension("missing"))])
        let failingLoader = DeferredImageHistory()
        let fallback = ConversationImagePreviewModel(
            conversationID: "peer", message: missing, attachmentID: "missing", historyLoader: failingLoader.load
        )
        fallback.start()
        failingLoader.finish(.failure(NSError(domain: "HistoryRead", code: 1)))
        try await waitFor { !fallback.isLoadingImage && !fallback.isLoadingHistory }
        precondition(fallback.image == nil && fallback.historyError != nil,
                     "missing files and failed history queries must not leave an indefinite spinner")
        fallback.reloadHistory()
        failingLoader.finish(.success(ChatHistoryImage.images(in: anchor)))
        try await waitFor { !fallback.isLoadingHistory }
        precondition(fallback.historyError == nil && fallback.images.count == 3)
        fallback.move(by: -1)
        try await waitFor { !fallback.isLoadingImage }
        precondition(fallback.image != nil, "an unavailable image must not block navigation to another image")
    }

    private static func attachment(_ identifier: String, url: URL, kind: ChatAttachmentKind = .image) -> ChatAttachment {
        ChatAttachment(id: identifier, kind: kind, fileName: identifier + ".png", fileSize: 128,
                       modifiedAt: 0, fileAttributes: 1, localPath: url.path, mimeType: "image/png")
    }

    private static func message(_ time: TimeInterval, attachments: [ChatAttachment]) -> ChatMessage {
        ChatMessage(direction: .incoming, text: "", senderName: "测试", date: Date(timeIntervalSince1970: time),
                    attachments: attachments)
    }

    private static func makeImage(in root: URL) throws -> URL {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 24,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 128, bitsPerPixel: 32)!
        bitmap.bitmapData!.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let url = root.appendingPathComponent("test.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    private static func loadImages(_ repository: MessageRepository, conversationID: String) async throws -> [ChatHistoryImage] {
        try await withCheckedThrowingContinuation { continuation in
            repository.loadConversationImages(for: conversationID) { continuation.resume(with: $0) }
        }
    }

    @MainActor
    private static func waitFor(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() {
            precondition(Date() < deadline, "image preview update timed out")
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
