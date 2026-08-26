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

    var body: some View {
        Color.clear
            .aspectRatio(ratio, contentMode: .fit)
            .frame(width: width)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
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

/// Full-bleed 16:9 hero ghost (featured carousel placeholder).
struct GhostHero: View {
    var body: some View {
        Color.clear
            .aspectRatio(16/9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                LinearGradient(
                    colors: [Color.white.opacity(0.07), Color.white.opacity(0.03)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
            .shimmer()
    }
}

// MARK: - Layouts

/// A skeleton content rail: header line + row of posters (clears the sidebar).
struct GhostRail: View {
    var posterWidth: CGFloat = 180
    var ratio: CGFloat = 2/3

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GhostRect(height: 16)
                .frame(width: 170)
                .padding(.leading, 268)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(0..<7, id: \.self) { _ in
                        GhostPoster(width: posterWidth, ratio: ratio)
                    }
                }
                .padding(.leading, 268)
                .padding(.trailing, 40)
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
