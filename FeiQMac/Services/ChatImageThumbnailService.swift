import Foundation
import ImageIO

actor ChatImageThumbnailService {
    static let shared = ChatImageThumbnailService()
    private let cache = NSCache<NSString, CGImage>()

    init() {
        cache.countLimit = 120
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    func thumbnail(for attachment: ChatAttachment, pixelSize: Int = 360) -> CGImage? {
        guard attachment.isImage, !attachment.localPath.isEmpty,
              let values = try? attachment.localURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        let dimension = max(64, min(pixelSize, 640))
        let key = "\(attachment.localPath):\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(dimension)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(attachment.localURL as CFURL, options),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: dimension,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}
