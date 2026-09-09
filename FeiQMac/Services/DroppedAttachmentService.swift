import AppKit
import Foundation
import UniformTypeIdentifiers

struct DroppedAttachmentResult {
    let attachments: [ChatAttachment]
    let failures: [String]
}

enum DroppedAttachmentError: LocalizedError {
    case tooManyItems
    case unsupportedItem
    case localFilesOnly
    case timedOut
    case cancelled
    case cleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .tooManyItems: return "每次最多拖入 \(DroppedAttachmentService.maximumItemCount) 个文件或图片，请分批发送"
        case .unsupportedItem: return "只支持本地文件和图片，不支持文件夹、链接或其他拖拽内容"
        case .localFilesOnly: return "只能拖入本地文件，不会自动下载网络链接"
        case .timedOut: return "读取拖拽内容超时，请重试或先保存为本地文件"
        case .cancelled: return "拖拽发送已取消"
        case .cleanupFailed(let detail): return "未发送附件清理失败：\(detail)"
        }
    }
}

final class DroppedAttachmentCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handler: (() -> Void)?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let action = handler
        handler = nil
        lock.unlock()
        action?()
    }

    fileprivate func onCancel(_ action: (() -> Void)?) {
        lock.lock()
        let shouldCancel = cancelled
        handler = shouldCancel ? nil : action
        lock.unlock()
        if shouldCancel { action?() }
    }
}

enum ChatAttachmentDrop {
    static let typeIdentifiers = [UTType.fileURL.identifier, UTType.image.identifier]
    static let pasteboardTypes: [NSPasteboard.PasteboardType] = [
        .fileURL, .png, .tiff,
        NSPasteboard.PasteboardType(UTType.image.identifier),
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier),
        NSPasteboard.PasteboardType(UTType.gif.identifier),
        NSPasteboard.PasteboardType("org.webmproject.webp")
    ]

    static func supports(_ provider: NSItemProvider) -> Bool {
        typeIdentifiers.contains { provider.hasItemConformingToTypeIdentifier($0) }
    }

    static func containsAttachments(in pasteboard: NSPasteboard) -> Bool {
        pasteboard.pasteboardItems?.contains { item in
            item.types.contains { $0 == .fileURL || UTType($0.rawValue)?.conforms(to: .image) == true }
        } == true
    }

    static func providers(from pasteboard: NSPasteboard) -> [NSItemProvider] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            if let value = item.string(forType: .fileURL), let url = URL(string: value) {
                return NSItemProvider(item: url as NSURL, typeIdentifier: UTType.fileURL.identifier)
            }
            guard let type = item.types.first(where: { UTType($0.rawValue)?.conforms(to: .image) == true }),
                  let data = item.data(forType: type) else { return nil }
            return NSItemProvider(item: data as NSData, typeIdentifier: type.rawValue)
        }
    }
}

final class DroppedAttachmentService {
    static let maximumItemCount = 50
    private let attachmentRepository: AttachmentRepository
    private let queue = DispatchQueue(label: "com.local.feiqmac.dropped-attachments", qos: .userInitiated)
    private let timeout: TimeInterval

    init(attachmentRepository: AttachmentRepository, timeout: TimeInterval = 30) {
        self.attachmentRepository = attachmentRepository
        self.timeout = timeout
    }

    func prepare(
        _ providers: [NSItemProvider],
        progress: @escaping (Int, Int) -> Void,
        completion: @escaping (Result<DroppedAttachmentResult, Error>) -> Void
    ) -> DroppedAttachmentCancellation {
        let cancellation = DroppedAttachmentCancellation()
        let session = Preparation(
            providers: providers, repository: attachmentRepository, queue: queue, timeout: timeout,
            cancellation: cancellation, progress: progress, completion: completion
        )
        queue.async { session.start() }
        return cancellation
    }

    private final class Preparation {
        let providers: [NSItemProvider]
        let repository: AttachmentRepository
        let queue: DispatchQueue
        let timeout: TimeInterval
        let cancellation: DroppedAttachmentCancellation
        let progress: (Int, Int) -> Void
        let completion: (Result<DroppedAttachmentResult, Error>) -> Void
        var index = 0
        var attachments: [ChatAttachment] = []
        var failures: [String] = []
        var seenPaths = Set<String>()
        var timeoutWork: DispatchWorkItem?
        var loadingProgress: Progress?
        var finished = false

