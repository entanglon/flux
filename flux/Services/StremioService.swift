import Foundation

// MARK: - Stremio Models
struct StremioCatalogResponse: Codable {
    let metas: [StremioMetaPreview]
}

struct StremioMetaResponse: Codable {
    let meta: StremioMetaDetail
}

struct StremioMetaPreview: Codable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let background: String?
    let logo: String?
    let description: String?
    let releaseInfo: String?
    let imdbRating: String?
    let genres: [String]?
    let country: String?
    let popularity: Double?
}

struct StremioVideo: Codable {
    let id: String
    let title: String?
    let name: String?
    let released: String? // "YYYY-MM-DD"
    let season: Int?
    let episode: Int?
    let thumbnail: String?
    let overview: String?
    let description: String?
}

struct StremioMetaDetail: Codable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let background: String?
    let logo: String?
    let description: String?
    let releaseInfo: String?
    let imdbRating: String?
    let runtime: String?
    let cast: [String]?
    let director: [String]?
    let writer: [String]?
    let country: String?
    let popularity: Double?
    let genres: [String]?
    let videos: [StremioVideo]?
}

class StremioService {
    static let shared = StremioService()
    
    // Cinemeta Addon URL (Default Stremio Meta and Catalog Addon)
    private let cinemetaURL = "https://v3-cinemeta.strem.io"

    // "Streaming Catalogs" community addon — per-OTT-platform catalogs. Each
    // catalog id is a platform code (nfx=Netflix, dnp=Disney+, amp=Prime Video…).
    private let ottCatalogBase = "https://7a82163c306e-stremio-netflix-catalog-addon.baby-beamup.club/bmZ4LGRucCxhbXAsYXRwLGhibSxwbXAsaGx1LHBjcCxuZmssY3RzLG1nbCxjcnUsaGF5LGNsdixnb3AsamhzLHplZSxubHosdmlsLHNzdCxjcGQsc3R6LGRwZSxtYmksdmlrLHNnbyxzb255bGl2Ojo6MTc2MTkyMTY1ODU5Mw%3D%3D"

    /// Fetch the catalog for a single OTT platform (movies or series). Prefers
    /// TMDB watch providers (always fresh, paginated) when a key is configured;
    /// falls back to the third-party Streaming Catalogs addon otherwise (single
    /// page only). Preserves the platform's native popularity order — we must
    /// not re-sort by IMDb rating.
    func fetchOTTCatalog(platformID: String, type: String, page: Int = 1) async throws -> [MediaItem] {
        if TMDBEnricher.shared.hasKey {
            let tmdbItems = await TMDBEnricher.shared.fetchWatchProviderCatalog(platformID: platformID, type: type, page: page)
            if !tmdbItems.isEmpty { return tmdbItems }
        }
        // Addon returns the full catalog in one request — only serve it on page 1.
        guard page == 1 else { return [] }
        guard AddonManager.shared.isCinemetaEnabled else { return [] }
        return try await fetchCatalog(type: type, id: platformID, baseURL: ottCatalogBase, preserveOrder: true)
    }

    private init() {}
    
    // MARK: - Catalogs Fetching
    func fetchCatalog(type: String, id: String, baseURL: String? = nil, sector: String? = nil, genre: String? = nil, search: String? = nil, skip: Int = 0, preserveOrder: Bool = true, skipEnrichment: Bool = false) async throws -> [MediaItem] {
        let base = baseURL ?? cinemetaURL
        var urlString = "\(base)/catalog/\(type)/\(id)"
        
        if let genre = genre, let encodedGenre = genre.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            urlString += "/genre=\(encodedGenre)"
        }
        
