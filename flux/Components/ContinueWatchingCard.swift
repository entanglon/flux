import SwiftUI

struct ContinueWatchingCard: View {
    let item: MediaItem
    @State private var isHovering = false
    @ObservedObject private var userData = UserDataService.shared
    
    @State private var fetchedImage: URL?
    
    var DisplayImage: URL? {
        let rawURL = fetchedImage ?? item.lastEpisodeImage ?? item.heroURL ?? item.backdropURL ?? item.posterURL ?? item.imageURL
        guard let url = rawURL else { return nil }
        
        var urlString = url.absoluteString
        
        // Force high-res for TMDB image URLs
        if urlString.contains("image.tmdb.org") {
            urlString = urlString.replacingOccurrences(of: "/w300/", with: "/w1280/")
                                 .replacingOccurrences(of: "/w500/", with: "/w1280/")
                                 .replacingOccurrences(of: "/w780/", with: "/w1280/")
        }
        
        // Force high-res for Cinemeta / Metahub URLs
        if urlString.contains("images.metahub.space") {
            urlString = urlString.replacingOccurrences(of: "/small/", with: "/large/")
                                 .replacingOccurrences(of: "/medium/", with: "/large/")
        }
        
        return URL(string: urlString) ?? url
    }
    
    var body: some View {
        ZStack {
            // Background Image
            CachedImage(url: DisplayImage, maxDimension: 600) { phase in
                switch phase {
                case .empty:
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .overlay(ProgressView().controlSize(.small))
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure:
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .overlay(Image(systemName: "photo").foregroundColor(.secondary))
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: 280, height: 157.5) // 16:9 Aspect Ratio
            .clipped()
            .task {
                // Ensure TMDB Enriched Image for TV Shows
                if item.category == "TV Show",
                   let season = item.lastSeason,
                   let episode = item.lastEpisode {
                    do {
                        // Check if we already have it in history nicely
                        // Need to fetch TMDB ID
                        if let enriched = await TMDBEnricher.shared.enrichContent(imdbID: item.id, category: item.category),
                           let tmdbId = enriched.tmdbID {
                            let details = try await TMDBClient.shared.fetchSeasonDetails(tvId: tmdbId, seasonNumber: season)
                            if let ep = details.episodes.first(where: { $0.episodeNumber == episode }),
                               let path = ep.stillPath {
                                fetchedImage = URL(string: "https://image.tmdb.org/t/p/w1280\(path)")
                            } else if let backdrop = enriched.heroURL {
                                fetchedImage = backdrop
                            }
                        }
                    } catch {
                        print("Failed to fetch episode still: \(error)")
                    }
                } else if item.category == "Movie" {
                    // For movies, prioritize hero backdrop
                    do {
                        if let enriched = await TMDBEnricher.shared.enrichContent(imdbID: item.id, category: item.category),
                           let backdrop = enriched.heroURL {
                            fetchedImage = backdrop
                        }
                    } catch { }
                }
            }
            
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
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
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
                            
                            // Fill
                            if let progress = item.progress {
                                Capsule()
                                    .fill(Color.red) // Netflix Red
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
        .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 4)
        .onHover { isHovering = $0 }
    }
}
