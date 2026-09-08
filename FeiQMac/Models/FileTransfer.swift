import Foundation

enum FileTransferDirection: String, CaseIterable, Sendable {
    case incoming = "接收"
    case outgoing = "发送"
}

enum FileTransferState: String, Sendable {
    case queued = "排队中"
    case connecting = "连接中"
    case waitingForPeer = "等待对方接收"
    case transferring = "传输中"
    case cancelling = "正在取消"
    case completed = "已完成"
    case failed = "失败"
    case cancelled = "已取消"

    var isActive: Bool {
        [.connecting, .waitingForPeer, .transferring, .cancelling].contains(self)
    }

    var canCancel: Bool { self == .queued || (isActive && self != .cancelling) }
    var canRetry: Bool { self == .failed || self == .cancelled }
    var isFinished: Bool { self == .completed || canRetry }
}

struct FileTransferProgress: Sendable {
    var bytesTransferred: Int64
    var state: FileTransferState = .transferring
}

struct FileTransferRecord: Identifiable, Sendable {
    let id: UUID
    let attachment: ChatAttachment
    let direction: FileTransferDirection
    let peerName: String
    let ipAddress: String
    let messageID: UUID?
    let createdAt: Date
    var state: FileTransferState = .queued
    var bytesTransferred: Int64 = 0
    var bytesPerSecond: Double = 0
    var attemptCount = 0
    var startedAt: Date?
    var finishedAt: Date?
    var errorMessage: String?

    var progress: Double {
        if state == .completed { return 1 }
        guard attachment.fileSize > 0 else { return 0 }
        return min(1, max(0, Double(bytesTransferred) / Double(attachment.fileSize)))
    }

    var remainingSeconds: TimeInterval? {
        guard state == .transferring, bytesPerSecond > 0,
              bytesTransferred < attachment.fileSize else { return nil }
        return Double(attachment.fileSize - bytesTransferred) / bytesPerSecond
    }
}

struct FileTransferSnapshot: Sendable {
    var transfers: [FileTransferRecord] = []
    var isPaused = false
    var maximumConcurrentTransfers = 3

    var activeCount: Int { transfers.filter { $0.state.isActive }.count }
    var queuedCount: Int { transfers.filter { $0.state == .queued }.count }
    var failedCount: Int { transfers.filter { $0.state == .failed }.count }
    var unfinishedCount: Int { activeCount + queuedCount }
}