        if let search = search, !search.isEmpty, let encodedSearch = search.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            urlString += "/search=\(encodedSearch)"
        }
        if skip > 0 {
            urlString += "/skip=\(skip)"
        }
        urlString += ".json"
        
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        let catalogResponse = try JSONDecoder().decode(StremioCatalogResponse.self, from: data)
        let items = catalogResponse.metas.map { $0.toMediaItem() }
        
        // Skip TMDB enrichment when explicitly requested or when no TMDB key is available
        guard !skipEnrichment, TMDBEnricher.shared.hasKey else {
            return items
        }
        
        // Internal Enrichment: Process in parallel before returning
        var enrichedItems: [MediaItem] = []
        await withTaskGroup(of: MediaItem.self) { group in
            for item in items {
                group.addTask {
                    return await TMDBEnricher.shared.quickEnrich(item)
                }
            }
            for await enriched in group {
                enrichedItems.append(enriched)
            }
        }
        
        // Preserve catalog order from Cinemeta unless explicitly disabled
        if preserveOrder {
            // TaskGroup shuffles order — rebuild using original positions by matching IDs
            guard !enrichedItems.isEmpty else { return enrichedItems }
            var ordered: [MediaItem] = Array(repeating: enrichedItems[0], count: items.count)
            var lookup: [String: MediaItem] = [:]
            for e in enrichedItems { lookup[e.id] = e }
            for (i, orig) in items.enumerated() {
                if let match = lookup[orig.id] {
                    ordered[i] = match
                }
            }
            return ordered
        }
        return enrichedItems.sorted { ($0.popularity ?? 0) > ($1.popularity ?? 0) }
    }
    
    // MARK: - Meta Fetching
    func fetchMeta(type: String, id: String) async throws -> MediaItem {
        // Cinemeta metadata is only available when the Cinemeta addon is enabled.
        // When TMDB is the primary source, callers should use TMDBEnricher.fullEnrich() directly.
        guard AddonManager.shared.isCinemetaAvailableForMetadata else {
            throw URLError(.fileDoesNotExist)
        }
        
        let urlString = "\(cinemetaURL)/meta/\(type)/\(id).json"
        
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        let metaResponse = try JSONDecoder().decode(StremioMetaResponse.self, from: data)
        let rawItem = metaResponse.meta.toMediaItem()
        
        // Internal Full Enrichment: Cast, 4K Banners, Details
        return await TMDBEnricher.shared.fullEnrich(rawItem)
    }
    
    // Legacy API Maps (Translating old TMDB calls to Cinemeta catalogs)
    func fetchTrendingMovies() async throws -> [MediaItem] {
        return try await fetchCatalog(type: "movie", id: "top", preserveOrder: true)
    }
    func fetchPopularMovies() async throws -> [MediaItem] {
        return try await fetchCatalog(type: "movie", id: "top", preserveOrder: true)
    }
    // Cached Top Rated Pools for consistent pagination & instant delivery
    private var topRatedMoviesPool: [MediaItem] = []
    private var lastTopRatedMoviesFetch: Date?
    private var topRatedTVPool: [MediaItem] = []
    private var lastTopRatedTVFetch: Date?

    func fetchTopRatedMovies(page: Int = 1, pageSize: Int = 20) async throws -> [MediaItem] {
        let now = Date()
        if topRatedMoviesPool.isEmpty || now.timeIntervalSince(lastTopRatedMoviesFetch ?? .distantPast) > 1800 {
            async let p1 = fetchCatalog(type: "movie", id: "top", skip: 0, preserveOrder: false)
            async let p2 = fetchCatalog(type: "movie", id: "top", skip: 50, preserveOrder: false)
            async let p3 = fetchCatalog(type: "movie", id: "top", skip: 100, preserveOrder: false)
            async let p4 = fetchCatalog(type: "movie", id: "top", skip: 150, preserveOrder: false)
            
            let combined = ((try? await p1) ?? []) + ((try? await p2) ?? []) + ((try? await p3) ?? []) + ((try? await p4) ?? [])
            var seen = Set<String>()
            let unique = combined.filter { seen.insert($0.id).inserted }
            let filtered = unique.filter { ($0.voteAverage ?? 0) >= 8.0 }
                .sorted { ($0.voteAverage ?? 0) > ($1.voteAverage ?? 0) }
            topRatedMoviesPool = filtered
            lastTopRatedMoviesFetch = now
        }
        
        let startIndex = (page - 1) * pageSize
        guard startIndex < topRatedMoviesPool.count else { return [] }
        let endIndex = min(startIndex + pageSize, topRatedMoviesPool.count)
        return Array(topRatedMoviesPool[startIndex..<endIndex])
    }
    
    func fetchTopRatedMovies(skip: Int) async throws -> [MediaItem] {
        let page = (skip / 20) + 1
        return try await fetchTopRatedMovies(page: page, pageSize: 20)
    }
    
    func fetchTrendingTVShows() async throws -> [MediaItem] {
        return try await fetchCatalog(type: "series", id: "imdbRating", preserveOrder: true)
    }
    
    func fetchPopularTVShows(skip: Int = 0) async throws -> [MediaItem] {
        return try await fetchCatalog(type: "series", id: "top", skip: skip, preserveOrder: true)
    }
    
    func fetchTopRatedTVShows(page: Int = 1, pageSize: Int = 20) async throws -> [MediaItem] {
        let now = Date()
        if topRatedTVPool.isEmpty || now.timeIntervalSince(lastTopRatedTVFetch ?? .distantPast) > 1800 {
            async let p1 = fetchCatalog(type: "series", id: "top", skip: 0, preserveOrder: false)
            async let p2 = fetchCatalog(type: "series", id: "top", skip: 50, preserveOrder: false)
            async let p3 = fetchCatalog(type: "series", id: "top", skip: 100, preserveOrder: false)
            async let p4 = fetchCatalog(type: "series", id: "top", skip: 150, preserveOrder: false)
            
            let combined = ((try? await p1) ?? []) + ((try? await p2) ?? []) + ((try? await p3) ?? []) + ((try? await p4) ?? [])
            var seen = Set<String>()
            let unique = combined.filter { seen.insert($0.id).inserted }
            let filtered = unique.filter { ($0.voteAverage ?? 0) >= 8.2 }
                .sorted { ($0.voteAverage ?? 0) > ($1.voteAverage ?? 0) }
            topRatedTVPool = filtered
            lastTopRatedTVFetch = now
        }
        
        let startIndex = (page - 1) * pageSize
        guard startIndex < topRatedTVPool.count else { return [] }
        let endIndex = min(startIndex + pageSize, topRatedTVPool.count)
        return Array(topRatedTVPool[startIndex..<endIndex])
    }
    
    func fetchTopRatedTVShows(skip: Int) async throws -> [MediaItem] {
        let page = (skip / 20) + 1
        return try await fetchTopRatedTVShows(page: page, pageSize: 20)
    }
    func searchMulti(query: String) async throws -> (movies: [MediaItem], tvShows: [MediaItem]) {
        let addons = AddonManager.shared.enabledAddons
        var allMovies: [MediaItem] = []
        var allTVShows: [MediaItem] = []
        
        await withTaskGroup(of: (movies: [MediaItem], tvShows: [MediaItem]).self) { group in
            // Cinemeta search — only when Cinemeta is enabled (no TMDB key or enrichment disabled)
            if AddonManager.shared.isCinemetaEnabled {
                group.addTask {
                    let m = (try? await self.fetchCatalog(type: "movie", id: "top", search: query, skipEnrichment: true)) ?? []
                    let t = (try? await self.fetchCatalog(type: "series", id: "top", search: query, skipEnrichment: true)) ?? []
                    return (m, t)
                }
            }

            for addon in addons {
                guard let catalogs = addon.catalogs, !catalogs.isEmpty else { continue }
                
                // Get the first movie and series catalog for this addon to search against
                let movieCatalog = catalogs.first(where: { $0.type == "movie" })
                let tvCatalog = catalogs.first(where: { $0.type == "series" })
                
                group.addTask {
                    var m: [MediaItem] = []
                    var t: [MediaItem] = []
                    
                    if let movieCat = movieCatalog {
                        m = (try? await self.fetchCatalog(type: "movie", id: movieCat.id, baseURL: addon.url, search: query)) ?? []
                    }
                    if let tvCat = tvCatalog {
                        t = (try? await self.fetchCatalog(type: "series", id: tvCat.id, baseURL: addon.url, search: query)) ?? []
                    }
                    
                    return (m, t)
                }
            }
            
            for await result in group {
                allMovies.append(contentsOf: result.movies)
                allTVShows.append(contentsOf: result.tvShows)
            }
        }
        
        // Deduplicate and Sort
        let dedupedMovies = deduplicate(allMovies)
        let dedupedTV = deduplicate(allTVShows)
        
        return (dedupedMovies, dedupedTV)
    }
    
    private func deduplicate(_ items: [MediaItem]) -> [MediaItem] {
        var seenIDs = Set<String>()
        var uniqueItems: [MediaItem] = []
        
        for item in items {
            if !seenIDs.contains(item.id) {
                seenIDs.insert(item.id)
                uniqueItems.append(item)
            }
        }
        
        return uniqueItems.sorted { ($0.popularity ?? 0) > ($1.popularity ?? 0) }
    }
    
    func fetchRelated(type: String, genres: [String]?) async throws -> [MediaItem] {
        guard AddonManager.shared.isCinemetaEnabled else { return [] }
        guard let genres = genres, let primaryGenre = genres.first else {
            return try await fetchCatalog(type: type, id: "top", skipEnrichment: true)
        }
        
        // Fetch from the same primary genre
        return try await fetchCatalog(type: type, id: "top", genre: primaryGenre, skipEnrichment: true)
    }

    // MARK: - Subtitles Discovery
    
    /// Queries the stock OpenSubtitles v3 addon for all officially available subtitle tracks for an IMDb title.
    func fetchAvailableSubtitles(type: String, id: String) async -> [String] {
        let cleanType = type.lowercased().contains("tv") || type.lowercased().contains("series") ? "series" : "movie"
        let imdbID = id.starts(with: "tt") ? id : nil
        guard let fetchID = imdbID else { return [] }
        
        let urlString = "https://opensubtitles-v3.strem.io/subtitles/\(cleanType)/\(fetchID).json"
        guard let url = URL(string: urlString),
              let (data, response) = try? await URLSession.shared.data(from: url),
              let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subs = json["subtitles"] as? [[String: Any]] else {
            return []
        }
        
        var languageSet = Set<String>()
        for sub in subs {
            if let langCode = sub["lang"] as? String, !langCode.isEmpty {
                if langCode == "pob" {
                    languageSet.insert("Portuguese (Brazil) (SDH)")
                } else if langCode == "zho" || langCode == "chi" {
                    languageSet.insert("Chinese (SDH)")
                } else if let name = Locale.current.localizedString(forLanguageCode: langCode)?.capitalized {
                    languageSet.insert("\(name) (SDH)")
                } else {
                    languageSet.insert("\(langCode.uppercased()) (SDH)")
                }
            }
        }
        
        return languageSet.sorted()
    }
}

