import SwiftUI

// MARK: - Installed Extensions & Addon Manager View (Zero-Scraper Binary)

struct AddonsView: View {
    @ObservedObject var addonManager = AddonManager.shared
    @State private var searchText = ""
    @State private var showCustomURLModal = false
    
    // Filtered installed addons list
    private var filteredAddons: [StremioAddon] {
        if searchText.isEmpty {
            return addonManager.addons
        }
        let q = searchText.lowercased()
        return addonManager.addons.filter { addon in
            addon.name.lowercased().contains(q) ||
            (addon.description?.lowercased().contains(q) ?? false) ||
            addon.url.lowercased().contains(q)
        }
    }
    
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 28) {
                // Header Bar
                headerView
                
                // Web Store Hero Banner
                webStorePromoBanner
                
                // Installed Addons Header
                HStack(alignment: .center) {
                    Text("Installed Extensions")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    
                    Text("(\(addonManager.addons.count))")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                    
                    Spacer()
                }
                
                // Addon Cards Grid
                if filteredAddons.isEmpty {
                    emptyStateView
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340, maximum: 540), spacing: 20)], spacing: 20) {
                        ForEach(filteredAddons) { addon in
                            InstalledAddonCardView(
                                addon: addon,
                                onToggle: { addonManager.toggleAddon(addon) },
                                onConfigure: { openConfigure(addon: addon) },
                                onUninstall: { addonManager.removeAddon(addon) }
                            )
                        }
                    }
                }
            }
            .padding(.leading, LibraryScheme.leadingPadding)
            .padding(.trailing, LibraryScheme.trailingPadding)
            .padding(.top, LibraryScheme.topPadding)
            .padding(.bottom, LibraryScheme.bottomPadding)
        }
        .sheet(isPresented: $showCustomURLModal) {
            CustomManifestInstallerModal(isPresented: $showCustomURLModal)
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Extensions & Addons")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                
                Text("\(addonManager.addons.count) installed · Stremio-compatible streaming providers, metadata, and subtitles")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            
            Spacer(minLength: 20)
            
            // Search Input
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                
                TextField("Search installed…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .frame(width: 160)
                
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.07))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
            
            // Browse Store (SSO Auto-Login)
            Button(action: {
                addonManager.openWebStore()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "safari")
                        .font(.system(size: 12, weight: .bold))
                    Text("Browse Web Store")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 8)
                .background(
                    LinearGradient(
                        colors: [Color.blue.opacity(0.75), Color.cyan.opacity(0.65)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .foregroundColor(.white)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
                .shadow(color: Color.blue.opacity(0.25), radius: 8, x: 0, y: 2)
            }
            .buttonStyle(.plain)
            .help("Open community addon store in browser with auto-login")
            
            // Install from URL Button (Liquid Glass)
            Button(action: { showCustomURLModal = true }) {
                HStack(spacing: 5) {
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 12, weight: .bold))
                    Text("Install URL")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.12))
                .foregroundColor(.white)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }
    
    // MARK: - Web Store Promo Banner
    
    private var webStorePromoBanner: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.3), Color.cyan.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 54, height: 54)
                
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.cyan, Color.blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Discover Community Streaming & Metadata Extensions")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                
                Text("Visit the Flux Addon Directory on the web to browse verified community providers, torrent indexers, and live TV streams. 1-click install with automatic cloud sync.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
            }
            
            Spacer(minLength: 16)
            
            Button(action: {
                addonManager.openWebStore()
            }) {
                HStack(spacing: 6) {
                    Text("Open Store ↗")
                        .font(.system(size: 12.5, weight: .bold))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Color.white.opacity(0.14))
                .foregroundColor(.white)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.14), Color.white.opacity(0.03)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.3))
            
            Text("No matching extensions")
                .font(.headline)
                .foregroundColor(.white.opacity(0.8))
            
            Text("No installed extensions match \"\(searchText)\".")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
    
    private func openConfigure(addon: StremioAddon) {
        let urlStr = addon.url
        if !urlStr.contains("/configure") && !urlStr.isEmpty {
            if let configureURL = URL(string: "\(urlStr)/configure") {
                NSWorkspace.shared.open(configureURL)
                return
            }
        }
        if let targetURL = URL(string: urlStr) {
            NSWorkspace.shared.open(targetURL)
        }
    }
}

// MARK: - Installed Addon Card View (Liquid Glass)

