import Foundation

/// A user-created custom list ("Collection") — e.g. "Space Movies", "Watch
/// With Mom". Items are stored as MediaItem dicts (same shape as watchlist/
/// history entries) so grids render offline with full artwork.
struct UserCollection: Identifiable, Hashable {
    let id: String
    var name: String
    var createdAt: Date
    var items: [MediaItem]

    /// Poster stack preview (first three members, newest first).
    var previewPosters: [URL?] {
        items.prefix(3).map { $0.posterURL ?? $0.imageURL ?? $0.backdropURL }
    }

    static func newID() -> String { UUID().uuidString }
}
