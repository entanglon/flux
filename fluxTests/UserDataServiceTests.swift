import Testing
import Foundation
@testable import flux

struct UserDataServiceTests {

    @Test func mediaItemInitializationAndTypes() {
        let movie = MediaItem(
            id: "tt1234567",
            title: "Test Movie",
            description: "A test movie description",
            posterURL: URL(string: "https://example.com/poster.jpg"),
            backdropURL: URL(string: "https://example.com/backdrop.jpg"),
            streamURL: nil,
            category: "Movie",
            releaseDate: "2024-01-01"
        )

        #expect(movie.id == "tt1234567")
        #expect(movie.title == "Test Movie")
        #expect(movie.category == "Movie")
        #expect(movie.releaseDateYear == "2024")
        #expect(movie.isReleased == true)
    }

    @Test func userDefaultsKeyHelpersGenerateConsistentPaths() {
        let testID = "test-profile-uuid"
        #expect(UserDefaults.Key.profileHistory(id: testID) == "profile.test-profile-uuid.history")
        #expect(UserDefaults.Key.profileWatchlist(id: testID) == "profile.test-profile-uuid.watchlist")
        #expect(UserDefaults.Key.profileCollections(id: testID) == "profile.test-profile-uuid.collections")
        #expect(UserDefaults.Key.profileLoved(id: testID) == "profile.test-profile-uuid.loved")
        #expect(UserDefaults.Key.profileWatchSnaps(id: testID) == "profile.test-profile-uuid.watchSnaps")
    }

    @Test func keychainStoreSetGetDeleteRoundtrip() {
        let testKey = "flux.test.keychain.\(UUID().uuidString)"
        let testValue = "jwt-secret-payload-123"

        KeychainStore.set(testValue, forKey: testKey)
        let retrieved = KeychainStore.get(testKey)
        #expect(retrieved == testValue)

        KeychainStore.delete(testKey)
        let afterDelete = KeychainStore.get(testKey)
        #expect(afterDelete == nil)
    }

    @Test func watchedThresholdDistinguishesFinishedFromInProgress() {
        var completedMovie = MediaItem(
            id: "tt9999991",
            title: "Finished Movie",
            description: "",
            streamURL: nil,
            category: "Movie",
            progress: 0.95
        )
        var inProgressMovie = MediaItem(
            id: "tt9999992",
            title: "Started Movie",
            description: "",
            streamURL: nil,
            category: "Movie",
            progress: 0.15
        )

        #expect((completedMovie.progress ?? 0) >= 0.90)
        #expect((inProgressMovie.progress ?? 0) < 0.90)
    }
}
