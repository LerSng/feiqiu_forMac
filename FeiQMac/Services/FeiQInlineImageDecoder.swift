import Foundation
import ImageIO
import zlib

enum FeiQInlineImageDecodingError: LocalizedError {
    case unsupportedFormat
    case invalidBitmap
    case invalidCompressedData
    case sizeLimit

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "无法识别图片格式，或图片数据不完整"
        case .invalidBitmap: return "Windows 位图头、调色板或像素数据无效"
        case .invalidCompressedData: return "压缩图片数据不完整或校验失败"
        case .sizeLimit: return "图片数据或解压后的尺寸超过安全限制"
        }
    }
}

enum FeiQInlineImageDecoder {
    static let maximumInflatedBytes = 64 * 1024 * 1024
    private static let maximumPixelCount = 64 * 1024 * 1024

    static func decode(_ data: Data) throws -> CGImage {
        guard !data.isEmpty, data.count <= FeiQInlineImageCodec.maximumBytes else {
            throw FeiQInlineImageDecodingError.sizeLimit
        }
        let unpacked = try unpack(data)
        let hasBitmapHeader = unpacked.starts(with: [0x42, 0x4d])
            || (unpacked.count >= 4 && [12, 40, 52, 56, 108, 124].contains(Int(uint32(unpacked, at: 0))))
        let container = hasBitmapHeader ? try bitmapContainer(unpacked) : unpacked
        guard let image = try containerImage(container) else {
            throw FeiQInlineImageDecodingError.unsupportedFormat
        }
        return image
    }

    static func diagnosticSummary(_ data: Data) -> String {
        let signature = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        var details = "\(data.count) bytes，文件头=\(signature)"
        let offset = data.starts(with: [0x42, 0x4d]) ? 14 : 0
        if data.count >= offset + 40, [40, 52, 56, 108, 124].contains(Int(uint32(data, at: offset))) {
            details += "，DIB=\(uint32(data, at: offset))，位深=\(uint16(data, at: offset + 14))，压缩=\(uint32(data, at: offset + 16))"
        }
        return details
    }

    private static func containerImage(_ data: Data) throws -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        try validateDimensions(width: width.intValue, height: height.intValue)
        guard CGImageSourceGetStatus(source) == .statusComplete else {
            throw FeiQInlineImageDecodingError.unsupportedFormat
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
    }

