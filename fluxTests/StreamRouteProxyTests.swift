import Testing
import Foundation
@testable import flux

@Suite(.serialized)
struct StreamRouteProxyTests {

    @Test @MainActor func strictSafetyExclusionsBypassTorrentsAndMetadata() {
        let manager = StreamRouteProxyManager.shared
        defer {
            manager.endpointURL = ""
            manager.isEnabled = false
            UserDefaults.standard.removeObject(forKey: UserDefaults.Key.streamRouteProxyEndpoint)
        }
        manager.isEnabled = true
        manager.endpointURL = "http://100.64.0.1:8888"
        manager.targetHosts = ["2peckle", "peckle", "febbox"]

        // 1. Loopback addresses and local ports
        #expect(!manager.shouldProxy(url: URL(string: "http://127.0.0.1:11470/stream/0")))
        #expect(!manager.shouldProxy(url: URL(string: "http://localhost:11470/stream/0")))
        #expect(!manager.shouldProxy(url: URL(string: "http://127.0.0.1:51547/proxy?url=https://2peckle.com/test")))
        #expect(!manager.shouldProxy(url: URL(string: "http://localhost:8080/test")))

        // 2. Local files and custom schemes
        #expect(!manager.shouldProxy(url: URL(fileURLWithPath: "/tmp/sample.mp4")))
        #expect(!manager.shouldProxy(url: URL(string: "file:///Users/video.mkv")))
        #expect(!manager.shouldProxy(url: URL(string: "flux://stream-route-proxy")))

        // 3. App metadata and system services
        #expect(!manager.shouldProxy(url: URL(string: "https://api.themoviedb.org/3/movie/550")))
        #expect(!manager.shouldProxy(url: URL(string: "https://v3-cinemeta.strem.io/meta/movie/tt0137523.json")))
        #expect(!manager.shouldProxy(url: URL(string: "https://opensubtitles-v3.strem.io/subtitles/movie/tt0137523.json")))
        #expect(!manager.shouldProxy(url: URL(string: "https://api.github.com/repos/entanglon/flux/releases")))

        // 4. Torrent streams are strictly bypassed even if title mentions a target keyword
        let torrentStream = Stream(
            title: "2peckle Bypassed 1080p",
            cleanTitle: "2peckle Bypassed (2024)",
            url: URL(string: "http://127.0.0.1:11470/0")!,
            source: "Torrentio",
            quality: "1080p",
            size: "2.1 GB",
            seeders: 50,
            fileIdx: 0
        )
        #expect(!manager.shouldProxy(stream: torrentStream))
    }

    @Test @MainActor func targetHostMatchingAndScoping() {
        let manager = StreamRouteProxyManager.shared
        defer {
            manager.endpointURL = ""
            manager.isEnabled = false
            manager.proxyAllHTTP = true
            UserDefaults.standard.removeObject(forKey: UserDefaults.Key.streamRouteProxyEndpoint)
        }
        manager.endpointURL = "http://100.64.0.1:8888"
        manager.proxyAllHTTP = false
        manager.targetHosts = ["2peckle", "peckle", "febbox"]

        // When disabled: no streams should be proxied
        manager.isEnabled = false
        #expect(!manager.shouldProxy(url: URL(string: "https://stream.2peckle.com/video.mp4")))

        // When enabled: matching scraper domains are proxied
        manager.isEnabled = true
        #expect(manager.shouldProxy(url: URL(string: "https://stream.2peckle.com/video.mp4")))
        #expect(manager.shouldProxy(url: URL(string: "https://cdn.febbox.com/file/123.mkv")))
        #expect(manager.shouldProxy(url: URL(string: "https://peckle-storage.net/hls/index.m3u8")))

        // Unrelated domains are not proxied
        #expect(!manager.shouldProxy(url: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")))
        #expect(!manager.shouldProxy(url: URL(string: "https://archive.org/download/sample/movie.mp4")))

        // Matching by title / indexer keyword
        let directStream = Stream(
            title: "🛰️ 2Peckle 1080p Fast",
            cleanTitle: "2Peckle 1080p Fast",
            url: URL(string: "https://custom-cdn-storage.com/file/abc")!,
            source: "2peckle",
            quality: "1080p",
            size: "1.8 GB",
            seeders: nil,
            fileIdx: nil
        )
        #expect(manager.shouldProxy(stream: directStream))
    }

