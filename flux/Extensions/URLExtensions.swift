import Foundation

extension URL {
    /// Upgrades common metadata URLs (TMDB, Metahub) to FHD+ (High Definition) quality.
    func highQuality() -> URL {
        var urlString = self.absoluteString
        
        // 1. TMDB Upgrades (w500/w780 -> w1280)
        // w1280 is FHD+ and usually the best quality for backdrops without being 4K.
        if urlString.contains("image.tmdb.org/t/p/") {
            let sizes = ["/w300/", "/w500/", "/w780/", "/w1280/"]
            for size in sizes {
                if urlString.contains(size) {
                    urlString = urlString.replacingOccurrences(of: size, with: "/original/")
                    break
                }
            }
            // If it's the "original" size, we keep it as is or could force 1280 to save BW.
            // But usually users want the best.
        }
        
        // 2. Metahub Upgrades (small/medium -> large)
        if urlString.contains("images.metahub.space") {
            urlString = urlString.replacingOccurrences(of: "/small/", with: "/large/")
            urlString = urlString.replacingOccurrences(of: "/medium/", with: "/large/")
        }
        
        return URL(string: urlString) ?? self
    }
}
