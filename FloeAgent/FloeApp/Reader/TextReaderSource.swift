// FloeApp — Reading-mode source construction (workspace file / Notes text).
//
// SPDX-License-Identifier: MPL-2.0
//
// Reading mode is an alternate READ-ONLY view of the same original
// file/document. This file only builds a bounded byte source plus a
// change-detection fingerprint:
//   - workspace files resolve through the existing WorkspacePathGuard, and
//     local files are streamed (never loaded whole);
//   - cloud/network text is staged by the existing bounded remote reader
//     (`WorkspaceCenter.readRemotePreview`, ≤32 MiB) and the UI says so;
//   - Notes text documents read their own text content (the document is not
//     modified and no new store is introduced).
// A position is persisted only for durable documents (not task-private
// workspace files) and only when its fingerprint still matches.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeNotes
import FloeWorkspace
import FloeModels
import FloePersistence
import FloeTools
import CryptoKit
import Darwin

/// Bounded byte source plus the revision fingerprint it was built from.
struct TextReaderBytes: Sendable {
    var source: any ReaderByteSource
    var fingerprint: String
}

struct TextReaderSource {
    var kind: ReaderSourceKind
    /// Stable owner id (workspace id / "notes") for position storage.
    var ownerID: String
    /// Relative path for workspace files; note id for Notes documents.
    var documentKey: String
    var displayName: String
    /// Short format label shown in the reader ("txt", "md", "notes").
    var format: String
    var markdown: Bool
    /// True when the bytes are a fully staged remote/cloud snapshot: the
    /// reader states that honestly instead of pretending to stream.
    var isRemoteSnapshot: Bool
    /// False for task-private workspace files: their reading position is not
    /// remembered (temporary task data must not outlive the task).
    var persistsPosition: Bool
    /// True when the Notes document also contains ink/images: reading mode
    /// shows the text content only and says so.
    var hasNonTextContent: Bool
    var limits: ReaderLimits
    /// Produces the byte source and fingerprint on demand (off the view body).
    var makeBytes: @MainActor () async throws -> TextReaderBytes

    // MARK: - Fingerprints

    /// Change-detection fingerprint for a local file: size + mtime + a
    /// sha256 over the first and last 32 KiB. It is deliberately cheap (no
    /// whole-file read) and only decides whether a stored position may be
    /// restored; it is never used as a content address.
    static func fileFingerprint(url: URL, byteLength: Int64, mtime: Double) -> String {
        let window = 32 * 1024
        var sample = Data()
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let first = try? handle.read(upToCount: window) {
                sample.append(first)
            }
            if byteLength > Int64(window) {
                let tailStart = max(0, byteLength - Int64(window))
                if (try? handle.seek(toOffset: UInt64(tailStart))) != nil,
                   let last = try? handle.read(upToCount: window) {
                    sample.append(last)
                }
            }
        }
        return "\(byteLength)-\(String(format: "%.3f", mtime))-\(FloeDigest.sha256Hex(sample))"
    }

    /// Fingerprint for fully staged bytes (remote snapshots, Notes text).
    static func dataFingerprint(_ data: Data, revision: Int? = nil) -> String {
        let digest = FloeDigest.sha256Hex(data)
        if let revision { return "\(data.count)-\(digest)-r\(revision)" }
        return "\(data.count)-\(digest)"
    }

    // MARK: - Notes documents

    /// Text content of a Notes document in page order. Only `.text` elements
    /// are read; the document itself is untouched.
    static func notesText(_ document: NoteDocument) -> (text: String, hasNonTextContent: Bool) {
        let hasNonText = document.pages.contains { page in
            page.drawingResourceID != nil || page.backgroundResourceID != nil || page.elements.contains { $0.kind != .text }
        }
        return (NoteTextContent.reading(document).text, hasNonText)
    }

    static func notes(document: NoteDocument) -> TextReaderSource {
        let extracted = notesText(document)
        let markdown = document.pages.contains { $0.elements.contains { $0.kind == .text && $0.isMarkdown } }
        let presentation = markdown ? NoteTextContent.readerMarkdown(extracted.text) : extracted.text
        let data = Data(presentation.utf8)
        let fingerprint = dataFingerprint(data, revision: document.revision)
        return TextReaderSource(
            kind: .notesDocument,
            ownerID: "notes",
            documentKey: document.id.uuidString,
            displayName: document.title,
            format: "notes",
            markdown: markdown,
            isRemoteSnapshot: false,
            persistsPosition: true,
            hasNonTextContent: extracted.hasNonTextContent,
            limits: ReaderLimits(),
            makeBytes: {
                TextReaderBytes(source: ReaderDataByteSource(data: data), fingerprint: fingerprint)
            }
        )
    }
}

