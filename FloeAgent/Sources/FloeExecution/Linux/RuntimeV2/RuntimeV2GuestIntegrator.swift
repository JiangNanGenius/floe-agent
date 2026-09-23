// FloeExecution — bridge between the TinyEMU guest registry and Runtime v2.
//
// The registry keeps owning session/channel lifecycle; the integrator owns
// everything durable: pool admission (four running VMs, a fifth queues),
// the single-writer lease, working-disk materialization into the temporary
// runtime/vm/<runtimeID> directory, verified delta capture after a confirmed
// stop, and the explicit memory-tier path. The seam is a protocol so focused
// tests drive the registry with a scripted integrator (no VM, no disk).
//
// Memory boundary (documented, tested): the pinned TinyEMU engine allocates
// guest RAM once at create time and exposes no balloon/resize API. Adaptive
// memory therefore means (a) admission-time tiering — a start is granted the
// requested tier or the highest tier that fits the 1.5/2 GiB device budget —
// and (b) the safe stop → flush → restart path for an explicit tier change:
// the machine is stopped, its working disk is flushed (engine stdio close +
// host fsync), then the same machine is recreated on the same working disk
// with the new tier while the console stream and channel survive (the same
// reboot boundary the runner upgrade already uses). Nothing claims online
// ballooning.

import Foundation
import FloeCore

/// Pool admission result: the granted memory tier and vCPU count may be
/// lower than requested when the device budget is under pressure (honest
/// downgrade, reported through the status surface and the boot descriptor).
public struct RuntimeV2Admission: Sendable, Equatable {
    public var runtimeID: String
    public var ramMB: Int
    public var downgraded: Bool
    /// vCPUs actually granted at create time (the engine reads the count once).
    public var vcpus: Int
    /// True when the vCPU count was reduced below the request by an
    /// authorized downgrade policy.
    public var vcpusDowngraded: Bool
    public var downgradeReason: String?

    public init(
        runtimeID: String, ramMB: Int, downgraded: Bool,
        vcpus: Int = 1, vcpusDowngraded: Bool = false, downgradeReason: String? = nil
    ) {
        self.runtimeID = runtimeID
        self.ramMB = ramMB
        self.downgraded = downgraded
        self.vcpus = vcpus
        self.vcpusDowngraded = vcpusDowngraded
        self.downgradeReason = downgradeReason
    }
}

/// A materialized working disk ready for boot.
public struct RuntimeV2WorkingDisk: Sendable, Equatable {
    public var diskURL: URL
    public var capacityBytes: Int64

    public init(diskURL: URL, capacityBytes: Int64) {
        self.diskURL = diskURL
        self.capacityBytes = capacityBytes
    }
}

