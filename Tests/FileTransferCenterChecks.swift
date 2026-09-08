import Foundation

private final class TransferSnapshots {
    private let condition = NSCondition()
    private var value = FileTransferSnapshot()

    func record(_ snapshot: FileTransferSnapshot) {
        condition.lock()
        value = snapshot
        condition.broadcast()
        condition.unlock()
    }

    @discardableResult
    func waitFor(_ predicate: (FileTransferSnapshot) -> Bool) -> FileTransferSnapshot {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while !predicate(value) {
            precondition(condition.wait(until: deadline), "transfer state update timed out")
        }
        return value
    }
}

private final class ControlledTransfer {
    struct Attempt {
        let progress: (FileTransferProgress) -> Void
        let completion: (Result<Void, Error>) -> Void
        let cancellation: FileTransferCancellation
    }

    private let condition = NSCondition()
    private var attempts: [Attempt] = []
    var completesCancellation = true

    var count: Int {
        condition.lock()
        defer { condition.unlock() }
        return attempts.count
    }

    func start(progress: @escaping (FileTransferProgress) -> Void,
               completion: @escaping (Result<Void, Error>) -> Void) -> FileTransferCancellation {
        let cancellation = FileTransferCancellation()
        if completesCancellation {
            cancellation.onCancel { completion(.failure(FeiQFileTransferError.cancelled)) }
        }
        condition.lock()
        attempts.append(Attempt(progress: progress, completion: completion, cancellation: cancellation))
        condition.broadcast()
        condition.unlock()
        return cancellation
    }

    func attempt(_ index: Int = 0) -> Attempt {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while attempts.count <= index {
            precondition(condition.wait(until: deadline), "transfer did not start")
        }
        return attempts[index]
    }
}

@main
enum FileTransferCenterChecks {
    static func main() {
        checkOrderingProgressAndRetry()
        checkDirectionIsolationAndLimits()
        checkDeletionAndClearing()
        checkEmptyFileAndCompletionRace()
        print("File transfer center checks passed")
    }

    private static func attachment(_ name: String, size: Int64 = 100) -> ChatAttachment {
        ChatAttachment(id: name, kind: .file, fileName: name + ".txt", fileSize: size,
                       modifiedAt: 0, fileAttributes: 1, localPath: "/tmp/" + name, mimeType: "text/plain")
    }

    private static func state(_ identifier: UUID, in snapshot: FileTransferSnapshot) -> FileTransferState? {
        snapshot.transfers.first { $0.id == identifier }?.state
    }

