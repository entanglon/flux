import Foundation

struct Stream: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
    let source: String
    let quality: String
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
    
    // WebStreamer and Nuvio public instances (ElfHosted)
    private let webStreamerURL = "https://webstreamr.hayd.uk"
    private let nuvioURL = "https://nuviostreams.hayd.uk"
    
    // In-memory cache: "tmdbID:season:episode" -> [Stream]
    private var streamCache: [String: [Stream]] = [:]
    
    func preloadStreams(for item: MediaItem, season: Int? = nil, episode: Int? = nil) async {
        _ = await fetchStreams(for: item, season: season, episode: episode)
    }
    
    // Synchronous Cache Access
    func getCachedStreams(for item: MediaItem, season: Int? = nil, episode: Int? = nil) -> [Stream]? {
        guard let tmdbID = Int(item.id) else { return nil }
        
        let s = season ?? 1
        let e = episode ?? 1
        let isSeries = (item.seasons?.isEmpty == false) || (season != nil)
        let cacheKey = isSeries ? "\(tmdbID):\(s):\(e)" : "\(tmdbID)"
        
        if let cached = streamCache[cacheKey], !cached.isEmpty {
             return cached
        }
        return nil
    }
    
    func fetchStreams(for item: MediaItem, season: Int? = nil, episode: Int? = nil) async -> [Stream] {
        guard let tmdbID = Int(item.id) else { return [] }
        
        // Cache Key Construction
        let s = season ?? 1
        let e = episode ?? 1
        let isSeries = (item.seasons?.isEmpty == false) || (season != nil)
        let cacheKey = isSeries ? "\(tmdbID):\(s):\(e)" : "\(tmdbID)"
        
        // Check Cache
        if let cached = streamCache[cacheKey], !cached.isEmpty {
            print("[StreamManager] Returning cached streams for \(cacheKey)")
            return cached
        }
        
        var allStreams: [Stream] = []
        
        // Determine type based on seasons presence
        let type = (item.seasons?.isEmpty == false) ? "series" : "movie"
        let tmdbType = (type == "series") ? "tv" : "movie"
        
        // Use TMDB ID if available
        guard let tmdbID = Int(item.id) else {
            print("No TMDB ID for item: \(item.title)")
            return []
        }
        
        // Try to fetch IMDB ID
        var streamId = "tmdb:\(tmdbID)"
        if let imdbID = try? await TMDBClient.shared.fetchExternalIDs(type: tmdbType, id: tmdbID) {
            streamId = imdbID
            print("Found IMDB ID for \(item.title): \(imdbID)")
        } else {
            print("Could not find IMDB ID for \(item.title), falling back to TMDB ID")
        }
        
        let streamType = type
        
        // Construct the ID. For series, we must specify season and episode.
        if type == "series" {
            let s = season ?? 1
            let e = episode ?? 1
            streamId += ":\(s):\(e)"
        }
        
        let finalStreamId = streamId // Capture as immutable for async tasks
        
        print("Fetching streams for \(item.title) [\(streamType)] ID: \(finalStreamId)")
        
        // Fetch based on user preferences
        let defaults = UserDefaults.standard
        let useWebStreamer = defaults.object(forKey: "enableWebStreamer") as? Bool ?? true
        let useNuvio = defaults.object(forKey: "enableNuvio") as? Bool ?? true
        
        async let webStreamerStreams: [Stream] = useWebStreamer ? fetchFromAddon(baseURL: webStreamerURL, type: streamType, id: finalStreamId, sourceName: "WebStreamer") : []
        async let nuvioStreams: [Stream] = useNuvio ? fetchFromAddon(baseURL: nuvioURL, type: streamType, id: finalStreamId, sourceName: "Nuvio") : []
        
        let (ws, ns) = await (webStreamerStreams, nuvioStreams)
        allStreams.append(contentsOf: ws)
        allStreams.append(contentsOf: ns)
        
        // Filter by Title Match
        allStreams = allStreams.filter { stream in
            isTitleMatch(streamTitle: stream.title, itemTitle: item.title) ||
            isTitleMatch(streamTitle: stream.url.lastPathComponent, itemTitle: item.title)
        }
        print("[StreamManager] After Title Filtering: \(allStreams.count) streams remaining")

        // Sort by Priority (WebStreamer First), then Quality
        // Sort by Priority (Sticky Source -> WebStreamer -> Quality Compliance -> Quality Score)
        let lastSource = UserDefaults.standard.string(forKey: "lastUsedSource")
        let preferredQuality = UserDefaults.standard.string(forKey: "preferredQuality") ?? "4K"
        let targetScore = qualityScore(preferredQuality)

        let sortedStreams = allStreams.sorted { s1, s2 in
            // 1. Sticky Source Priority
            if let last = lastSource {
                if s1.source == last && s2.source != last { return true }
                if s2.source == last && s1.source != last { return false }
            }
            
            // 2. WebStreamer Priority (ensuring visibility for non-sticky cases)
            if s1.source == "WebStreamer" && s2.source != "WebStreamer" { return true }
            if s2.source == "WebStreamer" && s1.source != "WebStreamer" { return false }
            
            // 3. Quality Compliance
            let score1 = qualityScore(s1.quality)
            let score2 = qualityScore(s2.quality)
            
            let isCompliant1 = score1 <= targetScore
            let isCompliant2 = score2 <= targetScore
            
            if isCompliant1 && !isCompliant2 { return true } // Prefer compliant
            if !isCompliant1 && isCompliant2 { return false }
            
            if isCompliant1 && isCompliant2 {
                // Both compliant: Prefer HIGHER score (closest to target, e.g. 1080p > 720p if target 1080p)
                return score1 > score2
            } else {
                // Both non-compliant (Too high): Prefer LOWER score (closest to target, e.g. 4K > 8K if target 1080p)
                return score1 < score2
            }
        }
        
        // Cache the result
        if !sortedStreams.isEmpty {
             print("[StreamManager] Caching \(sortedStreams.count) streams for \(cacheKey)")
             streamCache[cacheKey] = sortedStreams
        }
        
        return sortedStreams
    }
    
    // MARK: - Verification Logic
    
    private func isTitleMatch(streamTitle: String, itemTitle: String) -> Bool {
        // Normalize: Lowercase, remove special chars
        func normalize(_ text: String) -> String {
            return text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: " ")
        }
        
        let nStream = normalize(streamTitle)
        let nItem = normalize(itemTitle)
        
        // Stop words to ignore
        let stopWords: Set<String> = ["the", "a", "an", "and", "or", "of", "to", "in", "on", "at", "by", "for", "with", "it", "is", "chapter", "part", "season", "episode", "s", "e"]
        
        let itemWords = nItem.split(separator: " ").map { String($0) }.filter { !stopWords.contains($0) && !$0.isEmpty }
        let streamWords = Set(nStream.split(separator: " ").map { String($0) })
        
        if itemWords.isEmpty { return true } // Too generic, let it pass
        
        // Check if ALL significant words from item title are present in stream title
        // We use a threshold. If > 75% of words match, we accept it.
        // For short titles (1-2 words), we require 100%.
        
        var matchCount = 0
        for word in itemWords {
            // Check for exact match or substring match (e.g. "Derry" in "Derrys")
            // CRITICAL FIX: For single letters (like "X" in "Dear X"), we MUST use strict equality
            // Otherwise "X" matches "x264", "remix", "flux", etc.
            if word.count == 1 {
                 if streamWords.contains(where: { $0 == word }) {
                     matchCount += 1
                 }
            } else {
                 if streamWords.contains(where: { $0.contains(word) }) {
                     matchCount += 1
                 }
            }
        }
        
        let ratio = Double(matchCount) / Double(itemWords.count)
        
        // Debug
        // print("Title Match debug: '\(itemTitle)' vs '\(streamTitle)' -> \(matchCount)/\(itemWords.count) (\(ratio))")
        
        return ratio >= 0.75
    }
    
    private func fetchFromAddon(baseURL: String, type: String, id: String, sourceName: String) async -> [Stream] {
        let urlString = "\(baseURL)/stream/\(type)/\(id).json"
        print("[\(sourceName)] Requesting: \(urlString)")
        guard let url = URL(string: urlString) else { return [] }
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8  // Fail fast
        config.timeoutIntervalForResource = 8
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        ]
        let session = URLSession(configuration: config)
        
        do {
            let (data, response) = try await session.data(from: url)
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 404 {
                    print("[\(sourceName)] Returned 404 (Not Found).")
                    return []
                } else if httpResponse.statusCode != 200 {
                    print("[\(sourceName)] Error: Status code \(httpResponse.statusCode)")
                    return []
                }
            }
            
            do {
                let response = try JSONDecoder().decode(StremioResponse.self, from: data)
                let streams = response.streams.compactMap { stream -> Stream? in
                    var urlString = stream.url
                    
                    // Recursively decode locally to ensure we strip all double-encodings
                    // (e.g. %2520 -> %20, and even %252520 -> %2520 -> %20)
                    // We limit to 3 levels to avoid infinite loops on broken URLs
                    for _ in 0..<3 {
                         if urlString.contains("%25") {
                             urlString = urlString.replacingOccurrences(of: "%25", with: "%")
                         } else {
                             break
                         }
                    }
                    
                    guard let streamUrl = URL(string: urlString) else { return nil }
                    
                    // Parse title for quality
                    let title = stream.title ?? stream.name ?? "Unknown"
                    let quality = parseQuality(from: title)
                    
                    return Stream(
                        title: title,
                        url: streamUrl,
                        source: sourceName,
                        quality: quality
                    )
                }
                print("[\(sourceName)] Found \(streams.count) streams")
                return streams
            } catch {
                print("[\(sourceName)] Error decoding JSON: \(error)")
                return []
            }
        } catch {
            print("[\(sourceName)] Network error: \(error)")
            return []
        }
    }
    
    private func parseQuality(from title: String) -> String {
        if title.contains("4k") || title.contains("2160p") { return "4K" }
        if title.contains("1080p") { return "1080p" }
        if title.contains("720p") { return "720p" }
        if title.contains("480p") { return "480p" }
        return "SD"
    }
    
    private func qualityScore(_ quality: String) -> Int {
        switch quality {
        case "4K": return 4
        case "1080p": return 3
        case "720p": return 2
        case "480p": return 1
        default: return 0
        }
    }
}
