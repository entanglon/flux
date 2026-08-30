import Foundation

// MARK: - Generic Response
struct TMDBResponse<T: Codable>: Codable {
    let page: Int
    let results: [T]
    let totalPages: Int
    let totalResults: Int
    
    enum CodingKeys: String, CodingKey {
        case page, results
        case totalPages = "total_pages"
        case totalResults = "total_results"
    }
}

// MARK: - Genre Mapper
enum TMDBGenreMapper {
    static let idToName: [Int: String] = [
        28: "Action",
        12: "Adventure",
        16: "Animation",
        35: "Comedy",
        80: "Crime",
        99: "Documentary",
        18: "Drama",
        10751: "Family",
        14: "Fantasy",
        36: "History",
        27: "Horror",
        10402: "Music",
        9648: "Mystery",
        10749: "Romance",
        878: "Sci-Fi",
        10770: "TV Movie",
        53: "Thriller",
        10752: "War",
        37: "Western",
        10759: "Action & Adventure",
        10762: "Kids",
        10763: "News",
        10764: "Reality",
        10765: "Sci-Fi & Fantasy",
        10766: "Soap",
        10767: "Talk",
        10768: "War & Politics"
    ]
    
    static func names(for ids: [Int]?) -> [String]? {
        guard let ids = ids, !ids.isEmpty else { return nil }
        let mapped = ids.compactMap { idToName[$0] }
        return mapped.isEmpty ? nil : mapped
    }
}

// MARK: - Trending Combined
struct TMDBTrendingResponse: Codable {
    let results: [TMDBTrendingItem]
}

struct TMDBTrendingItem: Codable {
    let id: Int
    let mediaType: String
    let title: String?
    let name: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let popularity: Double?
    let voteAverage: Double?
    let genreIds: [Int]?
    
    enum CodingKeys: String, CodingKey {
        case id, overview, popularity
        case mediaType = "media_type"
        case title, name
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
        case genreIds = "genre_ids"
    }
    
    func toMediaItem() -> MediaItem {
        let isMovie = mediaType == "movie"
        return MediaItem(
            id: String(id),
            title: (isMovie ? title : name) ?? "Untitled",
            description: overview ?? "",
            imageURL: TMDBEnricher.shared.adaptiveURL(path: backdropPath, quality: .backdrop) ?? TMDBEnricher.shared.adaptiveURL(path: posterPath, quality: .poster),
            posterURL: TMDBEnricher.shared.adaptiveURL(path: posterPath, quality: .poster),
            backdropURL: TMDBEnricher.shared.adaptiveURL(path: backdropPath, quality: .backdrop),
            heroURL: TMDBEnricher.shared.adaptiveURL(path: backdropPath, quality: .automatic),
            streamURL: nil,
            category: isMovie ? "Movie" : "TV Show",
            progress: nil,
            trailerURL: nil,
            cast: nil,
            seasons: nil,
            runtime: nil,
            certification: nil,
            genres: TMDBGenreMapper.names(for: genreIds),
            popularity: popularity,
            releaseDate: isMovie ? releaseDate : firstAirDate,
            spokenLanguages: nil,
            originCountry: nil,
            voteAverage: voteAverage
        )
    }
}

// MARK: - Movie
struct TMDBMovie: Codable, Identifiable {
    let id: Int
    let title: String
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let voteAverage: Double?
    let popularity: Double?
    let genreIds: [Int]?
    
    init(
        id: Int,
        title: String,
        overview: String? = nil,
        posterPath: String? = nil,
        backdropPath: String? = nil,
        releaseDate: String? = nil,
        voteAverage: Double? = nil,
        popularity: Double? = nil,
        genreIds: [Int]? = nil
    ) {
        self.id = id
        self.title = title
        self.overview = overview
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.releaseDate = releaseDate
        self.voteAverage = voteAverage
        self.popularity = popularity
        self.genreIds = genreIds
    }
    
    enum CodingKeys: String, CodingKey {
        case id, title, overview, popularity
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case voteAverage = "vote_average"
        case genreIds = "genre_ids"
    }
    
    nonisolated var posterURL: URL? {
        TMDBEnricher.shared.adaptiveURL(path: posterPath, quality: .poster)
    }
    
    nonisolated var backdropURL: URL? {
        TMDBEnricher.shared.adaptiveURL(path: backdropPath, quality: .backdrop)
    }
    
    nonisolated var heroURL: URL? {
        TMDBEnricher.shared.adaptiveURL(path: backdropPath, quality: .automatic)
    }
}

