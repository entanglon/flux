import SwiftUI

struct DetailView: View {
    let item: MediaItem
    @State private var fullItem: MediaItem?
    @State private var selectedSeason: Season?
    @State private var showSeasonPopover = false
    @State private var episodes: [Episode] = []
    @State private var relatedItems: [MediaItem] = []
    @State private var heroEpisode: Episode?
    @State private var isLoadingDetails = true
    @ObservedObject private var dataManager = DataManager.shared
    @ObservedObject private var userData = UserDataService.shared
    @ObservedObject private var downloadManager = DownloadManager.shared
    @Environment(\.openWindow) private var openWindow
    
    @AppStorage("enableRichMetadata") private var enableRichMetadata = false
    
    // Computed
    var displayItem: MediaItem { fullItem ?? item }
    
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
                        CachedImage(url: heroEpisode?.heroURL ?? displayItem.heroURL ?? displayItem.backdropURL ?? displayItem.imageURL, maxDimension: 1920) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: geo.size.width, height: geo.size.height * 0.80)
                                    .clipped()
                            default:
                                Rectangle().fill(Color(white: 0.1))
                                    .frame(width: geo.size.width, height: geo.size.height * 0.80)
                            }
                        }
                        
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
                            if let episode = heroEpisode {
                                Text("S\(episode.seasonNumber), E\(episode.episodeNumber) • \(episode.name)")
                                    .font(.headline)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.white.opacity(0.8))
                                    .tracking(0.5)
                            } else {
                                Text(displayItem.category == "TV Show" ? "NEW EPISODE EVERY FRIDAY" : displayItem.genres?.first?.uppercased() ?? "MOVIE")
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
                                Text("•")
                                Text(displayItem.genres?.prefix(2).joined(separator: ", ") ?? "Genre")
                                Text("•")
                                HStack(spacing: 2) {
                                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                                    Text(String(format: "%.1f", displayItem.voteAverage ?? 0))
                                }
                                TechBadge(text: "4K")
                                TechBadge(text: "DOLBY VISION")
                                TechBadge(text: "ATMOS")
                                TechBadge(text: "CC")
                            }
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white.opacity(0.9))
                            
                            // Hero Description (Episode or Show)
                            Text(heroEpisode?.overview ?? displayItem.description)
                                .font(.body)
                                .lineLimit(3)
                                .lineSpacing(4)
                                .foregroundStyle(.white.opacity(0.8))
                                .frame(maxWidth: 600, alignment: .leading)
                                .padding(.top, 4)
                            
                            // Action Buttons
                            HStack(spacing: 16) {
                                if isReleased {
                                    // Check Progress
                                    let progress = getEpisodeProgress(heroEpisode)
                                    
                                    Button(action: {
                                        PlayerManager.shared.play(displayItem, season: heroEpisode?.seasonNumber, episode: heroEpisode?.episodeNumber, episodeImage: heroEpisode?.stillURL)
                                        openWindow(id: "player", value: displayItem.id)
                                    }) {
                                        if progress > 0 && progress < 0.95 {
                                            // Resume / Progress Bar Button
                                            HStack(spacing: 12) {
                                                Image(systemName: "play.fill")
                                                    .font(.headline)
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text("Resume Episode")
                                                        .font(.subheadline).fontWeight(.bold)
                                                    // Progress Bar
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
                                            // Standard Play Button
                                            Text(displayItem.category == "Movie" ? "Play Movie" : "Play Episode")
                                                .font(.headline)
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 32)
                                                .padding(.vertical, 14)
                                        }
                                    }
                                    .buttonStyle(GlassButtonStyle(isProminent: true))
                                    
                                    Button(action: {
                                         userData.toggleWatchlist(displayItem)
                                    }) {
                                        Image(systemName: userData.isInWatchlist(displayItem) ? "checkmark" : "plus")
                                            .font(.headline)
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 24)
                                            .padding(.vertical, 14)
                                    }
                                    .buttonStyle(GlassButtonStyle(shape: .capsule, style: userData.isInWatchlist(displayItem) ? .regular.tint(.green) : .regular))
                                    
                                    if downloadManager.downloadedItems.contains(where: { $0.id == displayItem.id }) {
                                        Button(action: {
                                            if let downloadedItem = downloadManager.downloadedItems.first(where: { $0.id == displayItem.id }) {
                                                downloadManager.delete(item: downloadedItem)
                                            }
                                        }) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.headline)
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 24)
                                                .padding(.vertical, 14)
                                        }
                                        .buttonStyle(GlassButtonStyle(shape: .capsule, style: .regular.tint(.green)))
                                        .help("Downloaded")
                                    } else if let progress = downloadManager.activeDownloads[displayItem] {
                                        Button(action: {}) {
                                            HStack(spacing: 8) {
                                                ProgressView()
                                                    .controlSize(.small)
                                                    .tint(.white)
                                                Text("\(Int(progress * 100))%")
                                                    .font(.subheadline).bold()
                                            }
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 20)
                                            .padding(.vertical, 14)
                                        }
                                        .buttonStyle(GlassButtonStyle(shape: .capsule, style: .regular))
                                    }
                                } else {
                                    Text("Coming Soon")
                                        .font(.headline)
                                        .padding(.horizontal, 24)
                                        .padding(.vertical, 14)
                                        .glassEffect(.regular, in: .capsule)
                                }
                            }
                            .padding(.top, 10)
                        }
                        .padding(.horizontal, 60)
                        .padding(.bottom, 60)
                        .frame(maxWidth: 800, alignment: .leading)
                        
                        // Starring (Bottom Right)
                        VStack(alignment: .trailing, spacing: 4) {
                            if let cast = displayItem.cast?.prefix(3) {
                                Text("Starring")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ForEach(cast) { member in
                                    Text(member.name)
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.white.opacity(0.8))
                                }
                            }
                        }
                        .padding(.trailing, 60)
                        .padding(.bottom, 60)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                    .frame(height: geo.size.height * 0.80)
                    
                    // MARK: - 2. Horizontal Content Rails
                    VStack(alignment: .leading, spacing: 40) {
                        
                        // Season Header & Episodes Rail
                        if displayItem.category == "TV Show" {
                            VStack(alignment: .leading, spacing: 16) {
                                if let seasons = displayItem.seasons, !seasons.isEmpty {
                                    Button {
                                        showSeasonPopover.toggle()
                                    } label: {
                                        HStack(spacing: 8) {
                                            Text(selectedSeason?.name ?? "Season 1")
                                                .font(.headline)
                                                .fontWeight(.bold)
                                                .foregroundStyle(.white)
                                            Image(systemName: "chevron.down")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .glassEffect(.regular.interactive(), in: .capsule)
                                        .contentShape(Rectangle()) // Ensure hit area
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 60)
                                    .popover(isPresented: $showSeasonPopover, arrowEdge: .bottom) {
                                        SeasonSelectionList(seasons: seasons, selectedSeason: selectedSeason) { season in
                                            selectedSeason = season
                                            showSeasonPopover = false
                                            Task { await loadEpisodes(for: season) }
                                        }
                                    }
                                }
                                
                                // Episodes: 16:9 Rounded-Rect Cards
                                DetailRail(items: episodes, idPath: \.id, itemWidth: 380, itemHeight: 230) { episode in
                                    Button(action: {
                                        PlayerManager.shared.play(displayItem, season: selectedSeason?.seasonNumber, episode: episode.episodeNumber, episodeImage: episode.stillURL)
                                        openWindow(id: "player", value: displayItem.id)
                                    }) {
                                        LiquidEpisodeCard(episode: episode, progress: getEpisodeProgress(episode))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        
                        // Related Rail: 2:3 Vertical Posters
                        if !relatedItems.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionHeader(title: "Related", destination: MediaListView(title: "Related", type: .fixed(title: "Related", items: relatedItems)))
                                    .padding(.horizontal, 60)
                                    
                                
                                DetailRail(items: relatedItems, idPath: \.id, itemWidth: 160, itemHeight: 240) { item in
                                   NavigationLink(value: item) {
                                       GlassCard(item: item, aspectRatio: .portrait, showTitle: false)
                                           .frame(width: 160, height: 240)
                                   }
                                   .buttonStyle(.plain)
                                }
                            }
                        }
                        
                        // Cast Rail: Circular Avatars
                        if let cast = displayItem.cast, !cast.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionHeader(title: "Cast & Crew", destination: CastListView(cast: cast))
                                    .padding(.horizontal, 60)
                                
                                DetailRail(items: cast, idPath: \.id, itemWidth: 100, itemHeight: 140) { member in
                                    VStack(spacing: 8) {
                                        CastCircle(name: member.name, imageURL: member.imageURL, size: 80)
                                        
                                        VStack(spacing: 2) {
                                            Text(member.name)
                                                .font(.caption)
                                                .fontWeight(.bold)
                                                .foregroundStyle(.white)
                                                .multilineTextAlignment(.center)
                                            Text(member.role ?? "")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .multilineTextAlignment(.center)
                                        }
                                    }
                                    .frame(width: 100)
                                }
                            }
                        }
                    }
                    .padding(.top, 40)
                    .padding(.bottom, 60)
                    
                    // MARK: - 3. Info Grid Footer
                    // MARK: - 3. Info Footer Section
                    VStack(alignment: .leading, spacing: 40) {
                        Divider().background(Color.white.opacity(0.1))

                        // 1. Where to Watch (JustWatch Bridge / Providers)
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Where to Watch")
                                .font(.title3)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                            
                            if enableRichMetadata, let providers = displayItem.watchProviders, !providers.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 20) {
                                        ForEach(providers, id: \.self) { provider in
                                            let destURL = URL(string: "https://www.themoviedb.org/movie/\(displayItem.id)/watch")!
                                            // Ideally we'd use the TMDB /watch/providers link from provider itself if passed along
                                            Link(destination: destURL) {
                                                VStack(spacing: 8) {
                                                    if let logo = provider.logoURL {
                                                        AsyncImage(url: logo) { image in
                                                            image.resizable()
                                                                .aspectRatio(contentMode: .fit)
                                                        } placeholder: {
                                                            Color.gray.opacity(0.3)
                                                        }
                                                        .frame(width: 60, height: 60)
                                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                                    }
                                                    Text(provider.name)
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(1)
                                                        .frame(width: 60)
                                                }
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                            
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
                        .padding(.horizontal, 60)

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
                        .padding(.horizontal, 60)
                        
                        // 3. Information Grid
                        HStack(alignment: .top, spacing: 60) {
                            // Column 1: Information
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
                            
                            // Column 2: Languages
                            VStack(alignment: .leading, spacing: 20) {
                                Text("Languages")
                                    .font(.headline).fontWeight(.semibold)
                                    .foregroundStyle(.white)
                                
                                VStack(alignment: .leading, spacing: 16) {
                                    InfoDetailRow(label: "Original Audio", value: "English") // Mock/Infer
                                    InfoDetailRow(label: "Audio", value: displayItem.spokenLanguages?.joined(separator: ", ") ?? "English")
                                    InfoDetailRow(label: "Subtitles", value: displayItem.spokenLanguages?.joined(separator: ", ") ?? "English") // Mock same as audio for now
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            
                            // Column 3: Accessibility
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
                        .padding(.horizontal, 60)
                        .padding(.bottom, 80)
                    }
                    .background(Color.black.opacity(0.5))
                }
            }
        }
        .background(Color.black)
        .ignoresSafeArea(edges: .top)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // Force separation between Back (Leading) and Share (Trailing)
                Spacer()
            }
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: URL(string: "https://www.stremio.com/app/detail/\(displayItem.category == "TV Show" ? "series" : "movie")/\(displayItem.id)")!) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(.white)
                }
            }
        }
        .task {
            await loadDetails()
            preloadContent()
        }
    }
    
    // Trigger background preloading for instant playback
    private func preloadContent() {
        guard let item = fullItem else { return }
        Task {
            if item.category == "TV Show" {
                // Preload first episode of selected season
                if let season = selectedSeason?.seasonNumber, let episode = episodes.first?.episodeNumber {
                    print("[DetailView] Preloading streams for S\(season):E\(episode)")
                    await StreamManager.shared.preloadStreams(for: item, season: season, episode: episode)
                }
            } else {
                print("[DetailView] Preloading streams for Movie")
                await StreamManager.shared.preloadStreams(for: item)
            }
        }
    }
    
    // MARK: - Logic
    // Mock progress - replace with actual UserDataService call later
    func getEpisodeProgress(_ episode: Episode?) -> Double {
        // Return 0.0 for now, or check UserDataService if implemented
        return 0.0
    }
    
    private func loadDetails() async {
        do {
            let type = item.category == "TV Show" ? "series" : "movie"
            
            let detailedItem = try await StremioService.shared.fetchMeta(type: type, id: item.id)
            fullItem = detailedItem
            
            if enableRichMetadata {
                if let enriched = await TMDBEnricher.shared.enrichContent(imdbID: item.id, category: item.category) {
                    fullItem?.cast = enriched.cast
                    fullItem?.watchProviders = enriched.providers
                    if let newHero = enriched.heroURL {
                        fullItem?.heroURL = newHero
                    }
                    if let newSeasons = enriched.seasons {
                        fullItem?.seasons = newSeasons
                    }
                }
            }
            
            if type == "series" {
                if let seasons = detailedItem.seasons, let first = seasons.first(where: { $0.seasonNumber > 0 }) ?? seasons.first {
                    selectedSeason = first
                    await loadEpisodes(for: first)
                }
            }
            
            let related = try? await StremioService.shared.fetchRelated(type: type, genres: detailedItem.genres)
            relatedItems = Array(related?.filter { $0.id != detailedItem.id }.shuffled().prefix(10) ?? [])
            
            // Cinemeta does not return watch providers out of the box
            isLoadingDetails = false
        } catch {
            print(error)
            isLoadingDetails = false
        }
    }
    
    private func loadEpisodes(for season: Season) async {
        guard let allEpisodes = fullItem?.episodes else { return }
        self.episodes = allEpisodes.filter { $0.seasonNumber == season.seasonNumber }
            .sorted { $0.episodeNumber < $1.episodeNumber }
        
        if let first = self.episodes.first { heroEpisode = first }
    }
}

