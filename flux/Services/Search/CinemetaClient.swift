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

    var asMediaCandidate: MediaCandidate {
        asMediaCandidate(index: 0)
    }

    func asMediaCandidate(index: Int = 0) -> MediaCandidate {
        let rankPopularity = max(200.0 - Double(index) * 5.0, 10.0)
        let rankVoteCount = max(2000 - index * 50, 50)
        let syntheticVoteCount: Int
        let syntheticPopularity: Double
        if let rating = Double(imdbRating ?? ""), rating > 0 {
            syntheticVoteCount = max(Int(rating * 20), rankVoteCount)
            syntheticPopularity = max(rating * 15.0, rankPopularity)
        } else {
            syntheticVoteCount = rankVoteCount
            syntheticPopularity = rankPopularity
        }

        let sharpPoster: String? = {
            if id.hasPrefix("tt") {
                return "https://images.metahub.space/poster/large/\(id)/img"
            }
            return poster?.replacingOccurrences(of: "/poster/small/", with: "/poster/large/")
        }()

        let sharpBackdrop: String? = background?
            .replacingOccurrences(of: "/background/small/", with: "/background/large/")
            .replacingOccurrences(of: "/background/medium/", with: "/background/large/")

        return MediaCandidate(
            id: "cinemeta-\(id)",
            title: name,
            mediaType: type == "movie" ? .movie : .tvSeries,
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
        components.month = 1
        components.day = 1
        return Calendar(identifier: .gregorian).date(from: components)
    }
}
