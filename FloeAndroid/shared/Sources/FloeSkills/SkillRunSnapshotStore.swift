// SPDX-License-Identifier: MPL-2.0
//
// Durable per-run pinned Skill snapshots (n07-skill-snapshots69).
//
// Behavior reference: the fixed iOS SkillsCenter.snapshot(for:runID:)
// (FloeAgent/FloeApp/Skills/SkillsCenter.swift @ 1f6232a54, :1636-1652) plus
// writeSnapshot (:1550-1562): the FIRST validated exact enabled read of an
// installed guide for a real native run pins the digest-verified package
// bytes under `<installationRoot>/.run-snapshots/<runID>/<skillID>/`; every
// later page, re-read and process-death recovery of the SAME run re-validates
// and serves exactly those bytes, so an upgrade/edit/remove in between can
// never combine revisions inside one run. This package owns ONLY the
// immutable-bytes machinery (SkillContentSnapshot + the ORIGINAL
// SkillPackageValidator gate); it never touches grants, approvals or the
// store — historical pinned content confers no new authorization.
//
// OWNERSHIP (primary review 2026-11-09): `.run-snapshots` is SHARED with
// migration preparation trees, which carry their own
// `.floe-migration-owner` marker and are never touched here. A tree is a
// REAL per-run pin only when EVERY ancestor (the runs root, the run
// directory and the snapshot directory) is a plain non-symlink directory
// AND the exact owner marker `owner` == "run:<runID-lower>" is present.
// Markers/digest/manifest are staged with the package BEFORE the one atomic
// directory publication, so a pin is visible only when complete; a
// concurrent first read validates the already-published winner instead of
// replacing it, and a corrupt/foreign entry is refused (never deleted).
import Foundation

/// Outcome of releasing one run's pinned snapshot trees.
public enum SkillRunSnapshotRelease: String, Sendable, Equatable {
    /// The exact run tree existed, was marker-verified as a REAL per-run
    /// pin, and was removed.
    case released
    /// No tree existed for the run; nothing was removed.
    case absent
    /// The directory exists but fails the real-run ownership check (missing
    /// or foreign marker, a migration preparation tree, a symlink/plain-dir
    /// violation): it is NEVER removed.
    case notOwned
    /// Removal was attempted and failed; the tree is retained.
    case failed
}

/// Durable owner of `.run-snapshots/<runID>/<skillID>` pinned trees.
///
/// Thread-safety: the type is a stateless value type over the filesystem;
/// every mutation publishes exactly one complete tree (atomic directory
/// rename) and every read re-validates bytes against the recorded digest,
/// so crash windows degrade to an absent pin (re-pinned on the next
/// validated read) instead of mixed revisions.
public struct SkillRunSnapshotStore: Sendable {

    /// The SAME canonical Skills installation root that owns the live
    /// packages and `.upgrade-history` (iOS layout parity).
    public let installationRoot: URL

    /// The shared runs root (`.run-snapshots`). Migration preparation trees
    /// live beside real run trees under this root; ownership markers keep
    /// the two populations strictly separated.
    public static let runsRootComponent = ".run-snapshots"
    /// Marker file name inside a snapshot directory proving REAL per-run
    /// ownership. Value: `run:<runID-lower>`. The migration lane owns the
    /// complementary `floeMigrationSnapshotMarker = ".floe-migration-owner"`.
    public static let ownerMarkerComponent = "owner"
    /// Exact owner-marker value for one run id.
    public static func ownerMarkerValue(runID: UUID) -> String {
        "run:\(runID.uuidString.lowercased())"
    }

    public init(installationRoot: URL) {
        self.installationRoot = installationRoot
    }

    private var runsRoot: URL {
        installationRoot.appendingPathComponent(Self.runsRootComponent, isDirectory: true)
    }

    private func snapshotDirectory(runID: UUID, skillID: String) -> URL {
        runsRoot.appendingPathComponent(runID.uuidString, isDirectory: true)
            .appendingPathComponent(skillID, isDirectory: true)
    }

    private func packageDirectory(runID: UUID, skillID: String) -> URL {
        snapshotDirectory(runID: runID, skillID: skillID)
            .appendingPathComponent("package", isDirectory: true)
    }

