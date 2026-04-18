import Foundation
import Combine

struct Subtitle: Identifiable, Hashable {
    let id: String
    let url: URL
    let language: String
}

class SubtitleManager: ObservableObject {
    static let shared = SubtitleManager()
    private init() {}
    
    func fetchSubtitles(for item: MediaItem, season: Int?, episode: Int?) async -> [Subtitle] {
        // Implement full subtitle fetching logic here later
        return []
    }
}
