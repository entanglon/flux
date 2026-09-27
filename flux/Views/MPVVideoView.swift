import SwiftUI
import AppKit
import OpenGL.GL
import Libmpv
import Combine
import Darwin
import OSLog
import CoreAudio

/// Pauses playback when the macOS default audio output device changes
/// mid-playback (AirPods cased / Bluetooth dropped / HDMI unplugged) —
/// IINA parity. Pause-only, never auto-resume; the pause is marked as
/// user-initiated so overlays and controls treat it exactly like Space.
/// NOTE: removing a SINGLE bud usually fires no system signal at all (audio
/// keeps playing in the other bud, device stays alive), so that case is
/// undetectable without private APIs. Full disconnects are covered.
final class AudioOutputRouteMonitor {
    static let shared = AudioOutputRouteMonitor()
    var onRouteChanged: (() -> Void)?
    private let lock = NSLock()
    private var started = false

    /// Pure decision logic, hermetically unit-testable.
    static func shouldAutoPause(hasLoadedMedia: Bool, isPlaying: Bool, isUserPaused: Bool) -> Bool {
        hasLoadedMedia && isPlaying && !isUserPaused
    }

    func start() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard !self.started else { return }
            self.started = true
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &addr, audioRouteListener, nil)
        }
    }
}

private func audioRouteListener(_ inObjectID: AudioObjectID, _ inNumberAddresses: UInt32, _ inAddresses: UnsafePointer<AudioObjectPropertyAddress>, _ inClientData: UnsafeMutableRawPointer?) -> OSStatus {
    // CoreAudio fires on its own thread; hop to main for controller state.
    DispatchQueue.main.async { AudioOutputRouteMonitor.shared.onRouteChanged?() }
    return noErr
}
// MARK: - SwiftUI View
struct MPVVideoView: NSViewControllerRepresentable {
    @ObservedObject var controller: MPVController
    
    func makeNSViewController(context: Context) -> MPVViewController {
        let vc: MPVViewController
        if let existing = controller.playerView {
            // Adopted warm core from the detail-page prefetch — already paired
            // with its controller and buffering the stream.
            vc = existing
        } else {
            vc = MPVViewController()
            vc.delegate = controller
            _ = vc.view // Force loadView + viewDidLoad with delegate wired
            controller.playerView = vc
        }
        context.coordinator.player = vc // Link controller to view
        controller.flushPendingPlay(into: vc)
        return vc
    }
    
    func updateNSViewController(_ nsViewController: MPVViewController, context: Context) {
        // Updates handled via controller
    }
    
    static func dismantleNSViewController(_ nsViewController: MPVViewController, coordinator: Coordinator) {
        // While PiP floats this render layer, its mpv core must survive the
        // player window's INTENTIONAL unmount (entering PiP closes the window).
        // PiP owns teardown for that case — cleanup here would kill playback.
        if PiPManager.shared.isHosting(nsViewController.playerView) {
            return
        }
        nsViewController.playerView.cleanup()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject {
        var parent: MPVVideoView
        weak var player: MPVViewController?
        
        init(_ parent: MPVVideoView) {
            self.parent = parent
        }
    }
}

// MARK: - Models
struct PlaybackDiagnostics: Equatable {
    var videoCodec: String = "Unknown"
    var audioCodec: String = "Unknown"
    var resolution: String = "Unknown"
    var fps: Double = 0.0
    var videoBitrate: Double = 0.0 // kbps
    var audioBitrate: Double = 0.0 // kbps
    var hwDecoder: String = "None"
    var droppedFrames: Int = 0
    var cacheBufferSeconds: Double = 0.0
}

struct Track: Identifiable, Equatable {
    let id: Int
    let type: String // "audio", "sub"
    let title: String
    let lang: String
    var isSelected: Bool
    var isDefault: Bool = false
    var isForced: Bool = false
    
    var displayName: String {
        let rawTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let isUnknownTitle = rawTitle.isEmpty || rawTitle.lowercased() == "unknown" || rawTitle.lowercased().starts(with: "track")
        
        var languageName = ""
        if !lang.isEmpty && lang.lowercased() != "und" {
            let locale = Locale(identifier: "en")
            if let localized = locale.localizedString(forLanguageCode: lang), !localized.isEmpty {
                languageName = localized.capitalized
            } else {
                switch lang.lowercased() {
                case "eng", "en": languageName = "English"
                case "hin", "hi": languageName = "Hindi"
                case "spa", "es": languageName = "Spanish"
                case "fre", "fra", "fr": languageName = "French"
                case "ger", "deu", "de": languageName = "German"
                case "zho", "chi", "zh": languageName = "Chinese"
                case "jpn", "ja": languageName = "Japanese"
                case "kor", "ko": languageName = "Korean"
                case "rus", "ru": languageName = "Russian"
                case "ita", "it": languageName = "Italian"
                case "por", "pt": languageName = "Portuguese"
                case "tam", "ta": languageName = "Tamil"
                case "tel", "te": languageName = "Telugu"
                case "kan", "kn": languageName = "Kannada"
                case "mal", "ml": languageName = "Malayalam"
                case "ara", "ar": languageName = "Arabic"
                default: languageName = lang.uppercased()
                }
            }
        }
        
        if !isUnknownTitle {
            if !languageName.isEmpty && !rawTitle.lowercased().contains(languageName.lowercased()) {
                return "\(languageName) - \(rawTitle)"
            }
            return rawTitle
        }
        
        if !languageName.isEmpty {
            return "\(languageName) (\(type == "audio" ? "Audio" : "Subtitles"))"
        }
        
        return "\(type == "audio" ? "Audio Track" : "Subtitle Track") \(id)"
    }
}

// MARK: - Chapter Model
struct MediaChapter: Identifiable, Equatable {
    let id: Int
    let title: String
    let time: Double
}

// MARK: - Perceptual Volume Curve & Audio Amplification
public struct VolumeCurve {
    /// Maps UI slider value (0.0 ... 2.0) to mpv volume property (0.0 ... 200.0)
    /// 0.0 ... 1.0 uses a square root curve so 0.5 slider produces -9.0 dB (perceived half loudness)
    /// 1.0 ... 2.0 maps linearly up to 200.0 (+18.1 dB audio boost, matching VLC / Stremio)
    public static func uiToMpv(_ uiVolume: Double) -> Double {
        let clamped = max(0.0, min(uiVolume, 2.0))
        if clamped <= 0.0001 {
            return 0.0
        } else if clamped <= 1.0 {
            return sqrt(clamped) * 100.0
        } else {
            return clamped * 100.0
        }
    }

    /// Maps mpv volume property (0.0 ... 200.0) back to UI slider value (0.0 ... 2.0)
    public static func mpvToUi(_ mpvVolume: Double) -> Double {
        let clamped = max(0.0, min(mpvVolume, 200.0))
        if clamped <= 0.0001 {
            return 0.0
        } else if clamped <= 100.0 {
            return pow(clamped / 100.0, 2.0)
        } else {
            return clamped / 100.0
        }
    }

    /// Returns the approximate decibel gain or attenuation for a given mpv volume
    public static func decibels(forMpvVolume mpvVolume: Double) -> Double {
        guard mpvVolume > 0.0001 else { return -.infinity }
        return 60.0 * log10(mpvVolume / 100.0)
    }
}

// MARK: - Controller
class MPVController: ObservableObject {
    @Published var isPlaying = false
    @Published var progress: Double = 0.0
    @Published var duration: Double = 0.0
    @Published var timePos: Double = 0.0
    @Published var volume: Double = 1.0
    @Published var bufferProgress: Double = 0.0
    /// mpv's native `cache-speed` — current I/O read speed between the cache
    /// and the network layer, in KB/s over a 1-second window. Read-only
    /// telemetry (no engine config change); feeds the startup hot-swap
    /// monitor that hot-swaps starved sources for measured-faster standbys.
    var recentCacheSpeedKBps: Double = 0.0
    /// True once a loadfile was issued on this controller — lets the player
    /// window adopt a prefetch warm core without issuing a second load.
    @Published private(set) var hasLoadedMedia = false
    /// URL handed to the most recent loadfile — dedupes redundant reloads when
    /// currentStreamURL catches up after an early warm-core adoption.
    private(set) var loadedURL: URL?
    
    @Published var isBuffering = false
    /// When the current cache stall began (nil while flowing). Telemetry only.
    private var stallStartDate: Date?
    /// frame-drop-count at stall begin, for delta computation at stall end.
    private var stallStartDrops = -1
    @Published var demuxerCacheTime: Double = 0.0
    @Published var demuxerCacheDuration: Double = 0.0
    @Published var isSeeking = false
    @Published var isUserPaused = false
    
    @Published var audioTracks: [Track] = []
    @Published var subtitleTracks: [Track] = []
    @Published var chapters: [MediaChapter] = []
    
    // MARK: - Playback Calibration & Shaders
    @Published var subtitleDelay: Double = 0.0 // seconds (-10.0 ... 10.0)
    @Published var subtitleScale: Double = 1.0 // 0.5 ... 2.0
    @Published var subtitlePos: Double = 100.0 // 0 ... 100
    @Published var audioDelay: Double = 0.0 // seconds (-10.0 ... 10.0)
    @Published var isDialogueBoostEnabled: Bool = false
    @Published var videoAspect: String = "auto" // auto, 16:9, 21:9, 4:3
    @Published var isDebandEnabled: Bool = false
    @Published var contrast: Double = 0.0 // -100 ... 100
    @Published var brightness: Double = 0.0 // -100 ... 100
    @Published var saturation: Double = 0.0 // -100 ... 100

    func setSubtitleDelay(_ delay: Double) {
        let rounded = (delay * 20.0).rounded() / 20.0
        self.subtitleDelay = rounded
        playerView?.setSubtitleDelay(rounded)
    }

    func setSubtitleScale(_ scale: Double) {
        let clamped = max(0.5, min(scale, 2.0))
        let rounded = (clamped * 10.0).rounded() / 10.0
        self.subtitleScale = rounded
        playerView?.setSubtitleScale(rounded)
    }

    func setSubtitlePos(_ pos: Double) {
        let clamped = max(0.0, min(pos, 100.0))
        self.subtitlePos = clamped
        playerView?.setSubtitlePos(clamped)
    }

    func setAudioDelay(_ delay: Double) {
        let rounded = (delay * 20.0).rounded() / 20.0
        self.audioDelay = rounded
        playerView?.setAudioDelay(rounded)
    }

    func toggleDialogueBoost() {
        self.isDialogueBoostEnabled.toggle()
        playerView?.setDialogueBoost(self.isDialogueBoostEnabled)
    }

    func setVideoAspect(_ aspect: String) {
        self.videoAspect = aspect
        playerView?.setVideoAspect(aspect)
    }

    func toggleDeband() {
        self.isDebandEnabled.toggle()
        playerView?.setDeband(self.isDebandEnabled)
    }

    func setContrast(_ value: Double) {
        self.contrast = max(-100, min(value, 100))
        playerView?.setContrast(self.contrast)
    }

    func setBrightness(_ value: Double) {
        self.brightness = max(-100, min(value, 100))
        playerView?.setBrightness(self.brightness)
    }

    func setSaturation(_ value: Double) {
        self.saturation = max(-100, min(value, 100))
        playerView?.setSaturation(self.saturation)
    }

    func getPlaybackDiagnostics() -> PlaybackDiagnostics {
        let backend = playerView?.playerView
        var diag = PlaybackDiagnostics()
        diag.videoCodec = backend?.getPropertyString("video-codec") ?? backend?.getPropertyString("video-format") ?? "Unknown"
        diag.audioCodec = backend?.getPropertyString("audio-codec") ?? "Unknown"
        let w = backend?.getPropertyInt("video-params/w")
        let h = backend?.getPropertyInt("video-params/h")
        if let w = w, let h = h, w > 0, h > 0 {
            diag.resolution = "\(w)×\(h)"
        }
        diag.fps = backend?.getPropertyDouble("estimated-vf-fps") ?? 0.0
        diag.videoBitrate = (backend?.getPropertyDouble("video-bitrate") ?? 0.0) / 1000.0
        diag.audioBitrate = (backend?.getPropertyDouble("audio-bitrate") ?? 0.0) / 1000.0
        diag.hwDecoder = backend?.getPropertyString("hwdec-current") ?? "software"
        diag.droppedFrames = backend?.getPropertyInt("frame-drop-count") ?? 0
        diag.cacheBufferSeconds = self.demuxerCacheDuration > 0 ? self.demuxerCacheDuration : max(0.0, self.demuxerCacheTime - self.timePos)
        return diag
    }
    
