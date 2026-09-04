import SwiftUI

struct TVShowsView: View {
    @State private var heroShows: [MediaItem] = []
    @State private var forYouShows: [MediaItem] = []
    @State private var trendingTodayShows: [MediaItem] = []
    @State private var trendingWeekShows: [MediaItem] = []
    @State private var popularShows: [MediaItem] = []
    @State private var airingTodayShows: [MediaItem] = []
    @State private var onTheAirShows: [MediaItem] = []
    @State private var streamingShows: [MediaItem] = []
    @State private var topRatedShows: [MediaItem] = []
    @State private var trendingWindow: String = "day"
    @State private var isLoading = true
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Featured TV Carousel or Apple TV Skeleton Hero
                if !heroShows.isEmpty {
                    FeaturedCarousel(items: Array(heroShows.prefix(5)))
                        .padding(.bottom, 10)
                        .transition(.opacity)
                } else {
                    GhostHero()
                        .padding(.bottom, 10)
                        .transition(.opacity)
                }

                    // For You TV Shows
                    if !forYouShows.isEmpty {
                        renderRail(title: "For You", listType: .fixed(title: "For You TV Shows", items: forYouShows), items: forYouShows)
                    }

                    // 1. Combined Trending TV Shows with Liquid Glass Toggle
                    let activeTrending = trendingWindow == "day" ? trendingTodayShows : trendingWeekShows
                    if !activeTrending.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            TrendingToggleSectionHeader(
                                title: "Trending",
                                window: $trendingWindow,
                                value: MediaListView.ListType.trendingTV(window: trendingWindow)
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
                            .id("trending-tv-\(trendingWindow)")
                    }
                    .padding(.bottom, 16)
                    .transition(.opacity)
                } else if isLoading {
                    GhostRail()
                        .transition(.opacity)
                }

                // 2. Popular TV Shows
                if !popularShows.isEmpty {
                    renderRail(title: "Popular TV Shows", listType: .popularTV, items: popularShows)
                } else if isLoading {
                    GhostRail()
                        .transition(.opacity)
                }

                // 4. Airing Today on TV
                if !airingTodayShows.isEmpty {
                    renderRail(title: "Airing Today on TV", listType: .airingTodayTV, items: airingTodayShows)
                }

                // 5. On The Air / This Week on TV
                if !onTheAirShows.isEmpty {
                    renderRail(title: "On The Air / This Week", listType: .onTheAirTV, items: onTheAirShows)
                }

                // 6. Popular on Streaming
                if !streamingShows.isEmpty {
                    renderRail(title: "Popular on Streaming", listType: .streamingTV, items: streamingShows)
                }

                // 7. Top Rated TV Shows
                if !topRatedShows.isEmpty {
                    renderRail(title: "Top Rated Shows", listType: .topRatedTV, items: topRatedShows)
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
                async let dayTask = try? TMDBEnricher.shared.fetchTrendingTV(window: "day")
                async let weekTask = try? TMDBEnricher.shared.fetchTrendingTV(window: "week")
                let (dayItems, weekItems) = await (dayTask, weekTask)
                
                if let dayList = dayItems, !dayList.isEmpty {
                    await MainActor.run { self.trendingTodayShows = dayList }
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
                        self.trendingWeekShows = weekList
                        self.heroShows = finalHero
                        withAnimation(.easeOut(duration: 0.3)) { self.isLoading = false }
                    }
                }
            }
            
            // 3. Popular TV Shows
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchPopularTV(), !items.isEmpty {
                    await MainActor.run {
                        self.popularShows = items
                        if self.heroShows.isEmpty { self.heroShows = Array(items.prefix(10)) }
                        withAnimation(.easeOut(duration: 0.3)) { self.isLoading = false }
                    }
                }
            }

            // 4. Airing Today on TV
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchAiringTodayTV(), !items.isEmpty {
                    await MainActor.run { self.airingTodayShows = items }
                }
            }

            // 5. On The Air / This Week on TV
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchOnTheAirTV(), !items.isEmpty {
                    await MainActor.run { self.onTheAirShows = items }
                }
            }

            // 6. Popular on Streaming
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchStreamingTV(), !items.isEmpty {
                    await MainActor.run { self.streamingShows = items }
                }
            }

            // 7. Top Rated TV Shows
            group.addTask {
                if let items = try? await TMDBEnricher.shared.fetchTopRatedTV(), !items.isEmpty {
                    await MainActor.run { self.topRatedShows = items }
                }
            }

            // 8. For You TV Shows
            group.addTask {
                if TasteProfileManager.shared.hasEnoughSignal {
                    let (recs, _) = await TasteProfileManager.shared.forYouRecommendations()
                    let tvRecs = recs.filter { $0.category.lowercased().contains("tv") || $0.category.lowercased().contains("series") }
                    await MainActor.run { self.forYouShows = tvRecs }
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
