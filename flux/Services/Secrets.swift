import Foundation

struct Secrets {
    // Intentionally empty — Flux is Cinemeta-first and ships with NO bundled TMDB
    // key (embedding one would share it across every install and breach TMDB ToS).
    // Users may add their own free key in Settings → Metadata.
    static let tmdbAPIKey = ""
    static let streamRacerUrl = "https://stream-racer.nemesys.workers.dev"
    static let traktClientId = "7ed351ececce4850d2ed6e6e6785967fd145ffc36fc5b94c440f2d298ac881e3"
    static let traktClientSecret = "37db85d303bf26e71f82bf4e9176ee4334f197a590c426fa785d6cf25233a421"
    static let raspberryPiStremioAddonUrl = ""
    static let tmdbProxyURL = "https://tmdb-proxy.nemesys.workers.dev" // Public Flux Bridge
}
