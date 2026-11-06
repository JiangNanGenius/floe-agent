import Foundation

/// Preview is side-effect free. Accept exactly this proposal via the shared
/// coordinator; newer source/user edits invalidate its expected generation.
/// The host stages and verifies the immutable replacement bytes before accept.
public struct MediaPreparedAssetUpdateProposal: Sendable, Hashable {
    public let id: UUID
    public let documentID: UUID
    public let previous: MediaAssetReference
    public let replacement: MediaAssetReference
    public let expectedGeneration: UInt64
    public let sourceRevision: Int64

    public init(document: MediaPreparedDocument, assetID: UUID,
                replacement: MediaAssetReference, sourceRevision: Int64) throws {
        guard let previous = document.asset(assetID), replacement.id == assetID,
              replacement.kind == previous.kind, sourceRevision >= 0,
              previous.relativePath != replacement.relativePath,
              let newHash = replacement.contentHash, !newHash.isEmpty,
              newHash != previous.contentHash else {
            throw MediaPreparedCoreError.invalidOperation("update requires a distinct immutable, hashed source revision")
        }
        self.id = UUID(); self.documentID = document.id; self.previous = previous
        self.replacement = replacement; self.sourceRevision = sourceRevision
        self.expectedGeneration = document.assetRevisions?[assetID] ?? 0
    }

    public var operation: MediaPreparedOperation {
        .init(id: id, action: .replaceAsset(expected: previous, expectedRevision: expectedGeneration,
                                          replacement: replacement))
    }
}
