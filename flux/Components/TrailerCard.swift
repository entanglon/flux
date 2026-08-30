import SwiftUI

struct TrailerCard: View {
    let video: TMDBVideo
    var fallbackBackdropURL: URL? = nil
    
    @State private var isHovered = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Widescreen 16:9 Thumbnail Container
            ZStack(alignment: .bottomLeading) {
                // Background Thumbnail (YouTube MaxRes -> HQ -> MediaItem Backdrop)
                Group {
                    if let maxRes = video.maxResThumbnailURL {
                        CachedImage(url: maxRes, maxDimension: 960) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(16/9, contentMode: .fill)
                            default:
                                fallbackImage
                            }
                        }
                    } else {
                        fallbackImage
                    }
                }
                .frame(width: 300, height: 169)
                .clipped()
                
                // Subtle Dark Gradient Overlay for contrast
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.3),
                        .init(color: .black.opacity(0.4), location: 0.7),
                        .init(color: .black.opacity(0.85), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                
                // Frosted Liquid Glass Play Disc
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
                
                // Hover Brightness Wash (Zero Zoom)
                Color.white.opacity(isHovered ? 0.06 : 0.0)
                    .animation(.easeInOut(duration: 0.2), value: isHovered)
                
                // Top-Trailing Video Type Pill
                VStack {
                    HStack {
                        Spacer()
                        Text(video.type.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.black.opacity(0.6)))
                            .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
                            .padding(10)
                    }
                    Spacer()
                }
            }
            .frame(width: 300, height: 169)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            // Specular Highlight Stroke Border on Hover
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
            .shadow(color: isHovered ? Color.black.opacity(0.55) : Color.black.opacity(0.3), radius: isHovered ? 16 : 6, x: 0, y: isHovered ? 8 : 3)
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isHovered)
            
            // Metadata Below Card
            VStack(alignment: .leading, spacing: 4) {
                Text(video.name)
                    .font(.system(size: 14, weight: isHovered ? .bold : .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                
                HStack(spacing: 6) {
                    Text(video.type)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                    
                    Text("•")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                    
                    Text("Watch in Flux")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.cyan.opacity(0.85))
                }
            }
            .frame(width: 300, alignment: .leading)
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }
    
    @ViewBuilder
    private var fallbackImage: some View {
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
