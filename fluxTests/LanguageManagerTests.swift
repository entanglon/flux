import Testing
import Foundation
@testable import flux

struct LanguageManagerTests {

    @Test func appLanguagePropertiesAreCorrect() {
        let english = AppLanguage.english
        #expect(english.rawValue == "en")
        #expect(english.tmdbCode == "en-US")
        #expect(english.displayName == "English")
        #expect(english.nativeName == "English")
        #expect(english.audioLanguageName == "English")

        let japanese = AppLanguage.japanese
        #expect(japanese.rawValue == "ja")
        #expect(japanese.tmdbCode == "ja-JP")
        #expect(japanese.nativeName == "日本語")
        #expect(japanese.audioLanguageName == "Japanese")

        let spanish = AppLanguage.spanish
        #expect(spanish.rawValue == "es")
        #expect(spanish.tmdbCode == "es-ES")
        #expect(spanish.nativeName == "Español")

        let korean = AppLanguage.korean
        #expect(korean.rawValue == "ko")
        #expect(korean.tmdbCode == "ko-KR")
        #expect(korean.nativeName == "한국어")

        #expect(AppLanguage.allCases.count == 10)
    }

    @Test func localizationMatrixTranslatesKeysAndFallsBack() {
        #expect(L10n.string(for: "Home", language: .english) == "Home")
        #expect(L10n.string(for: "Home", language: .japanese) == "ホーム")
        #expect(L10n.string(for: "Home", language: .spanish) == "Inicio")
        #expect(L10n.string(for: "Home", language: .french) == "Accueil")
        #expect(L10n.string(for: "Home", language: .german) == "Startseite")
        #expect(L10n.string(for: "Home", language: .chinese) == "首页")

        #expect(L10n.string(for: "Continue Watching", language: .japanese) == "続きを見る")
        #expect(L10n.string(for: "Continue Watching", language: .spanish) == "Continuar viendo")
        #expect(L10n.string(for: "Continue Watching", language: .korean) == "이어보기")

        // Non-existent key should fall back to the key string itself
        #expect(L10n.string(for: "UnknownKeyXYZ", language: .japanese) == "UnknownKeyXYZ")
    }

    @Test func logoSelectionTier1PrefersActiveAppLanguage() {
        let logos: [[String: Any]] = [
            ["file_path": "/logo_en.png", "iso_639_1": "en", "vote_average": 9.0, "vote_count": 50, "width": 800],
            ["file_path": "/logo_ja.png", "iso_639_1": "ja", "vote_average": 7.0, "vote_count": 10, "width": 800]
        ]

        // When user prefers Japanese, Japanese logo is selected
        let selectedForJa = TMDBEnricher.selectBestLogoURL(
            from: logos,
            preferredLanguage: "ja",
            originalLanguage: "ja"
        )
        #expect(selectedForJa?.absoluteString == "https://image.tmdb.org/t/p/original/logo_ja.png")

        // When user prefers English, English logo is selected
        let selectedForEn = TMDBEnricher.selectBestLogoURL(
            from: logos,
            preferredLanguage: "en",
            originalLanguage: "ja"
        )
        #expect(selectedForEn?.absoluteString == "https://image.tmdb.org/t/p/original/logo_en.png")
    }

    @Test func logoSelectionTier2FallsBackToOriginalStudioLanguage() {
        // Scenario: User's app language is Spanish (es).
        // Anime Araiya-san has an authentic Japanese logo (ja) and an English logo (en), but NO Spanish logo.
        // Option 1 specification: App must fall back to the authentic Japanese original studio logo!
        let logos: [[String: Any]] = [
            ["file_path": "/logo_en.png", "iso_639_1": "en", "vote_average": 8.5, "vote_count": 100, "width": 1000],
            ["file_path": "/logo_ja.png", "iso_639_1": "ja", "vote_average": 7.0, "vote_count": 5, "width": 800]
        ]

        let selected = TMDBEnricher.selectBestLogoURL(
            from: logos,
            preferredLanguage: "es", // Spanish user
            originalLanguage: "ja"   // Japanese original title
        )

        #expect(selected?.absoluteString == "https://image.tmdb.org/t/p/original/logo_ja.png")
    }

    @Test func logoSelectionVotesCannotOverrideLanguageTiers() {
        // Even if an "other" language logo has massive community votes and resolution,
        // Tier 1 (Active App Language) and Tier 2 (Original Language) strictly dominate.
        let logos: [[String: Any]] = [
            ["file_path": "/logo_ru.png", "iso_639_1": "ru", "vote_average": 10.0, "vote_count": 999999, "width": 4000],
            ["file_path": "/logo_ja.png", "iso_639_1": "ja", "vote_average": 5.0, "vote_count": 1, "width": 500]
        ]

        let selectedForSpanish = TMDBEnricher.selectBestLogoURL(
            from: logos,
            preferredLanguage: "es",
            originalLanguage: "ja"
        )
        // ja (original) is Tier 2 (+5000), while ru is Tier 4 (+500). ja must win easily.
        #expect(selectedForSpanish?.absoluteString == "https://image.tmdb.org/t/p/original/logo_ja.png")
    }

