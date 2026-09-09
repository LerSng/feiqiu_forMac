import Foundation

final class ChatArchiveRepository {
    private let messageRepository: MessageRepository
    private let attachmentRepository: AttachmentRepository
    private let queue = DispatchQueue(label: "com.local.feiqmac.chat-archive", qos: .utility)
    private let fileManager = FileManager.default

    init(messageRepository: MessageRepository, attachmentRepository: AttachmentRepository) {
        self.messageRepository = messageRepository
        self.attachmentRepository = attachmentRepository
    }

    func exportHistory(
        matching query: ChatHistorySearchQuery, format: ChatHistoryExportFormat, to destination: URL,
        completion: @escaping (Result<ChatHistoryExportSummary, Error>) -> Void
    ) {
        messageRepository.loadArchive(matching: query) { result in
            self.queue.async {
                do {
                    completion(.success(try self.writeExport(result.get(), format: format, to: destination)))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    func inspectHistoryImport(
        from source: URL,
        completion: @escaping (Result<ChatHistoryImportPreview, Error>) -> Void
    ) {
        queue.async {
            do {
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true else { throw ChatHistoryArchiveError.invalidArchive("请选择普通文本文件") }
                guard let size = values.fileSize, size <= ChatArchiveCodec.maximumDocumentBytes else {
                    throw ChatHistoryArchiveError.documentTooLarge
                }
                let archive = try ChatArchiveCodec.decode(Data(contentsOf: source, options: .mappedIfSafe))
                var missingCount = 0
                for record in archive.messages {
                    for attachment in record.message.attachments {
                        if try self.importSource(for: attachment, archive: archive, documentURL: source) == nil {
                            missingCount += 1
                        }
                    }
                }
                completion(.success(ChatHistoryImportPreview(sourceURL: source, archive: archive, missingAttachmentCount: missingCount)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func importHistory(
        _ preview: ChatHistoryImportPreview,
        completion: @escaping (Result<ChatHistoryImportSummary, Error>) -> Void
    ) {
        queue.async {
            do {
                let prepared = try self.prepareImport(preview)
                self.messageRepository.importArchive(prepared.archive) { response in
                    self.queue.async {
                        switch response {
                        case .success(var summary):
                            let inserted = prepared.archive.messages.filter { summary.insertedMessageIDs.contains($0.message.id) }
                            let keptPaths = Set(inserted.flatMap { $0.message.attachments.map(\.localPath) })
                            summary.missingAttachmentCount = inserted.flatMap { $0.message.attachments }.filter { $0.localPath.isEmpty }.count
                            summary.cleanupWarning = self.cleanup(prepared.copied.filter { !keptPaths.contains($0.localPath) })
                            completion(.success(summary))
                        case .failure(let error):
                            let warning = self.cleanup(prepared.copied)
                            if let warning {
                                completion(.failure(ChatHistoryArchiveError.invalidArchive(error.localizedDescription + "；" + warning)))
                            } else {
                                completion(.failure(error))
                            }
                        }
                    }
                }
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func writeExport(
        _ source: ChatHistoryArchive, format: ChatHistoryExportFormat, to destination: URL
    ) throws -> ChatHistoryExportSummary {
        try source.validate()
        guard !source.messages.isEmpty else { throw ChatHistoryArchiveError.emptyExport }
        var archive = source
        let directoryName = "FeiQ-Attachments-" + UUID().uuidString
        let directory = destination.deletingLastPathComponent().appendingPathComponent(directoryName, isDirectory: true)
        var createdDirectory = false
        var completed = false
        var copiedPaths: [String: (path: String, size: Int64)] = [:]
        var missingCount = 0
        defer {
            if createdDirectory && !completed { try? fileManager.removeItem(at: directory) }
        }
        for index in archive.messages.indices {
            let message = archive.messages[index].message
            let attachments = try message.attachments.map { attachment -> ChatAttachment in
                guard !attachment.localPath.isEmpty, fileManager.fileExists(atPath: attachment.localPath) else {
                    missingCount += 1
                    return replacingPath(of: attachment, with: "")
                }
                let values = try attachment.localURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw ChatHistoryArchiveError.unsafeAttachmentPath
                }
                guard let fileSize = values.fileSize, Int64(fileSize) <= 2 * 1024 * 1024 * 1024 else {
                    throw ChatAttachmentStorageError.invalidFileSize
                }
                let key = attachment.localURL.standardizedFileURL.path
                if let previous = copiedPaths[key] {
                    return replacingPath(of: attachment, with: previous.path, size: previous.size)
                }
                if !createdDirectory {
                    try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
                    createdDirectory = true
                }
                let suffix = String(attachment.localURL.pathExtension.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(12))
                let name = UUID().uuidString + (suffix.isEmpty ? "" : ".\(suffix)")
                let path = directoryName + "/" + name
                try fileManager.copyItem(at: attachment.localURL, to: directory.appendingPathComponent(name))
                copiedPaths[key] = (path, Int64(fileSize))
                return replacingPath(of: attachment, with: path, size: Int64(fileSize))
            }
            archive.messages[index].message = replacingAttachments(of: message, with: attachments)
        }
        archive.attachmentDirectory = createdDirectory ? directoryName : nil
        let data = try ChatArchiveCodec.encode(archive, format: format)
        try data.write(to: destination, options: .atomic)
        completed = true
        return ChatHistoryExportSummary(
            fileURL: destination, messageCount: archive.messages.count,
            attachmentCount: copiedPaths.count, missingAttachmentCount: missingCount
        )
    }

    private func prepareImport(_ preview: ChatHistoryImportPreview) throws -> (archive: ChatHistoryArchive, copied: [ChatAttachment]) {
        try preview.archive.validate()
        var archive = preview.archive
        var copied: [ChatAttachment] = []
        var cache: [String: ChatAttachment] = [:]
        do {
            for index in archive.messages.indices {
                let message = archive.messages[index].message
                let attachments = try message.attachments.map { attachment -> ChatAttachment in
                    guard let source = try importSource(for: attachment, archive: preview.archive, documentURL: preview.sourceURL) else {
                        return replacingPath(of: attachment, with: "")
                    }
                    let key = attachment.kind.rawValue + ":" + source.path
                    if let cached = cache[key] {
                        return replacingPath(of: attachment, with: cached.localPath)
                    }
                    let imported = try attachmentRepository.importAttachment(attachment, from: source)
                    copied.append(imported)
                    cache[key] = imported
                    return imported
                }
                archive.messages[index].message = replacingAttachments(of: message, with: attachments)
            }
            archive.attachmentDirectory = nil
            return (archive, copied)
        } catch {
            if let warning = cleanup(copied) {
                throw ChatHistoryArchiveError.invalidArchive(error.localizedDescription + "；" + warning)
            }
            throw error
        }
    }

    private func importSource(for attachment: ChatAttachment, archive: ChatHistoryArchive, documentURL: URL) throws -> URL? {
        guard !attachment.localPath.isEmpty else { return nil }
        let components = attachment.localPath.components(separatedBy: "/")
        guard let directoryName = archive.attachmentDirectory, isSafeComponent(directoryName),
              components.count == 2, components[0] == directoryName, isSafeComponent(components[1]) else {
            throw ChatHistoryArchiveError.unsafeAttachmentPath
        }
        let parent = documentURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let directory = parent.appendingPathComponent(directoryName, isDirectory: true)
        let source = directory.appendingPathComponent(components[1])
        for location in [directory, source] {
            let values: URLResourceValues
            do {
                values = try location.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            } catch CocoaError.fileReadNoSuchFile {
                return nil
            }
            guard values.isSymbolicLink != true else { throw ChatHistoryArchiveError.unsafeAttachmentPath }
            if location == directory {
                guard values.isDirectory == true else { throw ChatHistoryArchiveError.unsafeAttachmentPath }
            } else {
                guard values.isRegularFile == true,
                      source.resolvingSymlinksInPath().path.hasPrefix(directory.path + "/") else {
                    throw ChatHistoryArchiveError.unsafeAttachmentPath
                }
                guard let size = values.fileSize, Int64(size) == attachment.fileSize else {
                    throw ChatHistoryArchiveError.attachmentChanged(attachment.fileName)
                }
            }
        }
        return source
    }

    private func isSafeComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".."
            && !component.contains("/") && !component.contains("\\")
            && component.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private func replacingPath(of attachment: ChatAttachment, with path: String, size: Int64? = nil) -> ChatAttachment {
        ChatAttachment(id: attachment.id, kind: attachment.kind, fileName: attachment.fileName,
                       fileSize: size ?? attachment.fileSize, modifiedAt: attachment.modifiedAt,
                       fileAttributes: attachment.fileAttributes, localPath: path, mimeType: attachment.mimeType)
    }

    private func replacingAttachments(of message: ChatMessage, with attachments: [ChatAttachment]) -> ChatMessage {
        ChatMessage(id: message.id, direction: message.direction, text: message.text, senderName: message.senderName,
                    recipientName: message.recipientName, date: message.date, attachments: attachments)
    }

    private func cleanup(_ attachments: [ChatAttachment]) -> String? {
        var failed = 0
        for attachment in attachments {
            do { try attachmentRepository.deleteManagedAttachment(attachment) }
            catch { failed += 1 }
        }
        return failed == 0 ? nil : "\(failed) 个未使用的临时附件清理失败"
    }
}
