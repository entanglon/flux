import Foundation
import Combine
import OSLog

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
        DispatchQueue.main.async { self.isGuestMode = true }
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
            self.currentUser = User(id: uid, email: email, displayName: email.components(separatedBy: "@").first)
            self.isAuthenticated = true
            self.isGuestMode = false
        } else if UserDefaults.standard.bool(forKey: Self.guestModeKey) {
            self.isGuestMode = true
        }
    }

    private func makeUser(uid: String, email: String) -> User {
        User(id: uid, email: email, displayName: email.components(separatedBy: "@").first)
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

    private func saveSession(_ resp: FluxAuthResponse) {
        KeychainStore.set(resp.token, forKey: Self.tokenKey)
        UserDefaults.standard.removeObject(forKey: Self.tokenKey) // Ensure plaintext copy is purged
        UserDefaults.standard.set(resp.uid, forKey: Self.userUIDKey)
        UserDefaults.standard.set(resp.email, forKey: Self.userEmailKey)
    }

    private func clearSession() {
        KeychainStore.delete(Self.tokenKey)
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        UserDefaults.standard.removeObject(forKey: Self.userUIDKey)
        UserDefaults.standard.removeObject(forKey: Self.userEmailKey)
    }

    // MARK: - Auth actions

    func signIn(email: String, password: String) async -> Bool {
        await MainActor.run {
            self.isLoading = true
            self.errorMessage = nil
        }
        do {
            let resp = try await client.signIn(email: email, password: password)
            saveSession(resp)
            await MainActor.run {
                self.currentUser = self.makeUser(uid: resp.uid, email: resp.email)
                self.isAuthenticated = true
                self.isLoading = false
            }
            await syncOnLogin()
            return true
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
            return false
        }
    }

    func signUp(email: String, password: String) async -> Bool {
        await MainActor.run {
            self.isLoading = true
            self.errorMessage = nil
        }
        do {
            let resp = try await client.signUp(email: email, password: password)
            saveSession(resp)
            await MainActor.run {
                self.currentUser = self.makeUser(uid: resp.uid, email: resp.email)
                self.isAuthenticated = true
                self.isLoading = false
            }
            await syncOnLogin()
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
        clearSession()
        UserDefaults.standard.removeObject(forKey: Self.guestModeKey)
        self.currentUser = nil
        self.isAuthenticated = false
        self.isGuestMode = false
        self.lastSyncDate = nil
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
            if pullFirst, let remote = try await client.fetchData(token: token) {
                let lastSync = UserDefaults.standard.double(forKey: UserDefaults.Key.cloudLastSyncAt)
                if forcePull || remote.updatedAt > lastSync {
                    await UserDataService.shared.applyCloudPayload(remote.payload)
                    UserDefaults.standard.set(remote.updatedAt, forKey: UserDefaults.Key.cloudLastSyncAt)
                    Logger.auth.info("Cloud library pulled (\(remote.updatedAt))")
                }
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
}
