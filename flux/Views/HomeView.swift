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
    
    // Core discovery rails
    @State private var heroContent: [MediaItem] = []
    @State private var trendingTodayItems: [MediaItem] = []
    @State private var trendingWeekItems: [MediaItem] = []
    @State private var popularMovies: [MediaItem] = []
    @State private var popularTV: [MediaItem] = []
    @State private var nowPlayingMovies: [MediaItem] = []
    @State private var airingTodayTV: [MediaItem] = []
    @State private var onTheAirTV: [MediaItem] = []
    @State private var topRatedMovies: [MediaItem] = []
    @State private var topRatedTV: [MediaItem] = []
    @State private var upcomingMovies: [MediaItem] = []
    @State private var quickWatches: [MediaItem] = []
    @State private var addonSections: [CatalogSection] = []
    @State private var genres: [Genre] = Genre.allGenres
    @State private var forYouItems: [MediaItem] = []
    @State private var becauseTitle: String? = nil
    @State private var trendingWindow: String = "day"
    
    @AppStorage("enableFluxCatalogue") private var enableFluxCatalogue = true

    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if isLoading && heroContent.isEmpty && trendingTodayItems.isEmpty {
                    // Ghost loading layout — hero + skeleton rails
                    VStack(alignment: .leading, spacing: 44) {
                        GhostHero()
                        GhostRail()
                        GhostRail()
                    }
                    .padding(.bottom, 40)
                    .transition(.opacity)
                } else {
                    // Featured Carousel (Trending Today & Hero Content)
                    if !heroContent.isEmpty {
                        FeaturedCarousel(items: Array(heroContent.prefix(5)))
                            .padding(.bottom, 10)
                    }
                    
                    // Continue Watching (Real Data with Episode Stills)
                    if !userData.history.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            ListSectionHeader(title: "Continue Watching", value: MediaListView.ListType.continueWatching)
                                .padding(.leading, 268)
                                .padding(.trailing, 40)
                            
                            CarouselView(items: userData.history, spacing: 16, itemWidth: 290) { item in
                                Button(action: {
                                    PlayerManager.shared.play(
                                        item,
                                        season: item.lastSeason,
                                        episode: item.lastEpisode,
                                        episodeImage: item.lastEpisodeImage,
                                        fromContinueWatching: true
                                    )
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

                    // 1. Combined Trending Rail with Liquid Glass Toggle
                    let activeTrending = trendingWindow == "day" ? trendingTodayItems : trendingWeekItems
                    if !activeTrending.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            TrendingToggleSectionHeader(
                                title: "Trending",
                                window: $trendingWindow,
                                value: trendingWindow == "day" ? MediaListView.ListType.trendingAllDay : MediaListView.ListType.trendingAllWeek
                            )
                            .padding(.leading, 268)
                            .padding(.trailing, 40)

                            CarouselView(items: activeTrending) { item in
                                NavigationLink(value: item) {
                                    GlassCard(item: item, aspectRatio: .portrait, showTitle: false)
                                        .frame(width: 180)
                                }
                                .buttonStyle(.plain)
                            }
                            .id("trending-home-\(trendingWindow)")
                        }
                        .padding(.bottom, 16)
                    }

                    // 2. Popular Movies
                    if !popularMovies.isEmpty {
                        renderRail(title: "Popular Movies", listType: .popularMovies, items: popularMovies)
                    }

                    // 4. Popular TV Shows
                    if !popularTV.isEmpty {
                        renderRail(title: "Popular TV Shows", listType: .popularTV, items: popularTV)
                    }

                    // 5. Now Playing in Theatres
                    if !nowPlayingMovies.isEmpty {
                        renderRail(title: "Now Playing in Theatres", listType: .nowPlayingMovies, items: nowPlayingMovies)
                    }

                    // 6. Airing Today on TV
                    if !airingTodayTV.isEmpty {
                        renderRail(title: "Airing Today on TV", listType: .airingTodayTV, items: airingTodayTV)
                    }

                    // Explore OTT Platforms
                    exploreOTTRow

                    // 7. On The Air / This Week on TV
                    if !onTheAirTV.isEmpty {
                        renderRail(title: "On The Air / This Week", listType: .onTheAirTV, items: onTheAirTV)
                    }

                    // 8. Top Rated Movies
                    if !topRatedMovies.isEmpty {
                        renderRail(title: "Top Rated Movies", listType: .topRatedMovies, items: topRatedMovies)
                    }

                    // 9. Top Rated TV Shows
                    if !topRatedTV.isEmpty {
                        renderRail(title: "Top Rated Shows", listType: .topRatedTV, items: topRatedTV)
                    }

                    // 10. Upcoming Movies
                    if !upcomingMovies.isEmpty {
                        renderRail(title: "Upcoming in Theatres", listType: .upcomingMovies, items: upcomingMovies)
                    }

                    // 11. Quick Watches (< 95 mins)
                    if !quickWatches.isEmpty {
                        renderRail(title: "Quick Watches", listType: .quickWatches, items: quickWatches)
                    }

                    // Addon Sections & Other Rows
                    addonRows
                    watchlistRow
                    genreRow
                    historyRow
                }
            }
            .padding(.bottom, 80)
        }
        .ignoresSafeArea(.all, edges: .top)
        .refreshable {
            await TMDBCatalogCacheActor.shared.clear()
            await loadData()
        }
        .task {
            await loadData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .fluxRefresh)) { _ in
            Task {
                await TMDBCatalogCacheActor.shared.clear()
                await loadData()
            }
        }
        // Live-refresh the For You rail when the user toggles ♥ anywhere.
        .onReceive(TasteProfileManager.shared.$lovedItems) { _ in
            refreshForYouTask?.cancel()
            refreshForYouTask = Task {
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
    
    @ViewBuilder
    private func renderRail(title: String, listType: MediaListView.ListType, items: [MediaItem]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ListSectionHeader(title: title, value: listType)
                .padding(.leading, 268)
                .padding(.trailing, 40)
            
            CarouselView(items: items) { item in
                NavigationLink(value: item) {
                    GlassCard(item: item, aspectRatio: .portrait, showTitle: false)
                        .frame(width: 180)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 16)
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
                NavigationLink(value: GenreNavigation(name: genre.name, id: genre.id)) {
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
                        PlayerManager.shared.play(
                            item,
                            season: item.lastSeason,
                            episode: item.lastEpisode,
                            episodeImage: item.lastEpisodeImage,
                            fromContinueWatching: true
                        )
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
        // Parallel non-blocking streaming load for all discovery rails
        await withTaskGroup(of: Void.self) { group in
            // 1. Hero Content & Trending Today
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchTrendingAll(window: "day"), !items.isEmpty {
                    await MainActor.run {
                        self.trendingTodayItems = items
                        self.heroContent = Array(items.prefix(10))
                        withAnimation(.easeOut(duration: 0.3)) { self.isLoading = false }
                    }
                } else if let items = try? await StremioService.shared.fetchTrendingMovies(), !items.isEmpty {
                    await MainActor.run {
                        self.heroContent = Array(items.prefix(10))
                        withAnimation(.easeOut(duration: 0.3)) { self.isLoading = false }
                    }
                }
            }
            
            // 2. Trending This Week
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchTrendingAll(window: "week"), !items.isEmpty {
                    await MainActor.run { self.trendingWeekItems = items }
                }
            }
            
            // 3. Popular Movies
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchPopularMovies(), !items.isEmpty {
                    await MainActor.run { self.popularMovies = items }
                }
            }

            // 4. Popular TV Shows
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchPopularTV(), !items.isEmpty {
                    await MainActor.run { self.popularTV = items }
                }
            }

            // 5. Now Playing in Theatres
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchNowPlayingMovies(), !items.isEmpty {
                    await MainActor.run { self.nowPlayingMovies = items }
                }
            }

            // 6. Airing Today on TV
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchAiringTodayTV(), !items.isEmpty {
                    await MainActor.run { self.airingTodayTV = items }
                }
            }

            // 7. On The Air / This Week on TV
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchOnTheAirTV(), !items.isEmpty {
                    await MainActor.run { self.onTheAirTV = items }
                }
            }

            // 8. Top Rated Movies
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchTopRatedMovies(), !items.isEmpty {
                    await MainActor.run { self.topRatedMovies = items }
                }
            }

            // 9. Top Rated TV Shows
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchTopRatedTV(), !items.isEmpty {
                    await MainActor.run { self.topRatedTV = items }
                }
            }

            // 10. Upcoming Movies
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchUpcomingMovies(), !items.isEmpty {
                    await MainActor.run { self.upcomingMovies = items }
                }
            }

            // 11. Quick Watches
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchQuickWatchMovies(), !items.isEmpty {
                    await MainActor.run { self.quickWatches = items }
                }
            }

            // 12. Addon sections
            group.addTask {
                await self.fetchAddonSections()
            }

            // 13. For You Recommendations
            group.addTask {
                if TasteProfileManager.shared.hasEnoughSignal {
                    let (recs, because) = await TasteProfileManager.shared.forYouRecommendations()
                    await MainActor.run {
                        self.forYouItems = recs
                        self.becauseTitle = because?.title
                    }
                }
            }

            // 14. Background history enrichment
            group.addTask {
                await self.userData.enrichHistory()
            }
        }

        await MainActor.run {
            withAnimation(.easeOut(duration: 0.3)) {
                self.isLoading = false
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

#Preview {
    HomeView()
        .background(Color.black)
}