    @Test @MainActor func proxyAllHTTPModeProxiesAllExternalMedia() {
        let manager = StreamRouteProxyManager.shared
        defer {
            manager.endpointURL = ""
            manager.isEnabled = false
            manager.proxyAllHTTP = true
            UserDefaults.standard.removeObject(forKey: UserDefaults.Key.streamRouteProxyEndpoint)
        }
        manager.endpointURL = "http://100.64.0.1:8888"
        manager.isEnabled = true
        manager.proxyAllHTTP = true

        // When proxyAllHTTP is enabled, all external media streams are proxied
        #expect(manager.shouldProxy(url: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")))
        #expect(manager.shouldProxy(url: URL(string: "https://archive.org/download/sample/movie.mp4")))
        #expect(manager.shouldProxy(url: URL(string: "https://stream.2peckle.com/video.mp4")))

        // Torrents and app metadata MUST still be strictly bypassed
        #expect(!manager.shouldProxy(url: URL(string: "http://127.0.0.1:11470/stream/0")))
        #expect(!manager.shouldProxy(url: URL(string: "https://api.themoviedb.org/3/movie/550")))
        #expect(!manager.shouldProxy(url: URL(string: "https://opensubtitles-v3.strem.io/subtitles/movie/tt0137523.json")))
    }

    @Test @MainActor func endpointComponentsAndProxyDictionary() {
        let manager = StreamRouteProxyManager.shared
        defer {
            manager.endpointURL = ""
            manager.isEnabled = false
            manager.proxyAllHTTP = true
            UserDefaults.standard.removeObject(forKey: UserDefaults.Key.streamRouteProxyEndpoint)
        }
        manager.endpointURL = "http://100.64.0.1:8888"
        manager.proxyAllHTTP = false
        manager.targetHosts = ["2peckle", "peckle", "febbox"]

        let components = manager.endpointComponents()
        #expect(components?.host == "100.64.0.1")
        #expect(components?.port == 8888)

        let dict = manager.proxyDictionary()
        #expect(dict != nil)
        #expect(dict?[kCFNetworkProxiesHTTPPort] as? Int == 8888)
        #expect(dict?[kCFNetworkProxiesHTTPProxy] as? String == "100.64.0.1")

        manager.isEnabled = true
        let matchingURL = URL(string: "https://stream.2peckle.com/file.mp4")!
        #expect(manager.mpvHttpProxy(for: matchingURL) == "http://100.64.0.1:8888")

        let nonMatchingURL = URL(string: "https://google.com/test.mp4")!
        #expect(manager.mpvHttpProxy(for: nonMatchingURL) == nil)
    }

    @Test @MainActor func defaultStateHasNoEndpointAndDoesNotProxy() {
        let manager = StreamRouteProxyManager.shared
        manager.endpointURL = ""
        UserDefaults.standard.removeObject(forKey: UserDefaults.Key.streamRouteProxyEndpoint)
        manager.isEnabled = true
        #expect(StreamRouteProxyManager.defaultEndpoint.isEmpty)
        #expect(manager.endpointComponents() == nil)
        #expect(manager.proxyDictionary() == nil)
        #expect(!manager.shouldProxy(url: URL(string: "https://stream.2peckle.com/file.mp4")))
        #expect(manager.mpvHttpProxy(for: URL(string: "https://stream.2peckle.com/file.mp4")) == nil)
    }

    @Test @MainActor func stockAddonRegistrationAndSynchronization() {
        let addonManager = AddonManager.shared
        let proxyAddon = addonManager.installedAddon(for: "stock.stream-route-proxy")
        #expect(proxyAddon != nil)
        #expect(proxyAddon?.isStock == true)

        let proxyManager = StreamRouteProxyManager.shared
        proxyManager.isEnabled = true
        #expect(addonManager.installedAddon(for: "stock.stream-route-proxy")?.isEnabled == true)

        proxyManager.isEnabled = false
        #expect(addonManager.installedAddon(for: "stock.stream-route-proxy")?.isEnabled == false)
    }

