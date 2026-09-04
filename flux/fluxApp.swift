import SwiftUI
#if os(macOS)
import AppKit
import Darwin

/// Held for the process lifetime — a second instance fails to lock and exits.
private var instanceLockFD: Int32 = -1
private func acquireSingleInstanceLock() -> Bool {
    let folderName = (Bundle.main.bundleIdentifier == "com.kernelmoth.flux") ? "Flux-Debug" : "Flux"
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent(folderName)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent(".instance.lock").path
    let fd = open(path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return true }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        close(fd)
        return false
    }
    instanceLockFD = fd
    return true
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // App lifecycle configuration
    }
    func applicationWillTerminate(_ notification: Notification) {
        UserDefaults.standard.synchronize()
        AuthManager.shared.syncNow()
        StremioServerManager.shared.stopServer()
        StreamProxyManager.shared.stop()
    }
}
#endif

@main
struct fluxApp: App {
    @StateObject private var playerManager = PlayerManager.shared
    @StateObject private var authManager = AuthManager.shared
    @StateObject private var profileManager = ProfileManager.shared
    @StateObject private var updateManager = UpdateManager.shared
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil ||
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
        ProcessInfo.processInfo.environment["XCInjectBundleInto"] != nil
    }

    init() {
        #if os(macOS)
        if !Self.isRunningTests {
            guard acquireSingleInstanceLock() else {
                print("[flux] Another instance is already running — exiting")
                exit(0)
            }
        }
        NSWindow.allowsAutomaticWindowTabbing = false
        #endif

        if !Self.isRunningTests {
            StremioServerManager.shared.startServerIfNeeded()
            StreamProxyManager.shared.start()
            AuthManager.shared.syncOnLaunch()
            Task(priority: .background) {
                await SearchEngine.shared.indexUserAndTrendingData()
            }
        }
    }
    
    var body: some Scene {
        WindowGroup {
            Group {
                if authManager.needsGate {
                    AuthGateView()
                        .environmentObject(authManager)
                } else if profileManager.currentProfile != nil {
                    ContentView()
                        .environmentObject(playerManager)
                        .environmentObject(authManager)
                } else {
                    ProfileGateView()
                }
            }
            .preferredColorScheme(.dark)
            .containerBackground(.clear, for: .window)
            .onOpenURL { url in
                AddonManager.shared.handleIncomingURL(url)
            }
        }
        .commands {
            SidebarCommands()
            ToolbarCommands()
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updateManager.checkForUpdates()
                }
                .disabled(!updateManager.canCheckForUpdates)
            }
            CommandGroup(after: .newItem) {
                Button("Refresh") {
                    Task {
                        await TMDBCatalogCacheActor.shared.clear()
                        await AuthManager.shared.syncNowAsync(forcePull: true)
                        await MainActor.run {
                            NotificationCenter.default.post(name: .fluxRefresh, object: nil)
                        }
                    }
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                Button("Home") {
                    NotificationCenter.default.post(name: .fluxNavigate, object: SidebarItem.home)
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Movies") {
                    NotificationCenter.default.post(name: .fluxNavigate, object: SidebarItem.movies)
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("TV Shows") {
                    NotificationCenter.default.post(name: .fluxNavigate, object: SidebarItem.tvShows)
                }
                .keyboardShortcut("3", modifiers: .command)

                Button("Trending") {
                    NotificationCenter.default.post(name: .fluxNavigate, object: SidebarItem.trending)
                }
                .keyboardShortcut("4", modifiers: .command)

                Button("Search") {
                    NotificationCenter.default.post(name: .fluxNavigate, object: SidebarItem.search)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
        .defaultSize(width: 1200, height: 800)
        .windowToolbarStyle(.unified(showsTitle: false))
        
        // Player Window
        WindowGroup(id: "player", for: MediaItem.ID.self) { $itemId in
            if let item = PlayerManager.shared.currentItem {
                PlayerView(item: item)
                    .environmentObject(playerManager)
            } else {
                Text("No Media Selected")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commandsRemoved()
        .defaultSize(width: 1280, height: 720)
        
        Settings {
            SettingsView()
        }
    }
}
