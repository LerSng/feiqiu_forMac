//
//  ChatAttachmentStorageService.swift
//  FeiQMac
//
//  负责图片与普通文件附件的本地导入、接收落盘和文件元数据管理。
//

import Foundation
import UniformTypeIdentifiers
import ImageIO

protocol ChatAttachmentStorageService: AnyObject {
    var locationDescription: String { get }

    func prepareOutgoingImage(from sourceURL: URL) throws -> ChatAttachment
    func prepareOutgoingImage(from data: Data, suggestedFileName: String?) throws -> ChatAttachment
    func prepareOutgoingFile(from sourceURL: URL) throws -> ChatAttachment
    func prepareIncomingImage(for descriptor: FeiQFileAttachment) throws -> ChatAttachment
    func prepareIncomingFile(for descriptor: FeiQFileAttachment) throws -> ChatAttachment
    func saveInlineImage(_ data: Data, imageID: String, isBitmap: Bool) throws -> ChatAttachment
    func deleteManagedImage(_ attachment: ChatAttachment) throws
    func deleteManagedAttachment(_ attachment: ChatAttachment) throws
}

enum ChatAttachmentStorageError: LocalizedError {
    case unsupportedImage
    case unsupportedFile
    case sourceFileUnavailable
    case invalidFileSize
    case copyFailed(String)
    case unsafeDeletion

    var errorDescription: String? {
        switch self {
        case .unsupportedImage:
            return "只支持发送图片文件"
        case .unsupportedFile:
            return "不支持发送文件夹或特殊文件"
        case .sourceFileUnavailable:
            return "无法读取附件文件"
        case .invalidFileSize:
            return "附件为空或超过 2 GB 限制"
        case .copyFailed(let message):
            return "附件保存失败：\(message)"
        case .unsafeDeletion:
            return "只能删除应用附件目录中的图片，不能删除原始文件或目录"
        }
    }
}

final class LocalChatAttachmentStorageService: ChatAttachmentStorageService {
    private static let regularFileAttribute: UInt32 = 0x00000001
    /// TCP transfer is streamed, so ordinary files do not need to fit in RAM.
    /// The limit still protects the local Documents directory from accidental
    /// selection of a disk image or an unbounded special file.
    static let maximumFileBytes: Int64 = 2 * 1024 * 1024 * 1024

    private let fileManager: FileManager
    private let rootDirectoryURL: URL
    private let imagesDirectoryURL: URL
    private let filesDirectoryURL: URL

    var locationDescription: String {
        rootDirectoryURL.path
    }

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.rootDirectoryURL = rootURL
        self.imagesDirectoryURL = rootURL.appendingPathComponent(
            "Images",
            isDirectory: true
        )
        self.filesDirectoryURL = rootURL.appendingPathComponent(
            "Files",
            isDirectory: true
        )

