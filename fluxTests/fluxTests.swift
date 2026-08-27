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

}
