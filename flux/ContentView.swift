import SwiftUI

struct ContentView: View {
    @ObservedObject private var languageManager = LanguageManager.shared
    @State private var selectedCategory: SidebarItem? = .home
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @StateObject private var playerManager = PlayerManager.shared
    @State private var path = NavigationPath()
    @ObservedObject private var seasonDropdown = SeasonDropdownController.shared
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 230
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack(alignment: .leading) {
            // MARK: - Full Bleed Detail Content View (Background Layer)
            NavigationStack(path: $path) {
                ZStack {
                    // Global dark mesh background
                    Color.black
                    .ignoresSafeArea()
                    
                    Group {
                        if let selected = selectedCategory {
                            switch selected {
                            case .search: SearchView()
                            case .home: HomeView()
                            case .movies: MoviesView()
                            case .tvShows: TVShowsView()
                            case .trending: TrendingView()
                            case .watchlist: WatchlistView(selectedTab: Binding(get: { selectedCategory ?? .home }, set: { selectedCategory = $0 }))
                            case .collections: CollectionsView(selectedTab: Binding(get: { selectedCategory ?? .home }, set: { selectedCategory = $0 }))
                            case .history: HistoryView()
                            case .downloads: DownloadsView()
                            }
                        } else {
                            HomeView()
                        }
                    }
                }
                .navigationDestination(for: MediaItem.self) { item in
                    DetailView(item: item)
                }
                .navigationDestination(for: CollectionNavigation.self) { nav in
                    CollectionDetailView(collectionID: nav.id)
                }
                .navigationDestination(for: GenreNavigation.self) { genreNav in
                    GenreDetailView(genre: genreNav)
                }
                .navigationDestination(for: MediaListView.ListType.self) { type in
                    MediaListView(type: type)
                }
                .navigationDestination(for: PersonNavigation.self) { person in
                    PersonView(personID: person.id, fallbackName: person.fallbackName)
                }
                .navigationDestination(for: CastListNavigation.self) { nav in
                    CastListView(cast: nav.cast)
                }
                .navigationDestination(for: HistoryNavigation.self) { nav in
                    HistoryView(showAsContinueWatching: nav.showAsContinueWatching)
                }
                .navigationDestination(for: WatchlistNavigation.self) { _ in
                    WatchlistView(selectedTab: Binding(get: { selectedCategory ?? .home }, set: { selectedCategory = $0 }))
                }
            }
            .navigationBarBackButtonHidden(true)
            .toolbarVisibility(.visible, for: .windowToolbar)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .toolbar(removing: .title)
            .windowToolbarFullScreenVisibility(.onHover)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.all, edges: .all)
            // Give PiPManager a way to reopen the player window on expand
            // (openWindow is environment-only; capture it while ContentView lives).
            .onAppear {
                PlayerWindowRouter.openPlayer = { openWindow(id: "player", value: $0) }
            }
            
            // MARK: - System Sidebar Material
            VStack(alignment: .leading, spacing: 0) {                // Traffic light clearance height
                Color.clear
                    .frame(height: 38)
                
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        browseSection
                        librarySection
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                }
                
                Spacer(minLength: 8)

