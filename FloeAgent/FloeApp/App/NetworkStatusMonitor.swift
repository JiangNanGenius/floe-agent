#if canImport(Network)
import Foundation
import Network
import FloeCore

/// Process-wide reachability signal used only for routing decisions. Provider
/// requests still own their transport errors; this monitor never claims that
/// an individual endpoint is healthy merely because a network path exists.
final class NetworkStatusMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "org.floeagent.network-status")
    private let lock = NSLock()
    private var status: NWPath.Status

    init() {
        status = monitor.currentPath.status
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.status = path.status
            self.lock.unlock()
            FloeLogger(category: .app).info(
                "networkPathChanged status=\(String(describing: path.status)) expensive=\(path.isExpensive) constrained=\(path.isConstrained)"
            )
        }
        monitor.start(queue: queue)
    }

    var isOffline: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.status == .unsatisfied
    }

    deinit { monitor.cancel() }
}
#endif
