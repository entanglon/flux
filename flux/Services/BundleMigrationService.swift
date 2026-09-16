import Foundation
import OSLog

/// Automatically migrates user library, preferences, profile data, and credentials
/// from the production bundle (`com.entanglon.flux`) to the beta bundle (`com.entanglon.flux.beta`).
enum BundleMigrationService {
    private static let migrationKey = "flux.didMigrateFromProductionBundle.v1"
    private static let sourceBundleID = "com.entanglon.flux"

    static func migrateIfNeeded() {
        let currentBundleID = Bundle.main.bundleIdentifier ?? ""
        guard currentBundleID != sourceBundleID else { return }

        let hasMigrated = UserDefaults.standard.bool(forKey: migrationKey)
        let currentTmdb = UserDefaults.standard.string(forKey: UserDefaults.Key.tmdbApiKey) ?? ""
        
        // If already migrated and user has a populated TMDB key or library, no need to re-migrate
        if hasMigrated && !currentTmdb.isEmpty {
            return
        }

        guard let sourceDefaults = UserDefaults(suiteName: sourceBundleID) else { return }
        let sourceDict = sourceDefaults.dictionaryRepresentation()
        guard !sourceDict.isEmpty else { return }

        Logger.sync.info("Starting bundle migration from \(sourceBundleID) to \(currentBundleID)...")

        let prefixesToMigrate = ["profile.", "flux.", "local"]
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
            "lastUsedSource"
        ]

        var migratedCount = 0

        for (key, value) in sourceDict {
            let shouldMigrate = exactKeysToMigrate.contains(key) ||
                prefixesToMigrate.contains(where: { key.hasPrefix($0) })
            guard shouldMigrate else { continue }

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
