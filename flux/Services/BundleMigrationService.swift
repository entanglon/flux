import Foundation
import OSLog

/// Automatically migrates user library, preferences, profile data, and credentials
/// from the production bundle (`com.entanglon.flux`) to the beta bundle (`com.entanglon.flux.beta`).
enum BundleMigrationService {
    private static let migrationKey = "flux.didMigrateFromProductionBundle.v1"
    private static let sourceBundleID = "com.entanglon.flux"

    static func migrateIfNeeded() {
        guard !AppEnvironment.isRunningTests else { return }
        let currentBundleID = Bundle.main.bundleIdentifier ?? ""
        guard currentBundleID != sourceBundleID else { return }

        let hasMigrated = UserDefaults.standard.bool(forKey: migrationKey)
        let currentTmdb = UserDefaults.standard.string(forKey: UserDefaults.Key.tmdbApiKey) ?? ""
        let targetAddonData = UserDefaults.standard.data(forKey: "StremioConfiguredAddons")
        let targetAddons = targetAddonData.flatMap { try? JSONDecoder().decode([StremioAddon].self, from: $0) } ?? []
        let targetCommunityAddonCount = targetAddons.filter { !$0.isStock }.count
        
        // If already migrated and user has a populated TMDB key and community addons, no need to re-migrate
        if hasMigrated && !currentTmdb.isEmpty && targetCommunityAddonCount > 0 {
            return
        }

        guard let sourceDefaults = UserDefaults(suiteName: sourceBundleID) else { return }
        let sourceDict = sourceDefaults.dictionaryRepresentation()
        guard !sourceDict.isEmpty else { return }

        Logger.sync.info("Starting bundle migration from \(sourceBundleID) to \(currentBundleID)...")

        let prefixesToMigrate = ["profile.", "flux.", "flux_", "local"]
        let exactKeysToMigrate = [
            UserDefaults.Key.tmdbApiKey,
            "globalEpisodeProgress",
            "tasteProfileLovedItems",
            "tasteProfileWatchSnapshots",
            "StremioConfiguredAddons",
            "fluxProfiles",
            "fluxCurrentProfile",
            "preferredQuality",
            "streamingSourceMode",
            "enableFluxCatalogue",
            "enableFluxLanguageFilter",
            "enableFluxMode",
            "autoPlayNextEnabled",
            "appLanguage",
            "lastUsedSource",
            "flux_recent_searches"
        ]

        var migratedCount = 0

        for (key, value) in sourceDict {
            let shouldMigrate = exactKeysToMigrate.contains(key) ||
                prefixesToMigrate.contains(where: { key.hasPrefix($0) })
            guard shouldMigrate else { continue }

            if key == "StremioConfiguredAddons" {
                let targetData = UserDefaults.standard.data(forKey: key)
                let targetAddons = targetData.flatMap { try? JSONDecoder().decode([StremioAddon].self, from: $0) } ?? []
                let sourceData = value as? Data
                let sourceAddons = sourceData.flatMap { try? JSONDecoder().decode([StremioAddon].self, from: $0) } ?? []
                let targetCommunity = targetAddons.filter { !$0.isStock }.count
                let sourceCommunity = sourceAddons.filter { !$0.isStock }.count
                // Only skip if target has at least as many community addons as source
                if targetCommunity >= sourceCommunity && targetCommunity > 0 {
                    continue
                }
            } else if key == "fluxCurrentProfile" {
                // If target has "Alex Smith", force restore from source
                if let targetData = UserDefaults.standard.data(forKey: key),
                   let prof = try? JSONDecoder().decode(UserProfile.self, from: targetData),
                   prof.name != "Alex Smith" {
                    continue
                }
            } else if key == "streamingSourceMode" {
                // If target has "both" but source had explicit "http", restore "http"
                if let targetMode = UserDefaults.standard.string(forKey: key),
                   targetMode != "both" {
                    continue
                }
            } else {
                // If target has a non-empty string, dictionary, or array, preserve it
                if let targetStr = UserDefaults.standard.string(forKey: key), !targetStr.isEmpty {
                    continue
                }
                if let targetArr = UserDefaults.standard.array(forKey: key), !targetArr.isEmpty {
                    continue
                }
                if let targetDict = UserDefaults.standard.dictionary(forKey: key), !targetDict.isEmpty {
                    continue
                }
            }

            UserDefaults.standard.set(value, forKey: key)
            migratedCount += 1
        }

        // Invalidate cloud sync timestamp so the app recognizes local additions that must push to cloud
        UserDefaults.standard.removeObject(forKey: UserDefaults.Key.cloudLastSyncAt)
        UserDefaults.standard.set(true, forKey: migrationKey)
        UserDefaults.standard.synchronize()

        Logger.sync.info("Bundle migration finished: \(migratedCount) keys copied from \(sourceBundleID)")
    }
}
