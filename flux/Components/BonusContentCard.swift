import SwiftUI

struct BonusContentCard: View {
    let item: BonusContentItem
    var fallbackBackdropURL: URL? = nil
    var showTextOverlay: Bool = true
    
    @State private var isHovered = false
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // 1. Full-Bleed 16:9 Vibrant Artwork Thumbnail (Zero Artificial Dimming, zero distortion)
            thumbnailArtwork
                .frame(width: 300, height: 169)
                .clipped()
            
            // 2. Subtle Bottom Text Shadow Gradient (Rest of image is 100% undimmed)
            if showTextOverlay {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.45),
                        .init(color: .black.opacity(0.80), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
            }
            
            // 3. Hover Subtle Brightness Wash (Zero Zoom)
            Color.white.opacity(isHovered ? 0.04 : 0.0)
                .allowsHitTesting(false)
            
            // 5. Title and Metadata on the Card (Bottom Part - Fixed typography, no hover shifts)
            if showTextOverlay {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.85), radius: 3, x: 0, y: 1)
                    
                    Text(item.subtitle ?? item.categoryType)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.85), radius: 2, x: 0, y: 1)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 300, height: 169)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.10, green: 0.10, blue: 0.12))
        )
        // Specular Rim Stroke Highlight on Hover
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: isHovered
                            ? [Color.white.opacity(0.70), Color.white.opacity(0.20), Color.blue.opacity(0.15)]
                            : [Color.white.opacity(0.14), Color.white.opacity(0.03)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isHovered ? 1.5 : 0.75
                )
        )
        .shadow(color: Color.black.opacity(isHovered ? 0.40 : 0.16), radius: isHovered ? 12 : 4, x: 0, y: isHovered ? 6 : 2)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isHovered)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }
    
    @ViewBuilder
    private var thumbnailArtwork: some View {
        if let url = item.thumbnailURL {
            CachedImage(url: url, maxDimension: 800) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: 300, height: 169)
                        .clipped()
                        .transition(.opacity.animation(.easeInOut(duration: 0.25)))
                case .failure:
                    secondaryFallbackArtwork
                case .empty:
                    skeletonLoadingView
                }
            }
        } else {
            secondaryFallbackArtwork
        }
    }

    @ViewBuilder
    private var secondaryFallbackArtwork: some View {
        if let fallbackThumb = item.fallbackThumbnailURL {
            CachedImage(url: fallbackThumb, maxDimension: 600) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: 300, height: 169)
                        .clipped()
                        .transition(.opacity.animation(.easeInOut(duration: 0.25)))
                case .failure:
                    backdropFallbackArtwork
                case .empty:
                    skeletonLoadingView
                }
            }
        } else {
            backdropFallbackArtwork
        }
    }

    @ViewBuilder
    private var backdropFallbackArtwork: some View {
        let artURL = item.fallbackArtURL ?? fallbackBackdropURL
        if let art = artURL {
            CachedImage(url: art, maxDimension: 600) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: 300, height: 169)
                        .clipped()
                        .transition(.opacity.animation(.easeInOut(duration: 0.25)))
                case .failure:
                    fallbackView
                case .empty:
                    skeletonLoadingView
                }
            }
        } else {
            fallbackView
        }
    }
    
    @ViewBuilder
    private var fallbackView: some View {
        ZStack {
            Rectangle()
                .fill(Color(red: 0.12, green: 0.12, blue: 0.14))
            
            LinearGradient(
                colors: [Color.white.opacity(0.05), Color.white.opacity(0.01)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            Image(systemName: item.categoryType == "Trailer" || item.categoryType == "Teaser" ? "play.rectangle.fill" : "sparkles.tv")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white.opacity(0.20))
        }
    }
    
    @ViewBuilder
    private var skeletonLoadingView: some View {
        Rectangle()
            .fill(Color(red: 0.12, green: 0.12, blue: 0.14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.04))
            )
            .shimmer()
    }
}
