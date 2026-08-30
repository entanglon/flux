import SwiftUI

struct BonusContentCard: View {
    let item: BonusContentItem
    var fallbackBackdropURL: URL? = nil
    
    @State private var isHovered = false
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // 1. Full-Bleed 16:9 Artwork Thumbnail
            Group {
                if let url = item.thumbnailURL {
                    CachedImage(url: url, maxDimension: 960) { phase in
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
            
            // 2. Cinematic Bottom-Up Shadow Gradient
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.20),
                    .init(color: .black.opacity(0.40), location: 0.55),
                    .init(color: .black.opacity(0.92), location: 1.0)
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
            
            // 4. Centered Frosted Liquid Glass Play Disc
            HStack {
                Spacer()
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(isHovered ? 0.45 : 0.35))
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.interactive(), in: .circle)
                    
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: isHovered ? [.white.opacity(0.8), .white.opacity(0.2)] : [.white.opacity(0.35), .white.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: isHovered ? 1.5 : 1.0
                        )
                        .frame(width: 44, height: 44)
                    
                    Image(systemName: "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.white)
                        .offset(x: 1.5)
                        .shadow(color: .white.opacity(isHovered ? 0.6 : 0.0), radius: 6)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .allowsHitTesting(false)
            
            // 5. Hover Brightness Wash (Zero Zoom)
            Color.white.opacity(isHovered ? 0.05 : 0.0)
                .animation(.easeInOut(duration: 0.2), value: isHovered)
                .allowsHitTesting(false)
            
            // 6. Title and Metadata on the Card (Bottom Part)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 14, weight: isHovered ? .bold : .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
                
                HStack(spacing: 6) {
                    Text(item.subtitle ?? item.categoryType)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                    
                    if item.isStreamableEpisode {
                        Text("•")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.4))
                        Text("Play Episode")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.cyan)
                    }
                }
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
        .shadow(color: isHovered ? Color.white.opacity(0.10) : Color.clear, radius: 14, x: 0, y: 0)
        .shadow(color: isHovered ? Color.black.opacity(0.60) : Color.black.opacity(0.35), radius: isHovered ? 16 : 6, x: 0, y: isHovered ? 8 : 3)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isHovered)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }
    
    @ViewBuilder
    private var fallbackView: some View {
        if let fallback = fallbackBackdropURL {
            CachedImage(url: fallback, maxDimension: 960) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .aspectRatio(16/9, contentMode: .fill)
                } else {
                    Rectangle().fill(Color.white.opacity(0.08))
                }
            }
        } else {
            Rectangle().fill(Color.white.opacity(0.08))
        }
    }
}
