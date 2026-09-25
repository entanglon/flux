import Foundation
import Combine
import SwiftUI

final class ProfileManager: ObservableObject {
    static let shared = ProfileManager()

    @Published var profiles: [UserProfile] = []
    @Published var currentProfile: UserProfile?

    private let profilesKey = "fluxProfiles"
    private let currentProfileKey = "fluxCurrentProfile"
    private let legacyHistoryKey = "localHistoryDataStremio"

    private init() {
        BundleMigrationService.migrateIfNeeded()
        if let data = UserDefaults.standard.data(forKey: profilesKey),
           let decoded = try? JSONDecoder().decode([UserProfile].self, from: data) {
            profiles = decoded
        }
        ensureKidsProfile()
        if let data = UserDefaults.standard.data(forKey: currentProfileKey),
           let profile = try? JSONDecoder().decode(UserProfile.self, from: data),
           let matched = profiles.first(where: { $0.id == profile.id }) {
            currentProfile = matched
            saveCurrentProfile()
            restoreSettings(for: matched.id)
            applyProfileDataScope(matched)
        }
        sanitizeProfileNames()
    }

    /// Whether exiting the current watching profile requires parental PIN verification.
    var requiresPinToExit: Bool {
        guard let current = currentProfile, current.isKids else { return false }
        return ParentalLockManager.shared.hasPin(for: current.id) || ParentalLockManager.shared.hasPin()
    }

    /// Whether entering a given profile requires PIN verification.
    func requiresPinToEnter(profile: UserProfile) -> Bool {
        ParentalLockManager.shared.hasPin(for: profile.id)
    }

    /// Guarantees that a stock, non-deletable Kids profile exists alongside regular profiles.
    func ensureKidsProfile() {
        guard !profiles.isEmpty else { return }
        if let idx = profiles.firstIndex(where: { $0.isKids || $0.name.lowercased() == "kids" }) {
            var updated = profiles[idx]
            if !updated.isKids || !updated.isStock || updated.name != "Kids" {
                updated.name = "Kids"
                updated.isKids = true
                updated.isStock = true
                profiles[idx] = updated
                saveProfiles()
            }
            cleanKidsProfileDataIfNeeded()
            return
        }
        let kids = UserProfile(
            id: UUID(),
            name: "Kids",
            avatarID: "face-lime",
            createdAt: Date(),
            isKids: true,
            isStock: true
        )
        profiles.append(kids)
        saveProfiles()
        cleanKidsProfileDataIfNeeded()
    }