// MARK: - Extensions to Convert to MediaItem

/// Cinemeta ships poster URLs at `poster/small` (300×450) and the OTT addon uses
/// JustWatch (`/s332/`, ~332px) — both pixelate. Metahub is keyed by IMDb id and
/// scales to `poster/large` (780×1170), so prefer it whenever we have a `tt` id.
fileprivate func sharpPosterURL(_ raw: String?, imdbID: String) -> URL? {
    if imdbID.hasPrefix("tt"),
       let u = URL(string: "https://images.metahub.space/poster/large/\(imdbID)/img") {
        return u
    }
    guard let raw, !raw.isEmpty else { return nil }
    return URL(string: raw.replacingOccurrences(of: "/poster/small/", with: "/poster/large/"))
}

/// Cinemeta backdrops arrive at `background/medium` (720p); `background/large`
/// is up to 4K (3840×2160). Upgrade so heroes render sharp on Retina.
fileprivate func sharpBackdropURL(_ raw: String?) -> URL? {
    guard let raw, !raw.isEmpty else { return nil }
    let upgraded = raw
        .replacingOccurrences(of: "/background/small/", with: "/background/large/")
        .replacingOccurrences(of: "/background/medium/", with: "/background/large/")
    return URL(string: upgraded)
}

/// Cinemeta ships `logo` as `logo/medium/{tt}/img`. Prefer the raw value when
/// present; fall back to constructing the Metahub URL from the IMDb id so
/// catalog items without an embedded logo still resolve.
fileprivate func logoURL(_ raw: String?, imdbID: String) -> URL? {
    if let raw, !raw.isEmpty {
        return URL(string: raw)
    }
    if imdbID.hasPrefix("tt") {
        return URL(string: "https://images.metahub.space/logo/medium/\(imdbID)/img")
    }
    if let match = imdbID.range(of: "tt[0-9]+", options: .regularExpression) {
        return URL(string: "https://images.metahub.space/logo/medium/\(imdbID[match])/img")
    }
    return nil
}

