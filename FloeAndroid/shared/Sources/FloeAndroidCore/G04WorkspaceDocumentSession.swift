// SPDX-License-Identifier: MPL-2.0
// Android IDE adapter over the original FloeWorkspace file/text authority.
// The trusted composition supplies ownership admission and draining leases.
// No URI, absolute root, permission grant or database is selected here.
import Foundation
import FloeCore
import FloeTools
import FloeWorkspace

public struct G04WorkspaceOwner: Hashable, Sendable {
    public let epoch: UInt64
    public let taskID: UUID
    public let workspaceID: UUID
    public init(epoch: UInt64, taskID: UUID, workspaceID: UUID) {
        self.epoch = epoch; self.taskID = taskID; self.workspaceID = workspaceID
    }
}

public enum G04WorkspaceIntent: Sendable { case read, editDraft, write, fileMutation }

/// Must be implemented by the live composition over the ORIGINAL workspace
/// store, permission/lifecycle fences and operation leases. A picker string
/// or renderer-provided path is never sufficient to construct this lease.
public protocol G04WorkspaceAccessPort: Sendable {
    func acquire(owner: G04WorkspaceOwner, intent: G04WorkspaceIntent,
                 relativePath: String?) async throws -> G04WorkspaceAccessLease
}

public struct G04WorkspaceAccessLease: Sendable {
    public let service: WorkspaceFileService
    public let cancellation: CancellationToken
    public let release: @Sendable () async -> Void
    public init(service: WorkspaceFileService, cancellation: CancellationToken,
                release: @escaping @Sendable () async -> Void) {
        self.service = service; self.cancellation = cancellation; self.release = release
    }
}

public enum G04DocumentError: Error, Sendable, Equatable {
    case retired, ownerChanged, missingDocument, staleRevision, invalidRange
    case invalidTransfer, transferLimit, invalidUTF8, dirtyDocument, historyUnavailable
    case bufferLimit, workspaceBusy
}

public struct G04DocumentHeader: Sendable, Equatable {
    public let owner: G04WorkspaceOwner
    public let documentID: UUID
    public let relativePath: String
    public let revision: String
    public let utf8Bytes: Int
    public let selection: NSRange
    public let dirty: Bool
    public let canUndo: Bool
    public let canRedo: Bool
}

public enum G04DocumentContentPart: String, Sendable, Codable {
    case document, diff, conflictBase, conflictCurrent
}

public struct G04DocumentContent: Sendable, Equatable {
    public let header: G04DocumentHeader
    public let handle: UUID
    public let byteCount: Int
    public let sha256: String
}

public struct G04DocumentChunk: Sendable, Equatable {
    public let bytes: Data
    public let nextOffset: Int
    public let finished: Bool
}

public struct G04DocumentFind: Sendable, Equatable {
    public let revision: String
    public let ranges: [NSRange]
    public let selection: NSRange?
    public let truncated: Bool
}

public struct G04DocumentReplace: Sendable, Equatable {
    public let header: G04DocumentHeader
    public let replacements: Int
}

/// In-process ownership handoff to the native recovery coordinator. This
/// value is never serialized into an oversized bridge/control message.
public struct G04RetainedDraft: Sendable {
    public let header: G04DocumentHeader
    public let text: String
    public let baselineSHA256: String
    public let baselineMtime: Double
}

public enum G04DocumentSave: Sendable {
    case saved(G04DocumentHeader)
    case conflict(G04DocumentHeader, WorkspaceEditConflict)
}

/// Outcome of a real "save a copy / fork draft" operation (renderer
/// KEEP_BOTH). `copy` is the separately-opened durable draft copy that
/// already passed a native read-back SHA check; `source` stays exactly as
/// it was (the external original on disk is never rewritten here). The
/// source tab is closed ONLY when `sourceClosedAfterCopy` is true, which
/// the session sets only after the copy was written AND read back AND the
/// caller explicitly chose to discard the old draft.
public struct G04DocumentFork: Sendable, Equatable {
    public let source: G04DocumentHeader
    public let copy: G04DocumentHeader
    public let sourceClosedAfterCopy: Bool
}

