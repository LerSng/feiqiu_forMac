import Darwin
import Foundation

@main
enum FileDownloadChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("feiq-tcp-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try checkDownload(root: root, firstAttemptBytes: 0)
        try checkDownload(root: root, firstAttemptBytes: 17)
        print("File download checks passed")
    }

    private static func checkDownload(root: URL, firstAttemptBytes: Int) throws {
        let listener = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        precondition(listener >= 0)
        defer { Darwin.close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(bindResult == 0 && Darwin.listen(listener, 2) == 0)
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(listener, $0, &addressLength)
            }
        }
        precondition(nameResult == 0)
        let port = UInt16(bigEndian: address.sin_port)
        let payload = Data((0..<23663).map { UInt8($0 % 251) })
        let serverDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            defer { serverDone.signal() }
            for attempt in 0..<2 {
                var readable = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                precondition(Darwin.poll(&readable, 1, 5000) > 0, "download client did not connect")
                let client = Darwin.accept(listener, nil, nil)
                precondition(client >= 0)
                defer { Darwin.close(client) }
                var timeout = timeval(tv_sec: 5, tv_usec: 0)
                _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var requestData = Data()
                var buffer = [UInt8](repeating: 0, count: 1024)
                while !requestData.contains(0) {
                    let received = buffer.withUnsafeMutableBytes {
                        Darwin.recv(client, $0.baseAddress, $0.count, 0)
                    }
                    precondition(received > 0, "GETFILEDATA must be NUL terminated")
                    requestData.append(contentsOf: buffer.prefix(received))
                    precondition(requestData.count < 4096)
                }
                let request = FeiQPacket.parse(requestData)!
                precondition(request.versionIdentifier == "1")
                precondition(request.commandType == .getFileData)
                precondition(request.additionalText == "6a6cbfa6:a:0", "packet/file IDs must be hexadecimal")
                precondition(request.senderName == "测试Mac" && request.senderHost == "TestMac")
                var prematureClose = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
                precondition(Darwin.poll(&prematureClose, 1, 100) == 0,
                             "client must not send FIN before receiving the file")
                let response = attempt == 0
                    ? payload.prefix(firstAttemptBytes) : payload.prefix(payload.count)
                response.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let sent = Darwin.send(client, bytes.baseAddress!.advanced(by: offset), min(997, bytes.count - offset), 0)
                        precondition(sent > 0)
                        offset += sent
                    }
                }
            }
        }

        let service = FeiQNetworkService()
        service.updateIdentity(name: "测试Mac", host: "TestMac", group: "")
        let destination = root.appendingPathComponent(UUID().uuidString + ".bin")
        let attachment = FeiQFileAttachment(
            fileID: "10", fileName: "report.bin", fileSize: Int64(payload.count),
            modifiedAt: 0, fileAttributes: 1
        )
        let completed = DispatchSemaphore(value: 0)
        service.downloadFile(
            attachment, packetNumber: 0x6a6cbfa6, from: "127.0.0.1", port: port, to: destination
        ) { result in
            try! result.get()
            precondition(try! Data(contentsOf: destination) == payload, "retry must not append to partial data")
            completed.signal()
        }
        precondition(completed.wait(timeout: .now() + 15) == .success)
        precondition(serverDone.wait(timeout: .now() + 5) == .success)
        withExtendedLifetime(service) {}
    }
}
