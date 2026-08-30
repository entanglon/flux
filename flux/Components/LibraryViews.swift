import SwiftUI

/// Shared geometry, typography, and building blocks for all Library pages
/// (Watchlist, Collections, Recently Watched / History, Downloads).
/// Guarantees pixel-identical header alignment, empty-state icon placement,
/// and responsive typography across sidebar navigation.
enum LibraryScheme {
    static let leadingPadding: CGFloat = 268
    static let trailingPadding: CGFloat = 40
    static let topPadding: CGFloat = 40
    static let headerTopPadding: CGFloat = 48
    static let headerBottomSpacing: CGFloat = 32
    static let bottomPadding: CGFloat = 60
    static let emptyStateTopPadding: CGFloat = 60
}

/// Unified Header component for all Library pages.
/// Ensures title baseline, badge pill, action buttons, and filter chips
/// sit at the exact same screen coordinates across all tabs.
struct LibraryPageHeader<RightContent: View, BottomContent: View>: View {
    let title: String
    var itemCount: Int? = nil
    var itemLabel: String = "ITEMS"
    let rightAction: RightContent
    let filterChips: BottomContent

    init(
        title: String,
        itemCount: Int? = nil,
        itemLabel: String = "ITEMS",
        @ViewBuilder rightAction: () -> RightContent = { EmptyView() },
        @ViewBuilder filterChips: () -> BottomContent = { EmptyView() }
    ) {
        self.title = title
        self.itemCount = itemCount
        self.itemLabel = itemLabel
        self.rightAction = rightAction()
        self.filterChips = filterChips()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                Text(title)
                    .font(.system(size: 44, weight: .heavy))
                    .foregroundStyle(.white)
                
                if let count = itemCount, count > 0 {
                    Text("\(count) \(itemLabel)")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.5)
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .glassEffect(.clear, in: .capsule)
                }
                
                Spacer()
                
                rightAction
            }
            .padding(.top, LibraryScheme.headerTopPadding)

            filterChips
        }
    }
}

/// The empty-state used across all library pages.
/// Clean, frameless layout perfectly centered in the body area.
/// Fixed geometric height guarantees 100% pixel-identical icon placement.
struct LibraryEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var actionIcon: String? = nil
    var action: (() -> Void)? = nil

    @State private var isHoveringAction = false

    var body: some View {
        VStack(spacing: 20) {
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

            Group {
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
                } else {
                    Color.clear.frame(height: 44)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }
}
