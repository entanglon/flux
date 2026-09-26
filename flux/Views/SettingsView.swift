import SwiftUI

struct SettingsView: View {
    @ObservedObject var languageManager = LanguageManager.shared

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label(L10n.tr("General"), systemImage: "gear") }
            StreamingSettingsView()
                .tabItem { Label(L10n.tr("Streaming"), systemImage: "antenna.radiowaves.left.and.right") }
            AddonsSettingsTabView()
                .tabItem { Label(L10n.tr("Addons"), systemImage: "puzzlepiece.extension") }
            PlaybackSettingsView()
                .tabItem { Label(L10n.tr("Playback"), systemImage: "play.tv") }
            AdvancedSettingsView()
                .tabItem { Label(L10n.tr("Advanced"), systemImage: "slider.horizontal.3") }
        }
        .frame(width: 620, height: 530)
        .padding()
        .preferredColorScheme(.dark)
    }
}

// MARK: - 1. General Settings (Account + Profiles + TMDB + App)
struct GeneralSettingsView: View {
    @ObservedObject var authManager = AuthManager.shared
    @ObservedObject var profileManager = ProfileManager.shared
    @ObservedObject var languageManager = LanguageManager.shared
    @AppStorage("syncEnabled") private var syncEnabled = true
    @AppStorage("enrichHomeWithTMDB") private var enrichHomeWithTMDB = true
    @AppStorage("tmdbApiKey") private var tmdbApiKey = ""
    @State private var draftKey = ""
    @State private var isEditingKey = false
    @State private var isValidating = false
    @State private var keyStatus: KeyStatus = .idle
    @State private var showEditName = false
    @State private var showingVerifyPinSheet = false
    @State private var pendingProfileToSelect: UserProfile? = nil
    @State private var pendingActionAfterPin: (() -> Void)? = nil

    private enum KeyStatus { case idle, valid, invalid }

