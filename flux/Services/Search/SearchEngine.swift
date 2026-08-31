import Foundation

// MARK: - Production Search Engine Actor (Debounced, Race-Free, Multi-Tier)

actor SearchEngine {
    static let shared = SearchEngine()

    let trie: PrefixTrie
    private let tmdbClient: TMDBClient
    private let cinemetaClient: CinemetaClient
    private let filter: QualityFilter
    private let scorer: RelevanceScorer
    private let debounceNanoseconds: UInt64

    private var activeTask: Task<Void, Never>?

    init(
        trie: PrefixTrie = PrefixTrie(),
        tmdbClient: TMDBClient = TMDBClient(),
        cinemetaClient: CinemetaClient = CinemetaClient(),
        filter: QualityFilter = QualityFilter(),
        scorer: RelevanceScorer = RelevanceScorer(),
        debounceMilliseconds: Int = 200
    ) {
        self.trie = trie
        self.tmdbClient = tmdbClient
        self.cinemetaClient = cinemetaClient
        self.filter = filter
        self.scorer = scorer
        self.debounceNanoseconds = UInt64(debounceMilliseconds) * 1_000_000
    }

    /// Call this on every keystroke. Instant trie suggestions are returned
    /// directly (0ms); remote, ranked results arrive asynchronously through
    /// `onRemoteResults` unless superseded by a newer keystroke.
    @discardableResult
    func updateQuery(
        _ rawQuery: String,
        onRemoteResults: @escaping @Sendable ([MediaCandidate]) -> Void
    ) async -> [PrefixTrie.TrieEntry] {
        // Cancelling the previous task cooperatively stops in-flight network requests
        activeTask?.cancel()

        let localResults = await trie.suggestions(forPrefix: rawQuery, limit: 6)

        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            activeTask = nil
            return localResults
        }

        activeTask = Task { [debounceNanoseconds] in
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self.performRemoteSearch(query: trimmed, onResults: onRemoteResults)
        }

        return localResults
    }

    private func performRemoteSearch(
        query: String,
        onResults: @escaping @Sendable ([MediaCandidate]) -> Void
    ) async {
        guard !Task.isCancelled else { return }

        let candidates = await withTaskGroup(of: [MediaCandidate].self) { group -> [MediaCandidate] in
            group.addTask { [tmdbClient] in
                (try? await tmdbClient.multiSearch(query: query)) ?? []
            }
            group.addTask { [cinemetaClient] in
                (try? await cinemetaClient.search(query: query)) ?? []
            }

            var merged: [MediaCandidate] = []
            for await batch in group {
                merged.append(contentsOf: batch)
            }
            return merged
        }

        // Dual-Layer Cancellation Check: guarantees no stale responses overwrite newer queries
        guard !Task.isCancelled else { return }

        let deduped = Self.deduplicate(candidates)
        let eligible = filter.filter(deduped)
        let ranked = scorer.rank(candidates: eligible, query: query)

        onResults(ranked)
    }

    /// Indexes user data (History, Watchlist) and top trending items into the local Prefix Trie
    func indexUserAndTrendingData() async {
        // 1. Index History and Watchlist from MainActor
        let (historyItems, watchlistItems) = await MainActor.run {
            (UserDataService.shared.history, UserDataService.shared.watchlist)
        }

        for item in historyItems {
            await trie.insertMediaItem(item, category: .continueWatching)
        }

        for item in watchlistItems {
            await trie.insertMediaItem(item, category: .watchlist)
        }

        // 2. Index Top Trending & Popular Titles from TMDB
        if let trending = try? await TMDBEnricher.shared.fetchTrendingAll(window: "week") {
            for item in trending {
                await trie.insertMediaItem(item, category: .trending)
            }
        }
        if let popularMovies = try? await TMDBEnricher.shared.fetchPopularMovies(page: 1) {
            for item in popularMovies {
                await trie.insertMediaItem(item, category: .trending)
            }
        }
        if let popularTV = try? await TMDBEnricher.shared.fetchPopularTV(page: 1) {
            for item in popularTV {
                await trie.insertMediaItem(item, category: .trending)
            }
        }
    }

    /// Prefers TMDB's richer metadata when both providers return the same title
    private static func deduplicate(_ candidates: [MediaCandidate]) -> [MediaCandidate] {
        var bestByKey: [String: MediaCandidate] = [:]
        var order: [String] = []

        for candidate in candidates {
            let key = candidate.imdbID ?? candidate.id
            if let existing = bestByKey[key] {
                if existing.source != .tmdb && candidate.source == .tmdb {
                    bestByKey[key] = candidate
                }
            } else {
                bestByKey[key] = candidate
                order.append(key)
            }
        }

        return order.compactMap { bestByKey[$0] }
    }
}
