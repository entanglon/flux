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
    @ObservedObject var traktManager = TraktManager.shared
    
    @State private var pinCode: String = ""
    @State private var isActivating: Bool = false
    @State private var errorMessage: String? = nil
    
    var body: some View {
        Form {
            Section(header: Text("Account")) {
                if traktManager.isAuthenticated {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Connected to Trakt")
                        Spacer()
                        Button("Disconnect") {
                            traktManager.logout()
                        }
                    }
                    
                    HStack {
                        Button("Sync History Now") {
                            Task {
                                try? await traktManager.syncHistory()
                            }
                        }
                        .disabled(traktManager.isSyncing)
                        
                        if traktManager.isSyncing {
                            ProgressView()
                                .scaleEffect(0.5)
                        }
                    }
                } else if isActivating {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Finish Linking Trakt")
                            .font(.headline)
                        Text("1. A browser window should have opened. Log in and Approve Flux.")
                        Text("2. Copy the PIN code provided by Trakt and paste it below.")
                        
                        TextField("Enter PIN Code", text: $pinCode)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        
                        HStack {
                            Button("Submit PIN") {
                                submitPin()
                            }
                            .disabled(pinCode.isEmpty)
                            .buttonStyle(.borderedProminent)
                            
                            Button("Cancel") {
                                isActivating = false
                                pinCode = ""
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                } else {
                    Button("Connect to Trakt") {
                        startPinFlow()
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
    
    private func startPinFlow() {
        if let url = traktManager.authorizationURL {
            NSWorkspace.shared.open(url)
            isActivating = true
            errorMessage = nil
            pinCode = ""
        } else {
            errorMessage = "Failed to generate authorization URL."
        }
    }
    
    private func submitPin() {
        Task {
            do {
                try await traktManager.exchangePINForToken(pin: pinCode)
                await MainActor.run {
                    self.isActivating = false
                    self.pinCode = ""
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Authentication failed. Please check your PIN and try again."
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