    var body: some View {
        Form {
            // MARK: Account Section
            Section(header: Text("Account".localized)) {
                if authManager.isAuthenticated, let user = authManager.currentUser {
                    HStack(spacing: 14) {
                        if let profile = profileManager.currentProfile {
                            AvatarBadge(avatarID: profile.avatarID, size: 42)
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                                Image(systemName: "person.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            .frame(width: 42, height: 42)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(user.displayName ?? user.email?.components(separatedBy: "@").first ?? "Flux User")
                                    .font(.system(size: 14, weight: .semibold))

                                Button(action: { showEditName = true }) {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.8))
                                        .frame(width: 20, height: 20)
                                        .background(Color.white.opacity(0.08))
                                        .clipShape(Circle())
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .help("Edit Display Name".localized)

                                if authManager.needsDisplayNamePrompt {
                                    Button(action: { showEditName = true }) {
                                        HStack(spacing: 3) {
                                            Image(systemName: "pencil.line")
                                                .font(.system(size: 9))
                                            Text("Add Name".localized)
                                                .font(.system(size: 10, weight: .semibold))
                                        }
                                        .foregroundStyle(.white.opacity(0.9))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(Color.white.opacity(0.12))
                                        .clipShape(Capsule())
                                        .contentShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            Text(user.email ?? "")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)

                            HStack(spacing: 6) {
                                Circle()
                                    .fill(authManager.isLoading ? Color.orange : Color.green)
                                    .frame(width: 6, height: 6)
                                if authManager.isLoading {
                                    Text("Syncing library…".localized)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                } else if let synced = authManager.lastSyncDate {
                                    Text("Synced %@".localizedFormat(synced.formatted(date: .abbreviated, time: .shortened)))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Cloud Connected".localized)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Spacer()

                        HStack(spacing: 8) {
                            Button("Sync Now".localized) { authManager.syncNow() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(authManager.isLoading)

                            Button("Sign Out".localized) { authManager.signOut() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Cloud Sync".localized)
                                .font(.system(size: 13, weight: .semibold))
                            Text(authManager.isLoading ? "Connecting…".localized : "Sign in to sync your library, watch progress, and history.".localized)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Sign In".localized) {
                            authManager.startSignInFlow()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }

            // MARK: Watching Profiles Section
            Section(header: Text("Watching Profiles".localized)) {
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(profileManager.profiles) { profile in
                                let isCurrent = profile.id == profileManager.currentProfile?.id
                                let hasLock = ParentalLockManager.shared.hasPin(for: profile.id)

                                Button(action: {
                                    guard !isCurrent else { return }
                                    if profileManager.requiresPinToExit {
                                        pendingProfileToSelect = profile
                                        showingVerifyPinSheet = true
                                    } else if profileManager.requiresPinToEnter(profile: profile) {
                                        pendingProfileToSelect = profile
                                        showingVerifyPinSheet = true
                                    } else {
                                        profileManager.selectProfile(profile)
                                    }
                                }) {
                                    HStack(spacing: 8) {
                                        AvatarBadge(avatarID: profile.avatarID, size: 28)

                                        Text(profile.displayName)
                                            .font(.system(size: 12, weight: isCurrent ? .bold : .medium))
                                            .foregroundStyle(isCurrent ? .white : .white.opacity(0.85))

                                        if profile.isKids {
                                            Text("KIDS".localized)
                                                .font(.system(size: 8, weight: .heavy, design: .rounded))
                                                .foregroundStyle(.black)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Capsule().fill(Color.yellow))
                                        }

                                        if hasLock {
                                            Image(systemName: "lock.fill")
                                                .font(.system(size: 9))
                                                .foregroundStyle(.white.opacity(0.6))
                                        }

                                        if isCurrent {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(.green)
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(isCurrent ? Color.white.opacity(0.14) : Color.white.opacity(0.06))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .stroke(isCurrent ? Color.white.opacity(0.28) : Color.white.opacity(0.08), lineWidth: 1)
                                            )
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }

                    HStack {
                        Button("Manage Profiles…".localized) {
                            let action = {
                                #if os(macOS)
                                for window in NSApp.windows {
                                    let title = window.title.lowercased()
                                    let id = window.identifier?.rawValue ?? ""
                                    let autosave = window.frameAutosaveName
                                    if id.contains("Settings") || id.contains("settings") ||
                                       autosave.contains("Settings") || autosave.contains("settings") ||
                                       title.contains("settings") || title.contains("general") || title.contains("preferences") {
                                        window.close()
                                    }
                                }
                                #endif
                                profileManager.switchToProfileSelection()
                            }

                            if profileManager.requiresPinToExit {
                                pendingActionAfterPin = action
                                showingVerifyPinSheet = true
                            } else {
                                action()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Spacer()
                    }
                }
                .padding(.vertical, 3)
            }

            // MARK: Catalog & Metadata (TMDB) Section
            Section(header: Text("Catalog & Metadata".localized)) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "film.stack.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.cyan)
                            .frame(width: 28, height: 28)
                            .background(Color.cyan.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text("The Movie Database (TMDB)".localized)
                                .font(.system(size: 13, weight: .semibold))
                            Text(tmdbApiKey.isEmpty ? "Using high-speed keyless catalog".localized : "Personal API key active for high-rate enrichment".localized)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if !tmdbApiKey.isEmpty && !isEditingKey {
                            HStack(spacing: 6) {
                                HStack(spacing: 4) {
                                    Circle().fill(Color.green).frame(width: 6, height: 6)
                                    Text("Active".localized)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.green)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.green.opacity(0.12))
                                .clipShape(Capsule())

                                Button(action: {
                                    draftKey = tmdbApiKey
                                    isEditingKey = true
                                }) {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.85))
                                        .frame(width: 24, height: 24)
                                        .background(Color.white.opacity(0.08))
                                        .clipShape(Circle())
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .help("Edit TMDB API Key".localized)

                                Button(action: clearTmdbKey) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.red.opacity(0.85))
                                        .frame(width: 24, height: 24)
                                        .background(Color.red.opacity(0.12))
                                        .clipShape(Circle())
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .help("Remove TMDB API Key".localized)
                            }
                        } else if !isEditingKey {
                            Button("Add Key".localized) {
                                draftKey = ""
                                isEditingKey = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    if isEditingKey {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                SecureField("Enter TMDB API Key (e.g. 32-char hex)…".localized, text: $draftKey)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { saveTmdbKey() }

                                Button("Cancel".localized) {
                                    draftKey = tmdbApiKey
                                    keyStatus = .idle
                                    isEditingKey = false
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button(action: saveTmdbKey) {
                                    if isValidating {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Text("Save".localized)
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(draftKey.trimmingCharacters(in: .whitespaces).isEmpty || isValidating)
                            }

                            HStack {
                                if keyStatus == .invalid {
                                    Text("Invalid API key. Please check your key.".localized)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.red)
                                } else {
                                    Text("Flux works keyless out of the box. A personal key provides unlimited discovery.".localized)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Link("Get Free Key ↗".localized, destination: URL(string: "https://www.themoviedb.org/settings/api")!)
                                    .font(.system(size: 11))
                            }
                        }
                        .padding(10)
                        .background(Color.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    Divider()

                    Toggle(isOn: $enrichHomeWithTMDB) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enrich Discovery Rails with TMDB".localized)
                                .font(.system(size: 13, weight: .medium))
                            Text("Overlay rich artwork, genres, and cast details on Home & OTT rows.".localized)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: enrichHomeWithTMDB) { _, _ in
                        NotificationCenter.default.post(name: .fluxRefresh, object: nil)
                    }
                }
                .padding(.vertical, 3)
            }

            // MARK: Language Section
            Section(header: Text(L10n.tr("App Language"))) {
                VStack(alignment: .leading, spacing: 6) {
                    Picker(L10n.tr("App Language"), selection: Binding(
                        get: { languageManager.currentLanguage },
                        set: { newLang in languageManager.setLanguage(newLang) }
                    )) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .pickerStyle(.menu)

                    Text(L10n.tr("Select Interface Language"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }

            // MARK: App Information Section
            Section(header: Text("App Information".localized)) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Flux")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Version %@".localizedFormat(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Link("Project GitHub ↗".localized, destination: URL(string: "https://github.com/entanglon/flux")!)
                        .font(.caption)
                }
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            draftKey = tmdbApiKey
            isEditingKey = false
            keyStatus = tmdbApiKey.isEmpty ? .idle : .valid
        }
        .onChange(of: draftKey) { _, _ in
            if keyStatus != .idle { keyStatus = .idle }
        }
        .sheet(isPresented: $showEditName) {
            EditDisplayNameSheet()
        }
        .sheet(isPresented: $showingVerifyPinSheet) {
            let target = pendingProfileToSelect
            let exitingKids = profileManager.requiresPinToExit
            let subtitle = exitingKids 
                ? "Enter 4-digit PIN required to exit Kids profile".localized 
                : "Enter 4-digit PIN to access %@".localizedFormat(target?.name ?? "profile")
            let targetId = (target != nil && profileManager.requiresPinToEnter(profile: target!)) 
                ? target?.id 
                : profileManager.currentProfile?.id

            PINEntrySheet(mode: .verify(
                title: target?.name ?? "Parental PIN".localized,
                subtitle: subtitle,
                profileId: targetId,
                onSuccess: {
                    if let target = pendingProfileToSelect {
                        profileManager.selectProfile(target)
                        pendingProfileToSelect = nil
                    }
                    if let action = pendingActionAfterPin {
                        action()
                        pendingActionAfterPin = nil
                    }
                }
            ))
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
                    tmdbApiKey = key
                    UserDefaults.standard.set(key, forKey: UserDefaults.Key.tmdbApiKey)
                    keyStatus = .valid
                    withAnimation(.spring(response: 0.35)) {
                        isEditingKey = false
                    }
                    authManager.scheduleAutoSync(delay: 0.1)
                    NotificationCenter.default.post(name: .fluxRefresh, object: nil)
                } else {
                    keyStatus = .invalid
                }
            }
        }
    }

    private func clearTmdbKey() {
        withAnimation(.spring(response: 0.3)) {
            tmdbApiKey = ""
            draftKey = ""
            keyStatus = .idle
            isEditingKey = false
        }
        UserDefaults.standard.removeObject(forKey: UserDefaults.Key.tmdbApiKey)
        authManager.scheduleAutoSync(delay: 0.1)
        NotificationCenter.default.post(name: .fluxRefresh, object: nil)
    }
}

// MARK: - 2. Streaming Settings
struct StreamingSettingsView: View {
    @ObservedObject var languageManager = LanguageManager.shared
    @ObservedObject private var proxyManager = StreamRouteProxyManager.shared
    @AppStorage("enableFluxMode") private var enableFluxMode = true
    @AppStorage("preferredQuality") private var preferredQuality = "1080p"
    @AppStorage("streamingSourceMode") private var streamingSourceMode = "both"
    @AppStorage("enableFluxLanguageFilter") private var enableFluxLanguageFilter = false
    @AppStorage(UserDefaults.Key.enableAIStreamSelection) private var enableAIStreamSelection = false
    @AppStorage(UserDefaults.Key.geminiApiKey) private var geminiApiKey = ""
    @AppStorage(UserDefaults.Key.geminiModel) private var geminiModel = "gemini-3.5-flash-lite"
    @State private var showProxySheet = false
    @State private var preferredLanguages: [String] = []
    @State private var isEditingGeminiKey = false
    @State private var draftGeminiKey = ""

    let availableLanguages = [
        "English", "Japanese", "Spanish", "French", "German",
        "Italian", "Portuguese", "Korean", "Hindi", "Chinese",
        "Russian", "Tamil", "Telugu"
    ]
    
    var body: some View {
        Form {
            Section(header: Text(L10n.tr("Stream Sources"))) {
                Picker(L10n.tr("Stream Filter"), selection: $streamingSourceMode) {
                    Text("Direct & P2P Streams (Both)".localized).tag("both")
                    Text("Direct Streams Only".localized).tag("http")
                    Text("P2P Streams Only".localized).tag("torrent")
                }
                .pickerStyle(.menu)
                
                Text("Select whether Flux should load Direct streams, P2P streams, or both simultaneously.".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if streamingSourceMode != "http" {
                    HStack {
                        Text(L10n.tr("P2P Streaming Engine"))
                        Spacer()
                        Text("Official Stremio Engine (Node.js)".localized)
                            .foregroundStyle(.secondary)
                    }

                    Text("Selects the underlying P2P BitTorrent streaming core.".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Section(header: Text(L10n.tr("Direct Stream Route Proxy")), footer: Text("Routes throttled Direct scraper streams (e.g. 2peckle) through a private forward proxy over Tailscale/LAN while strictly bypassing P2P and metadata.".localized)) {
                Toggle(L10n.tr("Enable Route Proxy"), isOn: $proxyManager.isEnabled)
                
                if proxyManager.isEnabled {
                    HStack {
                        Text("Proxy Endpoint".localized)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(proxyManager.endpointURL)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.primary)
                    }
                }
                
                Button(action: {
                    showProxySheet = true
                }) {
                    Label("Configure Route Proxy…".localized, systemImage: "network.badge.shield.half.filled")
                }
            }
            .sheet(isPresented: $showProxySheet) {
                StreamRouteProxyConfigSheet()
            }
            
            Section(header: Text(L10n.tr("Flux Mode"))) {
                Toggle(L10n.tr("Enable Flux Mode"), isOn: $enableFluxMode)
                Text("Automatically find and race to play the fastest available stream.".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Picker(L10n.tr("Maximum Resolution"), selection: $preferredQuality) {
                    Text("4K (2160p)".localized).tag("4K")
                    Text("2K (1440p)".localized).tag("2K")
                    Text("1080p".localized).tag("1080p")
                    Text("720p".localized).tag("720p")
                    Text("480p".localized).tag("480p")
                }
                .pickerStyle(.menu)
                .disabled(!enableFluxMode)
                .opacity(enableFluxMode ? 1.0 : 0.6)

                Toggle(L10n.tr("Language Filter in Flux Mode"), isOn: $enableFluxLanguageFilter)
                    .disabled(!enableFluxMode)
                    .opacity(enableFluxMode ? 1.0 : 0.6)
                Text("When enabled, Flux Mode strictly filters streams to match your Preferred Languages. When disabled, it races the fastest and healthiest stream provided by your addons.".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .opacity(enableFluxMode ? 1.0 : 0.6)

                if enableFluxLanguageFilter && enableFluxMode {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.tr("Preferred Languages"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        
                        Text("Select languages Flux Mode should prefer for stream selection and playback.".localized)
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 6)], spacing: 6) {
                            ForEach(availableLanguages, id: \.self) { lang in
                                let isSelected = preferredLanguages.contains(lang)
                                Button {
                                    toggleLanguage(lang)
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 11))
                                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.6))
                                        Text(lang.localized)
                                            .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 2)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section(header: Text(L10n.tr("Selection Engine")), footer: Text("Choose between Flux's fast heuristic stream scoring algorithm and experimental LLM-powered selection via Google Gemini.".localized)) {
                Picker(L10n.tr("Stream Selection Mode"), selection: $enableAIStreamSelection) {
                    Text("Heuristic Algorithm (Instant)".localized).tag(false)
                    Text("Smart AI Selection (Experimental)".localized).tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(!enableFluxMode)
                .opacity(enableFluxMode ? 1.0 : 0.6)

                if enableAIStreamSelection && enableFluxMode {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Google Gemini API".localized)
                                .font(.system(size: 13, weight: .semibold))
                            Text(geminiApiKey.isEmpty ? "API key required for AI stream ranking".localized : "Personal API key active for smart stream selection".localized)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if !geminiApiKey.isEmpty && !isEditingGeminiKey {
                            HStack(spacing: 6) {
                                HStack(spacing: 4) {
                                    Circle().fill(Color.green).frame(width: 6, height: 6)
                                    Text("Active".localized)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.green)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.green.opacity(0.12))
                                .clipShape(Capsule())

                                Button(action: {
                                    draftGeminiKey = geminiApiKey
                                    isEditingGeminiKey = true
                                }) {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.85))
                                        .frame(width: 24, height: 24)
                                        .background(Color.white.opacity(0.08))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .help("Edit Gemini API Key".localized)

                                Button(action: {
                                    geminiApiKey = ""
                                    draftGeminiKey = ""
                                    UserDefaults.standard.removeObject(forKey: UserDefaults.Key.geminiApiKey)
                                    persistSettings()
                                }) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.red.opacity(0.85))
                                        .frame(width: 24, height: 24)
                                        .background(Color.red.opacity(0.12))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .help("Remove Gemini API Key".localized)
                            }
                        } else if !isEditingGeminiKey {
                            Button("Add Key".localized) {
                                draftGeminiKey = ""
                                isEditingGeminiKey = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    if isEditingGeminiKey {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                SecureField("Enter Gemini API Key (from Google AI Studio)…".localized, text: $draftGeminiKey)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit {
                                        geminiApiKey = draftGeminiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                                        UserDefaults.standard.set(geminiApiKey, forKey: UserDefaults.Key.geminiApiKey)
                                        isEditingGeminiKey = false
                                        persistSettings()
                                    }

                                Button("Cancel".localized) {
                                    draftGeminiKey = geminiApiKey
                                    isEditingGeminiKey = false
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button("Save".localized) {
                                    geminiApiKey = draftGeminiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                                    UserDefaults.standard.set(geminiApiKey, forKey: UserDefaults.Key.geminiApiKey)
                                    isEditingGeminiKey = false
                                    persistSettings()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(draftGeminiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Picker(L10n.tr("Gemini Model"), selection: $geminiModel) {
                        Text("Gemini 3.5 Flash-Lite (Fastest)".localized).tag("gemini-3.5-flash-lite")
                        Text("Gemini 2.5 Flash".localized).tag("gemini-2.5-flash")
                        Text("Gemini 3.6 Flash".localized).tag("gemini-3.6-flash")
                        Text("Gemini 3.8 Flash (Recommended)".localized).tag("gemini-3.8-flash")
                        Text("Gemini 3.7 Flash".localized).tag("gemini-3.7-flash")
                        Text("Gemini 3.5 Flash".localized).tag("gemini-3.5-flash")
                        Text("Gemini 3.1 Flash-Lite".localized).tag("gemini-3.1-flash-lite")
                    }
                    .pickerStyle(.menu)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            loadPreferredLanguages()
        }
        .onChange(of: streamingSourceMode) { _, _ in persistSettings() }
        .onChange(of: enableFluxMode) { _, _ in persistSettings() }
        .onChange(of: preferredQuality) { _, _ in persistSettings() }
        .onChange(of: enableFluxLanguageFilter) { _, _ in persistSettings() }
        .onChange(of: enableAIStreamSelection) { _, _ in persistSettings() }
        .onChange(of: geminiModel) { _, _ in persistSettings() }
        .onChange(of: proxyManager.isEnabled) { _, _ in persistSettings() }
    }

    private func loadPreferredLanguages() {
        let validGeminiModels = ["gemini-3.5-flash-lite", "gemini-3.6-flash", "gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.5-flash", "gemini-3.1-flash-lite", "gemini-2.5-flash"]
        if !validGeminiModels.contains(geminiModel) {
            geminiModel = "gemini-3.5-flash-lite"
            UserDefaults.standard.set("gemini-3.5-flash-lite", forKey: UserDefaults.Key.geminiModel)
        }
        if let saved = UserDefaults.standard.stringArray(forKey: UserDefaults.Key.preferredStreamLanguages), !saved.isEmpty {
            preferredLanguages = saved
        } else {
            let defaultAudio = UserDefaults.standard.string(forKey: "defaultAudioLang") ?? "English"
            preferredLanguages = [defaultAudio]
            UserDefaults.standard.set(preferredLanguages, forKey: UserDefaults.Key.preferredStreamLanguages)
        }
    }

    private func toggleLanguage(_ lang: String) {
        var current = preferredLanguages
        if current.contains(lang) {
            if current.count > 1 {
                current.removeAll { $0 == lang }
            }
        } else {
            current.append(lang)
        }
        preferredLanguages = current
        UserDefaults.standard.set(current, forKey: UserDefaults.Key.preferredStreamLanguages)

        let currentDefault = UserDefaults.standard.string(forKey: "defaultAudioLang") ?? "English"
        if currentDefault != "Original Audio" && !current.contains(currentDefault) {
            UserDefaults.standard.set(current.first ?? "English", forKey: "defaultAudioLang")
        }

        persistSettings()
    }

    private func persistSettings() {
        ProfileManager.shared.saveCurrentProfileSettings()
        AuthManager.shared.scheduleAutoSync(delay: 0.1)
    }
}

// MARK: - 3. Playback Settings
struct PlaybackSettingsView: View {
    @ObservedObject var languageManager = LanguageManager.shared
    @AppStorage("useHardwareAcceleration") private var useHardwareAcceleration = true
    @AppStorage("autoPlayNextEnabled") private var autoPlayNextEnabled = true
    @AppStorage("enableAudioPassthrough") private var enableAudioPassthrough = false
    @AppStorage("defaultAudioLang") private var defaultAudioLang = "English"
    @AppStorage("defaultSubLang") private var defaultSubLang = "English"

    private var audioLanguages: [String] {
        let preferred = UserDefaults.standard.stringArray(forKey: UserDefaults.Key.preferredStreamLanguages) ?? ["English"]
        var list = ["Original Audio"]
        for lang in preferred {
            if !list.contains(lang) {
                list.append(lang)
            }
        }
        return list
    }

    let subtitleLanguages = ["Off", "English", "Japanese", "Spanish", "French", "German", "Italian", "Portuguese", "Korean", "Hindi", "Chinese", "Russian", "Tamil", "Telugu"]

    var body: some View {
        Form {
            Section(header: Text(L10n.tr("Video Player")), footer: Text("Hardware decoding utilizes Apple Silicon / GPU hardware acceleration for smooth 4K HDR playback.".localized)) {
                Toggle(L10n.tr("Hardware Acceleration"), isOn: $useHardwareAcceleration)
            }

            Section(header: Text(L10n.tr("Playback Behavior"))) {
                Toggle(L10n.tr("Auto-play Next Episode"), isOn: $autoPlayNextEnabled)
            }

            Section(header: Text(L10n.tr("Audio")), footer: Text("Bitstream Dolby Atmos (E-AC-3 JOC / TrueHD) and DTS to an AVR or soundbar over HDMI. Leave disabled when listening through Mac built-in speakers or AirPods.".localized)) {
                Toggle(L10n.tr("Audio Passthrough (Atmos / DTS)"), isOn: $enableAudioPassthrough)
            }
            
            Section(header: Text(L10n.tr("Languages"))) {
                Picker(L10n.tr("Default Audio"), selection: $defaultAudioLang) {
                    ForEach(audioLanguages, id: \.self) { Text($0.localized).tag($0) }
                }
                Picker(L10n.tr("Default Subtitles"), selection: $defaultSubLang) {
                    ForEach(subtitleLanguages, id: \.self) { Text($0.localized).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            validateDefaultAudio()
        }
        .onChange(of: useHardwareAcceleration) { _, _ in persistSettings() }
        .onChange(of: autoPlayNextEnabled) { _, _ in persistSettings() }
        .onChange(of: enableAudioPassthrough) { _, _ in persistSettings() }
        .onChange(of: defaultAudioLang) { _, _ in persistSettings() }
        .onChange(of: defaultSubLang) { _, _ in persistSettings() }
    }

    private func validateDefaultAudio() {
        if !audioLanguages.contains(defaultAudioLang) {
            defaultAudioLang = audioLanguages.first(where: { $0 != "Original Audio" }) ?? "English"
            UserDefaults.standard.set(defaultAudioLang, forKey: "defaultAudioLang")
            persistSettings()
        }
    }

    private func persistSettings() {
        ProfileManager.shared.saveCurrentProfileSettings()
        AuthManager.shared.scheduleAutoSync(delay: 0.5)
    }
}

// MARK: - 4. Advanced Settings
struct AdvancedSettingsView: View {
    @ObservedObject var languageManager = LanguageManager.shared
    @AppStorage("stremioCacheGB") private var stremioCacheGB = 2
    @State private var cacheUsage = ""
    @State private var usedBytes: Int64 = 0
    @State private var isClearingImages = false
    @State private var isClearingTorrents = false
    @State private var showClearWatchConfirm = false
    @State private var showClearSearchConfirm = false
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
                header: Text("Storage".localized),
                footer: Text("P2P streams buffer to disk and the least-recently-watched titles are evicted automatically when the limit is reached. Changing the limit applies immediately.".localized)
            ) {
                Picker("P2P Cache Limit".localized, selection: $stremioCacheGB) {
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
                        Label("Disk Cache Used".localized, systemImage: "internaldrive.fill")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(cacheUsage.isEmpty ? "Calculating…".localized : "%@ of %d GB".localizedFormat(cacheUsage, stremioCacheGB))
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
                            Text("Clear Images".localized)
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
                            Text("Purge P2P Cache".localized)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.top, 2)
            }

            Section(
                header: Text("History & Privacy".localized),
                footer: Text("Clearing history removes your viewing progress and recent searches across all devices synced to this account.".localized)
            ) {
                HStack(spacing: 12) {
                    Button(action: {
                        showClearWatchConfirm = true
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "clock.arrow.circlepath")
                            Text("Clear Watch History".localized)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(action: {
                        showClearSearchConfirm = true
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "magnifyingglass")
                            Text("Clear Search History".localized)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.vertical, 2)
            }

            Section(header: Text("About".localized)) {
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
                        Text("Version %@".localizedFormat(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(action: {
                        updateManager.checkForUpdates()
                    }) {
                        Label("Check for Updates…".localized, systemImage: "arrow.triangle.2.circlepath")
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
        .alert("Clear Watch History?".localized, isPresented: $showClearWatchConfirm) {
            Button("Clear All".localized, role: .destructive) {
                UserDataService.shared.clearHistory()
            }
            Button("Cancel".localized, role: .cancel) {}
        } message: {
            Text("This will permanently remove your watch history and continue watching progress across all synced devices.".localized)
        }
        .alert("Clear Search History?".localized, isPresented: $showClearSearchConfirm) {
            Button("Clear All".localized, role: .destructive) {
                RecentSearchManager.shared.clear()
            }
            Button("Cancel".localized, role: .cancel) {}
        } message: {
            Text("This will clear all recent searches and search queries across all synced devices.".localized)
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
    @ObservedObject var languageManager = LanguageManager.shared
    @State private var newAddonUrl = ""
    @State private var isAdding = false
    @State private var isSyncing = false
    @State private var addError: String?
    @State private var showStreamProxySheet = false

    var body: some View {
        Form {
            // Addon Store Banner
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.title2)
                        .foregroundStyle(LinearGradient(colors: [.blue.opacity(0.8), .cyan.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Addon Store & Directory".localized)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                        
                        Text("Explore streaming providers, platforms, and subtitle extensions.".localized)
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
                            Text("Web Store ↗".localized)
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
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Open Flux Addon Web Store in browser with auto-login".localized)
                }
                .padding(.vertical, 4)
            }
            
            // Installed Addons List
            Section(header: HStack {
                Text("Installed Addons (%d)".localizedFormat(addonManager.addons.count))
                
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
                        Text(isSyncing ? "Syncing…".localized : "Refresh".localized)
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
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isSyncing)
                .help("Refresh installed addons from Flux Cloud".localized)
            }) {
                if addonManager.addons.isEmpty {
                    Text("No addons installed.".localized)
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
                                        Text("STOCK".localized)
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
                                .help("Uninstall addon".localized)
                            }
                            
                            // Configure Gear Button (Left of Toggle)
                            if addon.id == "stock.stream-route-proxy" {
                                Button(action: {
                                    showStreamProxySheet = true
                                }) {
                                    Image(systemName: "gearshape.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(.white.opacity(0.75))
                                }
                                .buttonStyle(.borderless)
                                .help("Configure Stream Route Proxy".localized)
                            } else if let configURL = configureURL(for: addon) {
                                Button(action: {
                                    NSWorkspace.shared.open(configURL)
                                }) {
                                    Image(systemName: "gearshape.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(.white.opacity(0.75))
                                }
                                .buttonStyle(.borderless)
                                .help("Configure addon in browser".localized)
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
                    Text("Install Custom Addon".localized)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.white)
                    
                    Text("Paste any manifest URL (e.g. https://domain.com/manifest.json) or stremio:// link".localized)
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
                                Text("Install".localized)
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
                            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
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
        .sheet(isPresented: $showStreamProxySheet) {
            StreamRouteProxyConfigSheet()
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
                .fill(name == "Stream Route Proxy" ? Color.blue.opacity(0.3) : Color.white.opacity(0.1))
                .frame(width: 24, height: 24)
            if name == "Stream Route Proxy" {
                Image(systemName: "network.badge.shield.half.filled")
                    .font(.system(size: 12))
                    .foregroundColor(.cyan)
            } else {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
            }
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

