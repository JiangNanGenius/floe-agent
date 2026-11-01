import Foundation
import BridgeCore

/// Service-owned sampler for the existing Packet Tunnel app-message snapshot.
///
/// It runs only while a DDI probe/mount is active, keeps one request in flight,
/// and writes every accepted or rejected result through the process-wide
/// `BridgeTunnelSnapshotStore`. It never starts a VPN, changes routes, reads a
/// packet payload or touches the coordinator generation/readiness state.
@MainActor
final class BridgeTunnelSampler {
    private let tunnel: BridgeTunnelManager
    private let store: BridgeTunnelSnapshotStore
    private var task: Task<Void, Never>?
    private var runID: UInt64 = 0

    init(tunnel: BridgeTunnelManager, store: BridgeTunnelSnapshotStore = .shared) {
        self.tunnel = tunnel
        self.store = store
    }

    var isSampling: Bool { task != nil }

    func start(hostPid: Int32, generation: UInt64) {
        guard task == nil else { return }
        runID &+= 1
        let currentRun = runID
        task = Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(
                BridgeTunnelSnapshotPolicy.maximumSampleSeconds
            )
            while !Task.isCancelled && Date() < deadline {
                let sequence = self.store.beginRequest(
                    hostPid: hostPid,
                    generation: generation
                )
                let read = await self.tunnel.sampleProviderSnapshot()
                self.store.record(read, sequence: sequence)
                do {
                    try await Task.sleep(
                        for: .seconds(BridgeTunnelSnapshotPolicy.sampleIntervalSeconds)
                    )
                } catch {
                    break
                }
            }
            if self.runID == currentRun { self.task = nil }
        }
    }

    func stop() {
        runID &+= 1
        task?.cancel()
        task = nil
    }
}
