import SwiftUI

/// Portrait brand tile for an OTT platform. The bundled logo image fills the
/// entire card — no gradient backdrop, no padding. Hover matches GlassCard.
struct OTTCard: View {
    let platform: OTTPlatform
    @State private var isHovering = false

    private var assetName: String { "ott-\(platform.id)" }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
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

    var body: some View {
        Color.clear
            .aspectRatio(2/3, contentMode: .fit)
            .overlay(
                Image(assetName)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            )
            .clipShape(cardShape)
            .background(
                cardShape
                    .fill(Color(red: 0.10, green: 0.10, blue: 0.12))
            )
            .overlay(
                cardShape
                    .stroke(strokeGradient, lineWidth: isHovering ? 1.5 : 0.75)
            )
            .shadow(color: Color.black.opacity(isHovering ? 0.40 : 0.16),
                    radius: isHovering ? 12 : 4, x: 0, y: isHovering ? 6 : 2)
            .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.7), value: isHovering)
            .contentShape(cardShape)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}
