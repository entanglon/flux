import SwiftUI

struct DetailView: View {
    let item: MediaItem
    @Environment(\.dismiss) private var dismiss
    @State private var fullItem: MediaItem?
    @State private var selectedSeason: Season?
    @State private var showSeasonDropdown = false
    @State private var episodes: [Episode] = []
    @State private var relatedItems: [MediaItem] = []
    @State private var heroEpisode: Episode?
    @State private var isLoadingDetails = true
    
    // Derived IDs
    @State private var activeImdbID: String? = nil
    @ObservedObject private var dataManager = DataManager.shared
    @ObservedObject private var userData = UserDataService.shared
    @ObservedObject private var tasteProfile = TasteProfileManager.shared
    @State private var isDownloading = false
    @State private var showCollectionsPopover = false
    @State private var trailerURL: URL? = nil
    @State private var bonusContent: [BonusContentItem] = []
    @Environment(\.openWindow) private var openWindow
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 230
    
    // Computed
    var displayItem: MediaItem { fullItem ?? item }
    
    private var isReleased: Bool {
        guard let dateString = displayItem.releaseDate else { return true }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = formatter.date(from: dateString) { return date <= Date() }
        return true
    }
    
    @State private var scrollOffsetY: CGFloat = 0
    
    var topBarOpacity: Double {
        let offset = -scrollOffsetY
        if offset <= 0 { return 0 }
        return min(1.0, Double(offset / 150.0))
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                LazyVStack(spacing: 0) {
                    GeometryReader { innerGeo in
                        Color.clear.preference(
                            key: DetailScrollOffsetKey.self,
                            value: innerGeo.frame(in: .named("detailScrollSpace")).minY
                        )
                    }
                    .frame(height: 0)
                    // MARK: - 1. Immersive Hero (60% Height)
                    ZStack(alignment: .bottomLeading) {
                        // Background Image
                        ZStack {
                            // Unified Banner Layer
                            // We use a single CachedImage that tracks displayItem.heroURL.
                            // Since displayItem defaults to fullItem ?? item, this handles the transition
                            // from initial metadata to enriched metadata seamlessly without a view swap.
                            CachedImage(url: displayItem.heroURL ?? displayItem.backdropURL ?? item.imageURL, maxDimension: 1920) { phase in
                                if let image = phase.image {
                                    HeroBackdrop.banner(
                                        image: image,
                                        width: geo.size.width,
                                        height: geo.size.height * 0.80,
                                        sidebarWidth: sidebarWidth
                                    )
                                    .transition(.opacity.animation(.easeInOut(duration: 0.5)))
                                } else {
                                    Rectangle().fill(Color(white: 0.1))
                                }
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height * 0.80)
                        .clipped()
                        
                        // Gradient Mesh Overlay
                        ZStack {
                            // Bottom Gradient
                            LinearGradient(gradient: Gradient(colors: [
                                .black.opacity(0.0),
                                .black.opacity(0.4),
                                .black.opacity(0.8),
                                .black
                            ]), startPoint: .top, endPoint: .bottom)
                            
                            // Left Side Gradient (Darker for Text)
                            LinearGradient(gradient: Gradient(colors: [
                                .black.opacity(0.9),
                                .black.opacity(0.6),
                                .clear
                            ]), startPoint: .leading, endPoint: .center)
                        }
                        
                        // Hero Content Overlay
                        VStack(alignment: .leading, spacing: 16) {
                            // 1. Dynamic Eyebrow
                            if !isReleased {
                                Text(displayItem.upcomingBadgeText)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(Color.white.opacity(0.18)))
                                    .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1))
                            } else {
                                Text(displayItem.genres?.first?.uppercased() ?? displayItem.category.uppercased())
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .tracking(1.5)
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                            
                            // Title
                            Text(displayItem.title)
                                .font(.system(size: 64, weight: .heavy, design: .default))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .shadow(radius: 10)
                            
                            // Metadata Row
                            HStack(spacing: 6) {
                                Text(displayItem.category)
                                if let genres = displayItem.genres, !genres.isEmpty {
                                    Text("•")
                                    Text(genres.prefix(2).joined(separator: ", "))
                                }
                                if let voteAvg = displayItem.voteAverage, voteAvg > 0 {
                                    Text("•")
                                    HStack(spacing: 2) {
                                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                                        Text(String(format: "%.1f", voteAvg))
                                    }
                                }
                                TechBadge(text: "4K")
                                TechBadge(text: "DOLBY VISION")
                                TechBadge(text: "ATMOS")
                                TechBadge(text: "CC")
                            }
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white.opacity(0.9))
                            
                            // Hero Description
                            Text(displayItem.description)
                                .font(.body)
                                .lineLimit(3)
                                .lineSpacing(4)
                                .foregroundStyle(.white.opacity(0.8))
                                .frame(maxWidth: 600, alignment: .leading)
                                .padding(.top, 4)
                            
                            // Action Buttons
                            HStack(spacing: 16) {
                                if isReleased {
                                    let progress = getEpisodeProgress(heroEpisode)
                                    
                                    Button(action: {
                                        PlayerManager.shared.play(displayItem, season: heroEpisode?.seasonNumber, episode: heroEpisode?.episodeNumber, episodeImage: heroEpisode?.stillURL)
                                        openWindow(id: "player", value: displayItem.id)
                                    }) {
                                        if progress > 0 && progress < 0.95 {
                                            HStack(spacing: 12) {
                                                Image(systemName: "play.fill")
                                                    .font(.headline)
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text("Resume Episode")
                                                        .font(.subheadline).fontWeight(.bold)
                                                    ZStack(alignment: .leading) {
                                                        Capsule().fill(Color.white.opacity(0.3)).frame(width: 100, height: 4)
                                                        Capsule().fill(Color.white).frame(width: 100 * progress, height: 4)
                                                    }
                                                }
                                            }
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 24)
                                            .padding(.vertical, 10)
                                        } else {
                                            Text(displayItem.category == "Movie" ? "Play Movie" : "Play Episode")
                                                .font(.headline)
                                                .fontWeight(.bold)
                                                .foregroundStyle(.black)
                                                .padding(.horizontal, 40)
                                                .padding(.vertical, 14)
                                                .background(Color.white)
                                                .clipShape(Capsule())
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    
                                    Button(action: {
                                        userData.toggleWatchlist(displayItem)
                                    }) {
                                        Image(systemName: userData.isInWatchlist(displayItem) ? "checkmark" : "plus")
                                            .font(.title3)
                                            .foregroundStyle(.white)
                                            .padding(14)
                                            .glassEffect(.regular.interactive(), in: .circle)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help(userData.isInWatchlist(displayItem) ? "In Watchlist" : "Add to Watchlist")
                                    .accessibilityLabel(userData.isInWatchlist(displayItem) ? "Remove from Watchlist" : "Add to Watchlist")

                                    // Mark as Watched / Unwatched toggle
                                    Button(action: {
                                        withAnimation(.spring(duration: 0.25)) {
                                            userData.toggleWatched(displayItem)
                                        }
                                    }) {
                                        Image(systemName: userData.isWatched(displayItem) ? "eye.fill" : "eye")
                                            .font(.title3)
                                            .foregroundStyle(userData.isWatched(displayItem) ? Color.cyan : .white)
                                            .padding(14)
                                            .glassEffect(.regular.interactive(), in: .circle)
                                            .symbolEffect(.bounce, value: userData.isWatched(displayItem))
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help(userData.isWatched(displayItem) ? "Mark as unwatched" : "Mark as watched")
                                    .accessibilityLabel(userData.isWatched(displayItem) ? "Mark as unwatched" : "Mark as watched")

                                    // Love — strongest taste signal for the For You rail
                                    Button(action: {
                                        tasteProfile.toggleLove(displayItem)
                                    }) {
                                        Image(systemName: tasteProfile.isLoved(displayItem) ? "heart.fill" : "heart")
                                            .font(.title3)
                                            .foregroundStyle(tasteProfile.isLoved(displayItem) ? Color.pink : .white)
                                            .padding(14)
                                            .glassEffect(.regular.interactive(), in: .circle)
                                            .symbolEffect(.bounce, value: tasteProfile.isLoved(displayItem))
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help(tasteProfile.isLoved(displayItem) ? "Loved" : "Love this")

                                    // Custom user lists (Collections)
                                    Button(action: { showCollectionsPopover = true }) {
                                        Image(systemName: "rectangle.stack.badge.plus")
                                            .font(.title3)
                                            .foregroundStyle(.white)
                                            .padding(14)
                                            .glassEffect(.regular.interactive(), in: .circle)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .popover(isPresented: $showCollectionsPopover, arrowEdge: .bottom) {
                                        AddToCollectionView(item: displayItem)
                                    }
                                    .help("Add to list")

                                    // Download best stream for offline viewing
                                    Button {
                                        isDownloading = true
                                        Task {
                                            await downloadBestStream()
                                            isDownloading = false
                                        }
                                    } label: {
                                        Group {
                                            if isDownloading {
                                                ProgressView().controlSize(.small)
                                                    .frame(width: 18, height: 18)
                                            } else {
                                                Image(systemName: "arrow.down.circle")
                                                    .font(.title3)
                                                    .foregroundStyle(.white)
                                            }
                                        }
                                        .padding(14)
                                        .glassEffect(.regular.interactive(), in: .circle)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isDownloading)
                                    .help("Download best stream for offline")

                                    // Play Trailer in Flux Native Player
                                    if !bonusContent.isEmpty || trailerURL != nil {
                                        Button {
                                            if let firstTrailer = bonusContent.first(where: { $0.categoryType == "Trailer" || $0.categoryType == "Teaser" }) ?? bonusContent.first {
                                                playBonusContent(firstTrailer)
                                            } else if let trailer = trailerURL {
                                                NSWorkspace.shared.open(trailer)
                                            }
                                        } label: {
                                            Image(systemName: "play.rectangle.fill")
                                                .font(.title3)
                                                .foregroundStyle(.white)
                                                .padding(14)
                                                .glassEffect(.regular.interactive(), in: .circle)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .help("Play trailer in Flux")
                                    }
                                } else {
                                    // UPCOMING CONTENT MASTER LAYOUT (Apple TV style)
                                    Button(action: {
                                        userData.toggleWatchlist(displayItem)
                                    }) {
                                        HStack(spacing: 10) {
                                            Image(systemName: userData.isInWatchlist(displayItem) ? "checkmark" : "plus")
                                                .font(.system(size: 15, weight: .bold))
                                            Text(userData.isInWatchlist(displayItem) ? "In Watchlist" : "Add to Watchlist")
                                                .font(.system(size: 15, weight: .bold))
                                        }
                                        .foregroundStyle(.black)
                                        .padding(.horizontal, 32)
                                        .padding(.vertical, 14)
                                        .background(Color.white)
                                        .clipShape(Capsule())
                                        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                                    }
                                    .buttonStyle(.plain)

                                    // Love button
                                    Button(action: {
                                        tasteProfile.toggleLove(displayItem)
                                    }) {
                                        Image(systemName: tasteProfile.isLoved(displayItem) ? "heart.fill" : "heart")
                                            .font(.title3)
                                            .foregroundStyle(tasteProfile.isLoved(displayItem) ? Color.pink : .white)
                                            .padding(14)
                                            .glassEffect(.regular.interactive(), in: .circle)
                                            .symbolEffect(.bounce, value: tasteProfile.isLoved(displayItem))
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help(tasteProfile.isLoved(displayItem) ? "Loved" : "Love this")

                                    // Custom user lists (Collections)
                                    Button(action: { showCollectionsPopover = true }) {
                                        Image(systemName: "rectangle.stack.badge.plus")
                                            .font(.title3)
                                            .foregroundStyle(.white)
                                            .padding(14)
                                            .glassEffect(.regular.interactive(), in: .circle)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .popover(isPresented: $showCollectionsPopover, arrowEdge: .bottom) {
                                        AddToCollectionView(item: displayItem)
                                    }
                                    .help("Add to list")

                                    // Play Trailer Button
                                    if !bonusContent.isEmpty || trailerURL != nil {
                                        Button {
                                            if let firstTrailer = bonusContent.first(where: { $0.categoryType == "Trailer" || $0.categoryType == "Teaser" }) ?? bonusContent.first {
                                                playBonusContent(firstTrailer)
                                            } else if let trailer = trailerURL {
                                                NSWorkspace.shared.open(trailer)
                                            }
                                        } label: {
                                            HStack(spacing: 8) {
                                                Image(systemName: "play.rectangle.fill")
                                                    .font(.title3)
                                                Text("Trailer")
                                                    .font(.system(size: 14, weight: .bold))
                                            }
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 20)
                                            .padding(.vertical, 12)
                                            .glassEffect(.regular.interactive(), in: .capsule)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Play trailer in Flux")
                                    }
                                }
                            }
                            .padding(.top, 10)
                        }
                        .padding(.leading, 268)
                        .padding(.bottom, 60)
                    }
                    .frame(height: geo.size.height * 0.80)
                    
                    VStack(alignment: .leading, spacing: 40) {
                        // Ghost rails while metadata loads
                        if isLoadingDetails {
                            VStack(alignment: .leading, spacing: 44) {
                                if item.category == "TV Show" {
                                    GhostRail(posterWidth: 380, ratio: 16/9)
                                }
                                GhostRail(posterWidth: 300, ratio: 16/9)
                                GhostRail()
                                GhostGrid()
                            }
                        } else if isReleased && displayItem.category == "TV Show" {
                            VStack(alignment: .leading, spacing: 16) {
                                if let seasons = displayItem.seasons, !seasons.isEmpty {
                                    let regularSeasons = seasons.filter { $0.seasonNumber > 0 && !$0.name.lowercased().contains("special") }
                                    if !regularSeasons.isEmpty {
                                        // Floating dropdown trigger — the panel itself
                                        // renders at ContentView's root overlay (above
                                        // rail + sidebar), positioned via this frame.
                                        Button {
                                            SeasonDropdownController.shared.seasons = regularSeasons
                                            SeasonDropdownController.shared.selectedName = selectedSeason?.name ?? regularSeasons.first?.name ?? "Season 1"
                                            SeasonDropdownController.shared.onSelect = { season in
                                                selectedSeason = season
                                                Task { await loadEpisodes(for: season) }
                                                // Re-prime the pipeline for the newly selected season (S{n}E1)
                                                PlayerManager.shared.startDetailPrefetch(
                                                    item: displayItem,
                                                    season: season.seasonNumber,
                                                    episode: 1
                                                )
                                            }
                                            withAnimation(.easeInOut(duration: 0.18)) {
                                                SeasonDropdownController.shared.toggle()
                                            }
                                        } label: {
                                            HStack(spacing: 8) {
                                                Text(selectedSeason?.name ?? regularSeasons.first?.name ?? "Season 1")
                                                    .font(.headline)
                                                    .fontWeight(.bold)
                                                    .foregroundStyle(.white)
                                                Image(systemName: "chevron.down")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .rotationEffect(.degrees(SeasonDropdownController.shared.isOpen ? 180 : 0))
                                            }
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                            .glassEffect(.regular.interactive(), in: .capsule)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .background(
                                            GeometryReader { geo in
                                                // Direct write to the controller — PreferenceKey
                                                // values don't propagate out of pushed NavigationStack
                                                // views reliably on macOS
                                                Color.clear
                                                    .onAppear {
                                                        SeasonDropdownController.shared.anchor = geo.frame(in: .named("rootSpace"))
                                                    }
                                                    .onChange(of: geo.frame(in: .named("rootSpace"))) { _, frame in
                                                        SeasonDropdownController.shared.anchor = frame
                                                    }
                                            }
                                        )
                                        .padding(.leading, 268)
                                    }
                                }
                                
                                DetailRail(items: episodes, idPath: \.id, itemWidth: 380, itemHeight: 214) { episode in
                                    Button(action: {
                                        PlayerManager.shared.play(displayItem, season: selectedSeason?.seasonNumber, episode: episode.episodeNumber, episodeImage: episode.stillURL)
                                        openWindow(id: "player", value: displayItem.id)
                                    }) {
                                        LiquidEpisodeCard(episode: episode, progress: getEpisodeProgress(episode), item: displayItem)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        
                        if !bonusContent.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Bonus Content")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.white)
                                    .padding(.leading, 268)
                                    .padding(.trailing, 60)

                                DetailRail(items: bonusContent, idPath: \.id, itemWidth: 300, itemHeight: 169) { item in
                                    Button {
                                        playBonusContent(item)
                                    } label: {
                                        BonusContentCard(item: item, fallbackBackdropURL: displayItem.backdropURL ?? displayItem.heroURL)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        
                        if !relatedItems.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                ListSectionHeader(title: "Related", value: MediaListView.ListType.fixed(title: "Related", items: relatedItems))
                                    .padding(.leading, 268)
                                    .padding(.trailing, 60)
                                
                                DetailRail(items: relatedItems, idPath: \.id, itemWidth: 160, itemHeight: 240) { item in
                                   NavigationLink(value: item) {
                                       GlassCard(item: item, aspectRatio: .portrait, showTitle: false)
                                           .frame(width: 160, height: 240)
                                   }
                                   .buttonStyle(.plain)
                                }
                            }
                        }
                        
                        if let cast = displayItem.cast, !cast.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                ListSectionHeader(title: "Cast & Crew", value: CastListNavigation(cast: cast))
                                    .padding(.leading, 268)
                                    .padding(.trailing, 60)

                                DetailRail(items: cast, idPath: \.id, itemWidth: 100, itemHeight: 200) { member in
                                    NavigationLink(value: PersonNavigation(id: member.personID ?? 0, fallbackName: member.name)) {
                                        VStack(spacing: 8) {
                                            CastCircle(name: member.name, imageURL: member.imageURL, size: 80)

                                            // Fixed-height text block keeps every
                                            // circle on the same axis
                                            VStack(spacing: 2) {
                                                Text(member.name)
                                                    .font(.caption)
                                                    .fontWeight(.bold)
                                                    .foregroundStyle(.white)
                                                    .multilineTextAlignment(.center)
                                                    .lineLimit(1)
                                                Text(member.role ?? "")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                    .multilineTextAlignment(.center)
                                                    .lineLimit(1)
                                            }
                                            .frame(height: 44)
                                        }
                                        .frame(width: 100)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(member.personID == nil)
                                }
                            }
                        }

                        Divider().background(Color.white.opacity(0.1))

                        // Where to Watch (JustWatch Bridge)
                        if let providers = displayItem.watchProviders, !providers.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("Where to Watch")
                                    .font(.title3)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.white)
                                
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 20) {
                                        ForEach(providers) { provider in
                                            VStack(spacing: 8) {
                                                CachedImage(url: provider.logoURL) { phase in
                                                    if let image = phase.image {
                                                        image
                                                            .resizable()
                                                            .aspectRatio(contentMode: .fill)
                                                            .frame(width: 60, height: 60)
                                                            .cornerRadius(12)
                                                    } else {
                                                        RoundedRectangle(cornerRadius: 12)
                                                            .fill(Color.gray.opacity(0.3))
                                                            .frame(width: 60, height: 60)
                                                    }
                                                }
                                                
                                                Text(provider.name)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                            .frame(width: 80)
                                        }
                                    }
                                }
                            }
                            .padding(.leading, 268)
                            .padding(.trailing, 60)
                        } else {
                            // Fallback to Search Link
                            VStack(alignment: .leading, spacing: 16) {
                                Text("Where to Watch")
                                    .font(.title3)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.white)
                                
                                Link(destination: URL(string: "https://www.justwatch.com/us/search?q=\(displayItem.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!) {
                                    HStack(spacing: 16) {
                                        Image(systemName: "magnifyingglass.circle.fill")
                                            .font(.system(size: 40))
                                            .foregroundStyle(.blue)
                                        
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Find on JustWatch")
                                                .font(.headline)
                                                .foregroundStyle(.white)
                                            Text("Check region-specific availability and providers")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.up.forward.app")
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(20)
                                    .background(Color(white: 0.12))
                                    .cornerRadius(16)
                                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.leading, 268)
                            .padding(.trailing, 60)
                        }

                        VStack(alignment: .leading, spacing: 16) {
                            Text("About")
                                .font(.title3)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                            
                            VStack(alignment: .leading, spacing: 12) {
                                Text(displayItem.title)
                                    .font(.headline)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.white)
                                
                                Text(displayItem.genres?.joined(separator: ", ").uppercased() ?? "DRAMA")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                
                                Text(displayItem.description)
                                    .font(.body)
                                    .lineSpacing(4)
                                    .foregroundStyle(.white.opacity(0.9))
                                    .padding(.top, 4)
                            }
                            .padding(24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(white: 0.12))
                            .cornerRadius(16)
                        }
                        .padding(.leading, 268)
                        .padding(.trailing, 60)
                        
                        HStack(alignment: .top, spacing: 60) {
                            VStack(alignment: .leading, spacing: 20) {
                                Text("Information")
                                    .font(.headline).fontWeight(.semibold)
                                    .foregroundStyle(.white)
                                
                                VStack(alignment: .leading, spacing: 16) {
                                    InfoDetailRow(label: "Released", value: displayItem.releaseDate ?? "2025")
                                    InfoDetailRow(label: "Director", value: displayItem.director ?? "N/A")
                                    InfoDetailRow(label: "Runtime", value: displayItem.runtime ?? "N/A")
                                    InfoDetailRow(label: "Region of Origin", value: displayItem.originCountry ?? "United States")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            
                            VStack(alignment: .leading, spacing: 20) {
                                Text("Languages")
                                    .font(.headline).fontWeight(.semibold)
                                    .foregroundStyle(.white)
                                
                                VStack(alignment: .leading, spacing: 16) {
                                    InfoDetailRow(label: "Original Audio", value: "English")
                                    InfoDetailRow(label: "Audio", value: displayItem.spokenLanguages?.joined(separator: ", ") ?? "English")
                                    InfoDetailRow(label: "Subtitles", value: displayItem.spokenLanguages?.joined(separator: ", ") ?? "English")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            
                            VStack(alignment: .leading, spacing: 20) {
                                Text("Accessibility")
                                    .font(.headline).fontWeight(.semibold)
                                    .foregroundStyle(.white)
                                
                                VStack(alignment: .leading, spacing: 16) {
                                    InfoDetailBlock(label: "SDH", value: "Subtitles for the deaf and hard of hearing (SDH) refer to subtitles in the original language with the addition of relevant non-dialogue information.")
                                    InfoDetailBlock(label: "AD", value: "Audio descriptions (AD) refer to a narration track describing what is happening on screen, to provide context for those who are blind or have low vision.")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.leading, 268)
                        .padding(.trailing, 60)
                        .padding(.bottom, 80)
                    }
                    .background(Color.black.opacity(0.5))
                }
            }
            .coordinateSpace(name: "detailScrollSpace")
            .onPreferenceChange(DetailScrollOffsetKey.self) { value in
                self.scrollOffsetY = value
            }
            .ignoresSafeArea(edges: .top)
        }
        .background(
            Color.black
        )
        .overlay(alignment: .topLeading) {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .padding(.leading, 268)
            .padding(.top, 14)
        }
        .navigationBarBackButtonHidden(true)
        .toolbarVisibility(.hidden, for: .windowToolbar)
        .task {
            await loadDetails()
            prefetchPlaybackSources()
        }
        .onDisappear {
            PlayerManager.shared.cancelDetailPrefetch()
        }
    }

    private func playBonusContent(_ item: BonusContentItem) {
        if let episode = item.episode {
            PlayerManager.shared.play(displayItem, season: 0, episode: episode.episodeNumber, episodeImage: episode.stillURL)
            openWindow(id: "player", value: displayItem.id)
        } else if let url = item.youtubeURL {
            NSWorkspace.shared.open(url)
        }
    }

    /// ADVANCED LOADING: kick off source resolution the moment the page opens.
    /// Non-Flux → picker is instant on Play. Flux Mode → best source resolved,
    /// primed and held buffered in a warm mpv core so Play starts instantly.
    private func prefetchPlaybackSources() {
        let seasonNumber = selectedSeason?.seasonNumber ?? heroEpisode?.seasonNumber
        let episodeNumber = heroEpisode?.episodeNumber ?? (seasonNumber != nil ? 1 : nil)
        PlayerManager.shared.startDetailPrefetch(
            item: displayItem,
            season: seasonNumber,
            episode: episodeNumber
        )
    }
    
    func getEpisodeProgress(_ episode: Episode?) -> Double {
        return 0.0
    }
    
    private func loadDetails() async {
        do {
            SeasonDropdownController.shared.close()
            let type = item.category == "TV Show" ? "series" : "movie"
            var fetchID = item.id
            
            // 1. ID Translation Layer (TMDB -> IMDb)
            // If the ID is purely numerical, it's a TMDB ID and needs translation for Stremio
            if CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: item.id)) {
                if let translatedID = await TMDBEnricher.shared.getImdbID(tmdbID: item.id, type: type) {
                    fetchID = translatedID
                }
            }
            
            self.activeImdbID = fetchID
            
            // 2. Fetch Enriched Metadata (Internally handles TMDB if available)
            let detailedItem = try await StremioService.shared.fetchMeta(type: type, id: fetchID)
            
            var merged = detailedItem
            if !item.description.isEmpty {
                merged.description = item.description
            }
            if let genres = item.genres, !genres.isEmpty {
                merged.genres = genres
            }
            if let voteAverage = item.voteAverage, voteAverage > 0 {
                merged.voteAverage = voteAverage
            }
            if let releaseDate = item.releaseDate, !releaseDate.isEmpty {
                merged.releaseDate = releaseDate
            }
            if item.heroURL != nil { merged.heroURL = item.heroURL }
            if item.backdropURL != nil { merged.backdropURL = item.backdropURL }
            if item.posterURL != nil { merged.posterURL = item.posterURL }
            
            await MainActor.run {
                self.fullItem = merged
            }
            
            if type == "series" {
                let regularSeasons = merged.seasons?.filter { $0.seasonNumber > 0 && !$0.name.lowercased().contains("special") } ?? []
                if let first = regularSeasons.first ?? merged.seasons?.first {
                    selectedSeason = first
                    
                    // Track TMDB ID for sub-enrichment (episodes)
                    if let imdbID = merged.id.starts(with: "tt") ? merged.id : nil {
                        if let tmdbID = await TMDBEnricher.shared.resolveTmdbID(imdbID: imdbID, type: "tv") {
                             UserDefaults.standard.set(tmdbID, forKey: "activeTMDBID")
                        }
                    }
                    
                    await loadEpisodes(for: first)
                }
            }
            
            async let fetchedBonusTask = TMDBEnricher.shared.fetchBonusContent(item: merged, fullItem: merged)
            async let tmdbSimilarTask = TMDBEnricher.shared.fetchSimilar(item: merged)
            
            let (fetchedBonus, tmdbSimilar) = await (fetchedBonusTask, tmdbSimilarTask)
            
            self.bonusContent = fetchedBonus
            if let bestTrailer = fetchedBonus.first(where: { $0.categoryType == "Trailer" || $0.categoryType == "Teaser" }),
               let key = bestTrailer.videoKey {
                self.trailerURL = URL(string: "https://www.youtube.com/watch?v=\(key)")
            }
            
            if !tmdbSimilar.isEmpty {
                relatedItems = Array(tmdbSimilar.filter { $0.id != merged.id }.prefix(12))
            } else {
                let related = try? await StremioService.shared.fetchRelated(type: type, genres: merged.genres)
                relatedItems = Array(related?.filter { $0.id != merged.id }.shuffled().prefix(10) ?? [])
            }

            await MainActor.run {
                self.isLoadingDetails = false
            }
        } catch {
            print("Error loading detailed metadata: \(error)")
            await MainActor.run {
                self.isLoadingDetails = false
            }
        }
    }
    
    private func loadEpisodes(for season: Season) async {
        guard let allEpisodes = fullItem?.episodes else { return }
        let currentSeasonEpisodes = allEpisodes.filter { $0.seasonNumber == season.seasonNumber }
            .sorted { $0.episodeNumber < $1.episodeNumber }
        
        // Initial set to show something immediately
        await MainActor.run {
            self.episodes = currentSeasonEpisodes
            if let first = currentSeasonEpisodes.first { heroEpisode = first }
        }
        
        // Background Enrichment: Fetch descriptions automatically
        if let id = fullItem?.id, id.hasPrefix("tt"),
           let tmdbID = await TMDBEnricher.shared.resolveTmdbID(imdbID: id, type: "tv") {
            
            let enrichedOverviews = await TMDBEnricher.shared.fetchSeasonEnrichment(tvId: tmdbID, seasonNumber: season.seasonNumber)
            
            if !enrichedOverviews.isEmpty {
                await MainActor.run {
                    self.episodes = currentSeasonEpisodes.map { episode in
                        var enriched = episode
                        if let overview = enrichedOverviews[episode.episodeNumber], !overview.isEmpty {
                            enriched.overview = overview
                        }
                        return enriched
                    }
                }
            }
        }
    }
}

// MARK: - Helper Components
struct TechBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.4), lineWidth: 1))
    }
}

struct InfoDetailRow: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline).foregroundStyle(.white)
        }
    }
}

