import SwiftUI
import AppKit
import OpenGL.GL
import Libmpv
import Combine
import Darwin
import OSLog
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
            controller.playerView = vc
            vc.delegate = controller
        }
        context.coordinator.player = vc // Link controller to view
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
        diag.cacheBufferSeconds = self.demuxerCacheTime
        return diag
    }
    
    // Settings
    @AppStorage("useHardwareAcceleration") private var useHardwareAcceleration = true
    
    var onPlaybackError: (() -> Void)?
    /// Bumped once per natural end-of-file (see event loop). PlayerView observes
    /// via onChange — a closure would capture a stale View struct.
    @Published private(set) var endOfFileCount = 0
    func registerEndOfFile() { endOfFileCount += 1 }
    weak var playerView: MPVViewController?
    private var hasAutoSelectedTracksForCurrentMedia = false
    
    func play(url: URL) {
        // Same media already loading/loaded on this controller (warm-core
        // adoption races finishSelect) — reloading would discard the buffer.
        if hasLoadedMedia, loadedURL == url {
            print("[MPVController] Skipping duplicate loadfile for \(url.lastPathComponent)")
            return
        }
        self.isUserPaused = false
        self.hasLoadedMedia = true
        self.loadedURL = url
        self.hasAutoSelectedTracksForCurrentMedia = false
        resetVolumeBoostIfNeeded()
        playerView?.play(url)
    }

    func play() {
        self.isUserPaused = false
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
            case "pause":
                if let paused = value as? Bool {
                    self.isPlaying = !paused
                    if !self.isBuffering {
                        self.isUserPaused = paused
                    }
                }
            case "paused-for-cache":
                if let buff = value as? Bool {
                    // Stall telemetry on the ERROR channel: .info lines from this
                    // app never reach the persisted store. Values marked public
                    // (os.Logger redacts interpolations by default).
                    if buff && !self.isBuffering {
                        self.stallStartDate = Date()
                        self.stallStartDrops = self.playerView?.playerView?.getPropertyInt("frame-drop-count") ?? -1
                        let cache = String(format: "%.1f", self.demuxerCacheTime)
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
            case "demuxer-cache-time":
                if let time = value as? Double {
                    self.demuxerCacheTime = time
                }
            case "video-params/gamma", "video-params/primaries":
                self.playerView?.playerView?.applyColorPipeline()
            default:
                break
            }
        }
    }

    /// Live media format inspection for "About Stream Source"
    func getMediaInfo() -> (videoCodec: String?, audioCodec: String?, resolution: String?, hwdec: String?) {
        let backend = playerView?.playerView
        let vCodec = backend?.getPropertyString("video-codec") ?? backend?.getPropertyString("video-format")
        let aCodec = backend?.getPropertyString("audio-codec")
        let w = backend?.getPropertyInt("video-params/w")
        let h = backend?.getPropertyInt("video-params/h")
        let res = (w != nil && h != nil && w! > 0 && h! > 0) ? "\(w!)×\(h!)" : nil
        let hwdec = backend?.getPropertyString("hwdec-current")
        return (vCodec, aCodec, res, hwdec)
    }
    
    func fetchTracks() {
        guard let tracks = playerView?.getTracks() else { return }
        
        DispatchQueue.main.async {
            self.audioTracks = tracks.filter { $0.type == "audio" }
            self.subtitleTracks = tracks.filter { $0.type == "sub" }
            self.autoSelectPreferredTracks()
        }
    }

    private func trackMatchesLanguage(track: Track, targetLang: String) -> Bool {
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
                return ["ja", "jpn", "japanese", "nihongo"]
            case "korean", "ko", "kor":
                return ["ko", "kor", "korean", "hangul"]
            case "hindi", "hi", "hin":
                return ["hi", "hin", "hindi"]
            default:
                return [cleanTarget]
            }
        }()

        let trackLang = track.lang.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trackTitle = track.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trackDisplay = track.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Direct language code match
        if !trackLang.isEmpty && trackLang != "und" && aliases.contains(trackLang) {
            return true
        }

        // Title or display name match
        for alias in aliases {
            if trackTitle.contains(alias) || trackDisplay.contains(alias) {
                return true
            }
        }

        // If target is English, detect dub tracks that aren't other languages
        if cleanTarget.hasPrefix("eng") && (trackTitle.contains("dub") || trackDisplay.contains("dub")) {
            let foreignWords = ["spanish", "french", "german", "japanese", "korean", "hindi", "italian", "russian"]
            if !foreignWords.contains(where: { trackTitle.contains($0) || trackDisplay.contains($0) }) {
                return true
            }
        }

        return false
    }

    private func autoSelectPreferredTracks() {
        guard !hasAutoSelectedTracksForCurrentMedia else { return }
        guard !audioTracks.isEmpty else { return }
        hasAutoSelectedTracksForCurrentMedia = true

        let preferredAudio = UserDefaults.standard.string(forKey: "defaultAudioLang") ?? "English"
        let preferredSub = UserDefaults.standard.string(forKey: "defaultSubLang") ?? "English"

        // 1. Audio Track Selection
        let activeAudio = audioTracks.first(where: { $0.isSelected })
        let isAudioPreferred = activeAudio.map { trackMatchesLanguage(track: $0, targetLang: preferredAudio) } ?? false

        if !isAudioPreferred {
            if let matchedAudio = audioTracks.first(where: { trackMatchesLanguage(track: $0, targetLang: preferredAudio) }) {
                print("[MPV] Auto-selecting preferred audio track: \(matchedAudio.displayName) (id: \(matchedAudio.id))")
                playerView?.selectTrack(matchedAudio)
            }
        }

        let currentOrNewAudio = audioTracks.first(where: {
            if !isAudioPreferred, let matched = audioTracks.first(where: { trackMatchesLanguage(track: $0, targetLang: preferredAudio) }) {
                return $0.id == matched.id
            }
            return $0.isSelected
        })
        let resultingAudioMatches = currentOrNewAudio.map { trackMatchesLanguage(track: $0, targetLang: preferredAudio) } ?? false

        // 2. Subtitle Track Selection
        // If preferredSub is Off or None, the user explicitly does not want subtitles by default
        guard preferredSub != "Off" && preferredSub != "None" else { return }

        // If the audio track is foreign/non-preferred (e.g. only Korean audio available and user wanted English),
        // we MUST automatically turn on preferred subtitles!
        let activeSub = subtitleTracks.first(where: { $0.isSelected })
        let isSubPreferred = activeSub.map { trackMatchesLanguage(track: $0, targetLang: preferredSub) } ?? false

        if !resultingAudioMatches && !isSubPreferred {
            if let matchedSub = subtitleTracks.first(where: { trackMatchesLanguage(track: $0, targetLang: preferredSub) }) {
                print("[MPV] Foreign audio detected without subtitles — auto-selecting embedded subtitle: \(matchedSub.displayName) (id: \(matchedSub.id))")
                playerView?.selectTrack(matchedSub)
            } else if let extSub = PlayerManager.shared.externalSubtitles.first(where: { sub in
                let lang = sub.language.lowercased()
                return lang.contains("en") || lang.contains("eng") || lang.contains("english")
            }) {
                print("[MPV] Foreign audio detected — auto-attaching external subtitle: \(extSub.language)")
                addExternalSubtitle(extSub)
            }
        }
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
        playerView?.addExternalSubtitle(url: subtitle.url.absoluteString, title: subtitle.language)
        // Re-fetch tracks after a brief delay to show the new track selected
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.fetchTracks()
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
        
        self.playerView.onPropertyChange = { [weak self] name, value in
            self?.delegate?.handlePropertyChange(name: name, value: value)
        }
        
        self.playerView.onPlaybackError = { [weak self] in
              print("[MPV] Playback error detected")
              DispatchQueue.main.async {
                  self?.delegate?.onPlaybackError?()
              }
        }

        self.playerView.onEndOfFile = { [weak self] in
              DispatchQueue.main.async {
                  self?.delegate?.registerEndOfFile()
              }
        }
        
        let vol = self.playerView.getVolume()
        DispatchQueue.main.async {
            self.delegate?.volume = vol
        }
    }
    
    func play(_ url: URL) { playerView.loadFile(url) }
    func pause() { playerView.setPause(true) }
    func resume() { playerView.setPause(false) }
    func stop() { playerView.stop() }
    
    func seek(absolute seconds: Double) { playerView.seek(absoluteSeconds: seconds) }
    func seek(relative seconds: Double) { playerView.seek(relativeSeconds: seconds) }
    
    func setVolume(_ value: Double) { playerView.setVolume(value) }
    func getTracks() -> [Track] { return playerView.getTracks() }
    func getChapters() -> [MediaChapter] { return playerView.getChapters() }
    func selectTrack(_ track: Track) { playerView.selectTrack(track) }
    func addExternalSubtitle(url: String, title: String) { playerView.addExternalSubtitle(url: url, title: title) }

    func setSubtitleDelay(_ delay: Double) { playerView?.setSubtitleDelay(delay) }
    func setSubtitleScale(_ scale: Double) { playerView?.setSubtitleScale(scale) }
    func setSubtitlePos(_ pos: Double) { playerView?.setSubtitlePos(pos) }
    func setAudioDelay(_ delay: Double) { playerView?.setAudioDelay(delay) }
    func setDialogueBoost(_ enabled: Bool) { playerView?.setDialogueBoost(enabled) }
    func setVideoAspect(_ aspect: String) { playerView?.setVideoAspect(aspect) }
    func setDeband(_ enabled: Bool) { playerView?.setDeband(enabled) }
    func setContrast(_ value: Double) { playerView?.setContrast(value) }
    func setBrightness(_ value: Double) { playerView?.setBrightness(value) }
    func setSaturation(_ value: Double) { playerView?.setSaturation(value) }

    /// Pixel aspect of the loaded video (for PiP window sizing). Falls back to 16:9.
    var videoAspectRatio: Double { playerView?.videoAspectRatio ?? 16.0 / 9.0 }
}

