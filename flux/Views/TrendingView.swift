import SwiftUI

struct TrendingView: View {
    @State private var selectedType: String = "movie" // "movie" or "tv"
    @State private var movies: [MediaItem] = []
    @State private var tvShows: [MediaItem] = []
    @State private var isLoading = true
    
    private var currentItems: [MediaItem] {
        selectedType == "movie" ? movies : tvShows
    }
    
    let columns = [
        GridItem(.adaptive(minimum: 160), spacing: 24)
    ]
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                if isLoading && currentItems.isEmpty {
                    VStack(alignment: .leading, spacing: 40) {
                        GhostHero()
                        GhostGrid()
                    }
                    .transition(.opacity)
                } else {
                    // 1. Full-Bleed Hero Carousel for Top Trending Titles of Active Category
                    if !currentItems.isEmpty {
                        FeaturedCarousel(items: Array(currentItems.prefix(5)))
                            .id("trending-hero-\(selectedType)")
                            .transition(.opacity)
                    }
                    
                    // 2. Main Trending Catalog Section
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(alignment: .center, spacing: 16) {
                            Text("Trending Now")
                                .font(.system(size: 32, weight: .heavy))
                                .foregroundStyle(.white)
                            
                            LiquidGlassMediaToggle(selected: $selectedType)
                            
                            if !currentItems.isEmpty {
                                Text("\(currentItems.count) TITLES")
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
                            ForEach(currentItems) { item in
                                NavigationLink(value: item) {
                                    GlassCard(item: item, aspectRatio: .portrait, showTitle: true)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .id("trending-grid-\(selectedType)")
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
        .onReceive(NotificationCenter.default.publisher(for: .fluxRefresh)) { _ in
            Task {
                await loadTrendingData()
            }
        }
    }
    
    private func loadTrendingData() async {
        if ProfileManager.shared.currentProfile?.isKids == true {
            await MainActor.run {
                self.movies = []
                self.tvShows = []
                self.isLoading = true
            }
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    if let items = try? await TMDBEnricher.shared.fetchKidsMovies() {
                        let safe = await KidsContentFilter.shared.filterSafeItems(items)
                        await MainActor.run { self.movies = safe }
                    }
                }
                group.addTask {
                    if let items = try? await TMDBEnricher.shared.fetchKidsTV() {
                        let safe = await KidsContentFilter.shared.filterSafeItems(items)
                        await MainActor.run { self.tvShows = safe }
                    }
                }
            }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.3)) { self.isLoading = false }
            }
            return
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchTrendingMovies(window: "day") {
                    await MainActor.run {
                        self.movies = items.filter { $0.isReleased }
                    }
                }
            }
            
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchTrendingTV(window: "day") {
                    await MainActor.run {
                        self.tvShows = items.filter { $0.isReleased }
                    }
                }
            }
        }
        
        await MainActor.run {
            withAnimation(.easeOut(duration: 0.3)) {
                self.isLoading = false
            }
        }
    }
}

#Preview {
    TrendingView()
}