    private static func checkOrderingProgressAndRetry() {
        let center = FileTransferCenter(maximumConcurrentTransfers: 1)
        let snapshots = TransferSnapshots()
        center.observe(snapshots.record)
        center.setPaused(true)
        let first = ControlledTransfer()
        let second = ControlledTransfer()
        let third = ControlledTransfer()
        third.completesCancellation = false
        let firstID = center.enqueue(attachment: attachment("first"), direction: .incoming,
                                     peerName: "Win", ipAddress: "192.0.2.1", operation: first.start)
        let secondID = center.enqueue(attachment: attachment("second"), direction: .incoming,
                                      peerName: "Win", ipAddress: "192.0.2.1", operation: second.start)
        let thirdID = center.enqueue(attachment: attachment("third"), direction: .incoming,
                                     peerName: "Win", ipAddress: "192.0.2.1", operation: third.start)
        snapshots.waitFor { $0.queuedCount == 3 && $0.isPaused }
        precondition(first.count + second.count + third.count == 0, "paused queues must not start work")
        center.moveToFront(thirdID)
        snapshots.waitFor { $0.transfers.map(\.id) == [thirdID, firstID, secondID] }
        center.move(thirdID, by: 1)
        snapshots.waitFor { $0.transfers.map(\.id) == [firstID, thirdID, secondID] }
        center.cancel(secondID)
        snapshots.waitFor { state(secondID, in: $0) == .cancelled }
        precondition(second.count == 0, "queued cancellation must not invoke the transport")
        center.retry(secondID)
        snapshots.waitFor { state(secondID, in: $0) == .queued }
        center.setPaused(false)
        let firstAttempt = first.attempt()
        firstAttempt.progress(FileTransferProgress(bytesTransferred: 50))
        let half = snapshots.waitFor { $0.transfers.first { $0.id == firstID }?.bytesTransferred == 50 }
        precondition(half.transfers.first { $0.id == firstID }?.progress == 0.5)
        firstAttempt.progress(FileTransferProgress(bytesTransferred: 200))
        snapshots.waitFor { $0.transfers.first { $0.id == firstID }?.bytesTransferred == 100 }
        firstAttempt.progress(FileTransferProgress(bytesTransferred: 20, state: .connecting))
        let reset = snapshots.waitFor { $0.transfers.first { $0.id == firstID }?.bytesTransferred == 20 }
        precondition(reset.transfers.first { $0.id == firstID }?.bytesPerSecond == 0)
        firstAttempt.completion(.failure(FeiQFileTransferError.connectionFailed("interrupted")))
        let thirdAttempt = third.attempt()
        snapshots.waitFor { state(firstID, in: $0) == .failed }
        center.retry(firstID)
        center.retry(firstID)
        snapshots.waitFor { $0.queuedCount == 2 && state(firstID, in: $0) == .queued }
        center.cancel(thirdID)
        snapshots.waitFor { state(thirdID, in: $0) == .cancelling }
        precondition(thirdAttempt.cancellation.isCancelled && second.count == 0,
                     "cancelling must retain its slot until the socket has stopped")
        thirdAttempt.progress(FileTransferProgress(bytesTransferred: 90))
        thirdAttempt.completion(.failure(FeiQFileTransferError.cancelled))
        let secondAttempt = second.attempt()
        secondAttempt.completion(.success(()))
        let retried = first.attempt(1)
        retried.progress(FileTransferProgress(bytesTransferred: 30))
        snapshots.waitFor { $0.transfers.first { $0.id == firstID }?.bytesTransferred == 30 }
        firstAttempt.progress(FileTransferProgress(bytesTransferred: 99))
        firstAttempt.completion(.success(()))
        let barrier = DispatchSemaphore(value: 0)
        center.snapshot { snapshot in
            let record = snapshot.transfers.first { $0.id == firstID }!
            precondition(record.state == .transferring && record.bytesTransferred == 30 && record.attemptCount == 2,
                         "callbacks from a previous attempt must not mutate the retry")
            precondition(snapshot.transfers.first { $0.id == thirdID }?.bytesTransferred == 0)
            barrier.signal()
        }
        precondition(barrier.wait(timeout: .now() + 5) == .success)
        retried.completion(.success(()))
        snapshots.waitFor { state(firstID, in: $0) == .completed && $0.unfinishedCount == 0 }
        center.clearFinished()
        snapshots.waitFor { $0.transfers.isEmpty }
    }

    private static func checkDirectionIsolationAndLimits() {
        let center = FileTransferCenter(maximumConcurrentTransfers: 1)
        let snapshots = TransferSnapshots()
        center.observe(snapshots.record)
        let upload = ControlledTransfer()
        let nextUpload = ControlledTransfer()
        let download = ControlledTransfer()
        let nextDownload = ControlledTransfer()
        _ = center.enqueue(attachment: attachment("upload"), direction: .outgoing,
                           peerName: "Win", ipAddress: "192.0.2.1", operation: upload.start)
        _ = center.enqueue(attachment: attachment("upload-next"), direction: .outgoing,
                           peerName: "Win", ipAddress: "192.0.2.1", operation: nextUpload.start)
        upload.attempt().progress(FileTransferProgress(bytesTransferred: 0, state: .waitingForPeer))
        _ = center.enqueue(attachment: attachment("download"), direction: .incoming,
                           peerName: "Win", ipAddress: "192.0.2.1", operation: download.start)
        _ = center.enqueue(attachment: attachment("download-next"), direction: .incoming,
                           peerName: "Win", ipAddress: "192.0.2.1", operation: nextDownload.start)
        _ = download.attempt()
        snapshots.waitFor { $0.activeCount == 2 && $0.queuedCount == 2 }
        precondition(nextUpload.count == 0 && nextDownload.count == 0)
        center.setMaximumConcurrentTransfers(2)
        _ = nextUpload.attempt()
        _ = nextDownload.attempt()
        snapshots.waitFor { $0.activeCount == 4 && $0.queuedCount == 0 }
        center.setMaximumConcurrentTransfers(0)
        snapshots.waitFor { $0.maximumConcurrentTransfers == 1 && $0.activeCount == 4 }
        precondition(!upload.attempt().cancellation.isCancelled && !download.attempt().cancellation.isCancelled,
                     "lowering limits must not interrupt active transfers")
        center.setPaused(true)
        snapshots.waitFor { $0.isPaused && $0.activeCount == 4 }
        center.cancelAll()
        snapshots.waitFor { $0.unfinishedCount == 0 && $0.transfers.allSatisfy { $0.state == .cancelled } }
        center.setMaximumConcurrentTransfers(100)
        snapshots.waitFor { $0.maximumConcurrentTransfers == 6 }
    }

