// App-owned fixed legacy recovery authority, refreshed owner sources and native optimizer.
#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeEnvironments
import FloeExecution
import FloePersistence

func makeLegacyMaintenanceReferenceEvidence(
    from projection: EnvironmentReferenceProjection, domain: RuntimeV2MaintenanceDomain
) -> RuntimeV2MaintenanceReferenceEvidence {
    var active: [String] = []
    var unknown: [String] = []
    var activeUnattributed = 0
    var liveUnknownUnattributed = 0
    var idleUnknownUnattributed = 0
    var retained = 0
    for reference in projection.references {
        switch reference.classification {
        case .active:
            if let environmentID = reference.environmentID {
                active.append(environmentID)
            } else {
                activeUnattributed += 1
            }
        case .unknown:
            if let environmentID = reference.environmentID {
                unknown.append(environmentID)
            } else if reference.isLive {
                liveUnknownUnattributed += 1
            } else {
                idleUnknownUnattributed += 1
            }
        case .retained:
            retained += 1
        }
    }
    // The complete projection still supplies every blocker/unknown/live owner.
    // Stability is scoped to this physical legacy domain: a new fully bound
    // resident/native-file task must not revoke a legacy claim merely because
    // the global DB set changed. Keep complete canonical reference rows (and
    // their binding/runtime generations), not just active environment IDs.
    let scoped = EnvironmentReferenceProjection(
        isComplete: projection.isComplete, blockers: projection.blockers,
        references: projection.references.filter { reference in
            if let environmentID = reference.environmentID {
                return domain.ownsEnvironmentTrace(environmentID)
            }
            return reference.isLive
        })
    return RuntimeV2MaintenanceReferenceEvidence(
        isComplete: projection.isComplete,
        blockers: projection.blockers,
        activeEnvironmentIDs: Array(Set(active)).sorted(),
        unknownEnvironmentIDs: Array(Set(unknown)).sorted(),
        unattributedActiveCount: activeUnattributed,
        unattributedLiveUnknownCount: liveUnknownUnattributed,
        unattributedIdleUnknownCount: idleUnknownUnattributed,
        retainedCount: retained,
        fingerprint: scoped.fingerprint
    )
}

private final class LinuxGuestMaintenanceSources: @unchecked Sendable {
    private struct Snapshot: Sendable {
        let registry: LinuxGuestRegistry?
        let integrator: RuntimeV2GuestIntegrator?
        let database: DatabaseManager?
        let generation: UInt64
    }
    private let lock = NSLock()
    private var registry: LinuxGuestRegistry?
    private var integrator: RuntimeV2GuestIntegrator?
    private var database: DatabaseManager?
    private var generation: UInt64 = 0
    private weak var coordinator: RuntimeV2MaintenanceCoordinator?
    let domain: RuntimeV2MaintenanceDomain
    let closureAuthority: RuntimeV2RecoveryClosureAuthority