    @Test @MainActor func cloudSyncPreservesLocallyEnabledProxy() {
        let proxyManager = StreamRouteProxyManager.shared
        let addonManager = AddonManager.shared
        let profileManager = ProfileManager.shared

        if profileManager.currentProfile == nil {
            profileManager.ensureDefaultProfile(name: "TestUser")
        }
        guard let current = profileManager.currentProfile else { return }
        let originalProfileSettings = UserDefaults.standard.dictionary(forKey: "profile.\(current.id.uuidString).settings")
        let originalGlobalEndpoint = UserDefaults.standard.string(forKey: UserDefaults.Key.streamRouteProxyEndpoint)
        let originalGlobalEnabled = UserDefaults.standard.bool(forKey: UserDefaults.Key.streamRouteProxyEnabled)
        defer {
            if let snap = originalProfileSettings {
                UserDefaults.standard.set(snap, forKey: "profile.\(current.id.uuidString).settings")
            } else {
                UserDefaults.standard.removeObject(forKey: "profile.\(current.id.uuidString).settings")
            }
            if let ep = originalGlobalEndpoint {
                UserDefaults.standard.set(ep, forKey: UserDefaults.Key.streamRouteProxyEndpoint)
            } else {
                UserDefaults.standard.removeObject(forKey: UserDefaults.Key.streamRouteProxyEndpoint)
            }
            UserDefaults.standard.set(originalGlobalEnabled, forKey: UserDefaults.Key.streamRouteProxyEnabled)
            proxyManager.endpointURL = originalGlobalEndpoint ?? ""
            proxyManager.isEnabled = originalGlobalEnabled
        }

        proxyManager.isEnabled = true
        #expect(UserDefaults.standard.bool(forKey: UserDefaults.Key.streamRouteProxyEnabled) == true)
        let snap = UserDefaults.standard.dictionary(forKey: "profile.\(current.id.uuidString).settings")
        #expect(snap?[UserDefaults.Key.streamRouteProxyEnabled] as? Bool == true)

        let staleAddonsPayload: [[String: Any]] = [
            [
                "id": "stock.stream-route-proxy",
                "name": "Stream Route Proxy",
                "url": "flux://stream-route-proxy",
                "isEnabled": false,
                "isStock": true
            ]
        ]
        addonManager.syncWithCloudAddons(staleAddonsPayload)
        #expect(addonManager.installedAddon(for: "stock.stream-route-proxy")?.isEnabled == true)
        #expect(proxyManager.isEnabled == true)

        proxyManager.isEnabled = false
        #expect(proxyManager.isEnabled == false)
    }

    @Test func streamProxyManagerRelativeSegmentResolution() {
        let proxy = StreamProxyManager.shared
        let originalURL = URL(string: "https://example.com/hls/series/master.m3u8")!
        let proxyURL = proxy.proxyURL(for: originalURL, headers: ["User-Agent": "TestUA"], title: "Test Video")
        #expect(proxyURL != nil)
        #expect(proxyURL?.path == "/hls/series/master.m3u8")
        #expect(proxyURL?.query?.contains("url=") == true)

        let cleaned = PlayerManager.shared.cleanPlayableURLString(from: proxyURL?.absoluteString ?? "")
        #expect(cleaned == originalURL.absoluteString)
    }

    @Test @MainActor func cloudSyncRespectsLocallyDisabledProxyWhenTimestampsAreFresh() {
        let profileManager = ProfileManager.shared
        let proxyManager = StreamRouteProxyManager.shared
        if profileManager.currentProfile == nil {
            profileManager.ensureDefaultProfile(name: "TestUser")
        }
        guard let current = profileManager.currentProfile else { return }

        let originalProfileSettings = UserDefaults.standard.dictionary(forKey: "profile.\(current.id.uuidString).settings")
        let originalGlobalEndpoint = UserDefaults.standard.string(forKey: UserDefaults.Key.streamRouteProxyEndpoint)
        let originalGlobalEnabled = UserDefaults.standard.bool(forKey: UserDefaults.Key.streamRouteProxyEnabled)
        defer {
            if let snap = originalProfileSettings {
                UserDefaults.standard.set(snap, forKey: "profile.\(current.id.uuidString).settings")
            } else {
                UserDefaults.standard.removeObject(forKey: "profile.\(current.id.uuidString).settings")
            }
            if let ep = originalGlobalEndpoint {
                UserDefaults.standard.set(ep, forKey: UserDefaults.Key.streamRouteProxyEndpoint)
            } else {
                UserDefaults.standard.removeObject(forKey: UserDefaults.Key.streamRouteProxyEndpoint)
            }
            UserDefaults.standard.set(originalGlobalEnabled, forKey: UserDefaults.Key.streamRouteProxyEnabled)
            proxyManager.endpointURL = originalGlobalEndpoint ?? ""
            proxyManager.isEnabled = originalGlobalEnabled
        }

        // Local user disables proxy and saves with fresh timestamp
        UserDefaults.standard.set(false, forKey: UserDefaults.Key.streamRouteProxyEnabled)
        UserDefaults.standard.set("http://100.64.0.1:8888", forKey: UserDefaults.Key.streamRouteProxyEndpoint)
        profileManager.snapshotSettings(for: current.id)

        let localSettings = UserDefaults.standard.dictionary(forKey: "profile.\(current.id.uuidString).settings")
        let localTimestamp = localSettings?["settingsUpdatedAt"] as? Double ?? 0
        #expect(localTimestamp > 0)
        #expect(localSettings?[UserDefaults.Key.streamRouteProxyEnabled] as? Bool == false)

        // Incoming older remote payload with streamRouteProxyEnabled = true should NOT overwrite local settings
        let stalePayload: [String: Any] = [
            "settings": [
                UserDefaults.Key.streamRouteProxyEnabled: true,
                UserDefaults.Key.streamRouteProxyEndpoint: "http://100.64.0.1:8888",
                "settingsUpdatedAt": localTimestamp - 100.0
            ],
            "profiles": [
                [
                    "id": current.id.uuidString,
                    "name": current.name,
                    "settings": [
                        UserDefaults.Key.streamRouteProxyEnabled: true,
                        UserDefaults.Key.streamRouteProxyEndpoint: "http://100.64.0.1:8888",
                        "settingsUpdatedAt": localTimestamp - 100.0
                    ]
                ]
            ]
        ]

        let needsPush = UserDataService.shared.applyCloudPayload(stalePayload)
        // Stale remote should NOT override local false setting
        let afterSettings = UserDefaults.standard.dictionary(forKey: "profile.\(current.id.uuidString).settings")
        #expect(afterSettings?[UserDefaults.Key.streamRouteProxyEnabled] as? Bool == false)
        #expect(needsPush == true) // Local has additions or fresher changes to push back to cloud
    }

