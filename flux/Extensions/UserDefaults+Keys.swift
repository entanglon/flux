import Foundation

/// Centralized, strongly typed registry for all UserDefaults keys used across Flux.
/// Prevents typos, duplicates, and undocumented string keys.
extension UserDefaults {
    enum Key {
        // MARK: - App & General Settings
        static let tmdbApiKey = "tmdbApiKey"
        static let cloudLastSyncAt = "cloudLastSyncAt"
        static let stremioCacheGB = "stremioCacheGB"
        static let preferredQuality = "preferredQuality"
        static let enableFluxMode = "enableFluxMode"
        static let streamingSourceMode = "streamingSourceMode"
        static let lastUsedSource = "lastUsedSource"
        static let activeTMDBID = "activeTMDBID"

        // MARK: - Player & PiP
        static let autoPlayNextEnabled = "autoPlayNextEnabled"
        static let defaultAudioLang = "defaultAudioLang"
        static let defaultSubLang = "defaultSubLang"
        static let enableAudioPassthrough = "enableAudioPassthrough"

        // MARK: - Auth Keys
        static let authGuestMode = "flux.authGuestMode"
        static let authUID = "flux.authUID"
        static let authEmail = "flux.authEmail"

        // MARK: - Legacy / Stremio Fallbacks
        static let localHistoryDataStremio = "localHistoryDataStremio"
        static let localWatchlistDataStremio = "localWatchlistDataStremio"

        // MARK: - Dynamic Scoped Keys
        static func profileSettings(id: UUID) -> String {
            "profile.\(id.uuidString).settings"
        }

        static func profileHistory(id: String) -> String {
            "profile.\(id).history"
        }

        static func profileWatchlist(id: String) -> String {
            "profile.\(id).watchlist"
        }

        static func profileCollections(id: String) -> String {
            "profile.\(id).collections"
        }

        static func profileLoved(id: String) -> String {
            "profile.\(id).loved"
        }

        static func profileWatchSnaps(id: String) -> String {
            "profile.\(id).watchSnaps"
        }
    }
}
