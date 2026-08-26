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

/// The one empty-state used across all library pages. Monochrome icon in a
/// clear glass circle — no gradients, no accent colors.
struct LibraryEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var actionIcon: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 72, height: 72)
                .glassEffect(.clear, in: .circle)

            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)

            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

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
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
        }
        .padding(.vertical, 60)
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
        .glassEffect(.clear, in: .rect(cornerRadius: 24))
        .padding(.top, 20)
    }
}
