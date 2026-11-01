// SPDX-License-Identifier: MPL-2.0
//
// G09-R1 — Canvas content-addressed asset ingestion.
//
// Bytes travel from the trusted Android host as an opaque staging token under
// `<acceptedRoot>/FloeAgent/CreativeIncoming`. The JSON bridge never carries
// base64 asset bodies and never accepts a caller path. Ingestion verifies the
// declared size and SHA-256, copies into `FloeAgent/Materials` with an
// exclusive target, and records the canonical row in the EXISTING
// `CreativeAssetStore` (one content hash = one canonical asset).
//
// Physical reclamation is deferred: this package never deletes Materials
// bytes. Reference operations only change durable reference counts.
import Foundation
import Crypto
import FloeCore
import FloePersistence
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Verified, read-only local bytes for one canonical creative asset. Produced
/// ONLY by `G09CreativeAssetHost.verifiedLocalBytes` after the real on-disk
/// file size, containment and digest checks pass. This is the design owner's
/// material read; it never mutates the asset or its reference count.
public struct G09CreativeVerifiedLocalBytes: Sendable, Equatable {
    public let assetID: UUID
    public let data: Data
    public let format: String
    public let displayName: String
    public let contentSHA256: String
    public let byteCount: Int64

    public init(
        assetID: UUID, data: Data, format: String, displayName: String,
        contentSHA256: String, byteCount: Int64
    ) {
        self.assetID = assetID
        self.data = data
        self.format = format
        self.displayName = displayName
        self.contentSHA256 = contentSHA256
        self.byteCount = byteCount
    }
}

/// Result of a source-create ingest that also reports whether this call
/// created the canonical row or merged into an existing content-hash row. The
/// bytes are always the SAME content-addressed row; `deduplicated` is audit
/// data for the caller, never a second storage authority.
public struct G09CreativeIngestOutcome: Sendable, Equatable {
    public let reference: CanvasAssetReference
    public let deduplicated: Bool

    public init(reference: CanvasAssetReference, deduplicated: Bool) {
        self.reference = reference
        self.deduplicated = deduplicated
    }
}

/// Verified creative-library asset created by design-result publication.
public struct G09CreativePublishedDesignAsset: Sendable, Equatable {
    public let assetID: UUID
    public let contentSHA256: String
    public let format: String
    public let displayName: String
    public let byteCount: Int64
    public let relativePath: String

    public init(
        assetID: UUID, contentSHA256: String, format: String,
        displayName: String, byteCount: Int64, relativePath: String
    ) {
        self.assetID = assetID
        self.contentSHA256 = contentSHA256
        self.format = format
        self.displayName = displayName
        self.byteCount = byteCount
        self.relativePath = relativePath
    }
}

