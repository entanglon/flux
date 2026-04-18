import Foundation
import Combine

struct StremioSubtitleTrack: Identifiable, Hashable {
    let id: String
    let url: URL
    let language: String
    let source: String?
}

class SubtitleManager: ObservableObject {
    static let shared = SubtitleManager()
    private init() {}
    
    func fetchSubtitles(for item: MediaItem, season: Int?, episode: Int?) async -> [StremioSubtitleTrack] {
        let addons = AddonManager.shared.enabledAddons.filter { 
            $0.resources?.contains("subtitles") ?? false 
        }
        
        var allSubtitles: [StremioSubtitleTrack] = []
        let type = item.category == "TV Show" ? "series" : "movie"
        let id = (type == "series" && season != nil && episode != nil) ? "\(item.id):\(season!):\(episode!)" : item.id
        
        print("[SubtitleManager] Fetching subtitles for \(id) from \(addons.count) addons")
        
        await withTaskGroup(of: [StremioSubtitleTrack].self) { group in
            for addon in addons {
                group.addTask {
                    let urlString = "\(addon.url)/subtitles/\(type)/\(id).json"
                    guard let url = URL(string: urlString) else { return [] }
                    
                    do {
                        let (data, _) = try await URLSession.shared.data(from: url)
                        let response = try JSONDecoder().decode(StremioSubtitleResponse.self, from: data)
                        return response.subtitles.map { 
                            StremioSubtitleTrack(
                                id: $0.id, 
                                url: URL(string: $0.url) ?? url, 
                                language: $0.lang,
                                source: addon.name
                            )
                        }
                    } catch {
                        print("Failed to fetch subtitles from \(addon.name): \(error)")
                        return []
                    }
                }
            }
            
            for await subs in group {
                allSubtitles.append(contentsOf: subs)
            }
        }
        
        return allSubtitles
    }
}

// MARK: - Stremio Subtitle Models
struct StremioSubtitleResponse: Codable {
    let subtitles: [StremioSubtitle]
}

struct StremioSubtitle: Codable {
    let id: String
    let url: String
    let lang: String
}
