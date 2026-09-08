import Foundation

final class FileTransferCenter {
    typealias Operation = (
        @escaping (FileTransferProgress) -> Void,
        @escaping (Result<Void, Error>) -> Void
    ) -> FileTransferCancellation

    private final class Entry {
        var record: FileTransferRecord
        let operation: Operation
        let completion: (Result<Void, Error>) -> Void
        var cancellation: FileTransferCancellation?
        var generation = UUID()
        var lastProgressAt = ProcessInfo.processInfo.systemUptime
        var removeWhenFinished = false

        init(record: FileTransferRecord, operation: @escaping Operation,
             completion: @escaping (Result<Void, Error>) -> Void) {
            self.record = record
            self.operation = operation
            self.completion = completion
        }
    }

    private let queue = DispatchQueue(label: "com.feiqmac.transfer-center", qos: .utility)
    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private var isPaused = false
    private var maximumConcurrentTransfers: Int
    private var onChange: ((FileTransferSnapshot) -> Void)?
    private var progressPublishScheduled = false

    init(maximumConcurrentTransfers: Int = 3) {
        self.maximumConcurrentTransfers = min(6, max(1, maximumConcurrentTransfers))
    }

    func observe(_ handler: @escaping (FileTransferSnapshot) -> Void) {
        queue.async {
            self.onChange = handler
            self.publish()
        }
    }

    func snapshot(_ completion: @escaping (FileTransferSnapshot) -> Void) {
        queue.async { completion(self.makeSnapshot()) }
    }

    @discardableResult
    func enqueue(
        attachment: ChatAttachment,
        direction: FileTransferDirection,
        peerName: String,
        ipAddress: String,
        messageID: UUID? = nil,
        operation: @escaping Operation,
        completion: @escaping (Result<Void, Error>) -> Void = { _ in }
    ) -> UUID {
        let identifier = UUID()
        queue.async {
            let record = FileTransferRecord(
                id: identifier, attachment: attachment, direction: direction,
                peerName: peerName, ipAddress: ipAddress, messageID: messageID, createdAt: Date()
            )
            self.entries[identifier] = Entry(record: record, operation: operation, completion: completion)
            self.order.append(identifier)
            self.schedule()
        }
        return identifier
    }

    func setPaused(_ paused: Bool) {
        queue.async {
            self.isPaused = paused
            self.schedule()
        }
    }

    func setMaximumConcurrentTransfers(_ count: Int) {
        queue.async {
            self.maximumConcurrentTransfers = min(6, max(1, count))
            self.schedule()
        }
    }

    func moveToFront(_ identifier: UUID) {
        queue.async {
            guard self.entries[identifier]?.record.state == .queued else { return }
            self.order.removeAll { $0 == identifier }
            self.order.insert(identifier, at: 0)
            self.publish()
        }
    }

    func move(_ identifier: UUID, by offset: Int) {
        queue.async {
            guard let direction = self.entries[identifier]?.record.direction else { return }
            let queued = self.order.filter {
                self.entries[$0]?.record.state == .queued && self.entries[$0]?.record.direction == direction
            }
            guard let current = queued.firstIndex(of: identifier),
                  queued.indices.contains(current + offset),
                  let source = self.order.firstIndex(of: identifier),
                  let destination = self.order.firstIndex(of: queued[current + offset]) else { return }
            self.order.swapAt(source, destination)
            self.publish()
        }
    }

    func cancel(_ identifier: UUID) {
        queue.async {
            self.cancelEntry(identifier)
            self.schedule()
        }
    }

    func cancelAll(pauseQueue: Bool = false) {
        queue.async {
            if pauseQueue { self.isPaused = true }
            for identifier in self.order {
                self.cancelEntry(identifier)
            }
            self.schedule()
        }
    }

    func cancelTransfers(for messageID: UUID) {
        queue.async {
            for identifier in self.order where self.entries[identifier]?.record.messageID == messageID {
                self.entries[identifier]?.removeWhenFinished = true
                self.cancelEntry(identifier)
                if self.entries[identifier]?.record.state.isFinished == true {
                    self.entries.removeValue(forKey: identifier)
                }
            }
            self.order.removeAll { self.entries[$0] == nil }
            self.schedule()
        }
    }

    func retry(_ identifier: UUID) {
        queue.async {
            self.prepareRetry(identifier)
            self.schedule()
        }
    }

    func retryFailed() {
        queue.async {
            let identifiers = self.order.filter { self.entries[$0]?.record.state == .failed }
            for identifier in identifiers {
                self.prepareRetry(identifier)
            }
            self.schedule()
        }
    }

    func remove(_ identifier: UUID) {
        queue.async {
            guard self.entries[identifier]?.record.state.isFinished == true else { return }
            self.entries.removeValue(forKey: identifier)
            self.order.removeAll { $0 == identifier }
            self.publish()
        }
    }

