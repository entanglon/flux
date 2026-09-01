import AppKit
import Combine
import SwiftUI

/// Routes `openWindow` calls out of SwiftUI-land (captured in ContentView) so
/// PiPManager can reopen the player window when expanding.
enum PlayerWindowRouter {
    static var openPlayer: ((MediaItem.ID) -> Void)?
}

// MARK: - PiPManager

/// Picture-in-Picture: a floating always-on-top mini window that owns playback
/// while active (Cascade architecture, user-confirmed contract):
///
/// Entering PiP ADOPTS the live mpv core and CLOSES the player window — the
/// panel is where playback lives now. Two teardown hazards are handled
/// explicitly:
///   1. The player view's dismantle would normally destroy the mpv core —
///      `MPVVideoView.dismantleNSViewController` skips cleanup while this
///      manager hosts the layer (see `isHosting`).
///   2. PlayerView disappears with the window, killing its @StateObject
///      MPVController — this manager RETAINS layer + controller + view
///      controller, so commands keep routing while floating.
///
/// While floating, this manager also takes over the player-window duties:
/// stream-failure fallback, next-episode URL switching, smart preload and
/// auto-advance at end of file.
///
/// Expand tears the floating core down cleanly and reopens the player window,
/// resuming exactly at the floating position (`PlayerManager.pendingResumeTime`).
/// Closing the panel saves progress and stops playback entirely.
///
/// All public methods must be called on the main thread.
final class PiPManager: ObservableObject {
    static let shared = PiPManager()

    @Published private(set) var isActive = false

    // Mirrored state for the mini overlay (source: retained MPVController)
    @Published private(set) var miniIsPlaying = false
    @Published private(set) var miniProgress: Double = 0
    @Published private(set) var miniTitle = "Flux"

    // Retained on purpose — see class docs (MPVController.playerView is weak).
    private(set) var hostedLayer: MPVLayerView?
    private(set) var hostedViewController: MPVViewController?
    private var mpvController: MPVController?

    private var panel: NSPanel?
    private var willCloseObserver: NSObjectProtocol?
    private var takeoverCancellables = Set<AnyCancellable>()
    private var overlayCancellables = Set<AnyCancellable>()
    private var autoAdvanceTimer: Timer?
    /// True while the player window is being closed as part of the handoff —
    /// PlayerView.onDisappear checks this so it neither saves progress nor
    /// stops mpv during adoption.
    private(set) var isHandingOffCore = false
    private var lastFrame: NSRect?

    private init() {}

    /// Dismantle-guard: is this exact render layer currently floating in PiP?
    func isHosting(_ layer: MPVLayerView?) -> Bool {
        guard isActive else { return false }
        return hostedLayer != nil && hostedLayer === layer
    }

    // MARK: Enter (from the player's PIP button)

    func toggle(mpv: MPVController) {
        print("[PiP] toggle requested (isActive=\(isActive))")
        guard !isActive else { return }
        enter(mpv: mpv)
    }

    private func enter(mpv: MPVController) {
        guard !isActive else { return }
        guard PlayerManager.shared.currentStreamURL != nil else {
            print("[PiP] BAIL: no currentStreamURL")
            return
        }
        guard let vc = mpv.playerView else {
            print("[PiP] BAIL: mpv.playerView is nil")
            return
        }
        guard let layer = vc.playerView, let playerWin = layer.window, layer.superview != nil else {
            print("[PiP] BAIL: layer=\(String(describing: vc.playerView)), window=\(String(describing: vc.playerView?.window))")
            return
        }

        // Adopt the core BEFORE anything can tear it down.
        hostedLayer = layer
        hostedViewController = vc
        mpvController = mpv

        let size = panelSize(aspect: vc.videoAspectRatio)
        let content = PiPPanelContentView(frame: NSRect(origin: .zero, size: size))

        let pip = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        pip.title = displayTitle
        miniTitle = displayTitle
        pip.titleVisibility = .hidden
        pip.titlebarAppearsTransparent = true
        pip.level = .floating
        pip.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        pip.isMovableByWindowBackground = true
        pip.isReleasedWhenClosed = false
        pip.hidesOnDeactivate = false
        pip.backgroundColor = .black
        pip.contentView = content

        // Traffic-light close routes through the same exit path as everything else.
        willCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: pip, queue: .main
        ) { [weak self] _ in
            self?.stopPlayback()
        }

        content.install(videoLayer: layer)

        // Bottom-right of the display the player was on (or where the user left it).
        let target = clampToScreen(frameForPanel(size: size, on: playerWin.screen))
        pip.setFrameOrigin(target.origin)

        isActive = true
        panel = pip
        takeOverPlaybackDuties(mpv)

