import Foundation

protocol ChatRepository: AnyObject {
    var onEvent: ((ChatRepositoryEvent) -> Void)? { get set }
    var historyLocationDescription: String { get }
    var fileTransferCenter: FileTransferCenter { get }

    func loadConversationImages(
        for conversationID: String,
        completion: @escaping (Result<[ChatHistoryImage], Error>) -> Void
    )

    func start(identity: FeiQIdentity)
    func stop()
    func updateIdentity(_ identity: FeiQIdentity)
    func announce()
    func updateTyping(isTyping: Bool, for peer: FeiQPeer)
    func sendShake(to peer: FeiQPeer)
    func sendMessage(
        _ message: ChatMessage,
        to peer: FeiQPeer,
        unreadCount: Int
    )
    func sendGroupMessage(
        _ message: ChatMessage,
        to group: ChatGroup,
        members: [FeiQPeer]
    )
    func sendImage(
        from fileURL: URL,
        to peer: FeiQPeer,
        unreadCount: Int,
        completion: @escaping (Result<ChatMessage, Error>) -> Void
    )
    func preparePastedImage(
        data: Data,
        suggestedFileName: String?,
        completion: @escaping (Result<ChatAttachment, Error>) -> Void
    )
    func prepareOutgoingImage(
        from fileURL: URL,
        completion: @escaping (Result<ChatAttachment, Error>) -> Void
    )
    func captureScreenshot(
        completion: @escaping (Result<Data, Error>) -> Void
    )
    func prepareOutgoingFile(
        from fileURL: URL,
        completion: @escaping (Result<ChatAttachment, Error>) -> Void
    )
    func sendFile(
        from fileURL: URL,
        to peer: FeiQPeer,
        unreadCount: Int,
        completion: @escaping (Result<ChatMessage, Error>) -> Void
    )
    func sendGroupImage(
        from fileURL: URL,
        to group: ChatGroup,
        members: [FeiQPeer],
        completion: @escaping (Result<ChatMessage, Error>) -> Void
    )
    func sendGroupFile(
        from fileURL: URL,
        to group: ChatGroup,
        members: [FeiQPeer],
        completion: @escaping (Result<ChatMessage, Error>) -> Void
    )
    func persistMessage(
        _ message: ChatMessage,
        for peer: FeiQPeer,
        unreadCount: Int
    )
    func persistGroupMessage(
        _ message: ChatMessage,
        for group: ChatGroup,
        unreadCount: Int
    )
    func notifyIncomingMessage(
        text: String,
        from sender: String,
        conversationID: String
    )
    func refreshDiscovery()
    func setUnreadCount(_ count: Int, for peerID: String)
    func savePeer(_ peer: FeiQPeer)
    func saveGroup(_ group: ChatGroup)
    func deleteGroup(_ groupID: String)
    func deleteImage(
        attachmentID: String, messageID: UUID, conversationID: String,
        completion: @escaping (Result<ChatMessage, Error>) -> Void
    )
    func deleteMessage(
        _ message: ChatMessage,
        conversationID: String,
        completion: @escaping (Result<Void, Error>) -> Void
    )
    func deleteDraftImage(_ attachment: ChatAttachment, completion: @escaping (Result<Void, Error>) -> Void)
    func restorePeers(_ peers: [FeiQPeer])
    func restoreGroups(_ groups: [ChatGroup])
    func markOfflinePeers(before cutoff: Date)

    func loadSnapshot(
        completion: @escaping (Result<ChatHistorySnapshot, Error>) -> Void
    )
    func loadRecentMessages(
        for peerID: String,
        limit: Int,
        completion: @escaping (Result<ChatHistoryPage, Error>) -> Void
    )
    func loadEarlierMessages(
        for peerID: String,
        before message: ChatMessage,
        limit: Int,
        completion: @escaping (Result<ChatHistoryPage, Error>) -> Void
    )
    func loadReceivedFiles(
        for peerID: String,
        limit: Int,
        completion: @escaping (Result<[ChatReceivedFile], Error>) -> Void
    )
}

final class DefaultChatRepository: ChatRepository {
    let fileTransferCenter = FileTransferCenter()
    private let eventSource: FeiQNetworkEventSource
    private let discoveryService: DiscoveryService
    private let messageTransportService: MessageTransportService
    private let fileTransferService: FileTransferService
    private let inlineImageService: InlineImageService
    private let groupProtocolService: GroupProtocolService
    private let messageRepository: MessageRepository
    private let attachmentRepository: AttachmentRepository
    private let groupRepository: GroupRepository
    private let sessionRepository: SessionRepository
    private let notificationRepository: NotificationRepository
    private let screenshotService: ScreenshotCaptureService
    private let attachmentQueue = DispatchQueue(
        label: "com.feiqmac.chat-repository-attachments",
        qos: .utility
    )

    // Accessed only on attachmentQueue, like other received packet state.
    private var lastReceivedShakes: [String: Date] = [:]
    // FeiQ retries the private 0xB0 request when no response is observed.
    // Keep the UI from presenting the same request repeatedly.
    private var recentRemoteAssistanceRequests: [String: Date] = [:]
    // Owned by attachmentQueue. Marker and image packets can arrive in either order.
    private struct PendingInlineMessage {
        let id: UUID
        let peer: FeiQPeer
        let text: String
        let recipient: String
        var imageIDs: [String]
        let date: Date
        var timedOut = false
        var attachments: [String: ChatAttachment] = [:]
        var failedImageIDs: Set<String> = []
    }
    private var pendingInlineMessages: [String: PendingInlineMessage] = [:]
    private var receivedInlineImages: [String: (attachment: ChatAttachment, date: Date)] = [:]
    private var receivedMessagePackets: [String: Date] = [:]
    private var deletedFileMessageIDs: Set<UUID> = []
    private final class PendingFileMessage {
        let message: ChatMessage
        let peer: FeiQPeer
        let failureUnit: String
        let groups: [(group: ChatGroup, messageID: UUID)]
        var pending: Set<Int>
        var failed: Set<Int> = []
        var cancelled: Set<Int> = []
        var attachments: [Int: ChatAttachment] = [:]
        var hasRelayedText = false

