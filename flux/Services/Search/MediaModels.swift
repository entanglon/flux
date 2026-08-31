import Foundation

// MARK: - Search Media Models & Candidate Types

enum SearchMediaType: String, Codable, Sendable, Hashable {
    case movie
    case tvSeries = "tv"
    
    var displayName: String {
        switch self {
        case .movie: return "Movie"
        case .tvSeries: return "TV Show"
        }
    }
}

enum CatalogSource: Sendable, Hashable, Equatable {
    case tmdb
    case cinemeta
    case localCache
}

// MARK: - Canonical Candidate Produced by Every Search Provider

/// Every provider (TMDB, Cinemeta, local cache) maps into this single shape
/// before reaching the QualityFilter or RelevanceScorer.
struct MediaCandidate: Identifiable, Hashable, Sendable {
    let id: String                 // namespaced or raw id, e.g. "tmdb-603" or "tt0133093"
    let title: String
    let mediaType: SearchMediaType
    let popularity: Double         // TMDB-scale popularity (roughly 0...500+)
    let voteCount: Int
    let voteAverage: Double
    let posterPath: String?
    let backdropPath: String?
    let overview: String?
    let releaseDate: Date?
    let isAdult: Bool
    var imdbID: String?
    let source: CatalogSource
    
    // Derived precomputed fields for fast zero-cost matching
    let normalizedTitle: String
    let articleStrippedTitle: String
    let franchiseStem: String
    let hasSubtitle: Bool
    let subtitle: String?
    
    init(
        id: String,
        title: String,
        mediaType: SearchMediaType,
        popularity: Double,
        voteCount: Int,
        voteAverage: Double,
        posterPath: String?,
        backdropPath: String?,
        overview: String?,
        releaseDate: Date?,
        isAdult: Bool,
        imdbID: String?,
        source: CatalogSource
    ) {
        self.id = id
        self.title = title
        self.mediaType = mediaType
        self.popularity = popularity
        self.voteCount = voteCount
        self.voteAverage = voteAverage
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.overview = overview
        self.releaseDate = releaseDate
        self.isAdult = isAdult
        self.imdbID = imdbID
        self.source = source
        
        let norm = title.normalizedForSearch
        self.normalizedTitle = norm
        self.articleStrippedTitle = norm.articleStripped
        
        let decomposed = title.decomposedFranchise
        self.franchiseStem = decomposed.stem
        self.hasSubtitle = decomposed.hasSubtitle
        self.subtitle = decomposed.subtitle
    }
    
    var releaseDateString: String? {
        guard let date = releaseDate else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    
    var posterURL: URL? {
        guard let path = posterPath, !path.isEmpty else { return nil }
        if path.hasPrefix("http") {
            return URL(string: path)
        }
        return URL(string: "https://image.tmdb.org/t/p/w500\(path)")
    }
    
    var backdropURL: URL? {
        guard let path = backdropPath, !path.isEmpty else { return nil }
        if path.hasPrefix("http") {
            return URL(string: path)
        }
        return URL(string: "https://image.tmdb.org/t/p/w1280\(path)")
    }
    
    /// Converts this search candidate into Flux's primary `MediaItem`
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
            genres: nil,
            popularity: popularity,
            releaseDate: releaseDateString,
            spokenLanguages: nil,
            originCountry: nil,
            voteAverage: voteAverage,
            episodes: nil,
            watchProviders: nil
        )
    }
    
    /// Constructs a MediaCandidate from an existing MediaItem
    static func from(mediaItem: MediaItem, category: SearchMediaType? = nil) -> MediaCandidate {
        let detectedType: SearchMediaType = {
            if let cat = category { return cat }
            let lower = mediaItem.category.lowercased()
            return (lower.contains("series") || lower.contains("tv")) ? .tvSeries : .movie
        }()
        
        let parsedDate: Date? = {
            guard let str = mediaItem.releaseDate, !str.isEmpty else { return nil }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            if let d = formatter.date(from: str) { return d }
            if str.count >= 4, let yr = Int(str.prefix(4)) {
                var comp = DateComponents()
                comp.year = yr
                comp.month = 1
                comp.day = 1
                return Calendar(identifier: .gregorian).date(from: comp)
            }
            return nil
        }()
        
        return MediaCandidate(
            id: mediaItem.id,
            title: mediaItem.title,
            mediaType: detectedType,
            popularity: mediaItem.popularity ?? 10.0,
            voteCount: 100,
            voteAverage: mediaItem.voteAverage ?? 7.0,
            posterPath: mediaItem.posterURL?.absoluteString ?? mediaItem.imageURL?.absoluteString,
            backdropPath: mediaItem.backdropURL?.absoluteString,
            overview: mediaItem.description,
            releaseDate: parsedDate,
            isAdult: false,
            imdbID: mediaItem.id.starts(with: "tt") ? mediaItem.id : nil,
            source: .localCache
        )
    }
}

// MARK: - Search Query String Normalization & Structural Title Decomposition

extension String {
    /// Lowercases, strips diacritics and replaces punctuation with spaces
    var normalizedForSearch: String {
        let folded = folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(cleaned)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips leading stop articles ("the ", "a ", "an ") from normalized strings
    var articleStripped: String {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("the ") {
            return String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if trimmed.hasPrefix("a ") {
            return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if trimmed.hasPrefix("an ") {
            return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    var searchTokens: [Substring] {
        normalizedForSearch.split(separator: " ")
    }
    
    /// Splits raw title into (stem, subtitle) on strong delimiters (:, —, -)
    var decomposedFranchise: (stem: String, hasSubtitle: Bool, subtitle: String?) {
        // Look for common franchise subtitle separators
        let delimiters = [":", " — ", " – ", " - "]
        for delimiter in delimiters {
            if let range = self.range(of: delimiter) {
                let stemPart = String(self[..<range.lowerBound]).normalizedForSearch.articleStripped
                let subPart = String(self[range.upperBound...]).normalizedForSearch
                if !stemPart.isEmpty && !subPart.isEmpty {
                    return (stem: stemPart, hasSubtitle: true, subtitle: subPart)
                }
            }
        }
        
        let normalizedStem = self.normalizedForSearch.articleStripped
        return (stem: normalizedStem, hasSubtitle: false, subtitle: nil)
    }
}
