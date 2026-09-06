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
        debounceMilliseconds: Int = 120
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

        // 1. Tier A: Fast prefix trie walk
        var localResults = await trie.suggestions(forPrefix: rawQuery, limit: 6)

        // 2. Tier B (Fallback): If prefix lookup returns thin/empty results and query >= 4 chars, run fuzzy matching
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if localResults.count < 3 && trimmed.count >= 4 {
            let fuzzyHits = await trie.fuzzySuggestions(for: trimmed, limit: 6)
            var seen = Set(localResults.map(\.id))
            for hit in fuzzyHits {
                if seen.insert(hit.id).inserted {
                    localResults.append(hit)
                }
            }
        }

        guard trimmed.count >= 2 else {
            activeTask = nil
            return localResults
        }

        // Determine if local fuzzy found a high-confidence correction to rewrite the remote query
        let remoteQueryTarget: String = {
            if trimmed.count >= 4 {
                let normTrimmed = trimmed.normalizedForSearch.articleStripped
                for hit in localResults.prefix(3) {
                    let hitNorm = hit.title.normalizedForSearch.articleStripped
                    let dist = DamerauLevenshtein.distance(normTrimmed, hitNorm)
                    if dist <= (normTrimmed.count >= 6 ? 2 : 1) {
                        return hit.title
                    }
                    let words = hitNorm.split(separator: " ").map(String.init)
                    for w in words {
                        if abs(w.count - normTrimmed.count) <= 1 && DamerauLevenshtein.distance(normTrimmed, w) <= 1 {
                            return hit.title
                        }
                    }
                }
            }
            return trimmed
        }()

        activeTask = Task { [debounceNanoseconds] in
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self.performRemoteSearch(query: remoteQueryTarget, originalQuery: trimmed, onResults: onRemoteResults)
        }

        return localResults
    }

    private func performRemoteSearch(
        query: String,
        originalQuery: String,
        onResults: @escaping @Sendable ([MediaCandidate]) -> Void
    ) async {
        guard !Task.isCancelled else { return }

        let hasTMDB = TMDBEnricher.shared.hasKey
        let candidates: [MediaCandidate]

        if hasTMDB {
            // TMDB enrichment mode: Query TMDB directly and exclusively.
            // Eliminates 500-1500ms Cinemeta latency and prevents conflicting Cinemeta metadata from polluting results.
            var hits = (try? await tmdbClient.multiSearch(query: query)) ?? []
            if hits.isEmpty && query != originalQuery {
                hits = (try? await tmdbClient.multiSearch(query: originalQuery)) ?? []
            }
            candidates = hits
        } else {
            // Non-TMDB mode: Query Cinemeta catalog
            candidates = (try? await cinemetaClient.search(query: query)) ?? []
        }

        // Dual-Layer Cancellation Check: guarantees no stale responses overwrite newer queries
        guard !Task.isCancelled else { return }

        let deduped = Self.deduplicate(candidates)
        let eligible = filter.filter(deduped)
        let ranked = scorer.rank(candidates: eligible, query: originalQuery)

        onResults(ranked)
    }
    
    /// Clears the trie and re-indexes only public trending titles, purging any previous user data.
    func clearUserIndex() async {
        await trie.removeAll()
        await indexUserAndTrendingData()
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

        // 2. Index Top Trending & Popular Titles from TMDB (if available)
        if let trending = try? await TMDBEnricher.shared.fetchTrendingAll(window: "week") {
            for item in trending {
                await trie.insertMediaItem(item, category: .trending)
            }
        }
        for page in 1...2 {
            if let popularMovies = try? await TMDBEnricher.shared.fetchPopularMovies(page: page) {
                for item in popularMovies {
                    await trie.insertMediaItem(item, category: .trending)
                }
            }
            if let popularTV = try? await TMDBEnricher.shared.fetchPopularTV(page: page) {
                for item in popularTV {
                    await trie.insertMediaItem(item, category: .trending)
                }
            }
        }
    }

    /// Deduplicates multi-provider search results by merging candidates for the same title.
    /// Prefers TMDB's richer metadata (artwork, vote counts, synopsis, genres) while
    /// inheriting Cinemeta's IMDb ID (`tt...`) so detail views and streaming require zero ID translation.
    static func deduplicate(_ candidates: [MediaCandidate]) -> [MediaCandidate] {
        var mergedCandidates: [MediaCandidate] = []
        
        for candidate in candidates {
            if let index = mergedCandidates.firstIndex(where: { isMatch($0, candidate) }) {
                let existing = mergedCandidates[index]
                mergedCandidates[index] = merge(existing: existing, incoming: candidate)
            } else {
                mergedCandidates.append(candidate)
            }
        }
        
        return mergedCandidates
    }

    /// Evaluates if two candidates represent the exact same media item.
    static func isMatch(_ a: MediaCandidate, _ b: MediaCandidate) -> Bool {
        // 1. Direct ID match
        if a.id == b.id { return true }
        
        // 2. Direct IMDb ID match
        if let imdbA = a.imdbID, let imdbB = b.imdbID, !imdbA.isEmpty, !imdbB.isEmpty {
            if imdbA == imdbB { return true }
        }
        
        // 3. Semantic Title + MediaType + Year match
        guard a.mediaType == b.mediaType else { return false }
        
        let titleMatch = (a.normalizedTitle == b.normalizedTitle) ||
                         (!a.articleStrippedTitle.isEmpty && a.articleStrippedTitle == b.articleStrippedTitle)
        
        guard titleMatch else { return false }
        
        // Compare release years if both candidates specify one
        let cal = Calendar(identifier: .gregorian)
        let yearA = a.releaseDate.map { cal.component(.year, from: $0) }
        let yearB = b.releaseDate.map { cal.component(.year, from: $0) }
        
        if let yA = yearA, let yB = yearB {
            // Allow ±1 year tolerance for international release date discrepancies (e.g. late Dec vs Jan)
            return abs(yA - yB) <= 1
        }
        
        // If one or both lack a release year, matching titles + same mediaType is considered a match
        return true
    }

    /// Merges two matching candidates into a single canonical candidate.
    static func merge(existing: MediaCandidate, incoming: MediaCandidate) -> MediaCandidate {
        let primary: MediaCandidate
        let secondary: MediaCandidate
        
        if existing.source == .tmdb && incoming.source != .tmdb {
            primary = existing
            secondary = incoming
        } else if incoming.source == .tmdb && existing.source != .tmdb {
            primary = incoming
            secondary = existing
        } else {
            if incoming.popularity > existing.popularity || incoming.voteCount > existing.voteCount {
                primary = incoming
                secondary = existing
            } else {
                primary = existing
                secondary = incoming
            }
        }
        
        var merged = primary
        
        // Inherit Cinemeta's IMDb ID if primary (TMDB) candidate lacks it
        if merged.imdbID == nil || merged.imdbID?.isEmpty == true {
            merged.imdbID = secondary.imdbID
        }
        
        // Inherit any missing fields from secondary
        if merged.genres == nil || merged.genres?.isEmpty == true {
            merged.genres = secondary.genres
        }
        if merged.overview == nil || merged.overview?.isEmpty == true {
            merged.overview = secondary.overview
        }
        if merged.posterPath == nil || merged.posterPath?.isEmpty == true {
            merged.posterPath = secondary.posterPath
        }
        if merged.backdropPath == nil || merged.backdropPath?.isEmpty == true {
            merged.backdropPath = secondary.backdropPath
        }
        if merged.releaseDate == nil {
            merged.releaseDate = secondary.releaseDate
        }
        if merged.voteAverage <= 0 && secondary.voteAverage > 0 {
            merged = MediaCandidate(
                id: merged.id,
                title: merged.title,
                mediaType: merged.mediaType,
                popularity: merged.popularity,
                voteCount: max(merged.voteCount, secondary.voteCount),
                voteAverage: secondary.voteAverage,
                posterPath: merged.posterPath,
                backdropPath: merged.backdropPath,
                overview: merged.overview,
                releaseDate: merged.releaseDate,
                isAdult: merged.isAdult,
                imdbID: merged.imdbID,
                genres: merged.genres,
                source: merged.source
            )
        }
        
        return merged
    }
}
