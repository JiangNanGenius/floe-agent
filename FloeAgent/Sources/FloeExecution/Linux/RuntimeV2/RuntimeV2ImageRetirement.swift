// FloeExecution — automatic retirement of host-owned factory images.
//
// A downloaded base image becomes usable only after `RuntimeV2ImageStore`
// verified every artifact and materialized the expanded view. From that moment
// the retired copies of the generation it replaced are no longer a recovery
// path: the verified blobs hold the same bytes and a failed cutover is already
// handled by `migrateLegacyImage`/`rollbackMigration` before usability is ever
// announced. This file owns the durable lifecycle that turns that fact into
// reclaimed storage:
//
//   * RETIRED ARCHITECTURE — the guest runtime an image was built for no longer
//     exists on this machine. Every verified factory generation of that
//     architecture is retired, including its migration rollback copies, its
//     expanded view, its v2 manifest and the blobs only it references. There is
//     never a retained boot fallback and no redownload: the architecture is not
//     offered and cannot boot here.
//   * SUPERSEDED GENERATION — the image's own factory manifest declares the
//     predecessor (`compatibleOrigins`). After a usable replacement generation
//     exists, the predecessor closure is retired transitively, so repeated
//     upgrades converge without any per-build/per-image allowlist. A generation
//     that is still an environment base, a template pin, a live lease, an
//     active/preserved working disk or a user boot selection is retained and
//     reported with that exact reason.
//   * VERIFIED PRIOR BACKUP — the migration rollback copy of the image that
//     just became usable (`recovery/migrations/legacy-image-<id>/…`). The v2
//     blobs are the authenticated copy, so the duplicate factory bytes go; a
//     same-id reinstall simply creates a new backup, which a later pass retires
//     the same way.
//
// Safety contract (proven by RuntimeV2ImageRetirementTests):
//  * Every deleted byte is an entry declared by an authenticated factory
//    manifest (declared artifact, the factory manifest itself) or a file the
//    substrate itself materialized for that manifest. There is NO recursive
//    path-prefix delete, NO age/ID-only delete and NO directory sweep: each
//    entry is opened `O_NOFOLLOW`, lstat-ed, required to be a regular
//    single-link file owned by this process and matched against the file
//    instance recorded in the durable plan before `unlinkat`.
//  * An entry that changed, is a symlink, is not ours, is undeclared or has an
//    unreadable manifest is retained and reported; the image identity may still
//    be retired (it can never boot again) but the unknown bytes stay.
//  * Shared blob content is released through the registry's reference-count
//    transaction: a digest still referenced by another image manifest, a
//    template disk or an in-flight staging claim keeps its bytes.
//  * The plan is durable BEFORE the first unlink and the physical progress is
//    recorded after each unlink, so a kill/interrupted switch resumes from the
//    stored plan. A `done` row is only reused while the generation is really
//    gone; if identical bytes reappear, the pass reopens and converges again.
//  * The whole pass runs under the existing shared recovery use (the same
//    fence every store operation takes) and the registered maintenance
//    domain's shared claim, so exclusive maintenance/storage optimization can
//    never interleave with it.

import Foundation
import FloeCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Architecture policy

/// The architecture a factory image was built for, derived from the image's
/// OWN manifest bytes (declared artifact names and the factory package list) —
/// never from an image id, a path prefix or the current machine.
public enum RuntimeV2FactoryImageArchitecture: String, Codable, Sendable, CaseIterable {
    case arm64
    case riscv64
    /// No decisive marker in the authenticated manifest. Such a generation is
    /// never treated as retired by architecture.
    case unknown

    /// Architectures whose guest runtime has been discontinued. Their factory
    /// generations are retired instead of kept as a boot fallback. This is the
    /// product policy, not a build/image allowlist: a future migration to a
    /// new architecture changes this one set, never a list of image ids.
    public static let retired: Set<RuntimeV2FactoryImageArchitecture> = [.riscv64]

    public var isRetired: Bool { Self.retired.contains(self) }
}

public struct RuntimeV2FactoryImageArchitectureEvidence: Codable, Sendable, Equatable {
    public var architecture: RuntimeV2FactoryImageArchitecture
    /// The concrete manifest field that decided the architecture (diagnostic,
    /// kept in the durable retirement row).
    public var detail: String

    public init(architecture: RuntimeV2FactoryImageArchitecture, detail: String) {
        self.architecture = architecture
        self.detail = detail
    }
}

/// Reads architecture evidence from the verbatim factory manifest. Only the
/// image's own declared content is consulted: paths it will boot and the
/// package architecture list its template recorded.
public enum RuntimeV2FactoryImageArchitectureInspector {
    public static func inspect(
        legacyManifestJSON data: Data
    ) -> RuntimeV2FactoryImageArchitectureEvidence? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var paths: [String] = []
        func append(_ value: Any?) {
            if let text = value as? String, !text.isEmpty { paths.append(text) }
        }
        append(object["biosPath"])
        append(object["kernelPath"])
        append(object["initrdPath"])
        append(object["diskPath"])
        if let runner = object["runnerArtifact"] as? [String: Any] { append(runner["path"]) }
        for artifact in object["artifacts"] as? [[String: Any]] ?? [] { append(artifact["path"]) }

        func marker(_ text: String, _ needle: String) -> Bool {
            text.lowercased().contains(needle)
        }
        for path in paths {
            let leaf = path.split(separator: "/").last.map(String.init) ?? path
            if leaf.lowercased() == "bbl64.bin" {
                // TinyEMU's RISC-V boot loader: there is no ARM64 image with
                // this declared firmware.
                return .init(architecture: .riscv64, detail: "bios=bbl64.bin")
            }
            if marker(leaf, "riscv") {
                return .init(architecture: .riscv64, detail: "artifact path declares riscv64: \(leaf)")
            }
        }
        if let template = object["template"] as? [String: Any],
           let packages = template["packages"] as? [[String: Any]] {
            let riscv = packages.filter { ($0["arch"] as? String)?.lowercased() == "riscv64" }
            if !riscv.isEmpty {
                return .init(
                    architecture: .riscv64,
                    detail: "template records \(riscv.count) riscv64 packages"
                )
            }
            let arm = packages.filter {
                let arch = ($0["arch"] as? String)?.lowercased()
                return arch == "arm64" || arch == "aarch64"
            }
            if !arm.isEmpty {
                return .init(architecture: .arm64, detail: "template records \(arm.count) arm64 packages")
            }
        }
        for path in paths {
            let leaf = path.split(separator: "/").last.map(String.init) ?? path
            if marker(leaf, "arm64") || marker(leaf, "aarch64") {
                return .init(architecture: .arm64, detail: "artifact path declares arm64: \(leaf)")
            }
        }
        return .init(architecture: .unknown, detail: "no architecture marker in the factory manifest")
    }
}

// MARK: - Report

public struct RuntimeV2FactoryImageRetirementReport: Sendable, Equatable {
    public enum Trigger: String, Sendable, Equatable {
        /// A verified, usable image generation was announced by the install or
        /// boot path; its superseded predecessors and prior backups were
        /// reconciled.
        case usableImage
        /// The retired-architecture backlog was reconciled without a new
        /// replacement (nothing of that architecture can ever boot here).
        case retiredArchitectureBacklog
        /// The announced image is not durably usable (no verified row, no
        /// manifest, no expanded rootfs at its recorded size): nothing was
        /// retired and no durable plan was written.
        case notUsable
        /// The shared recovery fence or the maintenance domain refused the
        /// pass; it stays retryable.
        case deferred
        /// The caller's cancellation signal fired before any durable step.
        case cancelled
    }

    public var trigger: Trigger
    public var triggerImageID: String?
    public var triggerDetail: String
    /// Images whose whole factory identity was retired by this pass.
    public var retiredImages: [String]
    /// Images the pass refused to retire, with the exact live reason.
    public var retainedImages: [String: String]
    /// Images already recorded `done` whose bytes are gone (progress reused).
    public var alreadyRetiredImages: [String]
    public var deletedFiles: Int
    public var deletedBytes: Int64
    public var releasedBlobs: Int
    public var releasedBlobBytes: Int64
    /// Per-image failures (retryable on the next pass).
    public var failures: [String]
    public var cancelled: Bool
    public var retirements: [RuntimeV2Registry.ImageRetirementRow]

    public init(
        trigger: Trigger, triggerImageID: String? = nil, triggerDetail: String = "",
        retiredImages: [String] = [], retainedImages: [String: String] = [:],
        alreadyRetiredImages: [String] = [], deletedFiles: Int = 0,
        deletedBytes: Int64 = 0, releasedBlobs: Int = 0, releasedBlobBytes: Int64 = 0,
        failures: [String] = [], cancelled: Bool = false,
        retirements: [RuntimeV2Registry.ImageRetirementRow] = []
    ) {
        self.trigger = trigger
        self.triggerImageID = triggerImageID
        self.triggerDetail = triggerDetail
        self.retiredImages = retiredImages
        self.retainedImages = retainedImages
        self.alreadyRetiredImages = alreadyRetiredImages
        self.deletedFiles = deletedFiles
        self.deletedBytes = deletedBytes
        self.releasedBlobs = releasedBlobs
        self.releasedBlobBytes = releasedBlobBytes
        self.failures = failures
        self.cancelled = cancelled
        self.retirements = retirements
    }
}