    @Test @MainActor func cloudSyncRespectsLocallyEnabledProxyWhenRemoteIsStaleOrDisabled() {
        let profileManager = ProfileManager.shared
        let proxyManager = StreamRouteProxyManager.shared
        if profileManager.currentProfile == nil {
            profileManager.ensureDefaultProfile(name: "TestUser")
        }
        guard let current = profileManager.currentProfile else { return }

        let originalProfileSettings = UserDefaults.standard.dictionary(forKey: "profile.\(current.id.uuidString).settings")
        let originalGlobalEndpoint = UserDefaults.standard.string(forKey: UserDefaults.Key.streamRouteProxyEndpoint)
        let originalGlobalEnabled = UserDefaults.standard.bool(forKey: UserDefaults.Key.streamRouteProxyEnabled)
        defer {
            if let snap = originalProfileSettings {
                UserDefaults.standard.set(snap, forKey: "profile.\(current.id.uuidString).settings")
            } else {
                UserDefaults.standard.removeObject(forKey: "profile.\(current.id.uuidString).settings")
            }
            if let ep = originalGlobalEndpoint {
                UserDefaults.standard.set(ep, forKey: UserDefaults.Key.streamRouteProxyEndpoint)
            } else {
                UserDefaults.standard.removeObject(forKey: UserDefaults.Key.streamRouteProxyEndpoint)
            }
            UserDefaults.standard.set(originalGlobalEnabled, forKey: UserDefaults.Key.streamRouteProxyEnabled)
            proxyManager.endpointURL = originalGlobalEndpoint ?? ""
            proxyManager.isEnabled = originalGlobalEnabled
        }

        // Local user enables proxy and configures endpoint
        UserDefaults.standard.set(true, forKey: UserDefaults.Key.streamRouteProxyEnabled)
        UserDefaults.standard.set("http://100.64.0.1:8888", forKey: UserDefaults.Key.streamRouteProxyEndpoint)
        profileManager.snapshotSettings(for: current.id)

        let localSettings = UserDefaults.standard.dictionary(forKey: "profile.\(current.id.uuidString).settings")
        let localTimestamp = localSettings?["settingsUpdatedAt"] as? Double ?? 0
        #expect(localTimestamp > 0)
        #expect(localSettings?[UserDefaults.Key.streamRouteProxyEnabled] as? Bool == true)

        // Incoming older remote payload with streamRouteProxyEnabled = false should NOT disable local proxy
        let staleDisabledPayload: [String: Any] = [
            "settings": [
                UserDefaults.Key.streamRouteProxyEnabled: false,
                UserDefaults.Key.streamRouteProxyEndpoint: "http://100.64.0.1:8888",
                "settingsUpdatedAt": localTimestamp - 100.0
            ],
            "profiles": [
                [
                    "id": current.id.uuidString,
                    "name": current.name,
                    "settings": [
                        UserDefaults.Key.streamRouteProxyEnabled: false,
                        UserDefaults.Key.streamRouteProxyEndpoint: "http://100.64.0.1:8888",
                        "settingsUpdatedAt": localTimestamp - 100.0
                    ]
                ]
            ]
        ]

        let needsPush = UserDataService.shared.applyCloudPayload(staleDisabledPayload)
        let afterSettings = UserDefaults.standard.dictionary(forKey: "profile.\(current.id.uuidString).settings")
        #expect(afterSettings?[UserDefaults.Key.streamRouteProxyEnabled] as? Bool == true)
        #expect(UserDefaults.standard.bool(forKey: UserDefaults.Key.streamRouteProxyEnabled) == true)
        #expect(needsPush == true)
    }
}
