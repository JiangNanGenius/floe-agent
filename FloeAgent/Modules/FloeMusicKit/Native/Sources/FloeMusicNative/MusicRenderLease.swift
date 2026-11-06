import Foundation
import FloeMusicCore

/// A non-realtime job fence. The lock protects only active/commit state; the
/// DSP callback never sees this object. Host edits/navigation invalidate it.
public final class MusicRenderLease: @unchecked Sendable {
    public let projectID: MusicProjectID
    public let revision: Int64
    public let ownerToken: String
    private let lock = NSLock()
    private var active = true

    public init(document: MusicDocument, ownerToken: String) throws {
        try document.validate()
        guard !ownerToken.isEmpty else { throw MusicNativeError.staleOwner }
        projectID = document.id
        revision = document.revision
        self.ownerToken = ownerToken
    }

    public func invalidate() { lock.withLock { active = false } }

    public func validate(document: MusicDocument) throws {
        try lock.withLock {
            guard active, document.id == projectID, document.revision == revision else { throw MusicNativeError.staleOwner }
        }
    }

    /// Rename is the output's commit point. Invalidation and commit serialize;
    /// no existing destination is replaced, including after a failed render.
    func commit(staged: URL, destination: URL) throws {
        try lock.withLock {
            try Task.checkCancellation()
            guard active else { throw MusicNativeError.staleOwner }
            try FileManager.default.moveItem(at: staged, to: destination)
        }
    }
}
