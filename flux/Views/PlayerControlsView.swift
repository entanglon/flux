import SwiftUI

// MARK: - WWDC 2025 Glass Effect APIs
// Moved to Components/GlassEffect.swift

struct PlayerControlsView: View {
    @Binding var isPlaying: Bool
    @Binding var progress: Double
    @Binding var currentTime: Double
    @Binding var duration: Double
    @Binding var volume: Double
    @Binding var isControlsVisible: Bool
    var isVolumeHUDVisible: Binding<Bool> = .constant(false)
    var title: String
    var subtitle: String
    
    var onPlayPause: () -> Void
    var onSkipForward: () -> Void
    var onSkipBackward: () -> Void
    var onClose: () -> Void
    var onTogglePiP: (() -> Void)? = nil
    
    // Track Support
    var audioTracks: [Track]
    var subtitleTracks: [Track]
    var externalTracks: [StremioSubtitleTrack]
    var onSelectTrack: (Track) -> Void
    var onSelectExternalSub: (StremioSubtitleTrack) -> Void

    // Online subtitle search state
    @State private var onlineSubtitles: [StremioSubtitleTrack] = []
    @State private var isSearchingSubtitles = false
    @State private var subtitleSearchDone = false
    
    @State private var hoverTimer: Timer?
    @State private var showSubtitlePopover = false
    @State private var showAudioPopover = false
    @State private var isCopiedFeedback = false
    
