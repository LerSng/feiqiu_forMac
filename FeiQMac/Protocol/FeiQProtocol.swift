import Foundation

enum FeiQCommand: UInt32, Sendable {
    case broadcastEntry = 0x00000001
    case broadcastExit = 0x00000002
    case answerEntry = 0x00000003
    case broadcastAbsence = 0x00000004
    case broadcastNotify = 0x00000008
    case broadcastIsGetList = 0x00000010
    case okGetList = 0x00000011
    case getList = 0x00000012
    case answerList = 0x00000013
    case getInfo = 0x00000040
    case sendMessage = 0x00000020
    case receiveMessage = 0x00000021
    case readMessage = 0x00000030
    case deleteMessage = 0x00000031
    case answerReadMessage = 0x00000032
    case sendInfo = 0x00000041
    case getFileData = 0x00000060
    case releaseFiles = 0x00000061
    case getDirectoryFiles = 0x00000062
    /// FeiQ private typing notification commands used by FeiQ 2013.
    case inputting = 0x00000079
    case inputEnd = 0x0000007A
    /// FeiQ 2013 private remote-assistance request observed in the wild.
    /// The follow-up control/video channel is not part of public IPMsg.
    case remoteAssistanceRequest = 0x000000B0
    case shake = 0x000000D1
    case shakeAcknowledgement = 0x000000D2
    /// Some FeiQ 2013 builds use the private 0x77/0x78 pair for inline
    /// image chunks and their acknowledgements instead of 0xC0/0xC1.
    case legacyInlineImage = 0x00000077
    case legacyInlineImageAcknowledgement = 0x00000078
    case inlineImage = 0x000000C0
    case inlineImageAcknowledgement = 0x000000C1

    static func from(rawValue: UInt32) -> FeiQCommand? {
        // The high bits are option flags in the IP Messenger/FeiQ family.
        // Matching the low byte lets us handle packets carrying those flags.
        let baseValue = rawValue & 0x000000FF
        switch baseValue {
        case broadcastEntry.rawValue: return .broadcastEntry
        case broadcastExit.rawValue: return .broadcastExit
        case answerEntry.rawValue: return .answerEntry
        case broadcastAbsence.rawValue: return .broadcastAbsence
        case broadcastNotify.rawValue: return .broadcastNotify
        case broadcastIsGetList.rawValue: return .broadcastIsGetList
        case okGetList.rawValue: return .okGetList
        case getList.rawValue: return .getList
        case answerList.rawValue: return .answerList
        case getInfo.rawValue: return .getInfo
        case sendMessage.rawValue: return .sendMessage
        case receiveMessage.rawValue: return .receiveMessage
        case readMessage.rawValue: return .readMessage
        case deleteMessage.rawValue: return .deleteMessage
        case answerReadMessage.rawValue: return .answerReadMessage
        case sendInfo.rawValue: return .sendInfo
        case getFileData.rawValue: return .getFileData
        case releaseFiles.rawValue: return .releaseFiles
        case getDirectoryFiles.rawValue: return .getDirectoryFiles
        case inputting.rawValue: return .inputting
        case inputEnd.rawValue: return .inputEnd
        case remoteAssistanceRequest.rawValue: return .remoteAssistanceRequest
        case shake.rawValue: return .shake
        case shakeAcknowledgement.rawValue: return .shakeAcknowledgement
        case legacyInlineImage.rawValue: return .legacyInlineImage
        case legacyInlineImageAcknowledgement.rawValue: return .legacyInlineImageAcknowledgement
        case inlineImage.rawValue: return .inlineImage
        case inlineImageAcknowledgement.rawValue: return .inlineImageAcknowledgement
        default: return nil
        }
    }

    var isInlineImageChunk: Bool {
        self == .inlineImage || self == .legacyInlineImage
    }

    var isInlineImageAcknowledgement: Bool {
        self == .inlineImageAcknowledgement || self == .legacyInlineImageAcknowledgement
    }
}

