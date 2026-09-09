import Foundation

enum PeerIdentity {
    static func deviceIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard (4...128).contains(normalized.count),
              normalized.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              !normalized.allSatisfy({ $0 == "0" || $0 == "-" }),
              !["UNKNOWN", "NULL", "NONE"].contains(normalized) else { return nil }
        return normalized
    }

    static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping.lowercased()
    }

    static func host(_ value: String, address: String) -> String? {
        let normalized = normalizedName(value).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalized.isEmpty, normalized != normalizedName(address),
              !["未知地址", "unknown", "localhost", "localhost.localdomain"].contains(normalized),
              !normalized.contains(":"),
              !normalized.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return normalized
    }

    static func resolve(packet: FeiQPacket, address: String, peers: [FeiQPeer]) -> FeiQPeer? {
        let identifier = deviceIdentifier(packet.feiQDeviceIdentifier)
        if let identifier {
            let exact = peers.filter { deviceIdentifier($0.deviceIdentifier) == identifier }
            if exact.count == 1 { return exact[0] }
            if !exact.isEmpty { return nil }
        }
        let compatible = peers.filter { peer in
            guard let identifier, let existing = deviceIdentifier(peer.deviceIdentifier) else { return true }
            return identifier == existing
        }
        let packetHost = host(packet.senderHost, address: address)
        let sameAddress = compatible.filter { peer in
            guard peer.ipAddress == address else { return false }
            guard let packetHost, let existingHost = host(peer.hostName, address: peer.ipAddress) else { return true }
            return packetHost == existingHost
        }
        if sameAddress.count == 1 { return sameAddress[0] }
        guard let packetHost else { return nil }
        let sameHost = compatible.filter { host($0.hostName, address: $0.ipAddress) == packetHost }
        if sameHost.count == 1 { return sameHost[0] }
        let names = Set([packet.senderName, packet.entryName ?? ""].map(normalizedName).filter { !$0.isEmpty })
        let sameName = sameHost.filter { names.contains(normalizedName($0.name)) }
        return sameName.count == 1 ? sameName[0] : nil
    }

    static func legacyMergeKey(for peer: FeiQPeer) -> String? {
        if let identifier = deviceIdentifier(peer.deviceIdentifier) { return "device:" + identifier }
        guard peer.id == peer.ipAddress, let hostname = host(peer.hostName, address: peer.ipAddress) else { return nil }
        let name = normalizedName(peer.name)
        guard !name.isEmpty, name != normalizedName(peer.ipAddress) else { return nil }
        return "legacy:" + hostname + "\0" + name
    }
}
