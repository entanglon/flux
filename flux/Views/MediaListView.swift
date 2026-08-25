import SwiftUI

struct MediaListView: View {
    enum ListType: Hashable {
        case trendingMovies
        case popularMovies
        case topRatedMovies
        case trendingTV
        case popularTV
        case genre(id: Int) // TMDB genre ID maps to our static list
        case fixed(title: String, items: [MediaItem])
        
        var title: String {
            switch self {
            case .trendingMovies: return "Trending Movies"
            case .popularMovies: return "Popular Movies"
            case .topRatedMovies: return "Top Rated Movies"
            case .trendingTV: return "Trending TV Shows"
            case .popularTV: return "Popular TV Shows"
            case .genre: return "Genre"
            case .fixed(let title, _): return title
            }
        }
    }
    
    let title: String
    let type: ListType
    @State private var items: [MediaItem] = []
    @State private var isLoading = false
    @State private var skipCount = 0
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
                // Header with Liquid Glass Back button
                HStack(spacing: 16) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .contentShape(Circle())
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)

                    Text(title)
                        .font(.system(size: 44, weight: .heavy))
                        .foregroundStyle(.white)
                    
                    Spacer()
                }
                .padding(.top, 24)
                
                content
            }
            .padding(.leading, 268)
            .padding(.trailing, 40)
            .padding(.top, 40)
            .padding(.bottom, 40)
        }
        .navigationBarBackButtonHidden(true)
        .toolbarVisibility(.hidden, for: .windowToolbar)
        .background(
            LinearGradient(gradient: Gradient(colors: [Color(#colorLiteral(red: 0.1, green: 0.1, blue: 0.2, alpha: 1)), .black]), startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .task {
            await loadData()
        }
    }
    
    @ViewBuilder
    private var content: some View {
        if isLoading && items.isEmpty {
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
        switch type {
        case .trendingTV, .popularTV:
            return .landscape
        default:
            return .portrait
        }
    }
    
    private func loadData(reset: Bool = false) async {
        if reset {
            items = []
            skipCount = 0
            canLoadMore = true
        }
        
        guard canLoadMore, !isLoading else { return }
        isLoading = true
        
        do {
            var newItems: [MediaItem] = []
            
            switch type {
            case .trendingMovies:
                newItems = try await StremioService.shared.fetchTrendingMovies()
            case .popularMovies:
                newItems = try await StremioService.shared.fetchPopularMovies()
            case .topRatedMovies:
                newItems = try await StremioService.shared.fetchTrendingMovies() // Placeholder
            case .trendingTV:
                newItems = try await StremioService.shared.fetchTrendingTVShows()
            case .popularTV:
                newItems = try await StremioService.shared.fetchPopularTVShows()
            case .genre(let id):
                if let genreName = Genre.allGenres.first(where: { $0.id == id })?.name {
                    newItems = try await StremioService.shared.fetchCatalog(type: "movie", id: "top", genre: genreName, skip: skipCount)
                }
            case .fixed(_, let fixedItems):
                newItems = fixedItems
                canLoadMore = false
            }
            
            await MainActor.run {
                if newItems.isEmpty {
                    canLoadMore = false
                } else {
                    // Deduplicate + hide unreleased titles (nothing to play yet)
                    let existingIDs = Set(items.map { $0.id })
                    let uniqueItems = newItems.filter { !existingIDs.contains($0.id) && $0.isReleased }
                    items.append(contentsOf: uniqueItems)
                    skipCount += 20 // Standard Cinemeta skip
                }
                isLoading = false
            }
        } catch {
            print("Error loading list: \(error)")
            await MainActor.run { isLoading = false }
        }
    }
}
