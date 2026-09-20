import Testing
import Foundation
@testable import flux

@Suite(.serialized)
struct StreamRouteProxyTests {

    @Test func strictSafetyExclusionsBypassTorrentsAndMetadata() {
        let manager = StreamRouteProxyManager.shared
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

    @Test func targetHostMatchingAndScoping() {
        let manager = StreamRouteProxyManager.shared
        manager.endpointURL = "http://100.64.0.1:8888"
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

    @Test func endpointComponentsAndProxyDictionary() {
        let manager = StreamRouteProxyManager.shared
        manager.endpointURL = "http://100.64.0.1:8888"
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

    @Test func defaultStateHasNoEndpointAndDoesNotProxy() {
        let manager = StreamRouteProxyManager.shared
        manager.endpointURL = ""
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
}