struct InfoDetailBlock: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.headline).foregroundStyle(.white)
            Text(value).font(.caption).lineSpacing(3).foregroundStyle(.secondary)
        }
    }
}

struct LiquidEpisodeCard: View {
    let episode: Episode
    let progress: Double // 0.0 to 1.0
    var item: MediaItem? = nil
    @State private var isHovering = false
    @ObservedObject private var userData = UserDataService.shared
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // 1. Background Image
            AsyncImage(url: episode.stillURL) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(Color(white: 0.1))
            }
            .frame(width: 380, height: 214)
            .clipped()
            
            // 2. Liquid Glass Overlay
            LinearGradient(colors: [
                .black.opacity(0.1),
                .black.opacity(0.4),
                .black.opacity(0.8),
                .black.opacity(0.95)
            ], startPoint: .top, endPoint: .bottom)
            
            // 3. Content
            VStack(alignment: .leading, spacing: 6) {
                Spacer()
                
                Text("EPISODE \(episode.episodeNumber)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .tracking(1)
                
                Text(episode.name)
                    .font(.system(size: 22, weight: .bold, design: .default))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                
                Text(episode.overview)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(3)
                    .lineSpacing(2)
                    .frame(height: 60, alignment: .topLeading)
                
                // Bottom Row
                HStack(spacing: 12) {
                    if progress > 0 && progress < 0.95 {
                        // Progress Bar (Unfinished)
                         ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.3)).frame(height: 4)
                            Capsule().fill(Color.white).frame(width: 40 * 2, height: 4) // Restoring proportional width
                        }
                        .frame(width: 80)
                    } else {
                        // Play Icon (Default)
                        Image(systemName: "play.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                    }
                    
                    Text("\(episode.runtime ?? 50)m")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    
                    Spacer()
                    
                    Menu {
                        Button {} label: { Label("Download", systemImage: "arrow.down.circle") }
                        Button {} label: { Label("Share Episode", systemImage: "square.and.arrow.up") }
                        Button {} label: { Label("Share Show", systemImage: "square.and.arrow.up.on.square") }
                        Button {
                            if let item = item {
                                userData.toggleWatched(item, season: episode.seasonNumber, episode: episode.episodeNumber, episodeTitle: episode.name, episodeImage: episode.stillURL)
                            }
                        } label: {
                            Label("Mark as Watched", systemImage: "checkmark.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 20)) // Slightly larger touch target
                            .foregroundStyle(.white.opacity(0.8))
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .buttonStyle(.plain)
                }
                .padding(.top, 8)
            }
            .padding(20)
        }
        .frame(width: 380, height: 214)
        .background(Color(white: 0.1))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(isHovering ? 0.5 : 0.1), lineWidth: 1)
        )
        .shadow(color: isHovering ? Color.black.opacity(0.3) : Color.black.opacity(0.1), radius: isHovering ? 10 : 4, x: 0, y: isHovering ? 6 : 2)
        .animation(.spring(duration: 0.3), value: isHovering)
        .onHover { isHovering = $0 }
    }
}

