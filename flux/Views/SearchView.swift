import SwiftUI

struct SearchView: View {
    @StateObject private var viewModel = SearchViewModel()
    @FocusState private var isSearchFocused: Bool
    @ObservedObject private var recentManager = RecentSearchManager.shared
    @ObservedObject private var languageManager = LanguageManager.shared

    // Grid for Search Results
    let resultColumns = [
        GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 24)
    ]

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    // Toolbar clearance height
                    Color.clear.frame(height: 52)

                    if viewModel.isSearching {
                        if viewModel.isLoading && viewModel.searchResults.isEmpty && viewModel.personResults.isEmpty {
                            LazyVGrid(columns: resultColumns, spacing: 24) {
                                ForEach(0..<12, id: \.self) { _ in
                                    GhostCard()
                                }
                            }
                            .padding(.leading, 268)
                            .padding(.trailing, 40)
                            .transition(.opacity)
                        } else if viewModel.searchResults.isEmpty && viewModel.personResults.isEmpty {
                            VStack(spacing: 16) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 48))
                                    .foregroundStyle(.secondary)
                                Text("No results found".localized)
                                    .font(.title3)
                                    .fontWeight(.medium)
                                Text("Try searching for something else".localized)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 300)
                            .padding(.leading, 268)
                            .padding(.trailing, 40)
                            .transition(.opacity)
                        } else {
                            searchResultsContent
                                .transition(.opacity)
                        }
                    } else {
                        defaultBrowseView
                            .transition(.opacity)
                    }
                }
                .padding(.bottom, 60)
            }

            // Floating Apple TV Liquid Glass Search Bar Capsule
            VStack(spacing: 0) {
                HStack {
                    Spacer()

                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(isSearchFocused ? .cyan : .white.opacity(0.75))

                        TextField("Search".localized, text: $viewModel.query)
                            .font(.system(size: 15, weight: .medium))
                            .textFieldStyle(.plain)
                            .foregroundStyle(.white)
                            .focused($isSearchFocused)
                            .onSubmit {
                                viewModel.commitSearch()
                            }

                        if !viewModel.query.isEmpty {
                            Button(action: {
                                viewModel.clear()
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.white.opacity(0.65))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(width: isSearchFocused ? 520 : 460, height: 42)
                    .glassEffect(
                        .regular.interactive(),
                        in: .capsule
                    )
                    .contentShape(Capsule())
                    .onTapGesture { isSearchFocused = true }
                    .scaleEffect(isSearchFocused ? 1.01 : 1.0)
                    .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isSearchFocused)

                    Spacer()
                }
            }
            .padding(.leading, 244)
            .padding(.top, 14)
        }
        .navigationBarBackButtonHidden(true)
        .onAppear {
            isSearchFocused = true
            Task {
                await SearchEngine.shared.indexUserAndTrendingData()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fluxRefresh)) { _ in
            Task {
                await SearchEngine.shared.indexUserAndTrendingData()
                if !viewModel.query.isEmpty {
                    viewModel.commitSearch()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fluxFocusSearch)) { _ in
            isSearchFocused = true
        }
    }

    // MARK: - Search Results Content

    @ViewBuilder
    private var searchResultsContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            // Scope Pills (when multiple result types exist)
            if hasMultipleCategories {
                scopeFilterPills
                    .padding(.leading, 268)
                    .padding(.trailing, 40)
            }

            switch viewModel.selectedScope {
            case .all:
                if hasMultipleCategories {
                    allRailsView
                } else if !viewModel.movieResults.isEmpty {
                    moviesGridView
                        .padding(.leading, 268)
                        .padding(.trailing, 40)
                } else if !viewModel.seriesResults.isEmpty {
                    seriesGridView
                        .padding(.leading, 268)
                        .padding(.trailing, 40)
                } else {
                    peopleGridView
                        .padding(.leading, 268)
                        .padding(.trailing, 40)
                }
            case .movies:
                moviesGridView
                    .padding(.leading, 268)
                    .padding(.trailing, 40)
            case .series:
                seriesGridView
                    .padding(.leading, 268)
                    .padding(.trailing, 40)
            case .people:
                peopleGridView
                    .padding(.leading, 268)
                    .padding(.trailing, 40)
            }
        }
    }

    // MARK: - Scope Filter Bar

    private var hasMultipleCategories: Bool {
        var count = 0
        if !viewModel.movieResults.isEmpty { count += 1 }
        if !viewModel.seriesResults.isEmpty { count += 1 }
        if !viewModel.personResults.isEmpty { count += 1 }
        return count > 1
    }

    private var scopeFilterPills: some View {
        HStack(spacing: 10) {
            let totalCount = viewModel.searchResults.count + viewModel.personResults.count
            scopeButton(scope: .all, count: totalCount)

            if !viewModel.movieResults.isEmpty {
                scopeButton(scope: .movies, count: viewModel.movieResults.count)
            }

            if !viewModel.seriesResults.isEmpty {
                scopeButton(scope: .series, count: viewModel.seriesResults.count)
            }

            if !viewModel.personResults.isEmpty {
                scopeButton(scope: .people, count: viewModel.personResults.count)
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func scopeButton(scope: SearchScope, count: Int) -> some View {
        let isSelected = viewModel.selectedScope == scope
        return Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                viewModel.selectedScope = scope
            }
        }) {
            HStack(spacing: 6) {
                Text(scope.rawValue.localized)
                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))

                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? .white.opacity(0.9) : .white.opacity(0.45))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(isSelected ? Color.white.opacity(0.2) : Color.white.opacity(0.08))
                    )
            }
            .foregroundStyle(isSelected ? .white : .white.opacity(0.75))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(isSelected ? Color.white.opacity(0.18) : Color.white.opacity(0.06))
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color.white.opacity(0.35) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Carousel Rail Views (Apple TV Style)

    @ViewBuilder
    private var allRailsView: some View {
        VStack(alignment: .leading, spacing: 32) {
            // Reorder rails dynamically based on top result
            let topItem = viewModel.searchResults.first
            let topIsSeries = topItem?.category.lowercased().contains("tv") == true ||
                              topItem?.category.lowercased().contains("series") == true ||
                              topItem?.category.lowercased().contains("show") == true

            if topIsSeries {
                tvShowsRail
                moviesRail
                peopleRail
            } else {
                moviesRail
                tvShowsRail
                peopleRail
            }
        }
    }

    @ViewBuilder
    private var peopleRail: some View {
        if !viewModel.personResults.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                railHeader(title: "People".localized, count: viewModel.personResults.count, scope: .people)
                    .padding(.leading, 268)
                    .padding(.trailing, 40)

                CarouselView(items: viewModel.personResults, spacing: 20, itemWidth: 104) { person in
                    NavigationLink(value: PersonNavigation(id: person.id, fallbackName: person.name)) {
                        PersonSearchCard(person: person)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded {
                        recentManager.add(person.toMediaItem())
                    })
                }
            }
        }
    }

    @ViewBuilder
    private var moviesRail: some View {
        if !viewModel.movieResults.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                railHeader(title: "Movies".localized, count: viewModel.movieResults.count, scope: .movies)
                    .padding(.leading, 268)
                    .padding(.trailing, 40)

                CarouselView(items: viewModel.movieResults, spacing: 18, itemWidth: 180) { item in
                    NavigationLink(value: item) {
                        GlassCard(item: item, aspectRatio: .portrait, showTitle: false)
                            .frame(width: 180)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded {
                        recentManager.add(item)
                    })
                }
            }
        }
    }

    @ViewBuilder
    private var tvShowsRail: some View {
        if !viewModel.seriesResults.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                railHeader(title: "TV Shows".localized, count: viewModel.seriesResults.count, scope: .series)
                    .padding(.leading, 268)
                    .padding(.trailing, 40)

                CarouselView(items: viewModel.seriesResults, spacing: 18, itemWidth: 180) { item in
                    NavigationLink(value: item) {
                        GlassCard(item: item, aspectRatio: .portrait, showTitle: false)
                            .frame(width: 180)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded {
                        recentManager.add(item)
                    })
                }
            }
        }
    }

    private func railHeader(title: String, count: Int, scope: SearchScope) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)

            Spacer()

            if count > 5 {
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        viewModel.selectedScope = scope
                    }
                }) {
                    HStack(spacing: 4) {
                        Text("See All (\(count))".localized)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Category Grid Views

    @ViewBuilder
    private var moviesGridView: some View {
        VStack(alignment: .leading, spacing: 16) {
            if viewModel.selectedScope != .all {
                Text("Movies (\(viewModel.movieResults.count))".localized)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }

            LazyVGrid(columns: resultColumns, spacing: 24) {
                ForEach(viewModel.movieResults) { item in
                    NavigationLink(value: item) {
                        GlassCard(item: item, aspectRatio: .portrait, showTitle: false)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded {
                        recentManager.add(item)
                    })
                }
            }
        }
    }

    @ViewBuilder
    private var seriesGridView: some View {
        VStack(alignment: .leading, spacing: 16) {
            if viewModel.selectedScope != .all {
                Text("TV Shows (\(viewModel.seriesResults.count))".localized)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }

            LazyVGrid(columns: resultColumns, spacing: 24) {
                ForEach(viewModel.seriesResults) { item in
                    NavigationLink(value: item) {
                        GlassCard(item: item, aspectRatio: .portrait, showTitle: false)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded {
                        recentManager.add(item)
                    })
                }
            }
        }
    }

    @ViewBuilder
    private var peopleGridView: some View {
        VStack(alignment: .leading, spacing: 16) {
            if viewModel.selectedScope != .all {
                Text("People (\(viewModel.personResults.count))".localized)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 24)], spacing: 24) {
                ForEach(viewModel.personResults) { person in
                    NavigationLink(value: PersonNavigation(id: person.id, fallbackName: person.name)) {
                        PersonSearchCard(person: person)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded {
                        recentManager.add(person.toMediaItem())
                    })
                }
            }
        }
    }

    private var defaultBrowseView: some View {
        VStack(alignment: .leading, spacing: 32) {
            // Section 0: Recent Search Queries (Chips)
            if !recentManager.recentQueries.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Recent Searches".localized)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)

                        Spacer()

                        Button("Clear All".localized) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                recentManager.clear()
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.blue)
                    }
                    .padding(.leading, 268)
                    .padding(.trailing, 40)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(recentManager.recentQueries, id: \.self) { query in
                                HStack(spacing: 8) {
                                    Button(action: {
                                        viewModel.query = query
                                        viewModel.commitSearch()
                                    }) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "magnifyingglass")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(.white.opacity(0.6))
                                            Text(query)
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .buttonStyle(.plain)

                                    Button(action: {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            recentManager.removeQuery(query)
                                        }
                                    }) {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white.opacity(0.45))
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.08))
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                                )
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .contentMargins(.leading, 268, for: .scrollContent)
                    .contentMargins(.trailing, 40, for: .scrollContent)
                    .scrollClipDisabled()
                }
            }

            // Section 1: Recently Viewed Cards
            if !recentManager.recentItems.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(recentManager.recentQueries.isEmpty ? "Recently Searched".localized : "Recently Viewed".localized)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)

                        Spacer()

                        if recentManager.recentQueries.isEmpty {
                            Button("Clear".localized) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    recentManager.clear()
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.blue)
                        }
                    }
                    .padding(.leading, 268)
                    .padding(.trailing, 40)

                    CarouselView(items: displayRecentItems, spacing: 16, itemWidth: 270) { item in
                        NavigationLink(value: item) {
                            RecentSearchCard(item: item)
                                .frame(width: 270)
                        }
                        .buttonStyle(.plain)
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }

            // Section 2: Browse
            VStack(alignment: .leading, spacing: 16) {
                Text(isKidsProfile ? "Browse for Kids".localized : "Browse".localized)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 24)], spacing: 24) {
                    ForEach(browseGenres, id: \.id) { genre in
                        NavigationLink(value: GenreNavigation(name: genre.name, id: genre.id)) {
                            GenreCard(genre: genre)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.leading, 268)
            .padding(.trailing, 40)
        }
    }

    private var isKidsProfile: Bool {
        ProfileManager.shared.currentProfile?.isKids == true
    }

    private var browseGenres: [Genre] {
        if isKidsProfile {
            return Genre.allGenres.filter { KidsContentFilter.shared.isGenreSafeForKids($0.name) }
        }
        return Genre.allGenres
    }

    private var displayRecentItems: [MediaItem] {
        if isKidsProfile {
            return recentManager.recentItems.filter { !KidsContentFilter.shared.isRestricted(item: $0) }
        }
        return recentManager.recentItems
    }
}

