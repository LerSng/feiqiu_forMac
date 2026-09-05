//
//  ChatAttachmentStorageService.swift
//  FeiQMac
//
//  负责图片附件的本地导入、接收落盘和文件元数据管理。
//

import Foundation
import UniformTypeIdentifiers
import ImageIO

protocol ChatAttachmentStorageService: AnyObject {
    var locationDescription: String { get }

    func prepareOutgoingImage(from sourceURL: URL) throws -> ChatAttachment
    func prepareOutgoingImage(from data: Data, suggestedFileName: String?) throws -> ChatAttachment
    func prepareIncomingImage(for descriptor: FeiQFileAttachment) throws -> ChatAttachment
    func saveInlineImage(_ data: Data, imageID: String, isBitmap: Bool) throws -> ChatAttachment
}

enum ChatAttachmentStorageError: LocalizedError {
    case unsupportedImage
    case sourceFileUnavailable
    case invalidFileSize
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedImage:
            return "只支持发送图片文件"
        case .sourceFileUnavailable:
            return "无法读取图片文件"
        case .invalidFileSize:
            return "图片为空或超过 20 MB 限制"
        case .copyFailed(let message):
            return "图片保存失败：\(message)"
        }
    }
}

final class LocalChatAttachmentStorageService: ChatAttachmentStorageService {
    private static let regularFileAttribute: UInt32 = 0x00000001

    private let fileManager: FileManager
    private let imagesDirectoryURL: URL

    var locationDescription: String {
        imagesDirectoryURL.path
    }

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.imagesDirectoryURL = rootURL.appendingPathComponent(
            "Images",
            isDirectory: true
        )

        try? fileManager.createDirectory(
            at: imagesDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    static func makeDefault() -> LocalChatAttachmentStorageService {
        let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let rootURL = documentsURL.appendingPathComponent(
            "飞秋 Mac",
            isDirectory: true
        )
        return LocalChatAttachmentStorageService(rootURL: rootURL)
    }

    func prepareOutgoingImage(from sourceURL: URL) throws -> ChatAttachment {
        let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard let type = Self.imageType(for: sourceURL),
              type.conforms(to: .image) else {
            throw ChatAttachmentStorageError.unsupportedImage
        }

        let values: URLResourceValues
        do {
            values = try sourceURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey
            ])
        } catch {
            throw ChatAttachmentStorageError.sourceFileUnavailable
        }

        guard values.isRegularFile != false,
              let fileSize = values.fileSize,
              fileSize > 0, fileSize <= FeiQInlineImageCodec.maximumBytes else {
            throw ChatAttachmentStorageError.invalidFileSize
        }

