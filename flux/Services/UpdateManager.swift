import Foundation
import Combine
import Sparkle

/// Manages application updates via the Sparkle 2 framework.
@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    private var updaterController: SPUStandardUpdaterController?
    @Published var canCheckForUpdates: Bool = false
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
}