    func clearFinished() {
        queue.async {
            let identifiers = self.order.filter {
                let state = self.entries[$0]?.record.state
                return state == .completed || state == .cancelled
            }
            for identifier in identifiers {
                self.entries.removeValue(forKey: identifier)
            }
            self.order.removeAll { self.entries[$0] == nil }
            self.publish()
        }
    }

    private func prepareRetry(_ identifier: UUID) {
        guard let entry = entries[identifier], entry.record.state.canRetry else { return }
        entry.record.state = .queued
        entry.record.bytesTransferred = 0
        entry.record.bytesPerSecond = 0
        entry.record.errorMessage = nil
        entry.record.startedAt = nil
        entry.record.finishedAt = nil
        order.removeAll { $0 == identifier }
        order.append(identifier)
    }

    private func cancelEntry(_ identifier: UUID) {
        guard let entry = entries[identifier], entry.record.state.canCancel else { return }
        entry.record.bytesPerSecond = 0
        if entry.record.state == .queued {
            entry.record.state = .cancelled
            entry.record.finishedAt = Date()
            entry.completion(.failure(FeiQFileTransferError.cancelled))
        } else {
            entry.record.state = .cancelling
            entry.cancellation?.cancel()
        }
    }

    private func schedule() {
        if !isPaused {
            var incomingSlots = maximumConcurrentTransfers - entries.values.filter {
                $0.record.direction == .incoming && $0.record.state.isActive
            }.count
            var outgoingSlots = maximumConcurrentTransfers - entries.values.filter {
                $0.record.direction == .outgoing && $0.record.state.isActive
            }.count
            for identifier in order {
                guard let entry = entries[identifier], entry.record.state == .queued else { continue }
                if entry.record.direction == .incoming {
                    guard incomingSlots > 0 else { continue }
                    incomingSlots -= 1
                } else {
                    guard outgoingSlots > 0 else { continue }
                    outgoingSlots -= 1
                }
                start(entry)
            }
        }
        publish()
    }

    private func start(_ entry: Entry) {
        entry.generation = UUID()
        let generation = entry.generation
        let identifier = entry.record.id
        entry.record.state = .connecting
        entry.record.attemptCount += 1
        entry.record.startedAt = Date()
        entry.lastProgressAt = ProcessInfo.processInfo.systemUptime
        entry.cancellation = entry.operation({ [weak self] progress in
            self?.queue.async { [weak self] in
                self?.update(identifier, generation: generation, progress: progress)
            }
        }, { [weak self] result in
            self?.queue.async { [weak self] in
                self?.finish(identifier, generation: generation, result: result)
            }
        })
    }

    private func update(_ identifier: UUID, generation: UUID, progress: FileTransferProgress) {
        guard let entry = entries[identifier], entry.generation == generation,
              entry.record.state.isActive, entry.record.state != .cancelling,
              [.connecting, .waitingForPeer, .transferring].contains(progress.state) else { return }
        let bytes = min(max(0, progress.bytesTransferred), max(0, entry.record.attachment.fileSize))
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - entry.lastProgressAt
        let difference = bytes - entry.record.bytesTransferred
        entry.record.bytesPerSecond = progress.state == .transferring && difference > 0 && elapsed > 0
            ? Double(difference) / elapsed : 0
        entry.lastProgressAt = now
        entry.record.bytesTransferred = bytes
        entry.record.state = progress.state
        if !progressPublishScheduled {
            progressPublishScheduled = true
            queue.asyncAfter(deadline: .now() + 0.1) {
                self.progressPublishScheduled = false
                self.publish()
            }
        }
    }

    private func finish(_ identifier: UUID, generation: UUID, result: Result<Void, Error>) {
        guard let entry = entries[identifier], entry.generation == generation,
              entry.record.state.isActive else { return }
        let finalResult: Result<Void, Error>
        if case .failure = result, entry.record.state == .cancelling {
            finalResult = .failure(FeiQFileTransferError.cancelled)
        } else {
            finalResult = result
        }
        entry.cancellation?.finish()
        entry.cancellation = nil
        entry.record.bytesPerSecond = 0
        entry.record.finishedAt = Date()
        switch finalResult {
        case .success:
            entry.record.state = .completed
            entry.record.bytesTransferred = max(0, entry.record.attachment.fileSize)
            entry.record.errorMessage = nil
        case .failure(let error):
            entry.record.state = (error as? FeiQFileTransferError) == .cancelled ? .cancelled : .failed
            entry.record.errorMessage = entry.record.state == .failed ? error.localizedDescription : nil
        }
        entry.completion(finalResult)
        if entry.removeWhenFinished {
            entries.removeValue(forKey: identifier)
            order.removeAll { $0 == identifier }
        }
        schedule()
    }

    private func makeSnapshot() -> FileTransferSnapshot {
        FileTransferSnapshot(
            transfers: order.compactMap { entries[$0]?.record },
            isPaused: isPaused,
            maximumConcurrentTransfers: maximumConcurrentTransfers
        )
    }

    private func publish() {
        onChange?(makeSnapshot())
    }
}
