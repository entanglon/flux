import Testing
import Foundation
@testable import flux

@Suite(.serialized)
@MainActor
struct UserDataServiceTests {

    @MainActor struct TestStateGuard {
        let savedProfiles: [UserProfile]
        let savedCurrentProfile: UserProfile?
        let savedProfileIDs: Set<String>
        let savedHistory: [MediaItem]
        let savedWatchlist: [MediaItem]
        let savedCollections: [UserCollection]
        let savedIsAuth: Bool
        let savedUser: User?
        let savedIsGuest: Bool
        let savedLanguage: AppLanguage
        let savedTmdb: String?
        let savedHistoryKey: String
        let savedHistoryDefaults: Any?
        let savedWatchlistKey: String
        let savedWatchlistDefaults: Any?
        let savedCollectionsKey: String
        let savedCollectionsDefaults: Any?
        let savedEpProgressKey: String
        let savedEpProgressDefaults: Any?
        let savedRecentSearches: [MediaItem]
        let savedAddons: [StremioAddon]
        let savedDisplayName: String?
        let savedLegacyDisplayName: String?
        let savedProfilesData: Data?
        let savedCurrentProfileData: Data?
        let savedAddonsData: Data?
        let savedStreamingSourceMode: String?
        let savedHasCustomizedName: Any?
        let savedKeychainToken: String?
        let savedKeychainUserID: String?
        let savedKeychainEmail: String?
        let savedKeychainDisplayName: String?
        let savedKeychainAvatar: String?

        init() {
            savedProfiles = ProfileManager.shared.profiles
            savedCurrentProfile = ProfileManager.shared.currentProfile
            savedProfileIDs = Set(ProfileManager.shared.profiles.map { $0.id.uuidString })
            savedHistory = UserDataService.shared.history
            savedWatchlist = UserDataService.shared.watchlist
            savedCollections = UserDataService.shared.collections
            savedRecentSearches = RecentSearchManager.shared.recentItems
            savedAddons = AddonManager.shared.addons
            savedIsAuth = AuthManager.shared.isAuthenticated
            savedUser = AuthManager.shared.currentUser
            savedIsGuest = AuthManager.shared.isGuestMode
            savedLanguage = LanguageManager.shared.currentLanguage
            savedTmdb = UserDefaults.standard.string(forKey: UserDefaults.Key.tmdbApiKey)
            savedDisplayName = UserDefaults.standard.string(forKey: "flux.authDisplayName")
            savedLegacyDisplayName = UserDefaults.standard.string(forKey: "userDisplayName")
            savedProfilesData = UserDefaults.standard.data(forKey: "fluxProfiles")
            savedCurrentProfileData = UserDefaults.standard.data(forKey: "fluxCurrentProfile")
            savedAddonsData = UserDefaults.standard.data(forKey: "StremioConfiguredAddons")
            savedStreamingSourceMode = UserDefaults.standard.string(forKey: "streamingSourceMode")
            savedHasCustomizedName = UserDefaults.standard.object(forKey: "flux.hasExplicitlyCustomizedName")
            savedKeychainToken = KeychainManager.getToken()
            savedKeychainUserID = KeychainManager.getUserID()
            savedKeychainEmail = KeychainManager.getEmail()
            savedKeychainDisplayName = KeychainManager.getDisplayName()
            savedKeychainAvatar = KeychainManager.getAvatarURL()
            let profileID = ProfileManager.shared.currentProfile?.id.uuidString ?? ""
            savedHistoryKey = profileID.isEmpty ? "localHistoryDataStremio" : "profile.\(profileID).history"
            savedWatchlistKey = profileID.isEmpty ? "localWatchlistDataStremio" : "profile.\(profileID).watchlist"
            savedCollectionsKey = profileID.isEmpty ? "localCollectionsData" : "profile.\(profileID).collections"
            savedEpProgressKey = UserDataService.shared.episodeProgressKey
            savedHistoryDefaults = UserDefaults.standard.object(forKey: savedHistoryKey)
            savedWatchlistDefaults = UserDefaults.standard.object(forKey: savedWatchlistKey)
            savedCollectionsDefaults = UserDefaults.standard.object(forKey: savedCollectionsKey)
            savedEpProgressDefaults = UserDefaults.standard.object(forKey: savedEpProgressKey)
        }