enum FeiQMessageFormatter {
    struct CompatibleEmoticon: Hashable, Sendable {
        let code: String
        let emoji: String
        let title: String
    }

    private static let fontDirectiveRegex = try? NSRegularExpression(
        pattern: #"\{[/\\]?font;[^{}]*\}"#,
        options: [.caseInsensitive]
    )

    // Wire codes: zyqg/feiq-android FeiqEmoticons.kt (8314e26), referenced
    // by feiqiu-README.md. Emoji are macOS approximations of Windows GIFs.
    static let compatibleEmoticons: [CompatibleEmoticon] = [
        CompatibleEmoticon(code: "/:)", emoji: "🙂", title: "微笑"),
        CompatibleEmoticon(code: "/:~", emoji: "😖", title: "撇嘴"),
        CompatibleEmoticon(code: "/:*", emoji: "😍", title: "色"),
        CompatibleEmoticon(code: "/:|", emoji: "😶", title: "发呆"),
        CompatibleEmoticon(code: "/8-)", emoji: "😎", title: "得意"),
        CompatibleEmoticon(code: "/:<", emoji: "🥲", title: "流泪"),
        CompatibleEmoticon(code: "/:$", emoji: "😊", title: "害羞"),
        CompatibleEmoticon(code: "/:X", emoji: "🤐", title: "闭嘴"),
        CompatibleEmoticon(code: "/:Z", emoji: "😴", title: "睡"),
        CompatibleEmoticon(code: "/:'(", emoji: "😭", title: "大哭"),
        CompatibleEmoticon(code: "/:-|", emoji: "😅", title: "尴尬"),
        CompatibleEmoticon(code: "/:@", emoji: "😡", title: "发怒"),
        CompatibleEmoticon(code: "/:P", emoji: "😛", title: "调皮"),
        CompatibleEmoticon(code: "/:D", emoji: "😁", title: "呲牙"),
        CompatibleEmoticon(code: "/:O", emoji: "😮", title: "惊讶"),
        CompatibleEmoticon(code: "/<rotate>", emoji: "🔄", title: "旋转"),
        CompatibleEmoticon(code: "/:(", emoji: "😞", title: "难过"),
        CompatibleEmoticon(code: "/:+", emoji: "😏", title: "酷"),
        CompatibleEmoticon(code: "/:lenhan", emoji: "😰", title: "冷汗"),
        CompatibleEmoticon(code: "/:Q", emoji: "😱", title: "抓狂"),
        CompatibleEmoticon(code: "/:T", emoji: "🤮", title: "吐"),
        CompatibleEmoticon(code: "/;P", emoji: "🤭", title: "偷笑"),
        CompatibleEmoticon(code: "/;-D", emoji: "😌", title: "可爱"),
        CompatibleEmoticon(code: "/;d", emoji: "🙄", title: "白眼"),
        CompatibleEmoticon(code: "/;o", emoji: "😤", title: "傲慢"),
        CompatibleEmoticon(code: "/:g", emoji: "😋", title: "饥饿"),
        CompatibleEmoticon(code: "/|-)", emoji: "😪", title: "困"),
        CompatibleEmoticon(code: "/:!", emoji: "😨", title: "惊恐"),
        CompatibleEmoticon(code: "/:L", emoji: "😓", title: "流汗"),
        CompatibleEmoticon(code: "/:>", emoji: "😆", title: "憨笑"),
        CompatibleEmoticon(code: "/;bin", emoji: "🪖", title: "大兵"),
        CompatibleEmoticon(code: "/:fw", emoji: "💪", title: "奋斗"),
        CompatibleEmoticon(code: "/;fd", emoji: "🤬", title: "咒骂"),
        CompatibleEmoticon(code: "/:-S", emoji: "🤔", title: "疑问"),
        CompatibleEmoticon(code: "/;?", emoji: "🤫", title: "嘘"),
        CompatibleEmoticon(code: "/;x", emoji: "😵", title: "晕"),
        CompatibleEmoticon(code: "/;@", emoji: "😩", title: "折磨"),
        CompatibleEmoticon(code: "/:8", emoji: "😈", title: "衰"),
        CompatibleEmoticon(code: "/;!", emoji: "💀", title: "骷髅"),
        CompatibleEmoticon(code: "/!!!", emoji: "🔨", title: "敲打"),
        CompatibleEmoticon(code: "/:xx", emoji: "👋", title: "再见"),
        CompatibleEmoticon(code: "/:bye", emoji: "🙋", title: "告别"),
        CompatibleEmoticon(code: "/:csweat", emoji: "🥵", title: "擦汗"),
        CompatibleEmoticon(code: "/:knose", emoji: "👃", title: "挖鼻"),
        CompatibleEmoticon(code: "/:applause", emoji: "👏", title: "鼓掌"),
        CompatibleEmoticon(code: "/:cdale", emoji: "😳", title: "糗大了"),
        CompatibleEmoticon(code: "/:huaixiao", emoji: "😼", title: "坏笑"),
        CompatibleEmoticon(code: "/:shake", emoji: "🤷", title: "摇头"),
        CompatibleEmoticon(code: "/:lhenhen", emoji: "😒", title: "左哼哼"),
        CompatibleEmoticon(code: "/:rhenhen", emoji: "😾", title: "右哼哼"),
        CompatibleEmoticon(code: "/:yawn", emoji: "🥱", title: "哈欠"),
        CompatibleEmoticon(code: "/:snooty", emoji: "😑", title: "鄙视"),
        CompatibleEmoticon(code: "/:chagrin", emoji: "😣", title: "委屈"),
        CompatibleEmoticon(code: "/:kcry", emoji: "😢", title: "快哭了"),
        CompatibleEmoticon(code: "/:yinxian", emoji: "🦊", title: "阴险"),
        CompatibleEmoticon(code: "/:qinqin", emoji: "😘", title: "亲亲"),
        CompatibleEmoticon(code: "/:xiaren", emoji: "😬", title: "吓人"),
        CompatibleEmoticon(code: "/:kelin", emoji: "🥹", title: "可怜"),
        CompatibleEmoticon(code: "/:caidao", emoji: "🔪", title: "菜刀"),
        CompatibleEmoticon(code: "/:xig", emoji: "🍉", title: "西瓜"),
        CompatibleEmoticon(code: "/:bj", emoji: "🍺", title: "啤酒"),
        CompatibleEmoticon(code: "/:basketball", emoji: "🏀", title: "篮球"),
        CompatibleEmoticon(code: "/:pingpong", emoji: "🏓", title: "乒乓"),
        CompatibleEmoticon(code: "/:jump", emoji: "🕺", title: "跳跳"),
        CompatibleEmoticon(code: "/:coffee", emoji: "☕", title: "咖啡"),
        CompatibleEmoticon(code: "/:eat", emoji: "🍚", title: "饭"),
        CompatibleEmoticon(code: "/:pig", emoji: "🐷", title: "猪头"),
        CompatibleEmoticon(code: "/:rose", emoji: "🌹", title: "玫瑰"),
        CompatibleEmoticon(code: "/:fade", emoji: "🥀", title: "凋谢"),
        CompatibleEmoticon(code: "/:kiss", emoji: "💋", title: "示爱"),
        CompatibleEmoticon(code: "/:heart", emoji: "💗", title: "爱心"),
        CompatibleEmoticon(code: "/:break", emoji: "💔", title: "心碎"),
        CompatibleEmoticon(code: "/:cake", emoji: "🎂", title: "蛋糕"),
        CompatibleEmoticon(code: "/:shd", emoji: "⚡", title: "闪电"),
        CompatibleEmoticon(code: "/:bomb", emoji: "💣", title: "炸弹"),
        CompatibleEmoticon(code: "/:dao", emoji: "🗡️", title: "刀"),
        CompatibleEmoticon(code: "/:footb", emoji: "⚽", title: "足球"),
        CompatibleEmoticon(code: "/:piaocon", emoji: "🐞", title: "瓢虫"),
        CompatibleEmoticon(code: "/:shit", emoji: "💩", title: "便便"),
        CompatibleEmoticon(code: "/:oh", emoji: "🆗", title: "哦"),
        CompatibleEmoticon(code: "/:moon", emoji: "🌙", title: "月亮"),
        CompatibleEmoticon(code: "/:sun", emoji: "☀️", title: "太阳"),
        CompatibleEmoticon(code: "/;gift", emoji: "🎁", title: "礼物"),
        CompatibleEmoticon(code: "/:hug", emoji: "🤗", title: "拥抱"),
        CompatibleEmoticon(code: "/:strong", emoji: "👍", title: "强"),
        CompatibleEmoticon(code: "/;weak", emoji: "👎", title: "弱"),
        CompatibleEmoticon(code: "/:share", emoji: "🤝", title: "握手"),
        CompatibleEmoticon(code: "/:shl", emoji: "✌️", title: "胜利"),
        CompatibleEmoticon(code: "/:baoquan", emoji: "✊", title: "抱拳"),
        CompatibleEmoticon(code: "/:cajole", emoji: "🥺", title: "撒娇"),
        CompatibleEmoticon(code: "/:quantou", emoji: "👊", title: "拳头"),
        CompatibleEmoticon(code: "/:chajin", emoji: "🤙", title: "差劲"),
        CompatibleEmoticon(code: "/:aini", emoji: "🤟", title: "爱你"),
        CompatibleEmoticon(code: "/:sayno", emoji: "🙅", title: "不"),
        CompatibleEmoticon(code: "/:sayok", emoji: "👌", title: "好的"),
        CompatibleEmoticon(code: "/:love", emoji: "❤️", title: "爱情"),
    ]

