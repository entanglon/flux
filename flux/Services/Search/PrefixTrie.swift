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
        
        var posterURL: URL? {
            guard let path = posterPath, !path.isEmpty else { return nil }
            if path.hasPrefix("http") { return URL(string: path) }
            return URL(string: "https://image.tmdb.org/t/p/w500\(path)")
        }
        
        func toMediaItem() -> MediaItem {
            let cleanId = id.replacingOccurrences(of: "tmdb-", with: "")
                            .replacingOccurrences(of: "cinemeta-", with: "")
            return MediaItem(
                id: cleanId,
                title: title,
                description: "",
                imageURL: posterURL,
                posterURL: posterURL,
                backdropURL: nil,
                heroURL: nil,
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
                genres: nil,
                popularity: nil,
                releaseDate: nil,
                spokenLanguages: nil,
                originCountry: nil,
                voteAverage: nil,
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
            sortWeight: category.boost + log10(candidate.popularity + 1) * 100
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
        var keys = [normalized]
        keys.append(contentsOf: normalized.split(separator: " ").map(String.init))
        return keys
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
        let normalized = prefix.normalizedForSearch
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

    private func collect(from node: Node, into result: inout [TrieEntry], cap: Int) {
        guard result.count < cap else { return }
        result.append(contentsOf: node.entries)
        for child in node.children.values {
            if result.count >= cap { return }
            collect(from: child, into: &result, cap: cap)
        }
    }
}
