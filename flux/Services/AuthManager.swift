import Foundation
import Combine
import OSLog
#if os(macOS)
import AppKit
#endif

/// Account identity via PocketBase (email/password); library data via PocketBase user_data collection.
class AuthManager: ObservableObject {
    static let shared = AuthManager()

    @Published var currentUser: User?
    @Published var isAuthenticated = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastSyncDate: Date?
    @Published private(set) var isGuestMode = false
    @Published var isLoadingMessage = "Loading…"

    private let client = PocketBaseClient.shared

    private static let guestModeKey = "flux.authGuestMode"
    private static let userDisplayNameKey = "flux.authDisplayName"

    /// ID of the existing user_data record (for PATCH vs POST).
    private var userDataRecordID: String?

    static var isConfigured: Bool {
        !(AppConfig.baseURL.host ?? "").contains("YOUR-SUBDOMAIN")
    }

    var needsGate: Bool {
        Self.isConfigured && !isAuthenticated && !isGuestMode
    }

    // MARK: - Init

    private init() {
        // Restore session from Keychain on launch
        if Self.isConfigured, KeychainManager.hasSession(),
           let uid = KeychainManager.getUserID() {
            let email = KeychainManager.getEmail()
            let name = KeychainManager.getDisplayName()
            self.currentUser = User(
                id: uid,
                email: email,
                displayName: name,
                photoURL: nil
            )
            self.isAuthenticated = true
        } else if UserDefaults.standard.bool(forKey: Self.guestModeKey) {
            self.isGuestMode = true
        }
    }

