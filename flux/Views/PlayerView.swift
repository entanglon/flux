import SwiftUI
import Combine
import AppKit

struct PlayerView: View {
    // Acquired at init: adopts the detail-page prefetch's warm mpv core when
    // one matches this title (already buffering → instant start), else fresh.
    @ObservedObject private var mpv: MPVController
    @ObservedObject private var playerManager = PlayerManager.shared
    @State private var showExitWarning = false
    @State private var isControlsVisible = true
    @State private var animatedProgress: Double = 0.0
    @State private var pulseScale: CGFloat = 0.96
    @AppStorage("autoPlayNextEnabled") private var autoPlayNextEnabled = true
    @State private var autoPlayCancelled = false
    @State private var hasStartedPlayback = false
    @State private var lastProgressSaveTime: Date = .distantPast
    @State private var showManualStreamPicker = false
    @State private var hostWindow: NSWindow?
    @State private var contextMenuMonitor: PlayerContextMenuMonitor?
    @Environment(\.dismiss) private var dismiss // Add dismiss environment
    var item: MediaItem? // Optional item to play

    init(item: MediaItem?) {
        self.item = item
        // Idempotent: re-inits (any PlayerManager @Published change rebuilds the
        // root) always hand back the SAME session controller.
        _mpv = ObservedObject(wrappedValue: PlayerManager.shared.beginSession())
    }

    private let loadingTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // 1. Video Layer
            MPVVideoView(controller: mpv)
                .ignoresSafeArea()
            
            // 2. Initial Buffer Loading Screen (Cold start: full artwork + animated logo fill, only AFTER stream selected & BEFORE playback starts)
            if isInitialLoading && playerManager.currentStreamURL != nil {
                logoBufferingView
                    .transition(.opacity)
                    .zIndex(10)
            }
            
            // 3. Mid-Playback Buffering (Logo buffer bar over the paused video frame)
            if isMidPlaybackBuffering {
                midPlaybackLogoBufferingView
            }
            
            // 4. Controls Layer (Only active once playback has started)
            controlsLayer
            
            // 5. Exit Warning Overlay
            exitWarningOverlay

