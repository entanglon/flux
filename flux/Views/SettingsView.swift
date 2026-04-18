import SwiftUI
import FirebaseAuth

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
            StreamingSettingsView()
                .tabItem { Label("Streaming", systemImage: "antenna.radiowaves.left.and.right") }
            AddonsView()
                .tabItem { Label("Addons", systemImage: "puzzlepiece.extension") }
            TraktSettingsView()
                .tabItem { Label("Trakt", systemImage: "calendar.badge.clock") }
            PlaybackSettingsView()
                .tabItem { Label("Playback", systemImage: "play.tv") }
            AdvancedSettingsView()
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 500, height: 400)
        .padding()
        .preferredColorScheme(.dark)
    }
}

// MARK: - 1. General Settings (Account + App)
struct GeneralSettingsView: View {
    @ObservedObject var authManager = AuthManager.shared
    @AppStorage("syncEnabled") private var syncEnabled = true
    
    @AppStorage("enableRichMetadata") private var enableRichMetadata = false
    @AppStorage("enableTMDBHomePage") private var enableTMDBHomePage = false
    @AppStorage("tmdbApiKey") private var tmdbApiKey = ""
    
    var body: some View {
        Form {
            Section(header: Text("Account")) {
                if let user = authManager.currentUser {
                    HStack {
                         Text(user.email ?? "User")
                         Spacer()
                         Button("Sign Out") { authManager.signOut() }
                    }
                    Toggle("Sync Watchlist & History", isOn: $syncEnabled)
                } else {
                    Text("Not Signed In")
                }
            }
            
            Section(header: Text("Metadata Preferences")) {
                Toggle("Enable Rich Metadata (TMDB)", isOn: $enableRichMetadata)
                Text("Show cast photos and detailed metadata. Requires a personal TMDB API key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                if enableRichMetadata {
                    Toggle("Use TMDB for Home Page", isOn: $enableTMDBHomePage)
                    Text("Replaces Stremio addons catalogs on the home page with TMDB trending/popular lists.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        
                    SecureField("TMDB API Key", text: $tmdbApiKey)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 2. Streaming Settings
struct StreamingSettingsView: View {
    @AppStorage("enableFluxMode") private var enableFluxMode = true
    @AppStorage("enableWebStreamer") private var enableWebStreamer = true
    @AppStorage("enableNuvio") private var enableNuvio = true
    @AppStorage("rdApiKey") private var rdApiKey = ""
    @AppStorage("traktClientId") private var traktClientId = ""
    @AppStorage("preferredQuality") private var preferredQuality = "4K"
    
    var body: some View {
        Form {
            Section(header: Text("Flux Mode")) {
                Toggle("Enable Flux Mode", isOn: $enableFluxMode)
                Text("Automatically find and play the fastest stream.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Picker("Maximum Resolution", selection: $preferredQuality) {
                    Text("4K (2160p)").tag("4K")
                    Text("1080p").tag("1080p")
                    Text("720p").tag("720p")
                    Text("480p").tag("480p")
                }
                .pickerStyle(.menu)
            }
            
            Section(header: Text("Services")) {
                SecureField("Real-Debrid API Key", text: $rdApiKey)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Trakt Settings
struct TraktSettingsView: View {
    @StateObject private var traktManager = TraktManager.shared
    @State private var pinCode: String = ""
    @State private var isExchanging: Bool = false
    @State private var errorMsg: String?

    var body: some View {
        Form {
            Section(header: Text("Trakt Integration")) {
                if traktManager.isAuthenticated {
                    HStack {
                        Text("Connected to Trakt")
                            .foregroundColor(.green)
                        Spacer()
                        Button("Disconnect") {
                            traktManager.logout()
                        }
                        .controlSize(.small)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Connect your Trakt account to automatically scrobble what you're watching.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Button("1. Get Trakt PIN") {
                            #if os(macOS)
                            NSWorkspace.shared.open(traktManager.authorizationURL)
                            #else
                            UIApplication.shared.open(traktManager.authorizationURL)
                            #endif
                        }
                        .controlSize(.regular)
                        
                        HStack {
                            TextField("2. Paste PIN here", text: $pinCode)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .disabled(isExchanging)
                            
                            Button(isExchanging ? "Connecting..." : "Connect") {
                                guard !pinCode.isEmpty else { return }
                                isExchanging = true
                                errorMsg = nil
                                
                                traktManager.exchangeCodeForToken(code: pinCode.trimmingCharacters(in: .whitespacesAndNewlines)) { success, error in
                                    isExchanging = false
                                    if success {
                                        pinCode = ""
                                    } else {
                                        errorMsg = error?.localizedDescription ?? "Failed to connect. Make sure your PIN is correct."
                                    }
                                }
                            }
                            .disabled(pinCode.isEmpty || isExchanging)
                        }
                        
                        if let errorMsg = errorMsg {
                            Text(errorMsg)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
// MARK: - 3. Playback Settings
struct PlaybackSettingsView: View {
    @AppStorage("useHardwareAcceleration") private var useHardwareAcceleration = true
    @AppStorage("defaultAudioLang") private var defaultAudioLang = "English"
    @AppStorage("defaultSubLang") private var defaultSubLang = "English"
    
    let languages = ["English", "Spanish", "French", "German", "Japanese", "Korean", "Hindi"]
    
    var body: some View {
        Form {
            Section(header: Text("Video Player")) {
                Toggle("Hardware Acceleration", isOn: $useHardwareAcceleration)
            }
            
            Section(header: Text("Languages")) {
                Picker("Default Audio", selection: $defaultAudioLang) {
                    ForEach(languages, id: \.self) { Text($0).tag($0) }
                }
                Picker("Default Subtitles", selection: $defaultSubLang) {
                    ForEach(languages, id: \.self) { Text($0).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 4. Advanced Settings
struct AdvancedSettingsView: View {
    var body: some View {
        Form {
             Section(header: Text("Storage")) {
                Button("Clear Image Cache") {
                    ImageSession.shared.configuration.urlCache?.removeAllCachedResponses()
                    URLCache.shared.removeAllCachedResponses()
                }
            }
            
            Section(header: Text("About")) {
                Text("Version 1.0.0 (Beta)")
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AuthManager.shared)
}
