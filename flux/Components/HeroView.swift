import SwiftUI
import AVKit

struct HeroView: View {
    let item: MediaItem
    @State private var player: AVPlayer?
    @State private var showVideo = false
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Background Layer
            ZStack {
                AsyncImage(url: item.backdropURL ?? item.imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        Rectangle().fill(Color.gray.opacity(0.3))
                    }
                }
                
                if let trailerURL = item.trailerURL {
                    VideoPlayer(player: player)
                        .disabled(true) // Disable controls
                        .opacity(showVideo ? 1 : 0)
                        .animation(.easeIn(duration: 1.0), value: showVideo)
                        .onAppear {
                            setupPlayer(url: trailerURL)
                        }
                        .onDisappear {
                            player?.pause()
                        }
                }
            }
            .frame(height: 500)
            .clipped()
            .mask(LinearGradient(gradient: Gradient(colors: [.black, .black.opacity(0)]), startPoint: .top, endPoint: .bottom))
            
            // Content Layer
            VStack(alignment: .leading, spacing: 8) {
                Text(item.title)
                    .font(.system(size: 48, weight: .bold))
                    .foregroundColor(.white)
                    .shadow(radius: 10)
                
                Text(item.description)
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(2)
                    .frame(maxWidth: 600, alignment: .leading)
                    .shadow(radius: 10)
                
                Button(action: {}) {
                    Label("Play Now", systemImage: "play.fill")
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .padding(.top, 16)
            }
            .padding(40)
        }
    }
    
    private func setupPlayer(url: URL) {
        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)
        player?.isMuted = true
        player?.actionAtItemEnd = .none
        
        // Loop video
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main) { _ in
            player?.seek(to: .zero)
            player?.play()
        }
        
        // Delay playing to let image load first
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            player?.play()
            showVideo = true
        }
    }
}

#Preview {
    HeroView(item: MockData.sampleMedia[0])
}
