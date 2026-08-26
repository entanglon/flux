import SwiftUI

/// A streaming (OTT) platform surfaced in the Home "Explore" rail. The `id`
/// is the catalog code understood by the Streaming Catalogs addon
/// (see StremioService.fetchOTTCatalog).
struct OTTPlatform: Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String
    let colors: [Color]

    static let all: [OTTPlatform] = [
        OTTPlatform(id: "nfx", name: "Netflix", symbol: "n.square.fill",
                    colors: [Color(red: 0.85, green: 0.05, blue: 0.09), Color(red: 0.35, green: 0.02, blue: 0.04)]),
        OTTPlatform(id: "dnp", name: "Disney+", symbol: "d.square.fill",
                    colors: [Color(red: 0.05, green: 0.20, blue: 0.55), Color(red: 0.02, green: 0.07, blue: 0.25)]),
        OTTPlatform(id: "amp", name: "Prime Video", symbol: "p.square.fill",
                    colors: [Color(red: 0.00, green: 0.45, blue: 0.65), Color(red: 0.02, green: 0.13, blue: 0.25)]),
        OTTPlatform(id: "atp", name: "Apple TV+", symbol: "apple.logo",
                    colors: [Color(red: 0.25, green: 0.25, blue: 0.28), Color(red: 0.05, green: 0.05, blue: 0.06)]),
        OTTPlatform(id: "hbm", name: "HBO Max", symbol: "h.square.fill",
                    colors: [Color(red: 0.45, green: 0.20, blue: 0.75), Color(red: 0.12, green: 0.03, blue: 0.25)]),
        OTTPlatform(id: "hlu", name: "Hulu", symbol: "h.square.fill",
                    colors: [Color(red: 0.10, green: 0.65, blue: 0.45), Color(red: 0.02, green: 0.20, blue: 0.13)]),
        OTTPlatform(id: "pcp", name: "Peacock", symbol: "p.square.fill",
                    colors: [Color(red: 0.85, green: 0.65, blue: 0.10), Color(red: 0.30, green: 0.20, blue: 0.02)]),
        OTTPlatform(id: "pmp", name: "Paramount+", symbol: "p.square.fill",
                    colors: [Color(red: 0.00, green: 0.35, blue: 0.75), Color(red: 0.02, green: 0.10, blue: 0.25)]),
        OTTPlatform(id: "cru", name: "Crunchyroll", symbol: "c.square.fill",
                    colors: [Color(red: 0.90, green: 0.45, blue: 0.12), Color(red: 0.35, green: 0.13, blue: 0.02)])
    ]
}
