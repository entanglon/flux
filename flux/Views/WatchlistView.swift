import SwiftUI

struct WatchlistView: View {
    @ObservedObject var userData = UserDataService.shared
    @Binding var selectedTab: SidebarItem
    
    enum Filter: String, CaseIterable {
        case all = "All"
        case movies = "Movies"
        case shows = "TV Shows"
    }
    
    @State private var activeFilter: Filter = .all
    
    private var filteredItems: [MediaItem] {
        switch activeFilter {
        case .all:
            return userData.watchlist
        case .movies:
            return userData.watchlist.filter { $0.category.lowercased().contains("movie") }
        case .shows:
            return userData.watchlist.filter { $0.category.lowercased().contains("tv") || $0.category.lowercased().contains("series") }
        }
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LibraryScheme.headerBottomSpacing) {
                LibraryPageHeader(
                    title: "Watchlist",
                    itemCount: userData.watchlist.isEmpty ? nil : userData.watchlist.count,
                    itemLabel: "ITEMS"
                ) {
                    EmptyView()
                } filterChips: {
                    if !userData.watchlist.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(Filter.allCases, id: \.self) { filter in
                                let count: Int = {
                                    switch filter {
                                    case .all: return userData.watchlist.count
                                    case .movies: return userData.watchlist.filter { $0.category.lowercased().contains("movie") }.count
                                    case .shows: return userData.watchlist.filter { $0.category.lowercased().contains("tv") || $0.category.lowercased().contains("series") }.count
                                    }
                                }()
                                
                                if count > 0 || filter == .all {
                                    Button {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                            activeFilter = filter
                                        }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Text(filter.rawValue)
                                                .font(.system(size: 13, weight: activeFilter == filter ? .bold : .medium))
                                            Text("\(count)")
                                                .font(.system(size: 11, weight: .bold))
                                                .opacity(activeFilter == filter ? 0.9 : 0.5)
                                        }
                                        .foregroundStyle(activeFilter == filter ? .white : .white.opacity(0.65))
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .background(
                                            Capsule()
                                                .fill(activeFilter == filter ? Color.white.opacity(0.18) : Color.white.opacity(0.06))
                                        )
                                        .overlay(
                                            Capsule()
                                                .stroke(activeFilter == filter ? Color.white.opacity(0.35) : Color.clear, lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                
                if userData.watchlist.isEmpty {
                    LibraryEmptyState(
                        icon: "bookmark.fill",
                        title: "Your Watchlist is Empty",
                        message: "Save movies and TV shows to keep track of what you want to watch next.",
                        actionTitle: "Find Something to Watch",
                        actionIcon: "sparkles",
                        action: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                selectedTab = .home
                            }
                        }
                    )
                } else if filteredItems.isEmpty {
                    VStack(spacing: 12) {
                        Text("No \(activeFilter.rawValue) in your Watchlist")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                        Button("Show All Titles") {
                            withAnimation { activeFilter = .all }
                        }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 24)], spacing: 40) {
                        ForEach(filteredItems) { item in
                            NavigationLink(value: item) {
                                GlassCard(item: item, aspectRatio: .portrait)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.leading, LibraryScheme.leadingPadding)
            .padding(.trailing, LibraryScheme.trailingPadding)
            .padding(.top, LibraryScheme.topPadding)
            .padding(.bottom, LibraryScheme.bottomPadding)
        }
        .background(Color.clear)
        .navigationBarBackButtonHidden(true)
        .toolbarVisibility(.hidden, for: .windowToolbar)
    }
}

#Preview {
    WatchlistView(selectedTab: .constant(.watchlist))
}
