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
    @AppStorage("enableTMDBHomePage") private var enableTMDBHomePage = false
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
            // Load Hero content (Featured Carousel)
            // Prioritize the top catalog of the first enabled addon (after Cinemeta) if available
            if let firstAddon = AddonManager.shared.enabledAddons.first,
               let firstCatalog = firstAddon.catalogs?.first(where: { $0.type == "movie" }),
               let items = try? await StremioService.shared.fetchCatalog(type: firstCatalog.type, id: firstCatalog.id, baseURL: firstAddon.url),
               !items.isEmpty {
                self.heroContent = items.sorted { ($0.popularity ?? 0) > ($1.popularity ?? 0) }
            } else {
                // Fallback to Cinemeta defaults
                let heroTrending = try await StremioService.shared.fetchTrendingMovies()
                self.heroContent = heroTrending.sorted { ($0.popularity ?? 0) > ($1.popularity ?? 0) }
            }
            
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
        
        // 1. Add TMDB Overrides if enabled
        if enableTMDBHomePage {
            if let trendingMovies = try? await TMDBEnricher.shared.fetchTrending(type: "movie") {
                fetchedSections.append(CatalogSection(addonName: "TMDB", title: "TMDB - Trending Movies", type: "movie", items: trendingMovies))
            }
            if let trendingTV = try? await TMDBEnricher.shared.fetchTrending(type: "tv") {
                fetchedSections.append(CatalogSection(addonName: "TMDB", title: "TMDB - Trending TV Shows", type: "series", items: trendingTV))
            }
        }
        
        // 2. Fetch from Stremio Addons
        await withTaskGroup(of: [CatalogSection].self) { group in
            for addon in addons {
                let hasCatalogResource = addon.resources?.contains("catalog") ?? false
                let catalogs = addon.catalogs ?? []
                
                if !hasCatalogResource && catalogs.isEmpty {
                    continue
                }
                
                group.addTask {
                    var localSections: [CatalogSection] = []
                    
                    // If catalogs are empty but resource is present, try a standard fallback
                    let catalogsToFetch = catalogs.isEmpty ? 
                        [StremioCatalog(type: "movie", id: "top", name: "Popular"), 
                         StremioCatalog(type: "series", id: "top", name: "Popular")] : 
                        Array(catalogs.prefix(3))
                    // Limit to 3 catalogs per addon to avoid overloading
                    for catalog in catalogsToFetch {
                        guard let items = try? await StremioService.shared.fetchCatalog(type: catalog.type, id: catalog.id, baseURL: addon.url) else { continue }
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
            self.dynamicSections = fetchedSections.sorted { s1, s2 in
                if s1.addonName == "Cinemeta" { return true }
                if s2.addonName == "Cinemeta" { return false }
                return s1.addonName < s2.addonName
            }
        }
    }
    

}

#Preview {
    HomeView()
        .background(Color.black)
}
