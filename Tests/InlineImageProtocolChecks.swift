// Standalone protocol regression checks; no Xcode app build or LAN peer required.
import Foundation
import ImageIO

@main
enum InlineImageProtocolChecks {
    static func main() throws {
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), name)
        }
        // Fixture follows the published FeiQ Windows format, independently
        // of the encoder under test. Its binary tail must remain byte-exact.
        let header = Data("1_lbt6_0#128#DEVICE#0#0#0#4001#9:123:Administrator:PC:2097344:".utf8)
        func fixture(_ metadata: String, _ bytes: [UInt8]) -> FeiQPacket {
            FeiQPacket.parse(header + Data(metadata.utf8) + Data([0]) + Data(bytes))!
        }
        let first = fixture("e8fdb8e6|6|0|2|1|3|0|2|0|00000000#", [1, 2, 0])
        let last = fixture("e8fdb8e6|6|3|2|2|3|0|2|0|00000000#", [0, 10, 13])
        check(first.commandType == .inlineImage, "Windows image command")
        let a = FeiQInlineImageCodec.decode(first.additionalData)!
        let b = FeiQInlineImageCodec.decode(last.additionalData)!
        check(b.data == Data([0, 10, 13]), "binary tail preserved")
        check(last.encoded() == header + last.additionalData, "binary packet gets no text terminator")
        check(FeiQInlineImageCodec.decode(Data("e8fdb8e6|6|0|2|1|3|0|2|0|00000000#\0".utf8) + Data([1, 2])) == nil, "reject truncated chunk")
        check(FeiQInlineImageCodec.decode(Data("e8fdb8e6|999999999|0|2|1|3|0|2|0|00000000#\0abc".utf8)) == nil, "reject oversized allocation")
        check(FeiQInlineImageCodec.decode(Data("e8fdb8e6|6|-1|2|1|3|0|2|0|00000000#\0abc".utf8)) == nil, "reject negative offset")
        let assembler = FeiQInlineImageAssembler()
        check(assembler.accept(b, from: "one").data == nil, "out of order")
        check(assembler.accept(b, from: "one").data == nil, "duplicate chunk")
        check(assembler.accept(a, from: "two").data == nil, "separate peers with same image ID")
        check(assembler.accept(a, from: "one").data == Data([1, 2, 0, 0, 10, 13]), "complete reassembly")
        let duplicate = assembler.accept(a, from: "one")
        check(duplicate.accepted && duplicate.data == nil, "completed retry ACK without duplicate delivery")
        let overlap = FeiQInlineImageCodec.decode(fixture("e8fdb8e6|6|1|2|2|3|0|2|0|00000000#", [1, 2, 3]).additionalData)!
        check(!assembler.accept(overlap, from: "two").accepted, "reject overlap / missing coverage")
        assembler.clear()
        _ = assembler.accept(a, from: "one")
        assembler.prune(now: Date().addingTimeInterval(601))
        check(assembler.accept(b, from: "one").data == nil, "expired partial discarded")
        assembler.clear()
        var acknowledged = 0
        _ = assembler.accept(a, from: "one") { acknowledged += 1 }
        assembler.prune(now: Date().addingTimeInterval(100))
        let delayed = assembler.accept(b, from: "one") { acknowledged += 1 }
        check(acknowledged == 2 && delayed.data != nil, "ACK callback and late chunks past soft timeout")
        _ = assembler.accept(b, from: "one") { acknowledged += 1 }
        check(acknowledged == 3, "completed retries ACKed without redelivery")

        let mixed = "前文/~#>e8fdb8e6<B~中间/~#>c5df6ae0<B~后文"
        check(FeiQInlineImageCodec.imageIDs(in: mixed) == ["e8fdb8e6", "c5df6ae0"], "marker order")
        check(FeiQInlineImageCodec.replacingMarkers(in: mixed, with: "") == "前文中间后文", "retain surrounding text")
        check(FeiQInlineImageCodec.imageIDs(in: "/~#>not-an-image<B~").isEmpty, "do not eat ordinary text")
        let ack = FeiQPacket(packetNumber: 124, senderName: "Mac", senderHost: "Mac", command: .inlineImageAcknowledgement, additionalText: "e8fdb8e6|2#")
        check(String(data: ack.encoded(), encoding: .utf8) == "1:124:Mac:Mac:193:e8fdb8e6|2#\0", "exact ACK command / body")
        check(FeiQInlineImageCodec.acknowledgement(FeiQPacket.parse(ack.encoded())!.additionalText)?.index == 2, "parse ACK")

        check(FeiQMessageFormatter.displayText("/:)") == "🙂", "decode FeiQ smile emoticon")
        check(FeiQMessageFormatter.displayText("你好 /:love") == "你好 ❤️", "decode named FeiQ emoticon")
        check(FeiQMessageFormatter.wireText("🙂") == "/:)", "encode FeiQ smile emoticon")
        check(FeiQMessageFormatter.wireText("❤️") == "/:love", "encode named FeiQ emoticon")

        let emoticons = FeiQMessageFormatter.compatibleEmoticons
        check(emoticons.count == 96, "complete published FeiQ catalog")
        check(Set(emoticons.map(\.code)).count == 96, "unique wire codes")
        for item in emoticons {
            check(FeiQMessageFormatter.displayText(item.code) == item.emoji, "decode \(item.code)")
            check(FeiQMessageFormatter.wireText(item.emoji) == item.code, "encode \(item.code)")
        }
        let allCodes = emoticons.map(\.code).joined()
        let allEmoji = emoticons.map(\.emoji).joined()
        check(FeiQMessageFormatter.displayText(allCodes) == allEmoji, "adjacent codes / overlapping prefixes")
        check(FeiQMessageFormatter.wireText(allEmoji) == allCodes, "adjacent emoji")
        check(FeiQMessageFormatter.displayText("你好/:D{/font;-16 微软雅黑 8404992;}\n/:strong/:love") == "你好😁\n👍❤️", "mixed text, font metadata and emoji")
        check(FeiQMessageFormatter.displayText("/:fd /:o") == "😶 😮", "legacy aliases")
        check(FeiQMessageFormatter.displayText("https://example.com /:unknown") == "https://example.com /:unknown", "ordinary and unknown text preserved")
        check(FeiQMessageFormatter.wireText("❤ ❤️ ✌ ☀ 👍🏽") == "/:love /:love /:shl /:sun /:strong", "presentation and skin-tone variants")
        check(FeiQMessageFormatter.wireText("👨‍👩‍👧‍👦 ❤️‍🔥") == "👨‍👩‍👧‍👦 ❤️‍🔥", "unsupported compound emoji remain intact")
        let emojiPacket = FeiQPacket(packetNumber: 128, senderName: "Mac", senderHost: "Mac", command: .sendMessage, additionalText: FeiQMessageFormatter.wireText("真的吗？😁👍❤️"))
        check(FeiQPacket.parse(emojiPacket.encoded())?.additionalText == "真的吗？/:D/:strong/:love", "legacy encoded Chinese and emoticons")

        let shake = FeiQPacket(packetNumber: 129, senderName: "Mac", senderHost: "Mac", command: .shake)
        let shakeAck = FeiQPacket(packetNumber: 130, senderName: "Mac", senderHost: "Mac", command: .shakeAcknowledgement)
        check(shake.encoded() == Data("1:129:Mac:Mac:209:\0".utf8), "exact shake request with single NUL")
        check(shakeAck.encoded() == Data("1:130:Mac:Mac:210:\0".utf8), "exact shake ACK with single NUL")
        let winShake = FeiQPacket.parse(Data("1_lbt6_0#128#DEVICE#0#0#0#4001#9:131:Win:PC:209:\0".utf8))!
        check(winShake.commandType == .shake && !winShake.isFeiQPresencePacket, "Windows shake is not presence")
        check(FeiQPacket.parse(shakeAck.encoded())?.commandType == .shakeAcknowledgement, "ACK is not another shake")
        check(FeiQCommand.from(rawValue: 0x002000D1) == .shake, "shake with upper command flags")
        check(FeiQCommand.from(rawValue: 0x000000B0) == .remoteAssistanceRequest, "remote assistance command")
        let remoteRequest = FeiQPacket(
            packetNumber: 131, senderName: "Administrator", senderHost: "PC-20250824UZVY",
            command: .remoteAssistanceRequest
        )
        check(
            FeiQPacket.parse(remoteRequest.encoded())?.commandType == .remoteAssistanceRequest,
            "parse remote assistance request"
        )

        let typing = FeiQPacket.parse(Data("1_lbt6_0#128#DEVICE#0#0#0#4001#9:126:Win:PC:121:\0".utf8))!
        let typingEnded = FeiQPacket.parse(Data("1_lbt6_0#128#DEVICE#0#0#0#4001#9:127:Win:PC:122:\0".utf8))!
        check(typing.commandType == .inputting, "parse FeiQ inputting command")
        check(typingEnded.commandType == .inputEnd, "parse FeiQ input-end command")
        check(!typing.isFeiQPresencePacket, "typing packet is not presence")

        let bytes = Data((0..<1030).map { UInt8(truncatingIfNeeded: $0) })
        let sent = FeiQInlineImageCodec.decode(FeiQInlineImageCodec.encode(imageID: "1234abcd", data: bytes, index: 3))!
        check(sent.offset == 1024 && sent.index == 3 && sent.data == bytes.suffix(6), "last outbound slice")
        let session = FeiQInlineImageSendSession(imageID: "1234abcd", ipAddress: "one", data: bytes)
        let now = Date()
        check(session.nextChunks(now: now) == [1, 2, 3], "send initial window")
        session.acknowledge(1); session.acknowledge(3)
        check(session.nextChunks(now: now.addingTimeInterval(2)) == [2], "retry missing chunk only")
        session.acknowledge(2)
        check(session.isComplete, "finish only after all ACKs")
        let failure = FeiQInlineImageSendSession(imageID: "1234abcd", ipAddress: "one", data: bytes)
        for n in 0...8 { _ = failure.nextChunks(now: now.addingTimeInterval(Double(n * 2))) }
        check(failure.failed, "bounded retries")

        let files = FeiQAttachmentCodec.decode(from: Data("\0".utf8) + Data("10:photo.jpg:100:12345678:1:\u{7}".utf8), preferUTF8: false)
        check(files.first?.fileSize == 256 && files.first?.fileID == "10", "hex size, decimal file ID")
        let colonFile = FeiQFileAttachment(
            fileID: "11",
            fileName: "报告:最终版.pdf",
            fileSize: 12,
            modifiedAt: 1,
            fileAttributes: 1
        )
        let colonRoundTrip = FeiQAttachmentCodec.decode(
            from: FeiQAttachmentCodec.encode(
                message: "附件",
                attachments: [colonFile],
                preferUTF8: false
            ),
            preferUTF8: false
        )
        check(colonRoundTrip.first?.fileName == colonFile.fileName, "escaped colon in file name")
        let markerPacket = FeiQPacket.parse(Data("1:125:Win:PC:288:/~#>e8fdb8e6<B~\0".utf8))!
        check(markerPacket.additionalText == "/~#>e8fdb8e6<B~", "text packet still strips terminator")

        // Minimal 1x1, 24-bit uncompressed Windows DIB (red pixel + padding).
        let dib = Data([
            40,0,0,0, 1,0,0,0, 1,0,0,0, 1,0,24,0,
            0,0,0,0, 4,0,0,0, 0,0,0,0, 0,0,0,0,
            0,0,0,0, 0,0,0,0, 0,0,255,0
        ])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feiq-image-check-" + UUID().uuidString)
        let storage = LocalChatAttachmentStorageService(rootURL: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap: ChatAttachment
        do { bitmap = try storage.saveInlineImage(dib, imageID: "e8fdb8e6", isBitmap: true) }
        catch { print("DIB storage failed: \(error)"); return }
        let jpeg = try Data(contentsOf: bitmap.localURL)
        let misflaggedJPEG = try storage.saveInlineImage(jpeg, imageID: "aabbccdd", isBitmap: true)
        check(misflaggedJPEG.isAvailable, "JPEG with bitmap flag still decodes")
        let unflaggedDIB = try storage.saveInlineImage(dib, imageID: "aabbccee", isBitmap: false)
        check(unflaggedDIB.isAvailable, "raw DIB detected without bitmap flag")
        check(jpeg.starts(with: [0xff, 0xd8]), "DIB normalized to JPEG")
        let source = CGImageSourceCreateWithData(jpeg as CFData, nil)!
        let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        check(decoded.width == 1 && decoded.height == 1, "DIB dimensions")
        let imported: ChatAttachment
        do { imported = try storage.prepareOutgoingImage(from: jpeg, suggestedFileName: "clipboard.png") }
        catch { print("JPEG import failed: \(error)"); return }
        check(imported.mimeType == "image/jpeg" && imported.isAvailable, "outgoing image persists")
        let incoming = try storage.saveInlineImage(jpeg, imageID: "c5df6ae0", isBitmap: false)
        check(incoming.isAvailable, "incoming JPEG persists")
        check((try? storage.saveInlineImage(Data([0, 1, 2]), imageID: "badimage", isBitmap: false)) == nil, "invalid image rejected")
        print("Inline image protocol checks passed")
    }
}
