//
//  AttachmentRepository.swift
//  FeiQMac
//
//  附件业务仓储：组合本地附件服务，负责附件准备、接收落盘、图片解码和安全删除。
//

import Foundation

protocol AttachmentRepository: AnyObject {
    var locationDescription: String { get }

    func prepareOutgoingImage(from sourceURL: URL) throws -> ChatAttachment
    func prepareOutgoingImage(
        from data: Data,
        suggestedFileName: String?
    ) throws -> ChatAttachment
    func prepareOutgoingFile(from sourceURL: URL) throws -> ChatAttachment
    func prepareIncomingImage(for descriptor: FeiQFileAttachment) throws -> ChatAttachment
    func prepareIncomingFile(for descriptor: FeiQFileAttachment) throws -> ChatAttachment
    func saveInlineImage(
        _ data: Data,
        imageID: String,
        isBitmap: Bool
    ) throws -> ChatAttachment
    func deleteManagedImage(_ attachment: ChatAttachment) throws
    func deleteManagedAttachment(_ attachment: ChatAttachment) throws
}

final class DefaultAttachmentRepository: AttachmentRepository {
    private let storageService: ChatAttachmentStorageService

    var locationDescription: String {
        storageService.locationDescription
    }

    init(storageService: ChatAttachmentStorageService) {
        self.storageService = storageService
    }

    func prepareOutgoingImage(from sourceURL: URL) throws -> ChatAttachment {
        try storageService.prepareOutgoingImage(from: sourceURL)
    }

    func prepareOutgoingImage(
        from data: Data,
        suggestedFileName: String?
    ) throws -> ChatAttachment {
        try storageService.prepareOutgoingImage(
            from: data,
            suggestedFileName: suggestedFileName
        )
    }

    func prepareOutgoingFile(from sourceURL: URL) throws -> ChatAttachment {
        try storageService.prepareOutgoingFile(from: sourceURL)
    }

    func prepareIncomingImage(for descriptor: FeiQFileAttachment) throws -> ChatAttachment {
        try storageService.prepareIncomingImage(for: descriptor)
    }

    func prepareIncomingFile(for descriptor: FeiQFileAttachment) throws -> ChatAttachment {
        try storageService.prepareIncomingFile(for: descriptor)
    }

    func saveInlineImage(
        _ data: Data,
        imageID: String,
        isBitmap: Bool
    ) throws -> ChatAttachment {
        try storageService.saveInlineImage(data, imageID: imageID, isBitmap: isBitmap)
    }

    func deleteManagedImage(_ attachment: ChatAttachment) throws {
        try storageService.deleteManagedImage(attachment)
    }

    func deleteManagedAttachment(_ attachment: ChatAttachment) throws {
        try storageService.deleteManagedAttachment(attachment)
    }
}
