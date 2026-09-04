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

    @Test func franchiseStemExactMatchRanksFlagshipAboveSequels() {
        let scorer = RelevanceScorer()

        let originalAvengers = MediaCandidate(
            id: "av-1",
            title: "The Avengers",
            mediaType: .movie,
            popularity: 90.0,
            voteCount: 29000,
            voteAverage: 7.7,
            posterPath: "/avengers1.jpg",
            backdropPath: nil,
            overview: "Earth's mightiest heroes assemble.",
            releaseDate: nil,
            isAdult: false,
            imdbID: "tt0848228",
            source: .tmdb
        )

        let infinityWar = MediaCandidate(
            id: "av-3",
            title: "Avengers: Infinity War",
            mediaType: .movie,
            popularity: 180.0, // Higher popularity and votes than 2012 Avengers
            voteCount: 32000,
            voteAverage: 8.3,
            posterPath: "/infinitywar.jpg",
            backdropPath: nil,
            overview: "Thanos collects the Infinity Stones.",
            releaseDate: nil,
            isAdult: false,
            imdbID: "tt4154756",
            source: .tmdb
        )

        let endgame = MediaCandidate(
            id: "av-4",
            title: "Avengers: Endgame",
            mediaType: .movie,
            popularity: 200.0,
            voteCount: 35000,
            voteAverage: 8.4,
            posterPath: "/endgame.jpg",
            backdropPath: nil,
            overview: "The grave course of events.",
            releaseDate: nil,
            isAdult: false,
            imdbID: "tt4154796",
            source: .tmdb
        )

        let candidates = [infinityWar, endgame, originalAvengers]
        let ranked = scorer.rank(candidates: candidates, query: "avengers")

        // The original 2012 "The Avengers" MUST rank #1 ahead of Infinity War and Endgame!
        #expect(ranked.first?.title == "The Avengers")
    }

    @Test func damerauLevenshteinDistanceCalculatesCorrectly() {
        // Exact match
        #expect(DamerauLevenshtein.distance("avengers", "avengers") == 0)
        
        // Single character drop ("avengrs" -> "avengers")
        #expect(DamerauLevenshtein.distance("avengrs", "avengers") == 1)
        
        // Single character transposition ("oppenhimr" -> "oppenheimer")
        #expect(DamerauLevenshtein.distance("hte", "the") == 1)
        
        // Missing letter ("interstelar" -> "interstellar")
        #expect(DamerauLevenshtein.distance("interstelar", "interstellar") == 1)
    }

    @Test func fuzzySuggestionsMatchTyposInPrefixTrie() async {
        let trie = PrefixTrie()

        let avengers = MediaCandidate(
            id: "av-1",
            title: "The Avengers",
            mediaType: .movie,
            popularity: 90.0,
            voteCount: 29000,
            voteAverage: 7.7,
            posterPath: "/avengers1.jpg",
            backdropPath: nil,
            overview: "Earth's mightiest heroes assemble.",
            releaseDate: nil,
            isAdult: false,
            imdbID: "tt0848228",
            source: .localCache
        )

        await trie.insert(avengers, category: .trending)

        // Exact typo query "avengrs"
        let fuzzyResults = await trie.fuzzySuggestions(for: "avengrs")
        #expect(fuzzyResults.first?.title == "The Avengers")
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
        #expect("The Avengers".normalizedForSearch.articleStripped == "avengers")
        #expect("Avengers: Infinity War".decomposedFranchise.stem == "avengers")
        #expect("Avengers: Infinity War".decomposedFranchise.hasSubtitle == true)
    }

    @Test func deduplicationMergesTMDBAndCinemetaForSameTitleAndYear() {
        let cal = Calendar(identifier: .gregorian)
        var comp2020 = DateComponents()
        comp2020.year = 2020
        comp2020.month = 10
        comp2020.day = 17
        let tmdbDate = cal.date(from: comp2020)

        var compCinemeta = DateComponents()
        compCinemeta.year = 2020
        compCinemeta.month = 1
        compCinemeta.day = 1
        let cinemetaDate = cal.date(from: compCinemeta)

        let tmdbCandidate = MediaCandidate(
            id: "tmdb-110356",
            title: "Start-Up",
            mediaType: .tvSeries,
            popularity: 85.0,
            voteCount: 450,
            voteAverage: 8.1,
            posterPath: "/startup_tmdb.jpg",
            backdropPath: "/startup_backdrop.jpg",
            overview: "Young entrepreneurs aspiring to launch virtual dreams into reality.",
            releaseDate: tmdbDate,
            isAdult: false,
            imdbID: nil,
            genres: ["Drama", "Comedy"],
            source: .tmdb
        )

        let cinemetaCandidate = MediaCandidate(
            id: "cinemeta-tt12920708",
            title: "Start-Up",
            mediaType: .tvSeries,
            popularity: 16.0,
            voteCount: 50,
            voteAverage: 8.0,
            posterPath: "https://images.metahub.space/poster/large/tt12920708/img",
            backdropPath: "https://images.metahub.space/background/large/tt12920708/img",
            overview: "Young entrepreneurs in South Korea's Sandbox.",
            releaseDate: cinemetaDate,
            isAdult: false,
            imdbID: "tt12920708",
            genres: ["Drama"],
            source: .cinemeta
        )

        let deduped = SearchEngine.deduplicate([tmdbCandidate, cinemetaCandidate])
        #expect(deduped.count == 1)

        let canonical = deduped[0]
        #expect(canonical.id == "tmdb-110356")
        #expect(canonical.imdbID == "tt12920708") // Inherited from Cinemeta!
        #expect(canonical.genres == ["Drama", "Comedy"])
        #expect(canonical.voteAverage == 8.1)
        #expect(canonical.posterPath == "/startup_tmdb.jpg")

        // Converted MediaItem should have IMDb ID and genres ready
        let item = canonical.toMediaItem()
        #expect(item.id == "tt12920708")
        #expect(item.genres == ["Drama", "Comedy"])
    }

    @Test func deduplicationPreservesDistinctRemakesWithDifferentYears() {
        let cal = Calendar(identifier: .gregorian)
        var comp1984 = DateComponents()
        comp1984.year = 1984
        let date1984 = cal.date(from: comp1984)

        var comp2021 = DateComponents()
        comp2021.year = 2021
        let date2021 = cal.date(from: comp2021)

        let duneOriginal = MediaCandidate(
            id: "tmdb-841",
            title: "Dune",
            mediaType: .movie,
            popularity: 45.0,
            voteCount: 3000,
            voteAverage: 6.5,
            posterPath: "/dune1984.jpg",
            backdropPath: nil,
            overview: "A Duke's son leads desert warriors.",
            releaseDate: date1984,
            isAdult: false,
            imdbID: "tt0087175",
            genres: ["Sci-Fi", "Adventure"],
            source: .tmdb
        )

        let duneRemake = MediaCandidate(
            id: "tmdb-438631",
            title: "Dune",
            mediaType: .movie,
            popularity: 120.0,
            voteCount: 11000,
            voteAverage: 7.9,
            posterPath: "/dune2021.jpg",
            backdropPath: nil,
            overview: "Paul Atreides arrives on Arrakis.",
            releaseDate: date2021,
            isAdult: false,
            imdbID: "tt1160419",
            genres: ["Sci-Fi", "Adventure"],
            source: .tmdb
        )

        let deduped = SearchEngine.deduplicate([duneOriginal, duneRemake])
        #expect(deduped.count == 2) // Both versions must be kept!
    }

    @Test func genresAndMetadataPreservedInTrieAndToMediaItem() async {
        let trie = PrefixTrie()

        let candidate = MediaCandidate(
            id: "tmdb-550",
            title: "Fight Club",
            mediaType: .movie,
            popularity: 75.0,
            voteCount: 26000,
            voteAverage: 8.4,
            posterPath: "/fightclub.jpg",
            backdropPath: "/fightclub_hero.jpg",
            overview: "An insomniac office worker.",
            releaseDate: nil,
            isAdult: false,
            imdbID: "tt0137523",
            genres: ["Drama", "Thriller"],
            source: .tmdb
        )

        await trie.insert(candidate, category: .trending)

        let results = await trie.suggestions(forPrefix: "fight")
        #expect(results.count >= 1)

        let entry = results.first
        #expect(entry?.title == "Fight Club")
        #expect(entry?.genres == ["Drama", "Thriller"])
        #expect(entry?.imdbID == "tt0137523")

        let item = entry?.toMediaItem()
        #expect(item?.id == "tt0137523")
        #expect(item?.genres == ["Drama", "Thriller"])
        #expect(item?.description == "An insomniac office worker.")
        #expect(item?.voteAverage == 8.4)
    }
}

