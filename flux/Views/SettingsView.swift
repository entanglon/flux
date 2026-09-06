import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
            StreamingSettingsView()
                .tabItem { Label("Streaming", systemImage: "antenna.radiowaves.left.and.right") }
            AddonsSettingsTabView()
                .tabItem { Label("Addons", systemImage: "puzzlepiece.extension") }
            PlaybackSettingsView()
                .tabItem { Label("Playback", systemImage: "play.tv") }
            AdvancedSettingsView()
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 550, height: 500)
        .padding()
        .preferredColorScheme(.dark)
    }
}

// MARK: - 1. General Settings (Account + App + TMDB)
struct GeneralSettingsView: View {
    @ObservedObject var authManager = AuthManager.shared
    @AppStorage("syncEnabled") private var syncEnabled = true
    @AppStorage("enrichHomeWithTMDB") private var enrichHomeWithTMDB = true
    @AppStorage("tmdbApiKey") private var tmdbApiKey = ""   // the saved (validated) key
    @State private var draftKey = ""                        // what the user is typing
    @State private var isEditingKey = false
    @State private var isValidating = false
    @State private var keyStatus: KeyStatus = .idle
    @State private var showAuth = false

    private enum KeyStatus { case idle, valid, invalid }

    var body: some View {
        Form {
            Section(header: Text("Account")) {
                if authManager.isAuthenticated, let user = authManager.currentUser {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.blue.gradient)

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
                    .padding(.vertical, 2)
                } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cloud Sync")
                                .font(.system(size: 13, weight: .medium))
                            Text(authManager.isLoading ? "Working…" : "Sign in to sync your library across Macs.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Sign In") { showAuth = true }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    .padding(.vertical, 2)

                    if let error = authManager.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }

            Section(header: Text("Metadata (Optional)")) {
                // Header Line with Status on the right
                HStack {
                    Label("TMDB API Key", systemImage: "key.fill")
                        .font(.system(size: 13, weight: .medium))
                    
                    Spacer()
                    
                    if !tmdbApiKey.isEmpty && !isEditingKey {
                        HStack(spacing: 8) {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Active")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.green)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.12))
                            .clipShape(Capsule())
                            
                            Button(action: {
                                withAnimation(.spring(response: 0.3)) {
                                    draftKey = tmdbApiKey
                                    isEditingKey = true
                                }
                            }) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Edit TMDB API Key")

                            Button(action: clearTmdbKey) {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.red.opacity(0.85))
                            }
                            .buttonStyle(.borderless)
                            .help("Remove TMDB API Key")
                        }
                    } else if tmdbApiKey.isEmpty && !isEditingKey {
                        Button(action: {
                            withAnimation(.spring(response: 0.3)) {
                                isEditingKey = true
                            }
                        }) {
                            Label("Add Key", systemImage: "plus.circle.fill")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 1)

                // Input field and action buttons (visible when editing or no key configured)
                if isEditingKey || tmdbApiKey.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            SecureField("Enter TMDB API Key…", text: $draftKey)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { saveTmdbKey() }
                        }

                        // Save and Clear action buttons on the right side below the field
                        HStack(spacing: 8) {
                            if keyStatus == .invalid {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.red)
                                    Text("Invalid API key. Check and try again.")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.red)
                                }
                            }
                            
                            Spacer()

                            // Clear / Cancel button
                            Button(action: {
                                draftKey = ""
                                keyStatus = .idle
                                if !tmdbApiKey.isEmpty {
                                    withAnimation(.spring(response: 0.3)) {
                                        isEditingKey = false
                                    }
                                }
                            }) {
                                Text(!tmdbApiKey.isEmpty ? "Cancel" : "Clear")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(!tmdbApiKey.isEmpty ? "Cancel editing" : "Clear field")

                            // Save & Validate button
                            Button(action: saveTmdbKey) {
                                if isValidating {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Text("Save Key")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(draftKey.trimmingCharacters(in: .whitespaces).isEmpty || isValidating)
                            .help("Validate and Save Key")
                        }
                    }
                    .padding(.top, 4)
                }

