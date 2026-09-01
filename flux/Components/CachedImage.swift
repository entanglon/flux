import SwiftUI
import ImageIO

struct CachedImage<Content: View>: View {
    private struct DecodedImage {
        let image: NSImage
        let cost: Int
    }

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
            .task(id: resolvedCandidates) {
                await load()
            }
    }

    /// Re-computed when url/fallbacks change so .task re-runs.
    private var resolvedCandidates: [URL] {
        ([url] + fallbacks).compactMap { $0 }
    }

    private func load() async {
        let candidates = resolvedCandidates
        guard !candidates.isEmpty else {
            if case .empty = phase { } else { phase = .empty }
            return
        }

        let roundedDim = Int(maxDimension.rounded())

        // Quick check: if already showing an image from our candidates, verify it's valid
        for candidate in candidates {
            let cacheKey = "\(candidate.absoluteString)#\(roundedDim)" as NSString
            if let cachedNSImage = ImageInMemoryCache.shared.object(forKey: cacheKey) {
                if case .success = phase {
                    return
                }
                phase = .success(Image(nsImage: cachedNSImage))
                return
            }
        }

        // Walk the ladder: first candidate that produces a decoded image wins.
        for candidate in candidates {
            if Task.isCancelled { return }
            let cacheKey = "\(candidate.absoluteString)#\(roundedDim)" as NSString

            // 1. In-memory NSCache (instant)
            if let cachedNSImage = ImageInMemoryCache.shared.object(forKey: cacheKey) {
                phase = .success(Image(nsImage: cachedNSImage))
                return
            }

            let session = ImageSession.shared
            let request = URLRequest(url: candidate, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)

            // 2. Session's own disk cache
            if let cachedResponse = session.configuration.urlCache?.cachedResponse(for: request),
               let downsampled = await downsample(data: cachedResponse.data, maxDimension: maxDimension) {
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
                guard let downsampled = await downsample(data: data, maxDimension: maxDimension) else {
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

    // Efficient Downsampling using ImageIO on a detached cooperative task
    private func downsample(data: Data, maxDimension: CGFloat) async -> DecodedImage? {
        await Task.detached(priority: .userInitiated) {
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
    }
}

class ImageSession {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 64 * 1024 * 1024,  // 64 MB memory
                                   diskCapacity: 512 * 1024 * 1024,   // 512 MB disk
                                   diskPath: "FluxImageCache")
        return URLSession(configuration: config)
    }()
}

final class ImageInMemoryCache {
    static let shared: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 600
        cache.totalCostLimit = 256 * 1024 * 1024  // 256 MB of decoded pixels in memory
        return cache
    }()

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
