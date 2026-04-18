import SwiftUI
// import FirebaseCore

@main
struct fluxApp: App {
    @StateObject private var playerManager = PlayerManager.shared
    @StateObject private var authManager = AuthManager.shared
    
    init() {
        // if FirebaseApp.app() == nil {
        //     FirebaseApp.configure()
        // }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(playerManager)
                .environmentObject(authManager)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            SidebarCommands()
        }
        .defaultSize(width: 1200, height: 800)
        
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
        .commandsRemoved()
        .defaultSize(width: 1280, height: 720)
        
        Settings {
            SettingsView()
        }
    }
}
