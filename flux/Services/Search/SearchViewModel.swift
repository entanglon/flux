import Foundation
import SwiftUI
import Combine

// MARK: - Search View Model (SwiftUI Observable Bridge)

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query: String = "" {
        didSet { handleQueryChange(query) }
    }

    @Published private(set) var instantSuggestions: [PrefixTrie.TrieEntry] = []
    @Published private(set) var searchResults: [MediaItem] = []
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
        isSearching = false
        isLoading = false
    }

    func commitSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        instantSuggestions = []
    }

    private func handleQueryChange(_ newQuery: String) {
        let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            instantSuggestions = []
            searchResults = []
            isSearching = false
            isLoading = false
            return
        }

        isSearching = true
        isLoading = true
        searchResults = [] // Clear previous results so ghost cards display cleanly during query refinement

        Task {
            let local = await engine.updateQuery(newQuery) { [weak self] remote in
                Task { @MainActor in
                    guard let self = self, self.query == newQuery else { return }
                    let items = remote.map { $0.toMediaItem() }
                    let finalResults: [MediaItem]
                    if ProfileManager.shared.currentProfile?.isKids == true {
                        finalResults = await KidsContentFilter.shared.filterSafeItems(items)
                    } else {
                        finalResults = items
                    }
                    withAnimation(.easeOut(duration: 0.2)) {
                        self.searchResults = finalResults
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
