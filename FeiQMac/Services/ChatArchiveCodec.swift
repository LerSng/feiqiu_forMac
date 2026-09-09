import Foundation

enum ChatArchiveCodec {
    static let maximumDocumentBytes = 200 * 1024 * 1024
    private static let beginMarker = "-----BEGIN FEIQ MAC ARCHIVE V1-----"
    private static let endMarker = "-----END FEIQ MAC ARCHIVE V1-----"

    static func encode(_ archive: ChatHistoryArchive, format: ChatHistoryExportFormat) throws -> Data {
        try archive.validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let recovery = try encoder.encode(archive).base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        let metadata = "\(beginMarker)\n\(recovery)\n\(endMarker)"
        let footer = format == .txt
            ? "\n\n以下为导入恢复数据，请保留完整文件及配套附件目录。\n\(metadata)\n"
            : "\n\n<!-- 飞秋 Mac 导入恢复数据，请勿修改。\n\(metadata)\n-->\n"
        let document = render(archive, format: format) + footer
        let data = Data(document.utf8)
        guard data.count <= maximumDocumentBytes else { throw ChatHistoryArchiveError.documentTooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> ChatHistoryArchive {
        guard data.count <= maximumDocumentBytes else { throw ChatHistoryArchiveError.documentTooLarge }
        guard let document = String(data: data, encoding: .utf8) else {
            throw ChatHistoryArchiveError.invalidArchive("文件不是 UTF-8 文本")
        }
        guard let begin = document.range(of: beginMarker, options: .backwards),
              let end = document.range(of: endMarker, range: begin.upperBound..<document.endIndex),
              let payload = Data(base64Encoded: document[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }) else {
            throw ChatHistoryArchiveError.missingRecoveryData
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let archive = try decoder.decode(ChatHistoryArchive.self, from: payload)
            try archive.validate()
            return archive
        } catch let error as ChatHistoryArchiveError {
            throw error
        } catch {
            throw ChatHistoryArchiveError.invalidArchive("恢复数据已损坏或不完整")
        }
    }

    static func attachmentLink(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")) ?? ""
    }

    private static func render(_ archive: ChatHistoryArchive, format: ChatHistoryExportFormat) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let exportedAt = formatter.string(from: archive.exportedAt)
        let names = archive.conversationNames
        let conversations = Dictionary(grouping: archive.messages, by: \.conversationID)
        let identifiers = conversations.keys.sorted {
            let first = names[$0] ?? $0
            let second = names[$1] ?? $1
            return first == second ? $0 < $1 : first.localizedStandardCompare(second) == .orderedAscending
        }
        var sections: [String] = []
        for identifier in identifiers {
            let title = names[identifier] ?? identifier
            let records = conversations[identifier, default: []].sorted {
                if $0.message.date != $1.message.date { return $0.message.date < $1.message.date }
                return $0.message.id.uuidString < $1.message.id.uuidString
            }
            let messages = records.map { record -> String in
                let message = record.message
                let sender = message.senderName.isEmpty ? (message.direction == .outgoing ? "我" : title) : message.senderName
                let heading = "\(formatter.string(from: message.date)) · \(sender) · \(message.direction == .outgoing ? "发送" : "接收")"
                let attachments = message.attachments.map { attachment -> String in
                    let label = "[\(attachment.isImage ? "图片" : "文件")] \(attachment.fileName)（\(attachment.fileSizeDescription)）"
                    guard !attachment.localPath.isEmpty else {
                        let missing = label + " · 附件文件未找到"
                        return format == .html ? "<p class=\"missing\">\(escapeHTML(missing))</p>" : escape(missing, format: format)
                    }
                    let link = attachmentLink(attachment.localPath)
                    switch format {
                    case .txt: return "\(label)\n  路径：\(attachment.localPath)"
                    case .markdown: return "[\(escapeMarkdown(label))](\(link))"
                    case .html:
                        let preview = attachment.isImage ? "<img loading=\"lazy\" src=\"\(link)\" alt=\"\(escapeHTML(attachment.fileName))\">" : ""
                        return "<p><a href=\"\(link)\">\(escapeHTML(label))</a></p>\(preview)"
                    }
                }.joined(separator: "\n")
                switch format {
                case .txt: return "[\(heading)]\n\(message.text)\n\(attachments)"
                case .markdown: return "### \(escapeMarkdown(heading))\n\n\(escapeMarkdown(message.text))\n\n\(attachments)"
                case .html: return "<article><header>\(escapeHTML(heading))</header><pre>\(escapeHTML(message.text))</pre>\(attachments)</article>"
                }
            }.joined(separator: "\n\n")
            switch format {
            case .txt: sections.append("\n========================================\n会话：\(title)\n\n\(messages)")
            case .markdown: sections.append("## \(escapeMarkdown(title))\n\n\(messages)")
            case .html: sections.append("<section><h2>\(escapeHTML(title))</h2>\(messages)</section>")
            }
        }
        let summary = "导出时间：\(exportedAt) · 共 \(archive.messages.count) 条消息"
        let body = sections.joined(separator: "\n\n")
        switch format {
        case .txt: return "飞秋 Mac 聊天记录\n\(summary)\n\(body)"
        case .markdown: return "# 飞秋 Mac 聊天记录\n\n\(summary)\n\n\(body)"
        case .html:
            return """
                <!doctype html>
                <html lang="zh-CN"><head><meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src file: data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
                <title>飞秋 Mac 聊天记录</title>
                <style>
                body{font:15px/1.65 -apple-system,BlinkMacSystemFont,sans-serif;color:#243047;background:#f5f7fb;margin:0}
                main{max-width:960px;margin:32px auto;padding:28px}h1{font-size:28px}h2{margin-top:32px}
                article{background:white;border:1px solid #dde3ef;border-radius:12px;padding:16px;margin:14px 0;break-inside:avoid}
                header,.summary{color:#66758d;font-size:13px}pre{font:inherit;white-space:pre-wrap;overflow-wrap:anywhere}
                img{max-width:100%;max-height:480px;border-radius:8px}a{color:#285fbd;overflow-wrap:anywhere}.missing{color:#94621c}
                @media print{body{background:white}main{padding:0;margin:0}}
                </style></head><body><main><h1>飞秋 Mac 聊天记录</h1><p class="summary">\(escapeHTML(summary))</p>\(body)</main></body></html>
                """
        }
    }

    private static func escape(_ text: String, format: ChatHistoryExportFormat) -> String {
        format == .markdown ? escapeMarkdown(text) : text
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func escapeMarkdown(_ text: String) -> String {
        let escaped = escapeHTML(text)
        let punctuation: Set<Character> = ["\\", "`", "*", "_", "[", "]", "(", ")", "#", "!", "|", "~"]
        return escaped.map { punctuation.contains($0) ? "\\\($0)" : String($0) }.joined()
            .replacingOccurrences(of: "\n", with: "  \n")
    }
}
