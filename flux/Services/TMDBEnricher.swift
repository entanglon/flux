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

    /// Whether TMDB should be used to enrich Home, Movies, and TV Shows discovery rails.
    /// Controlled by the "Enrich Home with TMDB" setting (defaults to true when a key exists).
    var hasKeyForHome: Bool {
        guard hasKey else { return false }
        if UserDefaults.standard.object(forKey: "enrichHomeWithTMDB") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "enrichHomeWithTMDB")
    }

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
        let cleanID = item.id.replacingOccurrences(of: "tmdb-", with: "").replacingOccurrences(of: "tmdb:", with: "")
        let tmdbIDString = item.id.starts(with: "tt") ? await resolveTmdbID(imdbID: item.id, type: type) : cleanID
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
        
        let cleanID = item.id.replacingOccurrences(of: "tmdb-", with: "").replacingOccurrences(of: "tmdb:", with: "")
        let tmdbIDString = item.id.starts(with: "tt") ? await resolveTmdbID(imdbID: item.id, type: type) : cleanID
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
                                enriched.runtime = MediaItem.formatRuntime(minutes: runtime)
                            }
                            if let originalLanguage = detail.originalLanguage, !originalLanguage.isEmpty {
                                enriched.originalLanguage = originalLanguage
                            }
                            if let country = detail.originCountry?.first ?? detail.productionCountries?.first?.iso_3166_1, !country.isEmpty {
                                enriched.originCountry = country
                            }
                            if let spoken = detail.spokenLanguages?.map({ $0.english_name }).filter({ !$0.isEmpty }), !spoken.isEmpty {
                                enriched.spokenLanguages = spoken
                                enriched.audioTracks = spoken
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
                            if let seasons = detail.seasons?.map({ $0.toSeason() }), !seasons.isEmpty {
                                enriched.seasons = seasons
                            }
                            if let originalLanguage = detail.originalLanguage, !originalLanguage.isEmpty {
                                enriched.originalLanguage = originalLanguage
                            }
                            if let country = detail.originCountry?.first ?? detail.productionCountries?.first?.iso_3166_1, !country.isEmpty {
                                enriched.originCountry = country
                            }
                            if let spoken = detail.spokenLanguages?.map({ $0.english_name }).filter({ !$0.isEmpty }), !spoken.isEmpty {
                                enriched.spokenLanguages = spoken
                                enriched.audioTracks = spoken
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

            // Certification (Rated) & Content Advisories
            group.addTask {
                let (cert, advisories) = await self.fetchCertification(id: id, type: type)
                await MainActor.run {
                    if let c = cert, !c.isEmpty { enriched.certification = c }
                    if let adv = advisories, !adv.isEmpty { enriched.contentAdvisories = adv }
                }
            }
        }
        
        await memoryCache.storeItem(enriched, for: item.id)
        return enriched
    }

    // MARK: - Certification & Content Advisories
    
    /// Fetches official age ratings (e.g. "PG-13", "TV-MA", "A") and content advisory descriptors.
    func fetchCertification(id: String, type: String) async -> (certification: String?, advisories: [String]?) {
        guard hasKey else { return (nil, nil) }
        let endpoint = type == "tv" ? "tv/\(id)/content_ratings" : "movie/\(id)/release_dates"
        let urlString = "\(baseURL)/\(endpoint)?api_key=\(apiKey)"
        guard let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return (nil, nil)
        }
        
        let userRegion = Locale.current.region?.identifier ?? "US"
        var foundCert: String? = nil
        var descriptorsList: [String] = []
        
        if type == "tv" {
            // Find user's region or US
            let match = results.first(where: { ($0["iso_3166_1"] as? String) == userRegion })
                ?? results.first(where: { ($0["iso_3166_1"] as? String) == "US" })
                ?? results.first
            if let match = match, let rating = match["rating"] as? String, !rating.isEmpty {
                foundCert = rating
                if let descriptors = match["descriptors"] as? [String], !descriptors.isEmpty {
                    descriptorsList = descriptors
                }
            }
        } else {
            // Movies release_dates
            let match = results.first(where: { ($0["iso_3166_1"] as? String) == userRegion })
                ?? results.first(where: { ($0["iso_3166_1"] as? String) == "US" })
                ?? results.first
            if let match = match, let dates = match["release_dates"] as? [[String: Any]] {
                for d in dates {
                    if let cert = d["certification"] as? String, !cert.isEmpty {
                        foundCert = cert
                        if let descriptors = d["descriptors"] as? [String], !descriptors.isEmpty {
                            descriptorsList = descriptors
                        }
                        break
                    }
                }
            }
        }
        
        // If descriptors list is empty, query keywords for content advisory signals
        if descriptorsList.isEmpty {
            if let keywords = await fetchKeywords(id: id, type: type) {
                let lowerKeywords = keywords.map { $0.lowercased() }
                var detected: [String] = []
                if lowerKeywords.contains(where: { $0.contains("drug") || $0.contains("substance") || $0.contains("alcohol") || $0.contains("smoking") }) {
                    detected.append("Drugs or Drug Use")
                }
                if lowerKeywords.contains(where: { $0.contains("violence") || $0.contains("murder") || $0.contains("gore") || $0.contains("battle") || $0.contains("fight") }) {
                    detected.append("Violence")
                }
                if lowerKeywords.contains(where: { $0.contains("nudity") || $0.contains("sex") || $0.contains("erotic") }) {
                    detected.append("Sexual Content")
                }
                if lowerKeywords.contains(where: { $0.contains("profanity") || $0.contains("curse") || $0.contains("language") }) {
                    detected.append("Language")
                }
                if !detected.isEmpty {
                    descriptorsList = detected
                }
            }
        }
        
        return (foundCert, descriptorsList.isEmpty ? nil : descriptorsList)
    }

    private func fetchKeywords(id: String, type: String) async -> [String]? {
        let urlString = "\(baseURL)/\(type)/\(id)/keywords?api_key=\(apiKey)"
        guard let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let list = (json["keywords"] as? [[String: Any]]) ?? (json["results"] as? [[String: Any]])
        return list?.compactMap { $0["name"] as? String }
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
    
    func fetchSeasonEpisodes(tvId: String, seasonNumber: Int) async -> [Episode] {
        let urlString = "\(baseURL)/tv/\(tvId)/season/\(seasonNumber)?api_key=\(apiKey)"
        guard let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(TMDBSeasonResponse.self, from: data) else { return [] }
        
        return response.episodes.map { ep in
            let still = ep.still_path != nil ? URL(string: "https://image.tmdb.org/t/p/w780\(ep.still_path!)") : nil
            return Episode(
                id: ep.id ?? (seasonNumber * 1000 + ep.episode_number),
                name: ep.name.isEmpty ? "Episode \(ep.episode_number)" : ep.name,
                overview: ep.overview,
                stillURL: still,
                heroURL: still,
                episodeNumber: ep.episode_number,
                seasonNumber: seasonNumber,
                airDate: ep.air_date,
                runtime: ep.runtime
            )
        }
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
        guard hasKeyForHome else {
            let movies: [MediaItem]
            let series: [MediaItem]
            if window == "day" {
                movies = (try? await StremioService.shared.fetchTrendingMovies()) ?? []
                series = (try? await StremioService.shared.fetchTrendingTVShows()) ?? []
            } else {
                movies = (try? await StremioService.shared.fetchPopularMovies()) ?? []
                series = (try? await StremioService.shared.fetchPopularTVShows()) ?? []
            }
            var interleaved: [MediaItem] = []
            let maxCount = max(movies.count, series.count)
            for i in 0..<maxCount {
                if i < movies.count { interleaved.append(movies[i]) }
                if i < series.count { interleaved.append(series[i]) }
            }
            return interleaved
        }
        
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
        guard hasKeyForHome else {
            if window == "day" {
                return try await StremioService.shared.fetchTrendingMovies()
            } else {
                return try await StremioService.shared.fetchPopularMovies()
            }
        }
        
        let cacheKey = "trending:movie:\(window)"
        if let cached = await TMDBCatalogCacheActor.shared.get(key: cacheKey) { return cached }
        
        let urlString = "\(baseURL)/trending/movie/\(window)?api_key=\(apiKey)"
        let items = try await fetchCatalog(from: urlString, type: "movie")
        await TMDBCatalogCacheActor.shared.set(key: cacheKey, items: items, ttl: window == "day" ? .trendingDay : .trendingWeek)
        return items
    }

    func fetchTrendingTV(window: String = "day") async throws -> [MediaItem] {
        guard hasKeyForHome else {
            if window == "day" {
                return try await StremioService.shared.fetchTrendingTVShows()
            } else {
                return try await StremioService.shared.fetchPopularTVShows()
            }
        }
        
        let cacheKey = "trending:tv:\(window)"
        if let cached = await TMDBCatalogCacheActor.shared.get(key: cacheKey) { return cached }
        
        let urlString = "\(baseURL)/trending/tv/\(window)?api_key=\(apiKey)"
        let items = try await fetchCatalog(from: urlString, type: "tv")
        await TMDBCatalogCacheActor.shared.set(key: cacheKey, items: items, ttl: window == "day" ? .trendingDay : .trendingWeek)
        return items
    }

    func fetchPopularMovies(page: Int = 1) async throws -> [MediaItem] {
        guard hasKeyForHome else {
            let skip = (page - 1) * 20
            return try await StremioService.shared.fetchCatalog(type: "movie", id: "top", skip: skip, preserveOrder: true)
        }
        
        let cacheKey = "movie:popular:\(currentRegion):\(page)"
        if page == 1, let cached = await TMDBCatalogCacheActor.shared.get(key: cacheKey) { return cached }
        
        let urlString = "\(baseURL)/movie/popular?api_key=\(apiKey)&region=\(currentRegion)&page=\(page)"
        let items = try await fetchCatalog(from: urlString, type: "movie")
        if page == 1 { await TMDBCatalogCacheActor.shared.set(key: cacheKey, items: items, ttl: .popular) }
        return items
    }

    func fetchNowPlayingMovies(page: Int = 1) async throws -> [MediaItem] {
        guard hasKeyForHome else { return [] }
        
        let cacheKey = "movie:now_playing:\(currentRegion):\(page)"
        if page == 1, let cached = await TMDBCatalogCacheActor.shared.get(key: cacheKey) { return cached }
        
        let urlString = "\(baseURL)/movie/now_playing?api_key=\(apiKey)&region=\(currentRegion)&page=\(page)"
        let items = try await fetchCatalog(from: urlString, type: "movie", allowUnreleased: true)
        if page == 1 { await TMDBCatalogCacheActor.shared.set(key: cacheKey, items: items, ttl: .nowPlaying) }
        return items
    }

    func fetchUpcomingMovies(page: Int = 1) async throws -> [MediaItem] {
        guard hasKeyForHome else { return [] }
        
        let cacheKey = "movie:upcoming:\(currentRegion):\(page)"
        if page == 1, let cached = await TMDBCatalogCacheActor.shared.get(key: cacheKey) { return cached }
        
        let urlString = "\(baseURL)/movie/upcoming?api_key=\(apiKey)&region=\(currentRegion)&page=\(page)"
        let items = try await fetchCatalog(from: urlString, type: "movie", allowUnreleased: true)
        if page == 1 { await TMDBCatalogCacheActor.shared.set(key: cacheKey, items: items, ttl: .upcoming) }
        return items
    }

    func fetchTopRatedMovies(page: Int = 1) async throws -> [MediaItem] {
        guard hasKeyForHome else {
            return try await StremioService.shared.fetchTopRatedMovies(page: page)
        }
        
        let cacheKey = "movie:top_rated:\(currentRegion):\(page)"
        if page == 1, let cached = await TMDBCatalogCacheActor.shared.get(key: cacheKey) { return cached }
        
        let urlString = "\(baseURL)/movie/top_rated?api_key=\(apiKey)&region=\(currentRegion)&page=\(page)"
        let items = try await fetchCatalog(from: urlString, type: "movie")
        if page == 1 { await TMDBCatalogCacheActor.shared.set(key: cacheKey, items: items, ttl: .topRated) }
        return items
    }

    func fetchStreamingMovies(page: Int = 1) async throws -> [MediaItem] {
        guard hasKeyForHome else {
            let skip = (page - 1) * 20 + 20
            return try await StremioService.shared.fetchCatalog(type: "movie", id: "top", skip: skip, preserveOrder: true)
        }
        
        let cacheKey = "movie:streaming:\(currentRegion):\(page)"
        if page == 1, let cached = await TMDBCatalogCacheActor.shared.get(key: cacheKey) { return cached }
        
        let urlString = "\(baseURL)/discover/movie?api_key=\(apiKey)&with_watch_monetization_types=flatrate&watch_region=\(currentRegion)&sort_by=popularity.desc&include_adult=false&vote_count.gte=30&page=\(page)"
        let items = try await fetchCatalog(from: urlString, type: "movie")
        if page == 1 { await TMDBCatalogCacheActor.shared.set(key: cacheKey, items: items, ttl: .discover) }
        return items
    }

    func fetchQuickWatchMovies(page: Int = 1) async throws -> [MediaItem] {
        guard hasKeyForHome else {
            let skip = (page - 1) * 20
            return (try? await StremioService.shared.fetchCatalog(type: "movie", id: "top", genre: "Animation", skip: skip, preserveOrder: true)) ?? []
        }
        
        let cacheKey = "movie:quick:\(page)"
        if page == 1, let cached = await TMDBCatalogCacheActor.shared.get(key: cacheKey) { return cached }
        
        let urlString = "\(baseURL)/discover/movie?api_key=\(apiKey)&with_runtime.lte=95&sort_by=popularity.desc&include_adult=false&vote_count.gte=50&page=\(page)"
        let items = try await fetchCatalog(from: urlString, type: "movie")
        if page == 1 { await TMDBCatalogCacheActor.shared.set(key: cacheKey, items: items, ttl: .discover) }
        return items
    }

    func fetchPopularTV(page: Int = 1) async throws -> [MediaItem] {
        guard hasKeyForHome else {
            let skip = (page - 1) * 20
            return try await StremioService.shared.fetchCatalog(type: "series", id: "top", skip: skip, preserveOrder: true)
        }
        
        let cacheKey = "tv:popular:\(page)"
        if page == 1, let cached = await TMDBCatalogCacheActor.shared.get(key: cacheKey) { return cached }
        
        let urlString = "\(baseURL)/discover/tv?api_key=\(apiKey)&sort_by=popularity.desc&without_genres=10763,10767&include_adult=false&vote_count.gte=10&page=\(page)"
        let items = try await fetchCatalog(from: urlString, type: "tv")
        if page == 1 { await TMDBCatalogCacheActor.shared.set(key: cacheKey, items: items, ttl: .popular) }
        return items
    }

    func fetchAiringTodayTV(page: Int = 1) async throws -> [MediaItem] {
        guard hasKeyForHome else { return [] }
        
        let cacheKey = "tv:airing_today:\(currentTimeZone):\(page)"
        if page == 1, let cached = await TMDBCatalogCacheActor.shared.get(key: cacheKey) { return cached }
        
        let urlString = "\(baseURL)/tv/airing_today?api_key=\(apiKey)&timezone=\(currentTimeZone)&page=\(page)"
        let items = try await fetchCatalog(from: urlString, type: "tv", allowUnreleased: true)
        if page == 1 { await TMDBCatalogCacheActor.shared.set(key: cacheKey, items: items, ttl: .airingToday) }
        return items
    }

    func fetchOnTheAirTV(page: Int = 1) async throws -> [MediaItem] {
        guard hasKeyForHome else { return [] }
        
        let cacheKey = "tv:on_the_air:\(currentTimeZone):\(page)"
        if page == 1, let cached = await TMDBCatalogCacheActor.shared.get(key: cacheKey) { return cached }
        
        let urlString = "\(baseURL)/tv/on_the_air?api_key=\(apiKey)&timezone=\(currentTimeZone)&page=\(page)"
        let items = try await fetchCatalog(from: urlString, type: "tv", allowUnreleased: true)
        if page == 1 { await TMDBCatalogCacheActor.shared.set(key: cacheKey, items: items, ttl: .nowPlaying) }
        return items
    }

    func fetchTopRatedTV(page: Int = 1) async throws -> [MediaItem] {
        guard hasKeyForHome else {
            return try await StremioService.shared.fetchTopRatedTVShows(page: page)
        }
        
        let cacheKey = "tv:top_rated:\(page)"
        if page == 1, let cached = await TMDBCatalogCacheActor.shared.get(key: cacheKey) { return cached }
        
        let urlString = "\(baseURL)/tv/top_rated?api_key=\(apiKey)&page=\(page)"
        let items = try await fetchCatalog(from: urlString, type: "tv")
        if page == 1 { await TMDBCatalogCacheActor.shared.set(key: cacheKey, items: items, ttl: .topRated) }
        return items
    }

    func fetchStreamingTV(page: Int = 1) async throws -> [MediaItem] {
        guard hasKeyForHome else {
            let skip = (page - 1) * 20 + 20
            return try await StremioService.shared.fetchCatalog(type: "series", id: "top", skip: skip, preserveOrder: true)
        }
        
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
            let items = response.results.compactMap { movie -> MediaItem? in
                guard movie.posterPath != nil || movie.backdropPath != nil else { return nil }
                return movie.toMediaItem()
            }
            return allowUnreleased ? items : items.filter { $0.isReleased }
        } else {
            let response = try JSONDecoder().decode(TMDBResponse<TMDBTVShow>.self, from: data)
            let filtered = response.results.filter { show in
                guard show.posterPath != nil || show.backdropPath != nil else { return false }
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

    /// Translates movie genre ID to its corresponding TV genre ID on TMDB when querying TV shows.
    private func resolvedGenreID(for genreID: Int, mediaType: String) -> Int {
        guard mediaType == "tv" else { return genreID }
        switch genreID {
        case 28: return 10759   // Action -> Action & Adventure
        case 12: return 10759   // Adventure -> Action & Adventure
        case 14: return 10765   // Fantasy -> Sci-Fi & Fantasy
        case 878: return 10765  // Sci-Fi -> Sci-Fi & Fantasy
        case 27: return 9648    // Horror -> Mystery (closest TV match)
        case 53: return 9648    // Thriller -> Mystery
        case 10749: return 18   // Romance -> Drama
        case 10752: return 10768 // War -> War & Politics
        default: return genreID
        }
    }

    /// TMDB discover by genre — real genre-accurate titles, page-based pagination
    /// (pages 1..500). Used by the genre pages for endless scroll and rails.
    func fetchGenrePage(tmdbGenreID: Int, page: Int, mediaType: String = "movie", category: String = "popular") async -> [MediaItem] {
        let type = mediaType.lowercased().contains("tv") || mediaType.lowercased().contains("series") ? "tv" : "movie"
        
        guard hasKeyForHome else {
            let stremioType = type == "tv" ? "series" : "movie"
            let genreName: String? = {
                switch tmdbGenreID {
                case 10001: return "Animation"
                case 10002: return "Drama"
                case 10003: return "Drama"
                case 10004: return "Drama"
                case 10005: return "Short"
                default: return TMDBGenreMapper.idToName[tmdbGenreID]
                }
            }()
            let skip = (page - 1) * 20
            switch category {
            case "top_rated":
                let items = (try? await StremioService.shared.fetchCatalog(type: stremioType, id: "top", genre: genreName, skip: skip, preserveOrder: false)) ?? []
                return items.sorted { ($0.voteAverage ?? 0) > ($1.voteAverage ?? 0) }
            case "new_releases":
                let currentYear = String(Calendar.current.component(.year, from: Date()))
                return (try? await StremioService.shared.fetchCatalog(type: stremioType, id: "year", genre: currentYear, skip: skip, preserveOrder: true)) ?? []
            case "trending":
                return (try? await StremioService.shared.fetchCatalog(type: stremioType, id: "imdbRating", genre: genreName, skip: skip, preserveOrder: true)) ?? []
            default: // "popular"
                return (try? await StremioService.shared.fetchCatalog(type: stremioType, id: "top", genre: genreName, skip: skip, preserveOrder: true)) ?? []
            }
        }
        let baseFilter: String
        switch tmdbGenreID {
        case 10001: // Anime
            baseFilter = "with_genres=16&with_original_language=ja"
        case 10002: // Bollywood
            baseFilter = "with_original_language=hi"
        case 10003: // Classics
            let dateParam = type == "tv" ? "first_air_date.lte=1980-01-01" : "primary_release_date.lte=1980-01-01"
            baseFilter = dateParam
        case 10004: // K-Drama
            baseFilter = "with_original_language=ko"
        case 10005: // Short Films
            baseFilter = "with_runtime.lte=40"
        default:
            let resolvedID = resolvedGenreID(for: tmdbGenreID, mediaType: type)
            baseFilter = "with_genres=\(resolvedID)"
        }

        let sortAndVoteParams: String
        let today = ISO8601DateFormatter().string(from: Date()).prefix(10)
        switch category {
        case "top_rated":
            let minVotes = type == "tv" ? 40 : 150
            sortAndVoteParams = "sort_by=vote_average.desc&vote_count.gte=\(minVotes)"
        case "new_releases":
            let dateField = type == "tv" ? "first_air_date" : "primary_release_date"
            sortAndVoteParams = "sort_by=\(dateField).desc&vote_count.gte=5&\(dateField).lte=\(today)"
        case "trending":
            let calendar = Calendar.current
            let twoYearsAgo = calendar.date(byAdding: .year, value: -2, to: Date()) ?? Date()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let dateStr = formatter.string(from: twoYearsAgo)
            let dateField = type == "tv" ? "first_air_date.gte" : "primary_release_date.gte"
            sortAndVoteParams = "sort_by=popularity.desc&vote_count.gte=20&\(dateField)=\(dateStr)"
        default: // "popular"
            let minVotes = type == "tv" ? 10 : 30
            sortAndVoteParams = "sort_by=popularity.desc&vote_count.gte=\(minVotes)"
        }

        let urlString = "\(baseURL)/discover/\(type)?api_key=\(apiKey)&\(baseFilter)&\(sortAndVoteParams)&page=\(page)&include_adult=false"
        return (try? await fetchCatalog(from: urlString, type: type)) ?? []
    }

    struct GenreRailsData {
        var trending: [MediaItem] = []
        var topRated: [MediaItem] = []
        var popular: [MediaItem] = []
        var newReleases: [MediaItem] = []
        
        var isEmpty: Bool {
            trending.isEmpty && topRated.isEmpty && popular.isEmpty && newReleases.isEmpty
        }
    }

    /// Fetches 4 curated discovery rails in parallel for a genre page
    func fetchGenreRails(tmdbGenreID: Int, mediaType: String = "movie") async -> GenreRailsData {
        let type = mediaType.lowercased().contains("tv") || mediaType.lowercased().contains("series") ? "tv" : "movie"
        async let tr = fetchGenrePage(tmdbGenreID: tmdbGenreID, page: 1, mediaType: type, category: "trending")
        async let top = fetchGenrePage(tmdbGenreID: tmdbGenreID, page: 1, mediaType: type, category: "top_rated")
        async let pop = fetchGenrePage(tmdbGenreID: tmdbGenreID, page: 1, mediaType: type, category: "popular")
        async let nr = fetchGenrePage(tmdbGenreID: tmdbGenreID, page: 1, mediaType: type, category: "new_releases")

        let (trendingItems, topRatedItems, popularItems, newReleaseItems) = await (tr, top, pop, nr)
        return GenreRailsData(
            trending: trendingItems,
            topRated: topRatedItems,
            popular: popularItems,
            newReleases: newReleaseItems
        )
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
        guard hasKeyForHome, let providerID = Self.tmdbProviderIDs[platformID] else { return [] }
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
    let id: Int?
    let episode_number: Int
    let name: String
    let overview: String
    let still_path: String?
    let runtime: Int?
    let air_date: String?
}
