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

/// The durable result of a confirmed stop, so the guest registry/UI can say
/// what actually happened to the working disk instead of assuming success.
public enum RuntimeV2StopOutcome: Sendable, Equatable {
    /// There was no working disk to capture (nothing was materialized).
    case noWorkingDisk
    /// The guest state is durably in the environment's delta.
    case captured(generation: UInt64)
    /// The guest state could NOT be captured; the complete disk was preserved
    /// (recovery/quarantine) and the environment was marked repairRequired.
    case retainedForRepair(reason: String)
    /// The stop did not confirm: the VM may still be running on the disk.
    case notStopped
    /// The conformer does not report stop outcomes.
    case unknown
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
    ///
    /// `imageID` must be the image the start will actually boot — the
    /// environment descriptor's image id. The caller proves this obligation:
    /// the working disk is materialized from `prepareWorkingDisk(imageID:)`,
    /// which for a pinned environment fails closed unless the pinned
    /// template's root base image IS this image (`templateBaseImageMismatch`),
    /// and for a base-only environment clones this image's verified rootfs and
    /// boots its kernel/BIOS; the boot then freezes `baseImageID` into the
    /// runtime metadata and capture re-checks it. The SMP gate below evaluates
    /// exactly this image's verified manifest — never a different image and
    /// never the engine query — so the admission verdict is always about the
    /// kernel/firmware/disk view the guest will really start with.
    func acquireShape(
        environmentID: String, runtimeID: String, imageID: String,
        request: GuestResourceRequest,
        downgrade: GuestShapeDowngradePolicy
    ) async throws -> LinuxGuestShapeAdmission
    /// Validates a requested shape change (vCPU and/or RAM) against the pool
    /// quota and the image capability BEFORE the stop/flush/restart path.
    /// `imageID` is the image the running guest booted (the descriptor image
    /// it will boot again after the restart, frozen in its runtime metadata);
    /// the SMP gate evaluates exactly this image.
    func planReshape(
        environmentID: String, ramMB: Int, vcpus: Int, currentVCPUs: Int, imageID: String
    ) async throws
    /// Records the shape a completed stop → flush → restart made true.
    func confirmReshape(environmentID: String, ramMB: Int, vcpus: Int) async
    /// SMP capability proven by the canonical image manifest (never by an
    /// engine query and never assumed). Default false.
    func imageSMPCapable(imageID: String) async -> Bool
    /// Maximum core count proved by this exact verified image.
    func imageMaximumVCPUs(imageID: String) async -> Int
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
    /// Inspection-only real-file health of a Runtime v2 image: registry row,
    /// v2 manifest, the actual expanded bytes and (when the view needs
    /// rebuilding) referenced-blob availability. `nil` when the v2 store does
    /// not hold this image. Never migrates, rebuilds or downloads.
    func imageHealth(imageID: String) async -> RuntimeV2ImageStore.ImageHealth?
    /// Explicit re-verification: drops the cached success fingerprint before
    /// re-reading the actual bytes. Never migrates or downloads.
    func reverifyImageHealth(imageID: String) async -> RuntimeV2ImageStore.ImageHealth?
    /// Rebuilds the expanded boot view from verified blobs (no download).
    /// Throws `RuntimeV2Error.blobMissing` when a referenced blob is gone,
    /// and `CancellationError` when `isCancelled` fires between artifacts. The
    /// previous view is never replaced by a partial one.
    func reconstructExpandedImage(imageID: String, isCancelled: (@Sendable () -> Bool)?) async throws
    /// Same-id repair after `installTrustedImage` promoted a verified
    /// replacement into the legacy directory: re-hashes/re-places the v2
    /// blobs and rebuilds the expanded view so a migrated image does not keep
    /// booting damaged bytes. Observed `isCancelled` stops between blobs and
    /// before the switch; quarantined evidence is preserved either way.
    func repairImageFromLegacyInstall(imageID: String, isCancelled: (@Sendable () -> Bool)?) async throws
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
    /// Result-carrying stop for callers (guest registry/UI) that need the
    /// durable outcome. A REQUIREMENT (not only an extension method) so the
    /// real implementation is reached through the existential `any
    /// LinuxGuestRuntimeV2Integrating`: a refused capture is never reported
    /// as `.unknown`, and `retainedForRepair` keeps its truthful reason.
    /// Conformers that only implement the legacy `completeStop` keep the
    /// compatible default below, which reports `.unknown` honestly.
    func completeStopResult(
        environmentID: String, runtimeID: String, imageID: String, clean: Bool
    ) async -> RuntimeV2StopOutcome
    /// VERIFIED repair resolution for an environment the store excludes after
    /// a failed stop capture: provenance + content verification of the
    /// preserved bytes, capture into the environment delta, durable commit.
    /// Throws `RuntimeV2Error.repairResolutionUnavailable` when no exclusion
    /// exists or the preserved bytes cannot be proven; the preserved bytes and
    /// the exclusion are never touched on any failure path.
    func restoreRepair(environmentID: String) async throws -> RuntimeV2Store.RepairResolutionReport
}

public extension LinuxGuestRuntimeV2Integrating {
    /// Conservative default for conformers that cannot evaluate image
    /// manifests: a capability that is not proven is false. The production
    /// integrator overrides this with the verified image manifest's own
    /// declaration — never an engine query.
    func imageSMPCapable(imageID: String) async -> Bool { false }
    func imageMaximumVCPUs(imageID: String) async -> Int {
        await imageSMPCapable(imageID: imageID) ? 2 : 1
    }

    /// Compatible default for conformers that predate the result-carrying
    /// stop: runs the legacy `completeStop` and reports `unknown` honestly.
    func completeStopResult(
        environmentID: String, runtimeID: String, imageID: String, clean: Bool
    ) async -> RuntimeV2StopOutcome {
        await completeStop(
            environmentID: environmentID, runtimeID: runtimeID, imageID: imageID, clean: clean
        )
        return .unknown
    }

    /// Conservative defaults for scripted test integrators: no real image
    /// substrate answers "not held" / "cannot repair" instead of inventing
    /// verified truth.
    func imageHealth(imageID: String) async -> RuntimeV2ImageStore.ImageHealth? { nil }

    func reverifyImageHealth(imageID: String) async -> RuntimeV2ImageStore.ImageHealth? { nil }

    func reconstructExpandedImage(imageID: String, isCancelled: (@Sendable () -> Bool)?) async throws {
        throw RuntimeV2Error.imageNotFound(imageID)
    }

