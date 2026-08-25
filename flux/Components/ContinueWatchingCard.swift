import SwiftUI

struct ContinueWatchingCard: View {
    let item: MediaItem
    @State private var isHovering = false
    @ObservedObject private var userData = UserDataService.shared
    
    @State private var fetchedImage: URL?

    /// Full thumbnail ladder — CachedImage walks it and only shows the
    /// placeholder if EVERY candidate fails. Selection-time fallbacks that
    /// 404 at load time used to kill the whole chain.
    private var imageCandidates: [URL] {
        let cinemetaBackdrop = item.id.starts(with: "tt") ? URL(string: "https://images.metahub.space/background/medium/\(item.id)/img") : nil
        let cinemetaPoster = item.id.starts(with: "tt") ? URL(string: "https://images.metahub.space/poster/medium/\(item.id)/img") : nil

        func upgraded(_ url: URL?) -> URL? {
            guard var urlString = url?.absoluteString else { return nil }
            if urlString.contains("image.tmdb.org") {
                urlString = urlString.replacingOccurrences(of: "/w300/", with: "/w1280/")
                                     .replacingOccurrences(of: "/w500/", with: "/w1280/")
                                     .replacingOccurrences(of: "/w780/", with: "/w1280/")
            }
            if urlString.contains("images.metahub.space") || urlString.contains("episodes.metahub.space") {
                urlString = urlString.replacingOccurrences(of: "/small/", with: "/large/")
                                     .replacingOccurrences(of: "/medium/", with: "/large/")
                                     .replacingOccurrences(of: "/w780/", with: "/w1280/")
            }
            return URL(string: urlString)
        }

        var seen = Set<String>()
        var out: [URL] = []
        for candidate in [fetchedImage, item.lastEpisodeImage, item.backdropURL, item.heroURL, cinemetaBackdrop, item.posterURL, item.imageURL, cinemetaPoster] {
            if let url = upgraded(candidate), seen.insert(url.absoluteString).inserted {
                out.append(url)
            }
        }
        return out
    }

    var body: some View {
        ZStack {
            // Background Image — walks the candidate ladder on failure
            CachedImage(
                url: imageCandidates.first,
                fallbacks: Array(imageCandidates.dropFirst()),
                maxDimension: 600
            ) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                default:
                    // Every candidate failed — deterministic placeholder, never a spinner.
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.18, green: 0.20, blue: 0.32), Color(red: 0.05, green: 0.06, blue: 0.12)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            Image(systemName: "film.stack")
                                .font(.system(size: 32))
                                .foregroundStyle(.white.opacity(0.25))
                        )
                }
            }
            .frame(width: 280, height: 157.5) // 16:9 Aspect Ratio
            .clipped()
            
            // Gradient Overlay
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black.opacity(0.2), location: 0.5),
                    .init(color: .black.opacity(0.8), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            
            // Hover Overlay (Dim + Play Button)
            if isHovering {
                Color.black.opacity(0.3)
                    .transition(.opacity)
                
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.white)
                    .shadow(radius: 10)
                    .transition(.scale.combined(with: .opacity))
            }
            
            // Text & Progress Content
            VStack {
                // Top Right Menu (Visible on Hover)
                HStack {
                    Spacer()
                    if isHovering {
                        Menu {
                            Button(action: {
                                userData.toggleWatchlist(item)
                            }) {
                                let isInWatchlist = userData.isInWatchlist(item)
                                Label(isInWatchlist ? "Remove from Watchlist" : "Add to Watchlist",
                                      systemImage: isInWatchlist ? "minus.circle" : "plus.circle")
                            }
                            
                            Divider()
                            
                            Button(role: .destructive, action: {
                                userData.removeFromHistory(item)
                            }) {
                                Label("Remove from Continue Watching", systemImage: "xmark.circle")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                                .padding(8)
                                .glassEffect(.regular.interactive(), in: .circle)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }
                }
                .padding(8)
                
                Spacer()
                
                // Bottom Metadata
                VStack(alignment: .leading, spacing: 4) {
                    
                    // Show Title Only (Clean Look) or Episode Logic?
                    // User requested "Same S, E, time".
                    
                    // Logo/Title area
                    if let season = item.lastSeason, let episode = item.lastEpisode {
                        Text(item.title) // Show Title
                            .font(.headline)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .shadow(radius: 2)
                        
                        HStack(spacing: 6) {
                            Text("S\(season):E\(episode)")
                                .fontWeight(.semibold)
                            if let time = item.progress, time > 0 {
                                // We don't have total duration stored nicely to verify "50m" left easily without extra fields.
                                // For now just showing "Resume" or "XX%".
                                // User asked for "time". We stored progress (0.0-1.0).
                                // To show "50m" we need (1.0 - progress) * duration. We didn't store duration.
                                // Future improvement: Store duration. For now, mimic style.
                                Text("•")
                                Text("Resume")
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.9))
                        .shadow(radius: 2)
                    } else {
                        // Fallback for movies / no history data yet
                       Text(item.title)
                            .font(.headline)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .shadow(radius: 2)
                        
                       if item.category == "Movie" {
                            Text(item.releaseDateYear ?? "Movie")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.9))
                       }
                    }
                    
                    // Progress Bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            // Track
                            Capsule()
                                .fill(Color.white.opacity(0.3))
                                .frame(height: 4)
                            
                            // Fill (Apple TV White Progress)
                            if let progress = item.progress {
                                Capsule()
                                    .fill(Color.white)
                                    .frame(width: geo.size.width * max(progress, 0.05), height: 4)
                            }
                        }
                    }
                    .frame(height: 4)
                    .padding(.top, 4)
                }
                .padding(12)
            }
        }
        .frame(width: 280, height: 157.5)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    LinearGradient(
                        colors: isHovering ? [.white.opacity(0.5), .white.opacity(0.15)] : [.white.opacity(0.1), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isHovering ? 1.5 : 0.5
                )
        )
        .shadow(color: isHovering ? Color.black.opacity(0.5) : Color.black.opacity(0.25), radius: isHovering ? 16 : 8, x: 0, y: isHovering ? 10 : 4)
        .contentShape(Rectangle())
        .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.7), value: isHovering)
        .onHover { isHovering = $0 }
        .id("\(item.id)-\(item.lastSeason ?? 0)-\(item.lastEpisode ?? 0)")
        .task(id: "\(item.id)-\(item.lastSeason ?? 0)-\(item.lastEpisode ?? 0)") {
            fetchedImage = nil
            // Priority: Resolve thumbnails for TV Shows (especially Trakt sync items)
            if item.category == "TV Show",
               let season = item.lastSeason,
               let episode = item.lastEpisode {
                
                var tmdbIDToUse: String? = nil
                
                // Case 1: ID is already numerical (TMDB ID)
                if CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: item.id)) {
                    tmdbIDToUse = item.id
                } 
                // Case 2: ID is IMDb ID (Trakt Sync)
                else if item.id.starts(with: "tt") {
                    tmdbIDToUse = await TMDBEnricher.shared.resolveTmdbID(imdbID: item.id, type: "tv")
                }
                
                if let id = tmdbIDToUse {
                    if let stillURL = await TMDBEnricher.shared.fetchEpisodeStill(tmdbID: id, season: season, episode: episode) {
                        await MainActor.run {
                            self.fetchedImage = stillURL
                        }
                    }
                }
            }
        }
    }
}
