import SwiftUI
import Combine

struct FeaturedCarousel: View {
    let items: [MediaItem]
    @State private var currentIndex = 0
    @State private var isHovering = false
    @ObservedObject private var userData = UserDataService.shared
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 230
    
    let timer = Timer.publish(every: 8, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if !items.isEmpty {
                let safeIndex = max(0, min(currentIndex, items.count - 1))
                let item = items[safeIndex]
                
                // 1. Hero Image / Backdrop Selection
                GeometryReader { geo in
                    ZStack {
                        // Logic: Only use backdrop/hero (landscape). Never stretch a poster.
                        if let heroURL = item.heroURL ?? item.backdropURL {
                            // The carousel is visually full-width, but decoding a 4K
                            // image for every slide can retain ~32 MB per image. 1920px
                            // remains crisp for this view while keeping the image cache
                            // within its byte budget.
                            CachedImage(url: heroURL.highQuality(), maxDimension: 1920) { phase in
                                if let image = phase.image {
                                    HeroBackdrop.banner(
                                        image: image,
                                        width: geo.size.width,
                                        height: geo.size.height,
                                        sidebarWidth: sidebarWidth
                                    )
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
                
                // 2. Dual Vignette Gradient Mesh (Apple TV Master Grade)
                ZStack {
                    
                    // Left Vignette (Title text readability)
                    LinearGradient(
                        gradient: Gradient(colors: [.black.opacity(0.85), .black.opacity(0.4), .clear]),
                        startPoint: .leading,
                        endPoint: .init(x: 0.65, y: 0.5)
                    )
                    
                    // Bottom-Up Vignette (Seamless row transition)
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0.35),
                            .init(color: .black.opacity(0.5), location: 0.65),
                            .init(color: .black, location: 1.0)
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .ignoresSafeArea()
                
                // 3. Content
                NavigationLink(value: item) {
                    VStack(alignment: .leading, spacing: 14) {
                        // Category Eyebrow
                        Text(item.category.uppercased())
                            .font(.system(size: 12, weight: .bold))
                            .tracking(2.0)
                            .foregroundStyle(.white.opacity(0.75))
                            .shadow(color: .black.opacity(0.5), radius: 4)
                        
                        // Title (Logo styling)
                        Text(item.title)
                            .font(.system(size: 56, weight: .heavy))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 12, x: 0, y: 4)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        
                        // Metadata Row with Tech Badges
                        HStack(spacing: 10) {
                            if let year = item.releaseDateYear {
                                Text(year)
                                    .fontWeight(.bold)
                            }
                            if let genres = item.genres?.prefix(2).map({ $0 }) {
                                Text("•")
                                Text(genres.joined(separator: ", "))
                            }
                            if let vote = item.voteAverage, vote > 0 {
                                Text("•")
                                HStack(spacing: 3) {
                                    Image(systemName: "star.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.yellow)
                                    Text(String(format: "%.1f", vote))
                                }
                            }
                            
                            TechBadge(text: "4K")
                            TechBadge(text: "HDR")
                            TechBadge(text: "ATMOS")
                        }
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white.opacity(0.9))
                        
                        // Description
                        Text(item.description)
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(3)
                            .lineSpacing(3)
                            .frame(maxWidth: 620, alignment: .leading)
                            .padding(.top, 2)
                            .shadow(color: .black.opacity(0.4), radius: 4)
                        
                        // Action Buttons (Apple TV Master Layout)
                        HStack(spacing: 14) {
                            // Primary Play Button
                            HStack(spacing: 8) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 14, weight: .bold))
                                Text("Play")
                                    .font(.system(size: 14, weight: .bold))
                            }
                            .foregroundStyle(.black)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 10)
                            .background(Color.white)
                            .clipShape(Capsule())
                            .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                            
                            // Secondary Watchlist Button (Circular Glass + Button)
                            Button(action: {
                                userData.toggleWatchlist(item)
                            }) {
                                Image(systemName: userData.isInWatchlist(item) ? "checkmark" : "plus")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 36, height: 36)
                                    .glassEffect(.regular.interactive(), in: .circle)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 12)
                    }
                }
                .buttonStyle(.plain)
                .padding(.leading, 268)
                .padding(.trailing, 48)
                .padding(.bottom, 40)
            }
            
            // Apple TV Dynamic Page Indicators (Pills)
            HStack(spacing: 6) {
                ForEach(0..<items.count, id: \.self) { index in
                    Capsule()
                        .fill(index == currentIndex ? Color.white : Color.white.opacity(0.3))
                        .frame(width: index == currentIndex ? 24 : 8, height: 8)
                        .shadow(color: index == currentIndex ? .white.opacity(0.5) : .clear, radius: 4)
                        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: currentIndex)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.4)) {
                                currentIndex = index
                            }
                        }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.leading, 268)
            .padding(.trailing, 48)
            .padding(.bottom, 16)
        }
        .frame(height: 680)
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
                .padding(.leading, 268)
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
            guard !items.isEmpty, !isHovering else { return }
            withAnimation(.easeInOut(duration: 0.5)) {
                currentIndex = (currentIndex + 1) % items.count
            }
        }
    }
    
    private func arrowButton(direction: String) -> some View {
        Image(systemName: "chevron.\(direction)")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .glassEffect(.regular.interactive(), in: .circle)
    }
}

#Preview {
    FeaturedCarousel(items: MockData.sampleMedia)
        .frame(width: 1000, height: 800)
}
