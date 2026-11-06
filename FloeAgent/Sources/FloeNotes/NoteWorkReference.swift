// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A saved native-work citation, never a tool/file permission. Optional
/// fields on note content keep older note documents and readers compatible.
public struct NoteWorkReference: Codable, Hashable, Sendable {
    public var workID: UUID
    public var kind: String
    public var documentID: UUID
    public var revision: UInt64
    public var objectID: UUID?
    public var objectRevision: UInt64?
    public var objectDigest: String?
    public var imageDigest: String?
    public var renderKind: String?
    public var url: URL { URL(string: "floe://work/" + workID.uuidString.lowercased())! }
    public init(workID: UUID, kind: String, documentID: UUID, revision: UInt64,
                objectID: UUID? = nil, objectRevision: UInt64? = nil, objectDigest: String? = nil,
                imageDigest: String? = nil, renderKind: String? = nil) {
        self.workID = workID; self.kind = kind; self.documentID = documentID; self.revision = revision
        self.objectID = objectID; self.objectRevision = objectRevision; self.objectDigest = objectDigest
        self.imageDigest = imageDigest; self.renderKind = renderKind
    }
    public func validate() throws {
        guard !kind.isEmpty, kind.utf8.count <= 64, revision > 0,
              (renderKind?.utf8.count ?? 0) <= 64,
              objectID != nil || (objectRevision == nil && objectDigest == nil) else { throw NoteError.invalidDocument("Invalid work reference") }
        for digest in [objectDigest, imageDigest].compactMap({ $0 }) {
            guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else { throw NoteError.invalidDocument("Invalid work reference digest") }
        }
    }
}
