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
}
