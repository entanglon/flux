import SwiftUI

struct Channel: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let providerID: Int // TMDB Provider ID
    let logoName: String // System Image or Asset Name (fallback)
    var logoURL: URL? // Remote Logo URL
    let brandColor: Color
    var representativeImageURL: URL? // Optional cover image
    
    // Hardcoded TMDB IDs
    // Netflix: 8, Amazon: 9, Disney: 337, Apple: 350, HBO: 118, Hulu: 15, Peacock: 386, Paramount: 531, Hotstar: 122, Viki: 444
}

struct ChannelCard: View {
    let channel: Channel
    @State private var isHovering = false
    @State private var coverImage: URL? = nil // To store fetched image if not provided
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // 1. Full Background Image
            if let url = channel.representativeImageURL ?? coverImage {
                CachedImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 160, height: 240)
                            .clipped()
                    default:
                        // Loading/Failure Fallback
                        Rectangle()
                            .fill(channel.brandColor.opacity(0.2))
                    }
                }
            } else {
                // Gradient Fallback
                LinearGradient(
                    colors: [channel.brandColor.opacity(0.6), channel.brandColor.opacity(0.2)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            
            // 2. Liquid Glass Logo Area (Bottom 40%)
            ZStack(alignment: .center) {
                if let logoURL = channel.logoURL {
                    CachedImage(url: logoURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .padding(12)
                        default:
                             // Fallback Text/Icon
                             if channel.logoName.contains(".") {
                                Image(systemName: channel.logoName)
                                    .font(.system(size: 32))
                                    .foregroundStyle(.white)
                             } else {
                                styledLogo(channel.logoName)
                                    .scaleEffect(0.8)
                             }
                        }
                    }
                } else if channel.logoName.contains(".") {
                    Image(systemName: channel.logoName)
                        .font(.system(size: 32))
                        .foregroundStyle(.white)
                } else {
                    styledLogo(channel.logoName)
                        .scaleEffect(0.8)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 96) // 40% of 240
            .glassEffect(.clear, in: .rect)
        }
        .frame(width: 160, height: 240) // Standard Portrait Size
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.10, green: 0.10, blue: 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: isHovering
                            ? [Color.white.opacity(0.70), Color.white.opacity(0.20), channel.brandColor.opacity(0.40)]
                            : [Color.white.opacity(0.15), Color.white.opacity(0.03)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isHovering ? 1.5 : 0.75
                )
        )
        .shadow(color: isHovering ? channel.brandColor.opacity(0.45) : Color.black.opacity(0.20), radius: isHovering ? 12 : 4, x: 0, y: isHovering ? 6 : 2)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
    
    // Helper to style text as a logo if image is missing
    @ViewBuilder
    func styledLogo(_ text: String) -> some View {
        if text.lowercased().contains("netflix") {
            Text("NETFLIX").font(.custom("Bebas Neue", size: 28)).foregroundColor(Color(red: 229/255, green: 9/255, blue: 20/255))
        } else if text.lowercased().contains("hbo") {
            Text("HBO").font(.system(size: 28, weight: .black)).foregroundColor(.white)
        } else if text.lowercased().contains("prime") {
            Text("prime video").font(.system(size: 20, weight: .bold)).foregroundColor(.white)
        } else if text.lowercased().contains("hulu") {
            Text("hulu").font(.system(size: 28, weight: .heavy)).foregroundColor(.white)
        } else {
             Text(text)
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}
