//
//  fluxTests.swift
//  fluxTests
//
//  Created by Zain Ul Nazir on 04/12/25.
//

import Testing
import Foundation
import CoreGraphics
@testable import flux

struct fluxTests {

    @Test func decodedImageCostUsesFourBytesPerPixel() {
        #expect(ImageInMemoryCache.decodedImageCost(width: 1920, height: 1080) == 8_294_400)
        #expect(ImageInMemoryCache.decodedImageCost(width: 0, height: 1080) == 1)
    }

    @Test func decodedImageCostSaturatesOnOverflow() {
        #expect(ImageInMemoryCache.decodedImageCost(width: Int.max, height: 2) == Int.max)
    }

    // MARK: - VolumeCurve Tests

    @Test func volumeCurveSilenceAtZero() {
        #expect(VolumeCurve.uiToMpv(0.0) == 0.0)
        #expect(VolumeCurve.mpvToUi(0.0) == 0.0)
    }

    @Test func volumeCurvePerceptualMappingAtHalfVolume() {
        let mpvVol = VolumeCurve.uiToMpv(0.5)
        // 0.5 slider maps to sqrt(0.5) * 100 ≈ 70.7106
        #expect(abs(mpvVol - 70.7106) < 0.01)
        // Decibels at 70.71 is -9.03 dB (human acoustic perceptual half loudness)
        let db = VolumeCurve.decibels(forMpvVolume: mpvVol)
        #expect(abs(db - (-9.03)) < 0.1)
    }

    @Test func volumeCurveReferenceAtOneHundredPercent() {
        let mpvVol = VolumeCurve.uiToMpv(1.0)
        #expect(mpvVol == 100.0)
        let db = VolumeCurve.decibels(forMpvVolume: mpvVol)
        #expect(abs(db - 0.0) < 0.001)
    }

    @Test func volumeCurveBoostAtTwoHundredPercent() {
        let mpvVol = VolumeCurve.uiToMpv(2.0)
        #expect(mpvVol == 200.0)
        let db = VolumeCurve.decibels(forMpvVolume: mpvVol)
        // 200% volume amplification in mpv is +18.06 dB (nearly 8x power boost)
        #expect(abs(db - 18.06) < 0.1)
    }

