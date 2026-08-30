import Foundation

struct Stream: Identifiable {
    let id = UUID()
    let title: String
    let cleanTitle: String
    let url: URL
    let source: String
    let quality: String
    var size: String?
    var language: String?
    var seeders: Int?
    var leechers: Int?
    var fileIdx: Int? = nil
    var isSeasonPack: Bool = false
    var proxyHeaders: [String: String]? = nil

    /// True for magnet / torrent-backed sources
    var isTorrent: Bool {
        url.absoluteString.hasPrefix("magnet:") || url.absoluteString.contains("xt=urn:btih:")
    }

    /// Stable identity across refetches (UUID changes every snapshot): infoHash + file index.
    var stableKey: String {
        if let hash = url.absoluteString.range(of: #"btih:([a-fA-F0-9]{32,40})"#, options: .regularExpression) {
            return String(url.absoluteString[hash]).replacingOccurrences(of: "btih:", with: "") + "#\(fileIdx ?? -1)"
        }
        return url.absoluteString + "#\(fileIdx ?? -1)"
    }
}

struct StremioResponse: Codable {
    let streams: [StremioStream]
}

struct StremioBehaviorHints: Codable {
    let proxyHeaders: [String: [String: String]]?
    let notWebReady: Bool?

    enum CodingKeys: String, CodingKey {
        case proxyHeaders
        case notWebReady
    }
}

struct StremioStream: Codable {
    let name: String?
    let title: String?
    let url: String?
    let infoHash: String?
    let fileIdx: Int?
    let sources: [String]?
    let behaviorHints: StremioBehaviorHints?
}

class StreamManager {
    static let shared = StreamManager()

    private init() {}

