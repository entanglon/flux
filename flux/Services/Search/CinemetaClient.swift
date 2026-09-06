import Foundation

// MARK: - Stremio Cinemeta Catalog Search Client

actor CinemetaClient {
    private let session: URLSession
    private let baseURL = "https://v3-cinemeta.strem.io"

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(query: String) async throws -> [MediaCandidate] {
        async let movies = (try? fetch(type: "movie", query: query)) ?? []
        async let series = (try? fetch(type: "series", query: query)) ?? []
        let (movieResults, seriesResults) = await (movies, series)
        return movieResults + seriesResults
    }

    private func fetch(type: String, query: String) async throws -> [MediaCandidate] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw SearchClientError.invalidURL
        }
        guard let url = URL(string: "\(baseURL)/catalog/\(type)/top/search=\(encoded).json") else {
            throw SearchClientError.invalidURL
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SearchClientError.badStatusCode((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let decoded = try JSONDecoder().decode(CinemetaCatalogResponse.self, from: data)
        return decoded.metas.enumerated().map { index, meta in
            meta.asMediaCandidate(index: index)
        }
    }
}

struct CinemetaCatalogResponse: Decodable, Sendable {
    let metas: [CinemetaMeta]
}

struct CinemetaPopularities: Decodable, Sendable {
    let moviedb: Double?
    let stremio: Double?
    let trakt: Double?
}

struct CinemetaMeta: Decodable, Sendable {
    let id: String              // imdb id, e.g. "tt0133093"
    let type: String            // "movie" | "series"
    let name: String
    let poster: String?
    let background: String?
    let description: String?
    let releaseInfo: String?
    let imdbRating: String?
    let genres: [String]?
    let popularities: CinemetaPopularities?

    init(
        id: String,
        type: String,
        name: String,
        poster: String? = nil,
        background: String? = nil,
        description: String? = nil,
        releaseInfo: String? = nil,
        imdbRating: String? = nil,
        genres: [String]? = nil,
        popularities: CinemetaPopularities? = nil
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.poster = poster
        self.background = background
        self.description = description
        self.releaseInfo = releaseInfo
        self.imdbRating = imdbRating
        self.genres = genres
        self.popularities = popularities
    }

    var asMediaCandidate: MediaCandidate {
        asMediaCandidate(index: 0)
    }

    func asMediaCandidate(index: Int = 0) -> MediaCandidate {
        let isMovie = type == "movie"
        // Power-law Pareto decay matching streaming distribution across catalog rank positions
        let decay = 1.0 / pow(Double(index + 1), 0.65)

        var multiplier = 1.0
        if let tmdbPop = popularities?.moviedb, tmdbPop > 0 {
            multiplier = max(multiplier, min(tmdbPop / 20.0, 2.5))
        }
        if let rating = Double(imdbRating ?? ""), rating > 0 {
            if rating >= 7.5 {
                multiplier *= 1.3
            } else if rating < 5.0 {
                multiplier *= 0.6
            }
        }

        let syntheticPopularity = 250.0 * decay * multiplier
        let syntheticVoteCount = max(Int(40_000.0 * decay * multiplier), 50)

        let sharpPoster: String? = {
            if let p = poster, !p.isEmpty {
                if p.contains("m.media-amazon.com") {
                    // Upgrade low-res Amazon thumbnail to retina standard
                    return p.replacingOccurrences(of: "._V1_SX250.jpg", with: "._V1_SX700.jpg")
                }
                return p.replacingOccurrences(of: "/poster/small/", with: "/poster/large/")
            }
            if id.hasPrefix("tt") {
                return "https://images.metahub.space/poster/large/\(id)/img"
            }
            return nil
        }()

        let sharpBackdrop: String? = background?
            .replacingOccurrences(of: "/background/small/", with: "/background/large/")
            .replacingOccurrences(of: "/background/medium/", with: "/background/large/")

        return MediaCandidate(
            id: "cinemeta-\(id)",
            title: name,
            mediaType: isMovie ? .movie : .tvSeries,
            popularity: syntheticPopularity,
            voteCount: syntheticVoteCount,
            voteAverage: Double(imdbRating ?? "") ?? 0,
            posterPath: sharpPoster ?? poster,
            backdropPath: sharpBackdrop ?? background,
            overview: description,
            releaseDate: Self.parseYear(from: releaseInfo),
            isAdult: false,
            imdbID: id,
            genres: genres,
            source: .cinemeta
        )
    }

    private static func parseYear(from releaseInfo: String?) -> Date? {
        guard let yearString = releaseInfo?.prefix(4), let year = Int(yearString) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = 12
        components.day = 31
        return Calendar(identifier: .gregorian).date(from: components)
    }
}