    private func digestFile(runID: UUID, skillID: String) -> URL {
        snapshotDirectory(runID: runID, skillID: skillID)
            .appendingPathComponent("digest", isDirectory: false)
    }

    private func manifestFile(runID: UUID, skillID: String) -> URL {
        snapshotDirectory(runID: runID, skillID: skillID)
            .appendingPathComponent("manifest", isDirectory: false)
    }

    private func ownerMarkerFile(runID: UUID, skillID: String) -> URL {
        snapshotDirectory(runID: runID, skillID: skillID)
            .appendingPathComponent(Self.ownerMarkerComponent, isDirectory: false)
    }

    // MARK: - Pin / re-read

    /// The pinned, digest-verified snapshot for one installed row of one
    /// run. First call validates the CURRENT installed package through the
    /// ORIGINAL gate and pins the bytes; later calls (pagination, recovery)
    /// re-validate the pinned bytes against the recorded digest and pinned
    /// manifest and NEVER re-read the current installation, so a mid-run
    /// upgrade/edit cannot change what this run sees.
    ///
    /// - Parameters:
    ///   - root: the CURRENT installed package directory (used ONLY when no
    ///     valid pin exists yet).
    ///   - expectedDigest: the digest the current install must match to be
    ///     pinned (the persisted row CAS value).
    ///   - manifestOverride: the row's sidecar manifest (traditional
    ///     manifest-less packages); persisted with the pin so recovery
    ///     interprets the pinned bytes with the pinned manifest, never the
    ///     current row's. Packages carrying floe.json always verify against
    ///     their own on-disk manifest.
    ///   - runID: the REAL native run id from ToolContext (never minted).
    ///   - skillID: a SkillIdentifier-validated installed id.
    public func pinnedSnapshot(
        currentInstallRoot root: URL,
        expectedDigest: String,
        manifestOverride: SkillManifest?,
        runID: UUID,
        skillID: String
    ) throws -> SkillContentSnapshot {
        try SkillIdentifier.validate(skillID)
        let directory = snapshotDirectory(runID: runID, skillID: skillID)
        if FileManager.default.fileExists(atPath: directory.path) {
            // Pagination / process recovery, or a concurrent first read that
            // lost the publication race: the PUBLISHED pin is the authority
            // for this run. A valid winner is served; a corrupt or unowned
            // entry fails closed (typed refusal) instead of silently
            // adopting the current installation or deleting the entry.
            return try readPublishedPin(runID: runID, skillID: skillID)
        }
        // First validated read of this run: pin the CURRENT install.
        let snapshot = try SkillContentSnapshot(
            root: root,
            expectedDigest: expectedDigest,
            manifestOverride: manifestOverride)
        try publishPin(snapshot: snapshot,
                       manifestOverride: manifestOverride,
                       runID: runID, skillID: skillID)
        return try readPublishedPin(runID: runID, skillID: skillID)
    }

    /// Validate a published pin end to end: every ancestor a plain
    /// directory, the exact owner marker present, the recorded digest
    /// well-formed, and the package bytes re-verified through the ORIGINAL
    /// gate with the PINNED manifest (recovered from the pin itself, so a
    /// manifest-less package is never reinterpreted with a newer sidecar).
    private func readPublishedPin(runID: UUID, skillID: String) throws
        -> SkillContentSnapshot {
        let fileManager = FileManager.default
        let directory = snapshotDirectory(runID: runID, skillID: skillID)
        guard Self.isPlainDirectory(runsRoot),
              Self.isPlainDirectory(runsRoot.appendingPathComponent(runID.uuidString, isDirectory: true)),
              Self.isPlainDirectory(directory) else {
            throw SkillValidationError.unsafePath(skillID)
        }
        let markerURL = ownerMarkerFile(runID: runID, skillID: skillID)
        guard !Self.isSymbolicLink(markerURL),
              let marker = try? String(contentsOf: markerURL, encoding: .utf8),
              marker == Self.ownerMarkerValue(runID: runID) else {
            throw SkillValidationError.unsafePath(skillID)
        }
        let digestURL = digestFile(runID: runID, skillID: skillID)
        guard !Self.isSymbolicLink(digestURL),
              let recorded = try? String(contentsOf: digestURL, encoding: .utf8),
              recorded.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
        else {
            throw SkillValidationError.digestMismatch
        }
        let manifestURL = manifestFile(runID: runID, skillID: skillID)
        var pinnedManifest: SkillManifest?
        if fileManager.fileExists(atPath: manifestURL.path) {
            guard !Self.isSymbolicLink(manifestURL),
                  let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(SkillManifest.self, from: data)
            else {
                throw SkillValidationError.invalidManifest("pinnedManifest")
            }
            pinnedManifest = manifest
        }
        return try SkillContentSnapshot(
            root: packageDirectory(runID: runID, skillID: skillID),
            expectedDigest: recorded,
            manifestOverride: pinnedManifest)
    }