    /// Shared session: connection reuse + bounded timeouts so a hanging addon
    /// never stalls the whole source list (Stremio-style fast failure).
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        config.httpShouldUsePipelining = true
        return URLSession(configuration: config)
    }()
    
    // In-memory cache: "tmdbID:season:episode" -> [Stream]. Stream lists can
    // contain long addon-provided titles and URLs, so keep this strictly bounded
    // for long browsing sessions.
    private struct StreamCacheEntry {
        let streams: [Stream]
        var lastAccessed: Date
    }
    private let streamCacheLock = NSLock()
    private var streamCache: [String: StreamCacheEntry] = [:]
    private let streamCacheLimit = 40
    private let streamCacheTTL: TimeInterval = 15 * 60
    
    func preloadStreams(for item: MediaItem, season: Int? = nil, episode: Int? = nil) async {
        _ = await fetchStreams(for: item, season: season, episode: episode)
    }
    
    // Synchronous Cache Access
    func getCachedStreams(for item: MediaItem, season: Int? = nil, episode: Int? = nil) -> [Stream]? {
        let s = season ?? 1
        let e = episode ?? 1
        let isSeries = item.category == "TV Show"
        let cacheKey = isSeries ? "\(item.id):\(s):\(e)" : "\(item.id)"
        
        return cachedStreams(forKey: cacheKey)
    }
    
    func fetchStreams(for item: MediaItem, season: Int? = nil, episode: Int? = nil) async -> [Stream] {
        return await fetchStreamsRealtime(for: item, season: season, episode: episode, onStreamsUpdated: { _ in })
    }
    
    func fetchStreamsRealtime(for item: MediaItem, season: Int? = nil, episode: Int? = nil, onStreamsUpdated: @escaping ([Stream]) -> Void) async -> [Stream] {
        let s = season ?? 1
        let e = episode ?? 1
        let isSeries = item.category == "TV Show" || item.category == "Series"
        let type = isSeries ? "series" : "movie"
        let cacheKey = isSeries ? "\(item.id):\(s):\(e)" : "\(item.id)"
        
        if let cached = cachedStreams(forKey: cacheKey) {
            onStreamsUpdated(cached)
            return cached
        }
        
        // Resolve IMDb ID (Stremio addons expect tt... IDs)
        var resolvedImdbID: String? = nil
        if item.id.starts(with: "tt") {
            resolvedImdbID = item.id
        } else {
            resolvedImdbID = await TMDBEnricher.shared.getImdbID(tmdbID: item.id, type: type)
        }
        
        var allStreams: [Stream] = []

        await withTaskGroup(of: [Stream].self) { group in
            // Only addons that actually provide streams — Cinemeta (catalog/meta)
            // would just waste a request in the fan-out. Addons with unknown
            // resources are still queried (manifests may use complex shapes).
            let enabledAddons = AddonManager.shared.addons.filter {
                guard $0.isEnabled else { return false }
                guard let resources = $0.resources, !resources.isEmpty else { return true }
                return resources.contains("stream")
            }

            for addon in enabledAddons {
                let cleanBaseURL = addon.url.replacingOccurrences(of: "/manifest.json", with: "")

                group.addTask {
                    let baseID = resolvedImdbID ?? item.id
                    let targetID = isSeries ? "\(baseID):\(s):\(e)" : baseID
                    return await self.fetchFromAddon(baseURL: cleanBaseURL, type: type, id: targetID, sourceName: addon.name)
                }
            }
            
            for await streams in group {
                guard !streams.isEmpty else { continue }
                allStreams.append(contentsOf: streams)
                let sourceMode = UserDefaults.standard.string(forKey: UserDefaults.Key.streamingSourceMode) ?? "both"
                let filtered = allStreams.filter { s in
                    guard self.isWithinMaxResolution(s) else { return false }
                    let isTorrent = s.url.absoluteString.starts(with: "magnet:") || (s.seeders != nil && s.seeders! > 0)
                    if sourceMode == "http" { return !isTorrent }
                    if sourceMode == "torrent" { return isTorrent }
                    return true
                }
                let snapshot = filtered.sorted { s1, s2 in
                    self.streamSortComparator(s1, s2)
                }
                
                await MainActor.run {
                    onStreamsUpdated(snapshot)
                }
            }
        }
        
        let sourceMode = UserDefaults.standard.string(forKey: UserDefaults.Key.streamingSourceMode) ?? "both"
        let finalFiltered = deduped(allStreams).filter { s in
            guard self.isWithinMaxResolution(s) else { return false }
            let isTorrent = s.isTorrent || (s.seeders != nil && s.seeders! > 0)
            if sourceMode == "http" { return !isTorrent }
            if sourceMode == "torrent" { return isTorrent }
            return true
        }

        let sortedStreams = finalFiltered.sorted { s1, s2 in
            streamSortComparator(s1, s2)
        }

        storeCachedStreams(sortedStreams, forKey: cacheKey)
        return sortedStreams
    }

    private func cachedStreams(forKey key: String) -> [Stream]? {
        streamCacheLock.lock()
        defer { streamCacheLock.unlock() }
        guard var entry = streamCache[key] else { return nil }
        guard Date().timeIntervalSince(entry.lastAccessed) < streamCacheTTL else {
            streamCache.removeValue(forKey: key)
            return nil
        }
        entry.lastAccessed = Date()
        streamCache[key] = entry
        return entry.streams.isEmpty ? nil : entry.streams
    }

    private func storeCachedStreams(_ streams: [Stream], forKey key: String) {
        streamCacheLock.lock()
        defer { streamCacheLock.unlock() }
        let now = Date()
        streamCache = streamCache.filter { now.timeIntervalSince($0.value.lastAccessed) < streamCacheTTL }
        if streamCache[key] == nil, streamCache.count >= streamCacheLimit,
           let leastRecentKey = streamCache.min(by: { $0.value.lastAccessed < $1.value.lastAccessed })?.key {
            streamCache.removeValue(forKey: leastRecentKey)
        }
        streamCache[key] = StreamCacheEntry(streams: streams, lastAccessed: now)
    }

    /// Collapses duplicate entries for the same underlying source (same torrent from
    /// multiple addons, same HTTP URL) keeping the richest metadata per key.
    private func deduped(_ streams: [Stream]) -> [Stream] {
        var indexByKey: [String: Int] = [:]
        var out: [Stream] = []
        for s in streams {
            if let i = indexByKey[s.stableKey] {
                if (s.seeders ?? -1) > (out[i].seeders ?? -1) {
                    out[i] = s
                }
            } else {
                indexByKey[s.stableKey] = out.count
                out.append(s)
            }
        }
        return out
    }
    
    // MARK: - Quality & Health Sorting
    
    func qualityScore(_ quality: String) -> Int {
        switch quality.uppercased() {
        case "4K", "2160P", "UHD": return 4
        case "1080P", "FHD": return 3
        case "720P", "HD": return 2
        case "480P", "SD": return 1
        default: return 1
        }
    }
    
    func maxAllowedQualityScore() -> Int {
        let pref = UserDefaults.standard.string(forKey: UserDefaults.Key.preferredQuality) ?? "4K"
        return qualityScore(pref)
    }
    
    func isWithinMaxResolution(_ stream: Stream) -> Bool {
        return qualityScore(stream.quality) <= maxAllowedQualityScore()
    }
    
    /// Health score within a quality tier: Torrent health (seeders/leechers) + size sanity; HTTP reliability.
    func computeStreamHealthScore(_ stream: Stream) -> Double {
        var score: Double = 0.0

        if stream.isTorrent {
            let seeders = Double(stream.seeders ?? 0)
            score += min(seeders, 500.0) * 10.0
            if let leechers = stream.leechers {
                score += Double(leechers) * 0.5
            }
        } else {
            // Direct / Debrid HTTP streams have baseline verified instant availability
            score += 1000.0
        }

        // Language preference: penalize foreign-dub releases so a 191-seeder
        // "Dubbing PL" doesn't outrank the English original. Releases carrying
        // the original English audio (or unmarked) are unaffected.
        if let lang = stream.language?.uppercased(), isForeignDub(lang, title: stream.title) {
            score *= 0.35
        }

        // Size efficiency bonus for reasonable file sizes
        if let sizeStr = stream.size?.uppercased() {
            if sizeStr.contains("GB") {
                let numStr = sizeStr.replacingOccurrences(of: "GB", with: "").trimmingCharacters(in: .whitespaces)
                if let sizeInGB = Double(numStr) {
                    if sizeInGB >= 1.0 && sizeInGB <= 8.0 {
                        score += 25.0
                    }
                }
            }
        }

        return score
    }

    /// True when the release is a hard foreign DUB (no original English audio
    /// advertised). Multi-audio releases that include English are not penalized.
    private func isForeignDub(_ lang: String, title: String) -> Bool {
        if lang.contains("ENGLISH") || lang.contains("ORIGINAL") || lang.contains("MULTI") {
            return false
        }
        let upperTitle = title.uppercased()
        // Multi-audio markers: original track included alongside the dub
        if upperTitle.contains("DUAL") || upperTitle.contains("MULTI AUDIO") || upperTitle.contains("ORIG AUD") {
            return false
        }
        let dubMarkers = ["DUBBED", "DUBBING", "DUB"]
        return dubMarkers.contains { upperTitle.contains($0) }
    }
    
    /// Primary sort: Quality tier (1080p > 720p > SD).
    /// Secondary sort within tier: Health descending (healthiest first).
    func streamSortComparator(_ s1: Stream, _ s2: Stream) -> Bool {
        let q1 = qualityScore(s1.quality)
        let q2 = qualityScore(s2.quality)
        if q1 != q2 {
            return q1 > q2
        }
        return computeStreamHealthScore(s1) > computeStreamHealthScore(s2)
    }
    
    private func normalizeAddonURL(_ rawUrl: String) -> String {
        var url = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasPrefix("stremio://") {
            url = url.replacingOccurrences(of: "stremio://", with: "https://")
        }
        if url.hasSuffix("/manifest.json") {
            url = String(url.dropLast("/manifest.json".count))
        }
        return url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    
    private func fetchFromAddon(baseURL: String, type: String, id: String, sourceName: String) async -> [Stream] {
        let addonURLStr = normalizeAddonURL(baseURL)
        let urlString = "\(addonURLStr)/stream/\(type)/\(id).json"
        guard let url = URL(string: urlString) else { return [] }
        
        print("[\(sourceName)] Requesting: \(urlString)")

        var request = URLRequest(url: url)
        request.timeoutInterval = 12

        do {
            let (data, response) = try await self.session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return []
            }
            
            let stremioResponse = try JSONDecoder().decode(StremioResponse.self, from: data)
            let streams = stremioResponse.streams.compactMap { stream -> Stream? in
                var targetURLString = stream.url
                if (targetURLString == nil || targetURLString == "about:blank"), let hash = stream.infoHash {
                    var magnet = "magnet:?xt=urn:btih:\(hash)"
                    if let trackers = stream.sources {
                        for tr in trackers {
                            if tr.starts(with: "tracker:") {
                                let cleanTr = tr.replacingOccurrences(of: "tracker:", with: "")
                                if let encoded = cleanTr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                                    magnet += "&tr=\(encoded)"
                                }
                            }
                        }
                    }
                    targetURLString = magnet
                }
                
                guard var finalURLStr = targetURLString, finalURLStr != "about:blank" else { return nil }
                if !finalURLStr.starts(with: "magnet:") {
                    finalURLStr = normalizeAddonURL(finalURLStr)
                }
                guard let streamUrl = URL(string: finalURLStr) else { return nil }
                
                let rawTitle = stream.title ?? stream.name ?? "Unknown Stream"
                let nameHeader = stream.name ?? ""
                let combinedTitle = "\(nameHeader) \(rawTitle)"
                let quality = parseQuality(from: combinedTitle)
                let size = parseSize(from: rawTitle)
                let language = parseLanguage(from: rawTitle)
                let seeders = parseSeeders(from: rawTitle)
                let leechers = parseLeechers(from: rawTitle)
                let clean = cleanTitleString(name: nameHeader, title: rawTitle)

                // Extract proxy headers from behaviorHints (e.g. Referer, Origin)
                let headers = stream.behaviorHints?.proxyHeaders?["request"]

                return Stream(
                    title: rawTitle,
                    cleanTitle: clean,
                    url: streamUrl,
                    source: sourceName,
                    quality: quality,
                    size: size,
                    language: language,
                    seeders: seeders,
                    leechers: leechers,
                    fileIdx: stream.fileIdx,
                    isSeasonPack: detectSeasonPack(name: nameHeader, title: rawTitle),
                    proxyHeaders: headers
                )
            }
            print("[\(sourceName)] Found \(streams.count) streams")
            return streams
        } catch {
            print("[\(sourceName)] Error: \(error.localizedDescription)")
            return []
        }
    }
    
    private func parseSeeders(from title: String) -> Int? {
        let patterns = [
            #"👤\s*(\d+)"#,
            #"(?i)S:\s*(\d+)"#,
            #"(?i)seeders?:\s*(\d+)"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
               let range = Range(match.range(at: 1), in: title) {
                return Int(title[range])
            }
        }
        return nil
    }
    
    private func parseLeechers(from title: String) -> Int? {
        let patterns = [
            #"👥\s*(\d+)"#,
            #"(?i)P:\s*(\d+)"#,
            #"(?i)peers?:\s*(\d+)"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
               let range = Range(match.range(at: 1), in: title) {
                return Int(title[range])
            }
        }
        return nil
    }
    
    private func cleanTitleString(name: String, title: String) -> String {
        var result = title.replacingOccurrences(of: "\n", with: " • ")
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let lowerName = name.lowercased()
        let lowerResult = result.lowercased()
        
        if !name.isEmpty && !lowerName.contains("torrentio") && !lowerName.contains("stremio") && !lowerResult.hasPrefix(lowerName) {
            result = "\(name) • \(result)"
        }
        
        result = result.replacingOccurrences(of: "^[•\\-\\s]+", with: "", options: .regularExpression)
        return result
    }
    
    private func parseQuality(from title: String) -> String {
        let upperTitle = title.uppercased()
        if upperTitle.contains("4K") || upperTitle.contains("2160P") || upperTitle.contains("UHD") { return "4K" }
        if upperTitle.contains("1080P") || upperTitle.contains("FHD") { return "1080p" }
        if upperTitle.contains("720P") { return "720p" }
        if upperTitle.contains("HD") && !upperTitle.contains("HDR") && !upperTitle.contains("HDR10") { return "720p" }
        return "SD"
    }
    
    private func isTitleMatch(streamTitle: String, itemTitle: String) -> Bool {
        let s = streamTitle.lowercased()
        let t = itemTitle.lowercased()
        return s.contains(t) || t.contains(s)
    }
    
    private func parseSize(from title: String) -> String? {
        let pattern = #"(?i)(\d+(?:\.\d+)?)\s*(TB|GB|MB)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = title as NSString
        let matches = regex.matches(in: title, range: NSRange(location: 0, length: ns.length))
        // Prefer the size tagged with a disk/size marker (💾), else the LAST match —
        // addons like Torrentio put the authoritative size at the end of the title.
        for m in matches.reversed() {
            let lowerBound = max(0, m.range.location - 2)
            let prefix = ns.substring(with: NSRange(location: lowerBound, length: m.range.location - lowerBound))
            if prefix.contains("💾") || prefix.lowercased().contains("size") {
                return ns.substring(with: m.range)
            }
        }
        guard let last = matches.last else { return nil }
        return ns.substring(with: last.range)
    }

    /// Detects full-season / complete-series packs so the UI can label them and
    /// players know the listed size is NOT the per-episode size.
    private func detectSeasonPack(name: String, title: String) -> Bool {
        let combined = "\(name) \(title)"
        let patterns = [
            #"(?i)\b(?:complete|full)\s+season\b"#,
            #"(?i)\bseason\s*\d{1,2}\s*(?:complete|pack)\b"#,
            #"(?i)\bs\d{1,2}\s*[-–~]\s*s\d{1,2}\b"#,
            #"\bS\d{1,2}\b(?!\s*?E\d{1,3})"#
        ]
        for p in patterns {
            if combined.range(of: p, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }
    
    private func parseLanguage(from title: String) -> String? {
        let upperTitle = title.uppercased()
        
        // Separate audio portion from subtitle portion if "SUB" / "SUBS" is present
        var audioPart = upperTitle
        if let subRange = upperTitle.range(of: "SUB ") ?? upperTitle.range(of: "SUB(") ?? upperTitle.range(of: "SUBS") {
            audioPart = String(upperTitle[..<subRange.lowerBound])
        }
        
        var languages: [String] = []
        let tokens = audioPart.components(separatedBy: CharacterSet.alphanumerics.inverted)
        
        func hasLang(_ keys: [String], full: String) -> Bool {
            if audioPart.contains(full) { return true }
            for k in keys {
                if tokens.contains(k) { return true }
            }
            return false
        }
        
        if hasLang(["EN", "ENG"], full: "ENGLISH") { languages.append("EN") }
        if hasLang(["RU", "RUS"], full: "RUSSIAN") { languages.append("RU") }
        if hasLang(["KO", "KOR"], full: "KOREAN") { languages.append("KO") }
        if hasLang(["JA", "JPN"], full: "JAPANESE") { languages.append("JA") }
        if hasLang(["HI", "HIN"], full: "HINDI") { languages.append("HI") }
        if hasLang(["ES", "SPA"], full: "SPANISH") { languages.append("ES") }
        if hasLang(["FR", "FRE", "FRA"], full: "FRENCH") { languages.append("FR") }
        if hasLang(["DE", "GER", "DEU"], full: "GERMAN") { languages.append("DE") }
        if hasLang(["IT", "ITA"], full: "ITALIAN") { languages.append("IT") }
        if hasLang(["ZH", "CHI", "ZHO"], full: "CHINESE") { languages.append("ZH") }
        
        if (audioPart.contains("MULTI") || audioPart.contains("DUAL AUDIO") || audioPart.contains("MVO") || audioPart.contains("DVO")) && languages.isEmpty {
            languages.append("MULTI")
        }
        
        return languages.isEmpty ? nil : languages.joined(separator: ", ")
    }
    
    private func fetchKitsuID(for title: String) async -> String? {
        guard let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://kitsu.io/api/edge/anime?filter[text]=\(encoded)") else { return nil }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataArray = json["data"] as? [[String: Any]],
               let first = dataArray.first,
               let id = first["id"] as? String {
                print("[StreamManager] Resolved Kitsu Anime ID for '\(title)': \(id)")
                return id
            }
        } catch {
            return nil
        }
        return nil
    }
}