struct InstalledAddonCardView: View {
    let addon: StremioAddon
    let onToggle: () -> Void
    let onConfigure: () -> Void
    let onUninstall: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                // Addon Logo
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 46, height: 46)
                    
                    if let logoStr = addon.logoURL ?? addon.iconURL, let url = URL(string: logoStr) {
                        CachedImage(url: url, maxDimension: 120) { phase in
                            switch phase {
                            case .success(let img):
                                img
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 36, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            default:
                                fallbackIcon
                            }
                        }
                    } else {
                        fallbackIcon
                    }
                }
                .frame(width: 46, height: 46)
                
                // Name & Version
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(addon.name)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        
                        if addon.isStock {
                            Text("STOCK")
                                .font(.system(size: 9, weight: .heavy))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.indigo.opacity(0.8))
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                        }
                    }
                    
                    HStack(spacing: 6) {
                        Text("v\(addon.version ?? "1.0")")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                        
                        if let cat = addon.category {
                            Text("•")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.3))
                            
                            Text(cat)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
                
                Spacer()
                
                // Active / Disabled Badge
                HStack(spacing: 4) {
                    Circle()
                        .fill(addon.isEnabled ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    
                    Text(addon.isEnabled ? "Active" : "Disabled")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(addon.isEnabled ? .green : .orange)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())
            }
            
            // Description
            Text(addon.description ?? addon.url)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            Divider()
                .background(Color.white.opacity(0.08))
                .padding(.vertical, 2)
            
            // Bottom Action Row
            HStack(spacing: 10) {
                // Enable/Disable Toggle
                Toggle(isOn: Binding(
                    get: { addon.isEnabled },
                    set: { _ in onToggle() }
                )) {
                    Text(addon.isEnabled ? "Enabled" : "Disabled")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .toggleStyle(.switch)
                .labelsHidden()
                
                Spacer()
                
                // Configuration Button
                if !addon.url.isEmpty {
                    Button(action: onConfigure) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(.white.opacity(0.8))
                            .padding(7)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Configure addon")
                }
                
                // Delete Button: ONLY FOR USER ADDONS (Protected for Stock)
                if !addon.isStock {
                    Button(action: onUninstall) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(.red.opacity(0.85))
                            .padding(7)
                            .background(Color.red.opacity(0.12))
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.red.opacity(0.2), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Uninstall addon")
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(isHovered ? 0.08 : 0.04))
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: isHovered
                            ? [Color.white.opacity(0.25), Color.white.opacity(0.10)]
                            : [Color.white.opacity(0.08), Color.white.opacity(0.02)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .onHover { hovering in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                isHovered = hovering
            }
        }
    }
    
    private var fallbackIcon: some View {
        Text(String(addon.name.prefix(1)).uppercased())
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .foregroundColor(.white.opacity(0.85))
    }
}

// MARK: - Custom Manifest Installer Modal

