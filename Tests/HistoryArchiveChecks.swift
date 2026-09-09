import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct HistoryArchiveChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feiq-history-archive-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await checkThumbnails(root: root)
        try await checkRoundTrips(root: root)
        try await checkConflictsAndRollback(root: root)
        try await checkUnsafeImports(root: root)
        print("History archive and thumbnail checks passed")
    }

    private static func checkThumbnails(root: URL) async throws {
        let imageURL = root.appendingPathComponent("large-preview.png")
        try writeImage(to: imageURL, width: 2400, height: 1200)
        let attachment = try makeAttachment(id: "large", kind: .image, url: imageURL)
        let service = ChatImageThumbnailService()
        let thumbnail = await service.thumbnail(for: attachment, pixelSize: 320)
        precondition(thumbnail?.width == 320 && thumbnail?.height == 160, "Thumbnails must preserve aspect ratio and downsample the original")
        let cached = await service.thumbnail(for: attachment, pixelSize: 320)
        precondition(thumbnail === cached, "Repeated results should share a bounded thumbnail cache")
        let bounded = await service.thumbnail(for: attachment, pixelSize: Int.max)
        precondition(bounded?.width == 640)
        try writeImage(to: imageURL, width: 100, height: 200)
        let changed = await service.thumbnail(for: attachment, pixelSize: 320)
        precondition(changed?.width == 100 && changed?.height == 200, "Updated files must invalidate the cache")
        try FileManager.default.removeItem(at: imageURL)
        let missing = await service.thumbnail(for: attachment)
        precondition(missing == nil, "Missing images must not display stale cached pixels")
        let corruptURL = root.appendingPathComponent("corrupt.png")
        try Data("not an image".utf8).write(to: corruptURL)
        let corrupt = await service.thumbnail(for: try makeAttachment(id: "corrupt", kind: .image, url: corruptURL))
        precondition(corrupt == nil)
        let ordinary = await service.thumbnail(for: try makeAttachment(id: "file", kind: .file, url: corruptURL))
        precondition(ordinary == nil)
    }

    private static func checkRoundTrips(root: URL) async throws {
        let sourceRoot = root.appendingPathComponent("source")
        let service = makeService(at: sourceRoot)
        let repository = makeRepository(at: sourceRoot, service: service)
        let peer = makePeer("peer-source", name: "测试 <联系人>")
        let member = makePeer("group-member", name: "群成员")
        let group = ChatGroup(name: "项目群", memberIDs: [peer.id, member.id], ownerName: "我")
        let imageURL = sourceRoot.appendingPathComponent("截图 #1.png")
        try writeImage(to: imageURL, width: 120, height: 80)
        let fileURL = sourceRoot.appendingPathComponent("报告 [最终].txt")
        let fileData = Data("中文附件正文\n第二行\n".utf8)
        try fileData.write(to: fileURL)
        let image = try makeAttachment(id: "picture", kind: .image, url: imageURL)
        let file = try makeAttachment(id: "document", kind: .file, url: fileURL)
        let missing = ChatAttachment(id: "missing", kind: .image, fileName: "丢失图片.jpg", fileSize: 100,
                                     modifiedAt: 0, fileAttributes: 1, localPath: "/missing/archive-test.jpg", mimeType: "image/jpeg")
        let date = Date(timeIntervalSince1970: 1700000000.125)
        let first = ChatMessage(direction: .outgoing,
                                text: "你好 😀\n<script>alert('x')</script>\n[外部](https://example.invalid)\n-----END FEIQ MAC ARCHIVE V1-----",
                                senderName: "我", recipientName: peer.name, date: date, attachments: [image, file])
        let second = ChatMessage(direction: .incoming, text: "群消息\n多行", senderName: member.name,
                                 date: date.addingTimeInterval(0.125), attachments: [image, missing])
        service.savePeer(member)
        service.saveMessage(first, for: peer, unreadCount: 0)
        service.saveMessage(second, for: group, unreadCount: 0)
        var bulk: [ChatMessage] = []
        for index in 0..<215 {
            let message = ChatMessage(direction: .incoming, text: "分页导出 \(index)", date: date.addingTimeInterval(Double(index + 1)))
            bulk.append(message)
            service.saveMessage(message, for: peer, unreadCount: 0)
        }
        let expectedMessages = [first, second] + bulk
        let raw: ChatHistoryArchive = try await receive { service.loadArchive(matching: .init(), completion: $0) }
        precondition(raw.messages.count == expectedMessages.count)
        let filtered: ChatHistoryArchive = try await receive {
            service.loadArchive(matching: .init(conversationID: peer.id, text: "你好", kind: .image), completion: $0)
        }
        precondition(filtered.messages.map { $0.message.id } == [first.id])

        for format in ChatHistoryExportFormat.allCases {
            let exportURL = root.appendingPathComponent("聊天记录.\(format.fileExtension)")
            let exported: ChatHistoryExportSummary = try await receive {
                repository.exportHistory(matching: .init(), format: format, to: exportURL, completion: $0)
            }
            precondition(exported.messageCount == expectedMessages.count && exported.attachmentCount == 2 && exported.missingAttachmentCount == 1)
            let data = try Data(contentsOf: exportURL)
            let decoded = try ChatArchiveCodec.decode(data)
            precondition(decoded.messages.count == expectedMessages.count)
            precondition(!String(decoding: data, as: UTF8.self).contains(sourceRoot.path), "Exports must not leak original absolute attachment paths")
            let rendered = String(decoding: data, as: UTF8.self)
            if format == .html {
                precondition(rendered.contains("&lt;script&gt;") && !rendered.contains("<script>"))
                precondition(rendered.contains("<img loading=\"lazy\"") && rendered.contains("Content-Security-Policy"))
            }
            if format == .markdown { precondition(rendered.contains("\\[外部\\]") && !rendered.contains("[外部](https://example.invalid)")) }
            let targetRoot = root.appendingPathComponent("import-\(format.rawValue)")
            let targetService = makeService(at: targetRoot)
            let target = makeRepository(at: targetRoot, service: targetService)
            let preview: ChatHistoryImportPreview = try await receive { target.inspectHistoryImport(from: exportURL, completion: $0) }
            precondition(preview.missingAttachmentCount == 1)
            let summary: ChatHistoryImportSummary = try await receive { target.importHistory(preview, completion: $0) }
            precondition(summary.importedMessageCount == expectedMessages.count && summary.skippedMessageCount == 0)
            precondition(summary.missingAttachmentCount == 1 && summary.cleanupWarning == nil)
            let restored: ChatHistoryArchive = try await receive { targetService.loadArchive(matching: .init(), completion: $0) }
            let restoredByID = Dictionary(uniqueKeysWithValues: restored.messages.map { ($0.message.id, $0.message) })
            for original in expectedMessages {
                let restored = restoredByID[original.id]!
                precondition(restored.id == original.id && restored.text == original.text && restored.direction == original.direction)
                precondition(restored.date == original.date && restored.senderName == original.senderName && restored.recipientName == original.recipientName)
                precondition(restored.attachments.map(\.id) == original.attachments.map(\.id))
            }
            let restoredImage = restoredByID[first.id]!.attachments[0]
            let restoredFile = restoredByID[first.id]!.attachments[1]
            precondition(restoredImage.localPath.hasPrefix(targetRoot.appendingPathComponent("Images").path))
            precondition(restoredFile.localPath.hasPrefix(targetRoot.appendingPathComponent("Files").path))
            let restoredImageData = try Data(contentsOf: restoredImage.localURL)
            let originalImageData = try Data(contentsOf: imageURL)
            let restoredFileData = try Data(contentsOf: restoredFile.localURL)
            precondition(restoredImageData == originalImageData)
            precondition(restoredFileData == fileData)
            precondition(restoredByID[second.id]!.attachments[0].localPath == restoredImage.localPath)
            precondition(restoredByID[second.id]!.attachments[1].localPath.isEmpty && !restoredByID[second.id]!.attachments[1].isAvailable)
            let snapshot: ChatHistorySnapshot = try await receive { targetService.loadSnapshot(completion: $0) }
            precondition(snapshot.peers.allSatisfy { !$0.isOnline } && snapshot.unreadCountsByPeer.isEmpty)
            precondition(snapshot.groups.first?.memberIDs.isEmpty == true, "Import must not silently activate group message relaying")
            let pathsBefore = try managedPaths(at: targetRoot)
            let duplicate: ChatHistoryImportSummary = try await receive { target.importHistory(preview, completion: $0) }
            precondition(duplicate.importedMessageCount == 0 && duplicate.skippedMessageCount == expectedMessages.count)
            let pathsAfter = try managedPaths(at: targetRoot)
            precondition(duplicate.cleanupWarning == nil && pathsAfter == pathsBefore)
            let reopened = makeService(at: targetRoot)
            let reopenedArchive: ChatHistoryArchive = try await receive { reopened.loadArchive(matching: .init(), completion: $0) }
            precondition(reopenedArchive.messages.count == expectedMessages.count)
        }

        let sentinelURL = root.appendingPathComponent("unchanged.txt")
        try Data("keep existing document".utf8).write(to: sentinelURL)
        do {
            let _: ChatHistoryExportSummary = try await receive {
                repository.exportHistory(matching: .init(text: "不存在的关键词"), format: .txt, to: sentinelURL, completion: $0)
            }
            preconditionFailure("Empty exports must not overwrite an existing document")
        } catch ChatHistoryArchiveError.emptyExport {}
        let sentinel = try String(contentsOf: sentinelURL, encoding: .utf8)
        precondition(sentinel == "keep existing document")

        let movedRoot = root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: movedRoot, withIntermediateDirectories: true)
        let originalURL = root.appendingPathComponent("聊天记录.html")
        let movedURL = movedRoot.appendingPathComponent("renamed.html")
        try FileManager.default.copyItem(at: originalURL, to: movedURL)
        let movedArchive = try ChatArchiveCodec.decode(Data(contentsOf: movedURL))
        let directoryName = movedArchive.attachmentDirectory!
        try FileManager.default.copyItem(at: root.appendingPathComponent(directoryName), to: movedRoot.appendingPathComponent(directoryName))
        let movedPreview: ChatHistoryImportPreview = try await receive { repository.inspectHistoryImport(from: movedURL, completion: $0) }
        precondition(movedPreview.missingAttachmentCount == 1, "Portable imports must resolve attachments relative to the document")
        try FileManager.default.removeItem(at: movedRoot.appendingPathComponent(directoryName))
        let missingPreview: ChatHistoryImportPreview = try await receive { repository.inspectHistoryImport(from: movedURL, completion: $0) }
        precondition(missingPreview.missingAttachmentCount == 4)
    }

    private static func checkConflictsAndRollback(root: URL) async throws {
        let targetRoot = root.appendingPathComponent("conflicts")
        let service = makeService(at: targetRoot)
        let originalPeer = makePeer("existing", name: "保留名称")
        let message = ChatMessage(direction: .incoming, text: "现有记录", senderName: "原发送人")
        service.saveMessage(message, for: originalPeer, unreadCount: 3)
        let conflicting = makePeer("new-peer", name: "必须回滚")
        let importMessage = ChatMessage(id: message.id, direction: .outgoing, text: "试图覆盖")
        let archive = ChatHistoryArchive(peers: [conflicting], groups: [], messages: [.init(conversationID: conflicting.id, message: importMessage)])
        do {
            let _: ChatHistoryImportSummary = try await receive { service.importArchive(archive, completion: $0) }
            preconditionFailure("Conflicting message IDs must roll back the whole import")
        } catch ChatHistoryArchiveError.conflictingMessage {}
        let snapshot: ChatHistorySnapshot = try await receive { service.loadSnapshot(completion: $0) }
        precondition(snapshot.peers.map(\.id) == [originalPeer.id] && snapshot.totalMessageCount == 1)
        precondition(snapshot.unreadCountsByPeer[originalPeer.id] == 3)
        let duplicate = ChatHistoryArchive(peers: [makePeer(originalPeer.id, name: "不应覆盖名称")], groups: [],
                                           messages: [.init(conversationID: originalPeer.id, message: importMessage)])
        let summary: ChatHistoryImportSummary = try await receive { service.importArchive(duplicate, completion: $0) }
        precondition(summary.importedMessageCount == 0 && summary.skippedMessageCount == 1)
        let restored: ChatHistoryArchive = try await receive { service.loadArchive(matching: .init(), completion: $0) }
        precondition(restored.messages.first?.message == message && restored.peers.first?.name == originalPeer.name,
                     "Round trip: \(String(reflecting: restored.messages.first?.message)); original: \(String(reflecting: message)); peer: \(String(reflecting: restored.peers.first))")
        let group = ChatGroup(id: originalPeer.id, name: "冲突群聊", memberIDs: [], ownerName: "")
        do {
            let _: ChatHistoryImportSummary = try await receive {
                service.importArchive(.init(peers: [conflicting], groups: [group], messages: []), completion: $0)
            }
            preconditionFailure("Conversation-kind conflicts must roll back")
        } catch ChatHistoryArchiveError.conflictingConversation {}
        let afterConflict: ChatHistorySnapshot = try await receive { service.loadSnapshot(completion: $0) }
        precondition(afterConflict.peers.count == 1 && afterConflict.groups.isEmpty)
    }

    private static func checkUnsafeImports(root: URL) async throws {
        let targetRoot = root.appendingPathComponent("security-target")
        let service = makeService(at: targetRoot)
        let repository = makeRepository(at: targetRoot, service: service)
        let peer = makePeer("unsafe", name: "测试")
        let source = root.appendingPathComponent("unsafe.txt")
        let directoryName = "sidecar"
        let directory = root.appendingPathComponent(directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let secret = root.appendingPathComponent("must-not-read.txt")
        try Data("private".utf8).write(to: secret)

        func document(path: String, directoryName: String? = "sidecar") throws -> ChatHistoryArchive {
            let attachment = ChatAttachment(id: "test", kind: .file, fileName: "附件", fileSize: 7, modifiedAt: 0,
                                            fileAttributes: 1, localPath: path, mimeType: "text/plain")
            let message = ChatMessage(direction: .incoming, text: "测试", attachments: [attachment])
            let archive = ChatHistoryArchive(peers: [peer], groups: [], messages: [.init(conversationID: peer.id, message: message)],
                                             attachmentDirectory: directoryName)
            try ChatArchiveCodec.encode(archive, format: .txt).write(to: source)
            return archive
        }
        for path in [secret.path, "../must-not-read.txt", "sidecar/../must-not-read.txt", "sidecar/", "sidecar/\\outside", "other/must-not-read.txt"] {
            _ = try document(path: path)
            do {
                let _: ChatHistoryImportPreview = try await receive { repository.inspectHistoryImport(from: source, completion: $0) }
                preconditionFailure("Unsafe paths must be rejected: \(path)")
            } catch ChatHistoryArchiveError.unsafeAttachmentPath {}
        }
        let symlink = directory.appendingPathComponent("linked.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: secret)
        _ = try document(path: "sidecar/linked.txt")
        do {
            let _: ChatHistoryImportPreview = try await receive { repository.inspectHistoryImport(from: source, completion: $0) }
            preconditionFailure("Symlinks must not escape the sidecar directory")
        } catch ChatHistoryArchiveError.unsafeAttachmentPath {}

        let safe = directory.appendingPathComponent("safe.txt")
        try Data("private".utf8).write(to: safe)
        _ = try document(path: "sidecar/safe.txt")
        let preview: ChatHistoryImportPreview = try await receive { repository.inspectHistoryImport(from: source, completion: $0) }
        try FileManager.default.removeItem(at: safe)
        try FileManager.default.createSymbolicLink(at: safe, withDestinationURL: secret)
        do {
            let _: ChatHistoryImportSummary = try await receive { repository.importHistory(preview, completion: $0) }
            preconditionFailure("Import must revalidate paths after preview")
        } catch ChatHistoryArchiveError.unsafeAttachmentPath {}
        try FileManager.default.removeItem(at: safe)
        try Data("changed-size".utf8).write(to: safe)
        do {
            let _: ChatHistoryImportPreview = try await receive { repository.inspectHistoryImport(from: source, completion: $0) }
            preconditionFailure("Changed attachments must be rejected")
        } catch ChatHistoryArchiveError.attachmentChanged {}

        for bytes in [Data("plain third-party transcript".utf8), Data("-----BEGIN FEIQ MAC ARCHIVE V1-----\n!!!!\n-----END FEIQ MAC ARCHIVE V1-----".utf8)] {
            do {
                _ = try ChatArchiveCodec.decode(bytes)
                preconditionFailure("Malformed recovery data must be rejected")
            } catch {}
        }
        var invalid = try document(path: "", directoryName: nil)
        invalid.version = 2
        do { _ = try ChatArchiveCodec.encode(invalid, format: .html); preconditionFailure("Unsupported archive versions must fail") }
        catch ChatHistoryArchiveError.unsupportedVersion {}
        let final: ChatHistorySnapshot = try await receive { service.loadSnapshot(completion: $0) }
        let finalPaths = try managedPaths(at: targetRoot)
        precondition(final.totalMessageCount == 0 && final.peers.isEmpty && finalPaths.isEmpty)
    }

    private static func writeImage(to url: URL, width: Int, height: Int) throws {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
    }

    private static func makeAttachment(id: String, kind: ChatAttachmentKind, url: URL) throws -> ChatAttachment {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        return ChatAttachment(id: id, kind: kind, fileName: url.lastPathComponent, fileSize: Int64(size), modifiedAt: 0,
                              fileAttributes: 1, localPath: url.path, mimeType: kind == .image ? "image/png" : "text/plain")
    }

    private static func makePeer(_ identifier: String, name: String) -> FeiQPeer {
        FeiQPeer(id: identifier, name: name, hostName: "test-host", ipAddress: "192.0.2.1", group: "", lastSeen: Date(), isOnline: true)
    }

    private static func makeService(at root: URL) -> SQLiteChatHistoryService {
        SQLiteChatHistoryService(store: ChatHistoryStore(databaseURL: root.appendingPathComponent("history.sqlite"),
                                                       legacyURL: root.appendingPathComponent("missing.json")))
    }

    private static func makeRepository(at root: URL, service: ChatHistoryService) -> ChatArchiveRepository {
        ChatArchiveRepository(messageRepository: DefaultMessageRepository(historyService: service),
                              attachmentRepository: DefaultAttachmentRepository(storageService: LocalChatAttachmentStorageService(rootURL: root)))
    }

    private static func managedPaths(at root: URL) throws -> Set<String> {
        let paths = try ["Images", "Files"].flatMap {
            try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent($0), includingPropertiesForKeys: nil).map(\.path)
        }
        return Set(paths)
    }

    private static func receive<Value>(_ operation: (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in operation { continuation.resume(with: $0) } }
    }
}