    // MARK: - Guest Mode

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
            DispatchQueue.main.async { perform() }
        }
    }

    // MARK: - Email/Password Sign-In

    @MainActor
    func signIn(email: String, password: String) async -> Bool {
        self.isLoading = true
        self.isLoadingMessage = "Signing in…"
        self.errorMessage = nil

        do {
            let result = try await client.authWithPassword(email: email, password: password)

            let displayName = result.record.name ?? email.components(separatedBy: "@").first
            KeychainManager.saveSession(
                token: result.token,
                userID: result.record.id,
                email: result.record.email,
                displayName: displayName,
                avatarURL: result.record.avatar
            )

            UserDefaults.standard.removeObject(forKey: Self.guestModeKey)

            self.currentUser = User(
                id: result.record.id,
                email: result.record.email,
                displayName: displayName,
                photoURL: result.record.avatar.flatMap(URL.init(string:))
            )
            self.isAuthenticated = true
            self.isGuestMode = false

            if let remote = try? await client.fetchData(token: result.token, userID: result.record.id) {
                self.userDataRecordID = remote.id
                ProfileManager.shared.applyCloudProfilesData(remote.payload["profiles"] as? [[String: Any]])
                if !ProfileManager.shared.profiles.isEmpty {
                    if ProfileManager.shared.currentProfile != nil {
                        ProfileManager.shared.switchToProfileSelection()
                    }
                } else {
                    ProfileManager.shared.ensureDefaultProfile(name: displayName ?? "User")
                }
                self.isLoading = false
                Task { await syncNowInternal(pullFirst: true, forcePull: true) }
            } else {
                ProfileManager.shared.ensureDefaultProfile(name: displayName ?? "User")
                self.isLoading = false
                Task { await syncNowInternal(pullFirst: true, forcePull: false) }
            }

            Logger.auth.info("Sign-in succeeded for \(email)")
            return true
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
            return false
        }
    }

    // MARK: - Sign-Up

    @MainActor
    func signUp(email: String, password: String, displayName: String?) async -> Bool {
        self.isLoading = true
        self.isLoadingMessage = "Creating account…"
        self.errorMessage = nil

        do {
            let result = try await client.signUp(email: email, password: password, displayName: displayName)

            let name = displayName ?? email.components(separatedBy: "@").first
            KeychainManager.saveSession(
                token: result.token,
                userID: result.record.id,
                email: result.record.email,
                displayName: name,
                avatarURL: result.record.avatar
            )

            UserDefaults.standard.removeObject(forKey: Self.guestModeKey)

            self.currentUser = User(
                id: result.record.id,
                email: result.record.email,
                displayName: name,
                photoURL: result.record.avatar.flatMap(URL.init(string:))
            )
            self.isAuthenticated = true
            self.isGuestMode = false

            ProfileManager.shared.ensureDefaultProfile(name: name ?? "User")
            self.isLoading = false
            Task { await syncNowInternal(pullFirst: true, forcePull: false) }

            Logger.auth.info("Sign-up succeeded for \(email)")
            return true
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
            return false
        }
    }

    // MARK: - Sign Out

    func signOut() {
        autoSyncTask?.cancel()
        autoSyncTask = nil
        KeychainManager.clearSession()
        UserDefaults.standard.removeObject(forKey: Self.guestModeKey)
        UserDefaults.standard.removeObject(forKey: UserDefaults.Key.cloudLastSyncAt)
        UserDefaults.standard.removeObject(forKey: UserDefaults.Key.tmdbApiKey)
        UserDefaults.standard.removeObject(forKey: Self.userDisplayNameKey)
        UserDefaults.standard.removeObject(forKey: "flux.hasExplicitlyCustomizedName")
        self.currentUser = nil
        self.isAuthenticated = false
        self.isGuestMode = false
        self.lastSyncDate = nil
        self.userDataRecordID = nil

        ProfileManager.shared.handleSignOut()
        UserDataService.shared.handleSignOut()
        TasteProfileManager.shared.handleSignOut()
        AddonManager.shared.resetToStockAddons()
        PlayerManager.shared.handleSignOut()
        RecentSearchManager.shared.clear()
        Task { await SearchEngine.shared.clearUserIndex() }
        NotificationCenter.default.post(name: .fluxRefresh, object: nil)
    }

    // MARK: - Library Sync

    private var autoSyncTask: Task<Void, Never>?

    func scheduleAutoSync(delay: TimeInterval = 2.0) {
        guard isAuthenticated, Self.isConfigured else { return }
        autoSyncTask?.cancel()
        autoSyncTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self.syncNowInternal(pullFirst: false)
            } catch { }
        }
    }

    func syncOnLaunch() {
        // TEMP-DIAGNOSTIC (missing profiles): trace sync gating on error channel.
        Logger.auth.error("DIAG syncOnLaunch: authed=\(self.isAuthenticated, privacy: .public) configured=\(Self.isConfigured, privacy: .public) hasToken=\(KeychainManager.getToken() != nil, privacy: .public) hasUserID=\(KeychainManager.getUserID() != nil, privacy: .public) profiles=\(ProfileManager.shared.profiles.count)")
        guard isAuthenticated, Self.isConfigured else { return }
        Task { await syncNowInternal(pullFirst: true) }
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
        // TEMP-DIAGNOSTIC (missing profiles).
        Logger.auth.error("DIAG syncNowInternal: pullFirst=\(pullFirst, privacy: .public) forcePull=\(forcePull, privacy: .public) hasToken=\(KeychainManager.getToken() != nil, privacy: .public)")
        guard let token = KeychainManager.getToken(),
              let userID = KeychainManager.getUserID() else {
            Logger.auth.error("DIAG syncNowInternal: ABORTED (no token/userID)")
            return
        }
        // Mixed-session guard: concurrent processes/sign-ins can interleave
        // Keychain writes, pairing one account's token with another's userID.
        // Syncing (and especially POSTing) under a mismatched identity creates
        // duplicates under the wrong filter and applies foreign payloads. Abort;
        // a clean sign-out/in heals it. Never auto-sign-out (destructive).
        guard PocketBaseClient.recordID(in: token) == userID else {
            Logger.auth.error("DIAG syncNowInternal: ABORTED (token identity does not match stored userID — sign out/in to heal)")
            return
        }
        do {
            var pulledNewer = false
            var hasLocalAdditionsToPush = false

            // TEMP-DIAGNOSTIC (missing profiles): distinguish fetch-miss vs throw.
            var remote: (id: String, payload: [String: Any], updatedAt: Double)?
            var fetchError: String?
            if pullFirst {
                do {
                    remote = try await client.fetchData(token: token, userID: userID)
                } catch {
                    fetchError = error.localizedDescription
                }
                Logger.auth.error("DIAG pull: found=\(remote != nil, privacy: .public) err=\(fetchError ?? "none", privacy: .public) cloudProfiles=\((remote?.payload["profiles"] as? [[String: Any]])?.count ?? -1) localProfiles=\(ProfileManager.shared.profiles.count)")
            }
            if pullFirst, let remote = remote {
                self.userDataRecordID = remote.id
                let lastSync = UserDefaults.standard.double(forKey: UserDefaults.Key.cloudLastSyncAt)
                if forcePull || remote.updatedAt > lastSync {
                    // Fresh-enough remote: safe to adopt its profiles list.
                    // Stale pulls still merge library data but never replace profiles.
                    hasLocalAdditionsToPush = UserDataService.shared.applyCloudPayload(remote.payload, replaceProfiles: forcePull || remote.updatedAt > lastSync)
                    UserDefaults.standard.set(remote.updatedAt, forKey: UserDefaults.Key.cloudLastSyncAt)
                    Logger.auth.info("Cloud library pulled (\(remote.updatedAt))")
                    pulledNewer = true
                }
            }

            if pulledNewer && !forcePull && !hasLocalAdditionsToPush {
                await MainActor.run { self.lastSyncDate = Date() }
                return
            }

            let payload = UserDataService.shared.exportCloudPayload()
            let now = Date().timeIntervalSince1970
            let newRecordID = try await client.pushData(
                token: token,
                userID: userID,
                payload: payload,
                updatedAt: now,
                existingRecordID: userDataRecordID
            )
            if let id = newRecordID { self.userDataRecordID = id }
            UserDefaults.standard.set(now, forKey: UserDefaults.Key.cloudLastSyncAt)
            await MainActor.run { self.lastSyncDate = Date() }
            Logger.auth.info("Cloud library pushed (\(now))")
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
        KeychainManager.saveSession(
            token: KeychainManager.getToken() ?? "",
            userID: currentUser?.id ?? "",
            email: currentUser?.email,
            displayName: clean,
            avatarURL: currentUser?.photoURL?.absoluteString
        )
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

    // MARK: - Token (for backward compatibility with callers)

    var authToken: String? { KeychainManager.getToken() }
}
