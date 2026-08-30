import Foundation
import AppKit

/// Controller managing warm mpv playback cores and TTL auto-disposal.
/// Allows instant playback adoption when transitioning from DetailView to PlayerView.
final class WarmCoreController {
    struct WarmPlaybackCore {
        let key: String
        let url: URL
        let controller: MPVController
        let viewController: MPVViewController
        let hostWindow: NSWindow?
        let createdAt: Date
    }

    private(set) var activeCore: WarmPlaybackCore?
    private var discardTask: _Concurrency.Task<Void, Never>?

    /// Adopts a matching warm core if it is still within the 5-minute TTL.
    func adoptCore(for key: String) -> WarmPlaybackCore? {
        guard let core = activeCore, core.key == key else { return nil }
        let age = Date().timeIntervalSince(core.createdAt)
        guard age < 300 else {
            discardCore()
            return nil
        }
        activeCore = nil
        discardTask?.cancel()
        discardTask = nil
        return core
    }

    /// Stores a freshly built warm core with a 5-minute automatic teardown timer.
    func storeCore(_ core: WarmPlaybackCore) {
        discardCore()
        activeCore = core

        discardTask = _Concurrency.Task { [weak self] in
            try? await _Concurrency.Task.sleep(nanoseconds: 300 * 1_000_000_000)
            guard !(_Concurrency.Task.isCancelled) else { return }
            await MainActor.run {
                self?.discardCore()
            }
        }
    }

    /// Discards any existing warm core, stopping playback and hiding its host window.
    func discardCore() {
        discardTask?.cancel()
        discardTask = nil
        guard let core = activeCore else { return }
        core.controller.stop()
        core.hostWindow?.orderOut(nil)
        activeCore = nil
    }

    /// Discards core only if its key matches the specified key to cancel.
    func discardIfMatching(key: String) {
        if activeCore?.key == key {
            discardCore()
        }
    }
}