    // Settings
    @AppStorage("useHardwareAcceleration") private var useHardwareAcceleration = true
    
    var onPlaybackError: (() -> Void)?
    /// Bumped once per natural end-of-file (see event loop). PlayerView observes
    /// via onChange — a closure would capture a stale View struct.
    @Published private(set) var endOfFileCount = 0
    func registerEndOfFile() { endOfFileCount += 1 }
    var isCoreAlive: Bool {
        playerView?.playerView?.mpv != nil
    }

    weak var playerView: MPVViewController? {
        didSet {
            if let pv = playerView {
                flushPendingPlay(into: pv)
            }
        }
    }
    fileprivate var pendingPlayURL: URL?
    fileprivate var pendingPaused: Bool = false
    private var hasAutoSelectedAudio = false
    private var hasAutoSelectedSubtitles = false

    func flushPendingPlay(into pv: MPVViewController) {
        guard let url = pendingPlayURL else { return }
        let paused = pendingPaused
        pendingPlayURL = nil
        pendingPaused = false
        pv.loadViewIfNeeded()
        print("[MPVController] playerView attached! Loading queued stream: \(url.lastPathComponent) (paused: \(paused))")
        if paused {
            pv.setMute(true)
            pv.play(url, paused: true)
        } else {
            pv.setMute(false)
            pv.play(url, paused: false)
        }
    }

    func handleCoreDestroyed() {
        print("[MPVController] Underlying mpv core destroyed — resetting media state")
        self.hasLoadedMedia = false
        self.loadedURL = nil
        self.pendingPlayURL = nil
        self.pendingPaused = false
        self.isPlaying = false
        self.timePos = 0.0
        self.duration = 0.0
        self.progress = 0.0
        self.isBuffering = false
    }
    
    func preparePaused(url: URL) {
        if hasLoadedMedia, loadedURL == url, playerView != nil, isCoreAlive {
            print("[MPVController] Skipping duplicate preparePaused for \(url.lastPathComponent)")
            return
        }
        self.isUserPaused = true
        self.isPlaying = false
        self.hasLoadedMedia = true
        self.loadedURL = url
        self.hasAutoSelectedAudio = false
        self.hasAutoSelectedSubtitles = false
        guard let pv = playerView else {
            print("[MPVController] playerView not attached yet — queuing pendingPlayURL (paused) for \(url.lastPathComponent)")
            pendingPlayURL = url
            pendingPaused = true
            return
        }
        flushPendingPlay(into: pv)
    }

    func play(url: URL) {
        // Same media already loading/loaded on this controller and playerView is actively holding a live core
        if hasLoadedMedia, loadedURL == url, playerView != nil, isCoreAlive {
            print("[MPVController] Skipping duplicate loadfile for \(url.lastPathComponent)")
            if isUserPaused {
                play()
            }
            return
        }
        self.isUserPaused = false
        self.hasLoadedMedia = true
        self.loadedURL = url
        self.hasAutoSelectedAudio = false
        self.hasAutoSelectedSubtitles = false
        resetVolumeBoostIfNeeded()
        // IINA-parity auto-pause: output device vanishing mid-playback pauses.
        AudioOutputRouteMonitor.shared.start()
        AudioOutputRouteMonitor.shared.onRouteChanged = { [weak self] in
            guard let self = self else { return }
            if AudioOutputRouteMonitor.shouldAutoPause(hasLoadedMedia: self.hasLoadedMedia, isPlaying: self.isPlaying, isUserPaused: self.isUserPaused) {
                print("[MPV] Audio output route changed mid-playback — auto-pausing")
                self.pause()
            }
        }
        guard let pv = playerView else {
            print("[MPVController] playerView not attached yet — queuing pendingPlayURL for \(url.lastPathComponent)")
            pendingPlayURL = url
            pendingPaused = false
            return
        }
        pendingPlayURL = url
        pendingPaused = false
        flushPendingPlay(into: pv)
    }

    func play() {
        self.isUserPaused = false
        playerView?.setMute(false)
        playerView?.resume()
    }

    func pause() {
        self.isUserPaused = true
        playerView?.pause()
    }

    func stop() {
        self.isUserPaused = false
        self.hasLoadedMedia = false
        self.loadedURL = nil
        self.pendingPlayURL = nil
        self.pendingPaused = false
        self.timePos = 0.0
        self.duration = 0.0
        self.progress = 0.0
        self.bufferProgress = 0.0
        self.recentCacheSpeedKBps = 0.0
        self.isBuffering = false
        self.hasAutoSelectedAudio = false
        self.hasAutoSelectedSubtitles = false
        self.audioTracks = []
        self.subtitleTracks = []
        self.chapters = []
        resetVolumeBoostIfNeeded()
        playerView?.stop()
    }
    
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    // Seek by percentage (legacy/coarse)
    func seek(to value: Double) {
        // Optimistic update
        self.progress = value
        let targetTime = value * duration
        playerView?.seek(absolute: targetTime)
    }
    
    // Seek by time (precise)
    func seek(absolute time: Double) {
        if duration > 0 { self.progress = time / duration }
        playerView?.seek(absolute: time)
    }
    
    // Seek relative (skip forward/back)
    func seek(relative seconds: Double) {
        playerView?.seek(relative: seconds)
    }
    
    private var savedVolume: Double = 1.0

    func setVolume(_ value: Double) {
        let clamped = max(0.0, min(value, 2.0))
        playerView?.setVolume(clamped)
        volume = clamped
        if clamped > 0 {
            savedVolume = min(clamped, 1.0)
        }
    }

    func toggleMute() {
        if volume > 0.001 {
            savedVolume = min(volume, 1.0)
            setVolume(0)
        } else {
            setVolume(savedVolume > 0 ? savedVolume : 1.0)
        }
    }

    func resetVolumeBoostIfNeeded() {
        if volume > 1.001 {
            print("[MPVController] Resetting boosted volume (\(Int(volume * 100))%) to 100%")
            setVolume(1.0)
        }
    }
    
    func handlePropertyChange(name: String, value: Any) {
        DispatchQueue.main.async {
            switch name {
            case "time-pos":
                if let time = value as? Double {
                    self.timePos = time
                    if self.duration > 0 {
                        self.progress = time / self.duration
                    }
                }
            case "duration":
                if let dur = value as? Double {
                    self.duration = dur
                    self.fetchTracks()
                    self.fetchChapters()
                }
            case "track-list":
                self.fetchTracks()
            case "pause":
                if let paused = value as? Bool {
                    self.isPlaying = !paused
                }
            case "paused-for-cache":
                if let buff = value as? Bool {
                    // Stall telemetry on the ERROR channel: .info lines from this
                    // app never reach the persisted store. Values marked public
                    // (os.Logger redacts interpolations by default).
                    if buff && !self.isBuffering {
                        self.stallStartDate = Date()
                        self.stallStartDrops = self.playerView?.playerView?.getPropertyInt("frame-drop-count") ?? -1
                        let bufferAhead = self.demuxerCacheDuration > 0 ? self.demuxerCacheDuration : max(0.0, self.demuxerCacheTime - self.timePos)
                        let cache = String(format: "%.1f", bufferAhead)
                        let pos = String(format: "%.0f", self.timePos)
                        let af = self.playerView?.playerView?.getPropertyString("af") ?? "?"
                        Logger.player.error("Cache stall began (cache: \(cache, privacy: .public)s, at \(pos, privacy: .public)s, drops: \(self.stallStartDrops, privacy: .public), af: \(af, privacy: .public))")
                    } else if !buff && self.isBuffering {
                        let duration = self.stallStartDate.map { Date().timeIntervalSince($0) } ?? 0
                        let drops = self.playerView?.playerView?.getPropertyInt("frame-drop-count") ?? -1
                        let delta = (drops >= 0 && self.stallStartDrops >= 0) ? drops - self.stallStartDrops : -1
                        Logger.player.error("Cache stall ended after \(String(format: "%.2f", duration), privacy: .public)s (dropped delta: \(delta, privacy: .public))")
                        self.stallStartDate = nil
                    }
                    self.isBuffering = buff
                    if buff {
                        self.isUserPaused = false
                    }
                }
            case "seeking":
                if let seek = value as? Bool {
                    self.isSeeking = seek
                }
            case "volume":
                if let vol = value as? Double {
                    let uiVol = VolumeCurve.mpvToUi(vol)
                    if abs(self.volume - uiVol) > 0.01 {
                        self.volume = uiVol
                    }
                }
            case "cache-buffering-state":
                if let percent = value as? Int64 {
                    self.bufferProgress = min(1.0, max(0.0, Double(percent) / 100.0))
                } else if let percent = value as? Int {
                    self.bufferProgress = min(1.0, max(0.0, Double(percent) / 100.0))
                } else if let percent = value as? Double {
                    self.bufferProgress = min(1.0, max(0.0, percent / 100.0))
                }
            case "cache-speed":
                if let kbps = value as? Int64 {
                    // mpv reports bytes/sec over a 1s window → store KB/s.
                    self.recentCacheSpeedKBps = Double(kbps) / 1024.0
                }
            case "demuxer-cache-time":
                if let time = value as? Double {
                    self.demuxerCacheTime = time
                }
            case "demuxer-cache-duration":
                if let dur = value as? Double {
                    self.demuxerCacheDuration = max(0.0, dur)
                }
            case "video-params/gamma", "video-params/primaries":
                self.playerView?.playerView?.applyColorPipeline()
            default:
                break
            }
        }
    }

    /// Live media format inspection for "About Stream Source"
    func getMediaInfo() -> (videoCodec: String?, audioCodec: String?, resolution: String?, hwdec: String?, fileSize: String?, bufferDuration: Double?) {
        let backend = playerView?.playerView
        let vCodec = backend?.getPropertyString("video-codec") ?? backend?.getPropertyString("video-format")
        let aCodec = backend?.getPropertyString("audio-codec")
        let w = backend?.getPropertyInt("video-params/w")
        let h = backend?.getPropertyInt("video-params/h")
        let res = (w != nil && h != nil && w! > 0 && h! > 0) ? "\(w!)×\(h!)" : nil
        let hwdec = backend?.getPropertyString("hwdec-current")

        var formattedSize: String? = nil
        let fileFormat = backend?.getPropertyString("file-format")?.lowercased() ?? ""
        let isHlsOrDash = fileFormat.contains("hls") || fileFormat.contains("applehttp") || fileFormat.contains("dash")
        let rawBytes = backend?.getPropertyInt64("file-size") ?? backend?.getPropertyInt64("stream-end")
        let totalDuration = (self.duration > 0 ? self.duration : (backend?.getPropertyDouble("duration") ?? 0.0))

        // Legitimate non-manifest video file sizes (must be >= 5MB, or >= 500KB if duration is very short)
        let isPlausibleFileSize = !isHlsOrDash && (rawBytes != nil) && (
            (totalDuration > 60.0 && rawBytes! >= 5 * 1024 * 1024) ||
            (totalDuration <= 60.0 && rawBytes! >= 500 * 1024)
        )

        if isPlausibleFileSize, let bytes = rawBytes {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useGB, .useMB]
            formatter.countStyle = .file
            formattedSize = formatter.string(fromByteCount: bytes)
        } else {
            // HLS, DASH, or chunked stream where file-size is just the manifest/playlist text size (e.g. 4KB):
            // Calculate actual media size from active video+audio bitrate * duration
            let vBitrate = backend?.getPropertyDouble("video-bitrate") ?? 0.0
            let aBitrate = backend?.getPropertyDouble("audio-bitrate") ?? 0.0
            let totalBitrate = vBitrate + aBitrate
            if totalBitrate > 50_000, totalDuration > 0 {
                let estimatedBytes = Int64((totalBitrate / 8.0) * totalDuration)
                if estimatedBytes >= 5 * 1024 * 1024 {
                    let formatter = ByteCountFormatter()
                    formatter.allowedUnits = [.useGB, .useMB]
                    formatter.countStyle = .file
                    formattedSize = "~" + formatter.string(fromByteCount: estimatedBytes) + (isHlsOrDash ? " (HLS)" : "")
                }
            } else if isHlsOrDash {
                formattedSize = "Adaptive (HLS)"
            }
        }

