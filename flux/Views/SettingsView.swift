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
    @AppStorage("enableFluxCatalogue") private var enableFluxCatalogue = true
    
    var body: some View {
        Form {
            Section(header: Text("Account")) {
                if let user = authManager.currentUser {
                    HStack {
                         Text(user.email ?? "User")
                         Spacer()
                         Button("Sign Out") { authManager.signOut() }
                    }
                }
            }
            
            Section(header: Text("Discovery")) {
                Toggle("Enable Flux Home Catalogue", isOn: $enableFluxCatalogue)
                Text("Show Trending and Popular sections from TMDB at the top of Home.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
    @AppStorage("streamingSourceMode") private var streamingSourceMode = "both"
    
    var body: some View {
        Form {
            Section(header: Text("Stream Sources")) {
                Picker("Stream Filter", selection: $streamingSourceMode) {
                    Text("HTTP & Torrent Streams (Both)").tag("both")
                    Text("HTTP Streams Only").tag("http")
                    Text("Torrent Streams Only").tag("torrent")
                }
                .pickerStyle(.menu)
                
                Text("Select whether Flux should load HTTP streams, Torrent streams, or both simultaneously.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
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
        }
        .formStyle(.grouped)
    }
}

// MARK: - 3. Playback Settings
struct PlaybackSettingsView: View {
    @AppStorage("useHardwareAcceleration") private var useHardwareAcceleration = true
    @AppStorage("autoPlayNextEnabled") private var autoPlayNextEnabled = true
    @AppStorage("enableAudioPassthrough") private var enableAudioPassthrough = false
    @AppStorage("defaultAudioLang") private var defaultAudioLang = "English"
    @AppStorage("defaultSubLang") private var defaultSubLang = "English"

    let languages = ["English", "Spanish", "French", "German", "Japanese", "Korean", "Hindi"]

    var body: some View {
        Form {
            Section(header: Text("Video Player"), footer: Text("Restart playback after changing these options.")) {
                Toggle("Hardware Acceleration", isOn: $useHardwareAcceleration)
            }

            Section(header: Text("Playback Behavior")) {
                Toggle("Auto-play Next Episode", isOn: $autoPlayNextEnabled)
            }

            Section(header: Text("Audio"), footer: Text("Bitstream Dolby Atmos (E-AC-3 JOC / TrueHD) and DTS to an AVR or soundbar over HDMI. Requires exclusive access to the output device.")) {
                Toggle("Audio Passthrough (Atmos / DTS)", isOn: $enableAudioPassthrough)
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
    @AppStorage("stremioCacheGB") private var stremioCacheGB = 2
    @State private var cacheUsage = ""

    /// Mirrors Stremio's cache size options (disk LRU — oldest torrents evicted first).
    private let cacheOptions = [1, 2, 5, 10, 20, 50]

    var body: some View {
        Form {
             Section(header: Text("Storage"),
                     footer: Text("Torrent streams buffer to disk and the least-recently-watched titles are evicted automatically when the limit is reached. Changing the limit applies immediately.")) {
                Picker("Torrent Cache Size", selection: $stremioCacheGB) {
                    ForEach(cacheOptions, id: \.self) { gb in
                        Text("\(gb) GB").tag(gb)
                    }
                }
                .onChange(of: stremioCacheGB) { _, newValue in
                    Task { await StremioServerManager.shared.setCacheSize(gigabytes: newValue) }
                }

                if !cacheUsage.isEmpty {
                    HStack {
                        Text("Currently Used")
                        Spacer()
                        Text(cacheUsage).foregroundStyle(.secondary)
                    }
                }

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
        .task {
            cacheUsage = await StremioServerManager.shared.cacheUsage()
        }
    }
}

#Preview {
    SettingsView()
}