        return try makeOutgoingImage(
            data: Data(contentsOf: sourceURL),
            suggestedFileName: sourceURL.deletingPathExtension().lastPathComponent,
            modifiedAt: values.contentModificationDate ?? Date()
        )
    }

    func prepareOutgoingImage(from data: Data, suggestedFileName: String?) throws -> ChatAttachment {
        guard !data.isEmpty else {
            throw ChatAttachmentStorageError.invalidFileSize
        }
        return try makeOutgoingImage(
            data: data,
            suggestedFileName: suggestedFileName ?? "clipboard-image",
            modifiedAt: Date()
        )
    }

    private func makeOutgoingImage(
        data: Data,
        suggestedFileName: String,
        modifiedAt: Date
    ) throws -> ChatAttachment {
        // FeiQ 2013's format flag 2 denotes JPEG. Convert HEIC/PNG/etc.
        // using ImageIO before advertising that format on the wire.
        let jpeg = try Self.jpegData(from: data)
        let baseName = Self.safeFileName(URL(fileURLWithPath: suggestedFileName).deletingPathExtension().lastPathComponent)
        let fileName = (baseName.isEmpty ? "clipboard-image" : baseName) + ".jpg"
        let destinationURL = imagesDirectoryURL.appendingPathComponent(
            "\(UUID().uuidString)_\(fileName)",
            isDirectory: false
        )

        do {
            try jpeg.write(to: destinationURL, options: .atomic)
        } catch {
            throw ChatAttachmentStorageError.copyFailed(error.localizedDescription)
        }

        let descriptor = FeiQFileAttachment(
            fileID: String(UInt32.random(in: 1...UInt32.max)),
            fileName: fileName,
            fileSize: Int64(jpeg.count),
            modifiedAt: Int64(modifiedAt.timeIntervalSince1970),
            fileAttributes: Self.regularFileAttribute
        )

        return ChatAttachment(
            descriptor: descriptor,
            localPath: destinationURL.path,
            mimeType: "image/jpeg"
        )
    }

    func prepareIncomingImage(for descriptor: FeiQFileAttachment) throws -> ChatAttachment {
        guard descriptor.isImage else {
            throw ChatAttachmentStorageError.unsupportedImage
        }
        guard descriptor.fileSize > 0, descriptor.fileSize <= FeiQInlineImageCodec.maximumBytes else {
            throw ChatAttachmentStorageError.invalidFileSize
        }

        let fileName = Self.safeFileName(descriptor.fileName)
        let destinationURL = imagesDirectoryURL.appendingPathComponent(
            "\(UUID().uuidString)_\(fileName)",
            isDirectory: false
        )
        let type = Self.imageType(for: URL(fileURLWithPath: fileName))

        return ChatAttachment(
            descriptor: descriptor,
            localPath: destinationURL.path,
            mimeType: type?.preferredMIMEType ?? "application/octet-stream"
        )
    }

    private static func imageType(for url: URL) -> UTType? {
        guard !url.pathExtension.isEmpty else { return nil }
        return UTType(filenameExtension: url.pathExtension)
    }

    func saveInlineImage(_ data: Data, imageID: String, isBitmap: Bool) throws -> ChatAttachment {
        let encoded = isBitmap ? try Self.bitmapFile(from: data) : data
        let jpeg = try Self.jpegData(from: encoded)
        let descriptor = FeiQFileAttachment(fileID: imageID, fileName: "\(imageID).jpg",
                                            fileSize: Int64(jpeg.count), modifiedAt: Int64(Date().timeIntervalSince1970), fileAttributes: 1)
        let attachment = try prepareIncomingImage(for: descriptor)
        try jpeg.write(to: attachment.localURL, options: .atomic)
        return attachment
    }

    private static func jpegData(from data: Data) throws -> Data {
        guard data.count <= FeiQInlineImageCodec.maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ChatAttachmentStorageError.unsupportedImage
        }
        let thumbnailOptions: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
                ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ChatAttachmentStorageError.unsupportedImage
        }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ChatAttachmentStorageError.unsupportedImage
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination), result.length <= FeiQInlineImageCodec.maximumBytes else {
            throw ChatAttachmentStorageError.invalidFileSize
        }
        return Data(result)
    }

    /// FeiQ bitmap flag 1 carries a DIB without BITMAPFILEHEADER.
    private static func bitmapFile(from dib: Data) throws -> Data {
        if dib.starts(with: [0x42, 0x4d]) { return dib }
        guard dib.count >= 40 else { throw ChatAttachmentStorageError.unsupportedImage }
        func uint32(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | (Int(dib[offset + $1]) << ($1 * 8)) }
        }
        let headerSize = uint32(0)
        guard [40, 108, 124].contains(headerSize), dib.count >= headerSize else {
            throw ChatAttachmentStorageError.unsupportedImage
        }
        let bitCount = Int(dib[14]) | Int(dib[15]) << 8
        let compression = uint32(16)
        let colors = uint32(32) > 0 ? uint32(32) : (bitCount <= 8 ? 1 << bitCount : 0)
        let masks = headerSize == 40 && compression == 3 ? 12 : 0
        let offset = 14 + headerSize + masks + colors * 4
        guard offset <= dib.count + 14 else { throw ChatAttachmentStorageError.unsupportedImage }
        var header = Data([0x42, 0x4d])
        func appendUInt32(_ value: Int) {
            for shift in stride(from: 0, to: 32, by: 8) { header.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        appendUInt32(dib.count + 14)
        appendUInt32(0)
        appendUInt32(offset)
        header.append(dib)
        return header
    }

    private static func safeFileName(_ fileName: String) -> String {
        let baseName = URL(fileURLWithPath: fileName).lastPathComponent
        let sanitized = baseName
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\0", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "image" : sanitized
    }
}
