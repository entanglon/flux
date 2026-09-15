import Foundation
import Combine
import Sparkle

/// Manages application updates via the Sparkle 2 framework.
/// For unsigned builds, we use Sparkle for update checking only.
/// When an update is available, we open the GitHub releases page
/// for manual download and installation.
@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    private var updaterController: SPUStandardUpdaterController?
    @Published var canCheckForUpdates: Bool = false
    @Published var showUpdateAvailable: Bool = false
    @Published var latestVersion: String = ""
    @Published var releaseNotes: String = ""
    private var cancellable: AnyCancellable?

    private init() {
        let isRunningTests = NSClassFromString("XCTestCase") != nil ||
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            ProcessInfo.processInfo.environment["XCInjectBundleInto"] != nil

        guard !isRunningTests else { return }

        #if os(macOS)
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
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
