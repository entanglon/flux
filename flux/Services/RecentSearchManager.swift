import Foundation
import Combine

class RecentSearchManager: ObservableObject {
    static let shared = RecentSearchManager()
    
    @Published var recentItems: [MediaItem] = []
    private let key = "flux_recent_searches"
    
    private init() {
        load()
    }
    
    func add(_ item: MediaItem) {
        recentItems.removeAll { $0.id == item.id }
        recentItems.insert(item, at: 0)
        if recentItems.count > 15 {
            recentItems = Array(recentItems.prefix(15))
        }
        save()
    }
    
    func clear() {
        recentItems.removeAll()
        save()
    }
    
    private func save() {
        if let encoded = try? JSONEncoder().encode(recentItems) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }
    
    private func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([MediaItem].self, from: data) {
            recentItems = decoded
        }
    }
}
