#if os(macOS)
import AppKit
#endif

class TMDBEnricher {
    static let shared = TMDBEnricher()
    
    private let baseURL = "https://api.themoviedb.org/3"
    
    // MARK: - Caching Layer (Actor-isolated)
    private let memoryCache = TMDBMemoryCacheActor()
    
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
        case .backdrop, .original, .automatic: size = "original"
        }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }
    
    private var apiKey: String {
        let key = UserDefaults.standard.string(forKey: UserDefaults.Key.tmdbApiKey) ?? ""
        return key.isEmpty ? Secrets.tmdbAPIKey : key
    }

    /// Whether a TMDB key is available. Flux is Cinemeta-first and ships with no
    /// key; TMDB is an optional enhancement a user can enable in Settings. When
    /// absent, enrichment is skipped and Cinemeta data is used as-is.
    var hasKey: Bool { !apiKey.isEmpty }

    /// Validates a candidate API key against TMDB's lightweight /configuration
    /// endpoint. Returns true only on a 200 (valid key); 401/other = invalid.
    /// Used by Settings so a key is saved only after it's confirmed to work.
    func validateKey(_ key: String) async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: "\(baseURL)/configuration?api_key=\(trimmed)") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

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
        if let cached = await memoryCache.getIMDbID(for: cacheKey) { return cached }

        let urlString = "\(baseURL)/\(mediaType)/\(tmdbID)/external_ids?api_key=\(apiKey)"

        guard let url = URL(string: urlString) else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(ExternalIDsResponse.self, from: data)
            if let imdbID = response.imdb_id {
                await memoryCache.storeIMDbID(imdbID, for: cacheKey)
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
        if var cached = await memoryCache.getItem(for: item.id) {
            // Strictly preserve the episode-specific watch session state from the incoming item
            cached.lastSeason = item.lastSeason ?? cached.lastSeason
            cached.lastEpisode = item.lastEpisode ?? cached.lastEpisode
            cached.lastEpisodeTitle = item.lastEpisodeTitle ?? cached.lastEpisodeTitle
            cached.lastEpisodeImage = item.lastEpisodeImage ?? cached.lastEpisodeImage
            cached.progress = item.progress ?? cached.progress
            cached.runtime = item.runtime ?? cached.runtime
            cached.logoURL = item.logoURL ?? cached.logoURL
            return cached
        }
        
        var enriched = item
        let type = item.category.lowercased().contains("tv") || item.category.lowercased().contains("series") ? "tv" : "movie"
        
        // 1. Resolve TMDB ID
        let tmdbIDString = item.id.starts(with: "tt") ? await resolveTmdbID(imdbID: item.id, type: type) : item.id
        guard let id = tmdbIDString else { return item }
        
        // 2. Fetch basic metadata + images (logos)
        let urlString = "\(baseURL)/\(type)/\(id)?api_key=\(apiKey)&append_to_response=images&include_image_language=en,null"
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
            if let images = json["images"] as? [String: Any],
               let logos = images["logos"] as? [[String: Any]], !logos.isEmpty {
                let enLogo = logos.first(where: { ($0["iso_639_1"] as? String) == "en" }) ?? logos.first
                if let path = enLogo?["file_path"] as? String {
                    enriched.logoURL = URL(string: "https://image.tmdb.org/t/p/w500\(path)")
                }
            }
            if let popularity = json["popularity"] as? Double {
                enriched.popularity = popularity
            }
            if let overview = json["overview"] as? String, !overview.isEmpty {
                enriched.description = overview
            }
            if let voteAvg = json["vote_average"] as? Double, voteAvg > 0 {
                enriched.voteAverage = voteAvg
            }
            if let genresArray = json["genres"] as? [[String: Any]] {
                let names = genresArray.compactMap { $0["name"] as? String }
                if !names.isEmpty {
                    enriched.genres = names
                }
            }
            if let genreIds = json["genre_ids"] as? [Int] {
                if let names = TMDBGenreMapper.names(for: genreIds) {
                    enriched.genres = names
                }
            }
            if let releaseDate = (json["release_date"] as? String) ?? (json["first_air_date"] as? String), !releaseDate.isEmpty {
                enriched.releaseDate = releaseDate
            }
            if let originalLanguage = json["original_language"] as? String, !originalLanguage.isEmpty {
                enriched.originalLanguage = originalLanguage
            }
            if let countries = json["production_countries"] as? [[String: Any]] {
                let codes = countries.compactMap { $0["iso_3166_1"] as? String }
                if let first = codes.first { enriched.originCountry = first }
            }
            if let originCountryCodes = json["origin_country"] as? [String], let first = originCountryCodes.first, !first.isEmpty {
                enriched.originCountry = first
            }
            if let spoken = json["spoken_languages"] as? [[String: Any]] {
                let names = spoken.compactMap { $0["english_name"] as? String }.filter { !$0.isEmpty }
                if !names.isEmpty { enriched.spokenLanguages = names }
            }
        }
        
        // Retain caller's episode session properties
        enriched.lastSeason = item.lastSeason
        enriched.lastEpisode = item.lastEpisode
        enriched.lastEpisodeTitle = item.lastEpisodeTitle
        enriched.lastEpisodeImage = item.lastEpisodeImage
        enriched.progress = item.progress
        enriched.runtime = item.runtime
        enriched.logoURL = item.logoURL

        await memoryCache.storeItem(enriched, for: item.id)
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
                   let (data, _) = try? await URLSession.shared.data(from: url) {
                    if type == "movie", let detail = try? JSONDecoder().decode(TMDBMovieDetail.self, from: data) {
                        await MainActor.run {
                            if let backdrop = detail.backdropURL {
                                enriched.backdropURL = backdrop
                                enriched.heroURL = detail.heroURL ?? backdrop
                            }
                            if let poster = detail.posterURL {
                                enriched.posterURL = poster
                            }
                            if let overview = detail.overview, !overview.isEmpty {
                                enriched.description = overview
                            }
                            if let genres = detail.genres, !genres.isEmpty {
                                enriched.genres = genres.map { $0.name }
                            }
                            if let voteAverage = detail.voteAverage, voteAverage > 0 {
                                enriched.voteAverage = voteAverage
                            }
                            if let releaseDate = detail.releaseDate, !releaseDate.isEmpty {
                                enriched.releaseDate = releaseDate
                            }
                            if let runtime = detail.runtime {
                                enriched.runtime = "\(runtime / 60)h \(runtime % 60)m"
                            }
                            if let originalLanguage = detail.originalLanguage, !originalLanguage.isEmpty {
                                enriched.originalLanguage = originalLanguage
                            }
                            if let country = detail.originCountry?.first ?? detail.productionCountries?.first?.iso_3166_1, !country.isEmpty {
                                enriched.originCountry = country
                            }
                            if let spoken = detail.spokenLanguages?.map({ $0.english_name }).filter({ !$0.isEmpty }), !spoken.isEmpty {
                                enriched.spokenLanguages = spoken
                            }
                        }
                    } else if type == "tv", let detail = try? JSONDecoder().decode(TMDBTVShowDetail.self, from: data) {
                        await MainActor.run {
                            if let backdrop = detail.backdropURL {
                                enriched.backdropURL = backdrop
                                enriched.heroURL = detail.heroURL ?? backdrop
                            }
                            if let poster = detail.posterURL {
                                enriched.posterURL = poster
                            }
                            if let overview = detail.overview, !overview.isEmpty {
                                enriched.description = overview
                            }
                            if let genres = detail.genres, !genres.isEmpty {
                                enriched.genres = genres.map { $0.name }
                            }
                            if let voteAverage = detail.voteAverage, voteAverage > 0 {
                                enriched.voteAverage = voteAverage
                            }
                            if let releaseDate = detail.firstAirDate, !releaseDate.isEmpty {
                                enriched.releaseDate = releaseDate
                            }
                            if let originalLanguage = detail.originalLanguage, !originalLanguage.isEmpty {
                                enriched.originalLanguage = originalLanguage
                            }
                            if let country = detail.originCountry?.first ?? detail.productionCountries?.first?.iso_3166_1, !country.isEmpty {
                                enriched.originCountry = country
                            }
                            if let spoken = detail.spokenLanguages?.map({ $0.english_name }).filter({ !$0.isEmpty }), !spoken.isEmpty {
                                enriched.spokenLanguages = spoken
                            }
                        }
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
                            enriched.watchProviders = items.map {
                                WatchProvider(
                                    name: $0.provider_name,
                                    logoURL: self.adaptiveURL(path: $0.logo_path, quality: .poster),
                                    displayPriority: 0
                                )
                            }
                        }
                    }
                }
            }
        }
        
        await memoryCache.storeItem(enriched, for: item.id)
        return enriched
    }

    // MARK: - Specific Asset Fetching
    func fetchEpisodeStill(tmdbID: String, season: Int, episode: Int) async -> URL? {
        let (still, _) = await fetchEpisodeInfo(tmdbID: tmdbID, season: season, episode: episode)
        return still
    }

    func fetchEpisodeInfo(tmdbID: String, season: Int, episode: Int) async -> (stillURL: URL?, runtime: String?) {
        let urlString = "\(baseURL)/tv/\(tmdbID)/season/\(season)/episode/\(episode)?api_key=\(apiKey)"
        guard let url = URL(string: urlString), 
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(TMDBEpisodeDetail.self, from: data) else { return (nil, nil) }
        
        let still = adaptiveURL(path: response.still_path, quality: .backdrop)
        let rt = response.runtime.map { "\($0)m" }
        return (still, rt)
    }

    func fetchLogoURL(tmdbID: String, type: String) async -> URL? {
        let mediaType = type.contains("tv") || type.contains("series") ? "tv" : "movie"
        let urlString = "\(baseURL)/\(mediaType)/\(tmdbID)/images?api_key=\(apiKey)&include_image_language=en,null"
        guard let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let logos = json["logos"] as? [[String: Any]], !logos.isEmpty else {
            return nil
        }
        let enLogo = logos.first(where: { ($0["iso_639_1"] as? String) == "en" }) ?? logos.first
        guard let path = enLogo?["file_path"] as? String else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500\(path)")
    }

    func fetchMovieRuntime(tmdbID: String) async -> String? {
        let urlString = "\(baseURL)/movie/\(tmdbID)?api_key=\(apiKey)"
        guard let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtime = json["runtime"] as? Int, runtime > 0 else {
            return nil
        }
        let hours = runtime / 60
        let minutes = runtime % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        } else {
            return "\(minutes)m"
        }
    }
    
    struct TMDBEpisodeEnrichment {
        let name: String
        let overview: String
        let stillURL: URL?
        let runtime: Int?
    }

    func fetchFullSeasonEnrichment(tvId: String, seasonNumber: Int) async -> [Int: TMDBEpisodeEnrichment] {
        let urlString = "\(baseURL)/tv/\(tvId)/season/\(seasonNumber)?api_key=\(apiKey)"
        guard let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(TMDBSeasonResponse.self, from: data) else { return [:] }
        
        var result: [Int: TMDBEpisodeEnrichment] = [:]
        for episode in response.episodes {
            let still = episode.still_path != nil ? URL(string: "https://image.tmdb.org/t/p/w780\(episode.still_path!)") : nil
            result[episode.episode_number] = TMDBEpisodeEnrichment(
                name: episode.name,
                overview: episode.overview,
                stillURL: still,
                runtime: episode.runtime
            )
        }
        return result
    }

    func fetchSeasonEnrichment(tvId: String, seasonNumber: Int) async -> [Int: String] {
        let enrichments = await fetchFullSeasonEnrichment(tvId: tvId, seasonNumber: seasonNumber)
        return enrichments.mapValues { $0.overview }
    }
    
    // MARK: - Regional & Locale Helpers
    var currentRegion: String {
        Locale.current.region?.identifier ?? "US"
    }
    
    var currentTimeZone: String {
        TimeZone.current.identifier
    }

    // MARK: - Catalog Fetching (Flux Discovery Layer with TTL-Aware Caching)
    
    func fetchTrendingAll(window: String = "day") async throws -> [MediaItem] {
        let cacheKey = "trending:all:\(window)"
        if let cached = await TMDBCatalogCacheActor.shared.get(key: cacheKey) {
            return cached
        }
        
        let urlString = "\(baseURL)/trending/all/\(window)?api_key=\(apiKey)"
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let (data, _) = try await URLSession.shared.data(from: url)
        
        let response = try JSONDecoder().decode(TMDBTrendingResponse.self, from: data)
        let filtered = response.results.filter { item in
            if let genres = item.genreIds {
                if genres.contains(10763) || genres.contains(10767) { return false }
            }
            let name = (item.name ?? item.title ?? "").lowercased()
            if name.contains("tagesschau") || name.contains("tagesthemen") { return false }
            return true
        }
        let results = filtered.compactMap { $0.toMediaItem() }
        
        await TMDBCatalogCacheActor.shared.set(key: cacheKey, items: results, ttl: window == "day" ? .trendingDay : .trendingWeek)
        return results
    }

    func fetchTrendingMovies(window: String = "day") async throws -> [MediaItem] {
        let cacheKey = "trending:movie:\(window)"
        if let cached = await TMDBCatalogCacheActor.shared.get(key: cacheKey) { return cached }
        
        let urlString = "\(baseURL)/trending/movie/\(window)?api_key=\(apiKey)"
        let items = try await fetchCatalog(from: urlString, type: "movie")
        await TMDBCatalogCacheActor.shared.set(key: cacheKey, items: items, ttl: window == "day" ? .trendingDay : .trendingWeek)
        return items
    }

    func fetchTrendingTV(window: String = "day") async throws -> [MediaItem] {
        let cacheKey = "trending:tv:\(window)"
        if let cached = await TMDBCatalogCacheActor.shared.get(key: cacheKey) { return cached }
        
        let urlString = "\(baseURL)/trending/tv/\(window)?api_key=\(apiKey)"
        let items = try await fetchCatalog(from: urlString, type: "tv")
        await TMDBCatalogCacheActor.shared.set(key: cacheKey, items: items, ttl: window == "day" ? .trendingDay : .trendingWeek)
        return items
    }

    func fetchPopularMovies(page: Int = 1) async throws -> [MediaItem] {
        let cacheKey = "movie:popular:\(currentRegion):\(page)"
        if page == 1, let cached = await TMDBCatalogCacheActor.shared.get(key: cacheKey) { return cached }
        
        let urlString = "\(baseURL)/movie/popular?api_key=\(apiKey)&region=\(currentRegion)&page=\(page)"
        let items = try await fetchCatalog(from: urlString, type: "movie")
        if page == 1 { await TMDBCatalogCacheActor.shared.set(key: cacheKey, items: items, ttl: .popular) }
        return items
    }

    func fetchNowPlayingMovies(page: Int = 1) async throws -> [MediaItem] {
        let cacheKey = "movie:now_playing:\(currentRegion):\(page)"
        if page == 1, let cached = await TMDBCatalogCacheActor.shared.get(key: cacheKey) { return cached }
        
        let urlString = "\(baseURL)/movie/now_playing?api_key=\(apiKey)&region=\(currentRegion)&page=\(page)"
        let items = try await fetchCatalog(from: urlString, type: "movie", allowUnreleased: true)
        if page == 1 { await TMDBCatalogCacheActor.shared.set(key: cacheKey, items: items, ttl: .nowPlaying) }
        return items
    }

    func fetchUpcomingMovies(page: Int = 1) async throws -> [MediaItem] {
        let cacheKey = "movie:upcoming:\(currentRegion):\(page)"
        if page == 1, let cached = await TMDBCatalogCacheActor.shared.get(key: cacheKey) { return cached }
        
        let urlString = "\(baseURL)/movie/upcoming?api_key=\(apiKey)&region=\(currentRegion)&page=\(page)"
        let items = try await fetchCatalog(from: urlString, type: "movie", allowUnreleased: true)
        if page == 1 { await TMDBCatalogCacheActor.shared.set(key: cacheKey, items: items, ttl: .upcoming) }
        return items
    }

    func fetchTopRatedMovies(page: Int = 1) async throws -> [MediaItem] {
        let cacheKey = "movie:top_rated:\(currentRegion):\(page)"
        if page == 1, let cached = await TMDBCatalogCacheActor.shared.get(key: cacheKey) { return cached }
        
        let urlString = "\(baseURL)/movie/top_rated?api_key=\(apiKey)&region=\(currentRegion)&page=\(page)"
        let items = try await fetchCatalog(from: urlString, type: "movie")
        if page == 1 { await TMDBCatalogCacheActor.shared.set(key: cacheKey, items: items, ttl: .topRated) }
        return items
    }

    func fetchStreamingMovies(page: Int = 1) async throws -> [MediaItem] {
        let cacheKey = "movie:streaming:\(currentRegion):\(page)"
        if page == 1, let cached = await TMDBCatalogCacheActor.shared.get(key: cacheKey) { return cached }
        
        let urlString = "\(baseURL)/discover/movie?api_key=\(apiKey)&with_watch_monetization_types=flatrate&watch_region=\(currentRegion)&sort_by=popularity.desc&include_adult=false&vote_count.gte=30&page=\(page)"
        let items = try await fetchCatalog(from: urlString, type: "movie")
        if page == 1 { await TMDBCatalogCacheActor.shared.set(key: cacheKey, items: items, ttl: .discover) }
        return items
    }

    func fetchQuickWatchMovies(page: Int = 1) async throws -> [MediaItem] {
        let cacheKey = "movie:quick:\(page)"
        if page == 1, let cached = await TMDBCatalogCacheActor.shared.get(key: cacheKey) { return cached }
        
        let urlString = "\(baseURL)/discover/movie?api_key=\(apiKey)&with_runtime.lte=95&sort_by=popularity.desc&include_adult=false&vote_count.gte=50&page=\(page)"
        let items = try await fetchCatalog(from: urlString, type: "movie")
        if page == 1 { await TMDBCatalogCacheActor.shared.set(key: cacheKey, items: items, ttl: .discover) }
        return items
    }

    func fetchPopularTV(page: Int = 1) async throws -> [MediaItem] {
        let cacheKey = "tv:popular:\(page)"
        if page == 1, let cached = await TMDBCatalogCacheActor.shared.get(key: cacheKey) { return cached }
        
        let urlString = "\(baseURL)/discover/tv?api_key=\(apiKey)&sort_by=popularity.desc&without_genres=10763,10767&include_adult=false&vote_count.gte=10&page=\(page)"
        let items = try await fetchCatalog(from: urlString, type: "tv")
        if page == 1 { await TMDBCatalogCacheActor.shared.set(key: cacheKey, items: items, ttl: .popular) }
        return items
    }

    func fetchAiringTodayTV(page: Int = 1) async throws -> [MediaItem] {
        let cacheKey = "tv:airing_today:\(currentTimeZone):\(page)"
        if page == 1, let cached = await TMDBCatalogCacheActor.shared.get(key: cacheKey) { return cached }
        
        let urlString = "\(baseURL)/tv/airing_today?api_key=\(apiKey)&timezone=\(currentTimeZone)&page=\(page)"
        let items = try await fetchCatalog(from: urlString, type: "tv", allowUnreleased: true)
        if page == 1 { await TMDBCatalogCacheActor.shared.set(key: cacheKey, items: items, ttl: .airingToday) }
        return items
    }

    func fetchOnTheAirTV(page: Int = 1) async throws -> [MediaItem] {
        let cacheKey = "tv:on_the_air:\(currentTimeZone):\(page)"
        if page == 1, let cached = await TMDBCatalogCacheActor.shared.get(key: cacheKey) { return cached }
        
        let urlString = "\(baseURL)/tv/on_the_air?api_key=\(apiKey)&timezone=\(currentTimeZone)&page=\(page)"
        let items = try await fetchCatalog(from: urlString, type: "tv", allowUnreleased: true)
        if page == 1 { await TMDBCatalogCacheActor.shared.set(key: cacheKey, items: items, ttl: .nowPlaying) }
        return items
    }

    func fetchTopRatedTV(page: Int = 1) async throws -> [MediaItem] {
        let cacheKey = "tv:top_rated:\(page)"
        if page == 1, let cached = await TMDBCatalogCacheActor.shared.get(key: cacheKey) { return cached }
        
        let urlString = "\(baseURL)/tv/top_rated?api_key=\(apiKey)&page=\(page)"
        let items = try await fetchCatalog(from: urlString, type: "tv")
        if page == 1 { await TMDBCatalogCacheActor.shared.set(key: cacheKey, items: items, ttl: .topRated) }
        return items
    }

    func fetchStreamingTV(page: Int = 1) async throws -> [MediaItem] {
        let cacheKey = "tv:streaming:\(currentRegion):\(page)"
        if page == 1, let cached = await TMDBCatalogCacheActor.shared.get(key: cacheKey) { return cached }
        
        let urlString = "\(baseURL)/discover/tv?api_key=\(apiKey)&with_watch_monetization_types=flatrate&watch_region=\(currentRegion)&sort_by=popularity.desc&without_genres=10763,10767&include_adult=false&vote_count.gte=30&page=\(page)"
        let items = try await fetchCatalog(from: urlString, type: "tv")
        if page == 1 { await TMDBCatalogCacheActor.shared.set(key: cacheKey, items: items, ttl: .discover) }
        return items
    }

    // Generic Internal Fetcher with allowUnreleased switch
    private func fetchCatalog(from urlString: String, type mediaType: String, allowUnreleased: Bool = false) async throws -> [MediaItem] {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let (data, _) = try await URLSession.shared.data(from: url)
        
        if mediaType == "movie" {
            let response = try JSONDecoder().decode(TMDBResponse<TMDBMovie>.self, from: data)
            let items = response.results.map { $0.toMediaItem() }
            return allowUnreleased ? items : items.filter { $0.isReleased }
        } else {
            let response = try JSONDecoder().decode(TMDBResponse<TMDBTVShow>.self, from: data)
            let filtered = response.results.filter { show in
                if let genres = show.genreIds {
                    if genres.contains(10763) || genres.contains(10767) { return false }
                }
                let lower = show.name.lowercased()
                if lower.contains("tagesschau") || lower.contains("tagesthemen") { return false }
                return true
            }
            let items = filtered.map { $0.toMediaItem() }
            return allowUnreleased ? items : items.filter { $0.isReleased }
        }
    }

    /// TMDB discover by genre — real genre-accurate titles, page-based pagination
    /// (pages 1..500). Used by the genre pages for endless scroll.
    func fetchGenrePage(tmdbGenreID: Int, page: Int, mediaType: String = "movie") async -> [MediaItem] {
        let type = mediaType.lowercased().contains("tv") || mediaType.lowercased().contains("series") ? "tv" : "movie"
        let urlString: String
        switch tmdbGenreID {
        case 10001: // Anime
            urlString = "\(baseURL)/discover/\(type)?api_key=\(apiKey)&with_genres=16&with_original_language=ja&page=\(page)&sort_by=popularity.desc&include_adult=false"
        case 10002: // Bollywood
            urlString = "\(baseURL)/discover/\(type)?api_key=\(apiKey)&with_original_language=hi&page=\(page)&sort_by=popularity.desc&include_adult=false"
        case 10003: // Classics
            urlString = "\(baseURL)/discover/\(type)?api_key=\(apiKey)&primary_release_date.lte=1980-01-01&page=\(page)&sort_by=popularity.desc&include_adult=false"
        case 10004: // K-Drama
            urlString = "\(baseURL)/discover/\(type)?api_key=\(apiKey)&with_original_language=ko&page=\(page)&sort_by=popularity.desc&include_adult=false"
        case 10005: // Short Films
            urlString = "\(baseURL)/discover/\(type)?api_key=\(apiKey)&with_runtime.lte=40&page=\(page)&sort_by=popularity.desc&include_adult=false"
        default:
            urlString = "\(baseURL)/discover/\(type)?api_key=\(apiKey)&with_genres=\(tmdbGenreID)&page=\(page)&sort_by=popularity.desc&include_adult=false&vote_count.gte=50"
        }
        return (try? await fetchCatalog(from: urlString, type: type)) ?? []
    }

    /// OTT platform catalogs via TMDB watch providers
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

    func fetchWatchProviderCatalog(platformID: String, type: String, page: Int = 1) async -> [MediaItem] {
        guard hasKey, let providerID = Self.tmdbProviderIDs[platformID] else { return [] }
        let mediaType = type == "series" ? "tv" : "movie"
        let urlString = "\(baseURL)/discover/\(mediaType)?api_key=\(apiKey)&with_watch_providers=\(providerID)&watch_region=\(currentRegion)&sort_by=popularity.desc&include_adult=false&vote_count.gte=30&page=\(page)"
        return (try? await fetchCatalog(from: urlString, type: mediaType)) ?? []
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

    /// Returns all valid YouTube trailers, teasers, and clips for a title, prioritized by relevance.
    func fetchTrailers(item: MediaItem) async -> [TMDBVideo] {
        guard hasKey else { return [] }
        let type = item.category == "TV Show" || item.category == "Series" ? "tv" : "movie"
        let tmdbID = item.id.starts(with: "tt") ? await resolveTmdbID(imdbID: item.id, type: type) : item.id
        guard let id = tmdbID else { return [] }

        let videosURL = "\(baseURL)/\(type)/\(id)/videos?api_key=\(apiKey)"
        guard let url = URL(string: videosURL),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(TMDBVideoResponse.self, from: data) else {
            return []
        }

        let youtube = response.results.filter { $0.site == "YouTube" }
        return youtube.sorted { v1, v2 in
            let rank1 = trailerRank(for: v1)
            let rank2 = trailerRank(for: v2)
            if rank1 != rank2 { return rank1 < rank2 }
            return (v1.publishedAt ?? "") > (v2.publishedAt ?? "")
        }
    }

    private func trailerRank(for video: TMDBVideo) -> Int {
        let name = video.name.lowercased()
        let isOfficial = video.official == true
        if video.type == "Trailer" && (name.contains("official") || isOfficial) { return 0 }
        if video.type == "Trailer" { return 1 }
        if video.type == "Teaser" && (name.contains("official") || isOfficial) { return 2 }
        if video.type == "Teaser" { return 3 }
        if video.type == "Clip" { return 4 }
        if video.type == "Featurette" || video.type == "Behind the Scenes" { return 5 }
        return 6
    }

    /// Fetches up to 15 distinct backdrops from TMDB for a title, useful for unique trailer art fallbacks.
    func fetchBackdrops(item: MediaItem) async -> [URL] {
        guard hasKey else { return [] }
        let type = item.category == "TV Show" || item.category == "Series" ? "tv" : "movie"
        let tmdbID = item.id.starts(with: "tt") ? await resolveTmdbID(imdbID: item.id, type: type) : item.id
        guard let id = tmdbID else { return [] }

        let imagesURL = "\(baseURL)/\(type)/\(id)/images?api_key=\(apiKey)"
        guard let url = URL(string: imagesURL),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let backdrops = json["backdrops"] as? [[String: Any]], !backdrops.isEmpty else {
            return []
        }

        let primaryPath = item.backdropURL?.lastPathComponent
        var urls: [URL] = []
        for dict in backdrops {
            guard let path = dict["file_path"] as? String else { continue }
            if let primary = primaryPath, !primary.isEmpty, path.contains(primary) { continue }
            if let u = URL(string: "https://image.tmdb.org/t/p/w780\(path)") {
                urls.append(u)
            }
        }
        return urls
    }

    /// Returns curated bonus content items: High-res TMDB-enriched Season 0 Specials
    /// (streamable directly in Flux's native player) and strictly Official Trailers/Teasers.
    func fetchBonusContent(item: MediaItem, fullItem: MediaItem? = nil) async -> [BonusContentItem] {
        var items: [BonusContentItem] = []
        let type = item.category == "TV Show" || item.category == "Series" ? "tv" : "movie"
        var availableBackdrops = await fetchBackdrops(item: item)
        
        // 1. Season 0 Specials (from Series metadata - streamable in Flux's native player)
        if type == "tv" {
            let allEpisodes = fullItem?.episodes ?? item.episodes ?? []
            let seasonZeroEpisodes = allEpisodes.filter { $0.seasonNumber == 0 }.sorted { $0.episodeNumber < $1.episodeNumber }
            
            // Enrich with TMDB Season 0 data (for high-res stills & descriptions)
            var tmdbStills: [Int: (name: String, overview: String, stillURL: URL?)] = [:]
            let tmdbID = item.id.starts(with: "tt") ? await resolveTmdbID(imdbID: item.id, type: "tv") : item.id
            if let id = tmdbID {
                let seasonURL = "\(baseURL)/tv/\(id)/season/0?api_key=\(apiKey)"
                if let url = URL(string: seasonURL),
                   let (data, _) = try? await URLSession.shared.data(from: url),
                   let response = try? JSONDecoder().decode(TMDBSeasonResponse.self, from: data) {
                    for ep in response.episodes {
                        let stillURL = ep.still_path != nil ? URL(string: "https://image.tmdb.org/t/p/w780\(ep.still_path!)") : nil
                        tmdbStills[ep.episode_number] = (name: ep.name, overview: ep.overview, stillURL: stillURL)
                    }
                }
            }
            
            for ep in seasonZeroEpisodes {
                let tmdbData = tmdbStills[ep.episodeNumber]
                let epName = (!ep.name.isEmpty && ep.name != "Episode \(ep.episodeNumber)") ? ep.name : (tmdbData?.name ?? "Special \(ep.episodeNumber)")
                let epStill = ep.stillURL ?? tmdbData?.stillURL
                let fallbackArt = availableBackdrops.isEmpty ? nil : availableBackdrops.removeFirst()
                
                let subtitle: String
                if let runtime = ep.runtime {
                    subtitle = "Special • \(runtime)m"
                } else if let overview = tmdbData?.overview, !overview.isEmpty {
                    subtitle = "Special Episode"
                } else {
                    subtitle = "Special Feature"
                }
                
                let enrichedEp = Episode(
                    id: ep.id,
                    name: epName,
                    overview: tmdbData?.overview ?? ep.overview,
                    stillURL: epStill,
                    heroURL: ep.heroURL,
                    episodeNumber: ep.episodeNumber,
                    seasonNumber: ep.seasonNumber,
                    airDate: ep.airDate,
                    runtime: ep.runtime
                )
                
                items.append(BonusContentItem(
                    id: "s0-e\(ep.episodeNumber)-\(ep.id)",
                    title: epName,
                    subtitle: subtitle,
                    categoryType: "Special",
                    thumbnailURL: epStill,
                    fallbackArtURL: fallbackArt,
                    videoKey: nil,
                    episode: enrichedEp
                ))
            }
        }
        
        // 2. Official Trailers Only (filtered strictly to official trailers and teasers)
        let videos = await fetchTrailers(item: item)
        let officialTrailers = videos.filter { vid in
            let isOfficial = vid.official == true || vid.name.lowercased().contains("official")
            let isTrailerType = vid.type == "Trailer" || vid.type == "Teaser"
            return isOfficial && isTrailerType
        }
        
        for vid in officialTrailers {
            let catType = vid.type == "Teaser" ? "Teaser" : "Trailer"
            // Use 16:9 maxresdefault.jpg as primary thumbnail, with 16:9 mqdefault.jpg fallback
            let thumb = vid.thumbnailURL
            let fallbackThumb = vid.fallbackThumbnailURL
            let fallbackArt = availableBackdrops.isEmpty ? nil : availableBackdrops.removeFirst()
            items.append(BonusContentItem(
                id: "tmdb-trailer-\(vid.id)",
                title: vid.name,
                subtitle: "Official \(catType)",
                categoryType: catType,
                thumbnailURL: thumb,
                fallbackThumbnailURL: fallbackThumb,
                fallbackArtURL: fallbackArt,
                videoKey: vid.key,
                episode: nil
            ))
        }
        
        // Sort: Specials first, then Trailers
        return items.sorted { item1, item2 in
            let r1 = bonusRank(category: item1.categoryType)
            let r2 = bonusRank(category: item2.categoryType)
            return r1 < r2
        }
    }

    private func bonusRank(category: String) -> Int {
        switch category {
        case "Special": return 0
        case "Trailer": return 1
        case "Teaser": return 2
        default: return 3
        }
    }

    /// Returns the best YouTube trailer URL for a title, or nil if none.
    func fetchTrailerURL(item: MediaItem) async -> URL? {
        let trailers = await fetchTrailers(item: item)
        return trailers.first?.youtubeURL
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
        if let cached = await memoryCache.getNewEpisodeStatus(for: tmdbID) {
            return cached
        }

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
        
        await memoryCache.storeNewEpisodeStatus(fresh, for: tmdbID)
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
    let runtime: Int?
}
