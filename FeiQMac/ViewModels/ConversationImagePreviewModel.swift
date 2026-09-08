import AppKit
import Combine
import Foundation

enum ImagePreviewLayout {
    static func fittedImageSize(_ imageSize: CGSize, in viewport: CGSize, rotationDegrees: Double = 0) -> CGSize {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              viewport.width.isFinite, viewport.height.isFinite, rotationDegrees.isFinite,
              imageSize.width > 0, imageSize.height > 0,
              viewport.width > 0, viewport.height > 0 else { return .zero }
        let radians = rotationDegrees.truncatingRemainder(dividingBy: 360) * .pi / 180
        let cosine = CGFloat(abs(cos(radians)))
        let sine = CGFloat(abs(sin(radians)))
        let rotatedWidth = imageSize.width * cosine + imageSize.height * sine
        let rotatedHeight = imageSize.width * sine + imageSize.height * cosine
        let scale = min(viewport.width / rotatedWidth, viewport.height / rotatedHeight)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}

@MainActor
final class ConversationImagePreviewModel: ObservableObject, Identifiable {
    typealias HistoryLoader = (@escaping (Result<[ChatHistoryImage], Error>) -> Void) -> Void

    let id = UUID()
    let conversationID: String?
    let conversationTitle: String
    @Published private(set) var images: [ChatHistoryImage]
    @Published private(set) var selectedImageID: String?
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var historyError: String?
    @Published private(set) var image: NSImage?
    @Published private(set) var isLoadingImage = false

    private let historyLoader: HistoryLoader?
    private var messageOverrides: [UUID: ChatMessage] = [:]
    private var removedMessageIDs: Set<UUID> = []
    private var historyGeneration = UUID()
    private var imageTask: Task<Void, Never>?
    private var hasStarted = false

    var currentIndex: Int? { images.firstIndex { $0.id == selectedImageID } }
    var currentImage: ChatHistoryImage? { currentIndex.map { images[$0] } }
    var canGoPrevious: Bool { (currentIndex ?? 0) > 0 }
    var canGoNext: Bool { currentIndex.map { $0 + 1 < images.count } ?? false }

    init(
        conversationID: String?,
        conversationTitle: String = "",
        message: ChatMessage,
        attachmentID: String,
        loadedMessages: [ChatMessage] = [],
        historyLoader: HistoryLoader? = nil
    ) {
        self.conversationID = conversationID
        self.conversationTitle = conversationTitle
        self.historyLoader = historyLoader
        for loadedMessage in loadedMessages {
            messageOverrides[loadedMessage.id] = loadedMessage
        }
        messageOverrides[message.id] = message
        images = messageOverrides.values.flatMap(ChatHistoryImage.images).sorted(by: ChatHistoryImage.precedes)
        let selectedID = message.id.uuidString + ":" + attachmentID
        selectedImageID = images.contains { $0.id == selectedID } ? selectedID : images.first?.id
    }

    convenience init(attachment: ChatAttachment) {
        self.init(conversationID: nil,
                  message: ChatMessage(direction: .outgoing, text: "", attachments: [attachment]),
                  attachmentID: attachment.id)
    }

    deinit { imageTask?.cancel() }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        loadCurrentImage()
        reloadHistory()
    }

    func reloadHistory() {
        guard let historyLoader, !isLoadingHistory else { return }
        isLoadingHistory = true
        historyError = nil
        historyGeneration = UUID()
        let generation = historyGeneration
        historyLoader { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.historyGeneration == generation else { return }
                self.isLoadingHistory = false
                switch result {
                case .success(let storedImages):
                    let history = storedImages.filter {
                        self.messageOverrides[$0.messageID] == nil && !self.removedMessageIDs.contains($0.messageID)
                    }
                    self.replaceImages(history + self.messageOverrides.values.flatMap(ChatHistoryImage.images))
                case .failure(let error):
                    self.historyError = error.localizedDescription
                }
            }
        }
    }

    func move(by offset: Int) {
        guard let index = currentIndex, offset == -1 || offset == 1,
              images.indices.contains(index + offset) else { return }
        selectedImageID = images[index + offset].id
        if hasStarted { loadCurrentImage() }
    }

    func update(_ message: ChatMessage) {
        guard !removedMessageIDs.contains(message.id) else { return }
        messageOverrides[message.id] = message
        replaceImages(images.filter { $0.messageID != message.id } + ChatHistoryImage.images(in: message))
    }

    func removeMessage(_ messageID: UUID) {
        removedMessageIDs.insert(messageID)
        messageOverrides.removeValue(forKey: messageID)
        replaceImages(images.filter { $0.messageID != messageID })
    }

    private func replaceImages(_ newImages: [ChatHistoryImage]) {
        let previousImage = currentImage
        let previousIndex = currentIndex ?? 0
        var identifiers = Set<String>()
        images = newImages.sorted(by: ChatHistoryImage.precedes).filter { identifiers.insert($0.id).inserted }
        if !images.contains(where: { $0.id == selectedImageID }) {
            selectedImageID = images.isEmpty ? nil : images[min(previousIndex, images.count - 1)].id
        }
        if hasStarted, previousImage != currentImage { loadCurrentImage() }
    }

    private func loadCurrentImage() {
        imageTask?.cancel()
        image = nil
        guard let currentImage else {
            isLoadingImage = false
            return
        }
        isLoadingImage = true
        imageTask = Task { [weak self] in
            let bitmap = await PreviewImageReader.shared.load(currentImage.attachment.localURL)
            guard !Task.isCancelled, let self, self.selectedImageID == currentImage.id else { return }
            self.image = bitmap.image
            self.isLoadingImage = false
        }
    }
}

private struct PreviewBitmap: @unchecked Sendable {
    let image: NSImage?
}

private actor PreviewImageReader {
    static let shared = PreviewImageReader()

    func load(_ url: URL) -> PreviewBitmap {
        guard !Task.isCancelled else { return PreviewBitmap(image: nil) }
        return autoreleasepool { PreviewBitmap(image: NSImage(contentsOf: url)) }
    }
}
