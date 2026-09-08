import Darwin
import Foundation

enum FileTransferIO {
    static func download(
        _ attachment: FeiQFileAttachment,
        request: Data,
        from ipAddress: String,
        port: UInt16,
        to destinationURL: URL,
        cancellation: FileTransferCancellation,
        progress: FileTransferProgressReporter
    ) -> Result<Void, Error> {
        guard !cancellation.isCancelled else { return .failure(FeiQFileTransferError.cancelled) }
        guard attachment.isRegularFile, attachment.fileSize >= 0,
              attachment.fileSize <= 2 * 1024 * 1024 * 1024 else {
            return .failure(FeiQFileTransferError.requestFailed("不是普通文件或超过 2 GB 限制"))
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard ipAddress.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            return .failure(FeiQFileTransferError.invalidAddress)
        }
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { return .failure(FeiQFileTransferError.socketCreation) }
        guard cancellation.attachSocket(descriptor) else {
            Darwin.close(descriptor)
            return .failure(FeiQFileTransferError.cancelled)
        }
        defer { cancellation.closeSocket(descriptor) }
        configureSocket(descriptor)
        progress.report(0, state: .connecting, force: true)

        do {
            try connect(descriptor, address: &address, cancellation: cancellation)
            try sendAll(request, on: descriptor, cancellation: cancellation)
            return try receive(attachment, on: descriptor, to: destinationURL,
                               cancellation: cancellation, progress: progress)
        } catch {
            return .failure(cancellation.isCancelled ? FeiQFileTransferError.cancelled : error)
        }
    }

    static func sendFile(
        _ attachment: ChatAttachment,
        on descriptor: Int32,
        offset: UInt64,
        cancellation: FileTransferCancellation,
        progress: FileTransferProgressReporter
    ) -> Result<Void, Error> {
        guard cancellation.attachSocket(descriptor) else {
            Darwin.close(descriptor)
            return .failure(FeiQFileTransferError.cancelled)
        }
        defer { cancellation.closeSocket(descriptor) }
        configureSocket(descriptor)
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
            return .failure(FeiQFileTransferError.socketCreation)
        }
        do {
            guard attachment.fileSize >= 0, offset <= UInt64(attachment.fileSize) else {
                throw FeiQFileTransferError.requestFailed("文件偏移量无效")
            }
            let handle = try FileHandle(forReadingFrom: attachment.localURL)
            defer { try? handle.close() }
            guard try handle.seekToEnd() == UInt64(attachment.fileSize) else {
                throw FeiQFileTransferError.requestFailed("本地文件大小已改变，请重新添加文件")
            }
            try handle.seek(toOffset: offset)
            var sentBytes = Int64(offset)
            progress.report(sentBytes, force: true)
            while sentBytes < attachment.fileSize {
                guard !cancellation.isCancelled else { throw FeiQFileTransferError.cancelled }
                let size = Int(min(64 * 1024, attachment.fileSize - sentBytes))
                let chunk = try handle.read(upToCount: size) ?? Data()
                guard !chunk.isEmpty else { throw FeiQFileTransferError.fileNotFound }
                try sendAll(chunk, on: descriptor, cancellation: cancellation)
                sentBytes += Int64(chunk.count)
                progress.report(sentBytes)
            }
            guard !cancellation.isCancelled else { throw FeiQFileTransferError.cancelled }
            progress.report(sentBytes, force: true)
            _ = Darwin.shutdown(descriptor, SHUT_WR)
            return .success(())
        } catch {
            return .failure(cancellation.isCancelled ? FeiQFileTransferError.cancelled : error)
        }
    }

    private static func receive(
        _ attachment: FeiQFileAttachment,
        on descriptor: Int32,
        to destinationURL: URL,
        cancellation: FileTransferCancellation,
        progress: FileTransferProgressReporter
    ) throws -> Result<Void, Error> {
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).partial")
        let manager = FileManager.default
        defer { try? manager.removeItem(at: temporaryURL) }
        do {
            try manager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fileDescriptor = Darwin.open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            guard fileDescriptor >= 0 else {
                throw FeiQFileTransferError.fileWriteFailed(String(cString: strerror(errno)))
            }
            let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var receivedBytes: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            progress.report(0, force: true)
            while receivedBytes < attachment.fileSize {
                guard !cancellation.isCancelled else { throw FeiQFileTransferError.cancelled }
                let count = buffer.withUnsafeMutableBytes { rawBuffer in
                    Darwin.recv(descriptor, rawBuffer.baseAddress,
                                min(rawBuffer.count, Int(attachment.fileSize - receivedBytes)), 0)
                }
                if count > 0 {
                    try handle.write(contentsOf: Data(buffer.prefix(count)))
                    receivedBytes += Int64(count)
                    progress.report(receivedBytes)
                } else if count == 0 {
                    throw FeiQFileTransferError.unexpectedEndOfStream(
                        expected: attachment.fileSize, received: receivedBytes
                    )
                } else if errno != EINTR {
                    throw FeiQFileTransferError.connectionFailed(String(cString: strerror(errno)))
                }
            }
            try handle.synchronize()
            try handle.close()
            guard !cancellation.isCancelled else { throw FeiQFileTransferError.cancelled }
            try manager.moveItem(at: temporaryURL, to: destinationURL)
            progress.report(receivedBytes, force: true)
            return .success(())
        } catch let error as FeiQFileTransferError {
            throw error
        } catch {
            throw FeiQFileTransferError.fileWriteFailed(error.localizedDescription)
        }
    }

    private static func connect(
        _ descriptor: Int32,
        address: inout sockaddr_in,
        cancellation: FileTransferCancellation
    ) throws {
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw FeiQFileTransferError.socketCreation
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else {
                throw FeiQFileTransferError.connectionFailed(String(cString: strerror(errno)))
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            while true {
                guard !cancellation.isCancelled else { throw FeiQFileTransferError.cancelled }
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw FeiQFileTransferError.connectionFailed("连接超时，请检查对方防火墙及 TCP 端口")
                }
                var pending = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let ready = Darwin.poll(&pending, 1, 100)
                if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                var socketError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard ready > 0,
                      getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0,
                      socketError == 0 else {
                    throw FeiQFileTransferError.connectionFailed(String(cString: strerror(socketError == 0 ? errno : socketError)))
                }
                break
            }
        }
        guard fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
            throw FeiQFileTransferError.socketCreation
        }
    }

    private static func configureSocket(_ descriptor: Int32) {
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 60, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func sendAll(_ data: Data, on descriptor: Int32, cancellation: FileTransferCancellation) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                guard !cancellation.isCancelled else { throw FeiQFileTransferError.cancelled }
                let count = Darwin.send(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if count > 0 {
                    offset += count
                } else if count == 0 || errno != EINTR {
                    throw FeiQFileTransferError.connectionFailed(String(cString: strerror(errno)))
                }
            }
        }
    }
}
