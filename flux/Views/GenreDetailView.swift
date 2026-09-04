import SwiftUI

/// Dedicated genre browsing view featuring curated discovery rails
/// (Trending, Top Rated, Popular, New Releases) with Movies/TV Shows switcher
/// and "See All" full-grid drill-down.
struct GenreDetailView: View {
    let genre: GenreNavigation

    @State private var mediaType: String = "movie"
    @State private var railsData = TMDBEnricher.GenreRailsData()
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Header: Genre Title + Movies / TV Shows switcher
                HStack(spacing: 20) {
                    Text(genre.name)
                        .font(.system(size: 44, weight: .heavy))
                        .foregroundStyle(.white)

                    mediaTypeToggle

                    Spacer()
                }
                .padding(.leading, 268)
                .padding(.trailing, 40)
                .padding(.top, 48)

                if isLoading {
                    loadingRails
                } else if railsData.isEmpty {
                    emptyState
                } else {
                    railsContent
                }
            }
            .padding(.top, 40)
            .padding(.bottom, 60)
        }
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
            .padding(.top, 24)
        }
        .navigationBarBackButtonHidden(true)
        .toolbarVisibility(.hidden, for: .windowToolbar)
        .background(
            Color.black
                .ignoresSafeArea()
        )
        .task(id: mediaType) {
            await loadRails()
        }
        .refreshable {
            await TMDBCatalogCacheActor.shared.clear()
            await loadRails()
        }
        .onReceive(NotificationCenter.default.publisher(for: .fluxRefresh)) { _ in
            Task {
                await TMDBCatalogCacheActor.shared.clear()
                await loadRails()
            }
        }
    }

    // MARK: - Movies / TV Shows Switcher

    @ViewBuilder
    private var mediaTypeToggle: some View {
        HStack(spacing: 0) {
            ForEach(["movie", "tv"], id: \.self) { mt in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if mediaType != mt {
                            mediaType = mt
                        }
                    }
                } label: {
                    Text(mt == "movie" ? "Movies" : "TV Shows")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(mediaType == mt ? .black : .white.opacity(0.7))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(mediaType == mt ? Color.white : Color.white.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Rails Content

    @ViewBuilder
    private var railsContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            if !railsData.trending.isEmpty {
                renderRail(
                    title: "Trending in \(genre.name)",
                    category: "trending",
                    items: railsData.trending
                )
            }

            if !railsData.topRated.isEmpty {
                renderRail(
                    title: "Top Rated",
                    category: "top_rated",
                    items: railsData.topRated
                )
            }

            if !railsData.popular.isEmpty {
                renderRail(
                    title: "Popular Hits",
                    category: "popular",
                    items: railsData.popular
                )
            }

            if !railsData.newReleases.isEmpty {
                renderRail(
                    title: "New Releases",
                    category: "new_releases",
                    items: railsData.newReleases
                )
            }
        }
    }

    @ViewBuilder
    private func renderRail(title: String, category: String, items: [MediaItem]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ListSectionHeader(
                title: title,
                value: MediaListView.ListType.genreCategory(
                    id: genre.id,
                    name: genre.name,
                    category: category,
                    categoryTitle: title
                )
            )
            .padding(.leading, 268)
            .padding(.trailing, 40)

            CarouselView(items: items) { item in
                NavigationLink(value: item) {
                    GlassCard(item: item, aspectRatio: .portrait, showTitle: false)
                        .frame(width: 180)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: - Loading & Empty States

    @ViewBuilder
    private var loadingRails: some View {
        VStack(alignment: .leading, spacing: 40) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 16) {
                    GhostRect(height: 22)
                        .frame(width: 180)
                        .padding(.leading, 268)

                    HStack(spacing: 20) {
                        ForEach(0..<6, id: \.self) { _ in
                            GhostCard()
                                .frame(width: 180)
                        }
                    }
                    .padding(.leading, 268)
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No \(mediaType == "tv" ? "TV shows" : "movies") found in \(genre.name)")
                .font(.title3)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding(.leading, 268)
        .padding(.trailing, 40)
    }

    // MARK: - Data Fetching

    private func loadRails() async {
        isLoading = true
        let fetched = await TMDBEnricher.shared.fetchGenreRails(tmdbGenreID: genre.id, mediaType: mediaType)
        await MainActor.run {
            self.railsData = fetched
            self.isLoading = false
        }
    }
}
