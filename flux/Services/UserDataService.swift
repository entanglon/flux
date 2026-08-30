import Foundation
import Combine

class UserDataService: ObservableObject {
    static let shared = UserDataService()
    
    @Published var watchlist: [MediaItem] = []
    @Published var history: [MediaItem] = []
    @Published var collections: [UserCollection] = []
    
    // User Mock
    struct User { var id: String }
    private var currentUser: User?
    
    private var watchlistKey = "localWatchlistDataStremio" // New Key to prevent crash from old TMDB int IDs
    private var historyKey = "localHistoryDataStremio"
    private var collectionsKey = "localCollectionsData"

    /// Scopes all history/watchlist storage to a profile. When `migrateLegacyData`
    /// is set (first profile ever created), pre-profile data is carried over so
    /// nobody loses their library.
    func switchProfile(to profile: UserProfile?, migrateLegacyData: Bool = false) {
        if let profile {
            historyKey = "profile.\(profile.id.uuidString).history"
            watchlistKey = "profile.\(profile.id.uuidString).watchlist"
            collectionsKey = "profile.\(profile.id.uuidString).collections"

            if migrateLegacyData,
               UserDefaults.standard.data(forKey: historyKey) == nil,
               let legacy = UserDefaults.standard.array(forKey: "localHistoryDataStremio") {
                UserDefaults.standard.set(legacy, forKey: historyKey)
            }
        }
        watchlist = []
        history = []
        collections = []
        loadInitialData()
    }
    
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

        collections = loadCollections()
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
            if let r = dict["runtime"] as? String {
                item.runtime = r
            }
            if let l = dict["logo"] as? String, let u = URL(string: l) {
                item.logoURL = u
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
        if let r = item.runtime { finalItem["runtime"] = r }
        if let l = item.logoURL?.absoluteString { finalItem["logo"] = l }
        
        var currentData = UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []
        // Remove existing item if present
        currentData.removeAll { ($0["id"] as? String) == item.id }
        currentData.append(finalItem)
        UserDefaults.standard.set(currentData, forKey: key)
        
        let newItems = parseItems(currentData)
        DispatchQueue.main.async {
            self[keyPath: target] = newItems
        }
        AuthManager.shared.scheduleAutoSync()
    }
    
    func isInHistory(_ item: MediaItem) -> Bool {
        return history.contains { $0.id == item.id }
    }

