import Foundation
import Security

/// Minimal Keychain wrapper for session secrets.
enum KeychainStore {
    private static let service = (Bundle.main.bundleIdentifier ?? "flux.app.cloud") + ".auth"

    private static let legacyServices = [
        "com.kernelmoth.flux.auth",
        "com.nemesys.flux.auth",
        "flux.app.cloud.auth"
    ]

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
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func get(_ key: String) -> String? {
        if isRunningTests {
            return testStore[key]
        }
        if let current = readItem(key: key, serviceName: service) {
            return current
        }
        for legacy in legacyServices where legacy != service {
            if let found = readItem(key: key, serviceName: legacy) {
                set(found, forKey: key) // migrate to current service
                return found
            }
        }
        return nil
    }

    private static func readItem(key: String, serviceName: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        if isRunningTests {
            testStore.removeValue(forKey: key)
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