// MARK: - Apple TV Style Recent Search Card
struct RecentSearchCard: View {
    let item: MediaItem

    var body: some View {
        HStack(spacing: 12) {
            // Left Poster Thumbnail
            if item.category == "Actor" || item.category == "Person" {
                CastCircle(name: item.title, imageURL: item.posterURL ?? item.imageURL, size: 48)
            } else {
                CachedImage(url: item.posterURL ?? item.imageURL) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 48, height: 68)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    default:
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.1))
                            .frame(width: 48, height: 68)
                            .overlay(
                                Image(systemName: "film")
                                    .font(.system(size: 18))
                                    .foregroundStyle(.white.opacity(0.3))
                            )
                    }
                }
            }

            // Right Title & Subtitle Info
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(subtitleText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .padding(8)
        .frame(width: 270, height: 80)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .glassEffect(.clear.interactive(), in: .rect(cornerRadius: 14))
    }

    private var subtitleText: String {
        if item.category == "Actor" || item.category == "Person" {
            return !item.description.isEmpty ? item.description : item.localizedCategory
        }
        var parts: [String] = []
        parts.append(item.localizedCategory)
        if let year = item.releaseDateYear, !year.isEmpty {
            parts.append(year)
        }
        return parts.joined(separator: " • ")
    }
}

// MARK: - Person Search Card
struct PersonSearchCard: View {
    let person: PersonCandidate
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 10) {
            CastCircle(name: person.name, imageURL: person.profileURL, size: 84)
                .scaleEffect(isHovered ? 1.05 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)

            VStack(spacing: 2) {
                Text(person.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .frame(width: 96)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var subtitle: String {
        if !person.knownForTitles.isEmpty {
            return person.knownForTitles.prefix(2).joined(separator: ", ")
        }
        return (person.knownForDepartment ?? "Actor").localized
    }
}

#Preview {
    SearchView()
}
