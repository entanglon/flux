import SwiftUI

struct CatalogSection: Identifiable, Equatable {
    let id = UUID()
    let addonName: String
    let title: String
    let type: String
    let items: [MediaItem]
    
    static func == (lhs: CatalogSection, rhs: CatalogSection) -> Bool {
        lhs.id == rhs.id
    }
}

struct HomeView: View {
    @ObservedObject private var dataManager = DataManager.shared
    @ObservedObject private var userData = UserDataService.shared
    @Environment(\.openWindow) private var openWindow
    
    @State private var heroContent: [MediaItem] = []
    @State private var dynamicSections: [CatalogSection] = []
    @State private var genres: [Genre] = Genre.allGenres

    @State private var isLoading = true
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if isLoading {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .frame(height: 500)
                } else {
                    // Featured Carousel (Trending / Hero Content)
                    if !heroContent.isEmpty {
                        FeaturedCarousel(items: Array(heroContent.prefix(5)))
                            .padding(.bottom, 10)
                    }
                    
                    // Continue Watching (Real Data)
                    if !userData.history.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            SectionHeader(title: "Continue Watching", destination: HistoryView(showAsContinueWatching: true))
                                .padding(.horizontal, 40)
                            
                            CarouselView(items: userData.history, itemWidth: 280) { item in
                                Button(action: {
                                    PlayerManager.shared.play(item, season: item.lastSeason, episode: item.lastEpisode, episodeImage: item.lastEpisodeImage)
                                    openWindow(id: "player", value: item.id)
                                }) {
                                    ContinueWatchingCard(item: item)
                                }
                                .buttonStyle(.plain)
                                .focusEffectDisabled()
                            }
                        }
                        .padding(.bottom, 16)
                    }

                    // Dynamic Addon Catalogs
                    ForEach(dynamicSections) { section in
                        VStack(alignment: .leading, spacing: 16) {
                            ListSectionHeader(title: section.title, value: MediaListView.ListType.fixed(title: section.title, items: section.items))
                                .padding(.horizontal, 40)
                            
                            CarouselView(items: section.items) { item in
                                NavigationLink(value: item) {
                                    GlassCard(item: item, aspectRatio: .portrait, showTitle: false)
                                        .frame(width: 180)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.bottom, 16)
                    }

                    // Watchlist Row
                    if !userData.watchlist.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            SectionHeader(title: "Watchlist", destination: WatchlistView(selectedTab: .constant(.watchlist)))
                                .padding(.horizontal, 40)
                            
                            CarouselView(items: userData.watchlist) { item in
                                NavigationLink(value: item) {
                                    GlassCard(item: item, aspectRatio: .portrait, showTitle: false)
                                        .frame(width: 180)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.bottom, 16)
                    }

                    // Browse by Genre
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Browse by Genre")
                            .font(.title2)
                            .fontWeight(.bold)
                            .padding(.horizontal, 40)
                        
                        CarouselView(items: genres, spacing: 16, itemWidth: 160) { genre in
                            NavigationLink(value: MediaListView.ListType.genre(id: genre.id)) {
                                GenreCard(genre: genre)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 16)
                    
                    // Recently Watched (History - Vertical)
                    if !userData.history.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            SectionHeader(title: "Recently Watched", destination: HistoryView())
                                .padding(.horizontal, 40)
                            
                            CarouselView(items: userData.history) { item in
                                NavigationLink(value: item) {
                                    GlassCard(item: item, aspectRatio: .portrait, showTitle: false)
                                        .frame(width: 180)
                                }
                                .buttonStyle(.plain)
                            }
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
    
    @MainActor
    private func loadData() async {
        do {
            // Load Cinemeta defaults for the Hero carousel
            let heroTrending = try await StremioService.shared.fetchTrendingMovies()
            self.heroContent = heroTrending.sorted { ($0.popularity ?? 0) > ($1.popularity ?? 0) }
            
            // Generate dynamic catalogs
            await fetchDynamicCatalogs()
            
            isLoading = false
        } catch {
            print("Error fetching data: \(error)")
            // Generate dynamic catalogs anyway to show some content
            await fetchDynamicCatalogs()
            isLoading = false
        }
    }
    
    private func fetchDynamicCatalogs() async {
        let addons = AddonManager.shared.enabledAddons
        var fetchedSections: [CatalogSection] = []
        
        await withTaskGroup(of: [CatalogSection].self) { group in
            for addon in addons {
                guard let catalogs = addon.catalogs, !catalogs.isEmpty else {
                    // Try to fetch fallback from Cinemeta? No, only use typed catalogs
                    continue
                }
                
                group.addTask {
                    var localSections: [CatalogSection] = []
                    // Limit to 3 catalogs per addon to avoid overloading
                    for catalog in catalogs.prefix(3) {
                        guard let items = try? await StremioService.shared.fetchCatalog(type: catalog.type, id: catalog.id) else { continue }
                        if items.isEmpty { continue }
                        
                        let catalogName = catalog.name ?? catalog.id.capitalized
                        let title = "\(addon.name) - \(catalogName)"
                        
                        localSections.append(CatalogSection(
                            addonName: addon.name,
                            title: title,
                            type: catalog.type,
                            items: items
                        ))
                    }
                    return localSections
                }
            }
            
            for await sections in group {
                fetchedSections.append(contentsOf: sections)
            }
        }
        
        await MainActor.run {
            self.dynamicSections = fetchedSections.sorted { $0.addonName < $1.addonName }
        }
    }
    

}

#Preview {
    HomeView()
        .background(Color.black)
}