/// Keeps one admitted descriptor, validates exact bytes once, and rejects mutation on every page.
/// Below the trusted root every path component is opened with O_NOFOLLOW.
final class VerifiedPreviewByteSource: ReaderByteSource, @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private let observed: stat
    let byteLength: Int64

    init(root: URL, relativePath: String, bytes: Int, sha256: String) throws {
        guard bytes >= 0, Int64(bytes) <= ReaderLimits.default.maxFileBytes,
              RunOutputFile.isValidSHA256Hex(sha256), !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"), !relativePath.contains("\0") else {
            throw ReaderError.sourceUnavailable("The file reference could not be verified")
        }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ReaderError.sourceUnavailable("The file reference could not be verified")
        }
        var directory = open(root.standardizedFileURL.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        defer { close(directory) }
        for part in parts.dropLast() {
            let next = openat(directory, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw CocoaError(.fileReadNoPermission) }
            close(directory); directory = next
        }
        let fd = openat(directory, String(parts.last!), O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        var facts = stat()
        guard fstat(fd, &facts) == 0, facts.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              facts.st_nlink == 1, facts.st_size == off_t(bytes) else {
            close(fd); throw CocoaError(.fileReadCorruptFile)
        }
        var hash = SHA256(); var offset = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)
        do {
            while offset < bytes {
                try Task.checkCancellation()
                let wanted = min(buffer.count, bytes - offset)
                let n = buffer.withUnsafeMutableBytes { raw in
                    pread(fd, raw.baseAddress, wanted, off_t(offset))
                }
                guard n > 0 else { throw CocoaError(.fileReadCorruptFile) }
                hash.update(data: Data(buffer.prefix(n))); offset += n
            }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == sha256.lowercased() else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var after = stat()
            guard fstat(fd, &after) == 0, Self.same(facts, after) else { throw CocoaError(.fileReadCorruptFile) }
        } catch { close(fd); throw error }
        descriptor = fd; observed = facts; byteLength = Int64(bytes)
    }
    deinit { close(descriptor) }
    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size && a.st_nlink == b.st_nlink
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    func read(offset: Int64, length: Int) throws -> Data {
        try lock.withLock {
            guard offset >= 0, offset <= byteLength, length >= 0, length <= 512 * 1024 else {
                throw ReaderError.sourceUnavailable("Invalid preview page")
            }
            var before = stat()
            guard fstat(descriptor, &before) == 0, Self.same(observed, before) else { throw CocoaError(.fileReadCorruptFile) }
            let wanted = min(length, Int(byteLength - offset))
            var data = Data(count: wanted)
            let count = data.withUnsafeMutableBytes { buffer in pread(descriptor, buffer.baseAddress, wanted, off_t(offset)) }
            guard count == wanted else { throw CocoaError(.fileReadCorruptFile) }
            var after = stat()
            guard fstat(descriptor, &after) == 0, Self.same(observed, after) else { throw CocoaError(.fileReadCorruptFile) }
            return data
        }
    }
}

