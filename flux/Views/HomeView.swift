
import SwiftUI

struct HomeView: View {
    @ObservedObject private var dataManager = DataManager.shared
    @ObservedObject private var userData = UserDataService.shared
    @Environment(\.openWindow) private var openWindow
    
    @State private var trendingContent: [MediaItem] = []
    @State private var newReleaseContent: [MediaItem] = []
    @State private var upcomingContent: [MediaItem] = []
    @State private var popularContent: [MediaItem] = []
    @State private var forYouContent: [MediaItem] = []
    @State private var genres: [Genre] = Genre.allGenres

    @State private var channels: [Channel] = [
        Channel(name: "Netflix", providerID: 8, logoName: "play.tv.fill", logoURL: URL(string: "https://upload.wikimedia.org/wikipedia/commons/thumb/0/08/Netflix_2015_logo.svg/800px-Netflix_2015_logo.svg.png"), brandColor: Color(red: 229/255, green: 9/255, blue: 20/255), representativeImageURL: URL(string: "https://unsplash.com/photos/ZHFIR2oAPnM/download?force=true")),
        Channel(name: "Apple TV+", providerID: 350, logoName: "apple.logo", logoURL: URL(string: "https://upload.wikimedia.org/wikipedia/commons/thumb/a/ad/Apple_TV_Plus_Logo_white.svg/800px-Apple_TV_Plus_Logo_white.svg.png"), brandColor: Color.white, representativeImageURL: URL(string: "https://unsplash.com/photos/UCd78vfC8vU/download?force=true")),
        Channel(name: "Disney+", providerID: 337, logoName: "play.rectangle.fill", logoURL: URL(string: "https://upload.wikimedia.org/wikipedia/commons/thumb/3/3e/Disney%2B_logo.svg/800px-Disney%2B_logo.svg.png"), brandColor: Color(red: 17/255, green: 60/255, blue: 207/255), representativeImageURL: URL(string: "https://unsplash.com/photos/Lmd-CpZOGWc/download?force=true")),
        Channel(name: "JioHotstar", providerID: 122, logoName: "star.circle.fill", logoURL: URL(string: "https://upload.wikimedia.org/wikipedia/commons/4/40/JioHotstar_2025.png"), brandColor: Color(red: 18/255, green: 28/255, blue: 68/255), representativeImageURL: URL(string: "https://unsplash.com/photos/WCgioEcEVNc/download?force=true")),
        Channel(name: "Prime Video", providerID: 9, logoName: "checkmark.seal.fill", logoURL: URL(string: "https://upload.wikimedia.org/wikipedia/commons/thumb/f/f1/Prime_Video.png/800px-Prime_Video.png"), brandColor: Color(red: 0/255, green: 168/255, blue: 225/255), representativeImageURL: URL(string: "https://unsplash.com/photos/hOhlYhAiizc/download?force=true")),
        Channel(name: "HBO Max", providerID: 1899, logoName: "h.circle.fill", logoURL: URL(string: "https://upload.wikimedia.org/wikipedia/commons/thumb/b/b3/HBO_Max_%282025%29.svg/800px-HBO_Max_%282025%29.svg.png"), brandColor: Color(red: 71/255, green: 22/255, blue: 209/255), representativeImageURL: URL(string: "https://unsplash.com/photos/75xPHEQBmvA/download?force=true")),
        Channel(name: "Hulu", providerID: 15, logoName: "h.square.fill", logoURL: URL(string: "https://upload.wikimedia.org/wikipedia/commons/thumb/5/50/Hulu_logo_%282017%29.svg/800px-Hulu_logo_%282017%29.svg.png"), brandColor: Color(red: 28/255, green: 231/255, blue: 131/255), representativeImageURL: URL(string: "https://unsplash.com/photos/3tYZjGSBwbk/download?force=true")),
        Channel(name: "Peacock", providerID: 386, logoName: "p.circle.fill", logoURL: URL(string: "https://upload.wikimedia.org/wikipedia/commons/thumb/d/d3/NBCUniversal_Peacock_Logo.svg/800px-NBCUniversal_Peacock_Logo.svg.png"), brandColor: Color.white, representativeImageURL: URL(string: "https://unsplash.com/photos/NgF--NZcUNE/download?force=true")),
        Channel(name: "Paramount+", providerID: 531, logoName: "star.fill", logoURL: URL(string: "https://upload.wikimedia.org/wikipedia/commons/thumb/a/a5/Paramount_Plus.svg/800px-Paramount_Plus.svg.png"), brandColor: Color(red: 0/255, green: 100/255, blue: 255/255), representativeImageURL: URL(string: "https://unsplash.com/photos/MaG8tiHjqXc/download?force=true")),
        Channel(name: "Viki", providerID: 444, logoName: "v.circle.fill", logoURL: URL(string: "https://upload.wikimedia.org/wikipedia/commons/thumb/d/d9/Rakuten_Viki_Logo_2019.svg/800px-Rakuten_Viki_Logo_2019.svg.png"), brandColor: Color(red: 0/255, green: 160/255, blue: 200/255), representativeImageURL: URL(string: "https://unsplash.com/photos/SIVuMhvQlt8/download?force=true"))
    ]
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
                    // Featured Carousel (Trending New Releases)
                    if !newReleaseContent.isEmpty {
                        // Sort by popularity to show the "Trending" new arrivals
                        let heroItems = newReleaseContent.sorted { ($0.popularity ?? 0) > ($1.popularity ?? 0) }
                        FeaturedCarousel(items: Array(heroItems.prefix(5)))
                            .padding(.bottom, 10)
                    } else if !trendingContent.isEmpty {
                        // Fallback
                        FeaturedCarousel(items: Array(trendingContent.prefix(5)))
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
                    }

