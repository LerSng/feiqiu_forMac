import Foundation

protocol ChatRepository: AnyObject {
    var onEvent: ((ChatRepositoryEvent) -> Void)? { get set }
    var historyLocationDescription: String { get }

    func start(identity: FeiQIdentity)
    func stop()
    func updateIdentity(_ identity: FeiQIdentity)
    func announce()
    func updateTyping(isTyping: Bool, for peer: FeiQPeer)
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
    func sendGroupImage(
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
}

final class DefaultChatRepository: ChatRepository {
    private let networkService: FeiQNetworkServiceProtocol
    private let historyService: ChatHistoryService
    private let attachmentStorageService: ChatAttachmentStorageService
    private let notificationService: NotificationService
    private let stateQueue = DispatchQueue(label: "com.feiqmac.chat-repository-state")
    private let attachmentQueue = DispatchQueue(
        label: "com.feiqmac.chat-repository-attachments",
        qos: .utility
    )

    private var identity = FeiQIdentity(
        nickname: "飞秋 Mac",
        hostName: "Mac",
        groupName: ""
    )
    private var peersByID: [String: FeiQPeer] = [:]
    private var groupsByID: [String: ChatGroup] = [:]
    // Owned by attachmentQueue. Marker and image packets can arrive in either order.
    private struct PendingInlineMessage {
        let peer: FeiQPeer
        let text: String
        let recipient: String
        let imageIDs: [String]
        let date: Date
    }
    private var pendingInlineMessages: [String: PendingInlineMessage] = [:]
    private var receivedInlineImages: [String: (attachment: ChatAttachment, date: Date)] = [:]
    private var receivedMessagePackets: [String: Date] = [:]

    var onEvent: ((ChatRepositoryEvent) -> Void)?

    var historyLocationDescription: String {
        historyService.locationDescription
    }

    init(
        networkService: FeiQNetworkServiceProtocol,
        historyService: ChatHistoryService,
        attachmentStorageService: ChatAttachmentStorageService,
        notificationService: NotificationService
    ) {
        self.networkService = networkService
        self.historyService = historyService
        self.attachmentStorageService = attachmentStorageService
        self.notificationService = notificationService

        networkService.onPacket = { [weak self] packet, ipAddress, transport in
            self?.attachmentQueue.async { [weak self] in
                self?.handle(packet: packet, from: ipAddress, transport: transport)
            }
        }
        networkService.onInlineImage = { [weak self] bytes, imageID, bitmapFlag, packet, ipAddress in
            self?.attachmentQueue.async { [weak self] in
                guard let self else { return }
                do {
                    let attachment = try self.attachmentStorageService.saveInlineImage(bytes, imageID: imageID, isBitmap: bitmapFlag == 1)
                    self.receivedInlineImages = self.receivedInlineImages.filter { Date().timeIntervalSince($0.value.date) < 90 }
                    if self.receivedInlineImages.count >= 256,
                       let oldest = self.receivedInlineImages.min(by: { $0.value.date < $1.value.date })?.key {
                        self.receivedInlineImages.removeValue(forKey: oldest)
                    }
                    self.receivedInlineImages[ipAddress + "/" + imageID] = (attachment, Date())
                    for key in Array(self.pendingInlineMessages.keys) { self.finishInlineMessage(key) }
                } catch {
                    self.emit(.log("内嵌图片 \(imageID) 解码失败：\(error.localizedDescription)"))
                }
            }
        }
        networkService.onLog = { [weak self] message in
            self?.emit(.log(message))
        }
        networkService.onStateChange = { [weak self] running in
            self?.emit(.networkStateChanged(running))
        }
        notificationService.onNotificationSelected = { [weak self] peerID in
            self?.emit(.notificationSelected(conversationID: peerID))
        }
    }

    func start(identity: FeiQIdentity) {
        updateIdentity(identity)
        networkService.start(
            name: identity.nickname,
            host: identity.hostName,
            group: identity.groupName
        )
    }

    func stop() {
        networkService.stop()
    }

    func updateIdentity(_ identity: FeiQIdentity) {
        stateQueue.sync {
            self.identity = identity
        }
        networkService.updateIdentity(
            name: identity.nickname,
            host: identity.hostName,
            group: identity.groupName
        )
    }

    func announce() {
        networkService.announce()
    }

    func refreshDiscovery() {
        announce()
    }