enum RunOutputTextPreviewPolicy {
    static func normalizedMIME(_ value: String) -> String {
        value.split(separator: ";", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    }
    static func isMarkdown(name: String, mimeType: String) -> Bool {
        normalizedMIME(mimeType) == "text/markdown"
            || ["md", "markdown", "mdown", "mkd"].contains((name as NSString).pathExtension.lowercased())
    }
    static func supports(name: String, mimeType: String) -> Bool {
        let mime = normalizedMIME(mimeType)
        if mime == "text/rtf" || mime == "application/rtf" { return false }
        if mime.hasPrefix("text/") { return true }
        if ["application/json", "application/xml", "application/javascript", "application/x-ndjson", "application/yaml"].contains(mime) { return true }
        guard mime.isEmpty || mime == "application/octet-stream" else { return false }
        switch WorkspaceTextPolicy.kind(forPath: name) { case .text, .code: return true; default: return false }
    }

    @MainActor static func source(receipt: RunOutputFile, context: RunOutputReceiptContext, artifactRoot: URL?) -> TextReaderSource {
        TextReaderSource(kind: .workspaceFile, ownerID: receipt.taskID?.uuidString ?? "",
            documentKey: receipt.relativePath, displayName: receipt.displayName,
            format: (receipt.displayName as NSString).pathExtension, markdown: isMarkdown(name: receipt.displayName, mimeType: receipt.mimeType),
            isRemoteSnapshot: false, persistsPosition: false, hasNonTextContent: false,
            limits: ReaderLimits(chunkBytes: 64 * 1024), makeBytes: {
                guard RunOutputReceiptGate.accepts(receipt, in: context), supports(name: receipt.displayName, mimeType: receipt.mimeType) else {
                    throw CocoaError(.fileReadNoPermission)
                }
                let worker = Task.detached(priority: .utility) {
                    guard Int64(receipt.byteCount) <= ReaderLimits.default.maxFileBytes else {
                        throw ReaderError.fileTooLarge(limit: ReaderLimits.default.maxFileBytes)
                    }
                    guard case .verified = RunOutputSnapshotStore.verify(receipt, artifactRoot: artifactRoot) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    let root = try artifactRoot ?? FloeArtifactStore.root()
                    let bytes = try VerifiedPreviewByteSource(root: root, relativePath: receipt.relativePath,
                        bytes: receipt.byteCount, sha256: receipt.sha256)
                    return TextReaderBytes(source: bytes, fingerprint: receipt.sha256)
                }
                return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            })
    }
}

private final class WorkspacePreviewByteSource: ReaderByteSource {
    private let source: any ReaderByteSource
    private let lease: GlobalWorkspaceReadLease
    init(source: any ReaderByteSource, lease: GlobalWorkspaceReadLease) { self.source = source; self.lease = lease }
    var byteLength: Int64 { source.byteLength }
    func read(offset: Int64, length: Int) throws -> Data { try source.read(offset: offset, length: length) }
    deinit { let release = lease.release; Task { await release() } }
}

/// A bounded writer receipt is presentation evidence, never a path grant.
/// A truncated receipt must reopen its actual frozen run/workspace and verify
/// the full committed size/digest before the reader can request any page.
enum SavedFileTextPreviewPolicy {
    static func matches(_ lhs: WorkspaceFileChangePreview, _ rhs: WorkspaceFileChangePreview) -> Bool {
        lhs.version == rhs.version && lhs.path == rhs.path && lhs.byteCount == rhs.byteCount
            && lhs.sha256 == rhs.sha256 && lhs.text == rhs.text && lhs.truncated == rhs.truncated
            && lhs.comparison == rhs.comparison
    }

    static func verifiedBytes(document: WorkspaceFileChangePreview, root: URL) throws -> TextReaderBytes {
        _ = try WorkspacePathGuard(rootURL: root).resolve(document.path)
        let bytes = try VerifiedPreviewByteSource(root: root, relativePath: document.path,
            bytes: document.byteCount, sha256: document.sha256)
        return TextReaderBytes(source: bytes, fingerprint: document.sha256)
    }

