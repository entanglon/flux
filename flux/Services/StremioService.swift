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
    let description: String?
    let releaseInfo: String?
    let imdbRating: String?
}

struct StremioVideo: Codable {
    let id: String
    let title: String?
    let name: String?
    let description: String?
    let released: String? // "YYYY-MM-DD"
    let season: Int?
    let episode: Int?
    let thumbnail: String?
}

struct StremioMetaDetail: Codable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let background: String?
    let description: String?
    let releaseInfo: String?
    let imdbRating: String?
    let runtime: String?
    let cast: [String]?
    let director: [String]?
    let genres: [String]?
    let videos: [StremioVideo]?
}

class StremioService {
    static let shared = StremioService()
    
    // Cinemeta Addon URL (Default Stremio Meta and Catalog Addon)
    private let cinemetaURL = "https://v3-cinemeta.strem.io"
    
    private init() {}
    
    // MARK: - Catalogs Fetching
    func fetchCatalog(baseURL: String? = nil, type: String, id: String, sector: String? = nil, genre: String? = nil, search: String? = nil, skip: Int = 0) async throws -> [MediaItem] {
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
        return catalogResponse.metas.map { $0.toMediaItem() }
    }
    
    // MARK: - Meta Fetching
    func fetchMeta(type: String, id: String) async throws -> MediaItem {
        let urlString = "\(cinemetaURL)/meta/\(type)/\(id).json"
        
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        let metaResponse = try JSONDecoder().decode(StremioMetaResponse.self, from: data)
        return metaResponse.meta.toMediaItem()
    }
    
    // Legacy API Maps (Translating old TMDB calls to Cinemeta catalogs)
    func fetchTrendingMovies() async throws -> [MediaItem] {
        return try await fetchCatalog(type: "movie", id: "top")
    }
    func fetchPopularMovies() async throws -> [MediaItem] {
        return try await fetchCatalog(type: "movie", id: "top", skip: 20) // Simulated offset
    }
    func fetchTrendingTVShows() async throws -> [MediaItem] {
        return try await fetchCatalog(type: "series", id: "top")
    }
    func fetchPopularTVShows() async throws -> [MediaItem] {
         return try await fetchCatalog(type: "series", id: "top", skip: 20)
    }
    func searchMulti(query: String) async throws -> (movies: [MediaItem], tvShows: [MediaItem]) {
        async let movies = fetchCatalog(type: "movie", id: "top", search: query)
        async let tvShows = fetchCatalog(type: "series", id: "top", search: query)
        return try await (movies, tvShows)
    }
    
    func fetchRelated(type: String, genres: [String]?) async throws -> [MediaItem] {
        guard let genres = genres, let primaryGenre = genres.first else {
            return try await fetchCatalog(type: type, id: "top")
        }
        
        // Fetch from the same primary genre
        return try await fetchCatalog(type: type, id: "top", genre: primaryGenre)
    }
}

// MARK: - Extensions to Convert to MediaItem
extension StremioMetaPreview {
    func toMediaItem() -> MediaItem {
        return MediaItem(
            id: self.id,
            title: self.name,
            description: self.description ?? "",
            imageURL: nil,
            posterURL: self.poster != nil ? URL(string: self.poster!) : nil,
            backdropURL: self.background != nil ? URL(string: self.background!) : nil,
            heroURL: nil,
            streamURL: nil,
            category: self.type == "series" ? "TV Show" : "Movie",
            releaseDate: self.releaseInfo,
            voteAverage: (Double(self.imdbRating ?? "") ?? 0.0) > 0.0 ? Double(self.imdbRating ?? "") : nil
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
            episodesArray = vids.compactMap { vid -> Episode? in
                guard let sn = vid.season, let en = vid.episode else { return nil }
                let epName = vid.name ?? vid.title ?? "Episode \(en)"
                // Make sure id maps to an Int, if vid.id is string, we can hash it
                let epId = Int(vid.id.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? vid.id.hashValue
                return Episode(
                    id: epId,
                    name: epName,
                    overview: vid.description ?? "",
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
            posterURL: self.poster != nil ? URL(string: self.poster!) : nil,
            backdropURL: self.background != nil ? URL(string: self.background!) : nil,
            heroURL: nil,
            streamURL: nil,
            category: self.type == "series" ? "TV Show" : "Movie",
            cast: finalCast,
            director: self.director?.joined(separator: ", "),
            seasons: seasonsArray,
            runtime: self.runtime,
            genres: self.genres,
            releaseDate: self.releaseInfo,
            voteAverage: (Double(self.imdbRating ?? "") ?? 0.0) > 0.0 ? Double(self.imdbRating ?? "") : nil,
            episodes: episodesArray
        )
    }
}
