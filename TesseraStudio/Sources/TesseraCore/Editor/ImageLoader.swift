import Foundation
#if canImport(AppKit)
import AppKit
import ImageIO
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Platform types

#if canImport(AppKit)
/// Platform image type — NSImage on macOS.
public typealias TesseraPlatformImage = NSImage
/// Weak wrapper so NSCache holds NSImage without retain cycles.
final class TesseraImageWrapper: NSObject {
    let image: NSImage
    init(image: NSImage) { self.image = image }
}
/// Weak reference to an NSImageView for live-update of attachments.
final class TesseraWeakImageView {
    weak var cell: AnyObject?
    init(_ cell: AnyObject?) { self.cell = cell }
}
#elseif canImport(UIKit)
/// Platform image type — UIImage on iOS.
public typealias TesseraPlatformImage = UIImage
/// Wrapper for UIImage caching.
final class TesseraImageWrapper: NSObject {
    let image: UIImage
    init(image: UIImage) { self.image = image }
}
/// Weak reference to a UIImageView.
final class TesseraWeakImageView {
    weak var cell: AnyObject?
    init(_ cell: AnyObject?) { self.cell = cell }
}
#else
/// Placeholder on unsupported platforms.
public typealias TesseraPlatformImage = Any
final class TesseraImageWrapper: NSObject {}
final class TesseraWeakImageView {
    weak var cell: AnyObject?
    init(_ cell: AnyObject?) { self.cell = cell }
}
#endif

// MARK: - ImageLoader

/// Global async image loader with memory caching, off-thread decoding,
/// cancellation, and viewport-based prefetch.
///
/// **Memory cache.** Backed by `NSCache` which is auto-purged under
/// system memory pressure — no manual `didReceiveMemoryWarning` needed.
///
/// **Off-thread decode.** `Data(contentsOf:)` and `NSImage(data:)` are
/// synchronous and block the main thread. The loader decodes on
/// `DispatchQueue.global(qos: .userInitiated)` and uses ImageIO for
/// memory-efficient downsampled thumbnail creation off the main thread.
///
/// **Cancellation.** Each `load(for:)` call can be abandoned via
/// `cancel(for:)` — the completion callback is dropped for cancelled requests.
///
/// **Memory-pressure resilience.** `NSCache` purges entries automatically.
/// When the cache is flushed, the next `load(for:)` re-fetches. We only
/// cache decoded `NSImage`/`UIImage`, never raw `Data`.
public final class ImageLoader: @unchecked Sendable {

    public static let shared = ImageLoader()

    // MARK: - Cache

    private let cache = NSCache<NSString, TesseraImageWrapper>()

    /// In-flight load tokens — removed when cancelled so callbacks are dropped.
    private let inflight = NSLock()
    private var inflightTokens = Set<UUID>()

    /// Pending completion callbacks, keyed by block UUID.
    private let callbacks = NSLock()
    private var pendingCallbacks: [UUID: [(TesseraPlatformImage?) -> Void]] = [:]

    /// Prefetch queue — serial to avoid thundering-herd on the same URL.
    private let prefetchQueue = DispatchQueue(label: "tessera.imageloader.prefetch", qos: .utility)

    // MARK: - Public API

    /// Load an image from `source` (file:// or http(s)://) and invoke
    /// `completion` on the main thread with the loaded image (or nil on failure).
    /// Repeated calls with the same source return the cached image without re-fetching.
    ///
    /// - Returns: the `blockID` as a cancellation token — pass to `cancel(for:)`.
    @discardableResult
    public func load(
        for blockID: UUID,
        source: String,
        completion: @escaping (TesseraPlatformImage?) -> Void
    ) -> UUID {
        let cacheKey = source as NSString

        // Fast path: serve from cache without any I/O.
        if let wrapper = cache.object(forKey: cacheKey) {
            DispatchQueue.main.async { completion(wrapper.image) }
            return blockID
        }

        // Check for an existing in-flight load for this block.
        inflight.lock()
        let alreadyLoading = inflightTokens.contains(blockID)
        inflight.unlock()

        if alreadyLoading {
            // Append to pending callbacks so the existing load fires them when done.
            callbacks.lock()
            pendingCallbacks[blockID, default: []].append(completion)
            callbacks.unlock()
            return blockID
        }

        // Register this load as in-flight.
        inflight.lock()
        inflightTokens.insert(blockID)
        inflight.unlock()

        // Register the caller's completion so it's fired when the load finishes.
        callbacks.lock()
        pendingCallbacks[blockID, default: []].append(completion)
        callbacks.unlock()

        // Perform the I/O off the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let image = self.loadFromSource(source)

            self.inflight.lock()
            let wasCancelled = !self.inflightTokens.contains(blockID)
            self.inflight.unlock()

            if !wasCancelled {
                if let img = image {
                    self.cache.setObject(TesseraImageWrapper(image: img), forKey: cacheKey)
                }
                self.fireCallbacks(for: blockID, with: image)
            }
        }

