import SwiftUI
import AppKit
import OpenGL.GL
import MPVKit
import Combine

// MARK: - SwiftUI View
struct MPVVideoView: NSViewControllerRepresentable {
    @ObservedObject var controller: MPVController
    
    func makeNSViewController(context: Context) -> MPVViewController {
        let mpv = MPVViewController()
        context.coordinator.player = mpv
        controller.playerView = mpv // Link controller to view
        mpv.delegate = controller // Link view to controller
        return mpv
    }
    
    func updateNSViewController(_ nsViewController: MPVViewController, context: Context) {
        // Updates handled via controller
    }
    
    static func dismantleNSViewController(_ nsViewController: MPVViewController, coordinator: Coordinator) {
        nsViewController.glView.cleanup()
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
}

// MARK: - Controller
class MPVController: ObservableObject {
    @Published var isPlaying = false
    @Published var progress: Double = 0.0
    @Published var duration: Double = 0.0
    @Published var timePos: Double = 0.0
    @Published var volume: Double = 1.0
    
    @Published var audioTracks: [Track] = []
    @Published var subtitleTracks: [Track] = []
    
    // Settings
    @AppStorage("useHardwareAcceleration") private var useHardwareAcceleration = true
    
    var onPlaybackError: (() -> Void)?
    weak var playerView: MPVViewController?
    
    func play(url: URL) {
        playerView?.play(url)
    }
    
    func play() {
        playerView?.resume()
    }
    
    func pause() {
        playerView?.pause()
    }
    
    func stop() {
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
    
    func setVolume(_ value: Double) {
        playerView?.setVolume(value)
        volume = value
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
                }
            case "pause":
                if let paused = value as? Bool {
                    self.isPlaying = !paused
                }
            case "volume":
                if let vol = value as? Double {
                    self.volume = vol / 100.0
                }
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
    var glView: MPVOGLView!
    weak var delegate: MPVController?
    
    override func loadView() {
        self.view = NSView(frame: .init(x: 0, y: 0, width: 1280, height: 720))
        self.glView = MPVOGLView(frame: self.view.bounds)
        self.glView.autoresizingMask = [.width, .height]
        self.view.addSubview(glView)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.glView.setupContext()
        self.glView.setupMpv()
        
        self.glView.onPropertyChange = { [weak self] name, value in
            self?.delegate?.handlePropertyChange(name: name, value: value)
        }
        
        self.glView.onPlaybackError = { [weak self] in
             print("[MPV] Playback error detected")
             DispatchQueue.main.async {
                 self?.delegate?.onPlaybackError?()
             }
        }
        
        let vol = self.glView.getVolume()
        DispatchQueue.main.async {
            self.delegate?.volume = vol / 100.0
        }
    }
    
    func play(_ url: URL) { glView.loadFile(url) }
    func pause() { glView.setPause(true) }
    func resume() { glView.setPause(false) }
    func stop() { glView.stop() }
    
    func seek(absolute seconds: Double) { glView.seek(absoluteSeconds: seconds) }
    func seek(relative seconds: Double) { glView.seek(relativeSeconds: seconds) }
    
    func setVolume(_ value: Double) { glView.setVolume(value) }
    func getTracks() -> [Track] { return glView.getTracks() }
    func selectTrack(_ track: Track) { glView.selectTrack(track) }
    func addExternalSubtitle(url: String, title: String) { glView.addExternalSubtitle(url: url, title: title) }
}

// MARK: - OpenGL View & MPV Backend
final class MPVOGLView: NSOpenGLView {
    var mpv: OpaquePointer!
    var mpvGL: OpaquePointer!
    var queue = DispatchQueue(label: "mpv", qos: .userInteractive)
    var onPropertyChange: ((String, Any) -> Void)?
    var onPlaybackError: (() -> Void)?
    
