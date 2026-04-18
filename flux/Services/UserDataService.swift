import Foundation
import Combine

class UserDataService: ObservableObject {
    static let shared = UserDataService()
    
    @Published var watchlist: [MediaItem] = []
    @Published var history: [MediaItem] = []
    
    // User Mock
    struct User { var id: String }
    private var currentUser: User?
    
    private let watchlistKey = "localWatchlistDataStremio" // New Key to prevent crash from old TMDB int IDs
    private let historyKey = "localHistoryDataStremio"
    
    private init() {
         loadInitialData()
    }
    
    func startSyncing(user: User) {
        self.currentUser = user
        loadInitialData()
    }
    
    func stopSyncing() {
        currentUser = nil
        DispatchQueue.main.async {
            self.watchlist = []
            self.history = []
        }
    }
    
    private func loadInitialData() {
        if let watchListData = UserDefaults.standard.array(forKey: watchlistKey) as? [[String: Any]] {
            self.watchlist = parseItems(watchListData)
        }
        
        if let historyData = UserDefaults.standard.array(forKey: historyKey) as? [[String: Any]] {
            self.history = parseItems(historyData)
        }
    }
    
    private func parseItems(_ itemsData: [[String: Any]]) -> [MediaItem] {
        let rawItems: [(item: MediaItem, timestamp: TimeInterval)] = itemsData.compactMap { dict in
            guard let idString = dict["id"] as? String,
                  let typeString = dict["type"] as? String else { return nil }
            
            let timestamp = dict["timestamp"] as? TimeInterval ?? 0
            let title = dict["title"] as? String ?? "Unknown"
            let posterPath = dict["image"] as? String
            let backdropPath = dict["backdrop"] as? String
            
            var finalPosterURL: URL?
            if let path = posterPath, !path.isEmpty {
                finalPosterURL = URL(string: path)
            }
            
            var finalBackdropURL: URL?
            if let path = backdropPath, !path.isEmpty {
                finalBackdropURL = URL(string: path)
            }
            
            let lastSeason = dict["lastSeason"] as? Int
            let lastEpisode = dict["lastEpisode"] as? Int
            let lastEpisodeTitle = dict["lastEpisodeTitle"] as? String
            let progress = dict["progress"] as? Double
            
            var item = MediaItem(
                id: idString,
                title: title,
                description: "",
                imageURL: nil,
                posterURL: finalPosterURL,
                backdropURL: finalBackdropURL,
                heroURL: nil,
                streamURL: nil,
                category: typeString == "movie" ? "Movie" : "TV Show",
                progress: progress,
                trailerURL: nil,
                cast: nil,
                seasons: nil,
                runtime: nil,
                certification: nil,
                genres: nil,
                popularity: nil,
                releaseDate: nil,
                spokenLanguages: nil,
                originCountry: nil,
                voteAverage: nil,
                episodes: nil
            )
            item.lastSeason = lastSeason
            item.lastEpisode = lastEpisode
            item.lastEpisodeTitle = lastEpisodeTitle
            
            if let imageString = dict["lastEpisodeImage"] as? String, let url = URL(string: imageString) {
                item.lastEpisodeImage = url
            }
            
            return (item, timestamp)
        }
        
        let sorted = rawItems.sorted { $0.timestamp > $1.timestamp }
        
        var uniqueItems: [MediaItem] = []
        var seenIDs: Set<String> = []
        
        for entry in sorted {
            let id = entry.item.id
            if !seenIDs.contains(id) {
                uniqueItems.append(entry.item)
                seenIDs.insert(id)
            }
        }
        
        return uniqueItems
    }
    
    // MARK: - Actions
    
    func isInWatchlist(_ item: MediaItem) -> Bool {
        return watchlist.contains { $0.id == item.id }
    }
    
    func toggleWatchlist(_ item: MediaItem) {
        if isInWatchlist(item) {
            removeFromList(key: watchlistKey, item: item, target: \.watchlist)
        } else {
            addToList(key: watchlistKey, item: item, target: \.watchlist)
        }
    }
    
