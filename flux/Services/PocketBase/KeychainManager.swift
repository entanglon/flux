import Foundation

/// Manages PocketBase auth token and user record persistence in the macOS Keychain.
enum KeychainManager {
    private static let tokenKey = "pb.authToken"
    private static let userIDKey = "pb.userID"
    private static let emailKey = "pb.email"
    private static let displayNameKey = "pb.displayName"
    private static let avatarURLKey = "pb.avatarURL"

    // MARK: - Save

    static func saveToken(_ token: String) {
        cachedWrite(tokenKey, value: token)
    }

    static func saveUser(id: String, email: String?, displayName: String?, avatarURL: String?) {
        cachedWrite(userIDKey, value: id)
        if let email { cachedWrite(emailKey, value: email) }
        if let name = displayName, !name.isEmpty { cachedWrite(displayNameKey, value: name) }
        if let avatar = avatarURL, !avatar.isEmpty { cachedWrite(avatarURLKey, value: avatar) }
    }

    static func saveSession(token: String, userID: String, email: String?, displayName: String?, avatarURL: String?) {
        saveToken(token)
        saveUser(id: userID, email: email, displayName: displayName, avatarURL: avatarURL)
    }

    // MARK: - Read

    static func getToken() -> String? {
        let token = cachedRead(tokenKey)
        return (token?.isEmpty == false) ? token : nil
    }

    // In-memory session cache: every Keychain read can trigger a macOS auth
    // prompt when the accessing build signature differs from the storing one
    // (unsigned rebuilds!), so read each secret from the Keychain at most once
    // per launch. Misses are NOT cached (absence must stay observable).
    // Note: a second concurrent process writing sessions can leave this stale
    // until relaunch — acceptable; run a single app instance.
    private static let cacheLock = NSLock()
    private static var memoryCache: [String: String] = [:]

    private static func cachedRead(_ key: String) -> String? {
        cacheLock.lock()
        if let hit = memoryCache[key] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()
        guard let value = KeychainStore.get(key) else { return nil }
        cacheLock.lock()
        memoryCache[key] = value
        cacheLock.unlock()
        return value
    }

    private static func cachedWrite(_ key: String, value: String) {
        KeychainStore.set(value, forKey: key)
        cacheLock.lock()
        memoryCache[key] = value
        cacheLock.unlock()
    }

    private static func cachedDelete(_ key: String) {
        KeychainStore.delete(key)
        cacheLock.lock()
        memoryCache.removeValue(forKey: key)
        cacheLock.unlock()
    }

    static func getUserID() -> String? {
        cachedRead(userIDKey)
    }

    static func getEmail() -> String? {
        cachedRead(emailKey)
    }

    static func getDisplayName() -> String? {
        cachedRead(displayNameKey)
    }

    static func getAvatarURL() -> String? {
        cachedRead(avatarURLKey)
    }

    static func hasSession() -> Bool {
        getToken() != nil && getUserID() != nil
    }

    // MARK: - Delete

    static func clearSession() {
        for key in [tokenKey, userIDKey, emailKey, displayNameKey, avatarURLKey] {
            cachedDelete(key)
        }
    }
}
