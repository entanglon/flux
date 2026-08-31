import SwiftUI

struct AddonsView: View {
    @ObservedObject var addonManager = AddonManager.shared
    @State private var selectedCategory: AddonCategory = .all
    @State private var searchText = ""
    @State private var showCustomURLModal = false
    @State private var installingAddonIDs: Set<String> = []
    
    // Filtered store catalog items
    private var filteredStoreAddons: [StoreAddonItem] {
        let all = AddonStoreCatalog.curatedAddons
        return all.filter { item in
            let matchesCategory: Bool
            switch selectedCategory {
            case .all:
                matchesCategory = true
            case .installed:
                matchesCategory = addonManager.isAddonInstalled(id: item.id)
            case .official:
                matchesCategory = item.category == .official || item.isStock
            case .streamingServices:
                matchesCategory = item.category == .streamingServices
            case .publicDomain:
                matchesCategory = item.category == .publicDomain
            case .community:
                matchesCategory = item.category == .community
            case .subtitles:
                matchesCategory = item.category == .subtitles
            }
            
            if !matchesCategory { return false }
            
            if searchText.isEmpty { return true }
            let query = searchText.lowercased()
            return item.name.lowercased().contains(query)
                || item.summary.lowercased().contains(query)
                || item.author.lowercased().contains(query)
                || item.tags.contains(where: { $0.lowercased().contains(query) })
        }
    }
    
