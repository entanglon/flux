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
    @Published var isFetchingStreams = false
    @Published var totalAddonsCount: Int = 0
    @Published var loadedAddonsCount: Int = 0
    @Published var pendingAddonNames: [String] = []
    @Published var currentStreamURL: URL?
    @Published var currentMagnetURL: String?
    @Published var currentSelectedStream: Stream? = nil
    @Published var forceStreamPicker: Bool = false
    @Published var isStreamPickerPresented: Bool = false
    @Published var externalSubtitles: [StremioSubtitleTrack] = []
    /// Human-readable progress during source resolution ("Resolving source…", "Trying next (2/8)…")
    @Published var statusText: String? = nil
    /// Live health verification per stream (HTTP TTFB probe / seeder-based for torrents),
    /// keyed by stream.stableKey so results survive refetch snapshots.
    @Published var probeStatus: [String: StreamProbeResult] = [:]
    /// Position to jump to once the next playback starts producing frames —
    /// armed when expanding a PiP session back into the player window.
    @Published var pendingResumeTime: Double? = nil

    /// Tracks the currently-active torrent hash so we can remove it before
    /// registering a new one (prevents double downloads).
    private var activeTorrentHash: String?

    // MARK: - Detail-Page Prefetch (advanced loading)
    //
    // Opening a DetailView kicks off source resolution in the background:
    //   - BOTH modes: streams are fetched (StreamManager cache) so the picker
    //     appears instantly on Play.
    //   - Flux Mode additionally resolves the best source, primes it (torrent
    //     registration / HTTP edge warm) and builds a WARM mpv core that holds
    //     the stream paused while buffering. Play adopts that core → instant
    //     start. Core is discarded after 5 min or when superseded.

    private struct WarmPlaybackCore {
        let key: String
        let url: URL
        let controller: MPVController
        let viewController: MPVViewController
        let hostWindow: NSWindow?
        let createdAt: Date
    }

    @Published private(set) var isPrefetching = false
    private var prefetchTask: AsyncTask<Void, Never>?
    private var inflightPrefetchKey: String?
    private var prefetchedKey: String?
    private var prefetchedStream: Stream?
    private var prefetchedSubtitles: [StremioSubtitleTrack]?
    /// Ownership is recorded before `/create` starts. This lets cancellation
    /// remove a prefetch torrent even while subtitle fetching is still pending.
    private var prefetchTorrentHash: String?
    private var prefetchedAt: Date?
    private var warmCore: WarmPlaybackCore?
    private var warmCoreDiscardTask: AsyncTask<Void, Never>?
    @Published var standbyFallbacks: [Stream] = []
    @Published var hasPlaybackStarted: Bool = false
    private var startupWatchdogTask: Task<Void, Never>?
    private var lastTelemetryProgressTime: Date?
    private var lastObservedCacheTime: Double = 0.0

    // Next-Episode preloading state (AIOStreams style)
    private var prefetchedNextKey: String?
    private var prefetchedNextStream: Stream?
    private var prefetchedNextSubtitles: [StremioSubtitleTrack]?
    private var prefetchedNextAt: Date?
    @Published var nextEpisode: Episode? = nil

    private var fetchAndRaceTask: AsyncTask<Void, Never>?

    func prefetchKey(for item: MediaItem, season: Int?, episode: Int?) -> String {
        let isEpisodic = item.isSeries || season != nil || episode != nil
        return isEpisodic ? "\(item.id):\(season ?? 1):\(episode ?? 1)" : item.id
    }

    /// DetailView .task hook — safe to call repeatedly; deduped per title.
    /// Tiered: with NO active session the full pipeline runs (race + prime +
    /// warm core). While something is playing/PiP'd, only the cheap stream
    /// fetch runs — registering a second torrent would compete for the same
    /// Stremio-server bandwidth as the active stream.
    func startDetailPrefetch(item: MediaItem, season: Int? = nil, episode: Int? = nil) {
        let isFluxEnabled = UserDefaults.standard.object(forKey: UserDefaults.Key.enableFluxMode) as? Bool ?? true
        guard isFluxEnabled else { return }

        let sessionActive = currentItem != nil || PiPManager.shared.isActive
        let key = prefetchKey(for: item, season: season, episode: episode)
        if inflightPrefetchKey == key { return }
        if prefetchedKey == key && warmCore?.key == key { return } // already primed

        // A new detail page supersedes every resource owned by the old one,
        // including a torrent whose `/create` request is still running.
        cancelDetailPrefetch()
        inflightPrefetchKey = key
        isPrefetching = true
        print("[PlayerManager] Prefetch starting for \(key)\(sessionActive ? " (streams-only — session active)" : "")")
        prefetchTask = AsyncTask { [weak self] in
            await self?.runPrefetch(item: item, season: season, episode: episode, key: key, allowPrime: !sessionActive)
        }
    }

    /// Called when the user navigates away from DetailView — cancels the
    /// in-flight prefetch and tells the engine to drop the torrent immediately
    /// instead of waiting for the idle timeout.
    func cancelDetailPrefetch() {
        guard inflightPrefetchKey != nil || prefetchedKey != nil || prefetchTorrentHash != nil else { return }
        let keyToCancel = inflightPrefetchKey ?? prefetchedKey
        print("[PlayerManager] Cancelling prefetch for \(keyToCancel ?? "?")")
        prefetchTask?.cancel()
        prefetchTask = nil
        inflightPrefetchKey = nil

        // Drop the warm core if it was built for this prefetch
        if let core = warmCore, core.key == keyToCancel {
            core.controller.stop()
            core.hostWindow?.orderOut(nil)   // orderOut hides; close() would double-release via isReleasedWhenClosed
            warmCore = nil
        }

        // Tell the engine to stop downloading the torrent immediately. The
        // hash is recorded before `/create`, so this also covers cancellation
        // while that request is in flight.
        if let hash = prefetchTorrentHash {
            prefetchTorrentHash = nil
            if activeTorrentHash != hash {
                StremioServerManager.shared.removeTorrent(infoHash: hash)
            }
        }
        prefetchedStream = nil
        prefetchedKey = nil
        prefetchedSubtitles = nil
        isPrefetching = false
    }

    private func runPrefetch(item: MediaItem, season: Int?, episode: Int?, key: String, allowPrime: Bool) async {
        async let subsTask = SubtitleManager.shared.fetchSubtitles(for: item, season: season, episode: episode)

        // Populates StreamManager's cache — the non-Flux picker reads from it
        // on Play, so results show immediately instead of after addon fan-out.
        let streams = await StreamManager.shared.fetchStreamsRealtime(for: item, season: season, episode: episode) { _ in }
        guard !Task.isCancelled else { return }

        let fluxEnabled = UserDefaults.standard.object(forKey: UserDefaults.Key.enableFluxMode) as? Bool ?? true
        defer {
            if Task.isCancelled {
                DispatchQueue.main.async { self.isPrefetching = false }
            }
        }
        guard fluxEnabled, allowPrime, !streams.isEmpty else {
            await MainActor.run {
                self.prefetchedKey = key   // streams cached for instant picker
                self.prefetchedAt = Date()
                self.isPrefetching = false
                self.inflightPrefetchKey = nil
            }
            return
        }

        guard let winner = await raceBestStream(from: streams), !Task.isCancelled else {
            await MainActor.run {
                self.isPrefetching = false
                self.inflightPrefetchKey = nil
            }
            return
        }

        // Prime the pipeline so pieces/bytes are already flowing pre-Play:
        // torrents register on the Stremio server (fire-and-forget per the
        // Stremio-exact protocol); HTTP sources get a small ranged GET to warm
        // proxy + CDN edge.
        if winner.isTorrent {
            guard let hash = torrentHash(winner) else {
                await MainActor.run {
                    self.isPrefetching = false
                    self.inflightPrefetchKey = nil
                }
                return
            }

            // Register ownership before beginning the request. Do not spawn an
            // unstructured child task here: it would outlive cancellation and
            // could create an orphan torrent after the detail page disappeared.
            await MainActor.run {
                guard self.inflightPrefetchKey == key else { return }
                self.prefetchTorrentHash = hash
                StremioServerManager.shared.trackCreate(
                    infoHash: hash,
                    magnetURL: winner.url.absoluteString,
                    fileIdx: winner.fileIdx ?? 0
                )
            }
            guard !Task.isCancelled, inflightPrefetchKey == key else { return }

            let creationError = await resolveTorrentStream(winner)
            guard !Task.isCancelled,
                  inflightPrefetchKey == key,
                  creationError == nil else {
                await MainActor.run {
                    if self.prefetchTorrentHash == hash {
                        self.prefetchTorrentHash = nil
                        if self.activeTorrentHash != hash {
                            StremioServerManager.shared.removeTorrent(infoHash: hash)
                        }
                    }
                    self.isPrefetching = false
                    if self.inflightPrefetchKey == key { self.inflightPrefetchKey = nil }
                }
                return
            }
        } else {
            Self.warmHTTP(url: getPlayableURL(for: winner))
        }

        let subs = await subsTask
        guard !Task.isCancelled else { return }

        await MainActor.run {
            // Session started while we were racing (user hit Play early) —
            // playback is already resolving normally; don't build a warm core
            // nobody will adopt (it would just buffer in the background).
            guard self.currentItem == nil, !Task.isCancelled else {
                self.isPrefetching = false
                self.inflightPrefetchKey = nil
                print("[PlayerManager] Prefetch aborted — playback started before priming finished")
                return
            }
            self.prefetchedKey = key
            self.prefetchedStream = winner
            self.prefetchedSubtitles = subs
            self.prefetchedAt = Date()
            self.inflightPrefetchKey = nil
            self.buildWarmCore(key: key, url: getPlayableURL(for: winner))
            self.isPrefetching = false
            print("[PlayerManager] ⚡ Prefetch primed: \(winner.cleanTitle) (\(winner.source)) — warm core holding")
        }
    }

    private static func warmHTTP(url: URL) {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        request.timeoutInterval = 4
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    // MARK: Warm mpv core

    private func buildWarmCore(key: String, url: URL) {
        discardWarmCore()

        let controller = MPVController()
        let vc = MPVViewController(nibName: nil, bundle: nil)
        vc.delegate = controller
        controller.playerView = vc
        _ = vc.view // forces loadView + viewDidLoad → mpv initialized + wired

        // Park the render surface in an invisible corner window: detached
        // CAOpenGLLayers never composite, and this pipeline creates the mpv
        // render context lazily inside the layer's draw() — without a host
        // window mpv would never start buffering.
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 90),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        host.alphaValue = 0.01
        host.isOpaque = false
        host.backgroundColor = .black
        host.level = NSWindow.Level(rawValue: -1)
        host.contentView = vc.view
        if let visible = NSScreen.main?.visibleFrame {
            host.setFrameOrigin(NSPoint(x: visible.minX, y: visible.minY))
        }
        host.isReleasedWhenClosed = false   // we manage the lifecycle; close() must not release
        host.orderFrontRegardless()

        controller.pause()      // hold BEFORE loadfile → loads paused, cache fills
        controller.play(url: url)

        warmCore = WarmPlaybackCore(
            key: key,
            url: url,
            controller: controller,
            viewController: vc,
            hostWindow: host,
            createdAt: Date()
        )

        warmCoreDiscardTask?.cancel()
        warmCoreDiscardTask = AsyncTask { [weak self] in
            try? await AsyncTask.sleep(nanoseconds: 300_000_000_000) // 5 min TTL
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.discardWarmCore() }
        }
    }

    /// Hands the warm core to a newly-opened player window (nil → build fresh).
    /// Only adopted when the resolved URL matches what play() actually picked —
    /// an Instant-Replay hit uses a different source and must NOT adopt.
    /// A nil currentStreamURL (fast-path hasn't landed yet) adopts OPTIMISTICALLY:
    /// the fast-path sets the very same URL moments later.
    func acquireSessionController() -> MPVController {
        if let core = warmCore,
           let item = currentItem,
           core.key == prefetchKey(for: item, season: currentSeason, episode: currentEpisode),
           currentStreamURL == nil || core.url.absoluteString == currentStreamURL?.absoluteString {
            print("[PlayerManager] ⚡ Adopting warm mpv core — playback ready")
            let controller = core.controller
            core.hostWindow?.orderOut(nil)
            warmCore = nil
            warmCoreDiscardTask?.cancel()
            warmCoreDiscardTask = nil
            // The warm core is now the active playback core. Transfer torrent
            // ownership so close/fallback cleans it up as a normal stream.
            if let hash = prefetchTorrentHash {
                activeTorrentHash = hash
                prefetchTorrentHash = nil
            }
            return controller
        }
        discardWarmCore()
        return MPVController()
    }

    // Session controller: PlayerView structs re-initialize constantly (the app
    // root observes PlayerManager, so any @Published blip rebuilds them) — the
    // session's mpv controller MUST be cached here so every init hands back the
    // SAME instance instead of spawning replacements that orphan the video view.
    private var sessionController: MPVController?

    /// Idempotent per playback session — called from PlayerView.init.
    func beginSession() -> MPVController {
        if let controller = sessionController { return controller }
        let controller = acquireSessionController()
        sessionController = controller
        return controller
    }

    func endSession() {
        sessionController = nil
    }

    func discardWarmCore() {
        warmCoreDiscardTask?.cancel()
        warmCoreDiscardTask = nil
        guard let core = warmCore else { return }
        warmCore = nil
        print("[PlayerManager] Discarding warm core (\(core.key)) age \(Int(Date().timeIntervalSince(core.createdAt)))s")
        core.controller.stop()
        if let hash = prefetchTorrentHash {
            prefetchTorrentHash = nil
            if activeTorrentHash != hash {
                StremioServerManager.shared.removeTorrent(infoHash: hash)
            }
        }
        let vc = core.viewController
        let host = core.hostWindow
        DispatchQueue.main.async {
            host?.orderOut(nil)
            vc.playerView.cleanup()
        }
    }


    /// Auto-failover safety valve: after this many consecutive dead sources, stop
    /// cascading silently and hand control back to the user (stream picker).
    private let maxAutoFallbacks = 2
    private var consecutiveFallbacks = 0
    /// MANUAL MODE CONTRACT: when the user explicitly picks a source, NOTHING may
    /// switch away from it — no racing, no auto-fallback. Failures surface to the user.
    var isManualSelection = false
    
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

    private func pruneSessionCaches() {
        let now = Date()
        lastPlayedStreams = lastPlayedStreams.filter { now.timeIntervalSince($0.value.timestamp) < 60 * 60 }
        recentlyDeadHashes = recentlyDeadHashes.filter { now.timeIntervalSince($0.value) < 10 * 60 }

        while lastPlayedStreams.count > 50,
              let oldestKey = lastPlayedStreams.min(by: { $0.value.timestamp < $1.value.timestamp })?.key {
            lastPlayedStreams.removeValue(forKey: oldestKey)
        }
        while recentlyDeadHashes.count > 200,
              let oldestKey = recentlyDeadHashes.min(by: { $0.value < $1.value })?.key {
            recentlyDeadHashes.removeValue(forKey: oldestKey)
        }
    }

    private var hasConfirmedPlaybackSuccess = false

    /// Confirms that a stream has successfully delivered frames and played for at least 1.0s.
    /// Only positively-verified streams are cached or written into persistent watch history.
    func confirmPlaybackSuccess() {
        guard !hasConfirmedPlaybackSuccess else { return }
        guard let item = currentItem, let url = currentStreamURL else { return }
        hasConfirmedPlaybackSuccess = true

        let isLocal = (url.host == "127.0.0.1" || url.host == "localhost")
        let isRemoteHttp = !isLocal && (url.scheme == "http" || url.scheme == "https")
        let hasQueryToken = (url.query?.contains("token") == true || url.query?.contains("expires") == true || url.query?.contains("exp=") == true || url.query?.contains("sig=") == true)

        let isEpisodic = item.isSeries || currentSeason != nil || currentEpisode != nil
        let key = isEpisodic ? "\(item.id):\(currentSeason ?? 1):\(currentEpisode ?? 1)" : "\(item.id)"

        // In-memory cache for instant replay during active session (avoid caching ephemeral expired HTTP tokens)
        if !hasQueryToken {
            lastPlayedStreams[key] = CachedStream(url: url, timestamp: Date())
            print("[PlayerManager] 💾 Positive playback confirmed (>=1s) — saved instant replay for \(key)")
        }

        let hash = currentSelectedStream?.isTorrent == true ? torrentHash(currentSelectedStream!) : nil
        var historyItem = item
        historyItem.lastStreamURL = (isRemoteHttp && hasQueryToken) ? nil : url
        historyItem.lastTorrentInfoHash = hash
        historyItem.lastFileIndex = currentSelectedStream?.fileIdx

        UserDataService.shared.addToHistory(
            historyItem,
            season: self.currentSeason,
            episode: self.currentEpisode,
            episodeImage: self.currentEpisodeImage,
            streamURL: (isRemoteHttp && hasQueryToken) ? nil : url,
            torrentInfoHash: hash,
            fileIndex: currentSelectedStream?.fileIdx
        )
    }

    /// Purges cached stream when playback fails or when the source cannot be loaded.
    func invalidateCachedStream(for item: MediaItem?, season: Int?, episode: Int?) {
        guard let item = item else { return }
        let isEpisodic = item.isSeries || season != nil || episode != nil
        let key = isEpisodic ? "\(item.id):\(season ?? 1):\(episode ?? 1)" : "\(item.id)"
        lastPlayedStreams.removeValue(forKey: key)
        print("[PlayerManager] 🗑️ Invalidation: removed cached stream for \(key)")
    }

    // MARK: - Client firewall (engine perimeter defense)
    //
    // Magnet URIs originate from community addons — arbitrary third-party
    // input. Validate EVERYTHING here before a request reaches the engine.

    /// 40 hex chars, not zero, not degenerate (all-same-char).
    static func validInfoHash(_ hash: String) -> Bool {
        guard hash.count == 40,
              hash.allSatisfy({ $0.isHexDigit }),
              Set(hash).count > 1 else { return false }
        return true
    }

    private func torrentHash(_ stream: Stream) -> String? {
        guard stream.isTorrent else { return nil }
        let s = stream.url.absoluteString
        guard let range = s.range(of: #"btih:([a-fA-F0-9]{32,40})"#, options: .regularExpression) else { return nil }
        // NOTE: must strip the "btih:" prefix — the raw match includes it, and
        // "/btih:<hash>/create" is a 404 on the Stremio server.
        let raw = String(s[range]).replacingOccurrences(of: "btih:", with: "")
        // Normalize to canonical 40-hex; reject anything the engine can't take.
        guard Self.validInfoHash(raw) else { return nil }
        return raw
    }

    private func markHashDead(_ stream: Stream) {
        pruneSessionCaches()
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
    
    func play(
        _ item: MediaItem,
        season: Int? = nil,
        episode: Int? = nil,
        episodeImage: URL? = nil,
        isAutoAdvance: Bool = false,
        fromContinueWatching: Bool = false,
        forceStreamPicker: Bool = false,
        startFromBeginning: Bool = false
    ) {
        pruneSessionCaches()
        // USER-initiated playback while a PiP session floats: same title =
        // expand (resume at the floating position); different title = tear the
        // floating session down first. Auto-advance skips this — the floating
        // core just switches files and keeps playing.
        var resumePos: Double?
        if !isAutoAdvance && !startFromBeginning {
            resumePos = PiPManager.shared.interceptPlaybackRequest(item: item, season: season, episode: episode)
        }
        
        // Automatic saved watch history resume position calculation (exact seconds)
        if !startFromBeginning && resumePos == nil {
            if let s = season, let e = episode,
               let epProg = UserDataService.shared.getEpisodeProgress(for: item.id, season: s, episode: e) {
                if epProg.position > 5.0 && (epProg.duration <= 0 || epProg.position / epProg.duration < 0.92) {
                    resumePos = epProg.position
                }
            }

            if resumePos == nil {
                let historyItem = UserDataService.shared.getHistoryItem(for: item) ?? item
                let isMatchingEpisode: Bool
                if item.isSeries || season != nil {
                    isMatchingEpisode = (historyItem.lastSeason == season || (season == nil && historyItem.lastSeason != nil)) &&
                                        (historyItem.lastEpisode == episode || (episode == nil && historyItem.lastEpisode != nil))
                } else {
                    isMatchingEpisode = true
                }

                if isMatchingEpisode {
                    if let pos = historyItem.lastPlaybackPosition, pos > 5.0, (historyItem.progress ?? 0) < 0.92 {
                        resumePos = pos
                    } else if let p = historyItem.progress ?? item.progress, p > 0.01 && p < 0.92, let dur = historyItem.lastPlaybackDuration, dur > 10 {
                        resumePos = p * dur
                    }
                }
            }
        }
        self.pendingResumeTime = resumePos

        self.currentItem = item
        self.currentSeason = season
        self.currentEpisode = episode
        self.currentEpisodeImage = episodeImage
        // New episode → completion may be attempted again (clears stale keys).
        let episodeKey = "\(item.id):\(season ?? -1):\(episode ?? -1)"
        if episodeKey != lastCompletedEpisodeKey {
            attemptedAdvances.removeAll()
            lastCompletedEpisodeKey = episodeKey
        }
        self.errorMessage = nil
        self.currentSelectedStream = nil
        self.hasConfirmedPlaybackSuccess = false
        if forceStreamPicker {
            self.forceStreamPicker = true
            self.isManualSelection = true
            self.isStreamPickerPresented = true
        } else {
            self.forceStreamPicker = false
            self.isManualSelection = false
            self.isStreamPickerPresented = false
        }
        let playbackKey = prefetchKey(for: item, season: season, episode: episode)

        // Only clear streams if we don't already have pre-fetched streams for this playback key
        if prefetchedKey != playbackKey && prefetchedNextKey != playbackKey {
            self.availableStreams = []
            self.currentStreamURL = nil
        }
        self.statusText = nil
        self.consecutiveFallbacks = 0
        self.probeStatus = [:]
        self.resetPreloadState()
        self.fetchAndRaceTask?.cancel()
        self.fetchAndRaceTask = nil
        self.resolveNextEpisode()

        // Cancel in-flight prefetch only if targeting a different title,
        // allowing in-flight queries for this title to finish seamlessly.
        if warmCore?.key != playbackKey && inflightPrefetchKey != playbackKey && prefetchedKey != playbackKey {
            cancelDetailPrefetch()
        }
        
        // 0. Offline Check
        if let localUrl = DownloadManager.shared.getLocalUrl(for: item) {
            print("[PlayerManager] Playing downloaded file: \(localUrl)")
            self.currentStreamURL = localUrl
            self.isLoading = false
            return
        }
        
        // Direct Stream Check (e.g. Bonus Content, Trailers, Direct URLs)
        if let directUrl = item.streamURL {
            print("[PlayerManager] Playing direct stream: \(directUrl)")
            self.currentStreamURL = directUrl
            self.isLoading = false
            return
        }
        
        // 1. Instant Replay / Active Session Reuse Check (ONLY for Continue Watching cards and Detail View resume when not forcing picker)
        if fromContinueWatching && !forceStreamPicker {
            let historyItem = UserDataService.shared.getHistoryItem(for: item)
            let matchedId = historyItem?.id ?? item.id
            let isEpisodic = item.isSeries || season != nil || episode != nil
            let key = isEpisodic ? "\(matchedId):\(season ?? 1):\(episode ?? 1)" : "\(matchedId)"
            let fallbackKey = isEpisodic ? "\(item.id):\(season ?? 1):\(episode ?? 1)" : "\(item.id)"
            
            let isMatchingEpisode: Bool
            if isEpisodic {
                isMatchingEpisode = (historyItem?.lastSeason == season || (season == nil && historyItem?.lastSeason != nil)) &&
                                    (historyItem?.lastEpisode == episode || (episode == nil && historyItem?.lastEpisode != nil))
            } else {
                isMatchingEpisode = true
            }

            let sourceMode = UserDefaults.standard.string(forKey: UserDefaults.Key.streamingSourceMode) ?? "both"

            // Helper to verify that saved URL matches the user's active streaming filter
            func isSavedURLCompatible(_ url: URL, hash: String?) -> Bool {
                let isTorrent = (hash != nil && !hash!.isEmpty) ||
                                url.absoluteString.contains("127.0.0.1:11470") ||
                                url.scheme == "magnet" ||
                                url.absoluteString.contains("xt=urn:btih:")
                if sourceMode == "http" && isTorrent { return false }
                if sourceMode == "torrent" && !isTorrent { return false }
                return true
            }

            if let cached = lastPlayedStreams[key] ?? lastPlayedStreams[fallbackKey],
               isSavedURLCompatible(cached.url, hash: activeTorrentHash) {
                let elapsed = Date().timeIntervalSince(cached.timestamp)
                
                // If Fresh (< 24 hours), verify health and play or fall back
                if elapsed < 86400 {
                    let isFlux = UserDefaults.standard.object(forKey: UserDefaults.Key.enableFluxMode) as? Bool ?? true
                    let isHttp = cached.url.scheme == "http" || cached.url.scheme == "https"
                    let isLocal = cached.url.host == "127.0.0.1" || cached.url.host == "localhost"

                    if isHttp && !isLocal {
                        AsyncTask {
                            let isHealthy = await self.verifyStreamURLHealth(cached.url)
                            await MainActor.run {
                                if isHealthy {
                                    print("[PlayerManager] Active Stream Session Healthy: Resuming stream session immediately.")
                                    self.currentStreamURL = cached.url
                                    self.isLoading = false
                                    self.populateStreamsInBackground(item: item, season: season, episode: episode)
                                } else {
                                    print("[PlayerManager] Cached stream expired/broken. Purging and falling back...")
                                    self.lastPlayedStreams.removeValue(forKey: key)
                                    self.lastPlayedStreams.removeValue(forKey: fallbackKey)
                                    self.fetchAndRace(item: item, season: season, episode: episode, forceStreamPicker: !isFlux)
                                }
                            }
                        }
                        return
                    } else {
                        print("[PlayerManager] Active Torrent Stream Session Fresh (\(Int(elapsed/60))m): Resuming stream session immediately.")
                        self.currentStreamURL = cached.url
                        self.isLoading = false
                        if activeTorrentHash != nil {
                            AsyncTask { _ = await StremioServerManager.shared.ensureRunning() }
                        }
                        self.populateStreamsInBackground(item: item, season: season, episode: episode)
                        return
                    }
                } else {
                    self.lastPlayedStreams.removeValue(forKey: key)
                    self.lastPlayedStreams.removeValue(forKey: fallbackKey)
                }
            } else if isMatchingEpisode, let savedURL = item.lastStreamURL ?? historyItem?.lastStreamURL,
                      isSavedURLCompatible(savedURL, hash: historyItem?.lastTorrentInfoHash) {
                let elapsed = Date().timeIntervalSince(historyItem?.timestamp.map { Date(timeIntervalSince1970: $0) } ?? Date())
                if elapsed < 86400 {
                    let isFlux = UserDefaults.standard.object(forKey: UserDefaults.Key.enableFluxMode) as? Bool ?? true
                    let isHttp = savedURL.scheme == "http" || savedURL.scheme == "https"
                    let isLocal = savedURL.host == "127.0.0.1" || savedURL.host == "localhost"

                    if isHttp && !isLocal {
                        AsyncTask {
                            let isHealthy = await self.verifyStreamURLHealth(savedURL)
                            await MainActor.run {
                                if isHealthy {
                                    print("[PlayerManager] Persisted Stream Healthy: Playing \(savedURL)")
                                    self.lastPlayedStreams[key] = CachedStream(url: savedURL, timestamp: Date())
                                    self.currentStreamURL = savedURL
                                    self.isLoading = false
                                    self.populateStreamsInBackground(item: item, season: season, episode: episode)
                                } else {
                                    print("[PlayerManager] Persisted stream expired/broken. Purging and falling back...")
                                    self.lastPlayedStreams.removeValue(forKey: key)
                                    self.lastPlayedStreams.removeValue(forKey: fallbackKey)
                                    self.fetchAndRace(item: item, season: season, episode: episode, forceStreamPicker: !isFlux)
                                }
                            }
                        }
                        return
                    } else {
                        print("[PlayerManager] Persisted History Stream Available (Across Restarts): Playing \(savedURL)")
                        self.lastPlayedStreams[key] = CachedStream(url: savedURL, timestamp: Date())
                        self.currentStreamURL = savedURL
                        self.isLoading = false
                        if let hash = historyItem?.lastTorrentInfoHash {
                            self.activeTorrentHash = hash
                            AsyncTask { _ = await StremioServerManager.shared.ensureRunning() }
                        }
                        self.populateStreamsInBackground(item: item, season: season, episode: episode)
                        return
                    }
                }
            } else {
                print("[PlayerManager] Saved session is incompatible with current stream filter '\(sourceMode)' or missing. Fetching fresh streams...")
            }
        }
        
        // 2. Normal Flow (Fetch and race, or show stream picker if forceStreamPicker / from detail view)
        fetchAndRace(item: item, season: season, episode: episode, forceStreamPicker: forceStreamPicker)
    }

    private func verifyStreamURLHealth(_ url: URL) async -> Bool {
        if url.host == "127.0.0.1" || url.host == "localhost" {
            return true
        }
        guard url.scheme == "http" || url.scheme == "https" else { return true }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 1.8
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                return (200...399).contains(http.statusCode) || http.statusCode == 405
            }
            return false
        } catch {
            print("[PlayerManager] Cached stream health probe failed for \(url.host ?? ""): \(error.localizedDescription)")
            return false
        }
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

    /// Manual picker refresh ("Choose Stream Source…", header refresh button):
    /// re-queries every enabled addon bypassing the 24h cache and streams results
    /// into `availableStreams` progressively as each addon responds — Stremio-style.
    /// Slow scraping addons (PenguPlay, WebStreamrMBG) arrive whenever they finish;
    /// fast ones are never held back. Never touches playback state.
    func refreshStreamsForPicker() {
        guard let item = currentItem else { return }
        let season = currentSeason, episode = currentEpisode
        isFetchingStreams = true
        AsyncTask {
            let streams = await StreamManager.shared.fetchStreamsRealtime(
                for: item,
                season: season,
                episode: episode,
                forceRefresh: true,
                onProgress: { loaded, total, pending in
                    Task { @MainActor in
                        self.loadedAddonsCount = loaded
                        self.totalAddonsCount = total
                        self.pendingAddonNames = pending
                    }
                }
            ) { updatedStreams in
                Task { @MainActor in
                    self.availableStreams = updatedStreams
                    self.verifyStreamHealth(updatedStreams)
                }
            }
            await MainActor.run {
                self.availableStreams = streams
                self.isFetchingStreams = false
                self.loadedAddonsCount = self.totalAddonsCount
                self.pendingAddonNames = []
                self.verifyStreamHealth(streams)
            }
        }
    }

    private func fetchAndRace(item: MediaItem, season: Int?, episode: Int?, forceStreamPicker: Bool = false) {
        self.isFetchingStreams = true
        self.isLoading = true

        self.fetchAndRaceTask?.cancel()
        self.fetchAndRaceTask = AsyncTask { [weak self] in
            guard let self = self else { return }

            func isStillCurrentTarget() async -> Bool {
                guard !Task.isCancelled else { return false }
                return await MainActor.run {
                    self.currentItem?.id == item.id && self.currentSeason == season && self.currentEpisode == episode
                }
            }

            // ⚡ ADVANCED LOADING fast-path (Flux Mode): if not forcing stream picker
            let key = self.prefetchKey(for: item, season: season, episode: episode)
            let isFluxEnabled = UserDefaults.standard.object(forKey: UserDefaults.Key.enableFluxMode) as? Bool ?? true
            
            let isDetailHit = (self.prefetchedKey == key && self.prefetchedStream != nil)
            let isNextHit = (self.prefetchedNextKey == key && self.prefetchedNextStream != nil)
            
            if !forceStreamPicker, isFluxEnabled, (isDetailHit || isNextHit) {
                guard await isStillCurrentTarget() else { return }
                let pf = isDetailHit ? self.prefetchedStream! : self.prefetchedNextStream!
                let subs = (isDetailHit ? self.prefetchedSubtitles : self.prefetchedNextSubtitles) ?? []
                let sourceMode = UserDefaults.standard.string(forKey: UserDefaults.Key.streamingSourceMode) ?? "both"
                let cached = (await StreamManager.shared.getCachedStreams(for: item, season: season, episode: episode) ?? [pf]).filter { s in
                    if sourceMode == "http" { return !s.isTorrent }
                    if sourceMode == "torrent" { return s.isTorrent }
                    return true
                }
                guard await isStillCurrentTarget() else { return }
                await MainActor.run {
                    self.availableStreams = cached
                    self.verifyStreamHealth(cached)
                    self.externalSubtitles = subs
                    self.isLoading = false
                    self.isFetchingStreams = false
                    self.loadedAddonsCount = self.totalAddonsCount
                    self.pendingAddonNames = []
                    self.finishSelect(pf)
                }
                return
            }

            if let cachedStreams = await StreamManager.shared.getCachedStreams(for: item, season: season, episode: episode), !cachedStreams.isEmpty {
                if await isStillCurrentTarget() {
                    print("[PlayerManager] Cache Hit! Ready to display available streams.")
                    await MainActor.run {
                        self.availableStreams = cachedStreams
                    }
                }
            }

            async let subsTask = SubtitleManager.shared.fetchSubtitles(for: item, season: season, episode: episode)
            
            let streams = await StreamManager.shared.fetchStreamsRealtime(
                for: item,
                season: season,
                episode: episode,
                forceRefresh: forceStreamPicker,
                onProgress: { loaded, total, pending in
                    Task { @MainActor in
                        guard self.currentItem?.id == item.id && self.currentSeason == season && self.currentEpisode == episode else { return }
                        self.loadedAddonsCount = loaded
                        self.totalAddonsCount = total
                        self.pendingAddonNames = pending
                    }
                }
            ) { updatedStreams in
                Task { @MainActor in
                    guard self.currentItem?.id == item.id && self.currentSeason == season && self.currentEpisode == episode else { return }
                    self.availableStreams = updatedStreams
                    self.verifyStreamHealth(updatedStreams)
                }
            }

            guard await isStillCurrentTarget() else {
                print("[PlayerManager] In-flight stream fetch cancelled/superseded for \(item.title) S\(season ?? 0):E\(episode ?? 0)")
                return
            }
            
            await MainActor.run {
                self.availableStreams = streams
                self.isFetchingStreams = false
                self.loadedAddonsCount = self.totalAddonsCount
                self.pendingAddonNames = []
                self.verifyStreamHealth(streams)
            }

            let extraSubs = await subsTask
            guard await isStillCurrentTarget() else { return }

            await MainActor.run {
                self.externalSubtitles = extraSubs
            }
            
            // If the user already made a stream selection while background fetching was underway,
            // do not disrupt active playback or re-open the stream picker.
            let hasActiveSelection = await MainActor.run { () -> Bool in
                return self.currentSelectedStream != nil || self.currentStreamURL != nil
            }
            if hasActiveSelection {
                print("[PlayerManager] Stream fetch completed after stream was already chosen. Preserving active playback.")
                await MainActor.run {
                    self.isLoading = false
                }
                return
            }

            // If user or caller requested the Stream Selector UI and hasn't yet made a selection:
            if forceStreamPicker || self.forceStreamPicker {
                await MainActor.run {
                    self.isLoading = false
                    self.isStreamPickerPresented = true
                }
                return
            }

            // If no streams were discovered at all
            if streams.isEmpty {
                await MainActor.run {
                    self.availableStreams = []
                    self.isLoading = false
                    self.currentStreamURL = nil
                    let sourceMode = UserDefaults.standard.string(forKey: UserDefaults.Key.streamingSourceMode) ?? "both"
                    if sourceMode == "http" {
                        self.errorMessage = "No streams found for this title."
                    } else if sourceMode == "torrent" {
                        self.errorMessage = "No streams found for this title."
                    } else {
                        self.errorMessage = "No streams found for this title."
                    }
                }
                return
            }

            // Flux Mode Auto-Play Engine
            if isFluxEnabled, !streams.isEmpty {
                if let winner = await self.raceBestStream(from: streams) {
                    guard await isStillCurrentTarget() else {
                        print("[PlayerManager] Discarding Flux Mode stream winner because user selected another title/episode.")
                        return
                    }
                    let selectionMade = await MainActor.run { () -> Bool in
                        return self.currentSelectedStream != nil || self.currentStreamURL != nil
                    }
                    if selectionMade {
                        print("[PlayerManager] Stream already selected manually; discarding auto-play winner.")
                        return
                    }
                    print("[PlayerManager] Flux Mode selected stream: \(winner.cleanTitle) (\(winner.source))")
                    await MainActor.run {
                        self.isManualSelection = false
                        self.attemptStream(winner)
                    }
                    return
                }
            }
            
            // Fallback: Show list
            guard await isStillCurrentTarget() else { return }
            let selectionMade = await MainActor.run { () -> Bool in
                return self.currentSelectedStream != nil || self.currentStreamURL != nil
            }
            if !selectionMade {
                await MainActor.run {
                    self.availableStreams = streams
                    self.isLoading = false
                    self.isStreamPickerPresented = true
                }
            }
        }
    }
    
    // Flux Mode source pick:
    // Leverages selectFastStartCandidate with quality cap, language match, and speed scoring.
    // Stashes standby fallbacks and warms HTTP candidates in the background.
    private func raceBestStream(from streams: [Stream]) async -> Stream? {
        let healthy = streams.filter { !isHashRecentlyDead($0) }
        guard !healthy.isEmpty else { return nil }

        let sourceMode = UserDefaults.standard.string(forKey: UserDefaults.Key.streamingSourceMode) ?? "both"
        let preferredQuality = UserDefaults.standard.string(forKey: UserDefaults.Key.preferredQuality) ?? "4K"
        let preferredLang = UserDefaults.standard.string(forKey: "defaultAudioLang") ?? "English"
        let enableLanguageFilter = UserDefaults.standard.bool(forKey: "enableFluxLanguageFilter")

        let (primary, fallbacks) = StreamManager.shared.selectFastStartCandidate(
            from: healthy,
            sourceMode: sourceMode,
            preferredQuality: preferredQuality,
            preferredLang: preferredLang,
            originalLanguage: currentItem?.originalLanguage,
            enableLanguageFilter: enableLanguageFilter,
            probeStatus: self.probeStatus,
            targetSeason: currentSeason,
            targetEpisode: currentEpisode
        )

        guard let winnerCandidate = primary else { return nil }

        // If in HTTP mode or candidate is HTTP, concurrently probe top candidates
        // to find the first alive (200-399) HTTP stream and discard dead ones (404/timeouts).
        if sourceMode == "http" || !winnerCandidate.isTorrent {
            let allHttp = ([winnerCandidate] + fallbacks).filter { !$0.isTorrent }
            if !allHttp.isEmpty {
                let (verifiedWinner, verifiedFallbacks) = await raceAndVerifyHTTPCandidates(Array(allHttp.prefix(6)))
                if let verified = verifiedWinner {
                    await MainActor.run {
                        self.standbyFallbacks = verifiedFallbacks + fallbacks.filter { $0.isTorrent }
                    }
                    print("[PlayerManager] ⚡ Flux Mode verified alive HTTP stream: \(verified.cleanTitle) (\(verified.quality))")
                    return verified
                } else if sourceMode == "http" {
                    print("[PlayerManager] All candidate HTTP streams failed HEAD verification (404/expired/timeout).")
                    return nil
                }
            }
        }

        await MainActor.run {
            self.standbyFallbacks = fallbacks
        }

        // Background probe HTTP fallbacks so their socket and TLS are hot
        let httpFallbacks = fallbacks.filter { !$0.isTorrent }
        if !httpFallbacks.isEmpty {
            AsyncTask {
                _ = await self.raceAndVerifyHTTPCandidates(Array(httpFallbacks.prefix(3)))
            }
        }

        return winnerCandidate
    }

    /// Races HTTP candidates in parallel via ranged GET requests with a 3.0s timeout.
    /// Preserves original ranked preference order: top-ranked stream that responds wins!
    private func raceAndVerifyHTTPCandidates(_ candidates: [Stream]) async -> (winner: Stream?, verifiedFallbacks: [Stream]) {
        guard !candidates.isEmpty else { return (nil, []) }

        return await withTaskGroup(of: (Stream, Bool).self) { group in
            for stream in candidates {
                let playableURL = self.getPlayableURL(for: stream)
                group.addTask {
                    var request = URLRequest(url: playableURL)
                    request.httpMethod = "GET"
                    request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
                    request.timeoutInterval = 3.0
                    do {
                        let (_, response) = try await URLSession.shared.data(for: request)
                        if let http = response as? HTTPURLResponse, (200...399).contains(http.statusCode) {
                            return (stream, true)
                        }
                        return (stream, false)
                    } catch {
                        return (stream, false)
                    }
                }
            }

            var results: [String: Bool] = [:]
            for await (stream, ok) in group {
                results[stream.stableKey] = ok
                if !ok {
                    await MainActor.run {
                        self.probeStatus[stream.stableKey] = StreamProbeResult(ok: false, latency: 99)
                    }
                }
            }

            // CRITICAL: Preserve original candidate preference ranking
            let verified = candidates.filter { results[$0.stableKey] == true }
            guard let winner = verified.first else {
                return (nil, [])
            }
            let verifiedFallbacks = Array(verified.dropFirst())
            return (winner, verifiedFallbacks)
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
    /// For HTTP streams with proxyHeaders, routes through the local proxy.
    func getPlayableURL(for stream: Stream) -> URL {
        if stream.isTorrent {
            let str = stream.url.absoluteString
            if let hashRange = str.range(of: #"btih:([a-fA-F0-9]{32,40})"#, options: .regularExpression) {
                let hash = String(str[hashRange]).replacingOccurrences(of: "btih:", with: "")
                // Firewall: never construct engine URLs from unvalidated hashes.
                guard Self.validInfoHash(hash) else { return stream.url }
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

        let target = stream.url
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
        self.currentSelectedStream = stream
        self.isManualSelection = true
        self.forceStreamPicker = false
        self.isStreamPickerPresented = false
        self.hasConfirmedPlaybackSuccess = false
        attemptStream(stream)
    }

    /// Two-phase playback (Stremio-style): torrents are resolved by the Stremio server,
    /// then the URL is handed to mpv. Dead sources fail and fall through to next candidate.
    private func attemptStream(_ stream: Stream) {
        self.currentSelectedStream = stream
        let isFluxEnabled = UserDefaults.standard.object(forKey: UserDefaults.Key.enableFluxMode) as? Bool ?? true

        // Cancel any existing startup watchdog
        startupWatchdogTask?.cancel()
        startupWatchdogTask = nil
        lastTelemetryProgressTime = nil
        lastObservedCacheTime = 0.0

        // Set up smart startup watchdog in Flux Mode with stall detection
        if isFluxEnabled && !isManualSelection {
            let connectTimeout: TimeInterval = stream.isTorrent ? 18.0 : 14.0
            print("[PlayerManager] ⏱️ Armed startup stall watchdog for \(stream.cleanTitle) (\(stream.quality)): connect timeout \(Int(connectTimeout))s")
            let startedAt = Date()
            startupWatchdogTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // check every 1s
                    guard !Task.isCancelled else { return }

                    let shouldAdvance = await MainActor.run { () -> Bool in
                        guard let self = self else { return false }
                        if self.hasPlaybackStarted { return false }

                        let elapsed = Date().timeIntervalSince(startedAt)

                        // If bytes have started flowing (telemetry received):
                        if let lastProgress = self.lastTelemetryProgressTime {
                            let stallDuration = Date().timeIntervalSince(lastProgress)
                            // Stall timeout: 6 seconds of ZERO new bytes after connection was established
                            if stallDuration >= 6.0 {
                                print("[PlayerManager] ⏱️ Stream stall detected (zero bytes for \(Int(stallDuration))s). Auto-advancing to standby fallback...")
                                self.advanceToStandbyFallback()
                                return true
                            }
                            return false
                        }

                        // Connecting phase: no bytes received yet
                        if elapsed >= connectTimeout {
                            print("[PlayerManager] ⏱️ Stream connect timeout (\(Int(connectTimeout))s, no response). Auto-advancing to standby fallback...")
                            self.advanceToStandbyFallback()
                            return true
                        }

                        return false
                    }

                    if shouldAdvance { break }
                }
            }
        }

        // Skip recently-dead hashes for AUTO selection only — an explicit user
        // click must always be attempted (the dead mark may be stale).
        if isFluxEnabled && !isManualSelection && isHashRecentlyDead(stream) && stream.isTorrent {
            advancePast(stream)
            return
        }

        if stream.isTorrent {
            // Client firewall: malformed hashes never reach the engine.
            guard let hash = torrentHash(stream) else {
                print("[PlayerManager] Rejecting torrent source with invalid infohash")
                advancePast(stream)
                return
            }
            // Remove the old torrent before registering a new one to prevent
            // double downloads when auto-falling-back to a different source.
            if let oldHash = activeTorrentHash, oldHash != hash {
                StremioServerManager.shared.removeTorrent(infoHash: oldHash)
            }
            activeTorrentHash = hash
            // Stremio-exact flow: register the torrent on the server (fire-and-forget)
            // and hand the URL to mpv IMMEDIATELY. The server blocks the file response
            // until pieces flow, mpv reports paused-for-cache → buffering overlay shows.
            // Awaiting /create here would stall the UI on metadata fetch (slow swarms)
            // and time out — the torrent still registers server-side, which is why a
            // second click "suddenly works".
            DispatchQueue.main.async { self.statusText = "Connecting to source…" }
            AsyncTask {
                let serverUp = await StremioServerManager.shared.ensureRunning()
                if serverUp {
                    // Fire-and-forget — do NOT block playback on metadata fetch.
                    let magnetURL = stream.url.absoluteString
                    StremioServerManager.shared.trackCreate(
                        infoHash: hash,
                        magnetURL: magnetURL,
                        fileIdx: stream.fileIdx ?? 0
                    )
                    AsyncTask { _ = await self.resolveTorrentStream(stream) }
                }
                await MainActor.run {
                    self.statusText = nil
                    if serverUp {
                        self.consecutiveFallbacks = 0
                        self.finishSelect(stream)
                    } else if isFluxEnabled {
                        advancePast(stream)
                    } else {
                        self.isLoading = false
                        self.errorMessage = "Streaming server unavailable"
                    }
                }
            }
        } else {
            // HTTP stream — hand the URL directly to mpv (Stremio-style).
            finishSelect(stream)
        }
    }

    func markPlaybackStarted() {
        hasPlaybackStarted = true
        startupWatchdogTask?.cancel()
        startupWatchdogTask = nil
    }

    func cancelStartupWatchdog() {
        startupWatchdogTask?.cancel()
        startupWatchdogTask = nil
    }

    func reportTelemetryProgress(cacheTime: Double) {
        if cacheTime > lastObservedCacheTime + 0.05 {
            lastObservedCacheTime = cacheTime
            lastTelemetryProgressTime = Date()
        }
        if cacheTime >= 1.5 {
            cancelStartupWatchdog()
        }
    }

    func advanceToStandbyFallback() {
        guard !isManualSelection else { return }
        startupWatchdogTask?.cancel()
        startupWatchdogTask = nil

        guard !standbyFallbacks.isEmpty else {
            print("[PlayerManager] No standby fallbacks remaining — falling back to standard next stream.")
            tryNextStream()
            return
        }

        let fallback = standbyFallbacks.removeFirst()
        print("[PlayerManager] ⚡ Seamlessly advancing to standby fallback: \(fallback.cleanTitle) (\(fallback.source))")

        // If the old stream was a torrent that stalled, clean it up and mark dead
        if let currentURL = currentStreamURL, let oldStream = availableStreams.first(where: { getPlayableURL(for: $0) == currentURL }) {
            if oldStream.isTorrent, let oldHash = torrentHash(oldStream) {
                markHashDead(oldStream)
                StremioServerManager.shared.removeTorrent(infoHash: oldHash)
            }
        }

        attemptStream(fallback)
    }

    private func finishSelect(_ stream: Stream) {
        let targetURL = getPlayableURL(for: stream)
        self.currentStreamURL = targetURL
        let hash = stream.isTorrent ? torrentHash(stream) : nil
        if stream.isTorrent, let h = hash {
            self.currentMagnetURL = stream.url.absoluteString.hasPrefix("magnet:") ? stream.url.absoluteString : "magnet:?xt=urn:btih:\(h)"
        } else {
            self.currentMagnetURL = nil
        }
        self.isLoading = false
        self.errorMessage = nil

        UserDefaults.standard.set(stream.source, forKey: UserDefaults.Key.lastUsedSource)
    }

    /// After a failed attempt, move on to the next candidate in the ranked list.
    /// Bounded: after maxAutoFallbacks consecutive failures, stop and show the
    /// stream picker instead of cascading silently for minutes.
    /// Never auto-advance when the user explicitly picked a source (manual mode).
    private func advancePast(_ failed: Stream) {
        invalidateCachedStream(for: currentItem, season: currentSeason, episode: currentEpisode)
        guard !isManualSelection else {
            // Manual pick failed — surface error, don't silently swap sources.
            errorMessage = "Couldn't load this source — the swarm looks too weak right now. Pick another one."
            return
        }

        if !standbyFallbacks.isEmpty {
            advanceToStandbyFallback()
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
            let nextStream = availableStreams[next]
            attemptStream(nextStream)
        } else {
            errorMessage = "All top sources failed to stream. Please pick another stream manually."
            statusText = nil
            isLoading = false
            currentStreamURL = nil
        }
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
        guard var item = currentItem, duration > 0 else { return }
        let progress = time / duration
        if item.runtime == nil || item.runtime?.isEmpty == true {
            let totalMinutes = Int(duration) / 60
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            if hours > 0 {
                item.runtime = minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
            } else if minutes > 0 {
                item.runtime = "\(minutes)m"
            }
        }
        // Completed episode (progress >= 90%): advance Continue Watching to the
        // next *released* episode (async — may fetch season listings). EOF calls
        // completeEpisode directly so natural ends count even under 90%.
        if (item.category == "TV Show" || currentSeason != nil), progress >= 0.90,
           let s = currentSeason, let e = currentEpisode {
            let snapshot = item
            Task { @MainActor [weak self] in
                await self?.completeEpisode(item: snapshot, season: s, episode: e, duration: duration, autoplay: false, cancelled: true, pickerVisible: true)
            }
        } else {
            UserDataService.shared.addToHistory(
                item,
                progress: progress,
                season: currentSeason,
                episode: currentEpisode,
                episodeImage: currentEpisodeImage,
                playbackPosition: time,
                playbackDuration: duration,
                streamURL: currentStreamURL,
                torrentInfoHash: activeTorrentHash,
                fileIndex: nil
            )
        }
        TasteProfileManager.shared.recordWatch(item, progress: progress)
    }

    /// Episodes already run through completion (per session). Prevents repeated
    /// season fetches from the 5-second progress saver while credits roll.
    private var attemptedAdvances = Set<String>()
    private var lastCompletedEpisodeKey = ""

    /// Records episode completion: advances Continue Watching to the next
    /// *released* episode, or autoplays it when requested. Safe to call
    /// repeatedly (idempotent per episode). Clips under 5 minutes can never
    /// advance a series (kills phantom jumps from mislabeled micro-streams).
    func completeEpisode(item: MediaItem, season: Int, episode: Int, duration: Double, autoplay: Bool, cancelled: Bool, pickerVisible: Bool) async {
        guard duration >= 300 else { return }
        let key = "\(item.id):\(season):\(episode)"
        guard !attemptedAdvances.contains(key) else { return }
        attemptedAdvances.insert(key)
        guard let next = await resolveNextReleased(item: item, season: season, episode: episode) else { return }
        if autoplay && !cancelled && !pickerVisible {
            // Play explicitly with resolved values (never recompute-and-diverge).
            let nextImage = self.nextEpisode?.stillURL ?? self.currentEpisodeImage
            self.play(item, season: next.season, episode: next.episode, episodeImage: nextImage, isAutoAdvance: true)
            return
        }
        if let stored = UserDataService.shared.getHistoryItem(for: item),
           stored.lastSeason == next.season && stored.lastEpisode == next.episode { return }
        UserDataService.shared.addToHistory(
            item,
            progress: 0.0,
            season: next.season,
            episode: next.episode,
            episodeImage: nil,
            playbackPosition: 0.0,
            playbackDuration: duration,
            streamURL: nil,
            torrentInfoHash: nil,
            fileIndex: nil
        )
    }

    func handleSignOut() {
        close()
        DispatchQueue.main.async {
            self.lastPlayedStreams = [:]
        }
    }

    func close() {
        DispatchQueue.main.async {
            SleepAssertionManager.shared.playerDidClose()
            self.cancelDetailPrefetch()
            self.fetchAndRaceTask?.cancel()
            self.fetchAndRaceTask = nil
            // When closing the player, MPV stops reading from the stream, naturally
            // pausing downloads in FluxEngine while preserving verified cache on disk.
            self.currentItem = nil
            // Don't clear lastPlayedStreams, it persists for the session
            self.currentStreamURL = nil
            self.currentMagnetURL = nil
            self.currentSelectedStream = nil
            self.forceStreamPicker = false
            self.isStreamPickerPresented = false
            self.hasConfirmedPlaybackSuccess = false
            self.availableStreams = []
            self.probeStatus = [:]
            self.externalSubtitles = []
            self.isLoading = false
            self.errorMessage = nil
            self.currentSeason = nil
            self.currentEpisode = nil
            self.currentEpisodeImage = nil
            self.nextEpisode = nil
            // Session over — a held warm core is stale now.
            self.prefetchedKey = nil
            self.prefetchedStream = nil
            self.prefetchedSubtitles = nil
            self.discardWarmCore()
            self.sessionController?.resetVolumeBoostIfNeeded()
            self.endSession()

            // Run cache eviction in background to strictly enforce the user's cache limit (e.g. 2 GB)
            AsyncTask {
                await StremioServerManager.shared.evictCacheIfNeeded()
            }
        }
    }
    
    // MARK: - Next Episode Logic
    
    var nextEpisodeInfo: (season: Int, episode: Int)? {
        guard let item = currentItem,
              let currentSeasonNum = currentSeason,
              let currentEpisodeNum = currentEpisode else { return nil }
        return countBasedNext(seasons: item.seasons, season: currentSeasonNum, episode: currentEpisodeNum)
    }

    /// Count-based next episode (legacy semantics, no air-date knowledge).
    private func countBasedNext(seasons: [Season]?, season: Int, episode: Int) -> (season: Int, episode: Int)? {
        guard let seasons else { return nil }
        // 1. Check current season
        if let currentSeasonObj = seasons.first(where: { $0.seasonNumber == season }) {
            if episode < currentSeasonObj.episodeCount {
                return (season, episode + 1)
            }
        }
        // 2. Check next season
        let nextSeasonNum = season + 1
        if seasons.contains(where: { $0.seasonNumber == nextSeasonNum }) {
            return (nextSeasonNum, 1)
        }
        return nil
    }

    private static let airedDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// True when the episode has aired (or its air date is unknown — unprovable
    /// unreleased episodes are allowed; only known-future ones are blocked).
    private func airedOrUnknown(_ airDate: String?) -> Bool {
        guard let airDate, !airDate.isEmpty else { return true }
        guard let date = Self.airedDateFormatter.date(from: String(airDate.prefix(10))) else { return true }
        return Calendar.current.startOfDay(for: date) <= Calendar.current.startOfDay(for: Date())
    }

    /// Air-date verdict for the episode after (season, episode), plus whether
    /// episode listings actually covered the decision. Returns legacy
    /// count-based info when uncovered; nil only when coverage proves nothing
    /// released is next (unaired or absent from a covered season).
    private func releaseVerdict(episodes: [Episode]?, seasons: [Season]?, season cs: Int, episode ce: Int) -> (next: (season: Int, episode: Int)?, covered: Bool) {
        if let eps = episodes, !eps.isEmpty {
            let seasonEps = eps.filter { $0.seasonNumber == cs }
            if !seasonEps.isEmpty {
                if let nxt = seasonEps.filter({ $0.episodeNumber > ce }).min(by: { $0.episodeNumber < $1.episodeNumber }) {
                    return (airedOrUnknown(nxt.airDate) ? (cs, nxt.episodeNumber) : nil, true)
                }
                let nextSeasonEps = eps.filter { $0.seasonNumber == cs + 1 }
                if !nextSeasonEps.isEmpty {
                    if let e1 = nextSeasonEps.first(where: { $0.episodeNumber == 1 }) {
                        return (airedOrUnknown(e1.airDate) ? (cs + 1, 1) : nil, true)
                    }
                    return (nil, true)
                }
                return (countBasedNext(seasons: seasons, season: cs, episode: ce), false)
            }
        }
        return (countBasedNext(seasons: seasons, season: cs, episode: ce), false)
    }

    /// Air-date-aware next episode. Behaves like nextEpisodeInfo, except an
    /// episode known to be unaired (or absent from a season listing covering
    /// its season) resolves to nil instead of being offered/auto-played.
    var nextReleasedEpisodeInfo: (season: Int, episode: Int)? {
        guard let item = currentItem,
              let cs = currentSeason,
              let ce = currentEpisode else { return nil }
        return releaseVerdict(episodes: item.episodes, seasons: item.seasons, season: cs, episode: ce).next
    }

    private func tmdbID(for item: MediaItem) async -> String? {
        let clean = item.id.replacingOccurrences(of: "tmdb-", with: "").replacingOccurrences(of: "tmdb:", with: "")
        if !clean.isEmpty, CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: clean)) {
            return clean
        }
        if item.id.starts(with: "tt") {
            return await TMDBEnricher.shared.resolveTmdbID(imdbID: item.id, type: "tv")
        }
        return nil
    }

    /// Resolves the next *released* episode, fetching season listings when the
    /// in-memory item lacks them (e.g. resumed from Continue Watching).
    /// Falls back to legacy count-based info only when air dates can't be
    /// established anywhere. Nil = nothing aired is next (hold the rail).
    func resolveNextReleased(item: MediaItem, season: Int, episode: Int) async -> (season: Int, episode: Int)? {
        let (syncNext, covered) = releaseVerdict(episodes: item.episodes, seasons: item.seasons, season: season, episode: episode)
        // A positively-aired verdict is final (air dates can't un-happen).
        if covered, let syncNext { return syncNext }
        // Covered-nil (stale listings?) or uncovered: verify against TMDB.
        if TMDBEnricher.shared.hasKey, let tvId = await tmdbID(for: item), !Task.isCancelled {
            let fetched = await TMDBEnricher.shared.fetchSeasonEpisodes(tvId: tvId, seasonNumber: season)
            if !fetched.isEmpty {
                let (fNext, fCovered) = releaseVerdict(episodes: fetched, seasons: nil, season: season, episode: episode)
                if fCovered {
                    if fNext == nil {
                        // Same season exhausted per authoritative listing — check next season premiere.
                        let nextSeas = await TMDBEnricher.shared.fetchSeasonEpisodes(tvId: tvId, seasonNumber: season + 1)
                        if let e1 = nextSeas.first(where: { $0.episodeNumber == 1 }), airedOrUnknown(e1.airDate) {
                            return (season + 1, 1)
                        }
                        return nil
                    }
                    return fNext
                }
            }
        }
        return syncNext
    }

    func resolveNextEpisode() {
        guard let item = currentItem, let next = nextEpisodeInfo else {
            self.nextEpisode = nil
            return
        }

        // 1. Check currentItem.episodes
        if let ep = item.episodes?.first(where: { $0.seasonNumber == next.season && $0.episodeNumber == next.episode }) {
            self.nextEpisode = ep
            return
        }

        // 2. Check currentItem.seasons
        if let season = item.seasons?.first(where: { $0.seasonNumber == next.season }),
           let ep = season.episodes?.first(where: { $0.episodeNumber == next.episode }) {
            self.nextEpisode = ep
            return
        }

        // 3. Background fetch from Stremio Service
        AsyncTask { [weak self] in
            guard let self = self else { return }
            if let meta = try? await StremioService.shared.fetchMeta(type: "series", id: item.id),
               let ep = meta.episodes?.first(where: { $0.seasonNumber == next.season && $0.episodeNumber == next.episode }) {
                await MainActor.run {
                    guard self.currentItem?.id == item.id,
                          self.currentSeason == next.season || self.nextEpisodeInfo?.season == next.season else { return }
                    self.nextEpisode = ep
                    // Backfill listings so air-gated math + rail advancement work
                    // for items resumed from Continue Watching (which carry no
                    // seasons/episodes arrays). Never clobbers richer data.
                    // (fetchMeta already returns a full MediaItem.)
                    if var cur = self.currentItem, cur.id == item.id {
                        var changed = false
                        if (cur.episodes == nil || cur.episodes?.isEmpty == true), let meps = meta.episodes, !meps.isEmpty {
                            cur.episodes = meps
                            changed = true
                        }
                        if (cur.seasons == nil || cur.seasons?.isEmpty == true), let mseas = meta.seasons, !mseas.isEmpty {
                            cur.seasons = mseas
                            changed = true
                        }
                        if changed { self.currentItem = cur }
                    }
                }
            }
        }
    }
    
    func playNextEpisode() {
        // Air-gated: never offer or auto-play an episode known to be unaired.
        guard let next = nextReleasedEpisodeInfo, let item = currentItem else { return }
        print("[PlayerManager] ⚡ Playing Next Episode: S\(next.season):E\(next.episode)")
        
        let nextImage = self.nextEpisode?.stillURL ?? self.currentEpisodeImage
        
        self.play(
            item,
            season: next.season,
            episode: next.episode,
            episodeImage: nextImage,
            isAutoAdvance: true
        )
    }
    
    // MARK: - Smart Preloading (Next Episode)
    
    private var hasPreloadedNext = false
    
    func resetPreloadState() {
        hasPreloadedNext = false
        prefetchedNextKey = nil
        prefetchedNextStream = nil
        prefetchedNextSubtitles = nil
        prefetchedNextAt = nil
    }
    
    func preloadNextEpisodeIfNeeded() {
        let isFluxEnabled = UserDefaults.standard.object(forKey: UserDefaults.Key.enableFluxMode) as? Bool ?? true
        guard isFluxEnabled else { return }
        guard !hasPreloadedNext, let next = nextEpisodeInfo, let item = currentItem else { return }
        hasPreloadedNext = true
        let nextKey = prefetchKey(for: item, season: next.season, episode: next.episode)
        print("[PlayerManager] ⚡ AIO Smart Preloading Next Episode: S\(next.season):E\(next.episode)")
        
        AsyncTask { [weak self] in
            guard let self = self else { return }
            async let subsTask = SubtitleManager.shared.fetchSubtitles(for: item, season: next.season, episode: next.episode)
            let streams = await StreamManager.shared.fetchStreamsRealtime(for: item, season: next.season, episode: next.episode) { _ in }
            guard !streams.isEmpty else { return }

            let sourceMode = UserDefaults.standard.string(forKey: UserDefaults.Key.streamingSourceMode) ?? "both"
            let preferredQuality = UserDefaults.standard.string(forKey: UserDefaults.Key.preferredQuality) ?? "4K"
            let preferredLang = UserDefaults.standard.string(forKey: "defaultAudioLang") ?? "English"
            let enableLanguageFilter = UserDefaults.standard.bool(forKey: "enableFluxLanguageFilter")

            let (bestNext, _) = StreamManager.shared.selectFastStartCandidate(
                from: streams,
                sourceMode: sourceMode,
                preferredQuality: preferredQuality,
                preferredLang: preferredLang,
                originalLanguage: item.originalLanguage,
                enableLanguageFilter: enableLanguageFilter,
                probeStatus: await MainActor.run { self.probeStatus },
                targetSeason: next.season,
                targetEpisode: next.episode
            )

            guard let winner = bestNext else { return }

            // Pre-warm the next episode source (AIOStreams style)
            if winner.isTorrent {
                if let hash = self.torrentHash(winner) {
                    StremioServerManager.shared.trackCreate(
                        infoHash: hash,
                        magnetURL: winner.url.absoluteString,
                        fileIdx: winner.fileIdx ?? 0
                    )
                    _ = await self.resolveTorrentStream(winner)
                }
            } else {
                Self.warmHTTP(url: self.getPlayableURL(for: winner))
            }

            let subs = await subsTask
            await MainActor.run {
                self.prefetchedNextStream = winner
                self.prefetchedNextSubtitles = subs
                self.prefetchedNextKey = nextKey
                self.prefetchedNextAt = Date()
                print("[PlayerManager] ⚡ Next Episode preloaded & primed: \(winner.cleanTitle)")
            }
        }
    }
    
    // MARK: - Fallback Logic

    func tryNextStream() {
        invalidateCachedStream(for: currentItem, season: currentSeason, episode: currentEpisode)
        // MANUAL MODE: show error but keep currentStreamURL so the buffering
        // overlay stays visible. The error view renders on top. When the user
        // dismisses the error, we clear the URL to reveal the picker.
        if isManualSelection {
            print("[PlayerManager] Manual-mode playback failed — showing error, keeping overlay.")
            errorMessage = "Playback failed for the selected source. Please pick another one."
            return
        }

        if !standbyFallbacks.isEmpty {
            advanceToStandbyFallback()
            return
        }

        let sourceMode = UserDefaults.standard.string(forKey: UserDefaults.Key.streamingSourceMode) ?? "both"
        let filteredStreams: [Stream]
        if sourceMode == "http" {
            filteredStreams = availableStreams.filter { !$0.isTorrent }
        } else if sourceMode == "torrent" {
            filteredStreams = availableStreams.filter { $0.isTorrent }
        } else {
            filteredStreams = availableStreams
        }

        guard !filteredStreams.isEmpty else {
            errorMessage = "No playable \(sourceMode) sources available."
            return
        }

        let currentIndex: Int?
        if let currentURL = currentStreamURL {
            currentIndex = filteredStreams.firstIndex(where: { s in
                if s.url == currentURL { return true }
                let playable = getPlayableURL(for: s)
                return playable == currentURL || playable.absoluteString == currentURL.absoluteString
            })
        } else {
            currentIndex = nil
        }

        let nextIndex = currentIndex.map { $0 + 1 } ?? 0
        if nextIndex < filteredStreams.count {
            let nextStream = filteredStreams[nextIndex]
            print("[PlayerManager] Current stream failed. Trying next (\(nextIndex + 1)/\(filteredStreams.count)): \(nextStream.cleanTitle)")
            attemptStream(nextStream)
        } else {
            print("[PlayerManager] All \(sourceMode) streams exhausted.")
            errorMessage = "All top sources failed to stream. Please pick another source manually."
        }
    }
}
