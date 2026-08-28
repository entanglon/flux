import SwiftUI
import AppKit

struct GenreCard: View {
    let genre: Genre
    @State private var isHovering = false

    /// Bundled high-resolution artwork from Assets.xcassets
    private var assetName: String {
        switch genre.name {
        case "Sci-Fi": return "genre-scifi"
        case "Short Films": return "genre-shortfilms"
        case "K-Drama": return "genre-kdrama"
        default: return "genre-\(genre.name.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: ""))"
        }
    }

    private var hasArtwork: Bool {
        NSImage(named: assetName) != nil
    }

    var body: some View {
        Color.clear
            .aspectRatio(2/3, contentMode: .fit)
            .overlay {
                if hasArtwork {
                    Image(assetName)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(
                        colors: [Color(red: 0.30, green: 0.34, blue: 0.55), Color(red: 0.10, green: 0.12, blue: 0.25)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }

                // Apple TV style smooth bottom gradient scrim
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .clear, location: 0.38),
                        .init(color: .black.opacity(0.35), location: 0.65),
                        .init(color: .black.opacity(0.85), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Bottom-left aligned genre title (matches reference design)
                VStack(alignment: .leading) {
                    Spacer()
                    Text(genre.name)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.8), radius: 4, x: 0, y: 2)
                        .padding(.leading, 16)
                        .padding(.bottom, 16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: isHovering ? [.white.opacity(0.55), .white.opacity(0.2)] : [.white.opacity(0.12), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: isHovering ? 1.5 : 0.75
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(isHovering ? 0.45 : 0.25), radius: isHovering ? 14 : 6, x: 0, y: isHovering ? 6 : 3)
            .animation(.easeOut(duration: 0.2), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}