    init(domain: RuntimeV2MaintenanceDomain, stateDirectory: URL, database: DatabaseManager?) {
        self.domain = domain; self.database = database
        self.closureAuthority = RuntimeV2RecoveryClosureAuthority(domain: domain, stateDirectory: stateDirectory)
    }
    func attach(_ coordinator: RuntimeV2MaintenanceCoordinator) {
        lock.withLock { self.coordinator = coordinator }
    }
    func replace(registry: LinuxGuestRegistry, integrator: RuntimeV2GuestIntegrator?, database: DatabaseManager?) {
        lock.withLock {
            self.registry = registry; self.integrator = integrator; self.database = database
            generation &+= 1
            RuntimeV2RecoveryAdmission.ownerSourcesChanged(root: domain.root)
        }
    }
    func replaceIntegrator(_ integrator: RuntimeV2GuestIntegrator?) {
        lock.withLock {
            self.integrator = integrator
            generation &+= 1
            RuntimeV2RecoveryAdmission.ownerSourcesChanged(root: domain.root)
        }
    }
    private func snapshot() -> Snapshot {
        lock.withLock { Snapshot(registry: registry, integrator: integrator, database: database, generation: generation) }
    }
    func collectRaw() async -> RuntimeV2MaintenanceOwnerEvidence {
        let source = snapshot()
        let collector = RuntimeV2MaintenanceEvidenceCollector(domain: domain, sources: .init(
            registry: { [source] in await source.registry?.maintenanceOwnerEvidence() },
            integrator: { [source] in await source.integrator?.maintenanceOwnerEvidence() },
            references: { [source, domain = self.domain] in
                guard let database = source.database else { return nil }
                return makeLegacyMaintenanceReferenceEvidence(
                    from: try await EnvironmentReferenceProjectionStore(database: database).project(), domain: domain)
            }))
        var evidence = await collector.collect()
        do {
            // Do not construct/prepare a legacy RuntimeV2Store to query its old
            // registry. Use a bounded readonly connection and CLOSE it before
            // the closure proof's native fd audit. WAL is honored; no migration.
            let legacy = try await RuntimeV2LegacyRegistryReader.readAsync(domain: domain)
            evidence.filesystem.legacyRegistryFingerprint = legacy.fingerprint
            evidence.filesystem.leaseRegistryUnmeasured = false
            evidence.filesystem.leaseEnvironmentIDs = Array(Set(
                evidence.filesystem.leaseEnvironmentIDs + legacy.leaseEnvironmentIDs)).sorted()
            evidence.blockers.removeAll { $0 == "filesystem_lease_registry_unmeasured" }
            let registryReady = evidence.registry.usesResidentMachine || evidence.registry.isComplete
            let integratorReady: Bool
            if let path = evidence.integrator.storeRootPath {
                let same = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path == domain.root.path
                integratorReady = same ? evidence.integrator.isComplete : true
            } else { integratorReady = false }
            evidence.isComplete = evidence.blockers.isEmpty && registryReady && integratorReady
                && evidence.references.isComplete && evidence.filesystem.isComplete
        } catch {
            evidence.isComplete = false
            evidence.filesystem.leaseRegistryUnmeasured = true
            evidence.blockers.append("legacy_registry_readonly_evidence_failed")
            if case RuntimeV2MaintenanceError.ownerEvidenceIncomplete(let reasons) = error {
                evidence.blockers.append(contentsOf: reasons)
            }
        }
        if snapshot().generation != source.generation {
            evidence.isComplete = false
            evidence.blockers.append("native_owner_sources_changed")
        }
        return evidence
    }
    func collectAdmitted() async -> RuntimeV2MaintenanceOwnerEvidence {
        var evidence = await collectRaw()
        do {
            guard let coordinator = lock.withLock({ self.coordinator }) else {
                throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["coordinator_unavailable"])
            }
            let intent = try await coordinator.nativeClosureIntent()
            evidence = try await closureAuthority.proveClosed(evidence: evidence, intent: intent, coordinator: coordinator)
        } catch {
            evidence.isComplete = false
            evidence.blockers.append("native_closed_receipt_unavailable")
            if case RuntimeV2MaintenanceError.ownerEvidenceIncomplete(let reasons) = error {
                evidence.blockers.append(contentsOf: reasons)
            }
        }
        return evidence
    }
}

final class LinuxGuestMaintenanceRuntime: @unchecked Sendable {
    let domain: RuntimeV2MaintenanceDomain
    let coordinator: RuntimeV2MaintenanceCoordinator
    let optimizer: RuntimeV2RecoveryOptimizationAdapter
    private let sources: LinuxGuestMaintenanceSources