        let dur: Double = {
            if self.demuxerCacheDuration > 0 {
                return self.demuxerCacheDuration
            }
            if self.demuxerCacheTime > self.timePos {
                return self.demuxerCacheTime - self.timePos
            }
            return 0.0
        }()

        return (vCodec, aCodec, res, hwdec, formattedSize, dur)
    }
    
    func fetchTracks() {
        guard let tracks = playerView?.getTracks() else { return }
        
        DispatchQueue.main.async {
            self.audioTracks = tracks.filter { $0.type == "audio" }
            self.subtitleTracks = tracks.filter { $0.type == "sub" }
            self.autoSelectPreferredTracks()
        }
    }

    func trackMatchesLanguage(track: Track, targetLang: String) -> Bool {
        Self.trackMatchesLanguage(track: track, targetLang: targetLang)
    }

    static func trackMatchesLanguage(track: Track, targetLang: String) -> Bool {
        let cleanTarget = targetLang.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let aliases: [String] = {
            switch cleanTarget {
            case "english", "en", "eng":
                return ["en", "eng", "english", "enus", "en-us"]
            case "spanish", "es", "spa":
                return ["es", "spa", "spanish", "español", "espanol"]
            case "french", "fr", "fra", "fre":
                return ["fr", "fra", "fre", "french", "français", "francais"]
            case "german", "de", "deu", "ger":
                return ["de", "deu", "ger", "german", "deutsch"]
            case "japanese", "ja", "jpn":
                return ["ja", "jpn", "japanese", "nihongo", "日本語"]
            case "korean", "ko", "kor":
                return ["ko", "kor", "korean", "hangul", "한국어"]
            case "hindi", "hi", "hin":
                return ["hi", "hin", "hindi", "हिन्दी"]
            case "tamil", "ta", "tam":
                return ["ta", "tam", "tamil", "தமிழ்"]
            case "telugu", "te", "tel":
                return ["te", "tel", "telugu", "తెలుగు"]
            case "italian", "it", "ita":
                return ["it", "ita", "italian", "italiano"]
            case "russian", "ru", "rus":
                return ["ru", "rus", "russian", "русский"]
            case "chinese", "zh", "chi", "zho":
                return ["zh", "chi", "zho", "chinese", "mandarin", "cantonese", "中文"]
            case "portuguese", "pt", "por":
                return ["pt", "por", "portuguese", "português", "portugues"]
            default:
                return [cleanTarget]
            }
        }()

        let trackLang = track.lang.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trackTitle = track.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trackDisplay = track.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // 1. Direct language code match on container metadata (e.g. "en", "ja", "ko")
        if !trackLang.isEmpty && trackLang != "und" && aliases.contains(trackLang) {
            return true
        }

        // 2. Title or display name match
        for alias in aliases {
            if alias.count <= 2 {
                // Short 2-char codes (en, ja, es, etc.) require word boundaries
                // so they do not falsely match words like "commentary", "adventure", "opening", etc.
                let pattern = #"(?i)(?:^|[\.\[\(\s/_\-,:])\#(alias)(?:$|[\.\]\)\s/_\-,:])"#
                if trackTitle.range(of: pattern, options: .regularExpression) != nil ||
                   trackDisplay.range(of: pattern, options: .regularExpression) != nil {
                    return true
                }
            } else {
                if trackTitle.contains(alias) || trackDisplay.contains(alias) {
                    return true
                }
            }
        }

        // 3. If target is English, detect dub tracks that aren't other foreign languages
        if cleanTarget.hasPrefix("eng") && (trackTitle.contains("dub") || trackDisplay.contains("dub")) {
            let foreignWords = ["spanish", "french", "german", "japanese", "korean", "hindi", "italian", "russian", "portuguese", "chinese"]
            if !foreignWords.contains(where: { trackTitle.contains($0) || trackDisplay.contains($0) }) {
                return true
            }
        }

        return false
    }

    /// Pure audio auto-selection decision (unit-tested in fluxTests).
    /// Original-language-first for foreign titles (Apple TV / Netflix
    /// behavior): a Hindi/Japanese/Korean title must open on its authentic
    /// dialogue track even when the container carries a track in the user's
    /// preferred language — directors' commentary is tagged `eng`, so a naive
    /// preferred-language match hijacked *3 Idiots* with English commentary.
    /// Commentary tracks never win while any dialogue track exists.
    /// Selects the optimal audio track according to user preferences:
    /// 1. If "Original Audio" is selected, authentic original dialogue wins.
    /// 2. Primary priority: User's explicitly preferred default audio language (dialogue only, commentary excluded).
    /// 3. Secondary priority: Any secondary preferred languages selected in stream settings (dialogue only).
    /// 4. Fallback: If no preferred language track is available in the container, gracefully defer
    ///    to container default dialogue, original dialogue, or MPV preference (never forced to wrong dub).
    static func preferredAudioTrack(
        from tracks: [Track],
        preferredLang: String,
        secondaryPreferredLangs: [String] = [],
        originalLanguage: String?
    ) -> Track? {
        guard !tracks.isEmpty else { return nil }

        func isCommentary(_ t: Track) -> Bool { t.title.lowercased().contains("commentary") }

        let original = (originalLanguage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let origMatches = !original.isEmpty
            ? tracks.filter { trackMatchesLanguage(track: $0, targetLang: original) }
            : []
        let origDialogue = origMatches.first(where: { !isCommentary($0) }) ?? origMatches.first

        // If the user explicitly selects "Original" or "Original Audio", authentic original dialogue wins
        if preferredLang.lowercased().contains("original") {
            return origDialogue
                ?? tracks.first(where: { $0.isDefault && !isCommentary($0) })
                ?? tracks.first(where: { !isCommentary($0) })
                ?? tracks.first(where: { $0.isDefault })
                ?? tracks.first
        }

        // 1. Primary priority: User's explicitly preferred default audio language (dialogue only)
        if let preferredDialogue = tracks.first(where: { trackMatchesLanguage(track: $0, targetLang: preferredLang) && !isCommentary($0) }) {
            return preferredDialogue
        }

        // 2. Secondary priority: Check any other preferred languages specified by the user (dialogue only)
        for secLang in secondaryPreferredLangs where secLang != preferredLang {
            if let secDialogue = tracks.first(where: { trackMatchesLanguage(track: $0, targetLang: secLang) && !isCommentary($0) }) {
                return secDialogue
            }
        }

        // 3. Fallback: Preferred audio is not available for this source.
        // User directive: "if the preferred default audio isn't available for the source, the player should ignore it and select whatever mpv prefers."
        // Defer to container default dialogue, original dialogue, or MPV first dialogue.
        return tracks.first(where: { $0.isDefault && !isCommentary($0) })
            ?? origDialogue
            ?? tracks.first(where: { !isCommentary($0) })
            ?? tracks.first(where: { $0.isDefault })
            ?? tracks.first
    }

    func autoSelectPreferredSubtitles(from externalSubs: [StremioSubtitleTrack]) {
        guard !hasAutoSelectedSubtitles else { return }
        let preferredSub = UserDefaults.standard.string(forKey: "defaultSubLang") ?? "English"
        let preferredAudio = UserDefaults.standard.string(forKey: "defaultAudioLang") ?? "English"

        let activeSub = subtitleTracks.first(where: { $0.isSelected })

        if preferredSub != "Off" && preferredSub != "None" {
            let isSubPreferred = activeSub.map { trackMatchesLanguage(track: $0, targetLang: preferredSub) } ?? false
            if !isSubPreferred {
                if let matchedSub = subtitleTracks.first(where: { trackMatchesLanguage(track: $0, targetLang: preferredSub) }) {
                    hasAutoSelectedSubtitles = true
                    print("[MPV] Auto-selecting embedded subtitle matching \(preferredSub): \(matchedSub.displayName) (id: \(matchedSub.id))")
                    playerView?.selectTrack(matchedSub)
                } else if let extSub = externalSubs.first(where: { sub in
                    let dummy = Track(id: 0, type: "sub", title: sub.displayName, lang: sub.language, isSelected: false)
                    return trackMatchesLanguage(track: dummy, targetLang: preferredSub)
                }) {
                    hasAutoSelectedSubtitles = true
                    print("[MPV] Auto-attaching external subtitle matching \(preferredSub): \(extSub.displayName) (\(extSub.source ?? "OpenSubtitles"))")
                    addExternalSubtitle(extSub)
                }
            } else {
                hasAutoSelectedSubtitles = true
            }
        } else {
            // User prefers Subtitles Off, but if foreign audio is detected, auto-enable subtitles in preferredAudio
            let effectiveAudio = audioTracks.first(where: { $0.isSelected })
            let isAudioPreferred = effectiveAudio.map { trackMatchesLanguage(track: $0, targetLang: preferredAudio) } ?? true
            if !isAudioPreferred {
                let isSubAudioActive = activeSub.map { trackMatchesLanguage(track: $0, targetLang: preferredAudio) } ?? false
                if !isSubAudioActive {
                    if let matchedSub = subtitleTracks.first(where: { trackMatchesLanguage(track: $0, targetLang: preferredAudio) }) {
                        hasAutoSelectedSubtitles = true
                        print("[MPV] Foreign audio detected — auto-selecting embedded subtitle: \(matchedSub.displayName)")
                        playerView?.selectTrack(matchedSub)
                    } else if let extSub = externalSubs.first(where: { sub in
                        let dummy = Track(id: 0, type: "sub", title: sub.displayName, lang: sub.language, isSelected: false)
                        return trackMatchesLanguage(track: dummy, targetLang: preferredAudio)
                    }) {
                        hasAutoSelectedSubtitles = true
                        print("[MPV] Foreign audio detected — auto-attaching external subtitle: \(extSub.displayName)")
                        addExternalSubtitle(extSub)
                    }
                } else {
                    hasAutoSelectedSubtitles = true
                }
            }
        }
    }

    private func autoSelectPreferredTracks() {
        guard !audioTracks.isEmpty else { return }

        if !hasAutoSelectedAudio {
            hasAutoSelectedAudio = true
            let preferredAudio = UserDefaults.standard.string(forKey: "defaultAudioLang") ?? "English"
            let preferredLanguages = UserDefaults.standard.stringArray(forKey: UserDefaults.Key.preferredStreamLanguages) ?? [preferredAudio]
            let activeAudio = audioTracks.first(where: { $0.isSelected })
            let currentOriginalLanguage = PlayerManager.shared.currentItem?.effectiveOriginalLanguage ?? PlayerManager.shared.currentItem?.originalLanguage
            if let pick = Self.preferredAudioTrack(
                from: audioTracks,
                preferredLang: preferredAudio,
                secondaryPreferredLangs: preferredLanguages,
                originalLanguage: currentOriginalLanguage
            ) {
                if activeAudio?.id != pick.id {
                    print("[MPV] Auto-selecting audio track: \(pick.displayName) (id: \(pick.id)) preferred=\(preferredAudio) original=\(currentOriginalLanguage ?? "nil")")
                    playerView?.selectTrack(pick)
                }
            }
        }

        autoSelectPreferredSubtitles(from: PlayerManager.shared.externalSubtitles)
    }
    
    func fetchChapters() {
        guard let list = playerView?.getChapters() else { return }
        DispatchQueue.main.async {
            self.chapters = list
        }
    }
    
    func selectTrack(_ track: Track) {
        playerView?.selectTrack(track)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.fetchTracks()
        }
    }
    
    func addExternalSubtitle(_ subtitle: StremioSubtitleTrack) {
        let title = subtitle.displayName
        let lang = subtitle.language
        let remoteURL = subtitle.url

        Task {
            var targetPath = remoteURL.absoluteString
            do {
                var request = URLRequest(url: remoteURL)
                request.timeoutInterval = 8
                request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), !data.isEmpty {
                    let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("FluxSubtitles", isDirectory: true)
                    try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                    let safeID = subtitle.id.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "_")
                    let localFileURL = cacheDir.appendingPathComponent("\(safeID).srt")
                    try data.write(to: localFileURL)
                    targetPath = localFileURL.path
                }
            } catch {
                print("[MPV] External subtitle download failed (\(error.localizedDescription)), passing remote URL to mpv")
            }

            await MainActor.run {
                self.playerView?.addExternalSubtitle(url: targetPath, title: title, lang: lang)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.fetchTracks()
                }
            }
        }
    }
}

// MARK: - View Controller
class MPVViewController: NSViewController {
    var playerView: MPVLayerView!
    weak var delegate: MPVController?
    
