import Foundation

struct Season: Identifiable, Codable, Hashable {
    let id: Int
    let name: String
    let overview: String?
    let posterURL: URL?
    let seasonNumber: Int
    let episodeCount: Int
    var episodes: [Episode]?

    var localizedName: String {
        if name.lowercased() == "specials" {
            return "Specials".localized
        }
        if let match = name.range(of: "^Season (\\d+)$", options: .regularExpression) {
            let numStr = String(name[match].replacingOccurrences(of: "Season ", with: ""))
            if let num = Int(numStr) {
                return "Season %d".localizedFormat(num)
            }
        }
        if seasonNumber > 0 && name.lowercased().starts(with: "season") {
            return "Season %d".localizedFormat(seasonNumber)
        }
        return name
    }
}
