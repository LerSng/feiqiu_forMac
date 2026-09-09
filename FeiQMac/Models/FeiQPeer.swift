import Foundation

struct FeiQPeer: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var name: String
    var hostName: String
    var ipAddress: String
    var group: String
    var lastSeen: Date
    var isOnline: Bool
    var deviceIdentifier: String? = nil

    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? (hostName.isEmpty ? ipAddress : hostName) : trimmedName
    }

    var detailText: String {
        if hostName.isEmpty || hostName == ipAddress {
            return ipAddress
        }
        return "\(hostName) · \(ipAddress)"
    }
}