    override class func defaultPixelFormat() -> NSOpenGLPixelFormat {
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAOpenGLProfile),
            NSOpenGLPixelFormatAttribute(NSOpenGLProfileVersion4_1Core),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFADoubleBuffer),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAColorSize), NSOpenGLPixelFormatAttribute(32),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFADepthSize), NSOpenGLPixelFormatAttribute(24),
            NSOpenGLPixelFormatAttribute(0)
        ]
        return NSOpenGLPixelFormat(attributes: attributes)!
    }
    
    override func reshape() {
        super.reshape()
        renderFrame()
    }
    
    override func draw(_ dirtyRect: NSRect) {
        renderFrame()
    }
    
    func setupContext() {
        self.openGLContext = NSOpenGLContext(format: MPVOGLView.defaultPixelFormat(), share: nil)
        self.openGLContext?.view = self
        self.openGLContext?.makeCurrentContext()
    }
    
    func setupMpv() {
        mpv = mpv_create()
        if mpv == nil { return }
        
        // 1. VO Setting
        mpv_set_option_string(mpv, "vo", "libmpv")
        
        // 2. High Quality Profile (Balanced)
        // 'gpu-hq' is high quality but efficient enough for most modern Macs.
        mpv_set_option_string(mpv, "profile", "gpu-hq")
        
        // REMOVED 'ewa_lanczossharp' as it causes lag on some systems.
        // mpv_set_option_string(mpv, "scale", "ewa_lanczossharp")
        // mpv_set_option_string(mpv, "cscale", "ewa_lanczossharp")
        
        // 3. HW Acceleration
        // 'auto-safe' allows MPV to choose best method (usually videotoolbox on macOS)
        let hwdec = UserDefaults.standard.bool(forKey: "useHardwareAcceleration") ? "auto-safe" : "no"
        mpv_set_option_string(mpv, "hwdec", hwdec)
        
        // 4. Cache & Streaming Optimization
        mpv_set_option_string(mpv, "cache", "yes")
        mpv_set_option_string(mpv, "demuxer-max-bytes", "256MiB")
        mpv_set_option_string(mpv, "demuxer-readahead-secs", "20")
        
        // 5. User-Agent & Referrer
        mpv_set_option_string(mpv, "user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
        mpv_set_option_string(mpv, "referrer", "https://flux.app/")
        
        // 6. Subtitle Styling (Premium scaling)
        mpv_set_option_string(mpv, "sub-font-size", "45") // Balanced size for desktop/TV
        mpv_set_option_string(mpv, "sub-border-size", "2") // Cleaner outlines
        mpv_set_option_string(mpv, "sub-margin-y", "40") // Slightly off the bottom edge
        
        // 7. Terminal/Log Output
        mpv_set_option_string(mpv, "terminal", "yes")
        
        // 7. Language Preferences
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
        
        mpv_set_option_string(mpv, "alang", getIsoCode(audioLang))
        mpv_set_option_string(mpv, "slang", getIsoCode(subLang))
        
        // Observe properties
        mpv_observe_property(mpv, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "volume", MPV_FORMAT_DOUBLE)
        
        if mpv_initialize(mpv) < 0 {
            print("mpv init failed")
            return
        }
        
        setupGL()
        
        mpv_set_wakeup_callback(self.mpv, mpvWakeUp, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
    }
    
    func setupGL() {
        let getProcAddress: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? = { _, name in
            guard let name = name else { return nil }
            let symbolName = CFStringCreateWithCString(kCFAllocatorDefault, name, CFStringBuiltInEncodings.ASCII.rawValue)
            let identifier = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
            return CFBundleGetFunctionPointerForName(identifier, symbolName)
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
                mpv_render_context_create(&mpvGL, mpv, &params)
            }
        }
        
        mpv_render_context_set_update_callback(mpvGL, mpvGLUpdate, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
    }
    
    func loadFile(_ url: URL) {
        command("loadfile", url.absoluteString)
    }
    
    func setPause(_ paused: Bool) {
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
                let title = getPropertyString("track-list/\(i)/title") ?? "Unknown"
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
        let propertyName = track.type == "audio" ? "aid" : "sid"
        mpv_set_option_string(mpv, propertyName, "\(track.id)")
    }
    
    func addExternalSubtitle(url: String, title: String) {
        command("sub-add", url, "select", title)
    }
    
    private func command(_ args: String...) {
        withCStrings(args) { cArgs in
            var mutableArgs = cArgs
            mutableArgs.withUnsafeMutableBufferPointer { buffer in
                _ = mpv_command(mpv, buffer.baseAddress)
            }
        }
    }
    
    // Helpers
    private func getPropertyString(_ name: String) -> String? {
        guard let cString = mpv_get_property_string(mpv, name) else { return nil }
        let str = String(cString: cString)
        mpv_free(cString)
        return str
    }
    
    private func getPropertyInt(_ name: String) -> Int? {
        var value: Int64 = 0
        if mpv_get_property(mpv, name, MPV_FORMAT_INT64, &value) >= 0 { return Int(value) }
        return nil
    }
    
    private func getPropertyBool(_ name: String) -> Bool? {
        var value: Int32 = 0
        if mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &value) >= 0 { return value != 0 }
        return nil
    }

    func readEvents() {
        queue.async {
            while self.mpv != nil {
                guard let event = mpv_wait_event(self.mpv, 0), event.pointee.event_id != MPV_EVENT_NONE else { break }
                
                if event.pointee.event_id == MPV_EVENT_PROPERTY_CHANGE {
                    let prop = event.pointee.data.assumingMemoryBound(to: mpv_event_property.self)
                    let name = String(cString: prop.pointee.name)
                    
                    if prop.pointee.format == MPV_FORMAT_DOUBLE {
                        let value = prop.pointee.data.assumingMemoryBound(to: Double.self).pointee
                        self.onPropertyChange?(name, value)
                    } else if prop.pointee.format == MPV_FORMAT_FLAG {
                        let value = prop.pointee.data.assumingMemoryBound(to: Int32.self).pointee != 0
                        self.onPropertyChange?(name, value)
                    }
                } else if event.pointee.event_id == MPV_EVENT_END_FILE {
                      let endFile = event.pointee.data.assumingMemoryBound(to: mpv_event_end_file.self)
                      // Detect error or initialization failure
                      if endFile.pointee.reason == MPV_END_FILE_REASON_ERROR {
                          print("[MPV] Error: End File Reason ERROR")
                          self.onPlaybackError?()
                      }
                }
            }
        }
    }
    
    func renderFrame() {
        guard let ctx = self.openGLContext, mpvGL != nil else { return }
        ctx.makeCurrentContext()
        let backingRect = self.convertToBacking(self.bounds)
        glViewport(0, 0, GLsizei(backingRect.width), GLsizei(backingRect.height))
        var flipY: Int32 = 1
        var fbo = mpv_opengl_fbo(fbo: 0, w: Int32(backingRect.width), h: Int32(backingRect.height), internal_format: 0)
        
        withUnsafeMutablePointer(to: &fbo) { fboPtr in
            withUnsafeMutablePointer(to: &flipY) { flipPtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fboPtr),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipPtr),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                mpv_render_context_render(mpvGL, &params)
            }
        }
        ctx.flushBuffer()
    }
    
    func cleanup() {
        if mpvGL != nil { mpv_render_context_free(mpvGL); mpvGL = nil }
        if mpv != nil { mpv_terminate_destroy(mpv); mpv = nil }
    }
    
    deinit { cleanup() }
    
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

func mpvGLUpdate(_ ctx: UnsafeMutableRawPointer?) {
    let glView = unsafeBitCast(ctx, to: MPVOGLView.self)
    DispatchQueue.main.async { glView.renderFrame() }
}

func mpvWakeUp(_ ctx: UnsafeMutableRawPointer?) {
    let glView = unsafeBitCast(ctx, to: MPVOGLView.self)
    glView.readEvents()
}
