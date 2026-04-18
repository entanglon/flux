import Foundation

struct Stream: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
    let source: String
    let quality: String
    var size: String?
    var language: String?
}

struct StremioResponse: Codable {
    let streams: [StremioStream]
}

struct StremioStream: Codable {
    let name: String?
    let title: String?
    let url: String
}

class StreamManager {
    static let shared = StreamManager()
    
    private init() {}
    
    // In-memory cache: "tmdbID:season:episode" -> [Stream]
    private var streamCache: [String: [Stream]] = [:]
    
    func preloadStreams(for item: MediaItem, season: Int? = nil, episode: Int? = nil) async {
        _ = await fetchStreams(for: item, season: season, episode: episode)
    }
    
    // Synchronous Cache Access
    func getCachedStreams(for item: MediaItem, season: Int? = nil, episode: Int? = nil) -> [Stream]? {
        let s = season ?? 1
        let e = episode ?? 1
        let isSeries = item.category == "TV Show"
        let cacheKey = isSeries ? "\(item.id):\(s):\(e)" : "\(item.id)"
        
        if let cached = streamCache[cacheKey], !cached.isEmpty {
             return cached
        }
        return nil
    }
    
    func fetchStreams(for item: MediaItem, season: Int? = nil, episode: Int? = nil) async -> [Stream] {
        // Cache Key Construction
        let s = season ?? 1
        let e = episode ?? 1
        let isSeries = item.category == "TV Show"
        let cacheKey = isSeries ? "\(item.id):\(s):\(e)" : "\(item.id)"
        
        // Check Cache
        if let cached = streamCache[cacheKey], !cached.isEmpty {
            print("[StreamManager] Returning cached streams for \(cacheKey)")
            return cached
        }
        
        var allStreams: [Stream] = []
        
        // Determine type based on category
        let type = (item.category == "TV Show") ? "series" : "movie"
        
        // Construct the ID. For series, we must specify season and episode.
        var finalStreamId = item.id
        if type == "series" {
            finalStreamId += ":\(s):\(e)"
        }
        
        print("Fetching streams for \(item.title) [\(type)] ID: \(finalStreamId)")
        
        // Parallel fetching from all enabled addons
        await withTaskGroup(of: [Stream].self) { group in
            let enabledAddons = AddonManager.shared.addons.filter { $0.isEnabled }
            
            for addon in enabledAddons {
                group.addTask {
                    return await self.fetchFromAddon(baseURL: addon.url.replacingOccurrences(of: "/manifest.json", with: ""), type: type, id: finalStreamId, sourceName: addon.name)
                }
            }
            
            for await streams in group {
                allStreams.append(contentsOf: streams)
            }
        }
        
        // Filter by Title Match (Basic fuzzy check)
        // allStreams = allStreams.filter { isTitleMatch(streamTitle: $0.title, itemTitle: item.title) }
        
        // Sort by Quality (4K > 1080p > 720p)
        let sortedStreams = allStreams.sorted { s1, s2 in
            qualityScore(s1.quality) > qualityScore(s2.quality)
        }
        
        streamCache[cacheKey] = sortedStreams
        return sortedStreams
    }
    
    private func fetchFromAddon(baseURL: String, type: String, id: String, sourceName: String) async -> [Stream] {
        let urlString = "\(baseURL)/stream/\(type)/\(id).json"
        guard let url = URL(string: urlString) else { return [] }
        
        print("[\(sourceName)] Requesting: \(urlString)")
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 45 // 45 second timeout for slow addons (Hydra etc)
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return []
            }
            
            let stremioResponse = try JSONDecoder().decode(StremioResponse.self, from: data)
            let streams = stremioResponse.streams.compactMap { stream -> Stream? in
                let urlString = stream.url
                guard let streamUrl = URL(string: urlString) else { return nil }
                    
                    // Parse metadata
                    let title = stream.title ?? stream.name ?? "Unknown"
                    let quality = parseQuality(from: title)
                    let size = parseSize(from: title)
                    let language = parseLanguage(from: title)
                    
                    return Stream(
                        title: title,
                        url: streamUrl,
                        source: sourceName,
                        quality: quality,
                        size: size,
                        language: language
                    )
                }
            print("[\(sourceName)] Found \(streams.count) streams")
            return streams
        } catch {
            print("[\(sourceName)] Error: \(error.localizedDescription)")
            return []
        }
    }
    
    private func parseQuality(from title: String) -> String {
        let upperTitle = title.uppercased()
        if upperTitle.contains("4K") || upperTitle.contains("2160P") || upperTitle.contains("UHD") { return "4K" }
        if upperTitle.contains("1080P") || upperTitle.contains("FHD") { return "1080p" }
        if upperTitle.contains("720P") || upperTitle.contains("HD") { return "720p" }
        return "SD"
    }
    
    private func isTitleMatch(streamTitle: String, itemTitle: String) -> Bool {
        let s = streamTitle.lowercased()
        let t = itemTitle.lowercased()
        return s.contains(t) || t.contains(s)
    }
    
    private func qualityScore(_ quality: String) -> Int {
        switch quality {
        case "4K": return 4
        case "1080p": return 3
        case "720p": return 2
        case "SD": return 1
        default: return 0
        }
    }
    
    private func parseSize(from title: String) -> String? {
        let pattern = #"(?i)(\d+(?:\.\d+)?\s*(MB|GB))"#
        if let range = title.range(of: pattern, options: .regularExpression) {
             return String(title[range])
        }
        return nil
    }
    
    private func parseLanguage(from title: String) -> String? {
        var languages: [String] = []
        let upperTitle = title.uppercased()
        let tokens = upperTitle.components(separatedBy: .whitespacesAndNewlines).flatMap { $0.components(separatedBy: .punctuationCharacters) }
        
        if tokens.contains("EN") || tokens.contains("ENG") || upperTitle.contains("ENGLISH") { languages.append("EN") }
        if tokens.contains("HI") || tokens.contains("HIN") || upperTitle.contains("HINDI") { languages.append("HI") }
        if tokens.contains("RU") || tokens.contains("RUS") || upperTitle.contains("RUSSIAN") { languages.append("RU") }
        if tokens.contains("FR") || tokens.contains("FRE") || upperTitle.contains("FRENCH") { languages.append("FR") }
        if tokens.contains("MULTI") || upperTitle.contains("DUAL AUDIO") || upperTitle.contains("MULTI-AUDIO") { languages.append("MULTI") }
        
        return languages.isEmpty ? nil : languages.joined(separator: ", ")
    }
}
