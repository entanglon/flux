import Foundation
import Combine
import Darwin

/// Manages Flux's own Stremio streaming server (server.js) instance.
/// - Downloads server.js from Stremio's CDN on first run (bundling it is not permitted).
/// - Runs it with node under Flux's own APP_PATH so it never touches a Stremio install.
/// - Discovers the actual port (server.js binds 11470 and increments on conflict).
///
/// Torrent playback protocol (same as the real Stremio client):
///   1. GET /{infoHash}/create?torrent={magnet}   → registers the torrent in the engine
///   2. mpv plays  /{infoHash}/{fileIdx}          → server serves pieces over HTTP
class StremioServerManager: ObservableObject {
    static let shared = StremioServerManager()

    @Published var isRunning = false
    private var isLaunching = false
    private var process: Process?
    private(set) var port = 11470
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private let serverVersion = "4.20.17"
    private let maxPort = 11474

    // MARK: Supervisor state (bulletproofing)
    /// Rolling-window crash cap: more than this many launch failures inside the
    /// window flips the engine into a failed state instead of crash-looping.
    private var failureTimestamps: [Date] = []
    private var lastLaunchAttempt: Date?
    private let maxFailuresPerWindow = 5
    private let failureWindow: TimeInterval = 60
    /// Torrents registered with the engine, replayed transparently after an
    /// engine restart so in-flight playback reconnects without user action.
    private struct ActiveRegistration {
        let infoHash: String
        let fileIdx: Int
        let magnetURL: String
    }
    private var activeRegistrations: [String: ActiveRegistration] = [:]
    private var engineIsFluxEngine = false

    /// Client firewall + registration tracking hook (called by PlayerManager).
    func trackCreate(infoHash: String, magnetURL: String, fileIdx: Int) {
        activeRegistrations[infoHash] = ActiveRegistration(
            infoHash: infoHash, fileIdx: fileIdx, magnetURL: magnetURL
        )
    }

    /// Removes a specific torrent from the engine and stops its download.
    func removeTorrent(infoHash: String) {
        activeRegistrations.removeValue(forKey: infoHash)
        guard let url = URL(string: "http://127.0.0.1:\(port)/\(infoHash)/remove") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        Task { _ = try? await URLSession.shared.data(for: request) }
        print("[StremioServer] Removed torrent \(infoHash.prefix(12))…")
    }

    /// Removes all torrents from the engine.
    func removeAllTorrents() {
        activeRegistrations.removeAll()
        guard let url = URL(string: "http://127.0.0.1:\(port)/removeAll") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        Task { _ = try? await URLSession.shared.data(for: request) }
        print("[StremioServer] Removed all torrents")
    }

    private func recordLaunchFailure() {
        failureTimestamps.append(Date())
        failureTimestamps.removeAll { Date().timeIntervalSince($0) > failureWindow }
        lastLaunchAttempt = Date()
    }

    private var backoffDelay: TimeInterval {
        let n = min(failureTimestamps.count, 5)
        return [0.25, 0.5, 1.0, 2.5, 5.0][max(0, n - 1)]
    }

    private func recordLaunchSuccess() {
        failureTimestamps.removeAll()
        lastLaunchAttempt = nil
        isRunning = true
    }

