import Testing
import Foundation
@testable import flux

struct SearchEngineTests {

    @Test func prefixTrie0msLookupAndCategoryBoosts() async {
        let trie = PrefixTrie()

        let continueWatching = MediaCandidate(
            id: "cw-1",
            title: "The Dark Knight",
            mediaType: .movie,
            popularity: 80.0,
            voteCount: 30000,
            voteAverage: 9.0,
            posterPath: "/poster1.jpg",
            backdropPath: nil,
            overview: "Batman raises the stakes.",
            releaseDate: nil,
            isAdult: false,
            imdbID: "tt0468569",
            source: .localCache
        )

        let trending = MediaCandidate(
            id: "tr-1",
            title: "Dark Matter",
            mediaType: .tvSeries,
            popularity: 150.0, // Higher raw popularity than Dark Knight
            voteCount: 500,
            voteAverage: 8.0,
            posterPath: "/poster2.jpg",
            backdropPath: nil,
            overview: "Alternate reality sci-fi.",
            releaseDate: nil,
            isAdult: false,
            imdbID: "tt19231808",
            source: .localCache
        )

        await trie.insert(trending, category: .trending)
        await trie.insert(continueWatching, category: .continueWatching)

        // Lookup prefix "dark" — continue watching should float to #1 due to boost
        let results = await trie.suggestions(forPrefix: "dark")
        #expect(results.count >= 2)
        #expect(results.first?.title == "The Dark Knight")

        // Lookup word token "knight"
        let knightResults = await trie.suggestions(forPrefix: "knight")
        #expect(knightResults.first?.title == "The Dark Knight")
    }

    @Test func qualityFilterPrunesZeroVoteEntriesWithoutPoster() {
        let filter = QualityFilter(config: QualityGateConfig(minVoteCountThreshold: 10, minPopularityFloor: 1.0))

        let validMovie = MediaCandidate(
            id: "m-1",
            title: "Interstellar",
            mediaType: .movie,
            popularity: 120.0,
            voteCount: 34000,
            voteAverage: 8.7,
            posterPath: "/interstellar.jpg",
            backdropPath: nil,
            overview: "A team of explorers travel through a wormhole.",
            releaseDate: Date(timeIntervalSince1970: 1415232000),
            isAdult: false,
            imdbID: "tt0816692",
            source: .tmdb
        )

        let mockbusterTrash = MediaCandidate(
            id: "trash-1",
            title: "Interstellar Knockoff Wars",
            mediaType: .movie,
            popularity: 0.1,
            voteCount: 2,
            voteAverage: 2.1,
            posterPath: "/fake.jpg",
            backdropPath: nil,
            overview: "Low budget space copy.",
            releaseDate: Date(timeIntervalSince1970: 1500000000),
            isAdult: false,
            imdbID: nil,
            source: .tmdb
        )

        let missingPoster = MediaCandidate(
            id: "noposter-1",
            title: "No Poster Student Project",
            mediaType: .movie,
            popularity: 5.0,
            voteCount: 20,
            voteAverage: 6.0,
            posterPath: nil,
            backdropPath: nil,
            overview: "Has no artwork.",
            releaseDate: nil,
            isAdult: false,
            imdbID: nil,
            source: .tmdb
        )

        let brandNewRelease = MediaCandidate(
            id: "fresh-1",
            title: "Brand New Theatrical Release",
            mediaType: .movie,
            popularity: 0.5,
            voteCount: 3, // Low votes because it released 3 days ago
            voteAverage: 7.5,
            posterPath: "/fresh.jpg",
            backdropPath: nil,
            overview: "Released in theaters this week.",
            releaseDate: Date().addingTimeInterval(-86400 * 3), // 3 days old
            isAdult: false,
            imdbID: nil,
            source: .tmdb
        )

        #expect(filter.isEligible(validMovie) == true)
        #expect(filter.isEligible(mockbusterTrash) == false)
        #expect(filter.isEligible(missingPoster) == false)
        #expect(filter.isEligible(brandNewRelease) == true) // Grace period applied
    }

    @Test func relevanceScorerDemotesMockbustersRidingFranchiseName() {
        let scorer = RelevanceScorer()

        let blockbuster = MediaCandidate(
            id: "bb-1",
            title: "Transformers",
            mediaType: .movie,
            popularity: 95.0,
            voteCount: 15000,
            voteAverage: 7.2,
            posterPath: "/transformers.jpg",
            backdropPath: nil,
            overview: "Autobots vs Decepticons.",
            releaseDate: nil,
            isAdult: false,
            imdbID: "tt0418279",
            source: .tmdb
        )

        let mockbuster = MediaCandidate(
            id: "mock-1",
            title: "Transmorphers",
            mediaType: .movie,
            popularity: 1.5,
            voteCount: 15,
            voteAverage: 1.8,
            posterPath: "/transmorphers.jpg",
            backdropPath: nil,
            overview: "A race of alien robots conquer Earth.",
            releaseDate: nil,
            isAdult: false,
            imdbID: "tt0960835",
            source: .tmdb
        )

        let fanFilm = MediaCandidate(
            id: "fan-1",
            title: "Transformers: Genesis Fan Project",
            mediaType: .movie,
            popularity: 0.8,
            voteCount: 8,
            voteAverage: 3.0,
            posterPath: "/fan.jpg",
            backdropPath: nil,
            overview: "Amateur fan recreation.",
            releaseDate: nil,
            isAdult: false,
            imdbID: nil,
            source: .tmdb
        )

        let candidates = [blockbuster, fanFilm]
        let ranked = scorer.rank(candidates: candidates, query: "Transformers")

        #expect(ranked.first?.title == "Transformers")
        
        let bbScore = scorer.score(candidate: blockbuster, query: "Transformers", batchContext: candidates)
        let fanScore = scorer.score(candidate: fanFilm, query: "Transformers", batchContext: candidates)

        // The fan film receives the -9,000 knockoff penalty
        #expect(bbScore > fanScore + 8000)
    }

    @Test func searchStringNormalizationHandlesDiacriticsAndCase() {
        let normalized = "  Amélie  ".normalizedForSearch
        #expect(normalized == "amelie")
        #expect(normalized.searchTokens.contains("amelie"))
    }
}
