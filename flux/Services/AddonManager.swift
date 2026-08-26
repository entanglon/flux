import Foundation
import Combine

struct StremioCatalog: Codable, Hashable {
    var type: String
    var id: String
    var name: String?
}

struct StremioAddon: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var description: String?
    var version: String?
    var url: String
    var transportUrl: String
    var isEnabled: Bool
    var catalogs: [StremioCatalog]?
    var resources: [String]?
}

struct AddonManifest: Codable {
    var id: String
    var name: String
    var description: String?
    var version: String?
    var catalogs: [StremioCatalog]?
    var resources: [String]?
}

class AddonManager: ObservableObject {
    static let shared = AddonManager()
    
    @Published var addons: [StremioAddon] = []
    private let storageKey = "StremioConfiguredAddons"
    
    private init() {
        loadAddons()
        
        // Bootstrap defaults if perfectly empty, for backward compatibility or better user experience.
        if addons.isEmpty {
            bootstrapDefaultAddons()
        }
        
        Task {
            await syncAddonManifests()
        }
    }
    
    // Background sync to heal older addons that have missing catalogs
    private func syncAddonManifests() async {
        for addon in addons {
            if addon.catalogs == nil || addon.catalogs!.isEmpty {
                if addon.id == "local.raspberry.webstreamer" { continue } // Skip local mock
                // Try to resync
                do {
                    try await addAddon(url: addon.url)
                } catch {
                    print("Failed to sync addon: \(addon.name)")
                }
            }
        }
    }
    
    var enabledAddons: [StremioAddon] {
        return addons.filter { $0.isEnabled }
    }
    
    private func loadAddons() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([StremioAddon].self, from: data) {
            self.addons = decoded
        }
        
