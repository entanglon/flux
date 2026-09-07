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
        if let data = UserDefaults.standard.data(forKey: profilesKey),
           let decoded = try? JSONDecoder().decode([UserProfile].self, from: data) {
            profiles = decoded
        }
        if let data = UserDefaults.standard.data(forKey: currentProfileKey),
           let profile = try? JSONDecoder().decode(UserProfile.self, from: data),
           profiles.contains(where: { $0.id == profile.id }) {
            currentProfile = profile
            restoreSettings(for: profile.id)
            applyProfileDataScope(profile)
        }
        sanitizeProfileNames()
    }

    func sanitizeProfileNames() {
        var didChange = false
        let isGuest = UserDefaults.standard.bool(forKey: "flux.authGuestMode")
        let savedName = UserDefaults.standard.string(forKey: "flux.authDisplayName")
        let email = UserDefaults.standard.string(forKey: "flux.authEmail")
        let userName = (savedName?.isEmpty == false && savedName != "Default" && savedName != "Guest") 
            ? savedName! 
            : (email?.components(separatedBy: "@").first ?? (isGuest ? "Guest" : "User"))

        for idx in profiles.indices {
            let pName = profiles[idx].name
            if pName == "Default" || pName.isEmpty {
                profiles[idx].name = isGuest ? "Guest" : userName
                didChange = true
            } else if isGuest && pName == "User" {
                profiles[idx].name = "Guest"
                didChange = true
            }
        }

        if let cur = currentProfile {
            if cur.name == "Default" || cur.name.isEmpty {
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
            if let cur = currentProfile, let data = try? JSONEncoder().encode(cur) {
                UserDefaults.standard.set(data, forKey: currentProfileKey)
            }
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
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: currentProfileKey)
        }
        restoreSettings(for: profile.id)
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
    }

    /// Wipes all active watching profile state and account profiles upon sign-out.
    func handleSignOut() {
        for profile in profiles {
            let prefix = "profile.\(profile.id.uuidString)."
            for key in [prefix + "history", prefix + "watchlist", prefix + "loved", prefix + "watchSnaps", prefix + "settings", prefix + "collections", prefix + "episodeProgress"] {
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
            return
        }
        if let first = profiles.first {
            var updated = first
            updated.name = "Guest"
            if let idx = profiles.firstIndex(where: { $0.id == first.id }) {
                profiles[idx] = updated
            }
            saveProfiles()
            selectProfile(updated)
            return
        }
        let guest = UserProfile(id: UUID(), name: "Guest", avatarID: "avatar1", createdAt: Date())
        profiles = [guest]
        saveProfiles()
        selectProfile(guest)
    }

    /// Ensures a watching profile exists with the given user name (from account signup or login).
    func ensureDefaultProfile(name: String, avatarID: String = "face-red") {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = AuthManager.shared.currentUser?.displayName ?? AuthManager.shared.currentUser?.email?.components(separatedBy: "@").first ?? "User"
        let profileName = (!cleanName.isEmpty && cleanName != "Default" && cleanName != "Guest") 
            ? cleanName 
            : ((!fallbackName.isEmpty && fallbackName != "Default" && fallbackName != "Guest") ? fallbackName : "User")

        if let existing = profiles.first {
            var updated = existing
            if updated.name == "Default" || updated.name == "Guest" || updated.name.isEmpty || updated.name != profileName {
                updated.name = profileName
            }
            if let idx = profiles.firstIndex(where: { $0.id == existing.id }) {
                profiles[idx] = updated
            }
            saveProfiles()
            selectProfile(updated)
            AuthManager.shared.scheduleAutoSync()
            return
        }

        let profile = UserProfile(id: UUID(), name: profileName, avatarID: avatarID, createdAt: Date())
        profiles = [profile]
        saveProfiles()
        selectProfile(profile)
        AuthManager.shared.scheduleAutoSync()
    }

    // MARK: - Per-profile settings snapshot

    var playbackSettingKeys: [String] {
        ["autoPlayNextEnabled", "useHardwareAcceleration", "enableAudioPassthrough",
         "defaultAudioLang", "defaultSubLang", "preferredQuality",
         "streamingSourceMode", "enableFluxMode", "enableFluxLanguageFilter", "enableFluxCatalogue", "stremioCacheGB"]
    }

    /// Persists current UserDefaults into the active profile's settings snapshot.
    func saveCurrentProfileSettings() {
        guard let current = currentProfile else { return }
        snapshotSettings(for: current.id)
    }

    func exportGlobalSettings() -> [String: Any] {
        var snap: [String: Any] = [:]
        for key in playbackSettingKeys {
            if let v = UserDefaults.standard.object(forKey: key) {
                snap[key] = v
            }
        }
        return snap
    }

    func snapshotSettings(for profileID: UUID) {
        var snap: [String: Any] = UserDefaults.standard.dictionary(forKey: "profile.\(profileID.uuidString).settings") ?? [:]
        for key in playbackSettingKeys {
            if let v = UserDefaults.standard.object(forKey: key) {
                snap[key] = v
            }
        }
        if !snap.isEmpty {
            UserDefaults.standard.set(snap, forKey: "profile.\(profileID.uuidString).settings")
        }
    }

    private func restoreSettings(for profileID: UUID) {
        if let snap = UserDefaults.standard.dictionary(forKey: "profile.\(profileID.uuidString).settings") {
            for (key, value) in snap {
                UserDefaults.standard.set(value, forKey: key)
            }
        } else {
            // First time loading this profile: snapshot current settings so active preferences persist
            snapshotSettings(for: profileID)
        }
    }

    func updateProfile(_ profile: UserProfile, name: String, avatarID: String) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        profiles[idx].name = trimmed
        profiles[idx].avatarID = avatarID
        saveProfiles()
        if currentProfile?.id == profile.id {
            currentProfile = profiles[idx]
            if let data = try? JSONEncoder().encode(profiles[idx]) {
                UserDefaults.standard.set(data, forKey: currentProfileKey)
            }
        }
        AuthManager.shared.scheduleAutoSync()
    }

    func deleteProfile(_ profile: UserProfile) {
        // Wipe the profile's namespaced data
        let prefix = "profile.\(profile.id.uuidString)."
        for key in [prefix + "history", prefix + "watchlist", prefix + "loved", prefix + "watchSnaps"] {
            UserDefaults.standard.removeObject(forKey: key)
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
    }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
    }

    // MARK: - Cloud Sync

    func exportProfilesData() -> [[String: Any]] {
        return profiles.map { p in
            var dict: [String: Any] = [
                "id": p.id.uuidString,
                "name": p.name,
                "avatarID": p.avatarID,
                "createdAt": p.createdAt.timeIntervalSince1970
            ]
            if let snap = UserDefaults.standard.dictionary(forKey: "profile.\(p.id.uuidString).settings") {
                dict["settings"] = snap
            }
            return dict
        }
    }

    func applyCloudProfilesData(_ raw: [[String: Any]]?) {
        guard let raw, !raw.isEmpty else { return }
        var imported: [UserProfile] = []
        for dict in raw {
            guard let idStr = dict["id"] as? String,
                  let id = UUID(uuidString: idStr),
                  let name = dict["name"] as? String,
                  let avatarID = dict["avatarID"] as? String else { continue }
            let created = (dict["createdAt"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
            imported.append(UserProfile(id: id, name: name, avatarID: avatarID, createdAt: created))
            if let remoteSettings = dict["settings"] as? [String: Any] {
                UserDefaults.standard.set(remoteSettings, forKey: "profile.\(id.uuidString).settings")
            }
        }
        guard !imported.isEmpty else { return }

        let applyBlock = {
            // Clean up any local profiles being replaced by the cloud profiles,
            // but preserve any local history/watchlist by carrying it into the primary imported profile!
            if let targetPrimary = imported.first {
                let targetPrefix = "profile.\(targetPrimary.id.uuidString)."
                for localProfile in self.profiles {
                    if !imported.contains(where: { $0.id == localProfile.id }) {
                        let sourcePrefix = "profile.\(localProfile.id.uuidString)."
                        let targetHist = (UserDefaults.standard.array(forKey: targetPrefix + "history") as? [[String: Any]]) ?? []
                        if targetHist.isEmpty,
                           let localHist = UserDefaults.standard.array(forKey: sourcePrefix + "history") as? [[String: Any]], !localHist.isEmpty {
                            UserDefaults.standard.set(localHist, forKey: targetPrefix + "history")
                        }
                        let targetWatch = (UserDefaults.standard.array(forKey: targetPrefix + "watchlist") as? [[String: Any]]) ?? []
                        if targetWatch.isEmpty,
                           let localWatch = UserDefaults.standard.array(forKey: sourcePrefix + "watchlist") as? [[String: Any]], !localWatch.isEmpty {
                            UserDefaults.standard.set(localWatch, forKey: targetPrefix + "watchlist")
                        }
                        for key in [sourcePrefix + "history", sourcePrefix + "watchlist", sourcePrefix + "loved", sourcePrefix + "watchSnaps", sourcePrefix + "settings", sourcePrefix + "collections", sourcePrefix + "episodeProgress"] {
                            UserDefaults.standard.removeObject(forKey: key)
                        }
                    }
                }
            }

            let userName = AuthManager.shared.currentUser?.displayName ?? AuthManager.shared.currentUser?.email?.components(separatedBy: "@").first ?? ""
            let sanitized = imported.map { p -> UserProfile in
                if (p.name == "Default" || p.name == "Guest") && !userName.isEmpty && userName != "Default" && userName != "Guest" {
                    return UserProfile(id: p.id, name: userName, avatarID: p.avatarID, createdAt: p.createdAt)
                }
                return p
            }

            self.profiles = sanitized
            self.saveProfiles()
            if let cur = self.currentProfile, !sanitized.contains(where: { $0.id == cur.id }) {
                if let first = sanitized.first {
                    self.selectProfile(first)
                } else {
                    self.currentProfile = nil
                }
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
