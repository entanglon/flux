import SwiftUI
import Combine
import _Concurrency

typealias AsyncTask = _Concurrency.Task

struct StreamProbeResult {
    let ok: Bool
    let latency: Double
}

class PlayerManager: ObservableObject {
    static let shared = PlayerManager()

    @Published var currentItem: MediaItem?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var availableStreams: [Stream] = []
    @Published var isFetchingStreams: Bool = false
    @Published var currentStreamURL: URL?
    @Published var externalSubtitles: [StremioSubtitleTrack] = []
    /// Human-readable progress during source resolution ("Resolving source…", "Trying next (2/8)…")
    @Published var statusText: String? = nil
    /// Live health verification per stream (HTTP TTFB probe / seeder-based for torrents),
    /// keyed by stream.stableKey so results survive refetch snapshots.
    @Published var probeStatus: [String: StreamProbeResult] = [:]

    /// Auto-failover safety valve: after this many consecutive dead sources, stop
    /// cascading silently and hand control back to the user (stream picker).
    private let maxAutoFallbacks = 2
    private var consecutiveFallbacks = 0
    /// MANUAL MODE CONTRACT: when the user explicitly picks a source, NOTHING may
    /// switch away from it — no racing, no auto-fallback. Failures surface to the user.
    private var isManualSelection = false
    
    // Track current episode
    var currentSeason: Int?
    var currentEpisode: Int?
    var currentEpisodeImage: URL?
    
    // Cache for last played URL per episode to enable instant playback on re-open
    private struct CachedStream {
        let url: URL
        let timestamp: Date
    }
    private var lastPlayedStreams: [String: CachedStream] = [:]

    /// Torrent infoHashes that failed swarm resolution recently — skipped for 10 min
    /// so dead sources never cost us a second 12s timeout.
    private var recentlyDeadHashes: [String: Date] = [:]

    private func torrentHash(_ stream: Stream) -> String? {
        guard stream.isTorrent else { return nil }
        let s = stream.url.absoluteString
        guard let range = s.range(of: #"btih:([a-fA-F0-9]{32,40})"#, options: .regularExpression) else { return nil }
        // NOTE: must strip the "btih:" prefix — the raw match includes it, and
        // "/btih:<hash>/create" is a 404 on the Stremio server.
        return String(s[range]).replacingOccurrences(of: "btih:", with: "")
    }

    private func markHashDead(_ stream: Stream) {
        if let hash = torrentHash(stream) {
            recentlyDeadHashes[hash] = Date()
        }
        probeStatus[stream.stableKey] = StreamProbeResult(ok: false, latency: 99)
    }

    func isHashRecentlyDead(_ stream: Stream) -> Bool {
        guard let hash = torrentHash(stream),
              let diedAt = recentlyDeadHashes[hash] else { return false }
        if Date().timeIntervalSince(diedAt) > 600 {
            recentlyDeadHashes.removeValue(forKey: hash)
            return false
        }
        return true
    }

    /// Registers the torrent on the Stremio server engine — the exact step the real
    /// Stremio client performs before handing the stream URL to its player.
    ///   GET /{infoHash}/create?torrent={magnet}&fileIdx={n}
    /// Returns nil on success, or a human-readable failure reason.
    /// NOTE: create failures are NOT marked dead — they're usually transient
    /// (server restart, timeout). Only real mpv playback failures mark hashes dead.
    func resolveTorrentStream(_ stream: Stream, keepOthers: Bool = false) async -> String? {
        guard stream.isTorrent else { return nil }
        guard let hash = torrentHash(stream) else { return "Invalid torrent source" }

        // The server may have died since app launch — recover before giving up.
        guard await StremioServerManager.shared.ensureRunning() else {
            return "Streaming server unavailable"
        }

        func createCall() async -> (ok: Bool, status: Int, connError: Bool) {
            var components = URLComponents(url: StremioServerManager.shared.baseURL, resolvingAgainstBaseURL: false)
            components?.path = "/\(hash)/create"
            var query = [URLQueryItem(name: "torrent", value: stream.url.absoluteString)]
            if let idx = stream.fileIdx {
                query.append(URLQueryItem(name: "fileIdx", value: String(idx)))
            }
            components?.queryItems = query
            guard let url = components?.url else { return (false, 0, false) }

            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                return (status == 200, status, false)
            } catch {
                return (false, 0, true)
            }
        }

        var result = await createCall()
        if !result.ok && result.connError {
            // Server died mid-request — recover and retry exactly once.
            guard await StremioServerManager.shared.ensureRunning() else {
                return "Streaming server unavailable"
            }
            result = await createCall()
        }

        if result.ok {
            print("[PlayerManager] Torrent created on server: \(hash.prefix(12))…")
            return nil
        }
        print("[PlayerManager] Create failed (HTTP \(result.status)) for \(stream.cleanTitle)")
        return result.status == 0 ? "Could not reach the streaming server" : "Source swarm did not respond"
    }
    
