import Network
import Observation

/// Publishes connectivity so the app can show the offline banner (G1).
@Observable
final class NetworkMonitor {
    private(set) var isOnline: Bool = true
    private(set) var isWiFi: Bool = false
    private(set) var isWired: Bool = false
    var isUnmeteredLocalConnection: Bool { (isWiFi || isWired) && !isExpensive && !isConstrained }
    private(set) var isExpensive: Bool = true
    private(set) var isConstrained: Bool = false
    @ObservationIgnored var didChange: (() -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.twende.network")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let wifi = path.usesInterfaceType(.wifi)
            let wired = path.usesInterfaceType(.wiredEthernet)
            let expensive = path.isExpensive, constrained = path.isConstrained
            Task { @MainActor in
                guard let self else { return }
                self.isOnline = online
                self.isWiFi = wifi
                self.isWired = wired
                self.isExpensive = expensive
                self.isConstrained = constrained
                self.didChange?()
            }
        }
        monitor.start(queue: queue)
    }
}
