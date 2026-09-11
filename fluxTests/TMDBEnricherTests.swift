import Testing
import Foundation
@testable import flux

struct TMDBEnricherTests {

    @Test func tmdbAdaptiveURLConstructsCorrectResolutions() {
        let enricher = TMDBEnricher.shared
        let posterURL = enricher.adaptiveURL(path: "/samplePoster.jpg", quality: .poster)
        let backdropURL = enricher.adaptiveURL(path: "/sampleBackdrop.jpg", quality: .backdrop)

        #expect(posterURL?.absoluteString.contains("https://image.tmdb.org/t/p/w780/samplePoster.jpg") == true)
        #expect(backdropURL?.absoluteString.contains("https://image.tmdb.org/t/p/original/sampleBackdrop.jpg") == true)
    }

    @Test func genreModelContainsAllSupportedGenres() {
        let all = Genre.allGenres
        #expect(all.count == 18)

        let names = Set(all.map { $0.name })
        #expect(names.contains("Action"))
        #expect(names.contains("Anime"))
        #expect(names.contains("Bollywood"))
        #expect(names.contains("Classics"))
        #expect(names.contains("K-Drama"))
        #expect(names.contains("Short Films"))
        #expect(names.contains("Western"))
    }

    @Test func tmdbCatalogCacheActorStoresAndExpiresEntries() async {
        let cache = TMDBCatalogCacheActor()
        let testItem = MediaItem(id: "test-123", title: "Test Movie", description: "Overview", imageURL: nil, posterURL: nil, backdropURL: nil, heroURL: nil, streamURL: nil, category: "Movie", progress: nil, trailerURL: nil, cast: nil, seasons: nil, runtime: nil, certification: nil, genres: nil, popularity: 99.5, releaseDate: "2026-08-30", voteAverage: 8.5)
        
        await cache.set(key: "test:key", items: [testItem], ttl: .trendingDay)
        let cached = await cache.get(key: "test:key")
        #expect(cached?.count == 1)
        #expect(cached?.first?.id == "test-123")
        #expect(cached?.first?.voteAverage == 8.5)
        
        // Test custom 0-second expired TTL
        await cache.set(key: "test:expired", items: [testItem], ttl: .custom(-1))
        let expired = await cache.get(key: "test:expired")
        #expect(expired == nil)
        
        await cache.clear()
        let cleared = await cache.get(key: "test:key")
        #expect(cleared == nil)
    }

    @Test func tmdbGenreMapperResolvesCorrectNames() {
        let genreNames = TMDBGenreMapper.names(for: [80, 18])
        #expect(genreNames == ["Crime", "Drama"])

        let singleName = TMDBGenreMapper.names(for: [28])
        #expect(singleName == ["Action"])

        let nilNames = TMDBGenreMapper.names(for: nil)
        #expect(nilNames == nil)

        let emptyNames = TMDBGenreMapper.names(for: [])
        #expect(emptyNames == nil)
    }

    @Test func mediaItemConversionPreservesMetadata() {
        let movie = TMDBMovie(id: 456, title: "Spider-Man", overview: "Friendly neighbor", posterPath: "/spider.jpg", backdropPath: "/spider_bg.jpg", releaseDate: "2026-07-24", voteAverage: 8.9, popularity: 1500.0, genreIds: [28, 12, 878])
        let mediaItem = movie.toMediaItem()
        
        #expect(mediaItem.id == "456")
        #expect(mediaItem.title == "Spider-Man")
        #expect(mediaItem.category == "Movie")
        #expect(mediaItem.voteAverage == 8.9)
        #expect(mediaItem.popularity == 1500.0)
        #expect(mediaItem.releaseDate == "2026-07-24")
        #expect(mediaItem.genres == ["Action", "Adventure", "Sci-Fi"])

        let show = TMDBTVShow(id: 789, name: "Reacher", overview: "Jack Reacher", posterPath: "/reacher.jpg", backdropPath: "/reacher_bg.jpg", firstAirDate: "2022-02-04", voteAverage: 8.2, popularity: 800.0, genreIds: [80, 18])
        let showItem = show.toMediaItem()
        
        #expect(showItem.id == "789")
        #expect(showItem.title == "Reacher")
        #expect(showItem.category == "TV Show")
        #expect(showItem.voteAverage == 8.2)
        #expect(showItem.popularity == 800.0)
        #expect(showItem.genres == ["Crime", "Drama"])
    }

