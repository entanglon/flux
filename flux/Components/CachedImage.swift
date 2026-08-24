import SwiftUI
import ImageIO

struct CachedImage<Content: View>: View {
    let url: URL?
    let transaction: Transaction
    let maxDimension: CGFloat // Max size to decode
    @ViewBuilder let content: (AsyncImagePhase) -> Content
    
    @State private var phase: AsyncImagePhase = .empty
    
    init(url: URL?, maxDimension: CGFloat = 300, transaction: Transaction = Transaction(), @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.maxDimension = maxDimension
        self.transaction = transaction
        self.content = content
    }
    
    var body: some View {
        content(phase)
            .task(id: url) {
                await load()
            }
    }
    
    private func load() async {
        guard let url = url else {
            phase = .empty
            return
        }
        
        // 1. Try In-Memory NSCache (Instant 0ms retrieval)
        let nsURL = url as NSURL
        if let cachedNSImage = ImageInMemoryCache.shared.object(forKey: nsURL) {
            phase = .success(Image(nsImage: cachedNSImage))
            return
        }
        
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)
        let session = ImageSession.shared
        
        do {
            // 2. Try Disk/URLCache
            if let cached = URLCache.shared.cachedResponse(for: request) {
                if let downsampled = downsample(data: cached.data, maxDimension: maxDimension) {
                    ImageInMemoryCache.shared.setObject(downsampled, forKey: nsURL)
                    withTransaction(transaction) {
                        phase = .success(Image(nsImage: downsampled))
                    }
                    return
                }
            }
            
            // 3. Fetch Network
            let (data, _) = try await session.data(for: request)
            
            // 4. Downsample
            guard let downsampled = downsample(data: data, maxDimension: maxDimension) else {
                throw URLError(.cannotDecodeContentData)
            }
            
            ImageInMemoryCache.shared.setObject(downsampled, forKey: nsURL)
            withTransaction(transaction) {
                phase = .success(Image(nsImage: downsampled))
            }
            
        } catch {
            withTransaction(transaction) {
                phase = .failure(error)
            }
        }
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
