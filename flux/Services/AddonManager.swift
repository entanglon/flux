import Foundation
import Combine
import SwiftUI

class AddonManager: ObservableObject {
    static let shared = AddonManager()
    
    @Published var addons: [StremioAddon] = []
    
    // Deep Link State for External Addon Installation
    @Published var pendingDeepLinkManifest: AddonManifest?
    @Published var pendingDeepLinkURL: String?
    @Published var showDeepLinkModal: Bool = false
    @Published var isInstallingDeepLink: Bool = false
    @Published var deepLinkError: String?
    
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
        if id == "opensubtitles3" || id == "org.stremio.opensubtitlesv3" {
            return addons.contains(where: { $0.id == "opensubtitles3" || $0.id == "org.stremio.opensubtitlesv3" || $0.url.contains("opensubtitles") })
        }
        return addons.contains(where: { $0.id == id })
    }
    
    func installedAddon(for id: String) -> StremioAddon? {
        if id == "opensubtitles3" || id == "org.stremio.opensubtitlesv3" {
            return addons.first(where: { $0.id == "opensubtitles3" || $0.id == "org.stremio.opensubtitlesv3" || $0.url.contains("opensubtitles") })
        }
        return addons.first(where: { $0.id == id })
    }
    
    // MARK: - Open Web Store with SSO Auto-Login
    
    func openWebStore() {
        let base = "https://flux-addons.pages.dev"
        if let token = KeychainStore.get("flux.authToken"), !token.isEmpty {
            if let encodedToken = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let url = URL(string: "\(base)/?token=\(encodedToken)") {
                NSWorkspace.shared.open(url)
                return
            }
        }
        if let url = URL(string: base) {
            NSWorkspace.shared.open(url)
        }
    }
    
    // MARK: - Cloud Synchronization
    
    func exportAddonsPayload() -> [[String: Any]] {
        return addons.map { addon in
            var dict: [String: Any] = [
                "id": addon.id,
                "name": addon.name,
                "url": addon.url,
                "isEnabled": addon.isEnabled,
                "isStock": addon.isStock
            ]
            if let ver = addon.version { dict["version"] = ver }
            if let desc = addon.description { dict["description"] = desc }
            if let logo = addon.logoURL { dict["logoURL"] = logo }
            if let icon = addon.iconURL { dict["iconURL"] = icon }
            if let cat = addon.category { dict["category"] = cat }
            return dict
        }
    }
    
    func syncWithCloudAddons(_ remoteList: [[String: Any]]) {
        var map: [String: StremioAddon] = [:]
        for addon in addons {
            map[addon.id] = addon
        }
        
        for dict in remoteList {
            guard let id = dict["id"] as? String,
                  let name = dict["name"] as? String,
                  let url = dict["url"] as? String else { continue }
            let isEnabled = dict["isEnabled"] as? Bool ?? true
            let isStock = dict["isStock"] as? Bool ?? false
            let version = dict["version"] as? String
            let description = dict["description"] as? String
            let logoURL = dict["logoURL"] as? String
            let iconURL = dict["iconURL"] as? String
            let category = dict["category"] as? String
            
            if let local = map[id] {
                var updated = local
                updated.isEnabled = isEnabled
                map[id] = updated
            } else {
                let newAddon = StremioAddon(
                    id: id,
                    name: name,
                    description: description,
                    version: version,
                    logoURL: logoURL,
                    iconURL: iconURL,
                    url: url,
                    transportUrl: url,
                    isEnabled: isEnabled,
                    isStock: isStock,
                    category: category
                )
                map[id] = newAddon
            }
        }
        
        // Ensure stock addons are never removed
        self.addons = Array(map.values)
        ensureDefaultAddons()
        sortAddonsDeterministically()
    }
    
    // MARK: - Local Persistence
    
    private func loadAddons() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([StremioAddon].self, from: data) {
            self.addons = decoded
        }
        
        // Always ensure essential default/stock addons are present
        ensureDefaultAddons()
        sortAddonsDeterministically()
    }
    
    private func ensureDefaultAddons() {
        // OpenSubtitles v3 — stock non-deletable subtitle search addon
        let openSubtitlesID = "opensubtitles3"
        let openSubtitlesHost = "https://opensubtitles-v3.strem.io"
        
        if let existingIdx = addons.firstIndex(where: { $0.id == openSubtitlesID || $0.url.contains("opensubtitles") }) {
            addons[existingIdx].id = openSubtitlesID
            addons[existingIdx].isStock = true
            addons[existingIdx].url = openSubtitlesHost
            addons[existingIdx].transportUrl = openSubtitlesHost
            addons[existingIdx].logoURL = "https://www.strem.io/images/addons/opensubtitles-logo.png"
        } else {
            let openSubs = StremioAddon(
                id: openSubtitlesID,
                name: "OpenSubtitles v3",
                description: "Official multi-language subtitle search",
                version: "1.0.0",
                logoURL: "https://www.strem.io/images/addons/opensubtitles-logo.png",
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

        sortAddonsDeterministically()
        saveAddons()
    }
    
    private func sortAddonsDeterministically() {
        addons.sort { (a, b) -> Bool in
            if a.isStock != b.isStock {
                return a.isStock && !b.isStock
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
    
    private func saveAddons() {
        if let encoded = try? JSONEncoder().encode(addons) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
        AuthManager.shared.scheduleAutoSync()
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
        
        guard let manifestURL = URL(string: manifestUrlStr) ?? URL(string: manifestUrlStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else {
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
        
        let isProtected = isStock || manifest.id == "opensubtitles3" || manifest.id == "org.stremio.opensubtitlesv3" || baseURLStr.contains("opensubtitles")
        let canonicalID = (manifest.id == "org.stremio.opensubtitlesv3") ? "opensubtitles3" : manifest.id
        let resolvedLogo = manifest.logo ?? manifest.icon ?? fallbackLogoURL
        let newAddon = StremioAddon(
            id: canonicalID,
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
            resources: manifest.resourceNames
        )
        
        await MainActor.run {
            self.addons.removeAll { $0.id == newAddon.id || $0.url == newAddon.url }
            self.addons.append(newAddon)
            self.sortAddonsDeterministically()
            self.saveAddons()
        }
    }
    
    func removeAddon(_ addon: StremioAddon) {
        guard !addon.isStock else { return } // Protected
        addons.removeAll { $0.id == addon.id }
        sortAddonsDeterministically()
        saveAddons()
    }
    
    func toggleAddon(_ addon: StremioAddon) {
        if let idx = addons.firstIndex(where: { $0.id == addon.id }) {
            addons[idx].isEnabled.toggle()
            saveAddons()
        }
    }
    
    // MARK: - Deep Link URL Interception & Verification
    
    func handleIncomingURL(_ url: URL) {
        var rawString = url.absoluteString
        
        if url.scheme == "flux" && url.host == "install-addon" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let queryItem = components.queryItems?.first(where: { $0.name == "url" }),
               let manifestParam = queryItem.value {
                rawString = manifestParam
            }
        }
        
        if rawString.hasPrefix("stremio://") {
            rawString = rawString.replacingOccurrences(of: "stremio://", with: "https://")
        }
        
        if !rawString.hasSuffix("/manifest.json") {
            if rawString.hasSuffix("/") {
                rawString.removeLast()
            }
            rawString += "/manifest.json"
        }
        
        guard let finalURL = URL(string: rawString) ?? URL(string: rawString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else { return }
        
        Task {
            await fetchManifestForDeepLink(url: finalURL)
        }
    }
    
    private func fetchManifestForDeepLink(url: URL) async {
        await MainActor.run {
            self.deepLinkError = nil
            self.pendingDeepLinkURL = url.absoluteString
            self.isInstallingDeepLink = false
        }
        
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let manifest = try JSONDecoder().decode(AddonManifest.self, from: data)
            
            await MainActor.run {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    self.pendingDeepLinkManifest = manifest
                    self.showDeepLinkModal = true
                }
            }
        } catch {
            await MainActor.run {
                self.deepLinkError = "Could not load addon manifest from \(url.host ?? "server")"
                self.showDeepLinkModal = true
            }
        }
    }
    
    func confirmDeepLinkInstallation() async {
        guard let manifest = pendingDeepLinkManifest, let urlStr = pendingDeepLinkURL else { return }
        await MainActor.run { self.isInstallingDeepLink = true }
        
        do {
            try await addAddon(url: urlStr, isStock: false, category: AddonCategory.community.rawValue)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) {
                    self.showDeepLinkModal = false
                    self.pendingDeepLinkManifest = nil
                    self.pendingDeepLinkURL = nil
                    self.isInstallingDeepLink = false
                }
            }
        } catch {
            await MainActor.run {
                self.deepLinkError = "Installation failed: \(error.localizedDescription)"
                self.isInstallingDeepLink = false
            }
        }
    }
    
    func dismissDeepLinkModal() {
        withAnimation(.easeOut(duration: 0.2)) {
            self.showDeepLinkModal = false
            self.pendingDeepLinkManifest = nil
            self.pendingDeepLinkURL = nil
            self.deepLinkError = nil
            self.isInstallingDeepLink = false
        }
    }
}
