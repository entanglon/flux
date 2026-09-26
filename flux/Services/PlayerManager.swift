import SwiftUI
import Combine
import _Concurrency
import OSLog

typealias AsyncTask = _Concurrency.Task

struct StreamProbeResult {
    let ok: Bool
    let latency: Double
    /// Measured sustained throughput (KB/s) from the parallel ranged-GET
    /// probe race. nil = not measured (HEAD-only probe or torrent swarm data).
    var throughputKBps: Double? = nil
    /// Upstream served an HTML interstitial / JSON error / junk body instead
    /// of media — the MovieBox-style hijack class.
    var hijacked: Bool = false
}

/// Stores information about an active season pack to link strictly for auto-playing the next episode.
/// Works uniformly for BitTorrent swarms, Debrid-cached releases, and Direct HTTP hosters.
struct LinkedSeasonPackSource: Equatable {
    let infoHash: String?
    let source: String
    let cleanProvider: String
    let quality: String
    let indexer: String?
    let releaseSignature: String
    let isTorrent: Bool

    init(stream: Stream, activeTorrentHash: String? = nil) {
        self.isTorrent = stream.isTorrent
        let hash = activeTorrentHash ?? stream.infoHash ?? PlayerManager.extractInfoHash(from: stream.url.absoluteString)
        self.infoHash = hash?.lowercased()
        self.source = stream.source
        self.cleanProvider = StreamManager.cleanProviderName(stream.source)
        self.quality = stream.quality
        self.indexer = stream.indexer

        let raw = stream.cleanTitle.isEmpty ? stream.title : stream.cleanTitle
        let stripped = raw.replacingOccurrences(of: #"(?i)e\d{1,3}\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)episode\s*\d{1,3}\b"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.releaseSignature = stripped.uppercased()
    }

    /// Checks whether an incoming stream candidate for the next episode matches this season pack.
    func matches(_ candidate: Stream) -> Bool {
        // 1. Exact infoHash match (BitTorrent swarms and Debrid cached season packs)
        if let targetHash = self.infoHash, !targetHash.isEmpty {
            if let candHash = candidate.infoHash?.lowercased(), candHash == targetHash {
                return true
            }
            if let candHash = PlayerManager.extractInfoHash(from: candidate.url.absoluteString)?.lowercased(), candHash == targetHash {
                return true
            }
            if candidate.url.absoluteString.lowercased().contains(targetHash) {
                return true
            }
        }

        // 2. Direct HTTP hoster / Scraper match (when no infoHash is present)
        if !self.isTorrent && !candidate.isTorrent {
            let candProvider = StreamManager.cleanProviderName(candidate.source)
            if candProvider == self.cleanProvider {
                if let idx1 = self.indexer, let idx2 = candidate.indexer, !idx1.isEmpty, !idx2.isEmpty {
                    if idx1.lowercased() != idx2.lowercased() {
                        return false
                    }
                }
                if candidate.quality == self.quality {
                    if candidate.isSeasonPack {
                        return true
                    }
                    let candRaw = candidate.cleanTitle.isEmpty ? candidate.title : candidate.cleanTitle
                    let candStripped = candRaw.replacingOccurrences(of: #"(?i)e\d{1,3}\b"#, with: "", options: .regularExpression)
                        .replacingOccurrences(of: #"(?i)episode\s*\d{1,3}\b"#, with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if candStripped.uppercased() == self.releaseSignature {
                        return true
                    }
                }
            }
        }

        return false
    }
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
    @Published var torrentStreamProgress: Double = 0.0
    private var torrentStatsPollTask: Task<Void, Never>? = nil
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
    private(set) var activeTorrentHash: String?

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
        let stream: Stream?
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
    @MainActor private var isAutoPlayRaceActive: Bool = false
    @MainActor private var hasCommittedAutoPlayWinner: Bool = false
    private var autoPlayRaceTask: Task<Void, Never>? = nil
    @Published var hasPlaybackStarted: Bool = false
    private var startupWatchdogTask: Task<Void, Never>?
    private var lastTelemetryProgressTime: Date?
    private var lastObservedCacheTime: Double = 0.0
    // Startup hot-swap monitor feed (see armStartupWatchdog post-start branch)
    private var startupThroughputSamples: [(date: Date, kbps: Double)] = []
    private var lastStartupTimePos: Double = 0.0
    private var slowStartStrikes: Int = 0
    private var lastFallbackAttemptDate: Date = .distantPast
    private var fallbackThrottleTask: Task<Void, Never>?
    private var currentAttemptStartTime: CFAbsoluteTime = 0.0

    // Next-Episode preloading state (AIOStreams style)
    private var prefetchedNextKey: String?
    private var prefetchedNextStream: Stream?
    private var prefetchedNextSubtitles: [StremioSubtitleTrack]?
    private var prefetchedNextAt: Date?
    @Published var nextEpisode: Episode? = nil
    /// Stores the active season pack source to prioritize linking strictly for auto-playing the next episode.
    @Published private(set) var linkedSeasonPack: LinkedSeasonPackSource? = nil

    /// Backward compatibility & diagnostic helper returning the active season pack infoHash if present.
    var linkedSeasonPackHash: String? {
        linkedSeasonPack?.infoHash
    }

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
            let controller = core.controller
            DispatchQueue.global(qos: .userInitiated).async {
                controller.stop()
            }
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

    private func primeWinner(winner: Stream, item: MediaItem, season: Int?, episode: Int?, key: String, subs: [StremioSubtitleTrack]?) async {
        if winner.isTorrent {
            guard let hash = torrentHash(winner) else {
                await MainActor.run {
                    self.isPrefetching = false
                    self.inflightPrefetchKey = nil
                }
                return
            }

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

        await MainActor.run {
            let targetMatchesCurrent = (self.currentItem?.id == item.id && self.currentSeason == season && self.currentEpisode == episode)
            if targetMatchesCurrent {
                self.prefetchedKey = key
                self.prefetchedStream = winner
                self.prefetchedSubtitles = subs
                self.prefetchedAt = Date()
                self.inflightPrefetchKey = nil
                self.isPrefetching = false
                if self.currentSelectedStream == nil && self.currentStreamURL == nil {
                    print("[PlayerManager] ⚡ Delivering prefetch winner directly to active player session: \(winner.cleanTitle)")
                    self.attemptStream(winner)
                }
                return
            }

            guard self.currentItem == nil, !Task.isCancelled else {
                self.isPrefetching = false
                self.inflightPrefetchKey = nil
                return
            }
            self.prefetchedKey = key
            self.prefetchedStream = winner
            self.prefetchedSubtitles = subs
            self.prefetchedAt = Date()
            self.inflightPrefetchKey = nil
            self.buildWarmCore(key: key, url: getPlayableURL(for: winner), stream: winner)
            self.isPrefetching = false
            print("[PlayerManager] ⚡ Prefetch primed: \(winner.cleanTitle) (\(winner.source)) — warm core holding")
            Logger.stream.error("⚡ Prefetch primed: \(winner.cleanTitle, privacy: .public) via \(winner.source, privacy: .public) — warm core holding, race ran during browsing")
        }
    }

    private func runPrefetch(item: MediaItem, season: Int?, episode: Int?, key: String, allowPrime: Bool) async {
        let subsTask = Task { await SubtitleManager.shared.fetchSubtitles(for: item, season: season, episode: episode) }

        let fluxEnabled = UserDefaults.standard.object(forKey: UserDefaults.Key.enableFluxMode) as? Bool ?? true
        defer {
            if Task.isCancelled {
                DispatchQueue.main.async { self.isPrefetching = false }
            }
        }

        var earlyPrimed = false
        var pendingAddonNames: [String] = []
        let fetchStart = CFAbsoluteTimeGetCurrent()
        let streams = await StreamManager.shared.fetchStreamsRealtime(
            for: item,
            season: season,
            episode: episode,
            onProgress: { loaded, total, pending in
                pendingAddonNames = pending
            }
        ) { updatedStreams in
            guard fluxEnabled, allowPrime, !earlyPrimed, !Task.isCancelled else { return }
            let sourceMode = UserDefaults.standard.string(forKey: UserDefaults.Key.streamingSourceMode) ?? "both"
            let prefQuality = UserDefaults.standard.string(forKey: UserDefaults.Key.preferredQuality) ?? "1080p"
            let elapsed = CFAbsoluteTimeGetCurrent() - fetchStart
            let hasPendingHttp = elapsed < 3.5 && pendingAddonNames.contains { StreamManager.isHttpSource($0) }
            if StreamManager.shared.hasQualityQuorum(
                streams: updatedStreams,
                sourceMode: sourceMode,
                preferredQuality: prefQuality,
                targetTitle: item.title,
                hasPendingHttpScrapers: hasPendingHttp
            ) {
                earlyPrimed = true
                AsyncTask {
                    guard let winner = await self.raceBestStream(from: updatedStreams, item: item, season: season, episode: episode, isPrefetch: true), !Task.isCancelled else { return }
                    let subs = await subsTask.value
                    await self.primeWinner(winner: winner, item: item, season: season, episode: episode, key: key, subs: subs)
                }
            }
        }
        guard !Task.isCancelled else { return }

        guard fluxEnabled, allowPrime, !streams.isEmpty else {
            await MainActor.run {
                self.prefetchedKey = key   // streams cached for instant picker
                self.prefetchedAt = Date()
                self.isPrefetching = false
                self.inflightPrefetchKey = nil
            }
            return
        }

        if !earlyPrimed {
            guard let winner = await raceBestStream(from: streams, item: item, season: season, episode: episode, isPrefetch: true), !Task.isCancelled else {
                await MainActor.run {
                    self.isPrefetching = false
                    self.inflightPrefetchKey = nil
                }
                return
            }
            let subs = await subsTask.value
            await self.primeWinner(winner: winner, item: item, season: season, episode: episode, key: key, subs: subs)
        }
    }

    private static func warmHTTP(url: URL) {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        request.timeoutInterval = 4
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    // MARK: Warm mpv core

    private func buildWarmCore(key: String, url: URL, stream: Stream? = nil) {
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
        host.identifier = NSUserInterfaceItemIdentifier("flux_warm_core_host")
        host.title = "FluxWarmCoreHost"
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

        controller.preparePaused(url: url)

        warmCore = WarmPlaybackCore(
            key: key,
            url: url,
            controller: controller,
            viewController: vc,
            hostWindow: host,
            createdAt: Date(),
            stream: stream
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
            if let s = core.stream {
                self.currentSelectedStream = s
            }
            warmCore = nil
            warmCoreDiscardTask?.cancel()
            warmCoreDiscardTask = nil
            // The warm core is now the active playback core. Transfer torrent
            // ownership so close/fallback cleans it up as a normal stream.
            if let hash = prefetchTorrentHash {
                activeTorrentHash = hash
                prefetchTorrentHash = nil
            }
            controller.playerView?.setMute(false)
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
        let controller = core.controller
        DispatchQueue.global(qos: .userInitiated).async {
            controller.stop()
        }
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

    /// Handles fatal stream drops or reconnect storms reported by the player or engine.
    func handleStreamFailure(reason: String) {
        print("[PlayerManager] 🚨 Stream failure reported: \(reason)")
        if warmCore != nil && currentItem == nil {
            print("[PlayerManager] 🚨 Discarding failing warm core")
            discardWarmCore()
        } else if currentItem != nil {
            print("[PlayerManager] 🚨 Advancing active playback to fallback due to stream failure")
            advanceToStandbyFallback()
        }
    }


    /// Auto-failover safety valve: after this many consecutive dead sources, stop
    /// cascading silently and hand control back to the user (stream picker).
    private let maxAutoFallbacks = 5
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
        let stream: Stream?
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
            lastPlayedStreams[key] = CachedStream(url: url, timestamp: Date(), stream: currentSelectedStream)
            print("[PlayerManager] 💾 Positive playback confirmed (>=1s) — saved instant replay for \(key)")
        }

        let hash = currentSelectedStream?.isTorrent == true ? torrentHash(currentSelectedStream!) : nil
        var historyItem = item
        historyItem.lastStreamURL = (isRemoteHttp && hasQueryToken) ? nil : url
        historyItem.lastTorrentInfoHash = hash
        historyItem.lastFileIndex = currentSelectedStream?.fileIdx
        historyItem.lastStreamSource = currentSelectedStream?.source
        historyItem.lastStreamTitle = currentSelectedStream?.title

        // Seed initial progress so newly started titles immediately appear on Continue Watching
        let initialProg = max(0.01, item.progress ?? 0.01)
        let initialPos = max(1.0, item.lastPlaybackPosition ?? 1.0)
        let initialDur = item.lastPlaybackDuration

        UserDataService.shared.addToHistory(
            historyItem,
            progress: initialProg,
            season: self.currentSeason,
            episode: self.currentEpisode,
            episodeImage: self.currentEpisodeImage,
            playbackPosition: initialPos,
            playbackDuration: initialDur,
            streamURL: (isRemoteHttp && hasQueryToken) ? nil : url,
            torrentInfoHash: hash,
            fileIndex: currentSelectedStream?.fileIdx,
            streamSource: currentSelectedStream?.source,
            streamTitle: currentSelectedStream?.title
        )
    }

    /// Cancels any active playback, stream probing, or auto-play race.
    /// Used when the user opens the stream picker to ensure background
    /// processes don't unexpectedly start playing a video under them.
    func cancelAllPlaybackAndRaces() {
        print("[PlayerManager] Cancelling all active playback and background auto-play races.")
        self.fetchAndRaceTask?.cancel()
        self.fetchAndRaceTask = nil
        self.autoPlayRaceTask?.cancel()
        self.autoPlayRaceTask = nil
        self.startupWatchdogTask?.cancel()
        self.startupWatchdogTask = nil
        self.torrentStatsPollTask?.cancel()
        self.torrentStatsPollTask = nil
        self.torrentStreamProgress = 0.0
        self.isAutoPlayRaceActive = false
        self.hasCommittedAutoPlayWinner = false
        self.currentStreamURL = nil
        self.currentSelectedStream = nil
        self.forceStreamPicker = true
        self.isStreamPickerPresented = true
        self.isManualSelection = true
        self.isLoading = false
        self.sessionController?.stop()
        if let hash = activeTorrentHash {
            StremioServerManager.shared.removeTorrent(infoHash: hash)
            activeTorrentHash = nil
        }
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

    static func extractInfoHash(from string: String) -> String? {
        if let range = string.range(of: #"btih:([a-fA-F0-9]{32,40})"#, options: .regularExpression) {
            let raw = String(string[range]).replacingOccurrences(of: "btih:", with: "")
            if validInfoHash(raw) {
                return raw.lowercased()
            }
        }
        if string.count == 40 && string.range(of: #"^[a-fA-F0-9]{40}$"#, options: .regularExpression) != nil {
            if validInfoHash(string) {
                return string.lowercased()
            }
        }
        return nil
    }

    func torrentHash(_ stream: Stream) -> String? {
        if let ih = stream.infoHash, !ih.isEmpty, Self.validInfoHash(ih) {
            return ih.lowercased()
        }
        return Self.extractInfoHash(from: stream.url.absoluteString)
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
        if ProfileManager.shared.currentProfile?.isKids == true && KidsContentFilter.shared.isRestricted(item: item) {
            print("[PlayerManager] Playback blocked for restricted title '\(item.title)' in Kids Profile")
            return
        }
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
        let playbackKey = prefetchKey(for: item, season: season, episode: episode)

        // Apple TV style single player window handoff:
        // Auto-play Season Pack preservation:
        // When auto-advancing to the next episode, preserve the active season pack source (P2P swarm or HTTP release)
        // so the warm swarm is not torn down, and the next episode links directly to the same release.
        var linkedSeasonPackToPreserve: LinkedSeasonPackSource?
        if isAutoAdvance, let cur = currentSelectedStream, cur.isSeasonPack {
            linkedSeasonPackToPreserve = LinkedSeasonPackSource(stream: cur, activeTorrentHash: activeTorrentHash)
        }
        self.linkedSeasonPack = linkedSeasonPackToPreserve

        if let _ = currentItem {
            let curTime = sessionController?.timePos ?? 0
            let curDur = sessionController?.duration ?? 0
            if curDur > 0 && curTime > 0 {
                updateWatchProgress(time: curTime, duration: curDur, isLightweightTick: false)
            }
            sessionController?.stop()
            self.fetchAndRaceTask?.cancel()
            self.fetchAndRaceTask = nil
            self.fallbackThrottleTask?.cancel()
            self.fallbackThrottleTask = nil
            if warmCore?.key != playbackKey {
                self.discardWarmCore()
            }
            let torrentHashToPreserve = linkedSeasonPackToPreserve?.isTorrent == true ? linkedSeasonPackToPreserve?.infoHash : nil
            if let hash = activeTorrentHash, hash != prefetchTorrentHash, hash != torrentHashToPreserve {
                StremioServerManager.shared.removeTorrent(infoHash: hash)
                activeTorrentHash = nil
            }
        } else {
            if warmCore?.key != playbackKey {
                self.discardWarmCore()
            }
        }

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
        // New session → nothing is playing yet. Without this reset the first
        // successful title flips hasPlaybackStarted permanently (it is never
        // set back to false anywhere else), and every later Flux Mode
        // auto-attempt's startup watchdog sees "already playing" and refuses
        // to advance past a stalled candidate — the classic "Flux Mode hangs,
        // manual pick works" failure.
        self.hasPlaybackStarted = false
        self.lastTelemetryProgressTime = nil
        self.lastObservedCacheTime = 0.0
        self.lastStartupTimePos = 0.0
        self.startupThroughputSamples.removeAll()
        self.slowStartStrikes = 0
        self.isAutoPlayRaceActive = false
        self.hasCommittedAutoPlayWinner = false
        self.currentAttemptStartTime = 0.0
        self.startupWatchdogTask?.cancel()
        self.startupWatchdogTask = nil
        self.autoPlayRaceTask?.cancel()
        self.autoPlayRaceTask = nil
        if forceStreamPicker {
            self.forceStreamPicker = true
            self.isManualSelection = true
            self.isStreamPickerPresented = true
            self.hasCommittedAutoPlayWinner = false
            self.isAutoPlayRaceActive = false
            self.currentStreamURL = nil
            self.currentSelectedStream = nil
            self.sessionController?.stop()
        } else {
            self.forceStreamPicker = false
            self.isManualSelection = false
            self.isStreamPickerPresented = false
        }

        // Only clear streams if we don't already have pre-fetched streams for this playback key
        if prefetchedKey != playbackKey && prefetchedNextKey != playbackKey {
            self.availableStreams = []
        }
        self.currentStreamURL = nil
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
               isSavedURLCompatible(cached.url, hash: activeTorrentHash),
               !cachedStreamLabelLooksLikeJunk(cached.stream, item: item) {
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
                                    if let s = cached.stream {
                                        self.currentSelectedStream = s
                                    }
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
                        if let s = cached.stream {
                            self.currentSelectedStream = s
                        }
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
                      isSavedURLCompatible(savedURL, hash: historyItem?.lastTorrentInfoHash),
                      !StreamManager.labelLooksLikeJunk(
                        labelText: "\(item.lastStreamTitle ?? historyItem?.lastStreamTitle ?? "") \(item.lastStreamSource ?? historyItem?.lastStreamSource ?? "")",
                        targetTitle: item.title) {
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
                                    let sourceStr = item.lastStreamSource ?? historyItem?.lastStreamSource ?? "Unknown Source".localized
                                    let titleStr = item.lastStreamTitle ?? historyItem?.lastStreamTitle ?? item.title
                                    let fallbackStream = Stream(
                                        title: titleStr,
                                        cleanTitle: item.title,
                                        url: savedURL,
                                        source: sourceStr,
                                        quality: "Auto",
                                        indexer: StreamManager.parseIndexer(name: sourceStr, title: titleStr)
                                    )
                                    self.currentSelectedStream = fallbackStream
                                    self.lastPlayedStreams[key] = CachedStream(url: savedURL, timestamp: Date(), stream: fallbackStream)
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
                        let sourceStr = item.lastStreamSource ?? historyItem?.lastStreamSource ?? "Unknown Source".localized
                        let titleStr = item.lastStreamTitle ?? historyItem?.lastStreamTitle ?? item.title
                        let fallbackStream = Stream(
                            title: titleStr,
                            cleanTitle: item.title,
                            url: savedURL,
                            source: sourceStr,
                            quality: "Auto",
                            indexer: StreamManager.parseIndexer(name: sourceStr, title: titleStr)
                        )
                        self.currentSelectedStream = fallbackStream
                        self.lastPlayedStreams[key] = CachedStream(url: savedURL, timestamp: Date(), stream: fallbackStream)
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
    
    /// Junk-label gate for instant-replay: a cached/persisted stream whose
    /// scraper label is a promo/review/intro ("MovieBox promo trailer") must
    /// NEVER auto-replay. A HEAD health check passes fine against a promo CDN
    /// — that's exactly the probe-vs-playback divergence — so the only
    /// reliable signal is the label itself. Gate does not mutate caches; if
    /// the caller then falls through to the race, the ranker's junk demotion
    /// will bury the source anyway.
    private func cachedStreamLabelLooksLikeJunk(_ stream: Stream?, item: MediaItem) -> Bool {
        guard let stream else { return false }
        let label = stream.fullScannableText
        if StreamManager.labelLooksLikeJunk(labelText: label, targetTitle: item.title) {
            print("[PlayerManager] 🗑️ Cached stream label looks like junk promo — skipping replay: \(label)")
            return true
        }
        return false
    }
    
    private func populateStreamsInBackground(item: MediaItem, season: Int?, episode: Int?) {
        AsyncTask {
            try? await AsyncTask.sleep(nanoseconds: 1 * 1_000_000_000)

            _ = await StreamManager.shared.fetchStreamsRealtime(for: item, season: season, episode: episode) { updatedStreams in
                Task { @MainActor in
                    self.availableStreams = updatedStreams
                    self.verifyStreamHealth(updatedStreams)
                    if self.currentSelectedStream == nil || self.currentSelectedStream?.source == nil {
                        if let matched = updatedStreams.first(where: { s in
                            if let activeHash = self.activeTorrentHash, s.isTorrent {
                                return self.torrentHash(s)?.lowercased() == activeHash.lowercased()
                            }
                            if let currentURL = self.currentStreamURL {
                                return s.url == currentURL || self.getPlayableURL(for: s) == currentURL
                            }
                            return false
                        }) {
                            self.currentSelectedStream = matched
                        }
                    }
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
        self.autoPlayRaceTask?.cancel()
        self.autoPlayRaceTask = nil
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
            
            if !forceStreamPicker && !self.forceStreamPicker && !self.isStreamPickerPresented, isFluxEnabled, (isDetailHit || isNextHit) {
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
                    self.currentAttemptStartTime = CFAbsoluteTimeGetCurrent()
                    self.finishSelect(pf)
                    if pf.isTorrent {
                        self.startTorrentStatsPolling(for: pf)
                    }
                    // The fast path bypasses attemptStream entirely, so arm the
                    // startup watchdog here too: a prefetched stream that went
                    // stale (expired CDN token / dead origin) must auto-advance
                    // to the standby fallbacks instead of hanging at 00:00.
                    self.armStartupWatchdog(for: pf)
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
            
            let fetchStartTime = CFAbsoluteTimeGetCurrent()
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

                    // Auto-Play Season Pack Direct Link:
                    // If auto-playing next episode and the previous episode was playing from a season pack (P2P or HTTP),
                    // link directly to that exact same season pack source as soon as it arrives!
                    if isFluxEnabled && !forceStreamPicker && !self.forceStreamPicker && !self.isStreamPickerPresented && !self.isAutoPlayRaceActive && !self.hasCommittedAutoPlayWinner && self.currentSelectedStream == nil && self.currentStreamURL == nil,
                       let linked = self.linkedSeasonPack,
                       let matchingStream = updatedStreams.first(where: { linked.matches($0) }) {
                        self.hasCommittedAutoPlayWinner = true
                        print("[PlayerManager] ⚡ Linked next episode auto-play directly to active season pack (\(matchingStream.isTorrent ? "P2P" : "HTTP")): \(matchingStream.cleanTitle) (fileIdx: \(matchingStream.fileIdx ?? 0))")
                        self.isManualSelection = false
                        self.attemptStream(matchingStream)
                        return
                    }

                    // Ingest newly discovered streams into standby fallbacks if auto-play already committed:
                    if self.hasCommittedAutoPlayWinner {
                        let currentFallbackKeys = Set(self.standbyFallbacks.map { $0.stableKey })
                        let prefQuality = UserDefaults.standard.string(forKey: UserDefaults.Key.preferredQuality) ?? "1080p"
                        let maxScore = StreamManager.shared.qualityScore(prefQuality)
                        let targetTitle = item.title

                        let newCandidates = updatedStreams.filter { s in
                            guard !currentFallbackKeys.contains(s.stableKey) && s.stableKey != self.currentSelectedStream?.stableKey else { return false }
                            // Filter out streams exceeding preferred quality (e.g. 4K when 1080p is preferred)
                            let sScore = StreamManager.shared.qualityScore(s.quality)
                            if sScore > maxScore && maxScore >= 3 { return false }
                            if !targetTitle.isEmpty && StreamManager.labelLooksLikeJunk(labelText: s.fullScannableText, targetTitle: targetTitle) {
                                return false
                            }
                            return true
                        }
                        if !newCandidates.isEmpty {
                            let newHTTP = newCandidates.filter { !$0.isTorrent && $0.isDirectHTTP }
                            let newP2P = newCandidates.filter { $0.isTorrent }
                            self.standbyFallbacks = newHTTP + self.standbyFallbacks + newP2P
                        }

                        // Dynamic Hot-Swap: ONLY if the committed stream is a torrent, playback hasn't started yet,
                        // and it has been STALLED for at least 8.0 seconds with zero progress/bytes:
                        let elapsedSinceAttempt = self.currentAttemptStartTime > 0 ? (CFAbsoluteTimeGetCurrent() - self.currentAttemptStartTime) : 0.0
                        let isTorrentStalled = self.torrentStreamProgress < 0.05 && self.lastObservedCacheTime < 0.5 &&
                            (self.lastTelemetryProgressTime == nil || Date().timeIntervalSince(self.lastTelemetryProgressTime!) >= 6.0)

                        if elapsedSinceAttempt >= 8.0,
                           isTorrentStalled,
                           let current = self.currentSelectedStream,
                           current.isTorrent,
                           !self.hasPlaybackStarted,
                           !self.isManualSelection,
                           !self.forceStreamPicker,
                           !self.isStreamPickerPresented {
                            let freshHTTP = newCandidates.filter { !$0.isTorrent && $0.isDirectHTTP }
                            if let bestHTTP = freshHTTP.first {
                                print("[PlayerManager] ⚡ Dynamic Hot-Swap: Torrent stalled after \(Int(elapsedSinceAttempt))s; swapping to matching direct HTTP source: \(bestHTTP.cleanTitle) (\(bestHTTP.quality))")
                                Logger.stream.error("⚡ Dynamic Hot-Swap from stalled torrent to direct HTTP: \(bestHTTP.cleanTitle, privacy: .public) (\(bestHTTP.quality, privacy: .public))")
                                self.attemptStream(bestHTTP)
                                return
                            }
                        }
                    }

                    // Early Quorum Commit: If in Flux Mode and no stream is selected yet,
                    // check if incoming streams already meet Quality Quorum!
                    if isFluxEnabled && !forceStreamPicker && !self.forceStreamPicker && !self.isStreamPickerPresented && !self.isAutoPlayRaceActive && !self.hasCommittedAutoPlayWinner && self.currentSelectedStream == nil && self.currentStreamURL == nil {
                        let sourceMode = UserDefaults.standard.string(forKey: UserDefaults.Key.streamingSourceMode) ?? "both"
                        let prefQuality = UserDefaults.standard.string(forKey: UserDefaults.Key.preferredQuality) ?? "1080p"
                        let elapsed = CFAbsoluteTimeGetCurrent() - fetchStartTime
                        let hasPendingHttp = elapsed < 3.5 && self.pendingAddonNames.contains { StreamManager.isHttpSource($0) }
                        if StreamManager.shared.hasQualityQuorum(
                            streams: updatedStreams,
                            sourceMode: sourceMode,
                            preferredQuality: prefQuality,
                            targetTitle: item.title,
                            hasPendingHttpScrapers: hasPendingHttp
                        ) {
                            self.isAutoPlayRaceActive = true
                            self.autoPlayRaceTask?.cancel()
                            self.autoPlayRaceTask = AsyncTask {
                                defer {
                                    Task { @MainActor in
                                        self.isAutoPlayRaceActive = false
                                    }
                                }
                                if let fastWinner = await self.raceBestStream(from: updatedStreams, item: item, season: season, episode: episode, isPrefetch: false) {
                                    await MainActor.run {
                                        guard self.currentItem?.id == item.id && self.currentSeason == season && self.currentEpisode == episode else { return }
                                        guard !self.hasCommittedAutoPlayWinner && !self.forceStreamPicker && !self.isStreamPickerPresented && self.currentSelectedStream == nil && self.currentStreamURL == nil else { return }
                                        self.hasCommittedAutoPlayWinner = true
                                        print("[PlayerManager] ⚡ Quorum reached early (\(updatedStreams.count) streams)! Committing winner: \(fastWinner.cleanTitle)")
                                        self.isManualSelection = false
                                        self.attemptStream(fastWinner)
                                    }
                                }
                            }
                        }
                    }
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
            
            // If an early quorum auto-play race is running, await its completion:
            if let race = await MainActor.run(body: { self.autoPlayRaceTask }) {
                _ = await race.value
            }

            guard await isStillCurrentTarget() else { return }

            // If the user already made a stream selection while background fetching was underway,
            // do not disrupt active playback or re-open the stream picker.
            let hasActiveSelection = await MainActor.run { () -> Bool in
                return self.hasCommittedAutoPlayWinner || self.currentSelectedStream != nil || self.currentStreamURL != nil
            }
            if hasActiveSelection {
                print("[PlayerManager] Stream fetch completed after stream was already chosen. Preserving active playback.")
                await MainActor.run {
                    self.isLoading = false
                }
                return
            }

            // If user or caller requested the Stream Selector UI and hasn't yet made a selection:
            if forceStreamPicker || self.forceStreamPicker || self.isStreamPickerPresented {
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
            if isFluxEnabled, !streams.isEmpty, !forceStreamPicker, !self.forceStreamPicker, !self.isStreamPickerPresented {
                let alreadyCommitted = await MainActor.run { () -> Bool in
                    return self.hasCommittedAutoPlayWinner || self.isAutoPlayRaceActive || self.currentSelectedStream != nil || self.currentStreamURL != nil || self.forceStreamPicker || self.isStreamPickerPresented
                }
                if !alreadyCommitted {
                    await MainActor.run {
                        self.isAutoPlayRaceActive = true
                    }
                    if let winner = await self.raceBestStream(from: streams, item: item, season: season, episode: episode, isPrefetch: false) {
                        await MainActor.run {
                            self.isAutoPlayRaceActive = false
                        }
                        guard await isStillCurrentTarget() else {
                            print("[PlayerManager] Discarding Flux Mode stream winner because user selected another title/episode.")
                            return
                        }
                        let selectionMade = await MainActor.run { () -> Bool in
                            return self.hasCommittedAutoPlayWinner || self.currentSelectedStream != nil || self.currentStreamURL != nil || self.forceStreamPicker || self.isStreamPickerPresented
                        }
                        if selectionMade {
                            print("[PlayerManager] Stream already selected manually or stream picker open; discarding auto-play winner.")
                            return
                        }
                        print("[PlayerManager] Flux Mode selected stream: \(winner.cleanTitle) (\(winner.source))")
                        await MainActor.run {
                            guard !self.forceStreamPicker && !self.isStreamPickerPresented else { return }
                            self.hasCommittedAutoPlayWinner = true
                            self.isManualSelection = false
                            self.attemptStream(winner)
                        }
                        return
                    } else {
                        await MainActor.run {
                            self.isAutoPlayRaceActive = false
                        }
                    }
                } else {
                    return
                }
            }
            
            // Fallback: Show list (Only when manual mode, forced picker, or auto-play truly failed to find any winner)
            guard await isStillCurrentTarget() else { return }
            let selectionMade = await MainActor.run { () -> Bool in
                return self.hasCommittedAutoPlayWinner || self.currentSelectedStream != nil || self.currentStreamURL != nil
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
    // Immediately commits to the highest-scoring candidate and stashes standby fallbacks
    // for seamless watchdog auto-advancement without blocking playback on artificial network probes.
    private func raceBestStream(from streams: [Stream], item: MediaItem? = nil, season: Int? = nil, episode: Int? = nil, isPrefetch: Bool = false) async -> Stream? {
        let isPickerActive = await MainActor.run { self.forceStreamPicker || self.isStreamPickerPresented }
        if isPickerActive {
            print("[PlayerManager] Stream picker active; cancelling race.")
            return nil
        }
        let healthy = streams.filter { !isHashRecentlyDead($0) }
        guard !healthy.isEmpty else { return nil }

        let targetItem = item ?? currentItem
        let targetSeason = season ?? currentSeason
        let targetEpisode = episode ?? currentEpisode

        let sourceMode = UserDefaults.standard.string(forKey: UserDefaults.Key.streamingSourceMode) ?? "both"
        let preferredQuality = UserDefaults.standard.string(forKey: UserDefaults.Key.preferredQuality) ?? "1080p"
        let preferredLang = UserDefaults.standard.string(forKey: "defaultAudioLang") ?? "English"
        let preferredLanguages = UserDefaults.standard.stringArray(forKey: UserDefaults.Key.preferredStreamLanguages) ?? [preferredLang]
        let enableLanguageFilter = UserDefaults.standard.bool(forKey: "enableFluxLanguageFilter")

        if let linked = self.linkedSeasonPack,
           let matchingStream = healthy.first(where: { linked.matches($0) }) {
            print("[PlayerManager] ⚡ Flux Mode raceBestStream linked directly to active season pack (\(matchingStream.isTorrent ? "P2P" : "HTTP")): \(matchingStream.cleanTitle) (fileIdx: \(matchingStream.fileIdx ?? 0))")
            return matchingStream
        }

        var (primary, fallbacks): (Stream?, [Stream]) = (nil, [])
        var wasRankedByAI = false

        let isAISelectionEnabled = UserDefaults.standard.bool(forKey: UserDefaults.Key.enableAIStreamSelection)
        let userGeminiKey = UserDefaults.standard.string(forKey: UserDefaults.Key.geminiApiKey) ?? ""
        let geminiKey = userGeminiKey.isEmpty ? Secrets.geminiAPIKey : userGeminiKey

        // Only invoke AI ranking for actual intentional playback, NEVER for speculative browsing prefetch
        if !isPrefetch && isAISelectionEnabled && !geminiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await MainActor.run {
                self.statusText = "AI analyzing streams…".localized
            }
            var model = UserDefaults.standard.string(forKey: UserDefaults.Key.geminiModel) ?? "gemini-3.5-flash-lite"
            let validGeminiModels = ["gemini-3.5-flash-lite", "gemini-3.6-flash", "gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.5-flash", "gemini-3.1-flash-lite", "gemini-2.5-flash"]
            if !validGeminiModels.contains(model) {
                model = "gemini-3.5-flash-lite"
                UserDefaults.standard.set(model, forKey: UserDefaults.Key.geminiModel)
            }
            do {
                let aiRanked = try await GeminiStreamRanker.shared.rankStreams(
                    healthy,
                    title: targetItem?.title ?? "",
                    year: targetItem?.year,
                    season: targetSeason,
                    episode: targetEpisode,
                    apiKey: geminiKey,
                    model: model,
                    preferredQuality: preferredQuality,
                    preferredLanguages: preferredLanguages,
                    enableLanguageFilter: enableLanguageFilter,
                    sourceMode: sourceMode
                )
                if let first = aiRanked.first {
                    let maxAllowed = StreamManager.shared.qualityScore(preferredQuality)
                    if StreamManager.shared.qualityScore(first.quality) > maxAllowed && maxAllowed >= 3 {
                        if let compliantWinner = aiRanked.first(where: { StreamManager.shared.qualityScore($0.quality) <= maxAllowed }) {
                            primary = compliantWinner
                            fallbacks = aiRanked.filter { $0.stableKey != compliantWinner.stableKey }
                        } else {
                            primary = first
                            fallbacks = Array(aiRanked.dropFirst())
                        }
                    } else {
                        primary = first
                        fallbacks = Array(aiRanked.dropFirst())
                    }
                    wasRankedByAI = true
                    Logger.stream.error("[PlayerManager] 🤖 AI Stream Selection (\(model, privacy: .public)) successfully prioritized \(aiRanked.count) streams. Top pick: \(primary?.cleanTitle ?? "", privacy: .public) (\(primary?.quality ?? "", privacy: .public))")
                }
            } catch {
                Logger.stream.error("[PlayerManager] ⚠️ AI Stream Selection (\(model, privacy: .public)) error: \(error.localizedDescription, privacy: .public) — falling back to local heuristic algorithm.")
            }
        }

        if primary == nil {
            (primary, fallbacks) = StreamManager.shared.selectFastStartCandidate(
                from: healthy,
                sourceMode: sourceMode,
                preferredQuality: preferredQuality,
                preferredLang: preferredLang,
                preferredLanguages: preferredLanguages,
                originalLanguage: targetItem?.effectiveOriginalLanguage ?? targetItem?.originalLanguage,
                enableLanguageFilter: enableLanguageFilter,
                probeStatus: self.probeStatus,
                targetSeason: targetSeason,
                targetEpisode: targetEpisode,
                targetTitle: targetItem?.title
            )
        }

        guard let firstPass = primary else { return nil }

        let winnerCandidate: Stream
        let finalStandby: [Stream]

        if wasRankedByAI {
            let maxAllowed = StreamManager.shared.qualityScore(preferredQuality)
            let chosenWinner: Stream
            let chosenStandby: [Stream]
            if StreamManager.shared.qualityScore(firstPass.quality) > maxAllowed && maxAllowed >= 3 {
                if let compliant = fallbacks.first(where: { StreamManager.shared.qualityScore($0.quality) <= maxAllowed }) {
                    chosenWinner = compliant
                    chosenStandby = [firstPass] + fallbacks.filter { $0.stableKey != compliant.stableKey }
                } else {
                    chosenWinner = firstPass
                    chosenStandby = fallbacks
                }
            } else {
                chosenWinner = firstPass
                chosenStandby = fallbacks
            }
            winnerCandidate = chosenWinner
            finalStandby = chosenStandby
            await MainActor.run {
                self.standbyFallbacks = finalStandby
                self.statusText = nil
            }
        } else {
            let top3Candidates = Array(([firstPass] + fallbacks).prefix(3))

            let (winner, standby, probeResults) = await StreamManager.shared.raceTopCandidatesWithResults(
                top3Candidates,
                playableURL: { self.getPlayableURL(for: $0) },
                timeout: 2.5
            )

            winnerCandidate = winner ?? firstPass
            let top3Keys = Set(top3Candidates.map { $0.stableKey })
            let remainingAfterTop3 = fallbacks.filter { !top3Keys.contains($0.stableKey) }
            finalStandby = standby + remainingAfterTop3

            await MainActor.run {
                for (key, ok) in probeResults {
                    self.probeStatus[key] = StreamProbeResult(ok: ok, latency: 0.0)
                }
                self.standbyFallbacks = finalStandby
                self.statusText = nil
            }
        }

        let isPickerStillActive = await MainActor.run { self.forceStreamPicker || self.isStreamPickerPresented }
        if isPickerStillActive {
            print("[PlayerManager] Stream picker active; discarding race winner.")
            return nil
        }

        print("[PlayerManager] ⚡ Flux Mode selected best candidate: \(winnerCandidate.cleanTitle) (\(winnerCandidate.quality)) via \(winnerCandidate.source)")
        Logger.stream.error("⚡ Race winner: \(winnerCandidate.cleanTitle, privacy: .public) via \(winnerCandidate.source, privacy: .public)")
        return winnerCandidate
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
                        // The measured throughput race result is authoritative —
                        // never overwrite it with a latency-only HEAD probe.
                        guard self.probeStatus[key]?.throughputKBps == nil else { return }
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
        if stream.isTorrent, let hash = torrentHash(stream) {
            var components = URLComponents()
            components.scheme = "http"
            components.host = "127.0.0.1"
            components.port = StremioServerManager.shared.port
            components.path = "/\(hash)/\(stream.fileIdx ?? 0)"
            if let finalURL = components.url {
                return finalURL
            }
        }

        let target = stream.url
        let streamTitle = stream.cleanTitle.isEmpty ? stream.title : stream.cleanTitle
        let hasProxyHeaders = (stream.proxyHeaders != nil && !stream.proxyHeaders!.isEmpty)
        let shouldRouteProxy = StreamRouteProxyManager.shared.shouldProxy(stream: stream)

        // Route HTTP streams with required headers OR scoped forward proxy streams through the local proxy
        if !stream.isTorrent && (hasProxyHeaders || shouldRouteProxy) {
            if !StreamProxyManager.shared.isRunning {
                StreamProxyManager.shared.start()
            }
            if let proxied = StreamProxyManager.shared.proxyURL(for: target, headers: stream.proxyHeaders, title: streamTitle) {
                if shouldRouteProxy {
                    print("[PlayerManager] Routing through StreamProxyManager via forward proxy for \(stream.source)")
                } else {
                    print("[PlayerManager] Routing through proxy for \(stream.source) (headers: \(stream.proxyHeaders?.keys.joined(separator: ", ") ?? ""))")
                }
                return proxied
            }
        }

        return target
    }
    
    func selectStream(_ stream: Stream) {
        print("Selected stream: \(stream.title) from \(stream.source)")
        self.linkedSeasonPack = nil
        self.currentSelectedStream = stream
        self.isManualSelection = true
        self.forceStreamPicker = false
        self.isStreamPickerPresented = false
        self.hasConfirmedPlaybackSuccess = false
        attemptStream(stream)
    }

    /// Retries playing the current stream, keeping any pendingResumeTime intact.
    func retryCurrentStream() {
        self.errorMessage = nil
        self.currentStreamURL = nil
        self.hasConfirmedPlaybackSuccess = false
        if let stream = self.currentSelectedStream {
            attemptStream(stream)
        } else if let first = self.availableStreams.first {
            attemptStream(first)
        } else {
            refreshStreamsForPicker()
        }
    }

    /// Extracts the clean external stream URL from any loopback proxy or stream object.
    /// Never exposes internal loopback proxy addresses (127.0.0.1:51547) to the user.
    func cleanPlayableURLString(from rawString: String) -> String {
        if rawString.contains("127.0.0.1:51547"),
           let comp = URLComponents(string: rawString),
           let target = comp.queryItems?.first(where: { $0.name == "url" })?.value,
           !target.isEmpty {
            return target
        }
        if !rawString.isEmpty {
            return rawString
        }
        return currentStreamURL?.absoluteString ?? currentSelectedStream?.url.absoluteString ?? ""
    }

    /// Two-phase playback (Stremio-style): torrents are resolved by the Stremio server,
    /// then the URL is handed to mpv. Dead sources fail and fall through to next candidate.
    private func attemptStream(_ stream: Stream) {
        self.currentAttemptStartTime = CFAbsoluteTimeGetCurrent()
        self.currentSelectedStream = stream
        self.hasCommittedAutoPlayWinner = true
        self.isAutoPlayRaceActive = false
        // Single telemetry line per committed attempt (error channel persists;
        // per-candidate logging would spam). Proxied = loopback routing intent.
        let routedViaProxy = (stream.proxyHeaders?.isEmpty == false) && !stream.isTorrent && StreamProxyManager.shared.isRunning
        Logger.stream.error("Attempting stream (proxied=\(routedViaProxy, privacy: .public)) from \(stream.source, privacy: .public)")
        let isFluxEnabled = UserDefaults.standard.object(forKey: UserDefaults.Key.enableFluxMode) as? Bool ?? true

        // Each committed attempt is a fresh startup: clear any stale
        // hasPlaybackStarted left by the previous candidate/session so this
        // attempt's watchdog is actually live (see reset rationale in play()).
        hasPlaybackStarted = false

        // Cancel any existing startup watchdog
        startupWatchdogTask?.cancel()
        startupWatchdogTask = nil
        lastTelemetryProgressTime = nil
        lastObservedCacheTime = 0.0
        startupThroughputSamples.removeAll()
        lastStartupTimePos = 0.0
        slowStartStrikes = 0

        // Set up smart startup watchdog in Flux Mode with stall detection
        if isFluxEnabled && !isManualSelection {
            armStartupWatchdog(for: stream)
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
                        self.startTorrentStatsPolling(for: stream)
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

            // Speculative torrent pre-warming in "both" mode:
            // If standby fallbacks include a healthy torrent, pre-register it with the Go engine
            // so if HTTP buffers or stalls, the fallback torrent swarm is already connected and warm!
            if isFluxEnabled, let standbyTorrent = self.standbyFallbacks.first(where: { $0.isTorrent }),
               let hash = self.torrentHash(standbyTorrent) {
                print("[PlayerManager] ⚡ Speculatively pre-warming standby torrent: \(standbyTorrent.cleanTitle) (\(standbyTorrent.seeders ?? 0) seeds)")
                AsyncTask {
                    let serverUp = await StremioServerManager.shared.ensureRunning()
                    if serverUp {
                        StremioServerManager.shared.trackCreate(
                            infoHash: hash,
                            magnetURL: standbyTorrent.url.absoluteString,
                            fileIdx: standbyTorrent.fileIdx ?? 0
                        )
                    }
                }
            }
        }
    }

    /// Arms the smart startup watchdog: advances to the standby fallback on
    /// connect timeout (no bytes at all) or on a mid-startup stall (bytes
    /// stopped flowing). Only meaningful in Flux Mode auto-selection; manual
    /// picks surface errors instead of silently swapping sources.
    /// Also used by the prefetch fast path (fetchAndRace finishSelect), which
    /// never routes through attemptStream — without this, a stale warm core
    /// (expired CDN token, dead origin) would hang with no auto-advance.
    private func armStartupWatchdog(for stream: Stream) {
        lastTelemetryProgressTime = nil
        lastObservedCacheTime = 0.0
        lastStartupTimePos = 0.0
        startupThroughputSamples.removeAll()
        slowStartStrikes = 0

        let isProxiedHTTP = !stream.isTorrent && StreamRouteProxyManager.shared.shouldProxy(stream: stream)
        let connectTimeout: TimeInterval = stream.isTorrent ? 35.0 : (isProxiedHTTP ? 20.0 : 14.0)
        print("[PlayerManager] ⏱️ Armed startup stall watchdog for \(stream.cleanTitle) (\(stream.quality)): connect timeout \(Int(connectTimeout))s")
        let startedAt = Date()
        startupWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // check every 1s
                guard !Task.isCancelled else { return }

                let shouldAdvance = await MainActor.run { () -> Bool in
                    guard let self = self else { return false }

                    let elapsed = Date().timeIntervalSince(startedAt)

                    if self.hasPlaybackStarted {
                        // Playback has successfully started and frames are rendering.
                        // Disarm startup watchdog to avoid interrupting healthy playback.
                        return false
                    }

                    // Slow-delivery / dead-origin detection — runs for BOTH
                    // zero-telemetry (dead origin: proxy accepted the socket,
                    // upstream never sent a byte) and trickling sources.
                    // For HTTP streams, 8s is plenty for CDN response.
                    // For P2P swarms, allow 30s for DHT peer discovery, tracker
                    // announces, piece bitfield handshake, and initial moov/header priming.
                    let isProxiedHTTP = !stream.isTorrent && StreamRouteProxyManager.shared.shouldProxy(stream: stream)
                    let slowLimit: TimeInterval = stream.isTorrent ? 35.0 : (isProxiedHTTP ? 14.0 : 8.0)
                    let slowMediaFloor: Double = stream.isTorrent ? 1.0 : 1.5

                    // For torrents: check if the swarm is actively receiving data
                    let isTorrentDownloading: Bool
                    if stream.isTorrent {
                        let hasRecentTelemetry = self.lastTelemetryProgressTime.map { Date().timeIntervalSince($0) < 12.0 } ?? false
                        let hasProgress = self.torrentStreamProgress >= 0.02
                        isTorrentDownloading = hasRecentTelemetry || hasProgress
                    } else {
                        isTorrentDownloading = false
                    }

                    if elapsed >= slowLimit, self.lastObservedCacheTime < slowMediaFloor, !isTorrentDownloading {
                        print("[PlayerManager] 🐌 Slow/dead source detected (only \(String(format: "%.1f", self.lastObservedCacheTime))s of media buffered in \(Int(elapsed))s). Auto-advancing to standby fallback...")
                        Logger.stream.error("Slow/dead source advanced after \(elapsed, privacy: .public)s (cache \(self.lastObservedCacheTime, privacy: .public)s) from \(stream.source, privacy: .public)")
                        self.advanceToStandbyFallback()
                        return true
                    }

                    // If bytes have started flowing (telemetry received for this session):
                    if let lastProgress = self.lastTelemetryProgressTime, lastProgress >= startedAt {
                        let stallDuration = Date().timeIntervalSince(lastProgress)
                        let stallTimeout: TimeInterval = stream.isTorrent ? 25.0 : 10.0
                        if stallDuration >= stallTimeout {
                            print("[PlayerManager] ⏱️ Stream stall detected (zero bytes for \(Int(stallDuration))s). Auto-advancing to standby fallback...")
                            self.advanceToStandbyFallback()
                            return true
                        }
                        return false
                    }

                    // Connecting phase: no bytes received yet
                    if elapsed >= connectTimeout, !isTorrentDownloading {
                        print("[PlayerManager] ⏱️ Stream connect timeout (\(Int(connectTimeout))s, no response). Auto-advancing to standby fallback...")
                        self.advanceToStandbyFallback()
                        return true
                    }

                    return false
                }

                if shouldAdvance { break }

                let playbackActive = await MainActor.run { [weak self] () -> Bool in
                    self?.hasPlaybackStarted == true
                }
                if playbackActive {
                    print("[PlayerManager] ▶️ Playback confirmed started — disarmed startup stall watchdog.")
                    break
                }
            }
        }
    }

    func startTorrentStatsPolling(for stream: Stream) {
        guard stream.isTorrent, let hash = torrentHash(stream) else { return }
        self.torrentStatsPollTask?.cancel()
        self.torrentStreamProgress = 0.0
        let targetFileIdx = stream.fileIdx ?? 0
        self.torrentStatsPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled, let self = self else { break }
                if self.hasPlaybackStarted { break }
                let stats = await StremioServerManager.shared.fetchTorrentStats(infoHash: hash, fileIdx: targetFileIdx)
                guard !Task.isCancelled else { break }
                if let stats {
                    var calculatedProgress: Double = 0.0
                    if let progress = stats.streamProgress, progress > 0 {
                        calculatedProgress = max(calculatedProgress, progress)
                    }
                    if let downloaded = stats.downloaded, downloaded > 0 {
                        self.lastTelemetryProgressTime = Date()
                        // Initial startup buffer fill target (~12.5MB for smooth first frame delivery)
                        let bytesProgress = min(0.90, Double(downloaded) / 12_500_000.0)
                        calculatedProgress = max(calculatedProgress, bytesProgress)
                    } else if let unchoked = stats.unchoked, unchoked > 0 {
                        calculatedProgress = max(calculatedProgress, 0.05)
                    } else if let peers = stats.peers, peers > 0 {
                        calculatedProgress = max(calculatedProgress, 0.02)
                    }

                    if calculatedProgress > 0 {
                        self.torrentStreamProgress = min(0.95, max(self.torrentStreamProgress, calculatedProgress))
                        self.reportTelemetryProgress(cacheTime: self.torrentStreamProgress * 5.0)
                    }
                }
            }
        }
    }

    func markPlaybackStarted() {
        hasPlaybackStarted = true
        torrentStatsPollTask?.cancel()
        torrentStatsPollTask = nil
        startupWatchdogTask?.cancel()
        startupWatchdogTask = nil
        print("[PlayerManager] ▶️ Playback confirmed started — canceled startup watchdog.")
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
        // NOTE: deliberately no watchdog cancel here. The watchdog now also
        // runs the 30s post-start hot-swap monitor and exits on its own via
        // the monitor-expiry break; cancelling at 1.5s of cache would blind
        // the slow-source hot-swap right when buffering has barely begun.
        // Pre-start checks are guarded by hasPlaybackStarted, so a healthy
        // stream is never advanced past.
    }

    /// Feed from PlayerView's 0.5s timer: mpv's native cache-speed (KB/s)
    /// plus the current position, for the startup hot-swap monitor.
    func reportStartupThroughput(kbps: Double, timePos: Double) {
        lastStartupTimePos = timePos
        startupThroughputSamples.append((Date(), kbps))
        startupThroughputSamples.removeAll { Date().timeIntervalSince($0.date) > 6.0 }
    }

    /// Sustained throughput (KB/s) averaged over the trailing window.
    /// nil until ~2s of samples exist (0.5s cadence).
    private func sustainedStartupThroughputKBps(window: TimeInterval) -> Double? {
        let cutoff = Date().addingTimeInterval(-window)
        let recent = startupThroughputSamples.filter { $0.date >= cutoff }
        guard recent.count >= 4 else { return nil }
        return recent.map { $0.kbps }.reduce(0, +) / Double(recent.count)
    }

    func advanceToStandbyFallback() {
        guard !isManualSelection else { return }
        startupWatchdogTask?.cancel()
        startupWatchdogTask = nil
        fallbackThrottleTask?.cancel()
        fallbackThrottleTask = nil

        guard !standbyFallbacks.isEmpty else {
            print("[PlayerManager] No standby fallbacks remaining — falling back to standard next stream.")
            tryNextStream()
            return
        }

        let timeSinceLast = Date().timeIntervalSince(lastFallbackAttemptDate)
        if timeSinceLast < 0.8 {
            print("[PlayerManager] ⏳ Fallback throttled (occurred within \(String(format: "%.2f", timeSinceLast))s) — scheduling smooth transition...")
            fallbackThrottleTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled, let self = self else { return }
                self.advanceToStandbyFallback()
            }
            return
        }
        lastFallbackAttemptDate = Date()

        let prefQuality = UserDefaults.standard.string(forKey: UserDefaults.Key.preferredQuality) ?? "1080p"
        let maxScore = StreamManager.shared.qualityScore(prefQuality)
        
        var nextFallback: Stream? = nil
        var higherQualityFallback: Stream? = nil
        while !standbyFallbacks.isEmpty {
            let candidate = standbyFallbacks.removeFirst()
            let score = StreamManager.shared.qualityScore(candidate.quality)
            if let title = currentItem?.title, !title.isEmpty, StreamManager.labelLooksLikeJunk(labelText: candidate.fullScannableText, targetTitle: title) {
                continue
            }
            if score > maxScore && maxScore >= 3 {
                // Keep higher-quality candidate as last resort rather than failing completely
                if higherQualityFallback == nil {
                    higherQualityFallback = candidate
                }
                continue
            }
            nextFallback = candidate
            break
        }

        if nextFallback == nil {
            nextFallback = higherQualityFallback
        }

        guard let fallback = nextFallback else {
            print("[PlayerManager] No eligible standby fallbacks remaining — falling back to standard next stream.")
            tryNextStream()
            return
        }
        print("[PlayerManager] ⚡ Seamlessly advancing to standby fallback: \(fallback.cleanTitle) (\(fallback.quality)) via \(fallback.source)")

        // If the old stream stalled or failed, record it so it is not
        // re-elected as candidate #1 next time: torrents get a session-scoped
        // dead hash, HTTP origins get a delivery-reputation strike
        // (HostHealthTracker — demoted in computeCompositeRank) plus a failed
        // probeStatus so selectFastStartCandidate filters it for this session.
        if let currentURL = currentStreamURL, let oldStream = availableStreams.first(where: { getPlayableURL(for: $0) == currentURL }) {
            if oldStream.isTorrent, let oldHash = torrentHash(oldStream) {
                markHashDead(oldStream)
                StremioServerManager.shared.removeTorrent(infoHash: oldHash)
            } else if !oldStream.isTorrent {
                markHashDead(oldStream)
                HostHealthTracker.shared.recordFailure(host: oldStream.url.host ?? "")
                self.probeStatus[oldStream.stableKey] = StreamProbeResult(ok: false, latency: 3.0)
            }
        }

        attemptStream(fallback)
    }

    private func finishSelect(_ stream: Stream) {
        self.currentSelectedStream = stream
        let targetURL = getPlayableURL(for: stream)
        self.currentStreamURL = targetURL
        let hash = stream.isTorrent ? torrentHash(stream) : nil
        if stream.isTorrent, let h = hash {
            self.activeTorrentHash = h
            self.currentMagnetURL = stream.url.absoluteString.hasPrefix("magnet:") ? stream.url.absoluteString : "magnet:?xt=urn:btih:\(h)"
        } else {
            self.activeTorrentHash = nil
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
        self.linkedSeasonPack = nil
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
            isStreamPickerPresented = true
            return
        }

        guard let idx = availableStreams.firstIndex(where: { $0.stableKey == failed.stableKey || $0.id == failed.id }) else {
            errorMessage = "Unable to play video. Please try another source."
            isStreamPickerPresented = true
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
            isStreamPickerPresented = true
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
    
    func updateWatchProgress(time: Double, duration: Double, isLightweightTick: Bool = false) {
        guard var item = currentItem, duration > 0 else { return }

        // Duration Sanity Watchdog: Detect and block promos, trailers, and preview clips pretending to be full content.
        // Movies are >= 40 minutes (2400s), but anything under 10 minutes (600s) is definitively a trailer/promo clip.
        // TV episodes are >= 15 minutes (900s), but anything under 5 minutes (300s) is definitively an intro/preview/promo.
        if !self.isManualSelection {
            let isEpisodic = item.isSeries || item.category == "TV Show" || currentSeason != nil
            let minDurationFloor: Double = isEpisodic ? 300.0 : 600.0
            if duration < minDurationFloor {
                print("[PlayerManager] ⚠️ Suspected promo/trailer detected: duration \(Int(duration))s is under threshold (\(Int(minDurationFloor))s) for \(item.title). Advancing to standby fallback...")
                Logger.stream.error("Suspected promo/trailer detected: duration \(duration, privacy: .public)s for \(item.title, privacy: .public)")
                self.advanceToStandbyFallback()
                return
            }
        }
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
        let currentEpKey = "\(item.id):\(currentSeason ?? -1):\(currentEpisode ?? -1)"
        if currentEpKey != currentTrackingEpisodeKey {
            currentTrackingEpisodeKey = currentEpKey
            sessionMaxPosition = time
            sessionMaxProgress = progress
        } else {
            sessionMaxPosition = max(sessionMaxPosition, time)
            sessionMaxProgress = max(sessionMaxProgress, progress)
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
                progress: sessionMaxProgress,
                season: currentSeason,
                episode: currentEpisode,
                episodeImage: currentEpisodeImage,
                playbackPosition: time,
                playbackDuration: duration,
                streamURL: currentStreamURL,
                torrentInfoHash: activeTorrentHash,
                fileIndex: nil,
                isLightweightTick: isLightweightTick
            )
        }
        if !isLightweightTick || progress >= 0.90 {
            TasteProfileManager.shared.recordWatch(item, progress: progress)
        }
    }

    /// High-water mark tracking per playback session to prevent Continue Watching regress
    private var sessionMaxPosition: Double = 0.0
    private var sessionMaxProgress: Double = 0.0
    private var currentTrackingEpisodeKey: String = ""

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
        guard let next = await resolveNextReleased(item: item, season: season, episode: episode) else {
            // Reached series finale / no next released episode:
            // Mark the series as completed (progress = 1.0) so it leaves Continue Watching and moves to Recently Watched!
            UserDataService.shared.addToHistory(
                item,
                progress: 1.0,
                season: season,
                episode: episode,
                episodeImage: self.currentEpisodeImage,
                playbackPosition: duration,
                playbackDuration: duration,
                streamURL: self.currentStreamURL,
                torrentInfoHash: self.activeTorrentHash,
                fileIndex: nil,
                isRestart: true
            )
            return
        }
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
        if let eps = item.episodes, !eps.isEmpty {
            let seasonEps = eps.filter { $0.seasonNumber == currentSeasonNum }
            if let nxt = seasonEps.filter({ $0.episodeNumber > currentEpisodeNum }).min(by: { $0.episodeNumber < $1.episodeNumber }) {
                return (currentSeasonNum, nxt.episodeNumber)
            }
            let nextSeasonEps = eps.filter { $0.seasonNumber == currentSeasonNum + 1 }
            if let e1 = nextSeasonEps.first(where: { $0.episodeNumber == 1 }) {
                return (currentSeasonNum + 1, 1)
            }
        }
        if let countNext = countBasedNext(seasons: item.seasons, season: currentSeasonNum, episode: currentEpisodeNum) {
            return countNext
        }
        // Fallback when neither episodes nor seasons are present in memory yet (e.g. Continue Watching):
        // Assume next episode in current season so background resolution can fetch metadata
        return (currentSeasonNum, currentEpisodeNum + 1)
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
        if let nextEp = nextEpisode {
            if !nextEp.isUpcoming {
                return (nextEp.seasonNumber, nextEp.episodeNumber)
            } else {
                return nil
            }
        }
        let verdict = releaseVerdict(episodes: item.episodes, seasons: item.seasons, season: cs, episode: ce)
        if verdict.covered {
            return verdict.next
        }
        // When not covered by local listings (e.g. Continue Watching resume before full seasons fetched),
        // fall back to nextEpisodeInfo so the prompt/action can proceed and resolve metadata
        return nextEpisodeInfo
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
            if let meta = try? await StremioService.shared.fetchMeta(type: "series", id: item.id) {
                let matchedEp = meta.episodes?.first(where: { $0.seasonNumber == next.season && $0.episodeNumber == next.episode })
                    ?? meta.episodes?.first(where: { $0.seasonNumber == next.season + 1 && $0.episodeNumber == 1 })
                if let ep = matchedEp {
                    await MainActor.run {
                        guard self.currentItem?.id == item.id,
                              self.currentSeason == next.season || self.nextEpisodeInfo?.season == next.season else { return }
                        self.nextEpisode = ep
                        // Backfill listings so air-gated math + rail advancement work
                        // for items resumed from Continue Watching (which carry no
                        // seasons/episodes arrays). Never clobbers richer data.
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
            isAutoAdvance: true,
            startFromBeginning: true
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

            // Auto-Play Season Pack Direct Link for Preloading:
            // If the currently playing stream is a season pack (P2P or HTTP), link directly to that same source for the next episode.
            let activePack: LinkedSeasonPackSource? = await MainActor.run {
                guard let cur = self.currentSelectedStream, cur.isSeasonPack else { return nil }
                return LinkedSeasonPackSource(stream: cur, activeTorrentHash: self.activeTorrentHash)
            }

            if let linked = activePack,
               let matchingSeasonPackStream = streams.first(where: { linked.matches($0) }) {
                print("[PlayerManager] ⚡ Smart preloading linked directly to active season pack (\(matchingSeasonPackStream.isTorrent ? "P2P" : "HTTP")): \(matchingSeasonPackStream.cleanTitle) (fileIdx: \(matchingSeasonPackStream.fileIdx ?? 0))")
                if matchingSeasonPackStream.isTorrent, let packHash = linked.infoHash {
                    StremioServerManager.shared.trackCreate(
                        infoHash: packHash,
                        magnetURL: matchingSeasonPackStream.url.absoluteString,
                        fileIdx: matchingSeasonPackStream.fileIdx ?? 0
                    )
                    _ = await self.resolveTorrentStream(matchingSeasonPackStream)
                }

                let subs = await subsTask
                await MainActor.run {
                    self.prefetchedNextStream = matchingSeasonPackStream
                    self.prefetchedNextSubtitles = subs
                    self.prefetchedNextKey = nextKey
                    self.prefetchedNextAt = Date()
                }
                return
            }

            let sourceMode = UserDefaults.standard.string(forKey: UserDefaults.Key.streamingSourceMode) ?? "both"
            let preferredQuality = UserDefaults.standard.string(forKey: UserDefaults.Key.preferredQuality) ?? "1080p"
            let preferredLang = UserDefaults.standard.string(forKey: "defaultAudioLang") ?? "English"
            let preferredLanguages = UserDefaults.standard.stringArray(forKey: UserDefaults.Key.preferredStreamLanguages) ?? [preferredLang]
            let enableLanguageFilter = UserDefaults.standard.bool(forKey: "enableFluxLanguageFilter")

            let (bestNext, _) = StreamManager.shared.selectFastStartCandidate(
                from: streams,
                sourceMode: sourceMode,
                preferredQuality: preferredQuality,
                preferredLang: preferredLang,
                preferredLanguages: preferredLanguages,
                originalLanguage: item.effectiveOriginalLanguage ?? item.originalLanguage,
                enableLanguageFilter: enableLanguageFilter,
                probeStatus: await MainActor.run { self.probeStatus },
                targetSeason: next.season,
                targetEpisode: next.episode,
                targetTitle: item.title
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
            if isFetchingStreams {
                print("[PlayerManager] tryNextStream invoked while streams are still actively fetching — deferring until scrape finishes.")
                return
            }
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
