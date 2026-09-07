//
//  FeiQInlineImage.swift
//  FeiQMac
//
//  飞秋内嵌图片的标记、二进制分片编解码及有界重组。调用方串行访问。
//  Wire reference: alakenda/HIM ScreenShotPkgHeader, zyqg/feiq-android protocol docs.
//

import Foundation

enum FeiQInlineImageCodec {
    static let maximumBytes = 20 * 1024 * 1024
    static let chunkSize = 512
    private static let markerRegex = try! NSRegularExpression(pattern: #"/~#>([0-9a-fA-F]{8})<B~"#)

    static func imageIDs(in text: String) -> [String] {
        markerRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]).lowercased() } }
    }

    static func replacingMarkers(in text: String, with replacement: String) -> String {
        markerRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }

    static func marker(for id: String) -> String { "/~#>\(id)<B~" }

    struct Chunk {
        let imageID: String
        let totalBytes: Int
        let offset: Int
        let totalChunks: Int
        let index: Int
        let bitmapFlag: Int
        let formatFlag: Int
        let data: Data
    }

    static func decode(_ data: Data) -> Chunk? {
        guard let boundary = data.prefix(256).firstIndex(of: 0),
              let header = String(data: data.prefix(upTo: boundary), encoding: .ascii),
              header.hasSuffix("#") else { return nil }
        let fields = header.dropLast().split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 10, fields[0].count == 8,
              UInt32(fields[0], radix: 16) != nil,
              let total = Int(fields[1]), total > 0, total <= maximumBytes,
              let offset = Int(fields[2]), offset >= 0, offset < total,
              let count = Int(fields[3]), count > 0, count <= 65536,
              let index = Int(fields[4]), (1...count).contains(index),
              let size = Int(fields[5]), size > 0, size <= 60000, size <= total - offset,
              let bitmap = Int(fields[6]), let format = Int(fields[7]) else { return nil }
        let payload = data.suffix(from: data.index(after: boundary))
        // A few clients append a NUL after the binary payload. Respect the
        // advertised length; never trim binary zero/CR/LF bytes.
        guard payload.count == size || (payload.count == size + 1 && payload.last == 0) else { return nil }
        return Chunk(imageID: fields[0].lowercased(), totalBytes: total, offset: offset,
                     totalChunks: count, index: index, bitmapFlag: bitmap, formatFlag: format,
                     data: Data(payload.prefix(size)))
    }

    static func encode(imageID: String, data: Data, index: Int) -> Data {
        let count = (data.count + chunkSize - 1) / chunkSize
        let offset = (index - 1) * chunkSize
        let size = min(chunkSize, data.count - offset)
        var result = Data("\(imageID)|\(data.count)|\(offset)|\(count)|\(index)|\(size)|0|2|0|00000000#".utf8)
        result.append(0)
        result.append(data.subdata(in: offset..<(offset + size)))
        return result
    }

    static func acknowledgement(_ text: String) -> (imageID: String, index: Int)? {
        guard text.hasSuffix("#") else { return nil }
        let fields = text.dropLast().split(separator: "|")
        guard fields.count == 2, fields[0].count == 8, UInt32(fields[0], radix: 16) != nil,
              let index = Int(fields[1]), index > 0 else { return nil }
        return (fields[0].lowercased(), index)
    }
}

final class FeiQInlineImageAssembler {
    private final class Buffer {
        let first: FeiQInlineImageCodec.Chunk
        var chunks: [Int: FeiQInlineImageCodec.Chunk] = [:]
        var byteCount = 0
        var updatedAt = Date()
        init(_ chunk: FeiQInlineImageCodec.Chunk) { first = chunk }
    }
    private var buffers: [String: Buffer] = [:]
    private var completed: [String: Date] = [:]

    func clear() { buffers.removeAll(); completed.removeAll() }

