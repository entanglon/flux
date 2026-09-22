import Foundation
import Combine

class RecentSearchManager: ObservableObject {
    static let shared = RecentSearchManager()
    
    @Published var recentItems: [MediaItem] = []
    @Published var recentQueries: [String] = []
    
    private var currentProfileID: UUID?
    
    private var itemsKey: String? {
        guard let id = currentProfileID else { return nil }
        return "profile.\(id.uuidString).recentSearches"
    }
    
    private var queriesKey: String? {
        guard let id = currentProfileID else { return nil }
        return "profile.\(id.uuidString).searchHistory"
    }
    
    private init() {
        if let currentData = UserDefaults.standard.data(forKey: "fluxCurrentProfile"),
           let profile = try? JSONDecoder().decode(UserProfile.self, from: currentData) {
            currentProfileID = profile.id
        }
        load()
    }
    
    func switchProfile(to profile: UserProfile?) {
        currentProfileID = profile?.id
        recentItems = []
        recentQueries = []
        load()
        if let profile, !profile.isKids {
            // Carry forward legacy global searches if profile has no searches yet
            if recentItems.isEmpty,
               let legacyData = UserDefaults.standard.data(forKey: "flux_recent_searches"),
               let legacy = try? JSONDecoder().decode([MediaItem].self, from: legacyData),
               !legacy.isEmpty {
                recentItems = legacy
                saveItems()
            }
            if recentQueries.isEmpty,
               let legacyQueries = UserDefaults.standard.stringArray(forKey: "flux_search_history"),
               !legacyQueries.isEmpty {
                recentQueries = legacyQueries
                saveQueries()
            }
        }
    }
    
    // MARK: - Query History
    
    func addQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recentQueries.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        recentQueries.insert(trimmed, at: 0)
        if recentQueries.count > 20 {
            recentQueries = Array(recentQueries.prefix(20))
        }
        saveQueries()
        if !AppEnvironment.isRunningTests {
            AuthManager.shared.scheduleAutoSync()
        }
    }
    
    func removeQuery(_ query: String) {
        recentQueries.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        saveQueries()
        if !AppEnvironment.isRunningTests {
            AuthManager.shared.scheduleAutoSync()
        }
    }
    
    // MARK: - Media Item History
    
    func add(_ item: MediaItem) {
        guard !item.id.hasPrefix("tt_test_") && !item.id.hasPrefix("test_") else { return }
        recentItems.removeAll { $0.id == item.id }
        recentItems.insert(item, at: 0)
        if recentItems.count > 15 {
            recentItems = Array(recentItems.prefix(15))
        }
        saveItems()
        if !AppEnvironment.isRunningTests {
            AuthManager.shared.scheduleAutoSync()
        }
    }
    
    func removeItem(_ item: MediaItem) {
        recentItems.removeAll { $0.id == item.id }
        saveItems()
        if !AppEnvironment.isRunningTests {
            AuthManager.shared.scheduleAutoSync()
        }
    }
    
    // MARK: - Clear
    
    func clear() {
        clearSearchHistory()
    }
    
    func clearSearchHistory() {
        recentItems.removeAll()
        recentQueries.removeAll()
        saveItems()
        saveQueries()
        if !AppEnvironment.isRunningTests {
            AuthManager.shared.scheduleAutoSync()
        }
    }
    
    func clearQueries() {
        recentQueries.removeAll()
        saveQueries()
        if !AppEnvironment.isRunningTests {
            AuthManager.shared.scheduleAutoSync()
        }
    }
    
    func setRecentItems(_ items: [MediaItem]) {
        recentItems = items
        saveItems()
    }
    
    // MARK: - Persistence
    
    private func saveItems() {
        guard !AppEnvironment.isRunningTests, let key = itemsKey else { return }
        if let encoded = try? JSONEncoder().encode(recentItems) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }
    
    private func saveQueries() {
        guard !AppEnvironment.isRunningTests, let key = queriesKey else { return }
        UserDefaults.standard.set(recentQueries, forKey: key)
    }
    
    func load() {
        if let key = itemsKey,
           let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([MediaItem].self, from: data) {
            recentItems = decoded
        } else {
            recentItems = []
        }
        
        if let key = queriesKey,
           let queries = UserDefaults.standard.stringArray(forKey: key) {
            recentQueries = queries
        } else {
            recentQueries = []
        }
    }
}
