//
//  CADMaterialLibraryStore.swift
//  FloeCADKit
//
//  One process-wide, app-owned personal material-library file. The document
//  package remains self-contained; this file is only used by explicit
//  libraryExport/libraryImport/libraryList `global=true` calls, or by a UI
//  store that calls `CADMaterialLibraryFileStore` directly. Keeping the URL in
//  the core avoids a second personal library path.
//

import Foundation

nonisolated enum CADSharedMaterialLibraryPaths {
    /// The one app-owned personal material library file. Both the core host
    /// and the UI store derive the path from this constant.
    static var libraryURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("CADMaterials", isDirectory: true)
            .appendingPathComponent("library.json", isDirectory: false)
    }
}

/// Pure shared-file merge used by the host's coordinated global export. An
/// existing corrupt/oversized file is a REFUSAL, never a reason to replace it
/// with the incoming document library. Incoming ids win; existing extras stay.
public nonisolated enum CADMaterialLibraryJSONMerge {
    public struct MergeError: Error, LocalizedError, Equatable, Sendable {
        public var code: String
        public var message: String
        public var errorDescription: String? { message }
        public init(code: String, message: String) {
            self.code = code
            self.message = message
        }
    }

    public static func merge(existing: Data?, incoming: Data,
                             maximumBytes: Int) throws -> Data {
        guard incoming.count <= maximumBytes else {
            throw MergeError(code: "shared_library_too_large",
                             message: "The incoming personal material library exceeds the size bound.")
        }
        guard let existing else { return incoming }
        guard existing.count <= maximumBytes else {
            throw MergeError(
                code: "shared_library_too_large",
                message: "The existing personal material library is oversized and was left untouched.")
        }
        guard let existingObject = (try? JSONSerialization.jsonObject(with: existing))
                as? [String: Any],
              let existingEntries = existingObject["entries"] as? [[String: Any]],
              let incomingObject = (try? JSONSerialization.jsonObject(with: incoming))
                as? [String: Any],
              let incomingEntries = incomingObject["entries"] as? [[String: Any]] else {
            throw MergeError(
                code: "shared_library_corrupt",
                message: "The existing personal material library is unreadable and was left untouched; "
                    + "no document export replaced it.")
        }
        func key(_ entry: [String: Any]) -> String? {
            guard let id = entry["id"] as? [String: Any],
                  let raw = id["raw"] as? String, !raw.isEmpty else { return nil }
            return raw.lowercased()
        }
        var seen = Set<String>()
        var mergedEntries: [[String: Any]] = []
        for entry in incomingEntries {
            if let key = key(entry), !seen.insert(key).inserted { continue }
            mergedEntries.append(entry)
        }
        for entry in existingEntries {
            if let key = key(entry), !seen.insert(key).inserted { continue }
            mergedEntries.append(entry)
        }
        var object = incomingObject
        object["entries"] = mergedEntries
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys]) else {
            throw MergeError(code: "shared_library_corrupt",
                             message: "The personal material library could not be merged safely.")
        }
        return data
    }
    /// Coordinated in-place write of a merged library. The same file key is
    /// used by the UI `NSFileCoordinator` store. An unreadable/oversized
    /// existing file makes this REFUSE without touching it; there is no
    /// "replace a corrupt file with incoming" fallback.
    public static func mergeInPlace(at url: URL, incoming: Data,
                                    maximumBytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var coordinationError: NSError?
        var failure: MergeError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing,
                                       error: &coordinationError) { coordinatedURL in
            do {
                let existing: Data?
                if FileManager.default.fileExists(atPath: coordinatedURL.path) {
                    let size = (try? coordinatedURL.resourceValues(forKeys: [.fileSizeKey]))?
                        .fileSize ?? 0
                    if size > maximumBytes {
                        throw MergeError(
                            code: "shared_library_too_large",
                            message: "The existing personal material library is oversized and was left untouched.")
                    }
                    existing = try Data(contentsOf: coordinatedURL)
                } else {
                    existing = nil
                }
                let merged = try merge(existing: existing, incoming: incoming,
                                       maximumBytes: maximumBytes)
                try merged.write(to: coordinatedURL, options: .atomic)
            } catch let error as MergeError {
                failure = error
            } catch {
                failure = MergeError(code: "shared_library_write_failed",
                                     message: "The personal material library could not be written: "
                                        + error.localizedDescription)
            }
        }
        if let coordinationError {
            throw MergeError(code: "shared_library_busy",
                             message: "The personal material library is busy: "
                                + coordinationError.localizedDescription)
        }
        if let failure { throw failure }
    }
}

