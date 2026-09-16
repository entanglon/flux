import Foundation

struct Episode: Identifiable, Codable, Hashable {
    let id: Int
    var name: String
    var overview: String
    var stillURL: URL?
    var heroURL: URL? // High-quality image for Hero background
    let episodeNumber: Int
    let seasonNumber: Int
    let airDate: String?
    var runtime: Int?
    
    var formattedRuntime: String {
        guard let runtime = runtime else { return "" }
        return "\(runtime) min"
    }

    private static let isoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()
    
    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    var isUpcoming: Bool {
        guard let airDate = airDate, !airDate.isEmpty else { return false }
        let dateStr = String(airDate.prefix(10))
        let date = Self.isoDateFormatter.date(from: dateStr) ?? Self.shortDateFormatter.date(from: dateStr)
        guard let date = date else { return false }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let epDay = calendar.startOfDay(for: date)
        return epDay > today
    }
}
