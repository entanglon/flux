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
            // Hotfix: Remove dead nuviostreams/webstreamr instances from active storage
            self.addons = decoded.filter { !$0.url.contains("hayd.uk") }
        }
        
        // Always ensure Cinemeta is present
        ensureCinemeta()
    }
    
    private func ensureCinemeta() {
        let cinemetaID = "official.cinemeta"
        if !addons.contains(where: { $0.id == cinemetaID }) {
            // Pre-seed Cinemeta
            let cinemeta = StremioAddon(
                id: cinemetaID,
                name: "Cinemeta",
                description: "Stremio's default movie and series catalog",
                version: "3.0.0",
                url: "https://v3-cinemeta.strem.io",
                transportUrl: "https://v3-cinemeta.strem.io",
                isEnabled: true,
                catalogs: [
                    StremioCatalog(type: "movie", id: "top", name: "Popular"),
                    StremioCatalog(type: "series", id: "top", name: "Popular")
                ],
                resources: ["catalog", "meta"]
            )
            addons.append(cinemeta)
            saveAddons()
        }
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
            let piAddon = StremioAddon(
                id: "local.raspberry.webstreamer",
                name: "Raspberry Pi WebStreamer",
                description: "Local stream bridge",
                version: "1.0.0",
                url: piUrl,
                transportUrl: piUrl,
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