            // 6. Smart Skip Intro / Skip Recap / Next Episode
            skipActionOverlay
        }
        .background(
            PlayerWindowAccessor { window in
                if self.hostWindow !== window {
                    self.hostWindow = window
                    self.setupContextMenuMonitor(for: window)
                }
            }
        )
        .focusable() // Make the view capable of receiving key presses
        .focusEffectDisabled() // Remove the blue focus ring
        .onKeyPress(.space) {
            withAnimation(.easeInOut(duration: 0.2)) { isControlsVisible = true }
            if mpv.timePos >= 0.5 {
                mpv.togglePlayPause()
            }
            return .handled
        }
        .onKeyPress(.escape) {
            if showExitWarning {
                playerManager.close()
                dismiss() // Dismiss the window
            } else {
                withAnimation {
                    showExitWarning = true
                }
                // Reset warning after 2 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation {
                        showExitWarning = false
                    }
                }
            }
            return .handled
        }
        .onKeyPress(.leftArrow) {
            handleRelativeSeek(delta: -10)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            handleRelativeSeek(delta: 10)
            return .handled
        }
        .onKeyPress(KeyEquivalent(",")) {
            handleRelativeSeek(delta: -10)
            return .handled
        }
        .onKeyPress(KeyEquivalent(".")) {
            handleRelativeSeek(delta: 10)
            return .handled
        }
        .onKeyPress(KeyEquivalent("<")) {
            handleRelativeSeek(delta: -10)
            return .handled
        }
        .onKeyPress(KeyEquivalent(">")) {
            handleRelativeSeek(delta: 10)
            return .handled
        }
        .onKeyPress(.upArrow) {
            withAnimation(.easeInOut(duration: 0.2)) { isControlsVisible = true }
            mpv.setVolume(min(mpv.volume + 0.05, 1.0))
            return .handled
        }
        .onKeyPress(.downArrow) {
            withAnimation(.easeInOut(duration: 0.2)) { isControlsVisible = true }
            mpv.setVolume(max(mpv.volume - 0.1, 0.0))
            return .handled
        }
        .onKeyPress(KeyEquivalent("m")) {
            withAnimation(.easeInOut(duration: 0.2)) { isControlsVisible = true }
            mpv.toggleMute()
            return .handled
        }
        .onKeyPress(KeyEquivalent("c")) {
            withAnimation(.easeInOut(duration: 0.2)) {
                isControlsVisible.toggle()
            }
            return .handled
        }
        .onKeyPress(KeyEquivalent("f")) {
            toggleFullScreen()
            return .handled
        }
        .onAppear {
            mpv.onPlaybackError = {
                print("[PlayerView] MPV playback error detected. Triggering auto-fallback to next stream...")
                playerManager.tryNextStream()
            }
            if mpv.hasLoadedMedia {
                print("PlayerView: adopting warm core, releasing hold...")
                mpv.play()
                animatedProgress = 1.0
                hasStartedPlayback = true
                SleepAssertionManager.shared.enableSleepPrevention()
            } else if let url = playerManager.currentStreamURL {
                // If URL is already present (Instant Replay), start playing
                print("PlayerView: onAppear found url, playing...")
                mpv.play(url: url)
            }
        }
        .onDisappear {
            contextMenuMonitor?.stop()
            contextMenuMonitor = nil
            // Entering PiP closes this window as a deliberate handoff — the
            // floating panel owns the core now. Saving progress or stopping
            // mpv here would kill playback mid-handoff.
            guard !PiPManager.shared.isHandingOffCore else { return }
            SleepAssertionManager.shared.disableSleepPrevention()
            playerManager.updateWatchProgress(time: mpv.timePos, duration: mpv.duration)
            mpv.pause()
            mpv.stop()
            playerManager.close()
        }
        .onChange(of: playerManager.currentStreamURL) { _, newURL in
            if let url = newURL {
                print("PlayerView: URL changed to \(url), playing...")
                // Reset buffering progress + auto-play cancellation for the new stream
                animatedProgress = 0.0
                autoPlayCancelled = false
                hasStartedPlayback = false
                mpv.play(url: url)
            }
        }
        .onChange(of: mpv.timePos) { _, t in
            handleTimePosChange(t)
        }
        .onChange(of: mpv.isPlaying) { _, isPlaying in
            handleIsPlayingChange(isPlaying)
        }
        .onChange(of: mpv.isSeeking) { wasSeeking, isSeeking in
            handleSeekEnd(wasSeeking: wasSeeking, isSeeking: isSeeking)
        }
        .onChange(of: mpv.duration) { _, dur in
            handleDurationChange(dur)
        }
        .onChange(of: mpv.progress) { _, newProgress in
             if newProgress > 0.9 {
                 playerManager.preloadNextEpisodeIfNeeded()
             }
        }
        .overlay {
            overlayContent
        }
    }
    
    private func handleTimePosChange(_ t: Double) {
        if t > 0.05 && !hasStartedPlayback {
            withAnimation(.easeOut(duration: 0.2)) {
                hasStartedPlayback = true
                animatedProgress = 1.0
            }
            if mpv.isPlaying {
                SleepAssertionManager.shared.enableSleepPrevention()
            }
        }
        // Continuous autosave during playback
        if hasStartedPlayback && mpv.duration > 0 && Date().timeIntervalSince(lastProgressSaveTime) >= 5.0 {
            lastProgressSaveTime = Date()
            playerManager.updateWatchProgress(time: t, duration: mpv.duration)
        }

        // Automatically preload next episode when reaching the final stretch (> 80% progress or < 2 min remaining)
        if hasStartedPlayback && mpv.duration > 60 && (mpv.progress > 0.80 || (mpv.duration - t) <= 120) {
            playerManager.preloadNextEpisodeIfNeeded()
        }

        guard let resume = playerManager.pendingResumeTime else { return }
        guard t > 0.1 || mpv.duration > 0 else { return }
        playerManager.pendingResumeTime = nil
        if abs(t - resume) > 1.5 {
            print("PlayerView: resuming playback at \(Int(resume))s")
            mpv.seek(absolute: resume)
        }
    }

    private func handleIsPlayingChange(_ isPlaying: Bool) {
        if isPlaying && hasStartedPlayback {
            SleepAssertionManager.shared.enableSleepPrevention()
        } else {
            SleepAssertionManager.shared.disableSleepPrevention()
        }
        if !isPlaying && hasStartedPlayback && mpv.duration > 0 {
            lastProgressSaveTime = Date()
            playerManager.updateWatchProgress(time: mpv.timePos, duration: mpv.duration)
        }
    }

    private func handleSeekEnd(wasSeeking: Bool, isSeeking: Bool) {
        if wasSeeking && !isSeeking && hasStartedPlayback && mpv.duration > 0 {
            lastProgressSaveTime = Date()
            playerManager.updateWatchProgress(time: mpv.timePos, duration: mpv.duration)
        }
    }

    private func handleDurationChange(_ dur: Double) {
        guard dur > 0, let resume = playerManager.pendingResumeTime else { return }
        playerManager.pendingResumeTime = nil
        if abs(mpv.timePos - resume) > 1.5 {
            print("PlayerView: duration received, seeking to resume position: \(Int(resume))s")
            mpv.seek(absolute: resume)
        }
    }

    private func handleRelativeSeek(delta: Double) {
        let targetTime = delta < 0 ? max(0, mpv.timePos + delta) : min(mpv.duration, mpv.timePos + delta)
        mpv.seek(relative: delta)
        if mpv.duration > 0 {
            lastProgressSaveTime = Date()
            playerManager.updateWatchProgress(time: targetTime, duration: mpv.duration)
        }
    }

    private func handleAbsoluteSeek(time: Double) {
        mpv.seek(absolute: time)
        if mpv.duration > 0 {
            lastProgressSaveTime = Date()
            playerManager.updateWatchProgress(time: time, duration: mpv.duration)
        }
    }

    private func toggleFullScreen() {
        if let window = hostWindow ?? NSApp.keyWindow {
            window.toggleFullScreen(nil)
        }
    }

    @ViewBuilder
    private func skipActionButton(for action: SkipActionType) -> some View {
        switch action {
        case .recap(let targetTime):
            Button {
                handleAbsoluteSeek(time: targetTime)
            } label: {
                Text("Skip Recap")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
            .transition(.opacity)
            
        case .intro(let targetTime):
            Button {
                handleAbsoluteSeek(time: targetTime)
            } label: {
                Text("Skip Intro")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
            .transition(.opacity)
            
        case .nextEpisode(let season, let episode):
            Button {
                playerManager.playNextEpisode()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 13, weight: .bold))
                    Text("Next: S\(season) E\(episode)")
                        .font(.system(size: 14, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var controlsLayer: some View {
        if hasStartedPlayback {
            PlayerControlsView(
                isPlaying: $mpv.isPlaying,
                progress: Binding(
                    get: { mpv.progress },
                    set: { 
                        let targetTime = $0 * mpv.duration
                        handleAbsoluteSeek(time: targetTime)
                        if $0 > 0.9 {
                            playerManager.preloadNextEpisodeIfNeeded()
                        }
                    }
                ),
                currentTime: $mpv.timePos,
                duration: $mpv.duration,
                volume: Binding(
                    get: { mpv.volume },
                    set: { mpv.setVolume($0) }
                ),
                isControlsVisible: $isControlsVisible,
                title: item?.title ?? "Unknown Title",
                subtitle: getSubtitle(),
                onPlayPause: { mpv.togglePlayPause() },
                onSkipForward: { handleRelativeSeek(delta: 15) }, 
                onSkipBackward: { handleRelativeSeek(delta: -15) },
                onClose: {
                    playerManager.close()
                    dismiss()
                },
                onTogglePiP: {
                    PiPManager.shared.toggle(mpv: mpv)
                },
                audioTracks: mpv.audioTracks,
                subtitleTracks: mpv.subtitleTracks,
                externalTracks: playerManager.externalSubtitles,
                onSelectTrack: { track in
                    mpv.selectTrack(track)
                },
                onSelectExternalSub: { sub in
                    mpv.addExternalSubtitle(sub)
                }
            )
            .transition(.opacity)
            .zIndex(20)
        }
    }

    @ViewBuilder
    private var exitWarningOverlay: some View {
        if showExitWarning {
            Text("Press Esc again to exit")
                .font(.headline)
                .foregroundColor(.white)
                .padding()
                .glassEffect(.clear, in: .rect(cornerRadius: 12))
                .cornerRadius(12)
                .transition(.opacity)
                .zIndex(200)
        }
    }

    @ViewBuilder
    private var skipActionOverlay: some View {
        if !isControlsVisible, let action = activeSkipAction {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    skipActionButton(for: action)
                }
                .padding(.trailing, 40)
                .padding(.bottom, 36)
            }
            .transition(.opacity)
            .zIndex(100)
        }
    }
    
    @ViewBuilder
    private var overlayContent: some View {
        let isFluxEnabled = UserDefaults.standard.object(forKey: UserDefaults.Key.enableFluxMode) as? Bool ?? true
        if playerManager.isLoading && !isFluxEnabled {
            loadingView
        }
        
        if let error = playerManager.errorMessage {
            errorView(error: error)
        }
        
        // Stream Selection UI (Initial automatic picker OR manually opened via Right-Click overlay)
        if showManualStreamPicker || (!playerManager.isLoading && playerManager.currentStreamURL == nil && !playerManager.isFetchingStreams) {
            ZStack {
                Color.black.opacity(0.65)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showManualStreamPicker = false
                        }
                    }
                    .transition(.opacity)
                
                streamSelectionView
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.95).combined(with: .opacity),
                        removal: .scale(scale: 0.98).combined(with: .opacity)
                    ))
            }
            .zIndex(20)
        }

        // Next Episode Overlay — countdown auto-play (last 10s)
        if let next = playerManager.nextEpisodeInfo, mpv.isPlaying {
            let remaining = mpv.duration > 0 ? mpv.duration - mpv.timePos : 999
            if autoPlayNextEnabled && !autoPlayCancelled && remaining <= 10 && remaining > 0.8 {
                autoPlayCountdownView(season: next.season, episode: next.episode, seconds: Int(ceil(remaining)))
            }
        }
    }

    // Countdown auto-play panel
    private func autoPlayCountdownView(season: Int, episode: Int, seconds: Int) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Next episode in \(seconds)s")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                        Text("S\(season) E\(episode)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    Button {
                        autoPlayCancelled = true
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.18), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Capsule())

                    Button {
                        autoPlayCancelled = true
                        playerManager.playNextEpisode()
                    } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.white))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.trailing, 40)
            .padding(.bottom, 40)
        }
    }
    
    // MARK: - Smart Skip Action Engine (Native Chapters + TV Heuristics)
    enum SkipActionType: Equatable {
        case recap(targetTime: Double)
        case intro(targetTime: Double)
        case nextEpisode(season: Int, episode: Int)
    }

    private var activeSkipAction: SkipActionType? {
        guard mpv.isPlaying, !mpv.isUserPaused, mpv.duration > 60 else { return nil }
        
        let t = mpv.timePos
        let season = playerManager.currentSeason ?? 1
        let episode = playerManager.currentEpisode ?? 1
        let isTV = item?.category == "TV Show" || playerManager.currentSeason != nil
        
        // 1. Native embedded chapters from video container (MKV / MP4)
        if !mpv.chapters.isEmpty {
            for (idx, chapter) in mpv.chapters.enumerated() {
                let lowerTitle = chapter.title.lowercased()
                let nextChapterTime = idx + 1 < mpv.chapters.count ? mpv.chapters[idx + 1].time : (chapter.time + 90)
                
                if t >= chapter.time && t < nextChapterTime {
                    // Recap chapter: NEVER show on Season 1 Episode 1
                    if (lowerTitle.contains("recap") || lowerTitle.contains("previously")) && (episode > 1 || season > 1) {
                        return .recap(targetTime: nextChapterTime)
                    }
                    if lowerTitle.contains("intro") || lowerTitle.contains("opening") || lowerTitle.contains("theme") || lowerTitle.contains("main title") || lowerTitle.contains("title") {
                        return .intro(targetTime: nextChapterTime)
                    }
                    if lowerTitle.contains("credit") || lowerTitle.contains("outro") || lowerTitle.contains("end") {
                        if let next = playerManager.nextEpisodeInfo {
                            return .nextEpisode(season: next.season, episode: next.episode)
                        }
                    }
                }
            }
        }
        
        // 2. Next Episode (end credits)
        if isTV, let next = playerManager.nextEpisodeInfo, (mpv.progress >= 0.94 || (mpv.duration > 0 && mpv.duration - t <= 60)) {
            return .nextEpisode(season: next.season, episode: next.episode)
        }
        
        return nil
    }
    
    private func setupContextMenuMonitor(for window: NSWindow) {
        contextMenuMonitor?.stop()
        let monitor = PlayerContextMenuMonitor()
        monitor.start(for: window) { [self] in
            if self.showManualStreamPicker {
                return NSMenu()
            }
            return self.buildNativeContextMenu()
        }
        self.contextMenuMonitor = monitor
    }

    private func buildNativeContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Player Context Menu")
        let isPlaying = mpv.isPlaying
        let isPlaybackEnabled = hasStartedPlayback || !isInitialLoading

        // 1. Play / Pause
        menu.addItem(ClosureMenuItem(
            title: isPlaying ? "Pause" : "Play",
            systemImage: isPlaying ? "pause.fill" : "play.fill",
            isEnabled: isPlaybackEnabled
        ) { [weak mpv] in
            DispatchQueue.main.async {
                mpv?.togglePlayPause()
            }
        })

        // 2. Rewind / Forward
        menu.addItem(ClosureMenuItem(
            title: "Rewind 15s",
            systemImage: "gobackward.15",
            isEnabled: isPlaybackEnabled
        ) { [weak mpv, weak playerManager] in
            DispatchQueue.main.async {
                guard let mpv = mpv else { return }
                let target = max(0, mpv.timePos - 15)
                mpv.seek(relative: -15)
                if mpv.duration > 0 {
                    playerManager?.updateWatchProgress(time: target, duration: mpv.duration)
                }
            }
        })

        menu.addItem(ClosureMenuItem(
            title: "Forward 15s",
            systemImage: "goforward.15",
            isEnabled: isPlaybackEnabled
        ) { [weak mpv, weak playerManager] in
            DispatchQueue.main.async {
                guard let mpv = mpv else { return }
                let target = min(mpv.duration, mpv.timePos + 15)
                mpv.seek(relative: 15)
                if mpv.duration > 0 {
                    playerManager?.updateWatchProgress(time: target, duration: mpv.duration)
                }
            }
        })

        menu.addItem(NSMenuItem.separator())

        // 3. Mute / Unmute
        let isMuted = mpv.volume <= 0.001
        menu.addItem(ClosureMenuItem(
            title: isMuted ? "Unmute" : "Mute",
            systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            isEnabled: isPlaybackEnabled
        ) { [weak mpv] in
            DispatchQueue.main.async {
                mpv?.toggleMute()
            }
        })

        // 4. Subtitles Submenu
        let subTracks = mpv.subtitleTracks
        let extSubs = playerManager.externalSubtitles
        if !subTracks.isEmpty || !extSubs.isEmpty {
            let subMenuItem = ClosureMenuItem(
                title: "Subtitles",
                systemImage: "captions.bubble",
                isEnabled: isPlaybackEnabled
            )
            let subMenu = NSMenu(title: "Subtitles")

            let isNoneSelected = !subTracks.contains(where: { $0.isSelected })
            subMenu.addItem(ClosureMenuItem(
                title: "Off",
                isChecked: isNoneSelected
            ) { [weak mpv] in
                DispatchQueue.main.async {
                    mpv?.selectTrack(Track(id: -1, type: "sub", title: "Off", lang: "", isSelected: true))
                }
            })

            if !subTracks.isEmpty {
                subMenu.addItem(NSMenuItem.separator())
                for track in subTracks {
                    subMenu.addItem(ClosureMenuItem(
                        title: track.displayName,
                        isChecked: track.isSelected
                    ) { [weak mpv] in
                        DispatchQueue.main.async {
                            mpv?.selectTrack(track)
                        }
                    })
                }
            }

            if !extSubs.isEmpty {
                subMenu.addItem(NSMenuItem.separator())
                for sub in extSubs {
                    let label = sub.source != nil ? "\(sub.language) (\(sub.source!))" : sub.language
                    subMenu.addItem(ClosureMenuItem(
                        title: label
                    ) { [weak mpv] in
                        DispatchQueue.main.async {
                            mpv?.addExternalSubtitle(sub)
                        }
                    })
                }
            }

            subMenuItem.submenu = subMenu
            menu.addItem(subMenuItem)
        }

        // 5. Audio Tracks Submenu
        let audioTracks = mpv.audioTracks
        if audioTracks.count > 1 {
            let audioMenuItem = ClosureMenuItem(
                title: "Audio Tracks",
                systemImage: "waveform",
                isEnabled: isPlaybackEnabled
            )
            let audioMenu = NSMenu(title: "Audio Tracks")
            for track in audioTracks {
                audioMenu.addItem(ClosureMenuItem(
                    title: track.displayName,
                    isChecked: track.isSelected
                ) { [weak mpv] in
                    DispatchQueue.main.async {
                        mpv?.selectTrack(track)
                    }
                })
            }
            audioMenuItem.submenu = audioMenu
            menu.addItem(audioMenuItem)
        }

        menu.addItem(NSMenuItem.separator())

        // 6. Choose Stream Source… (Always active)
        menu.addItem(ClosureMenuItem(
            title: "Choose Stream Source…",
            systemImage: "list.bullet.rectangle",
            isEnabled: true
        ) {
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    self.showManualStreamPicker = true
                }
            }
        })

        // 7. Picture in Picture
        menu.addItem(ClosureMenuItem(
            title: "Picture in Picture",
            systemImage: "pip.enter",
            isEnabled: isPlaybackEnabled
        ) { [weak mpv] in
            if let mpv = mpv {
                DispatchQueue.main.async {
                    PiPManager.shared.toggle(mpv: mpv)
                }
            }
        })

        // 8. Copy Stream / Magnet Link
        menu.addItem(ClosureMenuItem(
            title: "Copy Stream Link",
            systemImage: "square.and.arrow.up",
            isEnabled: isPlaybackEnabled
        ) { [weak playerManager] in
            let link = playerManager?.currentMagnetURL ?? playerManager?.currentStreamURL?.absoluteString ?? ""
            if !link.isEmpty {
                DispatchQueue.main.async {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                }
            }
        })

        return menu
    }

    private var isInitialLoading: Bool {
        return !hasStartedPlayback
    }

    private var isMidPlaybackBuffering: Bool {
        return hasStartedPlayback && mpv.timePos >= 3.0 && (mpv.isBuffering || mpv.isSeeking) && !mpv.isUserPaused
    }

    private var isBufferingOverlayActive: Bool {
        return isInitialLoading || isMidPlaybackBuffering
    }
    
    private var loadingView: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                let title = playerManager.isFetchingStreams ? "Finding Streams..." : "Connecting to Stream..."
                ProgressView(title)
                    .controlSize(.large)
                    .tint(.white)
                    .foregroundColor(.white)
                if let status = playerManager.statusText {
                    Text(status)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .transition(.opacity)
                }
            }
        }
    }
    
    private var midPlaybackLogoBufferingView: some View {
        ZStack {
            // Subtle dark vignette over the paused video frame
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            let mpvProgressMid = max(mpv.bufferProgress, min(0.99, mpv.demuxerCacheTime / 10.0))
            let realProgress = CGFloat(mpvProgressMid > 0.005 ? mpvProgressMid : animatedProgress)

            if let media = item {
                let logoURL = media.logoURL ?? (media.id.starts(with: "tt") ? URL(string: "https://images.metahub.space/logo/medium/\(media.id)/img") : nil)
                
                ZStack {
                    if let lURL = logoURL {
                        // Base translucent watermark logo
                        AsyncImage(url: lURL) { img in
                            img.resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 100)
                                .opacity(0.25)
                                .shadow(color: .black.opacity(0.8), radius: 10, x: 0, y: 4)
                        } placeholder: {
                            EmptyView()
                        }
                        
                        // Real progress fill logo (left-to-right fill)
                        AsyncImage(url: lURL) { img in
                            img.resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 100)
                                .opacity(1.0)
                                .mask(
                                    GeometryReader { geo in
                                        Rectangle()
                                            .frame(width: max(0, geo.size.width * realProgress))
                                            .animation(.linear(duration: 0.25), value: realProgress)
                                    }
                                )
                                .shadow(color: .white.opacity(0.5), radius: 12, x: 0, y: 2)
                        } placeholder: {
                            EmptyView()
                        }
                    } else {
                        // Text fallback for media with no logo image
                        Text(media.title.uppercased())
                            .font(.system(size: 36, weight: .black, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.25))
                        
                        Text(media.title.uppercased())
                            .font(.system(size: 36, weight: .black, design: .rounded))
                            .foregroundStyle(Color.white)
                            .mask(
                                GeometryReader { geo in
                                    Rectangle()
                                        .frame(width: max(0, geo.size.width * realProgress))
                                        .animation(.linear(duration: 0.25), value: realProgress)
                                }
                            )
                    }
                }
                .scaleEffect(pulseScale)
                .padding(.horizontal, 40)
            }
        }
        .transition(.opacity)
        .zIndex(15)
    }

    private var logoBufferingView: some View {
        ZStack {
            // Fullscreen backdrop picture & vignette
            if let media = item, let bgURL = media.backdropURL ?? media.heroURL ?? media.posterURL ?? media.imageURL {
                AsyncImage(url: bgURL) { image in
                    image.resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } placeholder: {
                    Color.black
                }
            } else {
                Color.black
            }
            
            LinearGradient(
                colors: [.black.opacity(0.4), .black.opacity(0.2), .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            // Real Telemetry Progress Fill Loading — prefer mpv's actual buffer telemetry, 
            // fall back to animated progress only when mpv hasn't reported yet
            let mpvProgress = max(mpv.bufferProgress, min(0.99, mpv.demuxerCacheTime / 10.0))
            let realProgress = CGFloat(mpvProgress > 0.005 ? mpvProgress : animatedProgress)
            
            VStack(spacing: 20) {
                if let media = item {
                    let logoURL = media.logoURL ?? (media.id.starts(with: "tt") ? URL(string: "https://images.metahub.space/logo/medium/\(media.id)/img") : nil)
                    
                    ZStack {
                        if let lURL = logoURL {
                            // Base translucent watermark logo
                            AsyncImage(url: lURL) { img in
                                img.resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 140)
                                    .opacity(0.25)
                                    .shadow(color: .black.opacity(0.8), radius: 10, x: 0, y: 4)
                            } placeholder: {
                                EmptyView()
                            }
                            
                            // Real progress fill logo (left-to-right fill)
                            AsyncImage(url: lURL) { img in
                                img.resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 140)
                                    .opacity(1.0)
                                    .mask(
                                        GeometryReader { geo in
                                            Rectangle()
                                                .frame(width: max(0, geo.size.width * realProgress))
                                                .animation(.linear(duration: 0.25), value: realProgress)
                                        }
                                    )
                                    .shadow(color: .white.opacity(0.4), radius: 12, x: 0, y: 2)
                            } placeholder: {
                                EmptyView()
                            }
                        } else {
                            // Text fallback for media with no logo image
                            Text(media.title.uppercased())
                                .font(.system(size: 48, weight: .black, design: .rounded))
                                .foregroundStyle(Color.white.opacity(0.25))
                            
                            Text(media.title.uppercased())
                                .font(.system(size: 48, weight: .black, design: .rounded))
                                .foregroundStyle(Color.white)
                                .mask(
                                    GeometryReader { geo in
                                        Rectangle()
                                            .frame(width: max(0, geo.size.width * realProgress))
                                            .animation(.linear(duration: 0.25), value: realProgress)
                                    }
                                )
                        }
                    }
                    .scaleEffect(pulseScale)
                    .padding(.horizontal, 40)
                }
            }
        }
        .onReceive(loadingTimer) { _ in
            if mpv.isPlaying && mpv.timePos >= 0.05 {
                withAnimation(.easeOut(duration: 0.2)) {
                    self.hasStartedPlayback = true
                    self.animatedProgress = 1.0
                }

                // Auto-play next episode at the very end (countdown UI shows from 10s)
                if autoPlayNextEnabled, !autoPlayCancelled,
                   playerManager.nextEpisodeInfo != nil,
                   mpv.duration > 0, (mpv.duration - mpv.timePos) <= 1.0 {
                    playerManager.playNextEpisode()
                }
                return
            }

            if playerManager.currentStreamURL == nil {
                // Smooth incremental progress while Flux Mode discovers and races streams
                withAnimation(.linear(duration: 0.5)) {
                    self.animatedProgress = min(0.40, self.animatedProgress + 0.06)
                }
                return
            }

            let cacheTime = mpv.demuxerCacheTime
            let fill = min(0.99, max(0.40, cacheTime / 8.0))

            if fill > 0.005 {
                withAnimation(.linear(duration: 0.35)) {
                    self.animatedProgress = max(self.animatedProgress, fill)
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                self.pulseScale = 1.03
            }
        }
    }

    private func errorView(error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.yellow)
            Text(error)
                .font(.headline)
                .foregroundColor(.white)
            Button("Close") {
                // Clear error + current URL to reveal the stream picker,
                // but keep availableStreams so the user can pick another source.
                playerManager.errorMessage = nil
                playerManager.currentStreamURL = nil
                playerManager.isLoading = false
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
    
    @State private var selectedStreamFilter: String = "All"
    @State private var searchText: String = ""
    @State private var focusedStreamIndex: Int? = nil
    @FocusState private var isSearchFocused: Bool

    private struct StreamCategory: Identifiable {
        let id = UUID()
        let name: String
        let icon: String
    }

    @ViewBuilder
    private func sidebarSection(_ title: String, categories: [StreamCategory]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.3))
                .padding(.horizontal, 12)
                .padding(.bottom, 3)

            ForEach(categories) { cat in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedStreamFilter = cat.name
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: cat.icon)
                            .font(.system(size: 11))
                            .frame(width: 16)
                        Text(cat.name)
                            .font(.system(size: 12, weight: selectedStreamFilter == cat.name ? .semibold : .regular))
                        Spacer()
                        if cat.name == selectedStreamFilter {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 5, height: 5)
                        }
                    }
                    .foregroundColor(selectedStreamFilter == cat.name ? .white : .white.opacity(0.5))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        selectedStreamFilter == cat.name
                        ? Color.white.opacity(0.07)
                        : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 6)
    }

    private var streamSelectionView: some View {
        let allStreams = playerManager.availableStreams

        let availableSources: [String] = {
            var sourcesSet = Set<String>()
            for s in allStreams {
                if !s.source.isEmpty { sourcesSet.insert(s.source) }
            }
            return Array(sourcesSet).sorted()
        }()

        var categories: [StreamCategory] = [
            StreamCategory(name: "All", icon: "square.grid.2x2"),
            StreamCategory(name: "Best", icon: "star.circle"),
        ]
        if allStreams.contains(where: { $0.isFastStart }) {
            categories.append(StreamCategory(name: "Fast Start", icon: "bolt.circle"))
        }
        if allStreams.contains(where: { $0.isTorrent }) {
            categories.append(StreamCategory(name: "Torrents", icon: "arrow.triangle.2.circlepath"))
        }
        if allStreams.contains(where: { !$0.isTorrent }) {
            categories.append(StreamCategory(name: "Direct", icon: "link"))
        }
        let availableQualities = Set(allStreams.map { $0.quality })
        for q in ["4K", "1080p", "720p"] {
            if availableQualities.contains(q) {
                categories.append(StreamCategory(name: q, icon: "sparkles"))
            }
        }
        for source in availableSources {
            categories.append(StreamCategory(name: source, icon: "puzzlepiece.extension.fill"))
        }

        let searchLower = searchText.lowercased()
        let filteredStreams: [Stream] = {
            var streams: [Stream]
            switch selectedStreamFilter {
            case "Best":
                streams = allStreams
                    .filter { playerManager.probeStatus[$0.stableKey]?.ok == true }
                    .sorted { StreamManager.shared.streamSortComparator($0, $1) }
            case "Fast Start":
                streams = allStreams
                    .filter { $0.isFastStart }
                    .sorted { StreamManager.shared.computeStartupSpeedScore($0) > StreamManager.shared.computeStartupSpeedScore($1) }
            case "Torrents":
                streams = allStreams.filter { $0.isTorrent }
            case "Direct":
                streams = allStreams.filter { !$0.isTorrent }
            case "4K", "1080p", "720p":
                streams = allStreams.filter { $0.quality == selectedStreamFilter }
            default:
                streams = allStreams.filter {
                    $0.source.lowercased() == selectedStreamFilter.lowercased()
                }
            }
            if !searchText.isEmpty {
                streams = streams.filter {
                    $0.cleanTitle.lowercased().contains(searchLower) ||
                    $0.source.lowercased().contains(searchLower) ||
                    $0.quality.lowercased().contains(searchLower) ||
                    ($0.language?.lowercased().contains(searchLower) ?? false)
                }
            }
            return streams
        }()

        let isVerifyingBest = selectedStreamFilter == "Best"
            && filteredStreams.isEmpty
            && allStreams.contains { playerManager.probeStatus[$0.stableKey] == nil }

        return VStack(spacing: 0) {
            // ── Top Bar ──
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 12, height: 12)
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.15)) {
                                if showManualStreamPicker {
                                    showManualStreamPicker = false
                                } else {
                                    playerManager.close()
                                    dismiss()
                                }
                            }
                        }
                    Circle().fill(Color.gray.opacity(0.35)).frame(width: 12, height: 12)
                    Circle().fill(Color.gray.opacity(0.35)).frame(width: 12, height: 12)
                }
                .padding(.leading, 16)

                Text("Stream Sources")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.leading, 12)

                Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(playerManager.isFetchingStreams ? Color.blue : Color.green)
                        .frame(width: 5, height: 5)
                    if playerManager.isFetchingStreams {
                        Text("Searching… (\(allStreams.count))")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                    } else {
                        Text("\(filteredStreams.count)/\(allStreams.count)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .padding(.trailing, 16)
            }
            .padding(.vertical, 12)

            Divider().background(Color.white.opacity(0.06))

            // ── Body: Sidebar + Stream List ──
            HStack(spacing: 0) {
                // Left Sidebar
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.3))
                            TextField("Search…", text: $searchText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .foregroundColor(.white)
                                .focused($isSearchFocused)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
                        )
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)

                        sidebarSection("Type", categories: categories.filter {
                            ["All", "Best", "Fast Start", "Torrents", "Direct"].contains($0.name)
                        })

                        let qualityCats = categories.filter { ["4K", "1080p", "720p"].contains($0.name) }
                        if !qualityCats.isEmpty {
                            sidebarSection("Quality", categories: qualityCats)
                        }

                        let sourceCats = categories.filter { cat in
                            !["All", "Best", "Fast Start", "Torrents", "Direct", "4K", "1080p", "720p"].contains(cat.name)
                        }
                        if !sourceCats.isEmpty {
                            sidebarSection("Sources", categories: sourceCats)
                        }
                    }
                    .padding(.vertical, 10)
                }
                .frame(width: 170)

                Divider().background(Color.white.opacity(0.06))

                // Stream List
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 6) {
                            if filteredStreams.isEmpty && isVerifyingBest {
                                VStack(spacing: 12) {
                                    ProgressView().tint(.blue)
                                    Text("Verifying sources…")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 60)
                            } else if filteredStreams.isEmpty {
                                VStack(spacing: 10) {
                                    Image(systemName: "film.stack")
                                        .font(.system(size: 30))
                                        .foregroundStyle(.secondary)
                                    Text("No streams found")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 60)
                            } else {
                                ForEach(Array(filteredStreams.enumerated()), id: \.element.id) { idx, stream in
                                    StreamRowItemView(
                                        stream: stream,
                                        isSelected: focusedStreamIndex == idx,
                                        onSelect: {
                                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                                showManualStreamPicker = false
                                                playerManager.selectStream(stream)
                                            }
                                        }
                                    )
                                    .id(idx)
                                }
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: focusedStreamIndex) { _, idx in
                        if let idx {
                            withAnimation { proxy.scrollTo(idx, anchor: .center) }
                        }
                    }
                }
            }
        }
        .frame(width: 900, height: 540)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0.95))
                .shadow(color: .black.opacity(0.65), radius: 36, x: 0, y: 14)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.04)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 0.5
                )
        )
        .onKeyPress(.upArrow) {
            if focusedStreamIndex == nil { focusedStreamIndex = max(0, filteredStreams.count - 1) }
            else if focusedStreamIndex! > 0 { focusedStreamIndex! -= 1 }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if focusedStreamIndex == nil { focusedStreamIndex = 0 }
            else if focusedStreamIndex! < filteredStreams.count - 1 { focusedStreamIndex! += 1 }
            return .handled
        }
        .onKeyPress(.return) {
            if let idx = focusedStreamIndex, idx < filteredStreams.count {
                showManualStreamPicker = false
                playerManager.selectStream(filteredStreams[idx])
            }
            return .handled
        }
        .onKeyPress(.escape) {
            withAnimation(.easeOut(duration: 0.15)) {
                if showManualStreamPicker { showManualStreamPicker = false }
                else { playerManager.close(); dismiss() }
            }
            return .handled
        }
        .onKeyPress(KeyEquivalent("/")) {
            isSearchFocused = true
            return .handled
        }
    }
    
    private func getSubtitle() -> String {
        if let season = PlayerManager.shared.currentSeason, let episode = PlayerManager.shared.currentEpisode {
            return "S\(season):E\(episode)"
        }
        return item?.description ?? "No description"
    }

}

