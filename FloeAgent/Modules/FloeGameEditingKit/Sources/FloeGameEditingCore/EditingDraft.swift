// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// One undoable/redoable session edit. Byte-level records keep every editor
/// family on an equal footing; summaries drive the visible history.
public enum SessionEdit: Codable, Sendable {
    case update(path: GameRelativePath, before: Data?, after: Data, summary: GameEditCopy)
    case move(from: GameRelativePath, to: GameRelativePath, before: Data,
               referenceUpdates: [ReferenceBytes], summary: GameEditCopy)
    case remove(path: GameRelativePath, before: Data,
                referenceUpdates: [ReferenceBytes], summary: GameEditCopy)

    public var summary: GameEditCopy {
        switch self {
        case .update(_, _, _, let summary): return summary
        case .move(_, _, _, _, let summary): return summary
        case .remove(_, _, _, let summary): return summary
        }
    }
    public var primaryPath: GameRelativePath {
        switch self {
        case .update(let path, _, _, _): return path
        case .move(let from, _, _, _, _): return from
        case .remove(let path, _, _, _): return path
        }
    }
    /// Counts retained byte payloads, rather than only the number of gestures.
    /// Pixel edits may retain two complete PNGs in a single history record.
    var retainedByteCount: Int {
        let values: [Int]
        switch self {
        case .update(_, let before, let after, _): values = [before?.count ?? 0, after.count]
        case .move(_, _, let before, let references, _), .remove(_, let before, let references, _):
            values = [before.count] + references.flatMap { [$0.before.count, $0.after.count] }
        }
        return values.reduce(0) { total, next in
            let sum = total.addingReportingOverflow(next)
            return sum.overflow ? Int.max : sum.partialValue
        }
    }
}

/// Byte state of one referencing document before/after a reference rewrite.
public struct ReferenceBytes: Codable, Sendable {
    public var path: GameRelativePath
    public var before: Data
    public var after: Data
    public init(path: GameRelativePath, before: Data, after: Data) {
        self.path = path; self.before = before; self.after = after
    }
}

/// Append-only per-session history entry (undo/redo also log here).
public struct GameEditRecord: Codable, Sendable, Identifiable {
    public enum Operation: String, Codable, Sendable { case apply, undo, redo }
    public var id: Int
    public var sequence: Int
    public var atUTC: Date
    public var operation: Operation
    public var summary: GameEditCopy
    public var path: GameRelativePath?
    public var byteDelta: Int
}

/// One open/edited document in the session working set.
public struct EditingDocument: Sendable {
    public var path: GameRelativePath
    /// Bytes at the session base revision; nil = new file added in this session.
    public var baseBytes: Data?
    public var currentBytes: Data
    public init(path: GameRelativePath, baseBytes: Data?, currentBytes: Data) {
        self.path = path; self.baseBytes = baseBytes; self.currentBytes = currentBytes
    }
    public var isNew: Bool { baseBytes == nil }
    public var isDirty: Bool { currentBytes != baseBytes }
}

/// Per-file rebase conflict after an external commit moved HEAD.
public struct FileRebaseConflict: Sendable {
    public var path: GameRelativePath
    public var baseBytes: Data
    public var theirsBytes: Data
    public var mineBytes: Data
    public var localDeletion = false
    public var remoteDeletion = false
}

/// Persistent draft for crash recovery. Lives inside the repository
/// directory so it shares the repository lock domain and is cleaned with it.
public struct EditingDraft: Codable, Sendable {
    public var formatVersion: Int
    public var projectID: UUID
    public var owner: GameProjectOwner
    public var baseRevision: String
    public var savedAtUTC: Date
    public var undoStack: [SessionEdit]
    public var redoStack: [SessionEdit]
    public var history: [GameEditRecord]
    /// Current bytes of every touched document, stored as content blobs.
    public var documents: [DraftDocument]
    public var removedPaths: [GameRelativePath]

