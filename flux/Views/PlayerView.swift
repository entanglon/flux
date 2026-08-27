import SwiftUI
import Combine

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
            
            // Video Layer
            MPVVideoView(controller: mpv)
                .ignoresSafeArea()
            
            // Controls Layer
            PlayerControlsView(
                isPlaying: $mpv.isPlaying,
                progress: Binding(
                    get: { mpv.progress },
                    set: { 
                         // Seek to absolute time based on percentage
                         let targetTime = $0 * mpv.duration
                         mpv.seek(absolute: targetTime)
                         
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
                onSkipForward: { mpv.seek(relative: 15) }, 
                onSkipBackward: { mpv.seek(relative: -15) },
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

            // Skip Intro / Next Episode — bottom-right floating button (Apple TV style)
            // Only visible when player controls are hidden
            if !isControlsVisible {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        if item?.category == "TV Show" && mpv.isPlaying && !mpv.isUserPaused
                            && mpv.timePos > 4 && mpv.timePos < 90 && mpv.duration > 120 {
                            Button {
                                mpv.seek(absolute: 95)
                            } label: {
                                Text("Skip Intro")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .transition(.opacity)
                        }

                        if let next = playerManager.nextEpisodeInfo, mpv.isPlaying && mpv.progress > 0.90 && mpv.progress < 1.0 {
                            Button {
                                playerManager.playNextEpisode()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "forward.end.fill")
                                        .font(.system(size: 11))
                                    Text("Next: S\(next.season) E\(next.episode)")
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(.ultraThinMaterial, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .transition(.opacity)
                        }
                    }
                    .padding(.trailing, 40)
                    .padding(.bottom, 40)
                }
            }
        }
        .focusable() // Make the view capable of receiving key presses
        .focusEffectDisabled() // Remove the blue focus ring
        .onKeyPress(.space) {
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
            mpv.seek(relative: -10)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            mpv.seek(relative: 10)
            return .handled
        }
        .onKeyPress(.upArrow) {
            mpv.setVolume(min(mpv.volume + 0.05, 1.0))
            return .handled
        }
        .onKeyPress(.downArrow) {
            mpv.setVolume(max(mpv.volume - 0.1, 0.0))
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
            } else if let url = playerManager.currentStreamURL {
                // If URL is already present (Instant Replay), start playing
                print("PlayerView: onAppear found url, playing...")
                mpv.play(url: url)
            }
        }
        .onDisappear {
            // Entering PiP closes this window as a deliberate handoff — the
            // floating panel owns the core now. Saving progress or stopping
            // mpv here would kill playback mid-handoff.
            guard !PiPManager.shared.isHandingOffCore else { return }
            playerManager.updateWatchProgress(time: mpv.timePos, duration: mpv.duration)
            mpv.pause()
            mpv.stop()
            playerManager.endSession()
        }
        .onChange(of: playerManager.currentStreamURL) { _, newURL in
            if let url = newURL {
                print("PlayerView: URL changed to \(url), playing...")
                // Reset buffering progress + auto-play cancellation for the new stream
                animatedProgress = 0.0
                autoPlayCancelled = false
                mpv.play(url: url)
            }
        }
        // Resume-after-PiP-expand: once the fresh stream is producing frames,
        // jump to the position the floating panel was at (once).
        .onChange(of: mpv.timePos) { _, t in
            guard let resume = playerManager.pendingResumeTime else { return }
            guard t > 0.3, mpv.duration > 0 else { return }
            playerManager.pendingResumeTime = nil
            if abs(t - resume) > 1.5 {
                print("PlayerView: resuming after PiP expand at \(Int(resume))s")
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
        
        // Logo Buffering Overlay (Stremio-style real logo fill loading bar)
        if isBufferingOverlayActive {
            logoBufferingView
        }
        
        // Stream Selection UI
        if !playerManager.isLoading && playerManager.currentStreamURL == nil && !playerManager.availableStreams.isEmpty {
            streamSelectionView
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
    
    private var isBufferingOverlayActive: Bool {
        guard !playerManager.isLoading, playerManager.currentStreamURL != nil else { return false }
        if mpv.isUserPaused { return false }
        
        let isInitialLoad = !mpv.isPlaying || mpv.timePos < 0.5
        let isMidPlayBuffer = mpv.isBuffering || mpv.isSeeking
        
        return isInitialLoad || isMidPlayBuffer
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
    
    private var logoBufferingView: some View {
        ZStack {
            // 1. Fullscreen backdrop picture
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
            
            // 2. Subtle dark vignette gradient
            LinearGradient(
                colors: [.black.opacity(0.4), .black.opacity(0.2), .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            // 3. Center Official Logo / Title vibrant fill loading bar
            let realProgress = CGFloat(min(1.0, max(0.0, animatedProgress)))
            
            VStack(spacing: 24) {
                if let media = item {
                    let logoURL = media.logoURL ?? (media.id.starts(with: "tt") ? URL(string: "https://images.metahub.space/logo/medium/\(media.id)/img") : nil)
                    
                    ZStack {
                        if let lURL = logoURL {
                            // Base translucent watermark logo
                            AsyncImage(url: lURL) { img in
                                img.resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 150)
                                    .opacity(0.25)
                                    .shadow(color: .black.opacity(0.8), radius: 10, x: 0, y: 4)
                            } placeholder: {
                                EmptyView()
                            }
                            
                            // Real progress fill logo (left-to-right fill)
                            AsyncImage(url: lURL) { img in
                                img.resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 150)
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

            if mpv.isPlaying && mpv.timePos >= 0.5 {
                withAnimation(.easeOut(duration: 0.3)) {
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

            // Buffer-readiness metric (real data): how full is mpv's pre-roll
            // demuxer cache vs its target (cache-secs=10). Reaches 100% exactly
            // when playback starts. NOTE: cacheTime/duration is WRONG here — a
            // 10s cache on a 2h movie is <0.2% and the fill would never move.
            let cacheTime = mpv.demuxerCacheTime
            print("[BUFFER] cacheTime=\(String(format: "%.1f", cacheTime))s playing=\(mpv.isPlaying) buffering=\(mpv.isBuffering)")
            let fill = min(0.99, cacheTime / 10.0)

            if fill > 0.005 {
                withAnimation(.easeOut(duration: 0.3)) {
                    self.animatedProgress = max(self.animatedProgress, fill)
                }
            }
        }
        .onAppear {
            animatedProgress = 0.0
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulseScale = 1.03
            }
        }
        .transition(.opacity)
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
        if allStreams.contains(where: { $0.isTorrent }) {
            dynamicFilters.append("Torrents")
        }
        if allStreams.contains(where: { !$0.isTorrent }) {
            dynamicFilters.append("Direct")
        }
        // Quality filters — only show qualities that exist
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
        
        return VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("Select Stream")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                if playerManager.isFetchingStreams {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(.blue)
                        Text("Searching Streams... (\(allStreams.count) found)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                } else {
                    Text("\(allStreams.count) streams found")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            
            // Dynamic Category / Source Filter Tabs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(dynamicFilters, id: \.self) { filter in
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedStreamFilter = filter
                            }
                        }) {
                            Text(filter)
                                .font(.system(size: 12, weight: .bold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    selectedStreamFilter == filter
                                    ? Color.blue
                                    : Color.white.opacity(0.12)
                                )
                                .foregroundColor(
                                    selectedStreamFilter == filter
                                    ? .white
                                    : .white.opacity(0.8)
                                )
                                .cornerRadius(20)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal)
            
            ScrollView {
                LazyVStack(spacing: 12) {
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
                        .padding(.top, 40)
                    } else if filteredStreams.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "film.stack")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                            Text("No streams found for \"\(selectedStreamFilter)\"")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 40)
                    } else {
                        ForEach(filteredStreams) { stream in
                            StreamRowItemView(stream: stream) {
                                playerManager.selectStream(stream)
                            }
                        }
                    }
                }
                .padding()
            }
            .frame(maxHeight: 440)
            
            Button("Cancel") {
                playerManager.close()
                dismiss()
            }
            .buttonStyle(.plain)
            .foregroundColor(.white.opacity(0.7))
        }
        .padding(20)
        .frame(width: 620)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 10)
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
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.mint.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(6)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.12))
                        .foregroundColor(.yellow)
                        .cornerRadius(6)
                }
            }
        }
    }

    /// Season-pack indicator: listed size is the whole pack; playback extracts only
    /// the requested episode.
    private var packBadge: some View {
        Group {
            if stream.isSeasonPack {
                HStack(spacing: 3) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 9))
                    Text("PACK")
                        .font(.system(size: 9, weight: .heavy))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.75))
                .foregroundColor(.white)
                .cornerRadius(6)
            }
        }
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    // Provider Badge
                    Text(stream.source)
                        .font(.caption2)
                        .fontWeight(.heavy)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(providerColor(stream.source))
                        .foregroundColor(.white)
                        .cornerRadius(6)
                    
                    // Quality Badge
                    Text(stream.quality)
                        .font(.caption2)
                        .fontWeight(.heavy)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(qualityColor(stream.quality))
                        .foregroundColor(.white)
                        .cornerRadius(6)
                    
                    // Seeders / Peers
                    if let seeders = stream.seeders {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 10))
                            Text("\(seeders)")
                                .font(.caption2)
                                .fontWeight(.bold)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.8))
                        .foregroundColor(.white)
                        .cornerRadius(6)
                    }
                    
                    // Size Badge (packs show total size explicitly)
                    if let size = stream.size {
                        Text(stream.isSeasonPack ? "\(size) pack" : size)
                            .font(.caption2)
                            .fontWeight(.bold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.15))
                            .foregroundColor(.white.opacity(0.9))
                            .cornerRadius(6)
                    }
                    
                    // Language Badge
                    if let lang = stream.language {
                        Text(lang)
                            .font(.caption2)
                            .fontWeight(.bold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.indigo.opacity(0.8))
                            .foregroundColor(.white)
                            .cornerRadius(6)
                    }
                    
                    Spacer()

                    packBadge

                    healthBadge

                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundColor(isHovered ? .blue : .white.opacity(0.9))
                        .scaleEffect(isHovered ? 1.15 : 1.0)
                }
                
                Text(stream.cleanTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.95))
                    .lineLimit(isHovered ? nil : 2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: isHovered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(12)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isHovered ? Color.blue.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.18)) {
                isHovered = hovering
            }
        }
    }
    
    private func providerColor(_ source: String) -> Color {
        let src = source.lowercased()
        if src.contains("hydra") { return .cyan }
        if src.contains("torrent") { return .orange }
        return .purple
    }
    
    private func qualityColor(_ quality: String) -> Color {
        switch quality {
        case "4K": return .purple
        case "1080p": return .blue
        case "720p": return .green
        default: return .gray
        }
    }
}
