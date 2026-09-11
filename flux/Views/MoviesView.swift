import SwiftUI

struct MoviesView: View {
    @ObservedObject private var profileManager = ProfileManager.shared
    @State private var heroMovies: [MediaItem] = []
    @State private var forYouMovies: [MediaItem] = []
    @State private var trendingTodayMovies: [MediaItem] = []
    @State private var trendingWeekMovies: [MediaItem] = []
    @State private var popularMovies: [MediaItem] = []
    @State private var nowPlayingMovies: [MediaItem] = []
    @State private var upcomingMovies: [MediaItem] = []
    @State private var streamingMovies: [MediaItem] = []
    @State private var topRatedMovies: [MediaItem] = []
    @State private var quickWatches: [MediaItem] = []
    @State private var trendingWindow: String = "day"
    @State private var isLoading = true
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Featured Movies Carousel or Apple TV Skeleton Hero
                if !heroMovies.isEmpty {
                    FeaturedCarousel(items: Array(heroMovies.prefix(5)))
                        .padding(.bottom, 10)
                        .transition(.opacity)
                } else {
                    GhostHero()
                        .padding(.bottom, 10)
                        .transition(.opacity)
                }

                if profileManager.currentProfile?.isKids == true {
                    kidsMoviesRails
                } else {
                    adultMoviesRails
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
    }
    
    @ViewBuilder private var adultMoviesRails: some View {
        // For You Movies
        if !forYouMovies.isEmpty {
            renderRail(title: "For You".localized, listType: .fixed(title: "For You Movies".localized, items: forYouMovies), items: forYouMovies)
        }

        // 1. Combined Trending Movies with Liquid Glass Toggle
        let activeTrending = trendingWindow == "day" ? trendingTodayMovies : trendingWeekMovies
        if !activeTrending.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                TrendingToggleSectionHeader(
                    title: "Trending".localized,
                    window: $trendingWindow,
                    value: MediaListView.ListType.trendingMovies(window: trendingWindow)
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
                .id("trending-movies-\(trendingWindow)")
            }
            .padding(.bottom, 16)
            .transition(.opacity)
        } else if isLoading {
            GhostRail()
                .transition(.opacity)
        }

        // 2. Popular Movies
        if !popularMovies.isEmpty {
            renderRail(title: "Popular Movies".localized, listType: .popularMovies, items: popularMovies)
        } else if isLoading {
            GhostRail()
                .transition(.opacity)
        }

        // 4. Now Playing
        if !nowPlayingMovies.isEmpty {
            renderRail(title: "Now Playing".localized, listType: .nowPlayingMovies, items: nowPlayingMovies)
        }

        // 5. Popular on Streaming
        if !streamingMovies.isEmpty {
            renderRail(title: "Popular on Streaming".localized, listType: .streamingMovies, items: streamingMovies)
        }

        // 6. Upcoming
        if !upcomingMovies.isEmpty {
            renderRail(title: "Upcoming".localized, listType: .upcomingMovies, items: upcomingMovies)
        }

        // 7. Top Rated Movies
        if !topRatedMovies.isEmpty {
            renderRail(title: "Top Rated Movies".localized, listType: .topRatedMovies, items: topRatedMovies)
        }