struct StreamRowItemView: View {
    let stream: Stream
    var isSelected: Bool = false
    let onSelect: () -> Void
    @ObservedObject private var playerManager = PlayerManager.shared
    @State private var isHovered = false
    @State private var showDetail = false
    @State private var hoverWorkItem: DispatchWorkItem?

    private var isHDR: Bool {
        let t = "\(stream.title) \(stream.cleanTitle)".uppercased()
        return t.contains("HDR") || t.contains("HDR10") || t.contains("HDR10+")
    }

    private var isDolbyVision: Bool {
        let t = "\(stream.title) \(stream.cleanTitle)".uppercased()
        return t.contains("DV") || t.contains("DOLBY VISION") || t.contains("DOVI")
    }

    private var audioBadgeText: String? {
        let t = "\(stream.title) \(stream.cleanTitle)".uppercased()
        if t.contains("ATMOS") { return "ATMOS" }
        if t.contains("7.1") { return "7.1" }
        if t.contains("5.1") || t.contains("DDP5.1") || t.contains("DD5.1") { return "5.1" }
        return nil
    }

    private var codecBadgeText: String? {
        if let c = stream.codec { return c }
        let t = "\(stream.title) \(stream.cleanTitle)".uppercased()
        if t.contains("HEVC") || t.contains("X265") || t.contains("H.265") { return "HEVC" }
        if t.contains("AV1") { return "AV1" }
        if t.contains("X264") || t.contains("H.264") || t.contains("AVC") { return "x264" }
        return nil
    }

