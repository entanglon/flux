import Testing
import Foundation
@testable import flux

struct StreamManagerTests {

    @Test func qualityScoringRanksResolutionsCorrectly() {
        let manager = StreamManager.shared
        #expect(manager.qualityScore("4K") > manager.qualityScore("2K"))
        #expect(manager.qualityScore("2K") > manager.qualityScore("1080P"))
        #expect(manager.qualityScore("1080P") > manager.qualityScore("720P"))
        #expect(manager.qualityScore("720P") > manager.qualityScore("480P"))
        #expect(manager.qualityScore("2160p") == manager.qualityScore("4K"))
        #expect(manager.qualityScore("1440P") == manager.qualityScore("2K"))
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

    @Test func parseQualityExtractsFromFilenameWhenTitleIsGeneric() {
        let manager = StreamManager.shared
        #expect(manager.parseQuality(from: "Auto", filename: "Reacher.S01E01.2160p.UHD.HDR.mkv") == "4K")
        #expect(manager.parseQuality(from: "Provider Stream", filename: "Show.S02E05.1080p.WEBRip.mp4") == "1080p")
        #expect(manager.parseQuality(from: "Movie 720p", filename: nil) == "720p")
        #expect(manager.parseQuality(from: "Standard Stream", filename: "Video.480p.avi") == "480p")
    }

    @Test func resolveImdbIDReturnsImmediatelyForTtIDs() async {
        let manager = StreamManager.shared
        let item = MediaItem(
            id: "tt9288030",
            title: "Reacher",
            description: "",
            streamURL: nil,
            category: "Series"
        )
        let resolved = await manager.resolveImdbID(for: item, type: "series")
        #expect(resolved == "tt9288030")
    }

    @Test func streamCategorizationSeparatesDirectHTTPFromTorrents() {
        let p2pTorrent = Stream(
            title: "Movie.1080p.BluRay.x264",
            cleanTitle: "Movie",
            url: URL(string: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")!,
            source: "Torrentio",
            quality: "1080p",
            seeders: 150
        )

        let directWebStream = Stream(
            title: "Movie.1080p.WEB.mp4",
            cleanTitle: "Movie",
            url: URL(string: "https://pengu.uk/direct/external/sample/tv.mp4")!,
            source: "PenguPlay",
            quality: "1080p",
            seeders: nil
        )

        let torrentioP2PStream = Stream(
            title: "Show.S01E01.720p",
            cleanTitle: "Show",
            url: URL(string: "https://torrentio.strem.fun/stream/123.mp4")!,
            source: "Torrentio",
            quality: "720p",
            seeders: 45
        )

        #expect(p2pTorrent.isTorrent == true)
        #expect(p2pTorrent.isDirectHTTP == false)

        #expect(directWebStream.isTorrent == false)
        #expect(directWebStream.isDirectHTTP == true)

        #expect(torrentioP2PStream.isTorrent == true)
        #expect(torrentioP2PStream.isDirectHTTP == false)
    }

    @Test func streamHealthComparatorPrioritizesHealthOverQuality() {
        let manager = StreamManager.shared

        let highHealth1080p = Stream(
            title: "Reacher.1080p.HighSeeds",
            cleanTitle: "Reacher",
            url: URL(string: "magnet:?xt=urn:btih:1111111111111111111111111111111111111111")!,
            source: "Torrentio",
            quality: "1080p",
            seeders: 2500,
            leechers: 100
        )

        let lowHealth4K = Stream(
            title: "Reacher.2160p.LowSeeds",
            cleanTitle: "Reacher",
            url: URL(string: "magnet:?xt=urn:btih:2222222222222222222222222222222222222222")!,
            source: "Torrentio",
            quality: "4K",
            seeders: 28,
            leechers: 20
        )

        // In standard All Sources sorting, 4K ranks above 1080p
        #expect(manager.streamSortComparator(lowHealth4K, highHealth1080p) == true)

        // In Best Health sorting, 2500 seeds significantly outranks 28 seeds
        #expect(manager.streamHealthComparator(highHealth1080p, lowHealth4K) == true)
        #expect(manager.streamHealthComparator(lowHealth4K, highHealth1080p) == false)
    }

    @Test func maximumResolutionFilteringCorrectlyCapsResolutions() {
        let manager = StreamManager.shared
        
        let stream4K = Stream(
            title: "Show.2160p",
            cleanTitle: "Show",
            url: URL(string: "https://example.com/4k.mp4")!,
            source: "WebStreamr",
            quality: "4K"
        )
        let stream1080p = Stream(
            title: "Show.1080p",
            cleanTitle: "Show",
            url: URL(string: "https://example.com/1080p.mp4")!,
            source: "WebStreamr",
            quality: "1080p"
        )
        let stream720p = Stream(
            title: "Show.720p",
            cleanTitle: "Show",
            url: URL(string: "https://example.com/720p.mp4")!,
            source: "WebStreamr",
            quality: "720p"
        )

        UserDefaults.standard.set("1080p", forKey: UserDefaults.Key.preferredQuality)
        #expect(manager.isWithinMaxResolution(stream4K) == false)
        #expect(manager.isWithinMaxResolution(stream1080p) == true)
        #expect(manager.isWithinMaxResolution(stream720p) == true)

        UserDefaults.standard.set("4K", forKey: UserDefaults.Key.preferredQuality)
        #expect(manager.isWithinMaxResolution(stream4K) == true)
        #expect(manager.isWithinMaxResolution(stream1080p) == true)
    }

    @Test func sourceIsolationGuaranteesTorrentioNeverDirectAndPenguNeverTorrent() {
        #expect(StreamManager.isP2PSource("Torrentio") == true)
        #expect(StreamManager.isHttpSource("Torrentio") == false)
        #expect(StreamManager.isP2PSource("Meteor") == true)
        #expect(StreamManager.isHttpSource("Meteor") == false)
        #expect(StreamManager.isP2PSource("Comet") == true)
        #expect(StreamManager.isP2PSource("Knightcrawler") == true)

        #expect(StreamManager.isHttpSource("PenguPlay") == true)
        #expect(StreamManager.isP2PSource("PenguPlay") == false)
        #expect(StreamManager.isHttpSource("WebStreamrMBG") == true)
        #expect(StreamManager.isP2PSource("WebStreamrMBG") == false)

        let torrentioStream = Stream(
            title: "Movie.2160p",
            cleanTitle: "Movie",
            url: URL(string: "magnet:?xt=urn:btih:17e191eae70e104db5dc4cea27950277336ac754")!,
            source: "Torrentio",
            quality: "4K",
            seeders: 192
        )
        #expect(torrentioStream.isTorrent == true)
        #expect(torrentioStream.isDirectHTTP == false)

        let penguStream = Stream(
            title: "Movie.1080p",
            cleanTitle: "Movie",
            url: URL(string: "https://pengu.uk/direct/external/test123")!,
            source: "PenguPlay",
            quality: "1080p",
            seeders: nil
        )
        #expect(penguStream.isDirectHTTP == true)
        #expect(penguStream.isTorrent == false)
    }

    @Test func parseQualityRecognizes2KAnd1440P() {
        let manager = StreamManager.shared
        #expect(manager.parseQuality(from: "Movie.2024.1440p.WEB-DL") == "2K")
        #expect(manager.parseQuality(from: "Movie.2024.2K.HDR") == "2K")
        #expect(manager.parseQuality(from: "Movie.2024.QHD.BluRay") == "2K")
        #expect(manager.parseQuality(from: "Movie.2024.2160p.UHD") == "4K")
        #expect(manager.parseQuality(from: "Movie.2024.1080p") == "1080p")
    }

    @Test func shouldQueryAddonStrictlyEnforcesSourceModeGating() {
        let manager = StreamManager.shared
        let torrentio = StremioAddon(
            id: "torrentio",
            name: "Torrentio",
            url: "https://torrentio.strem.fun/manifest.json",
            transportUrl: "https://torrentio.strem.fun/manifest.json"
        )
        let comet = StremioAddon(
            id: "comet",
            name: "Comet",
            url: "https://comet.elfhosted.com/manifest.json",
            transportUrl: "https://comet.elfhosted.com/manifest.json"
        )
        let pengu = StremioAddon(
            id: "pengu",
            name: "PenguPlay",
            url: "https://pengu.uk/manifest.json",
            transportUrl: "https://pengu.uk/manifest.json"
        )
        let webstreamr = StremioAddon(
            id: "webstreamr",
            name: "WebStreamrMBG",
            url: "https://webstreamr.org/manifest.json",
            transportUrl: "https://webstreamr.org/manifest.json"
        )

        // 1. In HTTP-only mode: torrent addons must NOT be queried
        #expect(manager.shouldQueryAddon(torrentio, sourceMode: "http") == false)
        #expect(manager.shouldQueryAddon(comet, sourceMode: "http") == false)
        #expect(manager.shouldQueryAddon(pengu, sourceMode: "http") == true)
        #expect(manager.shouldQueryAddon(webstreamr, sourceMode: "http") == true)

        // 2. In Torrent-only mode: HTTP addons must NOT be queried
        #expect(manager.shouldQueryAddon(torrentio, sourceMode: "torrent") == true)
        #expect(manager.shouldQueryAddon(comet, sourceMode: "torrent") == true)
        #expect(manager.shouldQueryAddon(pengu, sourceMode: "torrent") == false)
        #expect(manager.shouldQueryAddon(webstreamr, sourceMode: "torrent") == false)

        // 3. In Both mode: All addons must be queried
        #expect(manager.shouldQueryAddon(torrentio, sourceMode: "both") == true)
        #expect(manager.shouldQueryAddon(comet, sourceMode: "both") == true)
        #expect(manager.shouldQueryAddon(pengu, sourceMode: "both") == true)
        #expect(manager.shouldQueryAddon(webstreamr, sourceMode: "both") == true)
    }

    @Test func estimatedStartupBudgetReflectsQualityTiers() {
        let manager = StreamManager.shared
        let httpStream = Stream(
            title: "HTTP 1080p",
            cleanTitle: "Movie",
            url: URL(string: "https://pengu.uk/stream")!,
            source: "PenguPlay",
            quality: "1080p"
        )
        #expect(manager.estimatedStartupBudget(for: httpStream) == 8.0)

        let torrent4K = Stream(
            title: "Torrent 4K",
            cleanTitle: "Movie",
            url: URL(string: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")!,
            source: "Torrentio",
            quality: "4K",
            seeders: 120
        )
        #expect(manager.estimatedStartupBudget(for: torrent4K) == 13.0)

        let torrent2K = Stream(
            title: "Torrent 2K",
            cleanTitle: "Movie",
            url: URL(string: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")!,
            source: "Torrentio",
            quality: "2K",
            seeders: 80
        )
        #expect(manager.estimatedStartupBudget(for: torrent2K) == 10.0)

        let torrent1080 = Stream(
            title: "Torrent 1080p",
            cleanTitle: "Movie",
            url: URL(string: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")!,
            source: "Torrentio",
            quality: "1080p",
            seeders: 60
        )
        #expect(manager.estimatedStartupBudget(for: torrent1080) == 8.5)
    }

    @Test func selectFastStartCandidatePicksHealthiestTopQualityStream() {
        let manager = StreamManager.shared
        let stream4K = Stream(
            title: "Movie.2160p.REMUX",
            cleanTitle: "Movie",
            url: URL(string: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")!,
            source: "Torrentio",
            quality: "4K",
            size: "45.0 GB",
            seeders: 15
        )
        let stream2KFast = Stream(
            title: "Movie.1440p.Fast",
            cleanTitle: "Movie",
            url: URL(string: "magnet:?xt=urn:btih:abcdef0123456789abcdef0123456789abcdef01")!,
            source: "Torrentio",
            quality: "2K",
            size: "3.5 GB",
            seeders: 150
        )
        let stream1080p = Stream(
            title: "Movie.1080p",
            cleanTitle: "Movie",
            url: URL(string: "magnet:?xt=urn:btih:1111111111111111111111111111111111111111")!,
            source: "Torrentio",
            quality: "1080p",
            size: "2.0 GB",
            seeders: 80
        )

        let (winner, fallbacks) = manager.selectFastStartCandidate(
            from: [stream4K, stream2KFast, stream1080p],
            sourceMode: "both",
            preferredQuality: "4K",
            preferredLang: "English"
        )

        // 2K fast stream with 150 seeds and high StartupSpeedScore beats 45GB sluggish 4K stream
        #expect(winner?.id == stream2KFast.id)
        #expect(fallbacks.count >= 1)
    }

    @Test func selectFastStartCandidatePrefers1080pWhenConfigured() {
        let manager = StreamManager.shared
        UserDefaults.standard.set("1080p", forKey: UserDefaults.Key.preferredQuality)
        defer { UserDefaults.standard.removeObject(forKey: UserDefaults.Key.preferredQuality) }

        let stream4K = Stream(
            title: "Movie.2160p.HDR",
            cleanTitle: "Movie",
            url: URL(string: "https://stream.server/4k.mp4")!,
            source: "AIOStreams",
            quality: "4K"
        )
        let stream1080p = Stream(
            title: "Movie.1080p.WEB-DL",
            cleanTitle: "Movie",
            url: URL(string: "https://stream.server/1080p.mp4")!,
            source: "AIOStreams",
            quality: "1080p"
        )
        let stream720p = Stream(
            title: "Movie.720p.HD",
            cleanTitle: "Movie",
            url: URL(string: "https://stream.server/720p.mp4")!,
            source: "AIOStreams",
            quality: "720p"
        )

        let (winner, fallbacks) = manager.selectFastStartCandidate(
            from: [stream4K, stream1080p, stream720p],
            sourceMode: "http",
            preferredQuality: "1080p",
            preferredLang: "English"
        )

        // 4K is filtered out by cap, 1080p beats 720p
        #expect(winner?.quality == "1080p")
        #expect(winner?.id == stream1080p.id)
        #expect(fallbacks.contains(where: { $0.id == stream720p.id }))
        #expect(!fallbacks.contains(where: { $0.id == stream4K.id }))
    }

    @Test func aiostreamsSourceClassificationRecognizesHttpAndTorrents() {
        // Source-only classification (no URL = addon-level)
        // AIOStreams without URL defaults to torrent (unknown)
        #expect(StreamManager.isP2PSource("AIOStreams") == true)
        #expect(StreamManager.isHttpSource("AIOStreams") == false)

        // Individual stream URL classification: HTTP streams from AIOStreams
        #expect(StreamManager.isHttpSource("AIOStreams", url: "https://100.126.239.90:8888/proxy/stream/Movie.1080p.mkv") == true)
        #expect(StreamManager.isP2PSource("AIOStreams", url: "https://100.126.239.90:8888/proxy/stream/Movie.1080p.mkv") == false)

        // Individual stream URL classification: magnet links from AIOStreams
        #expect(StreamManager.isP2PSource("AIOStreams", url: "magnet:?xt=urn:btih:abc123def456") == true)
        #expect(StreamManager.isHttpSource("AIOStreams", url: "magnet:?xt=urn:btih:abc123def456") == false)
    }

    @Test func matchesPreferredLanguageCoupledWithOriginalLanguage() {
        let manager = StreamManager.shared

        let untaggedEnglishStream = Stream(
            title: "Oppenheimer.2023.1080p.BluRay.x264-SPARKS",
            cleanTitle: "Oppenheimer",
            url: URL(string: "https://stream.server/oppenheimer.mp4")!,
            source: "AIOStreams",
            quality: "1080p"
        )
        let frenchDubStream = Stream(
            title: "Oppenheimer.2023.1080p.FRENCH.DUBBED.x264",
            cleanTitle: "Oppenheimer",
            url: URL(string: "https://stream.server/oppenheimer_fr.mp4")!,
            source: "AIOStreams",
            quality: "1080p"
        )
        let dualAudioStream = Stream(
            title: "Oppenheimer.2023.1080p.Dual.Audio.x264",
            cleanTitle: "Oppenheimer",
            url: URL(string: "https://stream.server/oppenheimer_dual.mp4")!,
            source: "AIOStreams",
            quality: "1080p"
        )

        // For originally English title:
        // 1. Untagged release matches English
        #expect(manager.matchesPreferredLanguage(untaggedEnglishStream, preferred: "English", originalLanguage: "en", enableLanguageFilter: true) == true)
        // 2. Dual Audio matches English
        #expect(manager.matchesPreferredLanguage(dualAudioStream, preferred: "English", originalLanguage: "en", enableLanguageFilter: true) == true)
        // 3. Foreign dub without original English audio is rejected
        #expect(manager.matchesPreferredLanguage(frenchDubStream, preferred: "English", originalLanguage: "en", enableLanguageFilter: true) == false)

        // For originally foreign title (Korean 'ko'):
        let koreanStream = Stream(
            title: "Start-Up.S01E01.1080p.WEB-DL",
            cleanTitle: "Start-Up",
            url: URL(string: "https://stream.server/startup.mp4")!,
            source: "AIOStreams",
            quality: "1080p"
        )
        let koreanWithEngDub = Stream(
            title: "Start-Up.S01E01.1080p.English.Dub.x264",
            cleanTitle: "Start-Up",
            url: URL(string: "https://stream.server/startup_eng.mp4")!,
            source: "AIOStreams",
            quality: "1080p"
        )
        let koreanDualAudio = Stream(
            title: "Start-Up.S01E01.1080p.Dual-Audio.x264",
            cleanTitle: "Start-Up",
            url: URL(string: "https://stream.server/startup_dual.mp4")!,
            source: "AIOStreams",
            quality: "1080p"
        )

        // Native Korean without English audio does NOT match English preference
        #expect(manager.matchesPreferredLanguage(koreanStream, preferred: "English", originalLanguage: "ko", enableLanguageFilter: true) == false)
        // English dub or Dual-Audio on Korean title DOES match English preference
        #expect(manager.matchesPreferredLanguage(koreanWithEngDub, preferred: "English", originalLanguage: "ko", enableLanguageFilter: true) == true)
        #expect(manager.matchesPreferredLanguage(koreanDualAudio, preferred: "English", originalLanguage: "ko", enableLanguageFilter: true) == true)
    }

    @Test func languageFilterToggleBypassesFilterWhenDisabled() {
        let manager = StreamManager.shared

        let frenchDubStream = Stream(
            title: "Oppenheimer.2023.1080p.FRENCH.DUBBED.x264",
            cleanTitle: "Oppenheimer",
            url: URL(string: "https://stream.server/oppenheimer_fr.mp4")!,
            source: "AIOStreams",
            quality: "1080p"
        )

        // When enableLanguageFilter is false, stream is accepted unconditionally
        #expect(manager.matchesPreferredLanguage(frenchDubStream, preferred: "English", originalLanguage: "en", enableLanguageFilter: false) == true)
    }

    @Test func selectFastStartCandidateRespectsLanguageFilterToggle() {
        let manager = StreamManager.shared

        let fastForeignStream = Stream(
            title: "Movie.1080p.FRENCH.DUBBED",
            cleanTitle: "Movie",
            url: URL(string: "magnet:?xt=urn:btih:1111111111111111111111111111111111111111")!,
            source: "Torrentio",
            quality: "1080p",
            size: "2.0 GB",
            seeders: 200
        )
        let moderateEnglishStream = Stream(
            title: "Movie.1080p.WEBRip.x264",
            cleanTitle: "Movie",
            url: URL(string: "magnet:?xt=urn:btih:2222222222222222222222222222222222222222")!,
            source: "Torrentio",
            quality: "1080p",
            size: "2.5 GB",
            seeders: 60
        )

        // 1. With language filter ON: English stream wins over French dubbed stream
        let (winnerWithFilter, _) = manager.selectFastStartCandidate(
            from: [fastForeignStream, moderateEnglishStream],
            sourceMode: "both",
            preferredQuality: "1080p",
            preferredLang: "English",
            originalLanguage: "en",
            enableLanguageFilter: true
        )
        #expect(winnerWithFilter?.id == moderateEnglishStream.id)

        // 2. With language filter OFF: Highest seed/speed candidate wins without language penalty
        let (winnerWithoutFilter, _) = manager.selectFastStartCandidate(
            from: [fastForeignStream, moderateEnglishStream],
            sourceMode: "both",
            preferredQuality: "1080p",
            preferredLang: "English",
            originalLanguage: "en",
            enableLanguageFilter: false
        )
        #expect(winnerWithoutFilter?.id == fastForeignStream.id)
    }

    @Test func episodeMatchingAwardsBonusToTargetEpisode() {
        let manager = StreamManager.shared
        let ep2Stream = Stream(
            title: "The.Gentlemen.S01E02.1080p.WEB-DL",
            cleanTitle: "The Gentlemen S01E02",
            url: URL(string: "https://stream.server/s01e02.mp4")!,
            source: "PenguPlay",
            quality: "1080p"
        )
        let bonus = manager.evaluateEpisodeMatch(stream: ep2Stream, targetSeason: 1, targetEpisode: 2)
        #expect(bonus == 3500.0)
    }

    @Test func episodeMatchingDisqualifiesHttpSeasonPacksForEpisodicQueries() {
        let manager = StreamManager.shared
        let httpSeasonPack = Stream(
            title: "The Gentlemen Season 1 Complete 1080p",
            cleanTitle: "The Gentlemen Season 1 Complete",
            url: URL(string: "https://stream.server/season1_complete.mp4")!,
            source: "PenguPlay",
            quality: "1080p",
            isSeasonPack: true
        )
        let penalty = manager.evaluateEpisodeMatch(stream: httpSeasonPack, targetSeason: 1, targetEpisode: 2)
        #expect(penalty == -20000.0)
    }

    @Test func episodeMatchingSeverelyPenalizesWrongEpisodeReleases() {
        let manager = StreamManager.shared
        let ep1Stream = Stream(
            title: "The.Gentlemen.S01E01.1080p.WEB-DL",
            cleanTitle: "The Gentlemen S01E01",
            url: URL(string: "https://stream.server/s01e01.mp4")!,
            source: "PenguPlay",
            quality: "1080p"
        )
        let penalty = manager.evaluateEpisodeMatch(stream: ep1Stream, targetSeason: 1, targetEpisode: 2)
        #expect(penalty == -25000.0)
    }

    @Test func selectFastStartCandidatePicksTargetEpisodeOverSeasonPackAndWrongEpisode() {
        let manager = StreamManager.shared

        // HTTP Season Pack (compilation) that would otherwise win via HTTP bonus
        let httpSeasonPack = Stream(
            title: "The Gentlemen S01 Complete 1080p",
            cleanTitle: "The Gentlemen S01 Complete",
            url: URL(string: "https://stream.server/s01_pack.mp4")!,
            source: "PenguPlay",
            quality: "1080p",
            isSeasonPack: true
        )

        // Episode 1 stream
        let ep1Stream = Stream(
            title: "The.Gentlemen.S01E01.1080p.WEB-DL",
            cleanTitle: "The Gentlemen S01E01",
            url: URL(string: "https://stream.server/s01e01.mp4")!,
            source: "PenguPlay",
            quality: "1080p"
        )

        // Target Episode 2 stream
        let ep2Stream = Stream(
            title: "The.Gentlemen.S01E02.1080p.WEB-DL",
            cleanTitle: "The Gentlemen S01E02",
            url: URL(string: "https://stream.server/s01e02.mp4")!,
            source: "PenguPlay",
            quality: "1080p"
        )

        let (winner, _) = manager.selectFastStartCandidate(
            from: [httpSeasonPack, ep1Stream, ep2Stream],
            sourceMode: "both",
            preferredQuality: "1080p",
            preferredLang: "English",
            targetSeason: 1,
            targetEpisode: 2
        )

        #expect(winner?.id == ep2Stream.id)
    }
}

