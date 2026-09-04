import SwiftUI

struct MoviesView: View {
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

                    // For You Movies
                    if !forYouMovies.isEmpty {
                        renderRail(title: "For You", listType: .fixed(title: "For You Movies", items: forYouMovies), items: forYouMovies)
                    }

                    // 1. Combined Trending Movies with Liquid Glass Toggle
                    let activeTrending = trendingWindow == "day" ? trendingTodayMovies : trendingWeekMovies
                    if !activeTrending.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            TrendingToggleSectionHeader(
                                title: "Trending",
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
                        renderRail(title: "Popular Movies", listType: .popularMovies, items: popularMovies)
                    } else if isLoading {
                        GhostRail()
                            .transition(.opacity)
                    }

                    // 4. Now Playing in Theatres
                    if !nowPlayingMovies.isEmpty {
                        renderRail(title: "Now Playing in Theatres", listType: .nowPlayingMovies, items: nowPlayingMovies)
                    }

                    // 5. Popular on Streaming
                    if !streamingMovies.isEmpty {
                        renderRail(title: "Popular on Streaming", listType: .streamingMovies, items: streamingMovies)
                    }

                    // 6. Upcoming in Theatres
                    if !upcomingMovies.isEmpty {
                        renderRail(title: "Upcoming in Theatres", listType: .upcomingMovies, items: upcomingMovies)
                    }

                    // 7. Top Rated Movies
                    if !topRatedMovies.isEmpty {
                        renderRail(title: "Top Rated Movies", listType: .topRatedMovies, items: topRatedMovies)
                    }

                    // 8. Quick Watches (< 95 mins)
                    if !quickWatches.isEmpty {
                        renderRail(title: "Quick Watches", listType: .quickWatches, items: quickWatches)
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
                        let hasOverview = !item.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        let hasGoodRating = (item.voteAverage ?? 6.5) >= 6.0
                        return hasBackdrop && hasOverview && item.isReleased && hasGoodRating
                    }
                    .sorted { a, b in
                        let scoreA = (a.voteAverage ?? 6.0) * 15.0 + (a.popularity ?? 0) * 0.1
                        let scoreB = (b.voteAverage ?? 6.0) * 15.0 + (b.popularity ?? 0) * 0.1
                        return scoreA > scoreB
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
}