    override func loadView() {
        self.view = NSView(frame: .init(x: 0, y: 0, width: 1280, height: 720))
        self.playerView = MPVLayerView(frame: self.view.bounds)
        self.playerView.autoresizingMask = [.width, .height]
        self.view.addSubview(playerView)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.playerView.setupContext()
        self.playerView.setupMpv()
        
        self.playerView.onCoreDestroyed = { [weak self] in
            self?.delegate?.handleCoreDestroyed()
        }
        
        self.playerView.onPropertyChange = { [weak self] name, value in
            self?.delegate?.handlePropertyChange(name: name, value: value)
        }
        
        self.playerView.onPlaybackError = { [weak self] in
              guard let self = self, self.delegate?.hasLoadedMedia == true else { return }
              print("[MPV] Playback error detected")
              DispatchQueue.main.async {
                  self.delegate?.onPlaybackError?()
              }
        }

        self.playerView.onEndOfFile = { [weak self] in
              DispatchQueue.main.async {
                  self?.delegate?.registerEndOfFile()
              }
        }

        self.playerView.onFileLoaded = { [weak self] in
              DispatchQueue.main.async {
                  self?.delegate?.fetchTracks()
                  self?.delegate?.fetchChapters()
              }
        }
        
        let vol = self.playerView.getVolume()
        DispatchQueue.main.async {
            self.delegate?.volume = vol
        }
    }
    
    func play(_ url: URL, paused: Bool = false) { 
        loadViewIfNeeded()
        playerView?.loadFile(url, paused: paused) 
    }
    func pause() { 
        loadViewIfNeeded()
        playerView?.setPause(true) 
    }
    func resume() { 
        loadViewIfNeeded()
        playerView?.setPause(false) 
    }
    func setMute(_ muted: Bool) { 
        loadViewIfNeeded()
        playerView?.setMute(muted) 
    }
    func stop() { 
        loadViewIfNeeded()
        playerView?.stop() 
    }
    
    func seek(absolute seconds: Double) { 
        loadViewIfNeeded()
        playerView?.seek(absoluteSeconds: seconds) 
    }
    func seek(relative seconds: Double) { 
        loadViewIfNeeded()
        playerView?.seek(relativeSeconds: seconds) 
    }
    
    func setVolume(_ value: Double) { 
        loadViewIfNeeded()
        playerView?.setVolume(value) 
    }
    func getTracks() -> [Track] { 
        loadViewIfNeeded()
        return playerView?.getTracks() ?? [] 
    }
    func getChapters() -> [MediaChapter] { 
        loadViewIfNeeded()
        return playerView?.getChapters() ?? [] 
    }
    func selectTrack(_ track: Track) { 
        loadViewIfNeeded()
        playerView?.selectTrack(track) 
    }
    func addExternalSubtitle(url: String, title: String, lang: String? = nil) { 
        loadViewIfNeeded()
        playerView?.addExternalSubtitle(url: url, title: title, lang: lang) 
    }

    func setSubtitleDelay(_ delay: Double) { 
        loadViewIfNeeded()
        playerView?.setSubtitleDelay(delay) 
    }
    func setSubtitleScale(_ scale: Double) { 
        loadViewIfNeeded()
        playerView?.setSubtitleScale(scale) 
    }
    func setSubtitlePos(_ pos: Double) { 
        loadViewIfNeeded()
        playerView?.setSubtitlePos(pos) 
    }
    func setAudioDelay(_ delay: Double) { 
        loadViewIfNeeded()
        playerView?.setAudioDelay(delay) 
    }
    func setDialogueBoost(_ enabled: Bool) { 
        loadViewIfNeeded()
        playerView?.setDialogueBoost(enabled) 
    }
    func setVideoAspect(_ aspect: String) { 
        loadViewIfNeeded()
        playerView?.setVideoAspect(aspect) 
    }
    func setDeband(_ enabled: Bool) { 
        loadViewIfNeeded()
        playerView?.setDeband(enabled) 
    }
    func setContrast(_ value: Double) { 
        loadViewIfNeeded()
        playerView?.setContrast(value) 
    }
    func setBrightness(_ value: Double) { 
        loadViewIfNeeded()
        playerView?.setBrightness(value) 
    }
    func setSaturation(_ value: Double) { 
        loadViewIfNeeded()
        playerView?.setSaturation(value) 
    }

    /// Pixel aspect of the loaded video (for PiP window sizing). Falls back to 16:9.
    var videoAspectRatio: Double { playerView?.videoAspectRatio ?? 16.0 / 9.0 }
}

// MARK: - Replay diagnostics: unbuffered file log (print() is line-buffered
// on a TTY but BLOCK-buffered when stdout is redirected, which silently ate
// earlier capture attempts). Every render-lifecycle event lands in
// /tmp/flux_render_diag.log with timestamps and CGL context identities.
import os.signpost
let fluxDiagLock = NSLock()
func fluxDiag(_ message: String) {
    let line = "[\(Date().timeIntervalSince1970)] \(message)\n"
    fluxDiagLock.lock()
    if let fh = FileHandle(forWritingAtPath: "/tmp/flux_render_diag.log") {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        try? line.write(to: URL(fileURLWithPath: "/tmp/flux_render_diag.log"), atomically: true, encoding: .utf8)
    }
    fluxDiagLock.unlock()
}
func ptrId(_ p: UnsafeMutableRawPointer?) -> String {
    guard let p = p else { return "nil" }
    return String(UInt(bitPattern: p), radix: 16)
}
func ptrId(_ p: CGLContextObj?) -> String {
    guard let p = p else { return "nil" }
    return String(UInt(bitPattern: p), radix: 16)
}

// MARK: - OpenGL View & MPV Backend
// MARK: - CAOpenGLLayer Subclass for Zero Main-Thread Hop Rendering
/// Pure color-pipeline decision logic (unit-tested in fluxTests).
/// EDR routing keys on `maximumPotentialExtendedDynamicRangeColorComponentValue`:
/// `currentEDR` only lifts above 1.0 WHILE HDR content is on screen, so gating
/// the float16 framebuffer on it arrived too late — first HDR frames landed in
/// an 8-bit SDR framebuffer (washed out). Potential-EDR > 1.0 means the panel
/// CAN do EDR and the float16 pipeline must be created up front.
enum MPVColorPipelinePolicy {
    static func supportsEDR(maximumPotentialEDR: Double) -> Bool {
        maximumPotentialEDR > 1.0
    }

    static func targetPrimaries(for sourcePrimaries: String) -> String? {
        switch sourcePrimaries {
        case "bt.2020": return "bt.2020"
        case "display-p3", "dci-p3": return "display-p3"
        default: return nil
        }
    }

    static func targetTransferFunction(for sourceGamma: String) -> String? {
        sourceGamma == "pq" || sourceGamma == "hlg" ? "pq" : nil
    }

    static func usesEDR(gamma: String, primaries: String, maximumPotentialEDR: Double) -> Bool {
        targetTransferFunction(for: gamma) != nil
            && targetPrimaries(for: primaries) != nil
            && supportsEDR(maximumPotentialEDR: maximumPotentialEDR)
    }

    struct PipelineConfig: Equatable {
        let targetTrc: String
        let targetPrim: String
        let targetPeak: String
        let toneMapping: String
        let hdrComputePeak: String
        let videoOutputLevels: String
        let usesDisplayICCProfile: Bool
        let wantsEDR: Bool
        let contentsFormat: CALayerContentsFormat
        let colorSpaceName: CFString
    }

    static func resolvePipeline(
        gamma: String,
        primaries: String,
        potentialEDR: Double,
        currentEDR: Double = 1.0
    ) -> PipelineConfig {
        let isHDR = gamma == "pq" || gamma == "hlg"
        let canDoEDR = usesEDR(gamma: gamma, primaries: primaries, maximumPotentialEDR: potentialEDR)
        let outputPrimaries = targetPrimaries(for: primaries)
        let outputTRC = targetTransferFunction(for: gamma)
        let isP3 = outputPrimaries == "display-p3"

        if canDoEDR {
            let headroom = max(1.0, currentEDR > 1.0 ? currentEDR : potentialEDR)
            let peak = max(200, min(1600, Int(headroom * 250)))
            let csName: CFString = isP3 ? CGColorSpace.displayP3_PQ : CGColorSpace.itur_2100_PQ

            return PipelineConfig(
                targetTrc: outputTRC ?? "pq",
                targetPrim: outputPrimaries ?? "bt.2020",
                targetPeak: String(peak),
                toneMapping: "auto",
                hdrComputePeak: "auto",
                videoOutputLevels: "auto",
                usesDisplayICCProfile: false,
                wantsEDR: true,
                contentsFormat: .RGBA16Float,
                colorSpaceName: csName
            )
        } else if isHDR {
            // HDR content on a non-EDR panel: mpv tone-maps with its automatic
            // defaults; the display ICC profile supplies the compositor-side
            // correction so mpv and CA never double-manage color.
            return PipelineConfig(
                targetTrc: "auto",
                targetPrim: "auto",
                targetPeak: "auto",
                toneMapping: "auto",
                hdrComputePeak: "auto",
                videoOutputLevels: "auto",
                usesDisplayICCProfile: true,
                wantsEDR: false,
                contentsFormat: .RGBA8Uint,
                colorSpaceName: CGColorSpace.sRGB
            )
        } else {
            // SDR on SDR: leave all mpv color decisions automatic and correct
            // only via the display ICC profile — overriding target-trc/prim here
            // double-managed color against the compositor (washed out blacks).
            return PipelineConfig(
                targetTrc: "auto",
                targetPrim: "auto",
                targetPeak: "auto",
                toneMapping: "auto",
                hdrComputePeak: "auto",
                videoOutputLevels: "auto",
                usesDisplayICCProfile: true,
                wantsEDR: false,
                contentsFormat: .RGBA8Uint,
                colorSpaceName: CGColorSpace.sRGB
            )
        }
    }
}

/// OpenGL layer for MPVLayerView — structured to mirror IINA's ViewLayer
/// (iina/iina, develop branch), the most battle-tested CAOpenGLLayer+libmpv
/// implementation on macOS. Non-negotiable invariants taken from IINA + the
/// mpv render.h contract:
///   1. ONE CGL pixel format and ONE CGL context are created in init and
///      returned verbatim from copyCGLPixelFormat/copyCGLContext forever —
///      including in shadow copies (init(layer:), which CA creates on
///      contentsScale changes). render.h: every mpv_render_* call must use
///      "the same OpenGL context as the mpv_render_context was created with;
///      otherwise undefined behavior will occur."
///   2. All mpv_render_* calls are serialized through the owner view's
///      recursive displayLock (render.h: only one at a time per context).
///   3. draw() renders into the ACTUAL GL viewport/draw-FBO that CA reports,
///      not a bounds×scale recomputation.
final class MPVLayer: CAOpenGLLayer {
    weak var ownerView: MPVLayerView?
    fileprivate let cglPixelFormat: CGLPixelFormatObj
    fileprivate let cglContext: CGLContextObj
    /// IINA parity: rendering is DRIVEN, not polled. With isAsynchronous = true,
    /// CA autonomously polls canDraw — and that polling silently stops after a
    /// SwiftUI attach/detach/re-attach during window swap (log-verified: the
    /// replay session's layer was never polled again → no draw → no render
    /// context → black video + Software decode forever). Instead, mpv's
    /// render-update callback drives update() → display() on this queue,
    /// exactly like IINA's mpvGLQueue.
    fileprivate let mpvGLQueue = DispatchQueue(label: "flux.mpvgl.render", qos: .userInteractive)
    
    override init() {
        cglPixelFormat = MPVLayer.createPixelFormat()
        cglContext = MPVLayer.createContext(cglPixelFormat)
        super.init()
        self.isAsynchronous = false
        fluxDiag("LAYER INIT \(ObjectIdentifier(self).hashValue), pinned ctx \(ptrId(cglContext)), async=false (driven)")
        self.contentsFormat = .RGBA8Uint
        self.needsDisplayOnBoundsChange = true
        self.backgroundColor = NSColor.black.cgColor
    }
    
