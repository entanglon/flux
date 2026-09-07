import Foundation
import Combine
import OSLog
#if os(macOS)
import AppKit
#endif

/// Account identity via Cloudflare Worker native auth; library data via Worker D1.
/// Worker owns credentials (PBKDF2 hashing, HMAC-signed JWTs, throttling).
class AuthManager: ObservableObject {
    static let shared = AuthManager()

    @Published var currentUser: User?
    @Published var isAuthenticated = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastSyncDate: Date?
    /// Guest mode = local-only by choice; skips the auth gate.
    @Published private(set) var isGuestMode = false

    private let client = FluxCloudClient.shared

    private static let guestModeKey = "flux.authGuestMode"
    private static let tokenKey = "flux.authToken"
    private static let userUIDKey = "flux.authUID"
    private static let userEmailKey = "flux.authEmail"
    private static let userDisplayNameKey = "flux.authDisplayName"

    static var isConfigured: Bool {
        !(FluxCloudConfig.baseURL.host ?? "").contains("YOUR-SUBDOMAIN")
    }

    /// Show the first-start identity gate? (Skipped entirely when the backend
    /// isn't configured — dev fallback.)
    var needsGate: Bool {
        Self.isConfigured && !isAuthenticated && !isGuestMode
    }

    func continueAsGuest() {
        UserDefaults.standard.set(true, forKey: Self.guestModeKey)
        if Thread.isMainThread {
            self.isGuestMode = true
            ProfileManager.shared.ensureGuestProfile()
        } else {
            DispatchQueue.main.async {
                self.isGuestMode = true
                ProfileManager.shared.ensureGuestProfile()
            }
        }
    }

