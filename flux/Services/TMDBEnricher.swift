#if os(macOS)
import AppKit
#endif

class TMDBEnricher {
    static let shared = TMDBEnricher()
    
    private let baseURL = "https://api.themoviedb.org/3"
    
    // MARK: - Caching Layer
    // These methods are called from task groups, so cache access must be
    // synchronized as well as bounded. Metadata is cheap to re-fetch compared
    // with retaining every catalogue item for the full app lifetime.
    private struct CacheEntry<Value> {
        let value: Value
        var lastAccessed: Date
    }
    private let cacheLock = NSLock()
    private var itemCache: [String: CacheEntry<MediaItem>] = [:]
    private var imdbIDCache: [String: CacheEntry<String>] = [:]
    private var newEpisodeCache: [String: CacheEntry<Bool>] = [:]
    private let itemCacheLimit = 150
    private let idCacheLimit = 500
    private let itemCacheTTL: TimeInterval = 2 * 60 * 60
    private let idCacheTTL: TimeInterval = 24 * 60 * 60
    
    // MARK: - Adaptive Resolution
    enum ImageQuality {
        case poster      // w780
        case backdrop    // w1280
        case original    // 4K/Original
        case automatic   // Screen-aware
    }
    
    func adaptiveURL(path: String?, quality: ImageQuality) -> URL? {
        guard let path = path else { return nil }
        let size: String
        switch quality {
        case .poster: size = "w780"
        case .backdrop: size = "w1280"
        case .original: size = "original"
        case .automatic:
            #if os(macOS)
            let screen = NSScreen.main
            let scale = screen?.backingScaleFactor ?? 1.0
            let physicalWidth = (screen?.frame.width ?? 1920) * scale
            // If physical width is > 2000, we prioritize Original/4K quality
            size = physicalWidth > 2000 ? "original" : "w1280"
            #else
            size = "w1280"
            #endif
        }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }
    
    private var apiKey: String {
        let key = UserDefaults.standard.string(forKey: "tmdbApiKey") ?? ""
        return key.isEmpty ? Secrets.tmdbAPIKey : key
    }

    /// Whether a TMDB key is available. Flux is Cinemeta-first and ships with no
    /// key; TMDB is an optional enhancement a user can enable in Settings. When
    /// absent, enrichment is skipped and Cinemeta data is used as-is.
    var hasKey: Bool { !apiKey.isEmpty }

    private init() {}
    
    // MARK: - ID Translation
    func resolveTmdbID(imdbID: String, type: String) async -> String? {
        let mediaType = type.contains("movie") ? "movie" : "tv"
        let findURL = "\(baseURL)/find/\(imdbID)?api_key=\(apiKey)&external_source=imdb_id"
        
        guard let url = URL(string: findURL),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(TMDBFindResponse.self, from: data) else { return nil }
        
        if mediaType == "movie" {
            return response.movie_results.first.map { String($0.id) }
        } else {
            return response.tv_results.first.map { String($0.id) }
        }
    }
    