                    // Top 10 on Flux (Combined)
                    if !trendingContent.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            ListSectionHeader(title: "Top 10 on Flux", value: MediaListView.ListType.topTen)
                                .padding(.horizontal, 40)
                            
                            CarouselView(items: Array(trendingContent.prefix(10))) { item, index in
                                NavigationLink(value: item) {
                                    TopTenCard(item: item, rank: index + 1)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    
                    // New Releases (Combined)
                    if !newReleaseContent.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            ListSectionHeader(title: "New Releases", value: MediaListView.ListType.newReleases)
                                .padding(.horizontal, 40)
                            
                            CarouselView(items: newReleaseContent) { item in
                                NavigationLink(value: item) {
                                    GlassCard(item: item, aspectRatio: .portrait, showTitle: false)
                                        .frame(width: 180)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    
                    // Upcoming (Combined)
                    if !upcomingContent.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            ListSectionHeader(title: "Coming Soon", value: MediaListView.ListType.upcoming)
                                .padding(.horizontal, 40)
                            
                            CarouselView(items: upcomingContent) { item in
                                NavigationLink(value: item) {
                                    GlassCard(item: item, aspectRatio: .portrait, showTitle: false)
                                        .frame(width: 180)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Explore Channels
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Explore Channels")
                            .font(.title2)
                            .fontWeight(.bold)
                            .padding(.horizontal, 40)
                        
                        CarouselView(items: channels, itemWidth: 160) { channel in
                            NavigationLink(value: MediaListView.ListType.provider(id: channel.providerID)) {
                                ChannelCard(channel: channel)
                            }
                            .buttonStyle(.plain)
                        }
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
                    }

                    // For You (AI Curated)
                    if !forYouContent.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            ListSectionHeader(title: "For You", value: MediaListView.ListType.forYou)
                                .padding(.horizontal, 40)
                            
                            CarouselView(items: forYouContent) { item in
                                NavigationLink(value: item) {
                                    GlassCard(item: item, aspectRatio: .portrait, showTitle: false)
                                        .frame(width: 180)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Trending Now (Combined)
                    if !trendingContent.isEmpty {
                         VStack(alignment: .leading, spacing: 16) {
                            ListSectionHeader(title: "Trending Now", value: MediaListView.ListType.trending)
                                .padding(.horizontal, 40)
                            
                            CarouselView(items: trendingContent) { item in
                                NavigationLink(value: item) {
                                    GlassCard(item: item, aspectRatio: .portrait, showTitle: false)
                                        .frame(width: 180)
                                }
                                .buttonStyle(.plain)
                            }
                        }
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

                    // Popular Now (Combined)
                    if !popularContent.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            ListSectionHeader(title: "Popular Now", value: MediaListView.ListType.popularMovies)
                                .padding(.horizontal, 40)
                            
                            CarouselView(items: popularContent) { item in
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
            async let trendingM = TMDBService.shared.fetchTrendingMovies()
            async let trendingT = TMDBService.shared.fetchTrendingTVShows()
            
            async let nowPlayingM = TMDBService.shared.fetchNowPlayingMovies()
            async let airingTodayT = TMDBService.shared.fetchAiringTodayTV()
            
            // Removed upcomingM and onTheAirT single page fetches

            
            async let popularM = TMDBService.shared.fetchPopularMovies()
            async let popularT = TMDBService.shared.fetchPopularTVShows()
            
            let (tm, tt, npm, att, pm, pt) = try await (trendingM, trendingT, nowPlayingM, airingTodayT, popularM, popularT)
            
            // Combine and Sort by Popularity for Top 10
            trendingContent = (tm.map { $0.toMediaItem() } + tt.map { $0.toMediaItem() })
                .sorted { ($0.popularity ?? 0) > ($1.popularity ?? 0) }
            
            let newM = npm.map { $0.toMediaItem() }
            let newT = att.map { $0.toMediaItem() }
            newReleaseContent = (newM + newT).sorted { ($0.popularity ?? 0) > ($1.popularity ?? 0) }
            
            // Fetch Page 1, 2, 3 for Upcoming to ensure we get enough future items after filtering
            async let um1 = TMDBService.shared.fetchUpcomingMovies(page: 1)
            async let um2 = TMDBService.shared.fetchUpcomingMovies(page: 2)
            async let um3 = TMDBService.shared.fetchUpcomingMovies(page: 3)
            async let otat1 = TMDBService.shared.fetchOnTheAirTV(page: 1)
            async let otat2 = TMDBService.shared.fetchOnTheAirTV(page: 2)
            async let otat3 = TMDBService.shared.fetchOnTheAirTV(page: 3)
            
            let (upcomingM1, upcomingM2, upcomingM3, upcomingT1, upcomingT2, upcomingT3) = try await (um1, um2, um3, otat1, otat2, otat3)
            
            let upM = (upcomingM1 + upcomingM2 + upcomingM3).map { $0.toMediaItem() }
            let upT = (upcomingT1 + upcomingT2 + upcomingT3).map { $0.toMediaItem() }
            
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            let today = Date()
            
            // Filter strictly for future releases (or today) and sort by popularity
            upcomingContent = (upM + upT)
                .filter { item in
                    guard let dateString = item.releaseDate,
                          let date = dateFormatter.date(from: dateString) else { return false }
                    return date >= today
                }
                .sorted { ($0.popularity ?? 0) > ($1.popularity ?? 0) } // Popularity Descending
                .prefix(20) // Limit to top 20
                .map { $0 }
            
            popularContent = (pm.map { $0.toMediaItem() } + pt.map { $0.toMediaItem() }).shuffled()
            
            // Note: We use static curated images for Channels and Genres now.
            // Removed dynamic fetching to prevent overwriting high-quality assets.
            
            // Generate Recommendations
            await generateForYouRecommendations()
            
            isLoading = false
        } catch {
            print("Error fetching data: \(error)")
            isLoading = false
        }
    }
    
    private func generateForYouRecommendations() async {
        // AI Curation Simulation
        // 1. Get seed items from History or Watchlist
        let historySeeds = userData.history.prefix(2)
        let watchlistSeeds = userData.watchlist.prefix(2)
        let seeds = (Array(historySeeds) + Array(watchlistSeeds)).shuffled().prefix(3)
        
        var recs: [MediaItem] = []
        
        if seeds.isEmpty {
            // Cold Start: Use Top Rated
            if let tr = try? await TMDBService.shared.fetchTopRatedMovies() {
                recs = tr.map { $0.toMediaItem() }
            }
        } else {
            // Personalized: Fetch similar items
            await withTaskGroup(of: [MediaItem].self) { group in
                for seed in seeds {
                    group.addTask {
                        let idString = seed.id
                        if let id = Int(idString) {
                            if seed.category == "TV Show" {
                                if let recs = try? await TMDBService.shared.fetchTVShowRecommendations(id: id) {
                                    return recs.map { $0.toMediaItem() }
                                } else if let similar = try? await TMDBService.shared.fetchSimilarTVShows(id: id) {
                                    return similar.map { $0.toMediaItem() }
                                }
                            } else {
                                if let recs = try? await TMDBService.shared.fetchMovieRecommendations(id: id) {
                                    return recs.map { $0.toMediaItem() }
                                } else if let similar = try? await TMDBService.shared.fetchSimilarMovies(id: id) {
                                    return similar.map { $0.toMediaItem() }
                                }
                            }
                        }
                        return []
                    }
                }
                
                for await results in group {
                    recs.append(contentsOf: results)
                }
            }
        }
        
        // Remove duplicates and shuffle
        let existingIDs = Set(seeds.map { $0.id })
        var uniqueRecs: [MediaItem] = []
        var seenIDs = existingIDs
        
        for item in recs {
             if !seenIDs.contains(item.id) {
                 uniqueRecs.append(item)
                 seenIDs.insert(item.id)
             }
        }
        
        self.forYouContent = uniqueRecs
            .shuffled()
            .prefix(15) // Limit to 15 items
            .map { $0 }
    }
}

#Preview {
    HomeView()
        .background(Color.black)
}