    func startSignInFlow() {
        UserDefaults.standard.removeObject(forKey: Self.guestModeKey)
        let perform = {
            self.isGuestMode = false
            #if os(macOS)
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows {
                let id = window.identifier?.rawValue ?? ""
                let autosave = window.frameAutosaveName
                let title = window.title.lowercased()
                if id.contains("Settings") || autosave.contains("Settings") || title.contains("settings") || title.contains("general") || title.contains("preferences") {
                    window.close()
                } else if window.canBecomeMain {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            #endif
        }
        if Thread.isMainThread {
            perform()
        } else {
            DispatchQueue.main.async {
                perform()
            }
        }
    }

    private init() {
        let token: String? = {
            if let secureToken = KeychainStore.get(Self.tokenKey), !secureToken.isEmpty {
                return secureToken
            }
            // Seamless backward-compatible migration from legacy UserDefaults
            if let legacyToken = UserDefaults.standard.string(forKey: Self.tokenKey), !legacyToken.isEmpty {
                KeychainStore.set(legacyToken, forKey: Self.tokenKey)
                UserDefaults.standard.removeObject(forKey: Self.tokenKey)
                return legacyToken
            }
            return nil
        }()

        if Self.isConfigured, token != nil,
           let uid = UserDefaults.standard.string(forKey: Self.userUIDKey),
           let email = UserDefaults.standard.string(forKey: Self.userEmailKey) {
            // Set synchronously — init() runs on the main thread before any
            // @StateObject observation begins, so this is safe and prevents
            // AuthGateView from flashing for one frame on startup.
            let savedName = UserDefaults.standard.string(forKey: Self.userDisplayNameKey)
            let name = (savedName?.isEmpty == false && savedName != "Default" && savedName != "Guest") ? savedName : email.components(separatedBy: "@").first
            self.currentUser = User(id: uid, email: email, displayName: name)
            self.isAuthenticated = true
            self.isGuestMode = false
        } else if UserDefaults.standard.bool(forKey: Self.guestModeKey) {
            self.isGuestMode = true
        }
    }

    private func makeUser(uid: String, email: String, displayName: String? = nil) -> User {
        let name = displayName ?? email.components(separatedBy: "@").first
        return User(id: uid, email: email, displayName: name)
    }

    // MARK: - Token

    var authToken: String? {
        if let token = KeychainStore.get(Self.tokenKey), !token.isEmpty {
            return token
        }
        if let legacy = UserDefaults.standard.string(forKey: Self.tokenKey), !legacy.isEmpty {
            KeychainStore.set(legacy, forKey: Self.tokenKey)
            UserDefaults.standard.removeObject(forKey: Self.tokenKey)
            return legacy
        }
        return nil
    }

    private func saveSession(_ resp: FluxAuthResponse, displayName: String? = nil) {
        KeychainStore.set(resp.token, forKey: Self.tokenKey)
        UserDefaults.standard.removeObject(forKey: Self.tokenKey) // Ensure plaintext copy is purged
        UserDefaults.standard.set(resp.uid, forKey: Self.userUIDKey)
        UserDefaults.standard.set(resp.email, forKey: Self.userEmailKey)
        if let name = displayName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name != "Default", name != "Guest" {
            UserDefaults.standard.set(name, forKey: Self.userDisplayNameKey)
        }
    }

    private func clearSession() {
        KeychainStore.delete(Self.tokenKey)
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        UserDefaults.standard.removeObject(forKey: Self.userUIDKey)
        UserDefaults.standard.removeObject(forKey: Self.userEmailKey)
        UserDefaults.standard.removeObject(forKey: Self.userDisplayNameKey)
    }

    // MARK: - Auth actions

    func signIn(email: String, password: String) async -> Bool {
        await MainActor.run {
            self.isLoading = true
            self.errorMessage = nil
        }
        do {
            let resp = try await client.signIn(email: email, password: password)
            let savedName = UserDefaults.standard.string(forKey: Self.userDisplayNameKey)
            let finalName = (savedName?.isEmpty == false && savedName != "Default" && savedName != "Guest") ? savedName! : (resp.email.components(separatedBy: "@").first ?? "User")
            saveSession(resp, displayName: finalName)
            UserDefaults.standard.removeObject(forKey: Self.guestModeKey)
            await MainActor.run {
                self.currentUser = self.makeUser(uid: resp.uid, email: resp.email, displayName: finalName)
                self.isAuthenticated = true
                self.isGuestMode = false
            }
            // Quick cloud pull — profiles only, skip heavy library merge.
            // Library syncs in the background so the UI appears instantly.
            if let token = authToken, let remote = try? await client.fetchData(token: token) {
                await MainActor.run {
                    ProfileManager.shared.applyCloudProfilesData(remote.payload["profiles"] as? [[String: Any]])
                    if !ProfileManager.shared.profiles.isEmpty {
                        if ProfileManager.shared.currentProfile != nil {
                            ProfileManager.shared.switchToProfileSelection()
                        }
                    } else {
                        let resolvedName = self.currentUser?.displayName ?? finalName
                        ProfileManager.shared.ensureDefaultProfile(name: resolvedName)
                    }
                    self.isLoading = false
                }
                // Full library sync in background — no UI blocking
                Task { await syncNowInternal(pullFirst: true, forcePull: true) }
            } else {
                await MainActor.run {
                    let resolvedName = self.currentUser?.displayName ?? finalName
                    ProfileManager.shared.ensureDefaultProfile(name: resolvedName)
                    self.isLoading = false
                }
            }
            return true
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
            return false
        }
    }

    func signUp(email: String, password: String, displayName: String? = nil) async -> Bool {
        await MainActor.run {
            self.isLoading = true
            self.errorMessage = nil
        }
        do {
            let resp = try await client.signUp(email: email, password: password)
            let cleanName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalName = (cleanName?.isEmpty == false && cleanName != "Default" && cleanName != "Guest") ? cleanName! : (resp.email.components(separatedBy: "@").first ?? "User")
            // Clean slate for new account: guarantee no leftover API keys, old history, or third-party addons
            UserDefaults.standard.removeObject(forKey: UserDefaults.Key.tmdbApiKey)
            UserDefaults.standard.removeObject(forKey: "localHistoryDataStremio")
            UserDefaults.standard.removeObject(forKey: "localWatchlistDataStremio")
            UserDefaults.standard.removeObject(forKey: "localCollectionsData")
            UserDefaults.standard.removeObject(forKey: "globalEpisodeProgress")
            UserDataService.shared.watchlist = []
            UserDataService.shared.history = []
            UserDataService.shared.collections = []
            TasteProfileManager.shared.handleSignOut()
            AddonManager.shared.resetToStockAddons()
            RecentSearchManager.shared.clear()

            saveSession(resp, displayName: finalName)
            UserDefaults.standard.set("true", forKey: "flux.hasExplicitlyCustomizedName")
            UserDefaults.standard.removeObject(forKey: Self.guestModeKey)
            await MainActor.run {
                self.currentUser = self.makeUser(uid: resp.uid, email: resp.email, displayName: finalName)
                self.isAuthenticated = true
                self.isGuestMode = false
                // New account: single profile expected — create it now so the
                // gate never shows "Create Your Profile".
                ProfileManager.shared.ensureDefaultProfile(name: finalName)
                self.isLoading = false
            }
            // Push to cloud in background — no UI blocking
            Task { await syncNowInternal(pullFirst: true, forcePull: false) }
            return true
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
            return false
        }
    }

    func signOut() {
        autoSyncTask?.cancel()
        autoSyncTask = nil
        clearSession()
        UserDefaults.standard.removeObject(forKey: Self.guestModeKey)
        UserDefaults.standard.removeObject(forKey: UserDefaults.Key.cloudLastSyncAt)
        UserDefaults.standard.removeObject(forKey: UserDefaults.Key.tmdbApiKey)
        UserDefaults.standard.removeObject(forKey: "flux.authDisplayName")
        UserDefaults.standard.removeObject(forKey: "flux.hasExplicitlyCustomizedName")
        self.currentUser = nil
        self.isAuthenticated = false
        self.isGuestMode = false
        self.lastSyncDate = nil
        
        ProfileManager.shared.handleSignOut()
        UserDataService.shared.handleSignOut()
        TasteProfileManager.shared.handleSignOut()
        AddonManager.shared.resetToStockAddons()
        PlayerManager.shared.handleSignOut()
        RecentSearchManager.shared.clear()
        Task { await SearchEngine.shared.clearUserIndex() }
        NotificationCenter.default.post(name: .fluxRefresh, object: nil)
    }

    // MARK: - Library sync

    private var autoSyncTask: Task<Void, Never>?

    /// Schedules a debounced sync after state changes (e.g. watchlist, history, collections, taste signals).
    func scheduleAutoSync(delay: TimeInterval = 2.0) {
        guard isAuthenticated, Self.isConfigured else { return }
        autoSyncTask?.cancel()
        autoSyncTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self.syncNowInternal(pullFirst: false)
            } catch {
                // Task cancelled
            }
        }
    }

