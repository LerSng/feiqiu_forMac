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
        default: return nil
        }
    }
}

enum FeiQMessageFormatter {
    private static let fontDirectiveRegex = try? NSRegularExpression(
        pattern: #"\{[/\\]?font;[^{}]*\}"#,
        options: [.caseInsensitive]
    )

    // FeiQ 2013 does not use Unicode emoji for the expressions in its
    // message editor. It writes these names as plain ASCII tokens and the
    // Windows client replaces them with its bundled emoticon images.
    // Keep this list limited to codes confirmed from FeiQ packets so that
    // ordinary Unicode emoji are not converted to an incorrect wire value.
    private static let feiQEmojiByCode: [String: String] = [
        "/:fd": "😶",
        "/:cajole": "🥺",
        "/:o": "😮"
    ]

    private static let feiQCodeByEmoji: [String: String] = [
        "😶": "/:fd",
        "🥺": "/:cajole",
        "😮": "/:o"
    ]

    /// Expressions that are known to render as bundled FeiQ emoticons in
    /// FeiQ 2013 for Windows. The picker uses this list to make compatibility
    /// visible to the user.
    static let feiQCompatibleEmojis = ["😶", "🥺", "😮"]

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
        // FeiQ tokens afterwards.
        for (code, emoji) in feiQEmojiByCode {
            result = result.replacingOccurrences(of: code, with: emoji)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Converts the Mac-facing Unicode expressions into the ASCII tokens
    /// understood by FeiQ 2013 Windows before a packet is encoded.
    static func wireText(_ text: String) -> String {
        guard !text.isEmpty else { return "" }

        var result = text
        for (emoji, code) in feiQCodeByEmoji {
            result = result.replacingOccurrences(of: emoji, with: code)
        }
        return result
    }
}

struct FeiQPacket: Sendable {
    static let version = 1

    // Common option bit used by IP Messenger-compatible implementations.
    // It is kept here so the decoder can prefer UTF-8 when a peer advertises it.
    static let utf8Option: UInt32 = 0x00800000
    static let sendCheckOption: UInt32 = 0x00000100

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

    /// A few FeiQ 2013 builds use a private presence command (0x79 / 121)
    /// instead of the regular IPMSG entry command. The version marker and an
    /// empty payload make this distinguishable from a text message.
    var isFeiQPresencePacket: Bool {
        switch baseCommand {
        case FeiQCommand.broadcastEntry.rawValue,
             FeiQCommand.answerEntry.rawValue,
             0x00000009,
             0x00000079:
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
        case FeiQCommand.broadcastEntry.rawValue, 0x00000009, 0x00000079:
            return isFeiQFormat || baseCommand == 0x00000009 || baseCommand == 0x00000079
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
        var payload = additionalData
        if let nullIndex = payload.firstIndex(of: 0) {
            payload = Data(payload.prefix(upTo: nullIndex))
        }
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
        if result.last != 0 {
            result.append(0)
        }
        return result
    }

    static func parse(_ input: Data) -> FeiQPacket? {
        var bytes = Array(input)
        while bytes.last == 0 || bytes.last == 10 || bytes.last == 13 {
            bytes.removeLast()
        }

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
