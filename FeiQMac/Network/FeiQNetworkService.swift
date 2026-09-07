import Darwin
import Foundation

enum FeiQTransport: String, Sendable {
    case udp
    case tcp
}

enum FeiQFileTransferError: LocalizedError {
    case invalidAddress
    case socketCreation
    case connectionFailed(String)
    case requestFailed(String)
    case fileNotFound
    case fileWriteFailed(String)
    case unexpectedEndOfStream(expected: Int64, received: Int64)

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "文件传输地址无效"
        case .socketCreation:
            return "无法创建文件传输连接"
        case .connectionFailed(let message):
            return "文件传输连接失败：\(message)"
        case .requestFailed(let message):
            return "文件请求失败：\(message)"
        case .fileNotFound:
            return "待发送的文件不存在"
        case .fileWriteFailed(let message):
            return "接收文件保存失败：\(message)"
        case .unexpectedEndOfStream(let expected, let received):
            let hint = received == 0 ? "；TCP 已连接，但对方关闭连接且未返回文件数据，请确认文件仍在对方的发送列表中" : ""
            return "文件传输不完整（需要 \(expected) 字节，实际收到 \(received) 字节）\(hint)"
        }
    }
}

protocol FeiQNetworkServiceProtocol: FeiQNetworkEventSource {
    func start(name: String, host: String, group: String)
    func stop()
    func updateIdentity(name: String, host: String, group: String)
    func announce()
    func replyToEntry(from ipAddress: String)
    func sendTyping(isTyping: Bool, to ipAddress: String)
    func sendShake(to ipAddress: String)
    func sendText(_ text: String, to ipAddress: String, recipientName: String?)
    func sendFileMessage(
        _ text: String,
        attachments: [ChatAttachment],
        to ipAddress: String,
        recipientName: String?
    )
    func downloadFile(
        _ attachment: FeiQFileAttachment,
        packetNumber: UInt64,
        from ipAddress: String,
        to destinationURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    )
    func downloadFile(
        _ attachment: FeiQFileAttachment,
        packetNumber: UInt64,
        from ipAddress: String,
        port: UInt16,
        to destinationURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    )
    func acknowledge(_ packet: FeiQPacket, to ipAddress: String)
}

extension FeiQNetworkServiceProtocol {
    /// Older test transports and alternative implementations can continue to
    /// use the standard port. FeiQ itself may be configured with another
    /// port, which is why the real service receives the UDP source port.
    func downloadFile(
        _ attachment: FeiQFileAttachment,
        packetNumber: UInt64,
        from ipAddress: String,
        port: UInt16,
        to destinationURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        downloadFile(
            attachment,
            packetNumber: packetNumber,
            from: ipAddress,
            to: destinationURL,
            completion: completion
        )
    }
}

final class FeiQNetworkService: FeiQNetworkServiceProtocol {
    static let port: UInt16 = 2425