// MARK: - TV Show
struct TMDBTVShow: Codable, Identifiable {
    let id: Int
    let name: String
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let popularity: Double?
    let genreIds: [Int]?
    
    init(
        id: Int,
        name: String,
        overview: String? = nil,
        posterPath: String? = nil,
        backdropPath: String? = nil,
        firstAirDate: String? = nil,
        voteAverage: Double? = nil,
        popularity: Double? = nil,
        genreIds: [Int]? = nil
    ) {
        self.id = id
        self.name = name
        self.overview = overview
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.firstAirDate = firstAirDate
        self.voteAverage = voteAverage
        self.popularity = popularity
        self.genreIds = genreIds
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, overview, popularity
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
        case genreIds = "genre_ids"
    }
    
    nonisolated var posterURL: URL? {
        TMDBEnricher.shared.adaptiveURL(path: posterPath, quality: .poster)
    }
    
    nonisolated var backdropURL: URL? {
        TMDBEnricher.shared.adaptiveURL(path: backdropPath, quality: .backdrop)
    }
    
    nonisolated var heroURL: URL? {
        TMDBEnricher.shared.adaptiveURL(path: backdropPath, quality: .automatic)
    }
}

// MARK: - Credits
struct TMDBCredits: Codable {
    let cast: [TMDBCastMember]
    let crew: [TMDBCrewMember]
}

struct TMDBCastMember: Codable, Identifiable {
    let id: Int
    let name: String
    let character: String
    let profilePath: String?
    
    enum CodingKeys: String, CodingKey {
        case id, name, character
        case profilePath = "profile_path"
    }
    
    nonisolated var profileURL: URL? {
        guard let path = profilePath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500\(path)")
    }
}

struct TMDBCrewMember: Codable, Identifiable {
    let id: Int
    let name: String
    let job: String
    let profilePath: String?

    enum CodingKeys: String, CodingKey {
        case id, name, job
        case profilePath = "profile_path"
    }
}

// MARK: - New Episode Detection
struct TMDBLastEpisodeInfo: Codable {
    let lastEpisodeToAir: TMDBLastEpisode?

    enum CodingKeys: String, CodingKey {
        case lastEpisodeToAir = "last_episode_to_air"
    }
}

struct TMDBLastEpisode: Codable {
    let airDate: String?

    enum CodingKeys: String, CodingKey {
        case airDate = "air_date"
    }
}

// MARK: - Person Pages

struct TMDBPersonDetail: Codable {
    let id: Int
    let name: String
    let biography: String?
    let birthday: String?
    let deathday: String?
    let placeOfBirth: String?
    let knownForDepartment: String?
    let profilePath: String?
    let popularity: Double?

    enum CodingKeys: String, CodingKey {
        case id, name, biography, birthday, deathday, popularity
        case placeOfBirth = "place_of_birth"
        case knownForDepartment = "known_for_department"
        case profilePath = "profile_path"
    }

    nonisolated var profileURL: URL? {
        guard let path = profilePath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/h632\(path)")
    }
}

struct TMDBCombinedCredits: Codable {
    let cast: [TMDBCreditItem]
}

struct TMDBCreditItem: Codable {
    let id: Int?
    let mediaType: String?
    let title: String?
    let name: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let popularity: Double?
    let character: String?

    enum CodingKeys: String, CodingKey {
        case id, title, name, overview, character, popularity
        case mediaType = "media_type"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
    }
}

// MARK: - Videos
struct TMDBVideoResponse: Codable {
    let id: Int
    let results: [TMDBVideo]
}

struct TMDBVideo: Codable, Identifiable, Hashable {
    let id: String
    let key: String
    let name: String
    let site: String
    let type: String
    let official: Bool?
    let publishedAt: String?
    
    enum CodingKeys: String, CodingKey {
        case id, key, name, site, type, official
        case publishedAt = "published_at"
    }
    
    var thumbnailURL: URL? { URL(string: "https://img.youtube.com/vi/\(key)/hqdefault.jpg") }
    var maxResThumbnailURL: URL? { URL(string: "https://img.youtube.com/vi/\(key)/maxresdefault.jpg") }
    var youtubeURL: URL? { URL(string: "https://www.youtube.com/watch?v=\(key)") }
    var embedURL: URL? { URL(string: "https://www.youtube-nocookie.com/embed/\(key)?autoplay=1&rel=0&modestbranding=1&playsinline=1") }
}

// MARK: - Watch Providers
struct TMDBWatchProviderResponse: Codable {
    let id: Int
    let results: [String: TMDBProviderRegion]
}

