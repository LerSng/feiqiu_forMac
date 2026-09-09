import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct DropSendChecks {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feiq-drop-send-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let imageData = makeImage()
        try await checkPreparation(root: root, imageData: imageData)
        try await checkCancellationAndTimeout(root: root, imageData: imageData)
        try await checkNativeEditor(root: root, imageData: imageData)
        try await checkSending(root: root, imageData: imageData)
        print("Drag-and-drop sending checks passed")
    }

    private static func checkPreparation(root: URL, imageData: Data) async throws {
        let directory = root.appendingPathComponent("prepare")
        let storage = LocalChatAttachmentStorageService(rootURL: directory)
        let service = DroppedAttachmentService(attachmentRepository: DefaultAttachmentRepository(storageService: storage))
        let imageURL = directory.appendingPathComponent("照片 #1.png")
        let fileURL = directory.appendingPathComponent("中文 文档.txt")
        let emptyURL = directory.appendingPathComponent("empty.txt")
        let brokenURL = directory.appendingPathComponent("broken.png")
        try imageData.write(to: imageURL)
        try Data("正文".utf8).write(to: fileURL)
        try Data().write(to: emptyURL)
        try Data("invalid image".utf8).write(to: brokenURL)
        let prepared: DroppedAttachmentResult = try await receive {
            _ = service.prepare([
                fileProvider(imageURL), fileProvider(fileURL), fileProvider(imageURL), fileProvider(directory),
                fileProvider(brokenURL), fileProvider(URL(string: "https://example.invalid/image.png")!),
                imageProvider(imageData), fileProvider(emptyURL)
            ], progress: { _, _ in }, completion: $0)
        }
        precondition(prepared.attachments.map(\.kind) == [.image, .file, .image, .file])
        precondition(prepared.failures.count == 3 && prepared.attachments.allSatisfy(\.isAvailable))
        precondition(prepared.attachments[0].fileName.hasSuffix(".jpg"), "Images must use the existing FeiQ inline-image encoding")
        precondition(prepared.attachments[1].fileName == fileURL.lastPathComponent)
        precondition(prepared.attachments[3].fileSize == 0, "Empty regular files remain valid attachments")
        precondition(FileManager.default.fileExists(atPath: fileURL.path) && FileManager.default.fileExists(atPath: imageURL.path))
        for attachment in prepared.attachments { try storage.deleteManagedAttachment(attachment) }

        for value: NSSecureCoding in [fileURL.absoluteString as NSString, fileURL.dataRepresentation as NSData] {
            let provider = NSItemProvider(item: value, typeIdentifier: UTType.fileURL.identifier)
            let result: DroppedAttachmentResult = try await receive {
                _ = service.prepare([provider], progress: { _, _ in }, completion: $0)
            }
            precondition(result.attachments.count == 1 && result.failures.isEmpty)
            try storage.deleteManagedAttachment(result.attachments[0])
        }
        let tooLarge = directory.appendingPathComponent("large.bin")
        FileManager.default.createFile(atPath: tooLarge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tooLarge)
        try handle.truncate(atOffset: UInt64(LocalChatAttachmentStorageService.maximumFileBytes + 1))
        try handle.close()
        let rejected: DroppedAttachmentResult = try await receive {
            _ = service.prepare([fileProvider(tooLarge)], progress: { _, _ in }, completion: $0)
        }
        precondition(rejected.attachments.isEmpty && rejected.failures.count == 1)
        do {
            let _: DroppedAttachmentResult = try await receive {
                _ = service.prepare(Array(repeating: fileProvider(fileURL), count: 51), progress: { _, _ in }, completion: $0)
            }
            preconditionFailure("Oversized drop batches must be rejected")
        } catch DroppedAttachmentError.tooManyItems {}
        let remaining = try managedPaths(directory)
        precondition(remaining.isEmpty)
    }

    @MainActor
    private static func checkCancellationAndTimeout(root: URL, imageData: Data) async throws {
        let directory = root.appendingPathComponent("cancel")
        let storage = LocalChatAttachmentStorageService(rootURL: directory)
        let service = DroppedAttachmentService(attachmentRepository: DefaultAttachmentRepository(storageService: storage), timeout: 0.5)
        let successfulProvider = DelayedDropImage()
        let successfulResult = LockedDropValue<Result<DroppedAttachmentResult, Error>?>(nil)
        _ = service.prepare([successfulProvider.provider], progress: { _, _ in }) { successfulResult.set($0) }
        try await waitUntil { successfulProvider.isRequested }
        successfulProvider.finish(imageData)
        try await waitUntil { successfulResult.value != nil }
        let successful = try successfulResult.value!.get()
        precondition(successful.attachments.count == 1 && successful.failures.isEmpty)
        precondition(!successfulProvider.progress.isCancelled, "Successful drops must not cancel their source provider")
        try storage.deleteManagedAttachment(successful.attachments[0])

        let pending = DelayedDropImage()
        let resultBox = LockedDropValue<Result<DroppedAttachmentResult, Error>?>(nil)
        let cancellation = service.prepare([imageProvider(imageData), pending.provider], progress: { _, _ in }) {
            resultBox.set($0)
        }
        try await waitUntil { pending.isRequested }
        let copied = try managedPaths(directory)
        precondition(copied.count == 1)
        cancellation.cancel()
        try await waitUntil { resultBox.value != nil }
        precondition(pending.progress.isCancelled)
        if case .failure(let error) = resultBox.value {
            precondition(error is DroppedAttachmentError)
        } else { preconditionFailure("Cancelled preparations must not return sendable attachments") }
        pending.finish(imageData)
        try await Task.sleep(for: .milliseconds(40))
        let afterCancellation = try managedPaths(directory)
        precondition(afterCancellation.isEmpty, "Cancellation must remove prepared copies and ignore late image data")

        let timeoutProvider = DelayedDropImage()
        let timeoutResult: DroppedAttachmentResult = try await receive {
            _ = service.prepare([timeoutProvider.provider, imageProvider(imageData)], progress: { _, _ in }, completion: $0)
        }
        precondition(timeoutResult.attachments.count == 1 && timeoutResult.failures.count == 1)
        precondition(timeoutProvider.progress.isCancelled)
        timeoutProvider.finish(imageData)
        try await Task.sleep(for: .milliseconds(40))
        let afterTimeout = try managedPaths(directory)
        precondition(afterTimeout.count == 1, "Timed-out providers must not prepare or send a second copy")
        try storage.deleteManagedAttachment(timeoutResult.attachments[0])
    }

    @MainActor
    private static func checkNativeEditor(root: URL, imageData: Data) async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let imageURL = root.appendingPathComponent("drag-source.png")
        try imageData.write(to: imageURL)
        let fileItem = NSPasteboardItem()
        fileItem.setString(imageURL.absoluteString, forType: .fileURL)
        fileItem.setData(imageData, forType: .png)
        let rawImage = NSPasteboardItem()
        rawImage.setData(imageData, forType: .png)
        pasteboard.writeObjects([fileItem, rawImage])
        precondition(ChatAttachmentDrop.containsAttachments(in: pasteboard))
        let providers = ChatAttachmentDrop.providers(from: pasteboard)
        precondition(providers.count == 2 && providers[0].hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        let editor = PasteAwareNSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        editor.string = "未发送的草稿"
        editor.allowsAttachmentDrop = true
        var targeted = false
        var acceptedCount = 0
        editor.onDropTargeted = { targeted = $0 }
        editor.onDropAttachments = { acceptedCount += $0.count; return true }
        let drag = DropDraggingInfo(pasteboard: pasteboard)
        precondition(editor.draggingEntered(drag) == .copy && targeted)
        precondition(editor.draggingUpdated(drag) == .copy)
        precondition(editor.prepareForDragOperation(drag))
        precondition(editor.performDragOperation(drag) && acceptedCount == 2 && !targeted)
        precondition(editor.string == "未发送的草稿", "Native text views must not insert file paths or images into the draft")
        editor.allowsAttachmentDrop = false
        precondition(editor.draggingEntered(drag).isEmpty)
        precondition(!editor.prepareForDragOperation(drag) && !editor.performDragOperation(drag))
        precondition(acceptedCount == 2)
        pasteboard.clearContents()
        pasteboard.setString("普通文本", forType: .string)
        precondition(!ChatAttachmentDrop.containsAttachments(in: pasteboard))
    }

    @MainActor
    private static func checkSending(root: URL, imageData: Data) async throws {
        let directory = root.appendingPathComponent("send")
        let service = SQLiteChatHistoryService(store: ChatHistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"),
                                                                      legacyURL: directory.appendingPathComponent("missing.json")))
        let transport = DropTestTransport()
        let repository = DefaultChatRepository(networkService: transport, historyService: service,
                                                attachmentStorageService: LocalChatAttachmentStorageService(rootURL: directory),
                                                notificationService: DropTestNotifications())
        let peer = makePeer("peer-a", address: "192.0.2.1")
        let otherPeer = makePeer("peer-b", address: "192.0.2.2")
        let group = ChatGroup(name: "拖拽测试群", memberIDs: [peer.id, otherPeer.id], ownerName: "我")
        service.savePeer(peer)
        service.savePeer(otherPeer)
        service.saveGroup(group)
        let model = ChatViewModel(repository: repository, settingsRepository: DropTestSettings())
        try await waitUntil { model.peers.count == 2 && model.groups.count == 1 && model.isRunning }
        model.selectPeer(peer.id)
        precondition(!model.sendDroppedAttachments([imageProvider(imageData)]), "Offline peers must not accept direct-send drops")
        transport.deliverPresence(peer, packetNumber: 1)
        transport.deliverPresence(otherPeer, packetNumber: 2)
        try await waitUntil { model.selectedPeer?.isOnline == true && model.peers.allSatisfy(\.isOnline) }
        model.draft = "不要自动发送这段文字"
        model.pasteImage(imageData, suggestedFileName: "draft.png")
        try await waitUntil { !model.isPreparingPastedImage }
        let draftAttachments = model.draftAttachments
        let fileURL = directory.appendingPathComponent("report.txt")
        try Data("文件正文".utf8).write(to: fileURL)
        let providers = (0..<11).map { imageProvider(imageData, name: "image-\($0).png") } + [fileProvider(fileURL)]
        precondition(model.sendDroppedAttachments(providers))
        precondition(!model.sendDroppedAttachments([fileProvider(fileURL)]), "Only one batch may prepare at a time")
        try await waitUntil { !model.isPreparingDrop }
        let messages = model.messages(for: peer.id)
        precondition(messages.count == 3 && messages.map { $0.attachments.count } == [9, 2, 1])
        precondition(messages.prefix(2).allSatisfy { $0.attachments.allSatisfy(\.isImage) })
        precondition(messages.allSatisfy { $0.direction == .outgoing && $0.text.isEmpty })
        precondition(model.draft == "不要自动发送这段文字" && model.draftAttachments == draftAttachments)
        try await waitUntil { transport.sent.value.count == 3 }
        precondition(transport.sent.value.allSatisfy { $0.address == peer.ipAddress })
        let stored: ChatHistoryPage = try await receive { service.loadRecentMessages(for: peer.id, limit: 60, completion: $0) }
        precondition(stored.messages.map(\.id) == messages.map(\.id), "Dropped sends must persist through the ordinary repository")

        let beforeCancellation = try managedPaths(directory)
        let pending = DelayedDropImage()
        precondition(model.sendDroppedAttachments([fileProvider(fileURL), pending.provider]))
        try await waitUntil { pending.isRequested }
        model.cancelDroppedAttachments()
        pending.finish(imageData)
        try await waitUntil { (try? managedPaths(directory)) == beforeCancellation }
        precondition(model.messages(for: peer.id).count == 3 && transport.sent.value.count == 3)

        let switching = DelayedDropImage()
        precondition(model.sendDroppedAttachments([switching.provider]))
        try await waitUntil { switching.isRequested }
        model.selectPeer(otherPeer.id)
        model.selectPeer(peer.id)
        switching.finish(imageData)
        try await waitUntil { !model.isLoadingMessages }
        try await Task.sleep(for: .milliseconds(40))
        precondition(!model.isPreparingDrop && transport.sent.value.count == 3, "A stale drop must not send after switching away and back")

        let offline = DelayedDropImage()
        precondition(model.sendDroppedAttachments([offline.provider]))
        try await waitUntil { offline.isRequested }
        transport.deliverPresence(peer, online: false, packetNumber: 3)
        try await waitUntil { model.selectedPeer?.isOnline == false }
        offline.finish(imageData)
        try await waitUntil { !model.isPreparingDrop && model.dropSendError != nil }
        try await waitUntil { (try? managedPaths(directory)) == beforeCancellation }
        precondition(transport.sent.value.count == 3)

        model.selectGroup(group.id)
        try await waitUntil { !model.isLoadingMessages }
        precondition(model.sendDroppedAttachments([imageProvider(imageData)]))
        try await waitUntil { !model.isPreparingDrop && transport.sent.value.count == 4 }
        precondition(transport.sent.value.last?.address == otherPeer.ipAddress, "Group drops only target online members")
        precondition(model.messages(for: group.id).count == 1)
        let mixed = [fileProvider(fileURL), fileProvider(directory)]
        precondition(model.sendDroppedAttachments(mixed))
        try await waitUntil { !model.isPreparingDrop && transport.sent.value.count == 5 }
        precondition(model.dropSendError?.contains("1 项未发送") == true)

        transport.deliverPresence(peer, packetNumber: 4)
        model.selectPeer(peer.id)
        try await waitUntil { !model.isLoadingMessages && model.selectedPeer?.isOnline == true }
        let moving = DelayedDropImage()
        precondition(model.sendDroppedAttachments([moving.provider]))
        try await waitUntil { moving.isRequested }
        let newAddress = "192.0.2.10"
        transport.deliverPresence(peer, address: newAddress, packetNumber: 5)
        try await waitUntil { model.selectedPeer?.ipAddress == newAddress }
        moving.finish(imageData)
        try await waitUntil { !model.isPreparingDrop && transport.sent.value.count == 6 }
        precondition(model.selectedPeer?.id == peer.id && model.peers.count == 2)
        precondition(model.messages(for: peer.id).count == 4, "Address changes must preserve the original dropped-message history")
        precondition(transport.sent.value.last?.address == newAddress, "A prepared drop must send to the peer's current address")

        let stopped = DelayedDropImage()
        precondition(model.sendDroppedAttachments([stopped.provider]))
        try await waitUntil { stopped.isRequested }
        model.stopNetwork()
        try await waitUntil { !model.isRunning && !model.isPreparingDrop }
        stopped.finish(imageData)
        try await Task.sleep(for: .milliseconds(40))
        precondition(transport.sent.value.count == 6 && !model.sendDroppedAttachments([fileProvider(fileURL)]))
    }

    private static func makeImage() -> Data {
        let context = CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 320,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func fileProvider(_ url: URL) -> NSItemProvider {
        let provider = NSItemProvider(item: url as NSURL, typeIdentifier: UTType.fileURL.identifier)
        provider.suggestedName = url.lastPathComponent
        return provider
    }

    private static func imageProvider(_ data: Data, name: String = "拖拽图片.png") -> NSItemProvider {
        let provider = NSItemProvider(item: data as NSData, typeIdentifier: UTType.png.identifier)
        provider.suggestedName = name
        return provider
    }

    private static func makePeer(_ identifier: String, address: String) -> FeiQPeer {
        FeiQPeer(id: identifier, name: identifier, hostName: "test", ipAddress: address, group: "", lastSeen: Date(), isOnline: true)
    }

    private static func managedPaths(_ root: URL) throws -> Set<String> {
        Set(try ["Images", "Files"].flatMap {
            try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent($0), includingPropertiesForKeys: nil).map(\.path)
        })
    }

    private static func receive<Value>(_ operation: (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in operation { continuation.resume(with: $0) } }
    }

    @MainActor
    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out waiting for drag-and-drop state")
    }
}

