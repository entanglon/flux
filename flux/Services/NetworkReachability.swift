import Foundation
import Network
import Combine
import OSLog

/// Monitors internet connectivity state via NWPathMonitor and broadcasts
/// notifications when connectivity is restored after a drop, enabling
/// automatic retry of failed image loads, catalog syncs, and metadata fetches.
final class NetworkReachability: ObservableObject {
    static let shared = NetworkReachability()

    @Published private(set) var isConnected: Bool = true
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "flux.networkReachability", qos: .utility)
    private var hasObservedInitialState = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let connected = (path.status == .satisfied)
            
            DispatchQueue.main.async {
                let wasConnected = self.isConnected
                self.isConnected = connected

                if !self.hasObservedInitialState {
                    self.hasObservedInitialState = true
                    return
                }

                if !wasConnected && connected {
                    Logger.network.info("[NetworkReachability] Internet connection restored — posting fluxNetworkRestored")
                    NotificationCenter.default.post(name: .fluxNetworkRestored, object: nil)
                }
            }
        }
        monitor.start(queue: queue)
    }
}
