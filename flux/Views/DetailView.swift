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
    @ObservedObject private var profileManager = ProfileManager.shared
    @State private var isRestrictedItem = false
    @State private var showingPinToSwitch = false
    @State private var isDownloading = false
    @State private var showCollectionsPopover = false
    @State private var trailerURL: URL? = nil
    @State private var bonusContent: [BonusContentItem] = []
    @State private var trailers: [BonusContentItem] = []
    @State private var activeLanguageModal: LanguageModalType? = nil
    @Environment(\.openWindow) private var openWindow
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 230
    
    // Computed
    var displayItem: MediaItem { fullItem ?? item }
    
    /// The active history item for this title (if any).
    private var activeHistoryItem: MediaItem? {
        userData.getHistoryItem(for: displayItem)
            ?? userData.getHistoryItem(for: item)
            ?? (activeImdbID.flatMap { userData.getHistoryItem(id: $0, title: displayItem.title, category: displayItem.category) })
            ?? (item.progress != nil ? item : nil)
    }

    /// Whether this title is currently in progress in Continue Watching.
    private var isInContinueWatching: Bool {
        if let prog = item.progress, prog > 0.01 && prog < 0.90 {
            return true
        }
        guard let history = activeHistoryItem,
              let prog = history.progress,
              prog > 0.01 && prog < 0.90 else {
            return false
        }
        return true
    }

    /// Progress value (0.0 .. 1.0) for the hero continue watching button.
    private var heroProgress: Double {
        if let history = activeHistoryItem, let prog = history.progress, prog > 0.0 {
            return prog
        }
        return item.progress ?? 0.0
    }

    /// Resolves the smart target episode to play or prefetch for this TV show:
    /// 1. If currently in-progress (progress > 0.01 && < 0.90): resumes the in-progress episode.
    /// 2. If the last episode was finished (progress >= 0.90): advances to the next unwatched episode.
    /// 3. If never watched: defaults to Season 1 Episode 1.
    private var smartTargetEpisode: (season: Int, episode: Int, title: String?, image: URL?, isResume: Bool)? {
        guard displayItem.isSeries || item.isSeries else { return nil }
        
        let history = activeHistoryItem
        if let hist = history, let lastS = hist.lastSeason, let lastE = hist.lastEpisode {
            let prog = hist.progress ?? 0.0
            
            // In-progress: resume this exact episode
            if prog > 0.01 && prog < 0.90 {
                let match = episodes.first(where: { $0.seasonNumber == lastS && $0.episodeNumber == lastE }) ?? heroEpisode
                return (lastS, lastE, hist.lastEpisodeTitle ?? match?.name, hist.lastEpisodeImage ?? match?.stillURL, true)
            }
            
            // Completed (or marked watched): calculate next unwatched episode
            if prog >= 0.90 {
                let allEps = fullItem?.episodes ?? episodes
                // 1. Try next episode in the same season
                if let nextInSeason = allEps.first(where: { $0.seasonNumber == lastS && $0.episodeNumber == lastE + 1 }) {
                    return (lastS, lastE + 1, nextInSeason.name, nextInSeason.stillURL, false)
                }
                
                // If season has episodeCount metadata
                if let currentSeasonObj = (fullItem?.seasons ?? item.seasons)?.first(where: { $0.seasonNumber == lastS }) {
                    if lastE < currentSeasonObj.episodeCount {
                        return (lastS, lastE + 1, nil, nil, false)
                    }
                }
                
                // 2. Try first episode of next season
                let nextSeasonNum = lastS + 1
                if let nextSeasonFirst = allEps.first(where: { $0.seasonNumber == nextSeasonNum && $0.episodeNumber == 1 }) {
                    return (nextSeasonNum, 1, nextSeasonFirst.name, nextSeasonFirst.stillURL, false)
                }
                
                let nextSeasonExists = (fullItem?.seasons ?? item.seasons)?.contains(where: { $0.seasonNumber == nextSeasonNum }) ?? false
                if nextSeasonExists {
                    return (nextSeasonNum, 1, nil, nil, false)
                }
                
                // If reached the end of the entire show, stay on the last episode
                return (lastS, lastE, hist.lastEpisodeTitle, hist.lastEpisodeImage, false)
            }
        }
        
        // No history or unwatched: first available episode
        let firstEp = episodes.first(where: { $0.seasonNumber > 0 }) ?? episodes.first
        let sNum = selectedSeason?.seasonNumber ?? firstEp?.seasonNumber ?? 1
        let eNum = firstEp?.episodeNumber ?? 1
        return (sNum, eNum, firstEp?.name, firstEp?.stillURL, false)
    }

    /// The specific episode to resume for a TV show (from history or first available).
    private var resumeEpisode: (season: Int, episode: Int, title: String?, image: URL?)? {
        if let target = smartTargetEpisode {
            return (target.season, target.episode, target.title, target.image)
        }
        return nil
    }

    /// Formatted runtime / remaining time display for the hero button.
    private var heroButtonRuntimeText: String {
        let history = activeHistoryItem
        
        // If we have actual position and duration from mpv playback, compute remaining time
        if let pos = history?.lastPlaybackPosition,
           let dur = history?.lastPlaybackDuration,
           dur > pos {
            let remaining = dur - pos
            let mins = Int(remaining / 60)
            if mins >= 60 {
                let hours = mins / 60
                let m = mins % 60
                return "\(hours)h \(m)m"
            } else if mins > 0 {
                return "\(mins)m"
            }
        }
        
        // For TV show, check the matching episode runtime
        if displayItem.category == "TV Show" || displayItem.category == "Series" {
            let targetEpNum = activeHistoryItem?.lastEpisode ?? 1
            let targetSeasonNum = activeHistoryItem?.lastSeason ?? 1
            if let match = episodes.first(where: { $0.episodeNumber == targetEpNum && $0.seasonNumber == targetSeasonNum }) ?? heroEpisode {
                if let rt = match.runtime {
                    return "\(rt)m"
                }
            }
        }
        
        // Movie fallback to displayItem.runtime
        if let rt = displayItem.runtime, !rt.isEmpty {
            return rt
        }
        
        // Generic fallback
        return "45m"
    }
    
    /// Top-billed cast for the hero "Starring" block. Falls back to the
    /// pre-enrichment item's cast so names can show before TMDB responds.
    var starringCast: [CastMember]? {
        let cast = fullItem?.cast ?? item.cast ?? []
        let named = cast.filter { !$0.name.isEmpty }
        guard !named.isEmpty else { return nil }
        return Array(named.prefix(4))
    }
    
    private var isReleased: Bool {
        guard let dateString = displayItem.releaseDate else { return true }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = formatter.date(from: dateString) { return date <= Date() }
        return true
    }
    
    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
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
                        
                        // Hero Content & Starring Overlay
                        HStack(alignment: .bottom, spacing: 32) {
                            // Left Side: Title, Badges, Overview, Buttons
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
                            } else if let genre = displayItem.genres?.first, !genre.isEmpty {
                                Text(genre.uppercased())
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .tracking(1.5)
                                    .foregroundStyle(.white.opacity(0.7))
                            } else if isLoadingDetails {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                                    .frame(width: 80, height: 14)
                                    .shimmer()
                            } else {
                                Text(displayItem.category.uppercased())
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
                                } else if isLoadingDetails {
                                    Text("•")
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(Color.white.opacity(0.08))
                                        .frame(width: 80, height: 12)
                                        .shimmer()
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
                                    Button(action: {
                                        if let target = smartTargetEpisode {
                                            let isFlux = UserDefaults.standard.object(forKey: UserDefaults.Key.enableFluxMode) as? Bool ?? true
                                            let matchingEp = episodes.first(where: { $0.seasonNumber == target.season && $0.episodeNumber == target.episode }) ?? heroEpisode
                                            PlayerManager.shared.play(
                                                displayItem,
                                                season: target.season,
                                                episode: target.episode,
                                                episodeImage: target.image ?? matchingEp?.stillURL,
                                                fromContinueWatching: target.isResume,
                                                forceStreamPicker: !isFlux,
                                                startFromBeginning: !target.isResume
                                            )
                                        } else {
                                            let isFlux = UserDefaults.standard.object(forKey: UserDefaults.Key.enableFluxMode) as? Bool ?? true
                                            PlayerManager.shared.play(
                                                displayItem,
                                                season: nil,
                                                episode: nil,
                                                episodeImage: nil,
                                                fromContinueWatching: isInContinueWatching,
                                                forceStreamPicker: !isFlux,
                                                startFromBeginning: !isInContinueWatching
                                            )
                                        }
                                        openWindow(id: "player", value: displayItem.id)
                                    }) {
                                        if isInContinueWatching {
                                            // Apple TV style: Play icon + Progress Bar + Runtime in single white capsule button
                                            HStack(spacing: 10) {
                                                Image(systemName: "play.fill")
                                                    .font(.system(size: 13, weight: .bold))
                                                
                                                ZStack(alignment: .leading) {
                                                    Capsule()
                                                        .fill(Color.black.opacity(0.18))
                                                        .frame(width: 68, height: 4)
                                                    Capsule()
                                                        .fill(Color.black)
                                                        .frame(width: max(4, 68 * min(1.0, max(0.0, heroProgress))), height: 4)
                                                }
                                                
                                                Text(heroButtonRuntimeText)
                                                    .font(.system(size: 13, weight: .bold))
                                            }
                                            .foregroundStyle(.black)
                                            .padding(.horizontal, 22)
                                            .padding(.vertical, 14)
                                            .background(Color.white)
                                            .clipShape(Capsule())
                                            .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
                                        } else {
                                            // Default: Clean "Play" button for both movies and TV shows
                                            HStack(spacing: 8) {
                                                Image(systemName: "play.fill")
                                                    .font(.system(size: 14, weight: .bold))
                                                Text("Play")
                                                    .font(.system(size: 15, weight: .bold))
                                            }
                                            .foregroundStyle(.black)
                                            .padding(.horizontal, 36)
                                            .padding(.vertical, 14)
                                            .background(Color.white)
                                            .clipShape(Capsule())
                                            .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .animation(.easeOut(duration: 0.15), value: isInContinueWatching)
                                    .contextMenu {
                                        Button {
                                            if let target = smartTargetEpisode {
                                                let matchingEp = episodes.first(where: { $0.seasonNumber == target.season && $0.episodeNumber == target.episode }) ?? heroEpisode
                                                PlayerManager.shared.play(
                                                    displayItem,
                                                    season: target.season,
                                                    episode: target.episode,
                                                    episodeImage: target.image ?? matchingEp?.stillURL,
                                                    fromContinueWatching: false,
                                                    forceStreamPicker: true,
                                                    startFromBeginning: false
                                                )
                                            } else {
                                                PlayerManager.shared.play(
                                                    displayItem,
                                                    season: nil,
                                                    episode: nil,
                                                    episodeImage: nil,
                                                    fromContinueWatching: false,
                                                    forceStreamPicker: true,
                                                    startFromBeginning: false
                                                )
                                            }
                                            openWindow(id: "player", value: displayItem.id)
                                        } label: {
                                            Label("Choose Stream Source…", systemImage: "list.bullet.rectangle")
                                        }
                                    }
                                    
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

                                }
                            }
                            .padding(.top, 10)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 268)
                        
                        // Starring & Director — bottom-right of the hero (Apple TV style)
                        let castNames = starringCast?.map { $0.name } ?? []
                        let directorName = displayItem.director
                        let hasDirector = directorName != nil && !directorName!.isEmpty && directorName != "N/A"
                        
                        if !castNames.isEmpty || hasDirector {
                            VStack(alignment: .leading, spacing: 4) {
                                if !castNames.isEmpty {
                                    (
                                        Text("Starring ")
                                            .foregroundColor(Color(white: 0.6))
                                        + Text(castNames.joined(separator: ", "))
                                            .foregroundColor(.white)
                                    )
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                }
                                
                                if hasDirector {
                                    (
                                        Text("Director ")
                                            .foregroundColor(Color(white: 0.6))
                                        + Text(directorName!)
                                            .foregroundColor(.white)
                                    )
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                }
                            }
                            .frame(minWidth: 160, maxWidth: 280, alignment: .leading)
                            .padding(.trailing, 60)
                            .transition(.opacity)
                        }
                    }
                    .padding(.bottom, 60)
                    .frame(width: geo.size.width, height: geo.size.height * 0.80, alignment: .bottom)
                }
                .frame(height: geo.size.height * 0.80)
                    
                    VStack(alignment: .leading, spacing: 40) {
                        // Ghost rails while metadata loads
                        if isLoadingDetails {
                            VStack(alignment: .leading, spacing: 44) {
                                if item.category == "TV Show" {
                                    GhostRail(posterWidth: 380, ratio: 16/9, cornerRadius: 16)
                                }
                                GhostRail(posterWidth: 300, ratio: 16/9, cornerRadius: 16)
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
                                                let isFluxEnabled = UserDefaults.standard.object(forKey: UserDefaults.Key.enableFluxMode) as? Bool ?? true
                                                if isFluxEnabled {
                                                    PlayerManager.shared.startDetailPrefetch(
                                                        item: displayItem,
                                                        season: season.seasonNumber,
                                                        episode: 1
                                                    )
                                                }
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
                                
                                if !episodes.isEmpty {
                                    DetailRail(items: episodes, idPath: \.id, itemWidth: 380, itemHeight: 214) { episode in
                                        Button(action: {
                                            let prog = getEpisodeProgress(episode)
                                            let hasProgress = prog > 0.01 && prog < 0.90
                                            let isFlux = UserDefaults.standard.object(forKey: UserDefaults.Key.enableFluxMode) as? Bool ?? true
                                            PlayerManager.shared.play(
                                                displayItem,
                                                season: selectedSeason?.seasonNumber ?? episode.seasonNumber,
                                                episode: episode.episodeNumber,
                                                episodeImage: episode.stillURL,
                                                fromContinueWatching: hasProgress,
                                                forceStreamPicker: !isFlux,
                                                startFromBeginning: !hasProgress
                                            )
                                            openWindow(id: "player", value: displayItem.id)
                                        }) {
                                            LiquidEpisodeCard(episode: episode, progress: getEpisodeProgress(episode), item: displayItem)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                } else {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 24) {
                                            ForEach(0..<4, id: \.self) { _ in
                                                SkeletonEpisodeCard()
                                            }
                                        }
                                        .padding(.leading, 268)
                                        .padding(.trailing, 60)
                                        .padding(.top, 10)
                                        .padding(.bottom, 24)
                                    }
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

                        if !trailers.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Trailers")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.white)
                                    .padding(.leading, 268)
                                    .padding(.trailing, 60)

                                DetailRail(items: trailers, idPath: \.id, itemWidth: 300, itemHeight: 169) { item in
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
                            castSection(cast: cast)
                        }

                        Divider().background(Color.white.opacity(0.1))

                        whereToWatchSection

                        aboutSection
                        
                        HStack(alignment: .top, spacing: 60) {
                            informationSection
                            languagesSection
                            accessibilitySection
                        }
                        .padding(.leading, 268)
                        .padding(.trailing, 60)
                        .padding(.bottom, 80)
                    }
                    .background(Color.black.opacity(0.5))
                }
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
        .overlay {
            if let modalType = activeLanguageModal {
                ZStack {
                    Color.black.opacity(0.65)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                activeLanguageModal = nil
                            }
                        }
                    
                    LanguageTracksModalView(
                        title: modalType.title,
                        items: displayItem.displayAudioTracks,
                        onDismiss: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                activeLanguageModal = nil
                            }
                        }
                    )
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
                }
                .zIndex(100)
            }
        }
        .overlay {
            if isRestrictedItem {
                contentRestrictedOverlay
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbarVisibility(.hidden, for: .windowToolbar)
        .task {
            await checkKidsRestriction()
            if !isRestrictedItem {
                prefetchPlaybackSources()
                await loadDetails()
                prefetchPlaybackSources()
                await checkKidsRestriction()
            }
        }
        .onChange(of: displayItem.certification) { _, _ in
            Task { await checkKidsRestriction() }
        }
        .onChange(of: selectedSeason?.seasonNumber) { _, _ in
            prefetchPlaybackSources()
        }
        .onChange(of: heroEpisode?.episodeNumber) { _, _ in
            prefetchPlaybackSources()
        }
        .onReceive(NotificationCenter.default.publisher(for: .fluxRefresh)) { _ in
            Task {
                await loadDetails()
                prefetchPlaybackSources()
            }
        }
        .onDisappear {
            PlayerManager.shared.cancelDetailPrefetch()
        }
    }

    // MARK: - Detail Subsections

    @ViewBuilder
    private func castSection(cast: [CastMember]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ListSectionHeader(title: "Cast & Crew", value: CastListNavigation(cast: cast))
                .padding(.leading, 268)
                .padding(.trailing, 60)

            DetailRail(items: cast, idPath: \.id, itemWidth: 124, itemHeight: 180) { member in
                NavigationLink(value: PersonNavigation(id: member.personID ?? 0, fallbackName: member.name)) {
                    VStack(spacing: 10) {
                        CastCircle(name: member.name, imageURL: member.imageURL, size: 104)

                        VStack(spacing: 2) {
                            Text(member.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineLimit(1)
                            Text(member.role ?? "")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(1)
                        }
                        .frame(height: 38)
                    }
                    .frame(width: 124)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(member.personID == nil)
            }
        }
    }

    @ViewBuilder
    private var whereToWatchSection: some View {
        if let providers = displayItem.watchProviders, !providers.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("Where to Watch")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 20) {
                        ForEach(providers) { provider in
                            VStack(spacing: 10) {
                                CachedImage(url: provider.logoURL) { phase in
                                    if let image = phase.image {
                                        image
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(width: 76, height: 76)
                                            .cornerRadius(18)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 18)
                                                    .stroke(Color.white.opacity(0.12), lineWidth: 0.75)
                                            )
                                    } else {
                                        RoundedRectangle(cornerRadius: 18)
                                            .fill(Color(white: 0.14))
                                            .frame(width: 76, height: 76)
                                    }
                                }
                                
                                Text(provider.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(1)
                            }
                            .frame(width: 90)
                        }
                    }
                }
            }
            .padding(.leading, 268)
            .padding(.trailing, 60)
        } else {
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
    }

    @ViewBuilder
    private var aboutSection: some View {
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
    }

    @ViewBuilder
    private var informationSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Information")
                .font(.headline).fontWeight(.semibold)
                .foregroundStyle(.white)
            
            VStack(alignment: .leading, spacing: 16) {
                InfoDetailRow(label: "Released", value: displayItem.displayReleaseDate ?? "N/A")
                if let cert = displayItem.certification, !cert.isEmpty {
                    InfoDetailRow(label: "Rated", value: cert)
                }
                if let adv = displayItem.contentAdvisories, !adv.isEmpty {
                    InfoDetailRow(label: "Content Advisories", value: adv.joined(separator: ", "))
                }
                if let director = displayItem.director, !director.isEmpty && director != "N/A" {
                    InfoDetailRow(label: "Director", value: director)
                }
                if displayItem.category != "TV Show", let runtime = displayItem.runtime, !runtime.isEmpty {
                    InfoDetailRow(label: "Runtime", value: runtime)
                }
                InfoDetailRow(label: displayItem.displayOriginCountryTitle, value: displayItem.displayOriginCountry ?? "N/A")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var languagesSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Languages")
                .font(.headline).fontWeight(.semibold)
                .foregroundStyle(.white)
            
            VStack(alignment: .leading, spacing: 16) {
                InfoDetailRow(label: "Original Audio", value: displayItem.displayOriginalLanguage ?? "English")
                LanguagesExpandableRow(
                    title: "Audio",
                    items: displayItem.displayAudioTracks,
                    onMore: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            activeLanguageModal = .audio
                        }
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var accessibilitySection: some View {
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
        let isFluxEnabled = UserDefaults.standard.object(forKey: UserDefaults.Key.enableFluxMode) as? Bool ?? true
        guard isFluxEnabled else { return }

        if displayItem.isSeries || item.isSeries {
            if let target = smartTargetEpisode {
                PlayerManager.shared.startDetailPrefetch(
                    item: displayItem,
                    season: target.season,
                    episode: target.episode
                )
            } else {
                let seasonNumber = selectedSeason?.seasonNumber ?? heroEpisode?.seasonNumber ?? 1
                let episodeNumber = heroEpisode?.episodeNumber ?? 1
                PlayerManager.shared.startDetailPrefetch(
                    item: displayItem,
                    season: seasonNumber,
                    episode: episodeNumber
                )
            }
        } else {
            PlayerManager.shared.startDetailPrefetch(
                item: displayItem,
                season: nil,
                episode: nil
            )
        }
    }
    
    func getEpisodeProgress(_ episode: Episode?) -> Double {
        guard let episode = episode else { return 0.0 }
        if let epProg = UserDataService.shared.getEpisodeProgress(for: displayItem.id, season: episode.seasonNumber, episode: episode.episodeNumber),
           epProg.duration > 0 {
            return epProg.position / epProg.duration
        }
        guard let historyItem = activeHistoryItem else { return 0.0 }
        
        if displayItem.category == "TV Show" || displayItem.category == "Series" {
            let matchesSeason = (historyItem.lastSeason == nil && episode.seasonNumber == 1) || (historyItem.lastSeason == episode.seasonNumber)
            let matchesEpisode = historyItem.lastEpisode == episode.episodeNumber
            if matchesSeason && matchesEpisode {
                return historyItem.progress ?? 0.0
            }
            return 0.0
        } else {
            return historyItem.progress ?? displayItem.progress ?? 0.0
        }
    }
    
    private func loadDetails() async {
        do {
            SeasonDropdownController.shared.close()
            let type = item.category == "TV Show" ? "series" : "movie"
            var fetchID = item.id
            
            // 1. ID Translation Layer (TMDB -> IMDb)
            // If the ID is purely numerical or prefixed with "tmdb-", it's a TMDB ID and needs translation for Stremio
            let cleanTmdbId = item.id.replacingOccurrences(of: "tmdb-", with: "").replacingOccurrences(of: "tmdb:", with: "")
            if CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: cleanTmdbId)) {
                if let translatedID = await TMDBEnricher.shared.getImdbID(tmdbID: cleanTmdbId, type: type) {
                    fetchID = translatedID
                }
            }
            
            self.activeImdbID = fetchID
            
            // 2. Fetch Enriched Metadata
            // When TMDB enrichment is active, completely bypass Cinemeta to eliminate conflicting metadata
            // and prevent split-second textual/graphical layout pops.
            var detailedItem: MediaItem
            if TMDBEnricher.shared.hasKey {
                detailedItem = await TMDBEnricher.shared.fullEnrich(item)
            } else {
                do {
                    detailedItem = try await StremioService.shared.fetchMeta(type: type, id: fetchID)
                } catch {
                    print("Stremio fetchMeta failed (\(error))")
                    detailedItem = item
                }
            }
            
            var merged = detailedItem
            if merged.description.isEmpty && !item.description.isEmpty {
                merged.description = item.description
            }
            if (merged.genres == nil || merged.genres?.isEmpty == true) && (item.genres != nil && !item.genres!.isEmpty) {
                merged.genres = item.genres
            }
            if (merged.voteAverage == nil || merged.voteAverage == 0) && (item.voteAverage != nil && item.voteAverage! > 0) {
                merged.voteAverage = item.voteAverage
            }
            if (merged.releaseDate == nil || merged.releaseDate?.isEmpty == true) && (item.releaseDate != nil && !item.releaseDate!.isEmpty) {
                merged.releaseDate = item.releaseDate
            }
            if merged.heroURL == nil { merged.heroURL = item.heroURL }
            if merged.backdropURL == nil { merged.backdropURL = item.backdropURL }
            if merged.posterURL == nil { merged.posterURL = item.posterURL }
            
            await MainActor.run {
                self.fullItem = merged
            }
            
            if type == "series" {
                let regularSeasons = merged.seasons?.filter { $0.seasonNumber > 0 && !$0.name.lowercased().contains("special") } ?? []
                let targetSeason: Season?
                if let target = self.smartTargetEpisode,
                   let matchedSeason = regularSeasons.first(where: { $0.seasonNumber == target.season }) {
                    targetSeason = matchedSeason
                } else if let hist = activeHistoryItem,
                   let lastS = hist.lastSeason,
                   let matchedSeason = regularSeasons.first(where: { $0.seasonNumber == lastS }) {
                    targetSeason = matchedSeason
                } else {
                    targetSeason = regularSeasons.first ?? merged.seasons?.first
                }
                
                if let seasonToLoad = targetSeason {
                    selectedSeason = seasonToLoad
                    
                    // Track TMDB ID for sub-enrichment (episodes)
                    let cleanId = merged.id.replacingOccurrences(of: "tmdb-", with: "").replacingOccurrences(of: "tmdb:", with: "")
                    if CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: cleanId)) && !cleanId.isEmpty {
                        UserDefaults.standard.set(cleanId, forKey: "activeTMDBID")
                    } else if let imdbID = merged.id.starts(with: "tt") ? merged.id : nil {
                        if let tmdbID = await TMDBEnricher.shared.resolveTmdbID(imdbID: imdbID, type: "tv") {
                             UserDefaults.standard.set(tmdbID, forKey: "activeTMDBID")
                        }
                    }
                    
                    await loadEpisodes(for: seasonToLoad)
                }
            }
            
            async let fetchedBonusTask = TMDBEnricher.shared.fetchBonusContent(item: merged, fullItem: merged)
            async let tmdbSimilarTask = TMDBEnricher.shared.fetchSimilar(item: merged)
            
            let (fetchedBonus, tmdbSimilar) = await (fetchedBonusTask, tmdbSimilarTask)
            
            self.bonusContent = fetchedBonus.filter { $0.categoryType != "Trailer" && $0.categoryType != "Teaser" }
            self.trailers = fetchedBonus.filter { $0.categoryType == "Trailer" || $0.categoryType == "Teaser" }
            
            if let bestTrailer = self.trailers.first,
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
        let allEpisodes = fullItem?.episodes ?? []
        var currentSeasonEpisodes = allEpisodes.filter { $0.seasonNumber == season.seasonNumber }
            .sorted { $0.episodeNumber < $1.episodeNumber }
        
        // If episodes are missing (TMDB enrichment mode where Cinemeta was bypassed), fetch them from TMDB directly
        if currentSeasonEpisodes.isEmpty {
            let cleanTmdbId = fullItem?.id.replacingOccurrences(of: "tmdb-", with: "").replacingOccurrences(of: "tmdb:", with: "") ?? ""
            var resolvedTmdbId: String? = nil
            if CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: cleanTmdbId)) && !cleanTmdbId.isEmpty {
                resolvedTmdbId = cleanTmdbId
            } else if let id = fullItem?.id, id.hasPrefix("tt") {
                resolvedTmdbId = await TMDBEnricher.shared.resolveTmdbID(imdbID: id, type: "tv")
            }
            if resolvedTmdbId == nil {
                resolvedTmdbId = UserDefaults.standard.string(forKey: "activeTMDBID")
            }
            
            if let tvId = resolvedTmdbId {
                let fetched = await TMDBEnricher.shared.fetchSeasonEpisodes(tvId: tvId, seasonNumber: season.seasonNumber)
                if !fetched.isEmpty {
                    currentSeasonEpisodes = fetched
                    await MainActor.run {
                        if var updated = self.fullItem {
                            var existing = updated.episodes ?? []
                            existing.removeAll { $0.seasonNumber == season.seasonNumber }
                            existing.append(contentsOf: fetched)
                            updated.episodes = existing
                            self.fullItem = updated
                        }
                    }
                }
            }
        }
        
        // Initial set to show something immediately
        await MainActor.run {
            self.episodes = currentSeasonEpisodes
            if let target = self.smartTargetEpisode,
               let matched = currentSeasonEpisodes.first(where: { $0.seasonNumber == target.season && $0.episodeNumber == target.episode }) {
                self.heroEpisode = matched
            } else if let hist = activeHistoryItem,
               let lastE = hist.lastEpisode,
               let matched = currentSeasonEpisodes.first(where: { $0.episodeNumber == lastE }) {
                self.heroEpisode = matched
            } else if let first = currentSeasonEpisodes.first {
                self.heroEpisode = first
            }
        }
        
        // Background Enrichment: Fetch descriptions, stills, names, and runtimes automatically
        if let id = fullItem?.id, id.hasPrefix("tt"),
           let tmdbID = await TMDBEnricher.shared.resolveTmdbID(imdbID: id, type: "tv") {
            
            let enrichedMap = await TMDBEnricher.shared.fetchFullSeasonEnrichment(tvId: tmdbID, seasonNumber: season.seasonNumber)
            
            if !enrichedMap.isEmpty {
                await MainActor.run {
                    self.episodes = currentSeasonEpisodes.map { episode in
                        var enriched = episode
                        if let tmdbData = enrichedMap[episode.episodeNumber] {
                            if !tmdbData.overview.isEmpty {
                                enriched.overview = tmdbData.overview
                            }
                            if let still = tmdbData.stillURL {
                                enriched.stillURL = still
                            }
                            if let rt = tmdbData.runtime {
                                enriched.runtime = rt
                            }
                            if !tmdbData.name.isEmpty && (episode.name.hasPrefix("Episode ") || episode.name.isEmpty) {
                                enriched.name = tmdbData.name
                            }
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

enum LanguageModalType: Identifiable {
    case audio
    
    var id: String { "audio" }
    var title: String { "Audio" }
}

struct LanguagesExpandableRow: View {
    let title: String
    let items: [String]
    let onMore: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            
            let fullText = items.joined(separator: ", ")
            let isLong = fullText.count > 95 || items.count > 4
            
            if !isLong {
                Text(fullText.isEmpty ? "None" : fullText)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
            } else {
                let truncated = truncatedText(fullText, maxLength: 90)
                Button(action: onMore) {
                    (Text(truncated + "... ")
                        .foregroundStyle(.white.opacity(0.85))
                     + Text("more")
                        .foregroundStyle(.secondary)
                        .fontWeight(.medium))
                    .font(.subheadline)
                    .lineSpacing(3)
                    .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
        }
    }
    
    private func truncatedText(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let index = text.index(text.startIndex, offsetBy: maxLength)
        let prefix = String(text[..<index])
        if let lastComma = prefix.lastIndex(of: ",") {
            return String(prefix[..<lastComma])
        }
        return prefix
    }
}

struct LanguageTracksModalView: View {
    let title: String
    let items: [String]
    let onDismiss: () -> Void
    
    var body: some View {
        VStack(alignment: .center, spacing: 20) {
            Text(title)
                .font(.headline)
                .fontWeight(.bold)
                .foregroundStyle(.white)
            
            ScrollView(.vertical, showsIndicators: true) {
                Text(items.joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            
            HStack {
                Spacer()
                Button(action: onDismiss) {
                    Text("Done")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.18), in: Capsule())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
        }
        .padding(28)
        .frame(width: 460)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.6), radius: 30, x: 0, y: 15)
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
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.white.opacity(0.4), lineWidth: 1)
                )
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
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // 1. Background Image
            if let url = episode.stillURL {
                CachedImage(url: url, maxDimension: 760) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable()
                            .aspectRatio(contentMode: .fill)
                            .transition(.opacity.animation(.easeInOut(duration: 0.25)))
                    default:
                        skeletonPlaceholder
                    }
                }
                .frame(width: 380, height: 214)
                .clipped()
            } else {
                skeletonPlaceholder
                    .frame(width: 380, height: 214)
            }
            
            // 2. Liquid Glass Overlay
            LinearGradient(colors: [
                .clear,
                .black.opacity(0.35),
                .black.opacity(0.75),
                .black.opacity(0.92)
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
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(3)
                    .lineSpacing(2)
                    .frame(height: 60, alignment: .topLeading)
                
                // Bottom Row
                HStack(spacing: 10) {
                    // Play Icon (Always visible on all episode cards)
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                    
                    // Progress Bar (Conditional: displayed only when in-progress)
                    if progress > 0.01 && progress < 0.95 {
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.35)).frame(height: 4)
                            Capsule().fill(Color.white).frame(width: max(4, 70 * min(1.0, progress)), height: 4)
                        }
                        .frame(width: 70)
                    }
                    
                    Text("\(episode.runtime ?? 50)m")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    
                    Spacer()
                    
                    Menu {
                        Button {
                            if let item = item {
                                PlayerManager.shared.play(
                                    item,
                                    season: episode.seasonNumber,
                                    episode: episode.episodeNumber,
                                    episodeImage: episode.stillURL,
                                    fromContinueWatching: false,
                                    forceStreamPicker: true,
                                    startFromBeginning: false
                                )
                                openWindow(id: "player", value: item.id)
                            }
                        } label: {
                            Label("Choose Stream Source…", systemImage: "list.bullet.rectangle")
                        }

                        Button {
                            if let item = item {
                                userData.toggleWatched(
                                    item,
                                    season: episode.seasonNumber,
                                    episode: episode.episodeNumber,
                                    episodeTitle: episode.name,
                                    episodeImage: episode.stillURL
                                )
                            }
                        } label: {
                            Label("Mark as Watched", systemImage: "checkmark.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(isHovering ? 1.0 : 0.75))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .menuIndicator(.hidden)
                    .menuStyle(.borderlessButton)
                    .buttonStyle(.plain)
                }
                .padding(.top, 8)
            }
            .padding(20)
        }
        .frame(width: 380, height: 214)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.10, green: 0.10, blue: 0.12))
        )
        // Specular Rim Highlight on Hover
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: isHovering 
                            ? [Color.white.opacity(0.70), Color.white.opacity(0.20), Color.blue.opacity(0.15)]
                            : [Color.white.opacity(0.14), Color.white.opacity(0.03)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isHovering ? 1.5 : 0.75
                )
        )
        .shadow(color: Color.black.opacity(isHovering ? 0.40 : 0.16), radius: isHovering ? 12 : 4, x: 0, y: isHovering ? 6 : 2)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isHovering)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var skeletonPlaceholder: some View {
        ZStack {
            Rectangle()
                .fill(Color(red: 0.11, green: 0.11, blue: 0.13))
            LinearGradient(
                colors: [Color.white.opacity(0.06), Color.white.opacity(0.02)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

struct SkeletonEpisodeCard: View {
    @State private var phase: CGFloat = 0
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.11, green: 0.11, blue: 0.13))
            
            LinearGradient(
                stops: [
                    .init(color: .clear, location: max(0, phase - 0.35)),
                    .init(color: Color.white.opacity(0.07), location: phase),
                    .init(color: .clear, location: min(1, phase + 0.35))
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            
            VStack(alignment: .leading, spacing: 10) {
                Spacer()
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 75, height: 11)
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white.opacity(0.20))
                    .frame(width: 210, height: 20)
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.10))
                        .frame(width: 320, height: 12)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 240, height: 12)
                }
                .frame(height: 40, alignment: .topLeading)
                
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color.white.opacity(0.15))
                        .frame(width: 14, height: 14)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 35, height: 12)
                    Spacer()
                }
            }
            .padding(20)
        }
        .frame(width: 380, height: 214)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .onAppear {
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                phase = 1.0
            }
        }
    }
}

