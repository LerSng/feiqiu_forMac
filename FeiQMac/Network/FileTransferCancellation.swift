import Darwin
import Foundation

final class FileTransferCancellation: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var cancelled = false
    private var descriptor: Int32?
    private var cancellationHandler: (() -> Void)?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        if let descriptor {
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        }
        let handler = cancellationHandler
        cancellationHandler = nil
        lock.unlock()
        handler?()
    }

    func onCancel(_ handler: @escaping () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
        } else {
            cancellationHandler = handler
            lock.unlock()
        }
    }

    func attachSocket(_ descriptor: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.descriptor = descriptor
        return true
    }

    func closeSocket(_ descriptor: Int32) {
        lock.lock()
        if self.descriptor == descriptor {
            self.descriptor = nil
        }
        Darwin.close(descriptor)
        lock.unlock()
    }

    func finish() {
        lock.lock()
        cancellationHandler = nil
        lock.unlock()
    }
}

final class FileTransferProgressReporter {
    private let callback: (FileTransferProgress) -> Void
    private var lastReportedAt: TimeInterval = 0
    private var lastState: FileTransferState?
    private var lastReportedBytes: Int64 = 0

    init(_ callback: @escaping (FileTransferProgress) -> Void) {
        self.callback = callback
    }

    func report(_ bytes: Int64, state: FileTransferState = .transferring, force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || state != lastState || (lastReportedBytes == 0 && bytes > 0)
                || now - lastReportedAt >= 0.1 else { return }
        lastReportedAt = now
        lastState = state
        lastReportedBytes = bytes
        callback(FileTransferProgress(bytesTransferred: bytes, state: state))
    }
}
