import SwiftUI

struct MoviesView: View {
    @State private var popularMovies: [MediaItem] = []
    @State private var topRatedMovies: [MediaItem] = []
    @State private var isLoading = true
    
    var body: some View {
        ScrollView {
            VStack(spacing: 48) {
                if isLoading {
                    VStack(spacing: 48) {
                        GhostHero()
                        GhostGrid()
                    }
                }
                if !isLoading {
                // Featured Movie
                if !popularMovies.isEmpty {
                    FeaturedCarousel(items: Array(popularMovies.prefix(5)))
                }

                // Popular Movies Grid
                if !popularMovies.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader(title: "Popular Movies", destination: MediaListView(type: .popularMovies))
                            .padding(.leading, 268)
                        .padding(.trailing, 40)
                        
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 24)], spacing: 40) {
                            ForEach(popularMovies) { item in
                                NavigationLink(value: item) {
                                    GlassCard(item: item, aspectRatio: .portrait, showTitle: false)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.leading, 268)
                        .padding(.trailing, 40)
                    }
                }
                
                // Top Rated Grid
                if !topRatedMovies.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader(title: "Top Rated", destination: MediaListView(type: .topRatedMovies))
                            .padding(.leading, 268)
                        .padding(.trailing, 40)
                        
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 24)], spacing: 40) {
                            ForEach(topRatedMovies) { item in
                                NavigationLink(value: item) {
                                    GlassCard(item: item, aspectRatio: .portrait, showTitle: false)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.leading, 268)
                        .padding(.trailing, 40)
                    }
                }
                }
            }
            .padding(.bottom, 80)
        }

        .ignoresSafeArea(edges: .top)
        .task {
            await loadData()
        }
    }
    
    private func loadData() async {
        do {
            async let popular = StremioService.shared.fetchPopularMovies()
            async let topRated = StremioService.shared.fetchTrendingMovies() // Using trending as top rated for now
            
            let (p, t) = try await (popular, topRated)
            
            await MainActor.run {
                self.popularMovies = p.filter { $0.isReleased }
                self.topRatedMovies = t.filter { $0.isReleased }
                self.isLoading = false
            }
        } catch {
            print("Error fetching movies: \(error)")
            await MainActor.run { isLoading = false }
        }
    }
}