    /// The native writer's root is its canonical task workspace, not the
    /// selected execution environment's root. Resolve the same SQLite owner
    /// as ConversationCenter, using WorkspaceCenter's existing read-only lease.
    @MainActor static func ownedBytes(document: WorkspaceFileChangePreview, artifact: ToolArtifactReference,
        scope: ChatInlineContentScope, conversations: any ConversationStore, runs: any RunStore,
        workspaces: any WorkspaceStore, artifactRoot: URL,
        acquireRoot: @MainActor (WorkspaceRecord) async throws -> GlobalWorkspaceReadLease) async throws -> TextReaderBytes {
        guard !scope.isTemporary else { throw CocoaError(.fileReadNoPermission) }
        let parts = artifact.relativePath.split(separator: "/")
        guard parts.count == 3, parts[0] == "ChangeArtifacts", let runID = UUID(uuidString: String(parts[1])),
              let reference = ChatContentReference(kind: .artifact, ownerID: runID, contentID: artifact.id.uuidString),
              case .artifact(let actual, let ownerRun, let tool) = try await ChatInlineContentResolver.resolve(reference,
                scope: scope, conversations: conversations, runs: runs), actual == artifact, ownerRun == runID,
              let run = try await runs.run(id: runID), run.conversationID == scope.conversationID,
              let binding = run.executionBinding, binding.conversationID == scope.conversationID,
              binding.target.backend == .linuxVM, !binding.target.environmentID.isEmpty,
              let ownerID = try await workspaces.workspaceID(conversationID: run.conversationID),
              let workspace = try await workspaces.workspace(id: ownerID),
              workspace.kind != .privateTask || workspace.internalRelativePath == "PrivateTasks/\(scope.conversationID.uuidString)" else {
            throw CocoaError(.fileReadNoPermission)
        }
        let lease = try await acquireRoot(workspace)
        do {
            guard lease.workspaceID == ownerID else { throw CocoaError(.fileReadNoPermission) }
            let root = lease.root
            let worker = Task.detached(priority: .utility) {
                let verified = try VerifiedChatInlineArtifact.load(artifact, runID: runID, tool: tool, root: artifactRoot)
                let saved = try JSONDecoder().decode(WorkspaceFileChangePreview.self, from: verified.data)
                guard matches(saved, document) else { throw CocoaError(.fileReadCorruptFile) }
                return try verifiedBytes(document: document, root: root)
            }
            let bytes = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard try await workspaces.workspaceID(conversationID: scope.conversationID) == ownerID,
                  let current = try await runs.run(id: runID), current.conversationID == scope.conversationID,
                  current.executionBinding == binding,
                  try await conversations.conversation(id: scope.conversationID) != nil else {
                throw CocoaError(.fileReadNoPermission)
            }
            return TextReaderBytes(source: WorkspacePreviewByteSource(source: bytes.source, lease: lease), fingerprint: bytes.fingerprint)
        } catch { await lease.release(); throw error }
    }

    @MainActor static func source(document: WorkspaceFileChangePreview, artifact: ToolArtifactReference,
                                  scope: ChatInlineContentScope?, environment: AppEnvironment) -> TextReaderSource {
        TextReaderSource(kind: .workspaceFile, ownerID: scope?.conversationID.uuidString ?? "saved-preview",
            documentKey: artifact.id.uuidString, displayName: (document.path as NSString).lastPathComponent,
            format: (document.path as NSString).pathExtension, markdown: ["md", "markdown", "mdown", "mkd"].contains((document.path as NSString).pathExtension.lowercased()),
            isRemoteSnapshot: false, persistsPosition: false, hasNonTextContent: false,
            limits: ReaderLimits(chunkBytes: 64 * 1024), makeBytes: {
                // A complete digest-bound receipt already contains all bytes.
                // It cannot authorize reading any additional local path.
                if !document.truncated {
                    let data = Data(document.text.utf8)
                    guard data.count == document.byteCount, FloeDigest.sha256Hex(data) == document.sha256 else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    return TextReaderBytes(source: ReaderDataByteSource(data: data), fingerprint: document.sha256)
                }
                guard let scope else { throw CocoaError(.fileReadNoPermission) }
                return try await ownedBytes(document: document, artifact: artifact, scope: scope,
                    conversations: environment.conversationStore, runs: environment.runStore,
                    workspaces: SQLiteWorkspaceStore(database: environment.database), artifactRoot: FloeArtifactStore.root(),
                    acquireRoot: { workspace in try await environment.workspaceCenter.acquireMemorySourceRoot(workspace) })
            })
    }
}

#endif