    /// Ensures that the Kids profile never retains any adult or accidentally copied history/watchlist.
    func cleanKidsProfileDataIfNeeded() {
        guard !AppEnvironment.isRunningTests else { return }
        guard let kids = profiles.first(where: { $0.isKids }) else { return }
        let kidsPrefix = "profile.\(kids.id.uuidString)."
        
        let primary = profiles.first(where: { !$0.isKids })
        let primaryPrefix = primary != nil ? "profile.\(primary!.id.uuidString)." : ""
        let primaryHist = primary != nil ? ((UserDefaults.standard.array(forKey: primaryPrefix + "history") as? [[String: Any]]) ?? []) : []
        let primaryWatch = primary != nil ? ((UserDefaults.standard.array(forKey: primaryPrefix + "watchlist") as? [[String: Any]]) ?? []) : []
        let legacyHist = (UserDefaults.standard.array(forKey: "localHistoryDataStremio") as? [[String: Any]]) ?? []
        let legacyWatch = (UserDefaults.standard.array(forKey: "localWatchlistDataStremio") as? [[String: Any]]) ?? []

        let adultHistIDs = Set((primaryHist + legacyHist).compactMap { $0["id"] as? String })
        let adultWatchIDs = Set((primaryWatch + legacyWatch).compactMap { $0["id"] as? String })

        if let kidsHist = UserDefaults.standard.array(forKey: kidsPrefix + "history") as? [[String: Any]], !kidsHist.isEmpty {
            let kidsHistIDs = Set(kidsHist.compactMap { $0["id"] as? String })
            if !kidsHistIDs.isEmpty && (kidsHistIDs == adultHistIDs || kidsHistIDs.isSubset(of: adultHistIDs)) {
                UserDefaults.standard.removeObject(forKey: kidsPrefix + "history")
            } else {
                let safe = kidsHist.filter { dict in
                    guard let id = dict["id"] as? String, !adultHistIDs.contains(id) else { return false }
                    if let cert = dict["certification"] as? String {
                        return KidsContentFilter.shared.isCertificationSafe(cert)
                    }
                    return true
                }
                if safe.isEmpty {
                    UserDefaults.standard.removeObject(forKey: kidsPrefix + "history")
                } else {
                    UserDefaults.standard.set(safe, forKey: kidsPrefix + "history")
                }
            }
        }

        if let kidsWatch = UserDefaults.standard.array(forKey: kidsPrefix + "watchlist") as? [[String: Any]], !kidsWatch.isEmpty {
            let kidsWatchIDs = Set(kidsWatch.compactMap { $0["id"] as? String })
            if !kidsWatchIDs.isEmpty && (kidsWatchIDs == adultWatchIDs || kidsWatchIDs.isSubset(of: adultWatchIDs)) {
                UserDefaults.standard.removeObject(forKey: kidsPrefix + "watchlist")
            } else {
                let safe = kidsWatch.filter { dict in
                    guard let id = dict["id"] as? String, !adultWatchIDs.contains(id) else { return false }
                    if let cert = dict["certification"] as? String {
                        return KidsContentFilter.shared.isCertificationSafe(cert)
                    }
                    return true
                }
                if safe.isEmpty {
                    UserDefaults.standard.removeObject(forKey: kidsPrefix + "watchlist")
                } else {
                    UserDefaults.standard.set(safe, forKey: kidsPrefix + "watchlist")
                }
            }
        }

        if let kidsCol = UserDefaults.standard.array(forKey: kidsPrefix + "collections") as? [[String: Any]], !kidsCol.isEmpty {
            let primaryCol = primary != nil ? ((UserDefaults.standard.array(forKey: primaryPrefix + "collections") as? [[String: Any]]) ?? []) : []
            let legacyCol = (UserDefaults.standard.array(forKey: "localCollectionsData") as? [[String: Any]]) ?? []
            let adultColIDs = Set((primaryCol + legacyCol).compactMap { $0["id"] as? String })
            let kidsColIDs = Set(kidsCol.compactMap { $0["id"] as? String })
            if !kidsColIDs.isEmpty && (kidsColIDs == adultColIDs || kidsColIDs.isSubset(of: adultColIDs)) {
                UserDefaults.standard.removeObject(forKey: kidsPrefix + "collections")
            }
        }

        if currentProfile?.isKids == true {
            UserDataService.shared.reloadCurrentProfileData()
        }
    }

    func saveCurrentProfile() {
        guard !AppEnvironment.isRunningTests else { return }
        if let cur = currentProfile, let data = try? JSONEncoder().encode(cur) {
            UserDefaults.standard.set(data, forKey: currentProfileKey)
        }
    }

    func sanitizeProfileNames() {
        var didChange = false
        let isGuest = UserDefaults.standard.bool(forKey: "flux.authGuestMode")
        let savedName = UserDefaults.standard.string(forKey: "flux.authDisplayName")
        let email = UserDefaults.standard.string(forKey: "flux.authEmail")
        let userName = (savedName?.isEmpty == false && savedName != "Default" && savedName != "Guest" && savedName != "Kids" && savedName != "Alex Smith") 
            ? savedName! 
            : (email?.components(separatedBy: "@").first ?? (isGuest ? "Guest" : "User"))

        for idx in profiles.indices {
            let pName = profiles[idx].name
            if profiles[idx].isKids || pName.lowercased() == "kids" {
                profiles[idx].name = "Kids"
                profiles[idx].isKids = true
                profiles[idx].isStock = true
                didChange = true
            } else if pName == "Default" || pName.isEmpty || pName == "Alex Smith" {
                profiles[idx].name = isGuest ? "Guest" : userName
                didChange = true
            } else if isGuest && pName == "User" {
                profiles[idx].name = "Guest"
                didChange = true
            }
        }

        if let cur = currentProfile {
            if let matched = profiles.first(where: { $0.id == cur.id }) {
                if cur.name != matched.name || cur.avatarID != matched.avatarID || cur.isKids != matched.isKids {
                    currentProfile = matched
                    didChange = true
                }
            } else if cur.isKids || cur.name.lowercased() == "kids" {
                var updated = cur
                updated.name = "Kids"
                updated.isKids = true
                updated.isStock = true
                currentProfile = updated
                didChange = true
            } else if cur.name == "Default" || cur.name.isEmpty || cur.name == "Alex Smith" {
                var updated = cur
                updated.name = isGuest ? "Guest" : userName
                currentProfile = updated
                didChange = true
            } else if isGuest && cur.name == "User" {
                var updated = cur
                updated.name = "Guest"
                currentProfile = updated
                didChange = true
            }
        }

        if didChange {
            saveProfiles()
            saveCurrentProfile()
        }
    }

