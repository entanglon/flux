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
        let type = item.category.contains("TV") ? "tv" : "movie"
        
        // Parallel fetch for speed
        await withTaskGroup(of: Void.self) { group in
            // 1. Fetch Cast & Crew
            group.addTask {
                if let credits = await self.fetchCredits(id: item.id, type: type) {
                    await MainActor.run {
                        enriched.cast = credits.cast.prefix(15).map { cast in
                            CastMember(
                                name: cast.name,
                                role: cast.character,
                                imageURL: cast.profileURL
                            )
                        }
                    }
                }
            }
            
            // 2. Fetch Watch Providers
            group.addTask {
                if let providers = await self.fetchWatchProviders(id: item.id, type: type) {
                    await MainActor.run {
                        // Logic to convert TMDB providers to JustWatch bridge format
                        // (Simplified for now, could be further refined)
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
              let response = try? JSONDecoder().decode(TMDBEpisode.self, from: data) else { return nil }
        
        return response.toEpisode().stillURL
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
