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
                        .font(.system(size: 15, weight: .semibold))
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
        .onChange(of: item) { _, newItem in
            self.displayItem = newItem
        }
        .contextMenu {
            // Right-click parity with the hover ellipsis menu (macOS
            // right-click opens contextMenu natively; hover-only left the
            // card menu undiscoverable for trackpad users).
            NavigationLink(value: item) {
                Label((item.category == "Movie" ? "Go to Movie" : "Go to Show").localized, systemImage: "info.circle")
            }
            Button(action: {
                userData.toggleWatchlist(item)
            }) {
                let isInWatchlist = userData.watchlist.contains { $0.id == item.id }
                Label((isInWatchlist ? "Remove from Watchlist" : "Add to Watchlist").localized,
                      systemImage: isInWatchlist ? "minus.circle" : "plus.circle")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayItem.title), \(displayItem.category)\(displayItem.releaseDateYear.map { ", \($0)" } ?? "")")
        .accessibilityHint("Opens title details")
    }

    private var imagePlate: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .aspectRatio(aspectRatio.ratio, contentMode: .fit)

            imageContent
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()

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
                progressBarOverlay
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
            // No backdrop: single decode on a static gradient. (Previously a
            // full-image .blur(16) + second decode of the same URL — a Gaussian
            // blur composited every frame while scrolling.)
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.16, green: 0.16, blue: 0.20), Color(red: 0.07, green: 0.07, blue: 0.09)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                CachedImage(url: displayItem.posterURL ?? displayItem.imageURL, maxDimension: 480) { phase in
                    if let img = phase.image {
                        img.resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(.vertical, 6)
                            .shadow(color: .black.opacity(0.6), radius: 6)
                    }
                }
            }
        } else {
            // Cards render at ~180-300pt (≈360-600px @2x). Decoding at 480px
            // keeps them tack-sharp while using ~6x less memory than 1200px
            // and easing pressure on the 64MB image cache during scroll.
            CachedImage(url: aspectRatio == .portrait ? (displayItem.posterURL ?? displayItem.imageURL) : (displayItem.backdropURL ?? displayItem.imageURL), maxDimension: 480) { phase in
                switch phase {
                case .empty:
                    placeholderView
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .clipped()
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
                    // glassEffect already provides the material; layering
                    // .ultraThinMaterial underneath doubles backdrop-blur cost.
                    Capsule(style: .continuous)
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
                    Label((item.category == "Movie" ? "Go to Movie" : "Go to Show").localized, systemImage: "info.circle")
                }
                
                Button(action: {
                    userData.toggleWatchlist(item)
                }) {
                    let isInWatchlist = userData.watchlist.contains { $0.id == item.id }
                    Label((isInWatchlist ? "Remove from Watchlist" : "Add to Watchlist").localized,
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

    /// Progress fill via GPU scale transform instead of GeometryReader, so the
    /// bar never forces an extra layout pass per card during scroll.
    @ViewBuilder
    private var progressBarOverlay: some View {
        if let progress = progress {
            VStack {
                Spacer()
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.3))
                        .frame(height: 4)
                    Rectangle()
                        .fill(Color.white)
                        .scaleEffect(x: max(0, min(1, progress)), anchor: .leading)
                }
                .frame(height: 4)
                .padding(.bottom, 12)
                .padding(.horizontal, 12)
            }
        }
    }

    private var placeholderView: some View {
        ZStack {
            // Flat fill, not .ultraThinMaterial: placeholders are visible for
            // every card while images resolve during fast scroll, and backdrop
            // blur per card is one of the most expensive compositor operations.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.10, green: 0.10, blue: 0.12))
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
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
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
