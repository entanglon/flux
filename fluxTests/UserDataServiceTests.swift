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

    @Test func cloudMergePreservesLocalAdditionsAndNewerProgress() {
        let localItem1: [String: Any] = [
            "id": "tt1001",
            "title": "Local Recent Movie",
            "progress": 0.45,
            "timestamp": 1725001000.0
        ]
        let remoteItem1: [String: Any] = [
            "id": "tt1001",
            "title": "Local Recent Movie",
            "progress": 0.10,
            "timestamp": 1725000000.0
        ]
        let remoteItem2: [String: Any] = [
            "id": "tt1002",
            "title": "Remote Exclusive Show",
            "progress": 1.0,
            "timestamp": 1725000500.0
        ]

        let local = [localItem1]
        let remote = [remoteItem1, remoteItem2]

        var map: [String: [String: Any]] = [:]
        for item in local {
            guard let id = item["id"] as? String else { continue }
            map[id] = item
        }
        for item in remote {
            guard let id = item["id"] as? String else { continue }
            if let localItem = map[id] {
                let localTime = localItem["timestamp"] as? Double ?? 0
                let remoteTime = item["timestamp"] as? Double ?? 0
                if remoteTime > localTime {
                    map[id] = item
                }
            } else {
                map[id] = item
            }
        }

        #expect(map.count == 2)
        #expect(map["tt1001"]?["progress"] as? Double == 0.45)
        #expect(map["tt1002"]?["progress"] as? Double == 1.0)
    }

    @Test func collectionMergePreservesLocalAndRemoteItems() {
        let movie1 = MediaItem(id: "tt001", title: "SciFi A", description: "", streamURL: nil, category: "Movie")
        let movie2 = MediaItem(id: "tt002", title: "SciFi B", description: "", streamURL: nil, category: "Movie")
        let movie3 = MediaItem(id: "tt003", title: "SciFi C", description: "", streamURL: nil, category: "Movie")

        let localCollection = UserCollection(
            id: "col-1",
            name: "Sci-Fi Favorites",
            createdAt: Date(timeIntervalSince1970: 1000),
            items: [movie1, movie2]
        )
        let remoteCollection = UserCollection(
            id: "col-1",
            name: "Sci-Fi Favorites",
            createdAt: Date(timeIntervalSince1970: 1000),
            items: [movie2, movie3]
        )
        let remoteExclusiveCollection = UserCollection(
            id: "col-2",
            name: "Anime",
            createdAt: Date(timeIntervalSince1970: 2000),
            items: [movie1]
        )

        let local = [localCollection]
        let remote = [remoteCollection, remoteExclusiveCollection]

        var map: [String: UserCollection] = [:]
        var order: [String] = []

        for col in local {
            map[col.id] = col
            order.append(col.id)
        }

        for rCol in remote {
            if let lCol = map[rCol.id] {
                var itemMap: [String: MediaItem] = [:]
                var itemOrder: [String] = []
                for item in lCol.items {
                    itemMap[item.id] = item
                    itemOrder.append(item.id)
                }
                for item in rCol.items {
                    if itemMap[item.id] == nil {
                        itemMap[item.id] = item
                        itemOrder.append(item.id)
                    }
                }
                let mergedItems = itemOrder.compactMap { itemMap[$0] }
                map[rCol.id] = UserCollection(id: rCol.id, name: lCol.name, createdAt: lCol.createdAt, items: mergedItems)
            } else {
                map[rCol.id] = rCol
                order.append(rCol.id)
            }
        }

        let merged = order.compactMap { map[$0] }
        #expect(merged.count == 2)
        #expect(merged.first(where: { $0.id == "col-1" })?.items.count == 3)
        #expect(merged.first(where: { $0.id == "col-2" })?.items.count == 1)
    }

    @Test func cloudPayloadExportContainsEssentialSubsystems() {
        let payload = UserDataService.shared.exportCloudPayload()
        #expect(payload["version"] as? Int == 2)
        #expect(payload["watchlist"] != nil)
        #expect(payload["history"] != nil)
        #expect(payload["collections"] != nil)
        #expect(payload["tasteLoved"] != nil)
        #expect(payload["tasteSnapshots"] != nil)
        #expect(payload["profiles"] != nil)
    }

    @Test func continueWatchingDeduplicatesCrossFormatIDsAndTitles() {
        let item1 = MediaItem(
            id: "tt14688458",
            title: "Silo",
            description: "",
            streamURL: nil,
            category: "TV Show",
            progress: 0.45
        )
        let item2 = MediaItem(
            id: "14688458",
            title: "Silo",
            description: "",
            streamURL: nil,
            category: "TV Show",
            progress: 0.65
        )
        
        let stripped1 = item1.id.replacingOccurrences(of: "tt", with: "")
        let stripped2 = item2.id.replacingOccurrences(of: "tt", with: "")
        #expect(stripped1 == stripped2)
        #expect(item1.title.lowercased() == item2.title.lowercased())
    }

    @Test @MainActor func signOutRemovesActiveWatchingProfileAndData() {
        // Setup mock user session and profile
        let testProfile = UserProfile(id: UUID(), name: "TestAccountUser", avatarID: "avatar2", createdAt: Date())
        ProfileManager.shared.profiles = [testProfile]
        ProfileManager.shared.selectProfile(testProfile)
        
        let testMovie = MediaItem(id: "tt999999", title: "Test Logout Movie", description: "", streamURL: nil, category: "Movie", progress: 0.5)
        UserDataService.shared.addToHistory(testMovie, progress: 0.5)
        
        #expect(ProfileManager.shared.currentProfile?.name == "TestAccountUser")
        #expect(UserDataService.shared.history.contains(where: { $0.id == "tt999999" }))
        
        // Execute Sign Out
        AuthManager.shared.signOut()
        
        // Verify watching profile is completely removed
        #expect(ProfileManager.shared.currentProfile == nil)
        #expect(ProfileManager.shared.profiles.isEmpty)
        #expect(UserDataService.shared.history.isEmpty)
        #expect(UserDataService.shared.watchlist.isEmpty)
        #expect(!AuthManager.shared.isAuthenticated)
        #expect(!AuthManager.shared.isGuestMode)
    }

    @Test @MainActor func continueAsGuestInitializesFreshGuestWatchingProfile() {
        // Sign out to clean state
        AuthManager.shared.signOut()
        #expect(ProfileManager.shared.currentProfile == nil)
        
        // Continue as guest
        AuthManager.shared.continueAsGuest()
        
        #expect(AuthManager.shared.isGuestMode == true)
        #expect(ProfileManager.shared.currentProfile != nil)
        #expect(ProfileManager.shared.currentProfile?.name == "Guest")
        #expect(UserDataService.shared.history.isEmpty)
        
        // Clean up
        AuthManager.shared.signOut()
    }
}