                ProfileFooter()
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
            }
            .frame(width: sidebarWidth)
            .background(
                Color.black.opacity(0.22)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            )
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .overlay(alignment: .trailing) {
                // Sidebar Resizing Drag Handle
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: 8)
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { gesture in
                                let newWidth = sidebarWidth + gesture.translation.width
                                sidebarWidth = min(max(newWidth, 200), 340)
                            }
                    )
            }
            .padding(.leading, 8)
            .padding(.top, 0)
            .padding(.bottom, 10)
            .ignoresSafeArea(.all, edges: .top)
            .transaction { $0.animation = nil }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        // MARK: - Floating Season Dropdown (root-level overlay: above rail + sidebar)
        .coordinateSpace(name: "rootSpace")
        .overlay(alignment: .topLeading) {
            if seasonDropdown.isOpen {
                FloatingSeasonPanel(controller: seasonDropdown)
                    .offset(
                        x: seasonDropdown.anchor.minX,
                        y: seasonDropdown.anchor.maxY + 8
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // MARK: - Floating Glass Deep Link Addon Installer Modal
        .overlay {
            DeepLinkAddonInstallModal()
        }
        .simultaneousGesture(
            SpatialTapGesture()
                .onEnded { value in
                    guard seasonDropdown.isOpen else { return }
                    // Gesture is attached to the root ZStack — location is
                    // already in rootSpace coordinates
                    let p = value.location
                    // Ignore taps on the button and the panel itself
                    if !seasonDropdown.anchor.contains(p),
                       !seasonDropdown.panelFrame.contains(p) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            seasonDropdown.close()
                        }
                    }
                }
        )
        #if os(macOS)
        .background(WindowAccessor { window in
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = .clear
            window.toolbar?.isVisible = true
            window.toolbar?.showsBaselineSeparator = false
            window.standardWindowButton(.closeButton)?.isHidden = false
            window.standardWindowButton(.miniaturizeButton)?.isHidden = false
            window.standardWindowButton(.zoomButton)?.isHidden = false
            window.standardWindowButton(.closeButton)?.alphaValue = 1
            window.standardWindowButton(.miniaturizeButton)?.alphaValue = 1
            window.standardWindowButton(.zoomButton)?.alphaValue = 1
        })
        #endif
        .onChange(of: selectedCategory) {
            path = NavigationPath()
        }
        // NOTE: intentionally no cloud sync here. fluxRefresh means "reload UI".
        // Syncing here re-pulls, re-merges, and re-posts fluxRefresh
        // (applyCloudPayload publishes unconditionally), which self-perpetuates:
        // every cycle cleared all rails caches, refetched ~15 rails per page,
        // and rebuilt every @Published observer — holding scroll at ~10fps.
        // Sync keeps its own triggers: launch, login, becomeActive, Cmd+R,
        // and debounced autosync after local mutations.
        .onReceive(NotificationCenter.default.publisher(for: .fluxRefresh)) { _ in
            Task {
                await TMDBCatalogCacheActor.shared.clear()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fluxNavigate)) { note in
            guard let target = note.object as? SidebarItem else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                selectedCategory = target
                path = NavigationPath()
            }
            // Cmd+F while already on Search: nothing remounts (so onAppear never
            // refires) — focus the field explicitly instead. Navigating in from
            // another page is covered by SearchView.onAppear.
            if target == .search {
                NotificationCenter.default.post(name: .fluxFocusSearch, object: nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await AuthManager.shared.syncNowAsync(forcePull: true)
            }
        }
    }

    // MARK: - Sidebar Sections (Apple TV / Music SF Symbols)

    private var browseSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sidebarRow(.search, title: L10n.tr("Search"), icon: "magnifyingglass", fillIcon: "magnifyingglass")
            sidebarRow(.home, title: L10n.tr("Home"), icon: "house", fillIcon: "house.fill")
            sidebarRow(.movies, title: L10n.tr("Movies"), icon: "film", fillIcon: "film.fill")
            sidebarRow(.tvShows, title: L10n.tr("TV Shows"), icon: "tv", fillIcon: "tv.fill")
            sidebarRow(.trending, title: L10n.tr("Trending"), icon: "chart.line.uptrend.xyaxis", fillIcon: "chart.line.uptrend.xyaxis")
        }
    }
    
    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr("Library"))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.leading, 10)
                .padding(.bottom, 2)
                .padding(.top, 4)
            
            sidebarRow(.watchlist, title: L10n.tr("Watchlist"), icon: "bookmark", fillIcon: "bookmark.fill")
            sidebarRow(.collections, title: L10n.tr("Collections"), icon: "rectangle.stack", fillIcon: "rectangle.stack.fill")
            sidebarRow(.history, title: L10n.tr("History"), icon: "clock", fillIcon: "clock.fill")
            sidebarRow(.downloads, title: L10n.tr("Downloads"), icon: "arrow.down.circle", fillIcon: "arrow.down.circle.fill")
        }
    }
    
    @ViewBuilder
    private func sidebarRow(_ item: SidebarItem, title: String, icon: String, fillIcon: String) -> some View {
        let isSelected = selectedCategory == item
        
        Button(action: {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                path = NavigationPath()
                selectedCategory = item
            }
        }) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? fillIcon : icon)
                    .font(.system(size: 15, weight: isSelected ? .bold : .medium))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.68))
                    .frame(width: 22, alignment: .center)
                
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .bold : .semibold))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.82))
                
                Spacer()
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
            .if(isSelected) { view in
                view.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 10))
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView()
}

/// Current local profile identity — click returns to the profile picker.
struct ProfileFooter: View {
    @ObservedObject var profileManager = ProfileManager.shared
    @State private var showingPinPrompt = false

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if profileManager.requiresPinToExit {
                    showingPinPrompt = true
                } else {
                    profileManager.switchToProfileSelection()
                }
            } label: {
                HStack(spacing: 10) {
                    if let profile = profileManager.currentProfile {
                        AvatarBadge(avatarID: profile.avatarID, size: 28)

                        Text(profile.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .foregroundStyle(.white.opacity(0.9))

                        if profile.isKids {
                            Text("KIDS".localized)
                                .font(.system(size: 8, weight: .heavy, design: .rounded))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.yellow))
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Switch profile".localized)
            .sheet(isPresented: $showingPinPrompt) {
                PINEntrySheet(mode: .verify(
                    title: "Parental PIN".localized,
                    subtitle: "Enter the 4-digit PIN to exit Kids Profile".localized,
                    profileId: profileManager.currentProfile?.id,
                    onSuccess: {
                        profileManager.switchToProfileSelection()
                    }
                ))
            }

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)".localized)
        }
    }
}

#if os(macOS)
import AppKit

struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                self.configure(window)
                
                let center = NotificationCenter.default
                let names: [Notification.Name] = [
                    NSWindow.willEnterFullScreenNotification,
                    NSWindow.didEnterFullScreenNotification,
                    NSWindow.willExitFullScreenNotification,
                    NSWindow.didExitFullScreenNotification,
                    NSWindow.didResizeNotification
                ]
                for name in names {
                    center.addObserver(forName: name, object: window, queue: .main) { _ in
                        self.configure(window)
                    }
                }
            }
        }
        return view
    }
    
    private func configure(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        
        callback(window)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