/// Everything the guest registry delegates to Runtime v2.
public protocol LinuxGuestRuntimeV2Integrating: Sendable {
    /// Admits a start (queues when the pool is full). Granted RAM wins over
    /// the requested value.
    func acquireSlot(environmentID: String, runtimeID: String, requestedMB: Int) async throws -> RuntimeV2Admission
    /// Three-axis admission (vCPU + RAM + VM) for a shape-aware start. The
    /// granted vCPU count and RAM are the values the machine is created with;
    /// an image whose manifest does not PROVE SMP can never be granted two
    /// harts (the engine's `floe_vm_smp_capable()` is not image evidence).
    func acquireShape(
        environmentID: String, runtimeID: String,
        request: GuestResourceRequest, imageSMPCapable: Bool,
        downgrade: GuestShapeDowngradePolicy
    ) async throws -> LinuxGuestShapeAdmission
    /// Validates a requested shape change (vCPU and/or RAM) against the pool
    /// quota and the image capability BEFORE the stop/flush/restart path.
    func planReshape(
        environmentID: String, ramMB: Int, vcpus: Int, currentVCPUs: Int
    ) async throws
    /// Records the shape a completed stop → flush → restart made true.
    func confirmReshape(environmentID: String, ramMB: Int, vcpus: Int) async
    /// SMP capability proven by the canonical image manifest (never by an
    /// engine query and never assumed). Default false.
    func imageSMPCapable(imageID: String) async -> Bool
    /// Releases the pool slot after the session is fully torn down.
    func releaseSlot(environmentID: String, runtimeID: String) async
    /// Takes the single-writer lease and materializes the working disk
    /// (verified base clone + delta apply + grow to target capacity).
    func prepareWorkingDisk(
        environmentID: String, runtimeID: String, imageID: String,
        legacyWritableDirectory: URL?, targetCapacityBytes: Int64
    ) async throws -> RuntimeV2WorkingDisk
    /// The only per-environment Runtime v2 directory exported through 9P.
    func environmentDataDirectory(environmentID: String) async throws -> URL
    /// A VM confirmed stopped: flush, capture the delta, record the shutdown
    /// (clean or interrupted), sweep the runtime dir, release the lease.
    func completeStop(environmentID: String, runtimeID: String, imageID: String, clean: Bool) async
    /// The expanded (verified, rebuildable) image directory for boot paths.
    func expandedImageDirectory(imageID: String) async throws -> URL
    /// Verified-image truth for status composition.
    func isImageVerified(imageID: String) async -> Bool
    /// Verified-image truth WITHOUT triggering a migration: answers only
    /// whether the v2 store already holds this image verified, so a status
    /// read can never kick off a multi-gigabyte migration as a side effect.
    func isImageVerifiedWithoutMigration(imageID: String) async -> Bool
    /// Runner capability ledger (system/runner.json in v2).
    func recordedRunnerCapabilities(environmentID: String) async -> String?
    func recordRunnerCapabilities(_ capabilities: String, environmentID: String) async
    /// Working disk capacity feeding the in-guest ext4 resize check.
    func workingDiskCapacityBytes(environmentID: String, runtimeID: String) async -> Int64?
    /// Queued start requests, for honest capacity reporting.
    func queuedStarts() async -> Int
    /// Validates a requested tier change against the device budget BEFORE
    /// the stop/flush/restart path runs; throws when it cannot fit.
    func planRetier(environmentID: String, ramMB: Int) async throws
    /// Confirms a tier change after the stop/flush/restart path completed.
    func confirmTier(environmentID: String, ramMB: Int) async
}

public extension LinuxGuestRuntimeV2Integrating {
    /// Conservative default for conformers that cannot evaluate image
    /// manifests: a capability that is not proven is false. The production
    /// integrator overrides this with the verified image manifest's own
    /// declaration — never an engine query.
    func imageSMPCapable(imageID: String) async -> Bool { false }
}

