import SwiftUI
import AppKit

struct GenreCard: View {
    let genre: Genre
    @State private var isHovering = false

    /// Bundled, pre-optimized Unsplash artwork (downloaded into Assets.xcassets —
    /// zero network at runtime, the old Unsplash download-links never loaded).
    private var assetName: String {
        switch genre.name {
        case "Sci-Fi": return "genre-scifi"
        default: return "genre-\(genre.name.lowercased())"
        }
    }

    /// SF Symbols validation is done at runtime — some .fill variants don't exist
    /// (ghost.fill, skull.fill) and silently render nothing.
    private var icon: String {
        switch genre.name {
        case "Horror": return "eyes.inverse"
        default: return genre.icon ?? "film.fill"
        }
    }

    private var hasArtwork: Bool {
        NSImage(named: assetName) != nil
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if hasArtwork {
                Image(assetName)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 160, height: 240)
                    .clipped()
            } else {
                LinearGradient(
                    colors: [Color(red: 0.30, green: 0.34, blue: 0.55), Color(red: 0.10, green: 0.12, blue: 0.25)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .frame(width: 160, height: 240)
            }

            // Legibility gradient behind the title
            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .center,
                endPoint: .bottom
            )
            .frame(width: 160, height: 240)

            // Oversized watermark icon (top-right, subtle depth)
            Image(systemName: icon)
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(.white.opacity(0.28))
                .shadow(color: .black.opacity(0.4), radius: 3)
                .frame(width: 160, height: 240, alignment: .topTrailing)
                .padding(.trailing, 10)
                .padding(.top, 10)

            // Bottom-left aligned title
            Text(genre.name)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.7), radius: 4, x: 0, y: 2)
                .padding(.leading, 14)
                .padding(.bottom, 14)
        }
        .frame(width: 160, height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.25), .white.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(isHovering ? 0.45 : 0.25), radius: isHovering ? 14 : 8, x: 0, y: isHovering ? 8 : 4)
        .scaleEffect(isHovering ? 1.04 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