                Text("Flux works out of the box with no key. Add your own free TMDB key to unlock richer detail: cast photos, similar titles, and genre discovery. Leave blank to stay fully keyless.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                Link("Get Free TMDB Key ↗", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
                    .font(.caption)
                    .padding(.top, 1)

                if !tmdbApiKey.isEmpty {
                    Divider()
                        .padding(.vertical, 4)
                    
                    Toggle("Enrich Home & Discovery with TMDB", isOn: $enrichHomeWithTMDB)
                        .onChange(of: enrichHomeWithTMDB) { _, _ in
                            NotificationCenter.default.post(name: .fluxRefresh, object: nil)
                        }
                    Text("When enabled, Home discovery rails (trending, popular, top rated) and OTT streaming rows are enriched using TMDB. When disabled, Home uses pure native Cinemeta / Stremio catalogs while media details, cast, and search still use TMDB.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            draftKey = tmdbApiKey
            isEditingKey = tmdbApiKey.isEmpty
            keyStatus = tmdbApiKey.isEmpty ? .idle : .valid
        }
        .onChange(of: draftKey) { _, _ in
            if keyStatus != .idle { keyStatus = .idle }
        }
        .sheet(isPresented: $showAuth) {
            AuthView()
        }
    }

    private func saveTmdbKey() {
        let key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !isValidating else { return }
        isValidating = true
        keyStatus = .idle
        Task {
            let ok = await TMDBEnricher.shared.validateKey(key)
            await MainActor.run {
                isValidating = false
                if ok {
                    tmdbApiKey = key      // persist only when verified
                    keyStatus = .valid
                    withAnimation(.spring(response: 0.35)) {
                        isEditingKey = false
                    }
                } else {
                    keyStatus = .invalid  // leave the saved key untouched
                }
            }
        }
    }

    private func clearTmdbKey() {
        withAnimation(.spring(response: 0.3)) {
            tmdbApiKey = ""
            draftKey = ""
            keyStatus = .idle
            isEditingKey = true
        }
    }
}

// MARK: - 2. Streaming Settings
struct StreamingSettingsView: View {
    @AppStorage("enableFluxMode") private var enableFluxMode = true
    @AppStorage("preferredQuality") private var preferredQuality = "4K"
    @AppStorage("streamingSourceMode") private var streamingSourceMode = "both"
    @AppStorage("enableFluxLanguageFilter") private var enableFluxLanguageFilter = false
    
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
                Text("Automatically find and race to play the fastest available stream.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Picker("Maximum Resolution", selection: $preferredQuality) {
                    Text("4K (2160p)").tag("4K")
                    Text("2K (1440p)").tag("2K")
                    Text("1080p").tag("1080p")
                    Text("720p").tag("720p")
                    Text("480p").tag("480p")
                }
                .pickerStyle(.menu)
                .disabled(!enableFluxMode)
                .opacity(enableFluxMode ? 1.0 : 0.6)

                Toggle("Language Filter in Flux Mode", isOn: $enableFluxLanguageFilter)
                    .disabled(!enableFluxMode)
                    .opacity(enableFluxMode ? 1.0 : 0.6)
                Text("When enabled, Flux Mode filters streams by your preferred audio language. When disabled, it races the fastest and healthiest streams regardless of language tags.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .opacity(enableFluxMode ? 1.0 : 0.6)
            }
        }
        .formStyle(.grouped)
        .onChange(of: streamingSourceMode) { _, _ in persistSettings() }
        .onChange(of: enableFluxMode) { _, _ in persistSettings() }
        .onChange(of: preferredQuality) { _, _ in persistSettings() }
        .onChange(of: enableFluxLanguageFilter) { _, _ in persistSettings() }
    }

    private func persistSettings() {
        ProfileManager.shared.saveCurrentProfileSettings()
        AuthManager.shared.scheduleAutoSync()
    }
}