/// Production integrator backed by a RuntimeV2Store.
public actor RuntimeV2GuestIntegrator: LinuxGuestRuntimeV2Integrating {
    private let store: RuntimeV2Store
    private let legacyImagesRoot: URL?
    private let build: String
    private var fileManager: FileManager { .default }
    private var prepared = false
    /// Held leases by runtimeID so completeStop releases exactly its own.
    private var heldLeases: [String: RuntimeV2LeaseStore.HeldLease] = [:]

    public init(store: RuntimeV2Store, legacyImagesRoot: URL? = nil, build: String? = nil) {
        self.store = store
        self.legacyImagesRoot = legacyImagesRoot
        self.build = build
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            ?? "unknown"
    }

    private func ensurePrepared() async throws {
        guard !prepared else { return }
        _ = try await store.prepareAndRecover(build: build)
        prepared = true
    }

    private func ensureImageMigrated(_ imageID: String) async throws {
        try await ensurePrepared()
        if (try? await store.images.isImageVerified(imageID: imageID)) == true { return }
        guard let legacyImagesRoot else { throw RuntimeV2Error.imageNotFound(imageID) }
        _ = try await store.images.migrateLegacyImage(
            imageID: imageID, legacyImagesRoot: legacyImagesRoot
        )
    }

    public func acquireSlot(environmentID: String, runtimeID: String, requestedMB: Int) async throws -> RuntimeV2Admission {
        try await ensurePrepared()
        let tier = RuntimeMemoryTier.tier(forRequestedMB: requestedMB)
        let slot = try await store.pool.acquire(
            environmentID: environmentID, runtimeID: runtimeID, requestedTier: tier
        )
        return RuntimeV2Admission(
            runtimeID: slot.runtimeID, ramMB: slot.tier.mb, downgraded: slot.downgradedAtAdmission
        )
    }

    /// Shape-aware admission: the pool grants the real vCPU/RAM shape and the
    /// result carries exactly what was granted, so the boot descriptor is
    /// created with the granted count (never the request and never an
    /// engine-derived guess).
    public func acquireShape(
        environmentID: String, runtimeID: String,
        request: GuestResourceRequest, imageSMPCapable: Bool,
        downgrade: GuestShapeDowngradePolicy
    ) async throws -> LinuxGuestShapeAdmission {
        try await ensurePrepared()
        // The image manifest is the capability authority: the caller's flag is
        // a hint that can never widen an unproven image into SMP. The engine
        // gate (floe_vm_smp_capable) is deliberately not consulted here.
        let proven = await provenSMPCapability(environmentID: environmentID)
        let granted = try await store.pool.acquire(
            environmentID: environmentID, runtimeID: runtimeID,
            request: request, imageSMPCapable: proven, downgrade: downgrade
        )
        var reason = granted.vcpusDowngradeReason ?? granted.memoryDowngradeReason
        if request.vcpus == .two, imageSMPCapable, !proven {
            let note = "the caller claimed SMP but the image manifest does not prove it; the claim was not used"
            reason = reason.map { "\($0); \(note)" } ?? note
        }
        return LinuxGuestShapeAdmission(
            runtimeID: granted.runtimeID,
            ramMB: granted.shape.memory.mb,
            vcpus: granted.shape.vcpus.count,
            downgraded: granted.wasDowngraded,
            vcpusDowngraded: granted.vcpusDowngraded,
            downgradeReason: reason
        )
    }

    /// Validates a vCPU/RAM change against the pool quota and the image's SMP
    /// proof before any disruption. Nothing is stopped if this throws.
    public func planReshape(
        environmentID: String, ramMB: Int, vcpus: Int, currentVCPUs: Int
    ) async throws {
        try await ensurePrepared()
        let proven = await provenSMPCapability(environmentID: environmentID)
        let request = GuestResourceRequest(
            vcpus: GuestVCPUCount.clamping(vcpus),
            memory: GuestMemoryMiB.smallestHolding(max(0, ramMB)) ?? .m2048,
            origin: .environmentPolicy
        )
        try await store.pool.validateShapeChange(
            environmentID: environmentID, request: request, imageSMPCapable: proven
        )
    }

    /// Records the shape a completed stop → flush → restart actually produced.
    public func confirmReshape(environmentID: String, ramMB: Int, vcpus: Int) async {
        guard let slot = await store.pool.slot(environmentID: environmentID) else { return }
        let shape = GuestResourceRequest(
            vcpus: GuestVCPUCount.clamping(vcpus),
            memory: GuestMemoryMiB.smallestHolding(max(0, ramMB)) ?? .m2048,
            origin: .environmentPolicy
        )
        await store.pool.confirmShape(runtimeID: slot.runtimeID, shape: shape)
    }

    /// SMP capability proven by the verified image manifest. Absent or false
    /// declarations answer false; the engine query is never consulted.
    public func imageSMPCapable(imageID: String) async -> Bool {
        (try? await store.images.smpCapability(imageID: imageID))?.capable ?? false
    }

    /// The image whose manifest must prove the capability for this
    /// environment: the pinned template's root base image when one is pinned
    /// (the template rootfs boots with that image's kernel/BIOS), else the
    /// environment's own base image. Anything unresolved answers false.
    private func provenSMPCapability(environmentID: String) async -> Bool {
        if let pin = try? await store.templates.environmentPin(environmentID: environmentID) {
            guard let root = try? await store.templates.baseImageID(
                templateID: pin.templateID, version: pin.version
            ) else { return false }
            return await imageSMPCapable(imageID: root)
        }
        guard let row = try? await store.registry.environment(id: environmentID),
              let imageID = row.baseImageID else { return false }
        return await imageSMPCapable(imageID: imageID)
    }

    public func releaseSlot(environmentID: String, runtimeID: String) async {
        await store.pool.release(runtimeID: runtimeID)
        try? await store.registry.releasePorts(runtimeID: runtimeID)
    }

    public func prepareWorkingDisk(
        environmentID: String, runtimeID: String, imageID: String,
        legacyWritableDirectory: URL?, targetCapacityBytes: Int64
    ) async throws -> RuntimeV2WorkingDisk {
        try await ensureImageMigrated(imageID)
        if (try await store.registry.environment(id: environmentID)) == nil {
            let legacyDiskDirectory = legacyWritableDirectory?
                .appendingPathComponent(LinuxGuestRuntimeImagePreparer.writableDirectoryName, isDirectory: true)
                .appendingPathComponent("disks", isDirectory: true)
                .appendingPathComponent(environmentID, isDirectory: true)
            _ = try await RuntimeV2EnvironmentMigrator(store: store).migrateLegacyEnvironment(
                environmentID: environmentID,
                kind: "linuxVM",
                ownerID: nil,
                name: nil,
                baseImageID: imageID,
                legacyDiskDirectory: legacyDiskDirectory,
                legacyLayerDirectory: legacyWritableDirectory
            )
        }
        // Fail closed before any lease or materialization: an environment
        // whose migration ended repairRequired (e.g. an origin conflict that
        // quarantined the legacy disk) must never boot a fresh empty
        // data/delta over the preserved data, on any retry.
        if let row = try await store.registry.environment(id: environmentID),
           row.state == "repairRequired" {
            throw RuntimeV2Error.environmentRepairRequired(
                environmentID: environmentID, reason: row.repairReason
            )
        }
        // Lease first: single writable ownership of the environment's delta.
        // In-process staleness is already proven by the caller: the registry
        // only reaches here when no session exists, no teardown is in flight
        // and the environment is not quarantined, so no live VM/thread/disk
        // handle references it. A lease from THIS process incarnation is
        // therefore provably stale here; any other incarnation falls back to
        // the store's cross-process proof (recorded pid dead + TTL expired).
        let ownIncarnation = await store.leases.incarnation
        let staleProof: RuntimeV2LeaseStore.StaleProof = { lease in
            if lease.incarnation == ownIncarnation { return true }
            return RuntimeV2LeaseStore.processLiveness(lease: lease)
        }
        let lease = try await store.leases.acquire(
            environmentID: environmentID, runtimeID: runtimeID, staleProof: staleProof
        )
        heldLeases[runtimeID] = lease

        guard let manifest = try await store.images.manifest(imageID: imageID),
              let rootfsRef = manifest.artifacts["rootfs"] ?? manifest.artifacts["disk"],
              try await store.images.isImageVerified(imageID: imageID) else {
            await lease.release()
            heldLeases[runtimeID] = nil
            throw RuntimeV2Error.unverifiedImageReferenced(imageID)
        }
        let expanded = try await store.images.ensureExpanded(imageID: imageID)
        let baseRootfs = expanded.appendingPathComponent(rootfsRef.expandedPath)

        let directory = try store.layout.runtimeVMDirectory(runtimeID: runtimeID)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try RuntimeV2WorkingDirectory.writeMeta(
            RuntimeV2WorkingDirectory.Meta(
                runtimeID: runtimeID, environmentID: environmentID,
                baseImageID: imageID, createdAt: Date()
            ),
            to: directory
        )
        let diskURL = directory.appendingPathComponent("disk.img")
        // Deep reuse: an environment pinned to an immutable software template
        // boots a clone of exactly that template version's complete disk plus
        // its own private delta. The pin is resolved exactly — never "latest"
        // — and a pin that no longer resolves fails closed instead of booting
        // a different base.
        let pin = try await store.templates.environmentPin(environmentID: environmentID)
        let materializedCapacity: Int64
        if let pin {
            _ = try await store.templates.clonePinnedTemplateDisk(
                environmentID: environmentID, runtimeID: runtimeID,
                imageID: imageID, into: diskURL
            )
            // The delta was captured against (and must be applied onto) the
            // pinned template's disk, not the base image rootfs.
            let deltaBase = try await store.templates.deltaBase(
                environmentID: environmentID, imageID: imageID,
                baseRootfs: baseRootfs, baseRootfsSHA512: rootfsRef.sha512
            )
            materializedCapacity = try await store.deltas.applyDelta(
                environmentID: environmentID,
                expectedBaseRootfsSHA512: deltaBase.digest,
                expectedTemplate: pin,
                into: diskURL
            )
        } else {
            // Base-image-only environments keep the previous behavior exactly;
            // the delta is still bound to the verified base digest, so a base
            // swap can never silently absorb an old delta.
            materializedCapacity = try await store.deltas.materializeWorkingDisk(
                environmentID: environmentID, baseRootfs: baseRootfs,
                expectedBaseRootfsSHA512: rootfsRef.sha512,
                expectedTemplate: nil,
                into: diskURL
            )
        }
        // Grow-only to the target capacity (sparse): a pristine environment
        // gets the full configured logical disk; an existing delta never shrinks.
        let requestedCapacity = min(targetCapacityBytes, LinuxGuestDiskLayout.maximumLogicalCapacityBytes)
        var capacity = max(materializedCapacity, requestedCapacity)
        if materializedCapacity < requestedCapacity {
            try LinuxGuestRuntimeImagePreparer.growSparseFile(
                at: diskURL, capacityBytes: requestedCapacity, fileManager: fileManager
            )
        }
        if let recorded = try await store.deltas.loadDelta(environmentID: environmentID)?.header.capacityBytes {
            capacity = max(capacity, recorded)
        }
        return RuntimeV2WorkingDisk(diskURL: diskURL, capacityBytes: capacity)
    }

    /// Confirmed-stopped path. `clean == false` means the stop was requested
    /// but the session is being abandoned/quarantined by the caller — the VM
    /// may still be running on the working disk, so the runtime dir and the
    /// lease are kept for recovery instead of capturing over live state.
    public func completeStop(environmentID: String, runtimeID: String, imageID: String, clean: Bool) async {
        guard clean else {
            try? await store.deltas.recordShutdown(
                RuntimeV2DeltaStore.ShutdownRecord(
                    environmentID: environmentID, runtimeID: runtimeID, stoppedAt: Date(),
                    clean: false, deltaGeneration: nil,
                    detail: "stop did not confirm; the working disk and lease are retained for recovery"
                ),
                environmentID: environmentID
            )
            return
        }
        let directory = try? store.layout.runtimeVMDirectory(runtimeID: runtimeID)
        let diskURL = directory?.appendingPathComponent("disk.img")
        if let diskURL, fileManager.fileExists(atPath: diskURL.path) {
            // Flush: the engine's fclose already flushed stdio; fsync before
            // the capture so the delta never records unflushed bytes.
            if let handle = try? FileHandle(forUpdating: diskURL) {
                try? handle.synchronize()
                try? handle.close()
            }
            if let manifest = try? await store.images.manifest(imageID: imageID),
               let rootfsRef = manifest.artifacts["rootfs"] ?? manifest.artifacts["disk"],
               let expanded = try? await store.images.ensureExpanded(imageID: imageID) {
                let baseRootfs = expanded.appendingPathComponent(rootfsRef.expandedPath)
                // Capture binds the delta to exactly the base the working disk
                // was cloned from: the pinned template's immutable disk when
                // one is pinned, else the verified base image rootfs. A pinned
                // environment's delta therefore holds only its private
                // changes, and can never be folded into different bytes.
                let deltaBase = try? await store.templates.deltaBase(
                    environmentID: environmentID, imageID: imageID,
                    baseRootfs: baseRootfs, baseRootfsSHA512: rootfsRef.sha512
                )
                if let deltaBase, let info = try? await store.deltas.capture(
                    environmentID: environmentID,
                    workingDisk: diskURL,
                    baseRootfs: deltaBase.diskURL,
                    baseImageID: imageID,
                    baseRootfsSHA512: deltaBase.digest,
                    templatePin: deltaBase.templatePin
                ) {
                    try? await store.deltas.recordShutdown(
                        RuntimeV2DeltaStore.ShutdownRecord(
                            environmentID: environmentID, runtimeID: runtimeID,
                            stoppedAt: Date(), clean: true,
                            deltaGeneration: info.header.generation
                        ),
                        environmentID: environmentID
                    )
                }
            }
        }
        if let directory {
            try? fileManager.removeItem(at: directory)
        }
        if let lease = heldLeases.removeValue(forKey: runtimeID) {
            await lease.release()
        } else {
            await store.leases.release(environmentID: environmentID, runtimeID: runtimeID)
        }
    }

    public func expandedImageDirectory(imageID: String) async throws -> URL {
        try await ensureImageMigrated(imageID)
        return try await store.images.ensureExpanded(imageID: imageID)
    }

    public func isImageVerified(imageID: String) async -> Bool {
        try? await ensureImageMigrated(imageID)
        return (try? await store.images.isImageVerified(imageID: imageID)) ?? false
    }

    public func isImageVerifiedWithoutMigration(imageID: String) async -> Bool {
        do {
            try await ensurePrepared()
            return try await store.images.isImageVerified(imageID: imageID)
        } catch {
            return false
        }
    }

    public func environmentDataDirectory(environmentID: String) async throws -> URL {
        try await ensurePrepared()
        let directory = try store.layout.environmentDataDirectory(environmentID: environmentID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public func recordedRunnerCapabilities(environmentID: String) async -> String? {
        guard let url = try? store.layout.environmentSystemDirectory(environmentID: environmentID)
            .appendingPathComponent("runner.json"),
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(LinuxGuestRuntimeRunnerState.self, from: data),
              state.version == LinuxGuestRuntimeRunnerState.currentVersion else { return nil }
        return state.runnerCapabilities
    }

    public func recordRunnerCapabilities(_ capabilities: String, environmentID: String) async {
        guard let directory = try? store.layout.environmentSystemDirectory(environmentID: environmentID) else {
            return
        }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = LinuxGuestRuntimeRunnerState(runnerCapabilities: capabilities)
        try? JSONEncoder().encode(state).write(
            to: directory.appendingPathComponent("runner.json"), options: .atomic
        )
    }

    public func workingDiskCapacityBytes(environmentID: String, runtimeID: String) async -> Int64? {
        if let header = try? await store.deltas.loadDelta(environmentID: environmentID)?.header {
            return header.capacityBytes
        }
        let disk = (try? store.layout.runtimeVMDirectory(runtimeID: runtimeID))?
            .appendingPathComponent("disk.img")
        guard let disk else { return nil }
        return (try? fileManager.attributesOfItem(atPath: disk.path)[.size] as? Int64) ?? nil
    }

    public func queuedStarts() async -> Int {
        await store.pool.queuedCount
    }

    public func planRetier(environmentID: String, ramMB: Int) async throws {
        try await store.pool.validateRetier(
            environmentID: environmentID,
            tier: RuntimeMemoryTier.tier(forRequestedMB: ramMB)
        )
    }

    public func confirmTier(environmentID: String, ramMB: Int) async {
        guard let slot = await store.pool.slot(environmentID: environmentID) else { return }
        await store.pool.confirmRetier(
            runtimeID: slot.runtimeID,
            tier: RuntimeMemoryTier.tier(forRequestedMB: ramMB)
        )
    }
}

/// Image resolver that prefers Runtime v2 expanded (verified) images and
/// falls back to the legacy images directory for not-yet-migrated installs.
/// Status can therefore never report "uninstalled" for an image the verified
/// guest is actually running, whether or not its legacy directory was
/// already moved aside by migration.
public struct RuntimeV2CompositeImageResolver: LinuxGuestImageResolving {
    private let expanded: FileLinuxGuestImageResolver
    private let legacy: any LinuxGuestImageResolving
    private let verifiedGate: @Sendable (String) async -> Bool

    public init(
        expandedImagesRoot: URL,
        legacy: any LinuxGuestImageResolving,
        verifiedGate: @escaping @Sendable (String) async -> Bool
    ) {
        self.expanded = FileLinuxGuestImageResolver(root: expandedImagesRoot)
        self.legacy = legacy
        self.verifiedGate = verifiedGate
    }

    public var imageRoot: URL? { legacy.imageRoot }

    /// Root used for structural qualification of a specific id: the expanded
    /// root when that image is expanded, else the legacy root.
    public func qualificationRoot(id: String) async -> URL? {
        if await expanded.linuxGuestImage(id: id) != nil { return expanded.root }
        return legacy.imageRoot
    }

    public func linuxGuestImage(id: String) async -> LinuxGuestImage? {
        if await verifiedGate(id), let image = await expanded.linuxGuestImage(id: id) {
            return image
        }
        return await legacy.linuxGuestImage(id: id)
    }

    public func linuxGuestImageVerificationFailure(id: String) async -> String? {
        if await verifiedGate(id), await expanded.linuxGuestImage(id: id) != nil {
            return await expanded.linuxGuestImageVerificationFailure(id: id)
        }
        return await legacy.linuxGuestImageVerificationFailure(id: id)
    }
}
