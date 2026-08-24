import SwiftUI

struct Top10Card: View {
    let rank: Int
    let item: MediaItem
    @State private var isHovering = false
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Poster Image
            CachedImage(url: item.posterURL ?? item.imageURL, maxDimension: 500) { phase in
                switch phase {
                case .empty:
                    Rectangle()
                        .fill(Color.white.opacity(0.05))
                        .overlay(ProgressView().controlSize(.small))
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure:
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .overlay(Image(systemName: "film").foregroundStyle(.secondary))
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: 170, height: 255)
            .clipped()
            
            // Bottom Gradient for readability
            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .center,
                endPoint: .bottom
            )
            
            // Top-Left Scrim for Rank Number Contrast
            LinearGradient(
                colors: [.black.opacity(0.7), .clear],
                startPoint: .topLeading,
                endPoint: .center
            )
            
            // Top-Left Large Rank Number
            VStack {
                HStack {
                    Text("\(rank)")
                        .font(.system(size: 48, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.85), radius: 8, x: 2, y: 3)
                        .padding(.leading, 12)
                        .padding(.top, 6)
                    Spacer()
                }
                Spacer()
            }
            
            // Bottom Genre Tag
            if let genres = item.genres, let firstGenre = genres.first {
                VStack(alignment: .leading, spacing: 2) {
                    Text(firstGenre)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.95))
                        .shadow(color: .black.opacity(0.6), radius: 4)
                        .padding(.leading, 14)
                        .padding(.bottom, 12)
                }
            }
        }
        .frame(width: 170, height: 255)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    LinearGradient(
                        colors: isHovering ? [.white.opacity(0.5), .white.opacity(0.15)] : [.white.opacity(0.1), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isHovering ? 1.5 : 0.5
                )
        )
        .shadow(color: isHovering ? Color.black.opacity(0.5) : Color.black.opacity(0.25), radius: isHovering ? 16 : 8, x: 0, y: isHovering ? 10 : 4)
        .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.7), value: isHovering)
        .onHover { isHovering = $0 }
    }
}
