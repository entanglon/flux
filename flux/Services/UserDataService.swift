import Foundation
import FirebaseFirestore
import FirebaseAuth
import Combine

class UserDataService: ObservableObject {
    static let shared = UserDataService()
    
    @Published var watchlist: [MediaItem] = []
    @Published var history: [MediaItem] = []
    
    private lazy var db = Firestore.firestore()
    private var watchlistListener: ListenerRegistration?
    private var historyListener: ListenerRegistration?
    private var currentUser: User?
    
    private init() {}
    
    func startSyncing(user: User) {
        self.currentUser = user
        startSyncingWatchlist(user: user)
        startSyncingHistory(user: user)
    }
    
    func stopSyncing() {
        watchlistListener?.remove()
        historyListener?.remove()
        watchlistListener = nil
        historyListener = nil
        currentUser = nil
        DispatchQueue.main.async {
            self.watchlist = []
            self.history = []
        }
    }
    
    private func startSyncingWatchlist(user: User) {
        let docRef = db.collection("users").document(user.uid).collection("data").document("mylist")
        print("Starting Watchlist sync for: \(docRef.path)")
        
        watchlistListener = docRef.addSnapshotListener { [weak self] snapshot, error in
            guard let self = self else { return }
            if let error = error { print("Error syncing watchlist: \(error)"); return }
            self.processSnapshot(snapshot: snapshot, target: \.watchlist)
        }
    }
    
    private func startSyncingHistory(user: User) {
        let docRef = db.collection("users").document(user.uid).collection("data").document("history")
        print("Starting History sync for: \(docRef.path)")
        
        historyListener = docRef.addSnapshotListener { [weak self] snapshot, error in
            guard let self = self else { return }
            if let error = error { print("Error syncing history: \(error)"); return }
            self.processSnapshot(snapshot: snapshot, target: \.history)
        }
    }
    
    private func processSnapshot(snapshot: DocumentSnapshot?, target: ReferenceWritableKeyPath<UserDataService, [MediaItem]>) {
        guard let snapshot = snapshot, snapshot.exists,
              let data = snapshot.data(),
              let itemsData = data["items"] as? [[String: Any]] else {
            DispatchQueue.main.async { self[keyPath: target] = [] }
            return
        }
        
        // 1. Decode to temporary tuples with timestamp
        let rawItems: [(item: MediaItem, timestamp: TimeInterval)] = itemsData.compactMap { dict -> (MediaItem, TimeInterval)? in
            let idString = dict["id"] as? String ?? ""
            let typeString = dict["type"] as? String ?? ""
            
            let timestamp = dict["timestamp"] as? TimeInterval ?? 0
            
            let title = dict["title"] as? String ?? "Unknown"
            let posterPath = dict["image"] as? String
            let backdropPath = dict["backdrop"] as? String
            
            var finalPosterURL: URL?
            if let path = posterPath, !path.isEmpty {
                if path.hasPrefix("http") {
                    finalPosterURL = URL(string: path)
                } else {
                    finalPosterURL = URL(string: "https://image.tmdb.org/t/p/w500\(path)")
                }
            }
            
            var finalBackdropURL: URL?
            if let path = backdropPath, !path.isEmpty {
                if path.hasPrefix("http") {
                    finalBackdropURL = URL(string: path)
                } else {
                    finalBackdropURL = URL(string: "https://image.tmdb.org/t/p/w780\(path)")
                }
            }
            
            // History Details
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
            category: typeString == "movie" ? "Movie" : "TV Show"
        )
        item.lastSeason = lastSeason
        item.lastEpisode = lastEpisode
        item.lastEpisodeTitle = lastEpisodeTitle
        item.progress = progress
            if let imageString = dict["lastEpisodeImage"] as? String, let url = URL(string: imageString) {
                item.lastEpisodeImage = url
            }
            
            return (item, timestamp)
        }
        
        // 2. Sort by Timestamp (Descending - Newest First)
        let sorted = rawItems.sorted { $0.timestamp > $1.timestamp }
        
        // 3. Deduplicate (Keep first/newest occurrence)
        var uniqueItems: [MediaItem] = []
        var seenIDs: Set<String> = []
        
        for entry in sorted {
            let id = entry.item.id; if true {
                if !seenIDs.contains(id) {
                    uniqueItems.append(entry.item)
                    seenIDs.insert(id)
                }
            }
        }
        
        DispatchQueue.main.async {
            self[keyPath: target] = uniqueItems
            print("Synced \(uniqueItems.count) items to \(target == \.watchlist ? "Watchlist" : "History")")
        }
    }
    
    // MARK: - Actions
    
    func isInWatchlist(_ item: MediaItem) -> Bool {
        let tmdbID = item.id
        return watchlist.contains { $0.id == tmdbID }
    }
    
    func toggleWatchlist(_ item: MediaItem) {
        guard let user = currentUser, !item.id.isEmpty else { return }
        let docRef = db.collection("users").document(user.uid).collection("data").document("mylist")
        
        if isInWatchlist(item) {
            removeFromList(docRef: docRef, item: item)
        } else {
            addToList(docRef: docRef, item: item)
        }
    }
    
    // Helper to add/remove generic
    private func addToList(docRef: DocumentReference, item: MediaItem, progress: Double? = nil, season: Int? = nil, episode: Int? = nil, episodeTitle: String? = nil, episodeImage: URL? = nil) {
        let tmdbID = item.id
        let typeString = item.category.lowercased().contains("movie") ? "movie" : "tv"
        
        var imageVal = ""
        if let url = item.posterURL {
            if url.absoluteString.contains("image.tmdb.org") {
                imageVal = url.path
            } else {
                imageVal = url.absoluteString
            }
        }
        
        var backdropVal = ""
        if let url = item.backdropURL {
             if url.absoluteString.contains("image.tmdb.org") {
                 backdropVal = url.path
             } else {
                 backdropVal = url.absoluteString
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
        
        if let p = progress { finalItem["progress"] = p }
        if let s = season { finalItem["lastSeason"] = s }
        if let e = episode { finalItem["lastEpisode"] = e }
        if let et = episodeTitle { finalItem["lastEpisodeTitle"] = et }
        if let ei = episodeImage { finalItem["lastEpisodeImage"] = ei.absoluteString }
        
        docRef.updateData(["items": FieldValue.arrayUnion([finalItem])]) { error in
            if error != nil {
                docRef.setData(["items": FieldValue.arrayUnion([finalItem])], merge: true)
            }
        }
    }
    
    func addToHistory(_ item: MediaItem, progress: Double? = nil, season: Int? = nil, episode: Int? = nil, episodeTitle: String? = nil, episodeImage: URL? = nil) {
        guard let user = currentUser, !item.id.isEmpty else { return }
        let docRef = db.collection("users").document(user.uid).collection("data").document("history")
        addToList(docRef: docRef, item: item, progress: progress, season: season, episode: episode, episodeTitle: episodeTitle, episodeImage: episodeImage)
    }
    
    func removeFromHistory(_ item: MediaItem) {
        guard let user = currentUser, !item.id.isEmpty else { return }
        let docRef = db.collection("users").document(user.uid).collection("data").document("history")
        removeFromList(docRef: docRef, item: item)
    }

    private func removeFromList(docRef: DocumentReference, item: MediaItem) {
        let tmdbID = item.id
        
        docRef.getDocument { snapshot, error in
            guard let data = snapshot?.data(),
                  let items = data["items"] as? [[String: Any]] else { return }
            
            let idStr = item.id
            let newItems = items.filter { ($0["id"] as? String) != idStr }
            
            docRef.updateData(["items": newItems])
        }
    }
}
