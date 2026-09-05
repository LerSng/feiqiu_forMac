import Darwin
import Foundation

enum FeiQTransport: String, Sendable {
    case udp
    case tcp
}

protocol FeiQNetworkServiceProtocol: AnyObject {
    var onPacket: ((FeiQPacket, String, FeiQTransport) -> Void)? { get set }
    var onLog: ((String) -> Void)? { get set }
    var onStateChange: ((Bool) -> Void)? { get set }

    func start(name: String, host: String, group: String)
    func stop()
    func updateIdentity(name: String, host: String, group: String)
    func announce()
    func replyToEntry(from ipAddress: String)
    func sendText(_ text: String, to ipAddress: String, recipientName: String?)
    func acknowledge(_ packet: FeiQPacket, to ipAddress: String)
}

final class FeiQNetworkService: FeiQNetworkServiceProtocol {
    static let port: UInt16 = 2425

    var onPacket: ((FeiQPacket, String, FeiQTransport) -> Void)?
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
        emitState(true)
        emitLog("本机 IPv4：\(localIPv4Addresses().joined(separator: ", "))")
        emitLog("广播地址：\(broadcastAddresses().joined(separator: ", "))")
        emitLog("飞秋设备标识：\(localDeviceIdentifier)")
        emitLog("已监听 UDP/TCP 2425，正在广播上线信息")
        sendEntryInternal()
    }

    private func stopInternal(announceExit: Bool) {
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
            handleIncoming(data: data, from: ipAddress, transport: .udp)
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
                consumeCompleteTCPFrames(for: descriptor)
                continue
            }

            if count == 0 {
                consumeFinalTCPFrame(for: descriptor)
                closeTCPClient(descriptor)
                return
            }

            if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }
            consumeFinalTCPFrame(for: descriptor)
            closeTCPClient(descriptor)
            return
        }
    }

    private func consumeCompleteTCPFrames(for descriptor: Int32) {
        guard var data = clientBuffers[descriptor] else { return }
        while let terminator = data.firstIndex(of: 0) {
            let frame = Data(data.prefix(upTo: terminator))
            data.removeSubrange(...terminator)
            handleIncoming(data: frame, from: clientAddresses[descriptor] ?? "未知地址", transport: .tcp)
        }

        // Some FeiQ/IPMSG clients send one logical packet on TCP and keep the
        // connection open without appending NUL. Once the complete header and
        // a non-empty message are available, process that packet immediately
        // instead of waiting forever for the peer to close the stream.
        if !data.isEmpty,
           let packet = FeiQPacket.parse(data),
           (packet.commandType != .sendMessage || !packet.additionalData.isEmpty) {
            handleIncoming(data: data, from: clientAddresses[descriptor] ?? "未知地址", transport: .tcp)
            data.removeAll(keepingCapacity: true)
        }

        // Avoid unbounded memory use if an invalid peer never sends a frame end.
        if data.count > 4 * 1024 * 1024 {
            emitLog("TCP ←：丢弃过大的未结束报文")
            data.removeAll(keepingCapacity: true)
        }
        clientBuffers[descriptor] = data
    }

    private func consumeFinalTCPFrame(for descriptor: Int32) {
        guard let data = clientBuffers[descriptor], !data.isEmpty else { return }
        handleIncoming(data: data, from: clientAddresses[descriptor] ?? "未知地址", transport: .tcp)
        clientBuffers[descriptor] = Data()
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

    private func handleIncoming(data: Data, from ipAddress: String, transport: FeiQTransport) {
        guard let packet = FeiQPacket.parse(data) else {
            let preview = data.prefix(96).map { String(format: "%02X", $0) }.joined(separator: " ")
            emitLog("\(transport.rawValue.uppercased()) ← \(ipAddress)：无法解析报文（\(data.count) bytes，前 96 bytes: \(preview)）")
            return
        }
        let commandText = packet.commandType.map { String(describing: $0) } ?? "0x\(String(packet.command, radix: 16))"
        let sender = packet.senderName.isEmpty ? "<空昵称>" : packet.senderName
        let host = packet.senderHost.isEmpty ? "<空主机名>" : packet.senderHost
        let recipient = packet.commandType == .sendMessage || packet.commandType == .receiveMessage
            ? localName
            : "局域网广播"
        emitLog("\(transport.rawValue.uppercased()) ← \(ipAddress)：\(commandText) [发送人：\(sender)，收件人：\(recipient)，命令 \(packet.command)，主机 \(host)，版本 \(packet.versionIdentifier)]")
        onPacket?(packet, ipAddress, transport)
    }

    // MARK: - Sending

    private func sendEntryInternal() {
        guard running || udpSocket >= 0 else { return }
        let packet = FeiQPacket(
            packetNumber: nextPacketNumber(),
            senderName: localName,
            senderHost: localHost,
            command: .broadcastEntry,
            additionalText: entryAdditionalText,
            versionIdentifier: feiQVersionIdentifier
        )
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
        let packet = FeiQPacket(
            packetNumber: nextPacketNumber(),
            senderName: localName,
            senderHost: localHost,
            command: .answerEntry,
            additionalText: entryAdditionalText,
            versionIdentifier: feiQVersionIdentifier
        )
        sendUDP(packet.encoded(), to: ipAddress)
        emitLog("UDP → \(ipAddress)：回复在线信息")
    }

    private func sendExitInternal() {
        guard udpSocket >= 0 else { return }
        let packet = FeiQPacket(
            packetNumber: nextPacketNumber(),
            senderName: localName,
            senderHost: localHost,
            command: .broadcastExit,
            additionalText: entryAdditionalText,
            versionIdentifier: feiQVersionIdentifier
        )
        for address in broadcastAddresses() {
            sendUDP(packet.encoded(), to: address)
        }
    }

    @discardableResult
    private func sendUDP(_ data: Data, to ipAddress: String) -> Bool {
        guard udpSocket >= 0 else { return false }
        guard var address = makeIPv4Address(ipAddress) else {
            emitLog("UDP → \(ipAddress)：不是有效的 IPv4 地址")
            return false
        }
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

    private func makeIPv4Address(_ ipAddress: String) -> sockaddr_in? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = Self.port.bigEndian
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
