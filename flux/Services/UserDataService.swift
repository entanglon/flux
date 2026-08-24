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

    /// Fills in missing artwork/IDs for history items via TMDB and publishes the
    /// enriched items. Without the write-back, Continue Watching cards restored
    /// from disk keep nil URLs and render as eternal spinners.
    func enrichHistory() async {
        let items = history
        guard !items.isEmpty else { return }
        var updated: [MediaItem] = []
        updated.reserveCapacity(items.count)
        var didChange = false
        for item in items {
            let enriched = await TMDBEnricher.shared.quickEnrich(item)
            if enriched.backdropURL != item.backdropURL || enriched.posterURL != item.posterURL {
                didChange = true
            }
            updated.append(enriched)
        }
        if didChange {
            await MainActor.run {
                self.history = updated
            }
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
        
        let imageVal = item.posterURL?.absoluteString ?? item.imageURL?.absoluteString ?? ""
        let backdropVal = item.backdropURL?.absoluteString ?? item.heroURL?.absoluteString ?? imageVal
        
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


