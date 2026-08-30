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
}
