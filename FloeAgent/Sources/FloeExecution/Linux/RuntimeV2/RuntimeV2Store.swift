// FloeExecution — Runtime v2 facade: preparation, recovery, storage truth.
//
// RuntimeV2Store wires the layout, registry, blob/image stores, delta store,
// leases, pool, workspaces, caches and logs into one coherent substrate and
// owns app-start recovery. Recovery is the contract that runtime/ is always
// temporary: after a restart the substrate rebuilds exactly from the registry
// plus the environment sidecars, salvaging interrupted working disks through
// the normal verified capture path, marking interrupted sessions explicitly,
// quarantining corrupt sidecars and sweeping stale staging — never silently
// adopting state and never destroying recoverable data.

import Foundation
import FloeCore

public actor RuntimeV2Store {
    public struct RecoveryReport: Sendable, Equatable {
        public var interruptedQueueEntries: Int
        public var unreclaimableLeases: [String]
        public var salvagedRuntimeDirs: [String]
        public var quarantinedRuntimeDirs: [String]
        /// Leftover runtime dirs whose owner could NOT be proven stopped (a
        /// live or unexpired lease, an inconsistent ownership record, or an
        /// unknown environment): preserved byte-for-byte, never captured,
        /// moved or deleted.
        public var preservedRuntimeDirs: [String]
        /// Environments whose preserved quarantine disk was discovered
        /// orphaned (the stop-time repair marker could not be persisted) and
        /// was re-marked repairRequired with a durable repair hold.
        public var repairReapplied: [String]
        public var repairedImages: [String]
        public var rebuiltExpandedViews: [String]
        public var sweptStagingEntries: Int
        /// Interrupted template builds: marked failed honestly, never verified.
        public var interruptedTemplateBuilds: Int
        public var notes: [String]

        public init() {
            self.interruptedQueueEntries = 0
            self.unreclaimableLeases = []
            self.salvagedRuntimeDirs = []
            self.quarantinedRuntimeDirs = []
            self.preservedRuntimeDirs = []
            self.repairReapplied = []
            self.repairedImages = []
            self.rebuiltExpandedViews = []
            self.sweptStagingEntries = 0
            self.interruptedTemplateBuilds = 0
            self.notes = []
        }
    }

    /// Disk-usage truth for UI/statistics: shared base, per-environment delta,
    /// workspaces and caches are separated so nothing is double-counted.
    public struct StorageBreakdown: Sendable, Equatable {
        public var sharedBaseBlobBytes: Int64
        public var expandedRebuildableBytes: Int64
        public var environmentDeltaBytes: Int64
        public var environmentDataBytes: Int64
        public var workspaceOwnedBytes: Int64
        public var workspaceScratchBytes: Int64
        public var cacheBytes: Int64
        public var runtimeTemporaryBytes: Int64
        public var logBytes: Int64
        public var registryBytes: Int64
        /// Immutable template disks: logical bytes (what each version would
        /// occupy alone) and measured allocated bytes. Shared template disks
        /// are counted once here, never once per environment.
        public var templateLogicalBytes: Int64
        public var templateAllocatedBytes: Int64
        public var templateDownloadBytes: Int64

        public init() {
            sharedBaseBlobBytes = 0; expandedRebuildableBytes = 0
            environmentDeltaBytes = 0; environmentDataBytes = 0
            workspaceOwnedBytes = 0; workspaceScratchBytes = 0
            cacheBytes = 0; runtimeTemporaryBytes = 0; logBytes = 0; registryBytes = 0
            templateLogicalBytes = 0; templateAllocatedBytes = 0; templateDownloadBytes = 0
        }
    }

    public let layout: RuntimeV2Layout
    public let registry: RuntimeV2Registry
    public let blobs: RuntimeV2BlobStore
    public let images: RuntimeV2ImageStore
    public let deltas: RuntimeV2DeltaStore
    public let leases: RuntimeV2LeaseStore
    public let repairHolds: RuntimeV2RepairHoldStore
    public let pool: RuntimeVMPool
    public let workspaces: RuntimeV2WorkspaceStore
    public let caches: RuntimeV2CacheStore
    public let logs: RuntimeV2LogStore
    public let templates: RuntimeV2TemplateStore
    private var fileManager: FileManager { .default }

    /// Injectable fault seams for the durability-critical recovery paths, so
    /// each persistent stage (repair-hold marker vs registry state) can be
    /// driven with a deterministic fault and the surviving exclusion proven.
    public struct Seams: Sendable {
        /// Replaces the durable repairRequired transition during startup
        /// recovery (throw to inject a registry fault at exactly that stage).
        /// nil = normal.
        public var markRepairRequired: (@Sendable (String, String) async throws -> Void)?
        /// Replaces the durable repair-hold placement during startup
        /// recovery (throw to inject an IO/full-disk fault at exactly that
        /// stage). nil = normal.
        public var placeRepairHold: (@Sendable (String, String, String, String?) async throws -> Void)?

        public init(
            markRepairRequired: (@Sendable (String, String) async throws -> Void)? = nil,
            placeRepairHold: (@Sendable (String, String, String, String?) async throws -> Void)? = nil
        ) {
            self.markRepairRequired = markRepairRequired
            self.placeRepairHold = placeRepairHold
        }

        public static let production = Seams()
    }

    private let seams: Seams

    public init(
        layout: RuntimeV2Layout,
        poolConfiguration: RuntimeVMPool.Configuration = .init(),
        templateSeams: RuntimeV2TemplateStore.Seams = .production,
        blobSeams: RuntimeV2BlobStore.Seams = .production,
        seams: Seams = .production
    ) {
        self.layout = layout
        self.seams = seams
        let registry = RuntimeV2Registry(layout: layout)
        self.registry = registry
        self.blobs = RuntimeV2BlobStore(layout: layout, registry: registry, seams: blobSeams)
        self.images = RuntimeV2ImageStore(layout: layout, registry: registry, blobs: blobs)
        self.deltas = RuntimeV2DeltaStore(layout: layout)
        let repairHolds = RuntimeV2RepairHoldStore(layout: layout)
        self.repairHolds = repairHolds
        self.leases = RuntimeV2LeaseStore(layout: layout, registry: registry, repairHolds: repairHolds)
        self.pool = RuntimeVMPool(configuration: poolConfiguration, registry: registry)
        self.workspaces = RuntimeV2WorkspaceStore(layout: layout, registry: registry)
        self.caches = RuntimeV2CacheStore(layout: layout)
        self.logs = RuntimeV2LogStore(layout: layout)
        self.templates = RuntimeV2TemplateStore(
            layout: layout, registry: registry, blobs: blobs,
            images: images, deltas: deltas, seams: templateSeams
        )
    }

    // MARK: prepare + recover

    /// Creates the tree, opens the registry and runs the startup recovery
    /// pass. Idempotent; safe to call on every launch.
    @discardableResult
    public func prepareAndRecover(build: String) async throws -> RecoveryReport {
        _ = try layout.prepare(build: build)
        try await registry.open()
        try await caches.prepare()
        var report = RecoveryReport()

        // 1. Queue entries from a dead incarnation are interrupted, never
        //    resumed as if still pending.
        report.interruptedQueueEntries = (try? await registry.interruptOpenQueueEntries()) ?? 0

        // 2. Leases: reclaim provably-stale ones; anything unreclaimable is
        //    reported and its environment marked interrupted. A durable repair
        //    hold outranks the interruption marking: the hold is the
        //    authoritative exclusion, and the lease stays untouched as
        //    evidence until repair is acknowledged.
        let unresolved = (try? await leases.recoverOnLaunch()) ?? []
        report.unreclaimableLeases = unresolved
        for environmentID in unresolved {
            if await leases.excludes(environmentID: environmentID) {
                report.notes.append(
                    "environment \(environmentID): a durable repair exclusion (marker or preserved physical evidence) excludes this environment; the unreclaimable lease was left untouched"
                )
                continue
            }
            try? await registry.setEnvironmentState(
                id: environmentID, state: "interrupted",
                repairReason: "a lease from a previous run could not be proven stale; the environment was not touched"
            )
        }

        // 3. Leftover runtime/vm working dirs: salvage through the verified
        //    capture path (like a power-loss recovery on real hardware), or
        //    quarantine when salvage fails. runtime/ is never a state source:
        //    everything ends up captured, quarantined or swept.
        report = await recoverRuntimeDirectories(report: report)

        // 3c. Authoritative quarantine recovery: a preserved working disk
        //     whose stop-time repair marker could not be persisted (full
        //     disk / IO / DB fault) is itself the durable evidence. Recovery
        //     re-derives the repairRequired state + durable hold from the
        //     orphaned quarantine entry, so preserved bytes can never become
        //     undiscoverable just because the original marker write failed.
        report = await recoverPreservedQuarantine(report: report)

        // 3b. Staged blob ownership claims are process-lifetime: a restart
        //     means no stage/ingest is in flight any more, so leftover claims
        //     must not leak permanent GC protection (registration recovery
        //     re-takes references from the recorded owner).
        try? await registry.resetBlobStagingClaims()

        // 4. Stale staging: cache/staging past the in-flight window, expanded
        //    .staging-* and per-environment system .staging-* leftovers.
        report.sweptStagingEntries = sweepStaging()

        // 5. Images stuck in 'staged' (crash between file writes and the
        //    registry update): re-verify files and promote, or leave staged.
        report.repairedImages = await repairStagedImages()

        // 6. Orphan v2 manifests without a registry row (crash window):
        //    verify and register, or quarantine the manifest.
        report.notes.append(contentsOf: await repairOrphanManifests())

        // 7. Verified images whose rebuildable expanded view was lost (the
        //    view is disposable — excluded from backup, re-materialized on
        //    demand; registry row + manifest + blobs are the truth):
        //    rebuild from the verified blobs so a status read never reports
        //    "uninstalled" and the boot path never redownloads.
        report = await rebuildMissingExpandedViews(report: report)

        // 8. Interrupted template builds: an unverified install can never
        //    become a verified version. Mark failed, quarantine the staging
        //    evidence, sweep orphaned clone directories.
        let templateNotes = (try? await templates.recoverInterruptedBuilds()) ?? []
        report.interruptedTemplateBuilds = templateNotes.count
        report.notes.append(contentsOf: templateNotes)

        await logs.log("Runtime v2 recovery: \(report.notes.count) notes, salvaged=\(report.salvagedRuntimeDirs.count), quarantined=\(report.quarantinedRuntimeDirs.count)")
        return report
    }

    private func recoverRuntimeDirectories(report: RecoveryReport) async -> RecoveryReport {
        var report = report
        let root = layout.runtimeVMDirectory
        guard let entries = try? fileManager.contentsOfDirectory(atPath: root.path) else { return report }
        for entry in entries where !entry.hasPrefix(".") {
            let directory = root.appendingPathComponent(entry, isDirectory: true)
            guard let meta = RuntimeV2WorkingDirectory.readMeta(from: directory) else {
                // Unparseable or missing ownership record: this NEVER grants
                // permission to move a potentially active VM disk. Attribute
                // ownership by directory runtimeID through the lease
                // sidecars + registry first; preserve byte-for-byte while any
                // ownership is uncertain.
                if let lease = await leases.lease(forRuntimeID: entry) {
                    if await leases.hasLiveOwnership(environmentID: lease.environmentID) {
                        report.preservedRuntimeDirs.append(entry)
                        report.notes.append(
                            "runtime/vm/\(entry) preserved: the ownership record is unreadable and environment \(lease.environmentID) still holds a live or unexpired write lease for this runtime; the disk was not touched"
                        )
                        continue
                    }
                    if await leases.excludes(environmentID: lease.environmentID, ignoringRuntimeEntry: entry) {
                        report.preservedRuntimeDirs.append(entry)
                        report.notes.append(
                            "runtime/vm/\(entry) preserved: the ownership record is unreadable and environment \(lease.environmentID) is durably repair-excluded for this runtime; the disk was not touched"
                        )
                        continue
                    }
                    if let environment = try? await registry.environment(id: lease.environmentID),
                       environment.state != "deleting" {
                        // The lease is proven stale and attributes this runtime
                        // to a known environment, but without runtime.json the
                        // disk bytes cannot be proven against any boot base:
                        // salvage is impossible. The same durable repair-hold
                        // protocol as a failed salvage applies — quarantine the
                        // bytes, exclude the environment until repair is
                        // explicitly resolved, and say so truthfully.
                        let attributed = RuntimeV2WorkingDirectory.Meta(
                            runtimeID: entry, environmentID: lease.environmentID,
                            baseImageID: environment.baseImageID ?? "", createdAt: Date()
                        )
                        report = await preserveUnsalvageableWorkingDirectory(
                            report: report, entry: entry, directory: directory,
                            meta: attributed,
                            error: RuntimeV2Error.workingDirectoryProvenanceUnavailable(
                                environmentID: lease.environmentID,
                                reason: "the working directory ownership record is unreadable; the disk cannot be attributed to a boot base"
                            )
                        )
                        continue
                    }
                    // Lease attribution exists but the environment is gone or
                    // being deleted: ownership is maximally uncertain — keep
                    // every byte exactly where it is.
                    report.preservedRuntimeDirs.append(entry)
                    report.notes.append(
                        "runtime/vm/\(entry) preserved: the ownership record is unreadable and its lease-attributed environment \(lease.environmentID) is gone or being deleted; the disk was not touched"
                    )
                    continue
                }
                // No ownership trace anywhere: the absence of a trace is NOT
                // proof the owner is stopped — a live VM may still hold an open
                // disk handle with every record faulted away. The directory is
                // preserved byte-for-byte IN PLACE (never moved, never mounted
                // over) until ownership resolves or a human/tool runs the
                // explicit verified cleanup `archiveUnknownRuntimeDirectory`.
                report.preservedRuntimeDirs.append(entry)
                report.notes.append(
                    "runtime/vm/\(entry) preserved: no ownership trace exists anywhere (unreadable ownership record, no lease sidecar, no registry row, no archived lease); the absence of a trace is not proof the owner stopped, so the disk was left byte-for-byte in place"
                )
                continue
            }
            // P0: never capture, move or delete a working disk until its owner
            // is proven stopped and every identity check is certain. An
            // unresolved lease (live pid or unexpired TTL — another app
            // instance or a session of this one), an inconsistent ownership
            // record, or an environment the registry does not know all mean
            // the state is uncertain; the fail-closed action is to preserve
            // the directory byte-for-byte and report it.
            if let preservation = await preservationReason(entry: entry, meta: meta) {
                report.preservedRuntimeDirs.append(entry)
                report.notes.append(preservation)
                continue
            }
            // A durable repair exclusion outranks salvage: the exclusion names
            // preserved bytes or an unaccounted working disk awaiting explicit
            // repair resolution, so a leftover directory of that environment
            // (e.g. a quarantine move that failed at stop time) is left
            // byte-for-byte untouched. The directory under evaluation is
            // ignored by the working-disk evidence scan: it can never be
            // evidence against itself.
            if await leases.excludes(environmentID: meta.environmentID, ignoringRuntimeEntry: entry) {
                report.preservedRuntimeDirs.append(entry)
                report.notes.append(
                    "runtime/vm/\(entry) preserved: environment \(meta.environmentID) is durably repair-excluded; the directory was not captured, moved or deleted"
                )
                continue
            }
            do {
                try await salvageWorkingDirectory(directory: directory, meta: meta)
                try? fileManager.removeItem(at: directory)
                report.salvagedRuntimeDirs.append(entry)
            } catch {
                report = await preserveUnsalvageableWorkingDirectory(
                    report: report, entry: entry, directory: directory, meta: meta, error: error
                )
            }
        }
        return report
    }

    /// Salvage failed: preserve the complete disk truthfully and make the
    /// environment durably non-restartable. The bytes are quarantined when the
    /// move succeeds, otherwise they stay untouched in runtime/vm; either way
    /// a non-expiring repair hold is placed FIRST so no future start can
    /// overwrite them, and the registry repairRequired state is written
    /// without swallowing — a failed durable write is reported in the notes,
    /// never converted into a silently restartable environment.
    private func preserveUnsalvageableWorkingDirectory(
        report: RecoveryReport, entry: String, directory: URL,
        meta: RuntimeV2WorkingDirectory.Meta, error: Error
    ) async -> RecoveryReport {
        var report = report
        let reason = "interrupted working disk could not be salvaged: \(error.localizedDescription)"
        let quarantine = layout.quarantineDirectory
            .appendingPathComponent("runtime-vm-\(entry)-\(UUID().uuidString)", isDirectory: true)
        let preservedPath: String
        if (try? fileManager.moveItem(at: directory, to: quarantine)) != nil {
            report.quarantinedRuntimeDirs.append(entry)
            preservedPath = "recovery/quarantine/\(quarantine.lastPathComponent)"
        } else {
            // The move itself failed: the bytes stay exactly where they are.
            report.preservedRuntimeDirs.append(entry)
            preservedPath = "runtime/vm/\(entry)"
            report.notes.append(
                "runtime/vm/\(entry) could not be quarantined (\(reason)); the directory was left untouched"
            )
        }
        await placeRepairHold(
            environmentID: meta.environmentID, runtimeID: entry,
            reason: reason, preservedPath: preservedPath, report: &report
        )
        await markRepairRequired(environmentID: meta.environmentID, reason: reason, report: &report)
        return report
    }

    private func placeRepairHold(
        environmentID: String, runtimeID: String, reason: String,
        preservedPath: String?, report: inout RecoveryReport
    ) async {
        do {
            if let placeRepairHold = seams.placeRepairHold {
                try await placeRepairHold(environmentID, runtimeID, reason, preservedPath)
            } else {
                try await repairHolds.place(
                    environmentID: environmentID, runtimeID: runtimeID,
                    reason: reason, preservedPath: preservedPath
                )
            }
        } catch {
            // The marker could not be persisted (full disk / IO fault): the
            // preserved bytes stay discoverable through the quarantine scan
            // (recoverPreservedQuarantine re-derives this hold next launch),
            // and the exclusion must not silently become a restartable state.
            report.notes.append(
                "environment \(environmentID): the durable repair hold could not be persisted (\(error.localizedDescription)); the preserved bytes at \(preservedPath ?? "unknown") remain the authoritative evidence and re-marking is retried on every launch"
            )
        }
    }

    private func markRepairRequired(
        environmentID: String, reason: String, report: inout RecoveryReport
    ) async {
        do {
            if let markRepairRequired = seams.markRepairRequired {
                try await markRepairRequired(environmentID, reason)
            } else {
                try await registry.setEnvironmentState(
                    id: environmentID, state: "repairRequired", repairReason: reason
                )
            }
        } catch {
            report.notes.append(
                "environment \(environmentID): the repairRequired state could not be persisted (\(error.localizedDescription)); the durable repair hold keeps the environment non-restartable"
            )
        }
    }

    /// The preserved working disk is itself durable evidence: when a stop- or
    /// recovery-time fault prevented the repair marker from being persisted,
    /// the orphaned quarantine entry (its runtime.json still names the
    /// environment) re-derives the repairRequired state + durable marker on
    /// every launch until repair is explicitly resolved. This re-derivation
    /// is best-effort bookkeeping: even when EVERY write here fails under a
    /// sustained fault, the physical bytes alone keep the environment
    /// excluded — the exclusion consult (`leases.excludes`) answers from the
    /// filesystem and is honored by lease reclamation, acquire, salvage and
    /// boot preparation. Quarantine entries are never moved or deleted here.
    ///
    /// A resolved entry is skipped: archived hold sidecars and resolution
    /// records name the exact preservedPath the resolution accounted for, so
    /// the bytes remaining in quarantine (kept for evidence) can never
    /// re-block a correctly repaired environment on a later recovery pass.
    private func recoverPreservedQuarantine(report: RecoveryReport) async -> RecoveryReport {
        var report = report
        guard let entries = try? fileManager.contentsOfDirectory(atPath: layout.quarantineDirectory.path)
        else { return report }
        let acknowledged = await repairHolds.acknowledgedQuarantineEntryNames()
        for entry in entries where entry.hasPrefix("runtime-vm-") {
            if acknowledged.contains(entry) { continue }
            let directory = layout.quarantineDirectory.appendingPathComponent(entry, isDirectory: true)
            guard let meta = RuntimeV2WorkingDirectory.readMeta(from: directory) else { continue }
            guard (try? RuntimeV2Identifier.validate(meta.environmentID, kind: .environment)) != nil else {
                continue
            }
            guard let environment = try? await registry.environment(id: meta.environmentID),
                  environment.state != "deleting" else { continue }
            // Already honestly marked with a live marker sidecar: nothing to
            // re-derive. (The durable marker is authoritative; when even it is
            // missing, the physical evidence still excludes the environment
            // and this pass retries the marker + state writes below.)
            if environment.state == "repairRequired",
               await repairHolds.markerHold(environmentID: meta.environmentID) != nil {
                continue
            }
            let reason = "preserved working disk discovered at recovery/quarantine/\(entry): an earlier stop or recovery could not persist its repair marker; the bytes were never lost"
            await placeRepairHold(
                environmentID: meta.environmentID, runtimeID: meta.runtimeID,
                reason: reason, preservedPath: "recovery/quarantine/\(entry)", report: &report
            )
            await markRepairRequired(environmentID: meta.environmentID, reason: reason, report: &report)
            // Report the re-application only when the marker actually
            // persisted: under a sustained fault the physical evidence keeps
            // the environment excluded anyway, and the failure notes above
            // stay visible on every launch.
            if await repairHolds.markerHold(environmentID: meta.environmentID) != nil {
                report.repairReapplied.append(meta.environmentID)
            }
        }
        return report
    }

    /// Why this working directory must be preserved untouched, or nil when
    /// salvage may proceed. Identity checks run before the lease check so a
    /// tampered record is never used to attribute a disk to an environment.
    private func preservationReason(
        entry: String, meta: RuntimeV2WorkingDirectory.Meta
    ) async -> String? {
        guard (try? RuntimeV2Identifier.validate(meta.environmentID, kind: .environment)) != nil else {
            return "runtime/vm/\(entry) preserved: the ownership record names an invalid environment; the disk was not touched"
        }
        guard meta.runtimeID == entry else {
            return "runtime/vm/\(entry) preserved: the ownership record belongs to runtime \(meta.runtimeID), not \(entry); the disk was not touched"
        }
        guard let environment = try? await registry.environment(id: meta.environmentID) else {
            return "runtime/vm/\(entry) preserved: environment \(meta.environmentID) is not known to the registry; the disk was not touched"
        }
        guard environment.state != "deleting" else {
            return "runtime/vm/\(entry) preserved: environment \(meta.environmentID) is being deleted; the disk was not touched"
        }
        guard await !leases.hasLiveOwnership(environmentID: meta.environmentID) else {
            return "runtime/vm/\(entry) preserved: environment \(meta.environmentID) still has a live or unexpired write lease; the owner was not proven stopped, so the disk was not captured, moved or deleted"
        }
        return nil
    }

    /// Captures the leftover working disk into the environment's delta (the
    /// same verified path as a clean stop) and marks the session interrupted.
    /// The capture base comes from the provenance frozen in `runtime.json`
    /// (the template pin + disk digest the guest actually booted), verified
    /// against the live registry: a pin that moved while the disk was live is
    /// a provenance mismatch, so the disk is preserved for repair instead of
    /// being rewritten against different bytes.
    private func salvageWorkingDirectory(
        directory: URL, meta: RuntimeV2WorkingDirectory.Meta
    ) async throws {
        let workingDisk = directory.appendingPathComponent("disk.img")
        guard fileManager.fileExists(atPath: workingDisk.path) else { return }
        let bootBase = try await templates.bootBase(matching: meta)
        let info = try await deltas.capture(
            environmentID: meta.environmentID,
            workingDisk: workingDisk,
            baseRootfs: bootBase.diskURL,
            baseImageID: meta.baseImageID,
            baseRootfsSHA512: bootBase.digest,
            templatePin: bootBase.templatePin
        )
        try await deltas.recordShutdown(
            RuntimeV2DeltaStore.ShutdownRecord(
                environmentID: meta.environmentID,
                runtimeID: meta.runtimeID,
                stoppedAt: Date(),
                clean: false,
                deltaGeneration: info.header.generation,
                detail: "recovered from an interrupted runtime; the guest state was salvaged through verified capture"
            ),
            environmentID: meta.environmentID
        )
    }

    private func sweepStaging() -> Int {
        var swept = 0
        let cutoff = Date().addingTimeInterval(-RuntimeV2CacheStore.inFlightWindow)
        // cache/staging leftovers older than the in-flight window
        let stagingRoot = layout.cacheDirectory(kind: "staging")
        if let entries = try? fileManager.contentsOfDirectory(atPath: stagingRoot.path) {
            for entry in entries {
                let url = stagingRoot.appendingPathComponent(entry)
                let modified = (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
                if modified < cutoff {
                    try? fileManager.removeItem(at: url)
                    swept += 1
                }
            }
        }
        // expanded .staging-* (crash during image switch)
        if let entries = try? fileManager.contentsOfDirectory(atPath: layout.expandedImagesDirectory.path) {
            for entry in entries where entry.hasPrefix(".staging-") {
                try? fileManager.removeItem(at: layout.expandedImagesDirectory.appendingPathComponent(entry))
                swept += 1
            }
        }
        // per-environment system .staging-* (crash during delta capture)
        if let environments = try? fileManager.contentsOfDirectory(atPath: layout.environmentsDirectory.path) {
            for environmentID in environments {
                let system = layout.environmentsDirectory
                    .appendingPathComponent(environmentID, isDirectory: true)
                    .appendingPathComponent("system", isDirectory: true)
                guard let entries = try? fileManager.contentsOfDirectory(atPath: system.path) else { continue }
                for entry in entries where entry.hasPrefix(".staging-") {
                    try? fileManager.removeItem(at: system.appendingPathComponent(entry))
                    swept += 1
                }
            }
        }
        return swept
    }

    private func repairStagedImages() async -> [String] {
        guard let staged = try? await registry.images(state: .staged) else { return [] }
        var repaired: [String] = []
        for row in staged {
            guard let manifest = try? await images.manifest(imageID: row.id),
                  let rootfs = manifest.rootfsDigest else { continue }
            var blobsValid = true
            for (_, ref) in manifest.artifacts {
                do { try await blobs.verify(digest: ref.sha512) } catch { blobsValid = false; break }
            }
            guard blobsValid else { continue }
            do {
                _ = try await images.ensureExpanded(imageID: row.id)
                try await registry.markImageVerified(
                    id: row.id, expandedPath: "images/expanded/\(row.id)", baseRootfsDigest: rootfs
                )
                repaired.append(row.id)
            } catch {
                continue
            }
        }
        return repaired
    }

    private func repairOrphanManifests() async -> [String] {
        var notes: [String] = []
        guard let entries = try? fileManager.contentsOfDirectory(atPath: layout.imageManifestsDirectory.path) else {
            return notes
        }
        for entry in entries where entry.hasSuffix(".json") {
            let imageID = String(entry.dropLast(".json".count))
            if let row = try? await registry.image(id: imageID), row.state == .verified { continue }
            guard let manifest = try? await images.manifest(imageID: imageID) else {
                let quarantine = layout.quarantineDirectory
                    .appendingPathComponent("manifest-\(imageID)-\(UUID().uuidString).json")
                try? fileManager.moveItem(
                    at: layout.imageManifestsDirectory.appendingPathComponent(entry), to: quarantine
                )
                notes.append("quarantined undecodable manifest \(imageID)")
                continue
            }
            var blobsValid = true
            for (_, ref) in manifest.artifacts {
                do { try await blobs.verify(digest: ref.sha512) } catch { blobsValid = false; break }
            }
            guard blobsValid, let rootfs = manifest.rootfsDigest else {
                notes.append("manifest \(imageID) references missing blobs; left unverified")
                continue
            }
            do {
                _ = try await images.ensureExpanded(imageID: imageID)
                try await registry.registerStagedImage(
                    id: imageID, manifestPath: "images/manifests/\(imageID).json",
                    bytes: manifest.artifacts.values.reduce(0) { $0 + $1.bytes }
                )
                try await registry.markImageVerified(
                    id: imageID, expandedPath: "images/expanded/\(imageID)", baseRootfsDigest: rootfs
                )
                notes.append("re-registered orphan manifest \(imageID) from verified files")
            } catch {
                notes.append("orphan manifest \(imageID) could not be repaired: \(error.localizedDescription)")
            }
        }
        return notes
    }

    /// Re-materializes the expanded view of every verified image whose view
    /// is missing or incomplete, straight from the verified blobs — the same
    /// verified path `ensureExpanded` already runs on demand. A rebuild that
    /// fails (a blob genuinely lost) is surfaced as an explicit recovery
    /// note, never silently ignored and never treated as "uninstalled".
    private func rebuildMissingExpandedViews(report: RecoveryReport) async -> RecoveryReport {
        var report = report
        guard let verified = try? await registry.images(state: .verified) else { return report }
        for row in verified {
            do {
                guard try await images.isExpandedViewComplete(imageID: row.id) == false else { continue }
                _ = try await images.ensureExpanded(imageID: row.id)
                report.rebuiltExpandedViews.append(row.id)
            } catch {
                report.notes.append(
                    "verified image \(row.id) has no complete expanded view and it could not be rebuilt: \(error.localizedDescription)"
                )
            }
        }
        return report
    }

    // MARK: repair inspection + explicit resolution
    //
    // A repair exclusion is resolved by exactly TWO named, explicit, durable
    // actions — never by inspection and never implicitly:
    //   - `restoreRepair`: the preserved bytes are proven (provenance +
    //     content), captured into the environment delta through the verified
    //     path, the durable state commits, and only then the exclusion lifts.
    //   - `discardRepair`: a deliberate, authorized decision to throw the
    //     preserved bytes away; the bytes are moved into the discarded-
    //     evidence area (never deleted) before the exclusion lifts.
    // Merely discovering the backup (`repairHoldStatus` / `verifyRecoverable`)
    // changes nothing.

    /// The durable repair exclusion for an environment, for status/repair
    /// surfaces (D-scope UI). Answers the marker sidecar first (a corrupt one
    /// answers a synthesized unreadable hold), then the physical-evidence
    /// hold. nil means the environment is not repair-excluded. Inspection
    /// only: never changes state.
    public func repairHoldStatus(environmentID: String) async -> RuntimeV2RepairHoldStore.Hold? {
        await repairHolds.effectiveHold(environmentID: environmentID)
    }

    /// Verifies what a repair resolution would account for: the preserved
    /// bytes (path) or nothing. Inspection only: never lifts the exclusion.
    public func verifyRecoverable(
        environmentID: String
    ) async -> RuntimeV2RepairHoldStore.RecoverableState {
        await repairHolds.verifyRecoverable(environmentID: environmentID)
    }

    /// The durable outcome of an explicit repair resolution (D/C5 surface).
    public struct RepairResolutionReport: Sendable, Equatable {
        /// "restored" or "discarded".
        public var resolution: String
        /// Layout-relative path of the preserved bytes that were accounted
        /// for, nil when there was nothing to recover.
        public var preservedPath: String?
        /// SHA-512 of the preserved disk for a restore (evidence), nil for a
        /// discard or when nothing remained.
        public var diskDigestSHA512: String?
        /// The delta generation the restored bytes were captured into.
        public var restoredGeneration: UInt64?
    }

    /// VERIFIED RESTORE — the only path that returns preserved bytes to the
    /// environment. Stages, in strict durable order:
    ///   1. Require an existing repair exclusion (else throw; never a silent
    ///      no-op a UI could mistake for a repair).
    ///   2. Verify the preserved LOCATION: the hold's preservedPath is
    ///      untrusted sidecar content — it must be a supported
    ///      runtime/quarantine path format, symlink-resolved inside the
    ///      runtime root, or the resolution refuses outright.
    ///   3. Verify provenance: the preserved ownership record must exist,
    ///      name this environment, match the directory entry identity, and
    ///      resolve against the LIVE registry through the exact boot-base
    ///      check a stop capture uses (template pin + digest equality) — an
    ///      unprovable disk is never restored.
    ///   4. Verify content: the preserved disk must be at least the boot
    ///      base's size and every byte must be readable (a full SHA-512 is
    ///      computed as restoration evidence).
    ///   5. Capture the preserved disk into the environment delta through the
    ///      verified staged/fsynced/atomically-promoted path, and record the
    ///      shutdown.
    ///   6. Commit the durable registry transition (stopped) — deleting
    ///      environments skip the write (teardown owns the row).
    ///   7. Record the resolution durably; only then does the exclusion lift.
    /// Any failure before step 7 leaves the exclusion AND the preserved bytes
    /// fully in place (an interrupted restore retains the hold), and a retry
    /// is idempotent: the same bytes capture to the same content.
    @discardableResult
    public func restoreRepair(environmentID: String) async throws -> RepairResolutionReport {
        guard await leases.excludes(environmentID: environmentID) else {
            throw RuntimeV2Error.repairResolutionUnavailable(
                environmentID: environmentID,
                reason: "no repair exclusion exists; there is nothing to restore"
            )
        }
        // The resolution commit below is a durable registry transaction; an
        // explicit repair may be resolved by ANY store instance, including one
        // constructed after the exclusion appeared that has not run the
        // launch-time `prepareAndRecover` pass yet (a fresh process opens its
        // registry lazily otherwise). `open()` is idempotent, so the normal
        // prepared path pays nothing. Without this the commit crashed on a nil
        // sqlite handle and sqlite3_errmsg(nil) misreported it as
        // "out of memory" (C7 ABA regression).
        try await registry.open()
        let resolvedHold = await repairHolds.effectiveHold(environmentID: environmentID)
        let observedCorruptMarker = await repairHolds.corruptMarkerObservation(environmentID: environmentID)
        guard let preservedPath = resolvedHold?.preservedPath else {
            throw RuntimeV2Error.repairResolutionUnavailable(
                environmentID: environmentID,
                reason: "no preserved bytes remain to restore; use discardRepair to clear the exclusion deliberately"
            )
        }
        // The preservedPath is untrusted: unsupported shapes (absolute, "..",
        // foreign prefixes, symlink escapes) refuse here BEFORE anything is
        // read, captured or moved.
        let preservedDirectory = try layout.preservedRuntimeDirectory(preservedPath)
        let preservedDisk = preservedDirectory.appendingPathComponent("disk.img")
        guard fileManager.fileExists(atPath: preservedDisk.path),
              ((try? fileManager.attributesOfItem(atPath: preservedDisk.path)[.size] as? Int64) ?? 0) > 0 else {
            throw RuntimeV2Error.repairResolutionUnavailable(
                environmentID: environmentID,
                reason: "no preserved bytes remain to restore; use discardRepair to clear the exclusion deliberately"
            )
        }
        guard let meta = RuntimeV2WorkingDirectory.readMeta(from: preservedDirectory) else {
            throw RuntimeV2Error.workingDirectoryProvenanceUnavailable(
                environmentID: environmentID,
                reason: "the preserved working directory at \(preservedPath) has no readable ownership record; its bytes can never be verified, so restore refuses rather than guess (discardUnverifiableRepairEvidence is the explicitly verified cleanup for unprovable bytes)"
            )
        }
        guard meta.environmentID == environmentID else {
            throw RuntimeV2Error.workingDirectoryProvenanceUnavailable(
                environmentID: environmentID,
                reason: "the preserved working directory belongs to \(meta.environmentID), not \(environmentID); restore refuses to move another environment's bytes"
            )
        }
        guard preservedEntryIdentityMatches(meta: meta, preservedPath: preservedPath) else {
            throw RuntimeV2Error.workingDirectoryProvenanceUnavailable(
                environmentID: environmentID,
                reason: "the preserved working directory identity does not match its recorded entry \(preservedPath); the path names different bytes than its ownership record claims"
            )
        }
        // The exact provenance check a stop capture runs: the recorded boot
        // base (template pin + digest) must still resolve against the live
        // registry. A moved/changed base refuses the restore instead of
        // rebasing preserved bytes onto different content.
        let bootBase = try await templates.bootBase(matching: meta)
        let baseSize = (try? fileManager.attributesOfItem(atPath: bootBase.diskURL.path)[.size] as? Int64) ?? 0
        let preservedSize = (try? fileManager.attributesOfItem(atPath: preservedDisk.path)[.size] as? Int64) ?? 0
        guard preservedSize >= baseSize else {
            throw RuntimeV2Error.workingDirectoryProvenanceUnavailable(
                environmentID: environmentID,
                reason: "the preserved disk (\(preservedSize) bytes) is smaller than its recorded boot base (\(baseSize) bytes); it cannot be the disk that booted"
            )
        }
        // Content verification: read every byte (a truncated/unreadable disk
        // throws here) and keep the digest as restoration evidence.
        let digest = try FloeDigest.sha512Hex(ofFileAt: preservedDisk)
        // Verified capture through the same staged/fsynced/atomic path a clean
        // stop uses; a crash before the promote keeps the previous delta.
        let info = try await deltas.capture(
            environmentID: environmentID,
            workingDisk: preservedDisk,
            baseRootfs: bootBase.diskURL,
            baseImageID: meta.baseImageID,
            baseRootfsSHA512: bootBase.digest,
            templatePin: bootBase.templatePin
        )
        try await deltas.recordShutdown(
            RuntimeV2DeltaStore.ShutdownRecord(
                environmentID: environmentID,
                runtimeID: meta.runtimeID,
                stoppedAt: Date(),
                clean: true,
                deltaGeneration: info.header.generation,
                detail: "repair restore: preserved bytes at \(preservedPath) were proven (provenance + content) and captured into the delta"
            ),
            environmentID: environmentID
        )
        if let environment = try await registry.environment(id: environmentID),
           environment.state != "deleting" {
            try await registry.setEnvironmentState(
                id: environmentID, state: "stopped", repairReason: nil
            )
        }
        // Durable resolution LAST: if this write fails, the exclusion stays
        // (fail closed), the state is re-marked repairRequired (best effort)
        // and the whole restore can be retried idempotently.
        do {
            try await repairHolds.recordResolution(
                environmentID: environmentID, preservedPath: preservedPath,
                resolution: "restored", diskDigestSHA512: digest,
                resolvedHoldID: resolvedHold?.holdID,
                observedCorruptMarker: observedCorruptMarker
            )
        } catch {
            try? await registry.setEnvironmentState(
                id: environmentID, state: "repairRequired",
                repairReason: "the repair resolution could not be persisted (\(error.localizedDescription)); the exclusion remains in place"
            )
            throw error
        }
        await logs.log(
            "runtime v2 repair restored environment=\(environmentID) preservedPath=\(preservedPath) digest=\(digest.prefix(16))… generation=\(info.header.generation)"
        )
        return RepairResolutionReport(
            resolution: "restored", preservedPath: preservedPath,
            diskDigestSHA512: digest, restoredGeneration: info.header.generation
        )
    }

    /// DELIBERATE DISCARD — the explicit, authorized decision to throw the
    /// preserved bytes away. Never a default and never reachable through
    /// inspection: the caller must name it. The preserved path (untrusted
    /// sidecar content) must pass the supported-format + symlink-containment
    /// validation, and the bytes must carry MATCHING PROVENANCE (a readable
    /// ownership record naming this environment with the recorded runtime
    /// identity) — a foreign or unprovable directory is never moved by this
    /// call; it belongs to `discardUnverifiableRepairEvidence` (damaged or
    /// missing metadata) or to the other environment's repair flow. The bytes
    /// are preserved as evidence under recovery/migrations/discarded/ (moved,
    /// never deleted) BEFORE the exclusion lifts; when the evidence move
    /// itself fails the exclusion stays and this throws. The durable state
    /// commits before the resolution record, which commits before the lift.
    @discardableResult
    public func discardRepair(environmentID: String, reason: String) async throws -> RepairResolutionReport {
        guard await leases.excludes(environmentID: environmentID) else {
            throw RuntimeV2Error.repairResolutionUnavailable(
                environmentID: environmentID,
                reason: "no repair exclusion exists; there is nothing to discard"
            )
        }
        // Same lazy-open contract as `restoreRepair`: the durable commit below
        // touches the registry, and a fresh store instance that never ran
        // `prepareAndRecover` must still be able to complete an explicit,
        // human-authorized resolution (idempotent no-op when already open).
        try await registry.open()
        // The preservedPath is untrusted: an unsupported/escaping path refuses
        // BEFORE anything is moved — a crafted sidecar can never authorize a
        // move, and can never lift the exclusion either.
        let resolvedHold = await repairHolds.effectiveHold(environmentID: environmentID)
        let observedCorruptMarker = await repairHolds.corruptMarkerObservation(environmentID: environmentID)
        let recordedPath = resolvedHold?.preservedPath
        var preservedPath: String?
        var discardedDigest: String?
        if let path = recordedPath {
            let source = try layout.preservedRuntimeDirectory(path)
            let disk = source.appendingPathComponent("disk.img")
            guard fileManager.fileExists(atPath: disk.path),
                  ((try? fileManager.attributesOfItem(atPath: disk.path)[.size] as? Int64) ?? 0) > 0 else {
                // A valid-format path whose bytes are already gone: nothing
                // remains to account for; the lift below destroys nothing.
                return try await commitDiscard(
                    environmentID: environmentID, preservedPath: nil,
                    diskDigestSHA512: nil, resolvedHoldID: resolvedHold?.holdID,
                    observedCorruptMarker: observedCorruptMarker,
                    reason: reason
                )
            }
            preservedPath = path
            // Evidence: the exact bytes about to be discarded are hashed
            // before the move, so the committed resolution binds to THIS
            // instance of the preserved evidence.
            discardedDigest = try FloeDigest.sha512Hex(ofFileAt: disk)
            guard let meta = RuntimeV2WorkingDirectory.readMeta(from: source),
                  meta.environmentID == environmentID,
                  preservedEntryIdentityMatches(meta: meta, preservedPath: path) else {
                throw RuntimeV2Error.workingDirectoryProvenanceUnavailable(
                    environmentID: environmentID,
                    reason: "the preserved bytes at \(path) do not carry matching provenance for this environment; discardRepair refuses to move unproven or foreign bytes (use discardUnverifiableRepairEvidence for explicitly verified cleanup of damaged metadata)"
                )
            }
            let archive = layout.recoveryMigrationsDirectory
                .appendingPathComponent("discarded", isDirectory: true)
                .appendingPathComponent(
                    "\(source.lastPathComponent)-\(Int(Date().timeIntervalSince1970))",
                    isDirectory: true
                )
            do {
                try fileManager.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: source, to: archive)
            } catch {
                // The evidence must be preserved before the lift: refuse.
                throw RuntimeV2Error.repairResolutionUnavailable(
                    environmentID: environmentID,
                    reason: "the preserved bytes could not be moved into the discarded-evidence area (\(error.localizedDescription)); the exclusion was kept"
                )
            }
        }
        return try await commitDiscard(
            environmentID: environmentID, preservedPath: preservedPath,
            diskDigestSHA512: discardedDigest, resolvedHoldID: resolvedHold?.holdID,
            observedCorruptMarker: observedCorruptMarker,
            reason: reason
        )
    }

    /// Shared durable tail of the deliberate discard: registry commit, then
    /// the crash-safe resolution record, with a best-effort repairRequired
    /// re-mark when the resolution cannot be persisted.
    private func commitDiscard(
        environmentID: String, preservedPath: String?, diskDigestSHA512: String?,
        resolvedHoldID: String?, observedCorruptMarker: RuntimeV2RepairHoldStore.CorruptMarkerObservation?, reason: String
    ) async throws -> RepairResolutionReport {
        if let environment = try await registry.environment(id: environmentID),
           environment.state != "deleting" {
            try await registry.setEnvironmentState(
                id: environmentID, state: "stopped", repairReason: nil
            )
        }
        do {
            try await repairHolds.recordResolution(
                environmentID: environmentID, preservedPath: preservedPath,
                resolution: "discarded", diskDigestSHA512: diskDigestSHA512,
                resolvedHoldID: resolvedHoldID,
                observedCorruptMarker: observedCorruptMarker
            )
        } catch {
            try? await registry.setEnvironmentState(
                id: environmentID, state: "repairRequired",
                repairReason: "the repair resolution could not be persisted (\(error.localizedDescription)); the exclusion remains in place"
            )
            throw error
        }
        await logs.log(
            "runtime v2 repair discarded environment=\(environmentID) preservedPath=\(preservedPath ?? "none") reason=\(reason)"
        )
        return RepairResolutionReport(
            resolution: "discarded", preservedPath: preservedPath,
            diskDigestSHA512: nil, restoredGeneration: nil
        )
    }

    /// EXPLICITLY VERIFIED CLEANUP of unverifiable preserved repair evidence:
    /// preserved quarantine bytes whose ownership record is damaged or
    /// missing can never go through `discardRepair` (no provenance to match)
    /// and must never be implicitly authorized by a hold sidecar. This is the
    /// separate, deliberately named action for them: the caller asserts —
    /// out of band, e.g. by inspecting the bytes — that they are not needed.
    /// Safety rails: entries with readable provenance naming THIS environment
    /// are refused (that is a discardRepair case), entries naming ANOTHER
    /// environment are refused outright (their bytes are that environment's
    /// state), and every physical move is rechecked against the live
    /// filesystem immediately before it happens. The bytes land in the
    /// discarded-evidence area (never deleted); the durable state commits
    /// before the resolution record, which commits before the lift.
    @discardableResult
    public func discardUnverifiableRepairEvidence(
        environmentID: String, reason: String
    ) async throws -> RepairResolutionReport {
        guard await leases.excludes(environmentID: environmentID) else {
            throw RuntimeV2Error.repairResolutionUnavailable(
                environmentID: environmentID,
                reason: "no repair exclusion exists; there is nothing to clean up"
            )
        }
        // Same lazy-open contract as `restoreRepair`/`discardRepair`: the
        // durable commit below touches the registry and must complete on any
        // store instance, prepared or not (idempotent no-op when already open).
        try await registry.open()
        let observedCorruptMarker = await repairHolds.corruptMarkerObservation(environmentID: environmentID)
        // Fresh physical scan (never trusting the hold's preservedPath): find
        // the unacknowledged preserved quarantine entries that are either
        // unprovable or provenanced for this environment.
        var unverifiable: (path: String, directory: URL)?
        var resolvedPath: String?
        var evidenceDigest: String?
        let entries = (try? fileManager.contentsOfDirectory(atPath: layout.quarantineDirectory.path)) ?? []
        let acknowledged = await repairHolds.acknowledgedQuarantineEntryNames()
        for entry in entries where entry.hasPrefix("runtime-vm-") && !acknowledged.contains(entry) {
            let directory = layout.quarantineDirectory.appendingPathComponent(entry, isDirectory: true)
            guard let meta = RuntimeV2WorkingDirectory.readMeta(from: directory) else {
                // Damaged or missing metadata: the unverifiable case.
                guard unverifiable == nil else {
                    throw RuntimeV2Error.repairResolutionUnavailable(
                        environmentID: environmentID,
                        reason: "multiple unverifiable preserved entries exist; clean them up one at a time after individual inspection"
                    )
                }
                unverifiable = ("recovery/quarantine/\(entry)", directory)
                continue
            }
            guard meta.environmentID == environmentID else {
                // Another environment's preserved bytes: never touch them.
                if (try? RuntimeV2Identifier.validate(meta.environmentID, kind: .environment)) != nil {
                    throw RuntimeV2Error.workingDirectoryProvenanceUnavailable(
                        environmentID: environmentID,
                        reason: "the preserved entry \(entry) belongs to environment \(meta.environmentID); its bytes are that environment's state and are never moved by this cleanup"
                    )
                }
                continue
            }
            // Provenanced for this environment: that is the discardRepair
            // case, not unverifiable cleanup.
            throw RuntimeV2Error.repairResolutionUnavailable(
                environmentID: environmentID,
                reason: "the preserved entry \(entry) carries matching provenance; resolve it through discardRepair (or restoreRepair), not the unverifiable-evidence cleanup"
            )
        }
        if let candidate = unverifiable {
            // Re-validate the freshly scanned path with the full untrusted-path
            // checks immediately before the move (TOCTOU-resistant at this
            // layer: symlink resolution is recomputed here).
            let source = try layout.preservedRuntimeDirectory(candidate.path)
            evidenceDigest = try FloeDigest.sha512Hex(
                ofFileAt: source.appendingPathComponent("disk.img")
            )
            let archive = layout.recoveryMigrationsDirectory
                .appendingPathComponent("discarded", isDirectory: true)
                .appendingPathComponent(
                    "\(source.lastPathComponent)-\(Int(Date().timeIntervalSince1970))",
                    isDirectory: true
                )
            do {
                try fileManager.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: source, to: archive)
            } catch {
                throw RuntimeV2Error.repairResolutionUnavailable(
                    environmentID: environmentID,
                    reason: "the unverifiable evidence could not be moved into the discarded-evidence area (\(error.localizedDescription)); the exclusion was kept"
                )
            }
            resolvedPath = candidate.path
        }
        if let environment = try await registry.environment(id: environmentID),
           environment.state != "deleting" {
            try await registry.setEnvironmentState(
                id: environmentID, state: "stopped", repairReason: nil
            )
        }
        do {
            try await repairHolds.recordResolution(
                environmentID: environmentID, preservedPath: resolvedPath,
                resolution: "discarded", diskDigestSHA512: evidenceDigest,
                resolvedHoldID: await repairHolds.effectiveHold(environmentID: environmentID)?.holdID,
                observedCorruptMarker: observedCorruptMarker
            )
        } catch {
            try? await registry.setEnvironmentState(
                id: environmentID, state: "repairRequired",
                repairReason: "the repair resolution could not be persisted (\(error.localizedDescription)); the exclusion remains in place"
            )
            throw error
        }
        await logs.log(
            "runtime v2 repair discarded unverifiable evidence environment=\(environmentID) preservedPath=\(resolvedPath ?? "none") reason=\(reason)"
        )
        return RepairResolutionReport(
            resolution: "discarded", preservedPath: resolvedPath,
            diskDigestSHA512: nil, restoredGeneration: nil
        )
    }

    /// The preserved entry name must agree with the ownership record's
    /// runtime identity: `runtime/vm/<runtimeID>` directories are named
    /// exactly by the runtime, and quarantine entries are
    /// `runtime-vm-<runtimeID>` or `runtime-vm-<runtimeID>-<suffix>`. A
    /// mismatch means the path names different bytes than the record claims
    /// (tampered or stale sidecar).
    private func preservedEntryIdentityMatches(
        meta: RuntimeV2WorkingDirectory.Meta, preservedPath: String
    ) -> Bool {
        let last = (preservedPath as NSString).lastPathComponent
        if preservedPath.hasPrefix("runtime/vm/") {
            return last == meta.runtimeID
        }
        let base = "runtime-vm-\(meta.runtimeID)"
        return last == base || last.hasPrefix("\(base)-")
    }

    /// Explicit verified cleanup of a runtime/vm directory whose owner could
    /// never be traced (the defect-4 preservation path): recovery preserves
    /// such directories byte-for-byte in place on every launch because the
    /// absence of a trace is not proof the owner stopped. This is the ONLY
    /// way they ever leave runtime/vm: the caller (a human/tool, out of band)
    /// asserts the directory is dead, every attribution source is RE-PROVEN
    /// empty here, and only then are the bytes moved into the quarantine
    /// evidence area (never deleted). If any trace has appeared the cleanup
    /// refuses.
    public func archiveUnknownRuntimeDirectory(runtimeID: String) async throws {
        try RuntimeV2Identifier.validate(runtimeID, kind: .runtime)
        let directory = try layout.runtimeVMDirectory(runtimeID: runtimeID)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw RuntimeV2Error.repairResolutionUnavailable(
                environmentID: runtimeID,
                reason: "no runtime/vm/\(runtimeID) directory exists; nothing to clean up"
            )
        }
        guard RuntimeV2WorkingDirectory.readMeta(from: directory) == nil else {
            throw RuntimeV2Error.repairResolutionUnavailable(
                environmentID: runtimeID,
                reason: "runtime/vm/\(runtimeID) now has a readable ownership record; it is owned state and must be resolved through the repair flow, not unknown-directory cleanup"
            )
        }
        if let lease = await leases.lease(forRuntimeID: runtimeID) {
            throw RuntimeV2Error.repairResolutionUnavailable(
                environmentID: lease.environmentID,
                reason: "runtime/vm/\(runtimeID) is attributed to environment \(lease.environmentID) through a lease trace; the disk is not untraceable and must be resolved through the repair flow"
            )
        }
        let quarantine = layout.quarantineDirectory
            .appendingPathComponent("runtime-vm-\(runtimeID)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.moveItem(at: directory, to: quarantine)
        await logs.log(
            "runtime v2 unknown runtime directory archived runtimeID=\(runtimeID) quarantine=\(quarantine.lastPathComponent)"
        )
    }

    // MARK: scratch environment promotion

    /// Promotes a scratch environment's staged system delta and data from
    /// runtime/scratch into environments/<id> atomically — the only moment
    /// scratch state becomes persistent.
    public func promoteScratchEnvironment(scratchID: String, environmentID: String) async throws {
        try RuntimeV2Identifier.validate(scratchID, kind: .scratch)
        try RuntimeV2Identifier.validate(environmentID, kind: .environment)
        let scratchRoot = layout.runtimeScratchDirectory.appendingPathComponent(scratchID, isDirectory: true)
        guard fileManager.fileExists(atPath: scratchRoot.path) else {
            throw RuntimeV2Error.migrationFailed(
                id: "scratch-env-\(scratchID)", phase: "switched", reason: "no scratch state to promote"
            )
        }
        let destination = try layout.environmentDirectory(environmentID: environmentID)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw RuntimeV2Error.migrationFailed(
                id: "scratch-env-\(scratchID)", phase: "switched",
                reason: "environment \(environmentID) already exists; promotion refused"
            )
        }
        try fileManager.createDirectory(at: layout.environmentsDirectory, withIntermediateDirectories: true)
        guard rename(scratchRoot.path, destination.path) == 0 else {
            throw RuntimeV2Error.migrationFailed(
                id: "scratch-env-\(scratchID)", phase: "switched",
                reason: "atomic promotion failed (errno \(errno))"
            )
        }
    }

    // MARK: storage truth

    /// Separated disk usage: shared base blobs, rebuildable expanded views,
    /// per-environment deltas, per-environment data, workspaces, caches,
    /// temporary runtime, logs and the registry. Designed for UI statistics
    /// so shared bases are never counted once per environment.
    public func storageBreakdown() async throws -> StorageBreakdown {
        var breakdown = StorageBreakdown()
        breakdown.sharedBaseBlobBytes = (try? await registry.blobStats())?.bytes ?? directorySize(layout.blobStoreDirectory)
        breakdown.expandedRebuildableBytes = directorySize(layout.expandedImagesDirectory)
        breakdown.environmentDeltaBytes = sumOverEnvironments { system in
            directorySize(at: system, matching: { $0.hasPrefix("delta.") })
        }
        breakdown.environmentDataBytes = sumOverEnvironments { environmentDir in
            directorySize(environmentDir.appendingPathComponent("data", isDirectory: true))
        }
        breakdown.workspaceOwnedBytes = directorySize(layout.ownedWorkspacesDirectory)
        breakdown.workspaceScratchBytes = directorySize(layout.scratchWorkspacesDirectory)
        breakdown.cacheBytes = directorySize(layout.cacheDirectory)
        breakdown.runtimeTemporaryBytes = directorySize(layout.runtimeDirectory)
        breakdown.logBytes = directorySize(layout.logsDirectory)
        breakdown.registryBytes = directorySize(layout.registryDirectory)
        // Template truth comes from the registry rows (measured at build
        // time), not from a directory walk: the disk bytes live in the shared
        // blob store and are already counted in sharedBaseBlobBytes, so only
        // per-version logical/allocated/download figures are surfaced here.
        let templateRows = (try? await registry.templates(state: .verified)) ?? []
        breakdown.templateLogicalBytes = templateRows.reduce(0) { $0 + $1.logicalBytes }
        breakdown.templateAllocatedBytes = templateRows.reduce(0) { $0 + $1.allocatedBytes }
        breakdown.templateDownloadBytes = templateRows.reduce(0) { $0 + $1.downloadBytes }
        return breakdown
    }

    private func sumOverEnvironments(_ measure: (URL) -> Int64) -> Int64 {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: layout.environmentsDirectory.path) else {
            return 0
        }
        return entries.reduce(0) { total, entry in
            total + measure(layout.environmentsDirectory.appendingPathComponent(entry, isDirectory: true))
        }
    }

    private func directorySize(_ root: URL) -> Int64 {
        directorySize(at: root, matching: { _ in true })
    }

    private func directorySize(at root: URL, matching predicate: (String) -> Bool) -> Int64 {
        guard fileManager.fileExists(atPath: root.path),
              let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard predicate(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

/// Ownership record written into every runtime/vm/<runtimeID> working
/// directory at VM start: the only link from a leftover working disk back to
/// the environment and base image it belongs to. runtime/ is temporary, so
/// this sidecar exists purely so recovery can salvage or quarantine honestly.
///
/// This record also freezes the FULL boot base: the immutable template pin and
/// the SHA-512 of the exact disk bytes `disk.img` was cloned from. A stop or
/// crash recovery captures the disk against that recorded identity — never
/// against the current environment pin, which may have moved while the disk
/// was live.
public enum RuntimeV2WorkingDirectory {
    public struct Meta: Codable, Sendable, Equatable {
        public var version: Int
        public var runtimeID: String
        public var environmentID: String
        public var baseImageID: String
        public var createdAt: Date
        /// The immutable template version the working disk booted (nil = the
        /// disk is a clone of the base image rootfs).
        public var templateID: String?
        public var templateVersion: Int?
        public var templateDigest: String?
        /// SHA-512 of the exact bytes `disk.img` was cloned from: the pinned
        /// template's disk blob, or the verified base image rootfs.
        public var bootBaseDiskDigest: String?

        public init(
            runtimeID: String, environmentID: String, baseImageID: String, createdAt: Date,
            templateID: String? = nil, templateVersion: Int? = nil,
            templateDigest: String? = nil, bootBaseDiskDigest: String? = nil
        ) {
            self.version = 1
            self.runtimeID = runtimeID
            self.environmentID = environmentID
            self.baseImageID = baseImageID
            self.createdAt = createdAt
            self.templateID = templateID
            self.templateVersion = templateVersion
            self.templateDigest = templateDigest
            self.bootBaseDiskDigest = bootBaseDiskDigest
        }
    }

    public static func writeMeta(_ meta: Meta, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meta).write(
            to: directory.appendingPathComponent("runtime.json"), options: .atomic
        )
    }

    public static func readMeta(from directory: URL) -> Meta? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("runtime.json")) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Meta.self, from: data)
    }
}