        // 8. Quick Watches (< 95 mins)
        if !quickWatches.isEmpty {
            renderRail(title: "Quick Watches".localized, listType: .quickWatches, items: quickWatches)
        }
    }

    @ViewBuilder private var kidsMoviesRails: some View {
        if !popularMovies.isEmpty {
            renderRail(title: "Kids & Family Movies".localized, listType: .fixed(title: "Kids & Family Movies".localized, items: popularMovies), items: popularMovies)
        } else if isLoading {
            GhostRail().transition(.opacity)
        }

        if !topRatedMovies.isEmpty {
            renderRail(title: "Animated Adventures".localized, listType: .fixed(title: "Animated Adventures".localized, items: topRatedMovies), items: topRatedMovies)
        }

        if !streamingMovies.isEmpty {
            renderRail(title: "Family Favorites".localized, listType: .fixed(title: "Family Favorites".localized, items: streamingMovies), items: streamingMovies)
        }

        if !quickWatches.isEmpty {
            renderRail(title: "Quick Watches".localized, listType: .quickWatches, items: quickWatches)
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
    
    private func loadData() async {
        if profileManager.currentProfile?.isKids == true {
            await loadKidsMoviesData()
            return
        }
        await withTaskGroup(of: Void.self) { group in
            // 1. Trending Today, Trending Week & Curated Hero Billboard
            group.addTask {
                async let dayTask = try? TMDBEnricher.shared.fetchTrendingMovies(window: "day")
                async let weekTask = try? TMDBEnricher.shared.fetchTrendingMovies(window: "week")
                let (dayItems, weekItems) = await (dayTask, weekTask)
                
                if let dayList = dayItems, !dayList.isEmpty {
                    await MainActor.run { self.trendingTodayMovies = dayList }
                }
                if let weekList = weekItems, !weekList.isEmpty {
                    let heroCandidates = weekList.filter { item in
                        let hasBackdrop = item.backdropURL != nil || item.heroURL != nil
                        return hasBackdrop && item.isReleased
                    }
                    let finalHero = Array((heroCandidates.isEmpty ? weekList : heroCandidates).prefix(7))
                    await MainActor.run {
                        self.trendingWeekMovies = weekList
                        self.heroMovies = finalHero
                        withAnimation(.easeOut(duration: 0.3)) { self.isLoading = false }
                    }
                }
            }
            
            // 3. Popular Movies
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchPopularMovies(), !items.isEmpty {
                    await MainActor.run {
                        self.popularMovies = items
                        if self.heroMovies.isEmpty { self.heroMovies = Array(items.prefix(10)) }
                        withAnimation(.easeOut(duration: 0.3)) { self.isLoading = false }
                    }
                }
            }

            // 4. Now Playing in Theatres
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchNowPlayingMovies(), !items.isEmpty {
                    await MainActor.run { self.nowPlayingMovies = items }
                }
            }

            // 5. Popular on Streaming
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchStreamingMovies(), !items.isEmpty {
                    await MainActor.run { self.streamingMovies = items }
                }
            }

            // 6. Upcoming in Theatres
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchUpcomingMovies(), !items.isEmpty {
                    await MainActor.run { self.upcomingMovies = items }
                }
            }

            // 7. Top Rated Movies
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchTopRatedMovies(), !items.isEmpty {
                    await MainActor.run { self.topRatedMovies = items }
                }
            }

            // 8. Quick Watches
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchQuickWatchMovies(), !items.isEmpty {
                    await MainActor.run { self.quickWatches = items }
                }
            }

            // 9. For You Movies
            group.addTask {
                if TasteProfileManager.shared.hasEnoughSignal {
                    let (recs, _) = await TasteProfileManager.shared.forYouRecommendations()
                    let movieRecs = recs.filter { $0.category.lowercased().contains("movie") }
                    await MainActor.run { self.forYouMovies = movieRecs }
                }
            }
        }

        await MainActor.run {
            withAnimation(.easeOut(duration: 0.3)) {
                self.isLoading = false
            }
        }
    }

    private func loadKidsMoviesData() async {
        await MainActor.run {
            self.popularMovies = []
            self.heroMovies = []
            self.topRatedMovies = []
            self.streamingMovies = []
            self.quickWatches = []
            self.isLoading = true
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchKidsMovies(), !items.isEmpty {
                    let safe = await KidsContentFilter.shared.filterSafeItems(items)
                    await MainActor.run {
                        self.popularMovies = safe
                        self.heroMovies = Array(safe.prefix(7))
                        withAnimation(.easeOut(duration: 0.3)) { self.isLoading = false }
                    }
                }
            }
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchAnimatedAdventures(), !items.isEmpty {
                    let safe = await KidsContentFilter.shared.filterSafeItems(items)
                    await MainActor.run { self.topRatedMovies = safe }
                }
            }
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchFamilyMovies(), !items.isEmpty {
                    let safe = await KidsContentFilter.shared.filterSafeItems(items)
                    await MainActor.run { self.streamingMovies = safe }
                }
            }
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchQuickWatchMovies(), !items.isEmpty {
                    let safe = await KidsContentFilter.shared.filterSafeItems(items)
                    await MainActor.run { self.quickWatches = safe }
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
