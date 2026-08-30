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
            
            // 3. Top-Trailing Category Pill
            VStack {
                HStack {
                    Spacer()
                    Text(item.categoryType.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.65)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
                        .padding(10)
                }
                Spacer()
            }
            
            // 4. Hover Subtle Brightness Wash (Zero Zoom)
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
        // Specular Rim Stroke Highlight on Hover
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: isHovered ? [.white.opacity(0.75), .white.opacity(0.25)] : [.white.opacity(0.14), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isHovered ? 1.5 : 0.5
                )
        )
        .shadow(color: Color.black.opacity(isHovered ? 0.50 : 0.25), radius: isHovered ? 12 : 5, x: 0, y: isHovered ? 6 : 2)
        .shadow(color: isHovered ? Color.white.opacity(0.12) : Color.clear, radius: 8, x: 0, y: 0)
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
                    Rectangle().fill(Color(white: 0.12))
                }
            }
        } else {
            Rectangle().fill(Color(white: 0.12))
        }
    }
}
