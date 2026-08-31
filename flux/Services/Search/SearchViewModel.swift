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

        Task {
            let local = await engine.updateQuery(newQuery) { [weak self] remote in
                Task { @MainActor in
                    guard let self = self, self.query == newQuery else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        self.searchResults = remote.map { $0.toMediaItem() }
                        self.isLoading = false
                    }
                }
            }

            guard self.query == newQuery else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                self.instantSuggestions = local
            }
        }
    }
}
