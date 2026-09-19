import Foundation
import Combine

class RecentSearchManager: ObservableObject {
    static let shared = RecentSearchManager()
    
    @Published var recentItems: [MediaItem] = []
    private var currentProfileID: UUID?
    private var key: String? {
        guard let id = currentProfileID else { return nil }
        return "profile.\(id.uuidString).recentSearches"
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
        load()
        if let profile, recentItems.isEmpty, !profile.isKids {
            // Carry forward legacy global searches if profile has no searches yet
            if let legacyData = UserDefaults.standard.data(forKey: "flux_recent_searches"),
               let legacy = try? JSONDecoder().decode([MediaItem].self, from: legacyData),
               !legacy.isEmpty {
                recentItems = legacy
                save()
            }
        }
    }
    
    func add(_ item: MediaItem) {
        guard !item.id.hasPrefix("tt_test_") && !item.id.hasPrefix("test_") else { return }
        recentItems.removeAll { $0.id == item.id }
        recentItems.insert(item, at: 0)
        if recentItems.count > 15 {
            recentItems = Array(recentItems.prefix(15))
        }
        save()
        if !AppEnvironment.isRunningTests {
            AuthManager.shared.scheduleAutoSync()
        }
    }
    
    func clear() {
        recentItems.removeAll()
        save()
        if !AppEnvironment.isRunningTests {
            AuthManager.shared.scheduleAutoSync()
        }
    }
    
    func setRecentItems(_ items: [MediaItem]) {
        recentItems = items
        save()
    }
    
    private func save() {
        guard !AppEnvironment.isRunningTests, let key = key else { return }
        if let encoded = try? JSONEncoder().encode(recentItems) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }
    
    private func load() {
        guard let key = key else {
            recentItems = []
            return
        }
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([MediaItem].self, from: data) {
            recentItems = decoded
        }
    }
}
