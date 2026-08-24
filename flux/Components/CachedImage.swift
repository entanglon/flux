import SwiftUI
import ImageIO

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
            phase = .empty
            return
        }

        // Walk the ladder: first candidate that produces a decoded image wins.
        // A dead CDN, 404, or corrupt cache entry falls through to the next URL.
        for candidate in candidates {
            let nsURL = candidate as NSURL

            // 1. In-memory NSCache (instant)
            if let cachedNSImage = ImageInMemoryCache.shared.object(forKey: nsURL) {
                phase = .success(Image(nsImage: cachedNSImage))
                return
            }

            let session = ImageSession.shared
            let request = URLRequest(url: candidate, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)

            // 2. Session's own disk cache (NOT URLCache.shared — that's a different
            //    cache and can hold stale redirect/HTML responses that fail decode).
            if let cachedResponse = session.configuration.urlCache?.cachedResponse(for: request),
               let downsampled = downsample(data: cachedResponse.data, maxDimension: maxDimension) {
                ImageInMemoryCache.shared.setObject(downsampled, forKey: nsURL)
                withTransaction(transaction) {
                    phase = .success(Image(nsImage: downsampled))
                }
                return
            }

            // 3. Network
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    continue // dead URL — try the next candidate
                }
                guard let downsampled = downsample(data: data, maxDimension: maxDimension) else {
                    continue // undecodable — try the next candidate
                }
                ImageInMemoryCache.shared.setObject(downsampled, forKey: nsURL)
                withTransaction(transaction) {
                    phase = .success(Image(nsImage: downsampled))
                }
                return
            } catch {
                if Task.isCancelled { return }
                continue
            }
        }

        phase = .failure(URLError(.cannotFindHost))
    }

    // Efficient Downsampling using ImageIO
    private func downsample(data: Data, maxDimension: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        // Convert to NSImage
        return NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
    }
}

class ImageSession {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 256 * 1024 * 1024, // 256 MB memory (Increased)
                                   diskCapacity: 1024 * 1024 * 1024,  // 1 GB disk (Increased)
                                   diskPath: "FluxImageCache")
        return URLSession(configuration: config)
    }()
}

final class ImageInMemoryCache {
    static let shared = NSCache<NSURL, NSImage>()
}
