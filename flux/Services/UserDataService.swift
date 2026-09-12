import Foundation
import Combine
import OSLog

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
    func switchProfile(to profile: UserProfile?) {
        if let profile {
            historyKey = "profile.\(profile.id.uuidString).history"
            watchlistKey = "profile.\(profile.id.uuidString).watchlist"
            collectionsKey = "profile.\(profile.id.uuidString).collections"

            if !profile.isKids {
                migrateLegacyDataIfNeeded(for: profile.id)
            }
        } else {
            historyKey = "localHistoryDataStremio"
            watchlistKey = "localWatchlistDataStremio"
            collectionsKey = "localCollectionsData"
        }
        watchlist = []
        history = []
        collections = []
        if profile != nil {
            loadInitialData()
        }
    }

    private func migrateLegacyDataIfNeeded(for profileID: UUID) {
        let pWatchKey = "profile.\(profileID.uuidString).watchlist"
        let pHistKey = "profile.\(profileID.uuidString).history"
        let pColKey = "profile.\(profileID.uuidString).collections"

        let existingWatch = UserDefaults.standard.array(forKey: pWatchKey) as? [[String: Any]] ?? []
        if existingWatch.isEmpty,
           let legacyWatch = UserDefaults.standard.array(forKey: "localWatchlistDataStremio") as? [[String: Any]], !legacyWatch.isEmpty {
            UserDefaults.standard.set(legacyWatch, forKey: pWatchKey)
        }

        let existingHist = UserDefaults.standard.array(forKey: pHistKey) as? [[String: Any]] ?? []
        if existingHist.isEmpty,
           let legacyHist = UserDefaults.standard.array(forKey: "localHistoryDataStremio") as? [[String: Any]], !legacyHist.isEmpty {
            UserDefaults.standard.set(legacyHist, forKey: pHistKey)
        }

        let existingCol = UserDefaults.standard.array(forKey: pColKey) as? [[String: Any]] ?? []
        if existingCol.isEmpty,
           let legacyCol = UserDefaults.standard.array(forKey: "localCollectionsData") as? [[String: Any]], !legacyCol.isEmpty {
            UserDefaults.standard.set(legacyCol, forKey: pColKey)
        }
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
            self.collections = []
        }
    }

    /// Wipes all in-memory library and local storage upon account sign-out.
    func handleSignOut() {
        stopSyncing()
        watchlist = []
        history = []
        collections = []
        historyKey = "localHistoryDataStremio"
        watchlistKey = "localWatchlistDataStremio"
        collectionsKey = "localCollectionsData"
        
        UserDefaults.standard.removeObject(forKey: "localHistoryDataStremio")
        UserDefaults.standard.removeObject(forKey: "localWatchlistDataStremio")
        UserDefaults.standard.removeObject(forKey: "localCollectionsData")
        UserDefaults.standard.removeObject(forKey: "globalEpisodeProgress")
        UserDefaults.standard.removeObject(forKey: UserDefaults.Key.tmdbApiKey)
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
            enriched.logoURL = enriched.logoURL ?? item.logoURL
            enriched.isNewEpisode = item.isNewEpisode ?? enriched.isNewEpisode

            // If the item was previously finished (progress >= 0.90) and is a TV series,
            // check if a newly aired episode or season has been released.
            let isSeries = (enriched.category == "TV Show" || enriched.category == "Series" || enriched.isSeries)
            if isSeries,
               let curSeason = enriched.lastSeason,
               let curEpisode = enriched.lastEpisode,
               (enriched.progress ?? 0) >= 0.90 {
                if let next = await PlayerManager.shared.resolveNextReleased(item: enriched, season: curSeason, episode: curEpisode) {
                    if next.season != curSeason || next.episode != curEpisode {
                        enriched.lastSeason = next.season
                        enriched.lastEpisode = next.episode
                        enriched.progress = 0.0
                        enriched.lastPlaybackPosition = 0.0
                        enriched.isNewEpisode = true
                        enriched.timestamp = Date().timeIntervalSince1970
                        
                        let type = "tv"
                        let tmdbID = enriched.id.starts(with: "tt") ? await TMDBEnricher.shared.resolveTmdbID(imdbID: enriched.id, type: type) : enriched.id
                        if let id = tmdbID {
                            let info = await TMDBEnricher.shared.fetchEpisodeInfo(tmdbID: id, season: next.season, episode: next.episode)
                            if let still = info.stillURL {
                                enriched.lastEpisodeImage = still
                            }
                            if let title = info.title, !title.isEmpty {
                                enriched.lastEpisodeTitle = title
                            }
                            if let rt = info.runtime {
                                enriched.runtime = rt
                            }
                        }
                        didChange = true
                    }
                }
            } else if (enriched.progress ?? 0) > 0.05 && (enriched.isNewEpisode == true) {
                enriched.isNewEpisode = false
                didChange = true
            }

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

            // If TMDB key is active, ensure we fetch and persist official TMDB transparent logos
            if TMDBEnricher.shared.hasKey {
                let isSeries = (enriched.category == "TV Show" || enriched.category == "Series" || enriched.isSeries)
                let type = isSeries ? "tv" : "movie"
                let needsTMDBLogo = enriched.logoURL == nil || (enriched.logoURL?.absoluteString.contains("tmdb.org") == false) || (enriched.logoURL?.absoluteString.contains("/original/") == false)
                if needsTMDBLogo {
                    let cleanID = enriched.id.replacingOccurrences(of: "tmdb-", with: "").replacingOccurrences(of: "tmdb:", with: "")
                    let tmdbID = enriched.id.starts(with: "tt") ? await TMDBEnricher.shared.resolveTmdbID(imdbID: enriched.id, type: type) : cleanID
                    if let id = tmdbID, let tmdbLogo = await TMDBEnricher.shared.fetchLogoURL(tmdbID: id, type: type, originalLanguage: enriched.originalLanguage) {
                        enriched.logoURL = tmdbLogo
                        didChange = true
                    }
                }
            }

            // Ensure logo is high-quality (upgrades any /medium/ to /large/ or /w500/ to /original/)
            if let existing = enriched.logoURL {
                let hq = existing.highQuality()
                if hq != existing {
                    enriched.logoURL = hq
                    didChange = true
                }
            } else if let match = enriched.id.range(of: "tt[0-9]+", options: .regularExpression) {
                // Fallback to Metahub large logo if none present
                let imdbID = String(enriched.id[match])
                enriched.logoURL = URL(string: "https://images.metahub.space/logo/large/\(imdbID)/img")
                didChange = true
            }

            enriched.timestamp = item.timestamp
            if enriched.backdropURL != item.backdropURL || enriched.posterURL != item.posterURL || enriched.lastEpisodeImage != item.lastEpisodeImage || enriched.lastSeason != item.lastSeason || enriched.logoURL != item.logoURL {
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
            let isNewEpisode = dict["isNewEpisode"] as? Bool
            
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
                originalLanguage: dict["originalLanguage"] as? String,
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
            item.isNewEpisode = isNewEpisode
            
            if let imageString = dict["lastEpisodeImage"] as? String, let url = URL(string: imageString) {
                item.lastEpisodeImage = url
            }
            if let r = dict["runtime"] as? String {
                item.runtime = r
            }
            if let l = dict["logo"] as? String, let u = URL(string: l) {
                item.logoURL = u.highQuality()
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
        var seenKeys: Set<String> = []
        
        for entry in sorted {
            let item = entry.item
            let strippedID = item.id.replacingOccurrences(of: "tt", with: "")
            let titleKey = "\(item.category.lowercased()):\(item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
            let idKey = "id:\(item.id)"
            let numKey = strippedID.isEmpty ? idKey : "num:\(strippedID)"
            
            if !seenKeys.contains(idKey) && !seenKeys.contains(numKey) && !seenKeys.contains(titleKey) {
                uniqueItems.append(item)
                seenKeys.insert(idKey)
                seenKeys.insert(numKey)
                if !item.title.isEmpty && item.title != "Unknown" {
                    seenKeys.insert(titleKey)
                }
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
    
    /// In-progress titles: started (<90% progress or next episode queued in a series).
    /// Sorted by most recently watched first, deduplicated by ID and normalized title.
    var continueWatching: [MediaItem] {
        var seen = Set<String>()
        var result: [MediaItem] = []

        for item in history {
            // Completed titles belong in Recently Watched, not Continue Watching
            if isWatched(item) { continue }

            // Must have some record of watching (progress > 0 or a specific TV episode queued)
            let prog = item.progress ?? 0.0
            let hasQueuedEpisode = (item.lastSeason != nil && item.lastEpisode != nil)
            if prog <= 0.001 && !hasQueuedEpisode {
                continue
            }

            let strippedID = item.id.replacingOccurrences(of: "tt", with: "")
            let titleKey = "\(item.category.lowercased()):\(item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
            let idKey = "id:\(item.id)"
            let numKey = strippedID.isEmpty ? idKey : "num:\(strippedID)"

            if !seen.contains(idKey) && !seen.contains(numKey) && !seen.contains(titleKey) {
                result.append(item)
                seen.insert(idKey)
                seen.insert(numKey)
                if !item.title.isEmpty && item.title != "Unknown" {
                    seen.insert(titleKey)
                }
            }
        }
        return result
    }

    /// Completed titles (progress >= 90% or marked watched).
    /// Sorted by most recently watched first, deduplicated by ID and normalized title.
    var recentlyWatched: [MediaItem] {
        var seen = Set<String>()
        var result: [MediaItem] = []

        for item in history {
            // Only genuinely completed titles belong in recently watched
            guard isWatched(item) else { continue }

            let strippedID = item.id.replacingOccurrences(of: "tt", with: "")
            let titleKey = "\(item.category.lowercased()):\(item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
            let idKey = "id:\(item.id)"
            let numKey = strippedID.isEmpty ? idKey : "num:\(strippedID)"

            if !seen.contains(idKey) && !seen.contains(numKey) && !seen.contains(titleKey) {
                result.append(item)
                seen.insert(idKey)
                seen.insert(numKey)
                if !item.title.isEmpty && item.title != "Unknown" {
                    seen.insert(titleKey)
                }
            }
        }
        return result
    }

    private func addToList(key: String, item: MediaItem, progress: Double? = nil, season: Int? = nil, episode: Int? = nil, episodeTitle: String? = nil, episodeImage: URL? = nil, playbackPosition: Double? = nil, playbackDuration: Double? = nil, streamURL: URL? = nil, torrentInfoHash: String? = nil, fileIndex: Int? = nil, isRestart: Bool = false, isLightweightTick: Bool = false, target: ReferenceWritableKeyPath<UserDataService, [MediaItem]>) {
        let typeString = item.category.lowercased().contains("movie") ? "movie" : "tv"
        
        let imageVal = item.posterURL?.absoluteString ?? item.imageURL?.absoluteString ?? ""
        let backdropVal = item.backdropURL?.absoluteString ?? item.heroURL?.absoluteString ?? imageVal
        
        var currentData = UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []
        // Find and remove existing item if present (handles exact ID, stripped 'tt' IMDb/TMDB cross-format, and normalized title+type)
        let cleanNewTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let strippedNewID = item.id.replacingOccurrences(of: "tt", with: "")
        var existingEntry: [String: Any]?
        currentData.removeAll { existing in
            guard let existingID = existing["id"] as? String else { return false }
            let isMatch: Bool
            if existingID == item.id {
                isMatch = true
            } else {
                let strippedExistingID = existingID.replacingOccurrences(of: "tt", with: "")
                if !strippedExistingID.isEmpty && strippedExistingID == strippedNewID {
                    isMatch = true
                } else {
                    let existingTitle = (existing["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let existingType = existing["type"] as? String ?? ""
                    isMatch = !cleanNewTitle.isEmpty && cleanNewTitle != "unknown" && existingTitle == cleanNewTitle && existingType == typeString
                }
            }
            if isMatch && existingEntry == nil {
                existingEntry = existing
            }
            return isMatch
        }

        // Monotonic high-water mark progress calculation:
        // Progress for Continue Watching cards must NEVER regress backwards when re-opening
        // or scrubbing to an earlier timestamp, unless explicitly restarting.
        var finalProgress: Double? = progress ?? item.progress
        if let newProg = finalProgress {
            if isRestart {
                finalProgress = newProg
            } else if let existingProg = existingEntry?["progress"] as? Double {
                let existingSeason = existingEntry?["lastSeason"] as? Int
                let existingEpisode = existingEntry?["lastEpisode"] as? Int
                let isSameUnit = (typeString == "movie") || (existingSeason == season && existingEpisode == episode)
                if isSameUnit {
                    // If previously finished (>= 90%) and starting again (< 2%), permit restart
                    if existingProg >= 0.90 && newProg < 0.02 {
                        finalProgress = newProg
                    } else {
                        // High-water mark
                        finalProgress = max(existingProg, newProg)
                    }
                }
            }
        }

        var finalItem: [String: Any] = [
            "id": item.id,
            "type": typeString,
            "title": item.title,
            "image": imageVal,
            "backdrop": backdropVal,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        if let p = finalProgress { finalItem["progress"] = p }
        if let s = season { finalItem["lastSeason"] = s }
        if let e = episode { finalItem["lastEpisode"] = e }
        if let et = episodeTitle { finalItem["lastEpisodeTitle"] = et }
        if let ei = episodeImage { finalItem["lastEpisodeImage"] = ei.absoluteString }
        if let r = item.runtime { finalItem["runtime"] = r }
        if let l = item.logoURL?.absoluteString { finalItem["logo"] = l }
        if let ol = item.originalLanguage { finalItem["originalLanguage"] = ol }
        if let pos = playbackPosition ?? item.lastPlaybackPosition ?? (existingEntry?["lastPlaybackPosition"] as? Double) { finalItem["lastPlaybackPosition"] = pos }
        if let dur = playbackDuration ?? item.lastPlaybackDuration ?? (existingEntry?["lastPlaybackDuration"] as? Double) { finalItem["lastPlaybackDuration"] = dur }
        if let su = streamURL ?? item.lastStreamURL { finalItem["lastStreamURL"] = su.absoluteString }
        if let hash = torrentInfoHash ?? item.lastTorrentInfoHash { finalItem["lastTorrentInfoHash"] = hash }
        if let fi = fileIndex ?? item.lastFileIndex { finalItem["lastFileIndex"] = fi }
        if (finalProgress ?? 0) > 0.05 {
            finalItem["isNewEpisode"] = false
        } else if let ne = item.isNewEpisode ?? (existingEntry?["isNewEpisode"] as? Bool) {
            finalItem["isNewEpisode"] = ne
        }
        
        currentData.append(finalItem)
        UserDefaults.standard.set(currentData, forKey: key)
        if !isLightweightTick {
            UserDefaults.standard.synchronize()
        }

        // Lightweight tick throttling: during continuous 5s playback ticks, avoid re-parsing
        // and re-publishing the full history array unless progress changed by at least 2%.
        if isLightweightTick {
            let prevProg = (existingEntry?["progress"] as? Double) ?? 0.0
            let currentProg = finalProgress ?? 0.0
            if abs(currentProg - prevProg) < 0.02 {
                return
            }
        }
        
        let newItems = parseItems(currentData)
        if Thread.isMainThread {
            self[keyPath: target] = newItems
        } else {
            DispatchQueue.main.async {
                self[keyPath: target] = newItems
            }
        }
        if !isLightweightTick {
            AuthManager.shared.scheduleAutoSync()
        }
    }
    
    /// Returns true only when the media is genuinely completed (progress >= 90% or marked 100%).
    /// Titles with <90% progress are "In Progress / Continue Watching" and not treated as finished.
    func isWatched(_ item: MediaItem) -> Bool {
        guard let existing = getHistoryItem(for: item) ?? history.first(where: { $0.id == item.id }) else { return false }
        return (existing.progress ?? 0) >= 0.90
    }

    func isInHistory(_ item: MediaItem) -> Bool {
        return getHistoryItem(for: item) != nil
    }

    func getHistoryItem(for item: MediaItem) -> MediaItem? {
        return getHistoryItem(id: item.id, title: item.title, category: item.category)
    }

    func getHistoryItem(id: String, title: String? = nil, category: String? = nil) -> MediaItem? {
        // 1. Direct ID Match
        if let direct = history.first(where: { $0.id == id }) {
            return direct
        }
        // 2. "tt" Prefix Invariance Match
        let stripped = id.replacingOccurrences(of: "tt", with: "")
        if !stripped.isEmpty {
            if let matched = history.first(where: { $0.id.replacingOccurrences(of: "tt", with: "") == stripped }) {
                return matched
            }
        }
        // 3. Exact Normalized Title and Category Match
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !title.isEmpty {
            let cat = category?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let matched = history.first(where: {
                let histTitle = $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let isTitleSame = histTitle == title
                if let cat = cat, !cat.isEmpty {
                    let histCat = $0.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let isSameCat = (histCat == cat) ||
                                    ((cat.contains("tv") || cat.contains("series")) && (histCat.contains("tv") || histCat.contains("series"))) ||
                                    (cat.contains("movie") && histCat.contains("movie"))
                    return isTitleSame && isSameCat
                }
                return isTitleSame
            }) {
                return matched
            }
        }
        return nil
    }

    func toggleWatched(_ item: MediaItem, season: Int? = nil, episode: Int? = nil, episodeTitle: String? = nil, episodeImage: URL? = nil) {
        if isWatched(item) {
            removeFromHistory(item)
        } else {
            addToHistory(item, progress: 1.0, season: season, episode: episode, episodeTitle: episodeTitle, episodeImage: episodeImage, isRestart: true)
        }
    }

    var episodeProgressKey: String {
        if let profile = ProfileManager.shared.currentProfile {
            return "profile.\(profile.id.uuidString).episodeProgress"
        }
        return "globalEpisodeProgress"
    }

    func getEpisodeProgress(for itemID: String, season: Int, episode: Int) -> (progress: Double, position: Double, duration: Double)? {
        let key = "\(itemID)_s\(season)e\(episode)"
        let allProgress = UserDefaults.standard.dictionary(forKey: episodeProgressKey) as? [String: [String: Any]] ?? [:]
        guard let dict = allProgress[key] else { return nil }
        let progress = dict["progress"] as? Double ?? 0.0
        let position = dict["position"] as? Double ?? 0.0
        let duration = dict["duration"] as? Double ?? 0.0
        return (progress, position, duration)
    }

    func saveEpisodeProgress(for itemID: String, season: Int, episode: Int, position: Double, duration: Double, isRestart: Bool = false, isLightweightTick: Bool = false) {
        guard duration > 0 else { return }
        let key = "\(itemID)_s\(season)e\(episode)"
        var allProgress = UserDefaults.standard.dictionary(forKey: episodeProgressKey) as? [String: [String: Any]] ?? [:]
        let rawProg = min(1.0, max(0.0, position / duration))
        let prevProg = allProgress[key]?["progress"] as? Double ?? 0.0
        let prog: Double
        if isRestart || (prevProg >= 0.90 && rawProg < 0.02) {
            prog = rawProg
        } else {
            prog = max(prevProg, rawProg)
        }
        allProgress[key] = [
            "position": position,
            "duration": duration,
            "progress": prog,
            "timestamp": Date().timeIntervalSince1970
        ]
        UserDefaults.standard.set(allProgress, forKey: episodeProgressKey)
        if !isLightweightTick {
            UserDefaults.standard.synchronize()
        }
    }

    func addToHistory(_ item: MediaItem, progress: Double? = nil, season: Int? = nil, episode: Int? = nil, episodeTitle: String? = nil, episodeImage: URL? = nil, playbackPosition: Double? = nil, playbackDuration: Double? = nil, streamURL: URL? = nil, torrentInfoHash: String? = nil, fileIndex: Int? = nil, isRestart: Bool = false, isLightweightTick: Bool = false) {
        let effProgress = progress ?? item.progress
        let effSeason = season ?? item.lastSeason
        let effEpisode = episode ?? item.lastEpisode
        let effPos = playbackPosition ?? item.lastPlaybackPosition
        let effDur = playbackDuration ?? item.lastPlaybackDuration

        if let s = effSeason, let e = effEpisode, let pos = effPos, let dur = effDur {
            saveEpisodeProgress(for: item.id, season: s, episode: e, position: pos, duration: dur, isRestart: isRestart, isLightweightTick: isLightweightTick)
        }
        addToList(
            key: historyKey,
            item: item,
            progress: effProgress,
            season: effSeason,
            episode: effEpisode,
            episodeTitle: episodeTitle ?? item.lastEpisodeTitle,
            episodeImage: episodeImage ?? item.lastEpisodeImage,
            playbackPosition: effPos,
            playbackDuration: effDur,
            streamURL: streamURL ?? item.lastStreamURL,
            torrentInfoHash: torrentInfoHash ?? item.lastTorrentInfoHash,
            fileIndex: fileIndex ?? item.lastFileIndex,
            isRestart: isRestart,
            isLightweightTick: isLightweightTick,
            target: \.history
        )
    }
    
    func removeFromHistory(_ item: MediaItem) {
        removeFromList(key: historyKey, item: item, target: \.history)
    }
    
    private func removeFromList(key: String, item: MediaItem, target: ReferenceWritableKeyPath<UserDataService, [MediaItem]>) {
        var currentData = UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []
        let cleanNewTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let strippedNewID = item.id.replacingOccurrences(of: "tt", with: "")
        currentData.removeAll { existing in
            guard let existingID = existing["id"] as? String else { return false }
            if existingID == item.id { return true }
            let strippedExistingID = existingID.replacingOccurrences(of: "tt", with: "")
            if !strippedExistingID.isEmpty && strippedExistingID == strippedNewID { return true }
            let existingTitle = (existing["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !cleanNewTitle.isEmpty && cleanNewTitle != "unknown" && existingTitle == cleanNewTitle {
                return true
            }
            return false
        }
        UserDefaults.standard.set(currentData, forKey: key)
        UserDefaults.standard.synchronize()
        
        let newItems = parseItems(currentData)
        if Thread.isMainThread {
            self[keyPath: target] = newItems
        } else {
            DispatchQueue.main.async {
                self[keyPath: target] = newItems
            }
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
        if let ne = item.isNewEpisode { dict["isNewEpisode"] = ne }
        if let ol = item.originalLanguage { dict["originalLanguage"] = ol }
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

    /// Sanitizes history and watchlist items for cloud sync by stripping device-local ephemeral fields.
    func sanitizeDataArray(_ items: [[String: Any]]) -> [[String: Any]] {
        return items.map { dict -> [String: Any] in
            var copy = dict
            copy.removeValue(forKey: "lastStreamURL")
            copy.removeValue(forKey: "lastTorrentInfoHash")
            return copy
        }
    }

    /// Full library snapshot for the cloud blob.
    /// In multi-profile mode, root `watchlist` and `history` mirror the primary adult profile
    /// for backward compatibility with older clients or single-profile views, while each
    /// profile's scoped library is independently synchronized within the `profiles` array.
    func exportCloudPayload() -> [String: Any] {
        let profiles = ProfileManager.shared.profiles
        let primaryProfile = profiles.first(where: { !$0.isKids }) ?? profiles.first
        let primaryPrefix = primaryProfile.map { "profile.\($0.id.uuidString)." }

        let primaryWatchlistKey = primaryPrefix.map { $0 + "watchlist" } ?? watchlistKey
        let primaryHistoryKey = primaryPrefix.map { $0 + "history" } ?? historyKey

        let watchlistData = (UserDefaults.standard.array(forKey: primaryWatchlistKey) as? [[String: Any]])
            ?? (UserDefaults.standard.array(forKey: "localWatchlistDataStremio") as? [[String: Any]])
            ?? []
        let historyData = (UserDefaults.standard.array(forKey: primaryHistoryKey) as? [[String: Any]])
            ?? (UserDefaults.standard.array(forKey: "localHistoryDataStremio") as? [[String: Any]])
            ?? []

        let sanitizedWatchlist = sanitizeDataArray(watchlistData)
        let sanitizedHistory = sanitizeDataArray(historyData)
        let epProgress = (UserDefaults.standard.dictionary(forKey: episodeProgressKey) as? [String: [String: Any]]) ?? [:]

        let tmdbKey = UserDefaults.standard.string(forKey: UserDefaults.Key.tmdbApiKey) ?? ""
        let displayName = UserDefaults.standard.string(forKey: "flux.authDisplayName") ?? ""
        let appLang = UserDefaults.standard.string(forKey: UserDefaults.Key.appLanguage) ?? "en"

        return [
            "version": 3,
            "watchlist": sanitizedWatchlist,
            "history": sanitizedHistory,
            "settings": ProfileManager.shared.exportGlobalSettings(),
            "episodeProgress": epProgress,
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
            "addons": AddonManager.shared.exportAddonsPayload(),
            "tmdbApiKey": tmdbKey,
            "userDisplayName": displayName,
            "appLanguage": appLang
        ]
    }

    var hasLibraryContent: Bool {
        !watchlist.isEmpty || !history.isEmpty || !collections.isEmpty
    }

    // MARK: - Smart Cloud Merge Helpers
    
    private func canonicalIdentityKey(for dict: [String: Any]) -> String {
        let id = dict["id"] as? String ?? ""
        let stripped = id.replacingOccurrences(of: "tt", with: "")
        if !stripped.isEmpty && CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: stripped)) {
            return "num:\(stripped)"
        }
        let title = (dict["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let type = dict["type"] as? String ?? ""
        if !title.isEmpty && title != "unknown" {
            return "title:\(type):\(title)"
        }
        return "id:\(id)"
    }

    func mergeHistoryData(local: [[String: Any]], remote: [[String: Any]]) -> [[String: Any]] {
        var map: [String: [String: Any]] = [:]
        for item in local {
            guard let _ = item["id"] as? String else { continue }
            let key = canonicalIdentityKey(for: item)
            map[key] = item
        }
        for item in remote {
            guard let _ = item["id"] as? String else { continue }
            let key = canonicalIdentityKey(for: item)
            if let localItem = map[key] {
                let localTime = localItem["timestamp"] as? Double ?? 0
                let remoteTime = item["timestamp"] as? Double ?? 0
                if remoteTime > localTime {
                    map[key] = item
                } else if remoteTime == localTime {
                    let localProg = localItem["progress"] as? Double ?? 0
                    let remoteProg = item["progress"] as? Double ?? 0
                    if remoteProg > localProg {
                        map[key] = item
                    }
                }
            } else {
                map[key] = item
            }
        }
        return Array(map.values).sorted {
            ($0["timestamp"] as? Double ?? 0) > ($1["timestamp"] as? Double ?? 0)
        }
    }

    func mergeWatchlistData(local: [[String: Any]], remote: [[String: Any]]) -> [[String: Any]] {
        var map: [String: [String: Any]] = [:]
        var order: [String] = []
        for item in local {
            guard let _ = item["id"] as? String else { continue }
            let key = canonicalIdentityKey(for: item)
            map[key] = item
            order.append(key)
        }
        for item in remote {
            guard let _ = item["id"] as? String else { continue }
            let key = canonicalIdentityKey(for: item)
            if map[key] == nil {
                map[key] = item
                order.append(key)
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

    /// Order-sensitive raw comparison for merged cloud arrays. Serialization
    /// failure (non-JSON values) treats the data as changed — the safe direction.
    private static func rawJSONEqual(_ a: [[String: Any]], _ b: [[String: Any]]) -> Bool {
        guard a.count == b.count,
              let da = try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys]),
              let db = try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys]) else { return false }
        return da == db
    }

    /// Reloads current profile data from disk into memory.
    func reloadCurrentProfileData() {
        loadInitialData()
    }

    /// Applies a cloud payload to the CURRENT profile with two-way smart merging
    /// to guarantee local watching progress or recent adds are never discarded by older cloud snapshots.
    /// - Parameter replaceProfiles: when false (stale background pull), per-profile
    ///   history merges still run, but the profiles LIST is never replaced — a stale
    ///   remote list must not wipe the local one. Sign-in always passes true.
    @discardableResult
    func applyCloudPayload(_ payload: [String: Any], replaceProfiles: Bool = true) -> Bool {
        // 1. Restore remote profiles FIRST so the active profile matches the cloud profile
        let profilesData = payload["profiles"] as? [[String: Any]]
        ProfileManager.shared.applyCloudProfilesData(profilesData, replaceList: replaceProfiles)
        // TEMP-DIAGNOSTIC (missing profiles).
        Logger.sync.error("DIAG apply: remoteProfiles=\(profilesData?.count ?? -1) localProfilesNow=\(ProfileManager.shared.profiles.count) names=\(ProfileManager.shared.profiles.map { $0.name }.joined(separator: ","), privacy: .public)")
        ProfileManager.shared.cleanKidsProfileDataIfNeeded()

        // 2. Restore TMDB API Key if present in cloud payload and unset locally
        if let remoteTmdb = payload["tmdbApiKey"] as? String, !remoteTmdb.isEmpty {
            let localTmdb = UserDefaults.standard.string(forKey: UserDefaults.Key.tmdbApiKey) ?? ""
            if localTmdb.isEmpty {
                UserDefaults.standard.set(remoteTmdb, forKey: UserDefaults.Key.tmdbApiKey)
                print("[UserDataService] Restored TMDB API key from cloud payload")
            }
        }

        // 3. Restore Display Name if present in cloud payload
        if let remoteName = payload["userDisplayName"] as? String, !remoteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let localName = UserDefaults.standard.string(forKey: "flux.authDisplayName") ?? ""
            if localName.isEmpty || localName == AuthManager.shared.currentUser?.email?.components(separatedBy: "@").first {
                UserDefaults.standard.set(remoteName, forKey: "flux.authDisplayName")
                if Thread.isMainThread {
                    AuthManager.shared.updateDisplayName(remoteName)
                } else {
                    DispatchQueue.main.async {
                        AuthManager.shared.updateDisplayName(remoteName)
                    }
                }
            }
        }

        // 4. Restore App Language if present in cloud payload
        let remoteSettings = payload["settings"] as? [String: Any]
        let remoteLang = (payload["appLanguage"] as? String) ?? (remoteSettings?["appLanguage"] as? String)
        if let remoteLang, !remoteLang.isEmpty {
            UserDefaults.standard.set(remoteLang, forKey: UserDefaults.Key.appLanguage)
            if Thread.isMainThread {
                LanguageManager.shared.syncFromProfile(remoteLang)
            } else {
                DispatchQueue.main.async {
                    LanguageManager.shared.syncFromProfile(remoteLang)
                }
            }
        }

        // 5. Merge history & watchlist for the now-active profile
        let remoteWatchlist = payload["watchlist"] as? [[String: Any]] ?? []
        let remoteHistory = payload["history"] as? [[String: Any]] ?? []
        let isCurrentKids = ProfileManager.shared.currentProfile?.isKids == true

        let localWatchlist = (UserDefaults.standard.array(forKey: self.watchlistKey) as? [[String: Any]])
            ?? (isCurrentKids ? [] : (UserDefaults.standard.array(forKey: "localWatchlistDataStremio") as? [[String: Any]]))
            ?? []
        let localHistory = (UserDefaults.standard.array(forKey: self.historyKey) as? [[String: Any]])
            ?? (isCurrentKids ? [] : (UserDefaults.standard.array(forKey: "localHistoryDataStremio") as? [[String: Any]]))
            ?? []

        let mergedWatchlist: [[String: Any]]
        let mergedHistory: [[String: Any]]

        if isCurrentKids {
            // Under Kids mode, root watchlist/history belongs to the primary adult profile.
            // Never copy adult items into the Kids profile!
            // Kids profile data was already restored/merged per-profile in applyCloudProfilesData().
            mergedWatchlist = localWatchlist
            mergedHistory = localHistory

            // Ensure adult profile receives any root payload updates
            if let primary = ProfileManager.shared.profiles.first(where: { !$0.isKids }) {
                let pPrefix = "profile.\(primary.id.uuidString)."
                let pLocalWatch = (UserDefaults.standard.array(forKey: pPrefix + "watchlist") as? [[String: Any]])
                    ?? (UserDefaults.standard.array(forKey: "localWatchlistDataStremio") as? [[String: Any]]) ?? []
                let pLocalHist = (UserDefaults.standard.array(forKey: pPrefix + "history") as? [[String: Any]])
                    ?? (UserDefaults.standard.array(forKey: "localHistoryDataStremio") as? [[String: Any]]) ?? []
                let pMergedWatch = mergeWatchlistData(local: pLocalWatch, remote: remoteWatchlist)
                let pMergedHist = mergeHistoryData(local: pLocalHist, remote: remoteHistory)
                UserDefaults.standard.set(pMergedWatch, forKey: pPrefix + "watchlist")
                UserDefaults.standard.set(pMergedHist, forKey: pPrefix + "history")
            }
        } else {
            mergedWatchlist = mergeWatchlistData(local: localWatchlist, remote: remoteWatchlist)
            mergedHistory = mergeHistoryData(local: localHistory, remote: remoteHistory)
            UserDefaults.standard.set(mergedWatchlist, forKey: self.watchlistKey)
            UserDefaults.standard.set(mergedHistory, forKey: self.historyKey)
        }

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

        let mergedCollections: [UserCollection]
        if isCurrentKids {
            mergedCollections = self.collections
        } else {
            mergedCollections = mergeCollections(local: self.collections, remote: imported)
        }

        let tasteLoved = payload["tasteLoved"] as? [[String: Any]]
        let tasteSnapshots = payload["tasteSnapshots"] as? [[String: Any]]
        let addonsData = payload["addons"] as? [[String: Any]]
        let remoteEpProgress = payload["episodeProgress"] as? [String: [String: Any]]

        // Only publish/post when the merge actually changed something. @Published
        // fires on every set (even for identical values), and fluxRefresh makes
        // every page wipe caches and refetch all rails — posting it on a no-op
        // pull kept the whole UI churning and pinned scrolling at ~10fps.
        let applyUIUpdates = {
            let watchlistChanged = !Self.rawJSONEqual(mergedWatchlist, localWatchlist)
            let historyChanged = !Self.rawJSONEqual(mergedHistory, localHistory)
            let mergedSig = mergedCollections.map { "\($0.id):\($0.items.count)" }
            let currentSig = self.collections.map { "\($0.id):\($0.items.count)" }
            let collectionsChanged = mergedSig != currentSig

            if collectionsChanged {
                self.collections = mergedCollections.sorted { $0.createdAt < $1.createdAt }
                self.saveCollections()
            }

            if watchlistChanged {
                self.watchlist = self.parseItems(mergedWatchlist)
            }
            if historyChanged {
                self.history = self.parseItems(mergedHistory)
            }

            TasteProfileManager.shared.applyCloudData(loved: tasteLoved, snapshots: tasteSnapshots)
            if let addonsData {
                AddonManager.shared.syncWithCloudAddons(addonsData)
            }
            if let remoteSettings {
                for (key, val) in remoteSettings {
                    if UserDefaults.standard.object(forKey: key) == nil {
                        UserDefaults.standard.set(val, forKey: key)
                    }
                }
            }
            if let remoteEpProgress {
                var localEpProgress = UserDefaults.standard.dictionary(forKey: self.episodeProgressKey) as? [String: [String: Any]] ?? [:]
                for (k, v) in remoteEpProgress {
                    let localTime = (localEpProgress[k]?["timestamp"] as? Double) ?? 0
                    let remoteTime = (v["timestamp"] as? Double) ?? 0
                    if remoteTime >= localTime {
                        localEpProgress[k] = v
                    }
                }
                UserDefaults.standard.set(localEpProgress, forKey: self.episodeProgressKey)
            }
            if watchlistChanged || historyChanged || collectionsChanged {
                NotificationCenter.default.post(name: .fluxRefresh, object: nil)
            }
            print("[UserDataService] Smart cloud merge applied (watchlist: \(self.watchlist.count), history: \(self.history.count), collections: \(self.collections.count), changed: \(watchlistChanged || historyChanged || collectionsChanged))")
        }

        let remoteHasTmdb = !((payload["tmdbApiKey"] as? String) ?? "").isEmpty
        let localHasTmdb = !(UserDefaults.standard.string(forKey: UserDefaults.Key.tmdbApiKey) ?? "").isEmpty
        let missingTmdbInCloud = !remoteHasTmdb && localHasTmdb

        let remoteHasName = !((payload["userDisplayName"] as? String) ?? "").isEmpty
        let localHasName = !(UserDefaults.standard.string(forKey: "flux.authDisplayName") ?? "").isEmpty
        let missingNameInCloud = !remoteHasName && localHasName

        let hasLocalHistoryAdditions = mergedHistory.count > remoteHistory.count
        let hasLocalWatchlistAdditions = mergedWatchlist.count > remoteWatchlist.count
        let hasLocalCollectionAdditions = mergedCollections.count > imported.count

        let hasLocalAdditionsToPush = missingTmdbInCloud || missingNameInCloud || hasLocalHistoryAdditions || hasLocalWatchlistAdditions || hasLocalCollectionAdditions

        if Thread.isMainThread {
            applyUIUpdates()
        } else {
            DispatchQueue.main.sync {
                applyUIUpdates()
            }
        }

        return hasLocalAdditionsToPush
    }
}


