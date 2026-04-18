import SwiftUI

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
                        .padding(.leading, 20)
                    
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
    @ObservedObject var traktService = TraktService.shared
    
    @State private var deviceCode: String? = nil
    @State private var verificationUrl: String? = nil
    @State private var isActivating: Bool = false
    @State private var errorMessage: String? = nil
    
    var body: some View {
        Form {
            Section(header: Text("API Credentials")) {
                Text("Trakt requires a Client ID & Secret to allow device authentication.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("Client ID", text: $traktService.clientId)
                SecureField("Client Secret", text: $traktService.clientSecret)
            }
            
            Section(header: Text("Account")) {
                if traktService.isAuthenticated {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Connected to Trakt")
                        Spacer()
                        Button("Disconnect") {
                            traktService.logout()
                        }
                    }
                    
                    HStack {
                        Button("Sync History Now") {
                            Task {
                                try? await traktService.syncHistory()
                            }
                        }
                        .disabled(traktService.isSyncing)
                        
                        if traktService.isSyncing {
                            ProgressView()
                                .scaleEffect(0.5)
                        }
                    }
                } else if isActivating, let code = deviceCode, let urlStr = verificationUrl, let url = URL(string: urlStr) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Activation Required")
                            .font(.headline)
                        Text("1. Go to \(urlStr)")
                        Text("2. Enter the code below:")
                        
                        HStack {
                            Text(code)
                                .font(.system(size: 24, weight: .bold, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Link(destination: url) {
                                Text("Open Link")
                            }
                        }
                        
                        ProgressView("Waiting for authorization...")
                            .padding(.top, 8)
                    }
                    .padding(.vertical, 8)
                } else {
                    Button("Connect to Trakt") {
                        startDeviceFlow()
                    }
                    .disabled(!traktService.canAttemptAuth)
                    if !traktService.canAttemptAuth {
                        Text("Please enter a Client ID and Secret to connect.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
    
    private func startDeviceFlow() {
        isActivating = true
        errorMessage = nil
        Task {
            do {
                let response = try await traktService.generateDeviceCode()
                await MainActor.run {
                    self.deviceCode = response.user_code
                    self.verificationUrl = response.verification_url
                }
                
                // Automatically polls
                try await traktService.pollForToken(deviceCode: response.device_code, interval: response.interval, expiresIn: response.expires_in)
                
                await MainActor.run {
                    self.isActivating = false
                    self.deviceCode = nil
                }
            } catch {
                await MainActor.run {
                    self.isActivating = false
                    self.errorMessage = "Failed to connect: \(error.localizedDescription)"
                }
            }
        }
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
                    if let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                         try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent("ImageCache"))
                    }
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
}
