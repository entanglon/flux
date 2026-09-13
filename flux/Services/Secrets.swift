import Foundation

struct Secrets {
    // Intentionally empty — Flux is Cinemeta-first and ships with NO bundled TMDB
    // key (embedding one would share it across every install and breach TMDB ToS).
    // Users may add their own free key in Settings → Metadata.
    static let tmdbAPIKey = ""
}