    /// CA shadow-copy initializer (fired on contentsScale changes / layer
    /// copying). IINA's comment: this is exactly where a naive CAOpenGLLayer
    /// subclass silently loses its context — the copy MUST carry the same
    /// pixel format and context, or mpv ends up rendering into an orphan.
    override init(layer: Any) {
        let previous = layer as! MPVLayer
        cglPixelFormat = previous.cglPixelFormat
        cglContext = previous.cglContext
        super.init(layer: layer)
        self.isAsynchronous = false
        self.contentsFormat = previous.contentsFormat
        self.wantsExtendedDynamicRangeContent = previous.wantsExtendedDynamicRangeContent
        self.ownerView = previous.ownerView
        fluxDiag("LAYER SHADOW COPY \(ObjectIdentifier(previous).hashValue) -> \(ObjectIdentifier(self).hashValue), carrying ctx \(ptrId(cglContext))")
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }
    
    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        cglPixelFormat
    }
    
    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        cglContext
    }
    
    // MARK: - IINA-parity driven rendering
    
    /// Called by mpv's render-update callback (and on attachment changes).
    /// Schedules display() on the render queue. IINA `update(force:)` parity.
    func requestRender() {
        mpvGLQueue.async { [weak self] in
            guard let self = self, !self.isCleaningUpLayer else { return }
            self.display()
        }
    }
    
    /// Non-atomic flag mirrored from the view's cleanup state (set before the
    /// queue captures self, read on the queue).
    fileprivate var isCleaningUpLayer = false
    
    /// IINA `display()` override parity: explicit CATransaction so the implicit
    /// transaction CA would create on a non-main thread is properly flushed.
    /// Without this, off-main-thread display() transactions silently never hit
    /// the compositor.
    override func display() {
        fluxDiag("DISPLAY override entered (layer \(ObjectIdentifier(self).hashValue))")
        if Thread.isMainThread {
            super.display()
        } else {
            CATransaction.begin()
            super.display()
            CATransaction.commit()
        }
        CATransaction.flush()
    }
    
    // MARK: - Core OpenGL Context and Pixel Format (IINA parity)
    
    /// Display-agnostic pixel format with graceful attribute fallback, mirroring
    /// IINA's findPixelFormat: try the richest attribute set first (float16
    /// framebuffer on EDR-capable panels), then progressively simpler ones, and
    /// finally a legacy-profile variant for picky drivers. Never force-unwraps.
    fileprivate static func createPixelFormat() -> CGLPixelFormatObj {
        let useFloat16 = MPVColorPipelinePolicy.supportsEDR(
            maximumPotentialEDR: Double(NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0)
        )
        
        func attributes(profile: CGLOpenGLProfile, float16: Bool) -> [CGLPixelFormatAttribute] {
            var attrs: [CGLPixelFormatAttribute] = [
                kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(profile.rawValue)),
                kCGLPFAAccelerated,
                kCGLPFADoubleBuffer,
                kCGLPFAAllowOfflineRenderers
            ]
            if float16 {
                attrs += [kCGLPFAColorFloat, kCGLPFAColorSize, CGLPixelFormatAttribute(64)]
            } else {
                attrs += [kCGLPFAColorSize, CGLPixelFormatAttribute(32)]
            }
            attrs += [kCGLPFADepthSize, CGLPixelFormatAttribute(24), CGLPixelFormatAttribute(0)]
            return attrs
        }
        
        var attempts: [[CGLPixelFormatAttribute]] = []
        if useFloat16 {
            attempts.append(attributes(profile: kCGLOGLPVersion_3_2_Core, float16: true))
        }
        attempts.append(attributes(profile: kCGLOGLPVersion_3_2_Core, float16: false))
        attempts.append(attributes(profile: kCGLOGLPVersion_Legacy, float16: false))
        
        for attrs in attempts {
            var pix: CGLPixelFormatObj?
            var npix: GLint = 0
            if CGLChoosePixelFormat(attrs, &pix, &npix) == kCGLNoError, let chosen = pix {
                return chosen
            }
        }
        
        // Last resort: bare minimum accelerated format.
        var pix: CGLPixelFormatObj?
        var npix: GLint = 0
        let minimal: [CGLPixelFormatAttribute] = [
            kCGLPFAAccelerated,
            kCGLPFADoubleBuffer,
            CGLPixelFormatAttribute(0)
        ]
        CGLChoosePixelFormat(minimal, &pix, &npix)
        if let chosen = pix { return chosen }
        fatalError("MPVLayer: cannot create any CGL pixel format")
    }
    
    fileprivate static func createContext(_ pixelFormat: CGLPixelFormatObj) -> CGLContextObj {
        var ctx: CGLContextObj?
        CGLCreateContext(pixelFormat, nil, &ctx)
        guard let context = ctx else {
            fatalError("MPVLayer: cannot create CGL context")
        }
        // IINA parity: sync to vertical retrace + enable multi-threaded GL engine.
        var swap: GLint = 1
        CGLSetParameter(context, kCGLCPSwapInterval, &swap)
        CGLEnable(context, kCGLCEMPEngine)
        return context
    }
    
    private var didLogFirstCanDraw = false
    private var didLogFirstCanDrawTrue = false
    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat: CGLPixelFormatObj, forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        guard let owner = ownerView else {
            if !didLogFirstCanDraw {
                didLogFirstCanDraw = true
                fluxDiag("CANDRAW polled: ownerView NIL (layer \(ObjectIdentifier(self).hashValue))")
            }
            return false
        }
        if !didLogFirstCanDraw {
            didLogFirstCanDraw = true
            fluxDiag("CANDRAW first poll: view \(ObjectIdentifier(owner).hashValue), cleaningUp \(owner.isCleaningUp), mpv \(owner.mpv != nil)")
        }
        if owner.isCleaningUp { return false }
        let alive = owner.mpv != nil
        if alive && !didLogFirstCanDrawTrue {
            didLogFirstCanDrawTrue = true
            fluxDiag("CANDRAW first TRUE — draw should follow (view \(ObjectIdentifier(owner).hashValue), ctx \(ptrId(ctx)))")
        }
        return alive
    }
    
    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj, forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        if ownerView?.didLogFirstDraw != true {
            ownerView?.didLogFirstDraw = true
            fluxDiag("DRAW first draw on layer \(ObjectIdentifier(self).hashValue), ctx \(ptrId(ctx)), ownerView \(ownerView.map { ObjectIdentifier($0).hashValue } ?? 0)")
        }
        guard let owner = ownerView, !owner.isCleaningUp, owner.mpv != nil else {
            if ownerView?.didLogFirstDraw == true, ownerView?.mpv == nil {
                fluxDiag("DRAW skipped: owner.mpv nil (ctx \(ptrId(ctx)))")
            }
            return
        }
        CGLSetCurrentContext(ctx)
        CGLLockContext(ctx)
        defer { CGLUnlockContext(ctx) }
        
        // IINA parity: clear first so a skipped render shows clean black.
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        
        // Render into the framebuffer/viewport CA actually gave us (IINA reads
        // these instead of recomputing bounds × contentsScale).
        var drawFBO: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &drawFBO)
        var dims: [GLint] = [0, 0, 0, 0]
        glGetIntegerv(GLenum(GL_VIEWPORT), &dims)
        
        // Serialize every mpv_render_* call (render.h contract; teardown on the
        // main thread also takes this lock before freeing the context).
        owner.displayLock.lock()
        defer { owner.displayLock.unlock() }
        
        if !owner.didEverDraw {
            owner.didEverDraw = true
            fluxDiag("PIPELINE BOOTSTRAP COMPLETE — first successful draw committed (view \(ObjectIdentifier(owner).hashValue))")
        }
        
        guard !owner.isCleaningUp, owner.mpv != nil else {
            return
        }
        
        if owner.mpvGL == nil {
            owner.setupMPVGL(with: ctx)
        } else if owner.mpvGLCreationContext != ctx {
            // Belt-and-braces: with the IINA-parity fixed context above this
            // should never fire, but if CA ever hands us a different context
            // the render context must be rebuilt against it — rendering into a
            // stale context is the black-video/software-decode failure mode.
            fluxDiag("DRAW context MISMATCH detected: mpvGL bound to \(ptrId(owner.mpvGLCreationContext)) but drawing into \(ptrId(ctx)) — rebuilding")
            owner.rebuildRenderContext(for: ctx)
        }
        
        guard let mpvGL = owner.mpvGL else {
            return
        }
        
        // Apply any pending display ICC profile on the CA render thread, inside
        // the render context's own GL context (mpv requirement).
        owner.applyPendingICCProfile(to: mpvGL)
        
        // Update render context on OpenGL thread with active context
        _ = mpv_render_context_update(mpvGL)
        
        guard dims[2] > 0 && dims[3] > 0 else {
            glFlush()
            return
        }
        
        var flipY: Int32 = 1
        // Dynamic depth for dithering:
        // When actively rendering HDR content in EDR mode, report 16-bit float depth.
        // When rendering SDR content (or on an SDR screen), report 8-bit depth so mpv's
        // active fruit / Floyd-Steinberg dithering runs, eliminating banding on 8-bit panels.
        var depth: Int32 = self.wantsExtendedDynamicRangeContent ? 16 : 8
        var fbo = mpv_opengl_fbo(fbo: drawFBO != 0 ? drawFBO : 1, w: dims[2], h: dims[3], internal_format: 0)
        
        withUnsafeMutablePointer(to: &fbo) { fboPtr in
            withUnsafeMutablePointer(to: &flipY) { flipPtr in
                withUnsafeMutablePointer(to: &depth) { depthPtr in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fboPtr),
                        mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipPtr),
                        mpv_render_param(type: MPV_RENDER_PARAM_DEPTH, data: depthPtr),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                    ]
                    let result = mpv_render_context_render(mpvGL, &params)
                    if result >= 0 {
                        mpv_render_context_report_swap(mpvGL)
                    }
                }
            }
        }
        
        glFlush()
    }
}

// MARK: - Hosting NSView Backed by CAOpenGLLayer
final class MPVLayerView: NSView {
    private(set) var mpv: OpaquePointer!
    var mpvGL: OpaquePointer!
    private var displayLink: CVDisplayLink?
    let mpvLayer = MPVLayer()
    
    var queue = DispatchQueue(label: "mpv", qos: .userInteractive)
    var onPropertyChange: ((String, Any) -> Void)?
    var onPlaybackError: (() -> Void)?
    /// Fired exactly once when the file ends naturally (EOF). File switches
    /// emit STOP/REDIRECT reasons instead, so autoplay must only listen here.
    var onEndOfFile: (() -> Void)?
    var onFileLoaded: (() -> Void)?
    var onCoreDestroyed: (() -> Void)?
    private var isEventLoopRunning = false
    private let eventLoopLock = NSLock()
    /// Last forwarded mpv log line (consecutive-dedupe key for diagnostics).
    private var lastForwardedMPVLog = ""
    private(set) var isCleaningUp = false
    private var lastTimePosDispatchTime: Double = 0
    private var lastTelemetryLogTime: Double = 0
    /// Token into MPVCallbackRegistry so mpv's C callbacks never hold a raw,
    /// unretained pointer to this view (use-after-free on teardown).
    fileprivate var callbackToken: UInt64 = 0
    private var currentScreenNumber: UInt32?
    private var lastBackingScale: CGFloat = 2.0
    private var isRenderUpdateScheduled = false
    private let renderUpdateLock = NSLock()
    private var reconnectTimestamps: [CFAbsoluteTime] = []
    private let reconnectLock = NSLock()
    /// One-shot first-draw diagnostic flag.
    var didLogFirstDraw = false
    /// Set once the first successful draw(inCGLContext:) completes — stops the
    /// attachment bootstrap ladder and lets mpv callbacks own rendering.
    var didEverDraw = false
    /// IINA parity: every mpv_render_* call (draw on the CA render thread,
    /// render-context free during teardown) is serialized through this
    /// recursive lock. render.h: only one mpv_render_* call at a time per
    /// context. Recursive because CA can re-enter display() during draw.
    let displayLock = NSRecursiveLock()
    /// Display ICC profile forwarding (see applyPendingICCProfile): written by
    /// applyColorPipeline on the main thread, consumed by draw() on the CA
    /// render thread once the mpv render context exists.
    private let iccProfileLock = NSLock()
    private var pendingICCProfileData: Data?
    private var iccProfileGeneration: UInt64 = 0
    private var attemptedICCProfileGeneration: UInt64 = 0
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        mpvLayer.ownerView = self
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    
    override func makeBackingLayer() -> CALayer {
        fluxDiag("BACKING LAYER requested for view \(ObjectIdentifier(self).hashValue) — returning mpvLayer \(ObjectIdentifier(mpvLayer).hashValue), ownerView wired: \(mpvLayer.ownerView != nil)")
        return mpvLayer
    }
    
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2.0
        if lastBackingScale != scale {
            lastBackingScale = scale
            mpvLayer.contentsScale = scale
        }
        