    func getImdbID(tmdbID: String, type: String) async -> String? {
        let mediaType = type.contains("movie") ? "movie" : "tv"
        let cacheKey = "\(mediaType):\(tmdbID)"
        if let cached = cachedIMDbID(for: cacheKey) { return cached }

        let urlString = "\(baseURL)/\(mediaType)/\(tmdbID)/external_ids?api_key=\(apiKey)"

        guard let url = URL(string: urlString) else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(ExternalIDsResponse.self, from: data)
            if let imdbID = response.imdb_id {
                storeIMDbID(imdbID, for: cacheKey)
            }
            return response.imdb_id
        } catch {
            return nil
        }
    }
    
    // MARK: - Built-Upon-Enriched Logic

    /// Quick enrichment for catalog carousels
    func quickEnrich(_ item: MediaItem) async -> MediaItem {
        guard hasKey else { return item }
        if let cached = cachedItem(for: item.id) { return cached }
        
        var enriched = item
        let type = item.category.lowercased().contains("tv") || item.category.lowercased().contains("series") ? "tv" : "movie"
        
        // 1. Resolve TMDB ID
        let tmdbIDString = item.id.starts(with: "tt") ? await resolveTmdbID(imdbID: item.id, type: type) : item.id
        guard let id = tmdbIDString else { return item }
        
        // 2. Fetch basic metadata
        let urlString = "\(baseURL)/\(type)/\(id)?api_key=\(apiKey)"
        guard let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return item }
        
        await MainActor.run {
            if let backdropPath = json["backdrop_path"] as? String {
                enriched.backdropURL = adaptiveURL(path: backdropPath, quality: .backdrop)
                enriched.heroURL = adaptiveURL(path: backdropPath, quality: .automatic)
            }
            if let posterPath = json["poster_path"] as? String {
                enriched.posterURL = adaptiveURL(path: posterPath, quality: .poster)
            }
            if let popularity = json["popularity"] as? Double {
                enriched.popularity = popularity
            }
            if let overview = json["overview"] as? String, enriched.description.isEmpty {
                enriched.description = overview
            }
        }
        
        storeItem(enriched, for: item.id)
        return enriched
    }

    /// Full enrichment for DetailView
    func fullEnrich(_ item: MediaItem) async -> MediaItem {
        guard hasKey else { return item }
        var enriched = await quickEnrich(item)
        
        // Preserve essential metadata from the source (Cinemeta/Addon)
        enriched.episodes = item.episodes
        enriched.seasons = item.seasons
        
        let type = enriched.category.lowercased().contains("tv") || enriched.category.lowercased().contains("series") ? "tv" : "movie"
        
        let tmdbIDString = item.id.starts(with: "tt") ? await resolveTmdbID(imdbID: item.id, type: type) : item.id
        guard let id = tmdbIDString else { return enriched }
        
        let currentBaseURL = self.baseURL
        let currentAPIKey = self.apiKey

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                let urlString = "\(currentBaseURL)/\(type)/\(id)?api_key=\(currentAPIKey)"
                if let url = URL(string: urlString),
                   let (data, _) = try? await URLSession.shared.data(from: url),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let backdropPath = json["backdrop_path"] as? String {
                    await MainActor.run {
                        enriched.backdropURL = self.adaptiveURL(path: backdropPath, quality: .automatic)
                        enriched.heroURL = enriched.backdropURL
                    }
                }
            }
            
            group.addTask {
                if let credits = await self.fetchCredits(id: id, type: type) {
                    await MainActor.run {
                        enriched.cast = credits.cast.prefix(15).map { cast in
                            CastMember(name: cast.name, role: cast.character, imageURL: self.adaptiveURL(path: cast.profilePath, quality: .poster), personID: cast.id)
                        }
                    }
                }
            }
            
            group.addTask {
                if let response = await self.fetchWatchProviders(id: id, type: type) {
                    let region = response.results["US"] ?? response.results.first?.value
                    let items = (region?.flatrate ?? []) + (region?.buy ?? []) + (region?.rent ?? [])
                    if !items.isEmpty {
                        await MainActor.run {
                            enriched.watchProviders = items.map { WatchProvider(name: $0.provider_name, logoURL: self.adaptiveURL(path: $0.logo_path, quality: .poster), displayPriority: 0) }
                        }
                    }
                }
            }
        }
        
        storeItem(enriched, for: item.id)
        return enriched
    }

    private func cachedItem(for key: String) -> MediaItem? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard var entry = itemCache[key] else { return nil }
        guard Date().timeIntervalSince(entry.lastAccessed) < itemCacheTTL else {
            itemCache.removeValue(forKey: key)
            return nil
        }
        entry.lastAccessed = Date()
        itemCache[key] = entry
        return entry.value
    }

    private func storeItem(_ item: MediaItem, for key: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let now = Date()
        itemCache = itemCache.filter { now.timeIntervalSince($0.value.lastAccessed) < itemCacheTTL }
        if itemCache[key] == nil {
            trim(&itemCache, limit: itemCacheLimit)
        }
        itemCache[key] = CacheEntry(value: item, lastAccessed: now)
    }

    private func cachedIMDbID(for key: String) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard var entry = imdbIDCache[key] else { return nil }
        guard Date().timeIntervalSince(entry.lastAccessed) < idCacheTTL else {
            imdbIDCache.removeValue(forKey: key)
            return nil
        }
        entry.lastAccessed = Date()
        imdbIDCache[key] = entry
        return entry.value
    }

    private func storeIMDbID(_ imdbID: String, for key: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let now = Date()
        imdbIDCache = imdbIDCache.filter { now.timeIntervalSince($0.value.lastAccessed) < idCacheTTL }
        if imdbIDCache[key] == nil {
            trim(&imdbIDCache, limit: idCacheLimit)
        }
        imdbIDCache[key] = CacheEntry(value: imdbID, lastAccessed: now)
    }

    private func trim<Value>(_ cache: inout [String: CacheEntry<Value>], limit: Int) {
        while cache.count >= limit,
              let leastRecentKey = cache.min(by: { $0.value.lastAccessed < $1.value.lastAccessed })?.key {
            cache.removeValue(forKey: leastRecentKey)
        }
    }
    
    // MARK: - Specific Asset Fetching
    func fetchEpisodeStill(tmdbID: String, season: Int, episode: Int) async -> URL? {
        let urlString = "\(baseURL)/tv/\(tmdbID)/season/\(season)/episode/\(episode)?api_key=\(apiKey)"
        guard let url = URL(string: urlString), 
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(TMDBEpisodeDetail.self, from: data) else { return nil }
        
        return adaptiveURL(path: response.still_path, quality: .backdrop)
    }
    
    func fetchSeasonEnrichment(tvId: String, seasonNumber: Int) async -> [Int: String] {
        let urlString = "\(baseURL)/tv/\(tvId)/season/\(seasonNumber)?api_key=\(apiKey)"
        guard let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(TMDBSeasonResponse.self, from: data) else { return [:] }
        
        var overviews: [Int: String] = [:]
        for episode in response.episodes {
            overviews[episode.episode_number] = episode.overview
        }
        return overviews
    }
    
    // MARK: - Catalog Fetching (Flux Discovery Layer)
    func fetchTrendingAll() async throws -> [MediaItem] {
        let urlString = "\(baseURL)/trending/all/week?api_key=\(apiKey)"
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let (data, _) = try await URLSession.shared.data(from: url)
        
        let response = try JSONDecoder().decode(TMDBTrendingResponse.self, from: data)
        let results = response.results.compactMap { $0.toMediaItem() }
        
        // Apply Freshness Filter: Only 2024+ content for the main Hero
        return results.filter { item in
            guard let date = item.releaseDate, !date.isEmpty else { return true }
            return date >= "2024-01-01"
        }
    }
    func fetchTrending(type: String) async throws -> [MediaItem] {
        let mediaType = type.contains("movie") ? "movie" : "tv"
        let urlString = "\(baseURL)/trending/\(mediaType)/week?api_key=\(apiKey)"
        return try await fetchCatalog(from: urlString, type: mediaType)
    }

    func fetchPopular(type: String) async throws -> [MediaItem] {
        let mediaType = type.contains("movie") ? "movie" : "tv"
        let urlString = "\(baseURL)/\(mediaType)/popular?api_key=\(apiKey)"
        return try await fetchCatalog(from: urlString, type: mediaType)
    }

    func fetchTopRated(type: String) async throws -> [MediaItem] {
        let mediaType = type.contains("movie") ? "movie" : "tv"
        let urlString = "\(baseURL)/\(mediaType)/top_rated?api_key=\(apiKey)"
        return try await fetchCatalog(from: urlString, type: mediaType)
    }

    /// TMDB discover by genre — real genre-accurate titles, page-based pagination
    /// (pages 1..500). Used by the genre pages for endless scroll.
    func fetchGenrePage(tmdbGenreID: Int, page: Int, mediaType: String = "movie") async -> [MediaItem] {
        let urlString = "\(baseURL)/discover/\(mediaType)?api_key=\(apiKey)&with_genres=\(tmdbGenreID)&page=\(page)&sort_by=popularity.desc&include_adult=false&vote_count.gte=50"
        return (try? await fetchCatalog(from: urlString, type: mediaType)) ?? []
    }

    /// OTT platform catalogs via TMDB watch providers — always fresh, unlike the
    /// stale third-party Streaming Catalogs addon. Maps our platform codes to
    /// TMDB provider IDs (US region) and queries /discover with
    /// `with_watch_providers`. Returns popularity-sorted results.
    static let tmdbProviderIDs: [String: Int] = [
        "nfx": 8,      // Netflix
        "dnp": 337,    // Disney+
        "amp": 9,      // Prime Video
        "atp": 350,    // Apple TV+
        "hbm": 1899,   // Max (HBO Max)
        "hlu": 15,     // Hulu
        "pcp": 386,    // Peacock
        "pmp": 531,    // Paramount+
        "cru": 1112,   // Crunchyroll
    ]

    func fetchWatchProviderCatalog(platformID: String, type: String) async -> [MediaItem] {
        guard hasKey, let providerID = Self.tmdbProviderIDs[platformID] else { return [] }
        let mediaType = type == "series" ? "tv" : "movie"
        let urlString = "\(baseURL)/discover/\(mediaType)?api_key=\(apiKey)&with_watch_providers=\(providerID)&watch_region=US&sort_by=popularity.desc&include_adult=false&vote_count.gte=50"
        return (try? await fetchCatalog(from: urlString, type: mediaType)) ?? []
    }

    func fetchUpcomingMovies() async throws -> [MediaItem] {        // /movie/upcoming mixes in titles whose PRIMARY date already passed
        // (earlier foreign release), which breaks unreleased-only filtering.
        // discover with primary_release_date.gte=today guarantees genuinely
        // unreleased, popularity-sorted results.
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let today = fmt.string(from: Date())
        let discoverURL = "\(baseURL)/discover/movie?api_key=\(apiKey)&primary_release_date.gte=\(today)&sort_by=popularity.desc&include_adult=false"
        let items = try await fetchCatalog(from: discoverURL, type: "movie")
        if !items.isEmpty { return items }
        return try await fetchCatalog(from: "\(baseURL)/movie/upcoming?api_key=\(apiKey)", type: "movie")
    }

    func fetchLatestMovies() async throws -> [MediaItem] {
        let urlString = "\(baseURL)/movie/now_playing?api_key=\(apiKey)"
        return try await fetchCatalog(from: urlString, type: "movie")
    }
    
    func fetchLatestTV() async throws -> [MediaItem] {
        let urlString = "\(baseURL)/tv/on_the_air?api_key=\(apiKey)"
        return try await fetchCatalog(from: urlString, type: "tv")
    }

    func fetchSimilar(item: MediaItem) async -> [MediaItem] {
        let type = item.category == "TV Show" || item.category == "Series" ? "tv" : "movie"
        let tmdbID = item.id.starts(with: "tt") ? await resolveTmdbID(imdbID: item.id, type: type) : item.id
        guard let id = tmdbID else { return [] }
        
        let recURL = "\(baseURL)/\(type)/\(id)/recommendations?api_key=\(apiKey)"
        if let items = try? await fetchCatalog(from: recURL, type: type), !items.isEmpty {
            return items
        }
        
        let simURL = "\(baseURL)/\(type)/\(id)/similar?api_key=\(apiKey)"
        if let items = try? await fetchCatalog(from: simURL, type: type), !items.isEmpty {
            return items
        }
        
        return []
    }

    /// Returns the best YouTube trailer URL for a title, or nil if none.
    /// Prefers an official "Trailer"; falls back to any YouTube trailer/teaser.
    func fetchTrailerURL(item: MediaItem) async -> URL? {
        guard hasKey else { return nil }
        let type = item.category == "TV Show" || item.category == "Series" ? "tv" : "movie"
        let tmdbID = item.id.starts(with: "tt") ? await resolveTmdbID(imdbID: item.id, type: type) : item.id
        guard let id = tmdbID else { return nil }

        let videosURL = "\(baseURL)/\(type)/\(id)/videos?api_key=\(apiKey)"
        guard let url = URL(string: videosURL),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(TMDBVideoResponse.self, from: data) else {
            return nil
        }

        let youtube = response.results.filter { $0.site == "YouTube" }
        let best = youtube.first { $0.type == "Trailer" }
            ?? youtube.first { $0.type == "Teaser" }
            ?? youtube.first
        return best?.youtubeURL
    }

    // Generic Internal Fetcher
    private func fetchCatalog(from urlString: String, type mediaType: String) async throws -> [MediaItem] {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let (data, _) = try await URLSession.shared.data(from: url)
        
        if mediaType == "movie" {
            let response = try JSONDecoder().decode(TMDBResponse<TMDBMovie>.self, from: data)
            return response.results.map { $0.toMediaItem() }.filter { $0.isReleased }
        } else {
            let response = try JSONDecoder().decode(TMDBResponse<TMDBTVShow>.self, from: data)
            return response.results.map { $0.toMediaItem() }.filter { $0.isReleased }
        }
    }
    
    // MARK: - Helper API Calls
    private func fetchCredits(id: String, type: String) async -> TMDBCredits? {
        let urlString = "\(baseURL)/\(type)/\(id)/credits?api_key=\(apiKey)"
        guard let url = URL(string: urlString), let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return try? JSONDecoder().decode(TMDBCredits.self, from: data)
    }

    // MARK: - New Episode Detection

    /// True when the show's most recent episode aired within the last 7 days.
    /// Cached 6h — watchlist cards call this per render.
    func hasAiredNewEpisode(tmdbID: String) async -> Bool {
        cacheLock.lock()
        if var cached = newEpisodeCache[tmdbID],
           Date().timeIntervalSince(cached.lastAccessed) < 6 * 3600 {
            cached.lastAccessed = Date()
            newEpisodeCache[tmdbID] = cached
            cacheLock.unlock()
            return cached.value
        }
        newEpisodeCache.removeValue(forKey: tmdbID)
        cacheLock.unlock()
        let urlString = "\(baseURL)/tv/\(tmdbID)?api_key=\(apiKey)"
        var fresh = false
        if let url = URL(string: urlString),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let show = try? JSONDecoder().decode(TMDBLastEpisodeInfo.self, from: data),
           let airDateStr = show.lastEpisodeToAir?.airDate, !airDateStr.isEmpty {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            if let airDate = fmt.date(from: airDateStr) {
                let days = Date().timeIntervalSince(airDate) / 86400
                fresh = days >= 0 && days <= 7
            }
        }
        cacheLock.lock()
        if newEpisodeCache[tmdbID] == nil {
            trim(&newEpisodeCache, limit: idCacheLimit)
        }
        newEpisodeCache[tmdbID] = CacheEntry(value: fresh, lastAccessed: Date())
        cacheLock.unlock()
        return fresh
    }

    // MARK: - Person Pages

    func fetchPerson(personID: Int) async -> TMDBPersonDetail? {
        let urlString = "\(baseURL)/person/\(personID)?api_key=\(apiKey)"
        guard let url = URL(string: urlString), let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return try? JSONDecoder().decode(TMDBPersonDetail.self, from: data)
    }

    /// Combined movie+TV credits for a person, mapped to MediaItems (sorted newest first).
    func fetchPersonCredits(personID: Int) async -> [MediaItem] {
        let urlString = "\(baseURL)/person/\(personID)/combined_credits?api_key=\(apiKey)"
        guard let url = URL(string: urlString), let (data, _) = try? await URLSession.shared.data(from: url) else { return [] }
        guard let response = try? JSONDecoder().decode(TMDBCombinedCredits.self, from: data) else { return [] }

        let items = response.cast.compactMap { credit -> MediaItem? in
            guard let id = credit.id else { return nil }
            let isMovie = credit.mediaType == "movie"
            let title = isMovie ? (credit.title ?? credit.name ?? "") : (credit.name ?? credit.title ?? "")
            guard !title.isEmpty else { return nil }

            var item = MediaItem(
                seed: String(id), title: title,
                category: isMovie ? "Movie" : "TV Show"
            )
            item.posterURL = adaptiveURL(path: credit.posterPath, quality: .poster)
            item.backdropURL = adaptiveURL(path: credit.backdropPath, quality: .backdrop)
            item.imageURL = item.backdropURL ?? item.posterURL
            item.voteAverage = credit.voteAverage
            item.releaseDate = isMovie ? credit.releaseDate : credit.firstAirDate
            item.description = credit.overview ?? ""
            item.popularity = credit.popularity
            return item
        }

        // Newest first (undated titles sink), then by popularity
        return items.sorted {
            let d1 = $0.releaseDate ?? "0000"
            let d2 = $1.releaseDate ?? "0000"
            if d1 != d2 { return d1 > d2 }
            return ($0.popularity ?? 0) > ($1.popularity ?? 0)
        }
    }
    
    private func fetchWatchProviders(id: String, type: String) async -> TMDBWatchProviderResponse? {
        let urlString = "\(baseURL)/\(type)/\(id)/watch/providers?api_key=\(apiKey)"
        guard let url = URL(string: urlString), let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return try? JSONDecoder().decode(TMDBWatchProviderResponse.self, from: data)
    }
}

// MARK: - Internal Helper Models
struct ExternalIDsResponse: Codable {
    let imdb_id: String?
}

struct TMDBFindResponse: Codable {
    let movie_results: [TMDBMovieResult]
    let tv_results: [TMDBTVResult]
}

struct TMDBMovieResult: Codable {
    let id: Int
}

struct TMDBTVResult: Codable {
    let id: Int
}

struct TMDBSeasonResponse: Codable {
    let episodes: [TMDBEpisodeDetail]
}

struct TMDBEpisodeDetail: Codable {
    let episode_number: Int
    let name: String
    let overview: String
    let still_path: String?
}
