import Foundation

/// Persistent per-host delivery reputation for autoplay ranking.
/// Origins that repeatedly cut mid-stream (ffmpeg premature-end / reconnect)
/// or force proxy upstream retries get demoted so healthy hosts win
/// automatically. Failures decay after 24h. Tiny footprint: host -> recent
/// failure epochs, capped per host. Loopback (our own proxy) never counts.
final class HostHealthTracker {
    static let shared = HostHealthTracker()
    /// Injectable for hermetic unit tests (default: standard).
    var defaults: UserDefaults = .standard
    private let storeKey = "flux.hostFailures.v1"
    private let lock = NSLock()
    private let window: TimeInterval = 24 * 3600
    private let perFailure = 1500.0
    private let maxPenalty = 6000.0

    private func readMap() -> [String: [Double]] {
        var map: [String: [Double]] = [:]
        for (k, v) in defaults.dictionary(forKey: storeKey) ?? [:] {
            if let arr = v as? [Double] { map[k] = arr }
            else if let arr = v as? [NSNumber] { map[k] = arr.map { $0.doubleValue } }
        }
        return map
    }

    func recordFailure(host: String) {
        let h = host.lowercased()
        guard !h.isEmpty, h != "127.0.0.1", h != "localhost" else { return }
        lock.lock(); defer { lock.unlock() }
        var map = readMap()
        let now = Date().timeIntervalSince1970
        var list = (map[h] ?? []).filter { now - $0 < window }
        list.append(now)
        map[h] = Array(list.suffix(20))
        defaults.set(map, forKey: storeKey)
    }

    /// Ranking penalty for a host: 1500 per failure in the last 24h, cap 6000.
    /// Calibrated against healthScore tiers: one failure drops an unverified
    /// direct stream 3000->1500 (still above typical swarms); 2+ sink it below
    /// decent torrents; verified-responsive (10000) always survives capped.
    func penalty(for host: String) -> Double {
        let h = host.lowercased()
        guard !h.isEmpty else { return 0 }
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        let recent = (readMap()[h] ?? []).filter { now - $0 < window }.count
        return min(maxPenalty, Double(recent) * perFailure)
    }
}

enum StartupSpeedTier: String, CaseIterable {
    case instant = "Instant"
    case fast = "Fast"
    case standard = "Standard"
    
    var badgeText: String {
        switch self {
        case .instant: return "⚡ Instant (~1-2s)"
        case .fast: return "⚡ Fast (~3-4s)"
        case .standard: return "Standard"
        }
    }
}

struct Stream: Identifiable, Codable, Hashable, Equatable {
    var id = UUID()
    let title: String
    let cleanTitle: String
    let url: URL
    let source: String
    let quality: String
    var size: String?
    var language: String?
    var codec: String?
    var bitrate: String?
    var subtitles: String?
    var seeders: Int?
    var leechers: Int?
    var fileIdx: Int? = nil
    var isSeasonPack: Bool = false
    var proxyHeaders: [String: String]? = nil
    /// Torrent identity even when this entry plays over direct HTTP (e.g. debrid
    /// links that ship both `url` and `infoHash`). Playback transport still follows `url`.
    var infoHash: String? = nil
    /// Underlying release source or indexer (e.g. 1337x, YTS, TorrentGalaxy, Server 1)
    var indexer: String? = nil
    /// Underlying release filename from behaviorHints or scraper metadata (if available)
    var filename: String? = nil

    /// True for magnet or torrent-swarm backed releases
    var isTorrent: Bool {
        let urlStr = url.absoluteString
        if StreamManager.isP2PSource(source, url: urlStr) { return true }
        if StreamManager.isHttpSource(source, url: urlStr) { return false }
        if urlStr.hasPrefix("magnet:") || urlStr.contains("xt=urn:btih:") {
            return true
        }
        if (seeders ?? 0) > 0 {
            return true
        }
        return false
    }

    /// True for direct web-scraped HTTP hosters, CDNs, or debrid-resolved streams
    var isDirectHTTP: Bool {
        let urlStr = url.absoluteString
        if StreamManager.isP2PSource(source, url: urlStr) { return false }
        if StreamManager.isHttpSource(source, url: urlStr) { return true }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        return !isTorrent
    }

    /// True when the content originates from a torrent swarm, even if this entry
    /// plays over direct HTTP (debrid-cached). Used for labels and origin indicators.
    var isTorrentSourced: Bool {
        isTorrent || (infoHash?.isEmpty == false)
    }

    /// Stable identity across refetches (UUID changes every snapshot): infoHash + file index.
    var stableKey: String {
        if let hash = url.absoluteString.range(of: #"btih:([a-fA-F0-9]{32,40})"#, options: .regularExpression) {
            return String(url.absoluteString[hash]).replacingOccurrences(of: "btih:", with: "") + "#\(fileIdx ?? -1)"
        }
        return url.absoluteString + "#\(fileIdx ?? -1)"
    }

    /// Detects file container format from title metadata
    var containerType: String {
        let combined = "\(title) \(cleanTitle)".uppercased()
        if combined.contains(".MKV") || combined.contains("MKV") || combined.contains("MATROSKA") {
            return "MKV"
        }
        if combined.contains(".MP4") || combined.contains("MP4") || combined.contains(".M4V") {
            return "MP4"
        }
        if combined.contains(".AVI") || combined.contains("AVI") {
            return "AVI"
        }
        return "UNKNOWN"
    }

    /// Matroska (MKV) places SeekHead at byte 0 by specification, enabling instant sequential demuxing
    var isMKV: Bool {
        containerType == "MKV"
    }

    /// Checks if MP4 release is from a known faststart (moov at byte 0) release group
    var isFastStartMP4: Bool {
        guard containerType == "MP4" else { return false }
        let combined = "\(title) \(cleanTitle)".uppercased()
        let knownFastStartGroups = ["PSA", "GALAXYRG", "YTS", "YIFY", "QXR", "NTB", "FLUX", "MEGUSTA", "PAHE", "TGX"]
        return knownFastStartGroups.contains { combined.contains($0) }
    }

    /// Parsed file size normalized to Gigabytes
    var parsedSizeInGB: Double? {
        guard let sizeStr = size?.uppercased() else { return nil }
        if sizeStr.contains("GB") {
            let num = sizeStr.replacingOccurrences(of: "GB", with: "").trimmingCharacters(in: .whitespaces)
            return Double(num)
        }
        if sizeStr.contains("MB") {
            let num = sizeStr.replacingOccurrences(of: "MB", with: "").trimmingCharacters(in: .whitespaces)
            if let mb = Double(num) {
                return mb / 1024.0
            }
        }
        return nil
    }

    var startupSpeedTier: StartupSpeedTier {
        StreamManager.shared.speedTier(for: self)
    }

    var isFastStart: Bool {
        StreamManager.shared.isFastStartStream(self)
    }
}

struct StremioResponse: Codable {
    let streams: [StremioStream]

    init(streams: [StremioStream]) { self.streams = streams }

    /// Salvages individually-decodable stream objects when whole-response decoding
    /// fails — scraping addons occasionally emit irregular shapes for a single
    /// entry, which must not wipe out the entire addon response.
    static func tolerantStreams(from data: Data) -> [StremioStream] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["streams"] as? [[String: Any]] else { return [] }
        var out: [StremioStream] = []
        out.reserveCapacity(raw.count)
        let decoder = JSONDecoder()
        for element in raw {
            guard let elementData = try? JSONSerialization.data(withJSONObject: element),
                  let stream = try? decoder.decode(StremioStream.self, from: elementData) else { continue }
            out.append(stream)
        }
        return out
    }
}

struct StremioBehaviorHints: Codable {
    let proxyHeaders: [String: [String: String]]?
    let notWebReady: Bool?
    let bingeGroup: String?
    let filename: String?
    let videoSize: Int64?

    enum CodingKeys: String, CodingKey {
        case proxyHeaders
        case notWebReady
        case bingeGroup
        case filename
        case videoSize
    }
}

struct StremioStream: Codable {
    let name: String?
    let title: String?
    let description: String?
    let url: String?
    let ytId: String?
    let infoHash: String?
    let fileIdx: Int?
    let externalUrl: String?
    let sources: [String]?
    let subtitles: [StremioSubtitle]?
    let behaviorHints: StremioBehaviorHints?
}

class StreamManager {
    static let shared = StreamManager()

    private init() {}