    private init() {}
    
    func play(_ item: MediaItem, season: Int? = nil, episode: Int? = nil, episodeImage: URL? = nil) {
        self.currentItem = item
        self.currentSeason = season
        self.currentEpisode = episode
        self.currentEpisodeImage = episodeImage
        self.errorMessage = nil
        self.availableStreams = []
        self.currentStreamURL = nil
        self.statusText = nil
        self.consecutiveFallbacks = 0
        self.isManualSelection = false
        self.probeStatus = [:]
        self.resetPreloadState()
        
        // 0. Offline Check
        if let localUrl = DownloadManager.shared.getLocalUrl(for: item) {
            print("[PlayerManager] Playing downloaded file: \(localUrl)")
            self.currentStreamURL = localUrl
            self.isLoading = false
            return
        }
        
        // 1. Instant Replay Check
        let key = item.category == "TV Show" ? "\(item.id):\(season ?? 1):\(episode ?? 1)" : "\(item.id)"
        
        if let cached = lastPlayedStreams[key] {
            let elapsed = Date().timeIntervalSince(cached.timestamp)
            
            // If Fresh (< 60 mins), Play Immediately
            if elapsed < 3600 {
                print("[PlayerManager] Cache Fresh (\(Int(elapsed/60))m): Playing immediately.")
                self.currentStreamURL = cached.url
                self.isLoading = false
                self.populateStreamsInBackground(item: item, season: season, episode: episode)
                return
            } else {
                // Cache Stale — don't bother validating a possibly-dead torrent URL;
                // refetch fresh sources instead (HEAD checks can pass on dead swarms).
                print("[PlayerManager] Cache Stale (\(Int(elapsed/60))m): Refetching.")
                self.lastPlayedStreams.removeValue(forKey: key)
                fetchAndRace(item: item, season: season, episode: episode)
                return
            }
        }
        
        // 2. Normal Flow
        fetchAndRace(item: item, season: season, episode: episode)
    }
    
    private func populateStreamsInBackground(item: MediaItem, season: Int?, episode: Int?) {
        AsyncTask {
            try? await AsyncTask.sleep(nanoseconds: 1 * 1_000_000_000)

            _ = await StreamManager.shared.fetchStreamsRealtime(for: item, season: season, episode: episode) { updatedStreams in
                Task { @MainActor in
                    self.availableStreams = updatedStreams
                    self.verifyStreamHealth(updatedStreams)
                }
            }
        }
    }

