import Foundation

class TMDBService {
    static let shared = TMDBService()
    private let baseURL = "https://api.themoviedb.org/3"
    private var apiKey: String {
        let key = UserDefaults.standard.string(forKey: "tmdbApiKey") ?? ""
        return key.isEmpty ? Secrets.tmdbAPIKey : key
    }
    
    private init() {}
    
    // MARK: - Generic Fetch
    private func fetch<T: Codable>(endpoint: String, parameters: [String: String] = [:]) async throws -> T {
        guard var components = URLComponents(string: baseURL + endpoint) else {
            throw URLError(.badURL)
        }
        
        var queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        for (key, value) in parameters {
            queryItems.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = queryItems
        
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        
        let (data, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
    }
    
    // MARK: - Movies
    func fetchTrendingMovies(page: Int = 1) async throws -> [TMDBMovie] {
        let response: TMDBResponse<TMDBMovie> = try await fetch(endpoint: "/trending/movie/week", parameters: ["page": String(page)])
        return response.results
    }
    
    func fetchPopularMovies(page: Int = 1) async throws -> [TMDBMovie] {
        let response: TMDBResponse<TMDBMovie> = try await fetch(endpoint: "/movie/popular", parameters: ["page": String(page)])
        return response.results
    }

    func fetchNowPlayingMovies(page: Int = 1) async throws -> [TMDBMovie] {
        let response: TMDBResponse<TMDBMovie> = try await fetch(endpoint: "/movie/now_playing", parameters: ["page": String(page)])
        return response.results
    }
    
    func fetchUpcomingMovies(page: Int = 1) async throws -> [TMDBMovie] {
        let response: TMDBResponse<TMDBMovie> = try await fetch(endpoint: "/movie/upcoming", parameters: ["page": String(page)])
        return response.results
    }
    
    func fetchTopRatedMovies(page: Int = 1) async throws -> [TMDBMovie] {
        let response: TMDBResponse<TMDBMovie> = try await fetch(endpoint: "/movie/top_rated", parameters: ["page": String(page)])
        return response.results
    }
    
    // MARK: - TV Shows
    func fetchTrendingTVShows(page: Int = 1) async throws -> [TMDBTVShow] {
        let response: TMDBResponse<TMDBTVShow> = try await fetch(endpoint: "/trending/tv/week", parameters: ["page": String(page)])
        return response.results
    }
    
    func fetchPopularTVShows(page: Int = 1) async throws -> [TMDBTVShow] {
        let response: TMDBResponse<TMDBTVShow> = try await fetch(endpoint: "/tv/popular", parameters: ["page": String(page)])
        return response.results
    }
    
    func fetchAiringTodayTV(page: Int = 1) async throws -> [TMDBTVShow] {
        let response: TMDBResponse<TMDBTVShow> = try await fetch(endpoint: "/tv/airing_today", parameters: ["page": String(page)])
        return response.results
    }
    
    func fetchOnTheAirTV(page: Int = 1) async throws -> [TMDBTVShow] {
        let response: TMDBResponse<TMDBTVShow> = try await fetch(endpoint: "/tv/on_the_air", parameters: ["page": String(page)])
        return response.results
    }
    
    // MARK: - Search
    func searchMovies(query: String) async throws -> [TMDBMovie] {
        let response: TMDBResponse<TMDBMovie> = try await fetch(endpoint: "/search/movie", parameters: ["query": query])
        return response.results
    }
    
    func searchTVShows(query: String) async throws -> [TMDBTVShow] {
        let response: TMDBResponse<TMDBTVShow> = try await fetch(endpoint: "/search/tv", parameters: ["query": query])
        return response.results
    }
    
    func searchMulti(query: String) async throws -> (movies: [TMDBMovie], tvShows: [TMDBTVShow]) {
        async let movies = searchMovies(query: query)
        async let tvShows = searchTVShows(query: query)
        return try await (movies, tvShows)
    }
    
    func fetchMoviesByGenre(genreId: Int, page: Int = 1) async throws -> [TMDBMovie] {
        let response: TMDBResponse<TMDBMovie> = try await fetch(endpoint: "/discover/movie", parameters: ["with_genres": String(genreId), "sort_by": "popularity.desc", "page": String(page)])
        return response.results
    }
    
    // MARK: - Regional Content
    func fetchKDrama(page: Int = 1) async throws -> [TMDBTVShow] {
        let response: TMDBResponse<TMDBTVShow> = try await fetch(endpoint: "/discover/tv", parameters: ["with_original_language": "ko", "sort_by": "popularity.desc", "page": String(page)])
        return response.results
    }
    
    func fetchChineseMovies(page: Int = 1) async throws -> [TMDBMovie] {
        let response: TMDBResponse<TMDBMovie> = try await fetch(endpoint: "/discover/movie", parameters: ["with_original_language": "zh", "sort_by": "popularity.desc", "page": String(page)])
        return response.results
    }
    
    func fetchBollywoodMovies(page: Int = 1) async throws -> [TMDBMovie] {
        let response: TMDBResponse<TMDBMovie> = try await fetch(endpoint: "/discover/movie", parameters: ["with_original_language": "hi", "sort_by": "popularity.desc", "page": String(page)])
        return response.results
    }
    
    // MARK: - Providers
    // Fetch popular movies for a specific provider (e.g. Netflix = 8)
    func fetchMovies(byProviderId id: Int, page: Int = 1) async throws -> [TMDBMovie] {
        let response: TMDBResponse<TMDBMovie> = try await fetch(endpoint: "/discover/movie", parameters: [
            "with_watch_providers": String(id),
            "watch_region": "US", // Default to US for broader results
            "sort_by": "popularity.desc",
            "page": String(page)
        ])
        return response.results
    }
    
    // Fetch popular TV shows for a specific provider
    func fetchTV(byProviderId id: Int, page: Int = 1) async throws -> [TMDBTVShow] {
        let response: TMDBResponse<TMDBTVShow> = try await fetch(endpoint: "/discover/tv", parameters: [
            "with_watch_providers": String(id),
            "watch_region": "US",
            "sort_by": "popularity.desc",
            "page": String(page)
        ])
        return response.results
    }
    
    // MARK: - Details
    func fetchMovieDetails(id: Int) async throws -> TMDBMovieDetail {
        return try await fetch(endpoint: "/movie/\(id)")
    }
    
    func fetchTVShowDetails(id: Int) async throws -> TMDBTVShowDetail {
        return try await fetch(endpoint: "/tv/\(id)")
    }
    
    func fetchSeasonDetails(tvId: Int, seasonNumber: Int) async throws -> TMDBSeasonDetail {
        return try await fetch(endpoint: "/tv/\(tvId)/season/\(seasonNumber)")
    }
    
    func fetchMovieCredits(id: Int) async throws -> TMDBCredits {
        return try await fetch(endpoint: "/movie/\(id)/credits")
    }
    
    func fetchTVCredits(id: Int) async throws -> TMDBCredits {
        return try await fetch(endpoint: "/tv/\(id)/credits")
    }
    
    // MARK: - Recommendations
    func fetchSimilarMovies(id: Int) async throws -> [TMDBMovie] {
        let response: TMDBResponse<TMDBMovie> = try await fetch(endpoint: "/movie/\(id)/similar")
        return response.results
    }
    
    func fetchMovieRecommendations(id: Int) async throws -> [TMDBMovie] {
        let response: TMDBResponse<TMDBMovie> = try await fetch(endpoint: "/movie/\(id)/recommendations")
        return response.results
    }
    
    func fetchSimilarTVShows(id: Int) async throws -> [TMDBTVShow] {
        let response: TMDBResponse<TMDBTVShow> = try await fetch(endpoint: "/tv/\(id)/similar")
        return response.results
    }
    
    func fetchTVShowRecommendations(id: Int) async throws -> [TMDBTVShow] {
        let response: TMDBResponse<TMDBTVShow> = try await fetch(endpoint: "/tv/\(id)/recommendations")
        return response.results
    }
    
    // MARK: - External IDs
    func fetchExternalIDs(type: String, id: Int) async throws -> String? {
        // type should be "movie" or "tv"
        struct ExternalIDs: Codable {
            let imdb_id: String?
        }
        let response: ExternalIDs = try await fetch(endpoint: "/\(type)/\(id)/external_ids")
        return response.imdb_id
    }
    
    // MARK: - Videos
    func fetchVideos(type: String, id: Int) async throws -> [TMDBVideo] {
        let response: TMDBVideoResponse = try await fetch(endpoint: "/\(type)/\(id)/videos")
        return response.results.filter { $0.site == "YouTube" }
    }
    
    // MARK: - Watch Providers
    func fetchWatchProviders(type: String, id: Int) async throws -> [TMDBWatchProvider] {
        let response: TMDBWatchProviderResponse = try await fetch(endpoint: "/\(type)/\(id)/watch/providers")
        
        // Priority: IN (India) -> US (USA) -> First Available
        // Ideally we should use the user's current locale region.
        // For now, hardcoding preference for typical test regions.
        if let india = response.results["IN"] {
            return india.flatrate ?? india.buy ?? []
        }
        if let us = response.results["US"] {
            return us.flatrate ?? us.buy ?? []
        }
        
        // Fallback: return first available region's providers
        return response.results.values.first?.flatrate ?? []
    }
}