        init(message: ChatMessage, peer: FeiQPeer, count: Int, failureUnit: String, groups: [ChatGroup]) {
            self.message = message
            self.peer = peer
            self.failureUnit = failureUnit
            self.groups = groups.map { ($0, UUID()) }
            self.pending = Set(0..<count)
        }
    }
    private let inlineImageTimeout: TimeInterval
    private let inlineImageRetention: TimeInterval

    var onEvent: ((ChatRepositoryEvent) -> Void)?

    var historyLocationDescription: String {
        messageRepository.locationDescription
    }

    convenience init(
        networkService: FeiQNetworkServiceProtocol,
        historyService: ChatHistoryService,
        attachmentStorageService: ChatAttachmentStorageService,
        notificationService: NotificationService,
        screenshotService: ScreenshotCaptureService = MacScreenshotCaptureService(),
        inlineImageTimeout: TimeInterval = 90,
        inlineImageRetention: TimeInterval = 600
    ) {
        self.init(
            eventSource: networkService,
            discoveryService: DefaultDiscoveryService(networkService: networkService),
            messageTransportService: DefaultMessageTransportService(networkService: networkService),
            fileTransferService: DefaultFileTransferService(networkService: networkService),
            inlineImageService: DefaultInlineImageService(networkService: networkService),
            groupProtocolService: DefaultGroupProtocolService(),
            messageRepository: DefaultMessageRepository(historyService: historyService),
            attachmentRepository: DefaultAttachmentRepository(storageService: attachmentStorageService),
            groupRepository: DefaultGroupRepository(historyService: historyService),
            sessionRepository: DefaultSessionRepository(historyService: historyService),
            notificationRepository: DefaultNotificationRepository(notificationService: notificationService),
            screenshotService: screenshotService,
            inlineImageTimeout: inlineImageTimeout,
            inlineImageRetention: inlineImageRetention
        )
    }

    init(
        eventSource: FeiQNetworkEventSource,
        discoveryService: DiscoveryService,
        messageTransportService: MessageTransportService,
        fileTransferService: FileTransferService,
        inlineImageService: InlineImageService,
        groupProtocolService: GroupProtocolService,
        messageRepository: MessageRepository,
        attachmentRepository: AttachmentRepository,
        groupRepository: GroupRepository,
        sessionRepository: SessionRepository,
        notificationRepository: NotificationRepository,
        screenshotService: ScreenshotCaptureService = MacScreenshotCaptureService(),
        inlineImageTimeout: TimeInterval = 90,
        inlineImageRetention: TimeInterval = 600
    ) {
        precondition(inlineImageTimeout > 0 && inlineImageRetention > inlineImageTimeout)
        self.inlineImageTimeout = inlineImageTimeout
        self.inlineImageRetention = inlineImageRetention
        self.eventSource = eventSource
        self.discoveryService = discoveryService
        self.messageTransportService = messageTransportService
        self.fileTransferService = fileTransferService
        self.inlineImageService = inlineImageService
        self.groupProtocolService = groupProtocolService
        self.messageRepository = messageRepository
        self.attachmentRepository = attachmentRepository
        self.groupRepository = groupRepository
        self.sessionRepository = sessionRepository
        self.notificationRepository = notificationRepository
        self.screenshotService = screenshotService

        eventSource.onPacket = { [weak self] packet, ipAddress, transport, sourcePort in
            self?.attachmentQueue.async { [weak self] in
                self?.handle(
                    packet: packet,
                    from: ipAddress,
                    transport: transport,
                    sourcePort: sourcePort
                )
            }
        }
        eventSource.onInlineImage = { [weak self] bytes, imageID, bitmapFlag, packet, ipAddress in
            self?.attachmentQueue.async { [weak self] in
                guard let self else { return }
                do {
                    let attachment = try self.attachmentRepository.saveInlineImage(
                        bytes,
                        imageID: imageID,
                        isBitmap: bitmapFlag == 1
                    )
                    self.receivedInlineImages = self.receivedInlineImages.filter { Date().timeIntervalSince($0.value.date) < 600 }
                    if self.receivedInlineImages.count >= 256,
                       let oldest = self.receivedInlineImages.min(by: { $0.value.date < $1.value.date })?.key {
                        self.receivedInlineImages.removeValue(forKey: oldest)
                    }
                    self.receivedInlineImages[ipAddress + "/" + imageID] = (attachment, Date())
                    for key in Array(self.pendingInlineMessages.keys) { self.finishInlineMessage(key) }
                } catch {
                    self.emit(.log("内嵌图片 \(imageID) 解码失败：\(error.localizedDescription)"))
                    for key in Array(self.pendingInlineMessages.keys) {
                        guard self.pendingInlineMessages[key]?.peer.ipAddress == ipAddress,
                              self.pendingInlineMessages[key]?.imageIDs.contains(imageID) == true else { continue }
                        self.pendingInlineMessages[key]?.failedImageIDs.insert(imageID)
                        self.finishInlineMessage(key)
                    }
                }
            }
        }
        eventSource.onLog = { [weak self] message in
            self?.emit(.log(message))
        }
        eventSource.onStateChange = { [weak self] running in
            self?.emit(.networkStateChanged(running))
        }
        notificationRepository.onNotificationSelected = { [weak self] peerID in
            self?.emit(.notificationSelected(conversationID: peerID))
        }
        fileTransferCenter.observe { [weak self] snapshot in
            self?.emit(.fileTransfersChanged(snapshot))
        }
    }

