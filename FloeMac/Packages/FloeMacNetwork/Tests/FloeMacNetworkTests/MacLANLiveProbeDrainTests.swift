// SPDX-License-Identifier: MPL-2.0
//
// Drain proofs for the LAN admission that used to stay closed.
//
// These tests exercise the real MacLANLiveProbe code paths (NWBrowser and
// DNSServiceRef resolve/address queries) without needing any device on the
// network: cancellation must retire the browser and deallocate the DNS-SD
// queries on their own queues well before the requested window elapses, and
// the manual owner must admit .lan through the same cancel/drain lifecycle
// as the other diagnostics.

import Foundation
import Testing
import FloeToolboxCore
import FloeToolboxDiagnostics
@testable import FloeMacNetwork

@Suite("LAN live probe cancellation drain")
struct MacLANLiveProbeDrainTests {
    private func elapsedSeconds(_ start: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: .now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    @Test func browseCancellationDrainsLongBeforeWindowEnds() async throws {
        let probe = MacLANLiveProbe.probe
        let start = ContinuousClock.now
        let task = Task { await probe.browse("_floe-drain-test._tcp", 30) { _ in } }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let outcome = await task.value
        let elapsed = elapsedSeconds(start)
        #expect(elapsed < 5, "Cancelled browse drained in \(elapsed)s")
        // The cancellation path settles the gate with the last observed
        // outcome instead of leaving a dangling continuation.
        _ = outcome
    }

    @Test func resolveCancellationDrainsLongBeforeTimeout() async throws {
        let probe = MacLANLiveProbe.probe
        let service = LANDiscoveredService(
            name: "Floe Drain Fixture", serviceType: "_floe-drain-test._tcp",
            domain: "local.", interfaceIndices: [0])
        let start = ContinuousClock.now
        let task = Task { await probe.resolve(service, 30) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let result = await task.value
        let elapsed = elapsedSeconds(start)
        #expect(elapsed < 5, "Cancelled resolve drained in \(elapsed)s")
        _ = result
    }

    @Test func addressResolutionCancellationDrainsLongBeforeTimeout() async throws {
        // The resolve phase issues A/AAAA record queries after the SRV step;
        // cancelling inside the record-query window must drain just as the
        // browser and resolve steps do.
        let probe = MacLANLiveProbe.probe
        let service = LANDiscoveredService(
            name: "Floe Drain Fixture", serviceType: "_floe-drain-test._tcp",
            domain: "local.", interfaceIndices: [0])
        let start = ContinuousClock.now
        let task = Task { await probe.resolve(service, 30) }
        try await Task.sleep(for: .milliseconds(1_200))
        task.cancel()
        let result = await task.value
        let elapsed = elapsedSeconds(start)
        #expect(elapsed < 5, "Cancelled address resolution drained in \(elapsed)s")
        _ = result
    }

    @Test func liveLanScanReturnsAnHonestBoundedReport() async throws {
        // The full path through the manual owner wiring: real probe, real
        // engine. The result must arrive well inside the bounded window and
        // must never fabricate services. Depending on the machine's local
        // network permission state the status is permissionUncertain or an
        // empty/definitive outcome — both are honest, neither hangs.
        let diagnostics = MacToolboxDiagnostics(
            lease: SessionLease(ownerID: UUID()),
            authorize: { _, _, _ in true },
            lanProbe: MacLANLiveProbe.probe)
        let start = ContinuousClock.now
        let report = try await diagnostics.lanScan(seconds: 1)
        let elapsed = elapsedSeconds(start)
        #expect(elapsed < 15, "Live LAN scan bounded in \(elapsed)s")
        #expect(report.browsedTypes.sorted() == LANDiscoveryScope.declaredBonjourTypes.sorted())
        #expect(report.services.allSatisfy { !$0.resolved || ($0.targetHost != nil && $0.port != nil) })
        await diagnostics.stop()
    }
}

@Suite("LAN admission through the manual owner")
@MainActor struct MacLANOwnerAdmissionTests {
    @Test func lanIsAdmittedAndDrainsThroughTheSameOwner() async {
        let runner = DelayedRunner()
        let owner = MacManualNetworkOwner(makeRunner: { _, _, _ in runner })
        #expect(owner.start(.lan))
        await runner.waitUntilEntered()
        owner.cancel()
        // The scripted runner suspends on a continuation that task cancellation
        // alone does not resume; the real transports return from their
        // cancellation handlers. Release it, then the owner task must run the
        // shared teardown (execute -> stop) before drain reports completion.
        await runner.finish("cancelled")
        #expect(await owner.drain(timeout: 2))
        #expect(await runner.stopCount > 0)
        #expect(!owner.running)
    }
}