    var onPacket: ((FeiQPacket, String, FeiQTransport, UInt16) -> Void)?
    var onInlineImage: ((Data, String, Int, FeiQPacket, String) -> Void)?
    private let imageAssembler = FeiQInlineImageAssembler()
    private var imageSends: [String: FeiQInlineImageSendSession] = [:]
    private var imageTimer: DispatchSourceTimer?
    private var imageMarkers: [UInt64: (packet: FeiQPacket, ip: String, sentAt: Date, attempts: Int)] = [:]
    private let downloadQueue = DispatchQueue(label: "com.feiqmac.file-downloads", qos: .utility)
    var onLog: ((String) -> Void)?
    var onStateChange: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "com.feiqmac.network", qos: .userInitiated)
    private var udpSocket: Int32 = -1
    private var tcpSocket: Int32 = -1
    private var udpSource: DispatchSourceRead?
    private var tcpSource: DispatchSourceRead?
    private var heartbeatTimer: DispatchSourceTimer?
    private var clientSources: [Int32: DispatchSourceRead] = [:]
    private var clientBuffers: [Int32: Data] = [:]
    private var clientAddresses: [Int32: String] = [:]
    private struct OutgoingFileKey: Hashable {
        let packetNumber: UInt64
        let fileID: UInt64
    }

    /// A file attachment is requested with the original message packet ID
    /// and the attachment ID. Keeping both prevents a stale/duplicated file
    /// ID from exposing the wrong local file.
    private var outgoingFilesByKey: [OutgoingFileKey: URL] = [:]
    private static let maximumFileBytes: Int64 = 2 * 1024 * 1024 * 1024
    private var packetCounter: UInt32 = 0
    private var running = false

    // FeiQ extends the normal IPMSG version field with a stable device
    // identifier. It is persisted so restarting the app does not create a
    // second identity in Windows FeiQ's user list.
    private let localDeviceIdentifier = FeiQNetworkService.persistentDeviceIdentifier()

    private var localName = "飞秋 Mac"
    private var localHost = "Mac"
    private var localGroup = ""

    private var feiQVersionIdentifier: String {
        "1_lbt6_0#128#\(localDeviceIdentifier)#0#0#0#4001#9"
    }

    private var entryAdditionalText: String {
        localGroup.isEmpty ? localName : "\(localName)\u{0}\(localGroup)"
    }

    deinit {
        stop()
    }

    func start(name: String, host: String, group: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.localName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "飞秋 Mac" : name
            self.localHost = host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Mac" : host
            self.localGroup = group.trimmingCharacters(in: .whitespacesAndNewlines)
            self.startInternal()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopInternal(announceExit: true)
        }
    }

    func updateIdentity(name: String, host: String, group: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.localName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "飞秋 Mac" : name
            self.localHost = host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Mac" : host
            self.localGroup = group.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func announce() {
        queue.async { [weak self] in
            self?.sendEntryInternal()
        }
    }

    func replyToEntry(from ipAddress: String) {
        queue.async { [weak self] in
            self?.sendAnswerEntryInternal(to: ipAddress)
        }
    }

    func sendShake(to ipAddress: String) {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            let packet = FeiQPacket(
                packetNumber: self.nextPacketNumber(), senderName: self.localName,
                senderHost: self.localHost, command: .shake,
                versionIdentifier: self.feiQVersionIdentifier
            )
            if self.sendUDP(packet.encoded(), to: ipAddress) {
                self.emitLog("UDP → \(ipAddress)：已发送抖一抖（等待确认）")
            }
        }
    }

    func sendTyping(isTyping: Bool, to ipAddress: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let command: FeiQCommand = isTyping ? .inputting : .inputEnd
            let packet = FeiQPacket(
                versionIdentifier: self.feiQVersionIdentifier,
                packetNumber: self.nextPacketNumber(),
                senderName: self.localName,
                senderHost: self.localHost,
                command: command.rawValue,
                // FeiQ expects the control packet payload to be empty or a
                // single NUL. FeiQPacket.encoded() adds the terminator too,
                // so this produces the compatible single-NUL payload.
                additionalData: Data([0])
            )
            guard self.sendUDP(packet.encoded(), to: ipAddress) else { return }
            let stateDescription = isTyping ? "正在输入" : "停止输入"
            self.emitLog("UDP → \(ipAddress)：已发送\(stateDescription)状态")
        }
    }

    func sendText(_ text: String, to ipAddress: String, recipientName: String? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let displayRecipient: String
            if let recipientName {
                let trimmed = recipientName.trimmingCharacters(in: .whitespacesAndNewlines)
                displayRecipient = trimmed.isEmpty ? ipAddress : trimmed
            } else {
                displayRecipient = ipAddress
            }
            // FeiQ 2013 Windows decodes legacy message packets as GB18030.
            // It may ignore the IPMSG UTF-8 option and display UTF-8 bytes as
            // mojibake (for example, "真的吗？" becoming "鐪熺殑鍚?").
            // Known FeiQ emoticons have already been converted to ASCII codes
            // before this method, so keep the whole message packet in the
            // legacy encoding expected by Windows.
            let messageCommand = FeiQCommand.sendMessage.rawValue
                | FeiQPacket.sendCheckOption
            let packet = FeiQPacket(
                versionIdentifier: self.feiQVersionIdentifier,
                packetNumber: self.nextPacketNumber(),
                senderName: self.localName,
                senderHost: self.localHost,
                command: messageCommand,
                additionalData: GBKCodec.encode(text)
            )
            // IPMSG/FeiQ text packets and receipts are UDP datagrams. TCP
            // port 2425 is reserved for the subsequent file-data stream.
            let success = self.sendUDP(packet.encoded(), to: ipAddress)
            if success {
                self.emitLog("UDP → \(self.localName) → \(displayRecipient)（\(ipAddress)）：已发送文字消息（等待回执）")
            } else {
                self.emitLog("UDP → \(self.localName) → \(displayRecipient)（\(ipAddress)）：文字消息发送失败")
            }
        }
    }

    func sendFileMessage(
        _ text: String,
        attachments: [ChatAttachment],
        to ipAddress: String,
        recipientName: String?
    ) {
        queue.async { [weak self] in
            guard let self else { return }

            guard self.running, !attachments.isEmpty else {
                self.emitLog("附件未发送：网络未启动或没有附件")
                return
            }

            // Pasted images use FeiQ's private UDP image protocol so that the
            // Windows client renders them directly. A message containing a
            // normal file uses the standard IPMsg attachment protocol. If a
            // draft mixes both kinds, sending all items as standard files is
            // intentional: one SENDMSG packet can then be downloaded without
            // splitting the user's message into two conversations.
            if attachments.allSatisfy({ $0.kind == .image }) {
                self.sendInlineImageMessage(
                    text,
                    attachments: attachments,
                    to: ipAddress,
                    recipientName: recipientName
                )
            } else {
                self.sendRegularFileMessage(
                    text,
                    attachments: attachments,
                    to: ipAddress,
                    recipientName: recipientName
                )
            }
        }
    }

    private func sendInlineImageMessage(
        _ text: String,
        attachments: [ChatAttachment],
        to ipAddress: String,
        recipientName: String?
    ) {
        guard imageSends.count + attachments.count <= 32 else {
            emitLog("图片未发送：待发送图片过多")
            return
        }

            var sessions: [FeiQInlineImageSendSession] = []
            do {
                for attachment in attachments {
                    let data = try Data(contentsOf: attachment.localURL, options: .mappedIfSafe)
                    guard !data.isEmpty, data.count <= FeiQInlineImageCodec.maximumBytes else {
                        self.emitLog("图片未发送：大小超过 20 MB")
                        return
                    }
                    let imageID = String(format: "%08x", UInt32.random(in: 1...UInt32.max))
                    sessions.append(FeiQInlineImageSendSession(imageID: imageID, ipAddress: ipAddress, data: data))
                }
            } catch {
                self.emitLog("读取发送图片失败：\(error.localizedDescription)")
                return
            }
            guard (self.imageSends.values.reduce(0) { $0 + $1.data.count }) + sessions.reduce(0, { $0 + $1.data.count }) <= 64 * 1024 * 1024 else {
                emitLog("待发送图片总大小超过 64 MB，请稍后发送")
                return
            }
            let command = FeiQCommand.sendMessage.rawValue | FeiQPacket.sendCheckOption
            let packet = FeiQPacket(
                versionIdentifier: self.feiQVersionIdentifier,
                packetNumber: self.nextPacketNumber(),
                senderName: self.localName,
                senderHost: self.localHost,
                command: command,
                additionalData: GBKCodec.encode(FeiQMessageFormatter.wireText(text) + sessions.map { FeiQInlineImageCodec.marker(for: $0.imageID) }.joined())
            )
            let success = self.sendUDP(packet.encoded(), to: ipAddress)
            if success {
                for session in sessions { self.imageSends[ipAddress + "/" + session.imageID] = session }
                self.imageMarkers[packet.packetNumber] = (packet, ipAddress, Date(), 1)
                self.emitLog("UDP → \(recipientName ?? ipAddress)：开始发送内嵌图片（逐片等待确认）")
                self.pumpImageSends()
            } else {
                emitLog("UDP → \(ipAddress)：图片标记消息发送失败")
            }
    }

    private func sendRegularFileMessage(
        _ text: String,
        attachments: [ChatAttachment],
        to ipAddress: String,
        recipientName: String?
    ) {
        guard attachments.count <= 32 else {
            emitLog("文件未发送：一次最多发送 32 个文件")
            return
        }

        var descriptors: [FeiQFileAttachment] = []
        descriptors.reserveCapacity(attachments.count)

        for attachment in attachments {
            guard attachment.isAvailable else {
                emitLog("文件未发送：文件不存在 \(attachment.fileName)")
                return
            }

            guard let fileID = numericFileID(attachment.id) else {
                emitLog("文件未发送：文件 ID 无效 \(attachment.fileName)")
                return
            }

            do {
                let values = try attachment.localURL.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .fileSizeKey
                ])
                guard values.isRegularFile == true,
                      let fileSize = values.fileSize,
                      Int64(fileSize) >= 0,
                      Int64(fileSize) <= Self.maximumFileBytes else {
                    emitLog("文件未发送：不是普通文件或超过 2 GB 限制 \(attachment.fileName)")
                    return
                }

                descriptors.append(
                    FeiQFileAttachment(
                        fileID: String(fileID),
                        fileName: attachment.fileName,
                        fileSize: Int64(fileSize),
                        modifiedAt: attachment.modifiedAt,
                        fileAttributes: attachment.fileAttributes == 0
                            ? 0x00000001
                            : attachment.fileAttributes
                    )
                )
            } catch {
                emitLog("文件未发送：无法读取 \(attachment.fileName)：\(error.localizedDescription)")
                return
            }
        }

        let packetNumber = nextPacketNumber()
        let packet = FeiQPacket(
            versionIdentifier: feiQVersionIdentifier,
            packetNumber: packetNumber,
            senderName: localName,
            senderHost: localHost,
            command: FeiQCommand.sendMessage.rawValue
                | FeiQPacket.sendCheckOption
                | FeiQPacket.fileAttachOption,
            additionalData: FeiQAttachmentCodec.encode(
                message: FeiQMessageFormatter.wireText(text),
                attachments: descriptors,
                preferUTF8: false
            )
        )

        guard sendUDP(packet.encoded(), to: ipAddress) else {
            emitLog("UDP → \(ipAddress)：文件通知发送失败")
            return
        }

        for (attachment, descriptor) in zip(attachments, descriptors) {
            guard let fileID = numericFileID(descriptor.fileID) else { continue }
            outgoingFilesByKey[
                OutgoingFileKey(packetNumber: packetNumber, fileID: fileID)
            ] = attachment.localURL
        }

        let names = descriptors.map(\.fileName).joined(separator: "、")
        emitLog(
            "UDP → \(localName) → \(recipientName ?? ipAddress)（\(ipAddress)）：已发送文件通知（\(names)）"
        )
    }

    func downloadFile(
        _ attachment: FeiQFileAttachment,
        packetNumber: UInt64,
        from ipAddress: String,
        to destinationURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        downloadFile(
            attachment,
            packetNumber: packetNumber,
            from: ipAddress,
            port: Self.port,
            to: destinationURL,
            completion: completion
        )
    }

    func downloadFile(
        _ attachment: FeiQFileAttachment,
        packetNumber: UInt64,
        from ipAddress: String,
        port: UInt16,
        to destinationURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let fileID = self.numericFileID(attachment.fileID) else {
                completion(.failure(FeiQFileTransferError.requestFailed("文件 ID 无效")))
                return
            }
            let request = FeiQPacket(packetNumber: self.nextPacketNumber(), senderName: self.localName,
                                     senderHost: self.localHost, command: .getFileData,
                                     additionalText: "\(String(packetNumber, radix: 16)):\(String(fileID, radix: 16)):0",
                                     versionIdentifier: "1")
            self.downloadQueue.async {
                // Most FeiQ installations use 2425, but some Windows builds
                // bind the TCP listener to the same port advertised by the
                // incoming UDP packet. Try that port first, then the standard
                // port so one misconfigured peer does not block transfers.
                let firstPort = port == 0 ? Self.port : port
                let candidatePorts = firstPort == Self.port
                    ? [Self.port]
                    : [firstPort, Self.port]
                var finalResult: Result<Void, Error>?

                for (index, candidatePort) in candidatePorts.enumerated() {
                    var result: Result<Void, Error> = .failure(
                        FeiQFileTransferError.connectionFailed("未尝试连接")
                    )
                    for attempt in 1...2 {
                        result = self.downloadFileInternal(
                            attachment,
                            request: request,
                            from: ipAddress,
                            port: candidatePort,
                            to: destinationURL
                        )
                        finalResult = result

                        if case .success = result {
                            break
                        }

                        if case .failure(let error) = result {
                            self.emitLog(
                                "TCP ← \(ipAddress):\(candidatePort)：文件 \(attachment.fileName)，请求 \(request.additionalText)，第 \(attempt) 次失败：\(error.localizedDescription)"
                            )
                        }

                        if attempt < 2 {
                            self.emitLog(
                                "TCP → \(ipAddress):\(candidatePort)：文件接收失败，正在重试（2/2）"
                            )
                            usleep(250_000)
                        }
                    }

                    if case .success = result {
                        break
                    }

                    if index < candidatePorts.count - 1 {
                        self.emitLog(
                            "TCP → \(ipAddress):\(candidatePort)：连接失败，正在尝试标准端口 \(Self.port)"
                        )
                    }
                }

                completion(
                    finalResult
                        ?? .failure(FeiQFileTransferError.connectionFailed("没有可用的文件传输端口"))
                )
            }
        }
    }

    private func pumpImageSends() {
        for (number, marker) in imageMarkers where Date().timeIntervalSince(marker.sentAt) >= 1 {
            if marker.attempts >= 8 {
                imageMarkers.removeValue(forKey: number)
                emitLog("图片标记消息未收到确认：\(marker.ip)")
            } else {
                _ = sendUDP(marker.packet.encoded(), to: marker.ip)
                imageMarkers[number] = (marker.packet, marker.ip, Date(), marker.attempts + 1)
            }
        }
        for (key, session) in imageSends {
            for index in session.nextChunks() {
                let packet = FeiQPacket(versionIdentifier: feiQVersionIdentifier, packetNumber: nextPacketNumber(),
                                        senderName: localName, senderHost: localHost,
                                        command: FeiQCommand.inlineImage.rawValue | FeiQPacket.fileAttachOption,
                                        additionalData: FeiQInlineImageCodec.encode(imageID: session.imageID, data: session.data, index: index))
                _ = sendUDP(packet.encoded(), to: session.ipAddress)
            }
            if session.failed || session.isComplete {
                imageSends.removeValue(forKey: key)
                emitLog("UDP → \(session.ipAddress)：图片 \(session.imageID) " + (session.failed ? "发送失败：重试后仍未收到分片确认" : "发送完成，所有分片已确认"))
            }
        }
    }

    func acknowledge(_ packet: FeiQPacket, to ipAddress: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let acknowledgement = FeiQPacket(
                packetNumber: self.nextPacketNumber(),
                senderName: self.localName,
                senderHost: self.localHost,
                command: .receiveMessage,
                additionalText: String(packet.packetNumber),
                versionIdentifier: self.feiQVersionIdentifier
            )
            if self.sendUDP(acknowledgement.encoded(), to: ipAddress) {
                let sender = packet.senderName.isEmpty ? ipAddress : packet.senderName
                self.emitLog("UDP → \(self.localName) → \(sender)（\(ipAddress)）：已发送消息接收回执 \(packet.packetNumber)")
            }
        }
    }

    // MARK: - Socket lifecycle

    private func startInternal() {
        stopInternal(announceExit: false)

        guard let udp = makeUDPSocket() else {
            emitLog("UDP 2425 监听失败：\(String(cString: strerror(errno)))")
            emitState(false)
            return
        }
        guard let tcp = makeTCPListener() else {
            Darwin.close(udp)
            emitLog("TCP 2425 监听失败：\(String(cString: strerror(errno)))")
            emitState(false)
            return
        }

        udpSocket = udp
        tcpSocket = tcp
        installUDPSource(for: udp)
        installTCPSource(for: tcp)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: .seconds(30))
        timer.setEventHandler { [weak self] in
            self?.sendEntryInternal()
        }
        timer.resume()
        heartbeatTimer = timer

        running = true
        let imageTimer = DispatchSource.makeTimerSource(queue: queue)
        imageTimer.schedule(deadline: .now(), repeating: .milliseconds(100))
        imageTimer.setEventHandler { [weak self] in
            self?.pumpImageSends()
            self?.imageAssembler.prune()
        }
        imageTimer.resume()
        self.imageTimer = imageTimer
        emitState(true)
        emitLog("本机 IPv4：\(localIPv4Addresses().joined(separator: ", "))")
        emitLog("广播地址：\(broadcastAddresses().joined(separator: ", "))")
        emitLog("飞秋设备标识：\(localDeviceIdentifier)")
        emitLog("已监听 UDP/TCP 2425，正在广播上线信息")
        sendEntryInternal()
    }

    private func stopInternal(announceExit: Bool) {
        imageTimer?.cancel()
        imageTimer = nil
        imageSends.removeAll()
        imageMarkers.removeAll()
        imageAssembler.clear()
        if announceExit, running {
            sendExitInternal()
        }

        heartbeatTimer?.cancel()
        heartbeatTimer = nil

        udpSource?.cancel()
        udpSource = nil
        if udpSocket >= 0 {
            Darwin.close(udpSocket)
            udpSocket = -1
        }
        tcpSource?.cancel()
        tcpSource = nil
        if tcpSocket >= 0 {
            Darwin.close(tcpSocket)
            tcpSocket = -1
        }

        for (descriptor, source) in clientSources {
            source.cancel()
            Darwin.close(descriptor)
        }
        clientSources.removeAll()
        clientBuffers.removeAll()
        clientAddresses.removeAll()
        // A single attachment can be requested by several recipients (for
        // example, when sending a group image). Keep the URL index for the
        // lifetime of this network session instead of removing it when the
        // first recipient sends RELEASEFILES.
        outgoingFilesByKey.removeAll()

        let wasRunning = running
        running = false
        if wasRunning {
            emitLog("网络服务已停止")
            emitState(false)
        }
    }

    private func makeUDPSocket() -> Int32? {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return nil }

        var reuse: Int32 = 1
        var receiveBuffer: Int32 = 1024 * 1024
        setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))
        _ = withUnsafePointer(to: &reuse) {
            setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        var broadcast: Int32 = 1
        _ = withUnsafePointer(to: &broadcast) {
            setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, $0, socklen_t(MemoryLayout<Int32>.size))
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = Self.port.bigEndian
        address.sin_addr.s_addr = in_addr_t(0)

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        setNonBlocking(descriptor)
        return descriptor
    }

    private func makeTCPListener() -> Int32? {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { return nil }

        var reuse: Int32 = 1
        _ = withUnsafePointer(to: &reuse) {
            setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = Self.port.bigEndian
        address.sin_addr.s_addr = in_addr_t(0)

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(descriptor, 16) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        setNonBlocking(descriptor)
        return descriptor
    }

    private func installUDPSource(for descriptor: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drainUDP()
        }
        source.setCancelHandler {}
        source.resume()
        udpSource = source
    }

    private func installTCPSource(for descriptor: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptTCPConnections()
        }
        source.setCancelHandler {}
        source.resume()
        tcpSource = source
    }

    private func acceptTCPConnections() {
        guard tcpSocket >= 0 else { return }

        while true {
            var address = sockaddr_storage()
            var addressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(tcpSocket, $0, &addressLength)
                }
            }

            guard client >= 0 else {
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    emitLog("TCP 接收连接失败：\(String(cString: strerror(errno)))")
                }
                return
            }

            setNonBlocking(client)
            let ipAddress = ipv4Address(from: address) ?? "未知地址"
            clientAddresses[client] = ipAddress
            clientBuffers[client] = Data()

            let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
            source.setEventHandler { [weak self] in
                self?.drainTCPClient(client)
            }
            source.setCancelHandler {}
            source.resume()
            clientSources[client] = source
            emitLog("TCP ← \(ipAddress): 建立连接")
        }
    }

    // MARK: - Receiving

    private func drainUDP() {
        guard udpSocket >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 65_535)

        while true {
            var sender = sockaddr_storage()
            var senderLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                withUnsafeMutablePointer(to: &sender) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.recvfrom(
                            udpSocket,
                            rawBuffer.baseAddress,
                            rawBuffer.count,
                            0,
                            $0,
                            &senderLength
                        )
                    }
                }
            }

            guard count > 0 else {
                if count < 0, errno != EAGAIN && errno != EWOULDBLOCK {
                    emitLog("UDP 接收失败：\(String(cString: strerror(errno)))")
                }
                return
            }

            let data = Data(buffer[0..<count])
            let ipAddress = ipv4Address(from: sender) ?? "未知地址"
            let sourcePort = withUnsafePointer(to: &sender) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
            }
            handleIncoming(data: data, from: ipAddress, transport: .udp, sourcePort: sourcePort)
        }
    }

    private func drainTCPClient(_ descriptor: Int32) {
        guard clientSources[descriptor] != nil else { return }
        var buffer = [UInt8](repeating: 0, count: 16_384)

        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                Darwin.recv(descriptor, rawBuffer.baseAddress, rawBuffer.count, 0)
            }

            if count > 0 {
                clientBuffers[descriptor, default: Data()].append(contentsOf: buffer[0..<count])
                if consumeCompleteTCPFrames(for: descriptor) {
                    return
                }
                continue
            }

            if count == 0 {
                if consumeFinalTCPFrame(for: descriptor) {
                    return
                }
                closeTCPClient(descriptor)
                return
            }

            if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }
            if consumeFinalTCPFrame(for: descriptor) {
                return
            }
            closeTCPClient(descriptor)
            return
        }
    }

    @discardableResult
    private func consumeCompleteTCPFrames(for descriptor: Int32) -> Bool {
        guard var data = clientBuffers[descriptor] else { return false }
        while let terminator = data.firstIndex(of: 0) {
            let frame = Data(data.prefix(upTo: terminator))
            data.removeSubrange(...terminator)
            if handleTCPFrame(frame, on: descriptor) {
                closeTCPClient(descriptor)
                return true
            }
        }

        // Some FeiQ/IPMSG clients send one logical packet on TCP and keep the
        // connection open without appending NUL. Once the complete header and
        // a non-empty message are available, process that packet immediately
        // instead of waiting forever for the peer to close the stream.
        if !data.isEmpty,
           let packet = FeiQPacket.parse(data),
           (packet.commandType != .sendMessage || !packet.additionalData.isEmpty) {
            if handleTCPFrame(data, on: descriptor) {
                closeTCPClient(descriptor)
                return true
            }
            data.removeAll(keepingCapacity: true)
        }

        // Avoid unbounded memory use if an invalid peer never sends a frame end.
        if data.count > 4 * 1024 * 1024 {
            emitLog("TCP ←：丢弃过大的未结束报文")
            data.removeAll(keepingCapacity: true)
        }
        clientBuffers[descriptor] = data
        return false
    }

    @discardableResult
    private func consumeFinalTCPFrame(for descriptor: Int32) -> Bool {
        guard let data = clientBuffers[descriptor], !data.isEmpty else { return false }
        if handleTCPFrame(data, on: descriptor) {
            return true
        }
        clientBuffers[descriptor] = Data()
        return false
    }

    private func handleTCPFrame(_ data: Data, on descriptor: Int32) -> Bool {
        guard let packet = FeiQPacket.parse(data) else {
            handleIncoming(
                data: data,
                from: clientAddresses[descriptor] ?? "未知地址",
                transport: .tcp
            )
            return false
        }

        if packet.commandType == .getFileData {
            sendRequestedFile(packet, on: descriptor)
            return true
        }

        handleIncoming(
            data: data,
            from: clientAddresses[descriptor] ?? "未知地址",
            transport: .tcp
        )
        return false
    }

    private func sendRequestedFile(_ packet: FeiQPacket, on descriptor: Int32) {
        let fields = packet.additionalText.split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        guard fields.count >= 2,
              let packetNumber = fields.first.flatMap({ numericHexValue(String($0)) }),
              let fileID = fields.dropFirst().first.flatMap({ numericHexValue(String($0)) }),
              let fileURL = outgoingFilesByKey[
                OutgoingFileKey(packetNumber: packetNumber, fileID: fileID)
              ] else {
            emitLog("TCP →：找不到请求的文件 \(packet.additionalText)")
            return
        }

        let offset: UInt64
        if fields.count > 2 {
            offset = numericHexValue(String(fields[2])) ?? 0
        } else {
            offset = 0
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            emitLog("TCP →：文件已不存在：\(fileURL.path)")
            return
        }

        setBlocking(descriptor)
        var timeout = timeval(tv_sec: 60, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_SNDTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }

        do {
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            defer { try? fileHandle.close() }
            try fileHandle.seek(toOffset: offset)

            while true {
                let chunk = try fileHandle.read(upToCount: 64 * 1024) ?? Data()
                if chunk.isEmpty { break }
                guard sendAll(chunk, on: descriptor) else {
                    emitLog("TCP →：发送文件数据失败：\(String(cString: strerror(errno)))")
                    return
                }
            }
            _ = Darwin.shutdown(descriptor, SHUT_WR)
            emitLog("TCP →：已发送文件 \(fileURL.lastPathComponent)")
        } catch {
            emitLog("TCP →：读取文件失败：\(error.localizedDescription)")
        }
    }

    private func closeTCPClient(_ descriptor: Int32) {
        clientBuffers.removeValue(forKey: descriptor)
        clientAddresses.removeValue(forKey: descriptor)
        if let source = clientSources.removeValue(forKey: descriptor) {
            source.cancel()
            Darwin.close(descriptor)
        } else {
            Darwin.close(descriptor)
        }
    }

    private func handleIncoming(data: Data, from ipAddress: String, transport: FeiQTransport, sourcePort: UInt16 = FeiQNetworkService.port) {
        guard let packet = FeiQPacket.parse(data) else {
            let preview = data.prefix(96).map { String(format: "%02X", $0) }.joined(separator: " ")
            emitLog("\(transport.rawValue.uppercased()) ← \(ipAddress)：无法解析报文（\(data.count) bytes，前 96 bytes: \(preview)）")
            return
        }
        if packet.commandType == .shake, transport == .udp {
            let ack = FeiQPacket(
                packetNumber: nextPacketNumber(), senderName: localName,
                senderHost: localHost, command: .shakeAcknowledgement,
                versionIdentifier: feiQVersionIdentifier
            )
            _ = sendUDP(ack.encoded(), to: ipAddress, port: sourcePort)
        }
        if packet.commandType?.isInlineImageChunk == true {
            guard transport == .udp, let chunk = FeiQInlineImageCodec.decode(packet.additionalData) else {
                emitLog("图片分片格式无效（\(packet.additionalData.count) bytes）")
                return
            }
            let acknowledgementCommand: FeiQCommand =
                packet.commandType == .legacyInlineImage
                    ? .legacyInlineImageAcknowledgement
                    : .inlineImageAcknowledgement
            let ack = FeiQPacket(packetNumber: nextPacketNumber(), senderName: localName, senderHost: localHost,
                                 command: acknowledgementCommand,
                                 additionalText: "\(chunk.imageID)|\(chunk.index)#", versionIdentifier: feiQVersionIdentifier)
            let result = imageAssembler.accept(chunk, from: ipAddress) {
                let bytes = ack.encoded()
                _ = sendUDP(bytes, to: ipAddress, port: sourcePort)
                // FeiQ 2013 can stall its send window after a lost ACK.
                // Match the measured redundancy policy in feiqiu-README.md.
                if chunk.index <= 160 || chunk.index.isMultiple(of: 32) {
                    _ = sendUDP(bytes, to: ipAddress, port: sourcePort)
                }
            }
            guard result.accepted else {
                emitLog("图片分片被拒绝：\(chunk.imageID)，\(chunk.index)/\(chunk.totalChunks)，元数据冲突或重组容量不足")
                return
            }
            if packet.commandType == .legacyInlineImage {
                // A few builds send 0x77 data but still listen for the newer
                // 0xC1 acknowledgement. Sending both is harmless and keeps
                // the receive path compatible with both implementations.
                let standardAck = FeiQPacket(
                    packetNumber: nextPacketNumber(),
                    senderName: localName,
                    senderHost: localHost,
                    command: .inlineImageAcknowledgement,
                    additionalText: "\(chunk.imageID)|\(chunk.index)#",
                    versionIdentifier: feiQVersionIdentifier
                )
                _ = sendUDP(standardAck.encoded(), to: ipAddress, port: sourcePort)
            }
            if let bytes = result.data {
                emitLog("UDP ← \(ipAddress)：内嵌图片 \(chunk.imageID) 重组完成（\(bytes.count) bytes）")
                onInlineImage?(bytes, chunk.imageID, chunk.bitmapFlag, packet, ipAddress)
            }
            return
        }
        if packet.commandType?.isInlineImageAcknowledgement == true {
            if let ack = FeiQInlineImageCodec.acknowledgement(packet.additionalText) {
                imageSends[ipAddress + "/" + ack.imageID]?.acknowledge(ack.index)
                pumpImageSends()
            }
            return
        }
        if packet.commandType == .receiveMessage, let number = UInt64(packet.additionalText),
           imageMarkers[number]?.ip == ipAddress {
            imageMarkers.removeValue(forKey: number)
        }
        if packet.commandType == .releaseFiles,
           let packetNumber = packet.additionalText
            .split(separator: ":", omittingEmptySubsequences: true)
            .first
            .flatMap({ numericHexValue(String($0)) }) {
            outgoingFilesByKey = outgoingFilesByKey.filter {
                $0.key.packetNumber != packetNumber
            }
        }
        let commandText = packet.commandType.map { String(describing: $0) } ?? "0x\(String(packet.command, radix: 16))"
        let sender = packet.senderName.isEmpty ? "<空昵称>" : packet.senderName
        let host = packet.senderHost.isEmpty ? "<空主机名>" : packet.senderHost
        let recipient = packet.commandType == .sendMessage || packet.commandType == .receiveMessage
            ? localName
            : "局域网广播"
        emitLog("\(transport.rawValue.uppercased()) ← \(ipAddress)：\(commandText) [发送人：\(sender)，收件人：\(recipient)，命令 \(packet.command)，主机 \(host)，版本 \(packet.versionIdentifier)]")

        onPacket?(packet, ipAddress, transport, sourcePort)
    }

    // MARK: - Sending

    private func sendEntryInternal() {
        guard running || udpSocket >= 0 else { return }
        let packet = makePresencePacket(command: .broadcastEntry)
        let addresses = broadcastAddresses()
        let data = packet.encoded()
        let sentCount = addresses.reduce(into: 0) { count, address in
            if sendUDP(data, to: address) {
                count += 1
            }
        }
        emitLog("UDP → 广播上线信息（\(sentCount)/\(addresses.count)：\(addresses.joined(separator: ", "))）")
    }

    private func sendAnswerEntryInternal(to ipAddress: String) {
        guard udpSocket >= 0 else { return }
        let packet = makePresencePacket(command: .answerEntry)
        sendUDP(packet.encoded(), to: ipAddress)
        emitLog("UDP → \(ipAddress)：回复在线信息")
    }

    private func sendExitInternal() {
        guard udpSocket >= 0 else { return }
        let packet = makePresencePacket(command: .broadcastExit)
        for address in broadcastAddresses() {
            sendUDP(packet.encoded(), to: address)
        }
    }

    private func makePresencePacket(command: FeiQCommand) -> FeiQPacket {
        FeiQPacket(
            versionIdentifier: feiQVersionIdentifier,
            packetNumber: nextPacketNumber(),
            senderName: localName,
            senderHost: localHost,
            command: command.rawValue | FeiQPacket.fileAttachOption,
            additionalData: GBKCodec.encodeForLegacyFeiQ(entryAdditionalText)
        )
    }

    @discardableResult
    private func sendUDP(_ data: Data, to ipAddress: String, port: UInt16 = FeiQNetworkService.port) -> Bool {
        guard udpSocket >= 0 else { return false }
        guard var address = makeIPv4Address(ipAddress) else {
            emitLog("UDP → \(ipAddress)：不是有效的 IPv4 地址")
            return false
        }
        address.sin_port = port.bigEndian
        let result = data.withUnsafeBytes { rawData -> Int in
            guard let baseAddress = rawData.baseAddress else { return -1 }
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.sendto(
                        udpSocket,
                        baseAddress,
                        rawData.count,
                        0,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
        if result < 0 {
            emitLog("UDP → \(ipAddress) 失败：\(String(cString: strerror(errno)))")
        }
        return result >= 0
    }

    private func sendTCP(_ data: Data, to ipAddress: String) -> Bool {
        guard let address = makeIPv4Address(ipAddress) else {
            emitLog("TCP → \(ipAddress)：不是有效的 IPv4 地址")
            return false
        }

        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else {
            emitLog("TCP → \(ipAddress)：创建 socket 失败：\(String(cString: strerror(errno)))")
            return false
        }
        defer { Darwin.close(descriptor) }

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }

        var mutableAddress = address
        let connected = withUnsafePointer(to: &mutableAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            let errorCode = errno
            emitLog("TCP → \(ipAddress)：连接失败：\(String(cString: strerror(errorCode)))")
            return false
        }

        let sent = sendAll(data, on: descriptor)
        if !sent {
            let errorCode = errno
            emitLog("TCP → \(ipAddress)：发送失败：\(String(cString: strerror(errorCode)))")
        }
        _ = Darwin.shutdown(descriptor, SHUT_WR)
        return sent
    }

    private func downloadFileInternal(
        _ attachment: FeiQFileAttachment,
        request: FeiQPacket,
        from ipAddress: String,
        port: UInt16,
        to destinationURL: URL
    ) -> Result<Void, Error> {
        guard let address = makeIPv4Address(ipAddress, port: port) else {
            return .failure(FeiQFileTransferError.invalidAddress)
        }

        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else {
            return .failure(FeiQFileTransferError.socketCreation)
        }
        defer { Darwin.close(descriptor) }

        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 60, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_SNDTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }

        var mutableAddress = address
        let connected = withUnsafePointer(to: &mutableAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard connected == 0 else {
            let errorCode = errno
            let systemMessage = String(cString: strerror(errorCode))
            let hint: String
            switch errorCode {
            case EHOSTUNREACH, ENETUNREACH, ECONNREFUSED:
                hint = "；请检查 Windows 飞秋是否允许 TCP 2425 入站"
            default:
                hint = ""
            }
            return .failure(
                FeiQFileTransferError.connectionFailed(
                    "\(ipAddress):\(port) · \(systemMessage)\(hint)"
                )
            )
        }

        guard sendAll(request.encoded(), on: descriptor) else {
            return .failure(
                FeiQFileTransferError.requestFailed(
                    String(cString: strerror(errno))
                )
            )
        }
        do {
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(
                atPath: destinationURL.path,
                contents: nil
            )
            let fileHandle = try FileHandle(forWritingTo: destinationURL)
            defer { try? fileHandle.close() }

            var receivedBytes: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while receivedBytes < attachment.fileSize {
                let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                    Darwin.recv(
                        descriptor,
                        rawBuffer.baseAddress,
                        min(rawBuffer.count, Int(attachment.fileSize - receivedBytes)),
                        0
                    )
                }

                if count > 0 {
                    try fileHandle.write(contentsOf: Data(buffer[0..<count]))
                    receivedBytes += Int64(count)
                    continue
                }
                if count == 0 {
                    try? FileManager.default.removeItem(at: destinationURL)
                    return .failure(
                        FeiQFileTransferError.unexpectedEndOfStream(
                            expected: attachment.fileSize,
                            received: receivedBytes
                        )
                    )
                }

                let errorCode = errno
                if errorCode == EINTR { continue }
                try? FileManager.default.removeItem(at: destinationURL)
                return .failure(
                    FeiQFileTransferError.connectionFailed(
                        "\(String(cString: strerror(errorCode)))（已收到 \(receivedBytes)/\(attachment.fileSize) 字节）"
                    )
                )
            }

            // Do not release the whole message here: other attachments may
            // still be downloading.
            emitLog(
                "TCP ← \(ipAddress)：已接收文件 \(attachment.fileName)（\(attachment.fileSize) bytes）"
            )
            return .success(())
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            return .failure(FeiQFileTransferError.fileWriteFailed(error.localizedDescription))
        }
    }

    private func sendReleaseFiles(for fileID: String, to ipAddress: String) {
        let packet = FeiQPacket(
            packetNumber: nextPacketNumber(),
            senderName: localName,
            senderHost: localHost,
            command: .releaseFiles,
            additionalText: fileID,
            versionIdentifier: feiQVersionIdentifier
        )
        _ = sendUDP(packet.encoded(), to: ipAddress)
    }

    private func numericFileID(_ value: String) -> UInt64? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return UInt64(trimmed) ?? numericHexValue(trimmed)
    }

    private func numericHexValue(_ value: String) -> UInt64? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X")
            ? String(trimmed.dropFirst(2))
            : trimmed
        guard !normalized.isEmpty else { return nil }
        return UInt64(normalized, radix: 16)
    }

    private func sendAll(_ data: Data, on descriptor: Int32) -> Bool {
        data.withUnsafeBytes { rawData in
            guard let baseAddress = rawData.baseAddress else { return true }
            var offset = 0
            while offset < rawData.count {
                let count = Darwin.send(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawData.count - offset,
                    0
                )
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    // MARK: - Address helpers

    private func makeIPv4Address(
        _ ipAddress: String,
        port: UInt16 = FeiQNetworkService.port
    ) -> sockaddr_in? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        let result = ipAddress.withCString {
            inet_pton(AF_INET, $0, &address.sin_addr)
        }
        return result == 1 ? address : nil
    }

    private func broadcastAddresses() -> [String] {
        var result = Set<String>()
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            return ["255.255.255.255"]
        }
        defer { freeifaddrs(first) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current {
            let flags = interface.pointee.ifa_flags
            let isUp = (flags & UInt32(IFF_UP)) != 0
            let isLoopback = (flags & UInt32(IFF_LOOPBACK)) != 0
            if isUp, !isLoopback,
               let address = interface.pointee.ifa_addr,
               Int32(address.pointee.sa_family) == AF_INET,
               (flags & UInt32(IFF_BROADCAST)) != 0,
               let broadcast = interface.pointee.ifa_dstaddr {
                let value = broadcast.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    ipv4String($0.pointee.sin_addr)
                }
                if !value.isEmpty {
                    result.insert(value)
                }
            }
            current = interface.pointee.ifa_next
        }

        return result.isEmpty ? ["255.255.255.255"] : result.sorted()
    }

    private func localIPv4Addresses() -> [String] {
        var result = Set<String>()
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            return []
        }
        defer { freeifaddrs(first) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current {
            let flags = interface.pointee.ifa_flags
            let isUp = (flags & UInt32(IFF_UP)) != 0
            let isLoopback = (flags & UInt32(IFF_LOOPBACK)) != 0
            if isUp, !isLoopback,
               let address = interface.pointee.ifa_addr,
               Int32(address.pointee.sa_family) == AF_INET {
                let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    ipv4String($0.pointee.sin_addr)
                }
                if !value.isEmpty {
                    result.insert(value)
                }
            }
            current = interface.pointee.ifa_next
        }

        return result.sorted()
    }

    private func setNonBlocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        }
    }

    private func setBlocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK)
        }
    }

    private func ipv4Address(from storage: sockaddr_storage) -> String? {
        var copy = storage
        guard Int32(copy.ss_family) == AF_INET else { return nil }
        return withUnsafePointer(to: &copy) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                let value = ipv4String($0.pointee.sin_addr)
                return value.isEmpty ? nil : value
            }
        }
    }

    private func ipv4String(_ address: in_addr) -> String {
        var copy = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let result = buffer.withUnsafeMutableBufferPointer {
            inet_ntop(AF_INET, &copy, $0.baseAddress, socklen_t($0.count))
        }
        guard result != nil else { return "" }
        return String(cString: buffer)
    }

    private func nextPacketNumber() -> UInt64 {
        packetCounter &+= 1
        let milliseconds = UInt64(Date().timeIntervalSince1970 * 1_000)
        // Keep generated IDs in the 32-bit range used by FeiQ 2013. Incoming
        // packets are parsed as UInt64 independently, so long peer IDs remain
        // valid for acknowledgements.
        let legacyMilliseconds = UInt32(truncatingIfNeeded: milliseconds)
        return UInt64(legacyMilliseconds &+ packetCounter)
    }

    private static func persistentDeviceIdentifier() -> String {
        let key = "feiq.deviceIdentifier"
        let defaults = UserDefaults.standard

        if let existing = defaults.string(forKey: key) {
            let value = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }

        // FeiQ only uses this field as a stable host identity. A persisted
        // hexadecimal value is safer than exposing a hardware address and is
        // accepted by the same extended version format used by FeiQ clients.
        let generated = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).uppercased()
        defaults.set(generated, forKey: key)
        return generated
    }

    private func emitLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        onLog?("[\(formatter.string(from: Date()))] \(message)")
    }

    private func emitState(_ value: Bool) {
        onStateChange?(value)
    }
}