    func start(identity: FeiQIdentity) {
        updateIdentity(identity)
        discoveryService.start(identity: identity)
        fileTransferCenter.setPaused(false)
    }

    func stop() {
        fileTransferCenter.cancelAll(pauseQueue: true)
        discoveryService.stop()
    }

    func updateIdentity(_ identity: FeiQIdentity) {
        sessionRepository.updateIdentity(identity)
        discoveryService.updateIdentity(identity)
    }

    func announce() {
        discoveryService.announce()
    }

    func refreshDiscovery() {
        announce()
    }

    func sendShake(to peer: FeiQPeer) {
        guard peer.isOnline else { return }
        messageTransportService.sendShake(to: peer.ipAddress)
    }

    func updateTyping(isTyping: Bool, for peer: FeiQPeer) {
        let address = peer.ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return }
        messageTransportService.sendTyping(isTyping: isTyping, to: address)
    }

    /// Routes outgoing content to the smallest network capability that can
    /// represent it. The repository decides the business type; the services
    /// only perform the corresponding transport operation.
    private func sendContent(
        text: String,
        attachments: [ChatAttachment],
        to ipAddress: String,
        recipientName: String?,
        messageID: UUID? = nil
    ) {
        let wireText = FeiQMessageFormatter.wireText(text)
        if attachments.isEmpty {
            messageTransportService.sendText(
                wireText,
                to: ipAddress,
                recipientName: recipientName
            )
        } else if attachments.allSatisfy(\.isImage) {
            inlineImageService.send(
                wireText,
                images: attachments,
                to: ipAddress,
                recipientName: recipientName
            )
        } else {
            for (index, attachment) in attachments.enumerated() {
                let attachmentText: String
                if index == 0 {
                    attachmentText = wireText
                } else if let relay = groupProtocolService.parseRelayText(wireText) {
                    attachmentText = groupProtocolService.makeRelayText(
                        groupName: relay.groupName, senderName: relay.senderName, text: ""
                    )
                } else {
                    attachmentText = ""
                }
                fileTransferCenter.enqueue(
                    attachment: attachment, direction: .outgoing,
                    peerName: recipientName ?? ipAddress, ipAddress: ipAddress, messageID: messageID
                ) { [fileTransferService] progress, completion in
                    fileTransferService.send(
                        attachment, text: attachmentText, to: ipAddress,
                        recipientName: recipientName, progress: progress, completion: completion
                    )
                }
            }
        }
    }

    func sendMessage(
        _ message: ChatMessage,
        to peer: FeiQPeer,
        unreadCount: Int
    ) {
        persistMessage(message, for: peer, unreadCount: unreadCount)
        sendContent(
            text: message.text,
            attachments: message.attachments,
            to: peer.ipAddress,
            recipientName: peer.displayName,
            messageID: message.id
        )
    }

    func sendGroupMessage(
        _ message: ChatMessage,
        to group: ChatGroup,
        members: [FeiQPeer]
    ) {
        persistGroupMessage(
            message,
            for: group,
            unreadCount: 0
        )

        let localNickname = sessionRepository.identity.nickname
        let relayText = groupProtocolService.makeRelayText(
            groupName: group.displayName,
            senderName: localNickname,
            text: message.text
        )
        var sentCount = 0
        var sentAddresses = Set<String>()
        for member in members where member.isOnline {
            let address = member.ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty, sentAddresses.insert(address).inserted else {
                continue
            }
            sendContent(
                text: relayText,
                attachments: message.attachments,
                to: address,
                recipientName: member.displayName + " · " + group.displayName,
                messageID: message.id
            )
            sentCount += 1
        }

        if sentCount == 0 {
            emit(.log("群聊「" + group.displayName + "」没有在线成员，未发送消息"))
        } else {
            emit(.log("群聊「" + group.displayName + "」已通过 Mac 中继发送给 " + String(sentCount) + " 位成员"))
        }
    }

    func sendImage(
        from fileURL: URL,
        to peer: FeiQPeer,
        unreadCount: Int,
        completion: @escaping (Result<ChatMessage, Error>) -> Void
    ) {
        attachmentQueue.async { [self] in
            do {
                let attachment = try attachmentRepository.prepareOutgoingImage(from: fileURL)
                let localNickname = sessionRepository.identity.nickname
                let message = ChatMessage(
                    direction: .outgoing,
                    text: "",
                    senderName: localNickname,
                    recipientName: peer.displayName,
                    attachments: [attachment]
                )
                persistMessage(message, for: peer, unreadCount: unreadCount)
                sendContent(
                    text: "",
                    attachments: [attachment],
                    to: peer.ipAddress,
                    recipientName: peer.displayName
                )
                completion(.success(message))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func prepareOutgoingImage(
        from fileURL: URL,
        completion: @escaping (Result<ChatAttachment, Error>) -> Void
    ) {
        attachmentQueue.async { [attachmentRepository] in
            completion(Result { try attachmentRepository.prepareOutgoingImage(from: fileURL) })
        }
    }

    func deleteImage(
        attachmentID: String, messageID: UUID, conversationID: String,
        completion: @escaping (Result<ChatMessage, Error>) -> Void
    ) {
        messageRepository.removeImage(
            attachmentID: attachmentID, messageID: messageID, conversationID: conversationID,
            deleteUnreferencedFile: { [attachmentRepository] attachment in
                try attachmentRepository.deleteManagedImage(attachment)
            }
        ) { [weak self] result in
            guard let self else { return }
            self.attachmentQueue.async {
                if case .success = result {
                    for key in Array(self.pendingInlineMessages.keys) {
                        guard self.pendingInlineMessages[key]?.id == messageID else { continue }
                        self.pendingInlineMessages[key]?.imageIDs.removeAll { $0 == attachmentID }
                        self.pendingInlineMessages[key]?.attachments.removeValue(forKey: attachmentID)
                    }
                }
                completion(result)
            }
        }
    }

    func deleteDraftImage(_ attachment: ChatAttachment, completion: @escaping (Result<Void, Error>) -> Void) {
        attachmentQueue.async { [attachmentRepository] in
            completion(Result { try attachmentRepository.deleteManagedImage(attachment) })
        }
    }

    func deleteMessage(
        _ message: ChatMessage,
        conversationID: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        messageRepository.deleteMessage(
            id: message.id,
            conversationID: conversationID
        ) { [weak self] result in
            guard let self else { return }
            self.attachmentQueue.async {
                switch result {
                case .success(let attachments):
                    self.deletedFileMessageIDs.insert(message.id)
                    self.fileTransferCenter.cancelTransfers(for: message.id)
                    for attachment in attachments {
                        do {
                            try self.attachmentRepository.deleteManagedAttachment(attachment)
                        } catch {
                            self.emit(.log("删除消息附件失败：\(attachment.fileName) · \(error.localizedDescription)"))
                        }
                    }
                    completion(.success(()))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    func prepareOutgoingFile(
        from fileURL: URL,
        completion: @escaping (Result<ChatAttachment, Error>) -> Void
    ) {
        attachmentQueue.async { [self] in
            do {
                completion(.success(try attachmentRepository.prepareOutgoingFile(from: fileURL)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func sendFile(
        from fileURL: URL,
        to peer: FeiQPeer,
        unreadCount: Int,
        completion: @escaping (Result<ChatMessage, Error>) -> Void
    ) {
        attachmentQueue.async { [self] in
            do {
                let attachment = try attachmentRepository.prepareOutgoingFile(from: fileURL)
                let localNickname = sessionRepository.identity.nickname
                let message = ChatMessage(
                    direction: .outgoing,
                    text: "",
                    senderName: localNickname,
                    recipientName: peer.displayName,
                    attachments: [attachment]
                )
                persistMessage(message, for: peer, unreadCount: unreadCount)
                sendContent(
                    text: "",
                    attachments: [attachment],
                    to: peer.ipAddress,
                    recipientName: peer.displayName
                )
                completion(.success(message))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func preparePastedImage(
        data: Data,
        suggestedFileName: String?,
        completion: @escaping (Result<ChatAttachment, Error>) -> Void
    ) {
        attachmentQueue.async { [self] in
            do {
                completion(.success(try attachmentRepository.prepareOutgoingImage(
                    from: data,
                    suggestedFileName: suggestedFileName
                )))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func captureScreenshot(
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        screenshotService.captureInteractive(completion: completion)
    }

    func sendGroupImage(
        from fileURL: URL,
        to group: ChatGroup,
        members: [FeiQPeer],
        completion: @escaping (Result<ChatMessage, Error>) -> Void
    ) {
        attachmentQueue.async { [self] in
            do {
                let attachment = try attachmentRepository.prepareOutgoingImage(from: fileURL)
                let localNickname = sessionRepository.identity.nickname
                let message = ChatMessage(
                    direction: .outgoing,
                    text: "",
                    senderName: localNickname,
                    recipientName: group.displayName,
                    attachments: [attachment]
                )
                persistGroupMessage(message, for: group, unreadCount: 0)

                let relayText = groupProtocolService.makeRelayText(
                    groupName: group.displayName,
                    senderName: localNickname,
                    text: ""
                )
                var sentCount = 0
                var sentAddresses = Set<String>()
                for member in members where member.isOnline {
                    let address = member.ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !address.isEmpty, sentAddresses.insert(address).inserted else {
                        continue
                    }
                    sendContent(
                        text: relayText,
                        attachments: [attachment],
                        to: address,
                        recipientName: group.displayName
                    )
                    sentCount += 1
                }

                if sentCount == 0 {
                    emit(.log("群聊「" + group.displayName + "」没有在线成员，图片未发送"))
                } else {
                    emit(.log("群聊「" + group.displayName + "」已通过 Mac 中继发送图片给 " + String(sentCount) + " 位成员"))
                }
                completion(.success(message))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func sendGroupFile(
        from fileURL: URL,
        to group: ChatGroup,
        members: [FeiQPeer],
        completion: @escaping (Result<ChatMessage, Error>) -> Void
    ) {
        attachmentQueue.async { [self] in
            do {
                let attachment = try attachmentRepository.prepareOutgoingFile(from: fileURL)
                let localNickname = sessionRepository.identity.nickname
                let message = ChatMessage(
                    direction: .outgoing,
                    text: "",
                    senderName: localNickname,
                    recipientName: group.displayName,
                    attachments: [attachment]
                )
                persistGroupMessage(message, for: group, unreadCount: 0)

                let relayText = groupProtocolService.makeRelayText(
                    groupName: group.displayName,
                    senderName: localNickname,
                    text: ""
                )
                var sentCount = 0
                var sentAddresses = Set<String>()
                for member in members where member.isOnline {
                    let address = member.ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !address.isEmpty, sentAddresses.insert(address).inserted else {
                        continue
                    }
                    sendContent(
                        text: relayText,
                        attachments: [attachment],
                        to: address,
                        recipientName: group.displayName
                    )
                    sentCount += 1
                }

                if sentCount == 0 {
                    emit(.log("群聊「" + group.displayName + "」没有在线成员，文件未发送"))
                } else {
                    emit(.log("群聊「" + group.displayName + "」已通过 Mac 中继发送文件给 " + String(sentCount) + " 位成员"))
                }
                completion(.success(message))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func persistMessage(
        _ message: ChatMessage,
        for peer: FeiQPeer,
        unreadCount: Int
    ) {
        messageRepository.saveMessage(
            message,
            for: peer,
            unreadCount: unreadCount
        )
    }

    func persistGroupMessage(
        _ message: ChatMessage,
        for group: ChatGroup,
        unreadCount: Int
    ) {
        messageRepository.saveMessage(
            message,
            for: group,
            unreadCount: unreadCount
        )
    }

    func notifyIncomingMessage(
        text: String,
        from sender: String,
        conversationID: String
    ) {
        notificationRepository.notifyIncomingMessage(
            text: text,
            from: sender,
            conversationID: conversationID
        )
    }

    func setUnreadCount(_ count: Int, for peerID: String) {
        messageRepository.setUnreadCount(count, for: peerID)
    }

    func savePeer(_ peer: FeiQPeer) {
        sessionRepository.savePeer(peer)
    }

    func saveGroup(_ group: ChatGroup) {
        groupRepository.save(group)
    }

    func deleteGroup(_ groupID: String) {
        groupRepository.delete(groupID: groupID)
    }

    func restorePeers(_ peers: [FeiQPeer]) {
        sessionRepository.restore(peers)
    }

    func restoreGroups(_ groups: [ChatGroup]) {
        groupRepository.restore(groups)
    }

    func markOfflinePeers(before cutoff: Date) {
        let changedPeers = sessionRepository.markOffline(before: cutoff)

        for peer in changedPeers {
            emit(.peerUpdated(peer))
        }
    }

    func loadSnapshot(
        completion: @escaping (Result<ChatHistorySnapshot, Error>) -> Void
    ) {
        messageRepository.loadSnapshot(completion: completion)
    }

    func loadRecentMessages(
        for peerID: String,
        limit: Int,
        completion: @escaping (Result<ChatHistoryPage, Error>) -> Void
    ) {
        messageRepository.loadRecentMessages(
            for: peerID,
            limit: limit,
            completion: completion
        )
    }

    func loadEarlierMessages(
        for peerID: String,
        before message: ChatMessage,
        limit: Int,
        completion: @escaping (Result<ChatHistoryPage, Error>) -> Void
    ) {
        messageRepository.loadEarlierMessages(
            for: peerID,
            before: message,
            limit: limit,
            completion: completion
        )
    }

    func loadConversationImages(
        for conversationID: String,
        completion: @escaping (Result<[ChatHistoryImage], Error>) -> Void
    ) {
        messageRepository.loadConversationImages(for: conversationID, completion: completion)
    }

    func loadReceivedFiles(
        for peerID: String,
        limit: Int,
        completion: @escaping (Result<[ChatReceivedFile], Error>) -> Void
    ) {
        messageRepository.loadReceivedFiles(
            for: peerID,
            limit: limit,
            completion: completion
        )
    }

    private func handle(
        packet: FeiQPacket,
        from ipAddress: String,
        transport: FeiQTransport,
        sourcePort: UInt16
    ) {
        let currentIdentity = sessionRepository.identity

        // A broadcast may be delivered back to its sender on some adapters.
        if packet.senderName == currentIdentity.nickname,
           packet.senderHost == currentIdentity.hostName {
            return
        }

        if packet.isFeiQPresencePacket {
            let peer = sessionRepository.upsertPeer(packet: packet, ipAddress: ipAddress)
            emit(.peerUpdated(peer))
            if packet.isFeiQEntryRequest {
                discoveryService.replyToEntry(from: ipAddress)
            }
            return
        }

        switch packet.commandType {
        case .remoteAssistanceRequest:
            guard transport == .udp else { return }
            let now = Date()
            recentRemoteAssistanceRequests = recentRemoteAssistanceRequests.filter {
                now.timeIntervalSince($0.value) < 15
            }
            let requestKey = [
                ipAddress,
                packet.senderName,
                packet.senderHost,
                packet.additionalData.base64EncodedString()
            ].joined(separator: "/")
            guard recentRemoteAssistanceRequests[requestKey] == nil else { return }
            recentRemoteAssistanceRequests[requestKey] = now

            let peer = sessionRepository.upsertPeer(packet: packet, ipAddress: ipAddress)
            emit(.peerUpdated(peer))
            emit(.remoteAssistanceRequested(FeiQRemoteAssistanceRequest(
                id: requestKey,
                peer: peer,
                packetNumber: packet.packetNumber,
                versionIdentifier: packet.versionIdentifier,
                payload: packet.additionalText,
                receivedAt: now
            )))

        case .shake:
            guard transport == .udp else { return }
            let now = Date()
            lastReceivedShakes = lastReceivedShakes.filter { now.timeIntervalSince($0.value) < 3 }
            guard lastReceivedShakes[ipAddress] == nil else { return }
            lastReceivedShakes[ipAddress] = now
            let peer = sessionRepository.upsertPeer(packet: packet, ipAddress: ipAddress)
            emit(.peerUpdated(peer))
            emit(.peerShook(peer))

        case .shakeAcknowledgement:
            emit(.log("来自 \(ipAddress) 的抖一抖已确认"))

        case .inputting, .inputEnd:
            let peer = sessionRepository.upsertPeer(packet: packet, ipAddress: ipAddress)
            emit(.peerUpdated(peer))
            emit(.peerTyping(
                peer: peer,
                isTyping: packet.commandType == .inputting
            ))

        case .broadcastEntry:
            let peer = sessionRepository.upsertPeer(packet: packet, ipAddress: ipAddress)
            emit(.peerUpdated(peer))
            discoveryService.replyToEntry(from: ipAddress)

        case .answerEntry, .answerList, .sendInfo:
            let peer = sessionRepository.upsertPeer(packet: packet, ipAddress: ipAddress)
            emit(.peerUpdated(peer))

        case .broadcastExit:
            if let peer = sessionRepository.markPeerOffline(ipAddress: ipAddress) {
                emit(.peerUpdated(peer))
            }

        case .sendMessage:
            let peer = sessionRepository.upsertPeer(packet: packet, ipAddress: ipAddress)
            emit(.peerUpdated(peer))

            // Acknowledge the wire packet first, even if it contains only
            // formatting metadata, so the Windows sender does not report a
            // delivery failure.
            let text = FeiQMessageFormatter.displayText(packet.additionalText)
            messageTransportService.acknowledge(packet, to: ipAddress)
            let packetKey = ipAddress + "/" + String(packet.packetNumber)
            guard receivedMessagePackets[packetKey] == nil else { return }
            receivedMessagePackets = receivedMessagePackets.filter { Date().timeIntervalSince($0.value) < 180 }
            if receivedMessagePackets.count >= 512,
               let oldest = receivedMessagePackets.min(by: { $0.value < $1.value })?.key {
                receivedMessagePackets.removeValue(forKey: oldest)
            }
            receivedMessagePackets[packetKey] = Date()
            let imageIDs = FeiQInlineImageCodec.imageIDs(in: packet.additionalText)
            if !imageIDs.isEmpty {
                guard pendingInlineMessages.count < 128 else {
                    emit(.log("待接收图片消息过多，请稍后重试"))
                    emit(.messageReceived(message: ChatMessage(
                        direction: .incoming, text: text + "\n[图片接收队列已满，请对方稍后重发]",
                        senderName: peer.displayName, recipientName: currentIdentity.nickname
                    ), peer: peer))
                    return
                }
                let messageID = UUID()
                let pending = PendingInlineMessage(
                    id: messageID,
                    peer: peer,
                    text: FeiQMessageFormatter.displayText(FeiQInlineImageCodec.replacingMarkers(in: packet.additionalText, with: "")),
                    recipient: currentIdentity.nickname, imageIDs: imageIDs, date: Date())
                pendingInlineMessages[packetKey] = pending
                emit(.messageReceived(message: ChatMessage(
                    id: messageID, direction: .incoming,
                    text: pending.text + (pending.text.isEmpty ? "" : "\n") + "[图片尚未接收完成]",
                    senderName: peer.displayName, recipientName: pending.recipient, date: pending.date
                ), peer: peer))
                finishInlineMessage(packetKey)
                attachmentQueue.asyncAfter(deadline: .now() + inlineImageTimeout) { [weak self] in
                    guard let self, self.pendingInlineMessages[packetKey]?.id == messageID else { return }
                    self.finishInlineMessage(packetKey, timedOut: true)
                }
                // Retain correlation after the soft timeout so a slow Windows
                // resend can still replace the same persisted placeholder.
                attachmentQueue.asyncAfter(deadline: .now() + inlineImageRetention) { [weak self] in
                    guard let self, self.pendingInlineMessages[packetKey]?.id == messageID else { return }
                    self.finishInlineMessage(packetKey, timedOut: true, expired: true)
                    self.pendingInlineMessages.removeValue(forKey: packetKey)
                }
                return
            }
            let remoteAttachments = packet.fileAttachments
            guard !text.isEmpty || !remoteAttachments.isEmpty else {
                if packet.hasFileAttachments {
                    emit(.log("收到文件附件，但附件清单为空或格式无效"))
                }
                return
            }

            if remoteAttachments.isEmpty {
                let incomingMessage = ChatMessage(
                    direction: .incoming,
                    text: text,
                    senderName: peer.displayName,
                    recipientName: currentIdentity.nickname
                )
                deliverIncomingMessage(incomingMessage, from: peer)
                return
            }

            downloadIncomingFiles(
                remoteAttachments,
                packetNumber: packet.packetNumber,
                from: peer,
                port: sourcePort,
                text: text,
                recipientName: currentIdentity.nickname
            )

        case .receiveMessage, .readMessage, .deleteMessage, .answerReadMessage,
             .broadcastAbsence, .broadcastNotify, .broadcastIsGetList,
             .okGetList, .getList, .getInfo, .getFileData,
             .releaseFiles, .getDirectoryFiles, .legacyInlineImage,
             .legacyInlineImageAcknowledgement, .inlineImage,
             .inlineImageAcknowledgement, nil:
            break
        }

        _ = transport
    }

    private func downloadIncomingFiles(
        _ remoteAttachments: [FeiQFileAttachment],
        packetNumber: UInt64,
        from peer: FeiQPeer,
        port: UInt16,
        text: String,
        recipientName: String
    ) {
        let relay = groupProtocolService.parseRelayText(text)
        let groups = groupRepository.groups(containing: peer.id).filter {
            relay == nil || relay?.groupName == $0.displayName
        }
        let pending = PendingFileMessage(
            message: ChatMessage(direction: .incoming, text: text, senderName: peer.displayName,
                                 recipientName: recipientName),
            peer: peer, count: remoteAttachments.count,
            failureUnit: remoteAttachments.allSatisfy(\.isImage) ? "张图片" : "个文件", groups: groups
        )
        publishFileMessage(pending, isNew: true)
        for (index, remote) in remoteAttachments.enumerated() {
            do {
                guard remote.isRegularFile else { throw ChatAttachmentStorageError.unsupportedFile }
                let local = try remote.isImage
                    ? attachmentRepository.prepareIncomingImage(for: remote)
                    : attachmentRepository.prepareIncomingFile(for: remote)
                fileTransferCenter.enqueue(
                    attachment: local, direction: .incoming, peerName: peer.displayName,
                    ipAddress: peer.ipAddress, messageID: pending.message.id,
                    operation: { [weak self, fileTransferService] progress, completion in
                        self?.attachmentQueue.async { [weak self] in
                            guard let self, !self.deletedFileMessageIDs.contains(pending.message.id) else { return }
                            pending.pending.insert(index)
                            pending.failed.remove(index)
                            pending.cancelled.remove(index)
                            self.publishFileMessage(pending)
                        }
                        return fileTransferService.download(
                            remote, packetNumber: packetNumber, from: peer.ipAddress, port: port,
                            to: local.localURL, progress: progress, completion: completion
                        )
                    }, completion: { [weak self] result in
                        self?.attachmentQueue.async { [weak self] in
                            guard let self else { return }
                            guard !self.deletedFileMessageIDs.contains(pending.message.id) else {
                                if case .success = result {
                                    try? self.attachmentRepository.deleteManagedAttachment(local)
                                }
                                return
                            }
                            pending.pending.remove(index)
                            pending.failed.remove(index)
                            pending.cancelled.remove(index)
                            switch result {
                            case .success:
                                pending.attachments[index] = local
                            case .failure(let error):
                                if (error as? FeiQFileTransferError) == .cancelled {
                                    pending.cancelled.insert(index)
                                } else {
                                    pending.failed.insert(index)
                                }
                                self.emit(.log("文件接收未完成：\(remote.fileName) · \(error.localizedDescription)"))
                            }
                            self.publishFileMessage(pending)
                            if case .success = result, relay == nil {
                                for groupEntry in pending.groups where !self.deletedFileMessageIDs.contains(groupEntry.messageID) {
                                    let message = ChatMessage(
                                        id: groupEntry.messageID, direction: .incoming,
                                        text: pending.hasRelayedText ? "" : pending.message.text,
                                        senderName: peer.displayName, recipientName: groupEntry.group.displayName,
                                        attachments: [local]
                                    )
                                    self.relayIncomingGroupMessage(
                                        message, from: peer, group: groupEntry.group,
                                        members: self.sessionRepository.peers(withIDs: groupEntry.group.memberIDs)
                                    )
                                }
                                pending.hasRelayedText = true
                            }
                        }
                    }
                )
            } catch {
                pending.pending.remove(index)
                pending.failed.insert(index)
                emit(.log("附件准备失败 \(remote.fileName)：\(error.localizedDescription)"))
            }
        }
        publishFileMessage(pending)
    }

    private func publishFileMessage(_ pending: PendingFileMessage, isNew: Bool = false) {
        let status: String
        if !pending.pending.isEmpty {
            status = "\(pending.pending.count) \(pending.failureUnit)等待或正在接收，请在文件传输中心查看进度"
        } else {
            var descriptions: [String] = []
            if !pending.failed.isEmpty {
                descriptions.append("\(pending.failed.count) \(pending.failureUnit)接收失败")
            }
            if !pending.cancelled.isEmpty {
                descriptions.append("\(pending.cancelled.count) \(pending.failureUnit)已取消")
            }
            status = descriptions.isEmpty ? "" : descriptions.joined(separator: "，") + "，可在文件传输中心重试"
        }
        let attachments = pending.attachments.keys.sorted().compactMap { pending.attachments[$0] }
        func messageText(_ text: String) -> String {
            text + (status.isEmpty ? "" : (text.isEmpty ? "" : "\n") + "[\(status)]")
        }
        let message = ChatMessage(
            id: pending.message.id, direction: .incoming, text: messageText(pending.message.text),
            senderName: pending.message.senderName, recipientName: pending.message.recipientName,
            date: pending.message.date, attachments: attachments
        )
        emit(isNew ? .messageReceived(message: message, peer: pending.peer)
             : .messageUpdated(message: message, peer: pending.peer))
        let relay = groupProtocolService.parseRelayText(pending.message.text)
        for groupEntry in pending.groups where !deletedFileMessageIDs.contains(groupEntry.messageID) {
            let groupMessage = ChatMessage(
                id: groupEntry.messageID, direction: .incoming,
                text: messageText(relay?.text ?? pending.message.text),
                senderName: relay?.senderName ?? pending.message.senderName,
                recipientName: groupEntry.group.displayName, date: pending.message.date, attachments: attachments
            )
            emit(isNew ? .groupMessageReceived(message: groupMessage, group: groupEntry.group)
                 : .groupMessageUpdated(message: groupMessage, group: groupEntry.group))
        }
    }

    private func deliverIncomingMessage(
        _ incomingMessage: ChatMessage,
        from peer: FeiQPeer,
        updatingDirectMessage: Bool = false
    ) {
        emit(updatingDirectMessage
             ? .messageUpdated(message: incomingMessage, peer: peer)
             : .messageReceived(message: incomingMessage, peer: peer))

        let matchingGroups = groupRepository.groups(containing: peer.id).map { group in
            (
                group: group,
                members: sessionRepository.peers(withIDs: group.memberIDs)
            )
        }

        let relayedMessage = groupProtocolService.parseRelayText(incomingMessage.text)
        for matchingGroup in matchingGroups {
            let group = matchingGroup.group
            // A relayed packet already represents a message that another
            // group hub forwarded. Do not inject it into a second group
            // or forward it again, otherwise two Mac hubs can create a
            // relay loop. Only display it in the group encoded on wire.
            if let relayedMessage,
               relayedMessage.groupName != group.displayName {
                continue
            }

            let groupText = relayedMessage?.text ?? incomingMessage.text
            let groupSenderName = relayedMessage?.senderName ?? incomingMessage.senderName
            let groupMessage = ChatMessage(
                direction: incomingMessage.direction,
                text: groupText,
                senderName: groupSenderName,
                recipientName: group.displayName,
                date: incomingMessage.date,
                attachments: incomingMessage.attachments
            )
            emit(
                .groupMessageReceived(
                    message: groupMessage,
                    group: group
                )
            )

            // A standard message from a group member is the group hub's
            // ingress. Relay it to every other online member. Packets
            // carrying our relay marker are already fan-out messages and
            // must not be sent again.
            if relayedMessage == nil {
                relayIncomingGroupMessage(
                    incomingMessage,
                    from: peer,
                    group: group,
                    members: matchingGroup.members
                )
            }
        }
    }

    private func finishInlineMessage(_ key: String, timedOut: Bool = false, expired: Bool = false) {
        guard var pending = pendingInlineMessages[key] else { return }
        let wasTimedOut = pending.timedOut
        pending.timedOut = pending.timedOut || timedOut
        var seen = Set<String>()
        let ids = pending.imageIDs.filter { seen.insert($0).inserted }
        for id in ids {
            if let image = receivedInlineImages[pending.peer.ipAddress + "/" + id]?.attachment {
                pending.attachments[id] = image
                pending.failedImageIDs.remove(id)
            }
        }
        let attachments = ids.compactMap { pending.attachments[$0] }
        let missing = attachments.count != ids.count
        let status: String
        if !missing {
            status = ""
        } else if expired {
            status = "\n[图片接收已超时，请对方重新发送]"
        } else if !pending.failedImageIDs.isEmpty {
            status = "\n[部分图片无法解码，请对方重新发送]"
        } else if pending.timedOut {
            status = "\n[图片接收不完整，请对方重新发送；稍后到达的图片会自动补全]"
        } else {
            status = "\n[图片尚未接收完成 \(attachments.count)/\(ids.count)]"
        }
        let message = ChatMessage(
            id: pending.id, direction: .incoming,
            text: (pending.text + status).trimmingCharacters(in: .whitespacesAndNewlines),
            senderName: pending.peer.displayName, recipientName: pending.recipient,
            date: pending.date, attachments: attachments
        )
        if missing {
            pendingInlineMessages[key] = pending
            emit(.messageUpdated(message: message, peer: pending.peer))
        } else {
            pendingInlineMessages.removeValue(forKey: key)
            deliverIncomingMessage(message, from: pending.peer, updatingDirectMessage: true)
        }
        if missing, timedOut, !wasTimedOut {
            emit(.log("来自 \(pending.peer.displayName) 的图片接收超时：\(attachments.count)/\(ids.count)，保留关联等待晚到分片"))
        }
    }

    private func relayIncomingGroupMessage(
        _ message: ChatMessage,
        from sourcePeer: FeiQPeer,
        group: ChatGroup,
        members: [FeiQPeer]
    ) {
        let relayText = groupProtocolService.makeRelayText(
            groupName: group.displayName,
            senderName: message.senderName,
            text: message.text
        )
        let sourceAddress = sourcePeer.ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep the attachment kind intact while relaying. Images received via
        // the private inline protocol remain inline images; normal files keep
        // their TCP attachment metadata and can be downloaded by every member.
        let relayAttachments = message.attachments
        var sentAddresses = Set<String>()
        var sentCount = 0

        for member in members where member.isOnline && member.id != sourcePeer.id {
            let address = member.ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty,
                  address != sourceAddress,
                  sentAddresses.insert(address).inserted else {
                continue
            }

            sendContent(
                text: relayText,
                attachments: relayAttachments,
                to: address,
                recipientName: member.displayName + " · " + group.displayName,
                messageID: message.id
            )
            sentCount += 1
        }

        if sentCount == 0 {
            emit(.log("群聊「" + group.displayName + "」收到「" + message.senderName + "」的消息，但没有其他在线成员可中继"))
        } else {
            let contentType = message.attachments.isEmpty
                ? "消息"
                : (message.attachments.allSatisfy { $0.kind == .image } ? "图片" : "文件")
            emit(.log("群聊「" + group.displayName + "」已将「" + message.senderName + "」的" + contentType + "中继给 " + String(sentCount) + " 位成员"))
        }
    }

    private func emit(_ event: ChatRepositoryEvent) {
        onEvent?(event)
    }
}