        pip.makeKeyAndOrderFront(nil)
        print("[PiP] Adopted mpv core (\(Int(target.width))×\(Int(target.height))) — closing player window")

        // Close the theater: the panel is where playback lives now. The flag
        // makes PlayerView.onDisappear a no-op during this handoff.
        isHandingOffCore = true
        DispatchQueue.main.async { [weak self] in
            playerWin.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.isHandingOffCore = false
            }
        }
    }

    // MARK: Exit paths

    /// Hover/expand action: stop the floating core and reopen the player
    /// window, resuming at the exact floating position.
    func expandToPlayer() {
        guard isActive else { return }
        let pos = mpvController?.timePos ?? 0
        let itemID = PlayerManager.shared.currentItem?.id
        // Save progress — expanding continues the same content.
        performFullStop(saveProgress: true)
        if pos > 0.5 {
            PlayerManager.shared.pendingResumeTime = pos
        }
        if pos > 0.5 {
            PlayerManager.shared.pendingResumeTime = pos
        }
        if let itemID {
            print("[PiP] Expanding to player at \(Int(pos))s")
            PlayerWindowRouter.openPlayer?(itemID)
        } else {
            PlayerManager.shared.close()
        }
    }

    /// Panel close (X / traffic light): save progress, stop everything.
    func stopPlayback() {
        guard isActive else { return }
        performFullStop(saveProgress: true)
        PlayerManager.shared.close()
        print("[PiP] Stopped playback from mini player")
    }

    /// Called at the top of PlayerManager.play() for USER-initiated playback.
    ///   - Same item/season/episode floating here → EXPAND semantics: tear the
    ///     core down and return its position to resume at.
    ///   - Anything else floating → save its progress and tear down first.
    /// Returns the resume position (nil = start fresh / nothing was floating).
    func interceptPlaybackRequest(item: MediaItem, season: Int?, episode: Int?) -> Double? {
        guard isActive else { return nil }
        let manager = PlayerManager.shared
        let sameTitle = manager.currentItem?.id == item.id
            && manager.currentSeason == season
            && manager.currentEpisode == episode
        let pos = mpvController?.timePos ?? 0

        if sameTitle {
            print("[PiP] Re-opening the floating title — expanding with resume at \(Int(pos))s")
            performFullStop(saveProgress: false)
            return pos > 0.5 ? pos : nil
        }
        print("[PiP] New title requested — tearing down floating session")
        performFullStop(saveProgress: true)
        return nil
    }

    // MARK: Duties taken over from PlayerView

    private func takeOverPlaybackDuties(_ mpv: MPVController) {
        // Dead source mid-PiP → auto-fallback keeps working headless.
        mpv.onPlaybackError = { [weak self] in
            guard let self, self.isActive else { return }
            print("[PiP] Playback error in mini player — trying next source")
            PlayerManager.shared.tryNextStream()
        }

        let manager = PlayerManager.shared
        manager.$currentStreamURL
            .dropFirst() // CRITICAL: Combine replays the current value — the
                         // file is ALREADY playing in the adopted core; only
                         // react to genuine switches (fallback / next episode).
            .receive(on: RunLoop.main)
            .sink { [weak self] url in
                guard let self, self.isActive, let url else { return }
                print("[PiP] Stream switched under the panel — playing new URL")
                self.mpvController?.play(url: url)
                self.miniTitle = self.displayTitle
            }
            .store(in: &takeoverCancellables)

        // Auto-advance at end of file + smart preload of the next episode.
        autoAdvanceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.isActive, let m = self.mpvController else { return }
            if m.progress > 0.9 {
                manager.preloadNextEpisodeIfNeeded()
            }
            let autoPlayEnabled = UserDefaults.standard.object(forKey: "autoPlayNextEnabled") as? Bool ?? true
            if autoPlayEnabled,
               manager.nextEpisodeInfo != nil,
               m.duration > 0, m.timePos > 0.5,
               (m.duration - m.timePos) <= 1.0 {
                manager.playNextEpisode() // play(isAutoAdvance:) → same core keeps floating
            }
        }

        mpv.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] isPlaying in
                self?.miniIsPlaying = isPlaying
                if isPlaying {
                    SleepAssertionManager.shared.enableSleepPrevention(reason: "Flux PiP Video Playback")
                } else {
                    SleepAssertionManager.shared.disableSleepPrevention()
                }
            }
            .store(in: &overlayCancellables)
        mpv.$progress
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.miniProgress = $0 }
            .store(in: &overlayCancellables)
    }

    func togglePlayPause() {
        mpvController?.togglePlayPause()
    }

    private var displayTitle: String {
        let manager = PlayerManager.shared
        guard let item = manager.currentItem else { return "Flux" }
        if let s = manager.currentSeason, let e = manager.currentEpisode {
            return "\(item.title) — S\(s):E\(e)"
        }
        return item.title
    }

    // MARK: Teardown

    private func performFullStop(saveProgress: Bool) {
        SleepAssertionManager.shared.disableSleepPrevention()
        if saveProgress, let m = mpvController, m.duration > 0 {
            PlayerManager.shared.updateWatchProgress(time: m.timePos, duration: m.duration)
        }
        // Stop duties FIRST so no subscription fires into a dying core.
        takeoverCancellables.removeAll()
        overlayCancellables.removeAll()
        autoAdvanceTimer?.invalidate()
        autoAdvanceTimer = nil
        mpvController?.onPlaybackError = nil

        let layer = hostedLayer
        hostedLayer = nil
        hostedViewController = nil
        mpvController = nil

        if let observer = willCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            willCloseObserver = nil
        }
        if let panel = panel {
            lastFrame = panel.frame
            panel.orderOut(nil)
        }
        panel = nil
        isActive = false

        // Destroy the orphaned core with its layer.
        layer?.cleanup()
    }

    // MARK: Geometry

    private func panelSize(aspect: Double) -> NSSize {
        let safeAspect = aspect > 0.2 && aspect < 4 ? CGFloat(aspect) : 16 / 9
        var width: CGFloat = 400
        var height = width / safeAspect
        let maxHeight: CGFloat = 300
        if height > maxHeight {
            height = maxHeight
            width = height * safeAspect
        }
        return NSSize(width: width.rounded(), height: height.rounded())
    }

    private func frameForPanel(size: NSSize, on screen: NSScreen?) -> NSRect {
        if let previous = lastFrame {
            return NSRect(origin: previous.origin, size: size)
        }
        let visible = screen?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: visible.maxX - size.width - 24, y: visible.minY + 20)
        return NSRect(origin: origin, size: size)
    }

    private func clampToScreen(_ rect: NSRect) -> NSRect {
        guard let visible = NSScreen.screens.first(where: { NSPointInRect(rect.origin, $0.visibleFrame) })?.visibleFrame
                ?? NSScreen.main?.visibleFrame else { return rect }
        var r = rect
        r.origin.x = min(max(visible.minX + 8, r.origin.x), max(visible.minX + 8, visible.maxX - r.width - 8))
        r.origin.y = min(max(visible.minY + 8, r.origin.y), max(visible.minY + 8, visible.maxY - r.height - 8))
        return r
    }
}

