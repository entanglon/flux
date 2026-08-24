import Foundation
import Combine

/// Local taste profile powering the "For You" rail.
/// Signals (strongest → weakest): loved ♥, watchlist, watch completion.
/// Everything stays on-device; TMDB's /recommendations endpoint (built from
/// global viewing behavior) provides the collaborative signal per seed title.
final class TasteProfileManager: ObservableObject {
    static let shared = TasteProfileManager()

    @Published private(set) var lovedItems: [MediaItem] = []

    private let lovedKey = "tasteProfileLovedItems"
    private let watchedKey = "tasteProfileWatchSnapshots"

    struct WatchSnapshot: Codable {
        let id: String
        let title: String
        let category: String
        let progress: Double
        let timestamp: Date
        let genres: [String]?

        /// Minimal MediaItem for API calls (fetchSimilar needs id + category only).
        var asMediaItem: MediaItem {
            MediaItem(seed: id, title: title, category: category, progress: progress, genres: genres)
        }
    }

    private var snapshots: [WatchSnapshot] = []

    private init() { load() }

    // MARK: - Persistence

    private func load() {
        if let data = UserDefaults.standard.data(forKey: lovedKey),
           let items = try? JSONDecoder().decode([MediaItem].self, from: data) {
            lovedItems = items
        }
        if let data = UserDefaults.standard.data(forKey: watchedKey),
           let snaps = try? JSONDecoder().decode([WatchSnapshot].self, from: data) {
            snapshots = snaps
        }
        backfillFromHistoryIfNeeded()
    }

    /// First launch of the taste profile: derive watch signals from the existing
    /// history so the For You rail works immediately, not only after new watches.
    private func backfillFromHistoryIfNeeded() {
        guard snapshots.isEmpty else { return }
        let snaps: [WatchSnapshot] = UserDataService.shared.history.compactMap { item in
            guard let p = item.progress, p > 0.02 else { return nil }
            return WatchSnapshot(
                id: item.id, title: item.title, category: item.category,
                progress: min(p, 1.0), timestamp: Date(), genres: item.genres
            )
        }
        if !snaps.isEmpty {
            snapshots = snaps
            save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(lovedItems) {
            UserDefaults.standard.set(data, forKey: lovedKey)
        }
        if let data = try? JSONEncoder().encode(snapshots) {
            UserDefaults.standard.set(data, forKey: watchedKey)
        }
    }

    // MARK: - Love Signal (strongest)

    func toggleLove(_ item: MediaItem) {
        if let idx = lovedItems.firstIndex(where: { $0.id == item.id }) {
            lovedItems.remove(at: idx)
        } else {
            lovedItems.insert(item, at: 0)
            if lovedItems.count > 50 { lovedItems.removeLast() }
        }
        save()
    }

    func isLoved(_ item: MediaItem) -> Bool {
        lovedItems.contains { $0.id == item.id }
    }

    // MARK: - Watch Signal

    /// Called on player close. Completion ≥70% is a positive signal; a few
    /// minutes then quit is a mild negative (excluded from seeds).
    func recordWatch(_ item: MediaItem, progress: Double) {
        guard progress > 0.02 else { return }
        snapshots.removeAll { $0.id == item.id }
        let snap = WatchSnapshot(
            id: item.id, title: item.title, category: item.category,
            progress: min(progress, 1.0), timestamp: Date(), genres: item.genres
        )
        snapshots.insert(snap, at: 0)
        if snapshots.count > 100 { snapshots.removeLast() }
        save()
    }

    // MARK: - Profile

    /// Enough signal for a meaningful For You rail?
    var hasEnoughSignal: Bool {
        if !lovedItems.isEmpty { return true }
        return snapshots.filter { $0.progress >= 0.7 }.count >= 2
    }

    /// Seeds: loved items first (recent first), then most-completed watches.
    var seeds: [(item: MediaItem, weight: Double)] {
        var out: [(MediaItem, Double)] = []
        for (i, item) in lovedItems.prefix(4).enumerated() {
            out.append((item, 5.0 - Double(i) * 0.5))
        }
        let completed = snapshots
            .filter { $0.progress >= 0.7 }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(4)
        for (i, snap) in completed.enumerated() where !out.contains(where: { $0.0.id == snap.id }) {
            out.append((snap.asMediaItem, 2.5 - Double(i) * 0.3))
        }
        return out
    }

    /// Weighted genre affinity across all signals (loved ×3, completed ×2, partial ×0.5),
    /// decayed by recency so last month's obsession outweighs last year's.
    func genreAffinity() -> [String: Double] {
        var affinity: [String: Double] = [:]
        let now = Date()

        func add(_ genres: [String]?, weight: Double, age: TimeInterval) {
            let decay = exp(-age / (60 * 60 * 24 * 45)) // ~45-day half-life-ish
            for g in genres ?? [] {
                affinity[g, default: 0] += weight * decay
            }
        }

        for (i, item) in lovedItems.prefix(10).enumerated() {
            add(item.genres, weight: 3.0, age: now.timeIntervalSinceNow - Double(i) * 60)
        }
        for snap in snapshots.prefix(30) {
            let w = snap.progress >= 0.7 ? 2.0 : 0.5
            add(snap.genres, weight: w, age: now.timeIntervalSince(snap.timestamp))
        }
        for item in UserDataService.shared.watchlist.prefix(20) {
            add(item.genres, weight: 1.5, age: 0)
        }
        return affinity
    }

    // MARK: - For You Recommendations

    /// Fetches TMDB recommendations per seed, merges, scores by seed weight +
    /// genre affinity + rating, and filters out already-seen/queued titles.
    func forYouRecommendations() async -> (items: [MediaItem], because: MediaItem?) {
        let allSeeds = seeds
        guard !allSeeds.isEmpty else { return ([], nil) }

        let historyIDs = Set(UserDataService.shared.history.map { $0.id })
        let watchlistIDs = Set(UserDataService.shared.watchlist.map { $0.id })
        let seedIDs = Set(allSeeds.map { $0.item.id })
        let affinity = genreAffinity()

        struct Candidate {
            let item: MediaItem
            var score: Double
        }
        var merged: [String: Candidate] = [:]
        let lock = NSLock()

        await withTaskGroup(of: (MediaItem, Double, [MediaItem]).self) { group in
            for seed in allSeeds.prefix(5) {
                group.addTask {
                    (seed.item, seed.weight, await TMDBEnricher.shared.fetchSimilar(item: seed.item))
                }
            }
            for await (seed, weight, recs) in group {
                for (rank, rec) in recs.prefix(10).enumerated() {
                    guard rec.isReleased else { continue }
                    guard !historyIDs.contains(rec.id),
                          !watchlistIDs.contains(rec.id),
                          !seedIDs.contains(rec.id) else { continue }

                    var score = weight * max(0.4, 1.0 - Double(rank) * 0.06)
                    for g in rec.genres ?? [] {
                        score += (affinity[g] ?? 0) * 0.3
                    }
                    if let v = rec.voteAverage {
                        score += min(v, 8.5) * 0.2
                    }

                    lock.lock()
                    if var existing = merged[rec.id] {
                        existing.score += score
                        merged[rec.id] = existing
                    } else {
                        merged[rec.id] = Candidate(item: rec, score: score)
                    }
                    lock.unlock()
                }
            }
        }

        let items = merged.values
            .sorted { $0.score > $1.score }
            .map { $0.item }
        return (Array(items.prefix(20)), allSeeds.first?.item)
    }
}
