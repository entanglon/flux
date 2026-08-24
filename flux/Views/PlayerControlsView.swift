import SwiftUI

// MARK: - WWDC 2025 Glass Effect APIs
// Moved to Components/GlassEffect.swift

struct PlayerControlsView: View {
    @Binding var isPlaying: Bool
    @Binding var progress: Double
    @Binding var currentTime: Double
    @Binding var duration: Double
    @Binding var volume: Double
    var title: String
    var subtitle: String
    
    var onPlayPause: () -> Void
    var onSkipForward: () -> Void
    var onSkipBackward: () -> Void
    var onClose: () -> Void
    
    // Track Support
    var audioTracks: [Track]
    var subtitleTracks: [Track]
    var externalTracks: [StremioSubtitleTrack]
    var onSelectTrack: (Track) -> Void
    var onSelectExternalSub: (StremioSubtitleTrack) -> Void
    
    @State private var isControlsVisible = true
    @State private var hoverTimer: Timer?
    @State private var showSubtitlePopover = false
    @State private var showAudioPopover = false
    @Namespace private var glassNamespace // WWDC 2025 Namespace
    
    var body: some View {
        ZStack {
            // Invisible background to track mouse movement
            Color.black.opacity(0.001)
                .onHover { hovering in
                    if hovering {
                        showControls()
                    }
                }
                .continuousHover { _ in
                    showControls()
                }
            
            // Controls Overlay
            if isControlsVisible {
                VStack {
                    // Top Bar
                    HStack(alignment: .top) {
                        // Left Group: PIP/Share
                        HStack(spacing: 0) {
                            Button(action: {}) {
                                Image(systemName: "rectangle.on.rectangle")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white.opacity(0.9))
                                    .frame(width: 44, height: 32)
                            }
                            .buttonStyle(.plain)
                            
                            Divider()
                                .frame(height: 16)
                                .background(Color.white.opacity(0.2))
                                
                            Button(action: {}) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white.opacity(0.9))
                                    .frame(width: 44, height: 32)
                            }
                            .buttonStyle(.plain)
                        }
                        .glassEffect(.regular.interactive(), in: .capsule)
                        
                        Spacer()
                        
                        // Right Group: Volume
                        HStack(spacing: 12) {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.8))
                            
                            Slider(value: $volume, in: 0...1)
                                .frame(width: 80)
                                .tint(.white)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .glassEffect(.regular.interactive(), in: .capsule)
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
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: onPlayPause) {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 44, weight: .bold)) // Slightly Larger
                                .foregroundColor(.white) // Pure White
                                .padding(36) // Larger Hit Area
                                .glassEffect(.regular.interactive(), in: .circle)
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: onSkipForward) {
                            Image(systemName: "goforward.10")
                                .font(.system(size: 28))
                                .foregroundColor(.white.opacity(0.9))
                                .padding(24)
                                .glassEffect(.regular.interactive(), in: .circle)
                        }
                        .buttonStyle(.plain)
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
                                }
                                .frame(width: 44, height: 36)
                                .contentShape(Rectangle())
                                .buttonStyle(.plain)
                                .popover(isPresented: $showSubtitlePopover, arrowEdge: .bottom) {
                                    TrackSelectionList(
                                        title: "Subtitles", 
                                        tracks: subtitleTracks, 
                                        externalTracks: externalTracks, 
                                        onSelect: onSelectTrack,
                                        onSelectExternal: onSelectExternalSub
                                    )
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
                                }
                                .frame(width: 44, height: 36)
                                .contentShape(Rectangle())
                                .buttonStyle(.plain)
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
                                .gesture(
                                    DragGesture()
                                        .onChanged { value in
                                            let newProgress = value.location.x / geo.size.width
                                            progress = min(max(newProgress, 0), 1)
                                            currentTime = progress * duration
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
                    .background(
                        LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                            .allowsHitTesting(false)
                    )
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }
        }
        .onAppear {
            showControls()
        }
        // Force Arrow Cursor
        .onHover { _ in
            NSCursor.arrow.push()
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
    
    private func showControls() {
        withAnimation {
            isControlsVisible = true
        }
        NSCursor.unhide()
        
        hoverTimer?.invalidate()
        
        // Don't schedule hide timer if popover is open
        if showSubtitlePopover || showAudioPopover {
            return
        }
        
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            // Double check before hiding
            if !showSubtitlePopover && !showAudioPopover {
                withAnimation {
                    isControlsVisible = false
                }
                // Only hide if we are the key window/active (simple check)
                if NSApp.isActive {
                    NSCursor.setHiddenUntilMouseMoves(true)
                }
            }
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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 8)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
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

