import Network
import Foundation
import Combine
import SwiftUI

/// Stream Route Proxy Manager: Stock Addon & Middleware service for routing
/// throttled HTTP scraper hosts (e.g. 2peckle, Febbox, shegu) through a dedicated high-speed
/// forward proxy (e.g. Tailscale / Tinyproxy) while strictly bypassing local traffic,
/// metadata queries, and P2P torrent swarms.
final class StreamRouteProxyManager: ObservableObject {
    static let shared = StreamRouteProxyManager()

    private var isReloading = false

    // MARK: - Published Configuration State

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: UserDefaults.Key.streamRouteProxyEnabled)
            if !isReloading {
                syncWithStockAddon()
                ProfileManager.shared.saveCurrentProfileSettings()
                AuthManager.shared.scheduleAutoSync()
            }
        }
    }

    @Published var endpointURL: String {
        didSet {
            UserDefaults.standard.set(endpointURL, forKey: UserDefaults.Key.streamRouteProxyEndpoint)
            if !isReloading {
                ProfileManager.shared.saveCurrentProfileSettings()
                AuthManager.shared.scheduleAutoSync()
            }
        }
    }

    @Published var targetHosts: [String] {
        didSet {
            UserDefaults.standard.set(targetHosts, forKey: UserDefaults.Key.streamRouteProxyTargetHosts)
            if !isReloading {
                ProfileManager.shared.saveCurrentProfileSettings()
                AuthManager.shared.scheduleAutoSync()
            }
        }
    }

    // Default Fallbacks
    public static let defaultEndpoint = ""
    public static let defaultTargetHosts = ["2peckle", "peckle", "febbox", "shegu", "pengu", "cinefreak", "fcdn"]

    /// Scans existing profile snapshots and settings dictionaries to recover any previously configured proxy endpoint.
    public static func recoverConfiguredEndpoint() -> String? {
        let allKeys = UserDefaults.standard.dictionaryRepresentation().keys
        var candidateEndpoints: [String] = []
        for key in allKeys {
            if key.hasPrefix("profile.") && key.hasSuffix(".settings"),
               let dict = UserDefaults.standard.dictionary(forKey: key),
               let ep = dict[UserDefaults.Key.streamRouteProxyEndpoint] as? String,
               !ep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                candidateEndpoints.append(ep.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        if let mostCommon = candidateEndpoints.reduce(into: [String: Int](), { $0[$1, default: 0] += 1 }).max(by: { $0.value < $1.value })?.key {
            return mostCommon
        }
        return nil
    }

    private init() {
        var ep = UserDefaults.standard.string(forKey: UserDefaults.Key.streamRouteProxyEndpoint) ?? Self.defaultEndpoint
        var enabled = UserDefaults.standard.bool(forKey: UserDefaults.Key.streamRouteProxyEnabled)
        if !AppEnvironment.isRunningTests, ep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let recovered = Self.recoverConfiguredEndpoint(), !recovered.isEmpty {
                ep = recovered
                UserDefaults.standard.set(ep, forKey: UserDefaults.Key.streamRouteProxyEndpoint)
                UserDefaults.standard.set(true, forKey: UserDefaults.Key.streamRouteProxyEnabled)
                enabled = true
            }
        }
        self.endpointURL = ep
        self.isEnabled = enabled
        var hosts = UserDefaults.standard.stringArray(forKey: UserDefaults.Key.streamRouteProxyTargetHosts) ?? Self.defaultTargetHosts
        var changed = false
        for h in Self.defaultTargetHosts {
            if !hosts.contains(h) {
                hosts.append(h)
                changed = true
            }
        }
        if changed {
            UserDefaults.standard.set(hosts, forKey: UserDefaults.Key.streamRouteProxyTargetHosts)
        }
        self.targetHosts = hosts
    }

    func reloadFromUserDefaults() {
        isReloading = true
        defer { isReloading = false }
        var ep = UserDefaults.standard.string(forKey: UserDefaults.Key.streamRouteProxyEndpoint) ?? Self.defaultEndpoint
        var enabled = UserDefaults.standard.bool(forKey: UserDefaults.Key.streamRouteProxyEnabled)
        if !AppEnvironment.isRunningTests, ep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let recovered = Self.recoverConfiguredEndpoint(), !recovered.isEmpty {
                ep = recovered
                UserDefaults.standard.set(ep, forKey: UserDefaults.Key.streamRouteProxyEndpoint)
                UserDefaults.standard.set(true, forKey: UserDefaults.Key.streamRouteProxyEnabled)
                enabled = true
            }
        }
        self.endpointURL = ep
        self.isEnabled = enabled
        var hosts = UserDefaults.standard.stringArray(forKey: UserDefaults.Key.streamRouteProxyTargetHosts) ?? Self.defaultTargetHosts
        var changed = false
        for h in Self.defaultTargetHosts {
            if !hosts.contains(h) {
                hosts.append(h)
                changed = true
            }
        }
        if changed {
            UserDefaults.standard.set(hosts, forKey: UserDefaults.Key.streamRouteProxyTargetHosts)
        }
        self.targetHosts = hosts
        syncWithStockAddon()
    }

    // MARK: - Stock Addon Synchronization

    private func syncWithStockAddon() {
        let stockID = "stock.stream-route-proxy"
        let apply = {
            if let idx = AddonManager.shared.addons.firstIndex(where: { $0.id == stockID }) {
                if AddonManager.shared.addons[idx].isEnabled != self.isEnabled {
                    AddonManager.shared.addons[idx].isEnabled = self.isEnabled
                    AddonManager.shared.saveAddons()
                }
            }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    // MARK: - Strict Safety & Scope Interception

    /// Determines whether a stream URL or candidate title matches the proxy scope.
    /// STRICT SAFETY REQUIREMENT: Local files, Cinemeta/TMDB metadata queries,
    /// addon manifest resolution, and P2P torrent swarms (loopback 127.0.0.1, port 11470)
    /// MUST be completely bypassed.
    func shouldProxy(url: URL?, title: String? = nil) -> Bool {
        guard isEnabled else { return false }
        guard let url = url else { return false }

        // 1. Strict Bypass: Local files and custom schemes
        if url.isFileURL || url.scheme == "file" || url.scheme == "flux" {
            return false
        }

        // 2. Strict Bypass: Torrents, loopback, and local engine ports
        let host = (url.host ?? "").lowercased()
        if host == "127.0.0.1" || host == "localhost" || host == "::1" {
            return false
        }
        if let port = url.port, port == 11470 || port == 51547 {
            return false
        }

        // 3. Strict Bypass: Critical metadata & app infrastructure
        if host.contains("themoviedb.org") || host.contains("tmdb.org") ||
            host.contains("cinemeta") ||
            host.contains("opensubtitles") ||
            host.contains("github.com") ||
            host.contains("sparkle-project.org") ||
            host.contains("pocketbase") {
            return false
        }

        // 4. Verify valid proxy endpoint configuration
        guard let (proxyHost, proxyPort) = endpointComponents(), !proxyHost.isEmpty, proxyPort > 0 else {
            return false
        }

        // 5. Target Scope Matching (Tokens match host, URL, or stream candidate title)
        let normalizedHosts = targetHosts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        guard !normalizedHosts.isEmpty else { return false }

        let urlString = url.absoluteString.lowercased()
        let cleanTitle = (title ?? "").lowercased()

        for token in normalizedHosts {
            if host.contains(token) || urlString.contains(token) || cleanTitle.contains(token) {
                return true
            }
        }

        return false
    }

    /// Convenience checker for Stream candidates directly.
    func shouldProxy(stream: Stream) -> Bool {
        guard !stream.isTorrent else { return false }
        let combinedTitle = "\(stream.title) \(stream.cleanTitle) \(stream.source)"
        return shouldProxy(url: stream.url, title: combinedTitle)
    }

    // MARK: - Endpoint Parsing & Proxy Dictionary

    /// Extracts (host, port) from endpointURL.
    func endpointComponents() -> (host: String, port: Int)? {
        let trimmed = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let host = components.host, !host.isEmpty else {
            return nil
        }
        let port = components.port ?? 8888
        return (host, port)
    }

    /// Creates CFNetwork proxy dictionary suitable for URLSessionConfiguration.connectionProxyDictionary.
    func proxyDictionary() -> [AnyHashable: Any]? {
        guard let (host, port) = endpointComponents() else { return nil }
        return [
            kCFNetworkProxiesHTTPEnable as String: 1 as NSNumber,
            kCFNetworkProxiesHTTPPort as String: port as NSNumber,
            kCFNetworkProxiesHTTPProxy as String: host as NSString,
            kCFNetworkProxiesHTTPSEnable as String: 1 as NSNumber,
            kCFNetworkProxiesHTTPSPort as String: port as NSNumber,
            kCFNetworkProxiesHTTPSProxy as String: host as NSString
        ]
    }

    /// Returns a pre-configured URLSessionConfiguration using the forward proxy.
    func urlSessionConfiguration(base: URLSessionConfiguration = .ephemeral) -> URLSessionConfiguration {
        let config = base
        if let dict = proxyDictionary() {
            config.connectionProxyDictionary = dict
        }
        return config
    }

    /// Returns the http-proxy string for MPV if the stream matches the proxy scope, else nil.
    func mpvHttpProxy(for url: URL?, title: String? = nil) -> String? {
        guard shouldProxy(url: url, title: title) else { return nil }
        let trimmed = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Connection Test Ping

    /// Probes the forward proxy endpoint to verify reachability and measure roundtrip latency.
    func testConnection(timeout: TimeInterval = 4.0) async -> Result<Double, Error> {
        guard let (host, port) = endpointComponents(), !host.isEmpty, port > 0 else {
            return .failure(NSError(domain: "StreamRouteProxy", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid proxy endpoint URL"]))
        }

        let testConfig = URLSessionConfiguration.ephemeral
        testConfig.timeoutIntervalForRequest = timeout
        testConfig.timeoutIntervalForResource = timeout
        if let dict = proxyDictionary() {
            testConfig.connectionProxyDictionary = dict
        }

        let session = URLSession(configuration: testConfig)
        guard let pingURL = URL(string: "http://captive.apple.com/hotspot-detect.html") else {
            return .failure(NSError(domain: "StreamRouteProxy", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid test target URL"]))
        }

        var request = URLRequest(url: pingURL)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let startTime = CFAbsoluteTimeGetCurrent()
        do {
            let (_, response) = try await session.data(for: request)
            let latencyMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            if let http = response as? HTTPURLResponse, (200...399).contains(http.statusCode) {
                return .success(latencyMs)
            } else {
                return .success(latencyMs)
            }
        } catch {
            // Fallback: Test direct TCP socket reachability to the proxy host:port
            do {
                let tcpLatency = try await testSocketConnection(host: host, port: port, timeout: timeout)
                return .success(tcpLatency)
            } catch {
                return .failure(error)
            }
        }
    }

    private func testSocketConnection(host: String, port: Int, timeout: TimeInterval) async throws -> Double {
        return try await withCheckedThrowingContinuation { continuation in
            let nwHost = NWEndpoint.Host(host)
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                continuation.resume(throwing: NSError(domain: "StreamRouteProxy", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid port"]))
                return
            }
            let connection = NWConnection(host: nwHost, port: nwPort, using: .tcp)
            let start = CFAbsoluteTimeGetCurrent()
            let lock = NSLock()
            var didResume = false

            let complete: (Result<Double, Error>) -> Void = { result in
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                connection.cancel()
                switch result {
                case .success(let ms):
                    continuation.resume(returning: ms)
                case .failure(let err):
                    continuation.resume(throwing: err)
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
                    complete(.success(ms))
                case .failed(let err):
                    complete(.failure(err))
                default:
                    break
                }
            }

            let queue = DispatchQueue(label: "flux.streamrouteproxy.test")
            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + timeout) {
                complete(.failure(NSError(domain: "StreamRouteProxy", code: -4, userInfo: [NSLocalizedDescriptionKey: "Connection timed out"])))
            }
        }
    }
}
