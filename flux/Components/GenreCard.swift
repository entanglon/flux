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

    private var hasArtwork: Bool {
        NSImage(named: assetName) != nil
    }

    var body: some View {
        // Color.clear + aspectRatio defines the layout bounds; the fill image is
        // an overlay constrained to those bounds and clipped — its intrinsic
        // size can never leak into layout (which broke shapes and edge clicks).
        Color.clear
            .aspectRatio(2/3, contentMode: .fit)
            .overlay {
                if hasArtwork {
                    Image(assetName)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(
                        colors: [Color(red: 0.30, green: 0.34, blue: 0.55), Color(red: 0.10, green: 0.12, blue: 0.25)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }

                // Legibility gradient behind the title
                LinearGradient(
                    colors: [.clear, .black.opacity(0.75)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                // Bottom-left aligned title
                VStack(alignment: .leading) {
                    Spacer()
                    Text(genre.name)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.7), radius: 4, x: 0, y: 2)
                        .padding(.leading, 14)
                        .padding(.bottom, 14)
                }
            }
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
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(isHovering ? 0.45 : 0.25), radius: isHovering ? 14 : 8, x: 0, y: isHovering ? 8 : 4)
            .onHover { hovering in
                isHovering = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}
