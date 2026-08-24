import SwiftUI

struct TVShowsView: View {
    @State private var popularShows: [MediaItem] = []
    @State private var trendingShows: [MediaItem] = []
    @State private var isLoading = true
    
    var body: some View {
        ScrollView {
            VStack(spacing: 48) {
                // Featured Carousel
                if !popularShows.isEmpty {
                    FeaturedCarousel(items: Array(popularShows.prefix(5)))
                }
                
                // Popular Shows Grid
                if !popularShows.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader(title: "Popular Shows", destination: MediaListView(type: .popularTV))
                            .padding(.leading, 268)
                        .padding(.trailing, 40)
                        
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 24)], spacing: 40) {
                            ForEach(popularShows) { item in
                                NavigationLink(value: item) {
                                    GlassCard(item: item, aspectRatio: .landscape, showTitle: false)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.leading, 268)
                        .padding(.trailing, 40)
                    }
                }
                
                // Trending Shows Grid
                if !trendingShows.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader(title: "Trending Now", destination: MediaListView(type: .trendingTV))
                            .padding(.leading, 268)
                        .padding(.trailing, 40)
                        
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 24)], spacing: 40) {
                            ForEach(trendingShows) { item in
                                NavigationLink(value: item) {
                                    GlassCard(item: item, aspectRatio: .landscape, showTitle: false)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.leading, 268)
                        .padding(.trailing, 40)
                    }
                }
            }
            .padding(.bottom, 80)
        }
        .overlay {
            if isLoading {
                ContentLoader()
            }
        }
        .ignoresSafeArea(edges: .top)
        .task {
            await loadData()
        }
    }
    
    private func loadData() async {
        do {
            async let popular = StremioService.shared.fetchPopularTVShows()
            async let trending = StremioService.shared.fetchTrendingTVShows()
            
            let (p, t) = try await (popular, trending)
            
            await MainActor.run {
                self.popularShows = p.filter { $0.isReleased }
                self.trendingShows = t.filter { $0.isReleased }
                self.isLoading = false
            }
        } catch {
            print("Error fetching TV shows: \(error)")
            await MainActor.run { isLoading = false }
        }
    }
}
