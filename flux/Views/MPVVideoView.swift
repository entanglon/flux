import SwiftUI
import AppKit
import OpenGL.GL
import Libmpv
import Combine
import Darwin
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
    @Published var demuxerCacheTime: Double = 0.0
    @Published var isSeeking = false
    @Published var isUserPaused = false
    
    @Published var audioTracks: [Track] = []
    @Published var subtitleTracks: [Track] = []
    
    // Settings
    @AppStorage("useHardwareAcceleration") private var useHardwareAcceleration = true
    
    var onPlaybackError: (() -> Void)?
    weak var playerView: MPVViewController?
    
    private var watchdogTimer: Timer?
    private var loadStartTime: CFAbsoluteTime = 0

    private func startHungStreamWatchdog() {
        watchdogTimer?.invalidate()
        loadStartTime = CFAbsoluteTimeGetCurrent()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            guard self.hasLoadedMedia, !self.isUserPaused else { return }

            if self.timePos > 0.5 || (self.duration > 0 && self.demuxerCacheTime > 0.5) {
                timer.invalidate()
                self.watchdogTimer = nil
                return
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - self.loadStartTime
            if elapsed >= 12.0 && self.demuxerCacheTime <= 0.0 && self.timePos <= 0.0 {
                print("[MPVController] Hung-stream watchdog triggered: 0 bytes/frames received in \(Int(elapsed))s. Auto-falling over to next stream...")
                timer.invalidate()
                self.watchdogTimer = nil
                self.onPlaybackError?()
            }
        }
    }

    private func disarmWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

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
        startHungStreamWatchdog()
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
        disarmWatchdog()
        self.isUserPaused = false
        self.hasLoadedMedia = false
        self.loadedURL = nil
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
        playerView?.setVolume(value)
        volume = value
        if value > 0 {
            savedVolume = value
        }
    }

    func toggleMute() {
        if volume > 0 {
            savedVolume = volume
            setVolume(0)
        } else {
            setVolume(savedVolume > 0 ? savedVolume : 1.0)
        }
    }
    
    func handlePropertyChange(name: String, value: Any) {
        DispatchQueue.main.async {
            switch name {
            case "time-pos":
                if let time = value as? Double {
                    self.timePos = time
                    if time > 0.5 {
                        self.disarmWatchdog()
                    }
                    if self.duration > 0 {
                        self.progress = time / self.duration
                    }
                }
            case "duration":
                if let dur = value as? Double {
                    self.duration = dur
                    self.fetchTracks()
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
                    self.volume = vol / 100.0
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
    
    func fetchTracks() {
        guard let tracks = playerView?.getTracks() else { return }
        
        DispatchQueue.main.async {
            self.audioTracks = tracks.filter { $0.type == "audio" }
            self.subtitleTracks = tracks.filter { $0.type == "sub" }
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
        
        let vol = self.playerView.getVolume()
        DispatchQueue.main.async {
            self.delegate?.volume = vol / 100.0
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
    func selectTrack(_ track: Track) { playerView.selectTrack(track) }
    func addExternalSubtitle(url: String, title: String) { playerView.addExternalSubtitle(url: url, title: title) }

    /// Pixel aspect of the loaded video (for PiP window sizing). Falls back to 16:9.
    var videoAspectRatio: Double { playerView?.videoAspectRatio ?? 16.0 / 9.0 }
}

// MARK: - OpenGL View & MPV Backend
// MARK: - CAOpenGLLayer Subclass for Zero Main-Thread Hop Rendering
final class MPVLayer: CAOpenGLLayer {
    weak var ownerView: MPVLayerView?
    private let frameLock = NSLock()
    private var hasNewFrame = false
    
    override init() {
        super.init()
        self.isAsynchronous = true
    }
    
    override init(layer: Any) {
        super.init(layer: layer)
        self.isAsynchronous = true
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.isAsynchronous = true
    }
    
    func markNewFrame() {
        frameLock.lock()
        hasNewFrame = true
        frameLock.unlock()
    }
    
    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        // Float (RGBA16F) backbuffer only on EDR-capable displays — needed for HDR output
        let edr = NSScreen.main?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
        let attributes: [CGLPixelFormatAttribute] = edr > 1.0
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
        guard let owner = ownerView else { return false }
        guard let gl = owner.mpvGL else { return true }
        let flags = mpv_render_context_update(gl)
        return (flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue)) != 0
    }
    
    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat: CGLPixelFormatObj, forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        CGLSetCurrentContext(ctx)
        
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
        var fbo = mpv_opengl_fbo(fbo: currentFBO, w: w, h: h, internal_format: 0)
        
        withUnsafeMutablePointer(to: &fbo) { fboPtr in
            withUnsafeMutablePointer(to: &flipY) { flipPtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fboPtr),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipPtr),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                let result = mpv_render_context_render(mpvGL, &params)
                if result >= 0 {
                    mpv_render_context_report_swap(mpvGL)
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
    private var isEventLoopRunning = false
    private let eventLoopLock = NSLock()
    private var isCleaningUp = false
    private var lastTimePosDispatchTime: Double = 0
    private var lastTelemetryLogTime: Double = 0
    /// Token into MPVCallbackRegistry so mpv's C callbacks never hold a raw,
    /// unretained pointer to this view (use-after-free on teardown).
    fileprivate var callbackToken: UInt64 = 0
    
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
        mpvLayer.contentsScale = window?.backingScaleFactor ?? 2.0
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        mpvLayer.contentsScale = window?.backingScaleFactor ?? 2.0
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
        guard key != lastPipelineKey || lastPipelineKey.isEmpty == isHDR else { return }
        lastPipelineKey = key

        if isHDR {
            let edr = NSScreen.main?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
            let peak = max(300, min(1600, Int(edr * 500)))
            mpv_set_property_string(mpv, "target-trc", gamma)
            switch primaries {
            case "bt.2020": mpv_set_property_string(mpv, "target-prim", "bt.2020")
            case "display-p3", "dci-p3": mpv_set_property_string(mpv, "target-prim", "display-p3")
            default: mpv_set_property_string(mpv, "target-prim", "auto")
            }
            mpv_set_property_string(mpv, "target-peak", String(peak))
            mpv_set_property_string(mpv, "tone-mapping", "clip")
            print("[MPV] HDR pipeline active (gamma=\(gamma), prim=\(primaries), peak=\(peak)nits)")
        } else {
            for p in ["target-trc", "target-prim", "target-peak", "tone-mapping"] {
                mpv_set_property_string(mpv, p, "auto")
            }
        }

        DispatchQueue.main.async { [mpvLayer] in
            mpvLayer.wantsExtendedDynamicRangeContent = isHDR
            if isHDR {
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
        DispatchQueue.main.async { [weak self] in
            self?.mpvLayer.setNeedsDisplay()
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
        // Fail over fast when a torrent swarm is dead (15s instead of 45s)
        mpv_set_option_string(mpv, "network-timeout", "15")
        mpv_set_option_string(mpv, "vd-lavc-dr", "no") // fixes mpv "stride > 0" assert crash on some 8K AV1 streams
        
        if mpv_initialize(mpv) < 0 {
            print("[MPV] init failed")
            return
        }
        
        // Properties set AFTER initialization (matching Stremio's mpv.cpp)
        mpv_set_property_string(mpv, "vo", "libmpv")
        mpv_set_property_string(mpv, "profile", "fast")
        mpv_set_property_string(mpv, "scale", "bilinear")
        mpv_set_property_string(mpv, "hwdec", "auto")
        mpv_set_property_string(mpv, "gpu-hwdec-interop", "auto")
        mpv_set_property_string(mpv, "video-sync", "audio")
        
        mpv_set_property_string(mpv, "sub-cache", "yes")
        mpv_set_property_string(mpv, "sub-ass-override", "no")
        
        mpv_set_property_string(mpv, "cache", "yes")
        mpv_set_property_string(mpv, "cache-pause-initial", "no")          // Start playback immediately on first decodable keyframe
        mpv_set_property_string(mpv, "cache-pause-wait", "3.0")            // Tolerate 3.0s cushion before re-pausing on stalls
        mpv_set_property_string(mpv, "cache-secs", "60")                   // 60-second forward buffer target
        mpv_set_property_string(mpv, "demuxer-max-bytes", "157286400")      // 150 MB demuxer buffer
        mpv_set_property_string(mpv, "demuxer-max-back-bytes", "31457280") // 30 MB backward seek buffer
        mpv_set_property_string(mpv, "demuxer-readahead-secs", "12")       // 12s background lookahead
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
        mpv_set_property_string(mpv, "slang", getIsoCode(subLang))
        
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
    
    func loadFile(_ url: URL) {
        print("[MPV] loadFile called: \(url.absoluteString)")
        if mpvGL == nil {
            print("[MPV] Deferring loadFile until render context is initialized: \(url.lastPathComponent)")
            pendingURL = url
        } else {
            pendingURL = nil
            print("[MPV] Executing loadfile command for: \(url.lastPathComponent)")
            command("loadfile", url.absoluteString)
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
        var doubleVal = value * 100
        mpv_set_property(mpv, "volume", MPV_FORMAT_DOUBLE, &doubleVal)
    }
    
    func getVolume() -> Double {
        var vol: Double = 0
        guard mpv != nil else { return 0 }
        mpv_get_property(mpv, "volume", MPV_FORMAT_DOUBLE, &vol)
        return vol
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
    
    func selectTrack(_ track: Track) {
        guard mpv != nil else { return }
        let propertyName = track.type == "audio" ? "aid" : "sid"
        mpv_set_property_string(mpv, propertyName, "\(track.id)")
    }
    
    func addExternalSubtitle(url: String, title: String) {
        command("sub-add", url, "select", title)
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
    private func getPropertyDouble(_ name: String) -> Double? {
        guard mpv != nil else { return nil }
        var value: Double = 0
        if mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &value) >= 0 { return value }
        return nil
    }
    
    private func getPropertyString(_ name: String) -> String? {
        guard mpv != nil else { return nil }
        guard let cString = mpv_get_property_string(mpv, name) else { return nil }
        let str = String(cString: cString)
        mpv_free(cString)
        return str
    }
    
    private func getPropertyInt(_ name: String) -> Int? {
        guard mpv != nil else { return nil }
        var value: Int64 = 0
        if mpv_get_property(mpv, name, MPV_FORMAT_INT64, &value) >= 0 { return Int(value) }
        return nil
    }
    
    private func getPropertyBool(_ name: String) -> Bool? {
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
                    if reason == MPV_END_FILE_REASON_ERROR {
                        print("[MPV] Error: End File Reason ERROR (code: \(error))")
                        DispatchQueue.main.async { self.onPlaybackError?() }
                    }
                case MPV_EVENT_FILE_LOADED:
                    print("[MPV EVENT] FILE_LOADED")
                case MPV_EVENT_LOG_MESSAGE:
                    let logMsg = event.pointee.data.assumingMemoryBound(to: mpv_event_log_message.self)
                    let prefix = String(cString: logMsg.pointee.prefix)
                    let text = String(cString: logMsg.pointee.text)
                    print("[MPV LOG] \(prefix): \(text)")
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