// MARK: - Retirement engine

/// Metadata-fast retirement of host-owned factory generations. See the file
/// header for the complete safety contract.
public actor RuntimeV2FactoryImageRetirement {
    /// Reason labels are durable (stored in `image_retirements.reason`).
    enum Reason: String, Codable, Sendable {
        case retiredArchitecture = "retired-architecture"
        case superseded
        case verifiedPriorBackup = "verified-prior-backup"
    }

    /// A deletion plan is expressed as layout-relative anchors plus the exact
    /// file instances observed at plan time. Nothing in the plan is a search
    /// pattern: execution only ever drops the named entries.
    struct Plan: Codable, Sendable, Equatable {
        struct File: Codable, Sendable, Equatable {
            /// Path relative to the item's anchor.
            var relativePath: String
            var bytes: Int64
            var device: UInt64
            var inode: UInt64
            var size: Int64
            var modificationSeconds: Int64
            var modificationNanoseconds: Int64
            var changeSeconds: Int64
            var changeNanoseconds: Int64
            var linkCount: UInt64
            /// Present for small factory records (the manifest files) only: the
            /// exact bytes parsed at plan time must still be the bytes that are
            /// deleted.
            var sha512: String?
        }

        struct Item: Codable, Sendable, Equatable {
            enum Kind: String, Codable, Sendable {
                case migrationLegacyImages
                case migrationExpandedPrevious
                case expandedView
                case quarantinedExpandedView
                case legacyInstallCopy
                case manifest
            }

            var kind: Kind
            var anchorRelativePath: String
            /// nil = the anchor is layout-relative. "legacy-images" = the
            /// caller-supplied legacy image root (a directory the App owns);
            /// the relative path is then `<imageID>` only.
            var anchorRoot: String? = nil
            var files: [File]
            /// Layout-relative directories that become empty once `files` are
            /// gone. Removed bottom-up with `rmdir` only; a non-empty directory
            /// is retained with its remaining bytes.
            var removableDirectories: [String]
        }

        var imageID: String
        var reason: Reason
        var architecture: String
        var evidence: String
        var items: [Item]
        /// Artifact digests the retired v2 manifest owned (one reference per
        /// digest). Empty for a prior-backup-only plan.
        var artifactDigests: [String]
        var deletesImageIdentity: Bool
        /// Facts discovered while planning that already prevent a complete
        /// teardown (undeclared entries, changed files, unreadable records).
        var retained: [String]
    }

    private struct Request {
        var triggerImageID: String?
        var legacyImagesRoot: URL?
        /// The image the native resident ARM64 machine is actually booting.
        /// Its mutable disk and origin.json live OUTSIDE this layout, so this
        /// layout can never prove that pin by itself: the App passes the bound
        /// native identity. A protected generation is never retired, even when
        /// no registry environment row pins it.
        var protectedActiveImageID: String?
        var isCancelled: (@Sendable () -> Bool)?
    }

    private struct ImageRecord {
        var id: String
        var v2Manifest: RuntimeV2ImageStore.Manifest?
        var v2ManifestData: Data?
        var registryRow: RuntimeV2Registry.ImageRow?
        var migrationRow: RuntimeV2Registry.MigrationRow?
        var rollbackLegacyManifestData: Data?
        var hasRollbackLegacyDirectory: Bool
        var hasRollbackExpandedPrevious: Bool
        var hasExpandedDirectory: Bool
        var hasManifestFile: Bool
        /// `recovery/quarantine/expanded-<id>-<UUID>` entries attributed by the
        /// manifest INSIDE them (the directory name is never the authority).
        var quarantinedExpandedEntries: [String] = []
        /// `<legacyImagesRoot>/<id>` when the caller supplied that root and its
        /// manifest identifies this generation (the fallback for a generation
        /// whose v2 row no longer exists).
        var legacyInstallManifestData: Data?

        var factoryManifestData: Data? {
            v2Manifest?.legacyManifestData ?? rollbackLegacyManifestData ?? legacyInstallManifestData
        }

        var hasAnyPhysicalPresence: Bool {
            hasRollbackLegacyDirectory || hasRollbackExpandedPrevious
                || hasExpandedDirectory || hasManifestFile || registryRow != nil
                || !quarantinedExpandedEntries.isEmpty || legacyInstallManifestData != nil
        }

        var migrationID: String { "legacy-image-" + id }
    }

    private struct ReferenceFacts {
        /// False when ANY registry/filesystem lookup needed to prove the live
        /// owners failed. An incomplete read is never "no references": the
        /// whole pass defers instead of deleting bytes it cannot account for.
        var isComplete = true
        /// imageID → environment ids that boot it (active/stopped/repairRequired).
        var environmentBaseImageIDs: [String: [String]] = [:]
        /// imageID → environment ids holding a live lease.
        var liveLeaseImageIDs: Set<String> = []
        /// imageID → template version labels pinned to it as their base.
        var templatePinImageIDs: Set<String> = []
        /// imageID → live or preserved working-disk owners.
        var workingDiskImageIDs: Set<String> = []
        /// Images whose expanded view carries a user boot-asset selection.
        var bootSelectedImageIDs: Set<String> = []
    }

    private let layout: RuntimeV2Layout
    private let registry: RuntimeV2Registry
    private let blobs: RuntimeV2BlobStore
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(layout: RuntimeV2Layout, registry: RuntimeV2Registry, blobs: RuntimeV2BlobStore) {
        self.layout = layout
        self.registry = registry
        self.blobs = blobs
    }

    // MARK: public entry points

    /// Reconciles factory generations after `imageID` proved usable.
    ///
    /// Durable trigger: `images.state = 'verified'` AND the v2 manifest exists
    /// AND its rootfs artifact exists in the expanded view at the recorded
    /// byte count. Only then is any retirement record written. Repeated calls
    /// (app taps, relaunches, retries, re-downloads) reuse the durable
    /// `image_retirements` rows: a completed row is a no-op while the
    /// generation is absent, and an interrupted/failed row resumes its stored
    /// plan instead of re-deriving or repeating work.
    @discardableResult
    public func retireSupersededFactoryImages(
        afterUsableImage imageID: String,
        legacyImagesRoot: URL? = nil,
        protectedActiveImageID: String? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) async -> RuntimeV2FactoryImageRetirementReport {
        await serialized(Request(
            triggerImageID: imageID, legacyImagesRoot: legacyImagesRoot,
            protectedActiveImageID: protectedActiveImageID, isCancelled: isCancelled
        ))
    }

    /// Reconciles the backlog of a discontinued architecture. This is the
    /// launch-time hook: it needs no replacement image because nothing of that
    /// architecture can boot on this machine, and it never waits for a legacy
    /// environment pin that can never boot.
    @discardableResult
    public func retireRetiredArchitectureFactoryImages(
        legacyImagesRoot: URL? = nil,
        protectedActiveImageID: String? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) async -> RuntimeV2FactoryImageRetirementReport {
        await serialized(Request(
            triggerImageID: nil, legacyImagesRoot: legacyImagesRoot,
            protectedActiveImageID: protectedActiveImageID, isCancelled: isCancelled
        ))
    }

    /// Durable retirement records, for status/UI composition.
    public func retirementRecords() async throws -> [RuntimeV2Registry.ImageRetirementRow] {
        try await registry.open()
        return try await registry.imageRetirements()
    }

    // MARK: serialization

    private func serialized(_ request: Request) async -> RuntimeV2FactoryImageRetirementReport {
        await acquire()
        defer { release() }
        return await perform(request)
    }

    private func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        busy = true
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            let next = waiters.removeFirst()
            next.resume()
        }
    }

    // MARK: pass

    private func perform(_ request: Request) async -> RuntimeV2FactoryImageRetirementReport {
        func isCancelled() -> Bool { request.isCancelled?() == true }

        if isCancelled() {
            return .init(trigger: .cancelled, triggerImageID: request.triggerImageID)
        }
        // The same shared recovery fence every store operation takes, plus the
        // registered maintenance domain's shared claim when this root has one.
        // An exclusive maintenance/optimization can never observe a half-retired
        // generation, and this pass defers instead of racing it.
        let nativeUse: RuntimeV2RecoveryUse?
        do {
            nativeUse = try layout.beginNativeRecoveryUse()
        } catch {
            return .init(
                trigger: .deferred, triggerImageID: request.triggerImageID,
                triggerDetail: "the runtime recovery fence is closed: \(error.localizedDescription)"
            )
        }
        defer { nativeUse?.release() }
        // Serialize retirement instances even on roots without a registered
        // maintenance domain (the live arm64-v1 substrate). This is a
        // retirement-only lock: it never substitutes for the store's own
        // exclusion, and a busy lock defers instead of waiting on the UI path.
        let retirementLock = acquireRetirementLock()
        if retirementLock == nil {
            return .init(
                trigger: .deferred, triggerImageID: request.triggerImageID,
                triggerDetail: "another factory-image retirement pass is running"
            )
        }
        defer { releaseRetirementLock(retirementLock) }
        let coordinator = RuntimeV2MaintenanceRegistry.coordinator(forLayoutRoot: layout.root)
        let sharedUse: RuntimeV2MaintenanceSharedUse?
        do {
            sharedUse = try await coordinator?.acquireSharedUse(
                owner: "runtime-v2-factory-image-retirement",
                purpose: "retire-factory-images"
            )
        } catch {
            return .init(
                trigger: .deferred, triggerImageID: request.triggerImageID,
                triggerDetail: "legacy maintenance holds the domain: \(error.localizedDescription)"
            )
        }
        defer { Task { await sharedUse?.release() } }

        do {
            try await registry.open()
        } catch {
            return .init(
                trigger: .deferred, triggerImageID: request.triggerImageID,
                triggerDetail: "the registry is unavailable: \(error.localizedDescription)"
            )
        }

        var triggerRootfsDigest: String?
        if let triggerID = request.triggerImageID {
            guard let rootfs = await usableRootfsDigest(imageID: triggerID) else {
                return .init(
                    trigger: .notUsable, triggerImageID: triggerID,
                    triggerDetail: "no verified row + manifest + expanded rootfs at the recorded size"
                )
            }
            triggerRootfsDigest = rootfs
        }

        var records = (try? await registry.imageRetirements()) ?? []
        var recordByID = Dictionary(uniqueKeysWithValues: records.map { ($0.imageID, $0) })
        var candidates = await discoverImages(legacyImagesRoot: request.legacyImagesRoot)
        var retained: [String: String] = [:]
        var retired: [String] = []
        var alreadyRetired: [String] = []
        var failures: [String] = []
        var deletedFiles = 0
        var deletedBytes: Int64 = 0
        var releasedBlobs = 0
        var releasedBlobBytes: Int64 = 0

        // The predecessor closure is derived BEFORE anything is deleted, so a
        // chain of three/four/five upgrades converges in one pass without any
        // image-id allowlist. Each image's own authenticated manifest declares
        // its immediate predecessor.
        var lineage: Set<String> = []
        if let triggerID = request.triggerImageID {
            lineage = predecessorClosure(of: triggerID, candidates: &candidates)
        }
        guard let references = await referenceFacts() else {
            return .init(
                trigger: .deferred, triggerImageID: request.triggerImageID,
                triggerDetail: "live-owner evidence is incomplete; nothing was retired"
            )
        }
        guard references.isComplete else {
            return .init(
                trigger: .deferred, triggerImageID: request.triggerImageID,
                triggerDetail: "a working-disk owner sidecar is unreadable; nothing was retired"
            )
        }

        for id in candidates.keys.sorted() {
            if isCancelled() { break }
            guard let candidate = candidates[id] else { continue }

            let evidence = candidate.factoryManifestData.flatMap {
                RuntimeV2FactoryImageArchitectureInspector.inspect(legacyManifestJSON: $0)
            }
            let reason: Reason?
            if let evidence, evidence.architecture.isRetired {
                reason = .retiredArchitecture
            } else if let triggerID = request.triggerImageID, id != triggerID, lineage.contains(id) {
                reason = .superseded
            } else if let triggerID = request.triggerImageID, id == triggerID,
                      candidate.hasRollbackLegacyDirectory || candidate.hasRollbackExpandedPrevious
                      || !candidate.quarantinedExpandedEntries.isEmpty {
                reason = .verifiedPriorBackup
            } else {
                reason = nil
            }
            guard let reason else { continue }

            let existing = recordByID[id]
            // A `done` row is progress reused only while the generation is
            // really absent. Re-downloaded identical bytes (or a same-id
            // reinstall creating a new rollback) reopen the lifecycle, so
            // repeated generations converge instead of leaking.
            if let existing, existing.phase == .done, !candidate.hasAnyPhysicalPresence {
                alreadyRetired.append(id)
                continue
            }

            // Reference and ownership evidence decides retention BEFORE a plan
            // is written. A retired architecture is never kept for a pin that
            // can never boot, but it is never torn down under a live lease or a
            // live working disk either.
            if let keep = retentionReason(
                for: id, reason: reason, candidate: candidate, references: references,
                protectedActiveImageID: request.protectedActiveImageID
            ) {
                retained[id] = keep
                continue
            }

            var plan: Plan
            if let prior = recordByID[id], prior.phase != .done,
               let stored = Self.decodePlan(prior.planJSON), stored.imageID == id,
               stored.reason == reason {
                plan = stored
            } else {
                plan = await buildPlan(
                    candidate: candidate, reason: reason,
                    evidence: evidence, triggerRootfsDigest: triggerRootfsDigest,
                    legacyImagesRootForPlan: request.legacyImagesRoot,
                    protectedActiveImageID: request.protectedActiveImageID
                )
            }
            if plan.items.isEmpty {
                // Nothing in the plan is provably factory-owned. Keep every
                // byte and record why instead of retiring an identity whose
                // files could not be named.
                if existing?.phase == .done {
                    alreadyRetired.append(id)
                } else {
                    retained[id] = plan.retained.first ?? "no-factory-owned-bytes"
                    if existing != nil {
                        try? await registry.recordImageRetirementRetained(
                            imageID: id,
                            notes: plan.retained.isEmpty ? ["no-factory-owned-bytes"] : plan.retained
                        )
                    }
                }
                continue
            }
            if !plan.deletesImageIdentity {
                plan.artifactDigests = []
            }
            // The generation is physically present again (or a new rollback
            // appeared): reopen the completed lifecycle only now that the plan
            // proves there is real work to do.
            if existing?.phase == .done {
                if let reopened = try? await registry.reopenImageRetirement(imageID: id) {
                    recordByID[id] = reopened
                } else {
                    failures.append("\(id): a completed retirement could not be reopened")
                    continue
                }
            }

            let row = RuntimeV2Registry.ImageRetirementRow(
                imageID: id,
                reason: reason.rawValue,
                phase: .planned,
                triggerImageID: request.triggerImageID,
                triggerRootfsDigest: triggerRootfsDigest,
                architecture: plan.architecture,
                evidence: plan.evidence,
                planJSON: Self.encodePlan(plan),
                releasedDigests: recordByID[id]?.releasedDigests ?? [],
                retainedNotes: recordByID[id]?.retainedNotes ?? [],
                retiredBytes: recordByID[id]?.retiredBytes ?? 0,
                attempts: recordByID[id]?.attempts ?? 0
            )
            guard let stored = try? await registry.planImageRetirement(row) else {
                failures.append("\(id): the retirement plan could not be persisted")
                continue
            }
            recordByID[id] = stored
            records = records.filter { $0.imageID != id } + [stored]

            // Deletion-time re-validation: another store instance may have
            // created an environment/lease/working disk or a template pin
            // since the pass began. Recompute the live facts under the fence
            // and never touch bytes that became live in between.
            guard let liveNow = await referenceFacts(), liveNow.isComplete else {
                try? await registry.failImageRetirement(
                    imageID: id, error: "live-owner evidence became incomplete; nothing was deleted"
                )
                continue
            }
            if let keep = retentionReason(
                for: id, reason: reason, candidate: candidate, references: liveNow,
                protectedActiveImageID: request.protectedActiveImageID
            ) {
                retained[id] = keep
                try? await registry.failImageRetirement(
                    imageID: id, error: "retained at deletion time: \(keep)"
                )
                continue
            }
            let outcome = await execute(
                plan: plan, record: stored,
                legacyImagesRoot: request.legacyImagesRoot, isCancelled: isCancelled
            )
            deletedFiles += outcome.deletedFiles
            deletedBytes += outcome.deletedBytes
            releasedBlobs += outcome.releasedBlobs
            releasedBlobBytes += outcome.releasedBlobBytes
            if let updated = try? await registry.imageRetirement(imageID: id) {
                recordByID[id] = updated
                records = records.filter { $0.imageID != id } + [updated]
            } else {
                recordByID[id] = stored
            }
            if outcome.failed {
                failures.append(outcome.failure ?? "\(id): retirement failed")
            } else {
                retired.append(id)
            }
            if outcome.cancelled {
                return .init(
                    trigger: request.triggerImageID == nil
                        ? .retiredArchitectureBacklog : .usableImage,
                    triggerImageID: request.triggerImageID,
                    triggerDetail: "cancelled mid-pass; the durable plan resumes on the next pass",
                    retiredImages: retired, retainedImages: retained,
                    alreadyRetiredImages: alreadyRetired,
                    deletedFiles: deletedFiles, deletedBytes: deletedBytes,
                    releasedBlobs: releasedBlobs,
                    releasedBlobBytes: releasedBlobBytes,
                    failures: failures, cancelled: true,
                    retirements: records.sorted { $0.imageID < $1.imageID }
                )
            }
        }

        let trigger: RuntimeV2FactoryImageRetirementReport.Trigger = request.triggerImageID == nil
            ? .retiredArchitectureBacklog : .usableImage
        return .init(
            trigger: trigger,
            triggerImageID: request.triggerImageID,
            triggerDetail: request.triggerImageID == nil
                ? "retired-architecture backlog reconciled"
                : "usable replacement reconciled",
            retiredImages: retired.sorted(),
            retainedImages: retained,
            alreadyRetiredImages: alreadyRetired.sorted(),
            deletedFiles: deletedFiles,
            deletedBytes: deletedBytes,
            releasedBlobs: releasedBlobs,
            releasedBlobBytes: releasedBlobBytes,
            failures: failures,
            cancelled: isCancelled(),
            retirements: records.sorted { $0.imageID < $1.imageID }
        )
    }

    // MARK: usability trigger

    private func usableRootfsDigest(imageID: String) async -> String? {
        guard (try? RuntimeV2Identifier.validate(imageID, kind: .image)) != nil else { return nil }
        guard let row = (try? await registry.bootableImage(id: imageID, root: layout.root)) ?? nil,
              row.state == .verified,
              let manifest = (try? readV2Manifest(imageID: imageID)) ?? nil,
              let ref = manifest.artifacts["rootfs"] ?? manifest.artifacts["disk"],
              let expanded = try? layout.expandedImageDirectory(imageID: imageID) else {
            return nil
        }
        let file = expanded.appendingPathComponent(ref.expandedPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              (attributes[.size] as? NSNumber)?.int64Value == ref.bytes,
              (attributes[.type] as? FileAttributeType) == .typeRegular else {
            return nil
        }
        return ref.sha512.lowercased()
    }

    // MARK: discovery

    private func discoverImages(legacyImagesRoot: URL? = nil) async -> [String: ImageRecord] {
        var ids = Set<String>()
        ids.formUnion((try? await registry.allImageIDs()) ?? [])
        ids.formUnion(validatedDirectoryIDs(layout.imageManifestsDirectory, suffix: ".json"))
        let migrations = (try? await registry.migrations(inPhases: Set(RuntimeV2Registry.MigrationPhase.allCases))) ?? []
        for row in migrations where row.kind == "legacy-image" {
            if let id = Self.imageID(fromMigrationID: row.id),
               (try? RuntimeV2Identifier.validate(id, kind: .image)) != nil {
                ids.insert(id)
            }
        }
        ids.formUnion(validatedDirectoryIDs(migrationRoot, prefix: "legacy-image-"))

        var result: [String: ImageRecord] = [:]
        for id in ids.sorted() {
            // A v2 manifest counts only when it is really THIS generation's
            // manifest: the same image id and a decodable embedded factory
            // manifest with the same id. Anything else is unidentified bytes.
            var v2Data: Data?
            var v2Manifest: RuntimeV2ImageStore.Manifest?
            if let data = try? readV2ManifestData(imageID: id),
               let decoded = try? RuntimeV2ImageStore.decoder.decode(
                   RuntimeV2ImageStore.Manifest.self, from: data
               ),
               decoded.imageID == id,
               let embedded = try? RuntimeV2ImageStore.decoder.decode(
                   LinuxGuestImage.self, from: decoded.legacyManifestData
               ),
               embedded.id == id {
                v2Data = data
                v2Manifest = decoded
            }
            let row = (try? await registry.image(id: id)) ?? nil
            let migration = (try? await registry.migration(id: "legacy-image-" + id)) ?? nil
            let rollbackLegacy = layout.recoveryMigrationsDirectory
                .appendingPathComponent("legacy-image-" + id, isDirectory: true)
                .appendingPathComponent("legacy-images", isDirectory: true)
                .appendingPathComponent(id, isDirectory: true)
            let rollbackExpanded = layout.recoveryMigrationsDirectory
                .appendingPathComponent("legacy-image-" + id, isDirectory: true)
                .appendingPathComponent("expanded-previous", isDirectory: true)
            var rollbackManifestData: Data?
            if let data = try? readRegularFile(
                rollbackLegacy.appendingPathComponent("manifest.json")
            ) {
                if let image = try? RuntimeV2ImageStore.decoder.decode(LinuxGuestImage.self, from: data),
                   image.id == id {
                    rollbackManifestData = data
                }
            }
            var legacyManifestData: Data?
            if let legacyImagesRoot {
                let legacyDirectory = legacyImagesRoot.appendingPathComponent(id, isDirectory: true)
                if let data = try? readRegularFile(legacyDirectory.appendingPathComponent("manifest.json")),
                   let image = try? RuntimeV2ImageStore.decoder.decode(LinuxGuestImage.self, from: data),
                   image.id == id {
                    legacyManifestData = data
                }
            }
            result[id] = ImageRecord(
                id: id,
                v2Manifest: v2Manifest,
                v2ManifestData: v2Data,
                registryRow: row,
                migrationRow: migration,
                rollbackLegacyManifestData: rollbackManifestData,
                hasRollbackLegacyDirectory: isRealDirectory(rollbackLegacy),
                hasRollbackExpandedPrevious: isRealDirectory(rollbackExpanded),
                hasExpandedDirectory: (try? layout.expandedImageDirectory(imageID: id)).map(isRealDirectory) ?? false,
                hasManifestFile: manifestFileExists(imageID: id),
                quarantinedExpandedEntries: quarantineEntries(for: id),
                legacyInstallManifestData: legacyManifestData
            )
        }
        // A legacy install whose v2 row no longer exists (a generation retired
        // before its legacy bytes were reconciled) must still be discoverable
        // when the caller supplies its root: enumerate it, attributed by its
        // OWN manifest, never by the directory name.
        if let legacyImagesRoot {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: legacyImagesRoot.path)) ?? []
            for name in names {
                guard (try? RuntimeV2Identifier.validate(name, kind: .image)) != nil else { continue }
                guard result[name] == nil else { continue }
                let directory = legacyImagesRoot.appendingPathComponent(name, isDirectory: true)
                guard isRealDirectory(directory),
                      let data = try? readRegularFile(directory.appendingPathComponent("manifest.json")),
                      let image = try? RuntimeV2ImageStore.decoder.decode(LinuxGuestImage.self, from: data),
                      image.id == name else { continue }
                result[name] = ImageRecord(
                    id: name, v2Manifest: nil, v2ManifestData: nil, registryRow: nil,
                    migrationRow: nil, rollbackLegacyManifestData: nil,
                    hasRollbackLegacyDirectory: false, hasRollbackExpandedPrevious: false,
                    hasExpandedDirectory: false, hasManifestFile: false,
                    quarantinedExpandedEntries: quarantineEntries(for: name),
                    legacyInstallManifestData: data
                )
            }
        }
        return result
    }

    /// Quarantined EXPANDED views of one image (an earlier `reconstructExpanded`
    /// moved the previous view aside). Attribution is by the manifest INSIDE
    /// each directory: the `expanded-<id>-<UUID>` name is only an index, never
    /// authority for a deletion.
    private func quarantineEntries(for imageID: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: layout.quarantineDirectory.path)) ?? []
        return names.filter { name in
            guard name.hasPrefix("expanded-") else { return false }
            let directory = layout.quarantineDirectory.appendingPathComponent(name, isDirectory: true)
            guard isRealDirectory(directory),
                  let data = try? readRegularFile(directory.appendingPathComponent("manifest.json")),
                  let image = try? RuntimeV2ImageStore.decoder.decode(LinuxGuestImage.self, from: data) else {
                return false
            }
            return image.id == imageID
        }.sorted()
    }

    private var migrationRoot: URL {
        layout.recoveryMigrationsDirectory
    }

    private func validatedDirectoryIDs(
        _ root: URL, prefix: String = "", suffix: String = ""
    ) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.compactMap { name in
            var value = name
            if !prefix.isEmpty {
                guard value.hasPrefix(prefix) else { return nil }
                value.removeFirst(prefix.count)
            }
            if !suffix.isEmpty {
                guard value.hasSuffix(suffix) else { return nil }
                value.removeLast(suffix.count)
            }
            guard !value.isEmpty, (try? RuntimeV2Identifier.validate(value, kind: .image)) != nil else {
                return nil
            }
            let path = root.appendingPathComponent(name)
            guard isRealDirectory(path) || isRegularFile(path) else { return nil }
            return value
        }
    }

    private func predecessorClosure(
        of imageID: String, candidates: inout [String: ImageRecord]
    ) -> Set<String> {
        var visited: Set<String> = [imageID]
        var frontier = [imageID]
        while let current = frontier.popLast() {
            guard let manifest = candidates[current]?.factoryManifestData,
                  let image = try? RuntimeV2ImageStore.decoder.decode(LinuxGuestImage.self, from: manifest) else {
                continue
            }
            for origin in image.compatibleOrigins ?? [] where !visited.contains(origin.imageID) {
                guard (try? RuntimeV2Identifier.validate(origin.imageID, kind: .image)) != nil else { continue }
                visited.insert(origin.imageID)
                frontier.append(origin.imageID)
                if candidates[origin.imageID] == nil {
                    // The predecessor may not be registered/visible yet; its
                    // bytes are still relevant only if they exist on disk.
                    candidates[origin.imageID] = ImageRecord(
                        id: origin.imageID, v2Manifest: nil, v2ManifestData: nil,
                        registryRow: nil, migrationRow: nil, rollbackLegacyManifestData: nil,
                        hasRollbackLegacyDirectory: false, hasRollbackExpandedPrevious: false,
                        hasExpandedDirectory: false, hasManifestFile: false
                    )
                }
            }
        }
        visited.remove(imageID)
        return visited
    }

    // MARK: reference evidence

    /// Complete live-owner evidence, or nil when any lookup failed. A missing
    /// registry row list, lease list, template list or unreadable owner
    /// directory is NEVER an empty reference set: the pass must defer.
    private func referenceFacts() async -> ReferenceFacts? {
        var facts = ReferenceFacts()
        guard let environments = try? await registry.environments(state: nil) else { return nil }
        var environmentBase: [String: String] = [:]
        for environment in environments where environment.state != "deleting" {
            guard let base = environment.baseImageID else { continue }
            environmentBase[environment.id] = base
            facts.environmentBaseImageIDs[base, default: []].append(environment.id)
        }
        guard let leases = try? await registry.heldLeases() else { return nil }
        let now = Date()
        for row in leases {
            guard let base = environmentBase[row.environmentID] else { continue }
            // Restored rows can outlive a kernel boot, and the PID may have been reused.
            let lease = RuntimeV2LeaseStore.Lease(
                environmentID: row.environmentID, runtimeID: row.runtimeID,
                incarnation: row.incarnation, sessionToken: row.sessionToken,
                pid: row.pid, acquiredAt: row.acquiredAt, renewedAt: row.renewedAt,
                ttlSeconds: row.ttlSeconds
            )
            if RuntimeV2LeaseStore.blocksRetirement(lease, now: now) {
                facts.liveLeaseImageIDs.insert(base)
            }
        }
        for state in [RuntimeV2Registry.TemplateState.verified, .building] {
            guard let templates = try? await registry.templates(state: state) else { return nil }
            for template in templates where template.parentKind == "base-image" {
                facts.templatePinImageIDs.insert(template.parentID)
            }
        }
        // Live and preserved working disks: their runtime record names the
        // exact base (and optional execution component) the disk needs.
        for directory in [layout.runtimeVMDirectory, layout.quarantineDirectory] {
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            } catch {
                // ENOENT is a genuinely empty owner set; anything else means
                // ownership cannot be proven.
                if (error as NSError).code == NSFileReadNoSuchFileError { continue }
                return nil
            }
            for name in names {
                let entry = directory.appendingPathComponent(name, isDirectory: true)
                guard isRealDirectory(entry) else { continue }
                // A factory expanded view quarantined by `reconstructExpanded`
                // is NOT a working root: it carries the authenticated factory
                // manifest (and the verifier snapshot) instead of runtime.json.
                // Its bytes are handled by the retirement plan, so it must not
                // make the whole pass look unattributable.
                if directory == layout.quarantineDirectory,
                   isAuthenticatedFactoryExpandedQuarantine(entry, name: name) {
                    continue
                }
                guard let meta = RuntimeV2WorkingDirectory.readMeta(from: entry) else {
                    // An unreadable/absent working-disk sidecar on any other
                    // quarantine/runtime entry is an unknown working root:
                    // fail closed for the whole pass.
                    facts.isComplete = false
                    continue
                }
                facts.workingDiskImageIDs.insert(meta.baseImageID)
                if let execution = meta.executionImageID {
                    facts.workingDiskImageIDs.insert(execution)
                }
            }
        }
        guard let knownImages = try? await registry.allImageIDs() else { return nil }
        for id in knownImages {
            guard let expanded = try? layout.expandedImageDirectory(imageID: id) else { continue }
            if isRegularFile(expanded.appendingPathComponent("boot-assets.json")) {
                facts.bootSelectedImageIDs.insert(id)
            }
        }
        return facts
    }

    private func retentionReason(
        for imageID: String, reason: Reason, candidate: ImageRecord, references: ReferenceFacts,
        protectedActiveImageID: String? = nil
    ) -> String? {
        // The migration rollback of the image that just proved usable is a
        // duplicate of authenticated blobs. No pin or lease makes a duplicate
        // necessary: the boot path reads the expanded view, and a failed
        // cutover never reaches this trigger. This also covers the same-id
        // backup of the active resident image (identical verified bytes).
        if reason == .verifiedPriorBackup { return nil }
        // The resident ARM64 machine's mutable disk and origin.json sit OUTSIDE
        // this layout. When the App binds its actual active image, that
        // generation is never retired here — even with no environment row.
        if imageID == protectedActiveImageID {
            return "active-resident-image: the native resident machine boots this image"
        }
        if references.liveLeaseImageIDs.contains(imageID) {
            return "live-lease: an environment booting this image still holds a lease"
        }
        if references.workingDiskImageIDs.contains(imageID) {
            return "active-working-disk: a live or preserved working disk was cloned from this base"
        }
        if reason == .retiredArchitecture {
            // A discontinued architecture is never kept for an environment pin
            // or template that can never boot here. Only live bytes above
            // (lease/working disk) and non-factory entries (retained in the
            // plan) delay/limit the teardown.
            return nil
        }
        if let environments = references.environmentBaseImageIDs[imageID], !environments.isEmpty {
            return "environment-base: \(environments.sorted().joined(separator: ",")) boots this image"
        }
        if references.templatePinImageIDs.contains(imageID) {
            return "template-pin: a verified software template was built on this base"
        }
        if references.bootSelectedImageIDs.contains(imageID) {
            return "user-boot-selection: the user selected an explicit boot pair for this image"
        }
        if candidate.migrationRow.map({ $0.phase == .failed || $0.phase == .switched }) == true,
           candidate.v2Manifest == nil {
            return "failed-migration: the only recoverable copy of a failed cutover is retained"
        }
        return nil
    }

    // MARK: planning

    private func buildPlan(
        candidate: ImageRecord, reason: Reason,
        evidence: RuntimeV2FactoryImageArchitectureEvidence?, triggerRootfsDigest: String?,
        legacyImagesRootForPlan: URL?, protectedActiveImageID: String?
    ) async -> Plan {
        var plan = Plan(
            imageID: candidate.id, reason: reason,
            architecture: evidence?.architecture.rawValue ?? RuntimeV2FactoryImageArchitecture.unknown.rawValue,
            evidence: evidence?.detail ?? "no decodable factory manifest",
            items: [], artifactDigests: [], deletesImageIdentity: reason != .verifiedPriorBackup,
            retained: []
        )
        guard let factoryManifest = candidate.factoryManifestData else {
            plan.retained.append("unidentified-factory-bytes: no authenticated manifest identifies this generation")
            return plan
        }
        let legacyImage = try? RuntimeV2ImageStore.decoder.decode(LinuxGuestImage.self, from: factoryManifest)
        // The migration rollback copy is its OWN generation: after a same-id
        // replacement its manifest can differ from the v2 manifest. Its
        // declared files come from the rollback manifest when one exists.
        let rollbackManifestData = candidate.rollbackLegacyManifestData ?? factoryManifest
        let rollbackImage = try? RuntimeV2ImageStore.decoder.decode(
            LinuxGuestImage.self, from: rollbackManifestData
        )
        func digestBytes(_ image: LinuxGuestImage?) -> [String: Int64] {
            var result: [String: Int64] = [:]
            guard let image else { return result }
            for declared in image.declaredArtifacts {
                guard let digest = image.artifactDigest(role: declared.role) else { continue }
                result[declared.path] = digest.bytes
            }
            return result
        }
        let declaredBytes = digestBytes(legacyImage)
        let rollbackDeclaredBytes = digestBytes(rollbackImage)

        func files(
            anchor: URL, declarations: [(path: String, bytes: Int64, sha512: String?)],
            retainedPrefix: String
        ) -> [Plan.File] {
            var result: [Plan.File] = []
            for declaration in declarations {
                guard validRelativeComponents(declaration.path) else {
                    plan.retained.append("\(retainedPrefix):escaping-or-invalid-declared-path")
                    continue
                }
                let url = anchor.appendingPathComponent(declaration.path)
                guard let identity = fileIdentity(url) else {
                    plan.retained.append("\(retainedPrefix):declared-entry-missing-or-not-a-file")
                    continue
                }
                if identity.linkCount != 1 || !identity.isRegular || identity.ownerUID != UInt64(geteuid()) {
                    plan.retained.append("\(retainedPrefix):declared-entry-unknown-owner-or-links")
                    continue
                }
                if identity.size != declaration.bytes {
                    plan.retained.append("\(retainedPrefix):declared-entry-size-changed")
                    continue
                }
                var sha512 = declaration.sha512
                if let expected = sha512 {
                    guard let data = try? readRegularFile(url),
                          FloeDigest.sha512Hex(data) == expected.lowercased() else {
                        plan.retained.append("\(retainedPrefix):factory-record-bytes-changed")
                        continue
                    }
                    sha512 = expected.lowercased()
                }
                result.append(identity.planFile(relativePath: declaration.path, sha512: sha512))
            }
            return result
        }

        func removableDirectories(anchor: String, paths: [String], extra: [String] = []) -> [String] {
            var directories = Set<String>()
            for path in paths {
                var components = path.split(separator: "/").map(String.init)
                guard components.count > 1 else { continue }
                components.removeLast()
                var current = anchor
                for component in components {
                    current += "/" + component
                    directories.insert(current)
                }
            }
            // Deepest first; the anchor and any explicitly named ancestors are
            // removed only when the listed files were the last entries.
            return directories.sorted { $0.split(separator: "/").count > $1.split(separator: "/").count }
                + [anchor] + extra
        }

        // 1. Migration rollback: the copied legacy generation and the replaced
        // expanded view. Always first: they are the duplicates of the verified
        // bytes, so an interrupted pass still leaves the v2 identity resolvable.
        if candidate.hasRollbackLegacyDirectory {
            let anchor = "recovery/migrations/legacy-image-\(candidate.id)/legacy-images/\(candidate.id)"
            let declarations = (rollbackImage?.declaredArtifacts ?? []).compactMap { declared -> (String, Int64, String?)? in
                guard let bytes = rollbackDeclaredBytes[declared.path] else { return nil }
                return (declared.path, bytes, nil)
            }
            var planned = files(
                anchor: layout.root.appendingPathComponent(anchor),
                declarations: declarations, retainedPrefix: "migration-legacy-images"
            )
            if let manifestData = candidate.rollbackLegacyManifestData,
               let identity = fileIdentity(layout.root.appendingPathComponent(anchor).appendingPathComponent("manifest.json")),
               identity.isRegular, identity.linkCount == 1, identity.ownerUID == UInt64(geteuid()) {
                planned.append(identity.planFile(
                    relativePath: "manifest.json", sha512: FloeDigest.sha512Hex(manifestData)
                ))
            }
            plan.items.append(.init(
                kind: .migrationLegacyImages, anchorRelativePath: anchor, files: planned,
                removableDirectories: removableDirectories(
                    anchor: anchor, paths: planned.map(\.relativePath),
                    extra: [
                        "recovery/migrations/legacy-image-\(candidate.id)/legacy-images",
                        "recovery/migrations/legacy-image-\(candidate.id)"
                    ]
                )
            ))
        }
        if candidate.hasRollbackExpandedPrevious {
            let anchor = "recovery/migrations/legacy-image-\(candidate.id)/expanded-previous"
            let declarations: [(path: String, bytes: Int64, sha512: String?)] = {
                if let manifest = candidate.v2Manifest {
                    return manifest.artifacts.values.map { ($0.expandedPath, $0.bytes, nil) }
                }
                return (legacyImage?.declaredArtifacts ?? []).compactMap { declared in
                    guard let bytes = declaredBytes[declared.path] else { return nil }
                    return (declared.path, bytes, nil)
                }
            }()
            var planned = files(
                anchor: layout.root.appendingPathComponent(anchor),
                declarations: declarations, retainedPrefix: "expanded-previous"
            )
            if let identity = fileIdentity(
                layout.root.appendingPathComponent(anchor).appendingPathComponent("manifest.json")
            ), identity.isRegular, identity.linkCount == 1, identity.ownerUID == UInt64(geteuid()) {
                planned.append(identity.planFile(relativePath: "manifest.json", sha512: nil))
            }
            plan.items.append(.init(
                kind: .migrationExpandedPrevious, anchorRelativePath: anchor, files: planned,
                removableDirectories: removableDirectories(
                    anchor: anchor, paths: planned.map(\.relativePath),
                    extra: [
                        "recovery/migrations/legacy-image-\(candidate.id)/legacy-images",
                        "recovery/migrations/legacy-image-\(candidate.id)"
                    ]
                )
            ))
        }

        // 2b. Earlier expanded views moved into recovery/quarantine by a
        // rebuild. They are the ImageStore's own factory rollbacks: the
        // manifest inside names every declared file, and the verifier sidecar
        // plus the manifest are the small factory records. Undeclared entries
        // (a user file that happened to land there) are retained.
        for entry in candidate.quarantinedExpandedEntries {
            let anchor = "recovery/quarantine/\(entry)"
            let directory = layout.quarantineDirectory.appendingPathComponent(entry, isDirectory: true)
            guard let data = try? readRegularFile(directory.appendingPathComponent("manifest.json")),
                  let image = try? RuntimeV2ImageStore.decoder.decode(LinuxGuestImage.self, from: data),
                  image.id == candidate.id else { continue }
            let declarations: [(path: String, bytes: Int64, sha512: String?)] =
                image.declaredArtifacts.compactMap { declared in
                    guard let digest = image.artifactDigest(role: declared.role) else { return nil }
                    return (declared.path, digest.bytes, nil)
                }
            var planned = files(
                anchor: directory, declarations: declarations,
                retainedPrefix: "quarantined-expanded-view"
            )
            if let identity = fileIdentity(directory.appendingPathComponent("manifest.json")),
               identity.isRegular, identity.linkCount == 1, identity.ownerUID == UInt64(geteuid()) {
                planned.append(identity.planFile(
                    relativePath: "manifest.json", sha512: FloeDigest.sha512Hex(data)
                ))
            }
            // The verifier's success snapshot(s) are factory records written by
            // this substrate next to the view. Names are matched narrowly and
            // each instance is still identity-checked at deletion.
            if let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
                for name in names where name.hasPrefix(".floe-verified-") && name.hasSuffix(".json") {
                    guard let identity = fileIdentity(directory.appendingPathComponent(name)),
                          identity.isRegular, identity.linkCount == 1,
                          identity.ownerUID == UInt64(geteuid()) else { continue }
                    planned.append(identity.planFile(relativePath: name, sha512: nil))
                }
            }
            plan.items.append(.init(
                kind: .quarantinedExpandedView, anchorRelativePath: anchor, anchorRoot: nil,
                files: planned,
                removableDirectories: removableDirectories(anchor: anchor, paths: planned.map(\.relativePath))
            ))
        }

        // 2c. The legacy install copy of this exact generation when the caller
        // supplied the legacy image root. Used both for the retired-architecture
        // backlog (a legacy-only RISC-V generation) and for a verified same-id
        // image whose old install copy is still on disk.
        if candidate.id != protectedActiveImageID,
           let legacyManifestData = candidate.legacyInstallManifestData,
           let legacyImage = try? RuntimeV2ImageStore.decoder.decode(
               LinuxGuestImage.self, from: legacyManifestData
           ), legacyImage.id == candidate.id {
            var legacyDeclared: [String: Int64] = [:]
            for declared in legacyImage.declaredArtifacts {
                guard let digest = legacyImage.artifactDigest(role: declared.role) else { continue }
                legacyDeclared[declared.path] = digest.bytes
            }
            let anchor = candidate.id
            let directory = legacyImagesRootForPlan?.appendingPathComponent(anchor, isDirectory: true)
            if let directory {
                let declarations = legacyImage.declaredArtifacts.compactMap {
                    declared -> (String, Int64, String?)? in
                    guard let bytes = legacyDeclared[declared.path] else { return nil }
                    return (declared.path, bytes, nil)
                }
                var planned = files(
                    anchor: directory, declarations: declarations,
                    retainedPrefix: "legacy-install-copy"
                )
                if let identity = fileIdentity(directory.appendingPathComponent("manifest.json")),
                   identity.isRegular, identity.linkCount == 1,
                   identity.ownerUID == UInt64(geteuid()) {
                    planned.append(identity.planFile(
                        relativePath: "manifest.json", sha512: FloeDigest.sha512Hex(legacyManifestData)
                    ))
                }
                plan.items.append(.init(
                    kind: .legacyInstallCopy, anchorRelativePath: anchor, anchorRoot: "legacy-images",
                    files: planned,
                    removableDirectories: removableDirectories(anchor: anchor, paths: planned.map(\.relativePath))
                ))
            }
        }

        guard plan.deletesImageIdentity else { return plan }
        // An unreadable/foreign v2 manifest that we cannot name file-by-file
        // must never turn into an identity-only retirement: the rollback copies
        // are still retired (the plan items above), but the generation keeps its
        // v2 manifest, its expanded view and its registry row.
        guard candidate.v2ManifestData != nil || !candidate.hasManifestFile else {
            plan.retained.append("v2-manifest:unreadable-or-foreign; the generation identity is kept")
            plan.deletesImageIdentity = false
            return plan
        }

        // 2. The rebuildable expanded view of the retired generation.
        if let manifest = candidate.v2Manifest, candidate.hasExpandedDirectory {
            let anchor = "images/expanded/\(candidate.id)"
            let declarations = manifest.artifacts.values.map { ($0.expandedPath, $0.bytes, String?.none) }
            var planned = files(
                anchor: layout.root.appendingPathComponent(anchor),
                declarations: declarations, retainedPrefix: "expanded-view"
            )
            if let identity = fileIdentity(
                layout.root.appendingPathComponent(anchor).appendingPathComponent("manifest.json")
            ), identity.isRegular, identity.linkCount == 1, identity.ownerUID == UInt64(geteuid()) {
                planned.append(identity.planFile(relativePath: "manifest.json", sha512: nil))
            }
            plan.items.append(.init(
                kind: .expandedView, anchorRelativePath: anchor, files: planned,
                removableDirectories: removableDirectories(anchor: anchor, paths: planned.map(\.relativePath))
            ))
            plan.artifactDigests = Array(Set(manifest.artifacts.values.map { $0.sha512.lowercased() })).sorted()
        } else if candidate.hasExpandedDirectory {
            plan.retained.append("expanded-view:no-v2-manifest-to-name-its-files")
        }

        // 3. The v2 manifest LAST: while it exists the generation is still
        // identified, so any interruption leaves the plan re-derivable.
        if let manifestData = candidate.v2ManifestData, candidate.hasManifestFile {
            let anchor = "images/manifests"
            let identity = fileIdentity(layout.root.appendingPathComponent("images/manifests/\(candidate.id).json"))
            if let identity, identity.isRegular, identity.linkCount == 1,
               identity.ownerUID == UInt64(geteuid()) {
                plan.items.append(.init(
                    kind: .manifest, anchorRelativePath: anchor,
                    files: [identity.planFile(
                        relativePath: "\(candidate.id).json",
                        sha512: FloeDigest.sha512Hex(manifestData)
                    )],
                    removableDirectories: []
                ))
            } else {
                plan.retained.append("v2-manifest:changed-or-not-owned")
            }
        }
        return plan
    }

    // MARK: execution

    private struct ExecutionOutcome {
        var deletedFiles = 0
        var deletedBytes: Int64 = 0
        var releasedBlobs = 0
        var releasedBlobBytes: Int64 = 0
        var failed = false
        var cancelled = false
        var failure: String?
    }

    private func execute(
        plan: Plan, record: RuntimeV2Registry.ImageRetirementRow,
        legacyImagesRoot: URL?, isCancelled: () -> Bool
    ) async -> ExecutionOutcome {
        var outcome = ExecutionOutcome()
        guard (try? await registry.beginImageRetirementAttempt(imageID: plan.imageID)) == true else {
            return outcome
        }
        var notes: [String] = []
        var concurrentConflict = false
        do {
            // Files first, in plan order (rollback copies → expanded → manifest).
            for item in plan.items {
                if isCancelled() { outcome.cancelled = true; break }
                let anchor = try resolvedAnchor(
                    item.anchorRelativePath, root: item.anchorRoot,
                    legacyImagesRoot: legacyImagesRoot
                )
                guard let anchorFD = openDirectoryNoFollow(anchor) else {
                    // Already gone (a previous interrupted pass finished this
                    // item); that is completion, not failure.
                    continue
                }
                for file in item.files {
                    if isCancelled() { outcome.cancelled = true; break }
                    let result = removePlannedFile(file, anchorFD: anchorFD)
                    switch result {
                    case .removed(let bytes):
                        outcome.deletedFiles += 1
                        outcome.deletedBytes += bytes
                        try? await registry.addImageRetirementBytes(
                            imageID: plan.imageID, delta: bytes
                        )
                    case .absent:
                        continue
                    case .retained(let note):
                        notes.append("\(item.kind.rawValue):\(file.relativePath):\(note)")
                        // A planned entry whose live instance no longer
                        // matches means a concurrent writer replaced it
                        // (import, repair, boot materialization). Never
                        // delete the generation's identity underneath that
                        // writer: keep the manifest/row and retry later.
                        if note == "file-instance-changed" || note == "factory-record-bytes-changed"
                            || note == "factory-record-unreadable" {
                            concurrentConflict = true
                        }
                    case .failed(let note):
                        throw RuntimeV2Error.migrationFailed(
                            id: "image-retirement-\(plan.imageID)", phase: "retiring",
                            reason: "\(item.kind.rawValue)/\(file.relativePath): \(note)"
                        )
                    }
                }
                close(anchorFD)
                for directory in item.removableDirectories {
                    if isCancelled() { outcome.cancelled = true; break }
                    let url = try resolvedAnchor(
                        directory, root: item.anchorRoot, legacyImagesRoot: legacyImagesRoot
                    )
                    if removeDirectoryIfEmpty(url) == .notEmpty {
                        notes.append("\(item.kind.rawValue):directory-not-empty")
                    }
                }
                if outcome.cancelled { break }
            }

            if !notes.isEmpty {
                try? await registry.recordImageRetirementRetained(imageID: plan.imageID, notes: notes)
            }
            if outcome.cancelled {
                try? await registry.releaseImageRetirementForResume(imageID: plan.imageID)
                return outcome
            }

            if concurrentConflict, plan.deletesImageIdentity {
                // The durable plan's file instances changed under us. Keep the
                // image identity (manifest, row, expanded view) so the
                // concurrent writer's result stays resolvable; a later pass
                // re-plans from the new live identities.
                try await registry.failImageRetirement(
                    imageID: plan.imageID,
                    error: "concurrent image writer changed the planned bytes; the identity was retained for a re-planned retry"
                )
                outcome.failed = true
                outcome.failure = "\(plan.imageID): concurrent-writer-detected; retained for retry"
                return outcome
            }
            // Blob references are released by live reference count only:
            // content shared with a still-verified generation, a template disk
            // or an in-flight staging claim keeps its bytes.
            if plan.deletesImageIdentity {
                let already = record.releasedDigests
                if !already.isEmpty {
                    let (files, bytes) = removeReleasedBlobBytes(digests: already)
                    outcome.releasedBlobs += files
                    outcome.releasedBlobBytes += bytes
                }
                if !plan.artifactDigests.isEmpty {
                    let collected = try await registry.retireImageArtifacts(
                        imageID: plan.imageID, digests: plan.artifactDigests
                    )
                    let (files, bytes) = removeReleasedBlobBytes(digests: collected)
                    outcome.releasedBlobs += files
                    outcome.releasedBlobBytes += bytes
                }
                try await registry.finishImageRetirement(
                    imageID: plan.imageID, releasedDigests: plan.artifactDigests
                )
            } else {
                // A prior-backup-only retirement leaves the image identity in
                // place; there is nothing to release.
                try await registry.finishImageRetirement(imageID: plan.imageID, releasedDigests: [])
            }
        } catch {
            outcome.failed = true
            outcome.failure = "\(plan.imageID): \(error.localizedDescription)"
            try? await registry.failImageRetirement(
                imageID: plan.imageID, error: error.localizedDescription
            )
        }
        return outcome
    }

    private enum FileRemoval {
        case removed(Int64)
        case absent
        case retained(String)
        case failed(String)
    }

    private func removePlannedFile(_ file: Plan.File, anchorFD: Int32) -> FileRemoval {
        var components = file.relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty, validRelativeComponents(file.relativePath) else {
            return .retained("invalid-relative-path")
        }
        let leaf = components.removeLast()
        var parent = dup(anchorFD)
        guard parent >= 0 else { return .failed("anchor-unavailable") }
        defer { close(parent) }
        for component in components {
            let next = component.withCString {
                openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else { return .absent }
            close(parent)
            parent = next
        }
        var info = stat()
        let status = leaf.withCString { fstatat(parent, $0, &info, AT_SYMLINK_NOFOLLOW) }
        guard status == 0 else {
            return errno == ENOENT ? .absent : .failed("lstat-errno-\(errno)")
        }
        let observed = FileIdentity(info: info)
        guard observed.isRegular else { return .retained("not-a-regular-file") }
        guard observed.linkCount == 1, observed.ownerUID == UInt64(geteuid()) else {
            return .retained("unknown-owner-or-multiple-links")
        }
        guard observed.matches(file) else { return .retained("file-instance-changed") }
        if let expected = file.sha512 {
            // Only factory RECORDS (the manifests) carry a digest here; they
            // are small and the exact bytes parsed at plan time must be the
            // bytes that are deleted. Large artifacts are protected by the
            // recorded file instance above, never by re-hashing gigabytes.
            guard observed.size >= 0, observed.size <= 4 << 20 else {
                return .retained("factory-record-size-out-of-range")
            }
            let fd = leaf.withCString { openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
            guard fd >= 0 else { return .retained("factory-record-unreadable") }
            defer { close(fd) }
            var buffer = [UInt8](repeating: 0, count: Int(observed.size))
            var offset = 0
            while offset < buffer.count {
                let count = buffer.withUnsafeMutableBytes {
                    read(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset)
                }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return .retained("factory-record-unreadable") }
                offset += count
            }
            guard FloeDigest.sha512Hex(Data(buffer)) == expected.lowercased() else {
                return .retained("factory-record-bytes-changed")
            }
        }
        guard leaf.withCString({ unlinkat(parent, $0, 0) }) == 0 else {
            return errno == ENOENT ? .absent : .failed("unlink-errno-\(errno)")
        }
        _ = fsync(parent)
        return .removed(observed.size)
    }

    private enum DirectoryRemoval { case removed, absent, notEmpty, failed }

    private func removeDirectoryIfEmpty(_ url: URL) -> DirectoryRemoval {
        let parent = url.deletingLastPathComponent().path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard parent >= 0 else { return .absent }
        defer { close(parent) }
        let name = url.lastPathComponent
        guard name.withCString({ unlinkat(parent, $0, AT_REMOVEDIR) }) == 0 else {
            switch errno {
            case ENOENT: return .absent
            case ENOTEMPTY, EEXIST: return .notEmpty
            default: return .failed
            }
        }
        _ = fsync(parent)
        return .removed
    }

    private func removeReleasedBlobBytes(digests: [String]) -> (files: Int, bytes: Int64) {
        var files = 0
        var bytes: Int64 = 0
        for digest in Set(digests.map { $0.lowercased() }) {
            for url in [
                try? layout.blobURL(digest: digest),
                try? layout.blobQuarantineURL(digest: digest)
            ].compactMap({ $0 }) {
                guard let identity = fileIdentity(url), identity.isRegular,
                      identity.linkCount == 1, identity.ownerUID == UInt64(geteuid()) else {
                    continue
                }
                guard (try? layout.contain(url)) != nil else { continue }
                guard url.path.withCString({ unlink($0) }) == 0 else { continue }
                files += 1
                bytes += identity.size
            }
        }
        return (files, bytes)
    }

    // MARK: path + identity helpers

    private func readV2ManifestData(imageID: String) throws -> Data? {
        guard let url = try? layout.imageManifestURL(imageID: imageID) else { return nil }
        return try readRegularFile(url)
    }

    private func readV2Manifest(imageID: String) throws -> RuntimeV2ImageStore.Manifest? {
        guard let data = try readV2ManifestData(imageID: imageID) else { return nil }
        guard let manifest = try? RuntimeV2ImageStore.decoder.decode(
            RuntimeV2ImageStore.Manifest.self, from: data
        ), manifest.imageID == imageID else {
            return nil
        }
        return manifest
    }

    /// The only tree this pass may ever write. Working disks, environments,
    /// workspaces and the quarantine evidence area are structurally excluded:
    /// no plan anchor can name them, whatever a manifest or a row says.
    private static let allowedAnchorPrefixes = [
        "recovery/migrations/", "images/expanded/", "images/manifests",
        "recovery/quarantine/expanded-"
    ]

    private func resolvedAnchor(
        _ relative: String, root: String? = nil, legacyImagesRoot: URL?
    ) throws -> URL {
        guard validRelativeComponents(relative) else {
            throw RuntimeV2Error.pathEscapesRoot(relative)
        }
        if root == "legacy-images" {
            guard let legacyImagesRoot, !relative.contains("/") else {
                throw RuntimeV2Error.pathEscapesRoot(relative)
            }
            let base = legacyImagesRoot.resolvingSymlinksInPath().standardizedFileURL
            let url = legacyImagesRoot.appendingPathComponent(relative, isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL
            guard url.path == base.appendingPathComponent(relative).standardizedFileURL.path,
                  url.path.hasPrefix(base.path + "/") else {
                throw RuntimeV2Error.pathEscapesRoot(relative)
            }
            return url
        }
        guard Self.allowedAnchorPrefixes.contains(where: { relative.hasPrefix($0) }) else {
            throw RuntimeV2Error.pathEscapesRoot(relative)
        }
        let url = layout.root.appendingPathComponent(relative)
        return try layout.contain(url)
    }

    /// Retirement-only cross-instance lock. It never replaces the store's own
    /// exclusion; it only makes two retirement passes on the same root
    /// converge through the durable rows instead of co-running.
    private struct RetirementLock { let fd: Int32 }

    private func acquireRetirementLock() -> RetirementLock? {
        #if canImport(Darwin)
        let directory = layout.runtimeDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("factory-retirement.lock").path
        let fd = path.withCString {
            open($0, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return RetirementLock(fd: fd)
        #else
        // Non-Darwin builds have no cross-process image store; the actor's
        // single flight is the only concurrency source.
        return RetirementLock(fd: -1)
        #endif
    }

    private func releaseRetirementLock(_ lock: RetirementLock?) {
        guard let lock else { return }
        #if canImport(Darwin)
        if lock.fd >= 0 {
            _ = flock(lock.fd, LOCK_UN)
            close(lock.fd)
        }
        #endif
    }

    /// Independent factory authentication for `recovery/quarantine/expanded-`:
    /// the directory name binds to the image id AND its own manifest decodes to
    /// exactly that id. A directory of that shape was written by this
    /// substrate's expanded-view rollback; it never contains a live VM disk.
    private func isAuthenticatedFactoryExpandedQuarantine(_ directory: URL, name: String) -> Bool {
        guard name.hasPrefix("expanded-"),
              let data = try? readRegularFile(directory.appendingPathComponent("manifest.json")),
              let image = try? RuntimeV2ImageStore.decoder.decode(LinuxGuestImage.self, from: data),
              (try? RuntimeV2Identifier.validate(image.id, kind: .image)) != nil,
              name.hasPrefix("expanded-\(image.id)-") else {
            return false
        }
        return true
    }

    private func manifestFileExists(imageID: String) -> Bool {
        guard let url = try? layout.imageManifestURL(imageID: imageID) else { return false }
        return FileManager.default.fileExists(atPath: url.path) && !isSymbolicLink(url)
    }

    private func isRealDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue && !isSymbolicLink(url)
    }

    private func isRegularFile(_ url: URL) -> Bool {
        guard let identity = fileIdentity(url) else { return false }
        return identity.isRegular && !isSymbolicLink(url)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType)
            == .typeSymbolicLink
    }

    private func readRegularFile(_ url: URL) throws -> Data? {
        guard let identity = fileIdentity(url), identity.isRegular, !isSymbolicLink(url) else {
            return nil
        }
        return try Data(contentsOf: url)
    }

    private func fileIdentity(_ url: URL) -> FileIdentity? {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else { return nil }
        return FileIdentity(info: info)
    }

    private func validRelativeComponents(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), path.utf8.count <= 4_096,
              !path.utf8.contains(0) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.count <= 16 else { return false }
        return components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255
        }
    }

    private func openDirectoryNoFollow(_ url: URL) -> Int32? {
        let fd = url.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        return fd >= 0 ? fd : nil
    }

    // MARK: plan coding

    static func encodePlan(_ plan: Plan) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(plan) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func decodePlan(_ text: String) -> Plan? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Plan.self, from: data)
    }

    static func imageID(fromMigrationID id: String) -> String? {
        let prefix = "legacy-image-"
        guard id.hasPrefix(prefix), id.count > prefix.count else { return nil }
        return String(id.dropFirst(prefix.count))
    }
}