    private static let feiQEmojiByCode: [String: String] = {
        var result = Dictionary(uniqueKeysWithValues: compatibleEmoticons.map { ($0.code, $0.emoji) })
        result["/:fd"] = "😶"
        result["/:o"] = "😮"
        return result
    }()

    private static let feiQCodeByEmoji = Dictionary(
        uniqueKeysWithValues: compatibleEmoticons.map { (normalizedEmoji($0.emoji), $0.code) }
    )

    private static let orderedCodes = feiQEmojiByCode.sorted { $0.key.count > $1.key.count }

    private static func normalizedEmoji(_ emoji: String) -> String {
        // Text/emoji presentation selectors and skin tones do not have
        // separate FeiQ GIFs. Keep ZWJ sequences intact to avoid partial codes.
        String(String.UnicodeScalarView(emoji.unicodeScalars.filter {
            $0.value != 0xFE0E && $0.value != 0xFE0F
                && !(0x1F3FB...0x1F3FF).contains($0.value)
        }))
    }

    static let feiQCompatibleEmojis = compatibleEmoticons.map(\.emoji)

    /// Removes FeiQ inline font metadata while preserving the actual text
    /// and line breaks. For example, a suffix such as
    /// `{/font;-16 ... 微软雅黑 8404992;}` is formatting, not user content.
    static func displayText(_ text: String) -> String {
        guard !text.isEmpty else { return "" }

        var result = text
        if let fontDirectiveRegex {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = fontDirectiveRegex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: ""
            )
        }