    /// Shared session: connection reuse + bounded timeouts so a hanging addon
    /// never stalls the whole source list (Stremio-style fast failure).
    /// Generous timeouts accommodate scraping-based addons (PenguPlay etc.)
    /// that query multiple providers sequentially. Fan-out is parallel and the
    /// UI updates progressively per addon, so a slow addon never blocks others.
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpShouldUsePipelining = true
        return URLSession(configuration: config)
    }()
    
    // In-memory cache (Actor-isolated)
    let cacheActor = StreamCacheActor()
    
    func preloadStreams(for item: MediaItem, season: Int? = nil, episode: Int? = nil) async {
        _ = await fetchStreams(for: item, season: season, episode: episode)
    }
    
    // Cache Access
    func getCachedStreams(for item: MediaItem, season: Int? = nil, episode: Int? = nil, sourceMode: String? = nil) async -> [Stream]? {
        let s = season ?? 1
        let e = episode ?? 1
        let isSeries = item.category == "TV Show"
        let cacheKey = isSeries ? "\(item.id):\(s):\(e)" : "\(item.id)"
        
        guard let cached = await cacheActor.get(key: cacheKey) else { return nil }
        let mode = sourceMode ?? UserDefaults.standard.string(forKey: UserDefaults.Key.streamingSourceMode) ?? "both"
        return cached.filter { s in
            if mode == "http" { return !s.isTorrent }
            if mode == "torrent" { return s.isTorrent }
            return true
        }
    }
    
    func fetchStreams(for item: MediaItem, season: Int? = nil, episode: Int? = nil) async -> [Stream] {
        return await fetchStreamsRealtime(for: item, season: season, episode: episode, onStreamsUpdated: { _ in })
    }

    // MARK: - Measured Throughput Race

    /// Result of one ranged-GET throughput probe.
    struct ThroughputProbe: Equatable {
        /// Upstream served actual media (right content type, sane size).
        let ok: Bool
        /// Upstream served an HTML interstitial / JSON error / junk body.
        let hijacked: Bool
        /// Seconds until completion of the probe range (includes TTFB).
        let ttfbSeconds: Double
        /// Sustained throughput in KB/s across the probe range.
        let throughputKBps: Double
    }

    /// Parallel ranged-GET probe race over HTTP candidates — the mechanism the
    /// README has always advertised. Each candidate fetches 512KB with the
    /// same headers the real playback path uses; we measure sustained
    /// throughput and classify hijacks (HTML/JSON/tiny non-media bodies).
    /// The first candidate whose measurement crosses `goodEnoughKBps` while
    /// every better-ranked rival has already measured slower wins the early
    /// commit; otherwise the caller re-ranks with the full measurement set.
    /// Hard time-boxed: a candidate that cannot deliver 512KB inside the
    /// budget is reported as failed (≈ < 170 KB/s is unusable for 1080p).
    /// Torrents are never probed here — swarm metrics rank them already.
    func raceThroughput(
        for candidates: [Stream],
        playableURL: @escaping (Stream) -> URL,
        budgetSeconds: Double = 3.0,
        goodEnoughKBps: Double = 800.0
    ) async -> (probes: [String: ThroughputProbe], committedKey: String?) {
        let httpCandidates = candidates.filter { !$0.isTorrent }
        guard !httpCandidates.isEmpty else { return ([:], nil) }

        var probes: [String: ThroughputProbe] = [:]
        var reported = Set<String>()
        var committedKey: String?

        await withTaskGroup(of: (String, ThroughputProbe?).self) { group in
            for stream in httpCandidates {
                let key = stream.stableKey
                let url = playableURL(stream)
                let headers = stream.proxyHeaders
                group.addTask {
                    let probe = await Self.probeThroughput(
                        url: url,
                        headers: headers,
                        budgetSeconds: budgetSeconds
                    )
                    return (key, probe)
                }
            }

            for await (key, probe) in group {
                guard let probe else { continue }
                reported.insert(key)
                probes[key] = probe

                let crossesBar = probe.ok && !probe.hijacked && probe.throughputKBps >= goodEnoughKBps
                guard crossesBar, committedKey == nil else { continue }
                // Respect metadata order: only early-commit when no better-ranked
                // candidate is still racing (they may yet cross the bar too).
                let index = httpCandidates.firstIndex { $0.stableKey == key } ?? 0
                let higherPending = httpCandidates.prefix(index).contains { !reported.contains($0.stableKey) }
                if !higherPending {
                    committedKey = key
                    group.cancelAll()
                    break
                }
            }
        }

        return (probes, committedKey)
    }

    /// Single-candidate probe: 512KB ranged GET through the real delivery path
    /// (custom headers included; loopback proxy URLs carry their headers
    /// server-side). Measures aggregate time → KB/s; classifies hijacks.
    private static func probeThroughput(
        url: URL,
        headers: [String: String]?,
        budgetSeconds: Double
    ) async -> ThroughputProbe {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-524287", forHTTPHeaderField: "Range")
        request.timeoutInterval = budgetSeconds
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let isLoopback = url.host == "127.0.0.1" || url.host == "localhost"
        if !isLoopback {
            for (key, value) in headers ?? [:] {
                request.setValue(value, forHTTPHeaderField: key)
            }
            if request.value(forHTTPHeaderField: "User-Agent") == nil {
                request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            }
        }

        let start = CFAbsoluteTimeGetCurrent()
        let isProxied = StreamRouteProxyManager.shared.shouldProxy(url: url)
        let session: URLSession
        if isProxied, let proxyDict = StreamRouteProxyManager.shared.proxyDictionary() {
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = proxyDict
            config.timeoutIntervalForRequest = budgetSeconds
            config.timeoutIntervalForResource = budgetSeconds
            session = URLSession(configuration: config)
        } else {
            session = URLSession.shared
        }

        do {
            let (data, response) = try await session.data(for: request)
            let elapsed = max(0.05, CFAbsoluteTimeGetCurrent() - start)

            guard let http = response as? HTTPURLResponse else {
                return ThroughputProbe(ok: false, hijacked: false, ttfbSeconds: elapsed, throughputKBps: 0)
            }

            let mime = (http.mimeType ?? "").lowercased()
            let bodyPrefix = String(data: data.prefix(512), encoding: .utf8)?.lowercased() ?? ""
            let bodyLooksHTML = bodyPrefix.contains("<!doctype") || bodyPrefix.contains("<html")
            let mediaMime = mime.hasPrefix("video") || mime.hasPrefix("audio")
                || mime.hasPrefix("application/octet-stream") || mime.hasPrefix("application/vnd.apple.mpegurl")
                || mime.isEmpty
            // Tiny non-media bodies are promo/reel junk, not the title.
            let hijacked = bodyLooksHTML || mime.contains("text/html") || mime.contains("json")
                || (!mediaMime && data.count < 32_768)

            guard (200...299).contains(http.statusCode), !hijacked else {
                return ThroughputProbe(ok: false, hijacked: hijacked, ttfbSeconds: elapsed, throughputKBps: 0)
            }

            let kbps = (Double(data.count) / 1024.0) / elapsed
            return ThroughputProbe(ok: true, hijacked: false, ttfbSeconds: elapsed, throughputKBps: kbps)
        } catch {
            if isProxied {
                // Transparent direct fallback if proxy endpoint is offline
                if let (fallbackData, fallbackResp) = try? await URLSession.shared.data(for: request),
                   let fallbackHttp = fallbackResp as? HTTPURLResponse, (200...299).contains(fallbackHttp.statusCode) {
                    let elapsed = max(0.05, CFAbsoluteTimeGetCurrent() - start)
                    let kbps = (Double(fallbackData.count) / 1024.0) / elapsed
                    return ThroughputProbe(ok: true, hijacked: false, ttfbSeconds: elapsed, throughputKBps: kbps)
                }
            }
            let elapsed = max(0.05, CFAbsoluteTimeGetCurrent() - start)
            // Timeout before any usable payload ≈ cannot sustain 512KB inside
            // the budget (≈ < 170 KB/s) — unusable for 1080p, report failed.
            return ThroughputProbe(ok: false, hijacked: false, ttfbSeconds: elapsed, throughputKBps: 0)
        }
    }
    
    // MARK: - Fast Responsive 1-Byte Probe Race (Flux Mode)

    /// Fast lightweight 1-byte range probe for HTTP streams.
    /// Checks responsiveness, status code (200/206/3xx), and non-hijack media MIME type.
    static func probeResponsive(
        url: URL,
        headers: [String: String]? = nil,
        timeout: TimeInterval = 1.5
    ) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let isLoopback = url.host == "127.0.0.1" || url.host == "localhost"
        if !isLoopback {
            for (key, value) in headers ?? [:] {
                request.setValue(value, forHTTPHeaderField: key)
            }
            if request.value(forHTTPHeaderField: "User-Agent") == nil {
                request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            }
        }

        let isProxied = StreamRouteProxyManager.shared.shouldProxy(url: url)
        let session: URLSession
        if isProxied, let proxyDict = StreamRouteProxyManager.shared.proxyDictionary() {
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = proxyDict
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout
            session = URLSession(configuration: config)
        } else {
            session = URLSession.shared
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            guard (200...399).contains(http.statusCode) else { return false }

            let mime = (http.mimeType ?? "").lowercased()
            let bodyPrefix = String(data: data.prefix(256), encoding: .utf8)?.lowercased() ?? ""
            let bodyLooksHTML = bodyPrefix.contains("<!doctype") || bodyPrefix.contains("<html")
            let hijacked = bodyLooksHTML || mime.contains("text/html") || mime.contains("json")

            return !hijacked
        } catch {
            if isProxied {
                // Fallback to direct probe if proxy is unreachable
                if let (fallbackData, fallbackResp) = try? await URLSession.shared.data(for: request),
                   let fallbackHttp = fallbackResp as? HTTPURLResponse, (200...399).contains(fallbackHttp.statusCode) {
                    let mime = (fallbackHttp.mimeType ?? "").lowercased()
                    let bodyPrefix = String(data: fallbackData.prefix(256), encoding: .utf8)?.lowercased() ?? ""
                    let bodyLooksHTML = bodyPrefix.contains("<!doctype") || bodyPrefix.contains("<html")
                    let hijacked = bodyLooksHTML || mime.contains("text/html") || mime.contains("json")
                    return !hijacked
                }
            }
            return false
        }
    }

    /// Parallel 1-byte probe race across top candidates. The first responsive candidate
    /// wins immediately, cancelling any remaining in-flight probes.
    func raceTopCandidates(
        _ candidates: [Stream],
        playableURL: @escaping (Stream) -> URL,
        timeout: TimeInterval = 1.5
    ) async -> (winner: Stream?, fallbacks: [Stream]) {
        guard !candidates.isEmpty else { return (nil, []) }

        let httpCandidates = candidates.filter { !$0.isTorrent }
        if httpCandidates.isEmpty {
            // Pure torrent selection: top candidate from Best Health wins
            return (candidates.first, Array(candidates.dropFirst()))
        }

        var responsiveWinner: Stream?

        await withTaskGroup(of: (Stream, Bool).self) { group in
            for stream in httpCandidates {
                let targetURL = playableURL(stream)
                let headers = stream.proxyHeaders
                group.addTask {
                    let ok = await Self.probeResponsive(url: targetURL, headers: headers, timeout: timeout)
                    return (stream, ok)
                }
            }

            for await (stream, ok) in group {
                if ok && responsiveWinner == nil {
                    responsiveWinner = stream
                    group.cancelAll()
                    break
                }
            }
        }

        if let winner = responsiveWinner {
            let fallbacks = candidates.filter { $0.stableKey != winner.stableKey }
            return (winner, fallbacks)
        } else {
            // If no HTTP candidate responded within timeout, fallback to candidate #1
            return (candidates.first, Array(candidates.dropFirst()))
        }
    }

    /// Determines whether the currently collected streams have reached a quality quorum
    /// sufficient for Flux Mode to commit without waiting for lagging scrapers.
    func hasQualityQuorum(
        streams: [Stream],
        sourceMode: String,
        preferredQuality: String = "1080p",
        targetTitle: String? = nil
    ) -> Bool {
        guard !streams.isEmpty else { return false }
        
        let filtered: [Stream]
        if sourceMode == "http" {
            filtered = streams.filter { !$0.isTorrent }
        } else if sourceMode == "torrent" {
            filtered = streams.filter { $0.isTorrent }
        } else {
            filtered = streams
        }
        guard !filtered.isEmpty else { return false }
        
        let maxAllowed = qualityScore(preferredQuality)
        let validCandidates = filtered.filter { s in
            if qualityScore(s.quality) > maxAllowed && maxAllowed >= 3 {
                return false
            }
            if let targetTitle, !targetTitle.isEmpty, Self.labelLooksLikeJunk(labelText: "\(s.cleanTitle) \(s.source)", targetTitle: targetTitle) {
                return false
            }
            if isDolbyVisionProfile5(s) {
                return false
            }
            if s.isTorrent {
                return (s.seeders ?? 0) >= 15
            } else {
                return s.isDirectHTTP
            }
        }
        
        if sourceMode == "http" {
            return validCandidates.count >= 1
        } else if sourceMode == "torrent" {
            return validCandidates.count >= 2
        } else {
            return validCandidates.count >= 2 || validCandidates.contains { $0.isDirectHTTP }
        }
    }

    func fetchStreamsRealtime(
        for item: MediaItem,
        season: Int? = nil,
        episode: Int? = nil,
        forceRefresh: Bool = false,
        onProgress: ((_ loaded: Int, _ total: Int, _ pendingNames: [String]) -> Void)? = nil,
        onStreamsUpdated: @escaping ([Stream]) -> Void
    ) async -> [Stream] {
        let s = season ?? 1
        let e = episode ?? 1
        let isSeries = item.category == "TV Show" || item.category == "Series"
        let type = isSeries ? "series" : "movie"
        let cacheKey = isSeries ? "\(item.id):\(s):\(e)" : "\(item.id)"
        
        let sourceMode = UserDefaults.standard.string(forKey: UserDefaults.Key.streamingSourceMode) ?? "both"

        if !forceRefresh, let cached = await cacheActor.get(key: cacheKey) {
            let filtered = cached.filter { s in
                if sourceMode == "http" { return !s.isTorrent }
                if sourceMode == "torrent" { return s.isTorrent }
                return true
            }
            onProgress?(1, 1, [])
            onStreamsUpdated(filtered)
            return filtered
        }
        
        // Resolve IMDb ID (Stremio addons expect tt... IDs)
        let resolvedImdbID = await resolveImdbID(for: item, type: type)
        
        var allStreams: [Stream] = []

        let enabledAddons = AddonManager.shared.addons.filter { $0.isEnabled && self.shouldQueryAddon($0, sourceMode: sourceMode) }
        var pendingNames = enabledAddons.map { $0.name }
        let totalCount = enabledAddons.count
        var loadedCount = 0

        onProgress?(loadedCount, totalCount, pendingNames)

        await withTaskGroup(of: (String, [Stream]).self) { group in
            for addon in enabledAddons {
                let cleanBaseURL = addon.url.replacingOccurrences(of: "/manifest.json", with: "")
                let name = addon.name

                group.addTask {
                    let baseID = resolvedImdbID ?? item.id
                    let targetID = isSeries ? "\(baseID):\(s):\(e)" : baseID
                    let streams = await self.fetchFromAddon(baseURL: cleanBaseURL, type: type, id: targetID, sourceName: name)
                    return (name, streams)
                }
            }

            for await (name, result) in group {
                loadedCount += 1
                pendingNames.removeAll { $0 == name }
                onProgress?(loadedCount, totalCount, pendingNames)

                if !result.isEmpty {
                    allStreams.append(contentsOf: result)
                    let currentDeduped = self.deduped(allStreams)
                    let currentSorted = currentDeduped.sorted { self.streamSortComparator($0, $1) }
                    let currentFiltered = currentSorted.filter { s in
                        if sourceMode == "http" { return !s.isTorrent }
                        if sourceMode == "torrent" { return s.isTorrent }
                        return true
                    }
                    onStreamsUpdated(currentFiltered)
                }
            }
        }
        
        // Preserve all discovered streams across all resolutions (4K, 1080p, 720p, SD).
        // Resolution preferences are applied dynamically in Flux Mode auto-play,
        // while the Stream Picker and cache retain all options for user choice.
        let sortedStreams = deduped(allStreams).sorted { s1, s2 in
            streamSortComparator(s1, s2)
        }

        // Cache the UNFILTERED (by source mode) result so switching between
        // http/torrent/both doesn't require re-fetching from all addons.
        await cacheActor.set(key: cacheKey, streams: sortedStreams)

        // Apply source mode filter AFTER caching
        let modeFiltered = sortedStreams.filter { s in
            if sourceMode == "http" { return !s.isTorrent }
            if sourceMode == "torrent" { return s.isTorrent }
            return true
        }
        return modeFiltered
    }

    /// Identifies whether a provider name or URL represents a known HTTP scraper / CDN addon
    static func isHttpSource(_ source: String, url: String? = nil) -> Bool {
        let s = "\(source) \(url ?? "")".lowercased()
        // AIOStreams serves both HTTP and torrent streams through the same addon.
        // Classification depends on the individual stream URL, not the addon config.
        if s.contains("aiostreams") {
            // If we have an actual stream URL, classify by whether it's a magnet link
            if let u = url?.lowercased() {
                if u.hasPrefix("magnet:") || u.contains("xt=urn:btih:") { return false }
                if u.hasPrefix("http://") || u.hasPrefix("https://") { return true }
            }
            // Addon-level classification: check the config path
            return s.contains("http-only") || s.contains("http")
        }
        if isP2PSource(source, url: url) {
            return false
        }
        return s.contains("pengu") || s.contains("webstream") || s.contains("stremify") || s.contains("easydebrid") || s.contains("http") || s.contains("direct") || s.contains("archive.org") || s.contains("archive")
    }

    /// Identifies whether a provider name or URL represents a known torrent/P2P addon
    static func isP2PSource(_ source: String, url: String? = nil) -> Bool {
        let s = "\(source) \(url ?? "")".lowercased()
        if s.contains("pengu") || s.contains("webstream") || s.contains("stremify") || s.contains("easydebrid") || s.contains("archive.org") || s.contains("archive") {
            return false
        }
        // AIOStreams: classify by the individual stream URL
        if s.contains("aiostreams") {
            if let u = url?.lowercased() {
                if u.hasPrefix("magnet:") || u.contains("xt=urn:btih:") { return true }
                if u.hasPrefix("http://") || u.hasPrefix("https://") { return false }
            }
            // Addon-level: torrent unless explicitly http-only
            return !s.contains("http-only")
        }
        return s.contains("torrentio") || s.contains("meteor") || s.contains("comet") || s.contains("knightcrawler") || s.contains("mediafusion") || s.contains("annatar") || s.contains("jackett") || s.contains("p2p") || s.contains("torrent")
    }

    /// Identifies whether a provider name represents a known torrent/P2P addon
    static func isKnownTorrentAddon(_ source: String, url: URL? = nil) -> Bool {
        return isP2PSource(source, url: url?.absoluteString)
    }

    /// Resolves an IMDb tt... ID for Stremio addons.
    /// Tries TMDB external IDs first, then falls back to Cinemeta search.
    func resolveImdbID(for item: MediaItem, type: String) async -> String? {
        if item.id.starts(with: "tt") {
            return item.id
        }

        // 1. Try TMDB external_ids
        if let tmdbImdb = await TMDBEnricher.shared.getImdbID(tmdbID: item.id, type: type), !tmdbImdb.isEmpty {
            return tmdbImdb
        }

        // 2. Fallback: Query Cinemeta catalog search by title
        let cleanTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty,
              let encoded = cleanTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://v3-cinemeta.strem.io/catalog/\(type)/top/search=\(encoded).json") else {
            return nil
        }

        do {
            let (data, response) = try await self.session.data(from: searchURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let metas = json["metas"] as? [[String: Any]] else {
                return nil
            }

            for meta in metas {
                if let imdbID = meta["imdb_id"] as? String, imdbID.starts(with: "tt") {
                    print("[StreamManager] Resolved IMDb ID via Cinemeta: \(cleanTitle) -> \(imdbID)")
                    return imdbID
                }
                if let id = meta["id"] as? String, id.starts(with: "tt") {
                    print("[StreamManager] Resolved IMDb ID via Cinemeta: \(cleanTitle) -> \(id)")
                    return id
                }
            }
        } catch {
            print("[StreamManager] Cinemeta IMDb resolution error: \(error)")
        }

        return nil
    }

    /// Determines whether an addon should be queried under the active sourceMode filter.
    /// In HTTP-only mode, P2P torrent addons are strictly bypassed.
    /// In Torrent-only mode, HTTP scraper addons are strictly bypassed.
    func shouldQueryAddon(_ addon: StremioAddon, sourceMode: String) -> Bool {
        if addon.url.hasPrefix("flux://") || addon.id == "stock.stream-route-proxy" || addon.id == "opensubtitles3" {
            return false
        }
        if sourceMode == "both" { return true }
        let name = addon.name
        let url = addon.url

        // AIOStreams is a hybrid addon that serves both HTTP and torrent streams
        // through the same endpoint — always query it; stream-level filtering handles the rest.
        if name.lowercased().contains("aiostreams") || url.lowercased().contains("aiostreams") {
            return true
        }

        let isHttp = Self.isHttpSource(name, url: url)
        let isTorrent = Self.isP2PSource(name, url: url)

        if sourceMode == "http" {
            // Strictly disable all P2P torrent addons
            if isTorrent { return false }
            return isHttp || !isTorrent
        } else if sourceMode == "torrent" {
            // Strictly disable all HTTP scraper addons
            if isHttp { return false }
            return isTorrent || !isHttp
        }
        return true
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
        case "4K", "2160P", "UHD": return 5
        case "2K", "1440P", "QHD": return 4
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
    func computeStreamHealthScore(_ stream: Stream, originalLanguage: String? = nil, enableLanguageFilter: Bool? = nil) -> Double {
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

        // Language preference:
        let isFilterActive = enableLanguageFilter ?? UserDefaults.standard.bool(forKey: "enableFluxLanguageFilter")
        if isFilterActive {
            let defaultLang = UserDefaults.standard.string(forKey: "defaultAudioLang") ?? "English"
            if matchesPreferredLanguage(stream, preferred: defaultLang, originalLanguage: originalLanguage, enableLanguageFilter: true) {
                score += 3000.0 // Major priority boost for matching the user's preferred audio language
            } else {
                // Demote releases that lack the preferred language
                score *= 0.40
            }
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

        // Dolby Vision Profile 5 Deprioritization:
        // Single-layer Profile 5 (IPTPQc2) lacks an HDR10 base layer fallback,
        // producing a magenta/green cast in OpenGL libmpv.
        // Deprioritize P5 so that clean HDR10, Profile 8 (hybrid DV/HDR10), and SDR streams win.
        if isDolbyVisionProfile5(stream) {
            score *= 0.20
        }

        return score
    }

    /// Detects single-layer Dolby Vision Profile 5 (IPTPQc2) streams that lack an HDR10 fallback.
    /// In OpenGL libmpv, these render with a magenta/green tint because the legacy vo_gpu path
    /// cannot perform IPTPQc2 polynomial reshaping.
    func isDolbyVisionProfile5(_ stream: Stream) -> Bool {
        let text = "\(stream.title) \(stream.cleanTitle)".uppercased()
        let hasDV = text.contains("DV") || text.contains("DOLBY VISION") || text.contains("DOVI")
        guard hasDV else { return false }
        
        // If the release has explicit HDR / HDR10 / Profile 8 / Profile 7 fallback, it's NOT single-layer Profile 5
        let hasHDRFallback = text.contains("HDR10") || text.contains("HDR") || text.contains("P8") ||
            text.contains("PROFILE 8") || text.contains("PROFILE.8") || text.contains("P7") ||
            text.contains("PROFILE 7") || text.contains("HYBRID")
        if hasHDRFallback {
            return false
        }

        // Explicit Profile 5 patterns (guarded with regex boundaries so DDP5.1 audio never matches)
        let explicitP5Patterns = [
            #"(?i)\bPROFILE[\.\s_-]*5\b"#,
            #"(?i)\bDOVI[\.\s_-]*0?5\b"#,
            #"(?i)\bDV[\.\s_-]*0?5\b"#,
            #"(?i)[\.\[\s_-]P0?5[\.\]\s_-]"#
        ]
        for pattern in explicitP5Patterns {
            if text.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        
        // Single-layer WEB-DL / WEBRip releases with DV but NO HDR10 fallback are Profile 5
        if text.contains("WEB-DL") || text.contains("WEBDL") || text.contains("WEBRIP") {
            return true
        }
        
        return false
    }

    static func canonicalLanguageCode(_ lang: String) -> String {
        let u = lang.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch u {
        case "ENGLISH", "EN", "ENG": return "EN"
        case "HINDI", "HI", "HIN": return "HI"
        case "TAMIL", "TA", "TAM": return "TAM"
        case "TELUGU", "TE", "TEL": return "TEL"
        case "JAPANESE", "JA", "JPN", "JAP": return "JA"
        case "KOREAN", "KO", "KOR": return "KO"
        case "SPANISH", "ES", "SPA", "LATINO", "CASTELLANO": return "ES"
        case "FRENCH", "FR", "FRA", "FRE": return "FR"
        case "GERMAN", "DE", "GER", "DEU": return "DE"
        case "ITALIAN", "IT", "ITA": return "IT"
        case "RUSSIAN", "RU", "RUS": return "RU"
        case "CHINESE", "ZH", "CHI", "ZHO": return "ZH"
        case "PORTUGUESE", "PT", "POR": return "PT"
        default: return u
        }
    }

    static let languageKeywordsAndFlags: [String: (keywords: [String], flags: [String])] = [
        "EN": (["ENGLISH", "ENG", "EN"], ["🇬🇧", "🇺🇸"]),
        "HI": (["HINDI", "HIN", "BOLLYWOOD", "DESI"], ["🇮🇳"]),
        "TAM": (["TAMIL", "TAM"], ["🇮🇳"]),
        "TEL": (["TELUGU", "TEL"], ["🇮🇳"]),
        "JA": (["JAPANESE", "JAP", "JPN", "ANIME"], ["🇯🇵"]),
        "KO": (["KOREAN", "KOR", "K-DRAMA"], ["🇰🇷"]),
        "FR": (["FRENCH", "FR", "VF", "VOSTFR", "VFF", "TRUEFRENCH"], ["🇫🇷"]),
        "ES": (["SPANISH", "SPA", "ESP", "LATINO", "CASTELLANO"], ["🇪🇸", "🇲🇽"]),
        "DE": (["GERMAN", "GER", "DEUTSCH", "DL"], ["🇩🇪"]),
        "IT": (["ITALIAN", "ITA", "ITALIANO"], ["🇮🇹"]),
        "RU": (["RUSSIAN", "RUS"], ["🇷🇺"]),
        "ZH": (["CHINESE", "CHI", "MANDARIN", "CANTONESE"], ["🇨🇳", "🇭🇰", "🇹🇼"]),
        "PT": (["PORTUGUESE", "POR", "PT-BR", "DUBLADO"], ["🇧🇷", "🇵🇹"])
    ]

    /// Checks if a stream contains or matches the user's preferred audio language,
    /// intelligently taking into account the title's original release language,
    /// flag emojis, and multi/dual audio combinations.
    func matchesPreferredLanguage(
        _ stream: Stream,
        preferred: String,
        originalLanguage: String? = nil,
        enableLanguageFilter: Bool = true
    ) -> Bool {
        // If the language filter toggle is disabled, accept all streams unconditionally
        guard enableLanguageFilter else { return true }

        let targetCode = Self.canonicalLanguageCode(preferred.isEmpty ? "ENGLISH" : preferred)
        let origCode = (originalLanguage != nil && !originalLanguage!.isEmpty) ? Self.canonicalLanguageCode(originalLanguage!) : "EN"

        let titleRaw = "\(stream.title) \(stream.cleanTitle)"
        let upperTitle = titleRaw.uppercased()
        let upperLang = (stream.language ?? "").uppercased()
        let combined = "\(upperTitle) \(upperLang)"

        // Check if stream is multi-audio / dual-audio (contains original audio + regional track)
        let isMultiOrDual = upperLang.contains("MULTI") ||
                            combined.contains("MULTI") ||
                            combined.contains("DUAL") ||
                            combined.contains("MVO") ||
                            combined.contains("DVO")

        // 1. Check for explicit keywords or country flag emojis matching target language
        let (keywords, flags) = Self.languageKeywordsAndFlags[targetCode] ?? ([targetCode], [])
        let hasFlagMatch = flags.contains { stream.title.contains($0) }
        let hasKeywordMatch = keywords.contains { kw in
            // Guard short 2-character keywords (like EN, HI, FR, ES) with boundary check
            if kw.count <= 2 {
                let pattern = #"(?i)[\.\[\(\s/_-]\#(kw)[\.\]\)\s/_-]"#
                return combined.range(of: pattern, options: .regularExpression) != nil ||
                       upperLang.components(separatedBy: ", ").contains(kw)
            } else {
                return combined.contains(kw)
            }
        }
        let hasExplicitMatch = hasFlagMatch || hasKeywordMatch

        // 2. Scenario A: The media's authentic original release language matches the target language!
        // (e.g. Hindi movie when user wants Hindi; Japanese anime when user wants Japanese; Hollywood when user wants English)
        if origCode == targetCode {
            // Hard foreign dubs that replace the original audio are disqualified
            if isForeignDub(stream.language ?? "", title: stream.title, originalLanguage: originalLanguage) {
                return false
            }
            // Standard untagged releases, Dual/Multi-audio releases, and explicitly tagged releases all contain original audio!
            return true
        }

        // 3. Scenario B: The media was originally foreign relative to target language
        // (e.g. Hollywood movie when user wants Hindi/Spanish/French; or Japanese anime when user wants English)
        if hasExplicitMatch {
            return true
        }

        // 4. Bracketed language validation: if stream has bracketed languages like [Eng+Fre] or [Hin+Eng]
        let bracketPattern = #"(?i)\[([^\]]+)\]|\(([^)]+)\)"#
        if let regex = try? NSRegularExpression(pattern: bracketPattern),
           let matches = regex.matches(in: stream.title, range: NSRange(stream.title.startIndex..., in: stream.title)) as [NSTextCheckingResult]?,
           !matches.isEmpty {
            for match in matches {
                if let range = Range(match.range, in: stream.title) {
                    let bracketContent = String(stream.title[range]).uppercased()
                    let bracketHasTarget = keywords.contains { bracketContent.contains($0) } ||
                                           flags.contains { bracketContent.contains($0) }
                    if bracketHasTarget {
                        return true
                    }
                }
            }
        }

        // 5. Multi / Dual Audio inference
        if isMultiOrDual {
            // If target is English on a foreign title (e.g. anime), Dual/Multi almost always has English dub
            if targetCode == "EN" {
                return true
            }
            // If stream originates from an Indian-focused addon (e.g. MediaFusion) or carries Indian flag,
            // Multi/Dual contains Indian regional tracks (Hindi/Tamil/Telugu)
            if (targetCode == "HI" || targetCode == "TAM" || targetCode == "TEL") &&
               (stream.source.localizedCaseInsensitiveContains("mediafusion") || stream.title.contains("🇮🇳")) {
                return true
            }
            // For major Hollywood releases, general Multi/Dual without restrictive brackets frequently includes Spanish, French, or Hindi
            if origCode == "EN" && !stream.title.contains("[") {
                return true
            }
        }

        return false
    }

    /// True when the release is a hard foreign DUB (no original audio advertised).
    /// Multi-audio releases that include original audio are not penalized.
    private func isForeignDub(_ lang: String, title: String, originalLanguage: String? = nil) -> Bool {
        let upperTitle = title.uppercased()
        let upperLang = lang.uppercased()

        // If explicitly tagged Original Audio, Multi, or Dual, it is not a hard dub
        if upperLang.contains("ORIGINAL") || upperLang.contains("MULTI") ||
           upperTitle.contains("DUAL") || upperTitle.contains("MULTI") ||
           upperTitle.contains("ORIG AUD") || upperTitle.contains("ORIGINAL") {
            return false
        }

        // If release explicitly tags the media's original native language, it is not a foreign dub
        let origCode = (originalLanguage != nil && !originalLanguage!.isEmpty) ? Self.canonicalLanguageCode(originalLanguage!) : "EN"
        if let (keywords, flags) = Self.languageKeywordsAndFlags[origCode] {
            let hasFlag = flags.contains { title.contains($0) }
            let tokens = upperTitle.components(separatedBy: CharacterSet.alphanumerics.inverted)
            let hasKw = keywords.contains { kw in
                if kw.count <= 2 {
                    return tokens.contains(kw) || upperLang.components(separatedBy: ", ").contains(kw)
                } else {
                    return upperTitle.contains(kw) || upperLang.contains(kw)
                }
            }
            if hasFlag || hasKw {
                return false
            }
        }

        let dubMarkers = ["DUBBED", "DUBBING", "TRUEFRENCH", "VOSTFR", "VFF"]
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

    /// Startup Speed Score (SSS): Estimates time-to-first-playable-byte.
    /// Higher = faster initial playback startup.
    func computeStartupSpeedScore(_ stream: Stream) -> Double {
        // Direct / Debrid HTTP streams are instant (0s swarm handshake)
        if !stream.isTorrent {
            return 10000.0
        }

        // Defensively handle missing or zero seeders (cannot be Fast Start)
        guard let seeders = stream.seeders, seeders > 0 else {
            return 0.0
        }

        let seedCount = Double(seeders)
        let sizeGB = stream.parsedSizeInGB ?? 2.5 // fallback to standard 2.5GB if size unparseable

        // Size penalty: heavily penalize massive 40GB+ remuxes, reward compact streams
        let sizePenalty: Double
        if sizeGB <= 1.5 {
            sizePenalty = 0.8 // very fast to buffer
        } else if sizeGB <= 4.0 {
            sizePenalty = 1.0 // standard sweet spot
        } else if sizeGB <= 10.0 {
            sizePenalty = 1.6
        } else {
            sizePenalty = max(2.5, sizeGB / 4.0) // heavy penalty for 20-50GB remuxes
        }

        // Container modifier:
        // MKV: SeekHead is at byte 0 by spec, sequential streaming starts immediately
        // MP4 with faststart: moov atom at byte 0
        // Generic MP4/AVI: moov atom may be at file end requiring range requests
        let containerModifier: Double
        if stream.isMKV {
            containerModifier = 1.35
        } else if stream.isFastStartMP4 {
            containerModifier = 1.30
        } else if stream.containerType == "MP4" {
            containerModifier = 0.90
        } else {
            containerModifier = 0.80
        }

        // Release group bonus for known fast-encoding streaming groups & modern seedboxes
        var groupBonus = 1.0
        let combined = "\(stream.title) \(stream.cleanTitle)".uppercased()
        let knownFastGroups = ["PSA", "GALAXYRG", "YTS", "YIFY", "QXR", "NTB", "FLUX", "MEGUSTA", "PAHE", "TGX", "SMURF", "KOGI", "PLAYBD"]
        if knownFastGroups.contains(where: { combined.contains($0) }) {
            groupBonus *= 1.30
        }

        // Modern streaming WEB-DL / WEBRip releases are seeded by 24/7 unchoked data center seedboxes
        if combined.contains("WEB-DL") || combined.contains("WEBDL") || combined.contains("WEBRIP") || combined.contains("AMZN") || combined.contains("ATVP") || combined.contains("MAX") || combined.contains("DSNP") || combined.contains("NF") || combined.contains("HMAX") {
            groupBonus *= 1.25
        }

        return (seedCount / (sizeGB * sizePenalty)) * containerModifier * groupBonus
    }

    /// Evaluates if a stream qualifies for the "Fast Start" tab (< 3.5s estimated startup)
    func isFastStartStream(_ stream: Stream) -> Bool {
        if stream.isDirectHTTP { return true }
        guard let seeders = stream.seeders, seeders >= 25 else { return false }
        let sizeGB = stream.parsedSizeInGB ?? 2.5
        // Exclude massive 10GB+ remuxes from Fast Start tab
        if sizeGB > 10.0 { return false }
        return computeStartupSpeedScore(stream) >= 12.0
    }

    /// Categorizes stream into speed tier
    func speedTier(for stream: Stream) -> StartupSpeedTier {
        if stream.isDirectHTTP { return .instant }
        guard let seeders = stream.seeders, seeders >= 25 else { return .standard }
        
        let score = computeStartupSpeedScore(stream)
        let sizeGB = stream.parsedSizeInGB ?? 2.5
        if seeders >= 60 && sizeGB <= 4.0 && score >= 35.0 {
            return .instant
        } else if seeders >= 25 && sizeGB <= 10.0 && score >= 12.0 {
            return .fast
        } else {
            return .standard
        }
    }

    /// Computes a health score for the "Best Health" tab.
    /// Direct verified HTTP streams receive top tier, while torrents are scored
    /// by swarm seed count and health ratio.
    func healthScore(for stream: Stream, probeOk: Bool? = nil) -> Double {
        if stream.isDirectHTTP {
            // Delivery-reputation demotion (HostHealthTracker): origins that
            // recently cut mid-stream sink below healthy ones without any
            // manual host lists. Failures decay after 24h.
            let hostPenalty = HostHealthTracker.shared.penalty(for: stream.url.host ?? "")
            if probeOk == true {
                return 10000.0 - min(hostPenalty, 4000.0) // Verified responsive direct stream
            }
            return max(0, 3000.0 - hostPenalty) // General direct HTTP
        }
        
        let seeds = Double(stream.seeders ?? 0)
        let leechers = Double(stream.leechers ?? 1)
        let ratio = seeds / max(1.0, leechers)
        let ratioMultiplier = min(2.0, max(0.8, ratio))
        return seeds * ratioMultiplier
    }

    /// Health comparator: prioritizes swarm health (seeds / responsive CDN) over raw resolution.
    func streamHealthComparator(_ s1: Stream, _ s2: Stream, probeStatus: [String: StreamProbeResult] = [:]) -> Bool {
        let h1 = healthScore(for: s1, probeOk: probeStatus[s1.stableKey]?.ok)
        let h2 = healthScore(for: s2, probeOk: probeStatus[s2.stableKey]?.ok)
        if h1 != h2 {
            return h1 > h2
        }
        let seeds1 = s1.seeders ?? 0
        let seeds2 = s2.seeders ?? 0
        if seeds1 != seeds2 {
            return seeds1 > seeds2
        }
        return qualityScore(s1.quality) > qualityScore(s2.quality)
    }

    /// Estimates expected seconds until playback starts for a given stream.
    /// Calibrated for broadband connections down to ~20 Mbps (2.5 MB/s) to ensure
    /// healthy initial piece buffering without prematurely abandoning valid swarms.
    func estimatedStartupBudget(for stream: Stream) -> TimeInterval {
        if !stream.isTorrent {
            return 8.0 // Direct HTTP / Debrid streams (proxy handshake, redirect, and initial demuxer cache)
        }
        let score = qualityScore(stream.quality)
        let seedCount = stream.seeders ?? 0
        switch score {
        case 5: // 4K / 2160p (8MB-16MB piece + tracker announce)
            return seedCount >= 100 ? 13.0 : 16.0
        case 4: // 2K / 1440p (4MB-8MB piece)
            return seedCount >= 75 ? 10.0 : 13.0
        case 3: // 1080p (2MB-4MB piece)
            return seedCount >= 50 ? 8.5 : 11.0
        case 2: // 720p (1MB-2MB piece)
            return seedCount >= 50 ? 6.5 : 8.5
        default: // SD / 480p
            return 6.0
        }
    }

    /// Flux Mode Fast Start candidate selection:
    /// Ranks streams balancing user's preferred resolution cap, preferred audio language,
    /// startup speed score, and swarm health.
    /// Returns the optimal primary stream and an ordered list of standby fallbacks.
    func selectFastStartCandidate(
        from streams: [Stream],
        sourceMode: String,
        preferredQuality: String,
        preferredLang: String,
        originalLanguage: String? = nil,
        enableLanguageFilter: Bool = false,
        probeStatus: [String: StreamProbeResult] = [:],
        targetSeason: Int? = nil,
        targetEpisode: Int? = nil,
        targetTitle: String? = nil
    ) -> (primary: Stream?, fallbacks: [Stream]) {
        let healthy = streams.filter { stream in
            if probeStatus[stream.stableKey]?.ok == false { return false }
            return true
        }
        let pool = healthy.isEmpty ? streams : healthy

        // 1. Source mode filter
        let modeFiltered: [Stream]
        if sourceMode == "http" {
            let httpOnly = pool.filter { !$0.isTorrent }
            modeFiltered = httpOnly.isEmpty ? streams.filter { !$0.isTorrent } : httpOnly
        } else if sourceMode == "torrent" {
            let torrentOnly = pool.filter { $0.isTorrent }
            modeFiltered = torrentOnly.isEmpty ? streams.filter { $0.isTorrent } : torrentOnly
        } else {
            modeFiltered = pool
        }
        guard !modeFiltered.isEmpty else { return (nil, []) }

        // 2. Strict Resolution Cap
        let maxAllowed = qualityScore(preferredQuality)
        let qualityCapped = modeFiltered.filter { qualityScore($0.quality) <= maxAllowed }
        let qualityCandidates = qualityCapped.isEmpty ? modeFiltered : qualityCapped
        var candidates = qualityCandidates

        // 3. Strict Language Gating when language filter is enabled
        if enableLanguageFilter {
            let matchedQuality = qualityCandidates.filter {
                matchesPreferredLanguage($0, preferred: preferredLang, originalLanguage: originalLanguage, enableLanguageFilter: true)
            }
            if !matchedQuality.isEmpty {
                print("[StreamManager] 🌐 Language Filter: found \(matchedQuality.count) candidate(s) matching audio (\(preferredLang)) within quality cap")
                candidates = matchedQuality
            } else {
                let matchedAll = modeFiltered.filter {
                    matchesPreferredLanguage($0, preferred: preferredLang, originalLanguage: originalLanguage, enableLanguageFilter: true)
                }
                if !matchedAll.isEmpty {
                    print("[StreamManager] 🌐 Language Filter: found \(matchedAll.count) candidate(s) matching audio (\(preferredLang)) (outside quality cap)")
                    candidates = matchedAll
                } else {
                    // Language Inavailability Safeguard:
                    // If preferred audio is completely unavailable (e.g. niche foreign cinema or Japanese anime with no dub),
                    // gracefully fall back to original audio candidates or the general quality-capped pool!
                    if let orig = originalLanguage, !orig.isEmpty {
                        let matchedOrig = qualityCandidates.filter {
                            matchesPreferredLanguage($0, preferred: orig, originalLanguage: originalLanguage, enableLanguageFilter: true)
                        }
                        if !matchedOrig.isEmpty {
                            print("[StreamManager] 🌐 Language Filter: preferred audio (\(preferredLang)) unavailable. Falling back to original audio (\(orig))")
                            candidates = matchedOrig
                        } else {
                            print("[StreamManager] ⚠️ Language Filter: zero candidates matched (\(preferredLang)). Falling back to general pool.")
                            candidates = qualityCandidates
                        }
                    } else {
                        print("[StreamManager] ⚠️ Language Filter: zero candidates matched (\(preferredLang)). Falling back to general pool.")
                        candidates = qualityCandidates
                    }
                }
            }
        }

        // 4. Composite score calculation
        let ranked = candidates.sorted { s1, s2 in
            let score1 = computeCompositeRank(
                s1,
                preferredLang: preferredLang,
                originalLanguage: originalLanguage,
                enableLanguageFilter: enableLanguageFilter,
                probeStatus: probeStatus,
                targetSeason: targetSeason,
                targetEpisode: targetEpisode,
                targetTitle: targetTitle
            )
            let score2 = computeCompositeRank(
                s2,
                preferredLang: preferredLang,
                originalLanguage: originalLanguage,
                enableLanguageFilter: enableLanguageFilter,
                probeStatus: probeStatus,
                targetSeason: targetSeason,
                targetEpisode: targetEpisode,
                targetTitle: targetTitle
            )
            if score1 != score2 {
                return score1 > score2
            }
            return computeStartupSpeedScore(s1) > computeStartupSpeedScore(s2)
        }

        let primary = ranked.first
        let fallbacks = Array(ranked.dropFirst().prefix(4))
        return (primary, fallbacks)
    }

    private func computeCompositeRank(
        _ stream: Stream,
        preferredLang: String,
        originalLanguage: String? = nil,
        enableLanguageFilter: Bool = false,
        probeStatus: [String: StreamProbeResult],
        targetSeason: Int? = nil,
        targetEpisode: Int? = nil,
        targetTitle: String? = nil
    ) -> Double {
        var score = 0.0

        // Target title match & mismatch penalty (cross-validates underlying URL/Referer/Filename)
        if let title = targetTitle, !title.isEmpty {
            score += evaluateTitleMatch(stream: stream, targetTitle: title, originalLanguage: originalLanguage)
        }

        // Episode match & Season Pack gating for TV shows
        if targetEpisode != nil {
            score += evaluateEpisodeMatch(stream: stream, targetSeason: targetSeason, targetEpisode: targetEpisode)
        }

        // Preferred Audio Language bonus / Foreign Dub penalty (ONLY when Language Filter in Flux Mode is enabled!)
        if enableLanguageFilter {
            let matchesPrimary = matchesPreferredLanguage(stream, preferred: preferredLang, originalLanguage: originalLanguage, enableLanguageFilter: true)
            let matchesOriginal = (originalLanguage != nil && !originalLanguage!.isEmpty)
                ? matchesPreferredLanguage(stream, preferred: originalLanguage!, originalLanguage: originalLanguage, enableLanguageFilter: true)
                : false
            let isForeign = isForeignDub(stream.language ?? "", title: stream.title, originalLanguage: originalLanguage)

            if matchesPrimary {
                score += 5000.0
            } else if matchesOriginal {
                score += 2500.0
            } else if isForeign {
                score -= 3500.0
            }
        }
        // When enableLanguageFilter is false: ZERO language bias, zero language scoring, zero language penalties.

        // Direct HTTP instant bonus
        if !stream.isTorrent {
            score += 2500.0
            if probeStatus[stream.stableKey]?.ok == true {
                score += 1000.0
            }
            // MEASURED THROUGHPUT (probe race): real bytes/sec outrank any
            // metadata estimate. ≥800 KB/s sustains 1080p comfortably (+3500,
            // scaling to +5500 for multi-MB/s origins); 170–800 KB/s ramps
            // linearly; <170 KB/s cannot sustain even 480p and sinks below
            // healthy torrents (their SSS caps at +5000); hijacked origins
            // (HTML interstitials, JSON errors) are excluded outright.
            if let probe = probeStatus[stream.stableKey] {
                if probe.hijacked {
                    score -= 25000.0
                } else if let kbps = probe.throughputKBps {
                    if kbps >= 800.0 {
                        score += 3500.0 + min(2000.0, (kbps - 800.0) / 4.0)
                    } else if kbps >= 170.0 {
                        score += 1500.0 * (kbps - 170.0) / 630.0
                    } else {
                        score -= 4000.0
                    }
                }
            }
        }

        // Delivery-reputation demotion (HostHealthTracker): origins that
        // recently cut mid-stream or stalled startup sink in Flux Mode autoplay
        // ranking too (mirrors healthScore). Without this, a freshly dead host
        // keeps winning candidate #1 on every new title. Torrent/magnet hosts
        // and loopback score zero.
        score -= HostHealthTracker.shared.penalty(for: stream.url.host ?? "")

        // Startup speed score contribution. For probed HTTP streams the
        // MEASURED throughput above replaces this paper estimate entirely —
        // that is the entire point of racing: actual delivery beats advertised
        // speed, and a measured-slow origin must lose to healthy torrents no
        // matter what its tags claim (HTTP SSS caps at +5000, which previously
        // made even a trickle-speed link outrank a 200-seed swarm).
        let sss = computeStartupSpeedScore(stream)
        if stream.isTorrent || probeStatus[stream.stableKey]?.throughputKBps == nil {
            score += min(sss, 5000.0)
        }

        // Quality tier bonus (higher quality within allowed cap gets strong weighting)
        score += Double(qualityScore(stream.quality)) * 500.0

        // Seed health bonus
        if let seeders = stream.seeders {
            score += Double(min(seeders, 300)) * 4.0
        }

        // Dolby Vision Profile 5 penalty:
        // Prefer HDR10, Profile 8 (hybrid), or SDR streams to avoid OpenGL magenta/green tint
        if isDolbyVisionProfile5(stream) {
            score -= 5000.0
        }

        // Size sanity: intros, promos, reviews and song reels are tiny.
        // A sub-50MB "episode" or sub-150MB "movie" that ADVERTISES its size
        // is near-certain wrong content (only when size is actually known —
        // unknown sizes are never punished).
        if !stream.isTorrent, let sizeGB = stream.parsedSizeInGB {
            let isJunkSized = (targetEpisode != nil && sizeGB < 0.05)
                || (targetEpisode == nil && sizeGB < 0.15)
            if isJunkSized {
                score -= 8000.0
            }
        }

        // Source fidelity tiers (Flux-mode autoplay): pristine studio sources
        // (BluRay/REMUX/WEB-DL/WEBRip) outrank broadcast rips; cams /
        // telesyncs / screeners sink but are never excluded (early releases
        // often exist ONLY as cams and must stay playable).
        score += sourceFidelityAdjustment(stream)

        return score
    }

    /// Source fidelity adjustment from scene provenance tags.
    /// Provenance ladder (researched scene consensus, best -> worst):
    /// REMUX/BluRay/BDRip (disc-sourced) > WEB-DL (lossless stream rip) >
    /// WEBRip/BRRip (re-encoded, 2nd-gen) > HDRip/HDTV/PDTV (broadcast
    /// captures/transcodes) > DVDRip > untagged > CAM/TS/TC/SCR (cams).
    /// Pristine checked FIRST so a title word like "Cam" (2018) can never
    /// demote a genuine WEB-DL (true cams never carry studio-source tags).
    /// Boundaries are alphanumeric lookarounds rather than \b (underscores
    /// are word chars, so \b never fires inside Movie_2024_WEB_DL_x264).
    /// Viability gate on all positive tiers: tags alone must not elect a
    /// sluggish giant (e.g. a 45GB REMUX on 15 seeds). Direct HTTP is always
    /// viable; torrents need a healthy swarm (>= 25 seeds, the codebase's own
    /// Fast-Start health threshold). Cams are demoted unconditionally but
    /// never excluded, so cam-only early releases stay playable.
    func sourceFidelityAdjustment(_ stream: Stream) -> Double {
        let text = "\(stream.title) \(stream.cleanTitle)"
        // Custom boundaries (not \b): underscores are word chars, so \b never
        // fires inside Movie_2024_WEB_DL_x264. Alphanumeric lookarounds treat
        // dots/spaces/hyphens/underscores/parens uniformly as separators.
        func has(_ core: String) -> Bool {
            let pattern = "(?<![A-Za-z0-9])" + core + "(?![A-Za-z0-9])"
            return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        // SEP matches the separators scene/P2P names actually use between tag
        // parts: dots (Movie.1080p.WEB-DL), spaces, hyphens, underscores.
        // Only separator chars may sit between parts, so "WEB.H264.DL" (German
        // DL track tag) can never match while "WEB DL"/"WEB_DL" still do.
        let viable = !stream.isTorrent || (stream.seeders ?? 0) >= 25
        let disc = [#"REMUX"#, #"BLU[\s.\-_]*RAY"#, #"BDREMUX"#, #"BDRIP"#]
        if disc.contains(where: has) { return viable ? 3000.0 : 0.0 }
        let webdl = [#"WEB[\s.\-_]*DL"#]
        if webdl.contains(where: has) { return viable ? 2500.0 : 0.0 }
        let webrip = [#"WEBRIP"#, #"BRRIP"#]
        if webrip.contains(where: has) { return viable ? 2000.0 : 0.0 }
        let broadcast = [#"HDRIP"#, #"HDTV"#, #"PDTV"#, #"DSRIP"#,
                         #"SATRIP"#, #"TVRIP"#, #"DVBRIP"#, #"WEBCAP"#]
        if broadcast.contains(where: has) { return viable ? 1000.0 : 0.0 }
        if has(#"DVDRIP"#) { return viable ? 500.0 : 0.0 }
        let cam = [#"CAM(RIP)?"#, #"HDCAM"#, #"HQCAM"#, #"HDTS"#,
                   #"HDTC"#, #"HDCINEMA"#, #"TELESYNC"#, #"TELECINE"#,
                   #"DVD[\s.\-_]*SCR"#, #"BDSCR"#, #"SCREENER"#,
                   #"WEBSCREENER"#, #"SCR"#, #"R5"#,
                   #"TS"#, #"TC"#]
        if cam.contains(where: has) { return -4000.0 }
        return 0.0
    }

    /// Evaluates how well a stream matches an episodic query (targetSeason, targetEpisode).
    /// Returns a score adjustment (bonus or severe penalty for wrong episode / season pack).
    func evaluateEpisodeMatch(
        stream: Stream,
        targetSeason: Int?,
        targetEpisode: Int?
    ) -> Double {
        guard let targetEp = targetEpisode else { return 0.0 }
        let s = targetSeason ?? 1
        let text = "\(stream.cleanTitle) \(stream.title)"

        // 1. Season Pack Check:
        // A direct HTTP stream that is a season pack CANNOT select individual episodes
        // and starts from byte 0 (usually Episode 1), playing the entire multi-hour compilation.
        if stream.isSeasonPack {
            if !stream.isTorrent {
                return -20000.0 // Disqualify HTTP season pack for episodic query
            } else if stream.fileIdx == nil {
                return -15000.0 // Disqualify torrent season pack if it lacks fileIdx
            } else {
                return -500.0 // Torrent with valid fileIdx is usable, slight tie-breaker
            }
        }

        // 2. Exact Episode Pattern Matches:
        // S01E02, S1E2, S01.E02, S01_E02, 1x02, 01x02, E02, EP02, EP.02, Episode 2, Episode 02
        let exactPatterns = [
            #"(?i)\bS0*"# + "\(s)" + #"[\.\s_-]*E0*"# + "\(targetEp)" + #"\b"#,
            #"(?i)\b0*"# + "\(s)" + #"x0*"# + "\(targetEp)" + #"\b"#,
            #"(?i)\bE0*"# + "\(targetEp)" + #"(?!\d)"#,
            #"(?i)\bEP[\.\s_-]*0*"# + "\(targetEp)" + #"(?!\d)"#,
            #"(?i)\bEpisode[\.\s_-]*0*"# + "\(targetEp)" + #"(?!\d)"#
        ]

        var hasExactMatch = false
        for pattern in exactPatterns {
            if text.range(of: pattern, options: .regularExpression) != nil {
                hasExactMatch = true
                break
            }
        }

        if hasExactMatch {
            return 3500.0 // Strong reward for explicitly verified target episode
        }

        // 3. Wrong Episode Check:
        // Does the stream explicitly name a DIFFERENT episode?
        // e.g. target is Episode 2, but stream is S01E01, 1x01, E01, Episode 1.
        let wrongEpisodePatterns = [
            #"(?i)\bS0*"# + "\(s)" + #"[\.\s_-]*E(\d{1,3})\b"#,
            #"(?i)\b0*"# + "\(s)" + #"x(\d{1,3})\b"#,
            #"(?i)\bE(\d{1,3})(?!\d)"#,
            #"(?i)\bEP[\.\s_-]*(\d{1,3})(?!\d)"#,
            #"(?i)\bEpisode[\.\s_-]*(\d{1,3})(?!\d)"#
        ]

        for p in wrongEpisodePatterns {
            if let regex = try? NSRegularExpression(pattern: p),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range(at: 1), in: text),
               let epNum = Int(text[range]), epNum != targetEp {
                return -25000.0 // Severe penalty: wrong episode release
            }
        }

        // 4. HTTP stream with no episode indicators in an episodic query:
        // Often a show trailer, promo, or unparsed season dump.
        if !stream.isTorrent {
            return -5000.0
        }

        return 0.0
    }

    /// Evaluates title consistency between the target media and the underlying stream URL / Referer header / release filename.
    /// Returns a strong bonus if target title is confirmed, or a severe disqualifying penalty (-30,000.0)
    /// if an English release explicitly points to a different, conflicting title (e.g. "Head Over Heels" for "Overflow").
    /// Opaque CDN tokens and foreign releases (where release names use native/romanized titles) are never penalized.
    /// Shared junk-brand detector for scraper labels (stream.title + stream.source).
    /// Deliberately SEPARATE from the filename junkTokens: adds "dubbed",
    /// "hindi-dub" style label brandings and streaming-brand noise that only
    /// ever appears in scraper display labels, never in release filenames.
    /// Returns true if any junk-brand token appears in the label that is not
    /// also a word of the target title (so "Trailer Park Boys" stays safe).
    public static func labelLooksLikeJunk(labelText: String, targetTitle: String?) -> Bool {
        let labelJunkTokens: Set<String> = [
            "moviebox", "review", "recap", "explained", "trailer", "teaser", "promo", "promos",
            "intro", "outro", "reaction", "unboxing", "breakdown", "clip", "clips",
            "sample", "shorts", "preview", "compilation", "interview", "jukebox", "songs"
        ]
        guard !labelText.isEmpty else { return false }
        let cleaned = labelText.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]", with: " ", options: .regularExpression)
        let words = Set(cleaned.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
        guard !words.isEmpty else { return false }
        let targetWords: Set<String> = {
            guard let t = targetTitle, !t.isEmpty else { return [] }
            return Set(t.lowercased()
                .replacingOccurrences(of: "[^a-z0-9]", with: " ", options: .regularExpression)
                .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
        }()
        return !words.intersection(labelJunkTokens).subtracting(targetWords).isEmpty
    }

    func evaluateTitleMatch(stream: Stream, targetTitle: String?, originalLanguage: String? = nil) -> Double {
        guard let rawTarget = targetTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTarget.isEmpty else {
            return 0.0
        }

        let stopwords: Set<String> = [
            "the", "a", "an", "and", "or", "of", "in", "on", "at", "to", "for", "with",
            "by", "from", "up", "about", "into", "over", "after", "is", "it", "this", "that"
        ]

        func extractMeaningfulTokens(_ text: String) -> [String] {
            let lower = text.lowercased()
            let cleaned = lower.replacingOccurrences(of: "[^a-z0-9]", with: " ", options: .regularExpression)
            return cleaned.components(separatedBy: .whitespacesAndNewlines)
                .filter { $0.count >= 2 && !stopwords.contains($0) && Int($0) == nil }
        }

        let targetTokens = extractMeaningfulTokens(rawTarget)
        guard !targetTokens.isEmpty else { return 0.0 }

        // Gather candidate filenames/slugs from release filename, media filename in URL, and Referer header
        var candidateStrings: [String] = []

        if let fn = stream.filename, !fn.isEmpty {
            candidateStrings.append(fn)
        }

        // Addon label + source name feed ONLY the junk scan (below) — they are
        // scraper-provided labels, so they must not influence conflict logic,
        // but junk brands hide there: scrapers label promos like
        // "Coyote vs Acme (2026) MovieBox promo trailer" while the URL is an
        // un-analyzable opaque CDN token. Without this the junk scan passed
        // vacuously and the MovieBox trailer won the seat on speed alone.
        // (Target-title subtraction still protects shows genuinely named
        // "Trailer Park Boys" etc.)
        let labelScanText = "\(stream.title) \(stream.source)"

        func isOpaqueToken(_ text: String) -> Bool {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return true }
            // Media extensions and release space encodings are never opaque tokens
            if trimmed.contains(".mkv") || trimmed.contains(".mp4") || trimmed.contains(".avi") ||
               trimmed.contains("-20-") || trimmed.contains("-20") || trimmed.contains("%20") {
                return false
            }
            let lower = trimmed.lowercased()
            if lower.contains("1080p") || lower.contains("720p") || lower.contains("2160p") || lower.contains("web-dl") || lower.contains("bluray") {
                return false
            }
            // If the text contains separators (- or _ or .), check if the chunks look like words or hash fragments
            let chunks = trimmed.components(separatedBy: CharacterSet(charactersIn: "-_."))
                .filter { !$0.isEmpty }
            if chunks.count > 1 {
                // If chunks contain words with purely letters of length >= 3 (e.g. "head", "over", "heels", "season")
                let wordChunks = chunks.filter { chunk in
                    chunk.count >= 3 &&
                    chunk.rangeOfCharacter(from: .letters) != nil &&
                    chunk.rangeOfCharacter(from: .decimalDigits) == nil
                }
                if wordChunks.count >= 2 {
                    return false // Human-readable slug with actual words
                }
            }
            // Cryptographic session hashes, CDN tokens, or high-entropy hex/base64 strings (e.g. aJFpjFS15-94WhTt...)
            let hasLetters = trimmed.rangeOfCharacter(from: .letters) != nil
            let hasDigits = trimmed.rangeOfCharacter(from: .decimalDigits) != nil
            if trimmed.count >= 20 && hasLetters && hasDigits && !trimmed.contains(" ") {
                return true
            }
            if trimmed.count > 28 && !trimmed.contains(" ") && !trimmed.contains("-") && !trimmed.contains(".") {
                return true
            }
            return false
        }

        func extractFilenameOrSlug(from urlString: String) {
            // Magnet URIs: extract display name 'dn' parameter
            if urlString.hasPrefix("magnet:") {
                if let components = URLComponents(string: urlString),
                   let dn = components.queryItems?.first(where: { $0.name == "dn" })?.value {
                    candidateStrings.append(dn)
                }
                return
            }

            guard let url = URL(string: urlString) else {
                if let lastSlash = urlString.components(separatedBy: "/").last, !lastSlash.isEmpty {
                    let cleaned = lastSlash.components(separatedBy: "?").first ?? lastSlash
                    if !isOpaqueToken(cleaned) {
                        candidateStrings.append(cleaned)
                    }
                }
                return
            }

            // Proxied URLs: unwrap underlying target url
            if url.path.contains("/proxy") {
                if let components = URLComponents(string: urlString),
                   let rawTargetURL = components.queryItems?.first(where: { $0.name == "url" })?.value {
                    extractFilenameOrSlug(from: rawTargetURL)
                }
                return
            }

            let lastComponent = url.lastPathComponent
            if !lastComponent.isEmpty && lastComponent != "/" && !isOpaqueToken(lastComponent) {
                candidateStrings.append(lastComponent)
            }
        }

        extractFilenameOrSlug(from: stream.url.absoluteString)

        if let ref = stream.proxyHeaders?["Referer"] ?? stream.proxyHeaders?["referer"] {
            if let refURL = URL(string: ref) {
                let slug = refURL.lastPathComponent
                if !slug.isEmpty && slug != "/" && !isOpaqueToken(slug) {
                    candidateStrings.append(slug)
                }
            } else {
                if let lastSlash = ref.components(separatedBy: "/").last, !lastSlash.isEmpty {
                    let cleaned = lastSlash.components(separatedBy: "?").first ?? lastSlash
                    if !isOpaqueToken(cleaned) {
                        candidateStrings.append(cleaned)
                    }
                }
            }
        }

        // Noise tokens (file extensions, codecs, release groups, resolutions, quality tags, common release tags, scraper provider tags)
        let noiseTokens: Set<String> = [
            "mkv", "mp4", "avi", "mov", "webm", "ts", "m3u8",
            "1080p", "720p", "2160p", "480p", "360p", "4k", "2k", "uhd", "fhd", "hd", "sd",
            "x264", "x265", "h264", "h265", "hevc", "avc", "av1", "aac", "ac3", "eac3", "dts", "flac", "ddp", "atmos",
            "webdl", "webrip", "bluray", "brrip", "bdrip", "hdtv", "dvdrip", "remux", "hdr", "dv", "sdr",
            "hindi", "english", "dual", "audio", "dub", "dubbed", "esub", "sub", "subs", "multisubs",
            "cinefreak", "cinefreaktop", "top", "yts", "psa", "rartv", "eztv", "galaxy", "tgx", "ettv",
            "2peckle", "peckle", "vidfast", "vedge", "kisskh", "vidlink", "cinejoy", "vidsrc", "autoembed", "superembed", "embed", "stream", "server", "shegu", "lb03", "external", "direct", "pad",
            "amazon", "netflix", "hotstar", "zee5", "gdrive", "download", "watch", "online", "series", "web", "korean", "anime",
            "tv", "original", "repack", "proper", "internal", "complete", "season", "episode", "ep", "part", "vol", "volume"
        ]

        var sawExplicitConflict = false
        var sawTargetConfirmation = false
        // Promo/review/intro-style uploads masquerading as the title (MovieBox
        // intros, YouTube reviews and song reels behind CDN tokens). A junk
        // word in the release text that is NOT part of the target title is a
        // near-certain wrong-content signal in ANY language — it must outrank
        // the foreign-title immunity below.
        let junkTokens: Set<String> = [
            "review", "recap", "explained", "trailer", "teaser", "promo", "promos",
            "intro", "outro", "opening", "ending", "reaction", "unboxing", "breakdown",
            "clip", "clips", "sample", "shorts", "preview", "compilation", "interview",
            "easter", "egg", "eggs", "moviebox", "sneak", "peek", "song", "songs", "jukebox"
        ]
        var junkInTitlePortion = false
        var junkAfterTitlePortion = false

        for text in candidateStrings {
            // Unescape percent-encoding and separators
            let rawUnescaped = text.removingPercentEncoding ?? text
            let unescaped = rawUnescaped
                .replacingOccurrences(of: #"(?i)(?:-20-|-20|%20)"#, with: " ", options: .regularExpression)

            // In release filenames/slugs, the media title is located BEFORE the season/episode pattern,
            // year, or resolution tag (e.g. "CINEFREAK.TOP - Head Over Heels - S01E02..." -> "CINEFREAK.TOP - Head Over Heels")
            var titlePortion = unescaped
            let boundaryPatterns = [
                #"(?i)[\._\s-](s\d{1,2}[\._\s-]?e\d{1,3}|\d{1,2}x\d{1,3}|ep?\d{1,3}|season[\._\s-]?\d{1,2})"#,
                #"(?i)[\._\s-](19\d\d|20\d\d)(?!p|\d)"#,
                #"(?i)[\._\s-](2160p|1080p|720p|480p|4k|2k|uhd|fhd)"#
            ]
            for pattern in boundaryPatterns {
                if let range = titlePortion.range(of: pattern, options: .regularExpression) {
                    titlePortion = String(titlePortion[..<range.lowerBound])
                    break
                }
            }

            let normalized = titlePortion
                .replacingOccurrences(of: "[-_\\.\\+\\/\\?&=#]", with: " ", options: .regularExpression)
                .lowercased()

            // Junk scan over the FULL text (episode titles legitimately sit
            // after the S/E marker, so junk found there is only a soft signal,
            // while junk inside the title portion is near-certain).
            let fullWords = Set(unescaped
                .replacingOccurrences(of: "[-_\\.\\+\\/\\?&=#]", with: " ", options: .regularExpression)
                .lowercased()
                .components(separatedBy: .whitespacesAndNewlines))
            let fullJunk = fullWords.intersection(junkTokens).subtracting(targetTokens)
            if !fullJunk.isEmpty { junkAfterTitlePortion = true }

            let rawWords = normalized.components(separatedBy: .whitespacesAndNewlines)
                .filter { word in
                    guard word.count >= 2, !stopwords.contains(word), !noiseTokens.contains(word), Int(word) == nil else { return false }
                    // Filter out alphanumeric hash fragments (e.g. 94whtt, ajfpjfs15)
                    if word.count > 18 { return false }
                    let hasL = word.rangeOfCharacter(from: .letters) != nil
                    let hasD = word.rangeOfCharacter(from: .decimalDigits) != nil
                    if hasL && hasD { return false }
                    if word.range(of: #"^(s\d+e\d+|\d+x\d+|e\d+|ep\d+)$"#, options: .regularExpression) != nil { return false }
                    return true
                }

            guard !rawWords.isEmpty else { continue }

            // Junk words inside the title portion (before S/E / year /
            // resolution markers) — the strongest wrong-content signal.
            let titleJunk = Set(rawWords).intersection(junkTokens).subtracting(targetTokens)
            if !titleJunk.isEmpty { junkInTitlePortion = true }

            // Check if any target token is present in the title portion
            let matchesTarget = targetTokens.contains { tToken in
                rawWords.contains(where: { $0 == tToken })
            }

            if matchesTarget {
                sawTargetConfirmation = true
            } else {
                // If the title portion has 2 or more distinct words (e.g. ["head", "heels"])
                // and none of the target keywords are present, this candidate is an explicitly different show!
                let distinctWords = Set(rawWords)
                if distinctWords.count >= 2 {
                    sawExplicitConflict = true
                }
            }
        }

        // Junk-content demotion outranks everything below: a "review" or
        // "intro" upload must never win a seat regardless of language or
        // confirmed title tokens ("3 Idiots Review" confirms the target —
        // and is still not the movie).
        if junkInTitlePortion { return -15000.0 }
        if junkAfterTitlePortion { return -6000.0 }

        // Scraper-label junk scan (stream.title + stream.source ONLY):
        // scrapers brand promos like "Coyote vs. Acme (2026) MovieBox promo
        // trailer" while the URL is an un-analyzable opaque CDN token — the
        // filename-based scans above then pass vacuously and the junk wins on
        // speed. Target-title words are still subtracted, so a source genuinely
        // named after the show is untouched; junk brands in the label are a
        // near-certain wrong-content signal in any language.
        if StreamManager.labelLooksLikeJunk(labelText: labelScanText, targetTitle: rawTarget) {
            return -15000.0
        }

        // Foreign titles (Anime, Bollywood/regional, K-drama, European cinema) use original/romanized
        // names in releases (e.g. "Kimetsu no Yaiba", "Hey Sinamika", "Chup", "Sarangui Bulsichak").
        // These will naturally differ from TMDB English titles — NEVER disqualify them with a -30,000 penalty!
        let isForeignTitle = originalLanguage != nil && !originalLanguage!.isEmpty && originalLanguage!.lowercased() != "en"
        if isForeignTitle {
            return sawTargetConfirmation ? 1500.0 : 0.0
        }

        if sawExplicitConflict && !sawTargetConfirmation {
            // Severe disqualification penalty: the underlying stream/referer explicitly points to another English show!
            return -30000.0
        }

        if sawTargetConfirmation {
            return 1500.0
        }

        return 0.0
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
        request.timeoutInterval = StreamManager.isHttpSource(sourceName) ? 22 : 12
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await self.session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                return []
            }

            // Strict decode first; fall back to per-element salvage so a single
            // malformed stream object can't wipe out the whole addon response.
            let decodedStreams: [StremioStream]
            do {
                decodedStreams = try JSONDecoder().decode(StremioResponse.self, from: data).streams
            } catch {
                print("[\(sourceName)] Strict decode failed (\(error)); salvaging individual streams")
                decodedStreams = StremioResponse.tolerantStreams(from: data)
            }
            let streams = decodedStreams.compactMap { stream -> Stream? in
                // Protocol-compliant URL resolution: url → ytId → infoHash → externalUrl
                var targetURLString = stream.url

                // YouTube ID → construct YouTube URL
                if targetURLString == nil || targetURLString == "about:blank" {
                    if let ytId = stream.ytId {
                        targetURLString = "https://www.youtube.com/watch?v=\(ytId)"
                    }
                }

                // Torrent infoHash → magnet URI
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

                // externalUrl (e.g. Netflix links, external players)
                if (targetURLString == nil || targetURLString == "about:blank") {
                    if let extUrl = stream.externalUrl {
                        targetURLString = extUrl
                    }
                }

                // Torrent identity survives even when a direct `url` wins below
                // (debrid-cached links ship both). Also harvest dht: entries.
                var torrentHash: String? = stream.infoHash
                if torrentHash == nil, let sources = stream.sources {
                    for entry in sources {
                        let candidate: String
                        if entry.lowercased().hasPrefix("dht:") {
                            candidate = String(entry.dropFirst(4))
                        } else if entry.count == 40, entry.allSatisfy({ $0.isHexDigit }) {
                            candidate = entry
                        } else {
                            continue
                        }
                        if !candidate.isEmpty { torrentHash = candidate; break }
                    }
                }

                guard var finalURLStr = targetURLString, finalURLStr != "about:blank" else { return nil }
                if !finalURLStr.starts(with: "magnet:") && !finalURLStr.starts(with: "https://www.youtube.com") {
                    finalURLStr = normalizeAddonURL(finalURLStr)
                }
                // File-host links sometimes contain spaces or unicode — retry percent-encoded.
                var streamUrl = URL(string: finalURLStr)
                if streamUrl == nil, let encoded = finalURLStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                    streamUrl = URL(string: encoded)
                }
                guard let streamUrl = streamUrl else { return nil }

                let rawTitle = stream.description ?? stream.title ?? stream.name ?? "Unknown Stream"
                let nameHeader = stream.name ?? ""
                let combinedTitle = "\(nameHeader) \(rawTitle)"
                let lowerCheck = "\(combinedTitle) \(finalURLStr)".lowercased()
                if lowerCheck.contains("sign in") || lowerCheck.contains("signin") ||
                   lowerCheck.contains("log in") || lowerCheck.contains("login") ||
                   lowerCheck.contains("authenticate") || lowerCheck.contains("unauthorized") ||
                   lowerCheck.contains("access denied") || lowerCheck.contains("account required") {
                    print("[\(sourceName)] Ignoring auth wall / placeholder banner: \(rawTitle)")
                    return nil
                }
                let quality = parseQuality(name: nameHeader, title: rawTitle, filename: stream.behaviorHints?.filename)
                let size = parseSize(from: rawTitle) ?? formatVideoSize(stream.behaviorHints?.videoSize)
                let language = parseLanguage(from: combinedTitle)
                let codec = parseCodec(from: combinedTitle)
                let bitrate = parseBitrate(from: combinedTitle)
                let subtitles = parseSubtitles(from: combinedTitle)
                let seeders = parseSeeders(from: rawTitle)
                let leechers = parseLeechers(from: rawTitle)
                let clean = cleanTitleString(name: nameHeader, title: rawTitle)
                let indexer = Self.parseIndexer(name: nameHeader, title: rawTitle)

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
                    codec: codec,
                    bitrate: bitrate,
                    subtitles: subtitles,
                    seeders: seeders,
                    leechers: leechers,
                    fileIdx: stream.fileIdx,
                    isSeasonPack: detectSeasonPack(name: nameHeader, title: rawTitle),
                    proxyHeaders: headers,
                    infoHash: torrentHash,
                    indexer: indexer,
                    filename: stream.behaviorHints?.filename
                )
            }
            print("[\(sourceName)] Found \(streams.count) streams")
            return streams
        } catch {
            print("[\(sourceName)] Error: \(error)")
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

    /// Normalizes and cleans raw addon/provider names for uniform UI display.
    static func cleanProviderName(_ source: String) -> String {
        let lower = source.lowercased()
        if lower.contains("webstreamrmbg") || lower.contains("webstreamr-mbg") { return "WebStreamrMBG" }
        if lower.contains("webstream") { return "WebStreamr" }
        if lower.contains("pengu") { return "PenguPlay" }
        if lower.contains("torrentio") { return "Torrentio" }
        if lower.contains("mediafusion") { return "MediaFusion" }
        if lower.contains("comet") { return "Comet" }
        if lower.contains("meteor") { return "Meteor" }
        if lower.contains("stremify") { return "Stremify" }
        if lower.contains("knightcrawler") { return "KnightCrawler" }
        if lower.contains("easydebrid") { return "EasyDebrid" }
        if lower.contains("aiostreams") { return "AIOStreams" }
        var s = source
        s = s.replacingOccurrences(of: #"(?i)\s*\[.*?\]"#, with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? source : s
    }

    /// Extracts origin release source or indexer (e.g. 1337x, YTS, TorrentGalaxy, Server 1).
    static func parseIndexer(name: String, title: String) -> String? {
        let combined = "\(name)\n\(title)"

        // 1. Emoji gear indexer (e.g. "⚙️ 1337x", "⚙️ YTS", "⚙️ TorrentGalaxy")
        if let match = combined.range(of: #"[⚙️⚙]\s*([^\n\r•]+)"#, options: .regularExpression) {
            let raw = String(combined[match]).replacingOccurrences(of: #"[⚙️⚙]\s*"#, with: "", options: .regularExpression)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        // 2. Explicit prefix (e.g. "Indexer: 1337x", "Provider: Vidcloud", "Source: Server 1")
        if let match = combined.range(of: #"(?i)\b(?:indexer|provider|source):\s*([^\n\r•]+)"#, options: .regularExpression) {
            let raw = String(combined[match]).replacingOccurrences(of: #"(?i)\b(?:indexer|provider|source):\s*"#, with: "", options: .regularExpression)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        // 3. Bracketed server (e.g. "[Server 1]", "[StreamWish]")
        if let match = title.range(of: #"(?i)\[(Server\s*\d+|StreamWish|DoodStream|FileLions|Vidcloud|UpCloud|MixDrop)\]"#, options: .regularExpression) {
            let raw = String(title[match]).replacingOccurrences(of: #"(\[|\])"#, with: "", options: .regularExpression)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        return nil
    }

    /// Strips multi-line scraper metadata and emoji clutter, returning a clean full release title.
    static func cleanReleaseTitle(title: String?, cleanTitle: String? = nil, itemTitle: String? = nil) -> String {
        let raw = title ?? ""

        // Split by lines and take the first line that isn't purely metadata (emojis, seeders, size)
        let lines = raw.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        var primaryLine: String?
        for line in lines {
            if line.range(of: #"^\d+(\.\d+)?\s*(gb|mb|tb|b)$"#, options: [.regularExpression, .caseInsensitive]) != nil { continue }
            if line.range(of: #"^[👤👥💾⚙️⚙•\s\d]+(seeds?|gb|mb|tb)?$"#, options: [.regularExpression, .caseInsensitive]) != nil { continue }
            if line.hasPrefix("👤") || line.hasPrefix("💾") || line.hasPrefix("⚙️") { continue }
            primaryLine = line
            break
        }

        var candidate = primaryLine ?? cleanTitle ?? raw

        // Strip trailing metadata line remnants if on same line (e.g. "Movie.1080p.x264 👤 200")
        if let emojiRemnant = candidate.range(of: #"\s*[👤👥💾⚙️⚙].*$"#, options: .regularExpression) {
            candidate = String(candidate[..<emojiRemnant.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // If candidate is very short or generic (e.g. "1080p", "Server 1", "Unknown Stream"), enrich with itemTitle
        let lower = candidate.lowercased()
        if candidate.count <= 10 || lower == "1080p" || lower == "720p" || lower == "4k" || lower == "unknown stream" || lower.hasPrefix("server") {
            if let it = itemTitle, !it.isEmpty {
                return candidate.isEmpty || lower == "unknown stream" ? it : "\(it) • \(candidate)"
            }
        }

        return candidate.isEmpty ? (itemTitle ?? "Unknown Source") : candidate
    }

    private func cleanTitleString(name: String, title: String) -> String {
        // Strip emojis from both name and title
        let emojiPattern = #"[\u{1F000}-\u{1FFFF}\u{2600}-\u{27BF}\u{2300}-\u{23FF}\u{FE0F}\u{200D}]"#
        let cleanRaw = title.replacingOccurrences(of: emojiPattern, with: " ", options: .regularExpression)
        
        // 1. Process line by line
        let lines = cleanRaw.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        
        var meaningfulSegments: [String] = []
        for line in lines {
            var l = line
            // Skip lines that are purely file size (e.g. "5.98 GB" or "77.48 GB")
            if l.range(of: #"^\d+(\.\d+)?\s*(gb|mb|tb|b)$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                continue
            }
            // Skip lines that are purely seeder info (e.g. "450 seeds" or "450")
            if l.range(of: #"^\d+\s*seeds?$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                continue
            }
            // Strip embedded pure file size strings (e.g. "• 5.98 GB")
            l = l.replacingOccurrences(of: #"\b\d+(\.\d+)?\s*(GB|MB|TB)\b"#, with: "", options: [.regularExpression, .caseInsensitive])
            // Strip standalone addon branding words
            l = l.replacingOccurrences(of: #"\b(torrentio|stremio|penguplay|webstreamrmbg|meteor|comet)\b"#, with: "", options: [.regularExpression, .caseInsensitive])
            // Strip "Source:" prefix
            l = l.replacingOccurrences(of: #"(?i)\bSource:\s*"#, with: "", options: .regularExpression)
            
            let trimmed = l.trimmingCharacters(in: CharacterSet(charactersIn: " •\t-|/"))
            if !trimmed.isEmpty {
                meaningfulSegments.append(trimmed)
            }
        }
        
        // If all lines were filtered out, fall back to the original title
        var combined = meaningfulSegments.isEmpty ? cleanRaw.replacingOccurrences(of: "\n", with: " • ") : meaningfulSegments.joined(separator: " • ")
        
        // Remove repetitive movie title & year patterns at the start (e.g. "Project Hail Mary (2026)", "Project.Hail.Mary.2026")
        combined = combined.replacingOccurrences(of: #"(?i)^[a-z0-9\s._\-]+?\s*[\(\[]?\d{4}[\)\]]?[\s._\-]*"#, with: "", options: .regularExpression)
        
        // Remove leading dots/separators
        combined = combined.replacingOccurrences(of: #"^[.\s•\-—|/]+"#, with: "", options: .regularExpression)
        
        // Clean multiple bullet/separator sequences
        combined = combined.replacingOccurrences(of: #"(\s*[•·|—/]\s*)+"#, with: " • ", options: .regularExpression)
        combined = combined.trimmingCharacters(in: CharacterSet(charactersIn: " •\t-|/"))
        
        // If cleaning resulted in an empty string, fall back to trimmed title
        if combined.isEmpty {
            combined = title.replacingOccurrences(of: "\n", with: " • ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return combined
    }
    
    func parseQuality(name: String? = nil, title: String, filename: String? = nil) -> String {
        // Stage 1: Check tokenized title and filename first for explicit release resolution.
        let combined = "\(title) \(filename ?? "")"
        
        // Neutralize misleading substrings that contain '4K' or 'HD':
        var cleaned = combined
        cleaned = cleaned.replacingOccurrences(of: #"(?i)4khdhub(\.com)?"#, with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"(?i)4khd"#, with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"(?i)hdhub"#, with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"(?i)dts-hd(\s*ma)?"#, with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"(?i)truehd"#, with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"(?i)hdr(10(\+)?)?"#, with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"(?i)\b2k\d{2}\b"#, with: " ", options: .regularExpression)

        // Exact pixel dimensions:
        if cleaned.range(of: #"\b(3840\s*[xX*]\s*2160|4096\s*[xX*]\s*2160)\b"#, options: .regularExpression) != nil {
            return "4K"
        }
        if cleaned.range(of: #"\b2560\s*[xX*]\s*1440\b"#, options: .regularExpression) != nil {
            return "2K"
        }
        if cleaned.range(of: #"\b1920\s*[xX*]\s*1080\b"#, options: .regularExpression) != nil {
            return "1080p"
        }
        if cleaned.range(of: #"\b1280\s*[xX*]\s*720\b"#, options: .regularExpression) != nil {
            return "720p"
        }

        // Standard word-bounded resolution tags in the release title:
        if cleaned.range(of: #"(?i)\b(2160p?|2160i|4k|uhd)\b"#, options: .regularExpression) != nil {
            return "4K"
        }
        if cleaned.range(of: #"(?i)\b(1440p?|1440i|2k|qhd)\b"#, options: .regularExpression) != nil {
            return "2K"
        }
        if cleaned.range(of: #"(?i)\b(1080p?|1080i|fhd)\b"#, options: .regularExpression) != nil {
            return "1080p"
        }
        if cleaned.range(of: #"(?i)\b(720p?|720i)\b"#, options: .regularExpression) != nil {
            return "720p"
        }
        if cleaned.range(of: #"(?i)\b(hd|hdtv|hdrip)\b"#, options: .regularExpression) != nil {
            return "720p"
        }
        if cleaned.range(of: #"(?i)\b(480p?|480i|576p?|576i|sd)\b"#, options: .regularExpression) != nil {
            return "480p"
        }

        // Stage 2: Fallback to addon name header lines.
        // Stremio addons (Torrentio, WebStreamr, Comet, Meteor, MediaFusion) embed their
        // authoritative, pre-parsed resolution on a line in the stream's 'name' property.
        if let name = name, !name.isEmpty {
            for line in name.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if trimmed.range(of: #"(?i)\b(2160p?|4k|uhd)\b"#, options: .regularExpression) != nil {
                    return "4K"
                }
                if trimmed.range(of: #"(?i)\b(1440p?|2k|qhd)\b"#, options: .regularExpression) != nil {
                    return "2K"
                }
                if trimmed.range(of: #"(?i)\b(1080p?|1080i|fhd)\b"#, options: .regularExpression) != nil {
                    return "1080p"
                }
                if trimmed.range(of: #"(?i)\b(720p?|720i)\b"#, options: .regularExpression) != nil {
                    return "720p"
                }
                if trimmed.range(of: #"(?i)\b(480p?|480i|576p?|576i|sd)\b"#, options: .regularExpression) != nil {
                    return "480p"
                }
            }
        }

        return "SD"
    }

    /// Convenience wrapper for backwards compatibility with tests and callers
    func parseQuality(from title: String, filename: String? = nil) -> String {
        return parseQuality(name: nil, title: title, filename: filename)
    }

    private func formatVideoSize(_ bytes: Int64?) -> String? {
        guard let b = bytes, b >= 5 * 1024 * 1024 else { return nil } // Ignore < 5MB manifests or stubs
        let gb = Double(b) / 1_073_741_824.0
        if gb >= 1.0 {
            return String(format: "%.2f GB", gb)
        } else {
            let mb = Double(b) / 1_048_576.0
            return String(format: "%.0f MB", mb)
        }
    }
    
    private func isTitleMatch(streamTitle: String, itemTitle: String) -> Bool {
        let s = streamTitle.lowercased()
        let t = itemTitle.lowercased()
        return s.contains(t) || t.contains(s)
    }
    
    func parseSize(from title: String) -> String? {
        // Enforce word boundaries and exclude bitrate units (Mbps, Mb/s) so bitrates
        // (~4.7 Mbps) are never mistaken for file sizes (4.7 MB). Supports GiB, MiB, TB, TiB.
        let pattern = #"(?i)(\d+(?:\.\d+)?)\s*(TB|GB|MB|TiB|GiB|MiB)\b(?!ps|/s|b/s)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = title as NSString
        let matches = regex.matches(in: title, range: NSRange(location: 0, length: ns.length))

        func extractValidSize(from match: NSTextCheckingResult) -> String? {
            guard match.numberOfRanges > 1 else { return nil }
            let numStr = ns.substring(with: match.range(at: 1))
            guard let val = Double(numStr), val > 0.0 else { return nil }
            return ns.substring(with: match.range)
        }

        // Prefer the size tagged with a disk/size marker (💾), else the LAST match —
        // addons like Torrentio put the authoritative size at the end of the title.
        for m in matches.reversed() {
            let lowerBound = max(0, m.range.location - 2)
            let prefix = ns.substring(with: NSRange(location: lowerBound, length: m.range.location - lowerBound))
            if prefix.contains("💾") || prefix.lowercased().contains("size") {
                if let size = extractValidSize(from: m) {
                    return size
                }
            }
        }
        for m in matches.reversed() {
            if let size = extractValidSize(from: m) {
                return size
            }
        }
        return nil
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
    
    func parseLanguage(from title: String) -> String? {
        let upperTitle = title.uppercased()
        
        // Separate audio portion from subtitle portion if "SUB" / "SUBS" is present
        var audioPart = upperTitle
        var rawAudioPart = title
        if let subRange = upperTitle.range(of: "SUB ") ?? upperTitle.range(of: "SUB(") ?? upperTitle.range(of: "SUBS") {
            audioPart = String(upperTitle[..<subRange.lowerBound])
            let dist = upperTitle.distance(from: upperTitle.startIndex, to: subRange.lowerBound)
            let rawSubIndex = title.index(title.startIndex, offsetBy: dist)
            rawAudioPart = String(title[..<rawSubIndex])
        }
        
        var languages: [String] = []
        let tokens = audioPart.components(separatedBy: CharacterSet.alphanumerics.inverted)
        
        func hasLang(_ keys: [String], full: String? = nil, flags: [String] = []) -> Bool {
            if let full = full, audioPart.contains(full) { return true }
            for k in keys {
                if tokens.contains(k) { return true }
            }
            for f in flags {
                if rawAudioPart.contains(f) { return true }
            }
            return false
        }
        
        if hasLang(["EN", "ENG"], full: "ENGLISH", flags: ["🇬🇧", "🇺🇸"]) { languages.append("EN") }
        if hasLang(["RU", "RUS"], full: "RUSSIAN", flags: ["🇷🇺"]) { languages.append("RU") }
        if hasLang(["KO", "KOR"], full: "KOREAN", flags: ["🇰🇷"]) { languages.append("KO") }
        if hasLang(["JA", "JPN", "JAP"], full: "JAPANESE", flags: ["🇯🇵"]) { languages.append("JA") }
        if hasLang(["ES", "SPA", "ESP"], full: "SPANISH", flags: ["🇪🇸", "🇲🇽"]) || audioPart.contains("LATINO") || audioPart.contains("CASTELLANO") { languages.append("ES") }
        if hasLang(["FR", "FRE", "FRA"], full: "FRENCH", flags: ["🇫🇷"]) || audioPart.contains("TRUEFRENCH") || audioPart.contains("VF") || audioPart.contains("VOSTFR") || audioPart.contains("VFF") { languages.append("FR") }
        if hasLang(["DE", "GER", "DEU"], full: "GERMAN", flags: ["🇩🇪"]) || audioPart.contains("DEUTSCH") { languages.append("DE") }
        if hasLang(["IT", "ITA"], full: "ITALIAN", flags: ["🇮🇹"]) || audioPart.contains("ITALIANO") { languages.append("IT") }
        if hasLang(["ZH", "CHI", "ZHO"], full: "CHINESE", flags: ["🇨🇳", "🇭🇰", "🇹🇼"]) || audioPart.contains("MANDARIN") || audioPart.contains("CANTONESE") { languages.append("ZH") }
        if hasLang(["PT", "POR"], full: "PORTUGUESE", flags: ["🇧🇷", "🇵🇹"]) || audioPart.contains("DUBLADO") { languages.append("PT") }
        if hasLang(["TA", "TAM"], full: "TAMIL") { languages.append("TAM") }
        if hasLang(["TE", "TEL"], full: "TELUGU") { languages.append("TEL") }

        let hasExplicitHindi = audioPart.contains("HINDI") || tokens.contains("HI") || tokens.contains("HIN")
        let isIndianFlag = rawAudioPart.contains("🇮🇳")
        if hasExplicitHindi || (isIndianFlag && !languages.contains("TAM") && !languages.contains("TEL")) {
            if !languages.contains("HI") {
                languages.append("HI")
            }
        }
        
        if audioPart.contains("MULTI") || tokens.contains("MULTI") ||
           audioPart.contains("DUAL") || tokens.contains("DUAL") ||
           audioPart.contains("MVO") || audioPart.contains("DVO") ||
           languages.count >= 2 {
            if !languages.contains("MULTI") {
                languages.append("MULTI")
            }
        }
        
        return languages.isEmpty ? nil : languages.joined(separator: ", ")
    }

    private func parseCodec(from title: String) -> String? {
        let upper = title.uppercased()
        if upper.contains("AV1") { return "AV1" }
        if upper.contains("HEVC") || upper.contains("X265") || upper.contains("H.265") { return "HEVC" }
        if upper.contains("X264") || upper.contains("H.264") || upper.contains("AVC") { return "x264" }
        if upper.contains("MPEG") { return "MPEG" }
        return nil
    }

    private func parseBitrate(from title: String) -> String? {
        let patterns = [
            #"~?(\d+(?:\.\d+)?)\s*Mbps"#,
            #"~?(\d+(?:\.\d+)?)\s*Mb/s"#,
            #"(?i)bitrate[:\s]*(\d+(?:\.\d+)?)\s*(?:Mbps|Mb/s)"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
               let range = Range(match.range(at: 1), in: title) {
                return "~\(title[range]) Mbps"
            }
        }
        return nil
    }

    private func parseSubtitles(from title: String) -> String? {
        let upper = title.uppercased()
        var subs: [String] = []

        if let subRange = upper.range(of: "SUB") ?? upper.range(of: "SUBS") ?? upper.range(of: "SUBTITLE") {
            let subPart = String(upper[subRange.lowerBound...])
            if subPart.contains("ENGLISH") || subPart.contains("ENG") { subs.append("English") }
            if subPart.contains("SPANISH") || subPart.contains("SPA") { subs.append("Spanish") }
            if subPart.contains("FRENCH") || subPart.contains("FRE") { subs.append("French") }
            if subPart.contains("GERMAN") || subPart.contains("DEU") { subs.append("German") }
            if subPart.contains("HINDI") || subPart.contains("HIN") { subs.append("Hindi") }
            if subPart.contains("ARABIC") || subPart.contains("ARA") { subs.append("Arabic") }
            if subPart.contains("PORTUGUESE") || subPart.contains("POR") { subs.append("Portuguese") }
            if subPart.contains("ITALIAN") || subPart.contains("ITA") { subs.append("Italian") }
            if subPart.contains("JAPANESE") || subPart.contains("JPN") { subs.append("Japanese") }
            if subPart.contains("KOREAN") || subPart.contains("KOR") { subs.append("Korean") }
            if subPart.contains("CHINESE") || subPart.contains("CHI") { subs.append("Chinese") }
            if subPart.contains("SDH") { subs.append("SDH") }
        }

        if subs.isEmpty && (upper.contains("SUBBED") || upper.contains("ENGSUB")) {
            subs.append("English")
        }

        return subs.isEmpty ? nil : subs.joined(separator: ", ")
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
