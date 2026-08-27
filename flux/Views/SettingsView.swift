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
    @AppStorage("tmdbApiKey") private var tmdbApiKey = ""

    var body: some View {
        Form {
            Section(header: Text("Account")) {
                if authManager.isAuthenticated, let user = authManager.currentUser {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.email ?? "User")
                                .font(.system(size: 13, weight: .semibold))
                            if let synced = authManager.lastSyncDate {
                                Text("Synced \(synced.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Sync Now") { authManager.syncNow() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button("Sign Out") { authManager.signOut() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                } else {
                    HStack {
                        Text(authManager.isLoading ? "Working…" : "Sign in to sync your library across Macs.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Sign In") { showAuth = true }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    if let error = authManager.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }

            Section(header: Text("Discovery")) {
                Toggle("Enable Flux Home Catalogue", isOn: $enableFluxCatalogue)
                Text("Show Popular and New Release sections (powered by Cinemeta, Stremio's free catalogue) at the top of Home.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(header: Text("Metadata (Optional)")) {
                SecureField("TMDB API key", text: $tmdbApiKey)
                    .textFieldStyle(.roundedBorder)
                Text("Flux works out of the box with no key. Add your own free TMDB key to unlock richer detail: cast photos, similar titles, and genre discovery. Leave blank to stay fully keyless.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !tmdbApiKey.isEmpty {
                    Button("Clear TMDB key") { tmdbApiKey = "" }
                        .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showAuth) {
            AuthView()
        }
    }

    @State private var showAuth = false
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
    @AppStorage("ramCacheMode") private var ramCacheMode = false
    @State private var cacheUsage = ""

    /// Mirrors Stremio's cache size options (disk LRU — oldest torrents evicted first).
    private let cacheOptions = [1, 2, 5, 10, 20, 50]

    var body: some View {
        Form {
             Section(header: Text("Storage"),
                     footer: Text("Torrent streams buffer to disk and the least-recently-watched titles are evicted automatically when the limit is reached. Changing the limit applies immediately.")) {
                Toggle("RAM Cache Mode", isOn: $ramCacheMode)
                    .tint(.cyan)

                if ramCacheMode {
                    Text("Pieces buffer in 512MB of RAM instead of disk. Reduces SSD wear. May cause brief stalls on backward seeks with poorly-seeded torrents. Requires app restart.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Torrent Cache Size", selection: $stremioCacheGB) {
                    ForEach(cacheOptions, id: \.self) { gb in
                        Text("\(gb) GB").tag(gb)
                    }
                }
                .onChange(of: stremioCacheGB) { _, newValue in
                    Task {
                        await StremioServerManager.shared.setCacheSize(gigabytes: newValue)
                        await StremioServerManager.shared.evictCacheIfNeeded()
                    }
                }

                if !cacheUsage.isEmpty {
                    HStack {
                        Text("Currently Used")
                        Spacer()
                        Text(cacheUsage).foregroundStyle(.secondary)
                    }
                }

                Button("Clear Image Cache") {
                    // Clear on-disk thumbnail cache
                    ThumbnailDiskCache.shared.clearCache()
                    // Remove the old FluxImageCache directory (legacy)
                    let container = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                        .deletingLastPathComponent().appendingPathComponent("Caches")
                    if let container {
                        try? FileManager.default.removeItem(at: container.appendingPathComponent("FluxImageCache"))
                    }
                    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                    if let caches {
                        try? FileManager.default.removeItem(at: caches.appendingPathComponent("FluxImageCache"))
                    }
                    cacheUsage = "0 KB"
                }
            }

            Section(header: Text("About")) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: Color.black.opacity(0.35), radius: 4, y: 2)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Flux")
                            .font(.system(size: 15, weight: .bold))
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0") (Beta)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(.vertical, 2)
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