private final class LockedDropValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ value: Value) { lock.lock(); defer { lock.unlock() }; stored = value }
    func update(_ transform: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; transform(&stored) }
}

private final class DelayedDropImage {
    let provider = NSItemProvider()
    let progress = Progress(totalUnitCount: 1)
    private let callback = LockedDropValue<((Data?, Error?) -> Void)?>(nil)
    var isRequested: Bool { callback.value != nil }
    init() {
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { [callback, progress] completion in
            callback.set(completion)
            return progress
        }
    }
    func finish(_ data: Data) { callback.value?(data, nil); callback.set(nil) }
}

private final class DropTestTransport: FeiQNetworkServiceProtocol {
    struct Sent {
        let address: String
        let attachments: [ChatAttachment]
    }
    let sent = LockedDropValue<[Sent]>([])
    var onInlineImage: ((Data, String, Int, FeiQPacket, String) -> Void)?
    var onPacket: ((FeiQPacket, String, FeiQTransport, UInt16) -> Void)?
    var onLog: ((String) -> Void)?
    var onStateChange: ((Bool) -> Void)?
    func deliverPresence(_ peer: FeiQPeer, online: Bool = true, address: String? = nil, packetNumber: UInt64) {
        let packet = FeiQPacket(packetNumber: packetNumber, senderName: peer.name, senderHost: peer.hostName,
                                command: online ? .answerEntry : .broadcastExit, additionalText: peer.name)
        onPacket?(packet, address ?? peer.ipAddress, .udp, 2425)
    }
    func start(name: String, host: String, group: String) { onStateChange?(true) }
    func stop() { onStateChange?(false) }
    func updateIdentity(name: String, host: String, group: String) {}
    func announce() {}
    func replyToEntry(from ipAddress: String) {}
    func sendTyping(isTyping: Bool, to ipAddress: String) {}
    func sendShake(to ipAddress: String) {}
    func sendText(_ text: String, to ipAddress: String, recipientName: String?) { preconditionFailure("Drag sends must not send draft text") }
    func sendFileMessage(_ text: String, attachments: [ChatAttachment], to ipAddress: String, recipientName: String?) {
        sent.update { $0.append(Sent(address: ipAddress, attachments: attachments)) }
    }
    func acknowledge(_ packet: FeiQPacket, to ipAddress: String) {}
    func uploadFile(_ attachment: ChatAttachment, text: String, to ipAddress: String, recipientName: String?,
                    progress: @escaping (FileTransferProgress) -> Void, completion: @escaping (Result<Void, Error>) -> Void) -> FileTransferCancellation {
        sent.update { $0.append(Sent(address: ipAddress, attachments: [attachment])) }
        completion(.success(()))
        return FileTransferCancellation()
    }
    func downloadFile(_ attachment: FeiQFileAttachment, packetNumber: UInt64, from ipAddress: String,
                      to destinationURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(FeiQFileTransferError.fileNotFound))
    }
}

private final class DropTestNotifications: NotificationService {
    var onNotificationSelected: ((String) -> Void)?
    func requestAuthorization() {}
    func notifyIncomingMessage(from sender: String, text: String, conversationID: String) {}
}

private final class DropTestSettings: AppSettingsRepository {
    func load() -> AppSettings {
        AppSettings(identity: FeiQIdentity(nickname: "测试", hostName: "test", groupName: ""), chatLoadAnimationMode: .instant)
    }
    func save(_ settings: AppSettings) {}
}

private final class DropDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
