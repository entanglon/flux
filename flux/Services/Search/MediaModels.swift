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

// MARK: - Search Query String Normalization

extension String {
    /// Lowercases, strips diacritics and punctuation so "Transformers: Rise of the Beasts"
    /// and "Transformers" share clean tokens ("transformers").
    var normalizedForSearch: String {
        let folded = folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(cleaned)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var searchTokens: [Substring] {
        normalizedForSearch.split(separator: " ")
    }
}
