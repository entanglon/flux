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
    @ObservedObject private var profileManager = ProfileManager.shared
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
    @State private var becauseWasLoved: Bool = false
    @State private var trendingWindow: String = "day"
    
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Featured Carousel (Trending Today & Hero Content) or Apple TV Skeleton Hero
                if !heroContent.isEmpty {
                    FeaturedCarousel(items: Array(heroContent.prefix(5)))
                        .padding(.bottom, 10)
                        .transition(.opacity)
                } else {
                    GhostHero()
                        .padding(.bottom, 10)
                        .transition(.opacity)
                }
                
                // Continue Watching (Real Data with Episode Stills) or Ghost Rail if loading
                let itemsToDisplay = continueWatchingItems
                if !itemsToDisplay.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        ListSectionHeader(title: "Continue Watching", value: MediaListView.ListType.continueWatching)
                            .padding(.leading, 268)
                            .padding(.trailing, 40)
                        
                        CarouselView(items: itemsToDisplay, spacing: 16, itemWidth: 290) { item in
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
                    .transition(.opacity)
                } else if isLoading && !userData.history.isEmpty {
                    GhostContinueWatchingRail()
                        .transition(.opacity)
                }

                if profileManager.currentProfile?.isKids == true {
                    kidsRails
                } else {
                    adultRails
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
            becauseWasLoved = false
            return
        }
        let (recs, because) = await TasteProfileManager.shared.forYouRecommendations()
        if !Task.isCancelled {
            forYouItems = recs
            becauseTitle = because?.title
            if let b = because {
                becauseWasLoved = TasteProfileManager.shared.lovedItems.contains(where: { $0.id == b.id })
            } else {
                becauseWasLoved = false
            }
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
    
    @ViewBuilder private var adultRails: some View {
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
            .transition(.opacity)
        } else if isLoading {
            GhostRail()
                .transition(.opacity)
        }

        // 2. Popular Movies
        if !popularMovies.isEmpty {
            renderRail(title: "Popular Movies", listType: .popularMovies, items: popularMovies)
        } else if isLoading {
            GhostRail()
                .transition(.opacity)
        }

        // 4. Popular TV Shows
        if !popularTV.isEmpty {
            renderRail(title: "Popular TV Shows", listType: .popularTV, items: popularTV)
        } else if isLoading {
            GhostRail()
                .transition(.opacity)
        }

        // 5. Now Playing
        if !nowPlayingMovies.isEmpty {
            renderRail(title: "Now Playing", listType: .nowPlayingMovies, items: nowPlayingMovies)
        }

        // 6. Airing Today
        if !airingTodayTV.isEmpty {
            renderRail(title: "Airing Today", listType: .airingTodayTV, items: airingTodayTV)
        }

        // Explore OTT Platforms
        exploreOTTRow

        // 7. On TV
        if !onTheAirTV.isEmpty {
            renderRail(title: "On TV", listType: .onTheAirTV, items: onTheAirTV)
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
            renderRail(title: "Upcoming", listType: .upcomingMovies, items: upcomingMovies)
        }

        // 11. Quick Watches (< 95 mins)
        if !quickWatches.isEmpty {
            renderRail(title: "Quick Watches", listType: .quickWatches, items: quickWatches)
        }

        // Addon Sections
        addonRows

        // For You / Taste Recommendations (placed at the bottom, just above Watchlist)
        if !forYouItems.isEmpty {
            let forYouTitle: String = {
                if let title = becauseTitle {
                    return becauseWasLoved ? "Because you liked \(title)" : "Because you watched \(title)"
                }
                return "For You"
            }()
            
            VStack(alignment: .leading, spacing: 16) {
                ListSectionHeader(
                    title: forYouTitle,
                    value: MediaListView.ListType.fixed(title: forYouTitle, items: forYouItems)
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

        watchlistRow
        genreRow
        historyRow
    }

    @ViewBuilder private var kidsRails: some View {
        // 1. Trending for Kids
        if !trendingTodayItems.isEmpty {
            renderRail(title: "Trending for Kids", listType: .fixed(title: "Trending for Kids", items: trendingTodayItems), items: trendingTodayItems)
        } else if isLoading {
            GhostRail().transition(.opacity)
        }

        // 2. Animated Adventures
        if !popularMovies.isEmpty {
            renderRail(title: "Animated Adventures", listType: .fixed(title: "Animated Adventures", items: popularMovies), items: popularMovies)
        } else if isLoading {
            GhostRail().transition(.opacity)
        }

        // 3. Kids TV Shows
        if !popularTV.isEmpty {
            renderRail(title: "Kids Shows", listType: .fixed(title: "Kids Shows", items: popularTV), items: popularTV)
        } else if isLoading {
            GhostRail().transition(.opacity)
        }

        // 4. Family Movie Night
        if !topRatedMovies.isEmpty {
            renderRail(title: "Family Movie Night", listType: .fixed(title: "Family Movie Night", items: topRatedMovies), items: topRatedMovies)
        }

        // 5. Quick Watches
        if !quickWatches.isEmpty {
            renderRail(title: "Quick Watches", listType: .quickWatches, items: quickWatches)
        }

        addonRows

        watchlistRow
        genreRow
        historyRow
    }

    private var displayGenres: [Genre] {
        if profileManager.currentProfile?.isKids == true {
            return genres.filter { KidsContentFilter.shared.isGenreSafeForKids($0.name) }
        }
        return genres
    }

    private var displayWatchlist: [MediaItem] {
        if profileManager.currentProfile?.isKids == true {
            return userData.watchlist.filter { !KidsContentFilter.shared.isRestricted(item: $0) }
        }
        return userData.watchlist
    }

    private var displayHistory: [MediaItem] {
        if profileManager.currentProfile?.isKids == true {
            return userData.recentlyWatched.filter { !KidsContentFilter.shared.isRestricted(item: $0) }
        }
        return userData.recentlyWatched
    }

    @ViewBuilder private var watchlistRow: some View {
        let items = displayWatchlist
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                ListSectionHeader(title: "Watchlist", value: WatchlistNavigation())
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
    }
    
    @ViewBuilder private var genreRow: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(profileManager.currentProfile?.isKids == true ? "Browse for Kids" : "Browse by Genre")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.leading, 268)
                .padding(.trailing, 40)
            
            CarouselView(items: displayGenres, spacing: 16, itemWidth: 160) { genre in
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
        let items = displayHistory
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                ListSectionHeader(title: "Recently Watched", value: HistoryNavigation(showAsContinueWatching: false))
                    .padding(.leading, 268)
                    .padding(.trailing, 40)
                
                CarouselView(items: items, spacing: 16, itemWidth: 290) { item in
                    Button(action: {
                        PlayerManager.shared.play(
                            item,
                            season: item.lastSeason,
                            episode: item.lastEpisode,
                            episodeImage: item.lastEpisodeImage,
                            fromContinueWatching: false
                        )
                        openWindow(id: "player", value: item.id)
                    }) {
                        ContinueWatchingCard(item: item, mode: .recentlyWatched)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            }
            .padding(.bottom, 16)
        }
    }
}

extension HomeView {
    private func loadData() async {
        if profileManager.currentProfile?.isKids == true {
            await loadKidsData()
            return
        }
        // Parallel non-blocking streaming load for all discovery rails
        await withTaskGroup(of: Void.self) { group in
            // 1. Trending Today, Trending This Week & Curated Hero Billboard
            group.addTask {
                async let dayTask = try? TMDBEnricher.shared.fetchTrendingAll(window: "day")
                async let weekTask = try? TMDBEnricher.shared.fetchTrendingAll(window: "week")
                
                let (dayItems, weekItems) = await (dayTask, weekTask)
                
                if let dayList = dayItems, !dayList.isEmpty {
                    await MainActor.run {
                        self.trendingTodayItems = dayList
                    }
                }
                
                if let weekList = weekItems, !weekList.isEmpty {
                    // Curate Flagship Hero Titles from Weekly Trends:
                    // Must have high-res backdrop and be released, preserving genuine trending order.
                    let heroCandidates = weekList.filter { item in
                        let hasBackdrop = item.backdropURL != nil || item.heroURL != nil
                        return hasBackdrop && item.isReleased
                    }
                    
                    let finalHero = Array((heroCandidates.isEmpty ? weekList : heroCandidates).prefix(7))
                    await MainActor.run {
                        self.trendingWeekItems = weekList
                        self.heroContent = finalHero
                        withAnimation(.easeOut(duration: 0.3)) { self.isLoading = false }
                    }
                } else if let items = try? await StremioService.shared.fetchTrendingMovies(), !items.isEmpty {
                    // Cinemeta fallback only when no TMDB key exists
                    guard !TMDBEnricher.shared.hasKey else { return }
                    let filtered = items.filter { ($0.backdropURL != nil || $0.heroURL != nil) && $0.isReleased }
                    await MainActor.run {
                        self.heroContent = Array((filtered.isEmpty ? items : filtered).prefix(7))
                        withAnimation(.easeOut(duration: 0.3)) { self.isLoading = false }
                    }
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

            // 6. Airing Today
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchAiringTodayTV(), !items.isEmpty {
                    await MainActor.run { self.airingTodayTV = items }
                }
            }

            // 7. On TV
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
    
    private var continueWatchingItems: [MediaItem] {
        if profileManager.currentProfile?.isKids == true {
            return userData.continueWatching.filter { !KidsContentFilter.shared.isRestricted(item: $0) }
        }
        return userData.continueWatching
    }

    private func loadKidsData() async {
        await MainActor.run {
            self.trendingTodayItems = []
            self.trendingWeekItems = []
            self.heroContent = []
            self.popularMovies = []
            self.popularTV = []
            self.topRatedMovies = []
            self.quickWatches = []
            self.addonSections = []
            self.isLoading = true
        }

        await withTaskGroup(of: Void.self) { group in
            // 1. Trending for Kids & Hero Billboard
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchKidsTrending(), !items.isEmpty {
                    let safe = await KidsContentFilter.shared.filterSafeItems(items)
                    let heroCandidates = safe.filter { ($0.backdropURL != nil || $0.heroURL != nil) && $0.isReleased }
                    let finalHero = Array((heroCandidates.isEmpty ? safe : heroCandidates).prefix(7))
                    await MainActor.run {
                        self.trendingTodayItems = safe
                        self.trendingWeekItems = safe
                        self.heroContent = finalHero
                        withAnimation(.easeOut(duration: 0.3)) { self.isLoading = false }
                    }
                }
            }

            // 2. Animated Adventures
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchAnimatedAdventures(), !items.isEmpty {
                    let safe = await KidsContentFilter.shared.filterSafeItems(items)
                    await MainActor.run { self.popularMovies = safe }
                }
            }

            // 3. Kids Shows
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchKidsTV(), !items.isEmpty {
                    let safe = await KidsContentFilter.shared.filterSafeItems(items)
                    await MainActor.run { self.popularTV = safe }
                }
            }

            // 4. Family Movie Night
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchFamilyMovies(), !items.isEmpty {
                    let safe = await KidsContentFilter.shared.filterSafeItems(items)
                    await MainActor.run { self.topRatedMovies = safe }
                }
            }

            // 5. Quick Watches (filtered for kids)
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchQuickWatchMovies(), !items.isEmpty {
                    let safe = await KidsContentFilter.shared.filterSafeItems(items)
                    await MainActor.run { self.quickWatches = safe }
                }
            }

            // 6. Addon Sections (filtered for kids)
            group.addTask {
                await self.fetchAddonSections()
                let currentSections = await MainActor.run { self.addonSections }
                var safeSections: [CatalogSection] = []
                for section in currentSections {
                    let safe = await KidsContentFilter.shared.filterSafeItems(section.items)
                    if !safe.isEmpty {
                        safeSections.append(CatalogSection(addonName: section.addonName, title: section.title, type: section.type, items: safe))
                    }
                }
                await MainActor.run { self.addonSections = safeSections }
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
    HomeView()
        .background(Color.black)
}