    private static func validateDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 32_768, height <= 32_768,
              width <= maximumPixelCount / height else {
            throw FeiQInlineImageDecodingError.sizeLimit
        }
    }

    private static func unpack(_ data: Data) throws -> Data {
        let offset: Int
        var expectedSizes: [Int] = []
        if hasCompressionHeader(data, at: 0) {
            offset = 0
        } else if data.count >= 6, hasCompressionHeader(data, at: 4) {
            offset = 4
            let length = uint32(data, at: 0)
            expectedSizes = [Int(length), Int(length.byteSwapped)].filter { $0 > 0 && $0 <= maximumInflatedBytes }
            guard !expectedSizes.isEmpty else { throw FeiQInlineImageDecodingError.sizeLimit }
        } else {
            return data
        }
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw FeiQInlineImageDecodingError.invalidCompressedData
        }
        defer { inflateEnd(&stream) }
        var output = Data()
        try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress!.advanced(by: offset))
            stream.avail_in = uInt(data.count - offset)
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let availableInput = stream.avail_in
                let status = buffer.withUnsafeMutableBufferPointer { destination in
                    stream.next_out = destination.baseAddress
                    stream.avail_out = uInt(destination.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = buffer.count - Int(stream.avail_out)
                guard produced <= maximumInflatedBytes - output.count else {
                    throw FeiQInlineImageDecodingError.sizeLimit
                }
                output.append(contentsOf: buffer.prefix(produced))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0, !output.isEmpty else {
                        throw FeiQInlineImageDecodingError.invalidCompressedData
                    }
                    break
                }
                guard status == Z_OK, produced > 0 || stream.avail_in < availableInput else {
                    throw FeiQInlineImageDecodingError.invalidCompressedData
                }
            }
        }
        guard expectedSizes.isEmpty || expectedSizes.contains(output.count) else {
            throw FeiQInlineImageDecodingError.invalidCompressedData
        }
        return output
    }

    private static func hasCompressionHeader(_ data: Data, at offset: Int) -> Bool {
        guard data.count >= offset + 2 else { return false }
        let first = Int(data[data.startIndex + offset])
        let second = Int(data[data.startIndex + offset + 1])
        return (first == 0x1f && second == 0x8b)
            || (first & 0x0f == 8 && first >> 4 <= 7 && (first * 256 + second).isMultiple(of: 31))
    }

    private static func bitmapContainer(_ input: Data) throws -> Data {
        var data = input
        var filePixelOffset: Int?
        if data.starts(with: [0x42, 0x4d]) {
            guard data.count >= 26, uint32(data, at: 10) >= 14 else {
                throw FeiQInlineImageDecodingError.invalidBitmap
            }
            filePixelOffset = Int(uint32(data, at: 10)) - 14
            data = Data(data.dropFirst(14))
        }
        guard data.count >= 12 else { throw FeiQInlineImageDecodingError.unsupportedFormat }
        let headerSize = Int(uint32(data, at: 0))
        guard [12, 40, 52, 56, 108, 124].contains(headerSize), data.count >= headerSize else {
            throw FeiQInlineImageDecodingError.unsupportedFormat
        }
        let isCore = headerSize == 12
        let width = isCore ? Int(uint16(data, at: 4)) : Int(Int32(bitPattern: uint32(data, at: 4)))
        let signedHeight = isCore ? Int(uint16(data, at: 6)) : Int(Int32(bitPattern: uint32(data, at: 8)))
        let height = abs(signedHeight)
        try validateDimensions(width: width, height: height)
        let depth = Int(uint16(data, at: isCore ? 10 : 14))
        let compression = isCore ? 0 : Int(uint32(data, at: 16))
        let imageSize = isCore ? 0 : Int(uint32(data, at: 20))
        guard uint16(data, at: isCore ? 8 : 12) == 1 else {
            throw FeiQInlineImageDecodingError.invalidBitmap
        }
        if compression == 4 || compression == 5 {
            let offset = filePixelOffset ?? headerSize
            guard offset >= headerSize, offset < data.count, imageSize <= data.count - offset else {
                throw FeiQInlineImageDecodingError.invalidBitmap
            }
            let payload = data.subdata(in: offset..<(imageSize == 0 ? data.count : offset + imageSize))
            guard compression == 4 ? payload.starts(with: [0xff, 0xd8])
                : payload.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) else {
                throw FeiQInlineImageDecodingError.invalidBitmap
            }
            return payload
        }
        guard [1, 4, 8, 16, 24, 32].contains(depth),
              compression == 0 || (compression == 1 && depth == 8 && signedHeight > 0)
                || (compression == 2 && depth == 4 && signedHeight > 0)
                || ([3, 6].contains(compression) && [16, 32].contains(depth) && !isCore) else {
            throw FeiQInlineImageDecodingError.invalidBitmap
        }
        let declaredColors = isCore ? 0 : Int(uint32(data, at: 32))
        let colors = declaredColors == 0 && depth <= 8 ? 1 << depth : declaredColors
        guard colors <= (depth <= 8 ? 1 << depth : 256) else { throw FeiQInlineImageDecodingError.invalidBitmap }
        let masksSize = headerSize == 40 ? (compression == 3 ? 12 : (compression == 6 ? 16 : 0)) : 0
        let paletteEnd = headerSize + masksSize + colors * (isCore ? 3 : 4)
        var pixelOffset = filePixelOffset ?? paletteEnd
        if filePixelOffset == nil, headerSize == 124 {
            let profileOffset = Int(uint32(data, at: 112))
            let profileSize = Int(uint32(data, at: 116))
            if profileOffset == paletteEnd, profileSize > 0 {
                pixelOffset = profileOffset + profileSize
            }
        }
        guard pixelOffset >= paletteEnd, pixelOffset < data.count, imageSize <= data.count - pixelOffset else {
            throw FeiQInlineImageDecodingError.invalidBitmap
        }
        if compression == 1 || compression == 2 {
            let end = imageSize == 0 ? data.count : pixelOffset + imageSize
            try validateRLE(data.subdata(in: pixelOffset..<end), width: width, height: height, depth: depth, colors: colors)
        } else {
            let stride = ((width * depth + 31) / 32) * 4
            guard height <= (data.count - pixelOffset) / stride else {
                throw FeiQInlineImageDecodingError.invalidBitmap
            }
        }
        if compression == 3 || compression == 6 {
            guard headerSize + masksSize >= 52,
                  compression != 6 || headerSize + masksSize >= 56 else {
                throw FeiQInlineImageDecodingError.invalidBitmap
            }
            let channels = [uint32(data, at: 40), uint32(data, at: 44), uint32(data, at: 48)]
            let alpha = headerSize + masksSize >= 56 ? uint32(data, at: 52) : 0
            var usedBits: UInt32 = 0
            for mask in channels + (alpha == 0 ? [] : [alpha]) {
                guard mask != 0, mask & usedBits == 0, depth == 32 || mask < 1 << depth else {
                    throw FeiQInlineImageDecodingError.invalidBitmap
                }
                let component = mask >> mask.trailingZeroBitCount
                guard component & (component &+ 1) == 0 else { throw FeiQInlineImageDecodingError.invalidBitmap }
                usedBits |= mask
            }
            guard compression != 6 || alpha != 0 else { throw FeiQInlineImageDecodingError.invalidBitmap }
            let oldHeaderEnd = headerSize + masksSize
            var normalized = Data(data.prefix(oldHeaderEnd))
            normalized.append(Data(repeating: 0, count: 124 - normalized.count))
            replaceUInt32(124, at: 0, in: &normalized)
            replaceUInt32(3, at: 16, in: &normalized)
            if headerSize < 108 { replaceUInt32(0x73524742, at: 56, in: &normalized) }
            normalized.append(data.dropFirst(oldHeaderEnd))
            pixelOffset += 124 - oldHeaderEnd
            data = normalized
        } else if headerSize == 108 {
            var normalized = Data(data.prefix(headerSize))
            replaceUInt32(124, at: 0, in: &normalized)
            normalized.append(Data(repeating: 0, count: 16))
            normalized.append(data.dropFirst(headerSize))
            pixelOffset += 16
            data = normalized
        }
        var bitmap = Data([0x42, 0x4d])
        for value in [data.count + 14, 0, pixelOffset + 14] {
            for shift in stride(from: 0, to: 32, by: 8) { bitmap.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        bitmap.append(data)
        return bitmap
    }

    private static func validateRLE(_ data: Data, width: Int, height: Int, depth: Int, colors: Int) throws {
        var offset = 0
        var column = 0
        var row = 0
        func validateIndices(_ packed: UInt8, count: Int) throws {
            if depth == 8 {
                guard Int(packed) < colors else { throw FeiQInlineImageDecodingError.invalidBitmap }
            } else if Int(packed >> 4) >= colors || (count > 1 && Int(packed & 0x0f) >= colors) {
                throw FeiQInlineImageDecodingError.invalidBitmap
            }
        }
        while offset + 2 <= data.count {
            let count = Int(data[offset])
            let value = data[offset + 1]
            offset += 2
            if count > 0 {
                guard row < height, count <= width - column else { throw FeiQInlineImageDecodingError.invalidBitmap }
                try validateIndices(value, count: count)
                column += count
            } else if value == 0 {
                column = 0
                row += 1
                guard row <= height else { throw FeiQInlineImageDecodingError.invalidBitmap }
            } else if value == 1 {
                return
            } else if value == 2 {
                guard offset + 2 <= data.count else { throw FeiQInlineImageDecodingError.invalidBitmap }
                column += Int(data[offset])
                row += Int(data[offset + 1])
                offset += 2
                guard column <= width, row < height else { throw FeiQInlineImageDecodingError.invalidBitmap }
            } else {
                let pixelCount = Int(value)
                let byteCount = depth == 8 ? pixelCount : (pixelCount + 1) / 2
                let paddedCount = (byteCount + 1) / 2 * 2
                guard row < height, pixelCount <= width - column, paddedCount <= data.count - offset else {
                    throw FeiQInlineImageDecodingError.invalidBitmap
                }
                for index in 0..<byteCount {
                    try validateIndices(data[offset + index], count: depth == 8 ? 1 : pixelCount - index * 2)
                }
                offset += paddedCount
                column += pixelCount
            }
        }
        throw FeiQInlineImageDecodingError.invalidBitmap
    }

    private static func uint16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) | UInt16(data[data.startIndex + offset + 1]) << 8
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(data[data.startIndex + offset + $1]) << ($1 * 8) }
    }

    private static func replaceUInt32(_ value: UInt32, at offset: Int, in data: inout Data) {
        for index in 0..<4 { data[data.startIndex + offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
}
