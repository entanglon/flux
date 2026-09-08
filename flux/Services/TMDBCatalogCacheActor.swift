import Foundation

/// Thread-safe in-memory cache for TMDB discovery catalogs.
/// Prevents redundant network requests across Home, Movies, and TV Shows tabs
/// with TTL expiration per endpoint category.
actor TMDBCatalogCacheActor {
    static let shared = TMDBCatalogCacheActor()
    
    private struct CacheEntry {
        let items: [MediaItem]
        let expiry: Date
    }
    
    private var cache: [String: CacheEntry] = [:]
    
    /// Default TTL presets
    enum TTLPreset {
        case trendingDay    // 1 hour
        case trendingWeek   // 6 hours
        case nowPlaying     // 4 hours
        case upcoming       // 4 hours
        case airingToday    // 4 hours
        case popular        // 12 hours
        case topRated       // 24 hours
        case discover       // 6 hours
        case custom(TimeInterval)
        
        var interval: TimeInterval {
            switch self {
            case .trendingDay: return 1800       // 30 min
            case .trendingWeek: return 7200      // 2 hours
            case .nowPlaying: return 7200        // 2 hours
            case .upcoming: return 7200          // 2 hours
            case .airingToday: return 7200       // 2 hours
            case .popular: return 14400          // 4 hours
            case .topRated: return 28800         // 8 hours
            case .discover: return 7200          // 2 hours
            case .custom(let seconds): return seconds
            }
        }
    }
    
    func get(key: String) -> [MediaItem]? {
        guard let entry = cache[key] else { return nil }
        if Date() > entry.expiry {
            cache.removeValue(forKey: key)
            return nil
        }
        return entry.items
    }
    
    func set(key: String, items: [MediaItem], ttl: TTLPreset) {
        let expiry = Date().addingTimeInterval(ttl.interval)
        cache[key] = CacheEntry(items: items, expiry: expiry)
    }
    
    func clear() {
        cache.removeAll()
    }
}