    private func fetchAndRace(item: MediaItem, season: Int?, episode: Int?) {
        self.isFetchingStreams = true
        if let cachedStreams = StreamManager.shared.getCachedStreams(for: item, season: season, episode: episode), !cachedStreams.isEmpty {
             print("[PlayerManager] Cache Hit! Ready to Race.")
             self.availableStreams = cachedStreams
             self.isLoading = true
        } else {
             self.isLoading = true
        }
        
        AsyncTask {
            async let subsTask = SubtitleManager.shared.fetchSubtitles(for: item, season: season, episode: episode)
            
            let streams = await StreamManager.shared.fetchStreamsRealtime(for: item, season: season, episode: episode) { updatedStreams in
                Task { @MainActor in
                    self.availableStreams = updatedStreams
                    self.verifyStreamHealth(updatedStreams)
                }
            }
            
            let extraSubs = await subsTask
            
            await MainActor.run {
                self.availableStreams = streams
                self.externalSubtitles = extraSubs
                self.isFetchingStreams = false
                self.verifyStreamHealth(streams)
            }
            
            // Flux Mode Debugging
            let isFluxEnabled = UserDefaults.standard.object(forKey: "enableFluxMode") as? Bool ?? true
            print("[DEBUG] Flux Mode Enabled: \(isFluxEnabled)")
            print("[DEBUG] Stream Count: \(streams.count)")

            // Flux Mode Auto-Play Engine
            if isFluxEnabled, !streams.isEmpty {
                await MainActor.run { self.isManualSelection = false }
                if let winner = await self.raceBestStream(from: streams) {
                    print("[PlayerManager] Flux Mode selected stream: \(winner.cleanTitle) (\(winner.source))")
                    await MainActor.run {
                        self.isLoading = false
                        self.finishSelect(winner)
                    }
                    return
                }
            }
            
            // Fallback: Show list
            await MainActor.run {
                self.availableStreams = streams
                self.isLoading = false
            }
        }
    }
    
    // Flux Mode source pick. The Stremio server's /create returns 200 for ANY
    // well-formed magnet (dead swarm or not), so racing creates cannot detect
    // dead swarms — instead take the top health-ranked torrent immediately and
    // let mpv playback + auto-fallback handle failures (exact Stremio behavior).
    // HTTP candidates still get a fast parallel HEAD race.
    private func raceBestStream(from streams: [Stream]) async -> Stream? {
        let healthy = streams.filter { !isHashRecentlyDead($0) }
        guard !healthy.isEmpty else { return nil }

        if let topTorrent = healthy.first(where: { $0.isTorrent }) {
            print("[PlayerManager] Flux Mode: top-ranked torrent \(topTorrent.cleanTitle) (\(topTorrent.source))")
            return topTorrent
        }

        let httpCandidates = Array(healthy.filter { !$0.isTorrent }.prefix(3))
        print("[PlayerManager] Racing \(httpCandidates.count) HTTP candidates in parallel...")

        return await withTaskGroup(of: Stream?.self) { group in
            for stream in httpCandidates {
                group.addTask {
                    var request = URLRequest(url: self.getPlayableURL(for: stream))
                    request.httpMethod = "HEAD"
                    request.timeoutInterval = 3
                    do {
                        let (_, response) = try await URLSession.shared.data(for: request)
                        if let http = response as? HTTPURLResponse, (200...399).contains(http.statusCode) {
                            return stream
                        }
                        return nil
                    } catch {
                        return nil
                    }
                }
            }

            // First successful completion wins; cancel remaining tasks immediately
            for await result in group {
                if let winner = result {
                    print("[PlayerManager] Race winner: \(winner.cleanTitle) (\(winner.source))")
                    group.cancelAll()
                    return winner
                }
            }
            return nil
        }
    }
    
