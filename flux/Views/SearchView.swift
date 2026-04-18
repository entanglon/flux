import SwiftUI

struct SearchView: View {
    @State private var searchText = ""
    @State private var searchResults: [MediaItem] = []
    @State private var isSearching = false
    
    // Grid for Search Results
    let resultColumns = [
        GridItem(.adaptive(minimum: 160), spacing: 24)
    ]
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                if isSearching {
                    searchResultsView
                } else {
                    defaultBrowseView
                }
            }
            .padding(40)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                CenteredSearchField(text: $searchText, onSubmit: {
                    Task {
                        await performSearch()
                    }
                })
                .frame(width: 400)
            }
        }
        .onChange(of: searchText) { _, newValue in
             if newValue.isEmpty {
                 isSearching = false
                 searchResults = []
             }
         }
        .task(id: searchText) {
            guard !searchText.isEmpty else { return }
            try? await Task.sleep(nanoseconds: 800_000_000) // 0.8s debounce
            if Task.isCancelled { return }
            await performSearch()
        }
    }
    
    private func performSearch() async {
        guard !searchText.isEmpty else { return }
        isSearching = true
        
        do {
            let (movies, tvShows) = try await StremioService.shared.searchMulti(query: searchText)
            
            await MainActor.run {
                self.searchResults = (movies + tvShows).sorted { ($0.popularity ?? 0) > ($1.popularity ?? 0) }
            }
        } catch {
            print("Error searching: \(error)")
        }
    }
    
    private var searchResultsView: some View {
        LazyVGrid(columns: resultColumns, spacing: 24) {
            ForEach(searchResults) { item in
                NavigationLink(value: item) {
                    GlassCard(item: item, aspectRatio: .portrait, showTitle: false)
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    private var defaultBrowseView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Browse by Genre")
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(.white)
            
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                ForEach(Genre.allGenres, id: \.id) { genre in
                    NavigationLink(destination: MediaListView(title: genre.name, type: .genre(id: genre.id))) {
                        GenreCard(genre: genre)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
