import Foundation

/// Protocol abstraction for stream resolution engines.
/// Enables mock stream engines and test doubles in unit tests.
protocol StreamServiceProtocol {
    func fetchStreamsRealtime(
        for item: MediaItem,
        season: Int?,
        episode: Int?,
        onStreamsUpdated: @escaping ([Stream]) -> Void
    ) async -> [Stream]
    
    func getCachedStreams(for item: MediaItem, season: Int?, episode: Int?) -> [Stream]?
}

/// Protocol abstraction for metadata enrichment services (TMDB / Cinemeta).
protocol TMDBServiceProtocol {
    func enrich(_ item: MediaItem) async -> MediaItem
    func quickEnrich(_ item: MediaItem) async -> MediaItem
    func resolveTmdbID(imdbID: String, type: String) async -> String?
    func hasAiredNewEpisode(tmdbID: String) async -> Bool
}

/// Protocol abstraction for user library and playback history storage.
protocol UserDataProtocol {
    var watchlist: [MediaItem] { get }
    var history: [MediaItem] { get }
    var collections: [UserCollection] { get }
    
    func isInWatchlist(_ item: MediaItem) -> Bool
    func toggleWatchlist(_ item: MediaItem)
    func isWatched(_ item: MediaItem) -> Bool
    func isInHistory(_ item: MediaItem) -> Bool
    func toggleWatched(_ item: MediaItem, season: Int?, episode: Int?, episodeTitle: String?, episodeImage: URL?)
    func addToHistory(_ item: MediaItem, progress: Double?, season: Int?, episode: Int?, episodeTitle: String?, episodeImage: URL?)
    func removeFromHistory(_ item: MediaItem)
}

/// Protocol abstraction for user identity and cloud sync backends.
protocol AuthServiceProtocol {
    var isAuthenticated: Bool { get }
    var isGuestMode: Bool { get }
    var authToken: String? { get }
    
    func signIn(email: String, password: String) async -> Bool
    func signUp(email: String, password: String) async -> Bool
    func signOut()
}