// Generic Rail
struct DetailRail<Data: RandomAccessCollection, Content: View, ID: Hashable>: View where Data.Element: Identifiable {
    let items: Data
    let idPath: KeyPath<Data.Element, ID>
    let itemWidth: CGFloat
    let itemHeight: CGFloat
    let content: (Data.Element) -> Content
    
    @State private var scrollPosition: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    
    // Missing properties restored
    @State private var isHovering: Bool = false
    private let scrollStep = 3
    
    // Threshold to consider "scrolled"
    private let tolerance: CGFloat = 10 
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 24) {
                    ForEach(Array(items.enumerated()), id: \.offset) { enumeration in
                        content(enumeration.element)
                            .id(enumeration.offset)
                    }
                }
                .padding(.leading, 268)
                .padding(.trailing, 60)
                .padding(.top, 10) // Reduced top padding
                .padding(.bottom, 30) // Keep bottom for shadow
                .background(GeometryReader { geo in
                    Color.clear
                        .preference(key: ScrollOffsetKey.self, value: geo.frame(in: .named("scrollContainer")).minX)
                        .onAppear { contentWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, newValue in contentWidth = newValue }
                })
            }
            .coordinateSpace(name: "scrollContainer")
            .onPreferenceChange(ScrollOffsetKey.self) { value in
                if let value = value {
                    self.scrollPosition = value
                }
            }
            .background(GeometryReader { geo in
                Color.clear.onAppear { containerWidth = geo.size.width }
                           .onChange(of: geo.size.width) { _, newValue in containerWidth = newValue }
            })
            // Left Arrow
            .overlay(alignment: .leading) {
                // Only show if we have scrolled past start (negative offset)
                if isHovering && scrollPosition < -tolerance {
                    Button(action: { scrollLeft(proxy: proxy) }) { arrowButton("left") }
                        .buttonStyle(.plain)
                        .padding(.leading, 268)
                        .transition(.opacity)
                }
            }
            // Right Arrow
            .overlay(alignment: .trailing) {
                // Show if content extends beyond current view
                // (scrollPosition is negative, so we add contentWidth to see where the end is)
                // If end > containerWidth, we have more to see.
                if isHovering && (scrollPosition + contentWidth > containerWidth + tolerance) {
                   Button(action: { scrollRight(proxy: proxy) }) { arrowButton("right") }
                        .buttonStyle(.plain)
                        .padding(.trailing, 20)
                        .transition(.opacity)
                }
            }
            .onHover { isHovering = $0 }
        }
    }
    
    private func arrowButton(_ direction: String) -> some View {
        Image(systemName: "chevron.\(direction)")
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 64)
            .glassEffect(.regular.interactive(), in: .capsule)
    }
    
    // Update scroll logic to deduce index from visual estimation if needed, 
    // but simple scrollTo relative to current index is safer. 
    // We need to track `firstVisibleIndex` roughly.
    // For now, let's just increment/decrement a reliable state or find the item closest to -scrollPosition.
    private func scrollRight(proxy: ScrollViewProxy) {
        // Simple heuristic: Move +3
        let currentIdx = Int(abs(scrollPosition - 60) / (itemWidth + 24)) // 60 is padding
        let nextIndex = min(currentIdx + scrollStep, items.count - 1)
        withAnimation { proxy.scrollTo(nextIndex, anchor: .leading) }
    }
    
    private func scrollLeft(proxy: ScrollViewProxy) {
        let currentIdx = Int(abs(scrollPosition - 60) / (itemWidth + 24))
        let nextIndex = max(currentIdx - scrollStep, 0)
        withAnimation { proxy.scrollTo(nextIndex, anchor: .leading) }
    }
}

struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = value ?? nextValue()
    }
}

struct DetailScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}


// MARK: - Offline Download

extension DetailView {
    /// Picks the best stream for the current title (respecting the source filter)
    /// and starts an offline download via DownloadManager.
    func downloadBestStream() async {
        // Shows: download the first episode of the selected season
        let season = selectedSeason?.seasonNumber
        let episode = item.category == "TV Show" ? (heroEpisode?.episodeNumber ?? 1) : nil

        let streams = await StreamManager.shared.fetchStreams(
            for: displayItem,
            season: season,
            episode: episode
        )

        let mode = UserDefaults.standard.string(forKey: "streamingSourceMode") ?? "both"
        let candidates = streams
            .filter { s in
                let isTorrent = s.isTorrent
                if mode == "http" { return !isTorrent }
                if mode == "torrent" { return isTorrent }
                return true
            }
            .sorted { StreamManager.shared.streamSortComparator($0, $1) }

        guard let best = candidates.first(where: { !$0.isTorrent }) ?? candidates.first else {
            print("[DetailView] Download: no streams available")
            return
        }

        let seasonEpisode: String? = (season != nil && episode != nil)
            ? "S\(season!)E\(episode!)" : nil

        DownloadManager.shared.startDownload(
            id: best.stableKey,
            title: displayItem.title,
            seasonEpisode: seasonEpisode,
            url: PlayerManager.shared.getPlayableURL(for: best)
        )
    }
}