    var isFirstRun: Bool { profiles.isEmpty }

    func createProfile(name: String, avatarID: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let profile = UserProfile(id: UUID(), name: trimmed, avatarID: avatarID, createdAt: Date())
        profiles.append(profile)
        saveProfiles()
        selectProfile(profile)
        AuthManager.shared.scheduleAutoSync()
    }

    func selectProfile(_ profile: UserProfile) {
        // Per-profile playback settings: snapshot globals for the old profile,
        // restore the new profile's snapshot into the global keys
        if let old = currentProfile {
            snapshotSettings(for: old.id)
        }
        currentProfile = profile
        saveCurrentProfile()
        restoreSettings(for: profile.id)
        if profile.isKids {
            cleanKidsProfileDataIfNeeded()
        }
        applyProfileDataScope(profile)
    }

    /// Returns to the "Who's Watching?" screen (data stays intact).
    func switchToProfileSelection() {
        if let old = currentProfile {
            snapshotSettings(for: old.id)
        }
        currentProfile = nil
        UserDefaults.standard.removeObject(forKey: currentProfileKey)
        UserDataService.shared.switchProfile(to: nil)
        TasteProfileManager.shared.switchProfile(to: nil)
        RecentSearchManager.shared.switchProfile(to: nil)
    }

    /// Wipes all active watching profile state and account profiles upon sign-out.
    func handleSignOut() {
        if AppEnvironment.isRunningTests {
            currentProfile = nil
            profiles = []
            applyProfileDataScope(nil)
            return
        }
        for profile in profiles {
            let prefix = "profile.\(profile.id.uuidString)."
            for key in [prefix + "history", prefix + "watchlist", prefix + "loved", prefix + "watchSnaps", prefix + "settings", prefix + "collections", prefix + "episodeProgress", prefix + "recentSearches", prefix + "searchHistory", prefix + "historyClearedAt"] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        currentProfile = nil
        UserDefaults.standard.removeObject(forKey: currentProfileKey)
        profiles = []
        UserDefaults.standard.removeObject(forKey: profilesKey)
        applyProfileDataScope(nil)
    }

    /// Ensures a clean, dedicated Guest watching profile is selected when continuing as guest.
    func ensureGuestProfile() {
        sanitizeProfileNames()
        if let existing = profiles.first(where: { $0.name == "Guest" }) {
            selectProfile(existing)
            ensureKidsProfile()
            return
        }
        if let first = profiles.first(where: { !$0.isKids }) {
            var updated = first
            updated.name = "Guest"
            if let idx = profiles.firstIndex(where: { $0.id == first.id }) {
                profiles[idx] = updated
            }
            ensureKidsProfile()
            saveProfiles()
            selectProfile(updated)
            return
        }
        let guest = UserProfile(id: UUID(), name: "Guest", avatarID: "avatar1", createdAt: Date())
        profiles = [guest]
        ensureKidsProfile()
        saveProfiles()
        selectProfile(guest)
    }

    /// Ensures a watching profile exists with the given user name (from account signup or login).
    func ensureDefaultProfile(name: String, avatarID: String = "face-red") {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = AuthManager.shared.currentUser?.displayName ?? AuthManager.shared.currentUser?.email?.components(separatedBy: "@").first ?? "User"
        let profileName = (!cleanName.isEmpty && cleanName != "Default" && cleanName != "Guest" && cleanName != "Kids") 
            ? cleanName 
            : ((!fallbackName.isEmpty && fallbackName != "Default" && fallbackName != "Guest" && fallbackName != "Kids") ? fallbackName : "User")

        if let existing = profiles.first(where: { !$0.isKids }) {
            var updated = existing
            if updated.name == "Default" || updated.name == "Guest" || updated.name.isEmpty || updated.name != profileName {
                updated.name = profileName
            }
            if let idx = profiles.firstIndex(where: { $0.id == existing.id }) {
                profiles[idx] = updated
            }
            ensureKidsProfile()
            saveProfiles()
            selectProfile(updated)
            AuthManager.shared.scheduleAutoSync()
            return
        }

        let profile = UserProfile(id: UUID(), name: profileName, avatarID: avatarID, createdAt: Date())
        profiles = [profile]
        ensureKidsProfile()
        saveProfiles()
        selectProfile(profile)
        AuthManager.shared.scheduleAutoSync()
    }

    // MARK: - Per-profile settings snapshot

    var playbackSettingKeys: [String] {
        ["autoPlayNextEnabled", "useHardwareAcceleration", "enableAudioPassthrough",
         "defaultAudioLang", "defaultSubLang", "preferredQuality",
         UserDefaults.Key.preferredStreamLanguages,
         "streamingSourceMode", "enableFluxMode", "enableFluxLanguageFilter", "enableFluxCatalogue", "stremioCacheGB",
         UserDefaults.Key.enableAIStreamSelection, UserDefaults.Key.geminiModel, UserDefaults.Key.geminiApiKey,
         "appLanguage",
         UserDefaults.Key.streamRouteProxyEnabled, UserDefaults.Key.streamRouteProxyEndpoint, UserDefaults.Key.streamRouteProxyTargetHosts, UserDefaults.Key.streamRouteProxyAllHTTP]
    }

    /// Persists current UserDefaults into the active profile's settings snapshot.
    func saveCurrentProfileSettings() {
        guard let current = currentProfile else { return }
        let now = Date().timeIntervalSince1970
        UserDefaults.standard.set(now, forKey: "settingsUpdatedAt")
        snapshotSettings(for: current.id)
    }

    func exportGlobalSettings() -> [String: Any] {
        var snap: [String: Any] = [:]
        for key in playbackSettingKeys {
            if let v = UserDefaults.standard.object(forKey: key) {
                snap[key] = v
            }
        }
        let currentProfileID = currentProfile?.id.uuidString ?? ""
        let profileSettings = UserDefaults.standard.dictionary(forKey: "profile.\(currentProfileID).settings")
        let profileUpdatedAt = profileSettings?["settingsUpdatedAt"] as? Double
        let localUpdatedAt = UserDefaults.standard.double(forKey: "settingsUpdatedAt")
        let effectiveUpdatedAt = profileUpdatedAt ?? (localUpdatedAt > 0 ? localUpdatedAt : Date().timeIntervalSince1970)
        snap["settingsUpdatedAt"] = effectiveUpdatedAt
        return snap
    }

    func snapshotSettings(for profileID: UUID) {
        var snap: [String: Any] = UserDefaults.standard.dictionary(forKey: "profile.\(profileID.uuidString).settings") ?? [:]
        for key in playbackSettingKeys {
            if let v = UserDefaults.standard.object(forKey: key) {
                snap[key] = v
            }
        }
        let now = Date().timeIntervalSince1970
        snap["settingsUpdatedAt"] = now
        UserDefaults.standard.set(now, forKey: "settingsUpdatedAt")
        if !snap.isEmpty {
            UserDefaults.standard.set(snap, forKey: "profile.\(profileID.uuidString).settings")
        }
    }

    private func restoreSettings(for profileID: UUID) {
        if let snap = UserDefaults.standard.dictionary(forKey: "profile.\(profileID.uuidString).settings") {
            for (key, value) in snap {
                if key == UserDefaults.Key.streamRouteProxyEndpoint {
                    let ep = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !ep.isEmpty {
                        UserDefaults.standard.set(ep, forKey: key)
                    } else if !AppEnvironment.isRunningTests, let cur = UserDefaults.standard.string(forKey: key), !cur.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // Keep current valid endpoint
                    } else if let recovered = StreamRouteProxyManager.recoverConfiguredEndpoint(), !recovered.isEmpty {
                        UserDefaults.standard.set(recovered, forKey: key)
                    } else if AppEnvironment.isRunningTests {
                        UserDefaults.standard.removeObject(forKey: key)
                    }
                    continue
                }
                UserDefaults.standard.set(value, forKey: key)
            }
            if let lang = snap["appLanguage"] as? String {
                LanguageManager.shared.syncFromProfile(lang)
            }
            if snap[UserDefaults.Key.streamRouteProxyEnabled] == nil {
                snapshotSettings(for: profileID)
            }
            if snap[UserDefaults.Key.preferredStreamLanguages] == nil {
                let defaultAudio = UserDefaults.standard.string(forKey: "defaultAudioLang") ?? "English"
                UserDefaults.standard.set([defaultAudio], forKey: UserDefaults.Key.preferredStreamLanguages)
                snapshotSettings(for: profileID)
            }
            if let model = snap[UserDefaults.Key.geminiModel] as? String {
                let validGeminiModels = ["gemini-3.5-flash-lite", "gemini-3.6-flash", "gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.5-flash", "gemini-3.1-flash-lite", "gemini-2.5-flash"]
                if !validGeminiModels.contains(model) {
                    UserDefaults.standard.set("gemini-3.5-flash-lite", forKey: UserDefaults.Key.geminiModel)
                    snapshotSettings(for: profileID)
                }
            }
            StreamRouteProxyManager.shared.reloadFromUserDefaults()
        } else {
            // First time loading this profile: snapshot current settings so active preferences persist
            snapshotSettings(for: profileID)
        }
    }

