import Foundation
import Combine
import SwiftUI

/// Manages parental lock PIN security for Kids watching profile protection.
/// The PIN is strictly stored locally in the hardware Keychain and is never synced to the cloud.
final class ParentalLockManager: ObservableObject {
    static let shared = ParentalLockManager()

    private let pinKeychainKey = "flux.parentalPin"
    private let maxAttempts = 5
    private let lockoutDuration: TimeInterval = 30.0

    @Published private(set) var hasPin: Bool = false
    @Published private(set) var isLockedOut: Bool = false
    @Published private(set) var remainingLockoutSeconds: Int = 0

    private var failedAttempts: Int = 0
    private var lockoutUntil: Date? = nil
    private var lockoutTimer: AnyCancellable?

    init() {
        refreshState()
    }

    private func keychainKey(for profileId: UUID?) -> String {
        if let id = profileId {
            return "flux.pin.\(id.uuidString.lowercased())"
        }
        return pinKeychainKey
    }

    func hasPin(for profileId: UUID? = nil) -> Bool {
        let key = keychainKey(for: profileId)
        if let stored = KeychainStore.get(key), !stored.isEmpty {
            return true
        }
        return false
    }

    func refreshState() {
        if let storedPin = KeychainStore.get(pinKeychainKey), !storedPin.isEmpty {
            hasPin = true
        } else {
            hasPin = false
        }
        checkLockout()
    }

    /// Sets or updates the 4-digit PIN for a profile (or master exit PIN if profileId is nil).
    @discardableResult
    func setPin(_ pin: String, for profileId: UUID? = nil) -> Bool {
        let trimmed = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 4, trimmed.allSatisfy({ $0.isNumber }) else {
            return false
        }
        let key = keychainKey(for: profileId)
        KeychainStore.set(trimmed, forKey: key)
        // If setting for a profile and no master exit PIN exists yet, also set as master exit PIN fallback
        if profileId != nil && KeychainStore.get(pinKeychainKey) == nil {
            KeychainStore.set(trimmed, forKey: pinKeychainKey)
        }
        resetAttempts()
        refreshState()
        return true
    }

    /// Removes the PIN from Keychain for a profile (or master if nil).
    @discardableResult
    func removePin(for profileId: UUID? = nil) -> Bool {
        let key = keychainKey(for: profileId)
        KeychainStore.delete(key)
        resetAttempts()
        refreshState()
        return true
    }

    /// Verifies the given 4-digit PIN against the Keychain for a profile (falling back to master PIN).
    func verify(pin: String, for profileId: UUID? = nil) -> Bool {
        if checkLockout() {
            return false
        }

        let key = keychainKey(for: profileId)
        var storedPin = KeychainStore.get(key)
        if storedPin == nil || storedPin?.isEmpty == true {
            // Fallback to master parental PIN if target profile has no unique PIN
            storedPin = KeychainStore.get(pinKeychainKey)
        }

        guard let targetPin = storedPin, !targetPin.isEmpty else {
            // No PIN is set; action is allowed
            return true
        }

        if pin == targetPin {
            resetAttempts()
            return true
        } else {
            recordFailedAttempt()
            return false
        }
    }

    private func recordFailedAttempt() {
        failedAttempts += 1
        if failedAttempts >= maxAttempts {
            lockoutUntil = Date().addingTimeInterval(lockoutDuration)
            isLockedOut = true
            remainingLockoutSeconds = Int(lockoutDuration)
            startLockoutTimer()
        }
    }

    private func resetAttempts() {
        failedAttempts = 0
        lockoutUntil = nil
        isLockedOut = false
        remainingLockoutSeconds = 0
        lockoutTimer?.cancel()
        lockoutTimer = nil
    }

    @discardableResult
    func checkLockout() -> Bool {
        guard let lockout = lockoutUntil else {
            isLockedOut = false
            remainingLockoutSeconds = 0
            return false
        }
        let remaining = lockout.timeIntervalSinceNow
        if remaining <= 0 {
            resetAttempts()
            return false
        } else {
            isLockedOut = true
            remainingLockoutSeconds = Int(ceil(remaining))
            return true
        }
    }

    private func startLockoutTimer() {
        lockoutTimer?.cancel()
        lockoutTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                if !self.checkLockout() {
                    self.lockoutTimer?.cancel()
                    self.lockoutTimer = nil
                }
            }
    }
}
