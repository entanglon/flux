import SwiftUI

struct TopTenCard: View {
    let item: MediaItem
    let rank: Int
    @State private var isHovering = false
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Base Poster (using GlassCard logic but simplified for this use case)
            CachedImage(url: item.posterURL ?? item.imageURL) { phase in
                switch phase {
                case .empty:
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .overlay(ProgressView().controlSize(.small))
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure:
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .overlay(Image(systemName: "photo").foregroundColor(.secondary))
                @unknown default:
                    EmptyView()
                }
            }
            // Liquid Glass Rank Number
            ZStack {
                // 1. The Glass Material Body
                Text("\(rank)")
                    .font(.system(size: 70, weight: .heavy, design: .rounded))
                    .foregroundStyle(.clear) // Text itself is transparent hole
                    .background(
                        Rectangle()
                            .fill(.ultraThinMaterial) // The glass material
                            .mask(
                                Text("\(rank)")
                                    .font(.system(size: 70, weight: .heavy, design: .rounded))
                            )
                    )
                
                // 2. Refractive/Glossy Overlay (White Gradient)
                Text("\(rank)")
                    .font(.system(size: 70, weight: .heavy, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.7),
                                .white.opacity(0.1),
                                .white.opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                
                // 3. Subtle Rim/Edge (Simulated)
                Text("\(rank)")
                    .font(.system(size: 70, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.1))
                    .shadow(color: .white.opacity(0.5), radius: 1, x: 0, y: 0) // Simulates stroke/rim
                    .mask(
                        Text("\(rank)")
                            .font(.system(size: 70, weight: .heavy, design: .rounded))
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, 8)
            .padding(.top, 0)
        }
        .frame(width: 180, height: 270)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: isHovering
                            ? [Color.white.opacity(0.70), Color.white.opacity(0.20), Color.blue.opacity(0.15)]
                            : [Color.white.opacity(0.15), Color.white.opacity(0.03)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isHovering ? 1.5 : 0.75
                )
        )
        .shadow(color: isHovering ? Color.black.opacity(0.50) : Color.black.opacity(0.25), radius: isHovering ? 16 : 8, x: 0, y: isHovering ? 8 : 4)
        .shadow(color: isHovering ? Color.white.opacity(0.08) : Color.clear, radius: 10, x: 0, y: 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

#Preview {
    ZStack {
        Color.black
        HStack(spacing: 20) {
            TopTenCard(item: MockData.sampleMedia[0], rank: 1)
            TopTenCard(item: MockData.sampleMedia[1], rank: 2)
        }
    }
    .frame(width: 600, height: 400)
}
