import Foundation

struct CastMember: Identifiable, Hashable, Codable {
    var id: String { name } // Stremio cast usually comes as an array of strings
    let name: String
    let role: String?
    let imageURL: URL?
    var personID: Int? // TMDB person id — enables Person pages
}

struct WatchProvider: Identifiable, Hashable, Codable {
    var id: String { name }
    let name: String
    let logoURL: URL?
    let displayPriority: Int
}


struct MediaItem: Identifiable, Hashable, Codable {
    let id: String
    var title: String
    var description: String
    var imageURL: URL? // Fallback/Main image
    var posterURL: URL?
    var backdropURL: URL?
    var heroURL: URL?
    var logoURL: URL?
    let streamURL: URL?
    let category: String // "movie" or "series" usually in Stremio
    var progress: Double? // 0.0 to 1.0
    var trailerURL: URL?
    var cast: [CastMember]?
    var director: String?
    
    // New Fields
    var seasons: [Season]?
    var runtime: String? // e.g. "2h 14m" or "45m"
    var certification: String? // e.g. "PG-13", "TV-MA"
    var genres: [String]?
    var popularity: Double? // For search ranking
    var releaseDate: String? // YYYY-MM-DD
    var originalLanguage: String? // ISO 639-1 code, e.g. "ko", "ja", "en"
    var spokenLanguages: [String]? // e.g. ["English", "Spanish"]
    var originCountry: String? // ISO 3166-1 code, e.g. "US", "KR", "JP"
    var voteAverage: Double? // e.g. 7.8
    var episodes: [Episode]? // To store all Stremio videos
    var watchProviders: [WatchProvider]?
    
    /// Localized display name for the original language (e.g. "Korean", "Japanese", "English").
    var displayOriginalLanguage: String? {
        guard let code = originalLanguage, !code.isEmpty else { return nil }
        return Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized
    }
    
    /// Localized display name for the origin country (e.g. "South Korea", "Japan", "United States").
    var displayOriginCountry: String? {
        guard let code = originCountry, !code.isEmpty else { return nil }
        // If the code is already a full name (legacy data), return it directly
        if code.count > 2 { return code }
        return Locale.current.localizedString(forRegionCode: code)
    }
    
    /// Formatted release date for display (e.g. "June 15, 2024" or "2024").
    var displayReleaseDate: String? {
        guard let dateStr = releaseDate, !dateStr.isEmpty else { return nil }
        // Try full date format first
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = formatter.date(from: dateStr) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .long
            return displayFormatter.string(from: date)
        }
        // Fallback: extract year if possible
        let year = String(dateStr.prefix(4))
        if year.count == 4, Int(year) != nil { return year }
        return nil
    }
    
    var releaseDateYear: String? {
        guard let date = releaseDate else { return nil }
        return String(date.prefix(4))
    }
    
    var isReleased: Bool {
        guard let dateStr = releaseDate, !dateStr.isEmpty else { return true }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = formatter.date(from: dateStr) {
            return date <= Date()
        }
        if dateStr.count >= 4, let year = Int(dateStr.prefix(4)) {
            let currentYear = Calendar.current.component(.year, from: Date())
            return year <= currentYear
        }
        return true
    }

    var upcomingBadgeText: String {
        guard let dateStr = releaseDate, !dateStr.isEmpty else { return "Coming Soon" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateStr) else { return "Coming Soon" }
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return "Releasing Today"
        } else if cal.isDateInTomorrow(date) {
            return "Coming Tomorrow"
        } else {
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)).day ?? 0
            if days > 0 && days <= 7 {
                let dayFormatter = DateFormatter()
                dayFormatter.dateFormat = "EEEE"
                return "Coming \(dayFormatter.string(from: date))"
            } else {
                let displayFormatter = DateFormatter()
                displayFormatter.dateFormat = "MMMM d"
                return "Coming \(displayFormatter.string(from: date))"
            }
        }
    }
    
    // History & Playback Persistence
    var lastSeason: Int?
    var lastEpisode: Int?
    var lastEpisodeTitle: String?
    var lastEpisodeImage: URL?
    var timestamp: TimeInterval?
    var lastPlaybackPosition: Double? // in seconds (e.g. 1420.5)
    var lastPlaybackDuration: Double? // in seconds (e.g. 7200.0)
    var lastStreamURL: URL?
    var lastTorrentInfoHash: String?
    var lastFileIndex: Int?
}

/// Minimal init for recommendation seeds — extension keeps the memberwise init.
extension MediaItem {
    init(seed id: String, title: String, category: String, progress: Double? = nil, genres: [String]? = nil) {
        self.init(
            id: id, title: title, description: "", imageURL: nil, posterURL: nil,
            backdropURL: nil, heroURL: nil, logoURL: nil, streamURL: nil,
            category: category, progress: progress, trailerURL: nil, cast: nil,
            director: nil, seasons: nil, runtime: nil, certification: nil,
            genres: genres, popularity: nil, releaseDate: nil, originalLanguage: nil,
            spokenLanguages: nil, originCountry: nil, voteAverage: nil, episodes: nil, watchProviders: nil,
            lastSeason: nil, lastEpisode: nil, lastEpisodeTitle: nil, lastEpisodeImage: nil,
            timestamp: nil, lastPlaybackPosition: nil, lastPlaybackDuration: nil,
            lastStreamURL: nil, lastTorrentInfoHash: nil, lastFileIndex: nil
        )
    }
}
