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
    @AppStorage("enableRichMetadata") private var enableRichMetadata = false
    
    // Derived IDs
    @State private var activeImdbID: String? = nil
    @ObservedObject private var dataManager = DataManager.shared
    @ObservedObject private var userData = UserDataService.shared
    @Environment(\.openWindow) private var openWindow
    
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
                                }
                                
                                Button(action: {
                                    userData.toggleWatchlist(displayItem)
                                }) {
                                    Image(systemName: userData.isInWatchlist(displayItem) ? "checkmark" : "plus")
                                        .font(.title3)
                                        .foregroundStyle(.white)
                                        .padding(14)
                                        .glassEffect(.regular.interactive(), in: .circle)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.top, 10)
                        }
                        .padding(.leading, 60)
                        .padding(.bottom, 60)
                    }
                    .frame(height: geo.size.height * 0.80)
                    
                    VStack(alignment: .leading, spacing: 40) {
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
                            .padding(.horizontal, 60)
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
                            .padding(.horizontal, 60)
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
                        .padding(.horizontal, 60)
                        
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
        }
    }
    
    func getEpisodeProgress(_ episode: Episode?) -> Double {
        return 0.0
    }
    
    private func loadDetails() async {
        do {
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
            
            // 2. Fetch Stremio/Cinemeta Metadata
            var detailedItem = try await StremioService.shared.fetchMeta(type: type, id: fetchID)
            
            // 3. Optional TMDB Enrichment Layer
            if enableRichMetadata {
                detailedItem = await TMDBEnricher.shared.enrichMediaItem(detailedItem)
            }
            
            fullItem = detailedItem
            
            if type == "series" {
                if let seasons = detailedItem.seasons, let first = seasons.first(where: { $0.seasonNumber > 0 }) ?? seasons.first {
                    selectedSeason = first
                    await loadEpisodes(for: first)
                }
            }
            
            let related = try? await StremioService.shared.fetchRelated(type: type, genres: detailedItem.genres)
            relatedItems = Array(related?.filter { $0.id != detailedItem.id }.shuffled().prefix(10) ?? [])
            isLoadingDetails = false
        } catch {
            print("Error loading detailed metadata: \(error)")
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

// MARK: - Detail Specific Components
struct DetailRail<T: Identifiable, Content: View>: View {
    let items: [T]
    let idPath: KeyPath<T, T.ID>? = nil // Re-using standard Identifiable
    let itemWidth: CGFloat
    let itemHeight: CGFloat
    let content: (T) -> Content
    
    // Explicitly using standard ForEach which works on Identifiable
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 24) {
                ForEach(items) { item in
                    content(item)
                }
            }
            .padding(.horizontal, 60)
        }
    }
}

extension DetailRail where T: Identifiable {
    init(items: [T], idPath: KeyPath<T, T.ID>, itemWidth: CGFloat, itemHeight: CGFloat, @ViewBuilder content: @escaping (T) -> Content) {
        self.items = items
        self.itemWidth = itemWidth
        self.itemHeight = itemHeight
        self.content = content
    }
}

struct LiquidEpisodeCard: View {
    let episode: Episode
    let progress: Double
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Thumbnail
            ZStack(alignment: .bottomLeading) {
                CachedImage(url: episode.stillURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Rectangle().fill(Color.gray.opacity(0.2))
                    }
                }
                .frame(width: 380, height: 214)
                .clipped()
                .cornerRadius(12)
                
                // Progress Bar
                if progress > 0 {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.3)).frame(height: 4)
                        Capsule().fill(Color.red).frame(width: 380 * progress, height: 4)
                    }
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("\(episode.episodeNumber). \(episode.name)")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(episode.airDate ?? "Unknown Date")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 380)
    }
}