    func prune(now: Date = Date()) {
        buffers = buffers.filter { now.timeIntervalSince($0.value.updatedAt) < 600 }
        completed = completed.filter { now.timeIntervalSince($0.value) < 180 }
    }

    /// Returns whether this chunk was accepted (and may be ACKed), together
    /// with the completed bytes once only. Keys include the remote IP.
    func accept(
        _ chunk: FeiQInlineImageCodec.Chunk,
        from ip: String,
        onAccepted: () -> Void = {}
    ) -> (accepted: Bool, data: Data?) {
        let key = ip + "/" + chunk.imageID
        if let completedAt = completed[key], Date().timeIntervalSince(completedAt) < 180 {
            onAccepted()
            return (true, nil)
        }
        completed.removeValue(forKey: key)
        if buffers[key] == nil {
            prune()
            guard buffers.count < 8,
                  buffers.values.reduce(0, { $0 + $1.first.totalBytes }) + chunk.totalBytes <= 64 * 1024 * 1024 else { return (false, nil) }
            buffers[key] = Buffer(chunk)
        }
        guard let buffer = buffers[key], buffer.first.totalBytes == chunk.totalBytes,
              buffer.first.totalChunks == chunk.totalChunks,
              buffer.first.bitmapFlag == chunk.bitmapFlag,
              buffer.first.formatFlag == chunk.formatFlag else { return (false, nil) }
        buffer.updatedAt = Date()
        if let old = buffer.chunks[chunk.index] {
            let matches = old.offset == chunk.offset && old.data == chunk.data
            if matches { onAccepted() }
            return (matches, nil)
        }
        guard buffer.byteCount + chunk.data.count <= chunk.totalBytes else { return (false, nil) }
        buffer.chunks[chunk.index] = chunk
        buffer.byteCount += chunk.data.count
        // ACK after admitting the bounded chunk, before sorting/copying the
        // complete image. The sender can immediately advance its UDP window.
        onAccepted()
        guard buffer.chunks.count == chunk.totalChunks else { return (true, nil) }
        var result = Data()
        result.reserveCapacity(chunk.totalBytes)
        for part in buffer.chunks.values.sorted(by: { $0.offset < $1.offset }) {
            guard part.offset == result.count else {
                buffers.removeValue(forKey: key)
                return (false, nil)
            }
            result.append(part.data)
        }
        buffers.removeValue(forKey: key)
        guard result.count == chunk.totalBytes else { return (false, nil) }
        if completed.count >= 256, let oldest = completed.min(by: { $0.value < $1.value })?.key {
            completed.removeValue(forKey: oldest)
        }
        completed[key] = Date()
        return (true, result)
    }
}

/// Sliding-window send state. The network queue owns instances and uses its
/// timer to resend only unacknowledged chunks, with bounded retry counts.
final class FeiQInlineImageSendSession {
    let imageID: String
    let ipAddress: String
    let data: Data
    let count: Int
    private var nextIndex = 1
    private var pending: [Int: (sentAt: Date, attempts: Int)] = [:]
    private(set) var failed = false
    var isComplete: Bool { nextIndex > count && pending.isEmpty }

    init(imageID: String, ipAddress: String, data: Data) {
        self.imageID = imageID; self.ipAddress = ipAddress; self.data = data
        count = (data.count + FeiQInlineImageCodec.chunkSize - 1) / FeiQInlineImageCodec.chunkSize
    }

    func acknowledge(_ index: Int) { pending.removeValue(forKey: index) }

    func nextChunks(now: Date = Date()) -> [Int] {
        var indexes: [Int] = []
        for (index, state) in pending where now.timeIntervalSince(state.sentAt) >= 1 {
            guard state.attempts < 8 else { failed = true; return [] }
            pending[index] = (now, state.attempts + 1)
            indexes.append(index)
        }
        while pending.count < 16 && nextIndex <= count {
            indexes.append(nextIndex)
            pending[nextIndex] = (now, 1)
            nextIndex += 1
        }
        return indexes.sorted()
    }
}
