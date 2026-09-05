import CoreFoundation
import Foundation

enum GBKCodec {
    private static let gb18030Encoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
    )

    static func encode(_ string: String, preferUTF8: Bool = false) -> Data {
        if preferUTF8 {
            return Data(string.utf8)
        }
        if let data = string.data(using: gb18030Encoding) {
            return data
        }
        return Data(string.utf8)
    }

    /// Removes characters that commonly force a legacy FeiQ packet into an
    /// incompatible encoding. Chinese characters remain unchanged; old
    /// Windows FeiQ clients receive a question mark for unsupported emoji.
    static func legacyCompatibleString(_ string: String) -> String {
        string.unicodeScalars.map { scalar in
            if scalar.value > 0xFFFF
                || isEmojiScalar(scalar.value)
                || scalar.value == 0xFE0E
                || scalar.value == 0xFE0F {
                return "?"
            }
            return String(scalar)
        }.joined()
    }

    static func encodeForLegacyFeiQ(_ string: String) -> Data {
        encode(legacyCompatibleString(string))
    }

    static func decode(_ data: Data, preferUTF8: Bool = false) -> String {
        guard !data.isEmpty else { return "" }

        if preferUTF8, let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }

        // Some FeiQ builds send Unicode emoji without setting the UTF-8
        // option bit. If the payload is valid UTF-8 and contains an emoji,
        // prefer it before trying GB18030; ordinary GBK traffic keeps its
        // existing decoding behavior.
        if let utf8 = String(data: data, encoding: .utf8),
           containsEmoji(utf8) {
            return utf8
        }

        if let gb18030 = String(data: data, encoding: gb18030Encoding) {
            return gb18030
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Emoji and supplementary-plane characters cannot be represented
    /// reliably by GBK-era FeiQ clients. Message packets containing either
    /// kind of scalar should use UTF-8 on the wire.
    static func requiresUTF8(_ string: String) -> Bool {
        string.unicodeScalars.contains { scalar in
            scalar.value > 0xFFFF || isEmojiScalar(scalar.value)
        }
    }

    static func containsEmoji(_ string: String) -> Bool {
        string.unicodeScalars.contains { isEmojiScalar($0.value) }
    }

    private static func isEmojiScalar(_ value: UInt32) -> Bool {
        switch value {
        case 0x1F000...0x1FAFF,
             0x2300...0x23FF,
             0x2600...0x27BF,
             0x2B00...0x2BFF,
             0x00A9, 0x00AE, 0x203C, 0x2049, 0x2122, 0x2139,
             0x3030, 0x303D, 0x3297, 0x3299:
            return true
        default:
            return false
        }
    }
}
