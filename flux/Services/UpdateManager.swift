import Foundation
import Combine
import Sparkle
import AppKit

/// Manages application updates via the Sparkle 2 framework.
/// For unsigned builds, we use Sparkle for update checking only.
/// When an update is available, we open the GitHub releases page
/// for manual download and installation.
@MainActor
final class UpdateManager: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    static let shared = UpdateManager()

    private var updaterController: SPUStandardUpdaterController?
    @Published var canCheckForUpdates: Bool = false
    @Published var showUpdateAvailable: Bool = false
    @Published var latestVersion: String = ""
    @Published var releaseNotes: String = ""
    private var cancellable: AnyCancellable?

    private override init() {
        super.init()
        let isRunningTests = NSClassFromString("XCTestCase") != nil ||
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            ProcessInfo.processInfo.environment["XCInjectBundleInto"] != nil

        guard !isRunningTests else { return }

        #if os(macOS)
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        self.updaterController = controller
        self.cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: \.canCheckForUpdates, on: self)
        #endif
    }

    /// Triggers the Sparkle standard updater check workflow.
    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    // MARK: - SPUStandardUserDriverDelegate

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        Task { @MainActor in
            self.styleUpdateAlertWindow()
        }
    }

    private func styleUpdateAlertWindow() {
        for window in NSApp.windows {
            let className = NSStringFromClass(type(of: window))
            if className.contains("SUUpdateAlert") || window.title.contains("Software Update") {
                window.titlebarAppearsTransparent = true
                window.isMovableByWindowBackground = true
                window.appearance = NSAppearance(named: .darkAqua)
            }
        }
    }

    /// Opens the GitHub releases page for manual download.
    func openDownloadPage() {
        let isBeta = Bundle.main.bundleIdentifier?.contains("beta") ?? false
        let urlString = isBeta
            ? "https://github.com/entanglon/flux/releases"
            : "https://github.com/entanglon/flux/releases"
        
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
