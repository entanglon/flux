import Foundation
import Combine

class SearchManager: ObservableObject {
    static let shared = SearchManager()
    
    @Published var recentSearches: [MediaItem] = []
    
    private let recentSearchesKey = "recentSearches"
    
    private init() {
        loadRecentSearches()
    }
    
    func addRecentSearch(_ item: MediaItem) {
        // Remove duplicates based on ID or title
        recentSearches.removeAll { existing in
            if existing.id == item.id {
                return true
            }
            return existing.title == item.title
        }
        
        // Add to front
        recentSearches.insert(item, at: 0)
        
        // Limit to 20 items
        if recentSearches.count > 20 {
            recentSearches = Array(recentSearches.prefix(20))
        }
        
        saveRecentSearches()
    }
    
    func clearRecentSearches() {
        recentSearches.removeAll()
        saveRecentSearches()
    }
    
    private func saveRecentSearches() {
        do {
            let data = try JSONEncoder().encode(recentSearches)
            UserDefaults.standard.set(data, forKey: recentSearchesKey)
        } catch {
            print("Error saving recent searches: \(error)")
        }
    }
    
    private func loadRecentSearches() {
        guard let data = UserDefaults.standard.data(forKey: recentSearchesKey) else { return }
        
        do {
            recentSearches = try JSONDecoder().decode([MediaItem].self, from: data)
        } catch {
            print("Error loading recent searches: \(error)")
        }
    }
}
