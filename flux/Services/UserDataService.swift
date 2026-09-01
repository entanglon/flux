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
               (UserDefaults.standard.array(forKey: historyKey) as? [[String: Any]]) == nil,
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
    /// enriched items. Preserves all episode-specific thumbnails, titles, runtimes,
    /// and watch progress so they are never overwritten.
    func enrichHistory() async {
        let items = history
        guard !items.isEmpty else { return }
        var updated: [MediaItem] = []
        updated.reserveCapacity(items.count)
        var didChange = false
        for item in items {
            var enriched = await TMDBEnricher.shared.quickEnrich(item)
            
            // STRICTLY PRESERVE all episode-specific user watch session metadata
            enriched.lastSeason = item.lastSeason ?? enriched.lastSeason
            enriched.lastEpisode = item.lastEpisode ?? enriched.lastEpisode
            enriched.lastEpisodeTitle = item.lastEpisodeTitle ?? enriched.lastEpisodeTitle
            enriched.lastEpisodeImage = item.lastEpisodeImage ?? enriched.lastEpisodeImage
            enriched.progress = item.progress ?? enriched.progress
            enriched.runtime = item.runtime ?? enriched.runtime
            enriched.logoURL = item.logoURL ?? enriched.logoURL

            // If TV show history item is missing season/episode, default to S1, E1 to repair
            if (enriched.category == "TV Show" || enriched.category == "Series") && enriched.lastSeason == nil {
                enriched.lastSeason = 1
                enriched.lastEpisode = 1
                didChange = true
            }

            // If the item has a specific episode, ensure episode still/runtime is populated
            if let season = enriched.lastSeason, let episode = enriched.lastEpisode {
                if enriched.lastEpisodeImage == nil || enriched.runtime == nil {
                    let type = "tv"
                    let tmdbID = enriched.id.starts(with: "tt") ? await TMDBEnricher.shared.resolveTmdbID(imdbID: enriched.id, type: type) : enriched.id
                    if let id = tmdbID {
                        let info = await TMDBEnricher.shared.fetchEpisodeInfo(tmdbID: id, season: season, episode: episode)
                        if enriched.lastEpisodeImage == nil, let still = info.stillURL {
                            enriched.lastEpisodeImage = still
                            didChange = true
                        }
                        if enriched.runtime == nil, let rt = info.runtime {
                            enriched.runtime = rt
                            didChange = true
                        }
                    }
                }
            }

            enriched.timestamp = item.timestamp
            if enriched.backdropURL != item.backdropURL || enriched.posterURL != item.posterURL || enriched.lastEpisodeImage != item.lastEpisodeImage || enriched.lastSeason != item.lastSeason {
                didChange = true
            }
            updated.append(enriched)
        }
        if didChange {
            await MainActor.run {
                self.history = updated
            }
            let rawData = updated.map { itemDict($0) }
            UserDefaults.standard.set(rawData, forKey: self.historyKey)
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
            let lastPlaybackPosition = dict["lastPlaybackPosition"] as? Double
            let lastPlaybackDuration = dict["lastPlaybackDuration"] as? Double
            let lastStreamURLString = dict["lastStreamURL"] as? String
            let lastTorrentInfoHash = dict["lastTorrentInfoHash"] as? String
            let lastFileIndex = dict["lastFileIndex"] as? Int
            
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
                originalLanguage: nil,
                spokenLanguages: nil,
                originCountry: nil,
                voteAverage: nil,
                episodes: nil
            )
            item.lastSeason = lastSeason
            item.lastEpisode = lastEpisode
            item.lastEpisodeTitle = lastEpisodeTitle
            item.timestamp = timestamp
            item.lastPlaybackPosition = lastPlaybackPosition
            item.lastPlaybackDuration = lastPlaybackDuration
            if let su = lastStreamURLString, let u = URL(string: su) {
                item.lastStreamURL = u
            }
            item.lastTorrentInfoHash = lastTorrentInfoHash
            item.lastFileIndex = lastFileIndex
            
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
        
        // Sort by timestamp descending. If timestamps differ by <= 1.0 second
        // (written in a batch loop), preserve original array order (earlier index = more recent).
        let sorted = rawItems.enumerated().sorted { a, b in
            let diff = a.element.timestamp - b.element.timestamp
            if abs(diff) > 1.0 {
                return a.element.timestamp > b.element.timestamp
            } else {
                return a.offset < b.offset
            }
        }.map { $0.element }
        
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
    
    private func addToList(key: String, item: MediaItem, progress: Double? = nil, season: Int? = nil, episode: Int? = nil, episodeTitle: String? = nil, episodeImage: URL? = nil, playbackPosition: Double? = nil, playbackDuration: Double? = nil, streamURL: URL? = nil, torrentInfoHash: String? = nil, fileIndex: Int? = nil, target: ReferenceWritableKeyPath<UserDataService, [MediaItem]>) {
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
        if let pos = playbackPosition ?? item.lastPlaybackPosition { finalItem["lastPlaybackPosition"] = pos }
        if let dur = playbackDuration ?? item.lastPlaybackDuration { finalItem["lastPlaybackDuration"] = dur }
        if let su = streamURL ?? item.lastStreamURL { finalItem["lastStreamURL"] = su.absoluteString }
        if let hash = torrentInfoHash ?? item.lastTorrentInfoHash { finalItem["lastTorrentInfoHash"] = hash }
        if let fi = fileIndex ?? item.lastFileIndex { finalItem["lastFileIndex"] = fi }
        
        var currentData = UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []
        // Remove existing item if present
        currentData.removeAll { ($0["id"] as? String) == item.id }
        currentData.append(finalItem)
        UserDefaults.standard.set(currentData, forKey: key)
        UserDefaults.standard.synchronize()
        
        let newItems = parseItems(currentData)
        DispatchQueue.main.async {
            self[keyPath: target] = newItems
        }
        AuthManager.shared.scheduleAutoSync()
    }
    
    /// Returns true only when the media is genuinely completed (progress >= 90% or marked 100%).
    /// Titles with <90% progress are "In Progress / Continue Watching" and not treated as finished.
    func isWatched(_ item: MediaItem) -> Bool {
        guard let existing = history.first(where: { $0.id == item.id }) else { return false }
        return (existing.progress ?? 0) >= 0.90
    }

    func isInHistory(_ item: MediaItem) -> Bool {
        return getHistoryItem(id: item.id) != nil
    }

    func getHistoryItem(id: String) -> MediaItem? {
        if let direct = history.first(where: { $0.id == id }) {
            return direct
        }
        let stripped = id.replacingOccurrences(of: "tt", with: "")
        if !stripped.isEmpty {
            return history.first(where: { $0.id.replacingOccurrences(of: "tt", with: "") == stripped })
        }
        return nil
    }

    func toggleWatched(_ item: MediaItem, season: Int? = nil, episode: Int? = nil, episodeTitle: String? = nil, episodeImage: URL? = nil) {
        if isWatched(item) {
            removeFromHistory(item)
        } else {
            addToHistory(item, progress: 1.0, season: season, episode: episode, episodeTitle: episodeTitle, episodeImage: episodeImage)
        }
    }

    func addToHistory(_ item: MediaItem, progress: Double? = nil, season: Int? = nil, episode: Int? = nil, episodeTitle: String? = nil, episodeImage: URL? = nil, playbackPosition: Double? = nil, playbackDuration: Double? = nil, streamURL: URL? = nil, torrentInfoHash: String? = nil, fileIndex: Int? = nil) {
        addToList(
            key: historyKey,
            item: item,
            progress: progress,
            season: season,
            episode: episode,
            episodeTitle: episodeTitle,
            episodeImage: episodeImage,
            playbackPosition: playbackPosition,
            playbackDuration: playbackDuration,
            streamURL: streamURL,
            torrentInfoHash: torrentInfoHash,
            fileIndex: fileIndex,
            target: \.history
        )
    }
    
    func removeFromHistory(_ item: MediaItem) {
        removeFromList(key: historyKey, item: item, target: \.history)
    }
    
    private func removeFromList(key: String, item: MediaItem, target: ReferenceWritableKeyPath<UserDataService, [MediaItem]>) {
        var currentData = UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []
        currentData.removeAll { ($0["id"] as? String) == item.id }
        UserDefaults.standard.set(currentData, forKey: key)
        UserDefaults.standard.synchronize()
        
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
        UserDefaults.standard.synchronize()
    }
    
    /// Same dict shape addToList() writes for watchlist/history entries.
    private func itemDict(_ item: MediaItem) -> [String: Any] {
        let typeString = item.category.lowercased().contains("movie") ? "movie" : "tv"
        let imageVal = item.posterURL?.absoluteString ?? item.imageURL?.absoluteString ?? ""
        let backdropVal = item.backdropURL?.absoluteString ?? item.heroURL?.absoluteString ?? imageVal
        var dict: [String: Any] = [
            "id": item.id,
            "type": typeString,
            "title": item.title,
            "image": imageVal,
            "backdrop": backdropVal,
            "timestamp": item.timestamp ?? Date().timeIntervalSince1970
        ]
        if let p = item.progress { dict["progress"] = p }
        if let s = item.lastSeason { dict["lastSeason"] = s }
        if let e = item.lastEpisode { dict["lastEpisode"] = e }
        if let et = item.lastEpisodeTitle { dict["lastEpisodeTitle"] = et }
        if let ei = item.lastEpisodeImage?.absoluteString { dict["lastEpisodeImage"] = ei }
        if let r = item.runtime { dict["runtime"] = r }
        if let l = item.logoURL?.absoluteString { dict["logo"] = l }
        if let pos = item.lastPlaybackPosition { dict["lastPlaybackPosition"] = pos }
        if let dur = item.lastPlaybackDuration { dict["lastPlaybackDuration"] = dur }
        if let su = item.lastStreamURL?.absoluteString { dict["lastStreamURL"] = su }
        if let hash = item.lastTorrentInfoHash { dict["lastTorrentInfoHash"] = hash }
        if let fi = item.lastFileIndex { dict["lastFileIndex"] = fi }
        return dict
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
            "profiles": ProfileManager.shared.exportProfilesData(),
            "addons": AddonManager.shared.exportAddonsPayload()
        ]
    }

    var hasLibraryContent: Bool {
        !watchlist.isEmpty || !history.isEmpty || !collections.isEmpty
    }

    // MARK: - Smart Cloud Merge Helpers
    
    private func mergeHistoryData(local: [[String: Any]], remote: [[String: Any]]) -> [[String: Any]] {
        var map: [String: [String: Any]] = [:]
        for item in local {
            guard let id = item["id"] as? String else { continue }
            map[id] = item
        }
        for item in remote {
            guard let id = item["id"] as? String else { continue }
            if let localItem = map[id] {
                let localTime = localItem["timestamp"] as? Double ?? 0
                let remoteTime = item["timestamp"] as? Double ?? 0
                if remoteTime > localTime {
                    map[id] = item
                } else if remoteTime == localTime {
                    let localProg = localItem["progress"] as? Double ?? 0
                    let remoteProg = item["progress"] as? Double ?? 0
                    if remoteProg > localProg {
                        map[id] = item
                    }
                }
            } else {
                map[id] = item
            }
        }
        return Array(map.values).sorted {
            ($0["timestamp"] as? Double ?? 0) > ($1["timestamp"] as? Double ?? 0)
        }
    }

    private func mergeWatchlistData(local: [[String: Any]], remote: [[String: Any]]) -> [[String: Any]] {
        var map: [String: [String: Any]] = [:]
        var order: [String] = []
        for item in local {
            guard let id = item["id"] as? String else { continue }
            map[id] = item
            order.append(id)
        }
        for item in remote {
            guard let id = item["id"] as? String else { continue }
            if map[id] == nil {
                map[id] = item
                order.append(id)
            }
        }
        return order.compactMap { map[$0] }
    }

    private func mergeCollections(local: [UserCollection], remote: [UserCollection]) -> [UserCollection] {
        var map: [String: UserCollection] = [:]
        var order: [String] = []
        
        for col in local {
            map[col.id] = col
            order.append(col.id)
        }
        
        for rCol in remote {
            if let lCol = map[rCol.id] {
                // Merge items between local and remote versions of this collection
                var itemMap: [String: MediaItem] = [:]
                var itemOrder: [String] = []
                for item in lCol.items {
                    itemMap[item.id] = item
                    itemOrder.append(item.id)
                }
                for item in rCol.items {
                    if itemMap[item.id] == nil {
                        itemMap[item.id] = item
                        itemOrder.append(item.id)
                    }
                }
                let mergedItems = itemOrder.compactMap { itemMap[$0] }
                let name = lCol.name.isEmpty ? rCol.name : lCol.name
                let created = min(lCol.createdAt, rCol.createdAt)
                map[rCol.id] = UserCollection(id: rCol.id, name: name, createdAt: created, items: mergedItems)
            } else {
                map[rCol.id] = rCol
                order.append(rCol.id)
            }
        }
        
        return order.compactMap { map[$0] }
    }

    /// Applies a cloud payload to the CURRENT profile with two-way smart merging
    /// to guarantee local watching progress or recent adds are never discarded by older cloud snapshots.
    func applyCloudPayload(_ payload: [String: Any]) {
        let remoteWatchlist = payload["watchlist"] as? [[String: Any]] ?? []
        let remoteHistory = payload["history"] as? [[String: Any]] ?? []

        let localWatchlist = (UserDefaults.standard.array(forKey: self.watchlistKey) as? [[String: Any]]) ?? []
        let localHistory = (UserDefaults.standard.array(forKey: self.historyKey) as? [[String: Any]]) ?? []

        let mergedWatchlist = mergeWatchlistData(local: localWatchlist, remote: remoteWatchlist)
        let mergedHistory = mergeHistoryData(local: localHistory, remote: remoteHistory)

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

        let mergedCollections = mergeCollections(local: self.collections, remote: imported)

        let tasteLoved = payload["tasteLoved"] as? [[String: Any]]
        let tasteSnapshots = payload["tasteSnapshots"] as? [[String: Any]]
        let profilesData = payload["profiles"] as? [[String: Any]]
        let addonsData = payload["addons"] as? [[String: Any]]

        DispatchQueue.main.async {
            // Persist first so disk matches memory.
            self.collections = mergedCollections.sorted { $0.createdAt < $1.createdAt }
            self.saveCollections()
            
            UserDefaults.standard.set(mergedWatchlist, forKey: self.watchlistKey)
            self.watchlist = self.parseItems(mergedWatchlist)
            
            UserDefaults.standard.set(mergedHistory, forKey: self.historyKey)
            self.history = self.parseItems(mergedHistory)
            
            TasteProfileManager.shared.applyCloudData(loved: tasteLoved, snapshots: tasteSnapshots)
            ProfileManager.shared.applyCloudProfilesData(profilesData)
            if let addonsData {
                AddonManager.shared.syncWithCloudAddons(addonsData)
            }
            print("[UserDataService] Smart cloud merge applied (watchlist: \(self.watchlist.count), history: \(self.history.count), collections: \(self.collections.count))")
        }
    }
}