// MARK: - Panel content

/// The adopted render view plus a Cascade-style control strip revealed on hover:
/// play/pause · title · progress line · expand back to the full player.
final class PiPPanelContentView: NSView {
    private let controlsHost: NSHostingView<PiPControlsOverlay>

    override init(frame frameRect: NSRect) {
        controlsHost = NSHostingView(rootView: PiPControlsOverlay())
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.isOpaque = true

        controlsHost.isHidden = true
        controlsHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controlsHost)
        NSLayoutConstraint.activate([
            controlsHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            controlsHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            controlsHost.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    required init?(coder: NSCoder) { fatalError("PiPPanelContentView is code-only") }

    /// Reparents the LIVE mpv render layer into the panel — playback continues
    /// untouched; mpv never learns about superview changes.
    func install(videoLayer layer: NSView) {
        layer.removeFromSuperview()
        layer.frame = bounds
        layer.autoresizingMask = [.width, .height]
        addSubview(layer, positioned: .below, relativeTo: controlsHost)
        needsLayout = true
        print("[PiP] Reparented live layer \(layer.bounds.size) → panel \(bounds.size)")
    }

    override func mouseEntered(with event: NSEvent) { controlsHost.isHidden = false }
    override func mouseExited(with event: NSEvent) { controlsHost.isHidden = true }
}

// MARK: - Mini control strip

struct PiPControlsOverlay: View {
    @ObservedObject private var pip = PiPManager.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: { PiPManager.shared.togglePlayPause() }) {
                    Image(systemName: pip.miniIsPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(pip.miniIsPlaying ? "Pause" : "Play")

                Text(pip.miniTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .shadow(radius: 2)

                Spacer(minLength: 0)

                Button(action: { PiPManager.shared.expandToPlayer() }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Back to Flux")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .bottom, endPoint: .top)
                    .ignoresSafeArea()
            )

            // Thin live progress line along the very bottom edge.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.25))
                    Rectangle().fill(.white.opacity(0.9))
                        .frame(width: geo.size.width * CGFloat(pip.miniProgress))
                }
            }
            .frame(height: 2)
        }
    }
}