    /// Materialize the validated bytes as this run's pin. The WHOLE pin
    /// (package, digest, pinned manifest and owner marker) lands in a
    /// run-private staging directory and is published with ONE atomic
    /// directory rename; a pre-existing entry is either a valid published
    /// pin (served, staging discarded) or a corrupt/foreign tree (typed
    /// refusal) — an existing directory is NEVER deleted or replaced.
    private func publishPin(snapshot: SkillContentSnapshot,
                            manifestOverride: SkillManifest?,
                            runID: UUID, skillID: String) throws {
        let fileManager = FileManager.default
        let runDirectory = runsRoot.appendingPathComponent(runID.uuidString,
                                                           isDirectory: true)
        let finalDirectory = snapshotDirectory(runID: runID, skillID: skillID)
        let stagingDirectory = runDirectory
            .appendingPathComponent(".\(skillID)-\(UUID().uuidString).staging",
                                    isDirectory: true)
        do {
            try ensurePlainRunsRootAndRunDirectory(runDirectory: runDirectory)
            if fileManager.fileExists(atPath: finalDirectory.path) {
                // Concurrent first read (or a prior crash-published tree):
                // never delete or replace. A valid pin wins outright; an
                // invalid one refuses this read without touching the entry.
                _ = try readPublishedPin(runID: runID, skillID: skillID)
                return
            }
            let stagedPackage = stagingDirectory
                .appendingPathComponent("package", isDirectory: true)
            try fileManager.createDirectory(at: stagedPackage,
                                            withIntermediateDirectories: true)
            for (path, bytes) in snapshot.files {
                let target = stagedPackage.appendingPathComponent(path)
                try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                try bytes.write(to: target, options: .atomic)
            }
            // The complete pin is staged BEFORE publication: digest and
            // marker inside the same moved tree, so the post-move checks
            // below cannot observe a half-written pin.
            try Data(snapshot.package.canonicalSHA256.utf8)
                .write(to: stagingDirectory.appendingPathComponent("digest"),
                       options: .atomic)
            if let manifestOverride {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(manifestOverride)
                try data.write(to: stagingDirectory.appendingPathComponent("manifest"),
                               options: .atomic)
            }
            try Data(Self.ownerMarkerValue(runID: runID).utf8)
                .write(to: stagingDirectory.appendingPathComponent(Self.ownerMarkerComponent),
                       options: .atomic)
            guard Self.isPlainDirectory(stagingDirectory) else {
                throw SkillValidationError.unsafePath(skillID)
            }
            try fileManager.moveItem(at: stagingDirectory, to: finalDirectory)
            // Post-move verification: only a tree that is complete and
            // marker-owned stays published; anything else is removed (it is
            // exactly the tree this branch just created) and the read fails
            // closed so the run can re-read from a fresh attempt.
            if let verified = try? readPublishedPin(runID: runID, skillID: skillID) {
                _ = verified
            } else {
                throw SkillValidationError.digestMismatch
            }
        } catch {
            // Only the staging tree — always this branch's own scratch — is
            // cleaned on failure; the runs root and any pre-existing entry
            // are never touched by an error path.
            if Self.isPlainDirectory(stagingDirectory) {
                try? fileManager.removeItem(at: stagingDirectory)
            }
            throw error
        }
    }