nonisolated enum CADMaterialLibraryFileStore {
    /// Same URL as `FloeCADDocument.sharedMaterialLibraryURL`; convenience for
    /// the UI store. There is exactly one personal library file.
    static var defaultURL: URL { CADSharedMaterialLibraryPaths.libraryURL }
    static func read(at url: URL) -> CADMaterialLibrary? {
        guard let data = try? Data(contentsOf: url),
              data.count <= CADMaterialLimits.maximumLibraryBytes else { return nil }
        return try? JSONDecoder().decode(CADMaterialLibrary.self, from: data)
    }

    static func write(_ library: CADMaterialLibrary, to url: URL) throws {
        guard let data = CADMaterialLibraryCodec.encode(library) else {
            throw CADDocumentError(code: "library_encode_failed",
                                   message: "The personal material library could not be encoded within its size bound.")
        }
        // A UI/coordinated writer must never silently replace an unreadable or
        // oversized personal library with the value it decoded as empty. The
        // caller can surface this and preserve the bytes for recovery.
        if FileManager.default.fileExists(atPath: url.path) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size <= CADMaterialLimits.maximumLibraryBytes else {
                throw CADDocumentError(
                    code: "shared_library_too_large",
                    message: "The existing personal material library is oversized and was left untouched.")
            }
            guard let existing = try? Data(contentsOf: url),
                  (try? JSONDecoder().decode(CADMaterialLibrary.self, from: existing)) != nil else {
                throw CADDocumentError(
                    code: "shared_library_corrupt",
                    message: "The existing personal material library is unreadable and was left untouched.")
            }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

@MainActor
public extension FloeCADDocument {
    /// Live in-memory generation, bumped by every undoable document command.
    /// Used to fence a save result against a concurrent editor mutation.
    var liveChangeCount: Int { session.changeCount }

    /// The single app-owned personal material library path. Both the tool
    /// bridge and any UI store must use THIS value; do not create a second
    /// library file.
    nonisolated static var sharedMaterialLibraryURL: URL {
        CADSharedMaterialLibraryPaths.libraryURL
    }
}

/// What reversing a failed commit means for the action that produced it.
public nonisolated enum CADNativeEditRollback: Sendable, Equatable {
    /// A forward edit: undo one command.
    case undo
    /// The action WAS undo: redo it to restore the prior state.
    case redo
    /// Nothing to reverse.
    case none
}

public nonisolated struct CADNativeEditSaveResult: Sendable, Equatable {
    public var saved: Bool
    public var rolledBack: Bool
    /// Another editor changed the document while the save was in flight. The
    /// commit deliberately did NOT undo, so it cannot erase that other edit;
    /// the caller must surface a retry/refresh.
    public var concurrentEdit: Bool
    public var revision: Int
    public var contentSHA256: String
    public var error: String?

    public init(saved: Bool, rolledBack: Bool, concurrentEdit: Bool,
                revision: Int, contentSHA256: String, error: String?) {
        self.saved = saved
        self.rolledBack = rolledBack
        self.concurrentEdit = concurrentEdit
        self.revision = revision
        self.contentSHA256 = contentSHA256
        self.error = error
    }
}

/// Commit one already-applied native edit with compare-and-swap semantics.
///
/// If the save fails and the document is still exactly at the post-edit
/// generation, the edit is reversed (or an undo is redone) so a retry cannot
/// apply it twice. If a concurrent editor changed the document during the
/// `await`, the commit refuses to undo and reports `concurrentEdit` — undoing
/// then could erase someone else's work.
@MainActor
public enum CADNativeEditCommit {
    public static func save(document: FloeCADDocument,
                            changeAfterMutation: Int,
                            rollback: CADNativeEditRollback = .undo,
                            checkpoint: CADEditCheckpoint? = nil) async -> CADNativeEditSaveResult {
        let outcome = await document.save()
        if outcome.succeeded {
            return CADNativeEditSaveResult(
                saved: true, rolledBack: false, concurrentEdit: false,
                revision: outcome.revision, contentSHA256: outcome.contentSHA256,
                error: nil)
        }
        guard document.liveChangeCount == changeAfterMutation else {
            return CADNativeEditSaveResult(
                saved: false, rolledBack: false, concurrentEdit: true,
                revision: outcome.revision, contentSHA256: outcome.contentSHA256,
                error: (outcome.error ?? "The edit could not be committed.")
                    + " Another edit landed during the save; nothing was undone. Re-read and retry.")
        }
        if let checkpoint {
            document.restoreEditCheckpoint(checkpoint)
        } else {
            switch rollback {
            case .undo:
                document.session.undo()
            case .redo:
                document.session.redo()
            case .none:
                break
            }
        }
        let rolledBack = checkpoint != nil || rollback != .none
        return CADNativeEditSaveResult(
            saved: false, rolledBack: rolledBack, concurrentEdit: false,
            revision: outcome.revision, contentSHA256: outcome.contentSHA256,
            error: (outcome.error ?? "The edit could not be committed.")
                + (rolledBack ? " The in-memory edit was rolled back." : ""))
    }
}
