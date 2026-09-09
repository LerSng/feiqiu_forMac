import Foundation
import ImageIO
import UniformTypeIdentifiers
import zlib

@main
enum WindowsInlineImageChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feiq-windows-images-" + UUID().uuidString)
        let storage = LocalChatAttachmentStorageService(rootURL: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try makePNG()
        let jpeg = try makePNG(type: .jpeg)
        let rgbPixels = Data((0..<(8 * 8)).flatMap { _ in [UInt8(0), 0, 255] })
        let bitmap = dib(width: 8, height: 8, depth: 24, compression: 0, pixels: rgbPixels)
        let palette = Data([0, 0, 0, 0, 0, 0, 255, 0])
        let rle8 = Data((0..<8).flatMap { _ in [UInt8(8), 1, 0, 0] } + [0, 1])
        let rle4 = Data((0..<8).flatMap { _ in [UInt8(8), 0x11, 0, 0] } + [0, 1])
        var core = Data()
        append32(12, to: &core)
        for value in [UInt16(8), 8, 1, 24] { append16(value, to: &core) }
        core.append(rgbPixels)

        let fixtures: [(String, Data)] = [
            ("PNG", png),
            ("RGB DIB", bitmap),
            ("CORE DIB", core),
            ("V4 RGB DIB", extendedBitmap(bitmap, headerSize: 108)),
            ("V5 RGB DIB", extendedBitmap(bitmap, headerSize: 124)),
            ("top-down DIB", dib(width: 8, height: -8, depth: 24, compression: 0, pixels: rgbPixels)),
            ("indexed 1-bit DIB", dib(width: 8, height: 8, depth: 1, compression: 0,
                                      pixels: Data((0..<8).flatMap { _ in [UInt8(255), 0, 0, 0] }), palette: palette)),
            ("indexed 4-bit DIB", dib(width: 8, height: 8, depth: 4, compression: 0,
                                      pixels: Data(repeating: 0x11, count: 32), palette: palette)),
            ("indexed 8-bit DIB", dib(width: 8, height: 8, depth: 8, compression: 0,
                                      pixels: Data(repeating: 1, count: 64), palette: palette)),
            ("16-bit RGB565 DIB", bitfieldsBitmap(headerSize: 40, depth: 16)),
            ("V2 bitfields DIB", bitfieldsBitmap(headerSize: 52)),
            ("V3 bitfields DIB", bitfieldsBitmap(headerSize: 56)),
            ("V4 bitfields DIB", bitfieldsBitmap(headerSize: 108)),
            ("V5 bitfields DIB", bitfieldsBitmap(headerSize: 124)),
            ("alpha bitfields DIB", bitfieldsBitmap(headerSize: 40, alphaCompression: true)),
            ("BMP file", bitmapFile(bitmap, pixelOffset: 40)),
            ("RLE8 DIB", dib(width: 8, height: 8, depth: 8, compression: 1, pixels: rle8, palette: palette)),
            ("RLE4 DIB", dib(width: 8, height: 8, depth: 4, compression: 2, pixels: rle4, palette: palette)),
            ("absolute RLE8", dib(width: 8, height: 8, depth: 8, compression: 1, pixels:
                                  Data((0..<8).flatMap { _ in [UInt8(0), 8, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0] } + [0, 1]), palette: palette)),
            ("absolute RLE4", dib(width: 8, height: 8, depth: 4, compression: 2, pixels:
                                  Data((0..<8).flatMap { _ in [UInt8(0), 8, 0x11, 0x11, 0x11, 0x11, 0, 0] } + [0, 1]), palette: palette)),
            ("embedded PNG DIB", dib(width: 8, height: 8, depth: 0, compression: 5, pixels: png)),
            ("embedded JPEG DIB", dib(width: 8, height: 8, depth: 0, compression: 4, pixels: jpeg)),
            ("JPEG", jpeg),
            ("zlib JPEG", try compress(jpeg)),
            ("zlib PNG", try compress(png)),
            ("zlib DIB", try compress(bitmap)),
            ("gzip PNG", try compress(png, gzip: true)),
            ("length-prefixed zlib DIB", try lengthPrefixed(bitmap)),
            ("big-endian length-prefixed PNG", try lengthPrefixed(png, bigEndian: true))
        ]
        var failures: [String] = []
        for (index, fixture) in fixtures.enumerated() {
            do {
                for isBitmap in [false, true] {
                    let imageID = String(format: "%08x", index * 2 + (isBitmap ? 1 : 2))
                    let stored = try storage.saveInlineImage(fixture.1, imageID: imageID, isBitmap: isBitmap)
                    let encoded = try Data(contentsOf: stored.localURL)
                    guard let source = CGImageSourceCreateWithData(encoded as CFData, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                        preconditionFailure("Saved image must be readable: \(fixture.0)")
                    }
                    precondition(image.width == 8 && image.height == 8, "Incorrect dimensions: \(fixture.0)")
                    try checkRedPixel(image, name: fixture.0)
                }
                print("PASS \(fixture.0)")
            } catch {
                failures.append(fixture.0 + ": " + error.localizedDescription)
                print("FAIL \(fixture.0): \(error)")
            }
        }
        if !failures.isEmpty {
            throw NSError(domain: "WindowsInlineImageChecks", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "\n")])
        }
        try checkMalformedImages(bitmap: bitmap, png: png, palette: palette, storage: storage)
        try checkFragmentedImage(jpeg)
        let summary = FeiQInlineImageDecoder.diagnosticSummary(bitmap)
        precondition(summary.contains("DIB=40") && summary.contains("位深=24") && summary.count < 200)
        print("Windows inline image checks passed")
    }

    private static func checkRedPixel(_ image: CGImage, name: String) throws {
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        guard pixels[0] > 200, pixels[1] < 40, pixels[2] < 40, pixels[3] == 255 else {
            throw NSError(domain: "WindowsInlineImageChecks", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "\(name) decoded with incorrect color or alpha: \(pixels.prefix(4))"])
        }
    }

    private static func checkMalformedImages(bitmap: Data, png: Data, palette: Data,
                                              storage: LocalChatAttachmentStorageService) throws {
        var corrupted = try compress(png)
        corrupted[corrupted.count - 1] ^= 0xff
        var wrongLength = try lengthPrefixed(png)
        wrongLength[0] ^= 0x01
        var oversized = bitmap
        oversized.replaceSubrange(4..<8, with: [0xff, 0xff, 0xff, 0x7f])
        var badPalette = bitmap
        badPalette.replaceSubrange(32..<36, with: [0xff, 0xff, 0xff, 0xff])
        let missingEnd = dib(width: 8, height: 8, depth: 8, compression: 1, pixels: Data([8, 1]), palette: palette)
        let invalid: [(String, Data)] = [
            ("empty image", Data()), ("unknown format", Data([1, 2, 3])),
            ("truncated pixels", Data(bitmap.dropLast())), ("oversized dimensions", oversized),
            ("oversized palette", badPalette), ("truncated zlib", Data(try compress(png).dropLast(2))),
            ("bad checksum", corrupted), ("wrong declared length", wrongLength),
            ("trailing compressed garbage", try compress(png) + Data([1])),
            ("RLE missing terminator", missingEnd),
            ("BMP RLE missing terminator", bitmapFile(missingEnd, pixelOffset: 48)),
            ("RLE row overflow", dib(width: 8, height: 8, depth: 8, compression: 1,
                                     pixels: Data([9, 1, 0, 1]), palette: palette)),
            ("RLE palette overflow", dib(width: 8, height: 8, depth: 8, compression: 1,
                                         pixels: Data([8, 2, 0, 1]), palette: palette)),
            ("RLE delta overflow", dib(width: 8, height: 8, depth: 8, compression: 1,
                                       pixels: Data([0, 2, 9, 0, 0, 1]), palette: palette)),
            ("RLE missing literal padding", dib(width: 8, height: 8, depth: 4, compression: 2,
                                                pixels: Data([0, 5, 0x11, 0x11, 0x10]), palette: palette)),
            ("decompression limit", try compress(Data(repeating: 0, count: FeiQInlineImageDecoder.maximumInflatedBytes + 1)))
        ]
        for (name, data) in invalid {
            do {
                _ = try storage.saveInlineImage(data, imageID: "ffffffff", isBitmap: false)
                preconditionFailure("Malformed input was accepted: \(name)")
            } catch is FeiQInlineImageDecodingError {}
        }
        print("PASS \(invalid.count) malformed / oversized inputs")
    }

    private static func checkFragmentedImage(_ jpeg: Data) throws {
        let compressed = try compress(jpeg)
        let assembler = FeiQInlineImageAssembler()
        let total = (compressed.count + 31) / 32
        var completed: Data?
        for index in (0..<total).reversed() {
            let offset = index * 32
            let chunk = compressed.subdata(in: offset..<min(offset + 32, compressed.count))
            let header = "11223344|\(compressed.count)|\(offset)|\(total)|\(index + 1)|\(chunk.count)|1|0|0|00000000#\0"
            let decoded = FeiQInlineImageCodec.decode(Data(header.utf8) + chunk + Data([0]))!
            let result = assembler.accept(decoded, from: "192.0.2.51")
            precondition(result.accepted)
            if let bytes = result.data { completed = bytes }
        }
        precondition(completed == compressed, "Fragmentation must preserve the compressed stream")
        let image = try FeiQInlineImageDecoder.decode(completed!)
        try checkRedPixel(image, name: "out-of-order compressed Windows fragments")
    }

    private static func bitfieldsBitmap(headerSize: Int, depth: UInt16 = 32, alphaCompression: Bool = false) -> Data {
        let pixels = depth == 16
            ? Data((0..<64).flatMap { _ in [UInt8(0), 0xf8] })
            : Data((0..<64).flatMap { _ in [UInt8(0), 0, 255, 255] })
        var header = Data(dib(width: 8, height: -8, depth: depth, compression: alphaCompression ? 6 : 3, pixels: pixels).prefix(40))
        var size = Data()
        append32(UInt32(headerSize), to: &size)
        header.replaceSubrange(0..<4, with: size)
        let masks: [UInt32] = depth == 16 ? [0xf800, 0x07e0, 0x001f] : [0x00ff0000, 0x0000ff00, 0x000000ff]
        for mask in masks { append32(mask, to: &header) }
        if headerSize >= 56 || alphaCompression { append32(0xff000000, to: &header) }
        if header.count < headerSize { header.append(Data(repeating: 0, count: headerSize - header.count)) }
        if headerSize >= 108 {
            var colorSpace = Data()
            append32(0x73524742, to: &colorSpace)
            header.replaceSubrange(56..<60, with: colorSpace)
        }
        header.append(pixels)
        return header
    }

    private static func bitmapFile(_ dib: Data, pixelOffset: Int) -> Data {
        var data = Data([0x42, 0x4d])
        append32(UInt32(dib.count + 14), to: &data)
        append32(0, to: &data)
        append32(UInt32(pixelOffset + 14), to: &data)
        data.append(dib)
        return data
    }

    private static func extendedBitmap(_ dib: Data, headerSize: Int) -> Data {
        var result = Data()
        append32(UInt32(headerSize), to: &result)
        result.append(dib.subdata(in: 4..<40))
        result.append(Data(repeating: 0, count: headerSize - 40))
        var colorSpace = Data()
        append32(0x73524742, to: &colorSpace)
        result.replaceSubrange(56..<60, with: colorSpace)
        result.append(dib.dropFirst(40))
        return result
    }

    private static func makePNG(type: UTType = .png) throws -> Data {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func dib(width: Int32, height: Int32, depth: UInt16, compression: UInt32,
                            pixels: Data, palette: Data = Data()) -> Data {
        var data = Data()
        append32(40, to: &data)
        append32(UInt32(bitPattern: width), to: &data)
        append32(UInt32(bitPattern: height), to: &data)
        append16(1, to: &data)
        append16(depth, to: &data)
        append32(compression, to: &data)
        append32(UInt32(pixels.count), to: &data)
        append32(0, to: &data)
        append32(0, to: &data)
        append32(UInt32(palette.count / 4), to: &data)
        append32(0, to: &data)
        data.append(palette)
        data.append(pixels)
        return data
    }

    private static func compress(_ data: Data, gzip: Bool = false) throws -> Data {
        var stream = z_stream()
        precondition(deflateInit2_(&stream, Z_BEST_COMPRESSION, Z_DEFLATED, gzip ? 31 : 15, 8,
                                  Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
        defer { deflateEnd(&stream) }
        var output = Data(count: Int(compressBound(uLong(data.count))) + 32)
        let capacity = output.count
        let status = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(capacity)
                return deflate(&stream, Z_FINISH)
            }
        }
        precondition(status == Z_STREAM_END)
        output.count = Int(stream.total_out)
        return output
    }

    private static func lengthPrefixed(_ data: Data, bigEndian: Bool = false) throws -> Data {
        var result = Data()
        append32(bigEndian ? UInt32(data.count).byteSwapped : UInt32(data.count), to: &result)
        result.append(try compress(data))
        return result
    }

    private static func append16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func append32(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
}
