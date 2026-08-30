import Testing
import Foundation
@testable import flux

struct TMDBEnricherTests {

    @Test func tmdbAdaptiveURLConstructsCorrectResolutions() {
        let enricher = TMDBEnricher.shared
        let posterURL = enricher.adaptiveURL(path: "/samplePoster.jpg", quality: .poster)
        let backdropURL = enricher.adaptiveURL(path: "/sampleBackdrop.jpg", quality: .backdrop)

        #expect(posterURL?.absoluteString.contains("https://image.tmdb.org/t/p/w780/samplePoster.jpg") == true)
        #expect(backdropURL?.absoluteString.contains("https://image.tmdb.org/t/p/w1280/sampleBackdrop.jpg") == true)
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

    @Test func mediaListTypeTitlesAreAccurate() {
        #expect(MediaListView.ListType.trendingAllDay.title == "Trending Today")
        #expect(MediaListView.ListType.trendingAllWeek.title == "Trending This Week")
        #expect(MediaListView.ListType.popularMovies.title == "Popular Movies")
        #expect(MediaListView.ListType.nowPlayingMovies.title == "Now Playing in Theatres")
        #expect(MediaListView.ListType.airingTodayTV.title == "Airing Today on TV")
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
        #expect(video.thumbnailURL?.absoluteString.contains("hqdefault.jpg") == true)
        #expect(video.maxResThumbnailURL?.absoluteString.contains("maxresdefault.jpg") == true)
    }
}

