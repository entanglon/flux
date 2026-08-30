import Foundation

struct BonusContentItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String?
    let categoryType: String // e.g. "Behind the Scenes", "Featurette", "Bloopers", "Trailer", "Teaser", "Special", "Clip"
    let thumbnailURL: URL?
    let videoKey: String? // YouTube key for video extras
    let episode: Episode? // If playable via native player stream (Season 0 Specials)
    
    var isStreamableEpisode: Bool {
        episode != nil
    }
    
    var youtubeURL: URL? {
        if let key = videoKey {
            return URL(string: "https://www.youtube.com/watch?v=\(key)")
        }
        return nil
    }
}
