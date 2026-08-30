import Testing
import Foundation
@testable import flux

struct StreamManagerTests {

    @Test func qualityScoringRanksResolutionsCorrectly() {
        let manager = StreamManager.shared
        #expect(manager.qualityScore("4K") > manager.qualityScore("1080P"))
        #expect(manager.qualityScore("1080P") > manager.qualityScore("720P"))
        #expect(manager.qualityScore("720P") > manager.qualityScore("480P"))
        #expect(manager.qualityScore("2160p") == manager.qualityScore("4K"))
        #expect(manager.qualityScore("HD") == manager.qualityScore("720P"))
    }

    @Test func streamStableKeyUniquelyIdentifiesTorrents() {
        let s1 = Stream(
            title: "Movie.2024.1080p.WEBRip",
            cleanTitle: "Movie (2024)",
            url: URL(string: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")!,
            source: "Torrentio",
            quality: "1080P",
            size: "2.1 GB",
            seeders: 100,
            fileIdx: 0
        )
        let s2 = Stream(
            title: "Movie.2024.1080p.WEBRip",
            cleanTitle: "Movie (2024)",
            url: URL(string: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")!,
            source: "Torrentio",
            quality: "1080P",
            size: "2.1 GB",
            seeders: 100,
            fileIdx: 0
        )
        let s3 = Stream(
            title: "Movie.2024.720p.HDTV",
            cleanTitle: "Movie (2024)",
            url: URL(string: "magnet:?xt=urn:btih:fedcba9876543210fedcba9876543210fedcba98")!,
            source: "Torrentio",
            quality: "720P",
            size: "1.1 GB",
            seeders: 50,
            fileIdx: 0
        )

        #expect(s1.stableKey == s2.stableKey)
        #expect(s1.stableKey != s3.stableKey)
        #expect(s1.isTorrent == true)
    }

    @Test func streamSortingPrefersHigherSeedersWithinSameQuality() {
        let manager = StreamManager.shared
        let highSeed = Stream(
            title: "High Seeds",
            cleanTitle: "Movie (2024)",
            url: URL(string: "magnet:?xt=urn:btih:1111111111111111111111111111111111111111")!,
            source: "Torrentio",
            quality: "1080P",
            seeders: 250
        )
        let lowSeed = Stream(
            title: "Low Seeds",
            cleanTitle: "Movie (2024)",
            url: URL(string: "magnet:?xt=urn:btih:2222222222222222222222222222222222222222")!,
            source: "Torrentio",
            quality: "1080P",
            seeders: 10
        )

        #expect(manager.streamSortComparator(highSeed, lowSeed) == true)
        #expect(manager.streamSortComparator(lowSeed, highSeed) == false)
    }
}
