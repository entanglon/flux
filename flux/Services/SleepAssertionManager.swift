import Foundation
import IOKit.pwr_mgt

/// Manages macOS power assertions during active video playback so that the display
/// and system do not sleep while the user is watching content in Flux or PiP.
final class SleepAssertionManager {
    static let shared = SleepAssertionManager()
    
    private var assertionID: IOPMAssertionID = 0
    private var isAsserted = false
    private var activityToken: NSObjectProtocol?
    private let lock = NSLock()
    
    private init() {}
    
    /// Prevents display and system idle sleep while media is actively playing.
    func enableSleepPrevention(reason: String = "Flux Video Playback") {
        lock.lock()
        defer { lock.unlock() }
        
        guard !isAsserted else { return }
        
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
            assertionID = newID
            isAsserted = true
            print("[SleepAssertionManager] Enabled display sleep prevention (Assertion ID: \(assertionID))")
        } else {
            print("[SleepAssertionManager] Failed to create IOKit sleep assertion: \(result)")
        }
        
        // 2. Dual-layer ProcessInfo activity to ensure system/display idle sleep is inhibited
        if activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated],
                reason: reason
            )
        }
    }
    
    /// Releases the sleep assertions so the display and system can sleep normally when paused/closed.
    func disableSleepPrevention() {
        lock.lock()
        defer { lock.unlock() }
        
        if isAsserted {
            let result = IOPMAssertionRelease(assertionID)
            if result == kIOReturnSuccess {
                print("[SleepAssertionManager] Released display sleep prevention (Assertion ID: \(assertionID))")
            } else {
                print("[SleepAssertionManager] Failed to release IOKit sleep assertion: \(result)")
            }
            assertionID = 0
            isAsserted = false
        }
        
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }
    
    deinit {
        disableSleepPrevention()
    }
}
