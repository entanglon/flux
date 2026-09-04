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
    @AppStorage("autoPlayNextEnabled") private var autoPlayNextEnabled = true
    @State private var autoPlayCancelled = false
    @State private var hasStartedPlayback = false
    @State private var lastProgressSaveTime: Date = .distantPast
    @State private var showManualStreamPicker = false
    @State private var showAboutStreamSource = false
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

    private var isFluxEnabled: Bool {
        UserDefaults.standard.object(forKey: UserDefaults.Key.enableFluxMode) as? Bool ?? true
    }

    private var isPickerVisible: Bool {
        showManualStreamPicker ||
        playerManager.forceStreamPicker ||
        playerManager.isStreamPickerPresented ||
        (!isFluxEnabled && playerManager.currentStreamURL == nil)
    }

    private func dismissStreamPicker() {
        showManualStreamPicker = false
        playerManager.forceStreamPicker = false
        playerManager.isStreamPickerPresented = false
        if playerManager.currentStreamURL == nil {
            playerManager.close()
            dismiss()
        }
    }

    private let loadingTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // 1. Video Layer
            MPVVideoView(controller: mpv)
                .ignoresSafeArea()
            
            // 2. Initial Buffer Loading Screen: in Flux Mode, display IMMEDIATELY on click
            // without waiting for stream resolution, preventing any blank screen or picker flashes.
            if isInitialLoading && playerManager.errorMessage == nil && !isPickerVisible && (playerManager.currentStreamURL != nil || (isFluxEnabled && !playerManager.isManualSelection)) {
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

            // 6. Smart Skip Intro / Skip Recap
            skipActionOverlay

            // 7. Apple TV / Netflix Style "Up Next" Floating Card
            upNextOverlay
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
            if showAboutStreamSource {
                withAnimation(.easeOut(duration: 0.2)) {
                    showAboutStreamSource = false
                }
                return .handled
            }
            if isPickerVisible {
                withAnimation(.easeOut(duration: 0.2)) {
                    dismissStreamPicker()
                }
                return .handled
            }
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
                let isFlux = UserDefaults.standard.object(forKey: UserDefaults.Key.enableFluxMode) as? Bool ?? true
                if isFlux && !playerManager.isManualSelection && !playerManager.standbyFallbacks.isEmpty {
                    playerManager.advanceToStandbyFallback()
                } else {
                    playerManager.tryNextStream()
                }
            }
            if mpv.hasLoadedMedia {
                print("PlayerView: adopting warm core, releasing hold...")
                mpv.play()
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
            handleStreamURLChange(newURL)
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
        .onChange(of: isPickerVisible) { _, visible in
            if visible {
                autoPlayCancelled = true
            }
        }
        .overlay {
            overlayContent
        }
    }
    
    private func handleStreamURLChange(_ newURL: URL?) {
        guard let url = newURL else { return }
        print("PlayerView: URL changed to \(url), playing...")
        autoPlayCancelled = false
        hasStartedPlayback = false
        mpv.play(url: url)
    }

    private func handleTimePosChange(_ t: Double) {
        if t > 0.05 && !hasStartedPlayback {
            withAnimation(.easeOut(duration: 0.2)) {
                hasStartedPlayback = true
                animatedProgress = 1.0
            }
            playerManager.markPlaybackStarted()
            if mpv.isPlaying {
                SleepAssertionManager.shared.enableSleepPrevention()
            }
        }
        // If playback is actively running, clear any stale or erroneous errorMessage
        if hasStartedPlayback && mpv.isPlaying && playerManager.errorMessage != nil {
            print("[PlayerView] Video is actively playing, clearing stale error message.")
            playerManager.errorMessage = nil
        }
        // Confirm positive playback for caching once we hit 1.0s of genuine playback
        if t >= 1.0 && mpv.isPlaying {
            playerManager.confirmPlaybackSuccess()
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
        if let error = playerManager.errorMessage {
            errorView(error: error)
                .zIndex(30)
        }
        
        // Stream Selection UI (Initial automatic picker OR manually opened via Right-Click overlay)
        if isPickerVisible {
            ZStack {
                // Dim backdrop — no tap-to-dismiss: mid-playback the picker must
                // only close via the X button, a row selection, or Escape.
                Color.black.opacity(0.65)
                    .ignoresSafeArea()
                    .transition(.opacity)
                
                streamSelectionView
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.95).combined(with: .opacity),
                        removal: .scale(scale: 0.98).combined(with: .opacity)
                    ))
            }
            .zIndex(20)
        }

        // About Stream Source Modal
        if showAboutStreamSource {
            ZStack {
                Color.black.opacity(0.65)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showAboutStreamSource = false
                        }
                    }
                    .transition(.opacity)

                aboutStreamSourceModal
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.95).combined(with: .opacity),
                        removal: .scale(scale: 0.98).combined(with: .opacity)
                    ))
            }
            .zIndex(25)
        }
    }

    // MARK: - Apple TV & Netflix Style "Up Next" Experience

    private var isEndCreditsOrNearEnd: Bool {
        guard mpv.isPlaying, mpv.duration > 60 else { return false }
        let t = mpv.timePos
        let remaining = mpv.duration - t

        // 1. Native container chapters check (credit/outro/end)
        if !mpv.chapters.isEmpty {
            for (idx, chapter) in mpv.chapters.enumerated() {
                let lower = chapter.title.lowercased()
                let nextChapterTime = idx + 1 < mpv.chapters.count ? mpv.chapters[idx + 1].time : (chapter.time + 120)
                if t >= chapter.time && t < nextChapterTime {
                    if lower.contains("credit") || lower.contains("outro") || lower.contains("end") {
                        return true
                    }
                }
            }
        }

        // 2. Remaining duration / progress heuristics (e.g. final 25 seconds or 96% progress)
        if remaining <= 25 && remaining > 0.8 {
            return true
        }
        if mpv.progress >= 0.96 && remaining <= 45 && remaining > 0.8 {
            return true
        }

        return false
    }

    private var shouldShowUpNextCard: Bool {
        guard playerManager.nextEpisodeInfo != nil,
              let item = item,
              item.isSeries || playerManager.currentSeason != nil,
              autoPlayNextEnabled,
              !autoPlayCancelled else {
            return false
        }
        return isEndCreditsOrNearEnd
    }

    @ViewBuilder
    private var upNextOverlay: some View {
        if shouldShowUpNextCard, let next = playerManager.nextEpisodeInfo {
            let remaining = mpv.duration > 0 ? max(0, mpv.duration - mpv.timePos) : 999
            upNextCard(season: next.season, episode: next.episode, remainingSeconds: remaining)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .scale(scale: 0.92).combined(with: .opacity)
                    )
                )
                .zIndex(110)
        }
    }

    // MARK: - Apple TV & Netflix Style "Up Next" Card
    private func upNextCard(season: Int, episode: Int, remainingSeconds: Double) -> some View {
        let isCountingDown = remainingSeconds <= 15.0 && remainingSeconds > 0.8
        let displaySeconds = Int(ceil(remainingSeconds))
        let nextMeta = playerManager.nextEpisode
        let epTitle = nextMeta?.name.isEmpty == false ? nextMeta!.name : "Episode \(episode)"
        let stillURL = nextMeta?.stillURL ?? playerManager.currentEpisodeImage

        return VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 12) {
                    // Header Row: "UP NEXT" badge + countdown + Dismiss X
                    HStack(alignment: .center) {
                        HStack(spacing: 5) {
                            Image(systemName: "forward.end.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white.opacity(0.8))
                            Text("UP NEXT")
                                .font(.system(size: 11, weight: .black))
                                .tracking(1.2)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(Color.white.opacity(0.12), in: Capsule())

                        Spacer()

                        if isCountingDown {
                            Text("in \(displaySeconds)s")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.75))
                        }

                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                autoPlayCancelled = true
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.7))
                                .frame(width: 22, height: 22)
                                .background(Color.white.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss auto-play and watch credits")
                    }

                    // Content Row: Episode Thumbnail + Episode Details
                    HStack(spacing: 12) {
                        // 16:9 Thumbnail
                        ZStack {
                            if let stillURL = stillURL {
                                AsyncImage(url: stillURL) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                    case .failure, .empty:
                                        thumbnailPlaceholder
                                    @unknown default:
                                        thumbnailPlaceholder
                                    }
                                }
                            } else {
                                thumbnailPlaceholder
                            }

                            // Subtle play badge overlay
                            Circle()
                                .fill(Color.black.opacity(0.55))
                                .frame(width: 28, height: 28)
                                .overlay(
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white)
                                        .offset(x: 1)
                                )
                        }
                        .frame(width: 120, height: 68)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.white.opacity(0.15), lineWidth: 0.8)
                        )

                        // Info Column
                        VStack(alignment: .leading, spacing: 3) {
                            Text("S\(season) : E\(episode)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.6))
                            
                            Text(epTitle)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)

                            if let runtime = nextMeta?.runtime, runtime > 0 {
                                Text("\(runtime) min")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Action Controls: Big Primary "Play Next" Button + Watch Credits
                    HStack(spacing: 10) {
                        Button {
                            withAnimation {
                                autoPlayCancelled = true
                                playerManager.playNextEpisode()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if isCountingDown {
                                    // Circular Animated Timer
                                    ZStack {
                                        Circle()
                                            .stroke(Color.black.opacity(0.2), lineWidth: 2.5)
                                        Circle()
                                            .trim(from: 0, to: CGFloat(max(0, min(1.0, remainingSeconds / 15.0))))
                                            .stroke(Color.black, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                            .rotationEffect(.degrees(-90))
                                        Image(systemName: "play.fill")
                                            .font(.system(size: 8, weight: .black))
                                            .foregroundStyle(.black)
                                            .offset(x: 0.5)
                                    }
                                    .frame(width: 18, height: 18)
                                } else {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.black)
                                }

                                Text(isCountingDown ? "Play Next Episode" : "Play Now")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.black)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                autoPlayCancelled = true
                            }
                        } label: {
                            Text("Credits")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.8))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss overlay and watch full end credits")
                    }
                }
                .padding(14)
                .frame(width: 360)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(Color.black.opacity(0.78))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.3), Color.white.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: Color.black.opacity(0.6), radius: 25, x: 0, y: 12)
            }
            .padding(.trailing, 36)
            .padding(.bottom, isControlsVisible ? 100 : 36)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isControlsVisible)
        }
    }

    private var thumbnailPlaceholder: some View {
        LinearGradient(
            colors: [Color.white.opacity(0.15), Color.white.opacity(0.05)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            Image(systemName: "film")
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.35))
        )
    }
    
    // MARK: - Smart Skip Action Engine (Native Chapters + TV Heuristics)
    enum SkipActionType: Equatable {
        case recap(targetTime: Double)
        case intro(targetTime: Double)
    }

    private var activeSkipAction: SkipActionType? {
        guard mpv.isPlaying, !mpv.isUserPaused, mpv.duration > 60, !shouldShowUpNextCard else { return nil }
        
        let t = mpv.timePos
        let season = playerManager.currentSeason ?? 1
        let episode = playerManager.currentEpisode ?? 1
        
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
                }
            }
        }
        
        return nil
    }
    
    private func setupContextMenuMonitor(for window: NSWindow) {
        contextMenuMonitor?.stop()
        let monitor = PlayerContextMenuMonitor()
        monitor.start(for: window) { [self] in
            if self.isPickerVisible || self.showAboutStreamSource {
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
                // Fresh re-query so slow HTTP addons (PenguPlay, WebStreamrMBG)
                // appear as they respond instead of showing a stale cached list.
                PlayerManager.shared.refreshStreamsForPicker()
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

        // 9. About Stream Source…
        menu.addItem(ClosureMenuItem(
            title: "About Stream Source…",
            systemImage: "info.circle",
            isEnabled: isPlaybackEnabled || playerManager.currentStreamURL != nil
        ) {
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    self.showAboutStreamSource = true
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
    
    private struct PulsingLogoContainer<Content: View>: View {
        @ViewBuilder let content: () -> Content
        @State private var isPulsing = false

        var body: some View {
            content()
                .scaleEffect(isPulsing ? 1.03 : 0.96)
                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: isPulsing)
                .onAppear {
                    isPulsing = true
                }
        }
    }
    
    private var midPlaybackLogoBufferingView: some View {
        ZStack {
            // Subtle dark vignette over the paused video frame
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            let mpvProgressMid = max(mpv.bufferProgress, min(0.99, mpv.demuxerCacheTime / 5.0))
            let realProgress = CGFloat(mpvProgressMid > 0.005 ? mpvProgressMid : animatedProgress)

            if let media = item {
                let logoURL = media.logoURL ?? (media.id.starts(with: "tt") ? URL(string: "https://images.metahub.space/logo/medium/\(media.id)/img") : nil)
                
                PulsingLogoContainer {
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
                }
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
            
            // Real Telemetry Progress Fill Loading — strictly monotonic (never moves backward)
            let realProgress = CGFloat(animatedProgress)
            
            VStack(spacing: 20) {
                if let media = item {
                    let logoURL = media.logoURL ?? (media.id.starts(with: "tt") ? URL(string: "https://images.metahub.space/logo/medium/\(media.id)/img") : nil)
                    
                    PulsingLogoContainer {
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
                    }
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
                if autoPlayNextEnabled, !autoPlayCancelled, !isPickerVisible,
                   playerManager.nextEpisodeInfo != nil,
                   mpv.duration > 0, (mpv.duration - mpv.timePos) <= 1.0 {
                    playerManager.playNextEpisode()
                }
                return
            }

            // Real telemetry only: while stream URL is resolving, progress stays strictly at 0.0
            if playerManager.currentStreamURL == nil {
                self.animatedProgress = 0.0
                return
            }

            // Genuine demuxer buffer telemetry from mpv (no artificial base jumps)
            let cacheTime = mpv.demuxerCacheTime
            playerManager.reportTelemetryProgress(cacheTime: cacheTime)

            let mpvBuf = max(mpv.bufferProgress, min(1.0, cacheTime / 4.0))
            self.animatedProgress = max(self.animatedProgress, mpvBuf)
        }
    }

    private func errorView(error: String) -> some View {
        let sourceMode = UserDefaults.standard.string(forKey: UserDefaults.Key.streamingSourceMode) ?? "both"
        let hasStreams = !playerManager.availableStreams.isEmpty

        return ZStack {
            Color.black.opacity(0.65)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(Color.yellow.opacity(0.15))
                        .frame(width: 64, height: 64)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundColor(.yellow)
                }

                VStack(spacing: 8) {
                    Text(hasStreams ? "Playback Issue" : "No Streams Available")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)

                    Text(error)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }

                HStack(spacing: 12) {
                    if !hasStreams && sourceMode == "http" {
                        Button {
                            UserDefaults.standard.set("both", forKey: UserDefaults.Key.streamingSourceMode)
                            playerManager.errorMessage = nil
                            playerManager.refreshStreamsForPicker()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text("Enable Torrents & Retry")
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                    }

                    if !hasStreams {
                        Button {
                            playerManager.errorMessage = nil
                            playerManager.refreshStreamsForPicker()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise")
                                Text("Retry")
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.15), in: Capsule())
                            .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            playerManager.errorMessage = nil
                            playerManager.currentStreamURL = nil
                            playerManager.forceStreamPicker = true
                            playerManager.isStreamPickerPresented = true
                            showManualStreamPicker = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "list.bullet.rectangle")
                                Text("Choose Another Source")
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.white, in: Capsule())
                            .foregroundColor(.black)
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        playerManager.close()
                        dismiss()
                    } label: {
                        Text("Close")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.12), in: Capsule())
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }
            .padding(32)
            .frame(width: 480)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 15)
        }
    }

    // MARK: - About Stream Source Inspector Modal

    @ViewBuilder
    private var aboutStreamSourceModal: some View {
        let stream = playerManager.currentSelectedStream
        let mediaInfo = mpv.getMediaInfo()
        let isTorrent = stream?.isTorrent == true
        let title = stream?.title ?? (playerManager.currentItem?.title ?? "Unknown")
        let sourceName = stream?.source ?? "Direct Link"
        let resolution = mediaInfo.resolution ?? (stream?.quality.isEmpty == false ? stream!.quality : "Unknown")
        let vCodec = mediaInfo.videoCodec?.uppercased() ?? (stream?.codec?.uppercased() ?? "Auto")
        let aCodec = mediaInfo.audioCodec?.uppercased() ?? "Stereo"
        let hwdec = mediaInfo.hwdec?.uppercased() ?? (UserDefaults.standard.bool(forKey: "useHardwareAcceleration") ? "Active" : "Disabled")
        let transport = isTorrent ? "BitTorrent Swarm (P2P)" : "Direct HTTP Stream"
        let size = stream?.size ?? "—"
        let demuxerCache = String(format: "%.1f sec", mpv.demuxerCacheTime)
        let link = playerManager.currentMagnetURL ?? playerManager.currentStreamURL?.absoluteString ?? ""

        VStack(alignment: .leading, spacing: 18) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.cyan)
                    Text("About Stream Source")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                }

                Spacer()

                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showAboutStreamSource = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
            }

            // Provider & Transport badges
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "cube.box.fill")
                        .font(.system(size: 10))
                    Text(sourceName)
                        .font(.system(size: 12, weight: .bold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.12), in: Capsule())
                .foregroundColor(.white)

                HStack(spacing: 5) {
                    Image(systemName: isTorrent ? "point.3.filled.connected.trianglepath.dotted" : "globe")
                        .font(.system(size: 10))
                    Text(transport)
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background((isTorrent ? Color.purple : Color.cyan).opacity(0.2), in: Capsule())
                .foregroundColor(isTorrent ? Color.purple.opacity(0.9) : Color.cyan)

                if isTorrent, let seeders = stream?.seeders {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 10))
                        Text("\(seeders) seeds")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.18), in: Capsule())
                    .foregroundColor(.green)
                }
            }

            // Full Release Title
            VStack(alignment: .leading, spacing: 6) {
                Text("RELEASE TITLE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .tracking(0.8)

                Text(title)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            // Specs Grid
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    specField(title: "Resolution", value: resolution)
                    specField(title: "Video Codec", value: vCodec)
                }
                GridRow {
                    specField(title: "Audio Codec", value: aCodec)
                    specField(title: "Hardware Dec", value: hwdec)
                }
                GridRow {
                    specField(title: "File Size", value: size)
                    specField(title: "Demuxer Buffer", value: demuxerCache)
                }
            }

            Divider()
                .background(Color.white.opacity(0.12))

            // Action Buttons
            HStack {
                if !link.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link, forType: .string)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.doc")
                            Text("Copy Stream Link")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.12), in: Capsule())
                        .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showAboutStreamSource = false
                    }
                } label: {
                    Text("Done")
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Color.white, in: Capsule())
                        .foregroundColor(.black)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
        .frame(width: 480)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.6), radius: 35, x: 0, y: 15)
    }

    private func specField(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.45))
                .tracking(0.6)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
    }
    
    // MARK: - Stream Picker State & Category
    
    enum StreamCategoryType: String, CaseIterable, Identifiable {
        case all = "All Sources"
        case best = "Best Health"
        case fastStart = "Fast Start"
        case direct = "Direct HTTP"
        case torrents = "Torrents"
        
        var id: String { rawValue }
        
        var icon: String {
            switch self {
            case .all: return "square.grid.2x2.fill"
            case .best: return "star.fill"
            case .fastStart: return "bolt.fill"
            case .direct: return "link"
            case .torrents: return "arrow.triangle.2.circlepath"
            }
        }
    }

    @State private var selectedCategoryFilter: StreamCategoryType = .all
    @State private var selectedQualityFilter: String = "All"
    @State private var selectedSourceFilter: String = "All"
    @State private var searchText: String = ""
    @State private var focusedStreamIndex: Int? = nil
    @FocusState private var isSearchFocused: Bool

    private var streamSelectionView: some View {
        let allStreams = playerManager.availableStreams

        let isStillFetching = playerManager.isFetchingStreams && (playerManager.totalAddonsCount == 0 || playerManager.loadedAddonsCount < playerManager.totalAddonsCount)

        let availableSources: [String] = {
            var sourcesSet = Set<String>()
            for s in allStreams {
                if !s.source.isEmpty { sourcesSet.insert(s.source) }
            }
            return Array(sourcesSet).sorted()
        }()

        let searchLower = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // 1. Filter by selected addon source
        let sourceFilteredStreams: [Stream] = {
            if selectedSourceFilter == "All" {
                return allStreams
            } else {
                return allStreams.filter { $0.source.lowercased() == selectedSourceFilter.lowercased() }
            }
        }()

        func qualityMatches(stream: Stream, label: String) -> Bool {
            let q = stream.quality.uppercased()
            switch label {
            case "4K":
                return q == "4K" || q == "2160P" || q.contains("4K") || q.contains("2160")
            case "2K":
                return q == "2K" || q == "1440P" || q.contains("2K") || q.contains("1440")
            case "FHD":
                return q == "1080P" || q == "FHD" || q.contains("1080")
            case "HD":
                return q == "720P" || q == "HD" || q.contains("720")
            case "SD":
                return q == "480P" || q == "SD" || q.contains("480") || q.contains("SD")
            default:
                return true
            }
        }

        // 2. Filter by selected quality within the active source scope
        let qualityFilteredStreams: [Stream] = {
            if selectedQualityFilter == "All" {
                return sourceFilteredStreams
            } else {
                return sourceFilteredStreams.filter { qualityMatches(stream: $0, label: selectedQualityFilter) }
            }
        }()

        // 3. Category streams within the active source & quality scope
        func categoryStreams(for category: StreamCategoryType) -> [Stream] {
            switch category {
            case .all:
                return qualityFilteredStreams
            case .best:
                return qualityFilteredStreams
                    .filter { s in
                        s.isDirectHTTP || (s.seeders ?? 0) >= 20 || playerManager.probeStatus[s.stableKey]?.ok == true
                    }
                    .sorted { StreamManager.shared.streamHealthComparator($0, $1, probeStatus: playerManager.probeStatus) }
            case .fastStart:
                return qualityFilteredStreams
                    .filter { $0.isFastStart || $0.startupSpeedTier == .instant }
                    .sorted { StreamManager.shared.computeStartupSpeedScore($0) > StreamManager.shared.computeStartupSpeedScore($1) }
            case .direct:
                return qualityFilteredStreams.filter { StreamManager.isHttpSource($0.source) }
            case .torrents:
                return qualityFilteredStreams.filter { StreamManager.isP2PSource($0.source) }
            }
        }

        func categoryCount(for category: StreamCategoryType) -> Int {
            return categoryStreams(for: category).count
        }

        let availableTabs: [StreamCategoryType] = {
            if selectedSourceFilter == "All" {
                return StreamCategoryType.allCases
            } else {
                return [.all, .best, .fastStart]
            }
        }()

        let filteredStreams: [Stream] = {
            var streams = categoryStreams(for: selectedCategoryFilter)

            // 4. Text Search Filter
            if !searchLower.isEmpty {
                streams = streams.filter {
                    $0.cleanTitle.lowercased().contains(searchLower) ||
                    $0.source.lowercased().contains(searchLower) ||
                    $0.quality.lowercased().contains(searchLower) ||
                    ($0.codec?.lowercased().contains(searchLower) ?? false) ||
                    ($0.language?.lowercased().contains(searchLower) ?? false) ||
                    ($0.subtitles?.lowercased().contains(searchLower) ?? false)
                }
            }

            return streams
        }()

        let isVerifyingBest = selectedCategoryFilter == .best
            && filteredStreams.isEmpty
            && allStreams.contains { playerManager.probeStatus[$0.stableKey] == nil }

        return VStack(spacing: 0) {
            // ── Top Header ──
            HStack(alignment: .center, spacing: 16) {
                // Media Title & Episode / Stream Stats
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if let media = item {
                            Text(media.title)
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        } else {
                            Text("Select Stream Source")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }

                        if let season = PlayerManager.shared.currentSeason, let episode = PlayerManager.shared.currentEpisode {
                            Text("S\(season):E\(episode)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .foregroundStyle(.white.opacity(0.95))
                                .glassEffect(.clear, in: .capsule)
                        }
                    }

                    HStack(spacing: 7) {
                        Circle()
                            .fill(isStillFetching ? Color.cyan : Color.green)
                            .frame(width: 7, height: 7)
                            .shadow(color: (isStillFetching ? Color.cyan : Color.green).opacity(0.9), radius: 5)

                        if isStillFetching {
                            if !playerManager.pendingAddonNames.isEmpty {
                                let pendingList = playerManager.pendingAddonNames.prefix(2).joined(separator: ", ")
                                let moreCount = playerManager.pendingAddonNames.count - 2
                                let addonStr = "\(pendingList)\(moreCount > 0 ? " +\(moreCount)" : "")"
                                Text("Loading \(playerManager.pendingAddonNames.count) addon\(playerManager.pendingAddonNames.count == 1 ? "" : "s") (\(addonStr))… • \(allStreams.count) found")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.cyan.opacity(0.95))
                            } else {
                                Text("Searching addons… (\(allStreams.count) found)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.75))
                            }
                        } else {
                            Text("\(filteredStreams.count) source\(filteredStreams.count == 1 ? "" : "s") available • All addons loaded")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                }

                Spacer()

                // Search Bar
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                    TextField("Filter streams (/)…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .focused($isSearchFocused)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(width: 250)
                .glassEffect(.clear, in: .rect(cornerRadius: 10))

                // Refresh Button — re-query all addons live (bypasses 24h cache)
                Button {
                    playerManager.refreshStreamsForPicker()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 30, height: 30)
                        .glassEffect(.clear.interactive(), in: .circle)
                        .contentShape(.circle)
                        .opacity(playerManager.isFetchingStreams ? 0.5 : 1.0)
                }
                .buttonStyle(.plain)
                .disabled(playerManager.isFetchingStreams)
                .help("Refresh streams from all addons")

                // Close Button
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        dismissStreamPicker()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 30, height: 30)
                        .glassEffect(.clear.interactive(), in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 14)

            // ── Horizontal Filter Bar ──
            HStack(spacing: 10) {
                // Category Pills with Live Counts (Direct HTTP & Torrents auto-hide when viewing a single addon)
                HStack(spacing: 5) {
                    ForEach(availableTabs) { cat in
                        let isSelected = selectedCategoryFilter == cat
                        let catCount = categoryCount(for: cat)
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedCategoryFilter = cat
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: cat.icon)
                                    .font(.system(size: 10, weight: .semibold))
                                Text(cat.rawValue)
                                    .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                                if catCount > 0 {
                                    Text("\(catCount)")
                                        .font(.system(size: 9, weight: .bold, design: .rounded))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(isSelected ? Color.white.opacity(0.28) : Color.white.opacity(0.12))
                                        .clipShape(Capsule())
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.65))
                            .background(isSelected ? Color.white.opacity(0.22) : Color.clear)
                            .glassEffect(isSelected ? .regular.interactive() : .clear.interactive(), in: .capsule)
                            .clipShape(Capsule())
                            .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()

                // Quality Dropdown Menu: Icon-only in bar
                Menu {
                    Button(selectedQualityFilter == "All" ? "✓ All (\(sourceFilteredStreams.count))" : "All (\(sourceFilteredStreams.count))") {
                        selectedQualityFilter = "All"
                    }
                    Divider()
                    ForEach(["4K", "2K", "FHD", "HD", "SD"], id: \.self) { q in
                        let count = sourceFilteredStreams.filter { qualityMatches(stream: $0, label: q) }.count
                        Button(selectedQualityFilter == q ? "✓ \(q) (\(count))" : "\(q) (\(count))") {
                            selectedQualityFilter = q
                        }
                        .disabled(count == 0)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .foregroundStyle(selectedQualityFilter != "All" ? Color.cyan : Color.white.opacity(0.75))
                    .background(selectedQualityFilter != "All" ? Color.cyan.opacity(0.2) : Color.clear)
                    .glassEffect(.clear.interactive(), in: .capsule)
                    .clipShape(Capsule())
                    .contentShape(.capsule)
                }
                .menuStyle(.borderlessButton)
                .help(selectedQualityFilter == "All" ? "Filter by Quality (All)" : "Quality: \(selectedQualityFilter)")

                // Addon Source Dropdown Menu: Icon-only in bar
                if !availableSources.isEmpty {
                    Menu {
                        Button(selectedSourceFilter == "All" ? "✓ All Addons (\(allStreams.count))" : "All Addons (\(allStreams.count))") {
                            selectedSourceFilter = "All"
                        }
                        Divider()
                        ForEach(availableSources, id: \.self) { src in
                            let srcCount = allStreams.filter { $0.source.lowercased() == src.lowercased() }.count
                            Button(selectedSourceFilter == src ? "✓ \(src) (\(srcCount))" : "\(src) (\(srcCount))") {
                                selectedSourceFilter = src
                                if selectedCategoryFilter == .direct || selectedCategoryFilter == .torrents {
                                    selectedCategoryFilter = .all
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "puzzlepiece.extension.fill")
                                .font(.system(size: 11, weight: .semibold))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .foregroundStyle(selectedSourceFilter != "All" ? Color.cyan : Color.white.opacity(0.75))
                        .background(selectedSourceFilter != "All" ? Color.cyan.opacity(0.2) : Color.clear)
                        .glassEffect(.clear.interactive(), in: .capsule)
                        .clipShape(Capsule())
                        .contentShape(.capsule)
                    }
                    .menuStyle(.borderlessButton)
                    .help(selectedSourceFilter == "All" ? "Filter by Addon (All)" : "Addon: \(selectedSourceFilter)")
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 14)

            Divider().background(Color.white.opacity(0.08))

            // ── Stremio-Style Real-Time Addon Loading Strip ──
            if isStillFetching {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.cyan)
                    
                    if !playerManager.pendingAddonNames.isEmpty {
                        Text("Loading from \(playerManager.pendingAddonNames.joined(separator: ", "))…")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    } else {
                        Text("Querying addons for media streams…")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    
                    Spacer()
                    
                    if playerManager.totalAddonsCount > 0 {
                        Text("\(playerManager.loadedAddonsCount) of \(playerManager.totalAddonsCount) loaded")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.cyan.opacity(0.9))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.cyan.opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // ── Stream Cards List ──
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 8) {
                        if filteredStreams.isEmpty && isVerifyingBest {
                            VStack(spacing: 12) {
                                ProgressView().tint(.blue)
                                Text("Verifying best health sources…")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 80)
                        } else if filteredStreams.isEmpty && isStillFetching {
                            VStack(spacing: 14) {
                                ProgressView().tint(.cyan)
                                    .scaleEffect(1.1)
                                Text("Searching addons for available streams…")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.75))
                            }
                            .padding(.vertical, 80)
                        } else if filteredStreams.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "film.stack")
                                    .font(.system(size: 36))
                                    .foregroundStyle(.white.opacity(0.3))
                                Text("No streams match your filter")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.8))
                                if selectedCategoryFilter != .all || selectedQualityFilter != "All" || selectedSourceFilter != "All" || !searchText.isEmpty {
                                    Button("Reset Filters") {
                                        withAnimation {
                                            selectedCategoryFilter = .all
                                            selectedQualityFilter = "All"
                                            selectedSourceFilter = "All"
                                            searchText = ""
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                            .padding(.vertical, 80)
                        } else {
                            ForEach(Array(filteredStreams.enumerated()), id: \.element.stableKey) { idx, stream in
                                StreamRowItemView(
                                    stream: stream,
                                    isSelected: focusedStreamIndex == idx,
                                    onSelect: {
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                            showManualStreamPicker = false
                                            playerManager.forceStreamPicker = false
                                            playerManager.isStreamPickerPresented = false
                                            playerManager.selectStream(stream)
                                        }
                                    }
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                }
                .onChange(of: focusedStreamIndex) { _, idx in
                    if let idx, idx >= 0, idx < filteredStreams.count {
                        withAnimation { proxy.scrollTo(filteredStreams[idx].stableKey, anchor: .center) }
                    }
                }
            }
        }
        .frame(width: 1060, height: 700)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.20), .white.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.6
                )
        )
        .shadow(color: .black.opacity(0.68), radius: 45, x: 0, y: 18)
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
                playerManager.forceStreamPicker = false
                playerManager.isStreamPickerPresented = false
                playerManager.selectStream(filteredStreams[idx])
            }
            return .handled
        }
        .onKeyPress(.escape) {
            withAnimation(.easeOut(duration: 0.15)) {
                dismissStreamPicker()
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
    @State private var showDetailCard = false
    @State private var hoverTask: Task<Void, Never>? = nil

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
            HStack(spacing: 14) {
                // ── Column 1: Source & Quality Pills ──
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        // Provider Badge
                        Text(stream.source)
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(providerGradient(stream.source))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                        // Quality Badge
                        Text(stream.quality)
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(qualityGradient(stream.quality))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }

                    // Direct HTTP vs Torrent Indicator
                    HStack(spacing: 4) {
                        Image(systemName: stream.isDirectHTTP ? "link" : "arrow.triangle.2.circlepath")
                            .font(.system(size: 8))
                        Text(stream.isDirectHTTP ? "Direct HTTP" : "P2P Torrent")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    }
                    .foregroundColor(stream.isDirectHTTP ? Color.cyan.opacity(0.85) : Color.orange.opacity(0.85))
                }
                .frame(width: 148, alignment: .leading)

                // ── Column 2: Title & Technical Metadata Badges ──
                VStack(alignment: .leading, spacing: 5) {
                    Text(stream.cleanTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.95))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    HStack(spacing: 5) {
                        if let codec = codecBadgeText {
                            Text(codec)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.indigo.opacity(0.6))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }

                        if isDolbyVision {
                            Text("DV")
                                .font(.system(size: 8, weight: .black, design: .monospaced))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.pink.opacity(0.8))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        }

                        if isHDR {
                            Text("HDR")
                                .font(.system(size: 8, weight: .black, design: .monospaced))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.8))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        }

                        if let audio = audioBadgeText {
                            HStack(spacing: 2) {
                                Image(systemName: "speaker.wave.2.fill").font(.system(size: 6))
                                Text(audio).font(.system(size: 9, weight: .bold, design: .monospaced))
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.cyan.opacity(0.6))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }

                        if let lang = stream.language {
                            let truncated = Self.truncateBadge(lang, max: 2)
                            HStack(spacing: 2) {
                                Image(systemName: "globe").font(.system(size: 7))
                                Text(truncated).font(.system(size: 8, weight: .semibold))
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.55))
                            .foregroundColor(.white.opacity(0.9))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }

                        if let subs = stream.subtitles {
                            let truncated = Self.truncateBadge(subs, max: 2)
                            HStack(spacing: 2) {
                                Image(systemName: "captions.bubble").font(.system(size: 7))
                                Text(truncated).font(.system(size: 8, weight: .semibold))
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.mint.opacity(0.55))
                            .foregroundColor(.white.opacity(0.9))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                    }
                }

                Spacer()

                // ── Column 3: Stats & Play Button ──
                HStack(spacing: 12) {
                    VStack(alignment: .trailing, spacing: 3) {
                        if let size = stream.size {
                            HStack(spacing: 3) {
                                Image(systemName: stream.isSeasonPack ? "square.stack.3d.up.fill" : "doc.fill")
                                    .font(.system(size: 8))
                                Text(stream.isSeasonPack ? "\(size) pack" : size)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            }
                            .foregroundColor(.white.opacity(0.75))
                        }

                        if let seeders = stream.seeders, seeders > 0, !stream.isDirectHTTP {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.up.circle.fill").font(.system(size: 8))
                                Text("\(seeders) seeds").font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundColor(.green)
                        } else if stream.isDirectHTTP {
                            HStack(spacing: 3) {
                                Image(systemName: "bolt.fill").font(.system(size: 8))
                                Text("Fast HTTP").font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundColor(.cyan)
                        }
                    }
                    .frame(minWidth: 80, alignment: .trailing)

                    // Play CTA Button
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text("Play")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        isSelected || isHovered
                        ? Color.white
                        : Color.white.opacity(0.08)
                    )
                    .foregroundColor(
                        isSelected || isHovered
                        ? Color.black
                        : Color.white.opacity(0.7)
                    )
                    .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .glassEffect(isSelected || isHovered ? .regular : .clear, in: .rect(cornerRadius: 14))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
            hoverTask?.cancel()
            if hovering {
                hoverTask = Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if !Task.isCancelled {
                        await MainActor.run {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                showDetailCard = true
                            }
                        }
                    }
                }
            } else {
                hoverTask = nil
                withAnimation(.easeOut(duration: 0.15)) {
                    showDetailCard = false
                }
            }
        }
        .popover(isPresented: $showDetailCard, arrowEdge: .top) {
            streamDetailFloatingCard
        }
    }

    private var streamDetailFloatingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with provider and quality pills
            HStack(spacing: 8) {
                Text(stream.source)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(providerGradient(stream.source))
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                Text(stream.quality)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(qualityGradient(stream.quality))
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                Spacer()

                if let size = stream.size {
                    Text(size)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.85))
                }
            }

            Divider().background(Color.white.opacity(0.15))

            // Full Release Title (untruncated, selectable)
            VStack(alignment: .leading, spacing: 4) {
                Text("RELEASE TITLE / FILENAME")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
                
                let rawTitle = stream.title.isEmpty ? stream.cleanTitle : stream.title
                Text(rawTitle)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.95))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Technical Specs Grid
            VStack(alignment: .leading, spacing: 6) {
                Text("SPECIFICATIONS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))

                HStack(spacing: 16) {
                    if let codec = codecBadgeText {
                        specItem(label: "Codec", value: codec)
                    }
                    if isDolbyVision || isHDR {
                        specItem(label: "HDR", value: isDolbyVision ? "Dolby Vision" : "HDR10")
                    }
                    if let audio = audioBadgeText {
                        specItem(label: "Audio", value: audio)
                    }
                    specItem(label: "Type", value: stream.isDirectHTTP ? "Direct HTTP" : "P2P Torrent")
                    if let seeders = stream.seeders, seeders > 0, !stream.isDirectHTTP {
                        specItem(label: "Seeds", value: "\(seeders)")
                    }
                }

                if let lang = stream.language, !lang.isEmpty {
                    specItem(label: "Audio Languages", value: lang)
                }

                if let subs = stream.subtitles, !subs.isEmpty {
                    specItem(label: "Subtitles", value: subs)
                }
            }
        }
        .padding(16)
        .frame(width: 440)
        .background(Color(red: 0.10, green: 0.11, blue: 0.14))
    }

    private func specItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
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
        if src.contains("pengu") {
            return LinearGradient(colors: [Color(red: 0.20, green: 0.70, blue: 0.95), Color(red: 0.10, green: 0.45, blue: 0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        if src.contains("webstream") {
            return LinearGradient(colors: [Color(red: 0.60, green: 0.25, blue: 0.95), Color(red: 0.45, green: 0.10, blue: 0.80)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        if src.contains("meteor") {
            return LinearGradient(colors: [Color(red: 0.95, green: 0.35, blue: 0.25), Color(red: 0.80, green: 0.20, blue: 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        if src.contains("stremify") {
            return LinearGradient(colors: [Color(red: 0.15, green: 0.80, blue: 0.70), Color(red: 0.05, green: 0.60, blue: 0.50)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        if src.contains("knightcrawler") {
            return LinearGradient(colors: [Color(red: 0.85, green: 0.35, blue: 0.75), Color(red: 0.65, green: 0.20, blue: 0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
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