// MARK: - OpenGL View & MPV Backend
// MARK: - CAOpenGLLayer Subclass for Zero Main-Thread Hop Rendering
final class MPVLayer: CAOpenGLLayer {
    weak var ownerView: MPVLayerView?
    
    override init() {
        super.init()
        self.isAsynchronous = false
        self.contentsFormat = .RGBA8Uint
    }
    
    override init(layer: Any) {
        super.init(layer: layer)
        self.isAsynchronous = false
        self.contentsFormat = .RGBA8Uint
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.isAsynchronous = false
        self.contentsFormat = .RGBA8Uint
    }
    
    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        // Evaluate potential EDR capability for the target display mask.
        // We check `maximumPotentialExtendedDynamicRangeColorComponentValue`,
        // because at launch before an EDR layer is active, `maximumExtendedDynamicRangeColorComponentValue`
        // is 1.0 at rest on MacBook Air M1 and Liquid Retina XDR displays.
        let targetScreen = NSScreen.screens.first(where: {
            guard let id = ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return false }
            return (CGDisplayIDToOpenGLDisplayMask(id) & mask) != 0
        }) ?? NSScreen.main
        
        let edr = targetScreen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
        let useFloat16 = edr > 1.0

        let attributes: [CGLPixelFormatAttribute] = useFloat16
            ? [
                kCGLPFAAccelerated,
                kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
                kCGLPFADoubleBuffer,
                kCGLPFAColorFloat,
                kCGLPFAColorSize, CGLPixelFormatAttribute(64),
                kCGLPFADepthSize, CGLPixelFormatAttribute(24),
                CGLPixelFormatAttribute(0)
            ]
            : [
                kCGLPFAAccelerated,
                kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
                kCGLPFADoubleBuffer,
                kCGLPFAColorSize, CGLPixelFormatAttribute(32),
                kCGLPFADepthSize, CGLPixelFormatAttribute(24),
                CGLPixelFormatAttribute(0)
            ]
        var pix: CGLPixelFormatObj?
        var npix: GLint = 0
        CGLChoosePixelFormat(attributes, &pix, &npix)
        return pix!
    }
    
    override func copyCGLContext(forPixelFormat pixelFormat: CGLPixelFormatObj) -> CGLContextObj {
        var ctx: CGLContextObj?
        CGLCreateContext(pixelFormat, nil, &ctx)
        return ctx!
    }
    
    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat: CGLPixelFormatObj, forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        return ownerView?.mpv != nil
    }
    
    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat: CGLPixelFormatObj, forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        CGLSetCurrentContext(ctx)
        CGLLockContext(ctx)
        defer { CGLUnlockContext(ctx) }
        
        guard let owner = ownerView, owner.mpv != nil else {
            glFlush()
            return
        }
        
        if owner.mpvGL == nil {
            owner.setupMPVGL(with: ctx)
        }
        
        guard let mpvGL = owner.mpvGL else {
            glFlush()
            return
        }
        
        // Update render context on OpenGL thread with active context
        _ = mpv_render_context_update(mpvGL)
        
        let scale = contentsScale
        let w = Int32(bounds.width * scale)
        let h = Int32(bounds.height * scale)
        
        guard w > 0 && h > 0 else {
            glFlush()
            return
        }
        
        glViewport(0, 0, GLsizei(w), GLsizei(h))
        
        var currentFBO: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &currentFBO)
        
        var flipY: Int32 = 1
        // Dynamic depth for dithering:
        // When actively rendering HDR content in EDR mode, report 16-bit float depth.
        // When rendering SDR content (or on an SDR screen), report 8-bit depth so mpv's
        // active fruit / Floyd-Steinberg dithering runs, eliminating banding on 8-bit panels.
        var depth: Int32 = self.wantsExtendedDynamicRangeContent ? 16 : 8
        var fbo = mpv_opengl_fbo(fbo: currentFBO, w: w, h: h, internal_format: 0)
        
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
    private var pendingURL: URL?
    private var displayLink: CVDisplayLink?
    let mpvLayer = MPVLayer()
    
    var queue = DispatchQueue(label: "mpv", qos: .userInteractive)
    var onPropertyChange: ((String, Any) -> Void)?
    var onPlaybackError: (() -> Void)?
    /// Fired exactly once when the file ends naturally (EOF). File switches
    /// emit STOP/REDIRECT reasons instead, so autoplay must only listen here.
    var onEndOfFile: (() -> Void)?
    private var isEventLoopRunning = false
    private let eventLoopLock = NSLock()
    /// Last forwarded mpv log line (consecutive-dedupe key for diagnostics).
    private var lastForwardedMPVLog = ""
    private var isCleaningUp = false
    private var lastTimePosDispatchTime: Double = 0
    private var lastTelemetryLogTime: Double = 0
    /// Token into MPVCallbackRegistry so mpv's C callbacks never hold a raw,
    /// unretained pointer to this view (use-after-free on teardown).
    fileprivate var callbackToken: UInt64 = 0
    private var currentScreenNumber: UInt32?
    private var lastBackingScale: CGFloat = 2.0
    private var isRenderUpdateScheduled = false
    private let renderUpdateLock = NSLock()
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        mpvLayer.ownerView = self
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    
    override func makeBackingLayer() -> CALayer {
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
        let scale = window?.backingScaleFactor ?? 2.0
        lastBackingScale = scale
        mpvLayer.contentsScale = scale
        
        let screen = window?.screen ?? NSScreen.main
        currentScreenNumber = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
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
        let key = "\(gamma)|\(primaries)"
        guard key != lastPipelineKey else { return }
        lastPipelineKey = key

        let screen = window?.screen ?? NSScreen.main
        let potentialEDR = screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
        let currentEDR = screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
        let canDoEDR = isHDR && potentialEDR > 1.0

        if canDoEDR {
            // Calibrate target peak to display capability:
            // 1.0 is SDR reference white (~100–250 nits).
            // On MacBook Air M1 (potential EDR = 2.0), 2.0 * 250 = 500 nits (matches the 500-nit panel).
            // On MacBook Pro Liquid Retina XDR (potential EDR = 3.2–4.0), matches 1000–1600 nits.
            let headroom = max(1.0, currentEDR > 1.0 ? currentEDR : potentialEDR)
            let peak = max(200, min(1600, Int(headroom * 250)))

            if gamma == "pq" {
                mpv_set_property_string(mpv, "target-trc", "pq")
                mpv_set_property_string(mpv, "target-prim", (primaries == "display-p3" || primaries == "dci-p3") ? "display-p3" : "bt.2020")
            } else if gamma == "hlg" {
                mpv_set_property_string(mpv, "target-trc", "hlg")
                mpv_set_property_string(mpv, "target-prim", (primaries == "display-p3" || primaries == "dci-p3") ? "display-p3" : "bt.2020")
            } else {
                mpv_set_property_string(mpv, "target-trc", "auto")
                mpv_set_property_string(mpv, "target-prim", "auto")
            }

            mpv_set_property_string(mpv, "target-peak", String(peak))
            mpv_set_property_string(mpv, "tone-mapping", "auto")
            print("[MPV] HDR EDR pipeline active (gamma=\(gamma), prim=\(primaries), peak=\(peak)nits)")
        } else {
            for p in ["target-trc", "target-prim", "target-peak", "tone-mapping"] {
                mpv_set_property_string(mpv, p, "auto")
            }
            if isHDR {
                print("[MPV] HDR tone-mapping to SDR active (gamma=\(gamma), prim=\(primaries))")
            }
        }

        DispatchQueue.main.async { [mpvLayer] in
            mpvLayer.wantsExtendedDynamicRangeContent = canDoEDR
            mpvLayer.contentsFormat = canDoEDR ? .RGBA16Float : .RGBA8Uint
            if canDoEDR {
                switch (gamma, primaries) {
                case ("hlg", "bt.2020"):
                    mpvLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
                case ("hlg", _):
                    mpvLayer.colorspace = CGColorSpace(name: CGColorSpace.displayP3_HLG)
                case (_, "display-p3"), (_, "dci-p3"):
                    mpvLayer.colorspace = CGColorSpace(name: CGColorSpace.displayP3_PQ)
                default:
                    mpvLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
                }
            } else {
                mpvLayer.colorspace = nil
            }
        }
    }
    
    func mpvRenderUpdate() {
        renderUpdateLock.lock()
        if isRenderUpdateScheduled {
            renderUpdateLock.unlock()
            return
        }
        isRenderUpdateScheduled = true
        renderUpdateLock.unlock()
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.renderUpdateLock.lock()
            self.isRenderUpdateScheduled = false
            self.renderUpdateLock.unlock()
            self.mpvLayer.setNeedsDisplay()
        }
    }
    
    private func displayLinkFired() {
        // Handled via mpvGLUpdate callback
    }
    
    func teardown() {
        guard !isCleaningUp else { return }
        isCleaningUp = true
        
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
        
        if let glCtx = self.mpvGL {
            mpv_render_context_set_update_callback(glCtx, { _ in }, nil)
            mpv_render_context_free(glCtx)
            self.mpvGL = nil
        }
        if let handle = self.mpv {
            mpv_set_wakeup_callback(handle, nil, nil)
            mpv_terminate_destroy(handle)
            self.mpv = nil
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
        
        // Options prior to initialization (matching Stremio's mpv.cpp)
        mpv_set_option_string(mpv, "terminal", "yes")
        mpv_set_option_string(mpv, "load-scripts", "no")
        mpv_set_option_string(mpv, "load-osd-console", "no")
        mpv_set_option_string(mpv, "load-stats-overlay", "no")
        mpv_set_option_string(mpv, "ytdl", "yes")
        mpv_set_option_string(mpv, "osc", "no")
        // Fail over reasonably fast when a torrent swarm is dead: the Stremio
        // server holds the file response silent until pieces flow, so without a
        // timeout mpv would wait forever instead of triggering auto-fallback.
        mpv_set_option_string(mpv, "network-timeout", "45")
        mpv_set_option_string(mpv, "vd-lavc-dr", "no") // fixes mpv "stride > 0" assert crash on some 8K AV1 streams
        
        // Support up to 200% volume amplification (matching VLC and Stremio)
        mpv_set_option_string(mpv, "volume-max", "200")
        // Enable AC3 Dynamic Range Compression (dialogue enhancement for movie audio tracks)
        mpv_set_option_string(mpv, "ad-lavc-ac3drc", "1")
        
        if mpv_initialize(mpv) < 0 {
            print("[MPV] init failed")
            return
        }
        
        // Properties set AFTER initialization (matching Stremio's mpv.cpp)
        mpv_set_property_string(mpv, "volume-max", "200")
        mpv_set_property_string(mpv, "ad-lavc-ac3drc", "1")
        mpv_set_property_string(mpv, "vo", "libmpv")
        mpv_set_property_string(mpv, "profile", "fast")
        mpv_set_property_string(mpv, "scale", "bilinear")
        
        // Connect Hardware Acceleration setting to mpv
        let useHW = UserDefaults.standard.object(forKey: "useHardwareAcceleration") as? Bool ?? true
        mpv_set_property_string(mpv, "hwdec", useHW ? "auto" : "no")
        mpv_set_property_string(mpv, "gpu-hwdec-interop", "auto")
        mpv_set_property_string(mpv, "video-sync", "audio")
        
        // Audio: CoreAudio with proper downmixing for laptop speakers
        mpv_set_property_string(mpv, "ao", "coreaudio")
        mpv_set_property_string(mpv, "audio-channels", "auto-safe")
        mpv_set_property_string(mpv, "audio-normalize-downmix", "yes")
        
        mpv_set_property_string(mpv, "sub-cache", "yes")
        mpv_set_property_string(mpv, "sub-ass-override", "no")
        
        mpv_set_property_string(mpv, "cache", "yes")
        mpv_set_property_string(mpv, "cache-secs", "60")
        // DIAGNOSTIC A/B (8/31 rhythmic lags, see agent-chat.md): reverted 256MB
        // back to 64MB to test whether the byte cap sets the reconnect/idle
        // metronome. If lags vanish at 64MB, the cap (not the content) drives the
        // cycle; if they persist unchanged, the cap is exonerated. Revisit after.
        mpv_set_property_string(mpv, "demuxer-max-bytes", "67108864")
        mpv_set_property_string(mpv, "demuxer-max-back-bytes", "15728640") // 15 MB backward seek buffer
        mpv_set_property_string(mpv, "demuxer-readahead-secs", "12")
        mpv_set_property_string(mpv, "demuxer-seekable-cache", "yes")      // Enable seekable cache for network streams
        mpv_set_property_string(mpv, "demuxer-mkv-subtitle-preroll", "yes")
        mpv_set_property_string(mpv, "stream-buffer-size", "131072")       // 128 KB initial network buffer for instant start
        mpv_set_property_string(mpv, "stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_delay_max=5")
        mpv_set_property_string(mpv, "force-seekable", "yes")              // Enable seeking in Hydra torrent streams
        mpv_set_property_string(mpv, "access-references", "no")
        mpv_set_property_string(mpv, "audio-fallback-to-null", "yes")
        mpv_set_property_string(mpv, "framedrop", "vo")
        
        mpv_set_property_string(mpv, "user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
        mpv_set_property_string(mpv, "referrer", "https://flux.app/")

        // Dolby Atmos / DTS bitstream passthrough (E-AC-3 JOC & TrueHD carry Atmos)
        if UserDefaults.standard.bool(forKey: "enableAudioPassthrough") {
            mpv_set_property_string(mpv, "audio-spdif", "ac3,eac3,truehd,dts")
            mpv_set_property_string(mpv, "audio-exclusive", "yes")
        }
        
        mpv_set_property_string(mpv, "sub-font-size", "45")
        mpv_set_property_string(mpv, "sub-border-size", "2")
        mpv_set_property_string(mpv, "sub-margin-y", "40")
        
        let audioLang = UserDefaults.standard.string(forKey: "defaultAudioLang") ?? "English"
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
            default: return "eng,en"
            }
        }
        
        mpv_set_property_string(mpv, "alang", getIsoCode(audioLang))
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
        mpv_observe_property(mpv, 0, "seeking", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "video-params/gamma", MPV_FORMAT_STRING)
        mpv_observe_property(mpv, 0, "video-params/primaries", MPV_FORMAT_STRING)
        
        // Only capture warnings and errors to minimize CPU and string allocations
        mpv_request_log_messages(mpv, "warn")
        
        callbackToken = MPVCallbackRegistry.register(self)
        mpv_set_wakeup_callback(self.mpv, mpvWakeUp, UnsafeMutableRawPointer(bitPattern: UInt(callbackToken)))
        startEventLoop()
    }
    
    func setupMPVGL(with ctx: CGLContextObj) {
        guard mpvGL == nil, mpv != nil else { return }
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
                } else {
                    print("[MPV] Successfully created render context!")
                }
            }
        }
        
        mpv_render_context_set_update_callback(mpvGL, mpvGLUpdate, UnsafeMutableRawPointer(bitPattern: UInt(callbackToken)))
        setupDisplayLink()
        
        if let pending = pendingURL {
            print("[MPV] Context ready! Now loading pending URL: \(pending.lastPathComponent)")
            let urlToLoad = pending
            pendingURL = nil
            command("loadfile", urlToLoad.absoluteString)
        }
    }
    
    private var isIntentionallySwitchingFile = false

    func loadFile(_ url: URL) {
        print("[MPV] loadFile called: \(url.absoluteString)")
        isIntentionallySwitchingFile = true
        if mpvGL == nil {
            print("[MPV] Deferring loadFile until render context is initialized: \(url.lastPathComponent)")
            pendingURL = url
        } else {
            pendingURL = nil
            print("[MPV] Executing loadfile command for: \(url.lastPathComponent)")
            command("loadfile", url.absoluteString)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.isIntentionallySwitchingFile = false
        }
    }
    
    func setPause(_ paused: Bool) {
        guard mpv != nil else { return }
        mpv_set_property_string(mpv, "pause", paused ? "yes" : "no")
    }
    
    func stop() {
        command("stop")
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
                if type == "audio" || type == "sub" {
                    tracks.append(Track(id: id, type: type, title: title, lang: lang, isSelected: selected))
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
    
    func addExternalSubtitle(url: String, title: String) {
        command("sub-add", url, "select", title)
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
    
    func getPropertyInt(_ name: String) -> Int? {
        guard mpv != nil else { return nil }
        var value: Int64 = 0
        if mpv_get_property(mpv, name, MPV_FORMAT_INT64, &value) >= 0 { return Int(value) }
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
                case MPV_EVENT_END_FILE:
                    let endFile = event.pointee.data.assumingMemoryBound(to: mpv_event_end_file.self)
                    let reason = endFile.pointee.reason
                    let error = endFile.pointee.error
                    print("[MPV EVENT] END_FILE reason:\(reason) error:\(error)")
                    if reason == MPV_END_FILE_REASON_ERROR && !self.isIntentionallySwitchingFile {
                        print("[MPV] Error: End File Reason ERROR (code: \(error))")
                        DispatchQueue.main.async { self.onPlaybackError?() }
                    } else if reason == MPV_END_FILE_REASON_EOF && !self.isIntentionallySwitchingFile {
                        print("[MPV] Natural end of file reached")
                        DispatchQueue.main.async { self.onEndOfFile?() }
                    }
                case MPV_EVENT_FILE_LOADED:
                    print("[MPV EVENT] FILE_LOADED")
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