    func repairImageFromLegacyInstall(imageID: String, isCancelled: (@Sendable () -> Bool)?) async throws {
        throw RuntimeV2Error.imageNotFound(imageID)
    }

    /// Conservative default for conformers without a repair substrate: the
    /// resolution refuses honestly instead of inventing a repair.
    func restoreRepair(environmentID: String) async throws -> RuntimeV2Store.RepairResolutionReport {
        throw RuntimeV2Error.repairResolutionUnavailable(
            environmentID: environmentID,
            reason: "this Runtime v2 substrate does not support repair resolution"
        )
    }
}

/// Production integrator backed by a RuntimeV2Store.
public actor RuntimeV2GuestIntegrator: LinuxGuestRuntimeV2Integrating {
    /// Injectable persistence seams so the failed-capture retention path can
    /// be driven with a fault at EACH individual durable stage (shutdown
    /// record vs repair marker) and prove the lease is kept either way.
    public struct Seams: Sendable {
        /// Replaces the durable shutdown-record write after a failed capture
        /// (throw to inject an IO fault at exactly that stage). nil = normal.
        public var recordShutdown: (@Sendable (RuntimeV2DeltaStore.ShutdownRecord, String) async throws -> Void)?
        /// Replaces the durable repairRequired transition (throw to inject a
        /// registry fault at exactly that stage). nil = normal.
        public var markRepairRequired: (@Sendable (String, String) async throws -> Void)?
        /// Replaces the durable non-expiring repair-hold placement (throw to
        /// inject a IO/full-disk fault at exactly that stage). nil = normal.
        public var placeRepairHold: (@Sendable (String, String, String, String?) async throws -> Void)?
        /// Replaces the one-time startup recovery pass (count or park it in
        /// focused tests to prove concurrent first uses share a single
        /// preparation). nil = normal.
        public var prepareAndRecover: (@Sendable (String) async throws -> Void)?
        /// Replaces the bounded backoff between stop-capture retry attempts
        /// (tests inject a no-op so the retry loop is deterministic;
        /// production sleeps). nil = the production backoff schedule.
        public var captureRetryDelay: (@Sendable (Int) async -> Void)?

        public init(
            recordShutdown: (@Sendable (RuntimeV2DeltaStore.ShutdownRecord, String) async throws -> Void)? = nil,
            markRepairRequired: (@Sendable (String, String) async throws -> Void)? = nil,
            placeRepairHold: (@Sendable (String, String, String, String?) async throws -> Void)? = nil,
            prepareAndRecover: (@Sendable (String) async throws -> Void)? = nil,
            captureRetryDelay: (@Sendable (Int) async -> Void)? = nil
        ) {
            self.recordShutdown = recordShutdown
            self.markRepairRequired = markRepairRequired
            self.placeRepairHold = placeRepairHold
            self.prepareAndRecover = prepareAndRecover
            self.captureRetryDelay = captureRetryDelay
        }

        public static let production = Seams()
    }

    private let store: RuntimeV2Store
    private let legacyImagesRoot: URL?
    private let build: String
    private let seams: Seams
    private var fileManager: FileManager { .default }
    private var prepared = false
    /// The single in-flight first-preparation pass. Concurrent first uses
    /// (a guest start, shell auto-preparation, a settings/terminal status
    /// read) join this one task instead of each running the full multi-
    /// gigabyte recovery themselves; on a device whose recovery hashes and
    /// re-materializes gigabytes, N concurrent first uses used to mean N
    /// complete recovery passes in the first-use critical path. Proven by
    /// `LinuxGuestFirstUsePreparationTests` (the device report itself shows
    /// the spinner/no-receipt symptom, not which pass count ran). nil again
    /// after failure so the next Linux use retries; success flips `prepared`.
    private var preparationFlight: PreparationFlight?
    /// Latest recovery stage observed by the shared pass, and the sink that
    /// forwards stages to the app (diagnostic progress for the storage-init
    /// presentation). Stage reporting never changes recovery semantics.
    private var latestStage: RuntimeV2Store.RecoveryStage?
    private var stageHandler: (@Sendable (RuntimeV2Store.RecoveryStage) -> Void)?
    /// Held leases by runtimeID so completeStop releases exactly its own. A
    /// lease kept here after a persistence failure is the surviving exclusion:
    /// it is NOT treated as stale by a later acquire in this process.
    private var heldLeases: [String: RuntimeV2LeaseStore.HeldLease] = [:]

    public init(
        store: RuntimeV2Store,
        legacyImagesRoot: URL? = nil,
        build: String? = nil,
        seams: Seams = .production,
        preparationStageHandler: (@Sendable (RuntimeV2Store.RecoveryStage) -> Void)? = nil
    ) {
        self.store = store
        self.legacyImagesRoot = legacyImagesRoot
        self.seams = seams
        self.build = build
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            ?? "unknown"
        // Installed in the initializer, not via the actor-isolated setter:
        // a synchronous assembly context (the app's non-async backend wiring)
        // can hand the handler over at construction and it is stored before the
        // integrator is observable to anyone — no unstructured Task and no
        // window in which a recovery pass could start without the sink. The
        // setter remains for async contexts (tests, replacement).
        self.stageHandler = preparationStageHandler
    }

    /// Installs the sink that receives startup-recovery stages from the
    /// shared preparation pass. The app wires this to its storage-init
    /// progress presentation; tests observe stage order. Callers in a
    /// synchronous context instead pass the handler to the initializer so it
    /// is registered before the integrator becomes reachable.
    public func setPreparationStageHandler(
        _ handler: (@Sendable (RuntimeV2Store.RecoveryStage) -> Void)?
    ) {
        stageHandler = handler
    }

    /// The latest recovery stage the shared pass reported (nil before any
    /// pass). Diagnostic progress truth for the storage-init presentation.
    public func preparationStage() -> RuntimeV2Store.RecoveryStage? {
        latestStage
    }

    /// Identity and waiter registry for one shared preparation pass. `Task`
    /// is a value type and cannot be compared, so the recorded flight is
    /// matched by reference; a finished or abandoned pass is cleared only by
    /// a caller still holding the current flight.
    ///
    /// Waiters are explicit continuations, not child tasks: resolving one
    /// caller's wait with `CancellationError` NEVER touches the shared task —
    /// recovery mutates durable state and must run to completion even when
    /// every caller has gone away.
    private final class PreparationFlight: @unchecked Sendable {
        enum Terminal {
            case success
            case failure(Error)
        }

        private let lock = NSLock()
        private var terminal: Terminal?
        private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

        init(task: Task<Void, Error>) {
            // Dedicated completion observer: resumes every registered waiter
            // exactly once when the shared task settles. The task itself is
            // never cancelled through this path.
            Task {
                let result = await task.result
                switch result {
                case .success:
                    complete(.success)
                case .failure(let error):
                    complete(.failure(error))
                }
            }
        }

        /// False when the pass already finished; the caller takes the inline
        /// terminal path instead of registering.
        func register(_ id: UUID, continuation: CheckedContinuation<Void, Error>) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard terminal == nil else { return false }
            waiters[id] = continuation
            return true
        }

        /// Removes and returns one waiter so an external cancellation can
        /// resolve exactly that caller. Returns nil when the flight already
        /// settled or the waiter was already withdrawn — the resume happened
        /// or will happen exactly once through the other path.
        func withdraw(_ id: UUID) -> CheckedContinuation<Void, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return waiters.removeValue(forKey: id)
        }

        func isSettled() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return terminal != nil
        }

        /// The settled terminal state, for inline completion after a
        /// register race.
        func settled() -> Terminal {
            lock.lock()
            defer { lock.unlock() }
            return terminal ?? .success
        }

        /// Resumes one waiter inline from the recorded terminal state.
        func resumeInline(_ continuation: CheckedContinuation<Void, Error>) {
            switch settled() {
            case .success:
                continuation.resume(returning: ())
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }

        private func complete(_ outcome: Terminal) {
            lock.lock()
            guard terminal == nil else {
                lock.unlock()
                return
            }
            terminal = outcome
            let pending = waiters
            waiters.removeAll()
            lock.unlock()
            for (_, continuation) in pending {
                resume(continuation, with: outcome)
            }
        }

        private func resume(_ continuation: CheckedContinuation<Void, Error>, with outcome: Terminal) {
            switch outcome {
            case .success:
                continuation.resume(returning: ())
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    /// Builds the shared preparation flight. The stage sink captures the
    /// integrator strongly: the pass may outlive any single caller, stage
    /// reporting is diagnostic-only, and the recorded flight is released as
    /// soon as the pass settles (no permanent cycle).
    private func startPreparationFlight() -> PreparationFlight {
        let store = self.store
        let build = self.build
        let seams = self.seams
        let stageSink: @Sendable (RuntimeV2Store.RecoveryStage) -> Void = { [self] stage in
            Task { await self.recordPreparationStage(stage) }
        }
        let task = Task<Void, Error> {
            if let prepare = seams.prepareAndRecover {
                try await prepare(build)
            } else {
                _ = try await store.prepareAndRecover(build: build, onStage: stageSink)
            }
        }
        return PreparationFlight(task: task)
    }

    private func ensurePrepared(isCancelled: (@Sendable () -> Bool)? = nil) async throws {
        if prepared { return }
        let flight: PreparationFlight
        if let existing = preparationFlight {
            flight = existing
        } else {
            flight = startPreparationFlight()
            preparationFlight = flight
        }
        do {
            try await joinPreparation(flight, isCancelled: isCancelled)
        } catch is CancellationError {
            // Only this caller's wait is abandoned; the shared pass is never
            // cancelled. The flight stays recorded so joiners (or the next
            // use) observe its completion and flip `prepared`.
            throw CancellationError()
        } catch {
            // A failed pass publishes nothing and stays retryable: the next
            // Linux use starts a fresh recovery instead of joining a
            // completed failure.
            if preparationFlight === flight {
                preparationFlight = nil
            }
            throw error
        }
        // Completion observed by this caller: cache it and release the
        // finished flight when this caller is still the recorded one.
        prepared = true
        if preparationFlight === flight {
            preparationFlight = nil
        }
    }

    private func recordPreparationStage(_ stage: RuntimeV2Store.RecoveryStage) {
        latestStage = stage
        stageHandler?(stage)
    }

    /// Bounded watcher for token-based cancellation: while the flight is
    /// unsettled it polls the caller's token and resolves exactly that waiter
    /// when it fires; it stops as soon as the flight settles, the waiter is
    /// withdrawn, or it is cancelled. Task-cancellation needs no watcher —
    /// `withTaskCancellationHandler` covers it.
    private func startTokenWatcher(
        flight: PreparationFlight,
        waiterID: UUID,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> Task<Void, Never> {
        Task {
            while true {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
                if flight.isSettled() { return }
                if isCancelled() {
                    if let continuation = flight.withdraw(waiterID) {
                        continuation.resume(throwing: CancellationError())
                    }
                    return
                }
            }
        }
    }

    /// Waits for the shared pass through the flight's waiter registry. The
    /// moment the CALLER's own cancellation fires — task cancellation via the
    /// handler, or a token via the bounded watcher — its continuation is
    /// resolved with `CancellationError` and the wait finishes, while the
    /// shared pass keeps running untouched.
    ///
    /// Every racing path resolves the continuation exactly once:
    /// cancel-before-register is caught by the inline cancellation check;
    /// cancel-between-register-and-recheck by the post-registration withdraw
    /// (the handler/watcher withdrew nothing, so this withdraw wins);
    /// cancel-after-registration by the handler/watcher withdraw; and a
    /// settle-before-register by the inline terminal path. `withdraw` returns
    /// non-nil for at most one resolver, and a settled flight resumes each
    /// waiter exactly once.
    private func joinPreparation(
        _ flight: PreparationFlight,
        isCancelled: (@Sendable () -> Bool)?
    ) async throws {
        if let isCancelled, isCancelled() {
            throw CancellationError()
        }
        let waiterID = UUID()
        let watcher = isCancelled.map {
            startTokenWatcher(flight: flight, waiterID: waiterID, isCancelled: $0)
        }
        defer { watcher?.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Cancellation may have fired before registration and removed
                // nothing: settle inline in that case.
                if Task.isCancelled || isCancelled?() == true {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard flight.register(waiterID, continuation: continuation) else {
                    // The pass settled between the pre-check and registration.
                    flight.resumeInline(continuation)
                    return
                }
                // Register-then-cancel race: a cancellation that fired between
                // the inline check and registration found nothing to withdraw.
                // Probe once more; this withdraw wins exactly-once when so.
                if Task.isCancelled || isCancelled?() == true {
                    if let registered = flight.withdraw(waiterID) {
                        registered.resume(throwing: CancellationError())
                    }
                }
            }
        } onCancel: {
            watcher?.cancel()
            if let continuation = flight.withdraw(waiterID) {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    private func ensureImageMigrated(_ imageID: String) async throws {
        try await ensurePrepared()
        if (try? await store.images.isImageVerified(imageID: imageID)) == true { return }
        guard let legacyImagesRoot else { throw RuntimeV2Error.imageNotFound(imageID) }
        try RuntimeV2Identifier.validate(imageID, kind: .image)
        let legacyDirectory = legacyImagesRoot.appendingPathComponent(imageID, isDirectory: true)
        // A fresh installation has no legacy image to migrate. Preserve the
        // missing-image contract so the UI offers installation; existing but
        // corrupt installs still go through migration and retain its error.
        guard FileManager.default.fileExists(atPath: legacyDirectory.path) else {
            throw RuntimeV2Error.imageNotFound(imageID)
        }
        _ = try await store.images.migrateLegacyImage(
            imageID: imageID, legacyImagesRoot: legacyImagesRoot
        )
    }

    public func acquireSlot(environmentID: String, runtimeID: String, requestedMB: Int) async throws -> RuntimeV2Admission {
        try await ensurePrepared(isCancelled: { Task.isCancelled })
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
    /// engine-derived guess). The SMP gate evaluates the verified manifest of
    /// `imageID` — the image this start boots (see the protocol requirement);
    /// the engine gate (`floe_vm_smp_capable`) is deliberately never consulted.
    public func acquireShape(
        environmentID: String, runtimeID: String, imageID: String,
        request: GuestResourceRequest,
        downgrade: GuestShapeDowngradePolicy
    ) async throws -> LinuxGuestShapeAdmission {
        try await ensurePrepared(isCancelled: { Task.isCancelled })
        // Import existing verified bytes before asking their capability. On
        // first launch the legacy image may be present but not yet have a v2
        // row; absence of that row is not proof of a single-core image.
        do {
            try await ensureImageMigrated(imageID)
        } catch RuntimeV2Error.imageNotFound {
            throw LinuxGuestError.imageNotQualified(
                environmentID: environmentID, reason: "The Linux image \(imageID) is not installed."
            )
        }
        let imageMaximum = await imageMaximumVCPUs(imageID: imageID)
        let granted = try await store.pool.acquire(
            environmentID: environmentID, runtimeID: runtimeID,
            request: request, imageSMPCapable: imageMaximum >= 2,
            imageMaximumVCPUs: imageMaximum, downgrade: downgrade
        )
        let reason = granted.vcpusDowngradeReason ?? granted.memoryDowngradeReason
        return LinuxGuestShapeAdmission(
            runtimeID: granted.runtimeID,
            ramMB: granted.shape.memory.mb,
            vcpus: granted.shape.vcpus.count,
            downgraded: granted.wasDowngraded,
            vcpusDowngraded: granted.vcpusDowngraded,
            downgradeReason: reason
        )
    }

    /// Validates a vCPU/RAM change against the release gate, pool quota and
    /// the image's SMP proof before any disruption. Nothing is stopped if
    /// this throws. The loose integer is validated, never clamped: a count
    /// outside the release ladder throws an actionable error, and a second
    /// hart requires the image the guest booted (`imageID`, the descriptor's
    /// image it will boot again after the restart) to prove SMP — a manifest
    /// claim on any other image is not authority.
    public func planReshape(
        environmentID: String, ramMB: Int, vcpus: Int, currentVCPUs: Int, imageID: String
    ) async throws {
        try await ensurePrepared()
        let policy = await store.pool.releasePolicy
        let resolvedVCPUs = try policy.resolve(requestedVCPUs: vcpus)
        let imageMaximum = await imageMaximumVCPUs(imageID: imageID)
        let request = GuestResourceRequest(
            vcpus: resolvedVCPUs,
            memory: GuestMemoryMiB.smallestHolding(max(0, ramMB)) ?? .m2048,
            origin: .environmentPolicy
        )
        try await store.pool.validateShapeChange(
            environmentID: environmentID, request: request,
            imageSMPCapable: imageMaximum >= 2, imageMaximumVCPUs: imageMaximum
        )
    }

    /// Records the shape a completed stop → flush → restart actually made
    /// true. The reported count goes through the same release gate: a
    /// restart result this release did not qualify (a second hart) is never
    /// recorded into pool accounting, so a direct engine start cannot
    /// widen the lease.
    public func confirmReshape(environmentID: String, ramMB: Int, vcpus: Int) async {
        guard let slot = await store.pool.slot(environmentID: environmentID) else { return }
        do {
            let policy = await store.pool.releasePolicy
            let resolvedVCPUs = try policy.resolve(requestedVCPUs: vcpus)
            let shape = GuestResourceRequest(
                vcpus: resolvedVCPUs,
                memory: GuestMemoryMiB.smallestHolding(max(0, ramMB)) ?? .m2048,
                origin: .environmentPolicy
            )
            await store.pool.confirmShape(runtimeID: slot.runtimeID, shape: shape)
        } catch {
            await store.logs.log(
                "runtime v2 reshape confirmation refused an unqualified vCPU count \(vcpus) for environment=\(environmentID): \(error.localizedDescription); the lease shape was not changed"
            )
        }
    }

    /// SMP capability proven by the verified image manifest. Absent or false
    /// declarations answer false; the engine query is never consulted.
    public func imageSMPCapable(imageID: String) async -> Bool {
        (try? await store.images.smpCapability(imageID: imageID))?.capable ?? false
    }

    public func imageMaximumVCPUs(imageID: String) async -> Int {
        (try? await store.images.smpCapability(imageID: imageID))?.maximumVCPUs ?? 1
    }

    /// The environment's immutable template pin, when one is recorded.
    public func environmentTemplatePin(environmentID: String) async -> RuntimeV2TemplatePin? {
        try? await store.templates.environmentPin(environmentID: environmentID)
    }

    /// The image whose kernel/BIOS a pinned environment's working disk boots
    /// with: the pinned template version's root base image. nil for an
    /// unpinned environment (the caller keeps its configured default image).
    public func environmentTemplateBaseImageID(environmentID: String) async -> String? {
        guard let pin = try? await store.templates.environmentPin(environmentID: environmentID) else {
            return nil
        }
        return try? await store.templates.baseImageID(templateID: pin.templateID, version: pin.version)
    }

    /// Rollback for a pinned-environment creation whose pin never completed:
    /// removes the just-created, never-started row (the registry guards on
    /// state + leases) so a half-created environment is never published.
    public func rollbackPinnedEnvironment(environmentID: String) async {
        _ = try? await store.registry.removeEnvironmentRow(environmentID: environmentID)
    }

    /// Creates (or reuses) the durable Runtime v2 environment row for a NEW
    /// environment and pins it to exactly one verified template version. The
    /// row is created with the template's root base image so the boot path
    /// resolves the template's own kernel/BIOS; an existing row on a different
    /// base is refused rather than silently re-pointed. The pin itself still
    /// goes through `RuntimeV2TemplateStore.pinEnvironment` (single registry
    /// transaction, refuses while a write lease is held).
    @discardableResult
    public func registerPinnedEnvironment(
        environmentID: String,
        name: String?,
        templateID: String,
        version: Int
    ) async throws -> RuntimeV2TemplatePin {
        guard let row = try await store.templates.version(templateID: templateID, version: version) else {
            throw RuntimeV2Error.templateNotFound(templateID: templateID, version: version)
        }
        guard row.state == .verified, row.diskDigest != nil else {
            throw RuntimeV2Error.templateNotVerified(
                templateID: templateID, version: version, reason: row.reason
            )
        }
        let rootImage = try await store.templates.baseImageID(templateID: templateID, version: version)
        let diskDigest = (row.diskDigest ?? "").lowercased()
        let now = Date()
        if let existing = try await store.registry.environment(id: environmentID) {
            if let base = existing.baseImageID, base != rootImage {
                throw RuntimeV2Error.templateBaseImageMismatch(
                    environmentID: environmentID, templateBaseImage: rootImage,
                    environmentBaseImage: base
                )
            }
        } else {
            try await store.registry.upsertEnvironment(RuntimeV2Registry.EnvironmentRow(
                id: environmentID, kind: "linuxVM", ownerID: nil, name: name,
                baseImageID: rootImage, baseRootfsDigest: diskDigest.isEmpty ? nil : diskDigest,
                state: "stopped", dataPath: "environments/\(environmentID)/data",
                compatHostFHS: false, repairReason: nil, createdAt: now, lastUsedAt: now
            ))
            // The repairable sidecar records the same truth so a damaged
            // registry can be rebuilt from verified files (the registry stays
            // authoritative; the sidecar is best-effort).
            let metadata = RuntimeV2EnvironmentMigrator.EnvironmentMetadata(
                environmentID: environmentID, kind: "linuxVM", ownerID: nil, name: name,
                baseImageID: rootImage,
                baseRootfsSHA512: diskDigest.isEmpty ? row.parentDigest : diskDigest,
                compatHostFHS: false, createdAt: now, migratedAt: nil,
                templateID: templateID, templateVersion: version, templateDigest: row.digest
            )
            try? await RuntimeV2EnvironmentMigrator(store: store).writeMetadata(
                metadata, environmentID: environmentID
            )
        }
        return try await store.templates.pinEnvironment(
            environmentID: environmentID, templateID: templateID, version: version
        )
    }

    public func releaseSlot(environmentID: String, runtimeID: String) async {
        await store.pool.release(runtimeID: runtimeID)
        try? await store.registry.releasePorts(runtimeID: runtimeID)
    }

    public func prepareWorkingDisk(
        environmentID: String, runtimeID: String, imageID: String,
        legacyWritableDirectory: URL?, targetCapacityBytes: Int64
    ) async throws -> RuntimeV2WorkingDisk {
        // Fail closed BEFORE anything else (including image migration): an
        // environment whose state is repairRequired, or whose durable
        // repair exclusion answers from ANY physical evidence (marker sidecar
        // — valid or corrupt — preserved quarantine bytes, or an untracked
        // working disk), must never boot a fresh empty data/delta over
        // preserved data, on any retry — even when every marker/registry
        // write was the thing that failed (the physical bytes are the
        // fault-surviving exclusion).
        if let row = try await store.registry.environment(id: environmentID),
           row.state == "repairRequired" {
            throw RuntimeV2Error.environmentRepairRequired(
                environmentID: environmentID, reason: row.repairReason
            )
        }
        if let hold = await store.leases.effectiveExclusion(environmentID: environmentID) {
            throw RuntimeV2Error.environmentRepairRequired(
                environmentID: environmentID, reason: hold.reason
            )
        }
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
        // Lease first: single writable ownership of the environment's delta.
        // In-process staleness is already proven by the caller: the registry
        // only reaches here when no session exists, no teardown is in flight
        // and the environment is not quarantined, so no live VM/thread/disk
        // handle references it. A lease from THIS process incarnation is
        // therefore provably stale here — EXCEPT a lease this integrator still
        // holds: that is the surviving exclusion of a failed capture whose
        // repair marker could not be persisted, and treating it as stale
        // would let a fresh start overwrite preserved state. Any other
        // incarnation falls back to the store's cross-process proof (recorded
        // pid dead + TTL expired).
        let ownIncarnation = await store.leases.incarnation
        let staleProof: RuntimeV2LeaseStore.StaleProof = { [weak self] lease in
            if lease.incarnation == ownIncarnation {
                guard let self else { return false }
                return await self.heldLeases[lease.runtimeID] == nil
            }
            return RuntimeV2LeaseStore.processLiveness(lease: lease)
        }
        let lease = try await store.leases.acquire(
            environmentID: environmentID, runtimeID: runtimeID, staleProof: staleProof
        )
        heldLeases[runtimeID] = lease

        let directory = try store.layout.runtimeVMDirectory(runtimeID: runtimeID)
        let diskURL = directory.appendingPathComponent("disk.img")
        let materializedCapacity: Int64
        do {
            guard let manifest = try await store.images.manifest(imageID: imageID),
                  let rootfsRef = manifest.artifacts["rootfs"] ?? manifest.artifacts["disk"],
                  try await store.images.isImageVerified(imageID: imageID) else {
                throw RuntimeV2Error.unverifiedImageReferenced(imageID)
            }
            let expanded = try await store.images.ensureExpanded(imageID: imageID)
            let baseRootfs = expanded.appendingPathComponent(rootfsRef.expandedPath)

            // Resolve the exact boot base BEFORE any bytes are written. For a
            // pinned environment that is the pinned template's immutable disk;
            // for an unpinned one, the verified base rootfs. The resolution
            // fails closed when the pin is unavailable — no boot happens on a
            // different base.
            let deltaBase = try await store.templates.deltaBase(
                environmentID: environmentID, imageID: imageID,
                baseRootfs: baseRootfs, baseRootfsSHA512: rootfsRef.sha512
            )
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            // Freeze the FULL boot base durably (template id/version/digest AND
            // the SHA-512 of the disk bytes) before cloning: a stop or crash
            // recovery must prove which base the disk was cloned from even if
            // the pin moves later. Never derived from the current pin at
            // capture time.
            try RuntimeV2WorkingDirectory.writeMeta(
                RuntimeV2WorkingDirectory.Meta(
                    runtimeID: runtimeID, environmentID: environmentID,
                    baseImageID: imageID, createdAt: Date(),
                    templateID: deltaBase.templatePin?.templateID,
                    templateVersion: deltaBase.templatePin?.version,
                    templateDigest: deltaBase.templatePin?.digest,
                    bootBaseDiskDigest: deltaBase.digest
                ),
                to: directory
            )
            if let pin = deltaBase.templatePin {
                // Deep reuse: the environment boots a clone of exactly the
                // pinned template version's complete disk plus its private
                // delta. The clone is validated against the resolved boot base
                // so an old delta can never land on different bytes.
                let clone = try await store.templates.clonePinnedTemplateDisk(
                    environmentID: environmentID, runtimeID: runtimeID,
                    imageID: imageID, into: diskURL, expecting: deltaBase
                )
                guard clone != nil else {
                    throw RuntimeV2Error.templatePinUnavailable(
                        environmentID: environmentID, templateID: pin.templateID,
                        version: pin.version,
                        reason: "the environment lost its pin between resolution and materialization"
                    )
                }
                materializedCapacity = try await store.deltas.applyDelta(
                    environmentID: environmentID,
                    expectedBaseRootfsSHA512: deltaBase.digest,
                    expectedTemplate: pin,
                    into: diskURL
                )
            } else {
                // Base-image-only environments keep the previous behavior
                // exactly; the delta is still bound to the verified base digest,
                // so a base swap can never silently absorb an old delta.
                materializedCapacity = try await store.deltas.materializeWorkingDisk(
                    environmentID: environmentID, baseRootfs: baseRootfs,
                    expectedBaseRootfsSHA512: deltaBase.digest,
                    expectedTemplate: nil,
                    into: diskURL
                )
            }
        } catch {
            // Nothing was booted: the freshly materialized disk is regenerable
            // from the untouched delta, so the working directory is removed and
            // the lease released instead of leaving a half-built runtime.
            try? fileManager.removeItem(at: directory)
            await lease.release()
            heldLeases[runtimeID] = nil
            throw error
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
    ///
    /// For a confirmed stop the capture base is the provenance recorded at boot
    /// (never the current environment pin). If the capture cannot be proven or
    /// fails, the working disk is NEVER deleted: it is quarantined, a durable
    /// shutdown error is recorded, the environment is marked repairRequired
    /// (so no fresh guest can boot over the preserved state) and only then is
    /// the lease released. The lease is released only when the guest really
    /// stopped and the failure state is durable.
    public func completeStop(environmentID: String, runtimeID: String, imageID: String, clean: Bool) async {
        _ = await completeStopReporting(
            environmentID: environmentID, runtimeID: runtimeID, imageID: imageID, clean: clean
        )
    }

    /// Result-carrying variant of `completeStop` (see `RuntimeV2StopOutcome`).
    public func completeStopResult(
        environmentID: String, runtimeID: String, imageID: String, clean: Bool
    ) async -> RuntimeV2StopOutcome {
        await completeStopReporting(
            environmentID: environmentID, runtimeID: runtimeID, imageID: imageID, clean: clean
        )
    }

    private func completeStopReporting(
        environmentID: String, runtimeID: String, imageID: String, clean: Bool
    ) async -> RuntimeV2StopOutcome {
        guard clean else {
            try? await store.deltas.recordShutdown(
                RuntimeV2DeltaStore.ShutdownRecord(
                    environmentID: environmentID, runtimeID: runtimeID, stoppedAt: Date(),
                    clean: false, deltaGeneration: nil,
                    detail: "stop did not confirm; the working disk and lease are retained for recovery"
                ),
                environmentID: environmentID
            )
            return .notStopped
        }
        let directory = try? store.layout.runtimeVMDirectory(runtimeID: runtimeID)
        let diskURL = directory?.appendingPathComponent("disk.img")
        guard let directory, let diskURL, fileManager.fileExists(atPath: diskURL.path) else {
            // No working disk to capture: sweep the (possibly empty) directory
            // and release the lease.
            if let directory, fileManager.fileExists(atPath: directory.path) {
                try? fileManager.removeItem(at: directory)
            }
            await releaseLease(environmentID: environmentID, runtimeID: runtimeID)
            return .noWorkingDisk
        }
        // Flush: the engine's fclose already flushed stdio; fsync before
        // the capture so the delta never records unflushed bytes.
        if let handle = try? FileHandle(forUpdating: diskURL) {
            try? handle.synchronize()
            try? handle.close()
        }
        do {
            guard let meta = RuntimeV2WorkingDirectory.readMeta(from: directory) else {
                throw RuntimeV2Error.workingDirectoryProvenanceUnavailable(
                    environmentID: environmentID,
                    reason: "the working directory has no ownership record; the disk cannot be attributed"
                )
            }
            guard meta.environmentID == environmentID else {
                throw RuntimeV2Error.workingDirectoryProvenanceUnavailable(
                    environmentID: environmentID,
                    reason: "the working directory belongs to \(meta.environmentID), not \(environmentID)"
                )
            }
            // Capture binds the delta to exactly the base the working disk was
            // cloned from: the pinned template's immutable disk when one was
            // pinned, else the verified base image rootfs. A pin that moved
            // while the guest ran is a provenance mismatch and refuses the
            // capture (the disk is preserved instead of being rewritten).
            //
            // A typed, known-transient access fault while opening or reading
            // either capture input (the stopped working disk or the base
            // rootfs) is retried a bounded number of times before the disk is
            // quarantined. The Build 238 device receipt recorded a raw,
            // errno-free "cannot open file" failure at this stage — its cause
            // is NOT proven, and these retries make no claim about it; they
            // only absorb faults whose errno classifies as transient once the
            // delta store reports typed errors. Provenance conflicts, digest
            // verdicts and every permanent or untyped error still fail closed
            // on the FIRST attempt — the disk is preserved, never rewritten,
            // and the environment is marked repairRequired exactly as before.
            // Nothing is deleted during retries and the staged delta writes
            // are idempotent against the previous generation.
            let info: RuntimeV2DeltaStore.DeltaInfo
            do {
                info = try await captureWithTransientRetry(
                    environmentID: environmentID, directory: directory,
                    diskURL: diskURL, meta: meta, imageID: imageID
                )
            } catch {
                let reason = await preserveAfterFailedCapture(
                    environmentID: environmentID, runtimeID: runtimeID,
                    directory: directory, error: error
                )
                return .retainedForRepair(reason: reason)
            }
            do {
                try await store.deltas.recordShutdown(
                    RuntimeV2DeltaStore.ShutdownRecord(
                        environmentID: environmentID, runtimeID: runtimeID,
                        stoppedAt: Date(), clean: true,
                        deltaGeneration: info.header.generation
                    ),
                    environmentID: environmentID
                )
            } catch {
                let reason = await preserveAfterFailedCapture(
                    environmentID: environmentID, runtimeID: runtimeID,
                    directory: directory, error: error
                )
                return .retainedForRepair(reason: reason)
            }
            try? fileManager.removeItem(at: directory)
            await releaseLease(environmentID: environmentID, runtimeID: runtimeID)
            return .captured(generation: info.header.generation)
        } catch {
            let reason = await preserveAfterFailedCapture(
                environmentID: environmentID, runtimeID: runtimeID,
                directory: directory, error: error
            )
            return .retainedForRepair(reason: reason)
        }
    }

    /// Total capture attempts for one clean stop: the initial try plus two
    /// bounded retries, only ever consumed by a transient access fault.
    static let captureAttempts = 3

    /// Production backoff between capture retry attempts (milliseconds). A
    /// real pause lets a momentary access condition (a busy file, a short
    /// memory-pressure window) clear; bounded so a stop can never stall
    /// unreasonably. Tests replace the delay through `Seams.captureRetryDelay`.
    static let captureRetryBackoffMs: [UInt64] = [250, 1000]

    /// True only for a typed, known-transient file access fault. Provenance
    /// conflicts, structural verdicts and untyped errors are permanent for
    /// this stop and must never be retried.
    static func isTransientCaptureIO(_ error: Error) -> Bool {
        guard let io = error as? FloeFileIOError else { return false }
        return io.isTransientAccessFailure
    }

    private func captureWithTransientRetry(
        environmentID: String, directory: URL, diskURL: URL,
        meta: RuntimeV2WorkingDirectory.Meta, imageID: String
    ) async throws -> RuntimeV2DeltaStore.DeltaInfo {
        // Once the guest is CONFIRMED stopped, the capture into the delta is
        // durable, integrator-owned work. The caller may be an incidentally
        // cancelled UI task (a Settings card torn down mid-stop), an expired
        // background task or a stopped agent run; its cancellation must not
        // abort the byte copy and misreport a perfectly healthy stopped disk
        // as unsaveable (the Build 241 `Swift.CancellationError` receipt).
        // The capture runs in an unstructured task that does not inherit the
        // caller's cancellation, so its own cancellation checks observe a task
        // the integrator owns. Genuine IO/provenance/digest failures (and the
        // bounded retry) are unchanged: they still flow into
        // `preserveAfterFailedCapture` and report `.retainedForRepair`.
        let capture = Task { () throws -> RuntimeV2DeltaStore.DeltaInfo in
            try await self.performCaptureAttempts(
                environmentID: environmentID, diskURL: diskURL, meta: meta, imageID: imageID
            )
        }
        return try await capture.value
    }

    /// The bounded capture retry loop itself. Runs on the integrator-owned
    /// capture task created by `captureWithTransientRetry`.
    private func performCaptureAttempts(
        environmentID: String, diskURL: URL,
        meta: RuntimeV2WorkingDirectory.Meta, imageID: String
    ) async throws -> RuntimeV2DeltaStore.DeltaInfo {
        var lastError: Error?
        for attempt in 1...Self.captureAttempts {
            do {
                // A capture attempt re-resolves the boot base: an interrupted
                // expanded view rebuild recovers instead of poisoning the
                // retry with a stale URL.
                let bootBase = try await store.templates.bootBase(
                    matching: meta, expectedImageID: imageID
                )
                return try await store.deltas.capture(
                    environmentID: environmentID,
                    workingDisk: diskURL,
                    baseRootfs: bootBase.diskURL,
                    baseImageID: meta.baseImageID,
                    baseRootfsSHA512: bootBase.digest,
                    templatePin: bootBase.templatePin
                )
            } catch {
                lastError = error
                let retryable = attempt < Self.captureAttempts
                    && Self.isTransientCaptureIO(error)
                    && fileManager.fileExists(atPath: diskURL.path)
                if !retryable { throw error }
                await store.logs.log(
                    "runtime v2 stop capture transient fault environment=\(environmentID) attempt=\(attempt)/\(Self.captureAttempts): \(error.localizedDescription); retrying"
                )
                if let delay = seams.captureRetryDelay {
                    await delay(attempt)
                } else {
                    let ms = Self.captureRetryBackoffMs[
                        min(attempt - 1, Self.captureRetryBackoffMs.count - 1)
                    ]
                    try? await Task.sleep(nanoseconds: ms * 1_000_000)
                }
            }
        }
        // Unreachable: the loop throws on the final attempt. Kept explicit so
        // the signature stays total without force-unwrapping in the hot path.
        struct ExhaustedCaptureRetries: Error {}
        _ = lastError
        throw ExhaustedCaptureRetries()
    }

    /// VERIFIED repair resolution for an environment the store excludes after
    /// a failed stop capture. See `RuntimeV2Store.restoreRepair`: the preserved
    /// bytes are proven (provenance + content) before anything moves, and any
    /// failure leaves the exclusion and the bytes fully in place.
    public func restoreRepair(environmentID: String) async throws -> RuntimeV2Store.RepairResolutionReport {
        try await store.restoreRepair(environmentID: environmentID)
    }

    /// Failed-capture retention. The complete stopped disk moves into
    /// recovery/quarantine (never deleted, never left as a bootable live
    /// duplicate) — that physical preservation is independent of persistence
    /// success. THEN the durable failure state is written in exclusion
    /// strength order: (1) the non-expiring repair hold — it survives process
    /// death, TTL expiry and stale-lease reclamation, so it is the durable
    /// cross-process exclusion; (2) the shutdown record; (3) the
    /// repairRequired marker. The TTL lease is released only when EVERY
    /// durable write committed; if any of them fails (full disk / IO / DB
    /// fault) the lease stays held as the surviving in-process exclusion and
    /// the returned outcome says so truthfully. When even the hold could not
    /// be persisted, the quarantined bytes themselves are the durable
    /// evidence: startup recovery re-derives the hold from the orphaned
    /// quarantine entry (RuntimeV2Store.recoverPreservedQuarantine), so the
    /// preserved state can never become undiscoverable.
    @discardableResult
    private func preserveAfterFailedCapture(
        environmentID: String, runtimeID: String, directory: URL, error: Error
    ) async -> String {
        let quarantine = store.layout.quarantineDirectory.appendingPathComponent(
            "runtime-vm-\(runtimeID)-\(UUID().uuidString)", isDirectory: true
        )
        let preserved: String
        let preservedPath: String
        if (try? fileManager.moveItem(at: directory, to: quarantine)) != nil {
            preservedPath = "recovery/quarantine/\(quarantine.lastPathComponent)"
            preserved = "the stopped working disk could not be captured into the delta "
                + "(\(error.localizedDescription)); the complete disk was preserved at "
                + preservedPath
        } else {
            preservedPath = "runtime/vm/\(runtimeID)"
            preserved = "the stopped working disk could not be captured into the delta "
                + "(\(error.localizedDescription)) and could not be quarantined; the disk remains "
                + "at \(preservedPath)"
        }
        let detail = preserved + " and the environment was marked repairRequired"
        let record = RuntimeV2DeltaStore.ShutdownRecord(
            environmentID: environmentID, runtimeID: runtimeID,
            stoppedAt: Date(), clean: false, deltaGeneration: nil, detail: detail
        )
        // 1. The durable non-expiring exclusion FIRST.
        do {
            if let placeRepairHold = seams.placeRepairHold {
                try await placeRepairHold(environmentID, runtimeID, detail, preservedPath)
            } else {
                try await store.repairHolds.place(
                    environmentID: environmentID, runtimeID: runtimeID,
                    reason: detail, preservedPath: preservedPath
                )
            }
        } catch {
            // The hold could not be persisted: keep the lease (the surviving
            // exclusion) and say so. No `try?` here converts preservation
            // failure into success, and releaseLease is deliberately NOT
            // called; the quarantined bytes remain discoverable to startup
            // recovery, which re-derives this hold on every launch.
            let retained = detail + "; additionally the durable repair hold could not be "
                + "persisted (\(error.localizedDescription)), so the write lease was "
                + "retained, the preserved bytes remain the authoritative evidence and the "
                + "environment cannot be restarted until repair is acknowledged"
            await store.logs.log("runtime v2 stop capture failed environment=\(environmentID): \(retained)")
            return retained
        }
        // 2. + 3. Shutdown record and repairRequired marker: both must commit
        // before the TTL lease is released.
        do {
            if let recordShutdown = seams.recordShutdown {
                try await recordShutdown(record, environmentID)
            } else {
                try await store.deltas.recordShutdown(record, environmentID: environmentID)
            }
            if let markRepairRequired = seams.markRepairRequired {
                try await markRepairRequired(environmentID, detail)
            } else {
                try await store.registry.setEnvironmentState(
                    id: environmentID, state: "repairRequired", repairReason: detail
                )
            }
        } catch {
            // Durable failure state could not be fully written: the hold
            // already excludes fresh starts cross-process, and the lease stays
            // held too until every durable write commits.
            let retained = detail + "; additionally the repair marker could not be "
                + "persisted (\(error.localizedDescription)), so the write lease was "
                + "retained and the environment cannot be restarted until repair"
            await store.logs.log("runtime v2 stop capture failed environment=\(environmentID): \(retained)")
            return retained
        }
        await releaseLease(environmentID: environmentID, runtimeID: runtimeID)
        await store.logs.log("runtime v2 stop capture failed environment=\(environmentID): \(detail)")
        return detail
    }

    private func releaseLease(environmentID: String, runtimeID: String) async {
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

    /// Inspection-only real-file health (see `RuntimeV2ImageStore.ImageHealth`).
    /// No migration, no rebuild, no download: failures answer `nil` rather
    /// than a fabricated state.
    public func imageHealth(imageID: String) async -> RuntimeV2ImageStore.ImageHealth? {
        do {
            try await ensurePrepared()
            return await store.images.imageHealth(imageID: imageID)
        } catch {
            return nil
        }
    }

    /// Cancellation-aware health. `.cancelled` means the caller's signal fired
    /// during a real-file hash: no verdict was produced and nothing was
    /// cached, so the caller must abort rather than treat it as an answer.
    public func imageHealth(
        imageID: String,
        isCancelled: (@Sendable () -> Bool)?
    ) async -> LinuxImageHealthCheck? {
        do {
            try await ensurePrepared(isCancelled: isCancelled)
        } catch is CancellationError {
            // The caller abandoned its wait (e.g. the card's refresh was
            // superseded): report the cooperative stop, never a verdict.
            return .cancelled
        } catch {
            return nil
        }
        return await store.images.imageHealth(imageID: imageID, isCancelled: isCancelled)
    }

    public func reverifyImageHealth(imageID: String) async -> RuntimeV2ImageStore.ImageHealth? {
        do {
            try await ensurePrepared()
            return await store.images.reverifyImageHealth(imageID: imageID)
        } catch {
            return nil
        }
    }

    /// Cancellation-aware explicit re-verification (see `imageHealth`).
    public func reverifyImageHealth(
        imageID: String,
        isCancelled: (@Sendable () -> Bool)?
    ) async -> LinuxImageHealthCheck? {
        do {
            try await ensurePrepared(isCancelled: isCancelled)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return nil
        }
        return await store.images.reverifyImageHealth(imageID: imageID, isCancelled: isCancelled)
    }

    public func reconstructExpandedImage(
        imageID: String,
        isCancelled: (@Sendable () -> Bool)?
    ) async throws {
        try await ensurePrepared()
        _ = try await store.images.reconstructExpandedImage(
            imageID: imageID, isCancelled: isCancelled
        )
    }

    public func repairImageFromLegacyInstall(
        imageID: String,
        isCancelled: (@Sendable () -> Bool)?
    ) async throws {
        try await ensurePrepared()
        guard let legacyImagesRoot else { throw RuntimeV2Error.imageNotFound(imageID) }
        _ = try await store.images.repairImageFromLegacyInstall(
            imageID: imageID, legacyImagesRoot: legacyImagesRoot, isCancelled: isCancelled
        )
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