extension StremioMetaPreview {
    func toMediaItem() -> MediaItem {
        return MediaItem(
            id: self.id,
            title: self.name,
            description: self.description ?? "",
            imageURL: nil,
            posterURL: sharpPosterURL(self.poster, imdbID: self.id),
            backdropURL: sharpBackdropURL(self.background),
            heroURL: sharpBackdropURL(self.background),
            logoURL: logoURL(self.logo, imdbID: self.id),
            streamURL: nil,
            category: self.type == "series" ? "TV Show" : "Movie",
            genres: self.genres,
            popularity: self.popularity ?? ((Double(self.imdbRating ?? "0") ?? 0) * 10),
            releaseDate: self.releaseInfo,
            originCountry: self.country,
            voteAverage: (Double(self.imdbRating ?? "0") ?? 0) > 0 ? Double(self.imdbRating ?? "0") : nil
        )
    }
}

extension StremioMetaDetail {
    func toMediaItem() -> MediaItem {
        var finalCast: [CastMember]? = nil
        if let castArray = self.cast {
            finalCast = castArray.map { CastMember(name: $0, role: nil, imageURL: nil) }
        }
        
        var episodesArray: [Episode]? = nil
        var seasonsArray: [Season]? = nil
        
        if self.type == "series", let vids = self.videos, !vids.isEmpty {
            episodesArray = vids.compactMap { vid in
                guard let sn = vid.season, let en = vid.episode else { return nil }
                // Use a consistent hashing for ID if it's not a number
                let epId = vid.id
                return Episode(
                    id: Int(epId.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? epId.hashValue,
                    name: vid.name ?? vid.title ?? "Episode \(en)",
                    overview: vid.overview ?? vid.description ?? "",
                    stillURL: vid.thumbnail != nil ? URL(string: vid.thumbnail!) : nil,
                    heroURL: nil,
                    episodeNumber: en,
                    seasonNumber: sn,
                    airDate: vid.released,
                    runtime: nil
                )
            }
            
            var seasonDict: [Int: Int] = [:]
            for vid in vids {
                if let s = vid.season {
                    seasonDict[s, default: 0] += 1
                }
            }
            // Remove Season 0 (Specials) for simpler UI unless requested, but we'll include it.
            seasonsArray = seasonDict.map { 
                Season(
                    id: $0.key,
                    name: "Season \($0.key)",
                    overview: nil,
                    posterURL: nil,
                    seasonNumber: $0.key,
                    episodeCount: $0.value,
                    episodes: nil
                )
            }.sorted { $0.seasonNumber < $1.seasonNumber }
        }
        
        return MediaItem(
            id: self.id,
            title: self.name,
            description: self.description ?? "",
            imageURL: nil,
            posterURL: sharpPosterURL(self.poster, imdbID: self.id),
            backdropURL: sharpBackdropURL(self.background),
            heroURL: sharpBackdropURL(self.background),
            logoURL: logoURL(self.logo, imdbID: self.id),
            streamURL: nil,
            category: self.type == "series" ? "TV Show" : "Movie",
            cast: finalCast,
            director: self.director?.joined(separator: ", "),
            seasons: seasonsArray,
            runtime: MediaItem.formatRuntimeString(self.runtime),
            genres: self.genres,
            popularity: self.popularity ?? ((Double(self.imdbRating ?? "0") ?? 0) * 10),
            releaseDate: self.releaseInfo,
            originCountry: self.country,
            voteAverage: (Double(self.imdbRating ?? "0") ?? 0) > 0 ? Double(self.imdbRating ?? "0") : nil,
            episodes: episodesArray
        )
    }
}
