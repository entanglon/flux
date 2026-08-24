import Foundation

struct CastMember: Identifiable, Hashable, Codable {
    var id: String { name } // Stremio cast usually comes as an array of strings
    let name: String
    let role: String?
    let imageURL: URL?
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
    var spokenLanguages: [String]? // e.g. ["English", "Spanish"]
    var originCountry: String? // e.g. "United States"
    var voteAverage: Double? // e.g. 7.8
    var episodes: [Episode]? // To store all Stremio videos
    var watchProviders: [WatchProvider]?
    
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
    
    // History Specific
    var lastSeason: Int?
    var lastEpisode: Int?
    var lastEpisodeTitle: String?
    var lastEpisodeImage: URL?
}
