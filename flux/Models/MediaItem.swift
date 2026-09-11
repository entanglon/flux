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
    var certification: String? // e.g. "PG-13", "TV-MA", "A"
    var contentAdvisories: [String]? // e.g. ["Drugs or Drug Use", "Violence", "Language"]
    var genres: [String]?
    var popularity: Double? // For search ranking
    var releaseDate: String? // YYYY-MM-DD
    var originalLanguage: String? // ISO 639-1 code, e.g. "ko", "ja", "en"
    var spokenLanguages: [String]? // e.g. ["English", "Spanish"]
    var availableSubtitles: [String]? // e.g. ["English (SDH)", "French (SDH)"]
    var audioTracks: [String]? // e.g. ["English (Dolby Atmos, Dolby 5.1)", "French (Dolby 5.1)"]
    var originCountry: String? // ISO 3166-1 code or full name
    var voteAverage: Double? // e.g. 7.8
    var episodes: [Episode]? // To store all Stremio videos
    var watchProviders: [WatchProvider]?
    
    // MARK: - Runtime Formatters
    
    /// Formats minutes into hours and minutes, supporting both < 60m (e.g. "45m") and >= 60m (e.g. "2h 28m", "2h").
    public static func formatRuntime(minutes: Int?) -> String? {
        guard let minutes = minutes, minutes > 0 else { return nil }
        if minutes < 60 {
            return "\(minutes)m"
        } else {
            let hours = minutes / 60
            let mins = minutes % 60
            return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h"
        }
    }
    
    /// Parses any string runtime (e.g. "148 min", "45 min", "148", "2h 14m") into standard hours and minutes.
    public static func formatRuntimeString(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if (raw.contains("h") || raw.hasSuffix("m")) && !raw.lowercased().contains("min") {
            return raw
        }
        let digits = raw.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        if let minutes = Int(digits), minutes > 0 {
            return formatRuntime(minutes: minutes)
        }
        return raw
    }
    
    /// Localized display name for the original language (e.g. "Korean", "Japanese", "English").
    /// Falls back to country-based language inference when explicit language is missing.
    var displayOriginalLanguage: String? {
        if let code = originalLanguage, !code.isEmpty {
            if let name = Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized, !name.isEmpty {
                return name
            }
            if code.count > 2 { return code.capitalized }
        }
        // Fallback: infer language from country of origin
        if let country = originCountry?.lowercased() {
            if country.contains("united states") || country.contains("united kingdom") || country.contains("canada") || country.contains("australia") || country == "us" || country == "gb" || country == "uk" || country == "ca" || country == "au" {
                return "English"
            }
            if country.contains("japan") || country == "jp" { return "Japanese" }
            if country.contains("korea") || country == "kr" { return "Korean" }
            if country.contains("france") || country == "fr" { return "French" }
            if country.contains("germany") || country == "de" { return "German" }
            if country.contains("italy") || country == "it" { return "Italian" }
            if country.contains("spain") || country.contains("mexico") || country.contains("argentina") || country == "es" || country == "mx" { return "Spanish" }
            if country.contains("india") || country == "in" { return "Hindi" }
            if country.contains("china") || country.contains("taiwan") || country == "cn" || country == "tw" { return "Mandarin" }
            if country.contains("russia") || country == "ru" { return "Russian" }
        }
        return "English"
    }
    
    /// Localized display name for the origin country (e.g. "South Korea", "Japan", "United States").
    var displayOriginCountry: String? {
        guard let code = originCountry, !code.isEmpty else { return nil }
        // If the code contains multiple countries or is already a full name, return it cleanly
        if code.contains(",") {
            let parts = code.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .compactMap { part -> String? in
                    if part.count == 2 {
                        return Locale.current.localizedString(forRegionCode: part) ?? part
                    }
                    return part
                }
            return parts.joined(separator: ", ")
        }
        if code.count > 2 { return code }
        return Locale.current.localizedString(forRegionCode: code) ?? code
    }
    
    /// Dynamic label: "Regions of Origin" if multiple countries are present, otherwise "Region of Origin".
    var displayOriginCountryTitle: String {
        guard let country = displayOriginCountry, !country.isEmpty else { return "Region of Origin" }
        if country.contains(",") || (originCountry?.contains(",") ?? false) {
            return "Regions of Origin"
        }
        return "Region of Origin"
    }

    public var displayAudioTracks: [String] {
        if let tracks = audioTracks, !tracks.isEmpty {
            return tracks
        }
        if let spoken = spokenLanguages, !spoken.isEmpty {
            return spoken
        }
        if let orig = displayOriginalLanguage {
            return [orig]
        }
        return ["English"]
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
    
    /// True if the item represents an episodic series / TV show (Stremio "series", TMDB "tv", or populated episodes/seasons).
    var isSeries: Bool {
        let lower = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower == "tv show" || lower == "tv" || lower == "series" || lower.contains("series") || lower.contains("tv") {
            return true
        }
        if (seasons?.count ?? 0) > 0 || (episodes?.count ?? 0) > 0 {
            return true
        }
        return false
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

    var localizedCategory: String {
        category.localized
    }

    var upcomingBadgeText: String {
        guard let dateStr = releaseDate, !dateStr.isEmpty else { return "Coming Soon".localized }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateStr) else { return "Coming Soon".localized }
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return "Releasing Today".localized
        } else if cal.isDateInTomorrow(date) {
            return "Coming Tomorrow".localized
        } else {
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)).day ?? 0
            if days > 0 && days <= 7 {
                let dayFormatter = DateFormatter()
                dayFormatter.dateFormat = "EEEE"
                return "Coming %@".localizedFormat(dayFormatter.string(from: date))
            } else {
                let currentYear = cal.component(.year, from: Date())
                let releaseYear = cal.component(.year, from: date)
                let displayFormatter = DateFormatter()
                if currentYear == releaseYear {
                    displayFormatter.dateFormat = "MMMM d"
                } else {
                    displayFormatter.dateFormat = "MMMM d, yyyy"
                }
                return "In Theatres %@".localizedFormat(displayFormatter.string(from: date))
            }
        }
    }

    var cardReleaseDateBadge: String {
        guard let dateStr = releaseDate, !dateStr.isEmpty else { return "Coming Soon".localized }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateStr) else {
            if dateStr.count >= 4 {
                return "Coming %@".localizedFormat(String(dateStr.prefix(4)))
            }
            return "Coming Soon".localized
        }
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return "Today".localized
        } else if cal.isDateInTomorrow(date) {
            return "Tomorrow".localized
        } else {
            let currentYear = cal.component(.year, from: Date())
            let releaseYear = cal.component(.year, from: date)
            let displayFormatter = DateFormatter()
            if currentYear == releaseYear {
                displayFormatter.dateFormat = "MMM d"
            } else {
                displayFormatter.dateFormat = "MMM d, yyyy"
            }
            return displayFormatter.string(from: date)
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
    var isNewEpisode: Bool? = nil
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
            lastStreamURL: nil, lastTorrentInfoHash: nil, lastFileIndex: nil,
            isNewEpisode: nil
        )
    }
}