    /// Lightweight background verification used by the "Best" tab.
    /// Fast HEAD check for HTTP sources, and seeder health validation for torrents.
    /// Zero background torrent swarms spawned so RAM stays clean.
    func verifyStreamHealth(_ streams: [Stream]) {
        let pending = streams.filter { probeStatus[$0.stableKey] == nil }
        guard !pending.isEmpty else { return }

        // Immediately score torrents based on swarm health
        for stream in pending where stream.isTorrent {
            let ok = (stream.seeders ?? 0) > 0
            probeStatus[stream.stableKey] = StreamProbeResult(ok: ok, latency: ok ? 0.5 : 99.0)
        }

        let httpPending = pending.filter { !$0.isTorrent }
        guard !httpPending.isEmpty else { return }

        AsyncTask {
            let httpProbes = Array(httpPending.prefix(6))

            await withTaskGroup(of: (String, StreamProbeResult).self) { group in
                for stream in httpProbes {
                    let key = stream.stableKey
                    let targetURL = self.getPlayableURL(for: stream)
                    group.addTask {
                        let startTime = CFAbsoluteTimeGetCurrent()
                        var request = URLRequest(url: targetURL)
                        request.httpMethod = "HEAD"
                        request.timeoutInterval = 3
                        do {
                            let (_, response) = try await URLSession.shared.data(for: request)
                            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                            let ok = (response as? HTTPURLResponse).flatMap({ (200...399).contains($0.statusCode) }) == true
                            return (key, StreamProbeResult(ok: ok, latency: elapsed))
                        } catch {
                            return (key, StreamProbeResult(ok: false, latency: 3.0))
                        }
                    }
                }
                for await (key, result) in group {
                    await MainActor.run {
                        self.probeStatus[key] = result
                    }
                }
            }
        }
    }

    func getPlayableURL(for url: URL) -> URL {
        let str = url.absoluteString
        if str.hasPrefix("magnet:") || str.contains("xt=urn:btih:") {
            if let hashRange = str.range(of: #"btih:([a-fA-F0-9]{32,40})"#, options: .regularExpression) {
                let hash = String(str[hashRange]).replacingOccurrences(of: "btih:", with: "")
                var components = URLComponents()
                components.scheme = "http"
                components.host = "127.0.0.1"
                components.port = StremioServerManager.shared.port
                components.path = "/\(hash)/0"
                if let streamURL = components.url {
                    return streamURL
                }
            }
        }
        return url
    }

    /// Builds the playable URL for a selected stream. For torrents, the Stremio server
    /// serves the file at /{infoHash}/{fileIdx} (torrent must be registered via /create first).
    /// For HTTP streams with proxyHeaders, routes through the local StreamProxy.
    func getPlayableURL(for stream: Stream) -> URL {
        if stream.isTorrent {
            let str = stream.url.absoluteString
            if let hashRange = str.range(of: #"btih:([a-fA-F0-9]{32,40})"#, options: .regularExpression) {
                let hash = String(str[hashRange]).replacingOccurrences(of: "btih:", with: "")
                var components = URLComponents()
                components.scheme = "http"
                components.host = "127.0.0.1"
                components.port = StremioServerManager.shared.port
                components.path = "/\(hash)/\(stream.fileIdx ?? 0)"
                if let finalURL = components.url {
                    return finalURL
                }
            }
        }

        var target = stream.url
        // Route HTTP streams with required headers through the local proxy
        if let headers = stream.proxyHeaders, !headers.isEmpty, !stream.isTorrent,
           StreamProxyManager.shared.isRunning,
           let proxied = StreamProxyManager.shared.proxyURL(for: target, headers: headers) {
            print("[PlayerManager] Routing through proxy for \(stream.source) (headers: \(headers.keys.joined(separator: ", ")))")
            return proxied
        }

        return target
    }
    
    func selectStream(_ stream: Stream) {
        print("Selected stream: \(stream.title) from \(stream.source)")
        isManualSelection = true
        attemptStream(stream)
    }

