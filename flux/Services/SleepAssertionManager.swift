import Foundation
import IOKit.pwr_mgt

/// Manages macOS power assertions during active video playback so that the display
/// and system do not sleep while the user is watching content in Flux or PiP,
/// and prevents macOS App Nap from throttling the player process.
final class SleepAssertionManager {
    static let shared = SleepAssertionManager()
    
    private var displayAssertionID: IOPMAssertionID = 0
    private var isDisplayAsserted = false
    private var playbackActivityToken: NSObjectProtocol?
    private var playerActiveToken: NSObjectProtocol?
    private let lock = NSLock()
    
    private init() {}
    
    /// Called when PlayerView opens or enters PiP. Ensures process latency and thread responsiveness
    /// are maintained (preventing App Nap even if paused or occluded by another window).
    func playerDidOpen(reason: String = "Flux Player Active") {
        lock.lock()
        defer { lock.unlock() }
        
        if playerActiveToken == nil {
            playerActiveToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical],
                reason: reason
            )
            print("[SleepAssertionManager] Began latencyCritical player activity")
        }
    }
    
    /// Called when PlayerView closes or playback terminates completely.
    func playerDidClose() {
        lock.lock()
        defer { lock.unlock() }
        
        disableSleepPreventionLocked()
        
        if let token = playerActiveToken {
            ProcessInfo.processInfo.endActivity(token)
            playerActiveToken = nil
            print("[SleepAssertionManager] Ended latencyCritical player activity")
        }
    }
    
    /// Prevents display and system idle sleep while media is actively playing.
    func enableSleepPrevention(reason: String = "Flux Video Playback") {
        lock.lock()
        defer { lock.unlock() }
        
        // Ensure playerActiveToken is active as well
        if playerActiveToken == nil {
            playerActiveToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical],
                reason: "Flux Player Active"
            )
        }
        
        guard !isDisplayAsserted else { return }
        
        // 1. IOKit display sleep assertion (primary macOS mechanism for keeping display awake)
        let assertionType = kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString
        let reasonForActivity = reason as CFString
        
        var newID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            assertionType,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reasonForActivity,
            &newID
        )
        
        if result == kIOReturnSuccess {
            displayAssertionID = newID
            isDisplayAsserted = true
            print("[SleepAssertionManager] Enabled display sleep prevention (Assertion ID: \(displayAssertionID))")
        } else {
            print("[SleepAssertionManager] Failed to create IOKit sleep assertion: \(result)")
        }
        
        // 2. Dual-layer ProcessInfo activity to ensure system/display idle sleep is inhibited during playback
        if playbackActivityToken == nil {
            playbackActivityToken = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated],
                reason: reason
            )
        }
    }
    
    /// Releases the display sleep assertions so the display can sleep normally when paused/closed.
    /// Does not terminate playerActiveToken so the player process remains warm and responsive.
    func disableSleepPrevention() {
        lock.lock()
        defer { lock.unlock() }
        disableSleepPreventionLocked()
    }
    
    private func disableSleepPreventionLocked() {
        if isDisplayAsserted {
            let result = IOPMAssertionRelease(displayAssertionID)
            if result == kIOReturnSuccess {
                print("[SleepAssertionManager] Released display sleep prevention (Assertion ID: \(displayAssertionID))")
            } else {
                print("[SleepAssertionManager] Failed to release IOKit sleep assertion: \(result)")
            }
            displayAssertionID = 0
            isDisplayAsserted = false
        }
        
        if let token = playbackActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            playbackActivityToken = nil
        }
    }
    
    deinit {
        playerDidClose()
    }
}