// Generic Rail
struct DetailRail<Data: RandomAccessCollection, Content: View, ID: Hashable>: View where Data.Element: Identifiable {
    let items: Data
    let idPath: KeyPath<Data.Element, ID>
    let itemWidth: CGFloat
    let itemHeight: CGFloat
    let content: (Data.Element) -> Content
    @State private var isHovering: Bool = false
    @State private var scrollTargetIndex: Int = 0
    private let scrollStep = 3
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 24) {
                    ForEach(Array(items.enumerated()), id: \.offset) { enumeration in
                        content(enumeration.element)
                            .id(enumeration.offset)
                            .onAppear {
                                prefetchAhead(from: enumeration.offset)
                            }
                    }
                }
                .padding(.leading, 268)
                .padding(.trailing, 60)
                .padding(.top, 10)
                .padding(.bottom, 24)
            }
            // Left Arrow
            .overlay(alignment: .leading) {
                if isHovering && scrollTargetIndex > 0 {
                    Button(action: { scrollLeft(proxy: proxy) }) { arrowButton("left") }
                        .buttonStyle(.plain)
                        .padding(.leading, 268)
                        .transition(.opacity)
                }
            }
            // Right Arrow
            .overlay(alignment: .trailing) {
                if isHovering && scrollTargetIndex < items.count - 1 {
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
    
    private func scrollRight(proxy: ScrollViewProxy) {
        guard !items.isEmpty else { return }
        scrollTargetIndex = min(scrollTargetIndex + scrollStep, items.count - 1)
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            proxy.scrollTo(scrollTargetIndex, anchor: .leading)
        }
    }
    
    private func scrollLeft(proxy: ScrollViewProxy) {
        guard !items.isEmpty else { return }
        scrollTargetIndex = max(scrollTargetIndex - scrollStep, 0)
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            proxy.scrollTo(scrollTargetIndex, anchor: .leading)
        }
    }

    private func prefetchAhead(from index: Int) {
        let array = Array(items)
        guard !array.isEmpty else { return }
        let nextStart = index + 1
        let nextEnd = min(index + 3, array.count - 1)
        guard nextStart <= nextEnd else { return }

        var urls: [URL?] = []
        for i in nextStart...nextEnd {
            let candidate = array[i]
            if let ep = candidate as? Episode {
                urls.append(ep.stillURL)
            } else if let media = candidate as? MediaItem {
                urls.append(media.posterURL ?? media.imageURL ?? media.backdropURL)
            } else if let mirror = Mirror(reflecting: candidate).descendant("stillURL") as? URL? {
                urls.append(mirror)
            } else if let mirror = Mirror(reflecting: candidate).descendant("posterURL") as? URL? {
                urls.append(mirror)
            }
        }
        ImagePrefetcher.shared.prefetch(urls: urls, maxDimension: itemWidth * 1.5)
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

    // MARK: - Kids Profile Content Gating

    private func checkKidsRestriction() async {
        guard profileManager.currentProfile?.isKids == true else {
            await MainActor.run { self.isRestrictedItem = false }
            return
        }
        if KidsContentFilter.shared.isRestricted(item: displayItem) {
            await MainActor.run { self.isRestrictedItem = true }
            return
        }
        let safe = await KidsContentFilter.shared.isKidsSafe(item: displayItem)
        await MainActor.run {
            self.isRestrictedItem = !safe
        }
    }

    @ViewBuilder private var contentRestrictedOverlay: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.12))
                        .frame(width: 80, height: 80)
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.red, .orange],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                VStack(spacing: 8) {
                    Text("Content Restricted")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(restrictedReasonText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                HStack(spacing: 14) {
                    Button(action: {
                        dismiss()
                    }) {
                        Text("Go Back")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.white.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        showingPinToSwitch = true
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.open.fill")
                                .font(.system(size: 12))
                            Text("Unlock with PIN")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.yellow)
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 8)
            }
            .padding(40)
            .frame(maxWidth: 480)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(red: 0.12, green: 0.13, blue: 0.16).opacity(0.95))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 15)
        }
        .sheet(isPresented: $showingPinToSwitch) {
            PINEntrySheet(mode: .verify(
                title: "Parental Unlock",
                subtitle: "Enter PIN to switch to an adult profile",
                profileId: profileManager.currentProfile?.id,
                onSuccess: {
                    profileManager.switchToProfileSelection()
                }
            ))
        }
    }

    private var restrictedReasonText: String {
        if let cert = displayItem.certification, !cert.isEmpty {
            return "This title is rated \(cert) and cannot be viewed in Kids Profile."
        }
        return "This title is not approved for Kids Profile."
    }
}