    /// Two-phase playback (Stremio-style): torrents are resolved by the Stremio server,
    /// then the URL is handed to mpv. Dead sources fail and fall through to next candidate.
    private func attemptStream(_ stream: Stream) {
        let isFluxEnabled = UserDefaults.standard.object(forKey: "enableFluxMode") as? Bool ?? true

        // Skip recently-dead hashes for AUTO selection only — an explicit user
        // click must always be attempted (the dead mark may be stale).
        if isFluxEnabled && !isManualSelection && isHashRecentlyDead(stream) && stream.isTorrent {
            advancePast(stream)
            return
        }

        if stream.isTorrent {
            // Stremio-exact flow: register the torrent on the server (fire-and-forget)
            // and hand the URL to mpv IMMEDIATELY. The server blocks the file response
            // until pieces flow, mpv reports paused-for-cache → buffering overlay shows.
            // Awaiting /create here would stall the UI on metadata fetch (slow swarms)
            // and time out — the torrent still registers server-side, which is why a
            // second click "suddenly works".
            DispatchQueue.main.async { self.statusText = "Connecting to source…" }
            self.isLoading = true
            AsyncTask {
                let serverUp = await StremioServerManager.shared.ensureRunning()
                if serverUp {
                    // Fire-and-forget — do NOT block playback on metadata fetch.
                    AsyncTask { _ = await self.resolveTorrentStream(stream) }
                }
                await MainActor.run {
                    self.isLoading = false
                    self.statusText = nil
                    if serverUp {
                        self.consecutiveFallbacks = 0
                        self.finishSelect(stream)
                    } else if isFluxEnabled {
                        advancePast(stream)
                    } else {
                        self.errorMessage = "Streaming server unavailable"
                    }
                }
            }
        } else {
            // HTTP stream — hand the URL directly to mpv (Stremio-style).
            finishSelect(stream)
        }
    }

    private func finishSelect(_ stream: Stream) {
        let targetURL = getPlayableURL(for: stream)
        self.currentStreamURL = targetURL
        self.errorMessage = nil

        self.saveLastPlayedStream(url: targetURL)

        if let item = self.currentItem {
            UserDataService.shared.addToHistory(item, season: self.currentSeason, episode: self.currentEpisode, episodeImage: self.currentEpisodeImage)
        }

        UserDefaults.standard.set(stream.source, forKey: "lastUsedSource")
    }

    /// After a failed attempt, move on to the next candidate in the ranked list.
    /// Bounded: after maxAutoFallbacks consecutive failures, stop and show the
    /// stream picker instead of cascading silently for minutes.
    /// Never auto-advance when the user explicitly picked a source (manual mode).
    private func advancePast(_ failed: Stream) {
        guard !isManualSelection else {
            // Manual pick failed — surface error, don't silently swap sources.
            errorMessage = "Couldn't load this source — the swarm looks too weak right now. Pick another one."
            return
        }

        consecutiveFallbacks += 1
        guard consecutiveFallbacks <= maxAutoFallbacks else {
            print("[PlayerManager] \(consecutiveFallbacks - 1) sources failed — stopping auto-fallback, showing picker.")
            statusText = nil
            isLoading = false
            currentStreamURL = nil
            return
        }

        guard let idx = availableStreams.firstIndex(where: { $0.id == failed.id }) else {
            errorMessage = "Unable to play video. Please try another source."
            return
        }
        let next = idx + 1
        if next < availableStreams.count {
            statusText = "Source unavailable — trying next (\(next + 1)/\(availableStreams.count))"
            print("[PlayerManager] Source dead. Falling through (\(next + 1)/\(availableStreams.count)): \(availableStreams[next].cleanTitle)")
            attemptStream(availableStreams[next])
        } else {
            errorMessage = "Unable to play video. Please try another source."
        }
    }
    
    private func saveLastPlayedStream(url: URL) {
        guard let item = currentItem else { return }
        let key = item.category == "TV Show" ? "\(item.id):\(currentSeason ?? 1):\(currentEpisode ?? 1)" : "\(item.id)"
        lastPlayedStreams[key] = CachedStream(url: url, timestamp: Date())
        print("[PlayerManager] Saved Instant Replay URL for \(key)")
    }
    
