import SwiftUI

/// Shared building blocks for the four Library pages (Watchlist, Collections,
/// Recently Added, Downloads) so they stay visually identical: same header
/// treatment, paddings and a single monochrome empty-state design.
enum LibraryScheme {
    /// Page scaffold — every library page wraps content in these.
    static let headerTopPadding: CGFloat = 48
    static let topPadding: CGFloat = 40
    static let leadingPadding: CGFloat = 268
    static let trailingPadding: CGFloat = 40
    static let bottomPadding: CGFloat = 60
}

/// The empty-state used across all library pages.
/// Clean, frameless layout floating naturally on the dark background.
struct LibraryEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var actionIcon: String? = nil
    var action: (() -> Void)? = nil

    @State private var isHoveringAction = false

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 80, height: 80)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )

                Image(systemName: icon)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .shadow(color: Color.black.opacity(0.25), radius: 12, y: 4)

            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)

                Text(message)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .lineSpacing(3)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    HStack(spacing: 8) {
                        if let actionIcon {
                            Image(systemName: actionIcon)
                                .font(.system(size: 13, weight: .bold))
                        }
                        Text(actionTitle)
                            .font(.system(size: 14, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(isHoveringAction ? 0.16 : 0.08))
                    )
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(isHoveringAction ? 0.35 : 0.16), lineWidth: 1)
                    )
                    .scaleEffect(isHoveringAction ? 1.03 : 1.0)
                }
                .buttonStyle(.plain)
                .onHover { isHoveringAction = $0 }
                .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHoveringAction)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
        .padding(.horizontal, 40)
    }
}