// MARK: - Local Components

struct TechBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.thinMaterial)
            .cornerRadius(4)
    }
}

// Detail Row with small label, normal value
struct InfoDetailRow: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline).fontWeight(.semibold).foregroundStyle(.secondary)
            Text(value).font(.body).foregroundStyle(.white.opacity(0.9))
        }
    }
}

// Block for long text (Accessibility)
struct InfoDetailBlock: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .fontWeight(.bold)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary, lineWidth: 1))
                .foregroundStyle(.secondary)
            
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// 16:9 Liquid Card for Episodes
struct LiquidEpisodeCard: View {
    let episode: Episode
    let progress: Double // 0.0 to 1.0
    @State private var isHovering = false
    
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
                            Capsule().fill(Color.white).frame(width: 40, height: 4) // Mock specific width
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
                            // TODO: Implement Mark Watched
                        } label: { Label("Mark as Watched", systemImage: "checkmark.circle") }
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
        .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 5)
        .scaleEffect(isHovering ? 1.02 : 1.0)
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
                HStack(spacing: 24) { // Switched to HStack for accurate contentSize
                    ForEach(Array(items.enumerated()), id: \.offset) { enumeration in
                        content(enumeration.element)
                            .id(enumeration.offset)
                    }
                }
                .padding(.horizontal, 60)
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
                        .padding(.leading, 20)
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
            .background(.ultraThinMaterial)
            .cornerRadius(32)
            .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
            .shadow(radius: 10)
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

