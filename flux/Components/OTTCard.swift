import SwiftUI

/// Portrait brand tile for an OTT platform. The bundled logo image fills the
/// entire card — no gradient backdrop, no padding. Hover matches GlassCard.
struct OTTCard: View {
    let platform: OTTPlatform
    @State private var isHovering = false

    private var assetName: String { "ott-\(platform.id)" }

    var body: some View {
        Color.clear
            .aspectRatio(2/3, contentMode: .fit)
            .overlay {
                Image(assetName)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            .overlay(
                Color.black.opacity(isHovering ? 0.3 : 0.0)
                    .animation(.easeInOut(duration: 0.2), value: isHovering)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: isHovering ? [.white.opacity(0.6), .white.opacity(0.2)] : [.white.opacity(0.12), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: isHovering ? 1.5 : 0.75
                    )
            )
            .shadow(color: isHovering ? Color.black.opacity(0.5) : Color.black.opacity(0.25),
                    radius: isHovering ? 16 : 6, x: 0, y: isHovering ? 10 : 4)
            .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.7), value: isHovering)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onHover { hovering in
                isHovering = hovering
            }
    }
}
