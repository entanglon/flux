import SwiftUI
#if os(macOS)
import AppKit
import Darwin

/// Held for the process lifetime — a second instance fails to lock and exits.
private var instanceLockFD: Int32 = -1
private func acquireSingleInstanceLock() -> Bool {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Flux")
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
}
#endif
// import FirebaseCore

@main
struct fluxApp: App {
    @StateObject private var playerManager = PlayerManager.shared
    @StateObject private var authManager = AuthManager.shared
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
        #if os(macOS)
        guard acquireSingleInstanceLock() else {
            print("[flux] Another instance is already running — exiting")
            exit(0)
        }
        NSWindow.allowsAutomaticWindowTabbing = false
        #endif

        StremioServerManager.shared.startServerIfNeeded()
        StreamProxyManager.shared.start()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(playerManager)
                .environmentObject(authManager)
                .preferredColorScheme(.dark)
                .containerBackground(.clear, for: .window)
        }
        .commands {
            SidebarCommands()
            ToolbarCommands()
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .newItem) {
                Button("Refresh") {
                    NotificationCenter.default.post(name: .fluxRefresh, object: nil)
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
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        
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