    private func ensurePlainRunsRootAndRunDirectory(runDirectory: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: runsRoot.path) {
            guard Self.isPlainDirectory(runsRoot) else {
                throw SkillValidationError.unsafePath(Self.runsRootComponent)
            }
        } else {
            try fileManager.createDirectory(at: runsRoot,
                                            withIntermediateDirectories: false)
            guard Self.isPlainDirectory(runsRoot) else {
                try? fileManager.removeItem(at: runsRoot)
                throw SkillValidationError.unsafePath(Self.runsRootComponent)
            }
        }
        if fileManager.fileExists(atPath: runDirectory.path) {
            guard Self.isPlainDirectory(runDirectory) else {
                throw SkillValidationError.unsafePath(runDirectory.lastPathComponent)
            }
        } else {
            try fileManager.createDirectory(at: runDirectory,
                                            withIntermediateDirectories: false)
            guard Self.isPlainDirectory(runDirectory) else {
                try? fileManager.removeItem(at: runDirectory)
                throw SkillValidationError.unsafePath(runDirectory.lastPathComponent)
            }
        }
    }

    // MARK: - Release (trusted task-deletion owners only; NOT root retirement)

    /// Remove EXACTLY one run's REAL per-run pinned trees. Called by the
    /// trusted task-deletion lifecycle only after its real quiescence gate
    /// and durable commit; an unfinished run of a live task and a plain
    /// generation retirement/rebind are never passed here (retirement fences
    /// readers but keeps the durable pins for unfinished-run recovery).
    /// Migration-marked and otherwise unowned trees report `.notOwned` and
    /// are never removed.
    @discardableResult
    public func release(runID: UUID) -> SkillRunSnapshotRelease {
        let fileManager = FileManager.default
        let directory = runsRoot.appendingPathComponent(runID.uuidString,
                                                        isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return .absent }
        guard Self.isPlainDirectory(runsRoot),
              Self.isPlainDirectory(directory) else { return .notOwned }
        // Real-run ownership is proven per CHILD tree: a run directory that
        // contains only migration preparation trees (a shared UUID can name
        // both) must report `.notOwned`, never `.released`.
        guard let children = try? fileManager.contentsOfDirectory(atPath: directory.path)
        else { return .notOwned }
        // Hidden entries can belong to migration preparation or an
        // unfinished publisher; their names do not prove ownership.
        guard !children.contains(where: { $0.hasPrefix(".") }) else { return .notOwned }
        let visible = children
        guard !visible.isEmpty else { return .notOwned }
        var sawOwned = false
        for child in visible {
            let childURL = directory.appendingPathComponent(child, isDirectory: true)
            guard Self.isPlainDirectory(childURL),
                  ownsRealRunPin(snapshotDirectory: childURL, runID: runID) else {
                return .notOwned
            }
            sawOwned = true
        }
        guard sawOwned else { return .notOwned }
        do {
            try fileManager.removeItem(at: directory)
            return .released
        } catch {
            return .failed
        }
    }

    /// Whether a snapshot directory carries the exact real-run owner marker.
    private func ownsRealRunPin(snapshotDirectory: URL, runID: UUID) -> Bool {
        let marker = snapshotDirectory.appendingPathComponent(Self.ownerMarkerComponent,
                                                              isDirectory: false)
        guard Self.isPlainDirectory(snapshotDirectory),
              !Self.isSymbolicLink(marker),
              let value = try? String(contentsOf: marker, encoding: .utf8)
        else { return false }
        return value == Self.ownerMarkerValue(runID: runID)
    }

    /// Bounded inspection of REAL per-run pins for the trusted lifecycles
    /// and qualification hosts; run directories that own no marker-verified
    /// child tree (e.g. migration-only trees) are never listed. Never
    /// model-facing.
    public func pinnedRunIDs() -> [UUID] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: runsRoot.path),
              Self.isPlainDirectory(runsRoot),
              let names = try? fileManager.contentsOfDirectory(atPath: runsRoot.path)
        else { return [] }
        var ids: [UUID] = []
        for name in names {
            guard let runID = UUID(uuidString: name) else { continue }
            let directory = runsRoot.appendingPathComponent(name, isDirectory: true)
            guard Self.isPlainDirectory(directory),
                  let children = try? fileManager.contentsOfDirectory(atPath: directory.path),
                  children.contains(where: { !$0.hasPrefix(".") && ownsRealRunPin(
                      snapshotDirectory: directory.appendingPathComponent($0, isDirectory: true),
                      runID: runID) })
            else { continue }
            ids.append(runID)
        }
        return ids.sorted { $0.uuidString < $1.uuidString }
    }

    // MARK: - Filesystem ownership checks (no symlink traversal, ever)

    static func isPlainDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path,
                                             isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            .isSymbolicLink) == false
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