    var body: some View {
        ZStack {
            // Touch/click background to reveal or hide controls (Apple TV behavior)
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture {
                    if isControlsVisible {
                        hideControls()
                    } else {
                        showControls()
                    }
                }
            
            // Controls Overlay
            if isControlsVisible {
                VStack {
                    // Top Bar
                    HStack(alignment: .top) {
                        // Left Group: PIP/Share
                        HStack(spacing: 0) {
                            Button(action: { onTogglePiP?() }) {
                                Image(systemName: "rectangle.on.rectangle")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white.opacity(0.9))
                                    .frame(width: 44, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Picture in Picture")
                            .accessibilityLabel("Picture in Picture")
                            
                            Divider()
                                .frame(height: 16)
                                .background(Color.white.opacity(0.2))
                                
                            Button(action: {
                                let link = PlayerManager.shared.currentMagnetURL ?? PlayerManager.shared.currentStreamURL?.absoluteString ?? ""
                                if !link.isEmpty {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(link, forType: .string)
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        isCopiedFeedback = true
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                        withAnimation {
                                            isCopiedFeedback = false
                                        }
                                    }
                                }
                            }) {
                                Image(systemName: isCopiedFeedback ? "checkmark" : "square.and.arrow.up")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(isCopiedFeedback ? .green : .white.opacity(0.9))
                                    .frame(width: 44, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(isCopiedFeedback ? "Copied to clipboard!" : "Copy playing magnet / stream link")
                            .accessibilityLabel("Copy Stream Link")
                        }
                        .glassEffect(.regular.interactive(), in: .capsule)
                        
                        Spacer()
                        
                        // Right Group: Volume Capsule
                        volumeCapsule
                    }
                    .padding(.horizontal, 60)
                    .padding(.top, 40)
                    
                    Spacer()
                    
                    // Center Controls
                    HStack(spacing: 80) {
                        Button(action: onSkipBackward) {
                            Image(systemName: "gobackward.10")
                                .font(.system(size: 28))
                                .foregroundColor(.white.opacity(0.9))
                                .padding(24)
                                .glassEffect(.regular.interactive(), in: .circle)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Skip backward 10 seconds")
                        
                        Button(action: onPlayPause) {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 44, weight: .bold)) // Slightly Larger
                                .foregroundColor(.white) // Pure White
                                .padding(36) // Larger Hit Area
                                .glassEffect(.regular.interactive(), in: .circle)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isPlaying ? "Pause" : "Play")
                        
                        Button(action: onSkipForward) {
                            Image(systemName: "goforward.10")
                                .font(.system(size: 28))
                                .foregroundColor(.white.opacity(0.9))
                                .padding(24)
                                .glassEffect(.regular.interactive(), in: .circle)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Skip forward 10 seconds")
                    }
                    
                    Spacer()
                    
                    // Bottom Bar
                    VStack(alignment: .leading, spacing: 24) {
                        // Info & Options Row
                        HStack(alignment: .bottom) { // Keep bottom alignment for text baseline match
                            // Title & Subtitle (Metadata)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(subtitle) // "S1, E1 . We Is Us"
                                    .font(.system(size: 15, weight: .semibold)) // Slightly larger
                                    .foregroundColor(.white.opacity(0.7))
                                    .shadow(radius: 2)
                                
                                Text(title) // "Pluribus"
                                    .font(.system(size: 36, weight: .bold)) // Larger Cinematic Title
                                    .foregroundColor(.white)
                                    .shadow(radius: 4)
                            }
                            
                            Spacer()
                            
                            // Audio/Subtitle/Settings Pill
                            // Audio/Subtitle Pill
                            HStack(spacing: 0) {
                                // Subtitles Button
                                Button {
                                    showSubtitlePopover.toggle()
                                } label: {
                                    Image(systemName: "captions.bubble.fill")
                                        .font(.system(size: 14))
                                        .foregroundColor(.white.opacity(0.9))
                                        .frame(width: 46, height: 36)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Subtitles menu")
                                .popover(isPresented: $showSubtitlePopover, arrowEdge: .bottom) {
                                    VStack(alignment: .leading, spacing: 0) {
                                        // Online subtitle search (OpenSubtitles addon etc.)
                                        VStack(alignment: .leading, spacing: 8) {
                                            Button {
                                                Task {
                                                    isSearchingSubtitles = true
                                                    subtitleSearchDone = false
                                                    if let item = PlayerManager.shared.currentItem {
                                                        onlineSubtitles = await SubtitleManager.shared.fetchSubtitles(
                                                            for: item,
                                                            season: PlayerManager.shared.currentSeason,
                                                            episode: PlayerManager.shared.currentEpisode
                                                        )
                                                    }
                                                    isSearchingSubtitles = false
                                                    subtitleSearchDone = true
                                                }
                                            } label: {
                                                HStack(spacing: 6) {
                                                    if isSearchingSubtitles {
                                                        ProgressView().controlSize(.mini)
                                                    } else {
                                                        Image(systemName: "globe")
                                                            .font(.system(size: 12, weight: .semibold))
                                                        Text("Search Online Subtitles")
                                                            .font(.system(size: 12, weight: .medium))
                                                    }
                                                }
                                                .foregroundColor(.white)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(Color.white.opacity(0.12))
                                                .cornerRadius(6)
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(isSearchingSubtitles)
                                            
                                            ForEach(onlineSubtitles) { sub in
                                                Button {
                                                    onSelectExternalSub(sub)
                                                    showSubtitlePopover = false
                                                } label: {
                                                    HStack(spacing: 8) {
                                                        Text(sub.language.uppercased())
                                                            .font(.system(size: 10, weight: .heavy))
                                                            .foregroundStyle(.black)
                                                            .frame(width: 34, height: 18)
                                                            .background(Capsule().fill(Color.white.opacity(0.85)))

                                                        VStack(alignment: .leading, spacing: 1) {
                                                            Text("Online subtitle")
                                                                .font(.system(size: 12, weight: .medium))
                                                                .foregroundStyle(.white)
                                                                .lineLimit(1)
                                                            if let source = sub.source {
                                                                Text("via \(source)")
                                                                    .font(.system(size: 10))
                                                                    .foregroundStyle(.secondary)
                                                                    .lineLimit(1)
                                                            }
                                                        }
                                                        Spacer()
                                                    }
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 5)
                                                    .contentShape(Rectangle())
                                                }
                                                .buttonStyle(.plain)
                                            }

                                            if subtitleSearchDone && onlineSubtitles.isEmpty {
                                                Text("No online subtitles found")
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(.secondary)
                                                    .padding(.horizontal, 8)
                                                    .padding(.bottom, 6)
                                            }

                                            Divider().background(Color.white.opacity(0.15))
                                        }

                                        TrackSelectionList(
                                            title: "Subtitles",
                                            tracks: subtitleTracks,
                                            externalTracks: externalTracks,
                                            onSelect: onSelectTrack,
                                            onSelectExternal: onSelectExternalSub
                                        )
                                    }
                                }
                                
                                Divider()
                                    .frame(height: 20)
                                    .background(Color.white.opacity(0.2))
                                
                                // Audio Button
                                Button {
                                    showAudioPopover.toggle()
                                } label: {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 14))
                                        .foregroundColor(.white.opacity(0.9))
                                        .frame(width: 46, height: 36)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Audio tracks menu")
                                .popover(isPresented: $showAudioPopover, arrowEdge: .bottom) {
                                    TrackSelectionList(
                                        title: "Audio", 
                                        tracks: audioTracks, 
                                        externalTracks: [], 
                                        onSelect: onSelectTrack,
                                        onSelectExternal: { _ in }
                                    )
                                }
                            }
                            .glassEffect(.regular.interactive(), in: .capsule)
                            .padding(.bottom, 6)
                        }
                        .padding(.horizontal, 60)
                        
                        // Progress Bar Row (Full Width)
                        HStack(spacing: 20) {
                            Text(formatTime(currentTime))
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.8))
                                .shadow(radius: 2)
                            
                            // Custom Slider
                            GeometryReader { geo in
                                let seekTo: (CGFloat) -> Void = { x in
                                    let newProgress = min(max(x / max(geo.size.width, 1), 0), 1)
                                    progress = newProgress
                                    currentTime = newProgress * duration
                                }
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(.white.opacity(0.3))
                                        .frame(height: 5)

                                    Capsule()
                                        .fill(Color.white)
                                        .frame(width: geo.size.width * progress, height: 5)
                                        .shadow(color: .white.opacity(0.5), radius: 4)

                                    Circle()
                                        .fill(Color.white)
                                        .frame(width: 18, height: 18)
                                        .offset(x: geo.size.width * progress - 9)
                                        .shadow(radius: 4)
                                }
                                .contentShape(Rectangle())
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Playback progress")
                                .accessibilityValue("\(Int(progress * 100)) percent, \(formatTime(currentTime)) of \(formatTime(duration))")
                                .onHover { hovering in
                                    if hovering {
                                        NSCursor.pointingHand.push()
                                    } else {
                                        NSCursor.pop()
                                    }
                                }
                                // Click anywhere on the bar to seek.
                                .gesture(
                                    SpatialTapGesture()
                                        .onEnded { value in
                                            seekTo(value.location.x)
                                        }
                                )
                                .simultaneousGesture(
                                    DragGesture(minimumDistance: 1)
                                        .onChanged { value in
                                            seekTo(value.location.x)
                                        }
                                        .onEnded { value in
                                            seekTo(value.location.x)
                                        }
                                )
                            }
                            .frame(height: 18)
                            
                            Text("-\(formatTime(max(0, duration - currentTime)))")
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.8))
                                .shadow(radius: 2)
                        }
                        .padding(.horizontal, 60)
                        .padding(.bottom, 40)
                    }
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            } else if isVolumeHUDVisible.wrappedValue {
                VStack {
                    HStack(alignment: .top) {
                        Spacer()
                        volumeCapsule
                    }
                    .padding(.horizontal, 60)
                    .padding(.top, 40)
                    
                    Spacer()
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                .allowsHitTesting(true)
            }
        }
        .onAppear {
            showControls()
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                NSCursor.unhide()
                if isControlsVisible {
                    showControls()
                } else {
                    hoverTimer?.invalidate()
                    hoverTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { _ in
                        if NSApp.isActive && !isControlsVisible {
                            NSCursor.setHiddenUntilMouseMoves(true)
                        }
                    }
                }
            case .ended:
                break
            }
        }
        .onChange(of: isControlsVisible) { _, newValue in
            if newValue {
                showControls()
            } else {
                hoverTimer?.invalidate()
            }
        }
        .onChange(of: showSubtitlePopover) { _, newValue in
            if newValue { hoverTimer?.invalidate() }
            else { showControls() }
        }
        .onChange(of: showAudioPopover) { _, newValue in
            if newValue { hoverTimer?.invalidate() }
            else { showControls() }
        }
    }
    
    // MARK: - Top-Right Volume Capsule (Interactive Gauge + Boost Indicator)
    private var volumeCapsule: some View {
        let vol = volume
        let percent = Int((vol * 100).rounded())
        let isBoosted = vol > 1.001
        let isMuted = vol <= 0.001

        let iconName: String = {
            if isMuted { return "speaker.slash.fill" }
            if vol <= 0.33 { return "speaker.wave.1.fill" }
            if vol <= 0.66 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        }()

        return HStack(spacing: 8) {
            Button(action: {
                if volume > 0.001 {
                    volume = 0
                } else {
                    volume = 1.0
                }
            }) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isBoosted ? .orange : (isMuted ? .white.opacity(0.45) : .white.opacity(0.9)))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(isMuted ? "Unmute" : "Mute")
            .accessibilityLabel("Mute toggle")

            // Interactive Gauge Bar with 100% Divider Notch
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let midX = w / 2.0

                ZStack(alignment: .leading) {
                    // Track background
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: w, height: h)

                    // 100% divider notch in center
                    Rectangle()
                        .fill(Color.white.opacity(0.45))
                        .frame(width: 1.5, height: h + 2)
                        .position(x: midX, y: h / 2.0)

                    // Base Volume Fill (0% to min(vol, 1.0))
                    let normalRatio = min(max(vol, 0.0), 1.0)
                    let normalWidth = midX * CGFloat(normalRatio)
                    if normalWidth > 0 {
                        Capsule()
                            .fill(Color.white)
                            .frame(width: max(h, normalWidth), height: h)
                    }

                    // Boost Volume Fill (1.0 to vol)
                    if isBoosted {
                        let boostRatio = min(vol - 1.0, 1.0)
                        let boostWidth = midX * CGFloat(boostRatio)
                        Capsule()
                            .fill(LinearGradient(
                                colors: [Color.orange.opacity(0.85), Color.orange],
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                            .frame(width: max(h, boostWidth), height: h)
                            .offset(x: midX)
                            .shadow(color: Color.orange.opacity(0.4), radius: 3, x: 0, y: 0)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let clampedX = max(0.0, min(value.location.x, w))
                            let newVol = Double(clampedX / w) * 2.0
                            volume = (newVol * 20.0).rounded() / 20.0
                        }
                )
            }
            .frame(width: 80, height: 6)
            .accessibilityLabel("Volume gauge")
            .accessibilityValue("\(percent) percent")

            // Percentage Label (Orange when boosted)
            Text(isMuted ? "0%" : "\(percent)%")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(isBoosted ? .orange : .white.opacity(0.75))
                .frame(minWidth: 32, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func showControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isControlsVisible = true
        }
        NSCursor.unhide()
        
        hoverTimer?.invalidate()
        
        // Don't schedule hide timer if popover is open
        if showSubtitlePopover || showAudioPopover {
            return
        }
        
        // Exactly 2.5s hide timer (Apple TV player standard)
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { _ in
            if !showSubtitlePopover && !showAudioPopover {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isControlsVisible = false
                }
                if NSApp.isActive {
                    NSCursor.setHiddenUntilMouseMoves(true)
                }
            }
        }
    }

    private func hideControls() {
        hoverTimer?.invalidate()
        withAnimation(.easeInOut(duration: 0.25)) {
            isControlsVisible = false
        }
        if NSApp.isActive {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }
}

