import SwiftUI

struct TrendingView: View {
    @State private var trendingItems: [MediaItem] = []
    @State private var isLoading = true
    
    let columns = [
        GridItem(.adaptive(minimum: 160), spacing: 24)
    ]
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                if isLoading {
                    VStack(alignment: .leading, spacing: 40) {
                        GhostHero()
                        GhostGrid()
                    }
                    .transition(.opacity)
                } else {
                    // 1. Full-Bleed Hero Carousel for Top Trending Titles
                    if !trendingItems.isEmpty {
                        FeaturedCarousel(items: Array(trendingItems.prefix(5)))
                    }
                    
                    // 2. Main Trending Catalog Section
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text("Trending Now")
                                .font(.system(size: 32, weight: .heavy))
                                .foregroundStyle(.white)
                            
                            if !trendingItems.isEmpty {
                                Text("\(trendingItems.count) TITLES")
                                    .font(.system(size: 11, weight: .bold))
                                    .tracking(1.5)
                                    .foregroundStyle(.white.opacity(0.8))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .glassEffect(.clear, in: .capsule)
                            }
                            
                            Spacer()
                        }
                        
                        // 3. Grid of Trending Glass Cards
                        LazyVGrid(columns: columns, spacing: 32) {
                            ForEach(trendingItems) { item in
                                NavigationLink(value: item) {
                                    GlassCard(item: item, aspectRatio: .portrait, showTitle: true)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.leading, 268)
                    .padding(.trailing, 40)
                }
            }
            .padding(.bottom, 80)
        }

        .ignoresSafeArea(edges: .top)
        .task {
            await loadTrendingData()
        }
    }
    
    private func loadTrendingData() async {
        do {
            let items = try await StremioService.shared.fetchTrendingMovies()
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.3)) {
                    self.trendingItems = items.filter { $0.isReleased }
                    self.isLoading = false
                }
            }
        } catch {
            print("Error loading trending data: \(error)")
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.3)) {
                    self.isLoading = false
                }
            }
        }
    }
}

#Preview {
    TrendingView()
}