// MARK: - 3. Playback Settings
struct PlaybackSettingsView: View {
    @AppStorage("useHardwareAcceleration") private var useHardwareAcceleration = true
    @AppStorage("autoPlayNextEnabled") private var autoPlayNextEnabled = true
    @AppStorage("enableAudioPassthrough") private var enableAudioPassthrough = false
    @AppStorage("defaultAudioLang") private var defaultAudioLang = "English"
    @AppStorage("defaultSubLang") private var defaultSubLang = "English"

    let audioLanguages = ["English", "Spanish", "French", "German", "Japanese", "Korean", "Hindi"]
    let subtitleLanguages = ["Off", "English", "Spanish", "French", "German", "Japanese", "Korean", "Hindi"]

    var body: some View {
        Form {
            Section(header: Text("Video Player"), footer: Text("Hardware decoding utilizes Apple Silicon / GPU hardware acceleration for smooth 4K HDR playback.")) {
                Toggle("Hardware Acceleration", isOn: $useHardwareAcceleration)
            }

            Section(header: Text("Playback Behavior")) {
                Toggle("Auto-play Next Episode", isOn: $autoPlayNextEnabled)
            }

            Section(header: Text("Audio"), footer: Text("Bitstream Dolby Atmos (E-AC-3 JOC / TrueHD) and DTS to an AVR or soundbar over HDMI. Leave disabled when listening through Mac built-in speakers or AirPods.")) {
                Toggle("Audio Passthrough (Atmos / DTS)", isOn: $enableAudioPassthrough)
            }
            
            Section(header: Text("Languages")) {
                Picker("Default Audio", selection: $defaultAudioLang) {
                    ForEach(audioLanguages, id: \.self) { Text($0).tag($0) }
                }
                Picker("Default Subtitles", selection: $defaultSubLang) {
                    ForEach(subtitleLanguages, id: \.self) { Text($0).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: useHardwareAcceleration) { _, _ in persistSettings() }
        .onChange(of: autoPlayNextEnabled) { _, _ in persistSettings() }
        .onChange(of: enableAudioPassthrough) { _, _ in persistSettings() }
        .onChange(of: defaultAudioLang) { _, _ in persistSettings() }
        .onChange(of: defaultSubLang) { _, _ in persistSettings() }
    }

    private func persistSettings() {
        ProfileManager.shared.saveCurrentProfileSettings()
        AuthManager.shared.scheduleAutoSync()
    }
}

// MARK: - 4. Advanced Settings
struct AdvancedSettingsView: View {
    @AppStorage("stremioCacheGB") private var stremioCacheGB = 2
    @State private var cacheUsage = ""
    @State private var usedBytes: Int64 = 0
    @State private var isClearingImages = false
    @State private var isClearingTorrents = false
    @ObservedObject private var updateManager = UpdateManager.shared

    /// Mirrors Stremio's cache size options (disk LRU — oldest torrents evicted first).
    private let cacheOptions = [1, 2, 5, 10, 20, 50]

    private var usageFraction: Double {
        let limitBytes = Int64(stremioCacheGB) * 1024 * 1024 * 1024
        guard limitBytes > 0 else { return 0.0 }
        return min(1.0, max(0.0, Double(usedBytes) / Double(limitBytes)))
    }

    var body: some View {
        Form {
            Section(
                header: Text("Storage"),
                footer: Text("Torrent streams buffer to disk and the least-recently-watched titles are evicted automatically when the limit is reached. Changing the limit applies immediately.")
            ) {
                Picker("Torrent Cache Limit", selection: $stremioCacheGB) {
                    ForEach(cacheOptions, id: \.self) { gb in
                        Text("\(gb) GB").tag(gb)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: stremioCacheGB) { _, newValue in
                    ProfileManager.shared.saveCurrentProfileSettings()
                    AuthManager.shared.scheduleAutoSync()
                    Task {
                        await StremioServerManager.shared.setCacheSize(gigabytes: newValue)
                        await StremioServerManager.shared.evictCacheIfNeeded()
                        await refreshCacheUsage()
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Disk Cache Used", systemImage: "internaldrive.fill")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(cacheUsage.isEmpty ? "Calculating…" : "\(cacheUsage) of \(stremioCacheGB) GB")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    // Sleek visual storage gauge
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.08))
                                .frame(height: 6)

                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: usageFraction > 0.85 ? [.orange, .red] : [.blue, .cyan],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(4, geo.size.width * usageFraction), height: 6)
                        }
                    }
                    .frame(height: 6)
                }
                .padding(.vertical, 4)

                HStack(spacing: 12) {
                    Button(action: clearImageCache) {
                        HStack(spacing: 5) {
                            if isClearingImages {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "photo.badge.arrow.down")
                            }
                            Text("Clear Images")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(action: purgeTorrentCache) {
                        HStack(spacing: 5) {
                            if isClearingTorrents {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "trash")
                            }
                            Text("Purge Torrent Cache")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.top, 2)
            }

            Section(header: Text("About")) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .shadow(color: Color.black.opacity(0.3), radius: 4, y: 2)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Flux")
                            .font(.system(size: 15, weight: .bold))
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(action: {
                        updateManager.checkForUpdates()
                    }) {
                        Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!updateManager.canCheckForUpdates)
                }
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
        .task {
            await refreshCacheUsage()
        }
    }

    private func refreshCacheUsage() async {
        let (bytes, formatted) = await StremioServerManager.shared.cacheUsageInfo()
        await MainActor.run {
            self.usedBytes = bytes
            self.cacheUsage = formatted
        }
    }

    private func clearImageCache() {
        isClearingImages = true
        Task {
            // Clear URLCache (in-memory + on-disk)
            ImageSession.shared.configuration.urlCache?.removeAllCachedResponses()
            // Clear the in-memory NSCache
            ImageInMemoryCache.shared.removeAllObjects()
            // Remove the on-disk FluxImageCache directory
            let container = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .deletingLastPathComponent().appendingPathComponent("Caches")
            if let container {
                try? FileManager.default.removeItem(at: container.appendingPathComponent("FluxImageCache"))
            }
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            if let caches {
                try? FileManager.default.removeItem(at: caches.appendingPathComponent("FluxImageCache"))
            }
            await refreshCacheUsage()
            await MainActor.run {
                isClearingImages = false
            }
        }
    }

    private func purgeTorrentCache() {
        isClearingTorrents = true
        Task {
            await StremioServerManager.shared.purgeTorrentCache()
            await refreshCacheUsage()
            await MainActor.run {
                isClearingTorrents = false
            }
        }
    }
}

// MARK: - 3. Addons Settings Tab (Clean macOS Preference Pane)
struct AddonsSettingsTabView: View {
    @ObservedObject var addonManager = AddonManager.shared
    @ObservedObject var authManager = AuthManager.shared
    @State private var newAddonUrl = ""
    @State private var isAdding = false
    @State private var isSyncing = false
    @State private var addError: String?

    var body: some View {
        Form {
            // Addon Store Banner
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.title2)
                        .foregroundStyle(LinearGradient(colors: [.blue.opacity(0.8), .cyan.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Addon Store & Directory")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                        
                        Text("Explore streaming providers, platforms, and subtitle extensions.")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    
                    Spacer()
                    
                    // Web Directory Button (SSO Auto-Login)
                    Button(action: {
                        addonManager.openWebStore()
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "safari")
                                .font(.system(size: 11, weight: .bold))
                            Text("Web Store ↗")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.12))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Open Flux Addon Web Store in browser with auto-login")
                }
                .padding(.vertical, 4)
            }
            
            // Installed Addons List
            Section(header: HStack {
                Text("Installed Addons (\(addonManager.addons.count))")
                
                Spacer()
                
                Button(action: {
                    Task {
                        isSyncing = true
                        await authManager.syncNowAsync(forcePull: true)
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        await MainActor.run { isSyncing = false }
                    }
                }) {
                    HStack(spacing: 5) {
                        if isSyncing {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 13, height: 13)
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 11, weight: .bold))
                        }
                        Text(isSyncing ? "Syncing…" : "Refresh")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4.5)
                    .background(Color.white.opacity(0.08))
                    .foregroundColor(.white.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isSyncing)
                .help("Refresh installed addons from Flux Cloud")
            }) {
                if addonManager.addons.isEmpty {
                    Text("No addons installed.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(addonManager.addons) { addon in
                        HStack(spacing: 12) {
                            // Logo
                            if let logoStr = addon.logoURL ?? addon.iconURL, let url = URL(string: logoStr) {
                                CachedImage(url: url, maxDimension: 60) { phase in
                                    switch phase {
                                    case .success(let img):
                                        img
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(width: 24, height: 24)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                    default:
                                        fallbackIcon(name: addon.name)
                                    }
                                }
                            } else {
                                fallbackIcon(name: addon.name)
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(addon.name)
                                        .font(.system(size: 13, weight: .semibold))
                                    
                                    if addon.isStock {
                                        Text("STOCK")
                                            .font(.system(size: 9, weight: .heavy))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1.5)
                                            .background(Color.indigo.opacity(0.8))
                                            .foregroundColor(.white)
                                            .clipShape(Capsule())
                                    }
                                }
                                
                                if let version = addon.version {
                                    Text("v\(version)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            
                            Spacer()
                            
                            // Delete / Uninstall Button (Left of Settings Gear)
                            if !addon.isStock {
                                Button(action: {
                                    addonManager.removeAddon(addon)
                                }) {
                                    Image(systemName: "trash.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(.red.opacity(0.85))
                                }
                                .buttonStyle(.borderless)
                                .help("Uninstall addon")
                            }
                            
                            // Configure Gear Button (Left of Toggle)
                            if let configURL = configureURL(for: addon) {
                                Button(action: {
                                    NSWorkspace.shared.open(configURL)
                                }) {
                                    Image(systemName: "gearshape.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(.white.opacity(0.75))
                                }
                                .buttonStyle(.borderless)
                                .help("Configure addon in browser")
                            }
                            
                            // Toggle Switch (Far Right Alignment)
                            Toggle("", isOn: Binding(
                                get: { addon.isEnabled },
                                set: { _ in addonManager.toggleAddon(addon) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            
            // Install from URL Section (Spacious Liquid Glass Input)
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Install Custom Addon")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.white)
                    
                    Text("Paste any manifest URL (e.g. https://domain.com/manifest.json) or stremio:// link")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                    
                    HStack(spacing: 8) {
                        TextField("https://addon-domain.com/manifest.json", text: $newAddonUrl)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            )
                            .labelsHidden()
                        
                        Button(action: addAddon) {
                            HStack(spacing: 5) {
                                if isAdding {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                        .tint(.white)
                                } else {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 11, weight: .bold))
                                }
                                Text("Install")
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.12))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(newAddonUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAdding)
                    }
                    
                    if let error = addError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                            Text(error)
                                .font(.system(size: 11))
                        }
                        .foregroundColor(.red)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await authManager.syncNowAsync(forcePull: true)
            }
        }
    }
    
    private func configureURL(for addon: StremioAddon) -> URL? {
        guard !addon.isStock, !addon.url.isEmpty else { return nil }
        var base = addon.url.replacingOccurrences(of: "/manifest.json", with: "")
        while base.hasSuffix("/") { base.removeLast() }
        if base.contains("/configure") {
            return URL(string: base)
        }
        if let url = URL(string: base), let scheme = url.scheme, let host = url.host {
            let portPart = url.port != nil ? ":\(url.port!)" : ""
            return URL(string: "\(scheme)://\(host)\(portPart)/configure")
        }
        return URL(string: "\(base)/configure")
    }

    private func fallbackIcon(name: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.1))
                .frame(width: 24, height: 24)
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
        }
    }
    
    private func addAddon() {
        let clean = newAddonUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        isAdding = true
        addError = nil
        Task {
            do {
                try await addonManager.addAddon(url: clean, isStock: false, category: AddonCategory.community.rawValue)
                await MainActor.run {
                    self.newAddonUrl = ""
                    self.isAdding = false
                }
            } catch {
                await MainActor.run {
                    self.addError = "Failed to load addon: \(error.localizedDescription)"
                    self.isAdding = false
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}

