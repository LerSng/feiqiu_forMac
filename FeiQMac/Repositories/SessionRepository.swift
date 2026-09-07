//
//  SessionRepository.swift
//  FeiQMac
//
//  会话业务仓储：维护本机身份、联系人在线状态、稳定联系人 ID 和离线收敛。
//

import Foundation

protocol SessionRepository: AnyObject {
    var identity: FeiQIdentity { get }

    func updateIdentity(_ identity: FeiQIdentity)
    func savePeer(_ peer: FeiQPeer)
    func restore(_ peers: [FeiQPeer])
    func peers(withIDs ids: [String]) -> [FeiQPeer]
    @discardableResult
    func upsertPeer(packet: FeiQPacket, ipAddress: String) -> FeiQPeer
    func markPeerOffline(ipAddress: String) -> FeiQPeer?
    func markOffline(before cutoff: Date) -> [FeiQPeer]
}

final class DefaultSessionRepository: SessionRepository {
    private let historyService: ChatHistoryService
    private let queue = DispatchQueue(label: "com.feiqmac.session-repository-state")

    private var currentIdentity = FeiQIdentity(
        nickname: "飞秋 Mac",
        hostName: "Mac",
        groupName: ""
    )
    private var peersByID: [String: FeiQPeer] = [:]

    var identity: FeiQIdentity {
        queue.sync { currentIdentity }
    }

    init(historyService: ChatHistoryService) {
        self.historyService = historyService
    }

    func updateIdentity(_ identity: FeiQIdentity) {
        queue.sync {
            currentIdentity = identity
        }
    }

    func savePeer(_ peer: FeiQPeer) {
        queue.sync {
            peersByID[peer.id] = peer
        }
        historyService.savePeer(peer)
    }

    func restore(_ peers: [FeiQPeer]) {
        queue.sync {
            for peer in peers {
                if let livePeer = peersByID[peer.id], livePeer.isOnline {
                    continue
                }
                peersByID[peer.id] = peer
            }
        }
    }

    func peers(withIDs ids: [String]) -> [FeiQPeer] {
        queue.sync {
            ids.compactMap { peersByID[$0] }
        }
    }

    @discardableResult
    func upsertPeer(packet: FeiQPacket, ipAddress: String) -> FeiQPeer {
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

        let result = queue.sync { () -> (peer: FeiQPeer, shouldPersist: Bool) in
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

    func markPeerOffline(ipAddress: String) -> FeiQPeer? {
        let peer = queue.sync { () -> FeiQPeer? in
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

    func markOffline(before cutoff: Date) -> [FeiQPeer] {
        let changedPeers = queue.sync { () -> [FeiQPeer] in
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
        }
        return changedPeers
    }
}
