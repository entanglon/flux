import SwiftUI

struct BonusContentCard: View {
    let item: BonusContentItem
    var fallbackBackdropURL: URL? = nil
    
    @State private var isHovered = false
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // 1. Full-Bleed 16:9 Vibrant Artwork Thumbnail (Zero Artificial Dimming)
            Group {
                if let url = item.thumbnailURL {
                    CachedImage(url: url, maxDimension: 600) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(16/9, contentMode: .fill)
                        default:
                            fallbackView
                        }
                    }
                } else {
                    fallbackView
                }
            }
            .frame(width: 300, height: 169)
            .clipped()
            
            // 2. Subtle Bottom Text Shadow Gradient (Rest of image is 100% undimmed)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.45),
                    .init(color: .black.opacity(0.80), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
            
            // 3. Hover Subtle Brightness Wash (Zero Zoom)
            Color.white.opacity(isHovered ? 0.04 : 0.0)
                .allowsHitTesting(false)
            
            // 5. Title and Metadata on the Card (Bottom Part - Fixed typography, no hover shifts)
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
        .frame(width: 300, height: 169)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
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
        .shadow(color: Color.black.opacity(isHovered ? 0.50 : 0.22), radius: isHovered ? 14 : 5, x: 0, y: isHovered ? 7 : 2)
        .shadow(color: isHovered ? Color.white.opacity(0.08) : Color.clear, radius: 10, x: 0, y: 0)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isHovered)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }
    
    @ViewBuilder
    private var fallbackView: some View {
        if let fallback = fallbackBackdropURL {
            CachedImage(url: fallback, maxDimension: 600) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .aspectRatio(16/9, contentMode: .fill)
                } else {
                    Rectangle().fill(.ultraThinMaterial)
                }
            }
        } else {
            Rectangle().fill(.ultraThinMaterial)
        }
    }
}
