import SwiftUI

struct MediaListView: View {
    enum ListType: Hashable {
        case continueWatching
        case trendingAllDay
        case trendingAllWeek
        case trendingMovies(window: String)
        case popularMovies
        case nowPlayingMovies
        case upcomingMovies
        case topRatedMovies
        case streamingMovies
        case quickWatches
        case trendingTV(window: String)
        case popularTV
        case airingTodayTV
        case onTheAirTV
        case topRatedTV
        case streamingTV
        case genre(id: Int, name: String) // TMDB genre — real ID + display name
        case ott(id: String, name: String) // OTT platform — catalog code + display name
        case fixed(title: String, items: [MediaItem])

        var title: String {
            switch self {
            case .continueWatching: return "Continue Watching"
            case .trendingAllDay: return "Trending Today"
            case .trendingAllWeek: return "Trending This Week"
            case .trendingMovies(let window): return window == "day" ? "Trending Movies Today" : "Trending Movies This Week"
            case .popularMovies: return "Popular Movies"
            case .nowPlayingMovies: return "Now Playing in Theatres"
            case .upcomingMovies: return "Upcoming Movies"
            case .topRatedMovies: return "Top Rated Movies"
            case .streamingMovies: return "Popular on Streaming"
            case .quickWatches: return "Quick Watches (< 95m)"
            case .trendingTV(let window): return window == "day" ? "Trending Shows Today" : "Trending Shows This Week"
            case .popularTV: return "Popular TV Shows"
            case .airingTodayTV: return "Airing Today on TV"
            case .onTheAirTV: return "On The Air / This Week"
            case .topRatedTV: return "Top Rated TV Shows"
            case .streamingTV: return "Popular on Streaming"
            case .genre(_, let name): return name
            case .ott(_, let name): return name
            case .fixed(let title, _): return title
            }
        }
    }
    
    let title: String
    let type: ListType
    @ObservedObject private var userData = UserDataService.shared
    @Environment(\.openWindow) private var openWindow
    @State private var genreMediaType = "movie" // genre pages: Movies/TV toggle
    @State private var items: [MediaItem] = []
    @State private var isLoading = false
    @State private var currentPage = 1
    @State private var canLoadMore = true
    
    init(title: String? = nil, type: ListType) {
        self.type = type
        self.title = title ?? type.title
    }
    
    let columns = [
        GridItem(.adaptive(minimum: 160), spacing: 24)
    ]
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Header
                HStack(spacing: 16) {
                    Text(title)
                        .font(.system(size: 44, weight: .heavy))
                        .foregroundStyle(.white)

                    if case .genre = type {
                        mediaTypeToggle
                    } else if case .ott = type {
                        mediaTypeToggle
                    }

                    Spacer()
                }
                .padding(.top, 48)
                