/// Root-owned RAM drafts survive view/tab reconstruction. Files, CAS,
/// recovery copies and path policy stay in WorkspaceFileService. This actor
/// is the Android presentation adapter; it does not require an uninstalled
/// Swift MainActor/Android Looper bridge or create another persistence store.
public actor G04WorkspaceDocumentSession {
    public static let maximumDocumentBytes = 4 * 1024 * 1024
    public static let maximumChunkBytes = 24 * 1024 // base64 still fits the 48KiB effect carrier
    public static let maximumBufferBytes = 16 * 1024 * 1024
    private static let maximumHistoryBytes = 16 * 1024 * 1024
    private static let maximumHistoryEntries = 512

    private struct Edit: Sendable {
        let location: Int
        let removed: String
        let inserted: String
        let before: NSRange
        let after: NSRange
        var bytes: Int { removed.utf8.count + inserted.utf8.count }
    }
    private struct Document: Sendable {
        let id: UUID
        var path: String
        var resolvedPath: String
        var text: String
        var baseline: String
        var mtime: Double
        var sha256: String
        var revision = UUID().uuidString
        var selection = NSRange(location: 0, length: 0)
        var undo: [Edit] = []
        var redo: [Edit] = []
        var conflict: WorkspaceEditConflict?
    }
    private struct Export: Sendable {
        let documentID: UUID
        let revision: String
        let data: Data
        let expires: Date
    }
    private struct Upload: Sendable {
        let documentID: UUID
        let revision: String
        let range: NSRange
        let expectedBytes: Int
        let expectedDigest: String
        var data = Data()
        let expires: Date
    }

    public let owner: G04WorkspaceOwner
    private let access: any G04WorkspaceAccessPort
    private var boundRoot: String?
    private var retired = false
    private var externalMutation: UUID?
    private var documents: [UUID: Document] = [:]
    private var order: [UUID] = []
    private var exports: [UUID: Export] = [:]
    private var uploads: [UUID: Upload] = [:]

    public init(owner: G04WorkspaceOwner, access: any G04WorkspaceAccessPort) {
        self.owner = owner; self.access = access
    }

    /// Admission can suspend. Re-check retirement/root identity AFTER it,
    /// then keep the ORIGINAL operation lease until actual IO has settled.
    private func withWorkspace<T: Sendable>(
        _ intent: G04WorkspaceIntent, path: String? = nil, documentID: UUID? = nil,
        _ body: (WorkspaceFileService, CancellationToken) throws -> T
    ) async throws -> T {
        let requestedPath = try documentID.map { try document($0).path } ?? path
        return try await withWorkspacePaths([(intent, requestedPath)], body)
    }

    /// Copy/move authorize BOTH endpoints. Keep every original ownership
    /// lease through IO; a denied second endpoint cannot leak the first.
    /// Revalidate resolutions after the last suspension (including mounts).
    private func withWorkspacePaths<T: Sendable>(
        _ requests: [(G04WorkspaceIntent, String?)],
        _ body: (WorkspaceFileService, CancellationToken) throws -> T
    ) async throws -> T {
        guard !retired else { throw G04DocumentError.retired }
        guard externalMutation == nil else { throw G04DocumentError.workspaceBusy }
        var leases: [G04WorkspaceAccessLease] = []
        var targets: [(String, String)] = []
        do {
            for (intent, path) in requests {
                let lease = try await access.acquire(owner: owner, intent: intent, relativePath: path)
                leases.append(lease)
                guard !retired else { throw G04DocumentError.retired }
                guard externalMutation == nil else { throw G04DocumentError.workspaceBusy }
                try Task.checkCancellation()
                try lease.cancellation.throwIfCancelled()
                let root = lease.service.guardResolver.rootURL.path
                if let boundRoot, boundRoot != root { throw G04DocumentError.ownerChanged }
                boundRoot = root
                if let path { targets.append((path, try lease.service.guardResolver.resolve(path).path)) }
            }
            guard let first = leases.first else { throw G04DocumentError.ownerChanged }
            for lease in leases {
                try lease.cancellation.throwIfCancelled()
                for (path, resolved) in targets {
                    guard try lease.service.guardResolver.resolve(path).path == resolved else {
                        throw G04DocumentError.ownerChanged
                    }
                }
            }
            guard externalMutation == nil else { throw G04DocumentError.workspaceBusy }
            let value = try body(first.service, first.cancellation)
            for lease in leases.reversed() { await lease.release() }
            return value
        } catch {
            for lease in leases.reversed() { await lease.release() }
            throw error
        }
    }

    private func header(_ document: Document) -> G04DocumentHeader {
        G04DocumentHeader(owner: owner, documentID: document.id, relativePath: document.path,
                          revision: document.revision, utf8Bytes: document.text.utf8.count,
                          selection: document.selection, dirty: document.text != document.baseline,
                          canUndo: !document.undo.isEmpty, canRedo: !document.redo.isEmpty)
    }
    private func document(_ id: UUID, revision: String? = nil) throws -> Document {
        guard let value = documents[id] else { throw G04DocumentError.missingDocument }
        if let revision, value.revision != revision { throw G04DocumentError.staleRevision }
        return value
    }
    private func invalidateTransfers(for id: UUID) {
        exports = exports.filter { $0.value.documentID != id }
        uploads = uploads.filter { $0.value.documentID != id }
    }
    private func pruneTransfers() {
        let now = Date()
        exports = exports.filter { $0.value.expires > now }
        uploads = uploads.filter { $0.value.expires > now }
    }
    private func trimHistoryBudget() {
        var bytes = documents.values.reduce(0) { total, value in
            total + value.undo.reduce(0) { $0 + $1.bytes } + value.redo.reduce(0) { $0 + $1.bytes }
        }
        while bytes > Self.maximumHistoryBytes {
            guard let id = order.first(where: {
                guard let value = documents[$0] else { return false }
                return !value.undo.isEmpty || !value.redo.isEmpty
            }), var value = documents[id] else { break }
            let edit = !value.undo.isEmpty ? value.undo.removeFirst() : value.redo.removeFirst()
            bytes -= edit.bytes; documents[id] = value
        }
    }
    private func checkBinding(_ value: Document, service: WorkspaceFileService) throws {
        guard try service.guardResolver.resolve(value.path).path == value.resolvedPath else {
            throw G04DocumentError.ownerChanged
        }
    }

    public func list(_ path: String = ".", page: String? = nil) async throws -> DirectoryPage {
        try await withWorkspace(.read, path: path) { service, cancel in
            try service.listDirectory(path, pageToken: page, cancellation: cancel)
        }
    }
    public func search(_ query: String, in path: String = ".") async throws -> [SearchHit] {
        try await withWorkspace(.read, path: path) { service, cancel in
            try service.search(query: query, in: path, cancellation: cancel)
        }
    }

    public func metadata(_ path: String) async throws -> WorkspaceFileMetadata {
        try await withWorkspace(.read, path: path) { service, _ in try service.metadata(path) }
    }

    public func findFileNames(_ query: String, in path: String = ".") async throws -> [String] {
        try await withWorkspace(.read, path: path) { service, cancel in
            try service.searchFileNames(query: query, in: path, cancellation: cancel)
        }
    }

    public func createFile(_ path: String, content: String = "") async throws -> WriteOutcome {
        try await withWorkspace(.fileMutation, path: path) { service, cancel in
            try service.createFile(path, content: content, overwrite: false, cancellation: cancel)
        }
    }

    public func createDirectory(_ path: String) async throws {
        try await withWorkspace(.fileMutation, path: path) { service, cancel in
            try service.createDirectory(path, cancellation: cancel)
        }
    }

    private func affectedDocuments(_ resolvedPath: String) -> [Document] {
        order.compactMap { documents[$0] }.filter {
            $0.resolvedPath == resolvedPath || $0.resolvedPath.hasPrefix(resolvedPath + "/")
        }
    }

    /// Move keeps native tab IDs and drafts. Construct every new binding
    /// before changing disk so a failed guard cannot strand a moved tab.
    public func move(_ from: String, to destination: String) async throws -> [G04DocumentHeader] {
        try await withWorkspacePaths([(.fileMutation, from), (.fileMutation, destination)]) { service, cancel in
            let sourceURL = try service.guardResolver.resolve(from)
            let destinationURL = try service.guardResolver.resolve(destination)
            let sourceLogical = (from as NSString).standardizingPath
            let destinationLogical = (destination as NSString).standardizingPath
            let affected = affectedDocuments(sourceURL.path)
            let updates: [(UUID, String, String)] = try affected.map { value in
                try checkBinding(value, service: service)
                guard value.path == sourceLogical || value.path.hasPrefix(sourceLogical + "/") else {
                    throw G04DocumentError.ownerChanged
                }
                let suffix = String(value.path.dropFirst(sourceLogical.count))
                let nextPath = destinationLogical + suffix
                let resolved = try service.guardResolver.resolve(nextPath).path
                guard resolved == destinationURL.path || resolved.hasPrefix(destinationURL.path + "/") else {
                    throw G04DocumentError.ownerChanged
                }
                return (value.id, nextPath, resolved)
            }
            try service.move(from, to: destination, cancellation: cancel)
            return updates.compactMap { id, path, resolved in
                guard var value = documents[id] else { return nil }
                value.path = path; value.resolvedPath = resolved
                value.revision = UUID().uuidString; value.conflict = nil
                documents[id] = value; invalidateTransfers(for: id)
                return header(value)
            }
        }
    }

    public func copy(_ from: String, to destination: String) async throws {
        try await withWorkspacePaths([(.read, from), (.fileMutation, destination)]) { service, cancel in
            try service.copy(from, to: destination, cancellation: cancel)
        }
    }

    /// Destructive tree operations never silently discard an open draft.
    /// Clean tabs close only AFTER successful deletion; failure keeps tabs.
    public func delete(_ path: String, recursive: Bool = false) async throws -> [UUID] {
        try await withWorkspace(.fileMutation, path: path) { service, cancel in
            let resolved = try service.guardResolver.resolve(path)
            let affected = affectedDocuments(resolved.path)
            for value in affected {
                try checkBinding(value, service: service)
                guard value.text == value.baseline else { throw G04DocumentError.dirtyDocument }
            }
            try service.delete(path, recursive: recursive, cancellation: cancel)
            let ids = affected.map(\.id)
            for id in ids { documents.removeValue(forKey: id); invalidateTransfers(for: id) }
            let removed = Set(ids); order.removeAll { removed.contains($0) }
            return ids
        }
    }

    /// Called only by the native Git owner while its ORIGINAL workspace IO
    /// lease is held. A checkout/merge/discard cannot overwrite an unsaved
    /// native draft or an in-flight large edit upload.
    func beginExternalMutation() throws -> UUID {
        guard !retired else { throw G04DocumentError.retired }
        guard externalMutation == nil, uploads.isEmpty else { throw G04DocumentError.workspaceBusy }
        guard documents.values.allSatisfy({ $0.text == $0.baseline }) else { throw G04DocumentError.dirtyDocument }
        let token = UUID(); externalMutation = token
        return token
    }

    /// Reload clean documents using the SAME authorized service under the
    /// caller's still-live lease. IDs survive; changed files get new opaque
    /// revisions and cleared undo lineage. Missing/unreadable files are
    /// removed from the projection and returned explicitly, never cached as
    /// a complete old body under a new on-disk revision.
    func finishExternalMutation(_ token: UUID, service: WorkspaceFileService) throws -> [String] {
        guard externalMutation == token else { throw G04DocumentError.ownerChanged }
        defer { externalMutation = nil }
        guard !retired else { return [] }
        var unavailable: [String] = []
        for id in order {
            guard var value = documents[id] else { continue }
            do {
                let current = try service.editConflict(path: value.path, base: nil, draft: "")
                if current.currentSHA256 != value.sha256 || current.currentMtime != value.mtime {
                    let changed = value.text != current.current
                    value.text = current.current; value.baseline = current.current
                    value.mtime = current.currentMtime; value.sha256 = current.currentSHA256
                    value.resolvedPath = try service.guardResolver.resolve(value.path).path
                    value.revision = UUID().uuidString; value.conflict = nil
                    value.selection = NSRange(location: 0, length: 0)
                    if changed { value.undo.removeAll(); value.redo.removeAll() }
                    invalidateTransfers(for: id)
                    documents[id] = value
                }
            } catch {
                unavailable.append(value.path)
                documents.removeValue(forKey: id); invalidateTransfers(for: id)
            }
        }
        order.removeAll { documents[$0] == nil }
        return unavailable
    }

    public func open(_ path: String) async throws -> G04DocumentHeader {
        try await withWorkspace(.read, path: path) { service, _ in
            let resolved = try service.guardResolver.resolve(path)
            // The ORIGINAL guard also authorizes explicit Mounts/<name>
            // roots. Preserve that virtual path instead of shrinking access
            // to physical descendants of the primary root.
            let relative = (path.trimmingCharacters(in: .whitespaces) as NSString).standardizingPath
            if let existing = documents.values.first(where: { $0.resolvedPath == resolved.path }) { return header(existing) }
            let snapshot = try service.editConflict(path: relative, base: nil, draft: "")
            guard documents.count < 32,
                  documents.values.reduce(0, { $0 + $1.text.utf8.count }) + snapshot.current.utf8.count
                    <= Self.maximumBufferBytes else { throw G04DocumentError.bufferLimit }
            let value = Document(id: UUID(), path: relative, resolvedPath: resolved.path, text: snapshot.current,
                                 baseline: snapshot.current, mtime: snapshot.currentMtime,
                                 sha256: snapshot.currentSHA256)
            documents[value.id] = value; order.append(value.id)
            return header(value)
        }
    }
    public func tabs() async throws -> [G04DocumentHeader] {
        try await withWorkspace(.read) { _, _ in order.compactMap { documents[$0].map(header) } }
    }

    /// A frozen native-owned byte handle, not text smuggled into control JSON.
    public func beginContent(_ id: UUID, revision: String, part: G04DocumentContentPart = .document) async throws -> G04DocumentContent {
        try await withWorkspace(.read, documentID: id) { service, _ in
            pruneTransfers()
            let value = try document(id, revision: revision)
            guard exports.count < 2 else { throw G04DocumentError.transferLimit }
            let text: String
            switch part {
            case .document: text = value.text
            case .diff: text = diffText(value, service: service)
            case .conflictBase:
                guard let conflict = value.conflict else { throw G04DocumentError.staleRevision }
                text = conflict.base ?? ""
            case .conflictCurrent:
                guard let conflict = value.conflict else { throw G04DocumentError.staleRevision }
                text = conflict.current
            }
            let data = Data(text.utf8), handle = UUID()
            exports[handle] = Export(documentID: id, revision: revision, data: data,
                                     expires: Date().addingTimeInterval(120))
            return G04DocumentContent(header: header(value), handle: handle, byteCount: data.count,
                                      sha256: FloeDigest.sha256Hex(data))
        }
    }
    public func readContent(_ handle: UUID, offset: Int, limit: Int) async throws -> G04DocumentChunk {
        try await withWorkspace(.read, documentID: exports[handle]?.documentID) { _, _ in
            pruneTransfers()
            guard let export = exports[handle], offset >= 0, offset <= export.data.count,
                  limit > 0, limit <= Self.maximumChunkBytes else { throw G04DocumentError.invalidTransfer }
            _ = try document(export.documentID, revision: export.revision)
            let end = min(export.data.count, offset + limit)
            return G04DocumentChunk(bytes: export.data.subdata(in: offset..<end), nextOffset: end,
                                    finished: end == export.data.count)
        }
    }
    public func releaseContent(_ handle: UUID) { exports.removeValue(forKey: handle) }

    private func validateRange(_ range: NSRange, text: String) throws {
        let length = (text as NSString).length
        guard range.location >= 0, range.length >= 0, range.location <= length,
              range.length <= length - range.location,
              IDENativeTextEditing.isComposedBoundary(in: text, offset: range.location),
              IDENativeTextEditing.isComposedBoundary(in: text, offset: range.location + range.length)
        else { throw G04DocumentError.invalidRange }
    }
    private func apply(_ id: UUID, revision: String, range: NSRange, replacement: String,
                       selection: NSRange? = nil) throws -> G04DocumentHeader {
        var value = try document(id, revision: revision)
        try validateRange(range, text: value.text)
        guard replacement.utf8.count <= Self.maximumDocumentBytes else { throw G04DocumentError.bufferLimit }
        let ns = value.text as NSString
        let removed = ns.substring(with: range)
        let prospectiveBytes = value.text.utf8.count - removed.utf8.count + replacement.utf8.count
        guard prospectiveBytes <= Self.maximumDocumentBytes,
              documents.values.reduce(0, { $0 + $1.text.utf8.count }) - value.text.utf8.count + prospectiveBytes
                <= Self.maximumBufferBytes else { throw G04DocumentError.bufferLimit }
        let text = ns.replacingCharacters(in: range, with: replacement)
        let proposedSelection = selection ?? NSRange(
            location: range.location + (replacement as NSString).length, length: 0)
        try validateRange(proposedSelection, text: text)
        let after = IDENativeTextEditing.clamp(proposedSelection, to: text)
        if text == value.text { value.selection = after; documents[id] = value; return header(value) }
        value.undo.append(Edit(location: range.location, removed: removed, inserted: replacement,
                               before: value.selection, after: after))
        value.redo.removeAll()
        while value.undo.count > Self.maximumHistoryEntries ||
                value.undo.reduce(0, { $0 + $1.bytes }) > Self.maximumHistoryBytes {
            value.undo.removeFirst()
        }
        value.text = text; value.selection = after; value.revision = UUID().uuidString
        documents[id] = value; invalidateTransfers(for: id)
        trimHistoryBudget()
        return header(documents[id]!)
    }
    public func edit(_ id: UUID, revision: String, range: NSRange, replacement: String,
                     selection: NSRange? = nil) async throws -> G04DocumentHeader {
        try await withWorkspace(.editDraft, documentID: id) { _, _ in
            try apply(id, revision: revision, range: range, replacement: replacement, selection: selection)
        }
    }
    public func updateSelection(_ id: UUID, revision: String, selection: NSRange) async throws -> G04DocumentHeader {
        try await withWorkspace(.read, documentID: id) { _, _ in
            var value = try document(id, revision: revision)
            try validateRange(selection, text: value.text)
            value.selection = selection; documents[id] = value
            return header(value)
        }
    }

    /// Identifier-style whole words include Unicode letters, numbers, marks
    /// and underscore. Search is literal; neither query nor replacement is code.
    private func isWholeWord(_ range: NSRange, in text: String) -> Bool {
        let start = String.Index(utf16Offset: range.location, in: text)
        let end = String.Index(utf16Offset: NSMaxRange(range), in: text)
        func word(_ scalar: Unicode.Scalar?) -> Bool {
            guard let scalar else { return false }
            return scalar.value == 95 || CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet.nonBaseCharacters.contains(scalar)
        }
        return !word(text[..<start].unicodeScalars.last) && !word(text[end...].unicodeScalars.first)
    }
    private func match(in text: String, query: String, caseSensitive: Bool, wholeWord: Bool,
                       backwards: Bool, start: Int, end: Int, cancel: CancellationToken) throws -> NSRange? {
        guard !query.isEmpty else { return nil }
        let ns = text as NSString
        var lower = start, upper = end
        var options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        if backwards { options.insert(.backwards) }
        while lower < upper {
            try cancel.throwIfCancelled()
            let hit = ns.range(of: query, options: options, range: NSRange(location: lower, length: upper - lower))
            guard hit.location != NSNotFound, hit.length > 0 else { return nil }
            if !wholeWord || isWholeWord(hit, in: text) { return hit }
            if backwards { upper = hit.location } else { lower = NSMaxRange(hit) }
        }
        return nil
    }
    public func find(_ id: UUID, revision: String, query: String, caseSensitive: Bool,
                     wholeWord: Bool, backwards: Bool = false, from: NSRange? = nil) async throws -> G04DocumentFind {
        try await withWorkspace(.read, documentID: id) { _, cancel in
            let value = try document(id, revision: revision)
            let selection = from ?? value.selection
            try validateRange(selection, text: value.text)
            let length = (value.text as NSString).length
            var hits: [NSRange] = [], cursor = 0, truncated = false
            while let hit = try match(in: value.text, query: query, caseSensitive: caseSensitive,
                                      wholeWord: wholeWord, backwards: false,
                                      start: cursor, end: length, cancel: cancel) {
                if hits.count == WorkspaceFileService.maxSearchHits { truncated = true; break }
                hits.append(hit); cursor = NSMaxRange(hit)
            }
            var selected = try match(in: value.text, query: query, caseSensitive: caseSensitive,
                                     wholeWord: wholeWord, backwards: backwards,
                                     start: backwards ? 0 : NSMaxRange(selection),
                                     end: backwards ? selection.location : length, cancel: cancel)
            if selected == nil {
                selected = try match(in: value.text, query: query, caseSensitive: caseSensitive,
                                     wholeWord: wholeWord, backwards: backwards,
                                     start: 0, end: length, cancel: cancel)
            }
            return G04DocumentFind(revision: value.revision, ranges: hits, selection: selected, truncated: truncated)
        }
    }
    public func replace(_ id: UUID, revision: String, query: String, replacement: String,
                        caseSensitive: Bool, wholeWord: Bool, all: Bool) async throws -> G04DocumentReplace {
        try await withWorkspace(.editDraft, documentID: id) { _, cancel in
            let value = try document(id, revision: revision)
            guard !query.isEmpty else { return G04DocumentReplace(header: header(value), replacements: 0) }
            let ns = value.text as NSString
            if !all {
                let range = value.selection
                let selected = ns.substring(with: range)
                let equal = caseSensitive ? selected == query : selected.compare(query, options: .caseInsensitive) == .orderedSame
                guard range.length > 0, equal, !wholeWord || isWholeWord(range, in: value.text) else {
                    return G04DocumentReplace(header: header(value), replacements: 0)
                }
                return G04DocumentReplace(header: try apply(id, revision: revision, range: range,
                                                            replacement: replacement), replacements: 1)
            }
            guard replacement.utf8.count <= Self.maximumDocumentBytes else { throw G04DocumentError.bufferLimit }
            var output = "", bytes = 0, cursor = 0, count = 0
            output.reserveCapacity(value.text.utf8.count)
            while let hit = try match(in: value.text, query: query, caseSensitive: caseSensitive,
                                      wholeWord: wholeWord, backwards: false, start: cursor,
                                      end: ns.length, cancel: cancel) {
                let prefix = ns.substring(with: NSRange(location: cursor, length: hit.location - cursor))
                bytes += prefix.utf8.count + replacement.utf8.count
                guard bytes <= Self.maximumDocumentBytes else { throw G04DocumentError.bufferLimit }
                output += prefix; output += replacement; count += 1; cursor = NSMaxRange(hit)
            }
            let suffix = ns.substring(from: cursor)
            guard bytes + suffix.utf8.count <= Self.maximumDocumentBytes else { throw G04DocumentError.bufferLimit }
            output += suffix
            try cancel.throwIfCancelled()
            guard count > 0 else { return G04DocumentReplace(header: header(value), replacements: 0) }
            return G04DocumentReplace(header: try apply(id, revision: revision,
                range: NSRange(location: 0, length: ns.length), replacement: output), replacements: count)
        }
    }

    public func beginEditUpload(_ id: UUID, revision: String, range: NSRange,
                                byteCount: Int, sha256: String) async throws -> UUID {
        try await withWorkspace(.editDraft, documentID: id) { _, _ in
            pruneTransfers()
            let value = try document(id, revision: revision)
            try validateRange(range, text: value.text)
            guard byteCount >= 0, byteCount <= Self.maximumDocumentBytes, uploads.count < 2,
                  !uploads.values.contains(where: { $0.documentID == id }), sha256.count == 64,
                  sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { throw G04DocumentError.invalidTransfer }
            let handle = UUID()
            uploads[handle] = Upload(documentID: id, revision: revision, range: range,
                                      expectedBytes: byteCount, expectedDigest: sha256,
                                      expires: Date().addingTimeInterval(120))
            return handle
        }
    }
    /// Identical replay of a previously accepted chunk is idempotent. A
    /// changed replay or gap refuses without changing the draft.
    public func appendEditUpload(_ handle: UUID, offset: Int, bytes: Data) async throws -> Int {
        try await withWorkspace(.editDraft, documentID: uploads[handle]?.documentID) { _, _ in
            pruneTransfers()
            guard var upload = uploads[handle], offset >= 0, bytes.count <= Self.maximumChunkBytes,
                  offset <= upload.data.count, bytes.count <= upload.expectedBytes - offset
            else { throw G04DocumentError.invalidTransfer }
            _ = try document(upload.documentID, revision: upload.revision)
            if offset < upload.data.count {
                guard bytes.count <= upload.data.count - offset,
                      upload.data.subdata(in: offset..<(offset + bytes.count)) == bytes
                else { throw G04DocumentError.invalidTransfer }
                return upload.data.count
            }
            upload.data.append(bytes); uploads[handle] = upload
            return upload.data.count
        }
    }
    public func commitEditUpload(_ handle: UUID) async throws -> G04DocumentHeader {
        try await withWorkspace(.editDraft, documentID: uploads[handle]?.documentID) { _, _ in
            pruneTransfers()
            guard let upload = uploads.removeValue(forKey: handle),
                  upload.data.count == upload.expectedBytes,
                  FloeDigest.sha256Hex(upload.data) == upload.expectedDigest else {
                throw G04DocumentError.invalidTransfer
            }
            guard let text = String(data: upload.data, encoding: .utf8) else { throw G04DocumentError.invalidUTF8 }
            return try apply(upload.documentID, revision: upload.revision, range: upload.range, replacement: text)
        }
    }
    public func cancelEditUpload(_ handle: UUID) { uploads.removeValue(forKey: handle) }

    public func undo(_ id: UUID, revision: String) async throws -> G04DocumentHeader {
        try await history(id, revision: revision, redo: false)
    }
    public func redo(_ id: UUID, revision: String) async throws -> G04DocumentHeader {
        try await history(id, revision: revision, redo: true)
    }
    private func history(_ id: UUID, revision: String, redo: Bool) async throws -> G04DocumentHeader {
        try await withWorkspace(.editDraft, documentID: id) { _, _ in
            var value = try document(id, revision: revision)
            guard let edit = redo ? value.redo.last : value.undo.last else { throw G04DocumentError.historyUnavailable }
            let before = redo ? edit.removed : edit.inserted
            let after = redo ? edit.inserted : edit.removed
            let range = NSRange(location: edit.location, length: (before as NSString).length)
            try validateRange(range, text: value.text)
            guard (value.text as NSString).substring(with: range) == before else { throw G04DocumentError.staleRevision }
            let next = (value.text as NSString).replacingCharacters(in: range, with: after)
            guard documents.values.reduce(0, { $0 + $1.text.utf8.count }) - value.text.utf8.count + next.utf8.count
                    <= Self.maximumBufferBytes else { throw G04DocumentError.bufferLimit }
            if redo { value.redo.removeLast(); value.undo.append(edit) }
            else { value.undo.removeLast(); value.redo.append(edit) }
            value.text = next; value.selection = redo ? edit.after : edit.before
            value.revision = UUID().uuidString
            documents[id] = value; invalidateTransfers(for: id)
            return header(value)
        }
    }

    public func save(_ id: UUID, revision: String) async throws -> G04DocumentSave {
        try await withWorkspace(.write, documentID: id) { service, cancel in
            var value = try document(id, revision: revision)
            try checkBinding(value, service: service)
            do {
                let outcome = try service.writeFile(value.path, content: value.text,
                    expectedMtime: value.mtime, expectedSHA256: value.sha256, cancellation: cancel)
                value.baseline = value.text; value.sha256 = outcome.sha256; value.mtime = outcome.mtime
                value.revision = UUID().uuidString; value.conflict = nil
                documents[id] = value; invalidateTransfers(for: id)
                return .saved(header(value))
            } catch WorkspaceToolError.conflict {
                let conflict = try service.editConflict(path: value.path, base: value.baseline,
                                                        draft: value.text, preserveDraft: true)
                value.conflict = conflict; value.revision = UUID().uuidString
                documents[id] = value; invalidateTransfers(for: id)
                return .conflict(header(value), conflict)
            } catch {
                // Missing or unreadable originals also preserve the actual
                // draft through the ORIGINAL recovery service before failing.
                _ = try service.editConflict(path: value.path, base: value.baseline,
                                              draft: value.text, preserveDraft: true)
                throw error
            }
        }
    }
    public func resolveConflict(_ id: UUID, revision: String, reviewedSHA256: String,
                                text: String) async throws -> G04DocumentHeader {
        try await withWorkspace(.write, documentID: id) { service, _ in
            var value = try document(id, revision: revision)
            try checkBinding(value, service: service)
            guard let conflict = value.conflict, conflict.currentSHA256 == reviewedSHA256 else {
                throw G04DocumentError.staleRevision
            }
            guard text.utf8.count <= Self.maximumDocumentBytes,
                  documents.values.reduce(0, { $0 + $1.text.utf8.count }) - value.text.utf8.count + text.utf8.count
                    <= Self.maximumBufferBytes else { throw G04DocumentError.bufferLimit }
            let outcome = try service.resolveConflict(conflict, content: text)
            value.text = text; value.baseline = text; value.mtime = outcome.mtime; value.sha256 = outcome.sha256
            value.selection = IDENativeTextEditing.clamp(value.selection, to: text)
            value.revision = UUID().uuidString; value.conflict = nil; value.undo.removeAll(); value.redo.removeAll()
            documents[id] = value; invalidateTransfers(for: id)
            return header(value)
        }
    }
    public func resolveConflictUsingDraft(_ id: UUID, revision: String,
                                          reviewedSHA256: String) async throws -> G04DocumentHeader {
        let value = try document(id, revision: revision)
        return try await resolveConflict(id, revision: revision, reviewedSHA256: reviewedSHA256, text: value.text)
    }

    /// Real renderer `KEEP_BOTH` path (D15): the external original file is
    /// NEVER rewritten. The COMPLETE native draft bytes are written to a
    /// separate no-overwrite target through the ORIGINAL `WorkspaceFileService`
    /// guard (so traversal/symlink/secret/mount policy is unchanged), then a
    /// fresh independent read-back of that copy must match the draft digest
    /// byte-for-byte before the copy is opened as its own tab. Only after
    /// that verified copy acknowledgement — and only when the caller
    /// explicitly chose `discardAfterCopy` — may the source draft tab close,
    /// and ONLY while its revision still equals the forked revision (a newer
    /// edit that raced in keeps its tab open honestly). Every failure or
    /// cancellation path leaves BOTH the on-disk original and this session's
    /// draft exactly intact; a partially-created copy is refused by the
    /// no-overwrite create and never mistaken for success.
    public func forkDraft(_ id: UUID, revision: String, destination: String? = nil,
                          discardAfterCopy: Bool = false) async throws -> G04DocumentFork {
        let draft = try document(id, revision: revision)
        let text = draft.text
        let draftDigest = FloeDigest.sha256Hex(Data(text.utf8))
        let target = destination ?? Self.forkDestination(for: draft.path, revision: revision)
        guard target != draft.path else { throw G04DocumentError.invalidTransfer }
        // No-overwrite create: an existing foreign file at the target refuses
        // typed before a single byte changes. Bytes stay native in-process.
        _ = try await withWorkspace(.fileMutation, path: target) { service, cancel in
            try service.createFile(target, content: text, overwrite: false, cancellation: cancel)
        }
        // Actual verified copy acknowledgement: read the new file back
        // through the ORIGINAL guard and compare the digest.
        let readBack = try await withWorkspace(.read, path: target) { service, _ in
            try service.metadata(target)
        }
        guard readBack.sha256 == draftDigest, !readBack.isDirectory else {
            throw G04DocumentError.invalidTransfer
        }
        let copy = try await open(target)
        var source = header(draft)
        var closed = false
        if discardAfterCopy {
            // The copy is durable and verified; the source tab may close
            // only if its revision is unchanged since the fork snapshot.
            if let current = documents[id], current.revision == revision {
                try await closeDocument(id, revision: revision, discardDraft: true)
                closed = true
            } else {
                source = header(try document(id))
            }
        }
        return G04DocumentFork(source: source, copy: copy, sourceClosedAfterCopy: closed)
    }

    /// Deterministic no-overwrite default: a stable short revision suffix in
    /// the source directory, never silently replacing any existing file.
    private static func forkDestination(for path: String, revision: String) -> String {
        let source = (path as NSString).standardizingPath
        let directory = (source as NSString).deletingLastPathComponent
        let last = (source as NSString).lastPathComponent
        let stem = (last as NSString).deletingPathExtension
        let fileExtension = (last as NSString).pathExtension
        let suffix = String(revision.prefix(8)).lowercased()
        let name = fileExtension.isEmpty ? "\(stem)-draft-\(suffix)"
            : "\(stem)-draft-\(suffix).\(fileExtension)"
        let normalizedDirectory = directory.isEmpty || directory == "."
            ? "" : (directory as NSString).standardizingPath
        return normalizedDirectory.isEmpty ? name : normalizedDirectory + "/" + name
    }


    public func diff(_ id: UUID, revision: String) async throws -> String {
        try await withWorkspace(.read, documentID: id) { service, _ in
            diffText(try document(id, revision: revision), service: service)
        }
    }

    private func diffText(_ value: Document, service: WorkspaceFileService) -> String {
        guard value.baseline != value.text else { return "" }
        let oldCount = value.baseline.utf8.reduce(1) { $0 + ($1 == 10 ? 1 : 0) }
        let newCount = value.text.utf8.reduce(1) { $0 + ($1 == 10 ? 1 : 0) }
        if oldCount > 1_000_000 / newCount {
            // The original small-file LCS allocates n*m cells. Large
            // inputs get an exact whole-change hunk in linear space,
            // preserving its components(separatedBy:"\n") convention.
            let label = value.path.replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            var output = "--- a/\(label)\n+++ b/\(label)\n@@ -1,\(oldCount) +1,\(newCount) @@\n"
            func appendLines(_ text: String, prefix: String) {
                var remaining = text[...]
                while let newline = remaining.firstIndex(of: "\n") {
                    output += prefix; output += remaining[..<newline]; output += "\n"
                    remaining = remaining[remaining.index(after: newline)...]
                }
                output += prefix; output += remaining; output += "\n"
            }
            appendLines(value.baseline, prefix: "-"); appendLines(value.text, prefix: "+")
            return output
        }
        return service.diff(original: value.baseline, modified: value.text, label: value.path)
    }
    public func closeDocument(_ id: UUID, revision: String, discardDraft: Bool) async throws {
        try await withWorkspace(.editDraft, documentID: id) { _, _ in
            let value = try document(id, revision: revision)
            guard discardDraft || value.text == value.baseline else { throw G04DocumentError.dirtyDocument }
            documents.removeValue(forKey: id); order.removeAll { $0 == id }; invalidateTransfers(for: id)
        }
    }
    /// Fences new work without silently dropping unsaved buffers. The live
    /// composition owns durable recovery or explicit task-deletion disposal.
    public func beginRetirement() -> [G04RetainedDraft] {
        retired = true; exports.removeAll(); uploads.removeAll()
        return order.compactMap { documents[$0] }.filter { $0.text != $0.baseline }.map {
            G04RetainedDraft(header: header($0), text: $0.text, baselineSHA256: $0.sha256,
                             baselineMtime: $0.mtime)
        }
    }

    /// Eviction evidence for the root-owned facade registry: a session may be
    /// replaced ONLY when no draft differs from its baseline and no byte
    /// transfer is open (an already-retired session is replaceable because
    /// its drafts were fenced out first). Never a blind drop.
    public var isEvictable: Bool {
        retired || (documents.values.allSatisfy { $0.text == $0.baseline }
                    && exports.isEmpty && uploads.isEmpty)
    }
}
