import Foundation
import SwiftUI
import Combine

// MARK: - Search Scope Enum

enum SearchScope: String, CaseIterable, Identifiable {
    case all = "All"
    case movies = "Movies"
    case series = "TV Shows"
    case people = "People"

    var id: String { rawValue }
}

// MARK: - Search View Model (SwiftUI Observable Bridge)

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query: String = "" {
        didSet { handleQueryChange(query) }
    }

    @Published var selectedScope: SearchScope = .all
    @Published private(set) var instantSuggestions: [PrefixTrie.TrieEntry] = []
    @Published private(set) var searchResults: [MediaItem] = []
    @Published private(set) var movieResults: [MediaItem] = []
    @Published private(set) var seriesResults: [MediaItem] = []
    @Published private(set) var personResults: [PersonCandidate] = []
    @Published private(set) var isSearching: Bool = false
    @Published private(set) var isLoading: Bool = false

    private let engine: SearchEngine

    init(engine: SearchEngine = SearchEngine.shared) {
        self.engine = engine
    }

    func clear() {
        query = ""
        instantSuggestions = []
        searchResults = []
        movieResults = []
        seriesResults = []
        personResults = []
        selectedScope = .all
        isSearching = false
        isLoading = false
    }

    func commitSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        instantSuggestions = []
        RecentSearchManager.shared.addQuery(trimmed)
    }

    private func handleQueryChange(_ newQuery: String) {
        let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            instantSuggestions = []
            searchResults = []
            movieResults = []
            seriesResults = []
            personResults = []
            selectedScope = .all
            isSearching = false
            isLoading = false
            return
        }

        isSearching = true
        isLoading = true
        searchResults = []
        movieResults = []
        seriesResults = []
        personResults = []

        Task {
            let local = await engine.updateQuery(newQuery) { [weak self] remote, people in
                Task { @MainActor in
                    guard let self = self, self.query == newQuery else { return }
                    let items = remote.map { $0.toMediaItem() }
                    let finalResults: [MediaItem]
                    let isKids = ProfileManager.shared.currentProfile?.isKids == true
                    if isKids {
                        finalResults = await KidsContentFilter.shared.filterSafeItems(items)
                    } else {
                        finalResults = items
                    }
                    
                    let movies = finalResults.filter { item in
                        let cat = item.category.lowercased()
                        return cat.contains("movie") || (!cat.contains("tv") && !cat.contains("series") && !cat.contains("show"))
                    }
                    let series = finalResults.filter { item in
                        let cat = item.category.lowercased()
                        return cat.contains("tv") || cat.contains("series") || cat.contains("show")
                    }

                    withAnimation(.easeOut(duration: 0.2)) {
                        self.searchResults = finalResults
                        self.movieResults = movies
                        self.seriesResults = series
                        self.personResults = isKids ? [] : people
                        self.isLoading = false
                    }
                }
            }

            guard self.query == newQuery else { return }
            let filteredSuggestions: [PrefixTrie.TrieEntry]
            if ProfileManager.shared.currentProfile?.isKids == true {
                filteredSuggestions = local.filter { entry in
                    let lower = entry.title.lowercased()
                    let blocked = ["horror", "murder", "xxx", "porn", "slasher", "erotic", "killing"]
                    return !blocked.contains(where: { lower.contains($0) })
                }
            } else {
                filteredSuggestions = local
            }
            withAnimation(.easeOut(duration: 0.15)) {
                self.instantSuggestions = filteredSuggestions
            }
        }
    }
}
