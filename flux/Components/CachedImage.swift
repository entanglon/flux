import SwiftUI
import ImageIO

struct DecodedImage: @unchecked Sendable {
    let image: NSImage
    let cost: Int
}

/// Bounds how many ImageIO decodes run at once. Scrolling reveals batches of
/// cards; without a gate, 20+ simultaneous decodes spike CPU in bursts and
/// stall the main thread between bursts (scroll-pause-scroll-pause). Overcount
/// from cancelled waiters self-heals on the next waiter-less release.
actor DecodeGate {
    static let shared = DecodeGate()
    private let maxConcurrent = 4
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else {
            running = max(0, running - 1)
        }
    }
}

enum CachedImageDownsampler {
    static func downsample(data: Data, maxDimension: CGFloat) async -> DecodedImage? {
        guard !Task.isCancelled else { return nil }
        await DecodeGate.shared.acquire()
        let result = await Task.detached(priority: .utility) { () -> DecodedImage? in
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension
            ]

            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                return nil
            }
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
            return DecodedImage(
                image: nsImage,
                cost: ImageInMemoryCache.decodedImageCost(width: cgImage.width, height: cgImage.height)
            )
        }.value
        await DecodeGate.shared.release()
        return result
    }
}

struct CachedImage<Content: View>: View {
    let url: URL?
    var fallbacks: [URL?] = []
    let transaction: Transaction
    let maxDimension: CGFloat // Max size to decode
    @ViewBuilder let content: (AsyncImagePhase) -> Content

    @State private var phase: AsyncImagePhase = .empty

    init(url: URL?, fallbacks: [URL?] = [], maxDimension: CGFloat = 300, transaction: Transaction = Transaction(), @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.fallbacks = fallbacks
        self.maxDimension = maxDimension
        self.transaction = transaction
        self.content = content

        // Instant frame 0 cache hit for smooth 120 FPS scrolling without task latency
        let candidates = ([url] + fallbacks).compactMap { $0 }
        let roundedDim = Int(maxDimension.rounded())
        var initialPhase: AsyncImagePhase = .empty
        for candidate in candidates {
            let key = "\(candidate.absoluteString)#\(roundedDim)" as NSString
            if let cached = ImageInMemoryCache.shared.object(forKey: key) {
                initialPhase = .success(Image(nsImage: cached))
                break
            }
        }
        self._phase = State(initialValue: initialPhase)
    }

    var body: some View {
        content(phase)
            .task(id: url) {
                await loadImage()
            }
    }

    private func loadImage() async {
        // Fast path: synchronous in-memory cache check (zero task latency on scroll)
        let candidates = ([url] + fallbacks).compactMap { $0 }
        guard !candidates.isEmpty else {
            phase = .empty
            return
        }

        let roundedDim = Int(maxDimension.rounded())

        // 1. Immediate in-memory cache hit
        for candidate in candidates {
            let key = "\(candidate.absoluteString)#\(roundedDim)" as NSString
            if let cached = ImageInMemoryCache.shared.object(forKey: key) {
                phase = .success(Image(nsImage: cached))
                return
            }
        }

        // 2. Fetch and decode (disk cache -> network -> downsample)
        for candidate in candidates {
            if Task.isCancelled { return }
            let cacheKey = "\(candidate.absoluteString)#\(roundedDim)" as NSString

            // Re-check memory cache (another task may have decoded it)
            if let cached = ImageInMemoryCache.shared.object(forKey: cacheKey) {
                withTransaction(transaction) {
                    phase = .success(Image(nsImage: cached))
                }
                return
            }

            let session = ImageSession.shared
            let request = URLRequest(url: candidate, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)

            // 2. Session's own disk cache
            if let cachedResponse = session.configuration.urlCache?.cachedResponse(for: request),
               let downsampled = await CachedImageDownsampler.downsample(data: cachedResponse.data, maxDimension: maxDimension) {
                ImageInMemoryCache.shared.setObject(downsampled.image, forKey: cacheKey, cost: downsampled.cost)
                if Task.isCancelled { return }
                withTransaction(transaction) {
                    phase = .success(Image(nsImage: downsampled.image))
                }
                return
            }

            // 3. Network fetch
            do {
                let (data, response) = try await session.data(for: request)
                if Task.isCancelled { return }
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    continue // dead URL — try next candidate
                }
                guard let downsampled = await CachedImageDownsampler.downsample(data: data, maxDimension: maxDimension) else {
                    continue // undecodable — try next candidate
                }
                ImageInMemoryCache.shared.setObject(downsampled.image, forKey: cacheKey, cost: downsampled.cost)
                if Task.isCancelled { return }
                withTransaction(transaction) {
                    phase = .success(Image(nsImage: downsampled.image))
                }
                return
            } catch {
                if Task.isCancelled { return }
                continue
            }
        }

