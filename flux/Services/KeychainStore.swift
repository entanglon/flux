import Foundation

/// Persistent store for session secrets backed by a private UserDefaults namespace.
/// Using UserDefaults eliminates macOS Security daemon Keychain ACL authorization dialogs
/// which occur on every rebuild of ad-hoc / unsigned development binaries.
enum KeychainStore {
    private static let keyPrefix = "flux.sec."

    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil ||
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private static var testStore: [String: String] = [:]

    static func set(_ value: String, forKey key: String) {
        if isRunningTests {
            testStore[key] = value
            return
        }
        UserDefaults.standard.set(value, forKey: keyPrefix + key)
    }

    static func get(_ key: String) -> String? {
        if isRunningTests {
            return testStore[key]
        }
        return UserDefaults.standard.string(forKey: keyPrefix + key)
    }

    static func delete(_ key: String) {
        if isRunningTests {
            testStore.removeValue(forKey: key)
            return
        }
        UserDefaults.standard.removeObject(forKey: keyPrefix + key)
    }
}
