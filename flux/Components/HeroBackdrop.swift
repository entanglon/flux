import SwiftUI

/// Shared hero backdrop builder used by FeaturedCarousel and DetailView so both
/// render identically: full-width artwork (natural crop — no over-zoom) plus a
/// TRUE mirrored reflection extending under the glass sidebar.
///
/// The old implementation cropped two copies independently inside an HStack,
/// which over-zoomed the artwork and left a visible seam at the sidebar edge.
enum HeroBackdrop {
    @ViewBuilder
    static func banner(image: Image, width: CGFloat, height: CGFloat, sidebarWidth: CGFloat) -> some View {
        let effectiveSidebar = max(160, sidebarWidth - 10)
        ZStack {
            // Main artwork — full width, one natural crop.
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: height)
                .clipped()

            // Reflection under the sidebar: identical full-size frame, flipped
            // about its center then shifted so the seam column CONTINUES the
            // artwork (displayed(x) = original(2·sidebar − x)). Heavy blur +
            // the left vignette finish the effect.
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: height)
                .clipped()
                .scaleEffect(x: -1, y: 1)
                .offset(x: 2 * effectiveSidebar - width)
                .blur(radius: 30)
                .mask(
                    HStack(spacing: 0) {
                        Rectangle().frame(width: effectiveSidebar)
                        Color.clear
                    }
                )
        }
        .frame(width: width, height: height)
    }
}
