// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeTools
import FloeWorkspace

/// Bounded ingestion of unconfirmed UI text into an ORIGINAL workspace
/// recovery file. This does not open/evict an editor document or invent a
/// native revision. Only complete, digest-matching bytes are committed;
/// the original file is never a write target. Actual disk read-back, not
/// the upload buffer, proves preservation. Retry uses the same recovery ID.
actor G04ProjectionRecovery {
    private struct Upload: Sendable {
        let owner: G04WorkspaceOwner
        let recoveryID: UUID
        let path: String
        let count: Int
        let digest: String
        var bytes = Data()
    }
    private let epoch: UInt64
    private let access: any G04WorkspaceAccessPort
    private var retired = false
    private var uploads: [UUID: Upload] = [:]
    static let operations: Set<G04WorkspaceWireRequest.Operation> = [
        .beginProjectionRecovery, .appendProjectionRecovery, .commitProjectionRecovery, .cancelProjectionRecovery]

    init(epoch: UInt64, access: any G04WorkspaceAccessPort) { self.epoch = epoch; self.access = access }

    private func leased<T: Sendable>(owner: G04WorkspaceOwner, intent: G04WorkspaceIntent, path: String?,
                                    _ body: (WorkspaceFileService, CancellationToken) throws -> T) async throws -> T {
        guard !retired, owner.epoch == epoch else { throw G04DocumentError.retired }
        let lease = try await access.acquire(owner: owner, intent: intent, relativePath: path)
        do {
            guard !retired else { throw G04DocumentError.retired }
            try Task.checkCancellation(); try lease.cancellation.throwIfCancelled()
            let result = try body(lease.service, lease.cancellation)
            await lease.release()
            return result
        } catch { await lease.release(); throw error }
    }

    func execute(_ request: G04WorkspaceWireRequest, owner: G04WorkspaceOwner) async throws -> DesignJSONValue {
        switch request.operation {
        case .beginProjectionRecovery:
            let recoveryID = try request.identifier("recoveryID")
            let count = try request.integer("byteCount", maximum: G04WorkspaceDocumentSession.maximumDocumentBytes)
            let digest = try request.digest("sha256")
            let source = try request.text("sourcePath")
            let suffix = (source as NSString).pathExtension.lowercased()
            let safeSuffix = suffix.range(of: "^[a-z0-9]{1,16}$", options: .regularExpression) != nil ? suffix : "txt"
            let path = "Recovered Drafts/\(recoveryID.uuidString).\(safeSuffix)"
            return try await leased(owner: owner, intent: .read, path: path) { service, _ in
                if let proof = try Self.proof(service, path: path, count: count, digest: digest) { return proof }
                if let old = uploads.first(where: { $0.value.owner == owner && $0.value.recoveryID == recoveryID }) {
                    guard old.value.count == count, old.value.digest == digest, old.value.path == path else {
                        throw G04DocumentError.staleRevision
                    }
                    return .object(["handle": .string(old.key.uuidString), "nextOffset": .integer(Int64(old.value.bytes.count))])
                }
                guard uploads.count < 8 else { throw G04DocumentError.transferLimit }
                let token = UUID()
                uploads[token] = Upload(owner: owner, recoveryID: recoveryID, path: path, count: count, digest: digest)
                return .object(["handle": .string(token.uuidString), "nextOffset": .integer(0)])
            }
        case .appendProjectionRecovery:
            let token = try request.identifier("handle")
            let offset = try request.integer("offset", maximum: G04WorkspaceDocumentSession.maximumDocumentBytes)
            guard let bytes = Data(base64Encoded: try request.text("bytes", maxBytes: 32 * 1024)),
                  !bytes.isEmpty, bytes.count <= G04WorkspaceDocumentSession.maximumChunkBytes else {
                throw G04DocumentError.invalidTransfer
            }
            return try await leased(owner: owner, intent: .read, path: nil) { _, _ in
                guard var upload = uploads[token], upload.owner == owner,
                      offset == upload.bytes.count, bytes.count <= upload.count - offset else {
                    throw G04DocumentError.invalidTransfer
                }
                upload.bytes.append(bytes); uploads[token] = upload
                return .object(["nextOffset": .integer(Int64(upload.bytes.count))])
            }
        case .commitProjectionRecovery:
            let token = try request.identifier("handle")
            guard let initial = uploads[token], initial.owner == owner else { throw G04DocumentError.invalidTransfer }
            return try await leased(owner: owner, intent: .fileMutation, path: initial.path) { service, cancellation in
                guard let upload = uploads[token], upload.owner == owner, upload.path == initial.path,
                      upload.bytes.count == upload.count, FloeDigest.sha256Hex(upload.bytes) == upload.digest,
                      String(data: upload.bytes, encoding: .utf8) != nil else { throw G04DocumentError.invalidTransfer }
                if let proof = try Self.proof(service, path: upload.path, count: upload.count, digest: upload.digest) {
                    uploads.removeValue(forKey: token); return proof
                }
                // Original mutation lock, no-overwrite semantics and staged
                // atomic commit. The separate metadata call hashes disk bytes.
                _ = try service.createBinaryFile(upload.path, data: upload.bytes, overwrite: false, cancellation: cancellation)
                guard let proof = try Self.proof(service, path: upload.path, count: upload.count, digest: upload.digest) else {
                    throw G04DocumentError.invalidTransfer
                }
                uploads.removeValue(forKey: token)
                return proof
            }
        case .cancelProjectionRecovery:
            let token = try request.identifier("handle")
            return try await leased(owner: owner, intent: .read, path: nil) { _, _ in
                if let upload = uploads[token] {
                    guard upload.owner == owner else { throw G04DocumentError.ownerChanged }
                    uploads.removeValue(forKey: token)
                }
                // No persisted original or verified recovery file is deleted.
                return .object(["cancelled": .bool(true)])
            }
        default: throw G04WorkspaceWireRequest.Failure.unknownOperation
        }
    }

    private static func proof(_ service: WorkspaceFileService, path: String, count: Int,
                              digest: String) throws -> DesignJSONValue? {
        let target = try service.guardResolver.resolve(path)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == Int64(count) else { throw G04DocumentError.staleRevision }
        let actual = try service.metadata(path)
        guard !actual.isDirectory, !actual.isSymlink, actual.size == Int64(count), actual.sha256 == digest else {
            throw G04DocumentError.staleRevision
        }
        return .object(["preserved": .bool(true), "path": .string(path),
            "byteCount": .integer(Int64(count)), "sha256": .string(digest)])
    }

    func retire() { retired = true; uploads.removeAll() }
}
