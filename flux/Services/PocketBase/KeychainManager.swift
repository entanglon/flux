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
        KeychainStore.set(token, forKey: tokenKey)
    }

    static func saveUser(id: String, email: String?, displayName: String?, avatarURL: String?) {
        KeychainStore.set(id, forKey: userIDKey)
        if let email { KeychainStore.set(email, forKey: emailKey) }
        if let name = displayName, !name.isEmpty { KeychainStore.set(name, forKey: displayNameKey) }
        if let avatar = avatarURL, !avatar.isEmpty { KeychainStore.set(avatar, forKey: avatarURLKey) }
    }

    static func saveSession(token: String, userID: String, email: String?, displayName: String?, avatarURL: String?) {
        saveToken(token)
        saveUser(id: userID, email: email, displayName: displayName, avatarURL: avatarURL)
    }

    // MARK: - Read

    static func getToken() -> String? {
        let token = KeychainStore.get(tokenKey)
        return (token?.isEmpty == false) ? token : nil
    }

    static func getUserID() -> String? {
        KeychainStore.get(userIDKey)
    }

    static func getEmail() -> String? {
        KeychainStore.get(emailKey)
    }

    static func getDisplayName() -> String? {
        KeychainStore.get(displayNameKey)
    }

    static func getAvatarURL() -> String? {
        KeychainStore.get(avatarURLKey)
    }

    static func hasSession() -> Bool {
        getToken() != nil && getUserID() != nil
    }

    // MARK: - Delete

    static func clearSession() {
        KeychainStore.delete(tokenKey)
        KeychainStore.delete(userIDKey)
        KeychainStore.delete(emailKey)
        KeychainStore.delete(displayNameKey)
        KeychainStore.delete(avatarURLKey)
    }
}
