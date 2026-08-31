import Foundation

// MARK: - Stremio Cinemeta Catalog Search Client

actor CinemetaClient {
    private let session: URLSession
    private let baseURL = "https://v3-cinemeta.strem.io"

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(query: String) async throws -> [MediaCandidate] {
        async let movies = fetch(type: "movie", query: query)
        async let series = fetch(type: "series", query: query)
        let (movieResults, seriesResults) = try await (movies, series)
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
        return decoded.metas.map { $0.asMediaCandidate }
    }
}

struct CinemetaCatalogResponse: Decodable, Sendable {
    let metas: [CinemetaMeta]
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

    var asMediaCandidate: MediaCandidate {
        let syntheticVoteCount: Int
        let syntheticPopularity: Double
        if let rating = Double(imdbRating ?? "") {
            syntheticVoteCount = 50
            syntheticPopularity = rating * 2
        } else {
            syntheticVoteCount = 0
            syntheticPopularity = 0
        }

        return MediaCandidate(
            id: "cinemeta-\(id)",
            title: name,
            mediaType: type == "movie" ? .movie : .tvSeries,
            popularity: syntheticPopularity,
            voteCount: syntheticVoteCount,
            voteAverage: Double(imdbRating ?? "") ?? 0,
            posterPath: poster,
            backdropPath: background,
            overview: description,
            releaseDate: Self.parseYear(from: releaseInfo),
            isAdult: false,
            imdbID: id,
            source: .cinemeta
        )
    }

    private static func parseYear(from releaseInfo: String?) -> Date? {
        guard let yearString = releaseInfo?.prefix(4), let year = Int(yearString) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = 1
        components.day = 1
        return Calendar(identifier: .gregorian).date(from: components)
    }
}