// Helper for continuous hover tracking
extension View {
    func continuousHover(perform action: @escaping (CGPoint) -> Void) -> some View {
        self.onContinuousHover { phase in
            switch phase {
            case .active(let location):
                action(location)
            case .ended:
                break
            }
        }
    }
}

struct TrackSelectionList: View {
    let title: String
    let tracks: [Track]
    let externalTracks: [StremioSubtitleTrack]
    let onSelect: (Track) -> Void
    let onSelectExternal: (StremioSubtitleTrack) -> Void
    
    private var isSubtitles: Bool {
        title.lowercased().contains("sub")
    }
    
    private var isNoneSelected: Bool {
        !tracks.contains(where: { $0.isSelected })
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 8)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if isSubtitles {
                        Button {
                            onSelect(Track(id: -1, type: "sub", title: "Off", lang: "", isSelected: true))
                        } label: {
                            HStack {
                                if isNoneSelected {
                                    Image(systemName: "checkmark")
                                        .frame(width: 16)
                                } else {
                                    Spacer().frame(width: 16)
                                }
                                
                                Text("Off")
                                    .fontWeight(isNoneSelected ? .semibold : .regular)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(isNoneSelected ? Color.white.opacity(0.1) : Color.clear)
                        .cornerRadius(6)
                        
                        Divider()
                            .background(Color.white.opacity(0.1))
                            .padding(.vertical, 2)
                    }
                    
                    ForEach(tracks) { track in
                        Button {
                            onSelect(track)
                        } label: {
                            HStack {
                                if track.isSelected {
                                    Image(systemName: "checkmark")
                                        .frame(width: 16)
                                } else {
                                    Spacer().frame(width: 16)
                                }
                                
                                Text(track.displayName)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(track.isSelected ? Color.white.opacity(0.1) : Color.clear)
                        .cornerRadius(6)
                    }
                }
                .padding(8)
                
                if !externalTracks.isEmpty {
                    Divider()
                        .background(Color.white.opacity(0.1))
                        .padding(.vertical, 4)
                    
                    Text("External Sources")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(externalTracks) { sub in
                            Button {
                                onSelectExternal(sub)
                            } label: {
                                HStack {
                                    Spacer().frame(width: 16)
                                    Text(sub.language)
                                    if let source = sub.source {
                                        Text("(\(source))")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .cornerRadius(6)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .frame(minWidth: 200, maxHeight: 300)
        .padding(.bottom, 8)
    }
}

