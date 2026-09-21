import Foundation

// MARK: - TMDB /3/search/multi Client with Cooperative Task Cancellation

struct MultiSearchResult: Sendable {
    let candidates: [MediaCandidate]
    let people: [PersonCandidate]
}

actor TMDBClient {
    static let shared = TMDBClient()
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

    func multiSearch(query: String) async throws -> MultiSearchResult {
        let initialResults = try await performMultiSearch(query: query)
        if !initialResults.candidates.isEmpty || !initialResults.people.isEmpty {
            return initialResults
        }

        // Typo & Variation Recovery Layer
        // 1. Plural / Suffix stemming (e.g. "avatar the way of waters" -> "avatar the way of water")
        let tokens = query.split(separator: " ").map(String.init)
        if tokens.contains(where: { $0.count > 3 && ($0.hasSuffix("s") || $0.hasSuffix("es")) }) {
            let singularTokens = tokens.map { word -> String in
                if word.count > 4 && word.hasSuffix("es") {
                    return String(word.dropLast(2))
                } else if word.count > 3 && word.hasSuffix("s") && !word.hasSuffix("ss") {
                    return String(word.dropLast())
                }
                return word
            }
            let singularQuery = singularTokens.joined(separator: " ")
            if singularQuery != query {
                let singularResults = try await performMultiSearch(query: singularQuery)
                if !singularResults.candidates.isEmpty || !singularResults.people.isEmpty {
                    return singularResults
                }
            }
        }

        // 2. Stop-word stripping for multi-word queries (e.g. "avatar the way of water" -> "avatar way water")
        if tokens.count >= 3 {
            let stopWords: Set<String> = ["the", "a", "an", "of", "in", "on", "at", "to", "for", "and"]
            let stripped = tokens.filter { !stopWords.contains($0.lowercased()) }.joined(separator: " ")
            if !stripped.isEmpty && stripped != query {
                let strippedResults = try await performMultiSearch(query: stripped)
                if !strippedResults.candidates.isEmpty || !strippedResults.people.isEmpty {
                    return strippedResults
                }
            }
        }

        return MultiSearchResult(candidates: [], people: [])
    }

    private func performMultiSearch(query: String) async throws -> MultiSearchResult {
        let key = apiKeyProvider()
        guard !key.isEmpty else { return MultiSearchResult(candidates: [], people: []) }
        
        let tmdbLang = await MainActor.run {
            let appLang = UserDefaults.standard.string(forKey: UserDefaults.Key.appLanguage) ?? "en"
            return AppLanguage(rawValue: appLang)?.tmdbCode ?? "en-US"
        }
        var components = URLComponents(string: "https://api.themoviedb.org/3/search/multi")
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "language", value: tmdbLang),
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
        var candidates: [MediaCandidate] = []
        var people: [PersonCandidate] = []

        for res in decoded.results {
            if let candidate = res.asMediaCandidate {
                candidates.append(candidate)
            } else if let person = res.asPersonCandidate {
                people.append(person)
                // Surface the actor's top known_for titles into the candidates list
                if let known = res.knownFor {
                    for k in known {
                        if let knownCand = k.asMediaCandidate {
                            candidates.append(knownCand)
                        }
                    }
                }
            }
        }

        return MultiSearchResult(candidates: candidates, people: people)
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
    let profilePath: String?
    let knownForDepartment: String?
    let knownFor: [TMDBResult]?

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
        case profilePath = "profile_path"
        case knownForDepartment = "known_for_department"
        case knownFor = "known_for"
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

    var asPersonCandidate: PersonCandidate? {
        guard mediaType == "person" else { return nil }
        guard let personName = (name ?? title)?.trimmingCharacters(in: .whitespacesAndNewlines), !personName.isEmpty else {
            return nil
        }
        let titles = (knownFor ?? []).compactMap { ($0.title ?? $0.name)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return PersonCandidate(
            id: id,
            name: personName,
            profilePath: profilePath,
            knownForDepartment: knownForDepartment,
            knownForTitles: titles,
            popularity: popularity ?? 0.0
        )
    }
}
