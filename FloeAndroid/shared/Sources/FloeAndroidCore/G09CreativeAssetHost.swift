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
        let digest = try Self.verifiedStagingDigest(
            staging, byteCount: byteCount, sha256: sha256)
        let ingested = try await ingestVerified(
            staging: staging, digest: digest, fileName: fileName,
            mimeType: mimeType, byteCount: byteCount, candidateID: candidateID)
        return ingested.reference
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