    private func addToList(key: String, item: MediaItem, progress: Double? = nil, season: Int? = nil, episode: Int? = nil, episodeTitle: String? = nil, episodeImage: URL? = nil, target: ReferenceWritableKeyPath<UserDataService, [MediaItem]>) {
        let typeString = item.category.lowercased().contains("movie") ? "movie" : "tv"
        
        let imageVal = item.posterURL?.absoluteString ?? ""
        let backdropVal = item.backdropURL?.absoluteString ?? ""
        
        var finalItem: [String: Any] = [
            "id": item.id,
            "type": typeString,
            "title": item.title,
            "image": imageVal,
            "backdrop": backdropVal,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        if let p = progress { finalItem["progress"] = p }
        if let s = season { finalItem["lastSeason"] = s }
        if let e = episode { finalItem["lastEpisode"] = e }
        if let et = episodeTitle { finalItem["lastEpisodeTitle"] = et }
        if let ei = episodeImage { finalItem["lastEpisodeImage"] = ei.absoluteString }
        
        var currentData = UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []
        // Remove existing item if present
        currentData.removeAll { ($0["id"] as? String) == item.id }
        currentData.append(finalItem)
        UserDefaults.standard.set(currentData, forKey: key)
        
        let newItems = parseItems(currentData)
        DispatchQueue.main.async {
            self[keyPath: target] = newItems
        }
    }
    
    func addToHistory(_ item: MediaItem, progress: Double? = nil, season: Int? = nil, episode: Int? = nil, episodeTitle: String? = nil, episodeImage: URL? = nil) {
        addToList(key: historyKey, item: item, progress: progress, season: season, episode: episode, episodeTitle: episodeTitle, episodeImage: episodeImage, target: \.history)
    }
    
    func removeFromHistory(_ item: MediaItem) {
        removeFromList(key: historyKey, item: item, target: \.history)
    }
    
    private func removeFromList(key: String, item: MediaItem, target: ReferenceWritableKeyPath<UserDataService, [MediaItem]>) {
        var currentData = UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []
        currentData.removeAll { ($0["id"] as? String) == item.id }
        UserDefaults.standard.set(currentData, forKey: key)
        
        let newItems = parseItems(currentData)
        DispatchQueue.main.async {
            self[keyPath: target] = newItems
        }
    }
}

// MARK: - Trakt Service
import SwiftUI

class TraktService: ObservableObject {
    static let shared = TraktService()
    
    @AppStorage("traktAccessToken") var accessToken: String = ""
    @AppStorage("traktRefreshToken") var refreshToken: String = ""
    
    @Published var isAuthenticated: Bool = false
    @Published var isSyncing: Bool = false
    
    private let baseURL = "https://api.trakt.tv"
    
    @AppStorage("traktClientId") var clientId = ""
    @AppStorage("traktClientSecret") var clientSecret = ""
    
    private init() {
        self.isAuthenticated = !accessToken.isEmpty
    }
    
    var canAttemptAuth: Bool {
        return !clientId.isEmpty && !clientSecret.isEmpty
    }
    
    func logout() {
        accessToken = ""
        refreshToken = ""
        isAuthenticated = false
    }
    
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
        
        let body: [String: String] = ["client_id": clientId]
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
                "client_id": clientId,
                "client_secret": clientSecret
            ]
            request.httpBody = try JSONEncoder().encode(body)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    let tokenData = try JSONDecoder().decode(TokenResponse.self, from: data)
                    DispatchQueue.main.async {
                        self.accessToken = tokenData.access_token
                        self.refreshToken = tokenData.refresh_token
                        self.isAuthenticated = true
                    }
                    try await syncHistory()
                    return
                } else if httpResponse.statusCode == 400 {
                    continue // Keep polling
                } else if httpResponse.statusCode == 401 || httpResponse.statusCode == 404 || httpResponse.statusCode == 409 || httpResponse.statusCode == 410 || httpResponse.statusCode == 418 {
                    throw URLError(.userAuthenticationRequired)
                }
            }
        }
        throw URLError(.timedOut)
    }
    
    struct TraktHistoryItem: Codable {
        let id: Int
        let watched_at: String
        let action: String
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
        guard isAuthenticated else { throw URLError(.userAuthenticationRequired) }
        
        DispatchQueue.main.async { self.isSyncing = true }
        defer { DispatchQueue.main.async { self.isSyncing = false } }
        
        let url = URL(string: "\(baseURL)/sync/history?limit=50")!
        var request = URLRequest(url: url)
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("2", forHTTPHeaderField: "trakt-api-version")
        request.addValue(clientId, forHTTPHeaderField: "trakt-api-key")
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        let history = try JSONDecoder().decode([TraktHistoryItem].self, from: data)
        
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
                DispatchQueue.main.async {
                    if let existing = UserDataService.shared.history.first(where: { $0.id == finalItem.id }) {
                        UserDataService.shared.addToHistory(existing, progress: 1.0, season: finalItem.lastSeason, episode: finalItem.lastEpisode, episodeTitle: finalItem.lastEpisodeTitle)
                    } else {
                        UserDataService.shared.addToHistory(finalItem, progress: 1.0, season: finalItem.lastSeason, episode: finalItem.lastEpisode, episodeTitle: finalItem.lastEpisodeTitle)
                    }
                }
            }
        }
    }
}
