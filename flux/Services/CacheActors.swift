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

/// Swift actor managing thread-safe and disk-persisted stream caches.
actor StreamCacheActor {
    private struct CacheEntry: Codable {
        let streams: [Stream]
        let timestamp: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private let ttl: TimeInterval
    private let maxEntries: Int
    private let diskURL: URL?

    init(ttl: TimeInterval = 24 * 3600, maxEntries: Int = 200) {
        self.ttl = ttl
        self.maxEntries = maxEntries
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        self.diskURL = dir?.appendingPathComponent("flux_streams_cache_v2.json")
        // v2: drops v1 entries (pre-infoHash, possibly addon-partial) so every
        // title gets one clean refetch under the new parsing rules.
        if let dir {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("flux_streams_cache.json"))
        }
        self.loadFromDisk()
    }

    private func loadFromDisk() {
        guard let url = diskURL, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: data) else { return }
        let now = Date()
        // Drop expired AND empty entries: a single fully-failed fetch must never
        // poison a title (autoplay reads cache without forceRefresh while the
        // manual picker bypasses it — the exact "no streams yet picker works" split).
        self.cache = decoded.filter { now.timeIntervalSince($0.value.timestamp) < ttl && !$0.value.streams.isEmpty }
    }

    private func saveToDisk() {
        guard let url = diskURL, let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func get(key: String) -> [Stream]? {
        guard let entry = cache[key] else { return nil }
        // Empty entries are cache poison (see loadFromDisk): treat as a miss so
        // already-poisoned titles self-heal on next read instead of erroring.
        if entry.streams.isEmpty || Date().timeIntervalSince(entry.timestamp) > ttl {
            cache.removeValue(forKey: key)
            saveToDisk()
            return nil
        }
        return entry.streams
    }

    func set(key: String, streams: [Stream]) {
        // Never store empty results: a transient all-addon failure would otherwise
        // persist as "No streams" for the full TTL (autoplay trusts cache).
        guard !streams.isEmpty else { return }
        if cache.count >= maxEntries {
            let sorted = cache.sorted { $0.value.timestamp < $1.value.timestamp }
            for (k, _) in sorted.prefix(maxEntries / 4) {
                cache.removeValue(forKey: k)
            }
        }
        cache[key] = CacheEntry(streams: streams, timestamp: Date())
        saveToDisk()
    }

    func clear() {
        cache.removeAll()
        if let url = diskURL {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