    private static func checkDeletionAndClearing() {
        let center = FileTransferCenter(maximumConcurrentTransfers: 1)
        let snapshots = TransferSnapshots()
        center.observe(snapshots.record)
        let failed = ControlledTransfer()
        let failedID = center.enqueue(attachment: attachment("failed"), direction: .incoming,
                                      peerName: "Win", ipAddress: "192.0.2.1", operation: failed.start)
        failed.attempt().completion(.failure(FeiQFileTransferError.fileNotFound))
        snapshots.waitFor { $0.failedCount == 1 }
        center.clearFinished()
        let barrier = DispatchSemaphore(value: 0)
        center.snapshot { snapshot in
            precondition(snapshot.transfers.count == 1 && snapshot.failedCount == 1,
                         "bulk cleanup must keep failed transfers available for retry")
            barrier.signal()
        }
        precondition(barrier.wait(timeout: .now() + 5) == .success)
        center.setPaused(true)
        center.retryFailed()
        snapshots.waitFor { state(failedID, in: $0) == .queued }
        center.remove(failedID)
        center.setPaused(false)
        failed.attempt(1).completion(.success(()))
        snapshots.waitFor { state(failedID, in: $0) == .completed }
        center.remove(failedID)
        snapshots.waitFor { $0.transfers.isEmpty }

        let messageID = UUID()
        let active = ControlledTransfer()
        let queued = ControlledTransfer()
        _ = center.enqueue(attachment: attachment("delete-active"), direction: .incoming,
                           peerName: "Win", ipAddress: "192.0.2.1", messageID: messageID, operation: active.start)
        _ = center.enqueue(attachment: attachment("delete-queued"), direction: .incoming,
                           peerName: "Win", ipAddress: "192.0.2.1", messageID: messageID, operation: queued.start)
        _ = active.attempt()
        snapshots.waitFor { $0.activeCount == 1 && $0.queuedCount == 1 }
        center.cancelTransfers(for: messageID)
        snapshots.waitFor { $0.transfers.isEmpty }
        precondition(active.attempt().cancellation.isCancelled && queued.count == 0)
    }

    private static func checkEmptyFileAndCompletionRace() {
        let center = FileTransferCenter()
        let snapshots = TransferSnapshots()
        center.observe(snapshots.record)
        let transfer = ControlledTransfer()
        transfer.completesCancellation = false
        let identifier = center.enqueue(attachment: attachment("empty", size: 0), direction: .incoming,
                                        peerName: "Win", ipAddress: "192.0.2.1", operation: transfer.start)
        let attempt = transfer.attempt()
        center.cancel(identifier)
        snapshots.waitFor { state(identifier, in: $0) == .cancelling }
        attempt.completion(.success(()))
        let completed = snapshots.waitFor { state(identifier, in: $0) == .completed }
        precondition(completed.transfers[0].progress == 1,
                     "an already committed empty file must not be reported as cancelled")
    }
}