        // The Windows client may append a font directive after every
        // emoticon, so remove formatting first and decode the remaining
        // FeiQ tokens afterwards. Longest codes are replaced first so a
        // future named code cannot be partially consumed by an alias.
        for (code, emoji) in orderedCodes {
            result = result.replacingOccurrences(of: code, with: emoji)
        }

        result = FeiQInlineImageCodec.replacingMarkers(in: result, with: "[图片]")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Converts the Mac-facing Unicode expressions into the ASCII tokens
    /// understood by FeiQ 2013 Windows before a packet is encoded.
    static func wireText(_ text: String) -> String {
        guard !text.isEmpty else { return "" }

        return text.map { character in
            let original = String(character)
            return feiQCodeByEmoji[normalizedEmoji(original)] ?? original
        }.joined()
    }
}

/// Defines the small amount of metadata needed to relay a group message
/// through a FeiQ 2013 client. FeiQ 2013 does not expose a native group-chat
/// packet, so group messages must remain ordinary FeiQ messages on the wire.
enum FeiQGroupRelayFormatter {
    struct ParsedMessage: Sendable {
        let groupName: String
        let senderName: String
        let text: String
    }

    private static let markerPrefix = "【飞秋群聊："

    static func makeText(
        groupName: String,
        senderName: String,
        text: String
    ) -> String {
        let normalizedGroupName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSenderName = senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayGroupName = normalizedGroupName.isEmpty ? "未命名群聊" : normalizedGroupName
        let displaySenderName = normalizedSenderName.isEmpty ? "未知发送人" : normalizedSenderName
        return "\(markerPrefix)\(displayGroupName)】\(displaySenderName)：\(text)"
    }

