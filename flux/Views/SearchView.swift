import SwiftUI

struct SearchView: View {
    @StateObject private var viewModel = SearchViewModel()
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

                    if viewModel.isSearching {
                        if viewModel.isLoading {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 24)], spacing: 24) {
                                ForEach(0..<12, id: \.self) { _ in
                                    GhostCard()
                                }
                            }
                            .transition(.opacity)
                        } else if viewModel.searchResults.isEmpty {
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
                            LazyVGrid(columns: resultColumns, spacing: 24) {
                                ForEach(viewModel.searchResults) { item in
                                    NavigationLink(value: item) {
                                        GlassCard(item: item, aspectRatio: .portrait, showTitle: false)
                                    }
                                    .buttonStyle(.plain)
                                    .simultaneousGesture(TapGesture().onEnded {
                                        recentManager.add(item)
                                    })
                                }
                            }
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

            // Floating Apple TV Liquid Glass Search Bar Capsule
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(isSearchFocused ? .cyan : .white.opacity(0.75))
                        
                        TextField("Search", text: $viewModel.query)
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
                                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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

#Preview {
    SearchView()
}
