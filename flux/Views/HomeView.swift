import SwiftUI
import UniformTypeIdentifiers

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
    @State private var nativeSections: [CatalogSection] = []
    @State private var addonSections: [CatalogSection] = []
    @State private var genres: [Genre] = Genre.allGenres
    @State private var forYouItems: [MediaItem] = []
    @State private var becauseTitle: String? = nil
    
    @AppStorage("enableFluxCatalogue") private var enableFluxCatalogue = true

    @State private var isLoading = true
    @State private var scrollOffset: CGFloat = 0.0

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: HomeScrollOffsetKey.self,
                        value: geo.frame(in: .named("homeScrollSpace")).minY
                    )
                }
                .frame(height: 0)

                if isLoading {
                    // Ghost loading layout — hero + skeleton rails
                    VStack(alignment: .leading, spacing: 44) {
                        GhostHero()
                        GhostRail()
                        GhostRail()
                    }
                    .padding(.bottom, 40)
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
                                .padding(.leading, 268)
                                .padding(.trailing, 40)
                            
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

                    // For You (taste-based recommendations, below Continue Watching)
                    if !forYouItems.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            ListSectionHeader(
                                title: becauseTitle != nil ? "Because you watched \(becauseTitle!)" : "For You",
                                value: MediaListView.ListType.fixed(title: "For You", items: forYouItems)
                            )
                            .padding(.leading, 268)
                            .padding(.trailing, 40)

                            CarouselView(items: forYouItems) { item in
                                NavigationLink(value: item) {
                                    GlassCard(item: item, aspectRatio: .portrait, showTitle: false)
                                        .frame(width: 180)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.bottom, 16)
                    }

                    // ... rest of content rows ...
                    fluxNativeRows
                    addonRows
                    watchlistRow
                    genreRow
                    historyRow
                }
            }
            .padding(.bottom, 80)
        }
        .coordinateSpace(name: "homeScrollSpace")
        .onPreferenceChange(HomeScrollOffsetKey.self) { value in
            scrollOffset = max(0, -value)
        }
        .ignoresSafeArea(.all, edges: .top)
        .task {
            await loadData()
        }
    }
    
    // Extracted subviews for readability
    @ViewBuilder private var fluxNativeRows: some View {
        if enableFluxCatalogue {
            ForEach(nativeSections) { section in
                VStack(alignment: .leading, spacing: 16) {
                    ListSectionHeader(title: section.title, value: MediaListView.ListType.fixed(title: section.title, items: section.items))
                        .padding(.leading, 268)
                        .padding(.trailing, 40)
                    
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
        }
    }
    
    @ViewBuilder private var addonRows: some View {
        ForEach(addonSections) { section in
            VStack(alignment: .leading, spacing: 16) {
                ListSectionHeader(title: section.title, value: MediaListView.ListType.fixed(title: section.title, items: section.items))
                    .padding(.leading, 268)
                    .padding(.trailing, 40)
                
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
    }
    
    @ViewBuilder private var watchlistRow: some View {
        if !userData.watchlist.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "Watchlist", destination: WatchlistView(selectedTab: .constant(.watchlist)))
                    .padding(.leading, 268)
                    .padding(.trailing, 40)
                
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
    }
    
    @ViewBuilder private var genreRow: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Browse by Genre")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.leading, 268)
                .padding(.trailing, 40)
            
            CarouselView(items: genres, spacing: 16, itemWidth: 160) { genre in
                NavigationLink(value: MediaListView.ListType.genre(id: genre.id)) {
                    GenreCard(genre: genre)
                        .frame(width: 160)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 16)
    }
    
    @ViewBuilder private var historyRow: some View {
        if !userData.history.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "Recently Watched", destination: HistoryView())
                    .padding(.leading, 268)
                    .padding(.trailing, 40)
                
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

extension HomeView {
    private func loadData() async {
        do {
            // 1. Featured Hero - Using Trending All for a perfect mix of Popularity + Newness
            if let trending = try? await TMDBEnricher.shared.fetchTrendingAll() {
                self.heroContent = Array(trending.filter { $0.isReleased }.prefix(20))
            }
            
            // 2. Load Sections
            await fetchNativeTMDBSections()
            await fetchAddonSections() // Restore Addon support
            
            // 3. Background: Enrich History Items (fills missing thumbnails, writes back)
            Task.detached(priority: .background) {
                await self.userData.enrichHistory()
            }

            // 4. For You — taste-based recommendations (hidden until enough signal)
            if TasteProfileManager.shared.hasEnoughSignal {
                let (recs, because) = await TasteProfileManager.shared.forYouRecommendations()
                self.forYouItems = recs
                self.becauseTitle = because?.title
            }
            
            await MainActor.run {
                self.isLoading = false
            }
        } catch {
            print("Error fetching data: \(error)")
            await fetchNativeTMDBSections()
            await MainActor.run {
                self.isLoading = false
            }
        }
    }
    
    private func fetchNativeTMDBSections() async {
        var fetchedSections: [CatalogSection] = []
        
        // We fetch these in parallel for speed
        await withTaskGroup(of: CatalogSection?.self) { group in
            // Trending
            group.addTask {
                 if let items = try? await TMDBEnricher.shared.fetchTrending(type: "movie"), !items.isEmpty {
                     return CatalogSection(addonName: "TMDB", title: "Trending Movies", type: "movie", items: items)
                 }
                 return nil
            }
            
            // Popular TV
            group.addTask {
                 if let items = try? await TMDBEnricher.shared.fetchPopular(type: "tv"), !items.isEmpty {
                     return CatalogSection(addonName: "TMDB", title: "Popular Series", type: "series", items: items)
                 }
                 return nil
            }
            
            // Upcoming
            group.addTask {
                 if let items = try? await TMDBEnricher.shared.fetchUpcomingMovies(), !items.isEmpty {
                     return CatalogSection(addonName: "TMDB", title: "Upcoming Movies", type: "movie", items: items)
                 }
                 return nil
            }
            
            // Top Rated TV
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchTopRated(type: "tv"), !items.isEmpty {
                    return CatalogSection(addonName: "TMDB", title: "Top Rated Shows", type: "series", items: items)
                }
                return nil
            }

            for await section in group {
                if let s = section { fetchedSections.append(s) }
            }
        }
        
        await MainActor.run {
            // Sort sections by a fixed preference
            let order = ["Trending Movies", "Popular Series", "Upcoming Movies", "Top Rated Shows"]
            // The dedicated "Upcoming Movies" row keeps ONLY genuinely unreleased
            // titles (TMDB's upcoming endpoint leaks just-released ones) — every
            // other row filters unreleased out (nothing to play yet). Empty
            // sections are dropped entirely so no hollow rails render.
            let released = fetchedSections.map { section -> CatalogSection in
                if section.title == "Upcoming Movies" {
                    return CatalogSection(addonName: section.addonName, title: section.title, type: section.type, items: section.items.filter { !$0.isReleased })
                }
                return CatalogSection(addonName: section.addonName, title: section.title, type: section.type, items: section.items.filter { $0.isReleased })
            }
            .filter { !$0.items.isEmpty }
            self.nativeSections = released.sorted { s1, s2 in
                let i1 = order.firstIndex(of: s1.title) ?? 99
                let i2 = order.firstIndex(of: s2.title) ?? 99
                return i1 < i2
            }
        }
    }
    
    private func fetchAddonSections() async {
        let addons = AddonManager.shared.enabledAddons
        var sections: [CatalogSection] = []
        
        await withTaskGroup(of: CatalogSection?.self) { group in
            for addon in addons {
                guard let catalogs = addon.catalogs else { continue }
                for catalog in catalogs {
                    // Only fetch first 2 catalogs per addon to keep home page snappy
                    if catalogs.firstIndex(where: { $0.id == catalog.id }) ?? 0 > 1 { continue }
                    
                    group.addTask {
                        do {
                            let items = try await StremioService.shared.fetchCatalog(type: catalog.type, id: catalog.id, baseURL: addon.url)
                            if !items.isEmpty {
                                let categoryName = catalog.type == "series" ? "Series" : "Movies"
                                let catalogTitle = catalog.name ?? addon.name
                                return CatalogSection(addonName: addon.name, title: "\(catalogTitle) \(categoryName)", type: catalog.type, items: items)
                            }
                        } catch {
                            print("Error fetching addon catalog: \(error)")
                        }
                        return nil
                    }
                }
            }
            
            for await section in group {
                if let s = section { sections.append(s) }
            }
        }
        
        await MainActor.run {
            self.addonSections = sections.map { section in
                CatalogSection(addonName: section.addonName, title: section.title, type: section.type, items: section.items.filter { $0.isReleased })
            }
            .filter { !$0.items.isEmpty }
        }
    }
    

}

struct HomeScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#Preview {
    HomeView()
        .background(Color.black)
}