public actor G09CreativeAssetHost {
    private let root: RuntimeStorageRoot
    private let store: CreativeAssetStore
    private let fileManager = FileManager.default

    public init(root: RuntimeStorageRoot, store: CreativeAssetStore) {
        self.root = root
        self.store = store
    }

    public nonisolated var incomingDirectoryPath: String {
        root.artifactStoreURL.appendingPathComponent("CreativeIncoming", isDirectory: true).path
    }

    public nonisolated var materialsDirectoryPath: String {
        root.artifactStoreURL.appendingPathComponent("Materials", isDirectory: true).path
    }

    public nonisolated func incomingURL(token: String) -> URL? {
        guard Self.safeStagingToken(token) else { return nil }
        return URL(fileURLWithPath: incomingDirectoryPath, isDirectory: true)
            .appendingPathComponent(token, isDirectory: false)
    }

    public nonisolated func materialsURL(relativePath: String) -> URL? {
        guard let relative = Self.canonicalAssetRelativePath(relativePath) else { return nil }
        let base = URL(fileURLWithPath: materialsDirectoryPath, isDirectory: true)
        let target = base.appendingPathComponent(relative).standardizedFileURL
        guard target.path.hasPrefix(base.standardizedFileURL.path + "/") else { return nil }
        return target
    }

    /// Asset references may be recorded with one leading `Materials/` (the
    /// historical store-relative spelling). The trusted `assetsBasePath`
    /// already ends at Materials, so strip exactly one prefix and never
    /// duplicate it.
    public nonisolated static func canonicalAssetRelativePath(_ raw: String) -> String? {
        guard safeRelativePath(raw) else { return nil }
        if raw.hasPrefix("Materials/") {
            let stripped = String(raw.dropFirst("Materials/".count))
            guard safeRelativePath(stripped), !stripped.isEmpty else { return nil }
            return stripped
        }
        return raw
    }

    // MARK: - Ingestion

    public func ingest(opID: String, token: String, sessionToken: String, fileName: String,
                       mimeType: String?, byteCount: Int64, sha256: String) async throws
        -> G09AssetReceiptDTO {
        guard G09CreativeWire.safeOperationID(opID) else {
            throw G09CreativeError.invalidPayload("invalidOperationID")
        }
        if let receipt = try? readIngestReceipt(opID) {
            guard receipt.sessionDigest == Self.sessionDigest(sessionToken) else {
                throw G09CreativeError.staleSession
            }
            return G09AssetReceiptDTO(
                asset: receipt.asset, deduplicated: receipt.deduplicated,
                opID: receipt.opID, idempotent: true)
        }
        guard G09CreativeWire.validSessionToken(sessionToken),
              token.hasPrefix(sessionToken + "."),
              Self.safeStagingToken(token),
              let staging = incomingURL(token: token) else {
            throw G09CreativeError.assetStagingInvalid
        }
        let digest = try Self.verifiedStagingDigest(
            staging, byteCount: byteCount, sha256: sha256)
        let ingested = try await ingestVerified(
            staging: staging, digest: digest, fileName: fileName,
            mimeType: mimeType, byteCount: byteCount, candidateID: UUID())
        try? fileManager.removeItem(at: staging)
        try? writeIngestReceipt(G09AssetImportReceipt(
            opID: opID, asset: ingested.reference,
            deduplicated: ingested.deduplicated,
            sessionDigest: Self.sessionDigest(sessionToken)))
        return G09AssetReceiptDTO(
            asset: ingested.reference, deduplicated: ingested.deduplicated,
            opID: opID, idempotent: false)
    }

    /// Atomic source-create ingestion: identical verification/copy/dedupe as
    /// the ordinary import, but the caller owns the durable pre-commit intent
    /// and receipt, so this does not write a per-op ingest receipt and does
    /// not delete the staged bytes before the project is published.
    public func ingestForSourceCreate(
        staging: URL, fileName: String, mimeType: String?,
        byteCount: Int64, sha256: String, candidateID: UUID
    ) async throws -> CanvasAssetReference {
        (try await ingestForSourceCreateReportingMerge(
            staging: staging, fileName: fileName, mimeType: mimeType,
            byteCount: byteCount, sha256: sha256, candidateID: candidateID)
        ).reference
    }

    /// Same verified source-create ingest, also reporting whether this call
    /// created the canonical row. Bounded and content-addressed exactly like
    /// the ordinary import; the caller must use the returned canonical id.
    public func ingestForSourceCreateReportingMerge(
        staging: URL, fileName: String, mimeType: String?,
        byteCount: Int64, sha256: String, candidateID: UUID
    ) async throws -> G09CreativeIngestOutcome {
        let digest = try Self.verifiedStagingDigest(
            staging, byteCount: byteCount, sha256: sha256)
        let ingested = try await ingestVerified(
            staging: staging, digest: digest, fileName: fileName,
            mimeType: mimeType, byteCount: byteCount, candidateID: candidateID)
        return G09CreativeIngestOutcome(
            reference: ingested.reference, deduplicated: ingested.deduplicated)
    }

    /// Publishes one verified adopted design result into the EXISTING
    /// content-addressed creative library. The caller has already verified the
    /// payload digest; this method re-checks it, writes only under
    /// `<acceptedRoot>/FloeAgent/Materials`, resolves the canonical row by
    /// content hash (identical bytes are ONE row) and returns only after the
    /// row AND the real contained bytes are read back and hash-verified.
    ///
    /// A losing candidate id never owns the durable file: when the content
    /// merge resolves to a different canonical id, the bytes are ensured at
    /// the CANONICAL id path and the row's path is repaired. The original
    /// source asset/file is never modified or deleted. Physical reclamation
    /// stays deferred like every other Materials write.
    public func publishDesignResult(
        candidateID: UUID,
        bytes: Data,
        format rawFormat: String,
        displayName: String,
        kind: MediaKind,
        mimeType: String?,
        tags: [String]
    ) async throws -> G09CreativePublishedDesignAsset {
        let format = rawFormat.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !format.isEmpty, format.utf8.count <= 16,
              format.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0)
              }) else {
            throw G09CreativeError.assetReferenceInvalid
        }
        guard !bytes.isEmpty else { throw G09CreativeError.assetEmpty }
        guard Int64(bytes.count) <= G09CreativeLimits.assetBytes else {
            throw G09CreativeError.assetTooLarge
        }
        let digest = FloeDigest.sha256Hex(bytes)
        let safeName = Self.safeDisplayName(displayName)
        let safeStem = (safeName as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = safeStem.isEmpty ? "asset" : safeStem
        let candidateRelative =
            "\(candidateID.uuidString)-design-\(baseName).\(format)"
        guard let candidateURL = materialsURL(relativePath: candidateRelative) else {
            throw G09CreativeError.assetReferenceInvalid
        }

        var canonical: CreativeAssetRecord
        let existingRecord = (try? await store.asset(contentHash: digest)) ?? nil
        if let existingRecord {
            canonical = existingRecord
        } else {
            try writeVerifiedFile(bytes, to: candidateURL, digest: digest)
            let candidate = CreativeAssetRecord(
                id: candidateID, contentHash: digest, kind: kind,
                displayName: safeName, mimeType: mimeType,
                localRelativePath: candidateRelative,
                byteCount: Int64(bytes.count), tags: tags,
                referenceCount: 0, createdAt: Date(), updatedAt: Date())
            do {
                canonical = try await store.saveResolvingCanonical(candidate)
            } catch {
                // The row was not created, so this exact file is unreferenced.
                try? fileManager.removeItem(at: candidateURL)
                throw G09CreativeError.storageUnavailable
            }
        }
        guard canonical.contentHash.caseInsensitiveCompare(digest)
            == .orderedSame else {
            throw G09CreativeError.assetDigestMismatch
        }

        let storedRelative = canonical.localRelativePath.flatMap {
            $0.isEmpty ? nil : $0
        }
        let cleanStored = storedRelative.flatMap(Self.canonicalAssetRelativePath)
        let canonicalRelative: String
        if let cleanStored, !cleanStored.isEmpty,
           !(cleanStored as NSString).pathExtension.isEmpty {
            canonicalRelative = cleanStored
        } else {
            let canonicalName = Self.safeDisplayName(
                canonical.displayName.isEmpty ? safeName : canonical.displayName)
            let canonicalStem = (canonicalName as NSString)
                .deletingPathExtension
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let canonicalBase = canonicalStem.isEmpty ? "asset" : canonicalStem
            canonicalRelative =
                "\(canonical.id.uuidString)-design-\(canonicalBase).\(format)"
        }
        guard let canonicalURL = materialsURL(relativePath: canonicalRelative) else {
            throw G09CreativeError.assetReferenceInvalid
        }

        // Ensure EXACTLY the verified bytes live at the canonical row path.
        // An existing correct file is reused; a missing/partial/corrupt file
        // is repaired atomically and verified again. The row is kept so a
        // retry can finish.
        try ensureVerifiedBytes(bytes, at: canonicalURL, digest: digest)

        if cleanStored != canonicalRelative {
            var repaired = canonical
            repaired.localRelativePath = canonicalRelative
            repaired.updatedAt = Date()
            do {
                try await store.save(repaired)
            } catch {
                throw G09CreativeError.storageUnavailable
            }
            canonical = repaired
        }

        // Remove ONLY the losing candidate copy this call created, and only
        // when the canonical row does not point at it. A foreign canonical
        // asset is never deleted.
        if canonicalURL.path != candidateURL.path,
           FileManager.default.fileExists(atPath: candidateURL.path),
           canonical.id != candidateID {
            try? fileManager.removeItem(at: candidateURL)
        }

        guard let readback = try? await store.asset(id: canonical.id),
              readback.contentHash.caseInsensitiveCompare(digest)
                == .orderedSame else {
            throw G09CreativeError.assetDigestMismatch
        }
        let fileDigest = try verifiedFileDigest(
            canonicalURL, expectedByteCount: bytes.count)
        guard fileDigest.caseInsensitiveCompare(digest) == .orderedSame else {
            throw G09CreativeError.assetDigestMismatch
        }
        return G09CreativePublishedDesignAsset(
            assetID: readback.id,
            contentSHA256: digest,
            format: format,
            displayName: readback.displayName.isEmpty
                ? safeName : readback.displayName,
            byteCount: Int64(bytes.count),
            relativePath: canonicalRelative)
    }

    /// Writes the payload atomically and verifies the read-back bytes.
    private func writeVerifiedFile(
        _ bytes: Data, to url: URL, digest: String
    ) throws {
        do {
            try G09R2DesignFileIO.writeAtomically(bytes, to: url)
        } catch {
            throw G09CreativeError.writeFailed
        }
        let actual = try verifiedFileDigest(
            url, expectedByteCount: bytes.count)
        guard actual.caseInsensitiveCompare(digest) == .orderedSame else {
            throw G09CreativeError.assetDigestMismatch
        }
    }

    private func ensureVerifiedBytes(
        _ bytes: Data, at url: URL, digest: String
    ) throws {
        if let actual = try? verifiedFileDigest(
            url, expectedByteCount: bytes.count),
           actual.caseInsensitiveCompare(digest) == .orderedSame {
            return
        }
        try writeVerifiedFile(bytes, to: url, digest: digest)
    }

    /// Bounded read-back digest: the REAL file must be a regular file of the
    /// exact expected size, then the streamed SHA-256 must match.
    private func verifiedFileDigest(
        _ url: URL, expectedByteCount: Int
    ) throws -> String {
        guard expectedByteCount >= 0,
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              size == Int64(expectedByteCount) else {
            throw G09CreativeError.assetDigestMismatch
        }
        do {
            return try FloeDigest.sha256Hex(ofFileAt: url)
        } catch {
            throw G09CreativeError.assetStagingUnavailable
        }
    }

    /// Current canonical reference for an existing asset row, or nil when the
    /// row is gone. Used only to complete an already-committed source-create
    /// retry without re-reading staged bytes.
    public func reference(id: UUID) async -> CanvasAssetReference? {
        guard let record = try? await store.asset(id: id) else { return nil }
        return Self.reference(record)
    }

    public func recordHasDigest(id: UUID, sha256: String) async -> Bool {
        guard let record = try? await store.asset(id: id) else { return false }
        return record.contentHash.caseInsensitiveCompare(sha256) == .orderedSame
    }

    /// Verifies declared size + digest against the actual staged bytes. A
    /// mismatch is refused before any Materials byte or DB row is written.
    nonisolated static func verifiedStagingDigest(
        _ staging: URL, byteCount: Int64, sha256: String
    ) throws -> String {
        guard byteCount > 0 else { throw G09CreativeError.assetEmpty }
        guard byteCount <= G09CreativeLimits.assetBytes else {
            throw G09CreativeError.assetTooLarge
        }
        guard let size = try? staging.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(size) == byteCount else {
            throw G09CreativeError.assetStagingInvalid
        }
        guard validDigest(sha256) else {
            throw G09CreativeError.assetStagingInvalid
        }
        let actual: String
        do {
            actual = try FloeDigest.sha256Hex(ofFileAt: staging)
        } catch {
            throw G09CreativeError.assetStagingUnavailable
        }
        guard actual.caseInsensitiveCompare(sha256) == .orderedSame else {
            throw G09CreativeError.assetDigestMismatch
        }
        return actual
    }

    private func ingestVerified(
        staging: URL, digest: String, fileName: String, mimeType: String?,
        byteCount: Int64, candidateID: UUID
    ) async throws -> (reference: CanvasAssetReference, deduplicated: Bool) {
        let displayName = Self.safeDisplayName(fileName)
        let kind = Self.mediaKind(fileName: displayName, mimeType: mimeType)
        let existingRecord = (try? await store.asset(contentHash: digest)) ?? nil
        if let existing = existingRecord {
            // Repair a missing canonical file from the verified staged copy.
            if let relative = existing.localRelativePath,
               let target = materialsURL(relativePath: relative),
               !fileManager.fileExists(atPath: target.path) {
                try copyVerifying(from: staging, to: target)
            }
            return (Self.reference(existing), true)
        }

        let relative = "\(candidateID.uuidString)-\(displayName)"
        guard let target = materialsURL(relativePath: relative) else {
            throw G09CreativeError.assetStagingInvalid
        }
        try copyVerifying(from: staging, to: target)
        let candidate = CreativeAssetRecord(
            id: candidateID, contentHash: digest, kind: kind,
            displayName: displayName, mimeType: mimeType,
            localRelativePath: relative, byteCount: byteCount,
            referenceCount: 0)
        do {
            let canonical = try await store.saveResolvingCanonical(candidate)
            if canonical.id != candidateID {
                // A concurrent identical ingest won the canonical row. Keep
                // the canonical bytes and remove only this losing copy.
                if let canonicalPath = canonical.localRelativePath,
                   canonicalPath != relative {
                    try? fileManager.removeItem(at: target)
                }
            }
            return (Self.reference(canonical), false)
        } catch {
            try? fileManager.removeItem(at: target)
            throw G09CreativeError.storageUnavailable
        }
    }

    private nonisolated var receiptDirectory: URL {
        URL(fileURLWithPath: root.artifactStoreURL
            .appendingPathComponent("CanvasRecovery", isDirectory: true).path,
             isDirectory: true)
            .appendingPathComponent("AssetReceipts", isDirectory: true)
    }

    public func readIngestReceipt(_ opID: String) throws -> G09AssetImportReceipt {
        guard G09CreativeWire.safeOperationID(opID) else {
            throw G09CreativeError.invalidPayload("invalidOperationID")
        }
        let url = receiptDirectory.appendingPathComponent("\(opID).json")
        guard let data = try? Data(contentsOf: url),
              let receipt = try? G09CreativeWire.decoder().decode(
                G09AssetImportReceipt.self, from: data) else {
            throw G09CreativeError.assetMissing
        }
        return receipt
    }

    private func writeIngestReceipt(_ receipt: G09AssetImportReceipt) throws {
        do {
            try fileManager.createDirectory(at: receiptDirectory,
                                            withIntermediateDirectories: true)
            let data = try G09CreativeWire.encoder().encode(receipt)
            let url = receiptDirectory.appendingPathComponent("\(receipt.opID).json")
            let temporary = receiptDirectory.appendingPathComponent(
                ".floe-asset-receipt-\(UUID().uuidString).tmp")
            defer { try? fileManager.removeItem(at: temporary) }
            try data.write(to: temporary, options: [])
            try fsyncFile(temporary)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: url)
            }
        } catch let typed as G09CreativeError {
            throw typed
        } catch {
            throw G09CreativeError.writeFailed
        }
    }

    public func discard(token: String) throws {
        guard let staging = incomingURL(token: token) else {
            throw G09CreativeError.assetStagingInvalid
        }
        if fileManager.fileExists(atPath: staging.path) {
            do {
                try fileManager.removeItem(at: staging)
            } catch {
                throw G09CreativeError.assetStagingUnavailable
            }
        }
    }

    /// Removes an abandoned staging file. Only the exact token path under
    /// CreativeIncoming is touched; a missing file is an idempotent success.
    public func discardIfPresent(token: String) {
        guard let staging = incomingURL(token: token) else { return }
        try? fileManager.removeItem(at: staging)
    }

    // MARK: - Validation

    /// A patch may only reference an existing Materials record. CAD/design
    /// metadata is preserved read-only but never allowed to smuggle an
    /// arbitrary filesystem path into a node asset.
    public func validateAssetReference(_ asset: CanvasAssetReference) async throws {
        guard Self.safeRelativePath(asset.localRelativePath) else {
            throw G09CreativeError.assetReferenceInvalid
        }
        guard let rawRelative = asset.localRelativePath,
              let relative = Self.canonicalAssetRelativePath(rawRelative) else {
            // Cloud-only references carry no local path and no storage
            // authority; they are preserved but never resolved here.
            if asset.localRelativePath == nil { return }
            throw G09CreativeError.assetReferenceInvalid
        }
        let existingRecord = (try? await store.asset(id: asset.id)) ?? nil
        guard let record = existingRecord else {
            // CAD/design package references are not CreativeAssetStore rows.
            // They are preserved read-only only when the path stays a plain
            // relative Materials path and the reference is explicitly opaque
            // (no content hash); a forged hashed reference is refused.
            if asset.contentHash == nil && !relative.contains("/") { return }
            throw G09CreativeError.assetMissing
        }
        if let hash = asset.contentHash,
           hash.caseInsensitiveCompare(record.contentHash) != .orderedSame {
            throw G09CreativeError.assetReferenceInvalid
        }
        guard let recordPath = record.localRelativePath,
              recordPath == relative else {
            throw G09CreativeError.assetReferenceInvalid
        }
    }

    public func record(id: UUID) async -> CreativeAssetRecord? {
        try? await store.asset(id: id)
    }

    /// Reads one canonical asset's local bytes for the DESIGN owner.
    ///
    /// Authority is the existing `CreativeAssetStore` row plus the actual
    /// contained file under `<acceptedRoot>/FloeAgent/Materials`:
    ///  * the recorded relative path must be a safe, contained relative path;
    ///  * the real on-disk file size is capped BEFORE any read (a stale row
    ///    byteCount is never accepted as the cap);
    ///  * the read is bounded again and its SHA-256 must equal the row hash;
    ///  * the format comes from the actual file extension, never a guess.
    ///
    /// The method is read-only: it never mutates the row, reference count or
    /// bytes. Cloud-only rows (no local path) are a typed miss, not a fabricated
    /// download.
    public func verifiedLocalBytes(
        id: UUID,
        maximumBytes: Int64 = G09R2CreativeLimits.designSourceBytes
    ) async throws -> G09CreativeVerifiedLocalBytes {
        guard maximumBytes > 0 else {
            throw G09CreativeError.invalidPayload("invalidAssetByteCap")
        }
        guard let record = try? await store.asset(id: id) else {
            throw G09CreativeError.assetMissing
        }
        guard let rawRelative = record.localRelativePath, !rawRelative.isEmpty else {
            throw G09CreativeError.assetMissing
        }
        guard let relative = Self.canonicalAssetRelativePath(rawRelative),
              let url = materialsURL(relativePath: relative) else {
            throw G09CreativeError.assetReferenceInvalid
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let fileSize = (attributes[.size] as? NSNumber)?.int64Value else {
            throw G09CreativeError.assetMissing
        }
        guard fileSize > 0 else { throw G09CreativeError.assetEmpty }
        guard fileSize <= maximumBytes else {
            throw G09CreativeError.assetTooLarge
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw G09CreativeError.assetStagingUnavailable
        }
        guard !data.isEmpty else { throw G09CreativeError.assetEmpty }
        guard Int64(data.count) <= maximumBytes else {
            throw G09CreativeError.assetTooLarge
        }
        let digest = FloeDigest.sha256Hex(data)
        guard digest.caseInsensitiveCompare(record.contentHash) == .orderedSame else {
            throw G09CreativeError.assetDigestMismatch
        }
        let format = (relative as NSString).pathExtension.lowercased()
        guard !format.isEmpty else {
            throw G09CreativeError.assetReferenceInvalid
        }
        return G09CreativeVerifiedLocalBytes(
            assetID: record.id,
            data: data,
            format: format,
            displayName: record.displayName,
            contentSHA256: digest,
            byteCount: Int64(data.count))
    }

    public func applyReferenceOp(opID: String, assetID: UUID, delta: Int) async throws {
        guard delta != 0 else { return }
        do {
            try await store.applyReferenceOp(opID: opID, assetID: assetID, delta: delta)
        } catch {
            throw G09CreativeError.map(error)
        }
    }

    // MARK: - Static guards

    public nonisolated static func safeRelativePath(_ raw: String?) -> Bool {
        guard let raw else { return true }
        guard !raw.isEmpty, raw.utf8.count <= 1024,
              !raw.hasPrefix("/"), !raw.hasPrefix("\\"),
              !raw.contains("\\"), !raw.contains("\u{0}") else { return false }
        let components = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        for component in components {
            guard !component.isEmpty, component != ".", component != ".." else {
                return false
            }
            if component.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            }) { return false }
        }
        return true
    }

    public nonisolated static func safeStagingToken(_ raw: String) -> Bool {
        !raw.isEmpty && raw.utf8.count <= G09CreativeLimits.stagingTokenBytes &&
            !raw.hasPrefix(".") &&
            raw.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "."
            }
    }

    public nonisolated static func validDigest(_ raw: String) -> Bool {
        raw.count == 64 && raw.unicodeScalars.allSatisfy {
            ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") || ($0 >= "A" && $0 <= "F")
        }
    }

    public nonisolated static func sessionDigest(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public nonisolated static func safeDisplayName(_ raw: String) -> String {
        let base = (raw as NSString).lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_. "))
        var cleaned = String(base.unicodeScalars.filter { allowed.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { cleaned = "asset" }
        if cleaned.utf8.count > 96 {
            let ext = (cleaned as NSString).pathExtension
            let stem = (cleaned as NSString).deletingPathExtension
            let suffix = ext.isEmpty ? "" : "." + String(ext.prefix(12))
            cleaned = String(stem.prefix(max(1, 96 - suffix.utf8.count))) + suffix
        }
        return cleaned
    }

    /// Canvas node kind for a staged source when the trusted host did not
    /// supply an explicit byte-derived kind. This only chooses the node's
    /// presentation; it never grants storage or bypasses the CAS.
    public nonisolated static func canvasNodeKind(fileName: String,
                                                  mimeType: String?) -> CanvasNodeKind {
        let mime = (mimeType ?? "").lowercased()
        if mime.hasPrefix("image/") { return .image }
        if mime.hasPrefix("video/") { return .video }
        if mime.hasPrefix("audio/") { return .audio }
        switch (fileName as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "bmp", "tiff": return .image
        case "mp4", "mov", "m4v", "webm": return .video
        case "mp3", "m4a", "wav", "aac", "flac": return .audio
        default: return .file
        }
    }

    private nonisolated static func mediaKind(fileName: String, mimeType: String?) -> MediaKind {
        let mime = (mimeType ?? "").lowercased()
        if mime.hasPrefix("image/") { return .image }
        if mime.hasPrefix("video/") { return .video }
        if mime.hasPrefix("audio/") { return .audio }
        switch (fileName as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "bmp", "tiff": return .image
        case "mp4", "mov", "m4v", "webm": return .video
        case "mp3", "m4a", "wav", "aac", "flac": return .audio
        default: return .document
        }
    }

    private nonisolated static func reference(_ record: CreativeAssetRecord) -> CanvasAssetReference {
        CanvasAssetReference(
            id: record.id, contentHash: record.contentHash,
            localRelativePath: record.localRelativePath,
            cloudRecordName: record.cloudRecordName,
            mimeType: record.mimeType, byteCount: record.byteCount,
            sourceURL: record.sourceURL, license: record.license)
    }

    private func copyVerifying(from source: URL, to target: URL) throws {
        let directory = target.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".floe-asset-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        do {
            try fileManager.copyItem(at: source, to: temporary)
            try fsyncFile(temporary)
            if fileManager.fileExists(atPath: target.path) {
                // Never overwrite existing canonical bytes under a different
                // content hash; the caller already resolved the canonical row.
                try fileManager.removeItem(at: temporary)
                return
            }
            try fileManager.moveItem(at: temporary, to: target)
        } catch {
            throw G09CreativeError.assetStagingUnavailable
        }
    }

    private func fsyncFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw G09CreativeError.assetStagingUnavailable }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw G09CreativeError.assetStagingUnavailable
        }
    }
}
