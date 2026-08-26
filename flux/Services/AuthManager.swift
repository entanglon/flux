import Foundation
import Combine

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
        if Self.isConfigured, let token = UserDefaults.standard.string(forKey: Self.tokenKey),
           let uid = UserDefaults.standard.string(forKey: Self.userUIDKey),
           let email = UserDefaults.standard.string(forKey: Self.userEmailKey) {
            DispatchQueue.main.async {
                self.currentUser = User(id: uid, email: email, displayName: email.components(separatedBy: "@").first)
                self.isAuthenticated = true
                self.isGuestMode = false
            }
        } else if UserDefaults.standard.bool(forKey: Self.guestModeKey) {
            self.isGuestMode = true
        }
    }

    private func makeUser(uid: String, email: String) -> User {
        User(id: uid, email: email, displayName: email.components(separatedBy: "@").first)
    }

    // MARK: - Token

    var authToken: String? {
        UserDefaults.standard.string(forKey: Self.tokenKey)
    }

    private func saveSession(_ resp: FluxAuthResponse) {
        UserDefaults.standard.set(resp.token, forKey: Self.tokenKey)
        UserDefaults.standard.set(resp.uid, forKey: Self.userUIDKey)
        UserDefaults.standard.set(resp.email, forKey: Self.userEmailKey)
    }

    private func clearSession() {
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

    func syncOnLogin() {
        Task { await syncNowInternal(pullFirst: true) }
    }

    func syncNow() {
        Task { await syncNowInternal(pullFirst: true) }
    }

    private func syncNowInternal(pullFirst: Bool) async {
        guard let token = authToken else { return }
        do {
            if pullFirst, let remote = try await client.fetchData(token: token) {
                let lastSync = UserDefaults.standard.double(forKey: "cloudLastSyncAt")
                if remote.updatedAt > lastSync {
                    await UserDataService.shared.applyCloudPayload(remote.payload)
                    print("[Auth] Cloud library pulled (\(remote.updatedAt))")
                }
            }

            _ = try await client.pushData(
                token: token,
                payload: UserDataService.shared.exportCloudPayload(),
                updatedAt: Date().timeIntervalSince1970
            )
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "cloudLastSyncAt")
            await MainActor.run { self.lastSyncDate = Date() }
        } catch {
            print("[Auth] Sync failed:", error.localizedDescription)
        }
    }
}
