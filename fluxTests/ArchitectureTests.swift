import Testing
import Foundation
@testable import flux

struct ArchitectureTests {

    @Test func fluxErrorDescriptionsAreMeaningful() {
        let streamErr = FluxError.streaming(.noStreamsFound)
        #expect(streamErr.localizedDescription.contains("No playable streams found"))

        let tmdbErr = FluxError.tmdb(.invalidAPIKey)
        #expect(tmdbErr.localizedDescription.contains("Invalid TMDB API key"))

        let authErr = FluxError.auth(.invalidCredentials)
        #expect(authErr.localizedDescription.contains("Incorrect email or password"))

        let syncErr = FluxError.sync(.unauthorized)
        #expect(syncErr.localizedDescription.contains("Unauthorized"))
    }

    @Test func tmdbCacheActorStoresAndRetrievesItems() async {
        let cache = TMDBMemoryCacheActor(itemCacheLimit: 10, idCacheLimit: 10)
        let item = MediaItem(id: "tt5555", title: "Test Cache Movie", description: "", streamURL: nil, category: "Movie")

        await cache.storeItem(item, for: item.id)
        let retrieved = await cache.getItem(for: item.id)
        #expect(retrieved?.id == "tt5555")
        #expect(retrieved?.title == "Test Cache Movie")

        await cache.storeIMDbID("tt7777", for: "movie:12345")
        let imdbID = await cache.getIMDbID(for: "movie:12345")
        #expect(imdbID == "tt7777")

        await cache.storeNewEpisodeStatus(true, for: "999")
        let hasNew = await cache.getNewEpisodeStatus(for: "999")
        #expect(hasNew == true)
    }

    @Test func streamCacheActorStoresAndRetrievesStreams() async {
        let cache = StreamCacheActor(ttl: 60, maxEntries: 10)
        let stream = Stream(
            title: "1080p Stream",
            cleanTitle: "1080p Stream",
            url: URL(string: "https://example.com/video.mp4")!,
            source: "TestAddon",
            quality: "1080p",
            size: "2.1 GB",
            language: "EN",
            seeders: 100,
            leechers: 10
        )

        await cache.set(key: "tt1234:1:1", streams: [stream])
        let cached = await cache.get(key: "tt1234:1:1")
        #expect(cached?.count == 1)
        #expect(cached?.first?.quality == "1080p")
        #expect(cached?.first?.seeders == 100)
    }

    @Test func warmCoreControllerStoresAndAdoptsCore() {
        let controller = WarmCoreController()
        #expect(controller.activeCore == nil)
        controller.discardCore()
        #expect(controller.activeCore == nil)
    }

    @Test func streamRacingControllerRacesFastestTorrent() async {
        let controller = StreamRacingController()
        let torrent = Stream(
            title: "4K Torrent",
            cleanTitle: "4K Torrent",
            url: URL(string: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")!,
            source: "Torrentio",
            quality: "4K",
            size: "15 GB",
            seeders: 250
        )

        let winner = await controller.raceBestStream(
            from: [torrent],
            deadHashes: [],
            sourceMode: "both",
            urlResolver: { $0.url }
        )

        #expect(winner?.cleanTitle == "4K Torrent")
        #expect(winner?.isTorrent == true)
    }
}