    func updateProfile(_ profile: UserProfile, name: String, avatarID: String) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        profiles[idx].name = profiles[idx].isKids ? "Kids" : trimmed
        profiles[idx].avatarID = avatarID
        saveProfiles()
        if currentProfile?.id == profile.id {
            currentProfile = profiles[idx]
            saveCurrentProfile()
        }
        AuthManager.shared.scheduleAutoSync()
    }

    func deleteProfile(_ profile: UserProfile) {
        guard !profile.isStock && !profile.isKids else { return }
        // Wipe the profile's namespaced data
        if !AppEnvironment.isRunningTests {
            let prefix = "profile.\(profile.id.uuidString)."
            for key in [prefix + "history", prefix + "watchlist", prefix + "loved", prefix + "watchSnaps", prefix + "settings", prefix + "collections", prefix + "episodeProgress", prefix + "recentSearches", prefix + "searchHistory", prefix + "historyClearedAt"] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        profiles.removeAll { $0.id == profile.id }
        saveProfiles()
        if currentProfile?.id == profile.id {
            switchToProfileSelection()
        }
        AuthManager.shared.scheduleAutoSync()
    }

    private func applyProfileDataScope(_ profile: UserProfile?) {
        UserDataService.shared.switchProfile(to: profile)
        TasteProfileManager.shared.switchProfile(to: profile)
        RecentSearchManager.shared.switchProfile(to: profile)
    }

    private func saveProfiles() {
        guard !AppEnvironment.isRunningTests else { return }
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
    }

    // MARK: - Cloud Sync

    func exportProfilesData() -> [[String: Any]] {
        saveCurrentProfileSettings()
        return profiles.map { p in
            let prefix = "profile.\(p.id.uuidString)."
            var dict: [String: Any] = [
                "id": p.id.uuidString,
                "name": p.name,
                "avatarID": p.avatarID,
                "createdAt": p.createdAt.timeIntervalSince1970,
                "isKids": p.isKids,
                "isStock": p.isStock
            ]
            if let hist = UserDefaults.standard.array(forKey: prefix + "history") {
                dict["history"] = hist
            }
            if let watch = UserDefaults.standard.array(forKey: prefix + "watchlist") {
                dict["watchlist"] = watch
            }
            if let loved = UserDefaults.standard.array(forKey: prefix + "loved") {
                dict["loved"] = loved
            } else if let lovedData = UserDefaults.standard.data(forKey: prefix + "loved"),
                      let raw = try? JSONSerialization.jsonObject(with: lovedData) {
                dict["loved"] = raw
            }
            if let snaps = UserDefaults.standard.data(forKey: prefix + "watchSnaps"),
               let raw = try? JSONSerialization.jsonObject(with: snaps) {
                dict["watchSnaps"] = raw
            }
            if let settings = UserDefaults.standard.dictionary(forKey: prefix + "settings") {
                dict["settings"] = settings
            }
            if let col = UserDefaults.standard.array(forKey: prefix + "collections") as? [[String: Any]] {
                dict["collections"] = col.map { c in
                    var sanitizedCol = c
                    if let d = c["itemsData"] as? Data {
                        sanitizedCol["itemsData"] = d.base64EncodedString()
                    }
                    return sanitizedCol
                }
            } else if let col = UserDefaults.standard.array(forKey: prefix + "collections") {
                dict["collections"] = col
            }
            if let epProg = UserDefaults.standard.dictionary(forKey: prefix + "episodeProgress") {
                dict["episodeProgress"] = epProg
            } else {
                dict["episodeProgress"] = [String: Any]()
            }
            if let recSearch = UserDefaults.standard.data(forKey: prefix + "recentSearches"),
               let raw = try? JSONSerialization.jsonObject(with: recSearch) {
                dict["recentSearches"] = raw
            }
            let clearedAt = UserDefaults.standard.double(forKey: prefix + "historyClearedAt")
            if clearedAt > 0 {
                dict["historyClearedAt"] = clearedAt
            }
            if let searchHist = UserDefaults.standard.stringArray(forKey: prefix + "searchHistory") {
                dict["searchHistory"] = searchHist
            }
            return dict
        }
    }

    func applyCloudProfilesData(_ remoteProfiles: [[String: Any]]?, replaceList: Bool = true) {
        guard let list = remoteProfiles, !list.isEmpty else { return }

        let applyBlock = {
            var imported: [UserProfile] = []
            for item in list {
                guard let idStr = item["id"] as? String,
                      let id = UUID(uuidString: idStr),
                      let name = item["name"] as? String,
                      let avatarID = item["avatarID"] as? String else { continue }
                let createdSeconds = item["createdAt"] as? Double ?? Date().timeIntervalSince1970
                let isKids = item["isKids"] as? Bool ?? false
                let isStock = item["isStock"] as? Bool ?? false
                let profile = UserProfile(
                    id: id,
                    name: name,
                    avatarID: avatarID,
                    createdAt: Date(timeIntervalSince1970: createdSeconds),
                    isKids: isKids,
                    isStock: isStock
                )
                imported.append(profile)

                let prefix = "profile.\(id.uuidString)."
                if let hist = item["history"] as? [[String: Any]] {
                    UserDefaults.standard.set(hist, forKey: prefix + "history")
                }
                if let watch = item["watchlist"] as? [[String: Any]] {
                    UserDefaults.standard.set(watch, forKey: prefix + "watchlist")
                }
                if let loved = item["loved"] as? [String] {
                    UserDefaults.standard.set(loved, forKey: prefix + "loved")
                }
                if let snaps = item["watchSnaps"],
                   let data = try? JSONSerialization.data(withJSONObject: snaps) {
                    UserDefaults.standard.set(data, forKey: prefix + "watchSnaps")
                }
                if let settings = item["settings"] as? [String: Any] {
                    let remoteUpdatedAt = settings["settingsUpdatedAt"] as? Double ?? 0
                    let localSettings = UserDefaults.standard.dictionary(forKey: prefix + "settings")
                    let localUpdatedAt = localSettings?["settingsUpdatedAt"] as? Double ?? 0
                    if remoteUpdatedAt > localUpdatedAt || localSettings == nil {
                        var updatedSettings = settings
                        let localProxyEnabled = (localSettings?[UserDefaults.Key.streamRouteProxyEnabled] as? Bool) ?? UserDefaults.standard.bool(forKey: UserDefaults.Key.streamRouteProxyEnabled)
                        let remoteProxyEnabled = settings[UserDefaults.Key.streamRouteProxyEnabled] as? Bool ?? false
                        let localEp = (localSettings?[UserDefaults.Key.streamRouteProxyEndpoint] as? String) ?? UserDefaults.standard.string(forKey: UserDefaults.Key.streamRouteProxyEndpoint) ?? ""
                        if !remoteProxyEnabled && localProxyEnabled && !localEp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && remoteUpdatedAt <= localUpdatedAt {
                            updatedSettings[UserDefaults.Key.streamRouteProxyEnabled] = true
                        }
                        UserDefaults.standard.set(updatedSettings, forKey: prefix + "settings")
                    }
                }
                if let col = item["collections"] as? [[String: Any]] {
                    UserDefaults.standard.set(col, forKey: prefix + "collections")
                }
                if let epProg = item["episodeProgress"] as? [String: Any] {
                    UserDefaults.standard.set(epProg, forKey: prefix + "episodeProgress")
                }
                if let recSearch = item["recentSearches"],
                   let data = try? JSONSerialization.data(withJSONObject: recSearch) {
                    UserDefaults.standard.set(data, forKey: prefix + "recentSearches")
                }
                if let clearedAt = item["historyClearedAt"] as? Double, clearedAt > 0 {
                    let localCleared = UserDefaults.standard.double(forKey: prefix + "historyClearedAt")
                    if clearedAt > localCleared {
                        UserDefaults.standard.set(clearedAt, forKey: prefix + "historyClearedAt")
                    }
                }
                if let searchHist = item["searchHistory"] as? [String] {
                    UserDefaults.standard.set(searchHist, forKey: prefix + "searchHistory")
                }
            }

            guard !imported.isEmpty else { return }

            // Merge legacy un-namespaced library data into the primary non-Kids profile
            // if this profile doesn't have namespaced data yet
            let primaryNonKids = imported.first(where: { !$0.isKids })
            if let primary = primaryNonKids {
                let targetPrefix = "profile.\(primary.id.uuidString)."
                for (legacyKey, subkey) in [
                    ("localHistoryDataStremio", "history"),
                    ("localWatchlistDataStremio", "watchlist"),
                    ("localCollectionsData", "collections"),
                    ("tasteProfileLovedItems", "loved"),
                    ("tasteProfileWatchSnapshots", "watchSnaps"),
                    ("globalEpisodeProgress", "episodeProgress")
                ] {
                    let targetKey = targetPrefix + subkey
                    if UserDefaults.standard.object(forKey: targetKey) == nil,
                       let legacyVal = UserDefaults.standard.object(forKey: legacyKey) {
                        UserDefaults.standard.set(legacyVal, forKey: targetKey)
                    }
                }
            }

            guard replaceList else { return }

            // Clean up any remaining legacy migration temp keys from old profile IDs
            for localP in self.profiles {
                if !imported.contains(where: { $0.id == localP.id }) && !localP.isKids {
                    if let primary = primaryNonKids {
                        let sourcePrefix = "profile.\(localP.id.uuidString)."
                        let targetPrefix = "profile.\(primary.id.uuidString)."
                        if UserDefaults.standard.object(forKey: targetPrefix + "history") == nil,
                           let localHist = UserDefaults.standard.array(forKey: sourcePrefix + "history") {
                            UserDefaults.standard.set(localHist, forKey: targetPrefix + "history")
                        }
                        if UserDefaults.standard.object(forKey: targetPrefix + "watchlist") == nil,
                           let localWatch = UserDefaults.standard.array(forKey: sourcePrefix + "watchlist") {
                            UserDefaults.standard.set(localWatch, forKey: targetPrefix + "watchlist")
                        }
                        if UserDefaults.standard.object(forKey: targetPrefix + "collections") == nil,
                           let localCol = UserDefaults.standard.array(forKey: sourcePrefix + "collections") {
                            UserDefaults.standard.set(localCol, forKey: targetPrefix + "collections")
                        }
                        if UserDefaults.standard.object(forKey: targetPrefix + "loved") == nil,
                           let localLoved = UserDefaults.standard.array(forKey: sourcePrefix + "loved") {
                            UserDefaults.standard.set(localLoved, forKey: targetPrefix + "loved")
                        }
                        if UserDefaults.standard.object(forKey: targetPrefix + "watchSnaps") == nil,
                           let localSnaps = UserDefaults.standard.data(forKey: sourcePrefix + "watchSnaps") {
                            UserDefaults.standard.set(localSnaps, forKey: targetPrefix + "watchSnaps")
                        }
                        if UserDefaults.standard.object(forKey: targetPrefix + "episodeProgress") == nil,
                           let localProg = UserDefaults.standard.dictionary(forKey: sourcePrefix + "episodeProgress") {
                            UserDefaults.standard.set(localProg, forKey: targetPrefix + "episodeProgress")
                        }
                        if UserDefaults.standard.object(forKey: targetPrefix + "recentSearches") == nil,
                           let localSearch = UserDefaults.standard.data(forKey: sourcePrefix + "recentSearches") {
                            UserDefaults.standard.set(localSearch, forKey: targetPrefix + "recentSearches")
                        }
                        let targetSettings = (UserDefaults.standard.dictionary(forKey: targetPrefix + "settings") as? [String: Any]) ?? [:]
                        if let localSettings = UserDefaults.standard.dictionary(forKey: sourcePrefix + "settings") as? [String: Any], !localSettings.isEmpty {
                            var mergedSettings = targetSettings
                            for (sk, sv) in localSettings {
                                if mergedSettings[sk] == nil {
                                    mergedSettings[sk] = sv
                                } else if sk == UserDefaults.Key.streamRouteProxyEndpoint {
                                    let tEp = (mergedSettings[sk] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                    let sEp = (sv as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                    if tEp.isEmpty && !sEp.isEmpty {
                                        mergedSettings[sk] = sEp
                                    }
                                }
                            }
                            UserDefaults.standard.set(mergedSettings, forKey: targetPrefix + "settings")
                        }
                        for key in [sourcePrefix + "history", sourcePrefix + "watchlist", sourcePrefix + "loved", sourcePrefix + "watchSnaps", sourcePrefix + "settings", sourcePrefix + "collections", sourcePrefix + "episodeProgress", sourcePrefix + "recentSearches"] {
                            UserDefaults.standard.removeObject(forKey: key)
                        }
                    }
                }
            }

            let userName = AuthManager.shared.currentUser?.displayName ?? AuthManager.shared.currentUser?.email?.components(separatedBy: "@").first ?? ""
            let sanitized = imported.map { p -> UserProfile in
                if (p.name == "Default" || p.name == "Guest" || p.name == "Alex Smith") && !userName.isEmpty && userName != "Default" && userName != "Guest" && userName != "Alex Smith" && !p.isKids {
                    return UserProfile(id: p.id, name: userName, avatarID: p.avatarID, createdAt: p.createdAt, isKids: p.isKids, isStock: p.isStock)
                }
                return p
            }

            self.profiles = sanitized
            self.ensureKidsProfile()
            self.saveProfiles()
            if let cur = self.currentProfile {
                if let matching = sanitized.first(where: { $0.id == cur.id }) {
                    self.currentProfile = matching
                    self.saveCurrentProfile()
                    self.restoreSettings(for: matching.id)
                    self.applyProfileDataScope(matching)
                } else if let first = sanitized.first {
                    self.selectProfile(first)
                } else {
                    self.currentProfile = nil
                }
            } else if let first = sanitized.first(where: { !$0.isKids }) ?? sanitized.first {
                self.selectProfile(first)
            }
        }

        if Thread.isMainThread {
            applyBlock()
        } else {
            DispatchQueue.main.sync {
                applyBlock()
            }
        }
    }

    /// Legacy (pre-profiles) history exists? Used to migrate data into the
    /// first created profile so nobody loses their library.
    var hasLegacyData: Bool {
        (UserDefaults.standard.array(forKey: legacyHistoryKey) as? [[String: Any]])?.isEmpty == false
    }
}
