// FloeExecution — Runtime v2 image store: manifests, expanded views, migration.
//
// An image is three views of the same verified bytes:
//
//   images/manifests/<imageID>.json  — the v2 manifest: content-addressed
//     digest references for BIOS/kernel/initrd/rootfs/runner plus the verbatim
//     legacy manifest for full provenance/qualification fidelity.
//   images/blobs/sha512/…            — the single, read-only copy of each
//     artifact's bytes (see RuntimeV2BlobStore).
//   images/expanded/<imageID>/       — a rebuildable bootable view: the legacy
//     manifest plus clonefile materializations of every blob, in the exact
//     layout the existing resolver/verifier/preparer contract understands.
//     Expanded views are excluded from backup and re-materialized from blobs
//     on demand; they are never a second source of truth.
//
// Migration from the legacy <artifactRoot>/LinuxGuest/images/<id>/ layout runs
// the discovered → copied → verified → switched → cleanupPending phase machine
// recorded in the registry's migrations table. Legacy content is never
// destroyed in place: it is moved aside into recovery/migrations/<id>/ only
// after the replacement is fully verified, which keeps a working rollback
// point until finalization. Same-id content whose digests mismatch the
// installed v2 image is staged and verified before the atomic switch.

import Foundation
import FloeCore

/// Outcome of a cancellation-aware image-health check. `.cancelled` is a
/// cooperative stop, never a verdict: nothing is cached and the caller must
/// not treat it as verified or damaged.
public enum LinuxImageHealthCheck: Sendable {
    case health(RuntimeV2ImageStore.ImageHealth)
    case cancelled
}

