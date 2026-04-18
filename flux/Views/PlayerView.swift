import SwiftUI

struct PlayerView: View {
    @StateObject private var mpv = MPVController()
    @ObservedObject private var playerManager = PlayerManager.shared
    @State private var showExitWarning = false
    @Environment(\.dismiss) private var dismiss // Add dismiss environment
    var item: MediaItem? // Optional item to play
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // Video Layer
            MPVVideoView(controller: mpv)
                .ignoresSafeArea()
                .onAppear {
                    mpv.onPlaybackError = {
                        playerManager.tryNextStream()
                    }
                }
            
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
                title: item?.title ?? "Unknown Title",
                subtitle: getSubtitle(),
                onPlayPause: { mpv.togglePlayPause() },
                onSkipForward: { mpv.seek(relative: 15) }, 
                onSkipBackward: { mpv.seek(relative: -15) },
                onClose: {
                    playerManager.close()
                    dismiss() // Dismiss the window
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
        }
        .focusable() // Make the view capable of receiving key presses
        .focusEffectDisabled() // Remove the blue focus ring
        .onKeyPress(.space) {
            mpv.togglePlayPause()
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
            // If URL is already present (Instant Replay), start playing
            if let url = playerManager.currentStreamURL {
                print("PlayerView: onAppear found url, playing...")
                mpv.play(url: url)
            }
        }
        .onDisappear {
            playerManager.updateWatchProgress(time: mpv.timePos, duration: mpv.duration)
            mpv.pause()
            mpv.stop()
        }
        .onChange(of: playerManager.currentStreamURL) { _, newURL in
            if let url = newURL {
                print("PlayerView: URL changed to \(url), playing...")
                mpv.play(url: url)
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
        
        // Stream Selection UI
        if !playerManager.isLoading && playerManager.currentStreamURL == nil && !playerManager.availableStreams.isEmpty {
            streamSelectionView
        }
        
        // Next Episode Overlay
        if let next = playerManager.nextEpisodeInfo, mpv.isPlaying, mpv.progress > 0.95 {
             nextEpisodeButton(season: next.season, episode: next.episode)
        }
    }
    
    @ViewBuilder
    private func nextEpisodeButton(season: Int, episode: Int) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button(action: {
                    playerManager.playNextEpisode()
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: "forward.end.fill")
                            .font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Next Episode")
                                .font(.caption).fontWeight(.bold).textCase(.uppercase)
                                .foregroundStyle(.white.opacity(0.8))
                            Text("S\(season) E\(episode)")
                                .font(.headline).fontWeight(.bold)
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                    .shadow(radius: 20)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 80) // Above control bar
                .padding(.trailing, 40)
            }
        }
        .transition(.opacity)
    }
    
    private var loadingView: some View {
        ZStack {
            Color.black.opacity(0.5)
            ProgressView("Finding Stream...")
                .controlSize(.large)
                .tint(.white)
                .foregroundColor(.white)
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
                playerManager.close()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
    
    private var streamSelectionView: some View {
        VStack(spacing: 20) {
            Text("Select Stream")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(playerManager.availableStreams) { stream in
                        Button(action: {
                            playerManager.selectStream(stream)
                        }) {
                            HStack {
                                HStack(spacing: 6) {
                                    Text(stream.quality)
                                        .font(.caption)
                                        .fontWeight(.bold)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(qualityColor(stream.quality))
                                        .foregroundColor(.white)
                                        .cornerRadius(6)
                                        
                                    if let lang = stream.language {
                                        Text(lang)
                                            .font(.caption)
                                            .fontWeight(.bold)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.blue.opacity(0.8))
                                            .foregroundColor(.white)
                                            .cornerRadius(6)
                                    }
                                    
                                    if let size = stream.size {
                                        Text(size)
                                            .font(.caption)
                                            .fontWeight(.bold)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.gray.opacity(0.8))
                                            .foregroundColor(.white)
                                            .cornerRadius(6)
                                    }
                                }
                                
                                VStack(alignment: .leading) {
                                    Text(stream.title)
                                        .font(.body)
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                    Text(stream.source)
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.7))
                                }
                                
                                Spacer()
                                
                                Image(systemName: "play.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.white.opacity(0.8))
                            }
                            .padding()
                            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .frame(maxWidth: 500, maxHeight: 600)
            
            Button("Cancel") {
                playerManager.close()
                dismiss()
            }
            .buttonStyle(.plain)
            .foregroundColor(.white.opacity(0.7))
        }
        .padding()
        .glassEffect(.regular.tint(.clear), in: .rect(cornerRadius: 20))
        .shadow(radius: 20)
    }
    
    func qualityColor(_ quality: String) -> Color {
        switch quality {
        case "4K": return .purple
        case "1080p": return .blue
        case "720p": return .green
        default: return .gray
        }
    }
    
    func getSubtitle() -> String {
        if let season = PlayerManager.shared.currentSeason, let episode = PlayerManager.shared.currentEpisode {
            return "S\(season):E\(episode)"
        }
        return item?.description ?? "No description"
    }
}