        init(providers: [NSItemProvider], repository: AttachmentRepository, queue: DispatchQueue,
             timeout: TimeInterval, cancellation: DroppedAttachmentCancellation,
             progress: @escaping (Int, Int) -> Void, completion: @escaping (Result<DroppedAttachmentResult, Error>) -> Void) {
            self.providers = providers
            self.repository = repository
            self.queue = queue
            self.timeout = timeout
            self.cancellation = cancellation
            self.progress = progress
            self.completion = completion
        }

        func start() {
            cancellation.onCancel { self.queue.async { self.finish(.failure(DroppedAttachmentError.cancelled)) } }
            guard providers.count <= DroppedAttachmentService.maximumItemCount else {
                finish(.failure(DroppedAttachmentError.tooManyItems))
                return
            }
            next()
        }

        func next() {
            guard !finished else { return }
            guard !cancellation.isCancelled else {
                finish(.failure(DroppedAttachmentError.cancelled))
                return
            }
            progress(index, providers.count)
            guard index < providers.count else {
                finish(.success(DroppedAttachmentResult(attachments: attachments, failures: failures)))
                return
            }
            let provider = providers[index]
            let itemIndex = index
            let timeoutWork = DispatchWorkItem { [weak self] in
                self?.receive(.failure(DroppedAttachmentError.timedOut), at: itemIndex)
            }
            self.timeoutWork = timeoutWork
            queue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, error in
                    guard let self else { return }
                    self.queue.async {
                        guard !self.finished, self.index == itemIndex else { return }
                        self.receive(Result {
                            if let error { throw error }
                            let url: URL?
                            if let value = item as? URL { url = value }
                            else if let value = item as? Data { url = URL(dataRepresentation: value, relativeTo: nil) }
                            else if let value = item as? String { url = URL(string: value) }
                            else { url = nil }
                            guard let url else { throw DroppedAttachmentError.unsupportedItem }
                            return try self.prepareFile(url)
                        }, at: itemIndex)
                    }
                }
            } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                let suggestedFileName = provider.suggestedName
                loadingProgress = provider.loadDataRepresentation(forTypeIdentifier: type) { [weak self] data, error in
                    guard let self else { return }
                    self.queue.async {
                        guard !self.finished, self.index == itemIndex else { return }
                        self.receive(Result {
                            if let error { throw error }
                            guard let data, !data.isEmpty, data.count <= FeiQInlineImageCodec.maximumBytes else {
                                throw ChatAttachmentStorageError.invalidFileSize
                            }
                            return try self.repository.prepareOutgoingImage(from: data, suggestedFileName: suggestedFileName)
                        }, at: itemIndex)
                    }
                }
            } else {
                receive(.failure(DroppedAttachmentError.unsupportedItem), at: itemIndex)
            }
        }

        func prepareFile(_ url: URL) throws -> ChatAttachment? {
            guard url.isFileURL else { throw DroppedAttachmentError.localFilesOnly }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentTypeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw DroppedAttachmentError.unsupportedItem
            }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard seenPaths.insert(path).inserted else { return nil }
            let type = values.contentType ?? UTType(filenameExtension: url.pathExtension)
            if type?.conforms(to: .image) == true {
                return try repository.prepareOutgoingImage(from: url)
            }
            return try repository.prepareOutgoingFile(from: url)
        }

        func receive(_ result: Result<ChatAttachment?, Error>, at itemIndex: Int) {
            guard !finished, index == itemIndex else { return }
            timeoutWork?.cancel()
            timeoutWork = nil
            let pendingProgress = loadingProgress
            loadingProgress = nil
            index += 1
            switch result {
            case .success(let attachment):
                if let attachment { attachments.append(attachment) }
            case .failure(let error):
                pendingProgress?.cancel()
                failures.append("\(providers[itemIndex].suggestedName ?? "第 \(itemIndex + 1) 项")：\(error.localizedDescription)")
            }
            next()
        }

        func finish(_ result: Result<DroppedAttachmentResult, Error>) {
            guard !finished else { return }
            finished = true
            timeoutWork?.cancel()
            loadingProgress?.cancel()
            timeoutWork = nil
            loadingProgress = nil
            cancellation.onCancel(nil)
            var result = result
            if case .failure = result {
                var cleanupErrors: [String] = []
                for attachment in attachments {
                    do { try repository.deleteManagedAttachment(attachment) }
                    catch { cleanupErrors.append(error.localizedDescription) }
                }
                if !cleanupErrors.isEmpty {
                    result = .failure(DroppedAttachmentError.cleanupFailed(cleanupErrors.joined(separator: "；")))
                }
            }
            attachments.removeAll()
            completion(result)
        }
    }
}