// MARK: - File identity

/// A directory entry's identity at plan/execution time. Deleting a file whose
/// instance changed since the plan would be deleting bytes the plan never
/// described, so every field participates in the match.
private struct FileIdentity {
    var device: UInt64
    var inode: UInt64
    var size: Int64
    var mode: UInt32
    var ownerUID: UInt64
    var linkCount: UInt64
    var modificationSeconds: Int64
    var modificationNanoseconds: Int64
    var changeSeconds: Int64
    var changeNanoseconds: Int64

    var isRegular: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFREG) }

    init(info: stat) {
        device = UInt64(bitPattern: Int64(info.st_dev))
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        mode = UInt32(info.st_mode)
        ownerUID = UInt64(info.st_uid)
        linkCount = UInt64(info.st_nlink)
        #if canImport(Darwin)
        modificationSeconds = Int64(info.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        changeSeconds = Int64(info.st_ctimespec.tv_sec)
        changeNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        #else
        modificationSeconds = Int64(info.st_mtim.tv_sec)
        modificationNanoseconds = Int64(info.st_mtim.tv_nsec)
        changeSeconds = Int64(info.st_ctim.tv_sec)
        changeNanoseconds = Int64(info.st_ctim.tv_nsec)
        #endif
    }

    func planFile(relativePath: String, sha512: String?) -> RuntimeV2FactoryImageRetirement.Plan.File {
        .init(
            relativePath: relativePath, bytes: size, device: device, inode: inode,
            size: size, modificationSeconds: modificationSeconds,
            modificationNanoseconds: modificationNanoseconds,
            changeSeconds: changeSeconds, changeNanoseconds: changeNanoseconds,
            linkCount: linkCount, sha512: sha512
        )
    }

    func matches(_ file: RuntimeV2FactoryImageRetirement.Plan.File) -> Bool {
        device == file.device && inode == file.inode && size == file.size
            && modificationSeconds == file.modificationSeconds
            && modificationNanoseconds == file.modificationNanoseconds
            && changeSeconds == file.changeSeconds
            && changeNanoseconds == file.changeNanoseconds
            && linkCount == file.linkCount
    }
}
