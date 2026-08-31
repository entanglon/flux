import Foundation
import Combine
import SwiftUI

class AddonManager: ObservableObject {
    static let shared = AddonManager()
    
    @Published var addons: [StremioAddon] = []
    private let storageKey = "StremioConfiguredAddons"
    
    private init() {
        loadAddons()
        
        Task {
            await syncAddonManifests()
        }
    }
    
    // Background sync to heal older addons that have missing catalogs
    private func syncAddonManifests() async {
        for addon in addons {
            if addon.catalogs == nil || addon.catalogs!.isEmpty {
                if addon.id == "local.raspberry.webstreamer" { continue }
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
    
    func isAddonInstalled(id: String) -> Bool {
        return addons.contains(where: { $0.id == id })
    }
    
    func installedAddon(for id: String) -> StremioAddon? {
        return addons.first(where: { $0.id == id })
    }
    
    private func loadAddons() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([StremioAddon].self, from: data) {
            self.addons = decoded
        }
        
        // Always ensure essential default/stock addons are present
        ensureDefaultAddons()
    }
    
    private func ensureDefaultAddons() {
        // Purge Hydra and dead addons from previous sessions
        addons.removeAll { $0.id == "hydra.local.server" || $0.url.contains("127.0.0.1:51546") || $0.url.contains("hayd.uk") }

        // Cinemeta is internal
        addons.removeAll { $0.id == "official.cinemeta" || $0.url.contains("cinemeta.strem.io") }

        // OpenSubtitles v3 — stock non-deletable subtitle search addon
        let openSubtitlesID = "opensubtitles3"
        let openSubtitlesHost = "https://opensubtitles-v3.strem.io"
        if let staleIdx = addons.firstIndex(where: { $0.url.contains("v3-opensubtitles") }) {
            addons[staleIdx].url = openSubtitlesHost
            addons[staleIdx].transportUrl = openSubtitlesHost
            addons[staleIdx].isStock = true
        }
        if let existingIdx = addons.firstIndex(where: { $0.id == openSubtitlesID || $0.url.contains("opensubtitles") }) {
            addons[existingIdx].id = openSubtitlesID
            addons[existingIdx].isStock = true
            addons[existingIdx].url = openSubtitlesHost
            addons[existingIdx].transportUrl = openSubtitlesHost
            addons[existingIdx].logoURL = "https://app.strem.io/images/addons/opensubtitles.png"
        } else {
            let openSubs = StremioAddon(
                id: openSubtitlesID,
                name: "OpenSubtitles v3",
                description: "Official multi-language subtitle search",
                version: "1.0.0",
                logoURL: "https://app.strem.io/images/addons/opensubtitles.png",
                url: openSubtitlesHost,
                transportUrl: openSubtitlesHost,
                isEnabled: true,
                isStock: true,
                category: AddonCategory.subtitles.rawValue,
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
    
    func installStoreAddon(_ item: StoreAddonItem) async throws {
        try await addAddon(url: item.manifestURL, isStock: item.isStock, category: item.category.rawValue, fallbackLogoURL: item.logoURL)
    }
    
    func addAddon(url: String, isStock: Bool = false, category: String? = nil, fallbackLogoURL: String? = nil) async throws {
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
        request.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        let manifest = try JSONDecoder().decode(AddonManifest.self, from: data)
        let baseURLStr = manifestUrlStr.replacingOccurrences(of: "/manifest.json", with: "")
        
        let isProtected = isStock || manifest.id == "opensubtitles3"
        let resolvedLogo = manifest.logo ?? manifest.icon ?? fallbackLogoURL
        let newAddon = StremioAddon(
            id: manifest.id,
            name: manifest.name,
            description: manifest.description,
            version: manifest.version,
            logoURL: resolvedLogo,
            iconURL: manifest.icon,
            url: baseURLStr,
            transportUrl: baseURLStr,
            isEnabled: true,
            isStock: isProtected,
            category: category,
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
        // Prevent deletion of protected stock addons
        guard !addon.isStock && addon.id != "opensubtitles3" else { return }
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
