import Foundation
import Combine
import OSLog

struct StremioSubtitleTrack: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let language: String
    let source: String?

    var displayName: String {
        let cleanLang = language.trimmingCharacters(in: .whitespacesAndNewlines)
        let locale = Locale(identifier: LanguageManager.shared.currentLanguage.isoCode)
        if let localized = locale.localizedString(forLanguageCode: cleanLang), !localized.isEmpty {
            return localized.capitalized
        }
        let enLocale = Locale(identifier: "en")
        if let localized = enLocale.localizedString(forLanguageCode: cleanLang), !localized.isEmpty {
            return localized.capitalized
        }
        switch cleanLang.lowercased() {
        case "eng", "en": return "English"
        case "spa", "es": return "Spanish"
        case "fre", "fra", "fr": return "French"
        case "ger", "deu", "de": return "German"
        case "ita", "it": return "Italian"
        case "por", "pt": return "Portuguese"
        case "rus", "ru": return "Russian"
        case "kor", "ko": return "Korean"
        case "jpn", "ja": return "Japanese"
        case "zho", "chi", "zh", "zht", "zh-tw", "zh-cn": return "Chinese"
        case "hin", "hi": return "Hindi"
        case "ara", "ar": return "Arabic"
        case "tur", "tr": return "Turkish"
        case "pol", "pl": return "Polish"
        case "nld", "nl": return "Dutch"
        case "swe", "sv": return "Swedish"
        case "nor", "no": return "Norwegian"
        case "dan", "da": return "Danish"
        case "fin", "fi": return "Finnish"
        case "ell", "el": return "Greek"
        case "heb", "he": return "Hebrew"
        case "vie", "vi": return "Vietnamese"
        case "tha", "th": return "Thai"
        case "ind", "id": return "Indonesian"
        case "ces", "cs": return "Czech"
        case "hun", "hu": return "Hungarian"
        case "ron", "ro": return "Romanian"
        case "ukr", "uk": return "Ukrainian"
        default: return cleanLang.capitalized
        }
    }
}

class SubtitleManager: ObservableObject {
    static let shared = SubtitleManager()
    private init() {}
    
    func fetchSubtitles(for item: MediaItem, season: Int?, episode: Int?) async -> [StremioSubtitleTrack] {
        let addons = AddonManager.shared.enabledAddons.filter { 
            ($0.resources?.contains("subtitles") ?? false) || $0.id == "opensubtitles3" || $0.url.contains("opensubtitles")
        }
        
        var allSubtitles: [StremioSubtitleTrack] = []
        let type = (item.category == "TV Show" || item.category == "Series") ? "series" : "movie"
        let resolvedImdbID = await StreamManager.shared.resolveImdbID(for: item, type: type) ?? item.id
        let targetID = (type == "series" && season != nil && episode != nil) ? "\(resolvedImdbID):\(season!):\(episode!)" : resolvedImdbID
        
        Logger.stream.error("[SubtitleManager] Fetching subtitles for \(targetID, privacy: .public) (\(item.title, privacy: .public)) from \(addons.count, privacy: .public) addons")
        
        await withTaskGroup(of: [StremioSubtitleTrack].self) { group in
            for addon in addons {
                group.addTask {
                    let cleanBaseURL = addon.url.replacingOccurrences(of: "/manifest.json", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let urlString = "\(cleanBaseURL)/subtitles/\(type)/\(targetID).json"
                    guard let url = URL(string: urlString) else { return [] }
                    
                    do {
                        var request = URLRequest(url: url)
                        request.timeoutInterval = 8
                        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
                        let (data, response) = try await URLSession.shared.data(for: request)
                        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                            let sc = (response as? HTTPURLResponse)?.statusCode ?? 0
                            Logger.stream.error("[SubtitleManager] HTTP \(sc, privacy: .public) from \(addon.name, privacy: .public)")
                            return []
                        }
                        let decoded = try JSONDecoder().decode(StremioSubtitleResponse.self, from: data)
                        let parsed = decoded.subtitles.compactMap { sub -> StremioSubtitleTrack? in
                            guard let subURL = sub.url,
                                  let subLang = sub.lang,
                                  let parsedURL = URL(string: subURL) ?? URL(string: subURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else {
                                return nil
                            }
                            return StremioSubtitleTrack(
                                id: sub.id ?? subURL,
                                url: parsedURL,
                                language: subLang,
                                source: addon.name
                            )
                        }
                        Logger.stream.error("[SubtitleManager] Discovered \(parsed.count, privacy: .public) subtitles from \(addon.name, privacy: .public)")
                        return parsed
                    } catch {
                        Logger.stream.error("[SubtitleManager] Failed to fetch subtitles from \(addon.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
struct StremioSubtitleResponse: Codable, Sendable {
    let subtitles: [StremioSubtitle]
}

struct StremioSubtitle: Codable, Sendable {
    let id: String?
    let url: String?
    let lang: String?
}
