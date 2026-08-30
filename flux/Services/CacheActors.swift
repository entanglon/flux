import Foundation

/// Swift actor managing in-memory bounded LRU cache for TMDB metadata and ID resolutions.
/// Guarantees compile-time data race safety without POSIX locks.
actor TMDBMemoryCacheActor {
    private struct CacheEntry<Value> {
        let value: Value
        var lastAccessed: Date
    }

    private var itemCache: [String: CacheEntry<MediaItem>] = [:]
    private var imdbIDCache: [String: CacheEntry<String>] = [:]
    private var newEpisodeCache: [String: CacheEntry<Bool>] = [:]

    private let itemCacheLimit: Int
    private let idCacheLimit: Int
    private let itemCacheTTL: TimeInterval
    private let idCacheTTL: TimeInterval

    init(
        itemCacheLimit: Int = 150,
        idCacheLimit: Int = 500,
        itemCacheTTL: TimeInterval = 2 * 60 * 60,
        idCacheTTL: TimeInterval = 24 * 60 * 60
    ) {
        self.itemCacheLimit = itemCacheLimit
        self.idCacheLimit = idCacheLimit
        self.itemCacheTTL = itemCacheTTL
        self.idCacheTTL = idCacheTTL
    }

    // MARK: - MediaItem Cache

    func getItem(for key: String) -> MediaItem? {
        guard var entry = itemCache[key] else { return nil }
        if Date().timeIntervalSince(entry.lastAccessed) > itemCacheTTL {
            itemCache.removeValue(forKey: key)
            return nil
        }
        entry.lastAccessed = Date()
        itemCache[key] = entry
        return entry.value
    }

    func storeItem(_ item: MediaItem, for key: String) {
        if itemCache[key] == nil {
            trim(&itemCache, limit: itemCacheLimit)
        }
        itemCache[key] = CacheEntry(value: item, lastAccessed: Date())
    }

    // MARK: - IMDb ID Cache

    func getIMDbID(for key: String) -> String? {
        guard var entry = imdbIDCache[key] else { return nil }
        if Date().timeIntervalSince(entry.lastAccessed) > idCacheTTL {
            imdbIDCache.removeValue(forKey: key)
            return nil
        }
        entry.lastAccessed = Date()
        imdbIDCache[key] = entry
        return entry.value
    }

    func storeIMDbID(_ id: String, for key: String) {
        if imdbIDCache[key] == nil {
            trim(&imdbIDCache, limit: idCacheLimit)
        }
        imdbIDCache[key] = CacheEntry(value: id, lastAccessed: Date())
    }

    // MARK: - New Episode Cache

    func getNewEpisodeStatus(for key: String) -> Bool? {
        guard var entry = newEpisodeCache[key] else { return nil }
        if Date().timeIntervalSince(entry.lastAccessed) > 6 * 3600 {
            newEpisodeCache.removeValue(forKey: key)
            return nil
        }
        entry.lastAccessed = Date()
        newEpisodeCache[key] = entry
        return entry.value
    }

    func storeNewEpisodeStatus(_ fresh: Bool, for key: String) {
        if newEpisodeCache[key] == nil {
            trim(&newEpisodeCache, limit: idCacheLimit)
        }
        newEpisodeCache[key] = CacheEntry(value: fresh, lastAccessed: Date())
    }

    func clear() {
        itemCache.removeAll()
        imdbIDCache.removeAll()
        newEpisodeCache.removeAll()
    }

    private func trim<T>(_ dict: inout [String: CacheEntry<T>], limit: Int) {
        guard dict.count >= limit else { return }
        let sorted = dict.sorted { $0.value.lastAccessed < $1.value.lastAccessed }
        let toRemove = max(1, limit / 4)
        for (k, _) in sorted.prefix(toRemove) {
            dict.removeValue(forKey: k)
        }
    }
}

/// Swift actor managing thread-safe stream caches.
actor StreamCacheActor {
    private struct CacheEntry {
        let streams: [Stream]
        let timestamp: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private let ttl: TimeInterval
    private let maxEntries: Int

    init(ttl: TimeInterval = 10 * 60, maxEntries: Int = 100) {
        self.ttl = ttl
        self.maxEntries = maxEntries
    }

    func get(key: String) -> [Stream]? {
        guard let entry = cache[key] else { return nil }
        if Date().timeIntervalSince(entry.timestamp) > ttl {
            cache.removeValue(forKey: key)
            return nil
        }
        return entry.streams
    }

    func set(key: String, streams: [Stream]) {
        if cache.count >= maxEntries {
            let sorted = cache.sorted { $0.value.timestamp < $1.value.timestamp }
            for (k, _) in sorted.prefix(maxEntries / 4) {
                cache.removeValue(forKey: k)
            }
        }
        cache[key] = CacheEntry(streams: streams, timestamp: Date())
    }

    func clear() {
        cache.removeAll()
    }
}
