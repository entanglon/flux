import SwiftUI

struct SearchView: View {
    @State private var searchText = ""
    @State private var searchResults: [MediaItem] = []
    @State private var suggestions: [MediaItem] = []
    @State private var isSearching = false
    @State private var isLoading = false
    @FocusState private var isSearchFocused: Bool
    @ObservedObject private var recentManager = RecentSearchManager.shared
    
    // Grid for Search Results
    let resultColumns = [
        GridItem(.adaptive(minimum: 160), spacing: 24)
    ]
    
    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    // Toolbar clearance height
                    Color.clear.frame(height: 44)

                    if isSearching {
                        if isLoading {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 24)], spacing: 24) {
                                ForEach(0..<12, id: \.self) { _ in
                                    GhostCard()
                                }
                            }
                            .transition(.opacity)
                        } else if searchResults.isEmpty {
                            VStack(spacing: 16) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 48))
                                    .foregroundStyle(.secondary)
                                Text("No results found")
                                    .font(.title3)
                                    .fontWeight(.medium)
                                Text("Try searching for something else")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 300)
                            .transition(.opacity)
                        } else {
                            searchResultsView
                                .transition(.opacity)
                        }
                    } else {
                        defaultBrowseView
                            .transition(.opacity)
                    }
                }
                .padding(.leading, 268)
                .padding(.trailing, 40)
                .padding(.bottom, 60)
            }

            // Floating Apple TV Liquid Glass Search Bar Capsule (Positioned in Toolbar Row, Centered over content)
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(isSearchFocused ? .cyan : .white.opacity(0.75))
                        
                        TextField("Search", text: $searchText)
                            .font(.system(size: 15, weight: .medium))
                            .textFieldStyle(.plain)
                            .foregroundStyle(.white)
                            .focused($isSearchFocused)
                            .onSubmit {
                                guard !searchText.isEmpty else { return }
                                suggestions = []
                                isSearching = true
                                Task { await performSearch() }
                            }
                        
                        if !searchText.isEmpty {
                            Button(action: {
                                searchText = ""
                                isSearching = false
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
                    .scaleEffect(isSearchFocused ? 1.01 : 1.0)
                    .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isSearchFocused)
                    
                    Spacer()
                }

                // Autocomplete suggestions — dropdown while typing, hidden after submit
                if !suggestions.isEmpty && isSearchFocused && !isSearching {
                    HStack {
                        Spacer()
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(suggestions.prefix(6)) { suggestion in
                                NavigationLink(value: suggestion) {
                                    HStack(spacing: 12) {
                                        CachedImage(url: suggestion.posterURL ?? suggestion.imageURL, maxDimension: 100) { phase in
                                            if let img = phase.image {
                                                img.resizable().aspectRatio(contentMode: .fill)
                                            } else {
                                                Rectangle().fill(Color.white.opacity(0.08))
                                                    .overlay { Image(systemName: "film").foregroundStyle(.white.opacity(0.3)) }
                                            }
                                        }
                                        .frame(width: 34, height: 48)
                                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(suggestion.title)
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(.white)
                                                .lineLimit(1)
                                            HStack(spacing: 6) {
                                                Text(suggestion.category)
                                                if let year = suggestion.releaseDateYear, !year.isEmpty {
                                                    Text("·")
                                                    Text(year)
                                                }
                                            }
                                            .font(.system(size: 11))
                                            .foregroundStyle(.white.opacity(0.5))
                                        }

                                        Spacer()

                                        Image(systemName: "arrow.up.left")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white.opacity(0.35))
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(8)
                        .frame(width: 520)
                        .glassEffect(.regular, in: .rect(cornerRadius: 18))
                        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        Spacer()
                    }
                }
            }
            .padding(.leading, 244)
            .padding(.top, 14)
            .animation(.easeInOut(duration: 0.15), value: suggestions)
        }
        .navigationBarBackButtonHidden(true)
        .onAppear {
            // Apple TV behavior: arriving at Search focuses the field immediately
            isSearchFocused = true
        }
        .onChange(of: searchText) { _, newValue in
            if newValue.isEmpty {
                isSearching = false
                isLoading = false
                searchResults = []
                suggestions = []
            } else if isSearching {
                // User typed after a search — go back to suggestion mode
                isSearching = false
                searchResults = []
            }
        }
        .task(id: searchText) {
            guard !searchText.isEmpty else { return }
            // Only populate suggestions (dropdown) — full search triggered by onSubmit
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            if let results = try? await StremioService.shared.searchMulti(query: searchText) {
                let combined = (results.0 + results.1).filter { $0.isReleased }
                if !Task.isCancelled {
                    suggestions = Array(sortByRelevance(combined, query: searchText).prefix(6))
                }
            }
        }
    }
    
    private func performSearch() async {
        guard !searchText.isEmpty else { return }
        await MainActor.run {
            withAnimation(.easeInOut(duration: 0.2)) {
                isSearching = true
                isLoading = true
            }
        }
        
        do {
            let (movies, tvShows) = try await StremioService.shared.searchMulti(query: searchText)
            
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.25)) {
                    self.searchResults = sortByRelevance(
                        (movies + tvShows).filter { $0.isReleased },
                        query: searchText
                    )
                    self.isLoading = false
                }
            }
        } catch {
            print("Error searching: \(error)")
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) {
                    self.isLoading = false
                }
            }
        }
    }
    
    private var searchResultsView: some View {
        LazyVGrid(columns: resultColumns, spacing: 24) {
            ForEach(searchResults) { item in
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
    
    private var defaultBrowseView: some View {
        VStack(alignment: .leading, spacing: 32) {
            // Section 1: Recently Searched
            if !recentManager.recentItems.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Recently Searched")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                        
                        Spacer()
                        
                        Button("Clear") {
                            recentManager.clear()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.blue)
                    }
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(recentManager.recentItems) { item in
                                NavigationLink(value: item) {
                                    RecentSearchCard(item: item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            
            // Section 2: Browse
            VStack(alignment: .leading, spacing: 16) {
                Text("Browse")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 24)], spacing: 24) {
                    ForEach(Genre.allGenres, id: \.id) { genre in
                        NavigationLink(value: GenreNavigation(name: genre.name, id: genre.id)) {
                            GenreCard(genre: genre)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - Apple TV Style Recent Search Card
struct RecentSearchCard: View {
    let item: MediaItem
    
    var body: some View {
        HStack(spacing: 12) {
            // Left Poster Thumbnail
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
        .glassEffect(.clear.interactive(), in: .rect(cornerRadius: 14))
    }
    
    private var subtitleText: String {
        var parts: [String] = []
        parts.append(item.category)
        if let year = item.releaseDateYear, !year.isEmpty {
            parts.append(year)
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Search Relevance Scoring

extension SearchView {
    /// Score how relevant a MediaItem is to the search query.
    /// Higher score = more relevant. Used to sort results instead of raw popularity.
    private func relevanceScore(_ item: MediaItem, query: String) -> Double {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let title = item.title.lowercased()
        guard !q.isEmpty else { return item.popularity ?? 0 }

        var score: Double = 0

        // Exact title match — highest priority
        if title == q { return 10000 }

        // Title starts with query
        if title.hasPrefix(q) { score += 5000 }

        // Title contains query as a whole word
        if title.contains(q) { score += 3000 }

        // Query words match title words (ordered)
        let queryWords = q.split(separator: " ")
        let titleWords = title.split(separator: " ")
        var matchedWords = 0
        for qw in queryWords {
            if titleWords.contains(where: { $0.hasPrefix(qw) }) {
                matchedWords += 1
            }
        }
        score += Double(matchedWords) * 500

        // Boost if all query words matched
        if matchedWords == queryWords.count && queryWords.count > 1 {
            score += 2000
        }

        // Tiebreaker: popularity (only if relevance is low)
        if score > 0 {
            score += (item.popularity ?? 0) * 0.1
        } else {
            score = item.popularity ?? 0
        }

        return score
    }

    /// Sort items by relevance to query, not just popularity.
    private func sortByRelevance(_ items: [MediaItem], query: String) -> [MediaItem] {
        items.sorted { relevanceScore($0, query: query) > relevanceScore($1, query: query) }
    }
}

#Preview {
    SearchView()
}
