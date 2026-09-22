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

        public var version: Int
        public var imageID: String
        public var createdAt: Date
        public var artifacts: [String: ArtifactRef] // role → ref (bios/kernel/initrd/rootfs/runner)
        /// The verbatim legacy manifest (LinuxGuestImage JSON) the digests
        /// were taken from: provenance, qualification record, runner contract
        /// and compatible origins stay byte-identical.
        public var legacyManifestData: Data

        public static let currentVersion = 2

        public init(imageID: String, createdAt: Date, artifacts: [String: ArtifactRef], legacyManifestData: Data) {
            self.version = Manifest.currentVersion
            self.imageID = imageID
            self.createdAt = createdAt
            self.artifacts = artifacts
            self.legacyManifestData = legacyManifestData
        }

        public var rootfsDigest: String? { artifacts["rootfs"]?.sha512 ?? artifacts["disk"]?.sha512 }
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

    // MARK: expansion (rebuildable view)

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
        return expanded
    }

    /// Writes the expanded tree into `directory`: the verbatim legacy manifest
    /// plus every artifact materialized from its blob, then re-verifies every
    /// file against the recorded digest before returning.
    private func materializeExpanded(manifest: Manifest, into directory: URL) async throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manifest.legacyManifestData.write(
            to: directory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        for (role, ref) in manifest.artifacts.sorted(by: { $0.key < $1.key }) {
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
            let digest = try FloeDigest.sha512Hex(ofFileAt: destination)
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
            if let existing = try manifest(imageID: imageID),
               try await registry.bootableImage(id: imageID, root: layout.root) != nil,
               manifestMatches(manifest: existing, image: image) {
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
                    let role = manifestRole(declared.role)
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
                imageID: imageID, createdAt: Date(), artifacts: refs, legacyManifestData: legacyData
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

    private func manifestRole(_ role: LinuxGuestImageArtifact.Role) -> String {
        role == .disk ? "rootfs" : role.rawValue
    }

    private func manifestMatches(manifest: Manifest, image: LinuxGuestImage) -> Bool {
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