        let screen = window?.screen ?? NSScreen.main
        let screenNum = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        if currentScreenNumber != screenNum {
            currentScreenNumber = screenNum
            lastPipelineKey = ""
            applyColorPipeline()
        }
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let attachDesc: String
        if let w = window {
            attachDesc = "ATTACHED window \(w.identifier?.rawValue ?? "unnamed")"
        } else {
            attachDesc = "DETACHED"
        }
        fluxDiag("VIEW didMoveToWindow \(attachDesc), view \(ObjectIdentifier(self).hashValue)")
        // IINA parity: on every attachment, render the current frame NOW from
        // the render queue. The immediate kick can be eaten while the previous
        // player window is still mid-teardown (log-verified), so schedule a
        // bounded recovery ladder: once ANY draw succeeds, the render context
        // exists and mpv's update callbacks drive frames forever after.
        if window != nil {
            mpvLayer.requestRender()
            for delay in [0.1, 0.3, 0.8, 1.5, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self, self.window != nil, !self.isCleaningUp else { return }
                    if !self.didEverDraw {
                        fluxDiag("BOOTSTRAP kick at +\(delay)s (view \(ObjectIdentifier(self).hashValue))")
                        self.mpvLayer.requestRender()
                    }
                }
            }
        }
        let scale = window?.backingScaleFactor ?? 2.0
        lastBackingScale = scale
        mpvLayer.contentsScale = scale
        
        let screen = window?.screen ?? NSScreen.main
        let screenNum = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        if currentScreenNumber != screenNum {
            currentScreenNumber = screenNum
            lastPipelineKey = ""
            applyColorPipeline()
        }
        mpvLayer.setNeedsDisplay()
    }
    
    func setupDisplayLink() {
        // Display link setup if needed
    }

    // MARK: HDR / EDR pipeline (ported from Cascade)
    private var lastPipelineKey: String = ""

    /// Pixel aspect ratio of the currently loaded video (1.78 for 16:9).
    var videoAspectRatio: Double {
        guard let w = getPropertyDouble("width"),
              let h = getPropertyDouble("height"),
              w > 0, h > 0 else { return 16.0 / 9.0 }
        return w / h
    }

    /// Detects HDR (PQ/HLG) content and routes mpv + the CAOpenGLLayer through
    /// an extended-dynamic-range output path, exactly like Cascade's player.
    func applyColorPipeline() {
        guard let mpv = mpv else { return }

        let gamma = getPropertyString("video-params/gamma") ?? ""
        let primaries = getPropertyString("video-params/primaries") ?? ""
        let isHDR = gamma == "pq" || gamma == "hlg"

        let screen = window?.screen ?? NSScreen.main
        let potentialEDR = screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
        let currentEDR = screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
        let config = MPVColorPipelinePolicy.resolvePipeline(
            gamma: gamma,
            primaries: primaries,
            potentialEDR: Double(potentialEDR),
            currentEDR: Double(currentEDR)
        )

        let screenNumber = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let key = "\(gamma)|\(primaries)|\(screenNumber)|\(config.wantsEDR)|\(config.targetPeak)|\(config.targetTrc)|\(config.toneMapping)"
        guard key != lastPipelineKey else { return }
        lastPipelineKey = key

        let displayProfile = config.usesDisplayICCProfile ? displayICCProfile(for: screen) : nil
        let iccProfileAuto = mpv_set_property_string(mpv, "icc-profile-auto", displayProfile == nil ? "no" : "yes")
        _ = mpv_set_property_string(mpv, "icc-profile", "")
        if iccProfileAuto < 0 {
            print("[MPV] Failed to configure display ICC profile (error \(iccProfileAuto))")
        }
        setICCProfileForRendering(displayProfile?.data)

        _ = mpv_set_property_string(mpv, "video-output-levels", config.videoOutputLevels)
        _ = mpv_set_property_string(mpv, "target-trc", config.targetTrc)
        _ = mpv_set_property_string(mpv, "target-prim", config.targetPrim)
        _ = mpv_set_property_string(mpv, "target-peak", config.targetPeak)
        _ = mpv_set_property_string(mpv, "tone-mapping", config.toneMapping)
        _ = mpv_set_property_string(mpv, "hdr-compute-peak", config.hdrComputePeak)

        if config.wantsEDR {
            print("[MPV] HDR EDR pipeline active (gamma=\(gamma), prim=\(config.targetPrim), peak=\(config.targetPeak)nits)")
        } else if isHDR {
            print("[MPV] HDR tone-mapping to SDR active (gamma=\(gamma), prim=\(config.targetPrim), algo=\(config.toneMapping))")
        } else {
            print("[MPV] SDR color pipeline active (trc=\(config.targetTrc), levels=\(config.videoOutputLevels))")
        }

        let layerColorSpace: CGColorSpace?
        if config.wantsEDR {
            layerColorSpace = CGColorSpace(name: config.colorSpaceName)
        } else if let displayProfile {
            layerColorSpace = displayProfile.colorSpace
        } else {
            layerColorSpace = CGColorSpace(name: config.colorSpaceName)
        }
        DispatchQueue.main.async { [mpvLayer] in
            mpvLayer.wantsExtendedDynamicRangeContent = config.wantsEDR
            mpvLayer.contentsFormat = config.contentsFormat
            mpvLayer.colorspace = layerColorSpace
            mpvLayer.setNeedsDisplay()
        }
    }

    private func displayICCProfile(for screen: NSScreen?) -> (data: Data, colorSpace: CGColorSpace)? {
        guard let displayColorSpace = screen?.colorSpace?.cgColorSpace,
              let profileData = displayColorSpace.copyICCData() as Data?,
              !profileData.isEmpty else {
            return nil
        }

        return (profileData, displayColorSpace)
    }

    private func setICCProfileForRendering(_ profileData: Data?) {
        iccProfileLock.lock()
        if pendingICCProfileData != profileData {
            pendingICCProfileData = profileData
            iccProfileGeneration &+= 1
        }
        iccProfileLock.unlock()
    }

    /// Applies the pending display ICC profile to the mpv render context.
    /// Runs on the CA render thread inside draw() with that thread's context —
    /// mpv_render_context_set_parameter requires the render context's GL context.
    fileprivate func applyPendingICCProfile(to renderContext: OpaquePointer) {
        iccProfileLock.lock()
        let generation = iccProfileGeneration
        guard generation != attemptedICCProfileGeneration else {
            iccProfileLock.unlock()
            return
        }
        let profileData = pendingICCProfileData
        iccProfileLock.unlock()

        let result: Int32
        if let profileData, !profileData.isEmpty {
            result = profileData.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return -1 }
                var byteArray = mpv_byte_array(
                    data: UnsafeMutableRawPointer(mutating: baseAddress),
                    size: buffer.count
                )
                let parameter = mpv_render_param(type: MPV_RENDER_PARAM_ICC_PROFILE, data: &byteArray)
                return mpv_render_context_set_parameter(renderContext, parameter)
            }
        } else {
            result = 0
        }

        iccProfileLock.lock()
        attemptedICCProfileGeneration = max(attemptedICCProfileGeneration, generation)
        iccProfileLock.unlock()

        if result < 0 {
            print("[MPV] Failed to apply display ICC profile to render context (error \(result))")
        }
    }
    
    func mpvRenderUpdate() {
        // IINA parity: drive the layer directly from mpv's update callback.
        // The old path (main-async → setNeedsDisplay → wait for CA's async poll)
        // depends on CA's polling state surviving the attach/detach dance —
        // which the replay log proved it does not. display() on the render
        // queue renders a frame NOW, no CA cooperation required.
        mpvLayer.requestRender()
    }
    
    private func displayLinkFired() {
        // Handled via mpvGLUpdate callback
    }
    
    func teardown() {
        guard !isCleaningUp else { return }
        isCleaningUp = true
        isIntentionallySwitchingFile = true
        fluxDiag("TEARDOWN view \(ObjectIdentifier(self).hashValue), mpvGL ctx was \(ptrId(mpvGLCreationContext))")
        
        onCoreDestroyed?()
        
        // Invalidate the callback token first so any in-flight or future mpv
        // callback resolves to nil and no-ops instead of touching a dying view.
        if callbackToken != 0 {
            MPVCallbackRegistry.unregister(callbackToken)
            callbackToken = 0
        }
        
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }
        
        // Signal the render queue to stop scheduling work for this dying view
        // BEFORE freeing the render context (queue closure checks this flag).
        mpvLayer.isCleaningUpLayer = true
        
        renderUpdateLock.lock()
        let handle = self.mpv
        self.mpv = nil
        renderUpdateLock.unlock()
        
        // IINA parity: serialize with draw() — the CA render thread may be
        // inside draw()/mpv_render_* right now; this lock makes it finish
        // before the render context is freed under its feet.
        displayLock.lock()
        defer { displayLock.unlock() }
        
        if let glCtx = self.mpvGL {
            mpv_render_context_set_update_callback(glCtx, { _ in }, nil)
            mpv_render_context_free(glCtx)
            self.mpvGL = nil
        }
        mpvGLCreationContext = nil
        if let handle = handle {
            mpv_set_wakeup_callback(handle, nil, nil)
            DispatchQueue.global(qos: .utility).async {
                mpv_terminate_destroy(handle)
            }
        }
    }
    
    func cleanup() {
        teardown()
    }
    
    deinit { cleanup() }
    
    func setupContext() {
        // Context created natively by CAOpenGLLayer
    }
    
    func setupMpv() {
        mpv = mpv_create()
        if mpv == nil { return }
        
        // Pre-init options — only what's needed
        mpv_set_option_string(mpv, "terminal", "yes")
        mpv_set_option_string(mpv, "ytdl", "no")
        mpv_set_option_string(mpv, "volume-max", "200")
        mpv_set_option_string(mpv, "network-timeout", "45")
        mpv_set_option_string(mpv, "vd-lavc-dr", "no") // fixes mpv "stride > 0" assert crash on some 8K AV1 streams

        if mpv_initialize(mpv) < 0 {
            print("[MPV] init failed")
            fluxDiag("CORE mpv_initialize FAILED (view \(ObjectIdentifier(self).hashValue))")
            return
        }
        fluxDiag("CORE mpv initialized (view \(ObjectIdentifier(self).hashValue), mpv \(ptrId(UnsafeMutableRawPointer(mpv))))")
        
        // Minimal mpv config — use mpv defaults, don't over-configure.
        mpv_set_property_string(mpv, "vo", "libmpv")
        mpv_set_property_string(mpv, "gpu-hwdec-interop", "auto")

        let useHW = UserDefaults.standard.object(forKey: "useHardwareAcceleration") as? Bool ?? true
        mpv_set_property_string(mpv, "hwdec", useHW ? "auto-safe" : "no")

        // Audio output: low-latency, strictly hardware-synchronized CoreAudio driver
        // with AVFoundation fallback.
        // float format + auto-safe channels provide native 32-bit float audio and safe channel layout.
        mpv_set_property_string(mpv, "ao", "coreaudio,avfoundation")
        mpv_set_property_string(mpv, "audio-format", "float")
        mpv_set_property_string(mpv, "audio-channels", "auto-safe")
        // Increase audio device buffer from default 0.2s to 0.5s to cushion against transient network jitter
        mpv_set_property_string(mpv, "audio-buffer", "0.5")
        mpv_set_property_string(mpv, "audio-wait-open", "0.2")

        // Smooth out A/V sync adjustments gradually rather than violent frame-rate jumps
        mpv_set_property_string(mpv, "autosync", "30")

        // Don't stop on audio output issues — let mpv fall back
        mpv_set_property_string(mpv, "audio-fallback-to-null", "yes")

        // Network stream auto-reconnection and keep-alive (FFmpeg libavformat)
        // Prevents dropped playback when CDNs/hosts terminate idle TCP connections after demuxer cache fills
        // Reconnect only on 5xx server errors and network drops (never loop retrying 4xx client errors)
        mpv_set_property_string(mpv, "stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=5,reconnect_on_http_error=5xx")
        mpv_set_property_string(mpv, "demuxer-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=5")
        mpv_set_property_string(mpv, "cache", "yes")
        mpv_set_property_string(mpv, "demuxer-max-bytes", "314572800") // 300 MiB high-throughput buffer for 1080p/4K HDR
        mpv_set_property_string(mpv, "demuxer-max-back-bytes", "104857600") // 100 MiB backward buffer for instant rewind
        mpv_set_property_string(mpv, "demuxer-readahead-secs", "60") // Read 60s ahead for jitter immunity
        // Cache stall protection: buffer 1.0s before resuming playback to eliminate stutter loops
        mpv_set_property_string(mpv, "cache-pause", "yes")
        mpv_set_property_string(mpv, "cache-pause-wait", "1.0")
        mpv_set_property_string(mpv, "cache-pause-initial", "yes")
        // Use standard vo framedrop and disable framedrop on high-res seek:
        // Prevents unbounded 5x-10x fast-forward speedup after buffer underruns
        // while preserving smooth playback.
        mpv_set_property_string(mpv, "framedrop", "vo")
        mpv_set_property_string(mpv, "hr-seek-framedrop", "no")

        mpv_set_property_string(mpv, "user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
        // Instruct FFmpeg HTTP demuxer to request uncompressed stream data (avoids unsupported Brotli 'br' encoding)
        mpv_set_property_string(mpv, "http-header-fields", "Accept-Encoding: identity")
        // Do not force a global synthetic referrer — streaming CDNs often reject or throttle requests with unrecognized external referrers.
        mpv_set_property_string(mpv, "referrer", "")

        // Dolby Atmos / DTS bitstream passthrough (E-AC-3 JOC & TrueHD carry Atmos)
        if UserDefaults.standard.bool(forKey: "enableAudioPassthrough") {
            mpv_set_property_string(mpv, "audio-spdif", "ac3,eac3,truehd,dts")
            mpv_set_property_string(mpv, "audio-exclusive", "yes")
        }

        mpv_set_property_string(mpv, "sub-font-size", "45")
        mpv_set_property_string(mpv, "sub-border-size", "2")
        mpv_set_property_string(mpv, "sub-margin-y", "40")

        let audioLang = UserDefaults.standard.string(forKey: "defaultAudioLang") ?? "English"
        let streamLangs = UserDefaults.standard.stringArray(forKey: UserDefaults.Key.preferredStreamLanguages) ?? [audioLang]
        let subLang = UserDefaults.standard.string(forKey: "defaultSubLang") ?? "English"
        
        func getIsoCode(_ lang: String) -> String {
            switch lang {
            case "Off", "None": return "no"
            case "English": return "eng,en"
            case "Spanish": return "spa,es"
            case "French": return "fra,fre,fr"
            case "German": return "deu,ger,de"
            case "Japanese": return "jpn,ja"
            case "Korean": return "kor,ko"
            case "Hindi": return "hin,hi"
            case "Italian": return "ita,it"
            case "Portuguese": return "por,pt"
            case "Chinese": return "zho,chi,zh"
            case "Russian": return "rus,ru"
            case "Tamil": return "tam,ta"
            case "Telugu": return "tel,te"
            case "Arabic": return "ara,ar"
            case "Turkish": return "tur,tr"
            case "Original Audio", "Original": return "und"
            default: return "eng,en"
            }
        }
        
        var alangList: [String] = []
        if audioLang != "Original Audio" && audioLang != "Original" {
            alangList.append(getIsoCode(audioLang))
        }
        for l in streamLangs where l != audioLang && l != "Original Audio" {
            let code = getIsoCode(l)
            if !alangList.contains(code) {
                alangList.append(code)
            }
        }
        if !alangList.isEmpty {
            mpv_set_property_string(mpv, "alang", alangList.joined(separator: ","))
        }
        if subLang == "Off" || subLang == "None" {
            mpv_set_property_string(mpv, "sid", "no")
            mpv_set_property_string(mpv, "slang", "no")
        } else {
            mpv_set_property_string(mpv, "slang", getIsoCode(subLang))
        }
        
        // Observe properties (Must be called AFTER mpv_initialize)
        mpv_observe_property(mpv, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "volume", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "cache-buffering-state", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "demuxer-cache-time", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "demuxer-cache-duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "cache-speed", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, 0, "seeking", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "video-params/gamma", MPV_FORMAT_STRING)
        mpv_observe_property(mpv, 0, "video-params/primaries", MPV_FORMAT_STRING)
        mpv_observe_property(mpv, 0, "track-list", MPV_FORMAT_NONE)
        
        // Only capture warnings and errors to minimize CPU and string allocations
        // Color management defaults: ICC correction is enabled later by
        // applyColorPipeline once the active display profile is known. Explicit
        // "no"/"" here prevents libmpv from picking up a stale global config.
        mpv_set_property_string(mpv, "icc-profile-auto", "no")
        mpv_set_property_string(mpv, "icc-profile", "")
        
        mpv_request_log_messages(mpv, "warn")
        
        callbackToken = MPVCallbackRegistry.register(self)
        mpv_set_wakeup_callback(self.mpv, mpvWakeUp, UnsafeMutableRawPointer(bitPattern: UInt(callbackToken)))
        startEventLoop()
    }
    
    func setupMPVGL(with ctx: CGLContextObj) {
        guard mpvGL == nil, mpv != nil else { return }
        mpvGLCreationContext = ctx
        CGLSetCurrentContext(ctx)
        
        let getProcAddress: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? = { _, name in
            guard let name = name else { return nil }
            return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) // RTLD_DEFAULT
        }
        
        var initParams = mpv_opengl_init_params(
            get_proc_address: getProcAddress,
            get_proc_address_ctx: nil
        )
        
        "opengl".withCString { api in
            withUnsafeMutablePointer(to: &initParams) { initParamsPtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: api)),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: initParamsPtr),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                let res = mpv_render_context_create(&mpvGL, mpv, &params)
                if res < 0 {
                    print("[MPV] Failed to create mpv render context: \(res)")
                    fluxDiag("GL mpv_render_context_create FAILED res=\(res) (ctx \(ptrId(ctx)))")
                } else {
                    print("[MPV] Successfully created render context!")
                    fluxDiag("GL mpv_render_context_create OK (mpvGL bound to ctx \(ptrId(ctx)), view \(ObjectIdentifier(self).hashValue))")
                }
            }
        }
        
        mpv_render_context_set_update_callback(mpvGL, mpvGLUpdate, UnsafeMutableRawPointer(bitPattern: UInt(callbackToken)))
        setupDisplayLink()
    }
    
    private var isIntentionallySwitchingFile = false
    /// The CGL context the mpv render context was created against. When the
    /// view moves between windows (warm-core host → player window), CA issues
    /// a NEW context for the new window; the old render context keeps
    /// rendering into the dead one — black video, audio only, hwdec demoted
    /// to Software (CPU) because GL interop can never complete.
    fileprivate var mpvGLCreationContext: CGLContextObj?
    
    /// Rebinds the mpv render context to the CGL context CA is actually
    /// drawing with. Called from draw() on the CA render thread when a
    /// context change is detected (window reparenting / display move).
    fileprivate func rebuildRenderContext(for ctx: CGLContextObj) {
        guard !isCleaningUp, mpv != nil else { return }
        CGLSetCurrentContext(ctx)
        if let old = mpvGL {
            mpvGL = nil
            mpv_render_context_set_update_callback(old, { _ in }, nil)
            mpv_render_context_free(old)
        }
        setupMPVGL(with: ctx)
        print("[MPV] Render context rebound to active window context — VideoToolbox interop restored")
    }

    func loadFile(_ url: URL, paused: Bool = false) {
        print("[MPV] loadFile called: \(url.absoluteString) (paused: \(paused))")
        isIntentionallySwitchingFile = true
        reconnectLock.lock()
        reconnectTimestamps.removeAll()
        reconnectLock.unlock()

        let isLoopback = url.host == "127.0.0.1" || url.host == "localhost"
        let selectedStream = PlayerManager.shared.currentSelectedStream
        let streamTitle = selectedStream?.cleanTitle ?? selectedStream?.title
        let proxyURL = (!isLoopback) ? StreamRouteProxyManager.shared.mpvHttpProxy(for: url, title: streamTitle) : nil

        print("[MPV] Executing loadfile command for: \(url.lastPathComponent) (paused: \(paused))")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, let mpv = self.mpv else { return }
            if let proxyURL = proxyURL {
                print("[MPV] Routing stream through forward proxy: \(proxyURL)")
                mpv_set_property_string(mpv, "http-proxy", proxyURL)
            } else {
                mpv_set_property_string(mpv, "http-proxy", "")
            }
            mpv_set_property_string(mpv, "pause", paused ? "yes" : "no")
            self.command("loadfile", url.absoluteString)
        }
    }
    
    func setPause(_ paused: Bool) {
        guard mpv != nil else { return }
        mpv_set_property_string(mpv, "pause", paused ? "yes" : "no")
    }

    func setMute(_ muted: Bool) {
        guard mpv != nil else { return }
        mpv_set_property_string(mpv, "mute", muted ? "yes" : "no")
    }
    
    func stop() {
        isIntentionallySwitchingFile = true
        reconnectLock.lock()
        reconnectTimestamps.removeAll()
        reconnectLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.command("stop")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.isIntentionallySwitchingFile = false
        }
    }
    
    func seek(absoluteSeconds seconds: Double) {
        command("seek", String(format: "%.2f", seconds), "absolute")
    }
    
    func seek(relativeSeconds seconds: Double) {
        command("seek", String(format: "%.2f", seconds), "relative")
    }
    
    func setVolume(_ value: Double) {
        guard mpv != nil else { return }
        var doubleVal = VolumeCurve.uiToMpv(value)
        mpv_set_property(mpv, "volume", MPV_FORMAT_DOUBLE, &doubleVal)
    }
    
    func getVolume() -> Double {
        var vol: Double = 0
        guard mpv != nil else { return 0 }
        mpv_get_property(mpv, "volume", MPV_FORMAT_DOUBLE, &vol)
        return VolumeCurve.mpvToUi(vol)
    }
    
    func getTracks() -> [Track] {
        guard mpv != nil else { return [] }
        var tracks: [Track] = []
        var count: Int64 = 0
        if mpv_get_property(mpv, "track-list/count", MPV_FORMAT_INT64, &count) >= 0 {
            for i in 0..<Int(count) {
                let type = getPropertyString("track-list/\(i)/type") ?? ""
                let id = getPropertyInt("track-list/\(i)/id") ?? 0
                let title = getPropertyString("track-list/\(i)/title") ?? getPropertyString("track-list/\(i)/demux-title") ?? ""
                let lang = getPropertyString("track-list/\(i)/lang") ?? "und"
                let selected = getPropertyBool("track-list/\(i)/selected") ?? false
                let isDef = getPropertyBool("track-list/\(i)/default") ?? false
                let isForce = getPropertyBool("track-list/\(i)/forced") ?? false
                if type == "audio" || type == "sub" {
                    tracks.append(Track(id: id, type: type, title: title, lang: lang, isSelected: selected, isDefault: isDef, isForced: isForce))
                }
            }
        }
        return tracks
    }
    
    func getChapters() -> [MediaChapter] {
        guard mpv != nil else { return [] }
        var chapters: [MediaChapter] = []
        var count: Int64 = 0
        if mpv_get_property(mpv, "chapter-list/count", MPV_FORMAT_INT64, &count) >= 0 {
            for i in 0..<Int(count) {
                let title = getPropertyString("chapter-list/\(i)/title") ?? ""
                let time = getPropertyDouble("chapter-list/\(i)/time") ?? 0.0
                chapters.append(MediaChapter(id: i, title: title, time: time))
            }
        }
        return chapters
    }
    
    func selectTrack(_ track: Track) {
        guard mpv != nil else { return }
        let propertyName = track.type == "audio" ? "aid" : "sid"
        if track.id <= 0 {
            mpv_set_property_string(mpv, propertyName, "no")
        } else {
            mpv_set_property_string(mpv, propertyName, "\(track.id)")
        }
    }
    
    func addExternalSubtitle(url: String, title: String, lang: String? = nil) {
        if let lang = lang, !lang.isEmpty {
            command("sub-add", url, "select", title, lang)
        } else {
            command("sub-add", url, "select", title)
        }
    }
    
    func setSubtitleDelay(_ delay: Double) {
        guard let mpv = mpv else { return }
        mpv_set_property_string(mpv, "sub-delay", String(format: "%.3f", delay))
    }

    func setSubtitleScale(_ scale: Double) {
        guard let mpv = mpv else { return }
        mpv_set_property_string(mpv, "sub-scale", String(format: "%.2f", scale))
    }

    func setSubtitlePos(_ pos: Double) {
        guard let mpv = mpv else { return }
        mpv_set_property_string(mpv, "sub-pos", String(format: "%.0f", pos))
    }

    func setAudioDelay(_ delay: Double) {
        guard let mpv = mpv else { return }
        mpv_set_property_string(mpv, "audio-delay", String(format: "%.3f", delay))
    }

    func setDialogueBoost(_ enabled: Bool) {
        guard let mpv = mpv else { return }
        if enabled {
            mpv_set_property_string(mpv, "af", "lavfi=[dynaudnorm=f=150:g=15:m=10.0:r=0.9]")
        } else {
            mpv_set_property_string(mpv, "af", "")
        }
    }

    func setVideoAspect(_ aspect: String) {
        guard let mpv = mpv else { return }
        switch aspect.lowercased() {
        case "16:9":
            mpv_set_property_string(mpv, "video-aspect-override", "16:9")
        case "21:9", "2.35:1":
            mpv_set_property_string(mpv, "video-aspect-override", "2.35:1")
        case "4:3":
            mpv_set_property_string(mpv, "video-aspect-override", "4:3")
        default:
            mpv_set_property_string(mpv, "video-aspect-override", "-1")
        }
    }

    func setDeband(_ enabled: Bool) {
        guard let mpv = mpv else { return }
        mpv_set_property_string(mpv, "deband", enabled ? "yes" : "no")
    }

    func setContrast(_ value: Double) {
        guard let mpv = mpv else { return }
        mpv_set_property_string(mpv, "contrast", String(format: "%.0f", value))
    }

    func setBrightness(_ value: Double) {
        guard let mpv = mpv else { return }
        mpv_set_property_string(mpv, "brightness", String(format: "%.0f", value))
    }

    func setSaturation(_ value: Double) {
        guard let mpv = mpv else { return }
        mpv_set_property_string(mpv, "saturation", String(format: "%.0f", value))
    }
    
    private func command(_ args: String...) {
        guard mpv != nil else { return }
        withCStrings(args) { cArgs in
            var mutableArgs = cArgs
            mutableArgs.withUnsafeMutableBufferPointer { buffer in
                _ = mpv_command(mpv, buffer.baseAddress)
            }
        }
    }
    
    // Helpers
    func getPropertyDouble(_ name: String) -> Double? {
        guard mpv != nil else { return nil }
        var value: Double = 0
        if mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &value) >= 0 { return value }
        return nil
    }
    
    func getPropertyString(_ name: String) -> String? {
        guard mpv != nil else { return nil }
        guard let cString = mpv_get_property_string(mpv, name) else { return nil }
        let str = String(cString: cString)
        mpv_free(cString)
        return str
    }
    
    func getPropertyInt64(_ name: String) -> Int64? {
        guard mpv != nil else { return nil }
        var value: Int64 = 0
        if mpv_get_property(mpv, name, MPV_FORMAT_INT64, &value) >= 0 { return value }
        if let d = getPropertyDouble(name), d > 0 { return Int64(d) }
        if let s = getPropertyString(name), let parsed = Int64(s), parsed > 0 { return parsed }
        return nil
    }

    func getPropertyInt(_ name: String) -> Int? {
        if let val = getPropertyInt64(name) {
            return Int(val)
        }
        return nil
    }
    
    func getPropertyBool(_ name: String) -> Bool? {
        guard mpv != nil else { return nil }
        var value: Int32 = 0
        if mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &value) >= 0 { return value != 0 }
        return nil
    }

    func startEventLoop() {
        eventLoopLock.lock()
        guard !isEventLoopRunning else {
            eventLoopLock.unlock()
            return
        }
        isEventLoopRunning = true
        eventLoopLock.unlock()

        queue.async { [weak self] in
            guard let self = self else { return }
            defer {
                self.eventLoopLock.lock()
                self.isEventLoopRunning = false
                self.eventLoopLock.unlock()
            }

            while !self.isCleaningUp, let handle = self.mpv {
                guard let event = mpv_wait_event(handle, 1.0) else { continue }
                let eventId = event.pointee.event_id
                if eventId == MPV_EVENT_NONE { continue }
                
                switch eventId {
                case MPV_EVENT_START_FILE:
                    print("[MPV EVENT] START_FILE")
                    self.isIntentionallySwitchingFile = false
                case MPV_EVENT_END_FILE:
                    let endFile = event.pointee.data.assumingMemoryBound(to: mpv_event_end_file.self)
                    let reason = endFile.pointee.reason
                    let error = endFile.pointee.error
                    print("[MPV EVENT] END_FILE reason:\(reason) error:\(error)")
                    if reason == MPV_END_FILE_REASON_ERROR {
                        print("[MPV] Error: End File Reason ERROR (code: \(error))")
                        self.isIntentionallySwitchingFile = false
                        DispatchQueue.main.async { self.onPlaybackError?() }
                    } else if reason == MPV_END_FILE_REASON_EOF && !self.isIntentionallySwitchingFile {
                        print("[MPV] Natural end of file reached")
                        DispatchQueue.main.async { self.onEndOfFile?() }
                    }
                case MPV_EVENT_FILE_LOADED:
                    print("[MPV EVENT] FILE_LOADED")
                    self.isIntentionallySwitchingFile = false
                    DispatchQueue.main.async { [weak self] in self?.onFileLoaded?() }
                case MPV_EVENT_LOG_MESSAGE:
                    let logMsg = event.pointee.data.assumingMemoryBound(to: mpv_event_log_message.self)
                    let prefix = String(cString: logMsg.pointee.prefix)
                    let text = String(cString: logMsg.pointee.text)
                    print("[MPV LOG] \(prefix): \(text)")
                    // Diagnostic forwarding (8/31 lags): only warn+ arrives here
                    // (requested level), so volume is inherently sparse. Forward
                    // audio/video/demuxer/stream lines + any underrun mention to
                    // the persisted channel; deduped consecutively.
                    let lowerText = text.lowercased()
                    if prefix.hasPrefix("ao") || prefix.hasPrefix("vo") || prefix.hasPrefix("ffmpeg") || prefix.hasPrefix("demux") || prefix.hasPrefix("stream") || lowerText.contains("underrun") {
                        let key = "\(prefix):\(text.prefix(60))"
                        if key != self.lastForwardedMPVLog {
                            self.lastForwardedMPVLog = key
                            let trimmed = String(text.prefix(160)).trimmingCharacters(in: .whitespacesAndNewlines)
                            Logger.player.error("mpv[\(prefix, privacy: .public)]: \(trimmed, privacy: .public)")
                        }
                    }
                    // Delivery-reputation feed: origin mid-stream cuts (the
                    // premature-end / reconnect storm class) demote the host in
                    // autoplay ranking via HostHealthTracker. Runs off-thread;
                    // mpv_get_property is thread-safe, callback must not block.
                    if lowerText.contains("prematurely") || (lowerText.contains("reconnect") && prefix.hasPrefix("ffmpeg")) {
                        DispatchQueue.global(qos: .utility).async { [weak self] in
                            guard let self = self else { return }
                            let sof = self.getPropertyString("stream-open-filename") ?? ""
                            if let host = URL(string: sof)?.host {
                                HostHealthTracker.shared.recordFailure(host: host)
                            }
                        }

                        let playbackRunning = PlayerManager.shared.hasPlaybackStarted

                        // Only evaluate reconnect storms during active mid-stream playback (after playback has started).
                        // Initial connection and buffering timeouts are safely managed by PlayerManager.armStartupWatchdog.
                        if playbackRunning {
                            let now = CFAbsoluteTimeGetCurrent()
                            self.reconnectLock.lock()
                            self.reconnectTimestamps.append(now)
                            self.reconnectTimestamps.removeAll { now - $0 > 5.0 }
                            let isStorm = self.reconnectTimestamps.count >= 4
                            if isStorm {
                                self.reconnectTimestamps.removeAll()
                            }
                            self.reconnectLock.unlock()

                            if isStorm {
                                DispatchQueue.main.async { [weak self] in
                                    guard let self = self, !self.isCleaningUp, self.mpv != nil else { return }
                                    Logger.player.error("🚨 Mid-playback reconnect storm detected in mpv (\(lowerText.prefix(80), privacy: .public)). Advancing to fallback stream...")
                                    PlayerManager.shared.handleStreamFailure(reason: "Stream connection dropped repeatedly during playback")
                                }
                            }
                        }
                    }
                default:
                    break
                }
                
                if eventId == MPV_EVENT_PROPERTY_CHANGE {
                    let prop = event.pointee.data.assumingMemoryBound(to: mpv_event_property.self)
                    let name = String(cString: prop.pointee.name)
                    
                    if prop.pointee.format == MPV_FORMAT_DOUBLE {
                        let value = prop.pointee.data.assumingMemoryBound(to: Double.self).pointee
                        if name == "time-pos" {
                            let now = CFAbsoluteTimeGetCurrent()
                            if now - self.lastTimePosDispatchTime >= 0.25 {
                                self.lastTimePosDispatchTime = now
                                DispatchQueue.main.async { self.onPropertyChange?(name, value) }
                            }
                        } else {
                            DispatchQueue.main.async { self.onPropertyChange?(name, value) }
                        }
                    } else if prop.pointee.format == MPV_FORMAT_FLAG {
                        let value = prop.pointee.data.assumingMemoryBound(to: Int32.self).pointee != 0
                        DispatchQueue.main.async { self.onPropertyChange?(name, value) }
                    } else if prop.pointee.format == MPV_FORMAT_INT64 {
                        let value = prop.pointee.data.assumingMemoryBound(to: Int64.self).pointee
                        DispatchQueue.main.async { self.onPropertyChange?(name, value) }
                    } else if prop.pointee.format == MPV_FORMAT_STRING {
                        if let cStr = prop.pointee.data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee {
                            let value = String(cString: cStr)
                            DispatchQueue.main.async { self.onPropertyChange?(name, value) }
                        }
                    }
                }
            }
        }
    }
    
    private func withCStrings(_ strings: [String], block: ([UnsafePointer<CChar>?]) -> Void) {
        var cStrings: [UnsafePointer<CChar>?] = []
        var keepAlive: [Any] = []
        for string in strings {
            let utf8 = string.utf8CString
            let ptrCopy = UnsafeMutablePointer<CChar>.allocate(capacity: utf8.count)
            utf8.withUnsafeBufferPointer { ptrCopy.initialize(from: $0.baseAddress!, count: utf8.count) }
            cStrings.append(UnsafePointer(ptrCopy))
            keepAlive.append(ptrCopy)
        }
        cStrings.append(nil)
        block(cStrings)
        for case let ptr as UnsafeMutablePointer<CChar> in keepAlive { ptr.deallocate() }
    }
}