    @Test func logoSelectionFiltersOutSvgAndNonPng() {
        let logos: [[String: Any]] = [
            ["file_path": "/logo.svg", "iso_639_1": "en", "vote_average": 9.0, "vote_count": 10, "width": 800],
            ["file_path": "/logo.jpg", "iso_639_1": "en", "vote_average": 9.0, "vote_count": 10, "width": 800],
            ["file_path": "/valid_logo.png", "iso_639_1": "en", "vote_average": 8.0, "vote_count": 10, "width": 800]
        ]

        let selected = TMDBEnricher.selectBestLogoURL(
            from: logos,
            preferredLanguage: "en",
            originalLanguage: "en"
        )
        #expect(selected?.absoluteString == "https://image.tmdb.org/t/p/original/valid_logo.png")
    }

    // MARK: - Poster Language Selection Tests

    @Test func posterSelectionTier1PrefersActiveAppLanguage() {
        let posters: [[String: Any]] = [
            ["file_path": "/poster_en.jpg", "iso_639_1": "en", "vote_average": 8.0, "vote_count": 200, "width": 2000, "height": 3000],
            ["file_path": "/poster_ja.jpg", "iso_639_1": "ja", "vote_average": 7.5, "vote_count": 50, "width": 2000, "height": 3000]
        ]

        let selectedJa = TMDBEnricher.selectBestPosterPath(
            from: posters,
            preferredLanguage: "ja",
            originalLanguage: "en"
        )
        #expect(selectedJa == "/poster_ja.jpg")

        let selectedEn = TMDBEnricher.selectBestPosterPath(
            from: posters,
            preferredLanguage: "en",
            originalLanguage: "ja"
        )
        #expect(selectedEn == "/poster_en.jpg")
    }

    @Test func posterSelectionTier2FallsBackToOriginalStudioLanguage() {
        // Japanese anime with authentic ja poster and Russian poster, viewed by Spanish user (no es poster)
        let posters: [[String: Any]] = [
            ["file_path": "/poster_ru.jpg", "iso_639_1": "ru", "vote_average": 9.0, "vote_count": 500, "width": 2000, "height": 3000],
            ["file_path": "/poster_ja.jpg", "iso_639_1": "ja", "vote_average": 7.0, "vote_count": 10, "width": 2000, "height": 3000]
        ]

        let selected = TMDBEnricher.selectBestPosterPath(
            from: posters,
            preferredLanguage: "es",
            originalLanguage: "ja"
        )
        #expect(selected == "/poster_ja.jpg")
    }

    @Test func posterSelectionTier3FallsBackToNeutralTextless() {
        // No user language, no original language poster -> falls back to clean textless artwork
        let posters: [[String: Any]] = [
            ["file_path": "/poster_pl.jpg", "iso_639_1": "pl", "vote_average": 6.0, "vote_count": 5, "width": 2000, "height": 3000],
            ["file_path": "/poster_neutral.jpg", "vote_average": 5.0, "vote_count": 5, "width": 2000, "height": 3000]
        ]

        let selected = TMDBEnricher.selectBestPosterPath(
            from: posters,
            preferredLanguage: "de",
            originalLanguage: "fr"
        )
        #expect(selected == "/poster_neutral.jpg")
    }

    @Test func posterSelectionTier4FallsBackToEnglish() {
        // German user watching French movie, has Polish poster and English poster -> English wins over random languages
        let posters: [[String: Any]] = [
            ["file_path": "/poster_pl.jpg", "iso_639_1": "pl", "vote_average": 6.0, "vote_count": 5, "width": 2000, "height": 3000],
            ["file_path": "/poster_en.jpg", "iso_639_1": "en", "vote_average": 5.0, "vote_count": 5, "width": 2000, "height": 3000]
        ]

        let selected = TMDBEnricher.selectBestPosterPath(
            from: posters,
            preferredLanguage: "de",
            originalLanguage: "fr"
        )
        #expect(selected == "/poster_en.jpg")
    }

    // MARK: - Backdrop / Banner Language Selection Tests

    @Test func backdropSelectionPrefersActiveAppLanguage() {
        let backdrops: [[String: Any]] = [
            ["file_path": "/backdrop_neutral.jpg", "vote_average": 8.0, "vote_count": 100, "width": 3840, "height": 2160],
            ["file_path": "/backdrop_ja.jpg", "iso_639_1": "ja", "vote_average": 7.0, "vote_count": 10, "width": 3840, "height": 2160]
        ]

        let selectedJa = TMDBEnricher.selectBestBackdropPath(
            from: backdrops,
            preferredLanguage: "ja",
            originalLanguage: "en"
        )
        #expect(selectedJa == "/backdrop_ja.jpg")
    }

    @Test func backdropSelectionPrefersTextlessWhenNoAppLanguageMatch() {
        // When no active app language backdrop exists, clean textless neutral backdrop is prioritized
        // over foreign languages with text (ideal for overlaying Flux's title logo)
        let backdrops: [[String: Any]] = [
            ["file_path": "/backdrop_de.jpg", "iso_639_1": "de", "vote_average": 7.5, "vote_count": 20, "width": 3840, "height": 2160],
            ["file_path": "/backdrop_neutral.jpg", "vote_average": 7.0, "vote_count": 50, "width": 3840, "height": 2160]
        ]

        let selected = TMDBEnricher.selectBestBackdropPath(
            from: backdrops,
            preferredLanguage: "es",
            originalLanguage: "ja"
        )
        #expect(selected == "/backdrop_neutral.jpg")
    }
}
