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
        public var repairedImages: [String]
        public var rebuiltExpandedViews: [String]
        public var sweptStagingEntries: Int
        public var notes: [String]

        public init() {
            self.interruptedQueueEntries = 0
            self.unreclaimableLeases = []
            self.salvagedRuntimeDirs = []
            self.quarantinedRuntimeDirs = []
            self.repairedImages = []
            self.rebuiltExpandedViews = []
            self.sweptStagingEntries = 0
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

        public init() {
            sharedBaseBlobBytes = 0; expandedRebuildableBytes = 0
            environmentDeltaBytes = 0; environmentDataBytes = 0
            workspaceOwnedBytes = 0; workspaceScratchBytes = 0
            cacheBytes = 0; runtimeTemporaryBytes = 0; logBytes = 0; registryBytes = 0
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
    private var fileManager: FileManager { .default }

    public init(
        layout: RuntimeV2Layout,
        poolConfiguration: RuntimeVMPool.Configuration = .init(),
    ) {
        self.layout = layout
        let registry = RuntimeV2Registry(layout: layout)
        self.registry = registry
        self.blobs = RuntimeV2BlobStore(layout: layout, registry: registry)
        self.images = RuntimeV2ImageStore(layout: layout, registry: registry, blobs: blobs)
        self.deltas = RuntimeV2DeltaStore(layout: layout)
        self.leases = RuntimeV2LeaseStore(layout: layout, registry: registry)
        self.pool = RuntimeVMPool(configuration: poolConfiguration, registry: registry)
        self.workspaces = RuntimeV2WorkspaceStore(layout: layout, registry: registry)
        self.caches = RuntimeV2CacheStore(layout: layout)
        self.logs = RuntimeV2LogStore(layout: layout)
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

    /// Captures the leftover working disk into the environment's delta (the
    /// same verified path as a clean stop) and marks the session interrupted.
    private func salvageWorkingDirectory(
        directory: URL, meta: RuntimeV2WorkingDirectory.Meta
    ) async throws {
        let workingDisk = directory.appendingPathComponent("disk.img")
        guard fileManager.fileExists(atPath: workingDisk.path) else { return }
        guard let manifest = try await images.manifest(imageID: meta.baseImageID),
              let rootfsRef = manifest.artifacts["rootfs"] ?? manifest.artifacts["disk"] else {
            throw RuntimeV2Error.imageNotFound(meta.baseImageID)
        }
        let expanded = try await images.ensureExpanded(imageID: meta.baseImageID)
        let baseRootfs = expanded.appendingPathComponent(rootfsRef.expandedPath)
        let info = try await deltas.capture(
            environmentID: meta.environmentID,
            workingDisk: workingDisk,
            baseRootfs: baseRootfs,
            baseImageID: meta.baseImageID,
            baseRootfsSHA512: rootfsRef.sha512
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
public enum RuntimeV2WorkingDirectory {
    public struct Meta: Codable, Sendable, Equatable {
        public var version: Int
        public var runtimeID: String
        public var environmentID: String
        public var baseImageID: String
        public var createdAt: Date

        public init(runtimeID: String, environmentID: String, baseImageID: String, createdAt: Date) {
            self.version = 1
            self.runtimeID = runtimeID
            self.environmentID = environmentID
            self.baseImageID = baseImageID
            self.createdAt = createdAt
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