    /// Called on app startup for authenticated users.
    func syncOnLaunch() {
        guard isAuthenticated, Self.isConfigured else { return }
        Task {
            await syncNowInternal(pullFirst: true)
        }
    }

    func syncOnLogin() {
        Task { await syncNowInternal(pullFirst: true, forcePull: false) }
    }

    func syncNow(forcePull: Bool = false) {
        Task { await syncNowInternal(pullFirst: true, forcePull: forcePull) }
    }

    func syncNowAsync(forcePull: Bool = true) async {
        await syncNowInternal(pullFirst: true, forcePull: forcePull)
    }

    private func syncNowInternal(pullFirst: Bool, forcePull: Bool = false) async {
        guard let token = authToken else { return }
        do {
            var pulledNewer = false
            var hasLocalAdditionsToPush = false
            if pullFirst, let remote = try await client.fetchData(token: token) {
                let lastSync = UserDefaults.standard.double(forKey: UserDefaults.Key.cloudLastSyncAt)
                if forcePull || remote.updatedAt > lastSync {
                    hasLocalAdditionsToPush = UserDataService.shared.applyCloudPayload(remote.payload)
                    UserDefaults.standard.set(remote.updatedAt, forKey: UserDefaults.Key.cloudLastSyncAt)
                    Logger.auth.info("Cloud library pulled (\(remote.updatedAt))")
                    pulledNewer = true
                }
            }

            // If we pulled newer data from cloud, only skip push if local had NO extra additions
            // and push is not forced.
            if pulledNewer && !forcePull && !hasLocalAdditionsToPush {
                await MainActor.run { self.lastSyncDate = Date() }
                return
            }

            let payload = UserDataService.shared.exportCloudPayload()
            let now = Date().timeIntervalSince1970
            _ = try await client.pushData(
                token: token,
                payload: payload,
                updatedAt: now
            )
            UserDefaults.standard.set(now, forKey: UserDefaults.Key.cloudLastSyncAt)
            await MainActor.run { self.lastSyncDate = Date() }
            Logger.auth.info("Cloud library pushed successfully (\(now))")
        } catch {
            Logger.auth.error("Sync failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Display Name Management

    func updateDisplayName(_ newName: String) {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != "Default", clean != "Guest" else { return }
        UserDefaults.standard.set(clean, forKey: Self.userDisplayNameKey)
        UserDefaults.standard.set("true", forKey: "flux.hasExplicitlyCustomizedName")
        if let user = currentUser {
            self.currentUser = User(id: user.id, email: user.email, displayName: clean, photoURL: user.photoURL, creationDate: user.creationDate)
        }
        if let current = ProfileManager.shared.currentProfile {
            ProfileManager.shared.updateProfile(current, name: clean, avatarID: current.avatarID)
        } else if let first = ProfileManager.shared.profiles.first {
            ProfileManager.shared.updateProfile(first, name: clean, avatarID: first.avatarID)
        }
        scheduleAutoSync(delay: 0.5)
    }

    var needsDisplayNamePrompt: Bool {
        guard isAuthenticated, let user = currentUser else { return false }
        guard let name = user.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, name != "Default", name != "Guest" else { return true }
        if let emailPrefix = user.email?.components(separatedBy: "@").first, name.lowercased() == emailPrefix.lowercased() {
            return UserDefaults.standard.string(forKey: "flux.hasExplicitlyCustomizedName") != "true"
        }
        return false
    }

    func markDisplayNameAsCustomized() {
        UserDefaults.standard.set("true", forKey: "flux.hasExplicitlyCustomizedName")
    }
}
