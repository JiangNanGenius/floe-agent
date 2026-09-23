// FloeExecution — Runtime v2 content-addressed blob store.
//
// Every verified image artifact (BIOS, kernel, initrd, base rootfs, runner)
// lives exactly once under images/blobs/sha512/<prefix>/<digest>. Identical
// content is never duplicated: ingest of an already-present digest verifies
// and reuses the existing blob. Blobs are read-only (mode 0444) so nothing —
// including a VM with a raw RW view of a cloned file — can mutate the shared
// base. Ingest always stages into cache/staging first, verifies size and
// SHA-512, and only then renames atomically into the store; a digest mismatch
// never reaches the store. Reference counts in the registry protect blobs
// from garbage collection while any manifest still points at them.

import Foundation
import FloeCore

public actor RuntimeV2BlobStore {
    /// Injectable host seam so the clone-vs-copy outcome is a real observation
    /// in tests on volumes where clonefile cannot be exercised directly.
    public struct Seams: Sendable {
        public var cloneFile: @Sendable (String, String) -> Bool

        public init(cloneFile: @escaping @Sendable (String, String) -> Bool) {
            self.cloneFile = cloneFile
        }

        public static let production = Seams(cloneFile: { source, destination in
            #if canImport(Darwin)
            return clonefile(source, destination, 0) == 0
            #else
            return false
            #endif
        })
    }

    /// What `materialize` actually did. `mode` is the syscall outcome, never
    /// inferred from any byte accounting.
    public struct MaterializeReport: Sendable, Equatable {
        public enum Mode: String, Sendable {
            /// APFS copy-on-write clone of the blob (no byte copy).
            case clone
            /// Space-checked byte-copy fallback.
            case copy
        }

        public var mode: Mode
        public var logicalBytes: Int64
        public var allocatedBytes: Int64?

        public init(mode: Mode, logicalBytes: Int64, allocatedBytes: Int64?) {
            self.mode = mode
            self.logicalBytes = logicalBytes
            self.allocatedBytes = allocatedBytes
        }
    }

    private let layout: RuntimeV2Layout
    private let registry: RuntimeV2Registry
    private let seams: Seams
    private var fileManager: FileManager { .default }

    public init(layout: RuntimeV2Layout, registry: RuntimeV2Registry, seams: Seams = .production) {
        self.layout = layout
        self.registry = registry
        self.seams = seams
    }

    /// Ingests `sourceURL` as the blob for `expectedSHA512` AND takes the one
    /// reference that names this owner. Returns the digest on success. Never
    /// mutates an existing blob in place: identical content is reused, corrupt
    /// existing content is moved to quarantine before the staged replacement
    /// lands.
    ///
    /// The ingest is claim-protected end to end: a durable staged-ownership
    /// claim is taken BEFORE the bytes become visible, and the reference
    /// conversion (`claimBlobReference`) commits in ONE transaction — so blob
    /// GC can never reclaim the bytes between placement and reference, even
    /// when the blob row pre-existed (an old released row is immediately
    /// collectable again). After the reference commits, the bytes are proven
    /// present at the canonical path (restoring from quarantine or re-copying
    /// from `sourceURL` when a racing GC claimed the row first).
    @discardableResult
    public func ingest(
        sourceURL: URL,
        expectedSHA512: String,
        expectedBytes: Int64,
        retainFor imageID: String?
    ) async throws -> String {
        let digest = expectedSHA512.lowercased()
        try await registry.takeBlobStagingClaim(digest: digest, bytes: expectedBytes)
        do {
            let placed = try await place(
                sourceURL: sourceURL, expectedSHA512: expectedSHA512, expectedBytes: expectedBytes
            )
            try await registry.claimBlobReference(digest: placed, bytes: expectedBytes)
            try await ensureBlobPresent(digest: placed, sourceURL: sourceURL)
            return placed
        } catch {
            try? await registry.releaseBlobStagingClaim(digest: digest)
            throw error
        }
    }

    /// Places and fully verifies the blob WITHOUT taking a reference. The
    /// caller must take the reference in the same transaction that records the
    /// durable owner (`RuntimeV2Registry.recordTemplateIngest`), so a crash can
    /// never leave a reference nobody owns.
    ///
    /// The stage is claim-protected: a durable staged-ownership claim is taken
    /// BEFORE the bytes are placed, so a concurrent `collectGarbage` can never
    /// delete the physical bytes or the row between placement and the
    /// registration transaction — the claim (not a re-check after an await) is
    /// what refuses the GC claim inside its own transaction. The caller
    /// converts the claim via `recordTemplateIngest` (or releases it with
    /// `releaseStagingClaim` on the compensating path).
    @discardableResult
    public func stageUnreferenced(
        sourceURL: URL,
        expectedSHA512: String,
        expectedBytes: Int64
    ) async throws -> String {
        let digest = expectedSHA512.lowercased()
        try await registry.takeBlobStagingClaim(digest: digest, bytes: expectedBytes)
        do {
            return try await place(
                sourceURL: sourceURL, expectedSHA512: expectedSHA512, expectedBytes: expectedBytes
            )
        } catch {
            try? await registry.releaseBlobStagingClaim(digest: digest)
            throw error
        }
    }

    /// Compensating path for a stage that never reached its reference: releases
    /// exactly the one claim `stageUnreferenced` took (clamped, idempotent).
    public func releaseStagingClaim(digest: String) async {
        try? await registry.releaseBlobStagingClaim(digest: digest.lowercased())
    }

    /// Proves the referenced bytes exist at the canonical path after the
    /// reference committed. A racing GC can have reclaimed the row and moved
    /// the bytes to quarantine in the tiny window before the reference
    /// committed; content addressing makes every copy identical, so the bytes
    /// are first restored from the deterministic quarantine slot and only
    /// re-copied from the caller's `sourceURL` when no quarantine copy exists.
    /// Throws `blobMissing` only when neither source has the bytes.
    public func ensureBlobPresent(digest: String, sourceURL: URL) async throws {
        let normalized = digest.lowercased()
        let canonical = try layout.blobURL(digest: normalized)
        if fileManager.fileExists(atPath: canonical.path) { return }
        restoreBlobFromQuarantine(digest: normalized, canonical: canonical)
        if fileManager.fileExists(atPath: canonical.path) { return }
        // No quarantine copy: re-place from the caller's own verified source.
        try fileManager.createDirectory(at: canonical.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: sourceURL, to: canonical)
        let actual = try FloeDigest.sha512Hex(ofFileAt: canonical)
        guard actual == normalized else {
            try? fileManager.removeItem(at: canonical)
            throw RuntimeV2Error.blobDigestMismatch(expected: normalized, actual: actual)
        }
        try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: canonical.path)
    }

    /// Restores a reclaimed blob's bytes from the deterministic quarantine
    /// slot when the canonical path is empty. Content addressing makes the
    /// quarantine copy exactly the referenced bytes. Best effort: any failure
    /// leaves the quarantine copy untouched for a later retry.
    private func restoreBlobFromQuarantine(digest: String, canonical: URL) {
        guard let quarantine = try? layout.blobQuarantineURL(digest: digest),
              fileManager.fileExists(atPath: quarantine.path) else { return }
        try? fileManager.createDirectory(at: canonical.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: canonical.path) {
            // A racing stage already re-placed identical bytes; drop ours.
            try? fileManager.removeItem(at: quarantine)
            return
        }
        if rename(quarantine.path, canonical.path) != 0 {
            do {
                try fileManager.copyItem(at: quarantine, to: canonical)
                try fileManager.removeItem(at: quarantine)
            } catch {
                return
            }
        }
        try? fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: canonical.path)
    }

    private func place(
        sourceURL: URL, expectedSHA512: String, expectedBytes: Int64
    ) async throws -> String {
        let digest = expectedSHA512.lowercased()
        let destination = try layout.blobURL(digest: digest)

        let staged = layout.cacheDirectory(kind: "staging")
            .appendingPathComponent("blob-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staged) }

        if fileManager.fileExists(atPath: destination.path) {
            let size = (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? -1
            if size == expectedBytes {
                // Content addressing: an existing blob of the right digest and
                // size was verified at its own ingest; reuse it.
                try await registry.recordBlob(digest: digest, bytes: expectedBytes)
                return digest
            }
            // Size disagreement under the same digest means the store was
            // damaged externally: quarantine the file, then stage fresh.
            let quarantine = layout.quarantineDirectory
                .appendingPathComponent("blob-\(digest.prefix(16))-\(UUID().uuidString)")
            try? fileManager.moveItem(at: destination, to: quarantine)
        }

        try requireFreeSpace(bytes: expectedBytes * 2 + (32 << 20))
        try fileManager.copyItem(at: sourceURL, to: staged)
        let stagedSize = (try fileManager.attributesOfItem(atPath: staged.path)[.size] as? Int64) ?? -1
        guard stagedSize == expectedBytes else {
            throw RuntimeV2Error.blobDigestMismatch(
                expected: "\(digest) (\(expectedBytes) bytes)",
                actual: "size \(stagedSize)"
            )
        }
        let actualDigest = try FloeDigest.sha512Hex(ofFileAt: staged)
        guard actualDigest == digest else {
            throw RuntimeV2Error.blobDigestMismatch(expected: digest, actual: actualDigest)
        }
        // Read-only shared base: no writer, not even the owner.
        try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: staged.path)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard rename(staged.path, destination.path) == 0 else {
            throw RuntimeV2Error.migrationFailed(
                id: "blob-\(digest.prefix(16))",
                phase: "copied",
                reason: "rename into the blob store failed (errno \(errno))"
            )
        }
        try await registry.recordBlob(digest: digest, bytes: expectedBytes)
        return digest
    }

    /// Releases one manifest's reference to a blob.
    public func release(digest: String) async throws {
        try await registry.adjustBlobRefs(digest: digest, delta: -1)
    }

    public func blobExists(digest: String) throws -> Bool {
        let url = try layout.blobURL(digest: digest)
        return fileManager.fileExists(atPath: url.path)
    }

    /// The read-only path of a blob that provably exists. Callers that clone
    /// straight from the store (template builds clone the parent's blob disk
    /// without a second materialization) still get a missing-blob error
    /// instead of a silent empty file.
    public func verifiedBlobURL(digest: String) throws -> URL {
        let normalized = digest.lowercased()
        let url = try layout.blobURL(digest: normalized)
        if !fileManager.fileExists(atPath: url.path) {
            // The bytes may have been reclaimed into the deterministic
            // quarantine slot between verified references; restore them.
            restoreBlobFromQuarantine(digest: normalized, canonical: url)
        }
        guard fileManager.fileExists(atPath: url.path) else {
            throw RuntimeV2Error.blobMissing(digest)
        }
        return url
    }

    /// Full re-verification of a blob (used by recovery scans and expansion).
    public func verify(digest: String) async throws {
        let normalized = digest.lowercased()
        let url = try layout.blobURL(digest: normalized)
        if !fileManager.fileExists(atPath: url.path) {
            restoreBlobFromQuarantine(digest: normalized, canonical: url)
        }
        guard fileManager.fileExists(atPath: url.path) else {
            throw RuntimeV2Error.blobMissing(digest)
        }
        let actual = try FloeDigest.sha512Hex(ofFileAt: url)
        guard actual == digest.lowercased() else {
            try await registry.adjustBlobRefs(digest: digest, delta: 0)
            throw RuntimeV2Error.blobDigestMismatch(expected: digest, actual: actual)
        }
    }

    /// Materializes a blob at `destination` as a copy-on-write clone (APFS
    /// clonefile, byte-copy fallback). The clone is writable only when
    /// `writable` is set — boot artifacts stay read-only like their blob.
    /// Returns the mode that ACTUALLY ran (the syscall outcome, never inferred
    /// from sparse-file accounting) plus this file's measured bytes.
    @discardableResult
    public func materialize(
        digest: String, at destination: URL, writable: Bool = false
    ) throws -> MaterializeReport {
        let normalized = digest.lowercased()
        let blob = try layout.blobURL(digest: normalized)
        if !fileManager.fileExists(atPath: blob.path) {
            restoreBlobFromQuarantine(digest: normalized, canonical: blob)
        }
        guard fileManager.fileExists(atPath: blob.path) else {
            throw RuntimeV2Error.blobMissing(digest)
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        let mode: MaterializeReport.Mode
        if seams.cloneFile(blob.path, destination.path) {
            mode = .clone
        } else {
            try fileManager.copyItem(at: blob, to: destination)
            mode = .copy
        }
        try fileManager.setAttributes(
            [.posixPermissions: writable ? 0o644 : 0o444],
            ofItemAtPath: destination.path
        )
        let bytes = RuntimeV2FileBytes.measure(fileAt: destination)
        return MaterializeReport(
            mode: mode, logicalBytes: bytes.logicalBytes, allocatedBytes: bytes.allocatedBytes
        )
    }

    /// Deletes unreferenced blobs older than `grace`. Referenced or staged
    /// blobs are never collected; per-blob failures are skipped, not fatal.
    ///
    /// Collection is linearized against acquire (stage/ingest) through ONE
    /// registry transaction per blob: `collectBlobIfUnreferenced` deletes the
    /// row only when it is STILL `refs = 0 AND staged = 0` inside the
    /// transaction, so a reference or staging claim that lands after the
    /// candidate listing refuses the delete and the physical bytes are left
    /// untouched. When the row delete commits, the physical bytes are MOVED to
    /// the deterministic per-digest quarantine slot (never hard-deleted): a
    /// racing stage that already re-created the row from identical content
    /// loses nothing, because the bytes stay recoverable until a verified
    /// reader restores or re-places them.
    @discardableResult
    public func collectGarbage(grace: TimeInterval = 7 * 24 * 3600, now: Date = Date()) async throws -> Int64 {
        let cutoff = now.addingTimeInterval(-grace)
        let candidates = try await registry.unreferencedBlobs(olderThan: cutoff)
        var reclaimed: Int64 = 0
        for blob in candidates {
            guard let url = try? layout.blobURL(digest: blob.digest) else { continue }
            guard try await registry.collectBlobIfUnreferenced(digest: blob.digest) else { continue }
            reclaimed += blob.bytes
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let quarantine = (try? layout.blobQuarantineURL(digest: blob.digest)) ?? layout.quarantineDirectory
                .appendingPathComponent("blob-\(blob.digest)-\(UUID().uuidString)")
            try? fileManager.createDirectory(at: quarantine.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: quarantine.path) {
                // A stale quarantine copy of the same content-addressed bytes:
                // identical content, so it can be replaced.
                try? fileManager.removeItem(at: quarantine)
            }
            // chmod back to writable so the move succeeds, then quarantine.
            try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            do {
                try fileManager.moveItem(at: url, to: quarantine)
            } catch {
                // The row is gone but the bytes stay at the canonical path:
                // harmless (a later stage reuses them) and still recoverable.
                continue
            }
        }
        return reclaimed
    }

    private func requireFreeSpace(bytes: Int64) throws {
        let values = try layout.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? Int64.max
        guard available >= bytes else {
            throw RuntimeV2Error.insufficientSpace(required: bytes, available: available)
        }
    }
}