struct TMDBProviderRegion: Codable {
    let link: String?
    let flatrate: [TMDBWatchProvider]?
    let rent: [TMDBWatchProvider]?
    let buy: [TMDBWatchProvider]?
}

struct TMDBWatchProvider: Codable, Identifiable {
    let provider_id: Int
    let provider_name: String
    let logo_path: String?
    
    var id: Int { provider_id }
    
    nonisolated var logoURL: URL? {
        guard let path = logo_path else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500\(path)")
    }
    
    nonisolated func externalURL(for title: String) -> URL? {
        let titleString = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        
        switch provider_name.lowercased() {
        case let name where name.contains("netflix"):
            return URL(string: "https://www.netflix.com/search?q=\(titleString)")
        case let name where name.contains("amazon") || name.contains("prime"):
            return URL(string: "https://www.amazon.com/s?k=\(titleString)")
        case let name where name.contains("disney"):
            return URL(string: "https://www.disneyplus.com/search?q=\(titleString)")
        case let name where name.contains("apple") || name.contains("tv+"):
            return URL(string: "https://tv.apple.com/search?term=\(titleString)")
        case let name where name.contains("hulu"):
            return URL(string: "https://www.hulu.com/search?q=\(titleString)")
        case let name where name.contains("hbo") || name.contains("max"):
            return URL(string: "https://play.max.com/search?q=\(titleString)")
        case let name where name.contains("peacock"):
            return URL(string: "https://www.peacocktv.com/search?q=\(titleString)")
        case let name where name.contains("paramount"):
             return URL(string: "https://www.paramountplus.com/search/?q=\(titleString)")
        default:
             // Fallback to Google Search
             return URL(string: "https://www.google.com/search?q=watch+\(titleString)+on+\(provider_name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
        }
    }
}

// MARK: - Details
struct TMDBGenre: Codable, Identifiable {
    let id: Int
    let name: String
}

struct TMDBSpokenLanguage: Codable {
    let english_name: String
    let iso_639_1: String
    let name: String
}

struct TMDBProductionCountry: Codable {
    let iso_3166_1: String
    let name: String
}

struct TMDBMovieDetail: Codable, Identifiable {
    let id: Int
    let title: String
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let voteAverage: Double?
    let runtime: Int?
    let genres: [TMDBGenre]?
    let spokenLanguages: [TMDBSpokenLanguage]?
    let productionCountries: [TMDBProductionCountry]?
    
    enum CodingKeys: String, CodingKey {
        case id, title, overview, genres, runtime
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case voteAverage = "vote_average"
        case spokenLanguages = "spoken_languages"
        case productionCountries = "production_countries"
    }
    
    nonisolated var posterURL: URL? {
        TMDBEnricher.shared.adaptiveURL(path: posterPath, quality: .poster)
    }
    
    nonisolated var backdropURL: URL? {
        TMDBEnricher.shared.adaptiveURL(path: backdropPath, quality: .backdrop)
    }
    
    nonisolated var heroURL: URL? {
        TMDBEnricher.shared.adaptiveURL(path: backdropPath, quality: .automatic)
    }
    
    nonisolated func toMediaItem() -> MediaItem {
        MediaItem(
            id: String(id),
            title: title,
            description: overview ?? "",
            imageURL: backdropURL ?? posterURL,
            posterURL: posterURL,
            backdropURL: backdropURL,
            heroURL: heroURL,
            streamURL: nil,
            category: "Movie",
            progress: nil,
            trailerURL: nil,
            cast: nil,
            seasons: nil,
            runtime: runtime.map { "\($0 / 60)h \($0 % 60)m" },
            certification: nil, 
            genres: genres?.map { $0.name },
            popularity: nil,
            releaseDate: releaseDate,
            spokenLanguages: spokenLanguages?.map { $0.english_name },
            originCountry: productionCountries?.first?.name,
            voteAverage: voteAverage
        )
    }
}

struct TMDBTVShowDetail: Codable, Identifiable {
    let id: Int
    let name: String
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let genres: [TMDBGenre]?
    let seasons: [TMDBSeasonSummary]?
    let spokenLanguages: [TMDBSpokenLanguage]?
    let productionCountries: [TMDBProductionCountry]?
    
    enum CodingKeys: String, CodingKey {
        case id, name, overview, genres, seasons
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
        case spokenLanguages = "spoken_languages"
        case productionCountries = "production_countries"
    }
    
    nonisolated var posterURL: URL? {
        TMDBEnricher.shared.adaptiveURL(path: posterPath, quality: .poster)
    }
    
    nonisolated var backdropURL: URL? {
        TMDBEnricher.shared.adaptiveURL(path: backdropPath, quality: .backdrop)
    }
    