    static func parse(_ text: String) -> ParsedMessage? {
        guard text.hasPrefix(markerPrefix),
              let titleEnd = text.firstIndex(of: "】") else {
            return nil
        }

        let groupStart = text.index(
            text.startIndex,
            offsetBy: markerPrefix.count
        )
        let groupName = String(text[groupStart..<titleEnd])
        let contentStart = text.index(after: titleEnd)
        let content = String(text[contentStart...])
        let separator = content.firstIndex(of: "：") ?? content.firstIndex(of: ":")
        guard let separator else { return nil }

        let senderName = String(content[..<separator])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let messageStart = content.index(after: separator)
        let messageText = String(content[messageStart...])

        guard !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !senderName.isEmpty else {
            return nil
        }

        return ParsedMessage(
            groupName: groupName,
            senderName: senderName,
            text: messageText
        )
    }
}

/// Encodes and decodes the attachment section used by IP Messenger and FeiQ.
/// The message text is followed by NUL and one or more BEL-terminated records:
/// fileID:fileName:fileSize:modifiedAt:fileAttributes.
enum FeiQAttachmentCodec {
    private static let metadataSeparator: UInt8 = 0
    private static let recordSeparator: UInt8 = 7

    static func encode(
        message: String,
        attachments: [FeiQFileAttachment],
        preferUTF8: Bool
    ) -> Data {
        var result = GBKCodec.encode(message, preferUTF8: preferUTF8)
        guard !attachments.isEmpty else { return result }

        result.append(metadataSeparator)
        for attachment in attachments {
            let fields = [
                attachment.fileID,
                escapeFileName(attachment.fileName),
                String(attachment.fileSize, radix: 16),
                String(attachment.modifiedAt, radix: 16),
                String(attachment.fileAttributes, radix: 16)
            ]
            result.append(
                GBKCodec.encode(fields.joined(separator: ":"), preferUTF8: preferUTF8)
            )
            result.append(recordSeparator)
        }
        return result
    }

    static func messageData(
        from data: Data,
        hasAttachments: Bool
    ) -> Data {
        guard hasAttachments else {
            guard let separator = data.firstIndex(of: metadataSeparator) else {
                return data
            }
            return Data(data.prefix(upTo: separator))
        }
        return split(data).message
    }

    static func decode(
        from data: Data,
        preferUTF8: Bool
    ) -> [FeiQFileAttachment] {
        guard !data.isEmpty else { return [] }
        let metadata = split(data).metadata
        guard !metadata.isEmpty else { return [] }

        return metadata
            .split { byte in
                byte == recordSeparator || byte == metadataSeparator
            }
            .compactMap { record in
                parseRecord(Data(record), preferUTF8: preferUTF8)
            }
    }

