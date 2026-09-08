import Darwin
import Foundation

private final class LoopbackFileServer {
    let descriptor: Int32
    let port: UInt16

    init() {
        let listener = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        descriptor = listener
        precondition(listener >= 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(result == 0 && Darwin.listen(listener, 2) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(listener, $0, &length)
            }
        }
        precondition(named == 0)
        port = UInt16(bigEndian: address.sin_port)
    }

    deinit { Darwin.close(descriptor) }

    func acceptRequest() -> Int32 {
        var pending = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        precondition(Darwin.poll(&pending, 1, 5000) > 0, "loopback client did not connect")
        let client = Darwin.accept(descriptor, nil, nil)
        precondition(client >= 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while !data.contains(0) {
            let count = buffer.withUnsafeMutableBytes { Darwin.recv(client, $0.baseAddress, $0.count, 0) }
            precondition(count > 0 && data.count < 4096)
            data.append(contentsOf: buffer.prefix(count))
        }
        precondition(FeiQPacket.parse(data)?.commandType == .getFileData)
        return client
    }

    static func send(_ data: Data, on descriptor: Int32) {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.send(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                precondition(count > 0)
                offset += count
            }
        }
    }
}

private final class ProgressSamples {
    private let lock = NSLock()
    private var values: [FileTransferProgress] = []

    func record(_ progress: FileTransferProgress) {
        lock.lock()
        values.append(progress)
        lock.unlock()
    }

