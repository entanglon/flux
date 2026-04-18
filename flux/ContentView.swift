import SwiftUI

struct ContentView: View {
    @State private var selectedCategory: SidebarItem? = .home
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @StateObject private var playerManager = PlayerManager.shared
    @State private var path = NavigationPath()

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: Binding(
                get: { selectedCategory },
                set: { newValue in
                    if newValue == selectedCategory {
                        // User accepted re-selection of same tab, reset stack
                        path = NavigationPath()
                    }
                    selectedCategory = newValue
                }
            )) {
                browseSection
                librarySection
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
            .safeAreaInset(edge: .bottom) {
                 UserProfileFooter()
            }
        } detail: {
            NavigationStack(path: $path) {
                ZStack {
                    // Global Background
                    LinearGradient(gradient: Gradient(colors: [Color(#colorLiteral(red: 0.1, green: 0.1, blue: 0.2, alpha: 1)), .black]), startPoint: .topLeading, endPoint: .bottomTrailing)
                        .ignoresSafeArea()
                    
                    if let selected = selectedCategory {
                        // Change content based on selection.
                        switch selected {
                        case .search:
                            SearchView()
                        case .home:
                            HomeView()
                        case .movies:
                            MoviesView()
                        case .tvShows:
                            TVShowsView()
                        case .trending:
                            TrendingView()
                        case .watchlist:
                            WatchlistView(selectedTab: Binding(get: { selectedCategory ?? .home }, set: { selectedCategory = $0 }))
                        case .history:
                            HistoryView()
                        case .downloads:
                            DownloadsView()
                        }
                    } else {
                        HomeView()
                    }
                }
                .navigationDestination(for: MediaItem.self) { item in
                    DetailView(item: item)
                }
                .navigationDestination(for: GenreNavigation.self) { genreNav in
                    MediaListView(title: genreNav.name, type: .genre(id: genreNav.id))
                }
                .navigationDestination(for: MediaListView.ListType.self) { type in
                    MediaListView(type: type)
                }
            }
        }
        .navigationTitle("Flux")
        .background(Color.black)
        .onChange(of: selectedCategory) {
            path = NavigationPath()
        }
    }

    private var browseSection: some View {
        Section("Browse") {
            NavigationLink(value: SidebarItem.search) { Label("Search", systemImage: "magnifyingglass") }
            NavigationLink(value: SidebarItem.home) { Label("Home", systemImage: "house") }
            NavigationLink(value: SidebarItem.movies) { Label("Movies", systemImage: "film") }
            NavigationLink(value: SidebarItem.tvShows) { Label("TV Shows", systemImage: "tv") }
            NavigationLink(value: SidebarItem.trending) { Label("Trending", systemImage: "flame") }
        }
    }
    
    private var librarySection: some View {
        Section("Library") {
            NavigationLink(value: SidebarItem.watchlist) { Label("Watchlist", systemImage: "bookmark") }
            NavigationLink(value: SidebarItem.history) { Label("History", systemImage: "clock") }
            NavigationLink(value: SidebarItem.downloads) { Label("Downloads", systemImage: "arrow.down.circle") }
        }
    }
}

#Preview {
    ContentView()
}

struct UserProfileFooter: View {
    @ObservedObject var authManager = AuthManager.shared
    @State private var showingAuth = false
    
    var body: some View {
        Button(action: {
            showingAuth = true
        }) {
            HStack(spacing: 12) {
                if let user = authManager.currentUser {
                    // Avatar
                    if let photoURL = user.photoURL {
                        AsyncImage(url: photoURL) { image in
                            image.resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Color.gray.opacity(0.3)
                        }
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())
                    } else {
                        Circle()
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: 32, height: 32)
                            .overlay(
                                Text(String(user.email?.prefix(1) ?? "U").uppercased())
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                            )
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.displayName ?? user.email ?? "User")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .foregroundStyle(.white)
                    }
                } else {
                    // Guest Avatar
                    Circle()
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 32, height: 32)
                        .overlay(
                            Image(systemName: "person.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.white.opacity(0.8))
                        )
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sign In")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                    }
                }
                Spacer() 
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 16) 
            .contentShape(Rectangle()) 
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingAuth) {
            if authManager.currentUser != nil {
                ProfileView()
            } else {
                AuthView()
            }
        }
    }
}