    // Custom user-installed addons not in the static store catalog
    private var customInstalledAddons: [StremioAddon] {
        let catalogIDs = Set(AddonStoreCatalog.curatedAddons.map { $0.id })
        return addonManager.addons.filter { !catalogIDs.contains($0.id) }
    }
    
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 24) {
                // Header Bar
                headerView
                
                // Category Filter Pills
                categoryFilterBar
                
                // Addon Cards Grid
                if filteredStoreAddons.isEmpty && (selectedCategory != .installed || customInstalledAddons.isEmpty) {
                    emptyStateView
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340, maximum: 540), spacing: 18)], spacing: 18) {
                        // 1. Curated Store Catalog Addons
                        ForEach(filteredStoreAddons) { item in
                            StoreAddonCardView(
                                item: item,
                                installedAddon: addonManager.installedAddon(for: item.id),
                                isInstalling: installingAddonIDs.contains(item.id),
                                onInstall: { installAddon(item) },
                                onToggle: { addon in addonManager.toggleAddon(addon) },
                                onConfigure: { addon in openConfigure(addon: addon, fallback: item.configureURL) },
                                onUninstall: { addon in addonManager.removeAddon(addon) }
                            )
                        }
                        
                        // 2. Custom Installed Addons (if viewing All or Installed)
                        if selectedCategory == .all || selectedCategory == .installed {
                            ForEach(customInstalledAddons) { addon in
                                CustomAddonCardView(
                                    addon: addon,
                                    onToggle: { addonManager.toggleAddon(addon) },
                                    onConfigure: { openConfigure(addon: addon, fallback: nil) },
                                    onUninstall: { addonManager.removeAddon(addon) }
                                )
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 42)
            .padding(.bottom, 60)
        }
        .sheet(isPresented: $showCustomURLModal) {
            CustomManifestInstallerModal(isPresented: $showCustomURLModal)
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.title2)
                        .foregroundStyle(LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                    
                    Text("Addon Store")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                
                Text("\(addonManager.addons.count) installed · Discover streaming providers, metadata, and subtitle extensions")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            
            Spacer()
            
            // Search Input
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                
                TextField("Search extensions…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
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
            .background(Color.white.opacity(0.08))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
            
            // Install from URL Button
            Button(action: { showCustomURLModal = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 13, weight: .bold))
                    Text("Install from URL")
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    LinearGradient(colors: [Color.blue, Color.cyan.opacity(0.85)], startPoint: .leading, endPoint: .trailing)
                )
                .foregroundColor(.white)
                .clipShape(Capsule())
                .shadow(color: Color.blue.opacity(0.3), radius: 8, x: 0, y: 3)
            }
            .buttonStyle(.plain)
        }
    }
    
    // MARK: - Category Filter Bar
    
    private var categoryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(AddonCategory.allCases) { category in
                    let isSelected = selectedCategory == category
                    Button(action: {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                            selectedCategory = category
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: category.icon)
                                .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                            
                            Text(category.rawValue)
                                .font(.system(size: 12.5, weight: isSelected ? .bold : .medium))
                            
                            if category == .installed {
                                Text("\(addonManager.addons.count)")
                                    .font(.system(size: 10.5, weight: .heavy))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(isSelected ? Color.white.opacity(0.25) : Color.white.opacity(0.12))
                                    .clipShape(Capsule())
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7.5)
                        .background(
                            isSelected
                            ? AnyShapeStyle(LinearGradient(colors: [Color.blue, Color.cyan.opacity(0.85)], startPoint: .leading, endPoint: .trailing))
                            : AnyShapeStyle(Color.white.opacity(0.08))
                        )
                        .foregroundColor(isSelected ? .white : .white.opacity(0.75))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().stroke(isSelected ? Color.white.opacity(0.3) : Color.white.opacity(0.06), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.3))
            
            Text("No addons found")
                .font(.headline)
                .foregroundColor(.white.opacity(0.8))
            
            Text(searchText.isEmpty ? "No extensions match the selected category." : "No results for \"\(searchText)\"")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }
    
    // MARK: - Actions
    
    private func installAddon(_ item: StoreAddonItem) {
        installingAddonIDs.insert(item.id)
        Task {
            do {
                try await addonManager.installStoreAddon(item)
                await MainActor.run {
                    installingAddonIDs.remove(item.id)
                }
            } catch {
                print("Failed to install addon \(item.name): \(error.localizedDescription)")
                await MainActor.run {
                    installingAddonIDs.remove(item.id)
                }
            }
        }
    }
    
    private func openConfigure(addon: StremioAddon, fallback: String?) {
        var urlStr = addon.url
        if urlStr.isEmpty, let fallback = fallback {
            urlStr = fallback
        }
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

// MARK: - Curated Store Addon Card

struct StoreAddonCardView: View {
    let item: StoreAddonItem
    let installedAddon: StremioAddon?
    let isInstalling: Bool
    let onInstall: () -> Void
    let onToggle: (StremioAddon) -> Void
    let onConfigure: (StremioAddon) -> Void
    let onUninstall: (StremioAddon) -> Void
    
    @State private var isHovered = false
    
    var isInstalled: Bool {
        installedAddon != nil
    }
    
    var isEnabled: Bool {
        installedAddon?.isEnabled ?? false
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Top Row: Icon + Title + Version + Status
            HStack(alignment: .top, spacing: 14) {
                // Extension Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: item.iconGradient,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 48, height: 48)
                        .shadow(color: item.iconGradient.first?.opacity(0.4) ?? .clear, radius: 8, x: 0, y: 3)
                    
                    Image(systemName: item.iconSymbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white)
                }
                
                // Name & Metadata
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        
                        if item.isStock {
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
                        Text("v\(item.version)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                        
                        Text("•")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.3))
                        
                        Text(item.author)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                
                Spacer()
                
                // Installed Status Capsule
                if isInstalled {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(isEnabled ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                        
                        Text(isEnabled ? "Active" : "Disabled")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(isEnabled ? .green : .orange)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
                }
            }
            
            // Middle: Clean Summary
            Text(item.summary)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            // Tags Row
            HStack(spacing: 6) {
                ForEach(item.tags.prefix(3), id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.08))
                        .foregroundStyle(.white.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                Spacer()
            }
            
            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.vertical, 2)
            
            // Bottom Action Row
            HStack(spacing: 10) {
                if let addon = installedAddon {
                    // Toggle Switch
                    Toggle(isOn: Binding(
                        get: { addon.isEnabled },
                        set: { _ in onToggle(addon) }
                    )) {
                        Text(addon.isEnabled ? "Enabled" : "Disabled")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .toggleStyle(.switch)
                    .labelsHidden()
                    
                    Spacer()
                    
                    // Configure button (if available)
                    if item.configureURL != nil || !addon.url.isEmpty {
                        Button(action: { onConfigure(addon) }) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white.opacity(0.8))
                                .padding(7)
                                .background(Color.white.opacity(0.1))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Configure addon in browser")
                    }
                    
                    // Delete button: ONLY FOR USER-INSTALLED ADDONS (Protected for Stock!)
                    if !addon.isStock {
                        Button(action: { onUninstall(addon) }) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.red.opacity(0.9))
                                .padding(7)
                                .background(Color.red.opacity(0.15))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Uninstall community addon")
                    }
                } else {
                    Spacer()
                    
                    // Install Button
                    Button(action: onInstall) {
                        HStack(spacing: 6) {
                            if isInstalling {
                                ProgressView()
                                    .scaleEffect(0.65)
                                    .tint(.white)
                            } else {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 13, weight: .bold))
                            }
                            
                            Text(isInstalling ? "Installing…" : "Install")
                                .font(.system(size: 12.5, weight: .bold))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(
                            LinearGradient(colors: [Color.blue, Color.cyan.opacity(0.85)], startPoint: .leading, endPoint: .trailing)
                        )
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isInstalling)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(isHovered ? 0.09 : 0.04))
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: isHovered
                            ? [Color.blue.opacity(0.6), Color.cyan.opacity(0.3)]
                            : [Color.white.opacity(0.1), Color.white.opacity(0.02)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isHovered ? 1.5 : 1
                )
        )
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .shadow(color: isHovered ? Color.blue.opacity(0.2) : Color.clear, radius: 10, x: 0, y: 4)
        .onHover { hovering in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Custom User Addon Card (Installed via custom URL)

struct CustomAddonCardView: View {
    let addon: StremioAddon
    let onToggle: () -> Void
    let onConfigure: () -> Void
    let onUninstall: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(colors: [Color.purple, Color.indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 48, height: 48)
                    
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white)
                }
                
                VStack(alignment: .leading, spacing: 3) {
                    Text(addon.name)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    
                    Text("Custom URL Addon • v\(addon.version ?? "1.0")")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
                
                Spacer()
                
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
            
            Text(addon.description ?? addon.url)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.vertical, 2)
            
            HStack(spacing: 10) {
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
                
                if !addon.url.isEmpty {
                    Button(action: onConfigure) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.8))
                            .padding(7)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Configure addon")
                }
                
                if !addon.isStock {
                    Button(action: onUninstall) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.red.opacity(0.9))
                            .padding(7)
                            .background(Color.red.opacity(0.15))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Uninstall custom addon")
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(isHovered ? 0.09 : 0.04))
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: isHovered
                            ? [Color.purple.opacity(0.6), Color.indigo.opacity(0.3)]
                            : [Color.white.opacity(0.1), Color.white.opacity(0.02)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isHovered ? 1.5 : 1
                )
        )
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .onHover { hovering in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                isHovered = hovering
            }
        }
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
                    
                    Text("Paste any Stremio manifest URL (e.g. https://domain.com/manifest.json)")
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
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
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
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13, weight: .bold))
                        }
                        
                        Text(isValidating ? "Validating…" : "Install Addon")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        LinearGradient(colors: [Color.blue, Color.cyan.opacity(0.85)], startPoint: .leading, endPoint: .trailing)
                    )
                    .foregroundColor(.white)
                    .clipShape(Capsule())
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
