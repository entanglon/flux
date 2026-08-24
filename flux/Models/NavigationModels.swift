import Foundation

extension Notification.Name {
    /// Reload the currently visible page (Cmd+R).
    static let fluxRefresh = Notification.Name("fluxRefresh")
    /// Switch sidebar page — object is a SidebarItem (Cmd+1…4, Cmd+F).
    static let fluxNavigate = Notification.Name("fluxNavigate")
}

struct GenreNavigation: Hashable {
    let name: String
    let id: Int
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case search = "Search"
    case home = "Home"
    case movies = "Movies"
    case tvShows = "TV Shows"
    case trending = "Trending"
    case watchlist = "Watchlist"
    case history = "History"
    case downloads = "Downloads"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .search: return "magnifyingglass"
        case .home: return "house"
        case .movies: return "film"
        case .tvShows: return "tv"
        case .trending: return "flame"
        case .watchlist: return "bookmark"
        case .history: return "clock"
        case .downloads: return "arrow.down.circle"
        }
    }
}
