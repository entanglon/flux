import Foundation
import Combine
import Darwin

class HydraServerManager: ObservableObject {
    static let shared = HydraServerManager()

    @Published var isRunning = false
    private var process: Process?
    private let port = 51546
    private var readyURL: URL { URL(string: "http://127.0.0.1:\(port)/ready")! }

    /// Bundled server inside the app (created by scripts/bundle_hydra.sh)
    private var bundledServerDir: String? {
        Bundle.main.resourceURL?.appendingPathComponent("hydra-server").path
    }
    /// Dev checkout fallback while the bundle hasn't been created yet.
    /// Locates the vendored `hydra/` source relative to THIS source file
    /// (.../flux/flux/Services/HydraServerManager.swift), so it works from any
    /// clone location without hardcoded absolute paths.
    private var devServerDir: String? {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            dir.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("hydra/package.json").path) {
                return dir.appendingPathComponent("hydra").path
            }
        }
        return nil
    }
    /// Node binary candidates for running the compiled server (bundled node first)
    private var nodeCandidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "\(home)/.nvm/versions/node/v24.3.0/bin/node"
        ].filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private init() {}

    func startServerIfNeeded() {
        Task {
            if await isServerAlive() {
                print("[HydraServerManager] Hydra server is already active on http://127.0.0.1:\(port)")
                await MainActor.run { self.isRunning = true }
                return
            }

            startBackgroundProcess()
        }
    }

    private func isServerAlive() async -> Bool {
        var request = URLRequest(url: readyURL)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                return true
            }
        } catch {}
        return false
    }

    private func startBackgroundProcess() {
        // Mode 1: bundled server (dist/index.js) — preferred
        if let dir = bundledServerDir,
           FileManager.default.fileExists(atPath: dir + "/dist/index.js") {
            launchCompiledServer(dir: dir)
            return
        }

        // Mode 2: dev checkout run via tsx
        if let dir = devServerDir {
            launchDevServer(dir: dir)
            return
        }

        print("[HydraServerManager] No hydra server found (bundle missing and no dev checkout). Torrent streaming unavailable.")
    }

    private func waitForReady() {
        Task {
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if await self.isServerAlive() {
                    print("[HydraServerManager] Hydra server is UP and ready!")
                    await MainActor.run { self.isRunning = true }
                    break
                }
            }
        }
    }

    private func launchCompiledServer(dir: String) {
        // Prefer the node runtime bundled inside hydra-server, fall back to system installs
        let bundledNode = dir + "/node"
        let nodePath = FileManager.default.fileExists(atPath: bundledNode)
            ? bundledNode
            : (nodeCandidates.first ?? "node")

        // Launch node DIRECTLY (no shell wrapper): a zsh -c wrapper either exits
        // immediately (backgrounded) or makes terminate() unreliable. Running the
        // binary itself means stopServer() always owns the real node PID.
        var args = ["dist/index.js"]
        if FileManager.default.fileExists(atPath: dir + "/.env") {
            args.insert("--env-file=.env", at: 0)
        }
        launchNode(nodePath, args: args, workingDir: dir)
    }

    private func launchDevServer(dir: String) {
        let nodePath = nodeCandidates.first ?? "node"
        // Mirrors hydra's `npm run dev`: node --env-file=.env --import tsx src/index.ts
        var args = ["--import", "tsx", "src/index.ts"]
        if FileManager.default.fileExists(atPath: dir + "/.env") {
            args.insert("--env-file=.env", at: 0)
        }
        launchNode(nodePath, args: args, workingDir: dir)
    }

    /// Runs node in-place so `process` references the actual node process and
    /// terminate() reliably stops it (no orphaned servers eating RAM/CPU).
    private func launchNode(_ nodePath: String, args: [String], workingDir: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: nodePath)
        task.arguments = args
        task.currentDirectoryURL = URL(fileURLWithPath: workingDir)

        var env = ProcessInfo.processInfo.environment
        env["PORT"] = String(port)
        task.environment = env

        do {
            try task.run()
            self.process = task
            print("[HydraServerManager] Launched hydra server: \(nodePath) \(args.joined(separator: " ")) in \(workingDir)")
            waitForReady()
        } catch {
            print("[HydraServerManager] Failed to launch hydra (\(nodePath)): \(error.localizedDescription)")
        }
    }

    func stopServer() {
        if let task = process {
            task.terminate()
            // Safety valve: SIGKILL if node hasn't exited after a grace period
            let pid = task.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if task.isRunning && pid > 0 {
                    kill(pid, SIGKILL)
                }
            }
        }
        process = nil
        isRunning = false
    }

    deinit {
        stopServer()
    }
}