    private static func split(_ data: Data) -> (message: Data, metadata: Data) {
        if let separator = data.firstIndex(of: metadataSeparator) {
            let metadataStart = data.index(after: separator)
            return (
                Data(data.prefix(upTo: separator)),
                Data(data.suffix(from: metadataStart))
            )
        }

        // A few older implementations use BEL as the text/metadata boundary
        // instead of NUL. Accept that form for receiving without changing the
        // canonical NUL + BEL representation used when sending.
        for separator in data.indices where data[separator] == recordSeparator {
            let metadataStart = data.index(after: separator)
            let candidate = Data(data.suffix(from: metadataStart))
            if parseRecords(candidate).contains(where: { parseRecord($0, preferUTF8: false) != nil }) {
                return (
                    Data(data.prefix(upTo: separator)),
                    candidate
                )
            }
        }

        if parseRecords(data).contains(where: { parseRecord($0, preferUTF8: false) != nil }) {
            return (Data(), data)
        }
        return (data, Data())
    }

    private static func parseRecords(_ data: Data) -> [Data] {
        data
            .split { byte in
                byte == recordSeparator || byte == metadataSeparator
            }
            .map { Data($0) }
    }

    private static func parseRecord(
        _ data: Data,
        preferUTF8: Bool
    ) -> FeiQFileAttachment? {
        let fields = splitFields(data)
            .map { GBKCodec.decode($0, preferUTF8: preferUTF8) }
        guard fields.count >= 5,
              !fields[0].isEmpty,
              !fields[1].isEmpty,
              let fileSize = Int64(fields[2], radix: 16),
              fileSize >= 0,
              let modifiedAt = Int64(fields[3], radix: 16),
              let fileAttributes = UInt32(fields[4], radix: 16) else {
            return nil
        }

        return FeiQFileAttachment(
            fileID: fields[0],
            fileName: fields[1],
            fileSize: fileSize,
            modifiedAt: modifiedAt,
            fileAttributes: fileAttributes
        )
    }

    private static func escapeFileName(_ fileName: String) -> String {
        fileName.replacingOccurrences(of: ":", with: "::")
    }

    /// Splits a metadata record while preserving the IPMsg `::` filename
    /// escape. `Data.split(separator:)` cannot distinguish an escaped colon
    /// from a field separator and corrupts names such as `报告:最终版.pdf`.
    private static func splitFields(_ data: Data) -> [Data] {
        var fields: [Data] = []
        var field = Data()
        var index = 0

        while index < data.count {
            let byte = data[index]
            if byte == 58 {
                if index + 1 < data.count, data[index + 1] == 58 {
                    field.append(58)
                    index += 2
                    continue
                }
                fields.append(field)
                field.removeAll(keepingCapacity: true)
            } else {
                field.append(byte)
            }
            index += 1
        }
        fields.append(field)
        return fields
    }

    private static func parseUInt32(_ value: String) -> UInt32? {
        if let decimal = UInt32(value) {
            return decimal
        }
        let hexadecimal = value.hasPrefix("0x") || value.hasPrefix("0X")
            ? String(value.dropFirst(2))
            : value
        return UInt32(hexadecimal, radix: 16)
    }
}

struct FeiQPacket: Sendable {
    static let version = 1

    // Common option bit used by IP Messenger-compatible implementations.
    // It is kept here so the decoder can prefer UTF-8 when a peer advertises it.
    static let utf8Option: UInt32 = 0x00800000
    static let sendCheckOption: UInt32 = 0x00000100
    static let fileAttachOption: UInt32 = 0x00200000

    let versionNumber: Int
    /// The first field is normally just "1", but FeiQ 2013 puts its
    /// implementation/device information in the same field, for example:
    /// 1_lbt6_0#128#F4B5203C203C2B02#0#0#0#4001#9
    let versionIdentifier: String
    /// Packet numbers are decimal strings on the wire. Older FeiQ builds
    /// commonly fit in 32 bits, while newer/modified clients may use a full
    /// millisecond timestamp, so the receiver must not truncate them.
    let packetNumber: UInt64
    let senderName: String
    let senderHost: String
    let command: UInt32
    let additionalData: Data

    var commandType: FeiQCommand? {
        FeiQCommand.from(rawValue: command)
    }

    /// Command options occupy the high bits in IPMSG/FeiQ packets. Keeping
    /// the base command available makes private FeiQ commands (9 and 121)
    /// easier to recognize without losing the original command value.
    var baseCommand: UInt32 {
        command & 0x000000FF
    }