    nonisolated var heroURL: URL? {
        TMDBEnricher.shared.adaptiveURL(path: backdropPath, quality: .automatic)
    }
    
    nonisolated func toMediaItem() -> MediaItem {
        MediaItem(
            id: String(id),
            title: name,
            description: overview ?? "",
            imageURL: backdropURL ?? posterURL,
            posterURL: posterURL,
            backdropURL: backdropURL,
            heroURL: heroURL,
            streamURL: nil,
            category: "TV Show",
            progress: nil,
            trailerURL: nil,
            cast: nil,
            seasons: seasons?.map { $0.toSeason() },
            runtime: nil,
            certification: nil,
            genres: genres?.map { $0.name },
            popularity: nil,
            releaseDate: firstAirDate,
            spokenLanguages: spokenLanguages?.map { $0.english_name },
            originCountry: productionCountries?.first?.name,
            voteAverage: voteAverage
        )
    }
}

struct TMDBSeasonSummary: Codable, Identifiable {
    let id: Int
    let name: String
    let overview: String?
    let posterPath: String?
    let seasonNumber: Int
    let episodeCount: Int
    
    enum CodingKeys: String, CodingKey {
        case id, name, overview
        case posterPath = "poster_path"
        case seasonNumber = "season_number"
        case episodeCount = "episode_count"
    }
    
    nonisolated func toSeason() -> Season {
        Season(
            id: id,
            name: name,
            overview: overview,
            posterURL: posterPath != nil ? URL(string: "https://image.tmdb.org/t/p/w500\(posterPath!)") : nil,
            seasonNumber: seasonNumber,
            episodeCount: episodeCount,
            episodes: nil // Fetched separately
        )
    }
}

struct TMDBSeasonDetail: Codable {
    let id: String
    let name: String
    let episodes: [TMDBEpisode]
    
    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case name, episodes
    }
}

struct TMDBEpisode: Codable, Identifiable {
    let id: Int
    let name: String
    let overview: String
    let stillPath: String?
    let episodeNumber: Int
    let seasonNumber: Int
    let airDate: String?
    let runtime: Int?
    
    enum CodingKeys: String, CodingKey {
        case id, name, overview
        case stillPath = "still_path"
        case episodeNumber = "episode_number"
        case seasonNumber = "season_number"
        case airDate = "air_date"
        case runtime = "runtime"
    }
    
    nonisolated func toEpisode() -> Episode {
        Episode(
            id: id,
            name: name,
            overview: overview,
            stillURL: stillPath != nil ? URL(string: "https://image.tmdb.org/t/p/w500\(stillPath!)") : nil, // Thumbnail
            heroURL: stillPath != nil ? URL(string: "https://image.tmdb.org/t/p/w1280\(stillPath!)") : nil, // Hero Quality
            episodeNumber: episodeNumber,
            seasonNumber: seasonNumber,
            airDate: airDate,
            runtime: runtime
        )
    }
}

// MARK: - Extensions for MediaItem Conversion
extension TMDBMovie {
    nonisolated func toMediaItem() -> MediaItem {
        MediaItem(
            id: String(id),
            title: title,
            description: overview ?? "",
            imageURL: backdropURL ?? posterURL,
            posterURL: posterURL,
            backdropURL: backdropURL,
            heroURL: backdropPath != nil ? URL(string: "https://image.tmdb.org/t/p/w1280\(backdropPath!)") : nil,
            streamURL: nil,
            category: "Movie",
            progress: nil,
            trailerURL: nil,
            cast: nil,
            seasons: nil,
            runtime: nil,
            certification: nil,
            genres: TMDBGenreMapper.names(for: genreIds),
            popularity: popularity,
            releaseDate: releaseDate,
            voteAverage: voteAverage
        )
    }
}

extension TMDBTVShow {
    nonisolated func toMediaItem() -> MediaItem {
        MediaItem(
            id: String(id),
            title: name,
            description: overview ?? "",
            imageURL: backdropURL ?? posterURL,
            posterURL: posterURL,
            backdropURL: backdropURL,
            heroURL: backdropPath != nil ? URL(string: "https://image.tmdb.org/t/p/w1280\(backdropPath!)") : nil,
            streamURL: nil,
            category: "TV Show",
            progress: nil,
            trailerURL: nil,
            cast: nil,
            seasons: nil,
            runtime: nil,
            certification: nil,
            genres: TMDBGenreMapper.names(for: genreIds),
            popularity: popularity,
            releaseDate: firstAirDate,
            voteAverage: voteAverage
        )
    }
}