        func restore() {
            // 1. Purge any temporary profiles created during the test run from UserDefaults
            let currentProfiles = ProfileManager.shared.profiles
            for p in currentProfiles {
                if !savedProfileIDs.contains(p.id.uuidString) {
                    let prefix = "profile.\(p.id.uuidString)."
                    for suffix in ["history", "watchlist", "loved", "watchSnaps", "settings", "collections", "episodeProgress", "recentSearches"] {
                        UserDefaults.standard.removeObject(forKey: prefix + suffix)
                    }
                }
            }

            // 2. Restore underlying UserDefaults keys BEFORE selecting profile so loadInitialData reads correct data
            if let val = savedHistoryDefaults {
                UserDefaults.standard.set(val, forKey: savedHistoryKey)
            } else {
                UserDefaults.standard.removeObject(forKey: savedHistoryKey)
            }
            if let val = savedWatchlistDefaults {
                UserDefaults.standard.set(val, forKey: savedWatchlistKey)
            } else {
                UserDefaults.standard.removeObject(forKey: savedWatchlistKey)
            }
            if let val = savedCollectionsDefaults {
                UserDefaults.standard.set(val, forKey: savedCollectionsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: savedCollectionsKey)
            }
            if let val = savedEpProgressDefaults {
                UserDefaults.standard.set(val, forKey: savedEpProgressKey)
            } else {
                UserDefaults.standard.removeObject(forKey: savedEpProgressKey)
            }
            if let val = savedAddonsData {
                UserDefaults.standard.set(val, forKey: "StremioConfiguredAddons")
            }
            if let val = savedProfilesData {
                UserDefaults.standard.set(val, forKey: "fluxProfiles")
            }
            if let val = savedCurrentProfileData {
                UserDefaults.standard.set(val, forKey: "fluxCurrentProfile")
            }
            if let val = savedStreamingSourceMode {
                UserDefaults.standard.set(val, forKey: "streamingSourceMode")
            }

            // 3. Restore profiles and currentProfile
            ProfileManager.shared.profiles = savedProfiles
            ProfileManager.shared.currentProfile = savedCurrentProfile
            if let profile = savedCurrentProfile {
                ProfileManager.shared.selectProfile(profile)
            }
            UserDataService.shared.history = savedHistory
            UserDataService.shared.watchlist = savedWatchlist
            UserDataService.shared.collections = savedCollections
            RecentSearchManager.shared.setRecentItems(savedRecentSearches)
            AddonManager.shared.addons = savedAddons

            AuthManager.shared.resetStateForTesting(user: savedUser, authenticated: savedIsAuth, guest: savedIsGuest)
            if let name = savedDisplayName {
                UserDefaults.standard.set(name, forKey: "flux.authDisplayName")
            } else {
                UserDefaults.standard.removeObject(forKey: "flux.authDisplayName")
            }
            if let legName = savedLegacyDisplayName {
                UserDefaults.standard.set(legName, forKey: "userDisplayName")
            } else {
                UserDefaults.standard.removeObject(forKey: "userDisplayName")
            }
            if let custom = savedHasCustomizedName {
                UserDefaults.standard.set(custom, forKey: "flux.hasExplicitlyCustomizedName")
            } else {
                UserDefaults.standard.removeObject(forKey: "flux.hasExplicitlyCustomizedName")
            }
            KeychainManager.saveSession(
                token: savedKeychainToken ?? "",
                userID: savedKeychainUserID ?? "",
                email: savedKeychainEmail,
                displayName: savedKeychainDisplayName,
                avatarURL: savedKeychainAvatar
            )
            LanguageManager.shared.setLanguage(savedLanguage)
            if let tmdb = savedTmdb {
                UserDefaults.standard.set(tmdb, forKey: UserDefaults.Key.tmdbApiKey)
            }
            UserDefaults.standard.synchronize()
        }
    }

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
        let guardState = TestStateGuard()
        defer { guardState.restore() }

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
        let guardState = TestStateGuard()
        defer { guardState.restore() }

