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
    @discardableResult
    public func ingest(
        sourceURL: URL,
        expectedSHA512: String,
        expectedBytes: Int64,
        retainFor imageID: String?
    ) async throws -> String {
        let digest = try await place(
            sourceURL: sourceURL, expectedSHA512: expectedSHA512, expectedBytes: expectedBytes
        )
        try await registry.adjustBlobRefs(digest: digest, delta: 1)
        return digest
    }

    /// Places and fully verifies the blob WITHOUT taking a reference. The
    /// caller must take the reference in the same transaction that records the
    /// durable owner (`RuntimeV2Registry.recordTemplateIngest`), so a crash can
    /// never leave a reference nobody owns. A placed-but-unreferenced blob is
    /// recorded with refs 0 and is reclaimable by blob GC.
    @discardableResult
    public func stageUnreferenced(
        sourceURL: URL,
        expectedSHA512: String,
        expectedBytes: Int64
    ) async throws -> String {
        try await place(
            sourceURL: sourceURL, expectedSHA512: expectedSHA512, expectedBytes: expectedBytes
        )
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
        let url = try layout.blobURL(digest: digest)
        guard fileManager.fileExists(atPath: url.path) else {
            throw RuntimeV2Error.blobMissing(digest)
        }
        return url
    }

    /// Full re-verification of a blob (used by recovery scans and expansion).
    public func verify(digest: String) async throws {
        let url = try layout.blobURL(digest: digest)
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
        let blob = try layout.blobURL(digest: digest)
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

    /// Deletes unreferenced blobs older than `grace`. Referenced blobs are
    /// never collected; per-blob failures are skipped, not fatal.
    @discardableResult
    public func collectGarbage(grace: TimeInterval = 7 * 24 * 3600, now: Date = Date()) async throws -> Int64 {
        let cutoff = now.addingTimeInterval(-grace)
        let candidates = try await registry.unreferencedBlobs(olderThan: cutoff)
        var reclaimed: Int64 = 0
        for blob in candidates {
            guard let url = try? layout.blobURL(digest: blob.digest) else { continue }
            // Refuse collection the moment anything still references the row.
            guard let current = try await registry.blob(digest: blob.digest), current.refs == 0 else { continue }
            do {
                // chmod back to writable so the delete succeeds.
                try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
                try fileManager.removeItem(at: url)
                try await registry.removeBlobRecord(digest: blob.digest)
                reclaimed += blob.bytes
            } catch {
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
