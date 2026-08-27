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
            applyProfileDataScope(profile)
        }
    }

    var isFirstRun: Bool { profiles.isEmpty }

    func createProfile(name: String, avatarID: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let profile = UserProfile(id: UUID(), name: trimmed, avatarID: avatarID, createdAt: Date())
        profiles.append(profile)
        saveProfiles()
        selectProfile(profile, migrateLegacyData: profiles.count == 1)
    }

    func selectProfile(_ profile: UserProfile, migrateLegacyData: Bool = false) {
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
        UserDataService.shared.switchProfile(to: profile, migrateLegacyData: migrateLegacyData)
        TasteProfileManager.shared.switchProfile(to: profile)
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

    // MARK: - Per-profile settings snapshot

    private var playbackSettingKeys: [String] {
        ["autoPlayNextEnabled", "useHardwareAcceleration", "enableAudioPassthrough",
         "defaultAudioLang", "defaultSubLang", "preferredQuality",
         "streamingSourceMode", "enableFluxMode", "enableFluxCatalogue", "stremioCacheGB",
         "ramCacheMode", "ramCacheLimitMB"]
    }

    private func snapshotSettings(for profileID: UUID) {
        var snap: [String: Any] = [:]
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
    }

    private func applyProfileDataScope(_ profile: UserProfile?) {
        // Hook for services that need the scope change; the services themselves
        // are switched in selectProfile/switchToProfileSelection.
    }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
    }

    /// Legacy (pre-profiles) history exists? Used to migrate data into the
    /// first created profile so nobody loses their library.
    var hasLegacyData: Bool {
        (UserDefaults.standard.array(forKey: legacyHistoryKey) as? [[String: Any]])?.isEmpty == false
    }
}