        try? fileManager.createDirectory(
            at: imagesDirectoryURL,
            withIntermediateDirectories: true
        )
        try? fileManager.createDirectory(
            at: filesDirectoryURL,
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

    func deleteManagedImage(_ attachment: ChatAttachment) throws {
        guard attachment.isImage else {
            throw ChatAttachmentStorageError.unsafeDeletion
        }
        try deleteManagedAttachment(attachment)
    }

    func deleteManagedAttachment(_ attachment: ChatAttachment) throws {
        let target = attachment.localURL.standardizedFileURL.resolvingSymlinksInPath()
        let allowedDirectories = [imagesDirectoryURL, filesDirectoryURL].map {
            $0.standardizedFileURL.resolvingSymlinksInPath()
        }
        guard allowedDirectories.contains(target.deletingLastPathComponent()) else {
            throw ChatAttachmentStorageError.unsafeDeletion
        }
        guard fileManager.fileExists(atPath: target.path) else { return }
        let values = try target.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw ChatAttachmentStorageError.unsafeDeletion
        }
        try fileManager.removeItem(at: target)
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

    func prepareOutgoingFile(from sourceURL: URL) throws -> ChatAttachment {
        let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
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

        guard values.isRegularFile == true else {
            throw ChatAttachmentStorageError.unsupportedFile
        }
        guard let fileSize = values.fileSize,
              Int64(fileSize) >= 0,
              Int64(fileSize) <= Self.maximumFileBytes else {
            throw ChatAttachmentStorageError.invalidFileSize
        }

        let originalName = Self.safeFileName(sourceURL.lastPathComponent)
        let fileName = originalName.isEmpty ? "未命名文件" : originalName
        let destinationURL = filesDirectoryURL.appendingPathComponent(
            "\(UUID().uuidString)_\(fileName)",
            isDirectory: false
        )

        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw ChatAttachmentStorageError.copyFailed(error.localizedDescription)
        }

        let descriptor = FeiQFileAttachment(
            fileID: Self.makeFileID(),
            fileName: fileName,
            fileSize: Int64(fileSize),
            modifiedAt: Int64((values.contentModificationDate ?? Date()).timeIntervalSince1970),
            fileAttributes: Self.regularFileAttribute
        )

        return ChatAttachment(
            descriptor: descriptor,
            localPath: destinationURL.path,
            mimeType: Self.mimeType(for: fileName),
            kind: .file
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
            fileID: Self.makeFileID(),
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
        guard descriptor.isImage, descriptor.isRegularFile else {
            throw ChatAttachmentStorageError.unsupportedImage
        }
        guard descriptor.fileSize >= 0,
              descriptor.fileSize <= Self.maximumFileBytes else {
            throw ChatAttachmentStorageError.invalidFileSize
        }

        return makeIncomingAttachment(
            descriptor: descriptor,
            directoryURL: imagesDirectoryURL,
            kind: .image
        )
    }

    func prepareIncomingFile(for descriptor: FeiQFileAttachment) throws -> ChatAttachment {
        guard descriptor.isRegularFile else {
            throw ChatAttachmentStorageError.unsupportedFile
        }
        guard descriptor.fileSize >= 0,
              descriptor.fileSize <= Self.maximumFileBytes else {
            throw ChatAttachmentStorageError.invalidFileSize
        }

        return makeIncomingAttachment(
            descriptor: descriptor,
            directoryURL: filesDirectoryURL,
            kind: .file
        )
    }

    private static func imageType(for url: URL) -> UTType? {
        guard !url.pathExtension.isEmpty else { return nil }
        return UTType(filenameExtension: url.pathExtension)
    }

    private static func mimeType(for fileName: String) -> String {
        imageType(for: URL(fileURLWithPath: fileName))?.preferredMIMEType
            ?? "application/octet-stream"
    }

    private func makeIncomingAttachment(
        descriptor: FeiQFileAttachment,
        directoryURL: URL,
        kind: ChatAttachmentKind
    ) -> ChatAttachment {
        let fileName = Self.safeFileName(descriptor.fileName)
        let destinationURL = directoryURL.appendingPathComponent(
            "\(UUID().uuidString)_\(fileName)",
            isDirectory: false
        )

        return ChatAttachment(
            descriptor: descriptor,
            localPath: destinationURL.path,
            mimeType: Self.mimeType(for: fileName),
            kind: kind
        )
    }

    func saveInlineImage(_ data: Data, imageID: String, isBitmap: Bool) throws -> ChatAttachment {
        guard !data.isEmpty, data.count <= FeiQInlineImageCodec.maximumBytes else {
            throw ChatAttachmentStorageError.invalidFileSize
        }
        // The bitmap flag differs across clients and image sources. Prefer
        // an actual image container (JPEG/PNG/BMP), then a validated raw DIB.
        // Do not reject a decodable JPEG solely because bitmapFlag is 1.
        let jpeg: Data
        if let decoded = try? Self.jpegData(from: data) {
            jpeg = decoded
        } else {
            jpeg = try Self.jpegData(from: Self.bitmapFile(from: data))
        }
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
        guard [40, 52, 56, 108, 124].contains(headerSize), dib.count >= headerSize else {
            throw ChatAttachmentStorageError.unsupportedImage
        }
        let bitCount = Int(dib[14]) | Int(dib[15]) << 8
        let compression = uint32(16)
        guard [1, 4, 8, 16, 24, 32].contains(bitCount),
              dib[12] == 1, dib[13] == 0,
              [0, 3, 6].contains(compression) else {
            throw ChatAttachmentStorageError.unsupportedImage
        }
        let colors = uint32(32) > 0 ? uint32(32) : (bitCount <= 8 ? 1 << bitCount : 0)
        let masks = headerSize == 40 ? (compression == 3 ? 12 : (compression == 6 ? 16 : 0)) : 0
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
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\0", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "file" : sanitized
    }

    private static func makeFileID() -> String {
        String(UInt32.random(in: 1...UInt32.max))
    }
}