        // Always ensure default addons are present
        ensureDefaultAddons()
    }
    
    private func ensureDefaultAddons() {
        // Purge Hydra and dead addons from previous sessions
        addons.removeAll { $0.id == "hydra.local.server" || $0.url.contains("127.0.0.1:51546") || $0.url.contains("hayd.uk") }

        // Cinemeta is no longer a user-facing addon: the built-in Flux Home
        // Catalogue + search hit it directly (StremioService.cinemetaURL), so a
        // seeded copy only produced duplicate "Popular" rails on Home. Remove any
        // copy persisted by older builds.
        addons.removeAll { $0.id == "official.cinemeta" || $0.url.contains("cinemeta.strem.io") }

        // Torrentio — torrent streams (the gold standard)
        let torrentioID = "com.stremio.torrentio"
        if !addons.contains(where: { $0.id == torrentioID || $0.url.contains("torrentio.strem.fun") }) {
            let torrentio = StremioAddon(
                id: torrentioID,
                name: "Torrentio",
                description: "Torrent streams from multiple trackers",
                version: "0.0.15",
                url: "https://torrentio.strem.fun",
                transportUrl: "https://torrentio.strem.fun",
                isEnabled: true,
                catalogs: nil,
                resources: ["stream"]
            )
            addons.append(torrentio)
        }
        
        // Comet — fast torrent/debrid backup
        let cometID = "com.stremio.comet"
        if !addons.contains(where: { $0.id == cometID || $0.url.contains("comet.elfhosted.com") }) {
            let comet = StremioAddon(
                id: cometID,
                name: "Comet",
                description: "Fast torrent streams backup",
                version: "2.0.0",
                url: "https://comet.elfhosted.com",
                transportUrl: "https://comet.elfhosted.com",
                isEnabled: true,
                catalogs: nil,
                resources: ["stream"]
            )
            addons.append(comet)
        }
        
        // WebStreamrMBG — free HTTP streams from streaming sites (verified working)
        let webstreamerID = "community.stremio.webstreamrmbg"
        if !addons.contains(where: { $0.id == webstreamerID || $0.url.contains("webstreamr") }) {
            let webstreamer = StremioAddon(
                id: webstreamerID,
                name: "WebStreamr",
                description: "Free HTTP streams from streaming sites",
                version: "1.0.0",
                url: "https://87d6a6ef6b58-webstreamrmbg.baby-beamup.club",
                transportUrl: "https://87d6a6ef6b58-webstreamrmbg.baby-beamup.club",
                isEnabled: true,
                catalogs: nil,
                resources: ["stream"]
            )
            addons.append(webstreamer)
        }

        // Meteor — franchise-aware torrent matching (verified working)
        let meteorID = "community.meteor"
        if !addons.contains(where: { $0.id == meteorID || $0.url.contains("meteor") }) {
            let meteor = StremioAddon(
                id: meteorID,
                name: "Meteor",
                description: "Franchise-aware torrent streams",
                version: "1.0.0",
                url: "https://meteorfortheweebs.midnightignite.me",
                transportUrl: "https://meteorfortheweebs.midnightignite.me",
                isEnabled: true,
                catalogs: nil,
                resources: ["stream"]
            )
            addons.append(meteor)
        }

        // Stremify — HTTP streams for popular movies (streams need referer header
        // from behaviorHints — Flux's StreamProxyManager injects it automatically)
        let stremifyID = "stremify.elfhosted.com"
        if !addons.contains(where: { $0.id == stremifyID || $0.url.contains("stremify") }) {
            let stremify = StremioAddon(
                id: stremifyID,
                name: "Stremify",
                description: "HTTP streams for popular content",
                version: "1.0.0",
                url: "https://stremify.elfhosted.com",
                transportUrl: "https://stremify.elfhosted.com",
                isEnabled: true,
                catalogs: nil,
                resources: ["stream"]
            )
            addons.append(stremify)
        }

        // OpenSubtitles v3 — online subtitle search (powers the player's subtitle picker)
        // Migration: older builds shipped the dead "v3-opensubtitles" host — replace it.
        let openSubtitlesID = "opensubtitles3"
        let openSubtitlesHost = "https://opensubtitles-v3.strem.io"
        if let staleIdx = addons.firstIndex(where: { $0.url.contains("v3-opensubtitles") }) {
            addons[staleIdx].url = openSubtitlesHost
            addons[staleIdx].transportUrl = openSubtitlesHost
        }
        if !addons.contains(where: { $0.id == openSubtitlesID || $0.url.contains("opensubtitles") }) {
            let openSubs = StremioAddon(
                id: openSubtitlesID,
                name: "OpenSubtitles",
                description: "Online subtitle search",
                version: "1.0.0",
                url: openSubtitlesHost,
                transportUrl: openSubtitlesHost,
                isEnabled: true,
                catalogs: nil,
                resources: ["subtitles"]
            )
            addons.append(openSubs)
        }

        saveAddons()
    }
    
    private func saveAddons() {
        if let encoded = try? JSONEncoder().encode(addons) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }
    
    private func bootstrapDefaultAddons() {
        self.addons = []
        
        let piUrl = Secrets.raspberryPiStremioAddonUrl
        if !piUrl.isEmpty {
            let mbgUrl = piUrl.replacingOccurrences(of: "webstreamer", with: "webstreamermbg")
            let piAddon = StremioAddon(
                id: "local.raspberry.webstreamermbg",
                name: "Raspberry Pi WebStreamerMBG",
                description: "Local stream bridge (MBG)",
                version: "1.0.0",
                url: mbgUrl,
                transportUrl: mbgUrl,
                isEnabled: true,
                catalogs: nil,
                resources: ["stream"]
            )
            self.addons.insert(piAddon, at: 0)
        }
        
        saveAddons()
    }
    
    func addAddon(url: String) async throws {
        var manifestUrlStr = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manifestUrlStr.hasSuffix("/manifest.json") {
            if manifestUrlStr.hasSuffix("/") {
                manifestUrlStr.removeLast()
            }
            manifestUrlStr += "/manifest.json"
        }
        
        if manifestUrlStr.hasPrefix("stremio://") {
            manifestUrlStr = manifestUrlStr.replacingOccurrences(of: "stremio://", with: "https://")
        }
        
        guard let manifestURL = URL(string: manifestUrlStr) else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: manifestURL)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        let manifest = try JSONDecoder().decode(AddonManifest.self, from: data)
        let baseURLStr = manifestUrlStr.replacingOccurrences(of: "/manifest.json", with: "")
        
        let newAddon = StremioAddon(
            id: manifest.id,
            name: manifest.name,
            description: manifest.description,
            version: manifest.version,
            url: baseURLStr,
            transportUrl: baseURLStr,
            isEnabled: true,
            catalogs: manifest.catalogs,
            resources: manifest.resources
        )
        
        await MainActor.run {
            self.addons.removeAll { $0.id == newAddon.id || $0.url == newAddon.url }
            self.addons.append(newAddon)
            self.saveAddons()
        }
    }
    
    func removeAddon(_ addon: StremioAddon) {
        addons.removeAll { $0.id == addon.id }
        saveAddons()
    }
    
    func toggleAddon(_ addon: StremioAddon) {
        if let index = addons.firstIndex(where: { $0.id == addon.id }) {
            addons[index].isEnabled.toggle()
            saveAddons()
        }
    }
}