public actor RuntimeV2ImageStore {
    /// images/manifests/<imageID>.json payload (schema version 2).
    public struct Manifest: Codable, Sendable, Equatable {
        public struct ArtifactRef: Codable, Sendable, Equatable {
            public var sha512: String
            public var bytes: Int64
            /// Path the artifact occupies inside the expanded view, relative
            /// to the expanded image directory (never absolute, never `..`).
            public var expandedPath: String

            public init(sha512: String, bytes: Int64, expandedPath: String) {
                self.sha512 = sha512
                self.bytes = bytes
                self.expandedPath = expandedPath
            }
        }

        /// Capabilities the image itself proves. Capability claims are NEVER
        /// inferred from the engine (`floe_vm_smp_capable()` is the engine
        /// gate, not guest compatibility) and NEVER default to true: an image
        /// that does not declare a capability does not have it.
        public struct Capabilities: Codable, Sendable, Equatable {
            /// True only when the image's own kernel/firmware were qualified
            /// for SMP (declared by the image build/qualification run).
            public var smp: Bool?
            /// Where the claim came from (legacy manifest key, qualification
            /// run id). Recorded so an ungrounded claim is visible.
            public var declaredBy: String?

            public init(smp: Bool? = nil, declaredBy: String? = nil) {
                self.smp = smp
                self.declaredBy = declaredBy
            }
        }

        public var version: Int
        public var imageID: String
        public var createdAt: Date
        public var artifacts: [String: ArtifactRef] // role → ref (bios/kernel/initrd/rootfs/runner)
        /// The verbatim legacy manifest (LinuxGuestImage JSON) the digests
        /// were taken from: provenance, qualification record, runner contract
        /// and compatible origins stay byte-identical.
        public var legacyManifestData: Data
        /// Declared image capabilities (schema-additive; absent on older
        /// manifests and then treated as "not declared" = false).
        public var capabilities: Capabilities?

        public static let currentVersion = 2

        public init(
            imageID: String, createdAt: Date, artifacts: [String: ArtifactRef],
            legacyManifestData: Data, capabilities: Capabilities? = nil
        ) {
            self.version = Manifest.currentVersion
            self.imageID = imageID
            self.createdAt = createdAt
            self.artifacts = artifacts
            self.legacyManifestData = legacyManifestData
            self.capabilities = capabilities
        }

        public var rootfsDigest: String? { artifacts["rootfs"]?.sha512 ?? artifacts["disk"]?.sha512 }

        /// SMP is granted only on an explicit true declaration.
        public var smpCapable: Bool { capabilities?.smp == true }
    }

    public struct MigrationReport: Sendable, Equatable {
        public var imageID: String
        public var migrationID: String
        public var phase: RuntimeV2Registry.MigrationPhase
        public var reusedExisting: Bool
        public var blobDigests: [String]
        public var detail: String?

        public init(imageID: String, migrationID: String, phase: RuntimeV2Registry.MigrationPhase, reusedExisting: Bool, blobDigests: [String], detail: String? = nil) {
            self.imageID = imageID
            self.migrationID = migrationID
            self.phase = phase
            self.reusedExisting = reusedExisting
            self.blobDigests = blobDigests
            self.detail = detail
        }
    }

    private let layout: RuntimeV2Layout
    private let registry: RuntimeV2Registry
    private let blobs: RuntimeV2BlobStore
    private let verifier: LinuxGuestImageVerifier
    private var fileManager: FileManager { .default }

    public init(
        layout: RuntimeV2Layout,
        registry: RuntimeV2Registry,
        blobs: RuntimeV2BlobStore,
        verifier: LinuxGuestImageVerifier = LinuxGuestImageVerifier(),
    ) {
        self.layout = layout
        self.registry = registry
        self.blobs = blobs
        self.verifier = verifier
    }

    // MARK: manifest access

    public func manifest(imageID: String) throws -> Manifest? {
        let url = try layout.imageManifestURL(imageID: imageID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try Self.decoder.decode(Manifest.self, from: data)
    }

    /// True only when the registry row is verified AND the v2 manifest file
    /// exists — the pair the boot path may rely on.
    public func isImageVerified(imageID: String) async throws -> Bool {
        guard try await registry.bootableImage(id: imageID, root: layout.root) != nil else { return false }
        return try manifest(imageID: imageID) != nil
    }

    /// The image's declared capabilities, or nil when there is no manifest.
    public func capabilities(imageID: String) throws -> Manifest.Capabilities? {
        try manifest(imageID: imageID)?.capabilities
    }

    /// SMP capability proven by the canonical image manifest. An absent
    /// declaration, a false declaration or an unverified image all answer
    /// false with an honest reason. The engine's `floe_vm_smp_capable()` is
    /// deliberately never consulted: engine capability is not evidence that
    /// THIS image's kernel/firmware can use a second hart.
    ///
    /// When the stored manifest has no lifted `capabilities` block, the
    /// declaration is re-derived from the manifest's own verbatim
    /// `legacyManifestData` (the authenticated installed-manifest bytes the
    /// verified digests were taken from), so a v2 manifest written before the
    /// capabilities block existed still answers truthfully about the installed
    /// image instead of defaulting to false. The embedded bytes are trusted
    /// only after the coherence check (`manifestDigestsMatch`): they must
    /// describe exactly the verified artifact digests and the same image id.
    /// An explicit `smp=false` or a withdrawn declaration in the stored block
    /// is authoritative and is never overridden by this fallback.
    public func smpCapability(imageID: String) async throws -> (capable: Bool, reason: String) {
        guard try await registry.bootableImage(id: imageID, root: layout.root) != nil else {
            return (false, "image '\(imageID)' is not verified; no capability can be assumed")
        }
        guard let manifest = try manifest(imageID: imageID) else {
            return (false, "no v2 manifest for '\(imageID)'; SMP capability defaults to false")
        }
        let lifted: Manifest.Capabilities?
        if let stored = manifest.capabilities {
            lifted = stored
        } else if let embedded = try? Self.decoder.decode(
            LinuxGuestImage.self, from: manifest.legacyManifestData
        ), Self.manifestDigestsMatch(manifest: manifest, image: embedded) {
            // Coherence rule: the embedded bytes are trusted only when they
            // describe exactly the verified artifact digests (and the same
            // image id); a corrupt or foreign manifest never influences the
            // verdict.
            lifted = Self.declaredCapabilities(legacyManifestData: manifest.legacyManifestData)
        } else {
            lifted = nil
        }
        guard let capabilities = lifted else {
            return (
                false,
                "image '\(imageID)' does not declare SMP in its manifest; capability defaults to false "
                    + "(the engine gate is not image evidence)"
            )
        }
        guard capabilities.smp == true else {
            return (
                false,
                "image '\(imageID)' declares smp=\(capabilities.smp.map(String.init) ?? "absent")"
                    + (capabilities.declaredBy.map { " (\($0))" } ?? "")
            )
        }
        return (true, "declared by \(capabilities.declaredBy ?? "the image manifest")")
    }

    // MARK: expansion (rebuildable view)

    /// Success-cache namespace for the expanded view of an image. The legacy
    /// directory of the same id lives in a different directory with different
    /// file identities; a shared key would evict and re-hash on every check.
    static let expandedVerificationNamespace = "v2-expanded"

    /// Real, path-level health of one image WITHOUT triggering a migration,
    /// a download or any rebuild. `nil` means the verified Runtime v2 store
    /// does not hold this image at all.
    ///
    /// Registry row + v2 manifest are registration evidence, never proof the
    /// bootable bytes exist: readiness is derived from the actual expanded
    /// view (hash-verified, with the success fingerprint cache) and from the
    /// availability of every referenced blob when the view needs rebuilding.
    public struct ImageHealth: Sendable, Equatable {
        public enum Readiness: String, Sendable, Equatable {
            /// Expanded view present and its artifact bytes match the manifest.
            case verified
            /// Blobs for every artifact are present; the expanded view is
            /// missing/incomplete/damaged and can be rebuilt locally with no
            /// download.
            case rebuildableFromBlobs
            /// At least one referenced blob is absent: only a verified
            /// replacement install can restore this image.
            case replacementRequired
        }

        public var readiness: Readiness
        public var issue: LinuxImageVerificationIssue?
        public var image: LinuxGuestImage?

        public init(readiness: Readiness, issue: LinuxImageVerificationIssue?, image: LinuxGuestImage?) {
            self.readiness = readiness
            self.issue = issue
            self.image = image
        }
    }

    /// Inspection-only real health (see `ImageHealth`). Cheap when healthy:
    /// expanded bytes are hash-verified only when the success fingerprint
    /// changed. When unhealthy it costs no hashing at all unless the view is
    /// complete-but-wrong, and it never reads a blob.
    ///
    /// No cancellation check is supplied here, so the throwing variant cannot
    /// cancel; nil keeps the previous "store does not hold this image"
    /// contract.
    public func imageHealth(imageID: String) async -> ImageHealth? {
        (try? await imageHealthOrCancelled(imageID: imageID, isCancelled: nil)) ?? nil
    }

    /// Cancellation-aware health check. `.cancelled` is returned when the
    /// caller's signal fires during the expanded-view hash; no verdict is
    /// cached, so a later check reads the real bytes again.
    public func imageHealth(
        imageID: String,
        isCancelled: (@Sendable () -> Bool)?
    ) async -> LinuxImageHealthCheck? {
        do {
            guard let health = try await imageHealthOrCancelled(imageID: imageID, isCancelled: isCancelled) else {
                return nil
            }
            return .health(health)
        } catch is CancellationError {
            return .cancelled
        } catch {
            // Unreachable: the implementation maps every non-cancellation
            // failure to a typed issue instead of throwing.
            return nil
        }
    }

    /// Explicit re-verification: drops the cached success fingerprint first,
    /// so expanded bytes that changed and changed back, or that share a
    /// stale fingerprint, are actually re-read.
    public func reverifyImageHealth(imageID: String) async -> ImageHealth? {
        await verifier.invalidate(id: imageID)
        return await imageHealth(imageID: imageID)
    }

    /// Cancellation-aware explicit re-verification (see `imageHealth`).
    public func reverifyImageHealth(
        imageID: String,
        isCancelled: (@Sendable () -> Bool)?
    ) async -> LinuxImageHealthCheck? {
        await verifier.invalidate(id: imageID)
        return await imageHealth(imageID: imageID, isCancelled: isCancelled)
    }

    private func imageHealthOrCancelled(
        imageID: String,
        isCancelled: (@Sendable () -> Bool)?
    ) async throws -> ImageHealth? {
        let bootable = (try? await registry.bootableImage(id: imageID, root: layout.root)) ?? nil
        guard bootable != nil, let imageManifest = try? manifest(imageID: imageID) else {
            return nil
        }
        let image = try? Self.decoder.decode(LinuxGuestImage.self, from: imageManifest.legacyManifestData)
        guard let image else {
            return ImageHealth(
                readiness: .replacementRequired,
                issue: .structural(detail: "the Runtime v2 manifest carries no decodable legacy manifest"),
                image: nil
            )
        }
        guard let expanded = try? layout.expandedImageDirectory(imageID: imageID) else {
            return ImageHealth(readiness: .replacementRequired, issue: .artifactMissing(role: "expanded"), image: image)
        }
        let issue = try await verifier.verificationIssueOrCancelled(
            image: image, imageDirectory: expanded,
            cacheNamespace: Self.expandedVerificationNamespace,
            isCancelled: isCancelled
        )
        if issue == nil {
            return ImageHealth(readiness: .verified, issue: nil, image: image)
        }
        // The expanded bytes are missing/incomplete/damaged. The blobs (a
        // cheap stat — never a hash; blob bytes are content-addressed and
        // re-verified by the rebuild itself) decide whether local
        // reconstruction can succeed.
        let rebuildable = await allBlobsAvailable(manifest: imageManifest)
        return ImageHealth(
            readiness: rebuildable ? .rebuildableFromBlobs : .replacementRequired,
            issue: issue,
            image: image
        )
    }

    /// Rebuilds the expanded boot view from the verified blobs (no download).
    /// Every materialized artifact is hashed against the v2 manifest before
    /// the switch, and the previous view is moved aside — never deleted. Use
    /// only when `imageHealth` reports `.rebuildableFromBlobs`; a missing
    /// blob throws `RuntimeV2Error.blobMissing` and nothing is switched.
    /// `force` re-materializes even a size-complete view: callers that know
    /// the bytes are suspect (a same-id repair after blob replacement) must
    /// not trust the cheap completeness check.
    @discardableResult
    public func reconstructExpandedImage(
        imageID: String,
        force: Bool = false,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) async throws -> URL {
        try Self.checkReconstructionCancelled(isCancelled)
        guard let imageManifest = try manifest(imageID: imageID) else {
            throw RuntimeV2Error.imageNotFound(imageID)
        }
        let bootable = (try? await registry.bootableImage(id: imageID, root: layout.root)) ?? nil
        guard bootable != nil else {
            throw RuntimeV2Error.imageNotFound(imageID)
        }
        let expanded = try layout.expandedImageDirectory(imageID: imageID)
        // A complete, digest-verified view needs no rebuild (unless forced).
        if !force, try expandedViewComplete(imageID: imageID, manifest: imageManifest, directory: expanded) {
            if let image = try? Self.decoder.decode(LinuxGuestImage.self, from: imageManifest.legacyManifestData) {
                let issue = try await verifier.verificationIssueOrCancelled(
                    image: image, imageDirectory: expanded,
                    cacheNamespace: Self.expandedVerificationNamespace,
                    isCancelled: isCancelled
                )
                if issue == nil { return expanded }
            }
        }
        let staging = layout.expandedImagesDirectory
            .appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try await materializeExpanded(manifest: imageManifest, into: staging, isCancelled: isCancelled)
        try Self.checkReconstructionCancelled(isCancelled)
        try fileManager.createDirectory(at: layout.expandedImagesDirectory, withIntermediateDirectories: true)
        let previous = layout.quarantineDirectory
            .appendingPathComponent("expanded-\(imageID)-\(UUID().uuidString)", isDirectory: true)
        let hadPrevious = fileManager.fileExists(atPath: expanded.path)
        if hadPrevious {
            try? fileManager.createDirectory(at: layout.quarantineDirectory, withIntermediateDirectories: true)
            try fileManager.moveItem(at: expanded, to: previous)
        }
        do {
            guard rename(staging.path, expanded.path) == 0 else {
                throw RuntimeV2Error.migrationFailed(
                    id: "reconstruct-\(imageID)", phase: "switched",
                    reason: "expanded rename failed (errno \(errno))"
                )
            }
        } catch {
            if hadPrevious, !fileManager.fileExists(atPath: expanded.path) {
                try? fileManager.moveItem(at: previous, to: expanded)
            }
            throw error
        }
        // materializeExpanded hashed every artifact against the manifest
        // before the switch; record that success so the next status read is
        // stat-only instead of re-hashing a multi-gigabyte disk.
        if let image = try? Self.decoder.decode(LinuxGuestImage.self, from: imageManifest.legacyManifestData) {
            await verifier.recordSuccessfulVerification(
                image: image, imageDirectory: expanded,
                cacheNamespace: Self.expandedVerificationNamespace
            )
        }
        return expanded
    }

    private static func checkReconstructionCancelled(
        _ isCancelled: (@Sendable () -> Bool)?
    ) throws {
        if Task.isCancelled || isCancelled?() == true {
            throw CancellationError()
        }
    }

    private func allBlobsAvailable(manifest: Manifest) async -> Bool {
        for (_, ref) in manifest.artifacts {
            guard let available = try? await blobs.blobAvailable(digest: ref.sha512), available else {
                return false
            }
        }
        return true
    }

    /// Materializes (or repairs) the expanded view for a verified image from
    /// its blobs. Expanded content is rebuildable: a missing or incomplete
    /// directory is re-cloned, never treated as state.
    public func ensureExpanded(imageID: String) async throws -> URL {
        guard let manifest = try manifest(imageID: imageID) else {
            throw RuntimeV2Error.imageNotFound(imageID)
        }
        let expanded = try layout.expandedImageDirectory(imageID: imageID)
        if try expandedViewComplete(imageID: imageID, manifest: manifest, directory: expanded) {
            return expanded
        }
        let staging = layout.expandedImagesDirectory
            .appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try await materializeExpanded(manifest: manifest, into: staging)
        try fileManager.createDirectory(at: layout.expandedImagesDirectory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: expanded.path) {
            try fileManager.removeItem(at: expanded)
        }
        guard rename(staging.path, expanded.path) == 0 else {
            throw RuntimeV2Error.migrationFailed(
                id: "expand-\(imageID)", phase: "verified",
                reason: "rename into images/expanded failed (errno \(errno))"
            )
        }
        // materializeExpanded just hashed every artifact; record the success
        // so a following status read is stat-only.
        if let image = try? Self.decoder.decode(LinuxGuestImage.self, from: manifest.legacyManifestData) {
            await verifier.recordSuccessfulVerification(
                image: image, imageDirectory: expanded,
                cacheNamespace: Self.expandedVerificationNamespace
            )
        }
        return expanded
    }

    /// True when the rebuildable expanded view exists and carries every
    /// artifact at its recorded size. The view is disposable — the registry
    /// row, the v2 manifest and the blobs are the truth — so this answers
    /// "is the cache intact", never "is the image installed".
    public func isExpandedViewComplete(imageID: String) throws -> Bool {
        guard let manifest = try manifest(imageID: imageID) else { return false }
        let expanded = try layout.expandedImageDirectory(imageID: imageID)
        return try expandedViewComplete(imageID: imageID, manifest: manifest, directory: expanded)
    }

    /// Writes the expanded tree into `directory`: the verbatim legacy manifest
    /// plus every artifact materialized from its blob, then re-verifies every
    /// file against the recorded digest before returning. `isCancelled` is
    /// observed between artifacts (and before the switch): a cancelled
    /// reconstruction leaves the previous view untouched and its staging tree
    /// is removed by the caller's defer.
    private func materializeExpanded(
        manifest: Manifest,
        into directory: URL,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) async throws {
        try Self.checkReconstructionCancelled(isCancelled)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manifest.legacyManifestData.write(
            to: directory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        for (role, ref) in manifest.artifacts.sorted(by: { $0.key < $1.key }) {
            try Self.checkReconstructionCancelled(isCancelled)
            guard !ref.expandedPath.contains("\u{0}"),
                  !ref.expandedPath.hasPrefix("/"),
                  !ref.expandedPath.split(separator: "/").contains("..") else {
                throw RuntimeV2Error.migrationFailed(
                    id: "expand-\(manifest.imageID)", phase: "copied",
                    reason: "artifact \(role) declares an escaping expanded path '\(ref.expandedPath)'"
                )
            }
            let destination = directory.appendingPathComponent(ref.expandedPath)
            // The expanded rootfs is the read-only base the per-VM working
            // disk is cloned from; nothing may write through this view.
            try await blobs.materialize(digest: ref.sha512, at: destination, writable: false)
            let size = (try fileManager.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? -1
            guard size == ref.bytes else {
                throw RuntimeV2Error.blobDigestMismatch(
                    expected: "\(ref.sha512) (\(ref.bytes) bytes)", actual: "expanded size \(size)"
                )
            }
            let digest = try FloeDigest.sha512Hex(ofFileAt: destination, isCancelled: isCancelled)
            guard digest == ref.sha512.lowercased() else {
                throw RuntimeV2Error.blobDigestMismatch(expected: ref.sha512, actual: digest)
            }
        }
    }

    private func expandedViewComplete(imageID: String, manifest: Manifest, directory: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) else {
            return false
        }
        for (_, ref) in manifest.artifacts {
            let file = directory.appendingPathComponent(ref.expandedPath)
            let size = (try? fileManager.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? -1
            if size != ref.bytes { return false }
        }
        return true
    }

    // MARK: legacy migration

    /// Migrates one legacy `<legacyImagesRoot>/<imageID>/` install into the
    /// content-addressed store. The legacy directory is only moved aside (to
    /// the migration's rollback directory) after the replacement is verified;
    /// it is never modified in place and never deleted outright.
    @discardableResult
    public func migrateLegacyImage(imageID: String, legacyImagesRoot: URL) async throws -> MigrationReport {
        try RuntimeV2Identifier.validate(imageID, kind: .image)
        let migrationID = "legacy-image-\(imageID)"
        let legacyDirectory = legacyImagesRoot.appendingPathComponent(imageID, isDirectory: true)
        let legacyManifestURL = legacyDirectory.appendingPathComponent("manifest.json")

        // Idempotent rerun: a previous migration already verified the v2
        // install and moved the legacy directory aside into its rollback
        // point. Report the recorded outcome instead of failing on the
        // missing source or copying a second time. A v2 manifest without a
        // verified registry row is NOT completion — that state falls through
        // to the discovered phase and is repaired or failed honestly there.
        if !fileManager.fileExists(atPath: legacyManifestURL.path),
           let existing = try manifest(imageID: imageID),
           try await registry.bootableImage(id: imageID, root: layout.root) != nil {
            // Capability metadata is not install content. Refresh the stored
            // declaration from the manifest's own verbatim legacy bytes when
            // they differ — but only after proving those bytes describe
            // exactly the artifact digests the verified v2 manifest records
            // (same coherence rule as the matching-legacy branch below). A
            // declared `smp_capable`/`smpCapable`/`capabilities.smp` value is
            // lifted verbatim, including an explicit false or a withdrawn
            // declaration; artifact digests are never touched.
            if let embedded = try? Self.decoder.decode(
                LinuxGuestImage.self, from: existing.legacyManifestData
            ), Self.manifestDigestsMatch(manifest: existing, image: embedded) {
                let refreshedCapabilities = Self.declaredCapabilities(legacyManifestData: existing.legacyManifestData)
                if existing.capabilities != refreshedCapabilities {
                    var refreshed = existing
                    refreshed.capabilities = refreshedCapabilities
                    try Self.encoder.encode(refreshed).write(
                        to: layout.imageManifestURL(imageID: imageID), options: .atomic
                    )
                    await verifier.invalidate(id: imageID)
                }
            }
            let stored = (try? await registry.migration(id: migrationID)) ?? nil
            return MigrationReport(
                imageID: imageID, migrationID: migrationID,
                phase: stored?.phase ?? .cleanupPending,
                reusedExisting: true,
                blobDigests: existing.artifacts.values.map(\.sha512).sorted()
            )
        }

        // Phase: discovered.
        try await registry.beginMigration(
            id: migrationID, kind: "legacy-image",
            sourcePath: legacyDirectory.path,
            targetPath: try layout.expandedImageDirectory(imageID: imageID).path,
            detail: nil
        )
        do {
            guard let legacyData = try? Data(contentsOf: legacyManifestURL),
                  let image = try? Self.decoder.decode(LinuxGuestImage.self, from: legacyData) else {
                throw RuntimeV2Error.migrationFailed(
                    id: migrationID, phase: "discovered",
                    reason: "legacy manifest is missing or undecodable; the legacy install was retained"
                )
            }
            if let failure = image.qualificationFailure(imageDirectory: legacyDirectory) {
                throw RuntimeV2Error.migrationFailed(
                    id: migrationID, phase: "discovered",
                    reason: "legacy image is not qualified: \(failure)"
                )
            }
            // Locally built images with absolute artifact paths cannot be
            // expanded faithfully; they stay legacy-only with the reason
            // recorded, never half-migrated.
            for declared in image.declaredArtifacts where declared.path.hasPrefix("/") {
                throw RuntimeV2Error.migrationFailed(
                    id: migrationID, phase: "discovered",
                    reason: "artifact \(declared.role.rawValue) uses an absolute path; local images stay legacy-only"
                )
            }

            // Already migrated with identical content? Reuse the verified v2
            // install: no re-copy, no switch; the legacy directory can move
            // aside straight into the rollback point.
            let declaredCapabilities = Self.declaredCapabilities(legacyManifestData: legacyData)
            if let existing = try manifest(imageID: imageID),
               try await registry.bootableImage(id: imageID, root: layout.root) != nil,
               Self.manifestDigestsMatch(manifest: existing, image: image) {
                // Capability metadata is not install content: a legacy
                // manifest that declares a capability differently (granted OR
                // withdrawn — an explicit false and an absent key are both
                // declarations) refreshes the v2 manifest in place. The
                // verbatim legacy bytes and the lifted capabilities update
                // TOGETHER, atomically, so the two sources can never diverge:
                // a stored withdrawal must not keep legacy bytes that the
                // embedded fallback would resurrect, and a stored declaration
                // must not sit on bytes that withdrew it. Artifact digests are
                // untouched and the verified row stays the truth.
                if existing.capabilities != declaredCapabilities
                    || existing.legacyManifestData != legacyData {
                    var refreshed = existing
                    refreshed.capabilities = declaredCapabilities
                    refreshed.legacyManifestData = legacyData
                    try Self.encoder.encode(refreshed).write(
                        to: layout.imageManifestURL(imageID: imageID), options: .atomic
                    )
                    await verifier.invalidate(id: imageID)
                }
                try await registry.setMigrationPhase(id: migrationID, phase: .verified)
                try await moveLegacyAside(
                    legacyDirectory: legacyDirectory, migrationID: migrationID, kind: "legacy-images"
                )
                try await registry.setMigrationPhase(id: migrationID, phase: .cleanupPending)
                let report = MigrationReport(
                    imageID: imageID, migrationID: migrationID, phase: .cleanupPending,
                    reusedExisting: true,
                    blobDigests: existing.artifacts.values.map(\.sha512).sorted()
                )
                return report
            }

            // Phase: copied — ingest every digest-bound artifact into the CAS.
            // Mismatched same-id content is staged here first; the switch only
            // happens after every staged blob verifies.
            try await registry.setMigrationPhase(id: migrationID, phase: .copied)
            var refs: [String: Manifest.ArtifactRef] = [:]
            var ingested: [String] = []
            do {
                for declared in image.declaredArtifacts {
                    guard let digestRecord = image.artifactDigest(role: declared.role) else {
                        throw RuntimeV2Error.migrationFailed(
                            id: migrationID, phase: "copied",
                            reason: "no digest record for \(declared.role.rawValue)"
                        )
                    }
                    let source = try containedArtifact(
                        path: declared.path, inside: legacyDirectory, migrationID: migrationID
                    )
                    let role = Self.manifestRole(declared.role)
                    let digest = try await blobs.ingest(
                        sourceURL: source,
                        expectedSHA512: digestRecord.sha512,
                        expectedBytes: digestRecord.bytes,
                        retainFor: imageID
                    )
                    ingested.append(digest)
                    refs[role] = Manifest.ArtifactRef(
                        sha512: digest, bytes: digestRecord.bytes, expandedPath: declared.path
                    )
                }
            } catch {
                for digest in ingested { try? await blobs.release(digest: digest) }
                throw error
            }

            // Phase: verified — build the expanded staging tree and prove every
            // file before anything switches.
            try await registry.setMigrationPhase(id: migrationID, phase: .verified)
            let v2Manifest = Manifest(
                imageID: imageID, createdAt: Date(), artifacts: refs,
                legacyManifestData: legacyData, capabilities: declaredCapabilities
            )
            let staging = layout.expandedImagesDirectory
                .appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
            defer { try? fileManager.removeItem(at: staging) }
            do {
                try await materializeExpanded(manifest: v2Manifest, into: staging)
            } catch {
                for digest in ingested { try? await blobs.release(digest: digest) }
                throw error
            }

            // Phase: switched — atomic directory switch of the expanded view,
            // then the v2 manifest, then the registry row. Any earlier v2
            // expanded content moves into the migration rollback directory
            // first, so the switch is reversible.
            try await registry.setMigrationPhase(id: migrationID, phase: .switched)
            let expanded = try layout.expandedImageDirectory(imageID: imageID)
            let rollback = layout.recoveryMigrationsDirectory
                .appendingPathComponent(migrationID, isDirectory: true)
            try fileManager.createDirectory(at: rollback, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: expanded.path) {
                let previous = rollback.appendingPathComponent("expanded-previous", isDirectory: true)
                try? fileManager.removeItem(at: previous)
                try fileManager.moveItem(at: expanded, to: previous)
            }
            do {
                guard rename(staging.path, expanded.path) == 0 else {
                throw RuntimeV2Error.migrationFailed(
                        id: migrationID, phase: "switched",
                        reason: "expanded rename failed (errno \(errno))"
                    )
                }
            } catch {
                let previous = rollback.appendingPathComponent("expanded-previous", isDirectory: true)
                if fileManager.fileExists(atPath: previous.path) {
                    try? fileManager.moveItem(at: previous, to: expanded)
                }
                for digest in ingested { try? await blobs.release(digest: digest) }
                throw error
            }
            // Release digests the replaced manifest referenced (refcount
            // symmetry keeps shared base blobs alive exactly while referenced).
            if let replaced = try manifest(imageID: imageID) {
                for digest in replaced.artifacts.values.map(\.sha512) where !ingested.contains(digest) {
                    try? await blobs.release(digest: digest)
                }
            }
            let manifestData = try Self.encoder.encode(v2Manifest)
            try manifestData.write(to: layout.imageManifestURL(imageID: imageID), options: .atomic)
            try await registry.registerStagedImage(
                id: imageID,
                manifestPath: "images/manifests/\(imageID).json",
                bytes: refs.values.reduce(0) { $0 + $1.bytes }
            )
            guard let rootfs = v2Manifest.rootfsDigest else {
                throw RuntimeV2Error.migrationFailed(
                    id: migrationID, phase: "switched", reason: "image declares no rootfs artifact"
                )
            }
            try await registry.markImageVerified(
                id: imageID,
                expandedPath: "images/expanded/\(imageID)",
                baseRootfsDigest: rootfs
            )
            await verifier.invalidate(id: imageID)

            // Phase: cleanupPending — the legacy directory moves into the
            // rollback point. Only finalization purges anything.
            try await moveLegacyAside(
                legacyDirectory: legacyDirectory, migrationID: migrationID, kind: "legacy-images"
            )
            try await registry.setMigrationPhase(id: migrationID, phase: .cleanupPending)
            return MigrationReport(
                imageID: imageID, migrationID: migrationID, phase: .cleanupPending,
                reusedExisting: false, blobDigests: ingested.sorted()
            )
        } catch {
            try? await registry.setMigrationPhase(
                id: migrationID, phase: .failed, error: error.localizedDescription
            )
            throw error
        }
    }

    /// Finalizes a migration whose replacement has proven itself: the rollback
    /// directory moves to recovery/trash (still not a hard delete), and the
    /// migration record reaches `done`.
    public func finalizeMigration(id migrationID: String) async throws {
        guard let row = try await registry.migration(id: migrationID), row.phase == .cleanupPending else {
            return
        }
        let rollback = layout.recoveryMigrationsDirectory.appendingPathComponent(migrationID, isDirectory: true)
        if fileManager.fileExists(atPath: rollback.path) {
            let trash = layout.trashDirectory.appendingPathComponent(
                "\(migrationID)-\(UUID().uuidString)", isDirectory: true
            )
            try fileManager.moveItem(at: rollback, to: trash)
        }
        try await registry.setMigrationPhase(id: migrationID, phase: .done)
    }

    /// Rolls a cleanupPending migration back: legacy content returns to its
    /// original location and the v2 replacement is quarantined, never deleted.
    public func rollbackMigration(id migrationID: String, legacyImagesRoot: URL) async throws {
        guard let row = try await registry.migration(id: migrationID) else { return }
        guard row.phase == .cleanupPending || row.phase == .switched else { return }
        let rollback = layout.recoveryMigrationsDirectory.appendingPathComponent(migrationID, isDirectory: true)
        if row.kind == "legacy-image",
           let source = row.sourcePath,
           let imageID = source.split(separator: "/").last.map(String.init) {
            let legacyBackup = rollback.appendingPathComponent("legacy-images", isDirectory: true)
                .appendingPathComponent(imageID, isDirectory: true)
            let destination = legacyImagesRoot.appendingPathComponent(imageID, isDirectory: true)
            if fileManager.fileExists(atPath: legacyBackup.path),
               !fileManager.fileExists(atPath: destination.path) {
                try fileManager.createDirectory(at: legacyImagesRoot, withIntermediateDirectories: true)
                try fileManager.moveItem(at: legacyBackup, to: destination)
            }
            try await registry.quarantineImage(id: imageID, reason: "rolled back to the legacy install")
            if let expanded = try? layout.expandedImageDirectory(imageID: imageID),
               fileManager.fileExists(atPath: expanded.path) {
                let quarantine = layout.quarantineDirectory
                    .appendingPathComponent("expanded-\(imageID)-\(UUID().uuidString)", isDirectory: true)
                try? fileManager.moveItem(at: expanded, to: quarantine)
            }
        }
        try await registry.setMigrationPhase(id: migrationID, phase: .failed, error: "rolled back by request")
    }

    // MARK: same-id repair from a verified replacement install

    /// Forces a same-id repair from a freshly verified legacy install.
    ///
    /// `installTrustedImage` promotes verified bytes into the legacy image
    /// directory, but a migrated image's boot path reads the Runtime v2 blobs
    /// and expanded view; without this step a damaged v2 image would keep
    /// booting damaged bytes even though a verified replacement was just
    /// downloaded. Every referenced blob is re-hashed and, when damaged or
    /// missing, re-placed from the legacy artifact; the expanded view is then
    /// rebuilt from the re-verified blobs and the legacy directory is moved
    /// aside into the existing migration rollback area (never deleted).
    ///
    /// Requires the legacy manifest to describe exactly the digests the v2
    /// manifest records: a genuinely different image must go through the
    /// normal migration path, and a same-id repair never silently rebases
    /// anything. Per-environment deltas, workspaces and working disks are not
    /// touched.
    @discardableResult
    public func repairImageFromLegacyInstall(
        imageID: String,
        legacyImagesRoot: URL,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) async throws -> Bool {
        try Self.checkReconstructionCancelled(isCancelled)
        try RuntimeV2Identifier.validate(imageID, kind: .image)
        let migrationID = "legacy-image-\(imageID)"
        guard let existingManifest = try manifest(imageID: imageID),
              try await registry.bootableImage(id: imageID, root: layout.root) != nil else {
            throw RuntimeV2Error.imageNotFound(imageID)
        }
        let legacyDirectory = legacyImagesRoot.appendingPathComponent(imageID, isDirectory: true)
        let legacyManifestURL = legacyDirectory.appendingPathComponent("manifest.json")
        guard let legacyData = try? Data(contentsOf: legacyManifestURL),
              let legacyImage = try? Self.decoder.decode(LinuxGuestImage.self, from: legacyData) else {
            throw RuntimeV2Error.migrationFailed(
                id: migrationID, phase: "discovered",
                reason: "the replacement legacy manifest is missing or undecodable"
            )
        }
        if let failure = legacyImage.qualificationFailure(imageDirectory: legacyDirectory) {
            throw RuntimeV2Error.migrationFailed(
                id: migrationID, phase: "discovered",
                reason: "the replacement legacy image is not qualified: \(failure)"
            )
        }
        guard Self.manifestDigestsMatch(manifest: existingManifest, image: legacyImage) else {
            throw RuntimeV2Error.migrationFailed(
                id: migrationID, phase: "discovered",
                reason: "the replacement image content differs from the installed Runtime v2 manifest; same-id repair refuses instead of rebasing"
            )
        }
        // Capability metadata is not install content: the verified replacement
        // manifest is the same authenticated content the digest match above
        // just proved (identical pinned artifact hashes), so its declared
        // `smp_capable`/`smpCapable`/`capabilities.smp` value — true, explicit
        // false or withdrawn — becomes the stored lift. The verbatim legacy
        // bytes and the lifted capabilities update TOGETHER so the embedded
        // fallback can never resurrect a declaration the replacement
        // withdrew. Artifact digests are never modified here.
        let repairedCapabilities = Self.declaredCapabilities(legacyManifestData: legacyData)
        if existingManifest.capabilities != repairedCapabilities
            || existingManifest.legacyManifestData != legacyData {
            var repaired = existingManifest
            repaired.capabilities = repairedCapabilities
            repaired.legacyManifestData = legacyData
            try Self.encoder.encode(repaired).write(
                to: layout.imageManifestURL(imageID: imageID), options: .atomic
            )
        }
        var replacedAny = false
        for declared in legacyImage.declaredArtifacts {
            try Self.checkReconstructionCancelled(isCancelled)
            guard legacyImage.artifactDigest(role: declared.role) != nil,
                  let ref = existingManifest.artifacts[Self.manifestRole(declared.role)] else {
                throw RuntimeV2Error.migrationFailed(
                    id: migrationID, phase: "copied",
                    reason: "no digest record for \(declared.role.rawValue)"
                )
            }
            let source = try containedArtifact(
                path: declared.path, inside: legacyDirectory, migrationID: migrationID
            )
            if try await blobs.repairBlob(
                digest: ref.sha512, sourceURL: source, expectedBytes: ref.bytes
            ) {
                replacedAny = true
            }
        }
        // Rebuild the bootable view from the re-verified blobs (forces a
        // fresh materialization instead of trusting a size-complete view).
        try Self.checkReconstructionCancelled(isCancelled)
        _ = try await reconstructExpandedImage(imageID: imageID, force: true, isCancelled: isCancelled)
        // reconstructExpandedImage seeds the success cache from the digests
        // it just verified; no invalidation is needed (and would force a
        // re-hash of the whole disk on the next status read).
        try await moveLegacyAside(
            legacyDirectory: legacyDirectory, migrationID: migrationID, kind: "legacy-images"
        )
        FloeLogger(category: .tools).info(
            "Runtime v2 image \(imageID) repaired from a verified legacy install (blobs re-placed=\(replacedAny))"
        )
        return replacedAny
    }

    // MARK: helpers

    private func moveLegacyAside(legacyDirectory: URL, migrationID: String, kind: String) async throws {
        guard fileManager.fileExists(atPath: legacyDirectory.path) else { return }
        let rollback = layout.recoveryMigrationsDirectory
            .appendingPathComponent(migrationID, isDirectory: true)
            .appendingPathComponent(kind, isDirectory: true)
        try fileManager.createDirectory(at: rollback, withIntermediateDirectories: true)
        let destination = rollback.appendingPathComponent(legacyDirectory.lastPathComponent, isDirectory: true)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: legacyDirectory, to: destination)
    }

    private static func manifestRole(_ role: LinuxGuestImageArtifact.Role) -> String {
        role == .disk ? "rootfs" : role.rawValue
    }

    /// Reads capability claims from the verbatim legacy manifest without
    /// decoding it into the (older) `LinuxGuestImage` shape, which would drop
    /// unknown keys. Absent keys mean "not declared" — never true.
    static func declaredCapabilities(legacyManifestData: Data) -> Manifest.Capabilities? {
        guard let object = try? JSONSerialization.jsonObject(with: legacyManifestData) as? [String: Any] else {
            return nil
        }
        if let smp = object["smp_capable"] as? Bool {
            return Manifest.Capabilities(smp: smp, declaredBy: "legacy manifest smp_capable")
        }
        if let smp = object["smpCapable"] as? Bool {
            return Manifest.Capabilities(smp: smp, declaredBy: "legacy manifest smpCapable")
        }
        if let capabilities = object["capabilities"] as? [String: Any], let smp = capabilities["smp"] as? Bool {
            return Manifest.Capabilities(smp: smp, declaredBy: "legacy manifest capabilities.smp")
        }
        return nil
    }

    /// True when the decoded legacy manifest describes exactly the artifact
    /// digests and byte counts the v2 manifest records (and the same image
    /// id): the coherence rule every capability refresh and every embedded-
    /// declaration fallback must satisfy before trusting manifest bytes.
    private static func manifestDigestsMatch(manifest: Manifest, image: LinuxGuestImage) -> Bool {
        guard image.id == manifest.imageID else { return false }
        for declared in image.declaredArtifacts {
            guard let record = image.artifactDigest(role: declared.role),
                  let ref = manifest.artifacts[manifestRole(declared.role)],
                  ref.sha512.lowercased() == record.sha512.lowercased(),
                  ref.bytes == record.bytes else {
                return false
            }
        }
        return true
    }

    private func containedArtifact(path: String, inside directory: URL, migrationID: String) throws -> URL {
        guard !path.contains("\u{0}"),
              !path.hasPrefix("/"),
              !path.split(separator: "/").contains("..") else {
            throw RuntimeV2Error.migrationFailed(
                id: migrationID, phase: "copied",
                reason: "artifact path escapes the legacy image directory: \(path)"
            )
        }
        let url = directory.appendingPathComponent(path)
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(root.path + "/") else {
            throw RuntimeV2Error.migrationFailed(
                id: migrationID, phase: "copied",
                reason: "artifact path escapes the legacy image directory: \(path)"
            )
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw RuntimeV2Error.migrationFailed(
                id: migrationID, phase: "copied",
                reason: "artifact is missing: \(path)"
            )
        }
        return resolved
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