// MARK: - Safe mpv callback registry

/// mpv invokes its wakeup / render-update callbacks from internal C threads,
/// passing back the context pointer we registered. Handing it an unretained
/// raw pointer to the view is a use-after-free if the view tears down while a
/// callback is in flight (the exact crash in the 2026-08-28 reports). Instead
/// we register each view under a unique token and resolve that token against a
/// lock-guarded table of weak references: a callback for a dead view no-ops.
private final class MPVLayerViewBox {
    weak var view: MPVLayerView?
    init(_ view: MPVLayerView) { self.view = view }
}

enum MPVCallbackRegistry {
    private static let lock = NSLock()
    private static var boxes: [UInt64: MPVLayerViewBox] = [:]
    private static var nextToken: UInt64 = 1

    static func register(_ view: MPVLayerView) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let token = nextToken
        nextToken &+= 1
        boxes[token] = MPVLayerViewBox(view)
        return token
    }

    static func unregister(_ token: UInt64) {
        lock.lock(); defer { lock.unlock() }
        boxes.removeValue(forKey: token)
    }

    /// Promotes the weak reference to a strong one while holding the lock, so
    /// the view cannot be deallocated mid-callback. Returns nil if it is gone.
    static func view(for token: UInt64) -> MPVLayerView? {
        lock.lock(); defer { lock.unlock() }
        return boxes[token]?.view
    }
}

func mpvGLUpdate(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx = ctx else { return }
    let token = UInt64(UInt(bitPattern: ctx))
    guard let layerView = MPVCallbackRegistry.view(for: token) else { return }
    layerView.mpvRenderUpdate()
}

func mpvWakeUp(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx = ctx else { return }
    let token = UInt64(UInt(bitPattern: ctx))
    guard let layerView = MPVCallbackRegistry.view(for: token) else { return }
    layerView.startEventLoop()
}