    var prefersUTF8: Bool {
        (command & Self.utf8Option) != 0
    }

    var hasFileAttachments: Bool {
        (command & Self.fileAttachOption) != 0
    }

    var fileAttachments: [FeiQFileAttachment] {
        guard hasFileAttachments else { return [] }
        return FeiQAttachmentCodec.decode(
            from: additionalData,
            preferUTF8: prefersUTF8
        )
    }

    /// The FeiQ implementation identifies itself by extending the version
    /// field with '#' separated values. This is not a different packet
    /// layout: the remaining fields are still the normal IPMSG fields.
    var isFeiQFormat: Bool {
        guard feiQVersionFields.count >= 3,
              let first = feiQVersionFields.first else {
            return false
        }
        return first.hasPrefix("1_lbt6_")
    }

    var feiQDeviceIdentifier: String? {
        guard isFeiQFormat else { return nil }
        return feiQVersionFields[2]
    }

    /// A few FeiQ 2013 builds use private presence commands instead of the
    /// regular IPMSG entry command. Typing notifications (0x79/0x7A) are
    /// deliberately excluded here: 0x79 is an input-state packet, not an
    /// online-presence packet.
    var isFeiQPresencePacket: Bool {
        switch baseCommand {
        case FeiQCommand.broadcastEntry.rawValue,
             FeiQCommand.answerEntry.rawValue,
             0x00000009:
            // Standard entry/answer packets are only classified here when
            // they carry FeiQ's extended version. The private 9/121 commands
            // are accepted even when a FeiQ build sends a plain "1" header.
            return isFeiQFormat || baseCommand == 0x00000009 || baseCommand == 0x00000079
        default:
            return false
        }
    }

    var isFeiQEntryRequest: Bool {
        switch baseCommand {
        case FeiQCommand.broadcastEntry.rawValue, 0x00000009:
            return isFeiQFormat || baseCommand == 0x00000009
        default:
            return false
        }
    }

    /// Entry packets may carry nickname and group as NUL-separated fields.
    /// FeiQ's common implementation often only carries the nickname.
    var additionalTextParts: [String] {
        guard !additionalData.isEmpty else { return [] }

        var payload = additionalData
        while let last = payload.last, last == 0 {
            payload.removeLast()
        }

        return payload
            .split(separator: 0, omittingEmptySubsequences: false)
            .map { GBKCodec.decode(Data($0), preferUTF8: prefersUTF8) }
    }

