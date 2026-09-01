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
            
            // 2. Initial Buffer Loading Screen (Cold start: full artwork + animated logo fill, only BEFORE playback starts)
            if isInitialLoading {
                logoBufferingView
                    .transition(.opacity)
                    .zIndex(10)
            }
            
            // 3. Mid-Playback Buffering (Logo buffer bar over the paused video frame)
            if isMidPlaybackBuffering {
                midPlaybackLogoBufferingView
            }
            
            // 4. Controls Layer (Only active once playback has started)
            if hasStartedPlayback {
                PlayerControlsView(
                    isPlaying: $mpv.isPlaying,
                    progress: Binding(
                        get: { mpv.progress },
                        set: { 
                             // Seek to absolute time based on percentage
                             let targetTime = $0 * mpv.duration
                             mpv.seek(absolute: targetTime)
                             if mpv.duration > 0 {
                                 lastProgressSaveTime = Date()
                                 playerManager.updateWatchProgress(time: targetTime, duration: mpv.duration)
                             }
                             
                             // Smart Preload Trigger
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
                    onSkipForward: { 
                        let targetTime = min(mpv.duration, mpv.timePos + 15)
                        mpv.seek(relative: 15)
                        if mpv.duration > 0 {
                            lastProgressSaveTime = Date()
                            playerManager.updateWatchProgress(time: targetTime, duration: mpv.duration)
                        }
                    }, 
                    onSkipBackward: { 
                        let targetTime = max(0, mpv.timePos - 15)
                        mpv.seek(relative: -15)
                        if mpv.duration > 0 {
                            lastProgressSaveTime = Date()
                            playerManager.updateWatchProgress(time: targetTime, duration: mpv.duration)
                        }
                    },
                    onClose: {
                        playerManager.close()
                        dismiss() // Dismiss the window
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
            
            // Exit Warning Overlay
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

            // Smart Skip Intro / Skip Recap / Next Episode — bottom-right floating button (Apple TV style)
            if !isControlsVisible, let action = activeSkipAction {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        switch action {
                        case .recap(let targetTime):
                            Button {
                                mpv.seek(absolute: targetTime)
                                if mpv.duration > 0 {
                                    lastProgressSaveTime = Date()
                                    playerManager.updateWatchProgress(time: targetTime, duration: mpv.duration)
                                }
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
                                mpv.seek(absolute: targetTime)
                                if mpv.duration > 0 {
                                    lastProgressSaveTime = Date()
                                    playerManager.updateWatchProgress(time: targetTime, duration: mpv.duration)
                                }
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
                    .padding(.trailing, 40)
                    .padding(.bottom, 36)
                }
            }
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
            let targetTime = max(0, mpv.timePos - 10)
            mpv.seek(relative: -10)
            if mpv.duration > 0 {
                lastProgressSaveTime = Date()
                playerManager.updateWatchProgress(time: targetTime, duration: mpv.duration)
            }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            let targetTime = min(mpv.duration, mpv.timePos + 10)
            mpv.seek(relative: 10)
            if mpv.duration > 0 {
                lastProgressSaveTime = Date()
                playerManager.updateWatchProgress(time: targetTime, duration: mpv.duration)
            }
            return .handled
        }
        .onKeyPress(KeyEquivalent(",")) {
            let targetTime = max(0, mpv.timePos - 10)
            mpv.seek(relative: -10)
            if mpv.duration > 0 {
                lastProgressSaveTime = Date()
                playerManager.updateWatchProgress(time: targetTime, duration: mpv.duration)
            }
            return .handled
        }
        .onKeyPress(KeyEquivalent(".")) {
            let targetTime = min(mpv.duration, mpv.timePos + 10)
            mpv.seek(relative: 10)
            if mpv.duration > 0 {
                lastProgressSaveTime = Date()
                playerManager.updateWatchProgress(time: targetTime, duration: mpv.duration)
            }
            return .handled
        }
        .onKeyPress(KeyEquivalent("<")) {
            let targetTime = max(0, mpv.timePos - 10)
            mpv.seek(relative: -10)
            if mpv.duration > 0 {
                lastProgressSaveTime = Date()
                playerManager.updateWatchProgress(time: targetTime, duration: mpv.duration)
            }
            return .handled
        }
        .onKeyPress(KeyEquivalent(">")) {
            let targetTime = min(mpv.duration, mpv.timePos + 10)
            mpv.seek(relative: 10)
            if mpv.duration > 0 {
                lastProgressSaveTime = Date()
                playerManager.updateWatchProgress(time: targetTime, duration: mpv.duration)
            }
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
        .onAppear {
            mpv.onPlaybackError = {
                print("[PlayerView] MPV playback error detected. Triggering auto-fallback to next stream...")
                playerManager.tryNextStream()
            }
            if mpv.hasLoadedMedia {
                // Warm core from the detail-page prefetch — already holding the
                // stream buffered. Just release the hold; do NOT reload.
                print("PlayerView: adopting warm core, releasing hold...")
                mpv.play()
                animatedProgress = 1.0
                hasStartedPlayback = true
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
        // Resume playback position & continuously persist watch progress (every 5 seconds during playback)
        .onChange(of: mpv.timePos) { _, t in
            if t > 0.05 && !hasStartedPlayback {
                withAnimation(.easeOut(duration: 0.2)) {
                    hasStartedPlayback = true
                    animatedProgress = 1.0
                }
            }
            // Continuous autosave during playback
            if hasStartedPlayback && mpv.duration > 0 && Date().timeIntervalSince(lastProgressSaveTime) >= 5.0 {
                lastProgressSaveTime = Date()
                playerManager.updateWatchProgress(time: t, duration: mpv.duration)
            }
            guard let resume = playerManager.pendingResumeTime else { return }
            guard t > 0.1 || mpv.duration > 0 else { return }
            playerManager.pendingResumeTime = nil
            if abs(t - resume) > 1.5 {
                print("PlayerView: resuming playback at \(Int(resume))s")
                mpv.seek(absolute: resume)
            }
        }
        // Save immediately on pause
        .onChange(of: mpv.isPlaying) { _, isPlaying in
            if !isPlaying && hasStartedPlayback && mpv.duration > 0 {
                lastProgressSaveTime = Date()
                playerManager.updateWatchProgress(time: mpv.timePos, duration: mpv.duration)
            }
        }
        // Save immediately when seeking finishes
        .onChange(of: mpv.isSeeking) { wasSeeking, isSeeking in
            if wasSeeking && !isSeeking && hasStartedPlayback && mpv.duration > 0 {
                lastProgressSaveTime = Date()
                playerManager.updateWatchProgress(time: mpv.timePos, duration: mpv.duration)
            }
        }
        .onChange(of: mpv.duration) { _, dur in
            guard dur > 0, let resume = playerManager.pendingResumeTime else { return }
            playerManager.pendingResumeTime = nil
            if abs(mpv.timePos - resume) > 1.5 {
                print("PlayerView: duration received, seeking to resume position: \(Int(resume))s")
                mpv.seek(absolute: resume)
            }
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
    
    @ViewBuilder
    private var overlayContent: some View {
        if playerManager.isLoading {
            loadingView
        }
        
        if let error = playerManager.errorMessage {
            errorView(error: error)
        }
        
        // Stream Selection UI (Initial automatic picker OR manually opened via Right-Click overlay)
        if showManualStreamPicker || (!playerManager.isLoading && playerManager.currentStreamURL == nil && !playerManager.availableStreams.isEmpty) {
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
        return !hasStartedPlayback && !playerManager.isLoading && playerManager.currentStreamURL != nil
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

            let realProgress = CGFloat(max(mpv.bufferProgress, min(0.99, mpv.demuxerCacheTime / 10.0), animatedProgress))

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
            
            // Real Telemetry Progress Fill Loading
            let realProgress = CGFloat(max(mpv.bufferProgress, min(0.99, mpv.demuxerCacheTime / 10.0), animatedProgress))
            
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
            guard playerManager.currentStreamURL != nil else { return }

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

            let cacheTime = mpv.demuxerCacheTime
            let fill = min(0.99, cacheTime / 10.0)

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

    private var streamSelectionView: some View {
        let allStreams = playerManager.availableStreams
        
        let availableSources: [String] = {
            var sourcesSet = Set<String>()
            for s in allStreams {
                if !s.source.isEmpty { sourcesSet.insert(s.source) }
            }
            return Array(sourcesSet).sorted()
        }()
        
        // Clean filter layout: type → quality → sources
        var dynamicFilters: [String] = ["All", "Best"]
        if allStreams.contains(where: { $0.isFastStart }) {
            dynamicFilters.append("Fast Start")
        }
        if allStreams.contains(where: { $0.isTorrent }) {
            dynamicFilters.append("Torrents")
        }
        if allStreams.contains(where: { !$0.isTorrent }) {
            dynamicFilters.append("Direct")
        }
        // Quality filters
        let availableQualities = Set(allStreams.map { $0.quality })
        for q in ["4K", "1080p", "720p"] {
            if availableQualities.contains(q) { dynamicFilters.append(q) }
        }
        // Source filters
        dynamicFilters += availableSources

        let filteredStreams: [Stream] = {
            if selectedStreamFilter == "All" { return allStreams }
            if selectedStreamFilter == "Best" {
                return allStreams
                    .filter { playerManager.probeStatus[$0.stableKey]?.ok == true }
                    .sorted { s1, s2 in
                        StreamManager.shared.streamSortComparator(s1, s2)
                    }
            }
            if selectedStreamFilter == "Fast Start" {
                return allStreams
                    .filter { $0.isFastStart }
                    .sorted { s1, s2 in
                        StreamManager.shared.computeStartupSpeedScore(s1) > StreamManager.shared.computeStartupSpeedScore(s2)
                    }
            }
            if selectedStreamFilter == "Torrents" { return allStreams.filter { $0.isTorrent } }
            if selectedStreamFilter == "Direct" { return allStreams.filter { !$0.isTorrent } }
            if selectedStreamFilter == "4K" || selectedStreamFilter == "1080p" || selectedStreamFilter == "720p" {
                return allStreams.filter { $0.quality == selectedStreamFilter }
            }
            return allStreams.filter { $0.source == selectedStreamFilter || $0.source.lowercased().contains(selectedStreamFilter.lowercased()) }
        }()

        let isVerifyingBest = selectedStreamFilter == "Best"
            && filteredStreams.isEmpty
            && allStreams.contains { playerManager.probeStatus[$0.stableKey] == nil }
        
        return VStack(spacing: 0) {
            // Header Bar
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Select Stream Source")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    
                    HStack(spacing: 6) {
                        Circle()
                            .fill(playerManager.isFetchingStreams ? Color.blue : Color.green)
                            .frame(width: 6, height: 6)
                        
                        if playerManager.isFetchingStreams {
                            Text("Searching streams… (\(allStreams.count) found)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.65))
                        } else {
                            Text("\(allStreams.count) sources available")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.65))
                        }
                    }
                }
                
                Spacer()
                
                Button(action: {
                    withAnimation(.easeOut(duration: 0.2)) {
                        if showManualStreamPicker {
                            showManualStreamPicker = false
                        } else {
                            playerManager.close()
                            dismiss()
                        }
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(4)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 14)
            
            // Dynamic Category / Source Filter Tabs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(dynamicFilters, id: \.self) { filter in
                        Button(action: {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                selectedStreamFilter = filter
                            }
                        }) {
                            Text(filter)
                                .font(.system(size: 12, weight: selectedStreamFilter == filter ? .bold : .medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    selectedStreamFilter == filter
                                    ? AnyShapeStyle(LinearGradient(colors: [Color.blue, Color.cyan.opacity(0.85)], startPoint: .leading, endPoint: .trailing))
                                    : AnyShapeStyle(Color.white.opacity(0.08))
                                )
                                .foregroundColor(
                                    selectedStreamFilter == filter ? .white : .white.opacity(0.75)
                                )
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(selectedStreamFilter == filter ? Color.white.opacity(0.3) : Color.white.opacity(0.05), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 22)
            }
            .padding(.bottom, 12)
            
            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.horizontal, 16)
            
            // Streams List
            ScrollView {
                LazyVStack(spacing: 10) {
                    if filteredStreams.isEmpty && isVerifyingBest {
                        VStack(spacing: 12) {
                            ProgressView()
                                .tint(.blue)
                            Text("Verifying sources…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("Probing response times and swarm health")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .padding(.vertical, 50)
                    } else if filteredStreams.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "film.stack")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                            Text("No streams found for \"\(selectedStreamFilter)\"")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 50)
                    } else {
                        ForEach(filteredStreams) { stream in
                            StreamRowItemView(stream: stream) {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                    showManualStreamPicker = false
                                    playerManager.selectStream(stream)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .frame(maxHeight: 460)
            
            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.horizontal, 16)
            
            // Footer Bar
            HStack {
                Spacer()
                Button("Cancel") {
                    withAnimation(.easeOut(duration: 0.2)) {
                        if showManualStreamPicker {
                            showManualStreamPicker = false
                        } else {
                            playerManager.close()
                            dismiss()
                        }
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .buttonStyle(.plain)
                .foregroundColor(.white.opacity(0.75))
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 640)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0.92))
                .shadow(color: .black.opacity(0.6), radius: 30, x: 0, y: 12)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.25), .white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
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
    let onSelect: () -> Void
    @State private var isHovered = false
    @ObservedObject private var playerManager = PlayerManager.shared

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
        let t = "\(stream.title) \(stream.cleanTitle)".uppercased()
        if t.contains("HEVC") || t.contains("X265") || t.contains("H.265") { return "HEVC" }
        if t.contains("AV1") { return "AV1" }
        return nil
    }

    /// Health badge: green check for probe/seeder-verified sources, gray dot while pending.
    private var healthBadge: some View {
        Group {
            if let status = playerManager.probeStatus[stream.stableKey] {
                if status.ok {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 10))
                        if !stream.isTorrent && status.latency > 0 && status.latency < 3 {
                            Text(String(format: "%.2fs", status.latency))
                                .font(.caption2)
                                .fontWeight(.bold)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(Color.mint.opacity(0.85))
                    .foregroundColor(.white)
                    .cornerRadius(6)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
                        .background(Color.white.opacity(0.12))
                        .foregroundColor(.yellow)
                        .cornerRadius(6)
                }
            }
        }
    }

    /// Season-pack indicator: listed size is the whole pack; playback extracts only the requested episode.
    private var packBadge: some View {
        Group {
            if stream.isSeasonPack {
                HStack(spacing: 3) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 9))
                    Text("PACK")
                        .font(.system(size: 9, weight: .heavy))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(Color.orange.opacity(0.85))
                .foregroundColor(.white)
                .cornerRadius(6)
            }
        }
    }

    /// Speed tier badge: highlights streams estimated to start in <2s (Instant) or <4s (Fast).
    private var speedBadge: some View {
        Group {
            let tier = stream.startupSpeedTier
            if tier == .instant {
                HStack(spacing: 3) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9))
                    Text("Instant")
                        .font(.system(size: 9, weight: .heavy))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(
                    LinearGradient(colors: [Color.cyan, Color.blue.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .foregroundColor(.black)
                .cornerRadius(6)
            } else if tier == .fast {
                HStack(spacing: 3) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9))
                    Text("Fast")
                        .font(.system(size: 9, weight: .heavy))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(
                    LinearGradient(colors: [Color.blue, Color.indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .foregroundColor(.white)
                .cornerRadius(6)
            }
        }
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 7) {
                // Top Tag Bar
                HStack(spacing: 6) {
                    // Provider Badge
                    Text(stream.source)
                        .font(.system(size: 11, weight: .heavy))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(providerGradient(stream.source))
                        .foregroundColor(.white)
                        .cornerRadius(6)
                    
                    // Quality Badge
                    Text(stream.quality)
                        .font(.system(size: 11, weight: .heavy))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(qualityGradient(stream.quality))
                        .foregroundColor(.white)
                        .cornerRadius(6)
                    
                    // Seeders / Peers
                    if let seeders = stream.seeders {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 9))
                            Text("\(seeders)")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
                        .background(Color.green.opacity(0.8))
                        .foregroundColor(.white)
                        .cornerRadius(6)
                    }
                    
                    // Size Badge
                    if let size = stream.size {
                        Text(stream.isSeasonPack ? "\(size) pack" : size)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3.5)
                            .background(Color.white.opacity(0.12))
                            .foregroundColor(.white.opacity(0.9))
                            .cornerRadius(6)
                    }

                    // HDR Badge
                    if isHDR {
                        Text("HDR")
                            .font(.system(size: 9, weight: .black))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3.5)
                            .background(Color.orange.opacity(0.85))
                            .foregroundColor(.white)
                            .cornerRadius(5)
                    }

                    // Dolby Vision Badge
                    if isDolbyVision {
                        Text("DV")
                            .font(.system(size: 9, weight: .black))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3.5)
                            .background(Color.pink.opacity(0.85))
                            .foregroundColor(.white)
                            .cornerRadius(5)
                    }

                    // Audio Badge (Atmos / 5.1)
                    if let audio = audioBadgeText {
                        Text(audio)
                            .font(.system(size: 9, weight: .heavy))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3.5)
                            .background(Color.cyan.opacity(0.75))
                            .foregroundColor(.black)
                            .cornerRadius(5)
                    }

                    // Codec Badge (HEVC)
                    if let codec = codecBadgeText {
                        Text(codec)
                            .font(.system(size: 9, weight: .heavy))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3.5)
                            .background(Color.indigo.opacity(0.75))
                            .foregroundColor(.white)
                            .cornerRadius(5)
                    }

                    // Language Badge
                    if let lang = stream.language {
                        Text(lang)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3.5)
                            .background(Color.purple.opacity(0.65))
                            .foregroundColor(.white)
                            .cornerRadius(6)
                    }
                    
                    Spacer()

                    speedBadge
                    packBadge
                    healthBadge

                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(isHovered ? AnyShapeStyle(LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(Color.white.opacity(0.85)))
                        .scaleEffect(isHovered ? 1.15 : 1.0)
                }
                
                // Stream Clean Title
                Text(stream.cleanTitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.95))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.10 : 0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: isHovered
                                ? [Color.blue.opacity(0.75), Color.cyan.opacity(0.45)]
                                : [Color.white.opacity(0.08), Color.white.opacity(0.02)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: isHovered ? 1.5 : 1
                    )
            )
            .scaleEffect(isHovered ? 1.01 : 1.0)
            .shadow(color: isHovered ? Color.blue.opacity(0.25) : Color.clear, radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                isHovered = hovering
            }
        }
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
            return LinearGradient(colors: [Color.white.opacity(0.25), Color.white.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
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
