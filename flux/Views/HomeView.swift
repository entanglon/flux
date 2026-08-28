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
                    .transition(.opacity)
                } else {
                    // Featured Carousel (Trending / Hero Content)
                    if !heroContent.isEmpty {
                        FeaturedCarousel(items: Array(heroContent.prefix(5)))
                            .padding(.bottom, 10)
                    }
                    
                    // Continue Watching (Real Data)
                    if !userData.history.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            ListSectionHeader(title: "Continue Watching", value: HistoryNavigation(showAsContinueWatching: true))
                                .padding(.leading, 268)
                                .padding(.trailing, 40)
                            
                            CarouselView(items: userData.history, spacing: 16, itemWidth: 290) { item in
                                Button(action: {
                                    PlayerManager.shared.play(item, season: item.lastSeason, episode: item.lastEpisode, episodeImage: item.lastEpisodeImage)
                                    openWindow(id: "player", value: item.id)
                                }) {
                                    ContinueWatchingCard(item: item, mode: .continueWatching)
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
                    exploreOTTRow
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
        // Live-refresh the For You rail when the user toggles ♥ anywhere.
        .onReceive(TasteProfileManager.shared.$lovedItems) { _ in
            refreshForYouTask?.cancel()
            refreshForYouTask = Task {
                // Debounce rapid ♥ toggles so we don't spam TMDB.
                try? await Task.sleep(nanoseconds: 600_000_000)
                if Task.isCancelled { return }
                await refreshForYou()
            }
        }
    }

    @State private var refreshForYouTask: Task<Void, Never>?

    private func refreshForYou() async {
        guard TasteProfileManager.shared.hasEnoughSignal else {
            forYouItems = []
            becauseTitle = nil
            return
        }
        let (recs, because) = await TasteProfileManager.shared.forYouRecommendations()
        if !Task.isCancelled {
            forYouItems = recs
            becauseTitle = because?.title
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
    
    @ViewBuilder private var exploreOTTRow: some View {
        if enableFluxCatalogue {
            VStack(alignment: .leading, spacing: 16) {
                Text("Explore")
                    .font(.title2)
                    .fontWeight(.bold)
                    .padding(.leading, 268)
                    .padding(.trailing, 40)

                CarouselView(items: OTTPlatform.all, spacing: 16, itemWidth: 200) { platform in
                    NavigationLink(value: MediaListView.ListType.ott(id: platform.id, name: platform.name)) {
                        OTTCard(platform: platform)
                            .frame(width: 200)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 16)
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
                ListSectionHeader(title: "Watchlist", value: WatchlistNavigation())
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
                NavigationLink(value: MediaListView.ListType.genre(id: genre.id, name: genre.name)) {
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
                ListSectionHeader(title: "Recently Watched", value: HistoryNavigation(showAsContinueWatching: false))
                    .padding(.leading, 268)
                    .padding(.trailing, 40)
                
                CarouselView(items: userData.history, spacing: 16, itemWidth: 290) { item in
                    Button(action: {
                        PlayerManager.shared.play(item, season: item.lastSeason, episode: item.lastEpisode, episodeImage: item.lastEpisodeImage)
                        openWindow(id: "player", value: item.id)
                    }) {
                        ContinueWatchingCard(item: item, mode: .recentlyWatched)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            }
        }
    }
}

extension HomeView {
    private func loadData() async {
        do {
            // 1. Featured Hero - Cinemeta's Popular movies (keyless)
            if let popular = try? await StremioService.shared.fetchCatalog(type: "movie", id: "top", preserveOrder: true) {
                self.heroContent = Array(popular.filter { $0.isReleased }.prefix(20))
            }
            
            // 2. Load Sections
            await fetchNativeCinemetaSections()
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
                withAnimation(.easeOut(duration: 0.3)) {
                    self.isLoading = false
                }
            }
        } catch {
            print("Error fetching data: \(error)")
            await fetchNativeCinemetaSections()
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.3)) {
                    self.isLoading = false
                }
            }
        }
    }
    
    private func fetchNativeCinemetaSections() async {
        // Cinemeta discovery rails — free, keyless (Stremio's own metadata source).
        // (title, type, catalog id)
        let defs: [(String, String, String)] = [
            ("Popular Movies", "movie", "top"),
            ("Popular Series", "series", "top"),
            ("New Releases", "movie", "year"),
            ("Top Rated Shows", "series", "imdbRating"),
        ]

        var fetchedSections: [CatalogSection] = []
        await withTaskGroup(of: CatalogSection?.self) { group in
            for (title, type, id) in defs {
                group.addTask {
                    if let items = try? await StremioService.shared.fetchCatalog(type: type, id: id, preserveOrder: true), !items.isEmpty {
                        return CatalogSection(addonName: "Cinemeta", title: title, type: type, items: items)
                    }
                    return nil
                }
            }
            for await section in group {
                if let s = section { fetchedSections.append(s) }
            }
        }

        await MainActor.run {
            let order = defs.map { $0.0 }
            // Nothing to play until it's released — drop unreleased, then hollow rails.
            let released = fetchedSections.map { section -> CatalogSection in
                CatalogSection(addonName: section.addonName, title: section.title, type: section.type, items: section.items.filter { $0.isReleased })
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
