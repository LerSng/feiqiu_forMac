//
//  NetworkServices.swift
//  FeiQMac
//
//  将底层 FeiQNetworkService 按能力拆分为发现、消息、文件、图片和群协议服务。
//  这些服务只负责网络能力或协议转换，不持有页面状态。
//

import Foundation

protocol FeiQNetworkEventSource: AnyObject {
    var onInlineImage: ((Data, String, Int, FeiQPacket, String) -> Void)? { get set }
    var onPacket: ((FeiQPacket, String, FeiQTransport, UInt16) -> Void)? { get set }
    var onLog: ((String) -> Void)? { get set }
    var onStateChange: ((Bool) -> Void)? { get set }
}

protocol DiscoveryService: AnyObject {
    func start(identity: FeiQIdentity)
    func stop()
    func stop(completion: @escaping () -> Void)
    func updateIdentity(_ identity: FeiQIdentity)
    func announce()
    func replyToEntry(from ipAddress: String)
}

extension DiscoveryService {
    func stop(completion: @escaping () -> Void) {
        stop()
        completion()
    }
}

final class DefaultDiscoveryService: DiscoveryService {
    private let networkService: FeiQNetworkServiceProtocol

    init(networkService: FeiQNetworkServiceProtocol) {
        self.networkService = networkService
    }

    func start(identity: FeiQIdentity) {
        networkService.start(
            name: identity.nickname,
            host: identity.hostName,
            group: identity.groupName
        )
    }

    func stop() {
        networkService.stop()
    }

    func stop(completion: @escaping () -> Void) {
        networkService.stop(completion: completion)
    }

    func updateIdentity(_ identity: FeiQIdentity) {
        networkService.updateIdentity(
            name: identity.nickname,
            host: identity.hostName,
            group: identity.groupName
        )
    }

    func announce() {
        networkService.announce()
    }

    func replyToEntry(from ipAddress: String) {
        networkService.replyToEntry(from: ipAddress)
    }
}

protocol MessageTransportService: AnyObject {
    func sendTyping(isTyping: Bool, to ipAddress: String)
    func sendShake(to ipAddress: String)
    func sendText(_ wireText: String, to ipAddress: String, recipientName: String?)
    func acknowledge(_ packet: FeiQPacket, to ipAddress: String)
}

final class DefaultMessageTransportService: MessageTransportService {
    private let networkService: FeiQNetworkServiceProtocol

    init(networkService: FeiQNetworkServiceProtocol) {
        self.networkService = networkService
    }

    func sendTyping(isTyping: Bool, to ipAddress: String) {
        networkService.sendTyping(isTyping: isTyping, to: ipAddress)
    }

    func sendShake(to ipAddress: String) {
        networkService.sendShake(to: ipAddress)
    }

    func sendText(_ wireText: String, to ipAddress: String, recipientName: String?) {
        networkService.sendText(wireText, to: ipAddress, recipientName: recipientName)
    }

    func acknowledge(_ packet: FeiQPacket, to ipAddress: String) {
        networkService.acknowledge(packet, to: ipAddress)
    }
}

protocol FileTransferService: AnyObject {
    func send(
        _ attachment: ChatAttachment,
        text: String,
        to ipAddress: String,
        recipientName: String?,
        progress: @escaping (FileTransferProgress) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) -> FileTransferCancellation
    func download(
        _ attachment: FeiQFileAttachment,
        packetNumber: UInt64,
        from ipAddress: String,
        port: UInt16,
        to destinationURL: URL,
        progress: @escaping (FileTransferProgress) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) -> FileTransferCancellation
    func send(
        _ wireText: String,
        attachments: [ChatAttachment],
        to ipAddress: String,
        recipientName: String?
    )
    func download(
        _ attachment: FeiQFileAttachment,
        packetNumber: UInt64,
        from ipAddress: String,
        port: UInt16,
        to destinationURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    )
}

final class DefaultFileTransferService: FileTransferService {
    private let networkService: FeiQNetworkServiceProtocol

    init(networkService: FeiQNetworkServiceProtocol) {
        self.networkService = networkService
    }

    func send(
        _ attachment: ChatAttachment,
        text: String,
        to ipAddress: String,
        recipientName: String?,
        progress: @escaping (FileTransferProgress) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) -> FileTransferCancellation {
        networkService.uploadFile(attachment, text: text, to: ipAddress, recipientName: recipientName,
                                  progress: progress, completion: completion)
    }

    func download(
        _ attachment: FeiQFileAttachment,
        packetNumber: UInt64,
        from ipAddress: String,
        port: UInt16,
        to destinationURL: URL,
        progress: @escaping (FileTransferProgress) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) -> FileTransferCancellation {
        networkService.downloadFile(attachment, packetNumber: packetNumber, from: ipAddress, port: port,
                                    to: destinationURL, progress: progress, completion: completion)
    }

    func send(
        _ wireText: String,
        attachments: [ChatAttachment],
        to ipAddress: String,
        recipientName: String?
    ) {
        networkService.sendFileMessage(
            wireText,
            attachments: attachments,
            to: ipAddress,
            recipientName: recipientName
        )
    }

    func download(
        _ attachment: FeiQFileAttachment,
        packetNumber: UInt64,
        from ipAddress: String,
        port: UInt16,
        to destinationURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        networkService.downloadFile(
            attachment,
            packetNumber: packetNumber,
            from: ipAddress,
            port: port,
            to: destinationURL,
            completion: completion
        )
    }
}

protocol InlineImageService: AnyObject {
    func send(
        _ wireText: String,
        images: [ChatAttachment],
        to ipAddress: String,
        recipientName: String?
    )
}

final class DefaultInlineImageService: InlineImageService {
    private let networkService: FeiQNetworkServiceProtocol

    init(networkService: FeiQNetworkServiceProtocol) {
        self.networkService = networkService
    }

    func send(
        _ wireText: String,
        images: [ChatAttachment],
        to ipAddress: String,
        recipientName: String?
    ) {
        networkService.sendFileMessage(
            wireText,
            attachments: images,
            to: ipAddress,
            recipientName: recipientName
        )
    }
}

protocol GroupProtocolService: AnyObject {
    func makeRelayText(groupName: String, senderName: String, text: String) -> String
    func parseRelayText(_ text: String) -> FeiQGroupRelayFormatter.ParsedMessage?
}

final class DefaultGroupProtocolService: GroupProtocolService {
    func makeRelayText(groupName: String, senderName: String, text: String) -> String {
        FeiQGroupRelayFormatter.makeText(
            groupName: groupName,
            senderName: senderName,
            text: text
        )
    }

    func parseRelayText(_ text: String) -> FeiQGroupRelayFormatter.ParsedMessage? {
        FeiQGroupRelayFormatter.parse(text)
    }
}