    private var addonLogoURL: URL? {
        guard let addon = AddonManager.shared.addons.first(where: {
            $0.name.lowercased() == stream.source.lowercased()
        }) else { return nil }
        if let logo = addon.logoURL, let url = URL(string: logo) { return url }
        if let icon = addon.iconURL, let url = URL(string: icon) { return url }
        return nil
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    if let logoURL = addonLogoURL {
                        CachedImage(url: logoURL) { phase in
                            if let img = phase.image {
                                img.resizable().scaledToFill()
                            } else {
                                Text(stream.source.prefix(2).uppercased())
                                    .font(.system(size: 9, weight: .heavy))
                            }
                        }
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(providerGradient(stream.source))
                        .foregroundColor(.white)
                        .cornerRadius(6)
                    } else {
                        Text(stream.source)
                            .font(.system(size: 10, weight: .heavy))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(providerGradient(stream.source))
                            .foregroundColor(.white)
                            .cornerRadius(6)
                    }

                    Text(stream.quality)
                        .font(.system(size: 10, weight: .heavy))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(qualityGradient(stream.quality))
                        .foregroundColor(.white)
                        .cornerRadius(6)

                    if let codec = codecBadgeText {
                        Text(codec)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(Color.indigo.opacity(0.65))
                            .foregroundColor(.white)
                            .cornerRadius(4)
                    }

                    if let audio = audioBadgeText {
                        HStack(spacing: 2) {
                            Image(systemName: "speaker.wave.2.fill").font(.system(size: 7))
                            Text(audio).font(.system(size: 9, weight: .bold, design: .monospaced))
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(Color.cyan.opacity(0.65))
                        .foregroundColor(.white)
                        .cornerRadius(4)
                    }

                    if isHDR {
                        Text("HDR")
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.8))
                            .foregroundColor(.white)
                            .cornerRadius(4)
                    }

