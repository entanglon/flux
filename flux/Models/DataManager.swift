import SwiftUI
import Combine

class DataManager: ObservableObject {
    static let shared = DataManager()
    
    @Published var watchlist: Set<String> = [] // Changed to String for id
    @Published var allMedia: [MediaItem] = MockData.sampleMedia
    
    private let watchlistKey = "user_watchlist_ids"
    
    private init() {
        loadWatchlist()
    }
    
    func toggleWatchlist(item: MediaItem) {
        let id = item.id
        
        if watchlist.contains(id) {
            watchlist.remove(id)
        } else {
            watchlist.insert(id)
        }
        saveWatchlist()
    }
    
    func isInWatchlist(item: MediaItem) -> Bool {
        let id = item.id
        return watchlist.contains(id)
    }
    
    private func saveWatchlist() {
        let array = Array(watchlist)
        UserDefaults.standard.set(array, forKey: watchlistKey)
    }
    
    private func loadWatchlist() {
        if let array = UserDefaults.standard.array(forKey: watchlistKey) as? [String] {
            watchlist = Set(array)
        }
    }
    
    func search(query: String) -> [MediaItem] {
        if query.isEmpty {
            return []
        }
        return allMedia.filter { item in
            item.title.localizedCaseInsensitiveContains(query) ||
            item.description.localizedCaseInsensitiveContains(query) ||
            item.category.localizedCaseInsensitiveContains(query)
        }
    }
}
