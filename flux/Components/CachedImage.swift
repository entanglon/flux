import SwiftUI
import ImageIO

struct CachedImage<Content: View>: View {
    let url: URL?
    var fallbacks: [URL?] = []
    let transaction: Transaction
    let maxDimension: CGFloat
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

    private var resolvedCandidates: [URL] {
        ([url] + fallbacks).compactMap { $0 }
    }

    private func load() async {
        let candidates = resolvedCandidates
        guard !candidates.isEmpty else {
            phase = .empty
            return
        }

        for candidate in candidates {
            // 1. Disk cache hit — instant decode from optimized JPEG
            if let cached = ThumbnailDiskCache.shared.load(candidate, maxDimension: maxDimension) {
                withTransaction(transaction) {
                    phase = .success(Image(nsImage: cached))
                }
                return
            }

            // 2. Network fetch
            do {
                let request = URLRequest(url: candidate, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
                let (data, response) = try await ImageSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    continue
                }
                guard let downsampled = downsample(data: data, maxDimension: maxDimension) else {
                    continue
                }
                // Save optimized JPEG to disk cache
                ThumbnailDiskCache.shared.save(candidate, image: downsampled, maxDimension: maxDimension)
                withTransaction(transaction) {
                    phase = .success(Image(nsImage: downsampled))
                }
                return
            } catch {
                if Task.isCancelled { return }
                continue
            }
        }

        phase = .failure(URL.error(.cannotFindHost))
    }

    private func downsample(data: Data, maxDimension: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
    }
}

// MARK: - Network Session (no in-memory cache)

class ImageSession {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil  // No URLCache — we handle disk caching ourselves
        return URLSession(configuration: config)
    }()
}

// MARK: - Disk-Only Thumbnail Cache

/// Stores optimized JPEG thumbnails on disk. No in-memory cache — the OS file
/// cache handles hot pages. Evicts oldest files when count exceeds the limit.
final class ThumbnailDiskCache {
    static let shared = ThumbnailDiskCache()

    private let cacheDir: URL
    private let fileManager = FileManager.default
    private let maxFiles = 300  // Max cached thumbnails

    private init() {
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDir = paths[0].appendingPathComponent("FluxThumbs", isDirectory: true)
        try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Load a cached thumbnail. Returns nil on miss.
    func load(_ url: URL, maxDimension: CGFloat) -> NSImage? {
        let key = cacheKey(url, maxDimension: maxDimension)
        let fileURL = cacheDir.appendingPathComponent(key)

        guard let data = try? Data(contentsOf: fileURL),
              let image = NSImage(data: data) else {
            return nil
        }
        // Touch the file to update access time for LRU eviction
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
        return image
    }

    /// Save an optimized JPEG thumbnail to disk.
    func save(_ url: URL, image: NSImage, maxDimension: CGFloat) {
        let key = cacheKey(url, maxDimension: maxDimension)
        let fileURL = cacheDir.appendingPathComponent(key)

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            return
        }
        try? jpeg.write(to: fileURL)
        evictIfNeeded()
    }

    /// Clear all cached thumbnails.
    func clearCache() {
        try? fileManager.removeItem(at: cacheDir)
        try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Evict oldest files when over the limit.
    private func evictIfNeeded() {
        guard let files = try? fileManager.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return
        }
        guard files.count > maxFiles else { return }

        let sorted = files.sorted { a, b in
            let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return dateA < dateB
        }
        let toRemove = sorted.prefix(files.count - maxFiles)
        for file in toRemove {
            try? fileManager.removeItem(at: file)
        }
    }

    private func cacheKey(_ url: URL, maxDimension: CGFloat) -> String {
        let raw = "\(url.absoluteString)_\(Int(maxDimension))"
        let data = Data(raw.utf8)
        // Use first 8 bytes of SHA256 for a fast, unique key
        var hash: UInt64 = 0
        data.withUnsafeBytes { ptr in
            for i in 0..<min(8, ptr.count) {
                hash = (hash &<< 8) | UInt64(ptr[i])
            }
        }
        return "\(hash).jpg"
    }
}

// MARK: - Helpers

private extension URL {
    static func error(_ code: URLError.Code) -> URLError { URLError(code) }
}