        if !Task.isCancelled {
            phase = .failure(URLError(.cannotFindHost))
        }
    }
}

/// Lightweight lookahead prefetcher for horizontal rails.
/// Warms the next 2-3 card thumbnails into ImageInMemoryCache ahead of the scroll position.
final class ImagePrefetcher: @unchecked Sendable {
    static let shared = ImagePrefetcher()

    private var inFlight = Set<String>()
    private let lock = NSLock()

    private init() {}

    func prefetch(urls: [URL?], maxDimension: CGFloat = 300) {
        let validURLs = urls.compactMap { $0 }
        guard !validURLs.isEmpty else { return }

        let roundedDim = Int(maxDimension.rounded())
        var toFetch: [URL] = []

        lock.lock()
        for url in validURLs {
            let cacheKey = "\(url.absoluteString)#\(roundedDim)"
            if ImageInMemoryCache.shared.object(forKey: cacheKey as NSString) != nil {
                continue
            }
            if inFlight.contains(cacheKey) {
                continue
            }
            inFlight.insert(cacheKey)
            toFetch.append(url)
        }
        lock.unlock()

        guard !toFetch.isEmpty else { return }

        Task(priority: .utility) {
            for url in toFetch {
                let cacheKey = "\(url.absoluteString)#\(roundedDim)"
                defer {
                    self.lock.lock()
                    self.inFlight.remove(cacheKey)
                    self.lock.unlock()
                }

                let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
                // 1. Session disk cache
                if let cachedResponse = ImageSession.shared.configuration.urlCache?.cachedResponse(for: request),
                   let downsampled = await CachedImageDownsampler.downsample(data: cachedResponse.data, maxDimension: maxDimension) {
                    ImageInMemoryCache.shared.setObject(downsampled.image, forKey: cacheKey as NSString, cost: downsampled.cost)
                    continue
                }

                // 2. Network fetch
                do {
                    let (data, response) = try await ImageSession.shared.data(for: request)
                    if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                       let downsampled = await CachedImageDownsampler.downsample(data: data, maxDimension: maxDimension) {
                        ImageInMemoryCache.shared.setObject(downsampled.image, forKey: cacheKey as NSString, cost: downsampled.cost)
                    }
                } catch {
                    // Ignore prefetch network errors
                }
            }
        }
    }
}

class ImageSession {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024,  // 16 MB memory cache (512 MB on disk)
                                   diskCapacity: 512 * 1024 * 1024,   // 512 MB disk
                                   diskPath: "FluxImageCache")
        return URLSession(configuration: config)
    }()
}

final class ImageInMemoryCache {
    static let shared: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        // No count limit: ~300 live cards across all rails exceeded 250 and
        // forced LRU thrash (re-decode on every scroll-back). The byte budget
        // below is the real bound — each entry carries an accurate pixel cost.
        cache.countLimit = 0
        cache.totalCostLimit = 128 * 1024 * 1024  // 128 MB of decoded pixels (≈100-200 cards at rail sizes; trivial on Apple Silicon unified memory)
        return cache
    }()

    /// Purges all in-memory decoded rasters (called during video playback to free RAM)
    static func purgeMemoryCache() {
        shared.removeAllObjects()
    }

    /// NSCache only enforces totalCostLimit when every insertion supplies a
    /// cost. Decoded image memory is approximately width × height × 4 bytes.
    static func decodedImageCost(width: Int, height: Int) -> Int {
        guard width > 0, height > 0 else { return 1 }
        let (pixels, pixelsOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelsOverflow else { return Int.max }
        let (bytes, bytesOverflow) = pixels.multipliedReportingOverflow(by: 4)
        return bytesOverflow ? Int.max : max(1, bytes)
    }
}

/// Debug logger for image loading
enum ImageDebugLog {
    @inline(__always)
    static func log(_ message: String) {
        // Fast in-memory logging; avoid synchronous disk I/O on scroll thread
    }
}