    @Test func volumeCurveRoundtripFidelity() {
        let testValues: [Double] = [0.0, 0.1, 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
        for val in testValues {
            let mpv = VolumeCurve.uiToMpv(val)
            let ui = VolumeCurve.mpvToUi(mpv)
            #expect(abs(ui - val) < 0.001)
        }
    }

    // MARK: - MediaItem Metadata & Formatting Tests

    @Test func runtimeFormattingBothMinutesAndHours() {
        #expect(MediaItem.formatRuntime(minutes: 45) == "45m")
        #expect(MediaItem.formatRuntime(minutes: 59) == "59m")
        #expect(MediaItem.formatRuntime(minutes: 60) == "1h")
        #expect(MediaItem.formatRuntime(minutes: 120) == "2h")
        #expect(MediaItem.formatRuntime(minutes: 148) == "2h 28m")
        #expect(MediaItem.formatRuntime(minutes: 0) == nil)
        #expect(MediaItem.formatRuntime(minutes: nil) == nil)

        #expect(MediaItem.formatRuntimeString("45 min") == "45m")
        #expect(MediaItem.formatRuntimeString("148 min") == "2h 28m")
        #expect(MediaItem.formatRuntimeString("2h 28m") == "2h 28m")
        #expect(MediaItem.formatRuntimeString("51m") == "51m")
    }

    @Test func regionOfOriginDynamicPluralization() {
        var itemSingle = MediaItem(seed: "tt1", title: "Single Origin", category: "movie")
        itemSingle.originCountry = "United States"
        #expect(itemSingle.displayOriginCountryTitle == "Region of Origin")

        var itemMultiple = MediaItem(seed: "tt2", title: "Multiple Origin", category: "movie")
        itemMultiple.originCountry = "United Kingdom, United States, Canada"
        #expect(itemMultiple.displayOriginCountryTitle == "Regions of Origin")
    }

    @Test func originalLanguageCountryFallback() {
        var itemUS = MediaItem(seed: "tt1", title: "US Movie", category: "movie")
        itemUS.originCountry = "US"
        #expect(itemUS.displayOriginalLanguage == "English")

        var itemFR = MediaItem(seed: "tt2", title: "French Movie", category: "movie")
        itemFR.originCountry = "FR"
        #expect(itemFR.displayOriginalLanguage == "French")

        var itemWithLang = MediaItem(seed: "tt3", title: "Korean Movie", category: "movie")
        itemWithLang.originalLanguage = "ko"
        itemWithLang.originCountry = "KR"
        #expect(itemWithLang.displayOriginalLanguage == "Korean")
    }

    // MARK: - Audio Track Language Matching Precision Tests

    @Test func trackMatchesLanguagePreventsSubwordFalsePositives() {
        // "commentary", "adventure", "opening", "ending" must NOT falsely match "en" (English)
        let commTrack = Track(id: 1, type: "audio", title: "Audio Commentary", lang: "und", isSelected: false)
        #expect(!MPVController.trackMatchesLanguage(track: commTrack, targetLang: "English"))
        #expect(!MPVController.trackMatchesLanguage(track: commTrack, targetLang: "en"))

        let adventureTrack = Track(id: 2, type: "audio", title: "Adventure Sound FX", lang: "und", isSelected: false)
        #expect(!MPVController.trackMatchesLanguage(track: adventureTrack, targetLang: "English"))

        let openingTrack = Track(id: 3, type: "audio", title: "Opening Theme", lang: "und", isSelected: false)
        #expect(!MPVController.trackMatchesLanguage(track: openingTrack, targetLang: "English"))

        // "releases" must NOT falsely match "es" (Spanish)
        let releasesTrack = Track(id: 4, type: "audio", title: "Special Releases Mix", lang: "und", isSelected: false)
        #expect(!MPVController.trackMatchesLanguage(track: releasesTrack, targetLang: "Spanish"))
        #expect(!MPVController.trackMatchesLanguage(track: releasesTrack, targetLang: "es"))

        // "edition" must NOT falsely match "it" (Italian)
        let editionTrack = Track(id: 5, type: "audio", title: "Criterion Edition Mix", lang: "und", isSelected: false)
        #expect(!MPVController.trackMatchesLanguage(track: editionTrack, targetLang: "Italian"))
        #expect(!MPVController.trackMatchesLanguage(track: editionTrack, targetLang: "it"))

        // "default" must NOT falsely match "de" (German)
        let defaultTrack = Track(id: 6, type: "audio", title: "Default Track", lang: "und", isSelected: false)
        #expect(!MPVController.trackMatchesLanguage(track: defaultTrack, targetLang: "German"))
        #expect(!MPVController.trackMatchesLanguage(track: defaultTrack, targetLang: "de"))
    }

    @Test func trackMatchesLanguageAccuratelyIdentifiesRealLanguageTags() {
        // Explicit metadata code
        let enMetaTrack = Track(id: 1, type: "audio", title: "Surround 5.1", lang: "eng", isSelected: false)
        #expect(MPVController.trackMatchesLanguage(track: enMetaTrack, targetLang: "English"))

        let jaMetaTrack = Track(id: 2, type: "audio", title: "Stereo", lang: "ja", isSelected: false)
        #expect(MPVController.trackMatchesLanguage(track: jaMetaTrack, targetLang: "Japanese"))
        #expect(MPVController.trackMatchesLanguage(track: jaMetaTrack, targetLang: "ja"))

        // Bracketed and tagged titles
        let bracketTrack = Track(id: 3, type: "audio", title: "Audio [en] 5.1", lang: "und", isSelected: false)
        #expect(MPVController.trackMatchesLanguage(track: bracketTrack, targetLang: "English"))

        let parenTrack = Track(id: 4, type: "audio", title: "Stereo (ja)", lang: "und", isSelected: false)
        #expect(MPVController.trackMatchesLanguage(track: parenTrack, targetLang: "Japanese"))

        // Full word titles
        let spanishTrack = Track(id: 5, type: "audio", title: "Spanish Latino 5.1", lang: "und", isSelected: false)
        #expect(MPVController.trackMatchesLanguage(track: spanishTrack, targetLang: "Spanish"))

        let frenchTrack = Track(id: 6, type: "audio", title: "French VFF AC3", lang: "und", isSelected: false)
        #expect(MPVController.trackMatchesLanguage(track: frenchTrack, targetLang: "French"))
    }

    // MARK: - Audio Auto-Selection Tests

    @Test func originalLanguageAudioWinsOverEnglishCommentary() {
        // 3 Idiots incident: Hindi movie, Default Audio English, container
        // carries Hindi dialogue + English-tagged directors' commentary.
        // The original-language dialogue track must win — never commentary.
        let hindiDialogue = Track(id: 1, type: "audio", title: "Stereo", lang: "hin", isSelected: false)
        let engCommentary = Track(id: 2, type: "audio", title: "Directors Commentary", lang: "eng", isSelected: false)

        let pick = MPVController.preferredAudioTrack(
            from: [hindiDialogue, engCommentary],
            preferredLang: "English",
            originalLanguage: "hi"
        )
        #expect(pick?.id == hindiDialogue.id)
    }

    @Test func preferredLanguageDialogueBeatsCommentaryWhenOriginalMissing() {
        // Foreign title whose file only carries English audio: preferred
        // dialogue plays, commentary never does (even when it is default).
        let engCommentary = Track(id: 1, type: "audio", title: "Commentary", lang: "eng", isSelected: false, isDefault: true)
        let engDialogue = Track(id: 2, type: "audio", title: "Stereo", lang: "eng", isSelected: false)

        let pick = MPVController.preferredAudioTrack(
            from: [engCommentary, engDialogue],
            preferredLang: "English",
            originalLanguage: "hi"
        )
        #expect(pick?.id == engDialogue.id)
    }

    @Test func sameLanguageCommentaryNeverBeatsDialogue() {
        // English title, English preferred: the old `?? matching.first`
        // fallthrough landed on commentary when every preferred match was
        // commentary. The container default dialogue must win instead.
        let engCommentary = Track(id: 1, type: "audio", title: "Commentary 2020", lang: "eng", isSelected: false, isDefault: true)
        let engDialogue = Track(id: 2, type: "audio", title: "5.1", lang: "eng", isSelected: false)

        let pick = MPVController.preferredAudioTrack(
            from: [engCommentary, engDialogue],
            preferredLang: "English",
            originalLanguage: "en"
        )
        #expect(pick?.id == engDialogue.id)
    }

    @Test func commentaryOnlyContainerIsLastResort() {
        let engCommentary = Track(id: 1, type: "audio", title: "Commentary", lang: "eng", isSelected: false)
        let pick = MPVController.preferredAudioTrack(
            from: [engCommentary],
            preferredLang: "English",
            originalLanguage: "en"
        )
        #expect(pick?.id == engCommentary.id)
    }

    // MARK: - Actor Search & Person Candidate Tests

    @Test func personCandidateConvertsToMediaItem() {
        let candidate = PersonCandidate(
            id: 10859,
            name: "Ryan Reynolds",
            profilePath: "/4Yt28sL.jpg",
            knownForDepartment: "Acting",
            knownForTitles: ["Deadpool", "Free Guy"],
            popularity: 88.5
        )

        let mediaItem = candidate.toMediaItem()
        #expect(mediaItem.id == "person-10859")
        #expect(mediaItem.title == "Ryan Reynolds")
        #expect(mediaItem.category == "Actor")
        #expect(mediaItem.personID == 10859)
        #expect(mediaItem.description == "Deadpool, Free Guy")
        #expect(mediaItem.posterURL?.absoluteString == "https://image.tmdb.org/t/p/w300/4Yt28sL.jpg")
    }

    // MARK: - Letterbox Trimming Tests

    @Test func letterboxTrimmingDetectsBlackBars() {
        let width = 160
        let height = 90
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            #expect(Bool(false), "Failed to create test graphics context")
            return
        }

        // Fill with black bars (top 15 rows and bottom 15 rows)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Fill bright center content (middle 60 rows)
        context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 15, width: width, height: 60))

        guard let originalCG = context.makeImage() else {
            #expect(Bool(false), "Failed to generate test image")
            return
        }

        let trimmedCG = CachedImageDownsampler.trimLetterbox(from: originalCG)
        #expect(trimmedCG.height < height, "Trimmed image should have removed black bars")
        #expect(trimmedCG.width == width, "Width should remain unchanged for letterbox")
    }

    // MARK: - OTT Watch Provider Regional Mappings

    @Test func ottPlatformProviderMappingsAndRegionalOverrides() {
        #expect(TMDBEnricher.tmdbProviderIDs["dnp"] == 337)
        #expect(TMDBEnricher.tmdbProviderIDs["amp"] == 9)
        #expect(TMDBEnricher.tmdbProviderIDs["nfx"] == 8)
        #expect(TMDBEnricher.tmdbProviderIDs["hbm"] == 1899)
        #expect(TMDBEnricher.regionalProviderOverrides["IN"]?["dnp"] == "122|2336|337")
        #expect(TMDBEnricher.regionalProviderOverrides["IN"]?["amp"] == "119|9")
        #expect(TMDBEnricher.regionalProviderOverrides["IN"]?["cru"] == "283|1112")
    }
}

