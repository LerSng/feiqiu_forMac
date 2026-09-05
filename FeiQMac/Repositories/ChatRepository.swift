import Foundation

protocol ChatRepository: AnyObject {
    var onEvent: ((ChatRepositoryEvent) -> Void)? { get set }
    var historyLocationDescription: String { get }

    func start(identity: FeiQIdentity)
    func stop()
    func updateIdentity(_ identity: FeiQIdentity)
    func announce()
    func sendMessage(
        _ message: ChatMessage,
        to peer: FeiQPeer,
        unreadCount: Int
    )
    func persistMessage(
        _ message: ChatMessage,
        for peer: FeiQPeer,
        unreadCount: Int
    )
    func notifyIncomingMessage(text: String, from peer: FeiQPeer)
    func refreshDiscovery()
    func setUnreadCount(_ count: Int, for peerID: String)
    func savePeer(_ peer: FeiQPeer)
    func restorePeers(_ peers: [FeiQPeer])
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
    private let notificationService: NotificationService
    private let stateQueue = DispatchQueue(label: "com.feiqmac.chat-repository-state")

    private var identity = FeiQIdentity(
        nickname: "飞秋 Mac",
        hostName: "Mac",
        groupName: ""
    )
    private var peersByID: [String: FeiQPeer] = [:]

    var onEvent: ((ChatRepositoryEvent) -> Void)?

    var historyLocationDescription: String {
        historyService.locationDescription
    }

    init(
        networkService: FeiQNetworkServiceProtocol,
        historyService: ChatHistoryService,
        notificationService: NotificationService
    ) {
        self.networkService = networkService
        self.historyService = historyService
        self.notificationService = notificationService

        networkService.onPacket = { [weak self] packet, ipAddress, transport in
            self?.handle(packet: packet, from: ipAddress, transport: transport)
        }
        networkService.onLog = { [weak self] message in
            self?.emit(.log(message))
        }
        networkService.onStateChange = { [weak self] running in
            self?.emit(.networkStateChanged(running))
        }
        notificationService.onNotificationSelected = { [weak self] peerID in
            self?.emit(.notificationSelected(peerID: peerID))
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

    func sendMessage(
        _ message: ChatMessage,
        to peer: FeiQPeer,
        unreadCount: Int
    ) {
        persistMessage(message, for: peer, unreadCount: unreadCount)
        networkService.sendText(
            FeiQMessageFormatter.wireText(message.text),
            to: peer.ipAddress,
            recipientName: peer.displayName
        )
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

    func notifyIncomingMessage(text: String, from peer: FeiQPeer) {
        notificationService.notifyIncomingMessage(
            from: peer.displayName,
            text: text,
            peerID: peer.id
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
            guard !text.isEmpty else { return }

            let incomingMessage = ChatMessage(
                direction: .incoming,
                text: text,
                senderName: peer.displayName,
                recipientName: currentIdentity.nickname
            )
            emit(
                .messageReceived(
                    message: incomingMessage,
                    peer: peer
                )
            )

        case .receiveMessage, .readMessage, .deleteMessage, .answerReadMessage,
             .broadcastAbsence, .broadcastNotify, .broadcastIsGetList,
             .okGetList, .getList, .getInfo, nil:
            break
        }

        _ = transport
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
