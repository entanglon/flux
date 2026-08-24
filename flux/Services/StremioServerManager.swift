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
            "\(home)/.nvm/versions/node/v24.3.0/bin/node"
        ].filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private init() {}

    // MARK: - Lifecycle

    /// Ensures a Flux-owned server is up. If the child process died (crash, kill),
    /// relaunches it and rediscovers the port. Safe to call before every playback.
    func ensureRunning() async -> Bool {
        if await isServerAlive() { return true }

        let shouldLaunch: Bool = await MainActor.run {
            if isLaunching { return false }
            isLaunching = true
            return true
        }

        if shouldLaunch {
            process = nil
            await launchAndDiscoverPort()
            await MainActor.run { isLaunching = false }
        } else {
            // Another task is already relaunching — wait for it to finish
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if await isServerAlive() { return true }
            }
            return false
        }
        return await isServerAlive()
    }

    func startServerIfNeeded() {
        Task {
            let haveServer = FileManager.default.fileExists(atPath: serverJSPath)
            var ok = haveServer
            if !ok { ok = await downloadServerJS() }
            if !ok {
                print("[StremioServer] server.js unavailable — torrent streaming disabled")
                return
            }
            // If a previous Flux-owned instance is already up, reuse it.
            if await isServerAlive() {
                await MainActor.run { self.isRunning = true }
                print("[StremioServer] Reusing running instance on port \(port)")
                return
            }
            await launchAndDiscoverPort()
        }
    }

    func stopServer() {
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

    private func launchAndDiscoverPort() async {
        let before = await alivePorts()

        try? FileManager.default.createDirectory(atPath: appPath, withIntermediateDirectories: true)

        let nodePath = nodeCandidates.first ?? "node"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: nodePath)
        task.arguments = [serverJSPath]
        task.currentDirectoryURL = URL(fileURLWithPath: appPath)
        var env = ProcessInfo.processInfo.environment
        env["APP_PATH"] = appPath
        env["NO_CORS"] = "1"
        task.environment = env

        do {
            try task.run()
            self.process = task
            print("[StremioServer] Launched server.js (node \(nodePath)), discovering port…")
        } catch {
            print("[StremioServer] Launch failed: \(error.localizedDescription)")
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
                return
            }
        }
        print("[StremioServer] No port answered after launch — server did not start")
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

    deinit { stopServer() }
}
