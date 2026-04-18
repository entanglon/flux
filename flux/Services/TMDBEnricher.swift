import Foundation
import SwiftUI

class TMDBEnricher {
    static let shared = TMDBEnricher()
    
    private let baseURL = "https://api.themoviedb.org/3"
    
    // We use a property to fetch the API key dynamically from AppStorage or Secrets
    private var apiKey: String {
        let key = UserDefaults.standard.string(forKey: "tmdbApiKey") ?? ""
        return key.isEmpty ? Secrets.tmdbAPIKey : key
    }
    
    private init() {}
    
    // MARK: - ID Translation (Critical for Stremio Compatibility)
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
        let urlString = "\(baseURL)/\(mediaType)/\(tmdbID)/external_ids?api_key=\(apiKey)"
        
        guard let url = URL(string: urlString) else { return nil }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(ExternalIDsResponse.self, from: data)
            return response.imdb_id
        } catch {
            print("Failed to translate TMDB ID \(tmdbID): \(error)")
            return nil
        }
    }
    
    // MARK: - Asset Enrichment
    func enrichMediaItem(_ item: MediaItem) async -> MediaItem {
        guard !apiKey.isEmpty else { return item }
        
        var enriched = item
        let type = item.category.contains("TV") || item.category.lowercased().contains("series") ? "tv" : "movie"
        let imdbID = item.id.starts(with: "tt") ? item.id : nil
        
        // 1. First, find the TMDB ID if we only have IMDb ID
        var tmdbID: Int? = nil
        if let id = imdbID {
            let findURL = "\(baseURL)/find/\(id)?api_key=\(apiKey)&external_source=imdb_id"
            if let url = URL(string: findURL),
               let (data, _) = try? await URLSession.shared.data(from: url),
               let response = try? JSONDecoder().decode(TMDBFindResponse.self, from: data) {
                if type == "movie" {
                    tmdbID = response.movie_results.first?.id
                } else {
                    tmdbID = response.tv_results.first?.id
                }
            }
        }
        
        let idToUse = tmdbID != nil ? String(tmdbID!) : item.id
        
        // 2. Fetch Details & Assets
        await withTaskGroup(of: Void.self) { group in
            // Step A: Details (for high-res imagery)
            group.addTask {
                let detailURL = "\(self.baseURL)/\(type)/\(idToUse)?api_key=\(self.apiKey)"
                if let url = URL(string: detailURL),
                   let (data, _) = try? await URLSession.shared.data(from: url),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    await MainActor.run {
                        if let backdropPath = json["backdrop_path"] as? String {
                            // Upgrading resolution to 'original' for crisp hero banners
                            enriched.backdropURL = URL(string: "https://image.tmdb.org/t/p/original\(backdropPath)")
                            enriched.heroURL = enriched.backdropURL
                        }
                        if let posterPath = json["poster_path"] as? String {
                            enriched.posterURL = URL(string: "https://image.tmdb.org/t/p/w780\(posterPath)")
                        }
                        if let overview = json["overview"] as? String, enriched.description.isEmpty {
                            enriched.description = overview
                        }
                    }
                }
            }
            
            // Step B: Credits
            group.addTask {
                if let credits = await self.fetchCredits(id: idToUse, type: type) {
                    await MainActor.run {
                        enriched.cast = credits.cast.prefix(15).map { cast in
                            CastMember(name: cast.name, role: cast.character, imageURL: cast.profileURL)
                        }
                    }
                }
            }
            
            // Step C: Watch Providers
            group.addTask {
                if let response = await self.fetchWatchProviders(id: idToUse, type: type) {
                    let region = response.results["US"] ?? response.results.first?.value
                    let items = (region?.flatrate ?? []) + (region?.buy ?? []) + (region?.rent ?? [])
                    if !items.isEmpty {
                        await MainActor.run {
                            enriched.watchProviders = items.map { WatchProvider(name: $0.provider_name, logoURL: $0.logoURL, displayPriority: 0) }
                        }
                    }
                }
            }
        }
        
        return enriched
    }
    
    // MARK: - Specific Asset Fetching
    func fetchEpisodeStill(tmdbID: String, season: Int, episode: Int) async -> URL? {
        let urlString = "\(baseURL)/tv/\(tmdbID)/season/\(season)/episode/\(episode)?api_key=\(apiKey)"
        guard let url = URL(string: urlString), 
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(TMDBEpisodeDetail.self, from: data) else { return nil }
        
        if let path = response.still_path {
            return URL(string: "https://image.tmdb.org/t/p/original\(path)")
        }
        return nil
    }
    
    func fetchSeasonEnrichment(tvId: String, seasonNumber: Int) async -> [Int: String] {
        let urlString = "\(baseURL)/tv/\(tvId)/season/\(seasonNumber)?api_key=\(apiKey)"
        guard let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(TMDBSeasonResponse.self, from: data) else { return [:] }
        
        var overviews: [Int: String] = [:]
        for episode in response.episodes {
            overviews[episode.episode_number] = episode.overview
        }
        return overviews
    }
    
    // MARK: - Catalog Fetching (HomeView Override)
    func fetchTrending(type: String) async throws -> [MediaItem] {
        let mediaType = type.contains("movie") ? "movie" : "tv"
        let urlString = "\(baseURL)/trending/\(mediaType)/week?api_key=\(apiKey)"
        
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let (data, _) = try await URLSession.shared.data(from: url)
        
        if mediaType == "movie" {
            let response = try JSONDecoder().decode(TMDBResponse<TMDBMovie>.self, from: data)
            return response.results.map { $0.toMediaItem() }
        } else {
            let response = try JSONDecoder().decode(TMDBResponse<TMDBTVShow>.self, from: data)
            return response.results.map { $0.toMediaItem() }
        }
    }
    func fetchLatestMovies() async throws -> [MediaItem] {
        let urlString = "\(baseURL)/movie/now_playing?api_key=\(apiKey)"
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(TMDBResponse<TMDBMovie>.self, from: data)
        return response.results.map { $0.toMediaItem() }
    }
    
    func fetchLatestTV() async throws -> [MediaItem] {
        let urlString = "\(baseURL)/tv/on_the_air?api_key=\(apiKey)"
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(TMDBResponse<TMDBTVShow>.self, from: data)
        return response.results.map { $0.toMediaItem() }
    }
    
    // MARK: - Helper API Calls
    private func fetchCredits(id: String, type: String) async -> TMDBCredits? {
        let urlString = "\(baseURL)/\(type)/\(id)/credits?api_key=\(apiKey)"
        guard let url = URL(string: urlString), let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return try? JSONDecoder().decode(TMDBCredits.self, from: data)
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
}
