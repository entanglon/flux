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
        #expect(payload["version"] as? Int == 3)
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

    @Test @MainActor func ensureDefaultProfileSetsWatchingProfileNameToChosenName() {
        AuthManager.shared.signOut()
        #expect(ProfileManager.shared.profiles.isEmpty)

        ProfileManager.shared.ensureDefaultProfile(name: "Zainul")
        #expect(ProfileManager.shared.currentProfile != nil)
        #expect(ProfileManager.shared.currentProfile?.name == "Zainul")
        #expect(ProfileManager.shared.profiles.count == 2)
        #expect(ProfileManager.shared.profiles.contains(where: { $0.isKids }))

        // Ensure renaming existing single profile updates name cleanly
        ProfileManager.shared.ensureDefaultProfile(name: "Alex")
        #expect(ProfileManager.shared.currentProfile?.name == "Alex")
        #expect(ProfileManager.shared.profiles.count == 2)

        // Clean up
        AuthManager.shared.signOut()
    }

    @Test @MainActor func cloudPayloadExportsAndRestoresTMDBKeyAndDisplayName() {
        let testKey = "test_tmdb_key_\(UUID().uuidString)"
        let testName = "TestUser_\(UUID().uuidString.prefix(6))"

        UserDefaults.standard.set(testKey, forKey: UserDefaults.Key.tmdbApiKey)
        UserDefaults.standard.set(testName, forKey: "flux.authDisplayName")

        let payload = UserDataService.shared.exportCloudPayload()
        #expect(payload["tmdbApiKey"] as? String == testKey)
        #expect(payload["userDisplayName"] as? String == testName)

        // Clear local state
        UserDefaults.standard.removeObject(forKey: UserDefaults.Key.tmdbApiKey)
        UserDefaults.standard.removeObject(forKey: "flux.authDisplayName")
        #expect(UserDefaults.standard.string(forKey: UserDefaults.Key.tmdbApiKey) == nil)

        // Apply cloud payload
        UserDataService.shared.applyCloudPayload(payload)

        #expect(UserDefaults.standard.string(forKey: UserDefaults.Key.tmdbApiKey) == testKey)
        #expect(UserDefaults.standard.string(forKey: "flux.authDisplayName") == testName)

        // Clean up
        UserDefaults.standard.removeObject(forKey: UserDefaults.Key.tmdbApiKey)
        UserDefaults.standard.removeObject(forKey: "flux.authDisplayName")
    }

    @Test @MainActor func profileManagerManagesPlaybackSettingsSeparatelyFromTMDBKey() {
        UserDefaults.standard.set(true, forKey: "autoPlayNextEnabled")
        let settings = ProfileManager.shared.exportGlobalSettings()
        #expect(settings["autoPlayNextEnabled"] as? Bool == true)
        #expect(settings[UserDefaults.Key.tmdbApiKey] == nil)
    }

    @Test @MainActor func freshSignUpGuaranteesEmptyLibraryAndStockAddonsOnly() {
        AuthManager.shared.signOut()
        #expect(UserDataService.shared.history.isEmpty)
        #expect(UserDataService.shared.watchlist.isEmpty)
        #expect(UserDataService.shared.collections.isEmpty)
        #expect(AddonManager.shared.addons.count == 2)
        #expect(AddonManager.shared.addons.contains(where: { $0.id == "opensubtitles3" && $0.isStock }))
        #expect(AddonManager.shared.addons.contains(where: { $0.id == "cinemeta" && $0.isStock }))
        #expect(AddonManager.shared.addons.allSatisfy { $0.isStock })
    }

    @Test @MainActor func sanitizeProfileNamesConvertsDefaultToGuestOrUserName() {
        // Test in guest mode
        UserDefaults.standard.set(true, forKey: "flux.authGuestMode")
        let legacyProfile = UserProfile(id: UUID(), name: "Default", avatarID: "face-blue", createdAt: Date())
        ProfileManager.shared.profiles = [legacyProfile]
        ProfileManager.shared.currentProfile = legacyProfile

        ProfileManager.shared.sanitizeProfileNames()

        #expect(ProfileManager.shared.currentProfile?.name == "Guest")
        #expect(ProfileManager.shared.profiles.first?.name == "Guest")

        // Clean up
        ProfileManager.shared.handleSignOut()
        UserDefaults.standard.removeObject(forKey: "flux.authGuestMode")
    }

    @Test @MainActor func startSignInFlowClearsGuestModeAndEnablesAuthGate() {
        AuthManager.shared.continueAsGuest()
        #expect(AuthManager.shared.isGuestMode == true)
        #expect(AuthManager.shared.needsGate == false)

        AuthManager.shared.startSignInFlow()
        #expect(AuthManager.shared.isGuestMode == false)
        #expect(AuthManager.shared.needsGate == true)

        // Clean up
        UserDefaults.standard.removeObject(forKey: "flux.authGuestMode")
    }

    @Test @MainActor func needsDisplayNamePromptRejectsDefaultAndGuest() {
        // Authenticate with a fallback name "Default"
        AuthManager.shared.currentUser = User(id: "test-user-123", email: "test@example.com", displayName: "Default")
        AuthManager.shared.isAuthenticated = true

        #expect(AuthManager.shared.needsDisplayNamePrompt == true)

        // Authenticate with "Guest"
        AuthManager.shared.currentUser = User(id: "test-user-123", email: "test@example.com", displayName: "Guest")
        #expect(AuthManager.shared.needsDisplayNamePrompt == true)

        // Update with custom name
        AuthManager.shared.updateDisplayName("Alex Smith")
        #expect(AuthManager.shared.currentUser?.displayName == "Alex Smith")
        #expect(AuthManager.shared.needsDisplayNamePrompt == false)

        // Clean up
        AuthManager.shared.signOut()
    }

    @Test @MainActor func stockKidsProfileCannotBeDeletedOrRenamed() {
        ProfileManager.shared.handleSignOut()
        ProfileManager.shared.ensureGuestProfile()
        
        let kids = ProfileManager.shared.profiles.first(where: { $0.isKids })
        #expect(kids != nil)
        #expect(kids?.name == "Kids")
        #expect(kids?.isStock == true)
        
        // Attempt renaming
        if let kidsProfile = kids {
            ProfileManager.shared.updateProfile(kidsProfile, name: "HackedName", avatarID: kidsProfile.avatarID)
            let updated = ProfileManager.shared.profiles.first(where: { $0.id == kidsProfile.id })
            #expect(updated?.name == "Kids")
            
            // Attempt deletion
            ProfileManager.shared.deleteProfile(kidsProfile)
            let remaining = ProfileManager.shared.profiles.first(where: { $0.id == kidsProfile.id })
            #expect(remaining != nil)
        }
        
        ProfileManager.shared.handleSignOut()
    }

    @Test @MainActor func parentalPinVerificationAndKeychainStorage() {
        ParentalLockManager.shared.removePin()
        #expect(ParentalLockManager.shared.hasPin == false)
        
        // Invalid PIN formats
        #expect(ParentalLockManager.shared.setPin("12") == false)
        #expect(ParentalLockManager.shared.setPin("abcd") == false)
        #expect(ParentalLockManager.shared.setPin("12345") == false)
        #expect(ParentalLockManager.shared.hasPin == false)
        
        // Valid PIN format
        #expect(ParentalLockManager.shared.setPin("1234") == true)
        #expect(ParentalLockManager.shared.hasPin == true)
        
        // Verification
        #expect(ParentalLockManager.shared.verify(pin: "9999") == false)
        #expect(ParentalLockManager.shared.verify(pin: "1234") == true)
        
        // Clean up
        ParentalLockManager.shared.removePin()
        #expect(ParentalLockManager.shared.hasPin == false)
    }

    @Test @MainActor func switchingFromKidsProfileRequiresPIN() {
        ProfileManager.shared.handleSignOut()
        ProfileManager.shared.ensureGuestProfile()
        ParentalLockManager.shared.removePin()
        
        guard let kids = ProfileManager.shared.profiles.first(where: { $0.isKids }) else {
            Issue.record("Kids profile was not found")
            return
        }
        
        ProfileManager.shared.selectProfile(kids)
        #expect(ProfileManager.shared.currentProfile?.isKids == true)
        // No PIN set yet -> requiresPinToExit is false
        #expect(ProfileManager.shared.requiresPinToExit == false)
        
        // Set PIN
        ParentalLockManager.shared.setPin("4321")
        #expect(ProfileManager.shared.requiresPinToExit == true)
        
        // Clean up
        ParentalLockManager.shared.removePin()
        ProfileManager.shared.handleSignOut()
    }

    @Test @MainActor func perProfilePinVerificationAndIsolation() {
        let profileA = UUID()
        let profileB = UUID()

        ParentalLockManager.shared.removePin(for: profileA)
        ParentalLockManager.shared.removePin(for: profileB)
        ParentalLockManager.shared.removePin()

        #expect(ParentalLockManager.shared.hasPin(for: profileA) == false)
        #expect(ParentalLockManager.shared.hasPin(for: profileB) == false)

        // Set PIN for Profile A only
        #expect(ParentalLockManager.shared.setPin("1111", for: profileA) == true)
        #expect(ParentalLockManager.shared.hasPin(for: profileA) == true)
        #expect(ParentalLockManager.shared.hasPin(for: profileB) == false)

        // Verify Profile A accepts its PIN
        #expect(ParentalLockManager.shared.verify(pin: "1111", for: profileA) == true)
        #expect(ParentalLockManager.shared.verify(pin: "2222", for: profileA) == false)

        // Set PIN for Profile B
        #expect(ParentalLockManager.shared.setPin("2222", for: profileB) == true)
        #expect(ParentalLockManager.shared.verify(pin: "2222", for: profileB) == true)
        #expect(ParentalLockManager.shared.verify(pin: "1111", for: profileB) == false)

        // Clean up
        ParentalLockManager.shared.removePin(for: profileA)
        ParentalLockManager.shared.removePin(for: profileB)
        ParentalLockManager.shared.removePin()
    }

    @Test @MainActor func avatarItemCatalogIncludesCatsPetsAndClassics() {
        #expect(AvatarItem.characters.count == 8)
        #expect(AvatarItem.pets.count == 12)
        #expect(AvatarItem.classics.count == 12)
        #expect(AvatarItem.all.count == 32)

        let cat1 = AvatarItem.characters.first(where: { $0.id == "avatar-cat-1" })
        #expect(cat1 != nil)
        #expect(cat1?.isImage == true)
        #expect(cat1?.category == .characters)

        let pet1 = AvatarItem.pets.first(where: { $0.id == "avatar-pet-1" })
        #expect(pet1 != nil)
        #expect(pet1?.isImage == true)
        #expect(pet1?.category == .pets)

        let classicRed = AvatarItem.classics.first(where: { $0.id == "face-red" })
        #expect(classicRed != nil)
        #expect(classicRed?.isImage == false)
        #expect(classicRed?.category == .classic)
    }

    @Test @MainActor func kidsProfileDataIsolationOnCloudApply() {
        // Setup mock adult and kids profiles
        let adultID = UUID()
        let kidsID = UUID()
        let adultProfile = UserProfile(id: adultID, name: "Zayn", avatarID: "face-red", createdAt: Date(), isKids: false)
        let kidsProfile = UserProfile(id: kidsID, name: "Kids", avatarID: "face-lime", createdAt: Date(), isKids: true, isStock: true)

        ProfileManager.shared.profiles = [adultProfile, kidsProfile]
        ProfileManager.shared.selectProfile(kidsProfile)

        // Clear any pre-existing keys
        let kidsWatchKey = "profile.\(kidsID.uuidString).watchlist"
        let kidsHistKey = "profile.\(kidsID.uuidString).history"
        let adultWatchKey = "profile.\(adultID.uuidString).watchlist"
        let adultHistKey = "profile.\(adultID.uuidString).history"

        UserDefaults.standard.removeObject(forKey: kidsWatchKey)
        UserDefaults.standard.removeObject(forKey: kidsHistKey)
        UserDefaults.standard.removeObject(forKey: adultWatchKey)
        UserDefaults.standard.removeObject(forKey: adultHistKey)

        // Simulate cloud payload where root contains adult watchlist/history
        let adultItem: [String: Any] = [
            "id": "tt0111161",
            "type": "movie",
            "title": "The Shawshank Redemption",
            "timestamp": 1700000000.0,
            "certification": "R"
        ]

        let payload: [String: Any] = [
            "version": 3,
            "watchlist": [adultItem],
            "history": [adultItem],
            "profiles": [
                [
                    "id": adultID.uuidString,
                    "name": "Zayn",
                    "avatarID": "face-red",
                    "createdAt": Date().timeIntervalSince1970,
                    "isKids": false,
                    "isStock": false,
                    "watchlist": [adultItem],
                    "history": [adultItem]
                ],
                [
                    "id": kidsID.uuidString,
                    "name": "Kids",
                    "avatarID": "face-lime",
                    "createdAt": Date().timeIntervalSince1970,
                    "isKids": true,
                    "isStock": true,
                    "watchlist": [],
                    "history": []
                ]
            ]
        ]

        UserDataService.shared.applyCloudPayload(payload)

        // Verify kids profile remains isolated and has zero adult items
        let kidsWatch = UserDefaults.standard.array(forKey: kidsWatchKey) as? [[String: Any]] ?? []
        let kidsHist = UserDefaults.standard.array(forKey: kidsHistKey) as? [[String: Any]] ?? []

        #expect(kidsWatch.isEmpty, "Kids watchlist should be empty, but found \(kidsWatch.count) items")
        #expect(kidsHist.isEmpty, "Kids history should be empty, but found \(kidsHist.count) items")
        #expect(UserDataService.shared.watchlist.isEmpty)
        #expect(UserDataService.shared.history.isEmpty)

        // Verify adult profile correctly received the items
        let adultWatch = UserDefaults.standard.array(forKey: adultWatchKey) as? [[String: Any]] ?? []
        let adultHist = UserDefaults.standard.array(forKey: adultHistKey) as? [[String: Any]] ?? []
        #expect(adultWatch.count == 1)
        #expect(adultHist.count == 1)

        // Clean up
        UserDefaults.standard.removeObject(forKey: kidsWatchKey)
        UserDefaults.standard.removeObject(forKey: kidsHistKey)
        UserDefaults.standard.removeObject(forKey: adultWatchKey)
        UserDefaults.standard.removeObject(forKey: adultHistKey)
    }

    @Test @MainActor func cloudPayloadExportVersion3HasPerProfileData() {
        ProfileManager.shared.ensureDefaultProfile(name: "TestUser")
        let payload = UserDataService.shared.exportCloudPayload()
        #expect(payload["version"] as? Int == 3)
        #expect(payload["profiles"] != nil)
        let profiles = payload["profiles"] as? [[String: Any]]
        #expect(profiles != nil)
        #expect(profiles?.isEmpty == false)
    }

    @Test @MainActor func continueWatchingAndRecentlyWatchedSeparation() {
        let profileID = UUID()
        let profile = UserProfile(id: profileID, name: "Test Separation", avatarID: "avatar_1", createdAt: Date())
        ProfileManager.shared.profiles = [profile]
        ProfileManager.shared.selectProfile(profile)
        
        let histKey = UserDefaults.Key.profileHistory(id: profileID.uuidString)
        UserDefaults.standard.removeObject(forKey: histKey)
        UserDataService.shared.history = []
        
        let inProgressItem = MediaItem(
            id: "tt_test_prog",
            title: "In Progress Show",
            description: "",
            streamURL: nil,
            category: "series",
            progress: 0.45
        )
        
        let completedItem = MediaItem(
            id: "tt_test_done",
            title: "Finished Movie",
            description: "",
            streamURL: nil,
            category: "movie",
            progress: 0.95
        )
        
        UserDataService.shared.addToHistory(inProgressItem)
        UserDataService.shared.addToHistory(completedItem)
        
        let cw = UserDataService.shared.continueWatching
        let rw = UserDataService.shared.recentlyWatched
        
        #expect(cw.contains(where: { $0.id == "tt_test_prog" }))
        #expect(!cw.contains(where: { $0.id == "tt_test_done" }))
        
        #expect(rw.contains(where: { $0.id == "tt_test_done" }))
        #expect(!rw.contains(where: { $0.id == "tt_test_prog" }))
        
        // Clean up
        UserDefaults.standard.removeObject(forKey: histKey)
    }

    @Test @MainActor func monotonicProgressPreventsBackwardRegression() {
        let profileID = UUID()
        let profile = UserProfile(id: profileID, name: "Test Monotonic", avatarID: "avatar_1", createdAt: Date())
        ProfileManager.shared.profiles = [profile]
        ProfileManager.shared.selectProfile(profile)
        
        let histKey = UserDefaults.Key.profileHistory(id: profileID.uuidString)
        UserDefaults.standard.removeObject(forKey: histKey)
        UserDataService.shared.history = []
        
        let itemFirst = MediaItem(
            id: "tt_test_seek",
            title: "Seek Test Movie",
            description: "",
            streamURL: nil,
            category: "movie",
            progress: 0.60
        )
        UserDataService.shared.addToHistory(itemFirst)
        
        let saved1 = UserDataService.shared.getHistoryItem(for: itemFirst)
        #expect(saved1?.progress == 0.60)
        
        // User reopens and scrubs back to 0.20
        let itemScrubbedBack = MediaItem(
            id: "tt_test_seek",
            title: "Seek Test Movie",
            description: "",
            streamURL: nil,
            category: "movie",
            progress: 0.20
        )
        UserDataService.shared.addToHistory(itemScrubbedBack, isRestart: false)
        
        let saved2 = UserDataService.shared.getHistoryItem(for: itemFirst)
        #expect(saved2?.progress == 0.60, "Progress should preserve high-water mark at 0.60, got \(String(describing: saved2?.progress))")
        
        // Explicit restart resets progress
        UserDataService.shared.addToHistory(itemScrubbedBack, isRestart: true)
        let saved3 = UserDataService.shared.getHistoryItem(for: itemFirst)
        #expect(saved3?.progress == 0.20, "Explicit restart should allow resetting progress to 0.20")
        
        // Clean up
        UserDefaults.standard.removeObject(forKey: histKey)
    }

    @Test @MainActor func cloudPayloadExportsAndRestoresAppLanguage() {
        let originalLanguage = LanguageManager.shared.currentLanguage
        defer {
            LanguageManager.shared.setLanguage(originalLanguage)
        }

        // 1. Set language to Japanese and verify export
        LanguageManager.shared.setLanguage(.japanese)
        #expect(UserDefaults.standard.string(forKey: UserDefaults.Key.appLanguage) == "ja")

        let payload = UserDataService.shared.exportCloudPayload()
        #expect(payload["appLanguage"] as? String == "ja")

        // 2. Change language locally to English
        LanguageManager.shared.setLanguage(.english)
        #expect(LanguageManager.shared.currentLanguage == .english)

        // 3. Apply cloud payload containing Spanish
        var spanishPayload = payload
        spanishPayload["appLanguage"] = "es"
        UserDataService.shared.applyCloudPayload(spanishPayload)

        #expect(UserDefaults.standard.string(forKey: UserDefaults.Key.appLanguage) == "es")
        #expect(LanguageManager.shared.currentLanguage == .spanish)
    }
}