struct CustomManifestInstallerModal: View {
    @Binding var isPresented: Bool
    @ObservedObject var addonManager = AddonManager.shared
    @State private var manifestUrl = ""
    @State private var isValidating = false
    @State private var errorMessage: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Install Custom Addon")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    
                    Text("Paste any Stremio manifest URL or stremio:// link")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                }
                
                Spacer()
                
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            
            // Text Input
            VStack(alignment: .leading, spacing: 8) {
                TextField("https://addon-domain.com/manifest.json", text: $manifestUrl)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(12)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
                
                if let error = errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                        Text(error)
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundColor(.red)
                }
            }
            
            // Actions
            HStack {
                Spacer()
                
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .padding(.trailing, 10)
                
                Button(action: installCustomManifest) {
                    HStack(spacing: 6) {
                        if isValidating {
                            ProgressView()
                                .scaleEffect(0.65)
                                .tint(.white)
                        } else {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 12.5, weight: .bold))
                        }
                        
                        Text(isValidating ? "Validating…" : "Install Addon")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7.5)
                    .background(Color.white.opacity(0.16))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.24), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(manifestUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidating)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0.95))
                .shadow(color: .black.opacity(0.6), radius: 30, x: 0, y: 12)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.25), .white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }
    
    private func installCustomManifest() {
        let cleanURL = manifestUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanURL.isEmpty else { return }
        
        isValidating = true
        errorMessage = nil
        
        Task {
            do {
                try await addonManager.addAddon(url: cleanURL, isStock: false, category: AddonCategory.community.rawValue)
                await MainActor.run {
                    isValidating = false
                    isPresented = false
                }
            } catch {
                await MainActor.run {
                    isValidating = false
                    errorMessage = "Failed to load manifest: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - Deep Link Installation Modal (Floating Glass UI)

struct DeepLinkAddonInstallModal: View {
    @ObservedObject var addonManager = AddonManager.shared
    
    var body: some View {
        if addonManager.showDeepLinkModal, let manifest = addonManager.pendingDeepLinkManifest {
            ZStack {
                // Dimmed Backdrop Blur
                Color.black.opacity(0.65)
                    .ignoresSafeArea()
                    .onTapGesture {
                        addonManager.dismissDeepLinkModal()
                    }
                
                // Floating Glass Card
                VStack(alignment: .leading, spacing: 18) {
                    // Header with Logo + Name + Dismiss
                    HStack(alignment: .top, spacing: 14) {
                        // Addon Logo
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                                .frame(width: 52, height: 52)
                            
                            if let logoStr = manifest.logo ?? manifest.icon, let url = URL(string: logoStr) {
                                CachedImage(url: url, maxDimension: 120) { phase in
                                    switch phase {
                                    case .success(let img):
                                        img
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(width: 42, height: 42)
                                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    default:
                                        fallbackLogo(name: manifest.name)
                                    }
                                }
                            } else {
                                fallbackLogo(name: manifest.name)
                            }
                        }
                        .frame(width: 52, height: 52)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(manifest.name)
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                                
                                if let ver = manifest.version {
                                    Text("v\(ver)")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.6))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.white.opacity(0.1))
                                        .clipShape(Capsule())
                                }
                            }
                            
                            Text("External Addon Installation Request")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        
                        Spacer()
                        
                        Button(action: { addonManager.dismissDeepLinkModal() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                    
                    // Description
                    if let desc = manifest.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(3)
                            .padding(.vertical, 2)
                    }
                    
                    // Permissions & Requested Resources
                    VStack(alignment: .leading, spacing: 8) {
                        Text("REQUESTED CAPABILITIES")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.white.opacity(0.45))
                            .tracking(0.8)
                        
                        HStack(spacing: 8) {
                            if let resources = manifest.resources, !resources.isEmpty {
                                ForEach(resources, id: \.self) { res in
                                    HStack(spacing: 4) {
                                        Image(systemName: iconForResource(res))
                                            .font(.system(size: 10))
                                        Text(res.capitalized)
                                            .font(.system(size: 11, weight: .semibold))
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.white.opacity(0.08))
                                    .foregroundColor(.white.opacity(0.85))
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                }
                            } else {
                                Text("Standard Media Provider")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            Spacer()
                        }
                    }
                    
                    // Manifest Source URL
                    if let urlStr = addonManager.pendingDeepLinkURL {
                        HStack(spacing: 6) {
                            Image(systemName: "link")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.4))
                            Text(urlStr)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    
                    if let error = addonManager.deepLinkError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                            Text(error)
                                .font(.system(size: 11.5))
                        }
                        .foregroundColor(.red)
                    }
                    
                    Divider()
                        .background(Color.white.opacity(0.08))
                    
                    // Action Buttons (Liquid Glass)
                    HStack(spacing: 12) {
                        Button("Cancel") {
                            addonManager.dismissDeepLinkModal()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7.5)
                        .background(Color.white.opacity(0.06))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
                        
                        Spacer()
                        
                        Button(action: {
                            Task {
                                await addonManager.confirmDeepLinkInstallation()
                            }
                        }) {
                            HStack(spacing: 6) {
                                if addonManager.isInstallingDeepLink {
                                    ProgressView()
                                        .scaleEffect(0.65)
                                        .tint(.white)
                                } else {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 12.5, weight: .bold))
                                }
                                Text(addonManager.isInstallingDeepLink ? "Installing…" : "Install Addon")
                                    .font(.system(size: 12.5, weight: .bold))
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 7.5)
                            .background(Color.white.opacity(0.18))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
                            .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 2)
                        }
                        .buttonStyle(.plain)
                        .disabled(addonManager.isInstallingDeepLink)
                    }
                }
                .padding(24)
                .frame(width: 480)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.ultraThinMaterial.opacity(0.95))
                        .shadow(color: .black.opacity(0.7), radius: 32, x: 0, y: 16)
                )
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.25), .white.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.94).combined(with: .opacity),
                    removal: .scale(scale: 0.96).combined(with: .opacity)
                ))
            }
            .zIndex(100)
        }
    }
    
    private func fallbackLogo(name: String) -> some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: 20, weight: .bold, design: .rounded))
            .foregroundColor(.white.opacity(0.9))
    }
    
    private func iconForResource(_ resource: String) -> String {
        switch resource.lowercased() {
        case "stream": return "play.circle.fill"
        case "subtitles": return "captions.bubble.fill"
        case "catalog": return "square.grid.2x2.fill"
        case "meta": return "info.circle.fill"
        default: return "puzzlepiece.extension.fill"
        }
    }
}
