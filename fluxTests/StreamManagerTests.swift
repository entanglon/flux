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

    @Test func startupSpeedScorePrefersCompactHighSeedMKVOverBloatedRemux() {
        let manager = StreamManager.shared
        
        let compactMKV = Stream(
            title: "Movie.2024.1080p.WEBRip.x264-PSA.mkv",
            cleanTitle: "Movie (2024)",
            url: URL(string: "magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")!,
            source: "Torrentio",
            quality: "1080P",
            size: "2.1 GB",
            seeders: 120
        )
        
        let bloatedRemux = Stream(
            title: "Movie.2024.UHD.Remux.2160p.HEVC.TrueHD.Atmos-FLUX.mkv",
            cleanTitle: "Movie (2024)",
            url: URL(string: "magnet:?xt=urn:btih:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")!,
            source: "Torrentio",
            quality: "4K",
            size: "52.4 GB",
            seeders: 45
        )
        
        let scoreCompact = manager.computeStartupSpeedScore(compactMKV)
        let scoreRemux = manager.computeStartupSpeedScore(bloatedRemux)
        
        #expect(scoreCompact > scoreRemux)
        #expect(compactMKV.isMKV == true)
        #expect(compactMKV.isFastStart == true)
        #expect(compactMKV.startupSpeedTier == .instant || compactMKV.startupSpeedTier == .fast)
        #expect(bloatedRemux.isFastStart == false) // 52GB remux excluded from Fast Start tab
    }

    @Test func defensiveHandlingWhenSeedersIsNilExcludesFromFastStart() {
        let manager = StreamManager.shared
        let missingSeeders = Stream(
            title: "Unknown.Release.mkv",
            cleanTitle: "Unknown",
            url: URL(string: "magnet:?xt=urn:btih:cccccccccccccccccccccccccccccccccccccccc")!,
            source: "Torrentio",
            quality: "1080P",
            seeders: nil
        )

        let zeroSeeders = Stream(
            title: "Dead.Swarm.mkv",
            cleanTitle: "Dead Swarm",
            url: URL(string: "magnet:?xt=urn:btih:dddddddddddddddddddddddddddddddddddddddd")!,
            source: "Torrentio",
            quality: "1080P",
            seeders: 0
        )

        #expect(manager.computeStartupSpeedScore(missingSeeders) == 0.0)
        #expect(manager.computeStartupSpeedScore(zeroSeeders) == 0.0)
        #expect(manager.isFastStartStream(missingSeeders) == false)
        #expect(manager.isFastStartStream(zeroSeeders) == false)
        #expect(manager.speedTier(for: missingSeeders) == .standard)
    }

    @Test func directStreamReceivesInstantSpeedTier() {
        let manager = StreamManager.shared
        let directStream = Stream(
            title: "Direct MP4 CDN Stream",
            cleanTitle: "Direct Stream",
            url: URL(string: "https://example.com/video.mp4")!,
            source: "Direct",
            quality: "1080P"
        )

        #expect(directStream.isTorrent == false)
        #expect(manager.isFastStartStream(directStream) == true)
        #expect(manager.speedTier(for: directStream) == .instant)
        #expect(manager.computeStartupSpeedScore(directStream) >= 10000.0)
    }
}