    init(domain: RuntimeV2MaintenanceDomain, stateDirectory: URL, database: DatabaseManager?) throws {
        self.domain = domain
        let sources = LinuxGuestMaintenanceSources(domain: domain, stateDirectory: stateDirectory, database: database)
        self.sources = sources
        let coordinator = try RuntimeV2MaintenanceCoordinator(
            domain: domain, stateDirectory: stateDirectory,
            evidenceProvider: { await sources.collectAdmitted() })
        self.coordinator = coordinator
        guard RuntimeV2MaintenanceRegistry.install(coordinator) === coordinator else {
            throw RuntimeV2MaintenanceError.claimInvalidated("legacy authority already has another App owner")
        }
        sources.attach(coordinator)
        self.optimizer = RuntimeV2RecoveryOptimizationAdapter(
            domain: domain, coordinator: coordinator, closureAuthority: sources.closureAuthority,
            rawEvidence: { await sources.collectRaw() }, admittedEvidence: { await sources.collectAdmitted() })
    }
    func bind(registry: LinuxGuestRegistry, integrator: RuntimeV2GuestIntegrator?, database: DatabaseManager?) {
        sources.replace(registry: registry, integrator: integrator, database: database)
    }
    func rebindIntegrator(_ integrator: RuntimeV2GuestIntegrator?) { sources.replaceIntegrator(integrator) }
    func recoverBeforeUse() async -> RuntimeV2MaintenanceRecoveryReport { await optimizer.recoverBeforeUse() }
    func maintenanceState() async -> RuntimeV2MaintenanceState { await coordinator.state() }
    func beginDeletionUse(environmentID: String) async throws -> (any ContainerLifecycleMaintenanceUse)? {
        guard await coordinator.ownsEnvironmentTrace(environmentID) else { return nil }
        let claim = try await coordinator.acquireSharedUse(owner: "container-lifecycle", purpose: "delete-environment")
        return LinuxGuestMaintenanceDeletionUse(claim: claim)
    }
}
private struct LinuxGuestMaintenanceDeletionUse: ContainerLifecycleMaintenanceUse {
    let claim: RuntimeV2MaintenanceSharedUse
    func end() async { await claim.release() }
}

enum LinuxGuestMaintenanceAssembly {
    private final class Holder: @unchecked Sendable {
        let lock = NSLock()
        var runtime: LinuxGuestMaintenanceRuntime?
        func current() -> LinuxGuestMaintenanceRuntime? { lock.withLock { runtime } }
        func install(_ candidate: LinuxGuestMaintenanceRuntime) -> LinuxGuestMaintenanceRuntime {
            lock.withLock {
                if let runtime { return runtime }
                runtime = candidate; return candidate
            }
        }
    }
    private static let holder = Holder()
    static func currentRuntime() -> LinuxGuestMaintenanceRuntime? { holder.current() }

    /// Must run BEFORE constructing any runtime layout/backend in this launch.
    /// It does not open/prepare/migrate the legacy store or stop any machine.
    @discardableResult
    static func bootstrapIfAvailable(database: DatabaseManager?) -> LinuxGuestMaintenanceRuntime? {
        if let existing = holder.current() { return existing }
        guard let root = RuntimeV2MaintenanceDomain.trustedLegacyRoot(),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("recovery").path) else { return nil }
        do {
            let domain = try RuntimeV2MaintenanceDomain(trustedLegacyRoot: root)
            guard RuntimeV2MaintenanceRegistry.coordinator(forDomain: domain) == nil else { return nil }
            let state = domain.root.deletingLastPathComponent().appendingPathComponent("MaintenanceAuthority", isDirectory: true)
                .appendingPathComponent(domain.domainKey, isDirectory: true)
            return holder.install(try LinuxGuestMaintenanceRuntime(domain: domain, stateDirectory: state, database: database))
        } catch {
            FloeLogger(category: .tools).error("Legacy native maintenance bootstrap unavailable; no optimization admitted")
            return nil
        }
    }

    @discardableResult
    static func installIfAvailable(registry: LinuxGuestRegistry, integrator: RuntimeV2GuestIntegrator?,
                                   database: DatabaseManager?) -> LinuxGuestMaintenanceRuntime? {
        guard let runtime = bootstrapIfAvailable(database: database) else { return nil }
        // Replace real current sources, while retaining the SAME coordinator,
        // gate and installed Core recovery handler across re-download/reconnect.
        runtime.bind(registry: registry, integrator: integrator, database: database)
        return runtime
    }
}
#endif
