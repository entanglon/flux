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
    @State private var hasNewEpisode = false
    
    init(item: MediaItem, aspectRatio: CardAspectRatio = .landscape, progress: Double? = nil, showTitle: Bool = true) {
        self._displayItem = State(initialValue: item)
        self.item = item
        self.aspectRatio = aspectRatio
        self.progress = progress
        self.showTitle = showTitle
    }
    
    private var userData: UserDataService { UserDataService.shared }
    
    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }

    private var strokeGradient: LinearGradient {
        LinearGradient(
            colors: isHovering
                ? [Color.white.opacity(0.70), Color.white.opacity(0.20), Color.blue.opacity(0.15)]
                : [Color.white.opacity(0.15), Color.white.opacity(0.03)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            imagePlate
            
            // Text Content
            if showTitle {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayItem.title)
                        .font(.system(size: 15, weight: isHovering ? .bold : .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    
                    Text(displayItem.category)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 4)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .task(id: displayItem.id) {
            // Auto-enrich if poster/backdrop is missing (e.g. History items from Trakt)
            if displayItem.posterURL == nil || displayItem.backdropURL == nil {
                let enriched = await TMDBEnricher.shared.quickEnrich(displayItem)
                await MainActor.run {
                    self.displayItem = enriched
                }
            }

            // New-episode badge for watchlisted shows (TMDB-id shows only)
            if displayItem.category == "TV Show", !displayItem.id.hasPrefix("tt"),
               userData.watchlist.contains(where: { $0.id == displayItem.id }) {
                hasNewEpisode = await TMDBEnricher.shared.hasAiredNewEpisode(tmdbID: displayItem.id)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayItem.title), \(displayItem.category)\(displayItem.releaseDateYear.map { ", \($0)" } ?? "")")
        .accessibilityHint("Opens title details")
    }

    private var imagePlate: some View {
        ZStack(alignment: .bottomLeading) {
            imageContent

            VStack {
                HStack {
                    badgeOverlay
                    Spacer()
                }
                Spacer()
                HStack {
                    Spacer()
                    menuOverlay
                }
            }

            if progress != nil {
                GeometryReader { geo in
                    progressBarView(totalWidth: geo.size.width)
                }
            }
        }
        .aspectRatio(aspectRatio.ratio, contentMode: .fit)
        .clipShape(cardShape)
        .background(
            cardShape
                .fill(Color(red: 0.10, green: 0.10, blue: 0.12))
        )
        .overlay(
            cardShape.stroke(strokeGradient, lineWidth: isHovering ? 1.5 : 0.75)
        )
        .shadow(color: Color.black.opacity(isHovering ? 0.40 : 0.16), radius: isHovering ? 12 : 4, x: 0, y: isHovering ? 6 : 2)
    }

    @ViewBuilder
    private var imageContent: some View {
        if aspectRatio == .landscape && displayItem.backdropURL == nil {
            ZStack {
                CachedImage(url: displayItem.posterURL ?? displayItem.imageURL) { phase in
                    if let img = phase.image {
                        img.resizable()
                            .aspectRatio(contentMode: .fill)
                            .blur(radius: 16)
                            .overlay(Color.black.opacity(0.45))
                    } else {
                        Rectangle().fill(Color.gray.opacity(0.2))
                    }
                }
                
                CachedImage(url: displayItem.posterURL ?? displayItem.imageURL, maxDimension: 800) { phase in
                    if let img = phase.image {
                        img.resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(.vertical, 6)
                            .shadow(color: .black.opacity(0.6), radius: 6)
                    }
                }
            }
        } else {
            CachedImage(url: aspectRatio == .portrait ? (displayItem.posterURL ?? displayItem.imageURL) : (displayItem.backdropURL ?? displayItem.imageURL), maxDimension: 1200) { phase in
                switch phase {
                case .empty:
                    placeholderView
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure:
                    placeholderView
                @unknown default:
                    placeholderView
                }
            }
        }
    }

    @ViewBuilder
    private var badgeOverlay: some View {
        // Date / "In Theatres" badge (Apple TV / Letterboxd style)
        if !displayItem.isReleased {
            Text(displayItem.cardReleaseDateBadge)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.95))
                .padding(.horizontal, 9)
                .padding(.vertical, 4.5)
                .background(
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                        .glassEffect(.regular, in: .capsule)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 0.75)
                )
                .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 2)
                .padding(8)
        } else if hasNewEpisode {
            Text("NEW EPISODE")
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(.black)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color(red: 0.30, green: 0.95, blue: 0.45)))
                .padding(8)
        }
    }

    @ViewBuilder
    private var menuOverlay: some View {
        if isHovering {
            Menu {
                NavigationLink(value: item) {
                    Label(item.category == "Movie" ? "Go to Movie" : "Go to Show", systemImage: "info.circle")
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
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .buttonStyle(.plain)
            .padding(10)
        }
    }

    @ViewBuilder
    private func progressBarView(totalWidth: CGFloat) -> some View {
        if let progress = progress {
            VStack {
                Spacer()
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.3))
                        .frame(height: 4)
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: totalWidth * progress, height: 4)
                }
                .frame(height: 4)
                .padding(.bottom, 12)
                .padding(.horizontal, 12)
            }
        }
    }

    private var placeholderView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    LinearGradient(
                        colors: [Color.white.opacity(0.06), Color.white.opacity(0.02)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            VStack(spacing: 8) {
                Image(systemName: displayItem.category.lowercased().contains("movie") ? "film" : "tv")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.40))
                
                Text(displayItem.title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.60))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 10)
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
