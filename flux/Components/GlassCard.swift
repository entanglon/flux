import SwiftUI

enum CardAspectRatio {
    case landscape
    case portrait
    case square
    
    var ratio: CGFloat {
        switch self {
        case .landscape: return 16/9
        case .portrait: return 2/3
        case .square: return 1
        }
    }
}

struct GlassCard: View {
    let item: MediaItem
    var aspectRatio: CardAspectRatio = .landscape
    var progress: Double? = nil
    var showTitle: Bool = true
    
    @State private var displayItem: MediaItem
    @State private var isHovering = false
    
    init(item: MediaItem, aspectRatio: CardAspectRatio = .landscape, progress: Double? = nil, showTitle: Bool = true) {
        self._displayItem = State(initialValue: item)
        self.item = item
        self.aspectRatio = aspectRatio
        self.progress = progress
        self.showTitle = showTitle
    }
    
    @ObservedObject private var userData = UserDataService.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Image Container
            Color.clear
                .aspectRatio(aspectRatio.ratio, contentMode: .fit)
                .overlay(
                    CachedImage(url: aspectRatio == .portrait ? (displayItem.posterURL ?? displayItem.imageURL) : (displayItem.backdropURL ?? displayItem.imageURL)) { phase in
                        switch phase {
                        case .empty:
                            Rectangle()
                                .fill(Color.gray.opacity(0.15))
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        case .failure:
                            Rectangle()
                                .fill(Color.gray.opacity(0.15))
                                .overlay(
                                    Image(systemName: "photo")
                                        .font(.system(size: 20))
                                        .foregroundColor(.white.opacity(0.3))
                                )
                        @unknown default:
                            EmptyView()
                        }
                    }
                )
                // Dimming on Hover
                .overlay(
                    Color.black.opacity(isHovering ? 0.3 : 0.0)
                        .animation(.easeInOut(duration: 0.2), value: isHovering)
                )
                // Menu Button
                .overlay(alignment: .bottomTrailing) {
                    if isHovering {
                         Menu {
                             NavigationLink(value: item) {
                                 Label(item.category == "Movie" ? "Go to Movie" : "Go to Show", systemImage: "info.circle")
                             }
                             
                             Button(action: {}) {
                                 Label(item.category == "Movie" ? "Share Movie" : "Share Show", systemImage: "square.and.arrow.up")
                             }
                             
                             Button(action: {
                                 userData.toggleWatchlist(item)
                             }) {
                                 let isInWatchlist = userData.watchlist.contains { $0.id == item.id }
                                 Label(isInWatchlist ? "Remove from Watchlist" : "Add to Watchlist",
                                       systemImage: isInWatchlist ? "minus.circle" : "plus.circle")
                             }
                             
                         } label: {
                             Image(systemName: "ellipsis")
                                 .font(.system(size: 16, weight: .bold))
                                 .foregroundColor(.white)
                                 .padding(8)
                                 .background(.ultraThinMaterial)
                                 .clipShape(Circle())
                                 .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
                                 .shadow(radius: 4)
                         }
                         .menuStyle(.button)
                         .buttonStyle(.plain)
                         .padding(8)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let progress = progress {
                        GeometryReader { geo in
                            VStack {
                                Spacer()
                                ZStack(alignment: .leading) {
                                    Rectangle()
                                        .fill(Color.white.opacity(0.3))
                                        .frame(height: 4)
                                    Rectangle()
                                        .fill(Color.white)
                                        .frame(width: geo.size.width * progress, height: 4)
                                }
                                .frame(height: 4)
                                .padding(.bottom, 12)
                                .padding(.horizontal, 12)
                            }
                        }
                    }
                }
                .cornerRadius(12)
                .clipped()
                .shadow(color: isHovering ? Color.black.opacity(0.4) : Color.black.opacity(0.2), radius: isHovering ? 12 : 6, x: 0, y: isHovering ? 6 : 3)
            
            // Text Content
            if showTitle {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayItem.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    
                    Text(displayItem.category)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 4)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .task {
            // Auto-enrich if poster/backdrop is missing (e.g. History items from Trakt)
            if displayItem.posterURL == nil || displayItem.backdropURL == nil {
                let enriched = await TMDBEnricher.shared.quickEnrich(displayItem)
                await MainActor.run {
                    self.displayItem = enriched
                }
            }
        }
    }
}

#Preview {
    HStack {
        GlassCard(item: MockData.sampleMedia[0], aspectRatio: .landscape)
            .frame(width: 300)
        GlassCard(item: MockData.sampleMedia[1], aspectRatio: .portrait)
            .frame(width: 200)
    }
    .padding()
    .background(Color.black)
}
