//
//  fluxTests.swift
//  fluxTests
//
//  Created by Zain Ul Nazir on 04/12/25.
//

import Testing
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

}