    // HEAD request validation
    private func validateStream(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 3 // Short timeout, we want fast answer
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                // 200 OK or 206 Partial Content (common for streams) are good
                return httpResponse.statusCode == 200 || httpResponse.statusCode == 206
            }
            return false
        } catch {
            return false
        }
    }
    
    func updateWatchProgress(time: Double, duration: Double) {
        guard let item = currentItem, duration > 0 else { return }
        let progress = time / duration
        UserDataService.shared.addToHistory(item, progress: progress, season: currentSeason, episode: currentEpisode, episodeImage: currentEpisodeImage)
    }
    
    func close() {
        DispatchQueue.main.async {
            self.currentItem = nil
            // Don't clear lastPlayedStreams, it persists for the session
            self.currentStreamURL = nil
            self.availableStreams = []
            self.probeStatus = [:]
            self.externalSubtitles = []
            self.isLoading = false
            self.errorMessage = nil
            self.currentSeason = nil
            self.currentEpisode = nil
            self.currentEpisodeImage = nil
        }
    }
    
    // MARK: - Next Episode Logic
    
    var nextEpisodeInfo: (season: Int, episode: Int)? {
        guard let item = currentItem,
              let currentSeasonNum = currentSeason,
              let currentEpisodeNum = currentEpisode,
              let seasons = item.seasons else { return nil }
        
        // 1. Check current season
        if let currentSeasonObj = seasons.first(where: { $0.seasonNumber == currentSeasonNum }) {
            if currentEpisodeNum < currentSeasonObj.episodeCount {
                return (currentSeasonNum, currentEpisodeNum + 1)
            }
        }
        
        // 2. Check next season
        let nextSeasonNum = currentSeasonNum + 1
        if seasons.contains(where: { $0.seasonNumber == nextSeasonNum }) {
            return (nextSeasonNum, 1)
        }
        
        return nil
    }
    
    func playNextEpisode() {
        guard let next = nextEpisodeInfo, let item = currentItem else { return }
        print("Playing Next Episode: S\(next.season):E\(next.episode)")
        
        AsyncTask {
            // Fetch next episode details to get the image
            var nextEpisodeImage: URL? = nil
            if let meta = try? await StremioService.shared.fetchMeta(type: "series", id: item.id) {
                // Find the episode
                if let vids = meta.episodes, let ep = vids.first(where: { $0.episodeNumber == next.episode && $0.seasonNumber == next.season }) {
                    nextEpisodeImage = ep.stillURL
                }
            }
            
            let finalImage = nextEpisodeImage
            
            await MainActor.run {
                self.play(item, season: next.season, episode: next.episode, episodeImage: finalImage)
            }
        }
    }
    
    // MARK: - Smart Preloading (Next Episode)
    
    private var hasPreloadedNext = false
    
    func resetPreloadState() {
        hasPreloadedNext = false
    }
    
    func preloadNextEpisodeIfNeeded() {
        guard !hasPreloadedNext, let next = nextEpisodeInfo, let item = currentItem else { return }
        
        hasPreloadedNext = true
        print("[PlayerManager] Smart Preloading Next Episode: S\(next.season):E\(next.episode)")
        
        AsyncTask {
            await StreamManager.shared.preloadStreams(for: item, season: next.season, episode: next.episode)
        }
    }
    
    // MARK: - Fallback Logic

    func tryNextStream() {
        // MANUAL MODE: show error but keep currentStreamURL so the buffering
        // overlay stays visible. The error view renders on top. When the user
        // dismisses the error, we clear the URL to reveal the picker.
        if isManualSelection {
            print("[PlayerManager] Manual-mode playback failed — showing error, keeping overlay.")
            errorMessage = "Playback failed for the selected source. Please pick another one."
            return
        }

        guard !availableStreams.isEmpty else { return }

        let currentIndex: Int?
        if let currentURL = currentStreamURL {
            currentIndex = availableStreams.firstIndex(where: { s in
                if s.url == currentURL { return true }
                let playable = getPlayableURL(for: s)
                return playable == currentURL || playable.absoluteString == currentURL.absoluteString
            })
        } else {
            currentIndex = nil
        }

        let nextIndex = currentIndex.map { $0 + 1 } ?? 0
        if nextIndex < availableStreams.count {
            let nextStream = availableStreams[nextIndex]
            print("[PlayerManager] Current stream failed. Trying next (\(nextIndex + 1)/\(availableStreams.count)): \(nextStream.cleanTitle)")
            attemptStream(nextStream)
        } else {
            print("[PlayerManager] All streams exhausted.")
            errorMessage = "Unable to play video. Please try another source."
        }
    }
}
