import Foundation
import ImageIO

enum ImageThumbnailLoader {
    private final class CachedImage: NSObject {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private static let cache: NSCache<NSString, CachedImage> = {
        let cache = NSCache<NSString, CachedImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        cache.countLimit = 128
        return cache
    }()
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "figma-finder.thumbnails"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    @discardableResult
    static func load(_ url: URL, completion: @escaping @MainActor (CGImage?) -> Void) -> Operation {
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak operation] in
            guard let operation, !operation.isCancelled else { return }
            let image = autoreleasepool { thumbnail(url) }
            guard !operation.isCancelled else { return }
            Task { @MainActor in
                if !operation.isCancelled { completion(image) }
            }
        }
        queue.addOperation(operation)
        return operation
    }

    private static func thumbnail(_ url: URL) -> CGImage? {
        let url = url.resolvingSymlinksInPath()
        // URL.resourceValues can retain stale metadata after an in-place edit.
        // Stat the file afresh, including its identity for atomic replacements.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let key = "\(url.absoluteString)|\(modified)|\(attributes?[.size] ?? 0)|\(attributes?[.systemFileNumber] ?? 0)" as NSString
        if let cached = cache.object(forKey: key) { return cached.image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 512
              ] as CFDictionary) else { return nil }
        cache.setObject(CachedImage(image), forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}
