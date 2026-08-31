import SwiftUI

struct ContinueWatchingCard: View {
    enum Mode {
        case continueWatching
        case recentlyWatched
    }

    let item: MediaItem
    var mode: Mode = .continueWatching

    @State private var isHovering = false
    @ObservedObject private var userData = UserDataService.shared
    @Environment(\.openWindow) private var openWindow

    @State private var fetchedImage: URL?
    @State private var fetchedRuntime: String?
    @State private var fetchedLogo: URL?

    /// Full thumbnail ladder — CachedImage walks it and only shows the
    /// placeholder if EVERY candidate fails.
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

    private var activeLogoURL: URL? {
        if let logo = item.logoURL { return logo }
        if let logo = fetchedLogo { return logo }
        if !TMDBEnricher.shared.hasKey, item.id.starts(with: "tt") {
            return URL(string: "https://images.metahub.space/logo/medium/\(item.id)/img")
        }
        return nil
    }

    private var subtitleText: String {
        var parts: [String] = []
        if let season = item.lastSeason, let episode = item.lastEpisode {
            parts.append("S\(season), E\(episode)")
        }
        if let rt = fetchedRuntime ?? item.runtime, !rt.isEmpty {
            parts.append(rt)
        } else if item.lastSeason == nil, let year = item.releaseDateYear, !year.isEmpty {
            parts.append(year)
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        ZStack {
            // Background Image
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
            .frame(width: 290, height: 163)
            .clipped()

            // Gradient Overlay for Text & Logo Legibility
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .clear, location: 0.30),
                    .init(color: .black.opacity(0.45), location: 0.65),
                    .init(color: .black.opacity(0.90), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Content Overlay
            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                // Title Treatment: Transparent Logo with Typographic Fallback
                Group {
                    if let logo = activeLogoURL {
                        CachedImage(url: logo) { phase in
                            switch phase {
                            case .success(let img):
                                img
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: 160, maxHeight: 36, alignment: .leading)
                                    .shadow(color: .black.opacity(0.85), radius: 4, x: 0, y: 2)
                            default:
                                fallbackTitleText
                            }
                        }
                    } else {
                        fallbackTitleText
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 6)

                // Subtitle / Bottom Control Row
                HStack(spacing: 8) {
                    if mode == .continueWatching {
                        // Play triangle
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)

                        // Real Progress capsule bar
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.35))
                                .frame(width: 52, height: 4)

                            if let progress = item.progress, progress > 0 {
                                Capsule()
                                    .fill(Color.white)
                                    .frame(width: 52 * max(min(progress, 1.0), 0.08), height: 4)
                            }
                        }
                    } else {
                        // Replay circular arrow
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.8))
                    }

                    if !subtitleText.isEmpty {
                        Text(subtitleText)
                            .font(.system(size: 12, weight: mode == .continueWatching ? .semibold : .medium))
                            .foregroundStyle(mode == .continueWatching ? .white.opacity(0.95) : .white.opacity(0.8))
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                    }

                    Spacer()

                    // Ellipsis Context Menu Button
                    Menu {
                        Button {
                            PlayerManager.shared.play(
                                item,
                                season: item.lastSeason,
                                episode: item.lastEpisode,
                                episodeImage: item.lastEpisodeImage,
                                fromContinueWatching: true
                            )
                            openWindow(id: "player", value: item.id)
                        } label: {
                            Label(mode == .continueWatching ? "Resume" : "Play Again",
                                  systemImage: mode == .continueWatching ? "play.fill" : "arrow.counterclockwise")
                        }

                        Button {
                            PlayerManager.shared.play(
                                item,
                                season: item.lastSeason,
                                episode: item.lastEpisode,
                                episodeImage: item.lastEpisodeImage,
                                fromContinueWatching: false,
                                forceStreamPicker: true
                            )
                            openWindow(id: "player", value: item.id)
                        } label: {
                            Label("Choose Stream Source…", systemImage: "list.bullet.rectangle")
                        }

                        Button {
                            userData.toggleWatchlist(item)
                        } label: {
                            let isInWatchlist = userData.isInWatchlist(item)
                            Label(isInWatchlist ? "Remove from Watchlist" : "Add to Watchlist",
                                  systemImage: isInWatchlist ? "bookmark.slash" : "bookmark")
                        }

                        Divider()

                        Button(role: .destructive) {
                            userData.removeFromHistory(item)
                        } label: {
                            Label(mode == .continueWatching ? "Remove from Continue Watching" : "Remove from History",
                                  systemImage: "xmark.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(isHovering ? 1.0 : 0.75))
                            .padding(4)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
        .frame(width: 290, height: 163)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: isHovering ? [.white.opacity(0.55), .white.opacity(0.2)] : [.white.opacity(0.1), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isHovering ? 1.5 : 0.75
                )
        )
        .shadow(color: isHovering ? Color.black.opacity(0.55) : Color.black.opacity(0.25), radius: isHovering ? 14 : 8, x: 0, y: isHovering ? 6 : 4)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(.easeOut(duration: 0.2), value: isHovering)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(mode == .continueWatching ? "Continue watching" : "Recently watched"), \(subtitleText)")
        .accessibilityHint("Resumes playback")
        .id("\(item.id)-\(item.lastSeason ?? 0)-\(item.lastEpisode ?? 0)")
        .task(id: "\(item.id)-\(item.lastSeason ?? 0)-\(item.lastEpisode ?? 0)") {
            let isTV = item.category == "TV Show" || item.lastSeason != nil
            let type = isTV ? "tv" : "movie"

            var tmdbIDToUse: String? = nil
            if CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: item.id)) {
                tmdbIDToUse = item.id
            } else if item.id.starts(with: "tt") {
                tmdbIDToUse = await TMDBEnricher.shared.resolveTmdbID(imdbID: item.id, type: type)
            }

            if let id = tmdbIDToUse {
                // Fetch TMDB logo if not already set
                if fetchedLogo == nil && (item.logoURL == nil || item.logoURL?.absoluteString.contains("tmdb.org") == false) {
                    if let logo = await TMDBEnricher.shared.fetchLogoURL(tmdbID: id, type: type) {
                        await MainActor.run { self.fetchedLogo = logo }
                    }
                }

                if isTV, let season = item.lastSeason, let episode = item.lastEpisode {
                    if fetchedImage == nil || fetchedRuntime == nil {
                        let info = await TMDBEnricher.shared.fetchEpisodeInfo(tmdbID: id, season: season, episode: episode)
                        await MainActor.run {
                            if let still = info.stillURL { self.fetchedImage = still }
                            if let rt = info.runtime { self.fetchedRuntime = rt }
                        }
                    }
                } else if !isTV {
                    // Movie: fetch runtime if not already present
                    if (item.runtime == nil || item.runtime?.isEmpty == true) && fetchedRuntime == nil {
                        if let rt = await TMDBEnricher.shared.fetchMovieRuntime(tmdbID: id) {
                            await MainActor.run { self.fetchedRuntime = rt }
                        }
                    }
                }
            }
        }
    }

    private var fallbackTitleText: some View {
        Text(item.title)
            .font(.system(size: mode == .continueWatching ? 15 : 14, weight: mode == .continueWatching ? .bold : .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
    }
}