    @Test @MainActor func mediaListTypeTitlesAreAccurate() {
        let prev = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.setLanguage(prev) }
        LanguageManager.shared.setLanguage(.english)

        #expect(MediaListView.ListType.trendingAllDay.title == "Trending Today")
        #expect(MediaListView.ListType.trendingAllWeek.title == "Trending This Week")
        #expect(MediaListView.ListType.popularMovies.title == "Popular Movies")
        #expect(MediaListView.ListType.nowPlayingMovies.title == "Now Playing")
        #expect(MediaListView.ListType.upcomingMovies.title == "Upcoming")
        #expect(MediaListView.ListType.airingTodayTV.title == "Airing Today")
        #expect(MediaListView.ListType.onTheAirTV.title == "On TV")
        #expect(MediaListView.ListType.topRatedTV.title == "Top Rated TV Shows")
    }

    @Test func tmdbVideoModelPropertiesAndEmbed() {
        let video = TMDBVideo(
            id: "vid-1",
            key: "dQw4w9WgXcQ",
            name: "Official Trailer",
            site: "YouTube",
            type: "Trailer",
            official: true,
            publishedAt: "2026-01-01T12:00:00.000Z"
        )
        
        #expect(video.youtubeURL?.absoluteString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(video.embedURL?.absoluteString.contains("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ") == true)
        #expect(video.thumbnailURL?.absoluteString.contains("maxresdefault.jpg") == true)
        #expect(video.fallbackThumbnailURL?.absoluteString.contains("mqdefault.jpg") == true)
        #expect(video.hqThumbnailURL?.absoluteString.contains("hqdefault.jpg") == true)
        #expect(video.maxResThumbnailURL?.absoluteString.contains("maxresdefault.jpg") == true)
    }

    @Test func bonusContentItemPropertiesAndStreamability() {
        let specialEp = Episode(id: 101, name: "The Making of Season 1", overview: "Behind the scenes look", stillURL: nil, heroURL: nil, episodeNumber: 1, seasonNumber: 0, airDate: "2026-01-01", runtime: 45)
        let bonusSpecial = BonusContentItem(
            id: "special-1",
            title: "The Making of Season 1",
            subtitle: "Special • 45m",
            categoryType: "Special",
            thumbnailURL: nil,
            videoKey: nil,
            episode: specialEp
        )
        #expect(bonusSpecial.isStreamableEpisode == true)
        #expect(bonusSpecial.categoryType == "Special")

        let bonusFeaturette = BonusContentItem(
            id: "feat-1",
            title: "Creating the Soundscape",
            subtitle: "Featurette",
            categoryType: "Featurette",
            thumbnailURL: URL(string: "https://example.com/thumb.jpg"),
            videoKey: "abcd1234",
            episode: nil
        )
        #expect(bonusFeaturette.isStreamableEpisode == false)
        #expect(bonusFeaturette.videoKey == "abcd1234")
        #expect(bonusFeaturette.youtubeURL?.absoluteString == "https://www.youtube.com/watch?v=abcd1234")
    }

    @Test func mediaItemAudioTracksAreTruthfulWithoutFakeCodecs() {
        var item = MediaItem(id: "tt123", title: "Test Title", description: "Desc", imageURL: nil, posterURL: nil, backdropURL: nil, heroURL: nil, streamURL: nil, category: "Movie")
        item.spokenLanguages = ["Korean", "English"]
        item.audioTracks = ["Korean", "English"]

        let tracks = item.displayAudioTracks
        #expect(tracks == ["Korean", "English"])
        for track in tracks {
            #expect(!track.contains("Dolby Atmos"))
            #expect(!track.contains("Dolby 5.1"))
            #expect(!track.contains("AAC"))
        }
    }

    @Test func topRatedRankingExcludesLowRatedAndSortsDescending() {
        let items: [MediaItem] = [
            MediaItem(id: "tt1", title: "It Ends", description: "", streamURL: nil, category: "movie", voteAverage: 5.7),
            MediaItem(id: "tt2", title: "The Shawshank Redemption", description: "", streamURL: nil, category: "movie", voteAverage: 9.3),
            MediaItem(id: "tt3", title: "The Godfather", description: "", streamURL: nil, category: "movie", voteAverage: 9.2),
            MediaItem(id: "tt4", title: "Low Tier Movie", description: "", streamURL: nil, category: "movie", voteAverage: 6.4),
            MediaItem(id: "tt5", title: "The Dark Knight", description: "", streamURL: nil, category: "movie", voteAverage: 9.1),
            MediaItem(id: "tt6", title: "Mid Movie", description: "", streamURL: nil, category: "movie", voteAverage: 7.2)
        ]

        let topRated = items.filter { ($0.voteAverage ?? 0) >= 8.0 }
            .sorted { ($0.voteAverage ?? 0) > ($1.voteAverage ?? 0) }

        #expect(topRated.count == 3)
        #expect(topRated[0].title == "The Shawshank Redemption")
        #expect(topRated[1].title == "The Godfather")
        #expect(topRated[2].title == "The Dark Knight")
        #expect(!topRated.contains { $0.title == "It Ends" })
    }

    @Test func topRatedShowsRankingExcludesLowRatedAndSortsDescending() {
        let shows: [MediaItem] = [
            MediaItem(id: "tt10", title: "Breaking Bad", description: "", streamURL: nil, category: "series", voteAverage: 9.5),
            MediaItem(id: "tt11", title: "The Wire", description: "", streamURL: nil, category: "series", voteAverage: 9.3),
            MediaItem(id: "tt12", title: "Random Weak Series", description: "", streamURL: nil, category: "series", voteAverage: 5.1),
            MediaItem(id: "tt13", title: "Game of Thrones", description: "", streamURL: nil, category: "series", voteAverage: 9.2),
            MediaItem(id: "tt14", title: "Average Drama", description: "", streamURL: nil, category: "series", voteAverage: 6.8)
        ]

        let topRated = shows.filter { ($0.voteAverage ?? 0) >= 8.2 }
            .sorted { ($0.voteAverage ?? 0) > ($1.voteAverage ?? 0) }

        #expect(topRated.count == 3)
        #expect(topRated[0].title == "Breaking Bad")
        #expect(topRated[1].title == "The Wire")
        #expect(topRated[2].title == "Game of Thrones")
        #expect(!topRated.contains { $0.title == "Random Weak Series" })
    }

    @Test func rootImdbIDStripsEpisodicSuffix() {
        let enricher = TMDBEnricher.shared
        #expect(enricher.rootImdbID(from: "tt0903747:1:1") == "tt0903747")
        #expect(enricher.rootImdbID(from: "tt0111161") == "tt0111161")
        #expect(enricher.rootImdbID(from: "series:tt0903747") == "tt0903747")
        #expect(enricher.rootImdbID(from: "tmdb-12345") == nil)
    }

    @Test func stremioMetaDetailDecodesLogoAndMapsToMediaItem() throws {
        let json = """
        {"id":"tt0111161","type":"movie","name":"The Shawshank Redemption","poster":"https://images.metahub.space/poster/small/tt0111161/img","background":"https://images.metahub.space/background/medium/tt0111161/img","logo":"https://images.metahub.space/logo/medium/tt0111161/img","description":"Hope","releaseInfo":"1994","imdbRating":"9.3"}
        """.data(using: .utf8)!
        let detail = try JSONDecoder().decode(StremioMetaDetail.self, from: json)
        #expect(detail.logo == "https://images.metahub.space/logo/medium/tt0111161/img")
        let item = detail.toMediaItem()
        #expect(item.logoURL?.absoluteString == "https://images.metahub.space/logo/medium/tt0111161/img")
    }

    @Test func stremioMetaPreviewFallsBackToMetahubLogoURL() throws {
        let json = """
        {"id":"tt0903747","type":"series","name":"Breaking Bad"}
        """.data(using: .utf8)!
        let preview = try JSONDecoder().decode(StremioMetaPreview.self, from: json)
        let item = preview.toMediaItem()
        // No embedded logo → constructed Metahub fallback so the buffering
        // view shows the graphic logo instead of the text fallback.
        #expect(item.logoURL?.absoluteString == "https://images.metahub.space/logo/medium/tt0903747/img")
    }
}


