import SwiftUI


struct GenreCard: View {
    let genre: Genre
    @State private var isHovering = false
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // Background Image
            CachedImage(url: URL(string: genre.imageURL ?? "")) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 160, height: 240) // Portrait size
                        .clipped()
                default:
                    Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 160, height: 240)
                    .overlay(
                        Image(systemName: "film")
                            .font(.largeTitle)
                            .foregroundStyle(.white.opacity(0.3))
                    )
                }
            }
            
            // Gradient Overlay
            LinearGradient(
                colors: [.clear, .black.opacity(0.8)],
                startPoint: .center,
                endPoint: .bottom
            )
            
            // Title
            Text(genre.name)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
                .padding(.bottom, 20)
        }
        .frame(width: 160, height: 240)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.4), .white.opacity(0.1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        // .scaleEffect(isHovering ? 1.05 : 1.0) // Scaling removed per user request
        .shadow(color: isHovering ? .black.opacity(0.4) : .black.opacity(0.2), radius: isHovering ? 12 : 8, x: 0, y: isHovering ? 6 : 4)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