                content
            }
            .padding(.leading, 268)
            .padding(.trailing, 40)
            .padding(.top, 40)
            .padding(.bottom, 40)
        }
        .overlay(alignment: .topLeading) {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .padding(.leading, 268)
            .padding(.top, 24)
        }
        .navigationBarBackButtonHidden(true)
        .toolbarVisibility(.hidden, for: .windowToolbar)
        .background(
            Color.black
        )
        .task {
            await loadData()
        }
        .refreshable {
            await TMDBCatalogCacheActor.shared.clear()
            await loadData(reset: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .fluxRefresh)) { _ in
            Task {
                await TMDBCatalogCacheActor.shared.clear()
                await loadData(reset: true)
            }
        }
        .onChange(of: genreMediaType) { _, _ in
            items = []
            currentPage = 1
            canLoadMore = true
            Task { await loadData() }
        }
    }
    
    @ViewBuilder
    private var mediaTypeToggle: some View {
        HStack(spacing: 0) {
            ForEach(["movie", "tv"], id: \.self) { mt in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if genreMediaType != mt {
                            genreMediaType = mt
                            items = []
                            currentPage = 1
                            canLoadMore = true
                            Task { await loadData() }
                        }
                    }
                } label: {
                    Text(mt == "movie" ? "Movies" : "TV Shows")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(genreMediaType == mt ? .black : .white.opacity(0.7))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(genreMediaType == mt ? Color.white : Color.white.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if type == .continueWatching {
            let continueItems = continueWatchingItems
            if continueItems.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 48))
                        .foregroundStyle(.white.opacity(0.3))
                    Text("No In-Progress Titles")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                    Text("Movies and TV shows you start watching will automatically appear here.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 24)], spacing: 32) {
                    ForEach(continueItems) { item in
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
            }
        } else if isLoading && items.isEmpty {
            LazyVGrid(columns: columns, spacing: 40) {
                ForEach(0..<12, id: \.self) { _ in
                    GhostCard()
                }
            }
        } else {
            LazyVGrid(columns: columns, spacing: 40) {
                ForEach(items) { item in
                    NavigationLink(value: item) {
                        GlassCard(item: item, aspectRatio: aspectRatio, showTitle: false)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if item == items.last {
                            Task { await loadData() }
                        }
                    }
                }

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
        }
    }
    
    private var aspectRatio: CardAspectRatio {
        .portrait
    }
    
    private func loadData(reset: Bool = false) async {
        if reset {
            items = []
            currentPage = 1
            canLoadMore = true
        }
        
        guard canLoadMore, !isLoading else { return }
        isLoading = true
        
        do {
            var newItems: [MediaItem] = []
            let page = currentPage
            
            switch type {
            case .continueWatching:
                newItems = userData.history
                canLoadMore = false
            case .trendingAllDay:
                newItems = (try? await TMDBEnricher.shared.fetchTrendingAll(window: "day")) ?? []
                canLoadMore = false
            case .trendingAllWeek:
                newItems = (try? await TMDBEnricher.shared.fetchTrendingAll(window: "week")) ?? []
                canLoadMore = false
            case .trendingMovies(let window):
                newItems = (try? await TMDBEnricher.shared.fetchTrendingMovies(window: window)) ?? []
                canLoadMore = false
            case .popularMovies:
                newItems = (try? await TMDBEnricher.shared.fetchPopularMovies(page: page)) ?? []
            case .nowPlayingMovies:
                newItems = (try? await TMDBEnricher.shared.fetchNowPlayingMovies(page: page)) ?? []
            case .upcomingMovies:
                newItems = (try? await TMDBEnricher.shared.fetchUpcomingMovies(page: page)) ?? []
            case .topRatedMovies:
                newItems = (try? await TMDBEnricher.shared.fetchTopRatedMovies(page: page)) ?? []
            case .streamingMovies:
                newItems = (try? await TMDBEnricher.shared.fetchStreamingMovies(page: page)) ?? []
            case .quickWatches:
                newItems = (try? await TMDBEnricher.shared.fetchQuickWatchMovies(page: page)) ?? []
            case .trendingTV(let window):
                newItems = (try? await TMDBEnricher.shared.fetchTrendingTV(window: window)) ?? []
                canLoadMore = false
            case .popularTV:
                newItems = (try? await TMDBEnricher.shared.fetchPopularTV(page: page)) ?? []
            case .airingTodayTV:
                newItems = (try? await TMDBEnricher.shared.fetchAiringTodayTV(page: page)) ?? []
            case .onTheAirTV:
                newItems = (try? await TMDBEnricher.shared.fetchOnTheAirTV(page: page)) ?? []
            case .topRatedTV:
                newItems = (try? await TMDBEnricher.shared.fetchTopRatedTV(page: page)) ?? []
            case .streamingTV:
                newItems = (try? await TMDBEnricher.shared.fetchStreamingTV(page: page)) ?? []
            case .genre(let id, _):
                newItems = await TMDBEnricher.shared.fetchGenrePage(tmdbGenreID: id, page: page, mediaType: genreMediaType)
            case .ott(let platformID, _):
                let ottType = genreMediaType == "tv" ? "series" : "movie"
                newItems = (try? await StremioService.shared.fetchOTTCatalog(platformID: platformID, type: ottType, page: page)) ?? []
            case .fixed(_, let fixedItems):
                newItems = fixedItems
                canLoadMore = false
            }
            
            await MainActor.run {
                if newItems.isEmpty {
                    canLoadMore = false
                } else {
                    let existingIDs = Set(items.map { $0.id })
                    let uniqueItems = newItems.filter { !existingIDs.contains($0.id) }
                    items.append(contentsOf: uniqueItems)
                    currentPage += 1
                    if currentPage > 500 { canLoadMore = false }
                }
                isLoading = false
            }
        } catch {
            print("Error loading list: \(error)")
            await MainActor.run { isLoading = false }
        }
    }
    
    private var continueWatchingItems: [MediaItem] {
        var seen = Set<String>()
        var result: [MediaItem] = []
        for item in userData.history {
            let strippedID = item.id.replacingOccurrences(of: "tt", with: "")
            let titleKey = "\(item.category.lowercased()):\(item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
            let idKey = "id:\(item.id)"
            let numKey = strippedID.isEmpty ? idKey : "num:\(strippedID)"
            
            if !seen.contains(idKey) && !seen.contains(numKey) && !seen.contains(titleKey) {
                result.append(item)
                seen.insert(idKey)
                seen.insert(numKey)
                if !item.title.isEmpty && item.title != "Unknown" {
                    seen.insert(titleKey)
                }
            }
        }
        return result
    }
}
