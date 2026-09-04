import Foundation

// MARK: - Actor-Based In-Memory Prefix Trie (0ms Instant Suggestions)

/// In-memory prefix trie over cached titles (trending, watchlist, continue watching)
/// so suggestions render in the exact same frame as the keystroke with 0ms network latency.
actor PrefixTrie {
    struct TrieEntry: Hashable, Sendable, Identifiable {
        let id: String
        let title: String
        let mediaType: SearchMediaType
        let posterPath: String?
        let backdropPath: String?
        /// Precomputed so lookups never have to re-rank; higher sorts first.
        let sortWeight: Double
        let overview: String?
        let voteAverage: Double?
        let genres: [String]?
        let releaseDate: String?
        let imdbID: String?
        
        init(
            id: String,
            title: String,
            mediaType: SearchMediaType,
            posterPath: String?,
            backdropPath: String?,
            sortWeight: Double,
            overview: String? = nil,
            voteAverage: Double? = nil,
            genres: [String]? = nil,
            releaseDate: String? = nil,
            imdbID: String? = nil
        ) {
            self.id = id
            self.title = title
            self.mediaType = mediaType
            self.posterPath = posterPath
            self.backdropPath = backdropPath
            self.sortWeight = sortWeight
            self.overview = overview
            self.voteAverage = voteAverage
            self.genres = genres
            self.releaseDate = releaseDate
            self.imdbID = imdbID
        }
        
        var posterURL: URL? {
            guard let path = posterPath, !path.isEmpty else { return nil }
            if path.hasPrefix("http") { return URL(string: path) }
            return URL(string: "https://image.tmdb.org/t/p/w500\(path)")
        }
        
        var backdropURL: URL? {
            guard let path = backdropPath, !path.isEmpty else { return nil }
            if path.hasPrefix("http") { return URL(string: path) }
            return URL(string: "https://image.tmdb.org/t/p/original\(path)")
        }
        
        func toMediaItem() -> MediaItem {
            let cleanId = id.replacingOccurrences(of: "tmdb-", with: "")
                            .replacingOccurrences(of: "cinemeta-", with: "")
            return MediaItem(
                id: imdbID ?? cleanId,
                title: title,
                description: overview ?? "",
                imageURL: posterURL,
                posterURL: posterURL,
                backdropURL: backdropURL,
                heroURL: backdropURL,
                logoURL: nil,
                streamURL: nil,
                category: mediaType == .movie ? "Movie" : "TV Show",
                progress: nil,
                trailerURL: nil,
                cast: nil,
                director: nil,
                seasons: nil,
                runtime: nil,
                certification: nil,
                genres: genres,
                popularity: nil,
                releaseDate: releaseDate,
                originalLanguage: nil,
                spokenLanguages: nil,
                originCountry: nil,
                voteAverage: voteAverage,
                episodes: nil,
                watchProviders: nil
            )
        }
    }

    enum LocalCacheCategory {
        case continueWatching
        case watchlist
        case trending

        /// Continue-watching and watchlist items float above generic trending titles.
        var boost: Double {
            switch self {
            case .continueWatching: return 1_000_000
            case .watchlist: return 500_000
            case .trending: return 0
            }
        }
    }

    private final class Node {
        var children: [Character: Node] = [:]
        var entries: [TrieEntry] = []
    }

    private let root = Node()
    private var indexedIDs = Set<String>()

    func insert(_ candidate: MediaCandidate, category: LocalCacheCategory) {
        guard !indexedIDs.contains(candidate.id) else { return }
        indexedIDs.insert(candidate.id)

        let entry = TrieEntry(
            id: candidate.id,
            title: candidate.title,
            mediaType: candidate.mediaType,
            posterPath: candidate.posterPath,
            backdropPath: candidate.backdropPath,
            sortWeight: category.boost + log10(candidate.popularity + 1) * 100,
            overview: candidate.overview,
            voteAverage: candidate.voteAverage,
            genres: candidate.genres,
            releaseDate: candidate.releaseDateString,
            imdbID: candidate.imdbID
        )

        for key in indexableKeys(for: candidate.title) {
            insertPath(key, entry: entry)
        }
    }
    
    func insertMediaItem(_ item: MediaItem, category: LocalCacheCategory) {
        let candidate = MediaCandidate.from(mediaItem: item)
        insert(candidate, category: category)
    }

    func removeAll() {
        root.children.removeAll()
        root.entries.removeAll()
        indexedIDs.removeAll()
    }

    /// Indexes both the full normalized title *and* each individual word, so
    /// typing "knight" finds "The Dark Knight" as quickly as typing "the d".
    private func indexableKeys(for title: String) -> [String] {
        let normalized = title.normalizedForSearch
        guard !normalized.isEmpty else { return [] }
        var keys = [normalized, normalized.articleStripped]
        keys.append(contentsOf: normalized.split(separator: " ").map(String.init))
        return Array(Set(keys))
    }

    private func insertPath(_ text: String, entry: TrieEntry) {
        var node = root
        for character in text {
            if let next = node.children[character] {
                node = next
            } else {
                let next = Node()
                node.children[character] = next
                node = next
            }
        }
        node.entries.append(entry)
    }

    func suggestions(forPrefix prefix: String, limit: Int = 6) -> [TrieEntry] {
        let normalized = prefix.normalizedForSearch.articleStripped
        guard !normalized.isEmpty else { return [] }

        var node = root
        for character in normalized {
            guard let next = node.children[character] else { return [] }
            node = next
        }

        var collected: [TrieEntry] = []
        collect(from: node, into: &collected, cap: limit * 6)

        var seen = Set<String>()
        var deduped: [TrieEntry] = []
        for entry in collected.sorted(by: { $0.sortWeight > $1.sortWeight }) {
            if seen.insert(entry.id).inserted {
                deduped.append(entry)
            }
            if deduped.count >= limit { break }
        }
        return deduped
    }

    /// Fallback fuzzy search using first-character pruning and Damerau-Levenshtein distance
    func fuzzySuggestions(for query: String, limit: Int = 6) -> [TrieEntry] {
        let normalized = query.normalizedForSearch.articleStripped
        guard normalized.count >= 4 else { return [] }
        let maxDist = DamerauLevenshtein.maxDistance(forQueryLength: normalized.count)
        guard maxDist > 0 else { return [] }
        
        guard let firstChar = normalized.first, let firstNode = root.children[firstChar] else {
            return []
        }
        
        var pool: [TrieEntry] = []
        collect(from: firstNode, into: &pool, cap: 200)
        
        var matches: [(entry: TrieEntry, dist: Int)] = []
        var seen = Set<String>()
        
        for entry in pool {
            guard seen.insert(entry.id).inserted else { continue }
            let entryNorm = entry.title.normalizedForSearch.articleStripped
            let dist = DamerauLevenshtein.distance(normalized, entryNorm)
            if dist <= maxDist {
                matches.append((entry, dist))
            }
        }
        
        return matches
            .sorted { ($0.dist, -$0.entry.sortWeight) < ($1.dist, -$1.entry.sortWeight) }
            .prefix(limit)
            .map(\.entry)
    }

    private func collect(from node: Node, into result: inout [TrieEntry], cap: Int) {
        guard result.count < cap else { return }
        result.append(contentsOf: node.entries)
        for child in node.children.values {
            if result.count >= cap { return }
            collect(from: child, into: &result, cap: cap)
        }
    }
}
