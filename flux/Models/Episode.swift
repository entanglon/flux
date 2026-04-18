import Foundation

struct Episode: Identifiable, Codable, Hashable {
    let id: Int
    let name: String
    var overview: String
    let stillURL: URL?
    let heroURL: URL? // High-quality image for Hero background
    let episodeNumber: Int
    let seasonNumber: Int
    let airDate: String?
    let runtime: Int?
    
    var formattedRuntime: String {
        guard let runtime = runtime else { return "" }
        return "\(runtime) min"
    }
}
