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
    public let pool: RuntimeVMPool
    public let workspaces: RuntimeV2WorkspaceStore
    public let caches: RuntimeV2CacheStore
    public let logs: RuntimeV2LogStore
    public let templates: RuntimeV2TemplateStore
    private var fileManager: FileManager { .default }

    public init(
        layout: RuntimeV2Layout,
        poolConfiguration: RuntimeVMPool.Configuration = .init(),
        templateSeams: RuntimeV2TemplateStore.Seams = .production,
        blobSeams: RuntimeV2BlobStore.Seams = .production
    ) {
        self.layout = layout
        let registry = RuntimeV2Registry(layout: layout)
        self.registry = registry
        self.blobs = RuntimeV2BlobStore(layout: layout, registry: registry, seams: blobSeams)
        self.images = RuntimeV2ImageStore(layout: layout, registry: registry, blobs: blobs)
        self.deltas = RuntimeV2DeltaStore(layout: layout)
        self.leases = RuntimeV2LeaseStore(layout: layout, registry: registry)
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
        //    reported and its environment marked interrupted.
        let unresolved = (try? await leases.recoverOnLaunch()) ?? []
        report.unreclaimableLeases = unresolved
        for environmentID in unresolved {
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
                // No ownership record: not adoptable, but kept for inspection.
                let quarantine = layout.quarantineDirectory
                    .appendingPathComponent("runtime-vm-\(entry)-\(UUID().uuidString)", isDirectory: true)
                try? fileManager.moveItem(at: directory, to: quarantine)
                report.quarantinedRuntimeDirs.append(entry)
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
            do {
                try await salvageWorkingDirectory(directory: directory, meta: meta)
                try? fileManager.removeItem(at: directory)
                report.salvagedRuntimeDirs.append(entry)
            } catch {
                let quarantine = layout.quarantineDirectory
                    .appendingPathComponent("runtime-vm-\(entry)-\(UUID().uuidString)", isDirectory: true)
                try? fileManager.moveItem(at: directory, to: quarantine)
                report.quarantinedRuntimeDirs.append(entry)
                try? await registry.setEnvironmentState(
                    id: meta.environmentID, state: "repairRequired",
                    repairReason: "interrupted working disk could not be salvaged: \(error.localizedDescription)"
                )
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