    func updateTyping(isTyping: Bool, for peer: FeiQPeer) {
        let address = peer.ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return }
        networkService.sendTyping(isTyping: isTyping, to: address)
    }

    func sendMessage(
        _ message: ChatMessage,
        to peer: FeiQPeer,
        unreadCount: Int
    ) {
        persistMessage(message, for: peer, unreadCount: unreadCount)
        if message.attachments.isEmpty {
            networkService.sendText(
                FeiQMessageFormatter.wireText(message.text),
                to: peer.ipAddress,
                recipientName: peer.displayName
            )
        } else {
            networkService.sendFileMessage(
                FeiQMessageFormatter.wireText(message.text),
                attachments: message.attachments,
                to: peer.ipAddress,
                recipientName: peer.displayName
            )
        }
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

        let localNickname = stateQueue.sync { identity.nickname }
        let relayText = FeiQGroupRelayFormatter.makeText(
            groupName: group.displayName,
            senderName: localNickname,
            text: message.text
        )
        let wireText = FeiQMessageFormatter.wireText(relayText)
        var sentCount = 0
        var sentAddresses = Set<String>()
        for member in members where member.isOnline {
            let address = member.ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty, sentAddresses.insert(address).inserted else {
                continue
            }
            if message.attachments.isEmpty {
                networkService.sendText(
                    wireText,
                    to: address,
                    recipientName: group.displayName
                )
            } else {
                networkService.sendFileMessage(
                    wireText,
                    attachments: message.attachments,
                    to: address,
                    recipientName: group.displayName
                )
            }
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
                let attachment = try attachmentStorageService.prepareOutgoingImage(from: fileURL)
                let localNickname = stateQueue.sync { identity.nickname }
                let message = ChatMessage(
                    direction: .outgoing,
                    text: "",
                    senderName: localNickname,
                    recipientName: peer.displayName,
                    attachments: [attachment]
                )
                persistMessage(message, for: peer, unreadCount: unreadCount)
                networkService.sendFileMessage(
                    "",
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
                completion(.success(try attachmentStorageService.prepareOutgoingImage(
                    from: data,
                    suggestedFileName: suggestedFileName
                )))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func sendGroupImage(
        from fileURL: URL,
        to group: ChatGroup,
        members: [FeiQPeer],
        completion: @escaping (Result<ChatMessage, Error>) -> Void
    ) {
        attachmentQueue.async { [self] in
            do {
                let attachment = try attachmentStorageService.prepareOutgoingImage(from: fileURL)
                let localNickname = stateQueue.sync { identity.nickname }
                let message = ChatMessage(
                    direction: .outgoing,
                    text: "",
                    senderName: localNickname,
                    recipientName: group.displayName,
                    attachments: [attachment]
                )
                persistGroupMessage(message, for: group, unreadCount: 0)

                let relayText = FeiQGroupRelayFormatter.makeText(
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
                    networkService.sendFileMessage(
                        relayText,
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

    func persistMessage(
        _ message: ChatMessage,
        for peer: FeiQPeer,
        unreadCount: Int
    ) {
        historyService.saveMessage(
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
        historyService.saveMessage(
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
        notificationService.notifyIncomingMessage(
            from: sender,
            text: text,
            conversationID: conversationID
        )
    }

    func setUnreadCount(_ count: Int, for peerID: String) {
        historyService.setUnreadCount(count, for: peerID)
    }

    func savePeer(_ peer: FeiQPeer) {
        stateQueue.sync {
            peersByID[peer.id] = peer
        }
        historyService.savePeer(peer)
    }

    func saveGroup(_ group: ChatGroup) {
        stateQueue.sync {
            groupsByID[group.id] = group
        }
        historyService.saveGroup(group)
    }

    func deleteGroup(_ groupID: String) {
        stateQueue.sync {
            groupsByID.removeValue(forKey: groupID)
        }
        historyService.deleteGroup(groupID)
    }

    func restorePeers(_ peers: [FeiQPeer]) {
        stateQueue.sync {
            for peer in peers {
                if let livePeer = peersByID[peer.id], livePeer.isOnline {
                    continue
                }
                peersByID[peer.id] = peer
            }
        }
    }

    func restoreGroups(_ groups: [ChatGroup]) {
        stateQueue.sync {
            for group in groups {
                groupsByID[group.id] = group
            }
        }
    }

    func markOfflinePeers(before cutoff: Date) {
        let changedPeers = stateQueue.sync { () -> [FeiQPeer] in
            var changed: [FeiQPeer] = []
            for (peerID, currentPeer) in peersByID {
                guard currentPeer.isOnline, currentPeer.lastSeen < cutoff else {
                    continue
                }
                var offlinePeer = currentPeer
                offlinePeer.isOnline = false
                peersByID[peerID] = offlinePeer
                changed.append(offlinePeer)
            }
            return changed
        }

        for peer in changedPeers {
            historyService.savePeer(peer)
            emit(.peerUpdated(peer))
        }
    }

    func loadSnapshot(
        completion: @escaping (Result<ChatHistorySnapshot, Error>) -> Void
    ) {
        historyService.loadSnapshot(completion: completion)
    }

    func loadRecentMessages(
        for peerID: String,
        limit: Int,
        completion: @escaping (Result<ChatHistoryPage, Error>) -> Void
    ) {
        historyService.loadRecentMessages(
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
        historyService.loadEarlierMessages(
            for: peerID,
            before: message,
            limit: limit,
            completion: completion
        )
    }

    private func handle(
        packet: FeiQPacket,
        from ipAddress: String,
        transport: FeiQTransport
    ) {
        let currentIdentity = stateQueue.sync { identity }

        // A broadcast may be delivered back to its sender on some adapters.
        if packet.senderName == currentIdentity.nickname,
           packet.senderHost == currentIdentity.hostName {
            return
        }

        if packet.isFeiQPresencePacket {
            let peer = upsertPeer(packet: packet, ipAddress: ipAddress)
            emit(.peerUpdated(peer))
            if packet.isFeiQEntryRequest {
                networkService.replyToEntry(from: ipAddress)
            }
            return
        }

        switch packet.commandType {
        case .inputting, .inputEnd:
            let peer = upsertPeer(packet: packet, ipAddress: ipAddress)
            emit(.peerUpdated(peer))
            emit(.peerTyping(
                peer: peer,
                isTyping: packet.commandType == .inputting
            ))

        case .broadcastEntry:
            let peer = upsertPeer(packet: packet, ipAddress: ipAddress)
            emit(.peerUpdated(peer))
            networkService.replyToEntry(from: ipAddress)

        case .answerEntry, .answerList, .sendInfo:
            let peer = upsertPeer(packet: packet, ipAddress: ipAddress)
            emit(.peerUpdated(peer))

        case .broadcastExit:
            if let peer = markPeerOffline(ipAddress: ipAddress) {
                emit(.peerUpdated(peer))
            }

        case .sendMessage:
            let peer = upsertPeer(packet: packet, ipAddress: ipAddress)
            emit(.peerUpdated(peer))

            // Acknowledge the wire packet first, even if it contains only
            // formatting metadata, so the Windows sender does not report a
            // delivery failure.
            let text = FeiQMessageFormatter.displayText(packet.additionalText)
            networkService.acknowledge(packet, to: ipAddress)
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
                    return
                }
                pendingInlineMessages[packetKey] = PendingInlineMessage(
                    peer: peer,
                    text: FeiQMessageFormatter.displayText(FeiQInlineImageCodec.replacingMarkers(in: packet.additionalText, with: "")),
                    recipient: currentIdentity.nickname, imageIDs: imageIDs, date: Date())
                finishInlineMessage(packetKey)
                attachmentQueue.asyncAfter(deadline: .now() + 90) { [weak self] in
                    self?.finishInlineMessage(packetKey, timedOut: true)
                }
                return
            }
            let remoteImages = packet.fileAttachments.filter(\.isImage)
            guard !text.isEmpty || !remoteImages.isEmpty else {
                if packet.hasFileAttachments {
                    emit(.log("收到文件附件，但当前仅支持图片格式"))
                }
                return
            }

            if remoteImages.isEmpty {
                let incomingMessage = ChatMessage(
                    direction: .incoming,
                    text: text,
                    senderName: peer.displayName,
                    recipientName: currentIdentity.nickname
                )
                deliverIncomingMessage(incomingMessage, from: peer)
                return
            }

            downloadIncomingImages(
                remoteImages,
                packetNumber: packet.packetNumber,
                from: ipAddress
            ) { [weak self] result in
                guard let self else { return }

                switch result {
                case .success(let attachments):
                    let incomingMessage = ChatMessage(
                        direction: .incoming,
                        text: text,
                        senderName: peer.displayName,
                        recipientName: currentIdentity.nickname,
                        attachments: attachments
                    )
                    self.deliverIncomingMessage(incomingMessage, from: peer)

                case .failure(let error):
                    self.emit(.log("图片接收失败：\(error.localizedDescription)"))
                    guard !text.isEmpty else { return }
                    let textMessage = ChatMessage(
                        direction: .incoming,
                        text: text,
                        senderName: peer.displayName,
                        recipientName: currentIdentity.nickname
                    )
                    self.deliverIncomingMessage(textMessage, from: peer)
                }
            }

        case .receiveMessage, .readMessage, .deleteMessage, .answerReadMessage,
             .broadcastAbsence, .broadcastNotify, .broadcastIsGetList,
             .okGetList, .getList, .getInfo, .getFileData,
             .releaseFiles, .getDirectoryFiles, .inlineImage, .inlineImageAcknowledgement, nil:
            break
        }

        _ = transport
    }

    private func downloadIncomingImages(
        _ remoteImages: [FeiQFileAttachment],
        packetNumber: UInt64,
        from ipAddress: String,
        completion: @escaping (Result<[ChatAttachment], Error>) -> Void
    ) {
        do {
            let preparedAttachments = try remoteImages.map {
                (
                    remote: $0,
                    local: try attachmentStorageService.prepareIncomingImage(for: $0)
                )
            }
            let group = DispatchGroup()
            let resultLock = NSLock()
            var downloaded = Array<ChatAttachment?>(repeating: nil, count: preparedAttachments.count)
            var firstError: Error?

            for (index, prepared) in preparedAttachments.enumerated() {
                group.enter()
                networkService.downloadFile(
                    prepared.remote,
                    packetNumber: packetNumber,
                    from: ipAddress,
                    to: prepared.local.localURL
                ) { result in
                    resultLock.lock()
                    defer {
                        resultLock.unlock()
                        group.leave()
                    }

                    switch result {
                    case .success:
                        downloaded[index] = prepared.local
                    case .failure(let error):
                        firstError = firstError ?? error
                    }
                }
            }

            group.notify(queue: attachmentQueue) {
                resultLock.lock()
                let error = firstError
                let attachments = downloaded.compactMap { $0 }
                resultLock.unlock()

                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(attachments))
                }
            }
        } catch {
            completion(.failure(error))
        }
    }

    private func deliverIncomingMessage(
        _ incomingMessage: ChatMessage,
        from peer: FeiQPeer
    ) {
        emit(
            .messageReceived(
                message: incomingMessage,
                peer: peer
            )
        )

        let matchingGroups = stateQueue.sync {
            groupsByID.values
                .filter { $0.memberIDs.contains(peer.id) }
                .sorted { $0.createdAt < $1.createdAt }
                .map { group in
                    (
                        group: group,
                        members: group.memberIDs.compactMap { peersByID[$0] }
                    )
                }
        }

        let relayedMessage = FeiQGroupRelayFormatter.parse(incomingMessage.text)
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

    private func finishInlineMessage(_ key: String, timedOut: Bool = false) {
        guard let pending = pendingInlineMessages[key] else { return }
        var seen = Set<String>()
        let ids = pending.imageIDs.filter { seen.insert($0).inserted }
        let attachments = ids.compactMap { receivedInlineImages[pending.peer.ipAddress + "/" + $0]?.attachment }
        guard timedOut || attachments.count == ids.count else { return }
        pendingInlineMessages.removeValue(forKey: key)
        let missing = attachments.count != ids.count
        let text = pending.text + (missing ? "\n[图片接收不完整，请对方重新发送]" : "")
        deliverIncomingMessage(ChatMessage(direction: .incoming, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                           senderName: pending.peer.displayName, recipientName: pending.recipient,
                                           date: pending.date, attachments: attachments), from: pending.peer)
        if missing { emit(.log("来自 \(pending.peer.displayName) 的图片接收超时")) }
    }

    private func relayIncomingGroupMessage(
        _ message: ChatMessage,
        from sourcePeer: FeiQPeer,
        group: ChatGroup,
        members: [FeiQPeer]
    ) {
        let relayText = FeiQGroupRelayFormatter.makeText(
            groupName: group.displayName,
            senderName: message.senderName,
            text: message.text
        )
        let sourceAddress = sourcePeer.ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let relayAttachments: [ChatAttachment]
        do {
            relayAttachments = try message.attachments.map {
                $0.mimeType == "image/jpeg" ? $0 : try attachmentStorageService.prepareOutgoingImage(from: $0.localURL)
            }
        } catch {
            emit(.log("群聊图片转换失败：\(error.localizedDescription)"))
            return
        }
        var sentAddresses = Set<String>()
        var sentCount = 0

        for member in members where member.isOnline && member.id != sourcePeer.id {
            let address = member.ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty,
                  address != sourceAddress,
                  sentAddresses.insert(address).inserted else {
                continue
            }

            if message.attachments.isEmpty {
                networkService.sendText(
                    FeiQMessageFormatter.wireText(relayText),
                    to: address,
                    recipientName: group.displayName
                )
            } else {
                networkService.sendFileMessage(
                    relayText,
                    attachments: relayAttachments,
                    to: address,
                    recipientName: group.displayName
                )
            }
            sentCount += 1
        }

        if sentCount == 0 {
            emit(.log("群聊「" + group.displayName + "」收到「" + message.senderName + "」的消息，但没有其他在线成员可中继"))
        } else {
            let contentType = message.attachments.isEmpty ? "消息" : "图片"
            emit(.log("群聊「" + group.displayName + "」已将「" + message.senderName + "」的" + contentType + "中继给 " + String(sentCount) + " 位成员"))
        }
    }

    @discardableResult
    private func upsertPeer(packet: FeiQPacket, ipAddress: String) -> FeiQPeer {
        let stableID = ipAddress == "未知地址" || ipAddress.isEmpty
            ? packet.senderHost
            : ipAddress
        let isPresencePacket = packet.commandType == .broadcastEntry
            || packet.commandType == .answerEntry
            || packet.isFeiQPresencePacket

        // FeiQ builds do not all put the nickname in the same header field.
        // Presence packets carry the nickname used by the contact list, while
        // message packets may carry the Windows account/machine user instead.
        let packetName = packet.senderName.isEmpty
            ? packet.senderHost
            : packet.senderName
        let packetHost = packet.senderHost.isEmpty
            ? ipAddress
            : packet.senderHost
        let advertisedName = packet.entryName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let presenceName = advertisedName.isEmpty ? packetName : advertisedName
        let presenceGroup = packet.entryGroup?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let result = stateQueue.sync { () -> (peer: FeiQPeer, shouldPersist: Bool) in
            if let existingPeer = peersByID[stableID] {
                var peer = existingPeer
                let name: String
                let host: String
                let updatedGroup: String

                if isPresencePacket {
                    name = presenceName
                    host = packetHost
                    updatedGroup = presenceGroup.isEmpty
                        ? peer.group
                        : presenceGroup
                } else {
                    name = peer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? packetName
                        : peer.name
                    host = peer.hostName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? packetHost
                        : peer.hostName
                    updatedGroup = peer.group
                }

                let metadataChanged = peer.name != name
                    || peer.hostName != host
                    || peer.ipAddress != ipAddress
                    || peer.group != updatedGroup
                let becameOnline = !peer.isOnline
                peer.name = name
                peer.hostName = host
                peer.ipAddress = ipAddress
                peer.group = updatedGroup
                peer.lastSeen = Date()
                peer.isOnline = true
                peersByID[stableID] = peer
                return (peer, metadataChanged || becameOnline)
            }

            let peer = FeiQPeer(
                id: stableID,
                name: isPresencePacket ? presenceName : packetName,
                hostName: packetHost,
                ipAddress: ipAddress,
                group: isPresencePacket ? presenceGroup : "",
                lastSeen: Date(),
                isOnline: true
            )
            peersByID[stableID] = peer
            return (peer, true)
        }

        if result.shouldPersist {
            historyService.savePeer(result.peer)
        }
        return result.peer
    }

    private func markPeerOffline(ipAddress: String) -> FeiQPeer? {
        let peer = stateQueue.sync { () -> FeiQPeer? in
            guard let peerID = peersByID.first(where: { $0.value.ipAddress == ipAddress })?.key,
                  var peer = peersByID[peerID] else {
                return nil
            }
            peer.isOnline = false
            peersByID[peerID] = peer
            return peer
        }

        if let peer {
            historyService.savePeer(peer)
        }
        return peer
    }

    private func emit(_ event: ChatRepositoryEvent) {
        onEvent?(event)
    }
}
