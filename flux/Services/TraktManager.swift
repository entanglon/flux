import Foundation
import Combine
import SwiftUI

class TraktManager: ObservableObject {
    static let shared = TraktManager()
    
    @AppStorage("traktAccessToken") var accessToken: String = ""
    @AppStorage("traktRefreshToken") var refreshToken: String = ""
    
    @Published var isAuthenticated: Bool = false
    @Published var isSyncing: Bool = false
    @Published var errorMessage: String? = nil
    
    private let baseURL = "https://api.trakt.tv"
    private let redirectURI = "urn:ietf:wg:oauth:2.0:oob"
    
    private init() {
        self.isAuthenticated = !accessToken.isEmpty
    }
    
    // MARK: - Auth Logic
    
    struct DeviceCodeResponse: Codable {
        let device_code: String
        let user_code: String
        let verification_url: String
        let expires_in: Int
        let interval: Int
    }
    
    func generateDeviceCode() async throws -> DeviceCodeResponse {
        let url = URL(string: "\(baseURL)/oauth/device/code")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: String] = ["client_id": Secrets.traktClientId]
        request.httpBody = try JSONEncoder().encode(body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
    }
    
    struct TokenResponse: Codable {
        let access_token: String
        let refresh_token: String
    }
    
    func pollForToken(deviceCode: String, interval: Int, expiresIn: Int) async throws {
        let url = URL(string: "\(baseURL)/oauth/device/token")!
        let expireDate = Date().addingTimeInterval(TimeInterval(expiresIn))
        
        while Date() < expireDate {
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let body: [String: String] = [
                "code": deviceCode,
                "client_id": Secrets.traktClientId,
                "client_secret": Secrets.traktClientSecret
            ]
            request.httpBody = try JSONEncoder().encode(body)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    let tokenData = try JSONDecoder().decode(TokenResponse.self, from: data)
                    await MainActor.run {
                        self.accessToken = tokenData.access_token
                        self.refreshToken = tokenData.refresh_token
                        self.isAuthenticated = true
                    }
                    // Initial sync
                    try? await syncHistory()
                    return
                } else if httpResponse.statusCode == 400 {
                    continue // Keep polling (Pending)
                } else {
                    throw URLError(.userAuthenticationRequired)
                }
            }
        }
        throw URLError(.timedOut)
    }
    
    func logout() {
        accessToken = ""
        refreshToken = ""
        isAuthenticated = false
    }
    
    // MARK: - Sync Logic
    
    struct TraktHistoryItem: Codable {
        let id: Int
        let watched_at: String
        let type: String
        let movie: TraktMovie?
        let show: TraktShow?
        let episode: TraktEpisode?
    }
    
    struct TraktMovie: Codable {
        let title: String
        let ids: TraktIDs
    }
    
    struct TraktShow: Codable {
        let title: String
        let ids: TraktIDs
    }
    
    struct TraktEpisode: Codable {
        let season: Int
        let number: Int
        let title: String
    }
    
    struct TraktIDs: Codable {
        let trakt: Int
        let imdb: String?
        let tmdb: Int?
    }
    
    func syncHistory() async throws {
        guard isAuthenticated && !accessToken.isEmpty else { return }
        
        await MainActor.run { self.isSyncing = true }
        
        do {
            let url = URL(string: "\(baseURL)/sync/history?limit=50")!
            var request = URLRequest(url: url)
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.addValue("2", forHTTPHeaderField: "trakt-api-version")
            request.addValue(Secrets.traktClientId, forHTTPHeaderField: "trakt-api-key")
            request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            
            let history = try JSONDecoder().decode([TraktHistoryItem].self, from: data)
            
            // Map to MediaItems and add to local history cache
            for item in history.reversed() { 
                var mappedItem: MediaItem?
                
                if item.type == "movie", let movie = item.movie {
                    let id = movie.ids.imdb ?? "tmdb:\(movie.ids.tmdb ?? 0)"
                    mappedItem = MediaItem(id: id, title: movie.title, description: "", imageURL: nil, posterURL: nil, backdropURL: nil, heroURL: nil, streamURL: nil, category: "Movie", progress: 1.0, trailerURL: nil, cast: nil, seasons: nil, runtime: nil, certification: nil, genres: nil, popularity: nil, releaseDate: nil, spokenLanguages: nil, originCountry: nil, voteAverage: nil, episodes: nil)
                } else if item.type == "episode", let show = item.show, let ep = item.episode {
                    let id = show.ids.imdb ?? "tmdb:\(show.ids.tmdb ?? 0)"
                    var m = MediaItem(id: id, title: show.title, description: "", imageURL: nil, posterURL: nil, backdropURL: nil, heroURL: nil, streamURL: nil, category: "TV Show", progress: 1.0, trailerURL: nil, cast: nil, seasons: nil, runtime: nil, certification: nil, genres: nil, popularity: nil, releaseDate: nil, spokenLanguages: nil, originCountry: nil, voteAverage: nil, episodes: nil)
                    m.lastSeason = ep.season
                    m.lastEpisode = ep.number
                    m.lastEpisodeTitle = ep.title
                    mappedItem = m
                }
                
                if let finalItem = mappedItem {
                    await MainActor.run {
                        UserDataService.shared.addToHistory(finalItem, progress: 1.0, season: finalItem.lastSeason, episode: finalItem.lastEpisode, episodeTitle: finalItem.lastEpisodeTitle)
                    }
                }
            }
        } catch {
            await MainActor.run { self.isSyncing = false }
            throw error
        }
        
        await MainActor.run { self.isSyncing = false }
    }
}