    var snapshot: [FileTransferProgress] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@main
enum FileTransferIOChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feiq-transfer-io-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try checkReceiveCancellation(root: root)
        try checkDownload(root: root, declaredSize: 128, payload: Data(repeating: 7, count: 17), existing: false)
        try checkDownload(root: root, declaredSize: 0, payload: Data(), existing: false)
        try checkDownload(root: root, declaredSize: 128, payload: Data(repeating: 8, count: 128), existing: true)
        try checkUpload(root: root, offset: 19)
        try checkUploadCancellation(root: root)
        checkCancellationBeforeConnection(root: root)
        print("File transfer I/O checks passed")
    }

    private static func checkReceiveCancellation(root: URL) throws {
        let server = LoopbackFileServer()
        let serverDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let client = server.acceptRequest()
            defer {
                Darwin.close(client)
                serverDone.signal()
            }
            LoopbackFileServer.send(Data(repeating: 3, count: 1024), on: client)
            var buffer = [UInt8](repeating: 0, count: 32)
            let count = buffer.withUnsafeMutableBytes { Darwin.recv(client, $0.baseAddress, $0.count, 0) }
            precondition(count == 0, "cancelling must close the receiving socket promptly")
        }
        let destination = root.appendingPathComponent("cancelled.bin")
        let receivedSomeBytes = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let service = FeiQNetworkService()
        let attachment = FeiQFileAttachment(fileID: "1", fileName: "cancelled.bin", fileSize: 4096,
                                            modifiedAt: 0, fileAttributes: 1)
        let cancellation = service.downloadFile(
            attachment, packetNumber: 123, from: "127.0.0.1", port: server.port, to: destination,
            progress: { progress in
                if progress.bytesTransferred > 0 {
                    precondition(!FileManager.default.fileExists(atPath: destination.path),
                                 "partial files must never appear at the final destination")
                    receivedSomeBytes.signal()
                }
            }, completion: { result in
                guard case .failure(let error) = result else { preconditionFailure("cancelled download succeeded") }
                precondition((error as? FeiQFileTransferError) == .cancelled)
                completed.signal()
            }
        )
        precondition(receivedSomeBytes.wait(timeout: .now() + 5) == .success)
        cancellation.cancel()
        cancellation.cancel()
        precondition(completed.wait(timeout: .now() + 2) == .success, "cancellation waited for the receive timeout")
        precondition(serverDone.wait(timeout: .now() + 2) == .success)
        precondition(!FileManager.default.fileExists(atPath: destination.path))
        try assertNoPartialFiles(root)
    }

    private static func checkDownload(root: URL, declaredSize: Int64, payload: Data, existing: Bool) throws {
        let server = LoopbackFileServer()
        let serverDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let client = server.acceptRequest()
            LoopbackFileServer.send(payload, on: client)
            Darwin.close(client)
            serverDone.signal()
        }
        let destination = root.appendingPathComponent(UUID().uuidString + ".txt")
        let original = Data("existing file".utf8)
        if existing { try original.write(to: destination) }
        let samples = ProgressSamples()
        let attachment = FeiQFileAttachment(fileID: "1", fileName: "测试文件.txt", fileSize: declaredSize,
                                            modifiedAt: 0, fileAttributes: 1)
        let request = FeiQPacket(packetNumber: 456, senderName: "Test", senderHost: "Mac",
                                command: .getFileData, additionalText: "7b:1:0", versionIdentifier: "1")
        let result = FileTransferIO.download(
            attachment, request: request.encoded(), from: "127.0.0.1", port: server.port,
            to: destination, cancellation: FileTransferCancellation(), progress: FileTransferProgressReporter(samples.record)
        )
        precondition(serverDone.wait(timeout: .now() + 5) == .success)
        if existing {
            guard case .failure = result else { preconditionFailure("download overwrote an existing file") }
            let contents = try Data(contentsOf: destination)
            precondition(contents == original)
        } else if payload.count != declaredSize {
            guard case .failure(let error) = result else { preconditionFailure("truncated download succeeded") }
            precondition((error as? FeiQFileTransferError) == .unexpectedEndOfStream(expected: declaredSize, received: Int64(payload.count)))
            precondition(!FileManager.default.fileExists(atPath: destination.path))
        } else {
            try result.get()
            let contents = try Data(contentsOf: destination)
            precondition(contents == payload)
            precondition(samples.snapshot.last?.bytesTransferred == declaredSize)
        }
        try assertNoPartialFiles(root)
    }

    private static func checkUpload(root: URL, offset: UInt64) throws {
        let sockets = socketPair()
        defer { Darwin.close(sockets[1]) }
        let payload = Data((0..<(256 * 1024)).map { UInt8($0 % 251) })
        let attachment = try makeAttachment(root: root, data: payload)
        let samples = ProgressSamples()
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let result = FileTransferIO.sendFile(
                attachment, on: sockets[0], offset: offset, cancellation: FileTransferCancellation(),
                progress: FileTransferProgressReporter(samples.record)
            )
            try! result.get()
            completed.signal()
        }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.recv(sockets[1], $0.baseAddress, $0.count, 0) }
            if count == 0 { break }
            precondition(count > 0)
            received.append(contentsOf: buffer.prefix(count))
        }
        precondition(completed.wait(timeout: .now() + 5) == .success)
        precondition(received == payload.dropFirst(Int(offset)), "upload must respect the requested hexadecimal offset")
        precondition(samples.snapshot.first?.bytesTransferred == Int64(offset))
        precondition(samples.snapshot.last?.bytesTransferred == Int64(payload.count))
        precondition(samples.snapshot.allSatisfy { $0.bytesTransferred <= payload.count })
    }

    private static func checkUploadCancellation(root: URL) throws {
        let sockets = socketPair()
        defer { Darwin.close(sockets[1]) }
        var bufferSize: Int32 = 4096
        _ = setsockopt(sockets[0], SOL_SOCKET, SO_SNDBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
        let attachment = try makeAttachment(root: root, data: Data(repeating: 4, count: 8 * 1024 * 1024))
        let cancellation = FileTransferCancellation()
        let started = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let result = FileTransferIO.sendFile(
                attachment, on: sockets[0], offset: 0, cancellation: cancellation,
                progress: FileTransferProgressReporter { _ in started.signal() }
            )
            guard case .failure(let error) = result else { preconditionFailure("cancelled upload succeeded") }
            precondition((error as? FeiQFileTransferError) == .cancelled)
            completed.signal()
        }
        precondition(started.wait(timeout: .now() + 5) == .success)
        cancellation.cancel()
        precondition(completed.wait(timeout: .now() + 2) == .success, "upload cancellation blocked on send")
        precondition(attachment.isAvailable, "cancelling an upload must not delete its source")
    }

    private static func checkCancellationBeforeConnection(root: URL) {
        let cancellation = FileTransferCancellation()
        cancellation.cancel()
        let attachment = FeiQFileAttachment(fileID: "1", fileName: "never.bin", fileSize: 1,
                                            modifiedAt: 0, fileAttributes: 1)
        let result = FileTransferIO.download(
            attachment, request: Data(), from: "192.0.2.1", port: 2425,
            to: root.appendingPathComponent("never.bin"), cancellation: cancellation,
            progress: FileTransferProgressReporter { _ in preconditionFailure("cancelled work reported progress") }
        )
        guard case .failure(let error) = result else { preconditionFailure("cancelled connection succeeded") }
        precondition((error as? FeiQFileTransferError) == .cancelled)
    }

    private static func makeAttachment(root: URL, data: Data) throws -> ChatAttachment {
        let url = root.appendingPathComponent(UUID().uuidString + ".bin")
        try data.write(to: url)
        return ChatAttachment(id: "1", kind: .file, fileName: "测试文件.bin", fileSize: Int64(data.count),
                              modifiedAt: 0, fileAttributes: 1, localPath: url.path, mimeType: "application/octet-stream")
    }

    private static func socketPair() -> [Int32] {
        var sockets = [Int32](repeating: -1, count: 2)
        let result = sockets.withUnsafeMutableBufferPointer { Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, $0.baseAddress!) }
        precondition(result == 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(sockets[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return sockets
    }

    private static func assertNoPartialFiles(_ root: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        precondition(!files.contains { $0.hasSuffix(".partial") }, "temporary download files leaked")
    }
}