    var entryName: String? {
        additionalTextParts.first?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var entryGroup: String? {
        guard additionalTextParts.count > 1 else { return nil }
        return additionalTextParts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var additionalText: String {
        var payload = FeiQAttachmentCodec.messageData(
            from: additionalData,
            hasAttachments: hasFileAttachments
        )
        while let last = payload.last, last == 0 || last == 10 || last == 13 {
            payload.removeLast()
        }
        return GBKCodec.decode(payload, preferUTF8: prefersUTF8)
    }

    init(
        versionNumber: Int = FeiQPacket.version,
        versionIdentifier: String? = nil,
        packetNumber: UInt64,
        senderName: String,
        senderHost: String,
        command: UInt32,
        additionalData: Data
    ) {
        self.versionNumber = versionNumber
        self.versionIdentifier = versionIdentifier ?? String(versionNumber)
        self.packetNumber = packetNumber
        self.senderName = senderName
        self.senderHost = senderHost
        self.command = command
        self.additionalData = additionalData
    }

    init(
        packetNumber: UInt64,
        senderName: String,
        senderHost: String,
        command: FeiQCommand,
        additionalText: String = "",
        versionIdentifier: String = String(FeiQPacket.version)
    ) {
        // FeiQ 2013 Windows decodes control packets as GB18030 and may
        // ignore the optional IPMSG UTF-8 flag. Keep presence, replies,
        // receipts and exits in the legacy encoding as well.
        self.init(
            versionIdentifier: versionIdentifier,
            packetNumber: packetNumber,
            senderName: senderName,
            senderHost: senderHost,
            command: command.rawValue,
            additionalData: GBKCodec.encodeForLegacyFeiQ(additionalText)
        )
    }

    func encoded() -> Data {
        var result = Data()
        result.append(contentsOf: Array("\(versionIdentifier):\(packetNumber):".utf8))
        let wireSenderName = prefersUTF8
            ? senderName
            : GBKCodec.legacyCompatibleString(senderName)
        let wireSenderHost = prefersUTF8
            ? senderHost
            : GBKCodec.legacyCompatibleString(senderHost)
        result.append(GBKCodec.encode(wireSenderName, preferUTF8: prefersUTF8))
        result.append(58)
        result.append(GBKCodec.encode(wireSenderHost, preferUTF8: prefersUTF8))
        result.append(58)
        result.append(contentsOf: Array("\(command):".utf8))
        result.append(additionalData)
        // FeiQ/IP Messenger packets are NUL-terminated. TCP is a stream, so
        // this terminator is also used by the stream decoder as a frame mark.
        if commandType?.isInlineImageChunk != true && result.last != 0 {
            result.append(0)
        }
        return result
    }

    static func parse(_ input: Data) -> FeiQPacket? {
        let bytes = Array(input)
        // Keep the payload byte-exact: inline image chunks contain arbitrary
        // binary data, including trailing zero, CR and LF bytes.

        guard !bytes.isEmpty else { return nil }

        var separators: [Int] = []
        separators.reserveCapacity(5)
        for (index, byte) in bytes.enumerated() where byte == 58 {
            separators.append(index)
            if separators.count == 5 { break }
        }
        guard separators.count == 5 else { return nil }

        func field(start: Int, end: Int) -> Data {
            guard end >= start, start >= 0, end <= bytes.count else { return Data() }
            return Data(bytes[start..<end])
        }

        let versionData = field(start: 0, end: separators[0])
        let packetNumberData = field(start: separators[0] + 1, end: separators[1])
        let senderNameData = field(start: separators[1] + 1, end: separators[2])
        let senderHostData = field(start: separators[2] + 1, end: separators[3])
        let commandData = field(start: separators[3] + 1, end: separators[4])
        let additionalData = Data(bytes[(separators[4] + 1)..<bytes.count])

        let versionIdentifier = String(decoding: versionData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !versionIdentifier.isEmpty,
            let packetNumber = parseUInt64(packetNumberData),
            let command = parseUInt32(commandData)
        else {
            return nil
        }

        // Keep the numeric version for callers that only care about the
        // protocol version. FeiQ's extended version still starts with "1".
        let numericVersion = Int(String(versionIdentifier.split(separator: "_", maxSplits: 1).first ?? "")) ?? FeiQPacket.version

        let prefersUTF8 = (command & Self.utf8Option) != 0

        return FeiQPacket(
            versionNumber: numericVersion,
            versionIdentifier: versionIdentifier,
            packetNumber: packetNumber,
            senderName: GBKCodec.decode(senderNameData, preferUTF8: prefersUTF8),
            senderHost: GBKCodec.decode(senderHostData, preferUTF8: prefersUTF8),
            command: command,
            additionalData: additionalData
        )
    }

    private var feiQVersionFields: [String] {
        versionIdentifier
            .split(separator: "#", omittingEmptySubsequences: false)
            .map(String.init)
    }

    private static func parseUInt32(_ data: Data) -> UInt32? {
        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let decimal = UInt32(value) {
            return decimal
        }

        let hexadecimal = value.hasPrefix("0x") || value.hasPrefix("0X")
            ? String(value.dropFirst(2))
            : value
        return UInt32(hexadecimal, radix: 16)
    }

    private static func parseUInt64(_ data: Data) -> UInt64? {
        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let decimal = UInt64(value) {
            return decimal
        }

        let hexadecimal = value.hasPrefix("0x") || value.hasPrefix("0X")
            ? String(value.dropFirst(2))
            : value
        return UInt64(hexadecimal, radix: 16)
    }
}
