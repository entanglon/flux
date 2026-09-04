import SwiftUI

// MARK: - Shimmer

private struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -0.9

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.07), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.7)
                    .offset(x: geo.size.width * phase)
                }
            )
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                    phase = 1.3
                }
            }
    }
}

extension View {
    func shimmer() -> some View { modifier(ShimmerModifier()) }
}

// MARK: - Ghost Primitives

/// Bare shimmering rounded rect.
struct GhostRect: View {
    var height: CGFloat
    var cornerRadius: CGFloat = 8

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .frame(height: height)
            .shimmer()
    }
}

/// 2:3 poster ghost matching GlassCard's footprint (or any aspect via `ratio`).
struct GhostPoster: View {
    var width: CGFloat = 180
    var ratio: CGFloat = 2/3
    var cornerRadius: CGFloat = 12

    var body: some View {
        Color.clear
            .aspectRatio(ratio, contentMode: .fit)
            .frame(width: width)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            }
            .shimmer()
    }
}

/// Full poster card ghost with title/subtitle placeholder lines (grid pages).
struct GhostCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Color.clear
                .aspectRatio(2/3, contentMode: .fit)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                }
                .shimmer()

            VStack(alignment: .leading, spacing: 6) {
                GhostRect(height: 10).frame(maxWidth: 110)
                GhostRect(height: 8).frame(maxWidth: 64)
            }
            .padding(.horizontal, 4)
        }
    }
}

/// Hero ghost matching FeaturedCarousel's exact footprint and typography/action layout.
struct GhostHero: View {
    var height: CGFloat = 680

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // 1. Shimmering backdrop canvas
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.06), Color.white.opacity(0.02)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )

            // 2. Dual Vignette Gradient Mesh (Matching FeaturedCarousel)
            ZStack {
                // Left Vignette
                LinearGradient(
                    gradient: Gradient(colors: [.black.opacity(0.85), .black.opacity(0.4), .clear]),
                    startPoint: .leading,
                    endPoint: .init(x: 0.65, y: 0.5)
                )

                // Bottom-Up Vignette
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0.35),
                        .init(color: .black.opacity(0.5), location: 0.65),
                        .init(color: .black.opacity(1.0), location: 1.0)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .ignoresSafeArea()

            // 3. Skeleton Content Block (Clearing Sidebar)
            VStack(alignment: .leading, spacing: 14) {
                // Category pill skeleton
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 72, height: 20)

                // Title skeleton
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 360, height: 48)

                // Metadata row skeleton (Year, Star, Tech badges)
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 44, height: 16)

                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 110, height: 16)

                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 50, height: 16)

                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 36, height: 16)

                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 42, height: 16)
                }

                // Description skeleton lines
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 520, height: 12)

                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 440, height: 12)

                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 300, height: 12)
                }
                .padding(.top, 2)

                // Action buttons skeleton
                HStack(spacing: 14) {
                    Capsule()
                        .fill(Color.white.opacity(0.16))
                        .frame(width: 116, height: 38)

                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 140, height: 38)
                }
                .padding(.top, 4)
            }
            .padding(.leading, 268)
            .padding(.bottom, 36)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .shimmer()
    }
}

/// 16:9 landscape ghost matching ContinueWatchingCard's exact footprint (290x163).
struct GhostContinueWatchingCard: View {
    var width: CGFloat = 290
    var height: CGFloat = 163
    var cornerRadius: CGFloat = 12

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Background
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .frame(width: width, height: height)

            // Bottom gradient vignette
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .clear, location: 0.35),
                    .init(color: .black.opacity(0.40), location: 0.68),
                    .init(color: .black.opacity(0.88), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

            // Text and progress bar
            VStack(alignment: .leading, spacing: 8) {
                // Title
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 140, height: 16)

                // Bottom row: play icon placeholder + progress capsule + episode text
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.20))

                    Capsule()
                        .fill(Color.white.opacity(0.15))
                        .frame(width: 52, height: 4)

                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                        .frame(width: 76, height: 10)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .frame(width: width, height: height)
        .shimmer()
    }
}

/// A skeleton rail for Continue Watching (clears the sidebar).
struct GhostContinueWatchingRail: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GhostRect(height: 16, cornerRadius: 4)
                .frame(width: 160)
                .padding(.leading, 268)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(0..<4, id: \.self) { _ in
                        GhostContinueWatchingCard()
                    }
                }
                .padding(.leading, 268)
                .padding(.trailing, 60)
                .padding(.vertical, 4)
            }
        }
        .padding(.bottom, 16)
    }
}

// MARK: - Layouts

/// A skeleton content rail: header line + row of posters (clears the sidebar).
struct GhostRail: View {
    var posterWidth: CGFloat = 180
    var ratio: CGFloat = 2/3
    var cornerRadius: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GhostRect(height: 16)
                .frame(width: 170)
                .padding(.leading, 268)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(0..<7, id: \.self) { _ in
                        GhostPoster(width: posterWidth, ratio: ratio, cornerRadius: cornerRadius)
                    }
                }
                .padding(.leading, 268)
                .padding(.trailing, 60)
                .padding(.top, 10)
                .padding(.bottom, 24)
            }
        }
    }
}

/// Skeleton grid matching the GlassCard grids (clears the sidebar).
struct GhostGrid: View {
    var columns: [GridItem] = [GridItem(.adaptive(minimum: 160), spacing: 24)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 40) {
            ForEach(0..<12, id: \.self) { _ in
                GhostCard()
            }
        }
        .padding(.leading, 268)
        .padding(.trailing, 40)
    }
}
