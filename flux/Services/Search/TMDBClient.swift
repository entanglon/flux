import Foundation

// MARK: - TMDB /3/search/multi Client with Cooperative Task Cancellation

actor TMDBClient {
    private let apiKeyProvider: @Sendable () -> String
    private let session: URLSession

    init(apiKey: String? = nil, session: URLSession = .shared) {
        if let key = apiKey {
            self.apiKeyProvider = { key }
        } else {
            self.apiKeyProvider = {
                let userKey = UserDefaults.standard.string(forKey: UserDefaults.Key.tmdbApiKey) ?? ""
                return userKey.isEmpty ? Secrets.tmdbAPIKey : userKey
            }
        }
        self.session = session
    }

    func multiSearch(query: String) async throws -> [MediaCandidate] {
        let key = apiKeyProvider()
        guard !key.isEmpty else { return [] }
        
        var components = URLComponents(string: "https://api.themoviedb.org/3/search/multi")
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "language", value: "en-US"),
            URLQueryItem(name: "api_key", value: key)
        ]

        guard let url = components?.url else { throw SearchClientError.invalidURL }

        // `data(from:)` cooperatively observes Task cancellation and throws
        // promptly rather than letting superseded requests execute to completion.
        let (data, response) = try await session.data(from: url)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SearchClientError.badStatusCode((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let decoded = try JSONDecoder().decode(TMDBMultiSearchResponse.self, from: data)
        return decoded.results.compactMap { $0.asMediaCandidate }
    }
}

enum SearchClientError: Error {
    case invalidURL
    case badStatusCode(Int)
}

// MARK: - Wire Format Decoders

struct TMDBMultiSearchResponse: Decodable, Sendable {
    let results: [TMDBResult]
}

struct TMDBResult: Decodable, Sendable {
    let id: Int
    let mediaType: String?
    let title: String?
    let name: String?
    let popularity: Double?
    let voteCount: Int?
    let voteAverage: Double?
    let posterPath: String?
    let backdropPath: String?
    let overview: String?
    let releaseDate: String?
    let firstAirDate: String?
    let adult: Bool?
    let genreIds: [Int]?

    enum CodingKeys: String, CodingKey {
        case id, title, name, popularity, adult, overview
        case mediaType = "media_type"
        case voteCount = "vote_count"
        case voteAverage = "vote_average"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case genreIds = "genre_ids"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    var asMediaCandidate: MediaCandidate? {
        guard let mediaType, mediaType == "movie" || mediaType == "tv" else { return nil }
        guard let name = (title ?? name)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }

        let dateString = releaseDate ?? firstAirDate
        let parsedDate = dateString.flatMap { Self.dateFormatter.date(from: $0) }

        return MediaCandidate(
            id: "tmdb-\(id)",
            title: name,
            mediaType: mediaType == "movie" ? .movie : .tvSeries,
            popularity: popularity ?? 0,
            voteCount: voteCount ?? 0,
            voteAverage: voteAverage ?? 0,
            posterPath: posterPath,
            backdropPath: backdropPath,
            overview: overview,
            releaseDate: parsedDate,
            isAdult: adult ?? false,
            imdbID: nil,
            genres: TMDBGenreMapper.names(for: genreIds),
            source: .tmdb
        )
    }
}