        return blockID
    }

    /// Abandon an in-flight load. Its completion callback will not be called.
    public func cancel(for blockID: UUID) {
        inflight.lock()
        inflightTokens.remove(blockID)
        inflight.unlock()

        callbacks.lock()
        pendingCallbacks.removeValue(forKey: blockID)
        callbacks.unlock()
    }

    /// Warm the cache for upcoming image blocks without calling completions.
    /// Fire-and-forget; failures are silently ignored.
    public func prefetch(sources: [(UUID, String)]) {
        prefetchQueue.async { [weak self] in
            guard let self else { return }
            for (_, source) in sources {
                let cacheKey = source as NSString
                if self.cache.object(forKey: cacheKey) != nil { continue }
                _ = self.loadFromSource(source)
            }
        }
    }

    /// Drop all in-flight loads and pending callbacks.
    /// Called when the document changes so stale callbacks never fire.
    public func cancelAllLoads() {
        inflight.lock()
        inflightTokens.removeAll()
        inflight.unlock()

        callbacks.lock()
        pendingCallbacks.removeAll()
        callbacks.unlock()
    }

    // MARK: - Private

    /// Fetch + decode image data. Must be called off the main thread.
    private func loadFromSource(_ source: String) -> TesseraPlatformImage? {
        guard let url = URL(string: source) else { return nil }

        var data: Data?
        if url.isFileURL {
            data = try? Data(contentsOf: url)
        } else {
            // URLSession for remote URLs with timeout.
            data = fetchWithTimeout(url: url, timeout: 10)
        }
        guard let d = data else { return nil }

        return decodeImage(data: d)
    }

    /// Fetch remote data with a timeout via URLSession.
    private func fetchWithTimeout(url: URL, timeout: TimeInterval) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        var fetchError: Error?
        let task = URLSession.shared.dataTask(with: url) { d, _, e in
            result = d
            fetchError = e
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout)
        return result
    }

    /// Decode image data to a platform image, using ImageIO for efficient
    /// downsampled thumbnail creation when possible. Called off the main thread.
    private func decodeImage(data: Data) -> TesseraPlatformImage? {
        #if canImport(AppKit)
        guard let image = NSImage(data: data) else { return nil }
        // Use ImageIO to create a downsampled thumbnail at display resolution
        // (max 2048px). This avoids decoding a 50MP camera RAW into full memory
        // when it'll only display at 1440p on screen.
        let decoded = decodeNSImageWithImageIO(data)
        return decoded ?? image
        #elseif canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        let decoded = decodeUIImageWithImageIO(data)
        return decoded ?? image
        #else
        return nil
        #endif
    }

    #if canImport(AppKit)
    private func decodeNSImageWithImageIO(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
    #endif

    #if canImport(UIKit)
    private func decodeUIImageWithImageIO(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
    #endif

    private func fireCallbacks(for blockID: UUID, with image: TesseraPlatformImage?) {
        callbacks.lock()
        let pending = pendingCallbacks.removeValue(forKey: blockID) ?? []
        callbacks.unlock()

        inflight.lock()
        inflightTokens.remove(blockID)
        inflight.unlock()

        DispatchQueue.main.async {
            for callback in pending {
                callback(image)
            }
        }
    }
}