    func toggleWatched(_ item: MediaItem, season: Int? = nil, episode: Int? = nil, episodeTitle: String? = nil, episodeImage: URL? = nil) {
        if isInHistory(item) {
            removeFromHistory(item)
        } else {
            addToHistory(item, progress: 1.0, season: season, episode: episode, episodeTitle: episodeTitle, episodeImage: episodeImage)
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
        AuthManager.shared.scheduleAutoSync()
    }
    
    // MARK: - Collections (custom user lists)
    //
    // Storage shape (one key per profile): [[String: Any]] where each entry is
    // { id, name, createdAt, items: Data } — `items` is JSON-serialized
    // [[String: Any]] using the SAME dict shape as watchlist/history entries,
    // so parseItems() decodes them and grids render with full artwork offline.
    
    private func loadCollections() -> [UserCollection] {
        guard let raw = UserDefaults.standard.array(forKey: collectionsKey) as? [[String: Any]] else { return [] }
        return raw.compactMap { decodeCollection($0) }.sorted { $0.createdAt < $1.createdAt }
    }
    
    private func saveCollections() {
        let raw: [[String: Any]] = collections.map { c in
            let itemsData = (try? JSONSerialization.data(withJSONObject: c.items.map { itemDict($0) })) ?? Data()
            return [
                "id": c.id,
                "name": c.name,
                "createdAt": c.createdAt.timeIntervalSince1970,
                "itemsData": itemsData
            ]
        }
        UserDefaults.standard.set(raw, forKey: collectionsKey)
    }
    
    /// Same dict shape addToList() writes for watchlist/history entries.
    private func itemDict(_ item: MediaItem) -> [String: Any] {
        let typeString = item.category.lowercased().contains("movie") ? "movie" : "tv"
        let imageVal = item.posterURL?.absoluteString ?? item.imageURL?.absoluteString ?? ""
        let backdropVal = item.backdropURL?.absoluteString ?? item.heroURL?.absoluteString ?? imageVal
        return [
            "id": item.id,
            "type": typeString,
            "title": item.title,
            "image": imageVal,
            "backdrop": backdropVal,
            "timestamp": Date().timeIntervalSince1970
        ]
    }
    
    private func decodeCollection(_ dict: [String: Any]) -> UserCollection? {
        guard let id = dict["id"] as? String,
              let name = dict["name"] as? String else { return nil }
        let created = (dict["createdAt"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        var items: [MediaItem] = []
        if let data = dict["itemsData"] as? Data,
           let dicts = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            items = parseItems(dicts)
        }
        return UserCollection(id: id, name: name, createdAt: created, items: items)
    }
    
    @discardableResult
    func createCollection(name: String) -> UserCollection {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let collection = UserCollection(
            id: UserCollection.newID(),
            name: trimmed.isEmpty ? "New List" : trimmed,
            createdAt: Date(),
            items: []
        )
        collections.append(collection)
        saveCollections()
        AuthManager.shared.scheduleAutoSync()
        return collection
    }
    
    func renameCollection(id: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[idx].name = trimmed
        saveCollections()
        AuthManager.shared.scheduleAutoSync()
    }
    
    func deleteCollection(id: String) {
        collections.removeAll { $0.id == id }
        saveCollections()
        AuthManager.shared.scheduleAutoSync()
    }
    
    func isInCollection(collectionID: String, item: MediaItem) -> Bool {
        collections.first(where: { $0.id == collectionID })?.items.contains { $0.id == item.id } ?? false
    }
    
    func collectionIDs(containing item: MediaItem) -> Set<String> {
        Set(collections.filter { c in c.items.contains { $0.id == item.id } }.map(\.id))
    }
    
    func toggleCollectionMembership(collectionID: String, item: MediaItem) {
        guard let idx = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        if collections[idx].items.contains(where: { $0.id == item.id }) {
            collections[idx].items.removeAll { $0.id == item.id }
        } else {
            collections[idx].items.insert(item, at: 0)
        }
        saveCollections()
        AuthManager.shared.scheduleAutoSync()
    }
    
    func removeFromCollection(collectionID: String, item: MediaItem) {
        guard let idx = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        collections[idx].items.removeAll { $0.id == item.id }
        saveCollections()
        AuthManager.shared.scheduleAutoSync()
    }

    // MARK: - Cloud sync payload

    /// Full library snapshot for the cloud blob. Uses raw UserDefaults arrays so
    /// it captures everything exactly as persisted (including episode metadata).
    func exportCloudPayload() -> [String: Any] {
        let watchlistData = (UserDefaults.standard.array(forKey: watchlistKey) as? [[String: Any]])
            ?? (UserDefaults.standard.array(forKey: "localWatchlistDataStremio") as? [[String: Any]])
            ?? []
        let historyData = (UserDefaults.standard.array(forKey: historyKey) as? [[String: Any]])
            ?? (UserDefaults.standard.array(forKey: "localHistoryDataStremio") as? [[String: Any]])
            ?? []

        return [
            "version": 2,
            "watchlist": watchlistData,
            "history": historyData,
            "collections": collections.map { c in
                let itemsData = (try? JSONSerialization.data(withJSONObject: c.items.map { itemDict($0) })) ?? Data()
                return [
                    "id": c.id,
                    "name": c.name,
                    "createdAt": c.createdAt.timeIntervalSince1970,
                    "itemsData": itemsData.base64EncodedString()
                ]
            },
            "tasteLoved": TasteProfileManager.shared.exportLovedData(),
            "tasteSnapshots": TasteProfileManager.shared.exportSnapshotsData(),
            "profiles": ProfileManager.shared.exportProfilesData()
        ]
    }

    var hasLibraryContent: Bool {
        !watchlist.isEmpty || !history.isEmpty || !collections.isEmpty
    }

    /// Applies a cloud payload to the CURRENT profile (replaces local state).
    func applyCloudPayload(_ payload: [String: Any]) {
        let watchlistData = payload["watchlist"] as? [[String: Any]]
        let historyData = payload["history"] as? [[String: Any]]

        var imported: [UserCollection] = []
        if let raw = payload["collections"] as? [[String: Any]] {
            for dict in raw {
                guard let id = dict["id"] as? String,
                      let name = dict["name"] as? String else { continue }
                let created = (dict["createdAt"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
                var items: [MediaItem] = []
                if let b64 = dict["itemsData"] as? String,
                   let data = Data(base64Encoded: b64),
                   let dicts = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                    items = parseItems(dicts)
                }
                imported.append(UserCollection(id: id, name: name, createdAt: created, items: items))
            }
        }

        let tasteLoved = payload["tasteLoved"] as? [[String: Any]]
        let tasteSnapshots = payload["tasteSnapshots"] as? [[String: Any]]
        let profilesData = payload["profiles"] as? [[String: Any]]

        DispatchQueue.main.async {
            // Persist first so disk matches memory.
            self.collections = imported.sorted { $0.createdAt < $1.createdAt }
            self.saveCollections()
            if let w = watchlistData {
                UserDefaults.standard.set(w, forKey: self.watchlistKey)
                self.watchlist = self.parseItems(w)
            }
            if let h = historyData {
                UserDefaults.standard.set(h, forKey: self.historyKey)
                self.history = self.parseItems(h)
            }
            TasteProfileManager.shared.applyCloudData(loved: tasteLoved, snapshots: tasteSnapshots)
            ProfileManager.shared.applyCloudProfilesData(profilesData)
            print("[UserDataService] Cloud payload applied (watchlist: \(self.watchlist.count), history: \(self.history.count), collections: \(self.collections.count))")
        }
    }
}