    public struct DraftDocument: Codable, Sendable {
        public var path: GameRelativePath
        /// Digest of base bytes (nil = new file). Base bytes themselves are
        /// re-read from the immutable revision object during recovery.
        public var baseDigest: String?
        public var currentDigest: String
    }
}

public struct DraftSummary: Sendable {
    public var baseRevision: String
    public var savedAtUTC: Date
    public var editCount: Int
    public var documentCount: Int
}

public enum DraftRecoveryError: Error, Sendable {
    case staleDraft
    case ownerMismatch
}

struct EditingDraftStore {
    let directory: URL

    init(repositoryDirectory: URL) {
        self.directory = repositoryDirectory.appendingPathComponent("EditingDrafts")
    }

    private func draftDirectory(_ projectID: UUID) -> URL {
        directory.appendingPathComponent(projectID.uuidString.lowercased())
    }

    func load(projectID: UUID, owner: GameProjectOwner, headRevision: String) throws -> EditingDraft? {
        guard let draft = try loadRetained(projectID: projectID, owner: owner) else { return nil }
        guard draft.baseRevision == headRevision else { throw DraftRecoveryError.staleDraft }
        return draft
    }

    func loadRetained(projectID: UUID, owner: GameProjectOwner) throws -> EditingDraft? {
        let url = draftDirectory(projectID).appendingPathComponent("draft.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try readBounded(url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let draft = try decoder.decode(EditingDraft.self, from: data)
        guard draft.formatVersion == 1, draft.projectID == projectID else { throw GameProjectError.corruptStorage }
        guard draft.owner == owner else { throw DraftRecoveryError.ownerMismatch }
        return draft
    }

    /// Callers save content blobs first (see `saveBlob`); draft.json is
    /// written last so a crash never leaves a draft pointing at missing bytes.
    func save(_ draft: EditingDraft) throws {
        let root = draftDirectory(draft.projectID)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Files"),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(draft)
        guard data.count <= 32 * 1_024 * 1_024 else { throw GameProjectError.limitExceeded("editingDraft") }
        try atomicWrite(data, to: root.appendingPathComponent("draft.json"))
    }

    /// Store real blob bytes; keyed by digest so identical documents dedup.
    func saveBlob(_ bytes: Data, digest: String, projectID: UUID) throws {
        guard bytes.count <= 32 * 1_024 * 1_024 else { throw GameProjectError.limitExceeded("editingDraftBlob") }
        let root = draftDirectory(projectID)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Files"),
                                                withIntermediateDirectories: true)
        let target = try blobURL(root: root, digest: digest)
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        try atomicWrite(bytes, to: target)
    }

    func loadBlob(digest: String, projectID: UUID) throws -> Data {
        let url = try blobURL(root: draftDirectory(projectID), digest: digest)
        let data = try readBounded(url)
        guard GameDigest.sha256(data) == digest else { throw GameProjectError.corruptStorage }
        return data
    }

    func containsBlob(digest: String, projectID: UUID) throws -> Bool {
        FileManager.default.fileExists(atPath: try blobURL(root: draftDirectory(projectID), digest: digest).path)
    }

    func clear(projectID: UUID) throws {
        try FileManager.default.removeItem(at: draftDirectory(projectID))
    }

    private func blobURL(root: URL, digest: String) throws -> URL {
        guard digest.utf8.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw GameProjectError.corruptStorage
        }
        return root.appendingPathComponent("Files/" + digest)
    }

    private func readBounded(_ url: URL) throws -> Data {
        let reader = try GameProjectReader(rootURL: url.deletingLastPathComponent(),
                                           maximumFileBytes: 32 * 1_024 * 1_024)
        guard let bytes = try reader.read(GameRelativePath(url.lastPathComponent)) else {
            throw GameProjectError.corruptStorage
        }
        return bytes
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".draft-" + UUID().uuidString)
        try data.write(to: temporary, options: [.atomic])
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }
}