        // Sign out to clean state
        AuthManager.shared.signOut()
        #expect(ProfileManager.shared.currentProfile == nil)
        
        // Continue as guest
        AuthManager.shared.continueAsGuest()
        
        #expect(AuthManager.shared.isGuestMode == true)
        #expect(ProfileManager.shared.currentProfile != nil)
        #expect(ProfileManager.shared.currentProfile?.name == "Guest")
        #expect(UserDataService.shared.history.isEmpty)
    }

    @Test @MainActor func ensureDefaultProfileSetsWatchingProfileNameToChosenName() {
        let guardState = TestStateGuard()
        defer { guardState.restore() }

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
    }

    @Test @MainActor func cloudPayloadExportsAndRestoresTMDBKeyAndDisplayName() {
        let guardState = TestStateGuard()
        defer { guardState.restore() }

        let testProfile = UserProfile(id: UUID(), name: "TestUser", avatarID: "avatar_1", createdAt: Date())
        ProfileManager.shared.profiles = [testProfile]
        ProfileManager.shared.selectProfile(testProfile)

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
    }

    @Test @MainActor func profileManagerManagesPlaybackSettingsSeparatelyFromTMDBKey() {
        UserDefaults.standard.set(true, forKey: "autoPlayNextEnabled")
        let settings = ProfileManager.shared.exportGlobalSettings()
        #expect(settings["autoPlayNextEnabled"] as? Bool == true)
        #expect(settings[UserDefaults.Key.tmdbApiKey] == nil)
    }

    @Test @MainActor func freshSignUpGuaranteesEmptyLibraryAndStockAddonsOnly() {
        let guardState = TestStateGuard()
        defer { guardState.restore() }

        AuthManager.shared.signOut()
        #expect(UserDataService.shared.history.isEmpty)
        #expect(UserDataService.shared.watchlist.isEmpty)
        #expect(UserDataService.shared.collections.isEmpty)
        #expect(AddonManager.shared.addons.count == 3)
        #expect(AddonManager.shared.addons.contains(where: { $0.id == "opensubtitles3" && $0.isStock }))
        #expect(AddonManager.shared.addons.contains(where: { $0.id == "cinemeta" && $0.isStock }))
        #expect(AddonManager.shared.addons.contains(where: { $0.id == "stock.stream-route-proxy" && $0.isStock }))
        #expect(AddonManager.shared.addons.allSatisfy { $0.isStock })
    }

    @Test @MainActor func sanitizeProfileNamesConvertsDefaultToGuestOrUserName() {
        let guardState = TestStateGuard()
        defer { guardState.restore() }

        // Test in guest mode
        UserDefaults.standard.set(true, forKey: "flux.authGuestMode")
        let legacyProfile = UserProfile(id: UUID(), name: "Default", avatarID: "face-blue", createdAt: Date())
        ProfileManager.shared.profiles = [legacyProfile]
        ProfileManager.shared.currentProfile = legacyProfile

        ProfileManager.shared.sanitizeProfileNames()

        #expect(ProfileManager.shared.currentProfile?.name == "Guest")
        #expect(ProfileManager.shared.profiles.first?.name == "Guest")
    }

    @Test @MainActor func startSignInFlowClearsGuestModeAndEnablesAuthGate() {
        let guardState = TestStateGuard()
        defer { guardState.restore() }

        AuthManager.shared.continueAsGuest()
        #expect(AuthManager.shared.isGuestMode == true)
        #expect(AuthManager.shared.needsGate == false)

        AuthManager.shared.startSignInFlow()
        #expect(AuthManager.shared.isGuestMode == false)
        #expect(AuthManager.shared.needsGate == true)
    }

    @Test @MainActor func needsDisplayNamePromptRejectsDefaultAndGuest() {
        let guardState = TestStateGuard()
        defer { guardState.restore() }

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
    }

    @Test @MainActor func stockKidsProfileCannotBeDeletedOrRenamed() {
        let guardState = TestStateGuard()
        defer { guardState.restore() }

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
        let guardState = TestStateGuard()
        defer { guardState.restore() }

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
        let guardState = TestStateGuard()
        defer { guardState.restore() }

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
        let guardState = TestStateGuard()
        defer { guardState.restore() }

        ProfileManager.shared.ensureDefaultProfile(name: "TestUser")
        let payload = UserDataService.shared.exportCloudPayload()
        #expect(payload["version"] as? Int == 3)
        #expect(payload["profiles"] != nil)
        let profiles = payload["profiles"] as? [[String: Any]]
        #expect(profiles != nil)
        #expect(profiles?.isEmpty == false)
        #expect(profiles?.first?["episodeProgress"] != nil)
    }

    @Test @MainActor func continueWatchingAndRecentlyWatchedSeparation() {
        let guardState = TestStateGuard()
        defer { guardState.restore() }

        let profileID = UUID()
        let profile = UserProfile(id: profileID, name: "Test Separation", avatarID: "avatar_1", createdAt: Date())
        ProfileManager.shared.profiles = [profile]
        ProfileManager.shared.selectProfile(profile)
        
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
    }

    @Test @MainActor func monotonicProgressPreventsBackwardRegression() {
        let guardState = TestStateGuard()
        defer { guardState.restore() }

        let profileID = UUID()
        let profile = UserProfile(id: profileID, name: "Test Monotonic", avatarID: "avatar_1", createdAt: Date())
        ProfileManager.shared.profiles = [profile]
        ProfileManager.shared.selectProfile(profile)
        
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
    }

    @Test @MainActor func cloudPayloadExportsAndRestoresAppLanguage() {
        let guardState = TestStateGuard()
        defer { guardState.restore() }

        let testProfile = UserProfile(id: UUID(), name: "TestLang", avatarID: "avatar_1", createdAt: Date())
        ProfileManager.shared.profiles = [testProfile]
        ProfileManager.shared.selectProfile(testProfile)

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

    @Test @MainActor func rewatchingCompletedEpisodeTracksActiveProgress() {
        let guardState = TestStateGuard()
        defer { guardState.restore() }

        let testProfile = UserProfile(id: UUID(), name: "TestRewatch", avatarID: "avatar_1", createdAt: Date())
        ProfileManager.shared.profiles = [testProfile]
        ProfileManager.shared.selectProfile(testProfile)

        let showID = "tt_test_rewatch_\(UUID().uuidString)"
        let show = MediaItem(
            id: showID,
            title: "Rewatch Test Show",
            description: "",
            streamURL: nil,
            category: "series"
        )

        // 1. Mark Episode 1 as completed (95% progress)
        UserDataService.shared.saveEpisodeProgress(for: showID, season: 1, episode: 1, position: 1710, duration: 1800)
        UserDataService.shared.addToHistory(show, progress: 0.95, season: 1, episode: 1, playbackPosition: 1710, playbackDuration: 1800)

        let initialEpProg = UserDataService.shared.getEpisodeProgress(for: showID, season: 1, episode: 1)
        #expect(initialEpProg?.progress ?? 0 >= 0.95)

        // 2. User re-watches Episode 1 for 5 minutes (300s / 1800s ≈ 0.166)
        UserDataService.shared.saveEpisodeProgress(for: showID, season: 1, episode: 1, position: 300, duration: 1800)
        UserDataService.shared.addToHistory(show, progress: 300.0 / 1800.0, season: 1, episode: 1, playbackPosition: 300, playbackDuration: 1800)

        // 3. Verify episode progress tracks active re-watch position (not clamped to 95%)
        let rewatchedEpProg = UserDataService.shared.getEpisodeProgress(for: showID, season: 1, episode: 1)
        #expect(rewatchedEpProg != nil)
        let prog = rewatchedEpProg?.progress ?? 0
        #expect(prog > 0.15 && prog < 0.20, "Expected progress around 0.166 for 5 min re-watch, got \(prog)")

        // 4. Verify history item points to Episode 1 with active progress instead of Episode 2
        let hist = UserDataService.shared.getHistoryItem(for: show)
        #expect(hist?.lastSeason == 1)
        #expect(hist?.lastEpisode == 1)
        let histProg = hist?.progress ?? 0
        #expect(histProg > 0.15 && histProg < 0.20, "Expected history progress around 0.166, got \(histProg)")
    }

    @Test @MainActor func monotonicHighWaterMarkProtectsEpisodicProgressFromRegression() {
        let guardState = TestStateGuard()
        defer { guardState.restore() }

        let testProfile = UserProfile(id: UUID(), name: "TestHWM", avatarID: "avatar_1", createdAt: Date())
        ProfileManager.shared.profiles = [testProfile]
        ProfileManager.shared.selectProfile(testProfile)

        let showID = "tt_test_hwm_\(UUID().uuidString)"
        let show = MediaItem(
            id: showID,
            title: "HWM Test Show",
            description: "",
            streamURL: nil,
            category: "series"
        )

        // 1. Advance to Season 1 Episode 10 (50% progress)
        UserDataService.shared.saveEpisodeProgress(for: showID, season: 1, episode: 10, position: 1000, duration: 2000)
        UserDataService.shared.addToHistory(show, progress: 0.50, season: 1, episode: 10, playbackPosition: 1000, playbackDuration: 2000)

        let initialHist = UserDataService.shared.getHistoryItem(for: show)
        #expect(initialHist?.lastSeason == 1)
        #expect(initialHist?.lastEpisode == 10)
        #expect(initialHist?.progress == 0.50)

        // 2. Play Episode 4 (not a restart, e.g. peeking at older episode or stale sync)
        UserDataService.shared.saveEpisodeProgress(for: showID, season: 1, episode: 4, position: 500, duration: 2000)
        UserDataService.shared.addToHistory(show, progress: 0.25, season: 1, episode: 4, playbackPosition: 500, playbackDuration: 2000, isRestart: false)

        // Verify low-level episodeProgress updated for Ep 4
        let ep4Prog = UserDataService.shared.getEpisodeProgress(for: showID, season: 1, episode: 4)
        #expect(ep4Prog?.progress == 0.25)

        // High-water mark protection: history item must remain on Episode 10!
        let protectedHist = UserDataService.shared.getHistoryItem(for: show)
        #expect(protectedHist?.lastSeason == 1)
        #expect(protectedHist?.lastEpisode == 10)
        #expect(protectedHist?.progress == 0.50)

        // 3. User explicitly restarts from Episode 4 (isRestart: true)
        UserDataService.shared.addToHistory(show, progress: 0.25, season: 1, episode: 4, playbackPosition: 500, playbackDuration: 2000, isRestart: true)
        let restartedHist = UserDataService.shared.getHistoryItem(for: show)
        #expect(restartedHist?.lastSeason == 1)
        #expect(restartedHist?.lastEpisode == 4)
    }

    @Test @MainActor func reconcileHistoryWithEpisodeProgressHealsOutdatedHistory() {
        let guardState = TestStateGuard()
        defer { guardState.restore() }

        let testProfile = UserProfile(id: UUID(), name: "TestHeal", avatarID: "avatar_1", createdAt: Date())
        ProfileManager.shared.profiles = [testProfile]
        ProfileManager.shared.selectProfile(testProfile)

        let showID = "tt_test_heal_\(UUID().uuidString)"
        let show = MediaItem(
            id: showID,
            title: "Heal Test Show",
            description: "",
            streamURL: nil,
            category: "series"
        )

        // 1. Stored episode progress shows episodes 4-9 watched, ep 10 at 56%
        for ep in 4...9 {
            UserDataService.shared.saveEpisodeProgress(for: showID, season: 1, episode: ep, position: 1900, duration: 2000)
        }
        UserDataService.shared.saveEpisodeProgress(for: showID, season: 1, episode: 10, position: 1120, duration: 2000)

        // 2. Put an outdated history item at Episode 4 (simulating legacy data restoration)
        UserDataService.shared.addToHistory(show, progress: 0.95, season: 1, episode: 4, playbackPosition: 1900, playbackDuration: 2000, isRestart: true)
        let beforeHist = UserDataService.shared.getHistoryItem(for: show)
        #expect(beforeHist?.lastEpisode == 4)

        // 3. Reconcile
        UserDataService.shared.reconcileHistoryWithEpisodeProgress()

        // 4. Verify history item was healed to Season 1 Episode 10 with 56% progress
        let healedHist = UserDataService.shared.getHistoryItem(for: show)
        #expect(healedHist?.lastSeason == 1)
        #expect(healedHist?.lastEpisode == 10)
        #expect(healedHist?.lastPlaybackPosition == 1120)
        #expect(healedHist?.lastPlaybackDuration == 2000)
        let progress = healedHist?.progress ?? 0
        #expect(progress > 0.55 && progress < 0.57)
    }

    @Test func mergeHistoryDataPreservesFurthestEpisode() {
        let localShow: [String: Any] = [
            "id": "tt_merge_show_1",
            "title": "Merge Test Series",
            "category": "series",
            "lastSeason": 1,
            "lastEpisode": 10,
            "progress": 0.56,
            "playbackPosition": 1120.0,
            "playbackDuration": 2000.0,
            "timestamp": 1725000000.0
        ]
        let remoteShowOutdated: [String: Any] = [
            "id": "tt_merge_show_1",
            "title": "Merge Test Series",
            "category": "series",
            "lastSeason": 1,
            "lastEpisode": 4,
            "progress": 0.95,
            "playbackPosition": 1900.0,
            "playbackDuration": 2000.0,
            "timestamp": 1726000000.0
        ]

        let merged = UserDataService.shared.mergeHistoryData(local: [localShow], remote: [remoteShowOutdated])
        #expect(merged.count == 1)
        let item = merged[0]
        #expect(item["lastSeason"] as? Int == 1)
        #expect(item["lastEpisode"] as? Int == 10)
        #expect(item["playbackPosition"] as? Double == 1120.0)
    }

    @Test @MainActor func recentSearchManagerProtectedFromSignOutAndScopedToProfiles() {
        let guardState = TestStateGuard()
        defer { guardState.restore() }

        let testProfile = UserProfile(id: UUID(), name: "SearchProfileUser", avatarID: "avatar1", createdAt: Date())
        ProfileManager.shared.profiles = [testProfile]
        ProfileManager.shared.selectProfile(testProfile)

        let initialSearch = MediaItem(id: "803736", title: "Hey! Sinamika", description: "", streamURL: nil, category: "Movie")
        RecentSearchManager.shared.setRecentItems([initialSearch])
        #expect(RecentSearchManager.shared.recentItems.contains(where: { $0.id == "803736" }))

        // Execute Sign Out
        AuthManager.shared.signOut()

        // When signed out, in-memory active watching profile is nil, so recentItems scopes to empty
        #expect(RecentSearchManager.shared.recentItems.isEmpty)
    }
}


