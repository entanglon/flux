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

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
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

    @ViewBuilder
    private var artworkView: some View {
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
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            artworkView

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

            VStack(alignment: .leading) {
                Spacer()
                Text(genre.name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 4, x: 0, y: 2)
                    .padding(.leading, 16)
                    .padding(.bottom, 16)
            }
        }
        .aspectRatio(2/3, contentMode: .fit)
        .clipShape(cardShape)
        .background(
            cardShape
                .fill(Color(red: 0.10, green: 0.10, blue: 0.12))
        )
        .overlay(
            cardShape.stroke(strokeGradient, lineWidth: isHovering ? 1.5 : 0.75)
        )
        .contentShape(cardShape)
        .shadow(color: .black.opacity(isHovering ? 0.40 : 0.16), radius: isHovering ? 12 : 4, x: 0, y: isHovering ? 6 : 2)
        .animation(.easeOut(duration: 0.2), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(genre.name) genre")
        .accessibilityHint("Browse all \(genre.name) titles")
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