                    if isDolbyVision {
                        Text("DV")
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 3)
                            .background(Color.pink.opacity(0.8))
                            .foregroundColor(.white)
                            .cornerRadius(4)
                    }

                    Spacer(minLength: 4)

                    if stream.startupSpeedTier == .instant {
                        Image(systemName: "bolt.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.cyan)
                    } else if stream.startupSpeedTier == .fast {
                        Image(systemName: "bolt.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.blue)
                    }

                    if let status = playerManager.probeStatus[stream.stableKey] {
                        Image(systemName: status.ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(status.ok ? .green : .yellow)
                    }
                }

                Spacer(minLength: 5)

                Text(stream.cleanTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 3)

                HStack(spacing: 8) {
                    if let size = stream.size {
                        HStack(spacing: 3) {
                            Image(systemName: stream.isSeasonPack ? "square.stack.3d.up.fill" : "doc.fill")
                                .font(.system(size: 8))
                            Text(stream.isSeasonPack ? "\(size) pack" : size)
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(.white.opacity(0.55))
                    }

                    if let seeders = stream.seeders {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 8))
                            Text("\(seeders)").font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(.green)
                    }

                    if let br = stream.bitrate {
                        HStack(spacing: 3) {
                            Image(systemName: "waveform").font(.system(size: 8))
                            Text(br).font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(.white.opacity(0.45))
                    }

                    Spacer(minLength: 4)

                    if let lang = stream.language {
                        let truncated = Self.truncateBadge(lang, max: 2)
                        HStack(spacing: 3) {
                            Image(systemName: "globe").font(.system(size: 8))
                            Text(truncated).font(.system(size: 9, weight: .semibold)).lineLimit(1)
                        }
                        .foregroundColor(.purple)
                    }

                    if let subs = stream.subtitles {
                        let truncated = Self.truncateBadge(subs, max: 2)
                        HStack(spacing: 3) {
                            Image(systemName: "captions.bubble").font(.system(size: 8))
                            Text(truncated).font(.system(size: 9, weight: .semibold)).lineLimit(1)
                        }
                        .foregroundColor(.mint)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 68)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(isSelected ? 0.10 : isHovered ? 0.05 : 0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.5)
                        : Color.white.opacity(isHovered ? 0.08 : 0.03),
                        lineWidth: isSelected ? 1 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                let work = DispatchWorkItem { showDetail = true }
                hoverWorkItem?.cancel()
                hoverWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
            } else {
                hoverWorkItem?.cancel()
                hoverWorkItem = nil
                withAnimation(.easeOut(duration: 0.12)) { showDetail = false }
            }
        }
        .overlay(alignment: .topTrailing) {
            if showDetail {
                streamDetailPanel
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                    .zIndex(100)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showDetail)
    }

    private var streamDetailPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(stream.cleanTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(4)

            Divider().background(Color.white.opacity(0.12))

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Label("Source", systemImage: "puzzlepiece.extension")
                    Text(stream.source)
                }
                GridRow {
                    Label("Quality", systemImage: "sparkles")
                    Text(stream.quality)
                }
                if let codec = stream.codec ?? codecBadgeText {
                    GridRow {
                        Label("Codec", systemImage: "film")
                        Text(codec)
                    }
                }
                if let size = stream.size {
                    GridRow {
                        Label("Size", systemImage: "doc.fill")
                        Text(size)
                    }
                }
                if let seeders = stream.seeders {
                    GridRow {
                        Label("Seeders", systemImage: "arrow.up.circle.fill")
                        Text("\(seeders)").foregroundColor(.green)
                    }
                }
                if let lang = stream.language {
                    GridRow {
                        Label("Language", systemImage: "globe")
                        Text(lang)
                    }
                }
                if let subs = stream.subtitles {
                    GridRow {
                        Label("Subtitles", systemImage: "captions.bubble")
                        Text(subs)
                    }
                }
                if let br = stream.bitrate {
                    GridRow {
                        Label("Bitrate", systemImage: "waveform")
                        Text(br)
                    }
                }
            }
            .font(.system(size: 11))
            .foregroundColor(.white.opacity(0.65))
        }
        .padding(12)
        .frame(width: 310)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0.95))
                .shadow(color: .black.opacity(0.5), radius: 16, x: 0, y: 6)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .offset(x: -330, y: -8)
    }

    private func providerGradient(_ source: String) -> LinearGradient {
        let src = source.lowercased()
        if src.contains("torrentio") {
            return LinearGradient(colors: [Color(red: 0.95, green: 0.45, blue: 0.15), Color(red: 0.85, green: 0.30, blue: 0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        if src.contains("hydra") || src.contains("cyber") {
            return LinearGradient(colors: [Color(red: 0.10, green: 0.70, blue: 0.90), Color(red: 0.05, green: 0.50, blue: 0.80)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        if src.contains("debrid") || src.contains("real") {
            return LinearGradient(colors: [Color(red: 0.65, green: 0.30, blue: 0.95), Color(red: 0.45, green: 0.15, blue: 0.80)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        if src.contains("comet") {
            return LinearGradient(colors: [Color(red: 0.95, green: 0.25, blue: 0.55), Color(red: 0.80, green: 0.15, blue: 0.40)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        if src.contains("mediafusion") {
            return LinearGradient(colors: [Color(red: 0.15, green: 0.80, blue: 0.60), Color(red: 0.05, green: 0.65, blue: 0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        if src.contains("pengu") {
            return LinearGradient(colors: [Color(red: 0.30, green: 0.80, blue: 0.90), Color(red: 0.15, green: 0.60, blue: 0.80)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        if src.contains("webstream") {
            return LinearGradient(colors: [Color(red: 0.55, green: 0.20, blue: 0.90), Color(red: 0.40, green: 0.10, blue: 0.75)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        if src.contains("easy") {
            return LinearGradient(colors: [Color(red: 0.35, green: 0.40, blue: 0.95), Color(red: 0.20, green: 0.25, blue: 0.80)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        return LinearGradient(colors: [Color(red: 0.25, green: 0.50, blue: 0.95), Color(red: 0.15, green: 0.35, blue: 0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func qualityGradient(_ quality: String) -> LinearGradient {
        switch quality.uppercased() {
        case "4K", "2160P", "UHD":
            return LinearGradient(colors: [Color(red: 0.65, green: 0.35, blue: 0.95), Color(red: 0.45, green: 0.15, blue: 0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "1080P", "FHD":
            return LinearGradient(colors: [Color(red: 0.20, green: 0.55, blue: 0.95), Color(red: 0.10, green: 0.40, blue: 0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "720P", "HD":
            return LinearGradient(colors: [Color(red: 0.15, green: 0.75, blue: 0.70), Color(red: 0.05, green: 0.60, blue: 0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
        default:
            return LinearGradient(colors: [Color.white.opacity(0.2), Color.white.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private static func truncateBadge(_ text: String, max: Int) -> String {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count <= max { return text }
        let shown = parts.prefix(max).joined(separator: ", ")
        let remaining = parts.count - max
        return "\(shown) +\(remaining)"
    }
}

// MARK: - Native AppKit Context Menu Monitor (Flicker-Free During 60FPS Playback)

final class PlayerContextMenuMonitor {
    private var monitor: Any?
    private weak var window: NSWindow?

    func start(for window: NSWindow, menuBuilder: @escaping () -> NSMenu) {
        self.window = window
        stop()

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self = self else { return event }

            let isRightClick = event.type == .rightMouseDown
            let isControlLeftClick = event.type == .leftMouseDown && event.modifierFlags.contains(.control)

            guard isRightClick || isControlLeftClick else {
                return event
            }

            guard let eventWindow = event.window else {
                return event
            }

            // Ensure event is targeted at the player window
            if let hostWindow = self.window {
                guard eventWindow == hostWindow else { return event }
            } else {
                guard eventWindow.isKeyWindow else { return event }
            }

            let menu = menuBuilder()
            guard !menu.items.isEmpty, let contentView = eventWindow.contentView else {
                return event
            }

            NSMenu.popUpContextMenu(menu, with: event, for: contentView)
            return nil
        }
    }

    func stop() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        stop()
    }
}

struct PlayerWindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> PlayerWindowAccessorView {
        let view = PlayerWindowAccessorView()
        view.onWindowAcquired = onWindow
        return view
    }

    func updateNSView(_ nsView: PlayerWindowAccessorView, context: Context) {
        nsView.onWindowAcquired = onWindow
        if let window = nsView.window {
            onWindow(window)
        }
    }
}

final class PlayerWindowAccessorView: NSView {
    var onWindowAcquired: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = self.window {
            onWindowAcquired?(window)
        }
    }
}

final class ClosureMenuItem: NSMenuItem {
    private var actionClosure: (() -> Void)?

    init(title: String, systemImage: String? = nil, isChecked: Bool = false, isEnabled: Bool = true, action: (() -> Void)? = nil) {
        self.actionClosure = action
        super.init(title: title, action: action != nil ? #selector(didSelect(_:)) : nil, keyEquivalent: "")
        self.target = self
        self.isEnabled = isEnabled
        self.state = isChecked ? .on : .off
        if let systemImage = systemImage {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            if let img = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)?.withSymbolConfiguration(config) {
                self.image = img
            }
        }
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc private func didSelect(_ sender: Any?) {
        actionClosure?()
    }
}
