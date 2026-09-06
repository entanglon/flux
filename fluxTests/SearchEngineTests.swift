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

    @Test func cinemetaCatalogRankPreservesCameronAvatarAboveJapaneseAvatar() {
        let metaCameron = CinemetaMeta(
            id: "tt0499549",
            type: "movie",
            name: "Avatar",
            poster: nil,
            background: nil,
            description: "A paraplegic Marine dispatched to the moon Pandora.",
            releaseInfo: "2009",
            imdbRating: nil,
            genres: ["Action", "Adventure", "Fantasy"]
        )

        let metaJapanese = CinemetaMeta(
            id: "tt1878848",
            type: "movie",
            name: "Avatar",
            poster: nil,
            background: nil,
            description: "A Japanese thriller.",
            releaseInfo: "2011",
            imdbRating: nil,
            genres: ["Thriller"]
        )

        // Cameron's Avatar is returned at index 0 by Cinemeta, Japanese Avatar at index 10
        let cameron = metaCameron.asMediaCandidate(index: 0)
        let japanese = metaJapanese.asMediaCandidate(index: 10)

        #expect(cameron.popularity > japanese.popularity)

        let scorer = RelevanceScorer()
        let ranked = scorer.rank(candidates: [japanese, cameron], query: "avatar")
        #expect(ranked.first?.imdbID == "tt0499549")
    }

    @Test func pluralTokenMatchingRanksAvatarWayOfWaterFirst() {
        let scorer = RelevanceScorer()

        let wayOfWater = MediaCandidate(
            id: "tt1630029",
            title: "Avatar: The Way of Water",
            mediaType: .movie,
            popularity: 180.0,
            voteCount: 15000,
            voteAverage: 7.6,
            posterPath: "/avatar2.jpg",
            backdropPath: nil,
            overview: "Jake Sully lives with his newfound family formed on the extrasolar moon Pandora.",
            releaseDate: nil,
            isAdult: false,
            imdbID: "tt1630029",
            genres: ["Action", "Sci-Fi"],
            source: .cinemeta
        )

        let theWayOfTheGun = MediaCandidate(
            id: "tt0202677",
            title: "The Way of the Gun",
            mediaType: .movie,
            popularity: 60.0,
            voteCount: 2000,
            voteAverage: 6.6,
            posterPath: "/gun.jpg",
            backdropPath: nil,
            overview: "Two criminal drifters get in over their heads.",
            releaseDate: nil,
            isAdult: false,
            imdbID: "tt0202677",
            genres: ["Action", "Crime"],
            source: .cinemeta
        )

        let avatar1 = MediaCandidate(
            id: "tt0499549",
            title: "Avatar",
            mediaType: .movie,
            popularity: 200.0,
            voteCount: 30000,
            voteAverage: 7.9,
            posterPath: "/avatar1.jpg",
            backdropPath: nil,
            overview: "A paraplegic Marine dispatched to Pandora.",
            releaseDate: nil,
            isAdult: false,
            imdbID: "tt0499549",
            genres: ["Action", "Sci-Fi"],
            source: .cinemeta
        )

        // Search with plural typo "waters" instead of "water"
        let ranked = scorer.rank(candidates: [theWayOfTheGun, avatar1, wayOfWater], query: "avatar the way of waters")
        #expect(ranked.first?.title == "Avatar: The Way of Water")
    }

    @Test func headlessStubWithoutPosterIsPrunedByQualityFilter() {
        let filter = QualityFilter()

        let emptyMaydayStub = MediaCandidate(
            id: "tmdb-324824",
            title: "Mayday",
            mediaType: .tvSeries,
            popularity: 0.8,
            voteCount: 0,
            voteAverage: 0,
            posterPath: nil, // Headless stub
            backdropPath: nil,
            overview: "",
            releaseDate: Date().addingTimeInterval(86400 * 30),
            isAdult: false,
            imdbID: nil,
            source: .tmdb
        )

        let realMaydayMovie = MediaCandidate(
            id: "tmdb-1137844",
            title: "Mayday",
            mediaType: .movie,
            popularity: 15.3,
            voteCount: 12,
            voteAverage: 7.2,
            posterPath: "/hVXjX1jLZ1ljFSNGXpjJfbTUOa7.jpg",
            backdropPath: "/4gyx49ibwQslyrwuUS1c58PJEEd.jpg",
            overview: "A U.S. Navy pilot during the Cold War...",
            releaseDate: Date().addingTimeInterval(-86400 * 3),
            isAdult: false,
            imdbID: "tt28014327",
            source: .tmdb
        )

        let filtered = filter.filter([emptyMaydayStub, realMaydayMovie])
        #expect(filtered.count == 1)
        #expect(filtered.first?.id == "tmdb-1137844")
    }

    @Test func upcomingReleaseWithValidPosterPassesQualityFilter() {
        let filter = QualityFilter()

        let upcomingMovie = MediaCandidate(
            id: "tmdb-999999",
            title: "Future Blockbuster",
            mediaType: .movie,
            popularity: 25.0,
            voteCount: 0, // Unreleased movies have 0 votes
            voteAverage: 0,
            posterPath: "/future_poster.jpg",
            backdropPath: "/future_backdrop.jpg",
            overview: "Coming next month to theatres.",
            releaseDate: Date().addingTimeInterval(86400 * 20), // 20 days in future
            isAdult: false,
            imdbID: nil,
            source: .tmdb
        )

        let filtered = filter.filter([upcomingMovie])
        #expect(filtered.count == 1)
        #expect(filtered.first?.title == "Future Blockbuster")
    }

    @Test func searchEngineFuzzyRewritingCorrectsTypoInTrie() async {
        let trie = PrefixTrie()
        let movie = MediaCandidate(
            id: "tt0499549",
            title: "Avatar",
            mediaType: .movie,
            popularity: 200.0,
            voteCount: 30000,
            voteAverage: 7.9,
            posterPath: "/avatar.jpg",
            backdropPath: nil,
            overview: "Pandora sci-fi adventure.",
            releaseDate: nil,
            isAdult: false,
            imdbID: "tt0499549",
            source: .localCache
        )
        await trie.insert(movie, category: .trending)

        // Fuzzy suggestions for misspelled "avatr" should recover "Avatar"
        let suggestions = await trie.fuzzySuggestions(for: "avatr")
        #expect(!suggestions.isEmpty)
        #expect(suggestions.first?.title == "Avatar")
    }

    @Test func franchiseSearchRanksFlagshipAndSequelsAboveVintageAndMockbusters() {
        let scorer = RelevanceScorer()

        let cal = Calendar(identifier: .gregorian)
        var comp2012 = DateComponents(); comp2012.year = 2012
        let date2012 = cal.date(from: comp2012)
        var comp2019 = DateComponents(); comp2019.year = 2019
        let date2019 = cal.date(from: comp2019)
        var comp2018 = DateComponents(); comp2018.year = 2018
        let date2018 = cal.date(from: comp2018)
        var comp1961 = DateComponents(); comp1961.year = 1961
        let date1961 = cal.date(from: comp1961)
        var comp2015 = DateComponents(); comp2015.year = 2015
        let date2015 = cal.date(from: comp2015)

        let originalAvengers = MediaCandidate(
            id: "m-2012",
            title: "The Avengers",
            mediaType: .movie,
            popularity: 87.0,
            voteCount: 39500,
            voteAverage: 8.0,
            posterPath: "/avengers2012.jpg",
            backdropPath: nil,
            overview: "Marvel's The Avengers assembly.",
            releaseDate: date2012,
            isAdult: false,
            imdbID: "tt0848228",
            source: .tmdb
        )

        let endgame = MediaCandidate(
            id: "m-2019",
            title: "Avengers: Endgame",
            mediaType: .movie,
            popularity: 58.0,
            voteCount: 28500,
            voteAverage: 8.4,
            posterPath: "/endgame.jpg",
            backdropPath: nil,
            overview: "The MCU conclusion.",
            releaseDate: date2019,
            isAdult: false,
            imdbID: "tt4154796",
            source: .tmdb
        )

        let infinityWar = MediaCandidate(
            id: "m-2018",
            title: "Avengers: Infinity War",
            mediaType: .movie,
            popularity: 81.0,
            voteCount: 32800,
            voteAverage: 8.3,
            posterPath: "/infinity.jpg",
            backdropPath: nil,
            overview: "Thanos attacks.",
            releaseDate: date2018,
            isAdult: false,
            imdbID: "tt4154756",
            source: .tmdb
        )

        let vintage1961 = MediaCandidate(
            id: "s-1961",
            title: "The Avengers",
            mediaType: .tvSeries,
            popularity: 89.0,
            voteCount: 154,
            voteAverage: 7.5,
            posterPath: "/vintage.jpg",
            backdropPath: nil,
            overview: "British espionage series.",
            releaseDate: date1961,
            isAdult: false,
            imdbID: "tt0054518",
            source: .tmdb
        )

        let mockbusterGrimm = MediaCandidate(
            id: "m-grimm",
            title: "Avengers Grimm",
            mediaType: .movie,
            popularity: 2.7,
            voteCount: 132,
            voteAverage: 2.7,
            posterPath: "/grimm.jpg",
            backdropPath: nil,
            overview: "Fairy tale heroes assemble.",
            releaseDate: date2015,
            isAdult: false,
            imdbID: "tt4296026",
            source: .tmdb
        )

        let candidates = [vintage1961, mockbusterGrimm, infinityWar, endgame, originalAvengers]
        let ranked = scorer.rank(candidates: candidates, query: "avengers")

        // 1. Marvel's The Avengers (2012) must be #1
        #expect(ranked[0].title == "The Avengers")
        #expect(ranked[0].id == "m-2012")

        // 2 & 3. Direct MCU blockbuster sequels must immediately follow
        let top3Titles = Set(ranked.prefix(3).map(\.title))
        #expect(top3Titles.contains("The Avengers"))
        #expect(top3Titles.contains("Avengers: Endgame"))
        #expect(top3Titles.contains("Avengers: Infinity War"))

        // 4. Vintage 1961 series and mockbuster must rank below all 3 MCU blockbusters
        let top3IDs = Set(ranked.prefix(3).map(\.id))
        #expect(!top3IDs.contains("s-1961"))
        #expect(!top3IDs.contains("m-grimm"))

        // 5. Mockbuster must receive knockoff demotion and rank last
        #expect(ranked.last?.id == "m-grimm")
    }

    @Test func cinemetaPowerLawPopularityAndArtworkPreservation() {
        let metaAmazonPoster = CinemetaMeta(
            id: "tt4154796",
            type: "movie",
            name: "Avengers: Endgame",
            poster: "https://m.media-amazon.com/images/M/MV5B._V1_SX250.jpg",
            background: "https://images.metahub.space/background/small/tt4154796/img",
            description: "Endgame",
            releaseInfo: "2019",
            imdbRating: "8.4",
            genres: ["Action"],
            popularities: CinemetaPopularities(moviedb: 50.0, stremio: 0.9, trakt: 25.0)
        )

        // Rank 0 (first catalog item)
        let candidate0 = metaAmazonPoster.asMediaCandidate(index: 0)
        #expect(candidate0.popularity >= 250.0)
        #expect(candidate0.voteCount >= 25000)
        // Poster upgraded to SX700 and preserved (NOT overwritten by 404 metahub URL)
        #expect(candidate0.posterPath?.contains("m.media-amazon.com") == true)
        #expect(candidate0.posterPath?.contains("._V1_SX700.jpg") == true)
        // Backdrop upgraded to large
        #expect(candidate0.backdropPath?.contains("/background/large/") == true)

        // Rank 10 should experience significant power-law decay
        let candidate10 = metaAmazonPoster.asMediaCandidate(index: 10)
        #expect(candidate10.popularity < candidate0.popularity)
        #expect(candidate10.voteCount < candidate0.voteCount)
    }

    @Test func qualityFilterPrunesRifftraxCommentary() {
        let filter = QualityFilter()

        let rifftrax = MediaCandidate(
            id: "tt16103750",
            title: "Rifftrax: Avengers: Endgame",
            mediaType: .movie,
            popularity: 5.0,
            voteCount: 15,
            voteAverage: 6.0,
            posterPath: "/poster.jpg",
            backdropPath: nil,
            overview: "Audio commentary.",
            releaseDate: nil,
            isAdult: false,
            imdbID: "tt16103750",
            source: .cinemeta
        )

        #expect(filter.isEligible(rifftrax) == false)
    }

    @Test func singularPluralQueryMatchesFlagshipSeriesAtRank1() {
        let scorer = RelevanceScorer()

        let gotSeries = MediaCandidate(
            id: "tt0944947",
            title: "Game of Thrones",
            mediaType: .tvSeries,
            popularity: 250.0,
            voteCount: 40000,
            voteAverage: 9.2,
            posterPath: "/got.jpg",
            backdropPath: nil,
            overview: "Nine noble families fight for control over the lands of Westeros.",
            releaseDate: Calendar(identifier: .gregorian).date(from: DateComponents(year: 2011, month: 4, day: 17)),
            isAdult: false,
            imdbID: "tt0944947",
            source: .cinemeta
        )

        let imaxSpecial = MediaCandidate(
            id: "tt43975484",
            title: "Game of Thrones: The IMAX Experience",
            mediaType: .movie,
            popularity: 200.0,
            voteCount: 500,
            voteAverage: 8.5,
            posterPath: "/imax.jpg",
            backdropPath: nil,
            overview: "IMAX special presentation.",
            releaseDate: Calendar(identifier: .gregorian).date(from: DateComponents(year: 2015, month: 1, day: 29)),
            isAdult: false,
            imdbID: "tt43975484",
            source: .cinemeta
        )

        let conquestRebellion = MediaCandidate(
            id: "tt7937220",
            title: "Game of Thrones Conquest & Rebellion: An Animated History of the Seven Kingdoms",
            mediaType: .movie,
            popularity: 150.0,
            voteCount: 300,
            voteAverage: 7.9,
            posterPath: "/conquest.jpg",
            backdropPath: nil,
            overview: "Animated history.",
            releaseDate: Calendar(identifier: .gregorian).date(from: DateComponents(year: 2017, month: 9, day: 18)),
            isAdult: false,
            imdbID: "tt7937220",
            source: .cinemeta
        )

        let candidates = [imaxSpecial, conquestRebellion, gotSeries]
        let ranked = scorer.rank(candidates: candidates, query: "game of throne")

        // Game of Thrones (the flagship series) must rank #1 even with singular "throne" query
        #expect(ranked.first?.id == "tt0944947")
    }
}


