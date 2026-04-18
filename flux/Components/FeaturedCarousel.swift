import SwiftUI
import Combine

struct FeaturedCarousel: View {
    let items: [MediaItem]
    @State private var currentIndex = 0
    @State private var isHovering = false
    @ObservedObject private var userData = UserDataService.shared
    
    let timer = Timer.publish(every: 8, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if !items.isEmpty {
                let item = items[currentIndex]
                
                // 1. Hero Image / Backdrop Selection
                GeometryReader { geo in
                    ZStack {
                        // Logic: Only use backdrop/hero (landscape). Never stretch a poster.
                        if let heroURL = item.heroURL ?? item.backdropURL {
                            CachedImage(url: heroURL.highQuality(), maxDimension: 1920) { phase in
                                if let image = phase.image {
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: geo.size.width, height: geo.size.height)
                                        .clipped()
                                } else {
                                    Rectangle().fill(Color.gray.opacity(0.1))
                                }
                            }
                        } else {
                            // High-quality fallback for items without backdrops (e.g. some Stremio catalogs)
                            // Use a premium glass/gradient background instead of a blurry stretched poster.
                            LinearGradient(
                                colors: [.blue.opacity(0.3), .purple.opacity(0.3), .black],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            .overlay(
                                Circle()
                                    .fill(Color.white.opacity(0.05))
                                    .frame(width: 800, height: 800)
                                    .blur(radius: 100)
                                    .offset(x: 200, y: -200)
                            )
                        }
                    }
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.8)))
                .id(currentIndex)
                
                // 2. Gradient Overlay (Bottom Up)
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0.4),
                        .init(color: .black.opacity(0.6), location: 0.7),
                        .init(color: .black.opacity(0.9), location: 1.0)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                
                // 3. Content
                VStack(alignment: .leading, spacing: 12) {
                    // Title (Logo styling)
                    Text(item.title)
                        .font(.system(size: 52, weight: .heavy)) // Large Impactful Title
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 4)
                        .lineLimit(2)
                    
                    // Metadata Row
                    HStack(spacing: 8) {
                        Text(item.category) // Movie / TV Show
                        Text("•")
                        if let genres = item.genres?.prefix(2).map({ $0 }) {
                            Text(genres.joined(separator: ", "))
                            Text("•")
                        }
                        if let year = item.releaseDateYear {
                            Text(year)
                        }
                    }
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.white.opacity(0.8))
                    
                    // Description
                    Text(item.description)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(3)
                        .frame(maxWidth: 600, alignment: .leading)
                        .padding(.top, 4)
                        .shadow(radius: 2)
                    
                    // Action Buttons
                    HStack(spacing: 16) {
                        // Play Button
                        if item.streamURL != nil {
                            Button(action: {
                                // Play action
                            }) {
                                HStack {
                                    Image(systemName: "play.fill")
                                        .font(.headline)
                                    Text("Play")
                                        .font(.headline)
                                }
                                .foregroundStyle(.black)
                                .padding(.horizontal, 32)
                                .padding(.vertical, 14)
                                .background(Color.white)
                                .cornerRadius(30)
                            }
                            .buttonStyle(.plain)
                        }
                        
                        // Watchlist Button
                        Button(action: {
                            userData.toggleWatchlist(item)
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: userData.isInWatchlist(item) ? "checkmark" : "plus")
                                Text(userData.isInWatchlist(item) ? "In Watchlist" : "Add to Watchlist")
                            }
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 14)
                            .glassEffect(.regular.interactive(), in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 16)
                }
                .padding(.horizontal, 48)
                .padding(.bottom, 60)
            }
            
            // Paging Indicators
            HStack(spacing: 8) {
                ForEach(0..<items.count, id: \.self) { index in
                    Circle()
                        .fill(index == currentIndex ? Color.white : Color.white.opacity(0.2))
                        .frame(width: 8, height: 8)
                        .onTapGesture {
                            withAnimation {
                                currentIndex = index
                            }
                        }
                }
            }
            .frame(maxWidth: .infinity) // Center align
            .padding(.bottom, 24)
        }
        .frame(height: 680) // Taller hero
        .overlay(alignment: .leading) {
            if isHovering {
                Button(action: {
                    withAnimation {
                        currentIndex = (currentIndex - 1 + items.count) % items.count
                    }
                }) {
                    arrowButton(direction: "left")
                }
                .buttonStyle(.plain)
                .padding(.leading, 20)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .trailing) {
            if isHovering {
                 Button(action: {
                    withAnimation {
                        currentIndex = (currentIndex + 1) % items.count
                    }
                }) {
                    arrowButton(direction: "right")
                }
                .buttonStyle(.plain)
                .padding(.trailing, 20)
                .transition(.opacity)
            }
        }
        .onHover { hovering in
            withAnimation { isHovering = hovering }
        }
        .onReceive(timer) { _ in
            withAnimation {
                currentIndex = (currentIndex + 1) % items.count
            }
        }
    }
    
    private func arrowButton(direction: String) -> some View {
        Image(systemName: "chevron.\(direction)")
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 64)
            .background(.ultraThinMaterial)
            .cornerRadius(32)
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
    }
}

#Preview {
    FeaturedCarousel(items: MockData.sampleMedia)
        .frame(width: 1000, height: 800)
}