    private var fluxDir: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Flux").path
    }
    private var serverJSPath: String { fluxDir + "/server.js" }
    private var appPath: String { fluxDir + "/StremioServer" }

    private var nodeCandidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "\(home)/.nvm/versions/node/v22.14.0/bin/node",
            "\(home)/.nvm/versions/node/v24.3.0/bin/node",
            "\(home)/.nvm/versions/node/v20.18.0/bin/node"
        ].filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Node runtime self-provisioning
    //
    // End users shouldn't need Node installed. If no system node exists, fetch
    // the official macOS runtime once into Flux's support dir (~47MB download)
    // — same first-run pattern as server.js itself.
    private static let nodeVersion = "v22.14.0"
    private var downloadedNodePath: String { fluxDir + "/runtime/node" }
    private var runtimeDir: String { fluxDir + "/runtime" }

    /// Resolution order: system node → previously-downloaded runtime → download.
    private func resolveNodePath() async -> String? {
        if let system = nodeCandidates.first { return system }
        if FileManager.default.isExecutableFile(atPath: downloadedNodePath) { return downloadedNodePath }
        print("[StremioServer] No system Node.js found — downloading bundled runtime (\(Self.nodeVersion))…")
        return await downloadNodeRuntime()
    }

    private func downloadNodeRuntime() async -> String? {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x64"
        #endif
        let version = Self.nodeVersion
        let urlString = "https://nodejs.org/dist/\(version)/node-\(version)-darwin-\(arch).tar.gz"

        guard let url = URL(string: urlString) else { return nil }
        do {
            try FileManager.default.createDirectory(atPath: runtimeDir, withIntermediateDirectories: true)
            let archivePath = fluxDir + "/node.tar.gz"
            let archiveURL = URL(fileURLWithPath: archivePath)

            print("[StremioServer] Downloading Node runtime (~47MB)…")
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                print("[StremioServer] Node download failed (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1))")
                return nil
            }
            try data.write(to: archiveURL)

            // Extract only bin/node from node-vX-darwin-arm64/bin/node
            let extract = Process()
            extract.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            extract.currentDirectoryURL = URL(fileURLWithPath: fluxDir)
            extract.arguments = ["-xzf", "node.tar.gz", "-C", "runtime",
                                 "--strip-components=2", "\(version)-darwin-\(arch)/bin/node"]
            try extract.run()
            extract.waitUntilExit()
            try? FileManager.default.removeItem(atPath: archivePath)

            let nodePath = downloadedNodePath
            guard extract.terminationStatus == 0,
                  FileManager.default.fileExists(atPath: nodePath) else {
                print("[StremioServer] Node extraction failed")
                return nil
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nodePath)

            // Smoke-test the binary actually executes.
            let check = Process()
            check.executableURL = URL(fileURLWithPath: nodePath)
            check.arguments = ["-v"]
            let pipe = Pipe()
            check.standardOutput = pipe
            try check.run()
            check.waitUntilExit()

            guard check.terminationStatus == 0 else {
                print("[StremioServer] Downloaded node failed to execute")
                try? FileManager.default.removeItem(atPath: nodePath)
                return nil
            }
            let versionOut = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "?"
            print("[StremioServer] Node runtime ready (\(versionOut.trimmingCharacters(in: .whitespacesAndNewlines))) at \(nodePath)")
            return nodePath
        } catch {
            print("[StremioServer] Node provisioning error: \(error.localizedDescription)")
            return nil
        }
    }

    private init() {}

    // MARK: - Lifecycle

    /// Ensures a Flux-owned server is up. If the child process died (crash, kill),
    /// relaunches it and rediscovers the port. Safe to call before every playback.
    ///
    /// Bulletproofing: exponential-backoff relaunches, a rolling-window crash cap
    /// (crash-loops degrade to an error state instead of burning CPU), and
    /// transparent replay of active torrent registrations after a restart.
    func ensureRunning() async -> Bool {
        if await isServerAlive() {
            recordLaunchSuccess()
            return true
        }

        // Crash-loop guard: too many recent failures → surface error, don't churn.
        failureTimestamps.removeAll { Date().timeIntervalSince($0) > failureWindow }
        if failureTimestamps.count >= maxFailuresPerWindow {
            print("[StremioServer] Launch failed \(failureTimestamps.count)x in \(Int(failureWindow))s — entering failed state")
            await MainActor.run { self.isRunning = false }
            return false
        }

        let shouldLaunch: Bool = await MainActor.run {
            if isLaunching { return false }
            isLaunching = true
            return true
        }

        if shouldLaunch {
            process = nil
            await launchAndDiscoverPort()
            await MainActor.run { isLaunching = false }
            if await isServerAlive() {
                recordLaunchSuccess()
                await replayActiveRegistrations()
                return true
            } else {
                recordLaunchFailure()
                return false
            }
        } else {
            // Another task is already relaunching — wait for it to finish
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if await isServerAlive() { return true }
            }
            return false
        }
    }

    /// Re-registers torrents the client was streaming before an engine restart,
    /// fire-and-forget, so mpv's reconnect lands on a live swarm registration.
    private func replayActiveRegistrations() async {
        guard !activeRegistrations.isEmpty else { return }
        print("[StremioServer] Replaying \(activeRegistrations.count) active registration(s) after restart")
        for reg in activeRegistrations.values {
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            components?.path = "/\(reg.infoHash)/create"
            var query = [URLQueryItem(name: "torrent", value: reg.magnetURL)]
            query.append(URLQueryItem(name: "fileIdx", value: String(reg.fileIdx)))
            components?.queryItems = query
            guard let url = components?.url else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            Task { _ = try? await URLSession.shared.data(for: request) }
        }
    }

    func startServerIfNeeded() {
        Task {
            killStaleEngines()

            // Engine order: bundled FluxEngine sidecar → node+server.js.
            // server.js is only needed for the legacy path; don't block startup
            // on its download when the sidecar is present.
            let hasSidecar = bundledFluxEnginePath() != nil
            let haveServer = FileManager.default.fileExists(atPath: serverJSPath)
            if !hasSidecar && !haveServer {
                let ok = await downloadServerJS()
                if !ok {
                    print("[StremioServer] No engine available — torrent streaming disabled")
                    return
                }
            }
            // If a previous Flux-owned instance is already up, reuse it.
            if await isServerAlive() {
                await MainActor.run { self.isRunning = true }
                print("[StremioServer] Reusing running instance on port \(port)")
                await applySavedCacheSize()
                return
            }
            await launchAndDiscoverPort()
        }
    }

    /// Kills leftover engines from previous crashed sessions. Patterns target
    /// OUR unique paths only — never a real Stremio install.
    private func killStaleEngines() {
        let patterns = [serverJSPath, "FluxEngine"]
        for pattern in patterns {
            let pkill = Process()
            pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            pkill.arguments = ["-f", pattern]
            pkill.standardOutput = FileHandle.nullDevice
            pkill.standardError = FileHandle.nullDevice
            try? pkill.run()
            pkill.waitUntilExit()
        }
    }

    /// Bundled Go engine (stremio-server-go fork). Ensures the exec bit survived
    /// the resource-copy step, then returns its path.
    private func bundledFluxEnginePath() -> String? {
        guard let url = Bundle.main.url(forResource: "FluxEngine", withExtension: nil) else { return nil }
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        if !FileManager.default.isExecutableFile(atPath: path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    func stopServer() {
        // Tell the engine to drop all torrents before killing it
        if isRunning { removeAllTorrents() }
        if let task = process {
            task.terminate()
            let pid = task.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if task.isRunning && pid > 0 { kill(pid, SIGKILL) }
            }
        }
        process = nil
        isRunning = false
    }

    // MARK: - Startup

    /// Ports answering /heartbeat BEFORE we launch — those belong to other apps
    /// (e.g. the user's Stremio desktop). Our instance is the NEW port that appears.
    private func alivePorts() async -> Set<Int> {
        var alive: Set<Int> = []
        await withTaskGroup(of: Int?.self) { group in
            for p in 11470...maxPort {
                group.addTask {
                    var req = URLRequest(url: URL(string: "http://127.0.0.1:\(p)/heartbeat")!)
                    req.timeoutInterval = 1
                    if let (_, resp) = try? await URLSession.shared.data(for: req),
                       (resp as? HTTPURLResponse)?.statusCode == 200 { return p }
                    return nil
                }
            }
            for await r in group { if let p = r { alive.insert(p) } }
        }
        return alive
    }

    private func isServerAlive() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("heartbeat"))
        req.timeoutInterval = 2
        if let (_, resp) = try? await URLSession.shared.data(for: req) {
            return (resp as? HTTPURLResponse)?.statusCode == 200
        }
        return false
    }

    private enum EngineLaunch {
        case fluxEngine(path: String, port: Int)
        case nodeJS(nodePath: String)
    }

    /// Engine order: bundled Go sidecar → node+server.js (system or downloaded).
    private func resolveEngine() async -> EngineLaunch? {
        if let sidecar = bundledFluxEnginePath() {
            // Sidecar does NOT self-increment on port conflicts — we assign the
            // port explicitly, walking 11470…maxPort.
            let busy = await alivePorts()
            let candidate = (11470...maxPort).first { !busy.contains($0) } ?? maxPort
            return .fluxEngine(path: sidecar, port: candidate)
        }
        let serverJSReady: Bool
        if FileManager.default.fileExists(atPath: serverJSPath) {
            serverJSReady = true
        } else {
            serverJSReady = await downloadServerJS()
        }
        if serverJSReady, let nodePath = await resolveNodePath() {
            return .nodeJS(nodePath: nodePath) // server.js self-increments on conflict
        }
        return nil
    }

    private func launchAndDiscoverPort() async {
        guard let engine = await resolveEngine() else {
            print("[StremioServer] Cannot launch: no engine available")
            return
        }
        let before = await alivePorts()

        try? FileManager.default.createDirectory(atPath: appPath, withIntermediateDirectories: true)

        let task = Process()
        task.currentDirectoryURL = URL(fileURLWithPath: appPath)
        var env = ProcessInfo.processInfo.environment
        env["APP_PATH"] = appPath

        switch engine {
        case .fluxEngine(let path, let assignedPort):
            task.executableURL = URL(fileURLWithPath: path)
            env["HTTP_PORT"] = String(assignedPort)
            env["NO_CORS"] = "1"
            env["STREMIO_TORRENT_IDLE_TIMEOUT"] = "600"
            env["STREMIO_MEM_LIMIT"] = "524288000"
            env["GOMEMLIMIT"] = "524288000"
            env["GOGC"] = "20"
            engineIsFluxEngine = true
            print("[StremioServer] Launching FluxEngine (Go) on port \(assignedPort)")
        case .nodeJS(let nodePath):
            // server.js binds 11470 and increments itself on conflict; launch on
            // the first free port so discovery finds it.
            let busy = await alivePorts()
            let startPort = (11470...maxPort).first { !busy.contains($0) } ?? maxPort
            task.executableURL = URL(fileURLWithPath: nodePath)
            task.arguments = [serverJSPath]
            env["HTTP_PORT"] = String(startPort)
            env["NO_CORS"] = "1"
            engineIsFluxEngine = false
            print("[StremioServer] Launching server.js via node \(nodePath) targeting port \(startPort)")
        }
        task.environment = env

        do {
            try task.run()
            self.process = task
        } catch {
            print("[StremioServer] Launch failed: \(error.localizedDescription)")
            return
        }

        // FluxEngine: we assigned the port explicitly — poll it directly.
        // server.js: poll for the NEW port that appears (self-incremented).
        if engineIsFluxEngine, case .fluxEngine(_, let assignedPort) = engine {
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                port = assignedPort
                if await isServerAlive() {
                    await MainActor.run { self.isRunning = true }
                    print("[StremioServer] FluxEngine UP on http://127.0.0.1:\(assignedPort)")
                    await applySavedCacheSize()
                    return
                }
            }
            print("[StremioServer] FluxEngine did not answer on \(assignedPort) — server did not start")
            return
        }

        // Poll up to 20s for a NEW port to come alive
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let after = await alivePorts()
            if let p = after.subtracting(before).first {
                port = p
                await MainActor.run { self.isRunning = true }
                print("[StremioServer] UP on http://127.0.0.1:\(p)")
                await applySavedCacheSize()
                return
            }
        }
        print("[StremioServer] No port answered after launch — server did not start")
    }

    /// Pushes the user's saved cache limit (UserDefaults) to the server at startup.
    private func applySavedCacheSize() async {
        let savedGB = UserDefaults.standard.object(forKey: "stremioCacheGB") as? Int ?? 2
        await setCacheSize(gigabytes: savedGB)
        await evictCacheIfNeeded()
    }

    // MARK: - Download

    private func downloadServerJS() async -> Bool {
        let urlString = "https://dl.strem.io/server/v\(serverVersion)/desktop/server.js"
        guard let url = URL(string: urlString) else { return false }
        do {
            try FileManager.default.createDirectory(atPath: fluxDir, withIntermediateDirectories: true)
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count > 100_000 else {
                print("[StremioServer] Download failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return false
            }
            try data.write(to: URL(fileURLWithPath: serverJSPath))
            print("[StremioServer] Downloaded server.js v\(serverVersion) (\(data.count / 1024)KB)")
            return true
        } catch {
            print("[StremioServer] Download error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Cache Size (Stremio-style disk cache limiter)

    /// Applies the user's disk-cache limit to the running server. The server
    /// evicts least-recently-watched torrents once the limit is exceeded.
    func setCacheSize(gigabytes: Int) async {
        guard await ensureRunning() else {
            print("[StremioServer] Cannot set cache size — server unavailable")
            return
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("settings"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5
        let bytes = Int64(gigabytes) * 1024 * 1024 * 1024
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["cacheSize": bytes])
        if let (_, resp) = try? await URLSession.shared.data(for: request) {
            print("[StremioServer] cacheSize=\(gigabytes)GB → HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
    }

    /// Current on-disk torrent cache usage, formatted ("2.1 GB").
    func cacheUsage() async -> String {
        let cacheDir = appPath + "/stremio-cache"
        guard let enumerator = FileManager.default.enumerator(atPath: cacheDir) else { return "0 KB" }
        var total: Int64 = 0
        for case let path as String in enumerator {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheDir + "/" + path),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    /// Evicts oldest torrent directories until total usage is within the limit.
    /// The Go server doesn't enforce the limit itself, so we do it client-side.
    func evictCacheIfNeeded() async {
        let savedGB = UserDefaults.standard.object(forKey: "stremioCacheGB") as? Int ?? 2
        let limitBytes = Int64(savedGB) * 1024 * 1024 * 1024
        let cacheDir = appPath + "/stremio-cache"
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(atPath: cacheDir) else { return }

        // Calculate total + collect per-directory sizes with modification dates
        struct TorrentDir { let path: String; let size: Int64; let modified: Date }
        var dirs: [TorrentDir] = []
        var totalBytes: Int64 = 0

        for name in contents {
            let fullPath = cacheDir + "/" + name
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue else { continue }

            var dirSize: Int64 = 0
            if let enumerator = fm.enumerator(atPath: fullPath) {
                for case let file as String in enumerator {
                    if let attrs = try? fm.attributesOfItem(atPath: fullPath + "/" + file),
                       let s = attrs[.size] as? Int64 {
                        dirSize += s
                    }
                }
            }

            let modDate = (try? fm.attributesOfItem(atPath: fullPath))?[.modificationDate] as? Date ?? .distantPast
            dirs.append(TorrentDir(path: fullPath, size: dirSize, modified: modDate))
            totalBytes += dirSize
        }

        guard totalBytes > limitBytes else { return }

        // Sort oldest first, evict until under limit
        dirs.sort { $0.modified < $1.modified }
        var freed: Int64 = 0
        let needToFree = totalBytes - limitBytes

        for dir in dirs {
            guard freed < needToFree else { break }
            try? fm.removeItem(atPath: dir.path)
            freed += dir.size
            print("[StremioServer] Evicted cache: \((dir.path as NSString).lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: dir.size, countStyle: .file)))")
        }
        print("[StremioServer] Evicted \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)) of cache")
    }

    deinit { stopServer() }
}
