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
    func peers(at ipAddress: String) -> [FeiQPeer]
    @discardableResult
    func upsertPeer(packet: FeiQPacket, ipAddress: String) -> FeiQPeer
    func markPeerOffline(packet: FeiQPacket, ipAddress: String) -> FeiQPeer?
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
        let current = queue.sync { () -> FeiQPeer in
            let current = peersByID[peer.id].flatMap { $0.lastSeen > peer.lastSeen ? $0 : nil } ?? peer
            peersByID[peer.id] = current
            return current
        }
        historyService.savePeer(current)
    }

    func restore(_ peers: [FeiQPeer]) {
        queue.sync {
            for peer in peers {
                if let livePeer = peersByID[peer.id], livePeer.isOnline || livePeer.lastSeen > peer.lastSeen {
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

    func peers(at ipAddress: String) -> [FeiQPeer] {
        queue.sync { peersByID.values.filter { $0.ipAddress == ipAddress } }
    }

    @discardableResult
    func upsertPeer(packet: FeiQPacket, ipAddress: String) -> FeiQPeer {
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

        let result = queue.sync { () -> (peer: FeiQPeer, shouldPersist: Bool, displaced: [FeiQPeer]) in
            let existingPeer = PeerIdentity.resolve(packet: packet, address: ipAddress, peers: Array(peersByID.values))
            let stableID = existingPeer?.id ?? "peer-" + UUID().uuidString
            var displaced: [FeiQPeer] = []
            for candidate in peersByID.values where candidate.id != stableID && candidate.ipAddress == ipAddress && candidate.isOnline {
                var offline = candidate
                offline.isOnline = false
                peersByID[offline.id] = offline
                displaced.append(offline)
            }
            if let existingPeer {
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
                    || PeerIdentity.deviceIdentifier(packet.feiQDeviceIdentifier).map { $0 != peer.deviceIdentifier } == true
                let becameOnline = !peer.isOnline
                peer.name = name
                peer.hostName = host
                peer.ipAddress = ipAddress
                peer.group = updatedGroup
                peer.lastSeen = Date()
                peer.isOnline = true
                peer.deviceIdentifier = PeerIdentity.deviceIdentifier(packet.feiQDeviceIdentifier) ?? peer.deviceIdentifier
                peersByID[stableID] = peer
                return (peer, metadataChanged || becameOnline, displaced)
            }

            let peer = FeiQPeer(
                id: stableID,
                name: isPresencePacket ? presenceName : packetName,
                hostName: packetHost,
                ipAddress: ipAddress,
                group: isPresencePacket ? presenceGroup : "",
                lastSeen: Date(),
                isOnline: true,
                deviceIdentifier: PeerIdentity.deviceIdentifier(packet.feiQDeviceIdentifier)
            )
            peersByID[stableID] = peer
            return (peer, true, displaced)
        }

        for peer in result.displaced { historyService.savePeer(peer) }
        if result.shouldPersist {
            historyService.savePeer(result.peer)
        }
        return result.peer
    }

    func markPeerOffline(packet: FeiQPacket, ipAddress: String) -> FeiQPeer? {
        let peer = queue.sync { () -> FeiQPeer? in
            guard var peer = PeerIdentity.resolve(packet: packet, address: ipAddress, peers: Array(peersByID.values)),
                  peer.ipAddress == ipAddress else {
                return nil
            }
            peer.isOnline = false
            peersByID[peer.id] = peer
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
