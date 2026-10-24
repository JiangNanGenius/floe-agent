// SPDX-License-Identifier: MPL-2.0
//
// G04BrowserWorkspacePorts — the REAL native workspace halves of the browser
// composition: the preview resource reader and the staged download sink.
//
// Both operate EXCLUSIVELY over the owner's authorized ACTUAL files: the
// exact private-task root that `LinuxWorkspaceAuthority` resolves from the
// ORIGINAL persisted record, guarded by the original `WorkspacePathGuard`
// (traversal/secret/`..` refusal, symlink-escape refusal via
// resolving-symlinks containment) and revalidated before and after every
// suspension against the ordinary persisted task + currently SELECTED
// workspace + the live native root epoch. A model-supplied absolute path,
// temp dir, foreign workspace or first-project guess is structurally
// impossible here: the accepted identity is only ever
// `PreviewWorkspaceRoot{owner, relativeRoot}` / `BrowserDownloadTicket`, and
// the closure that turns a task into a `WorkspaceFileService` is installed
// by trusted composition, never by a bridge payload.
//
// Managed project/SAF write layers require their OWN original source binding
// through the workspace source coordinator (Main's graph); until that edge
// exists for the browser ports these layers fail closed as typed misses —
// there is no content-URI-to-POSIX reinterpretation anywhere in this file.
import Foundation
#if canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#endif
import FloeCore
import FloeTools
import FloeWorkspace
import FloeBrowser

/// Owner -> WorkspaceFileService ladder shared by both ports. Resolution is
/// epoch-exact and store-backed; every call re-proves ownership AFTER its
/// own awaits so a query completion can never act on stale ownership.
struct G04BrowserWorkspaceLadder: Sendable {
    let epoch: UInt64
    let installed: G02InstalledComposition

    /// Revalidate the exact triple against the ORIGINAL records and return
    /// the guarded service for the task's CURRENT private-task root.
    func service(for owner: BrowserOwnerID, cancellation: CancellationToken) async throws -> WorkspaceFileService {
        try cancellation.throwIfCancelled()
        guard G02NativeRootEpoch.readback() == epoch,
              G02RuntimeComposition.shared.installedComposition === installed,
              installed.epoch == epoch,
              RunDomainFacade.current(epoch: epoch) != nil
        else { throw G04DocumentError.retired }
        do {
            guard let conversation = try await installed.cluster.conversationStore
                .conversation(id: owner.taskID), conversation.purpose == .ordinary
            else { throw G04DocumentError.ownerChanged }
            try cancellation.throwIfCancelled()
            let selected = try await installed.cluster.workspaceStore
                .workspaceID(conversationID: owner.taskID)
            guard selected == owner.workspaceID,
                  let workspace = try await installed.cluster.workspaceStore
                    .workspace(id: owner.workspaceID),
                  workspace.kind == .privateTask
            else { throw G04DocumentError.ownerChanged }
            try cancellation.throwIfCancelled()
            guard let binding = await LinuxWorkspaceAuthority.resolveWorkspace(
                conversationID: owner.taskID),
                binding.workspaceID == owner.workspaceID
            else { throw G04DocumentError.ownerChanged }
            try cancellation.throwIfCancelled()
            return WorkspaceFileService(guard: WorkspacePathGuard(rootURL: binding.rootURL))
        } catch let error as G04DocumentError {
            throw error
        } catch let error as FloeError where error == .cancelled {
            throw error
        } catch {
            throw G04DocumentError.ownerChanged
        }
    }

    func owner(forTask taskID: UUID) async -> BrowserOwnerID? {
        guard G02NativeRootEpoch.readback() == epoch,
              let selected = try? await installed.cluster.workspaceStore
                .workspaceID(conversationID: taskID)
        else { return nil }
        return BrowserOwnerID(taskID: taskID, workspaceID: selected, rootEpoch: epoch)
    }
}

// MARK: - Preview resource port (owner-authorized actual files only)

/// The `PreviewResourcePort` for `LocalPreviewServer`: every stat/read/list
/// runs through the original guard on the owner's private-task root. A
/// resolved node that escapes the root or IS a symlink answers as a typed
/// miss (empty read / nil stat), exactly as the module contract requires;
/// the server then answers an honest 404, never a 200 with fake bytes.
final class G04BrowserPreviewResourcePort: PreviewResourcePort, @unchecked Sendable {
    private let ladder: G04BrowserWorkspaceLadder
    /// Preview reads belong to the preview LEASE's owner operation; the
    /// lease token keeps cancellation honest per start/stop without a
    /// second store. The composition supplies it at coordinator wiring.
    private let cancellation = CancellationToken()

    init(ladder: G04BrowserWorkspaceLadder) {
        self.ladder = ladder
    }

    var leaseCancellation: CancellationToken { cancellation }

    private static let maximumListing = 512
    private static let maximumReadBytes = 64 * 1024

    private func composed(_ root: PreviewWorkspaceRoot, _ relativePath: String) -> String? {
        let trimmed = relativePath.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty || !root.relativeRoot.isEmpty else {
            // Empty composition = the workspace root itself, valid for
            // isDirectory/listing but never for stat/read.
            return nil
        }
        let base = root.relativeRoot.trimmingCharacters(in: .whitespaces)
        guard !base.hasPrefix("/"), !trimmed.hasPrefix("/") else { return nil }
        if trimmed.isEmpty { return base.isEmpty ? nil : base }
        if base.isEmpty { return trimmed }
        return base + "/" + trimmed
    }

    func isDirectory(_ root: PreviewWorkspaceRoot, relativePath: String) async throws -> Bool {
        let composedPath = composed(root, relativePath) ?? ""
        guard !composedPath.isEmpty else {
            // Empty composition = the task workspace root itself, and ONLY
            // the exact owner's bound root is probed; nothing else takes
            // this path.
            let service = try await ladder.service(for: root.owner, cancellation: cancellation)
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: service.guardResolver.rootURL.path,
                                                  isDirectory: &isDir) && isDir.boolValue
        }
        let service = try await ladder.service(for: root.owner, cancellation: cancellation)
        guard let url = try? service.guardResolver.resolve(composedPath) else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue, !Self.isSymlink(url) else { return false }
        return true
    }

    func stat(_ root: PreviewWorkspaceRoot, relativePath: String) async throws -> PreviewResourceInfo? {
        guard let composedPath = composed(root, relativePath) else { return nil }
        let service = try await ladder.service(for: root.owner, cancellation: cancellation)
        guard let url = try? service.guardResolver.resolve(composedPath),
              FileManager.default.fileExists(atPath: url.path),
              !Self.isSymlink(url) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes?[.size] as? NSNumber else { return nil }
        try await ladder.service(for: root.owner, cancellation: cancellation) // revalidate after IO
        return PreviewResourceInfo(byteCount: Int(size.int64Value))
    }

    func read(_ root: PreviewWorkspaceRoot, relativePath: String,
              offset: Int, length: Int) async throws -> Data {
        guard let composedPath = composed(root, relativePath) else { return Data() }
        let service = try await ladder.service(for: root.owner, cancellation: cancellation)
        guard let url = try? service.guardResolver.resolve(composedPath),
              !Self.isSymlink(url) else { return Data() }
        let boundedLength = max(0, min(length, Self.maximumReadBytes))
        guard boundedLength > 0, let handle = try? FileHandle(forReadingFrom: url) else {
            return Data()
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(max(0, offset)))
            let data = try handle.read(upToCount: boundedLength) ?? Data()
            // Revalidate AFTER the IO await boundary: a stale owner (deleted
            // task, moved workspace, new root) yields NO bytes.
            try await ladder.service(for: root.owner, cancellation: cancellation)
            return data
        } catch {
            return Data()
        }
    }

    func listing(_ root: PreviewWorkspaceRoot, relativePath: String) async throws -> [String] {
        let listingURL: URL
        if let composedPath = composed(root, relativePath) {
            let service = try await ladder.service(for: root.owner, cancellation: cancellation)
            guard let url = try? service.guardResolver.resolve(composedPath),
                  !Self.isSymlink(url) else { return [] }
            listingURL = url
        } else {
            // The task workspace root itself.
            let service = try await ladder.service(for: root.owner, cancellation: cancellation)
            listingURL = service.guardResolver.rootURL
        }
        // Ownership revalidation happened on BOTH branches above; enumerate
        // the admitted directory only.
        let entries = try? FileManager.default.contentsOfDirectory(
            at: listingURL, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        let names = (entries ?? []).map(\.lastPathComponent).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        return Array(names.prefix(Self.maximumListing))
    }

    /// The final node itself must not be a symlink: `resolve` already
    /// refuses symlink EXCAPES; an in-root symlink still violates the
    /// "serve the admitted file, not what it points at" preview rule, so
    /// symlinks are answered as misses here (the iOS original served the
    /// physical node only when it WAS the admitted file; android.webkit
    /// preview has no such promise to keep).
    private static func isSymlink(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let type = attributes?[.type] as? FileAttributeType, type == .typeSymbolicLink {
            return true
        }
        return false
    }
}

// MARK: - Download sink (staged bounded stream -> owner workspace, CAS/atomic)

/// The `BrowserDownloadSinkPort` production half. Bytes stream from the
/// Swift-side fetcher into a per-ticket staging file under the owner's
/// workspace; commit revalidates source/owner/version, fsyncs, verifies the
/// exact size, and performs an EXCLUSIVE rename — no overwrite without the
/// original conflict policy, no partial receipt on cancel/failure, and never
/// a whole-file RAM buffer. The coordinator (FloeBrowser) owns the running
/// SHA-256 and the byte cap; this sink re-enforces its own ceiling and the
/// original path guards at every boundary.
final class G04BrowserWorkspaceDownloadSink: BrowserDownloadSinkPort, @unchecked Sendable {
    private let ladder: G04BrowserWorkspaceLadder
    private let lock = NSLock()
    private struct Staged {
        let ticket: BrowserDownloadTicket
        let owner: BrowserOwnerID
        let stagingRelativePath: String
        let finalRelativePath: String
        var bytes: Int
    }
    private var staged: [String: Staged] = [:]
    /// Composition note so the coordinator's `onCommitted` signal (which
    /// carries only the receipt) can be routed back to the owning task.
    /// Set exactly once by the domain extension in the attach/retirement
    /// window; never written by a bridge payload.
    nonisolated(unsafe) var commitProofNote: (@Sendable (_ path: String, _ conversation: UUID) -> Void)?

    init(ladder: G04BrowserWorkspaceLadder) {
        self.ladder = ladder
    }

    var pendingStagingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return staged.count
    }

    func open(ticket: BrowserDownloadTicket) async throws -> String {
        // A missing current binding is a typed refusal, NEVER a fabricated
        // owner identity.
        guard let owner = await ladder.owner(forTask: ticket.taskID) else {
            throw BrowserDownloadError.sinkFailed(
                "the download task's workspace binding is no longer admitted")
        }
        guard ticket.maximumBytes > 0,
              !ticket.fileName.isEmpty, ticket.fileName != ".",
              ticket.fileName.range(of: #"[\\/:]"#, options: .regularExpression) == nil
        else { throw BrowserDownloadError.sinkFailed("the download ticket destination is not a safe file name") }
        let handle = "browser-download:\(ticket.id.uuidString)"
        let directory = ticket.relativeDirectory.trimmingCharacters(in: .whitespaces)
        guard !directory.hasPrefix("/"), !directory.isEmpty else {
            throw BrowserDownloadError.sinkFailed("the download directory must be workspace-relative")
        }
        let stagingRelative = directory + "/.staging/\(ticket.id.uuidString).part"
        let finalRelative = directory + "/" + ticket.fileName
        // Prove the guarded paths resolve for THIS owner before creating a
        // byte (secret names, traversal and escapes throw here, not later).
        let service = try await ladder.service(for: owner, cancellation: CancellationToken())
        _ = try service.guardResolver.resolve(stagingRelative)
        _ = try service.guardResolver.resolve(finalRelative)
        // Reuse refusal: a live staging file for the same ticket means the
        // previous attempt never settled; discard it honestly first.
        try? await removeStaged(owner: owner, relative: stagingRelative)
        lock.g04Locked {
            staged[handle] = Staged(ticket: ticket, owner: owner,
                                    stagingRelativePath: stagingRelative,
                                    finalRelativePath: finalRelative, bytes: 0)
        }
        // Create the staging file lazily on the first append; an admitted
        // but never-started ticket leaves nothing behind.
        return handle
    }

    func append(handle: String, bytes: Data) async throws {
        let item = try lock.g04Locked { () -> Staged in
            guard var item = staged[handle] else {
                throw BrowserDownloadError.unknownTicket
            }
            guard item.bytes + bytes.count <= item.ticket.maximumBytes,
                  bytes.count <= G04BrowserMailboxLimits.maximumCompletionBytes * 4 else {
                throw BrowserDownloadError.overCap(Int64(item.bytes + bytes.count))
            }
            item.bytes += bytes.count
            staged[handle] = item
            return item
        }
        let service = try await ladder.service(for: item.owner, cancellation: CancellationToken())
        let url = try service.guardResolver.resolve(item.stagingRelativePath)
        try Self.writeAppend(url: url, bytes: bytes, overCap: item.ticket.maximumBytes)
    }

    func commit(handle: String, sha256: String, expectedBytes: Int) async throws -> BrowserDownloadReceipt {
        let item = try lock.g04Locked { () -> Staged in
            guard let item = staged.removeValue(forKey: handle) else {
                throw BrowserDownloadError.unknownTicket
            }
            return item
        }
        do {
            guard sha256.count == 64, sha256.allSatisfy(\.isHexDigit),
                  item.bytes == expectedBytes, item.bytes >= 0
            else { throw BrowserDownloadError.sinkFailed("the staged bytes did not settle at the expected size") }
            // SOURCE/OWNER/VERSION revalidation immediately BEFORE commit:
            // the task must still be ordinary, still select the same
            // workspace, and the root epoch must still be the live one.
            let service = try await ladder.service(for: item.owner, cancellation: CancellationToken())
            let stagingURL = try service.guardResolver.resolve(item.stagingRelativePath)
            let finalURL = try service.guardResolver.resolve(item.finalRelativePath)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: stagingURL.path),
                  let size = attributes[.size] as? NSNumber, size.int64Value == Int64(expectedBytes)
            else {
                throw BrowserDownloadError.sinkFailed("the staged file is missing or short on disk")
            }
            try Self.fsync(stagingURL)
            // EXCLUSIVE publish: the original conflict policy refuses to
            // silently overwrite an existing workspace file.
            if FileManager.default.fileExists(atPath: finalURL.path) {
                throw BrowserDownloadError.sinkFailed(
                    "a file already exists at \(item.finalRelativePath); the download was not overwritten")
            }
            try FileManager.default.moveItem(at: stagingURL, to: finalURL)
            // FINAL proof: exact bytes on the published node (digest kept by
            // the coordinator's running hash over the SAME bytes streamed
            // into this file; the size proof here closes the rename window).
            guard let published = try? FileManager.default.attributesOfItem(atPath: finalURL.path),
                  let publishedSize = published[.size] as? NSNumber,
                  publishedSize.int64Value == Int64(expectedBytes) else {
                try? FileManager.default.removeItem(at: finalURL)
                throw BrowserDownloadError.sinkFailed("the published file failed its size proof")
            }
            try await ladder.service(for: item.owner, cancellation: CancellationToken())
            commitProofNote?(item.finalRelativePath, item.owner.taskID)
            return BrowserDownloadReceipt(
                relativePath: item.finalRelativePath,
                byteCount: expectedBytes,
                sha256: sha256.lowercased())
        } catch let error as BrowserDownloadError {
            try? await removeStaged(owner: item.owner, relative: item.stagingRelativePath)
            throw error
        } catch {
            try? await removeStaged(owner: item.owner, relative: item.stagingRelativePath)
            throw BrowserDownloadError.sinkFailed(error.localizedDescription)
        }
    }

    func discard(handle: String) async {
        let item = lock.g04Locked { staged.removeValue(forKey: handle) }
        guard let item else { return }
        try? await removeStaged(owner: item.owner, relative: item.stagingRelativePath)
    }

    /// Owner-exact cleanup used at release: drop every staging part owned by
    /// a released task (after the coordinator settled its actual IO).
    func discardAll(forTask taskID: UUID) async {
        let items = lock.g04Locked { () -> [Staged] in
            let handles = staged.keys.filter { staged[$0]!.ticket.taskID == taskID }
            return handles.compactMap { staged.removeValue(forKey: $0) }
        }
        for item in items {
            try? await removeStaged(owner: item.owner, relative: item.stagingRelativePath)
        }
    }

    private func removeStaged(owner: BrowserOwnerID, relative: String) async throws {
        let service = try await ladder.service(for: owner, cancellation: CancellationToken())
        let url = try service.guardResolver.resolve(relative)
        try? FileManager.default.removeItem(at: url)
    }

    private static func writeAppend(url: URL, bytes: Data, overCap: Int) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw BrowserDownloadError.sinkFailed("the staging file is not writable")
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: bytes)
            try handle.synchronize()
        } catch {
            throw BrowserDownloadError.sinkFailed("staging write failed")
        }
    }

    private static func fsync(_ url: URL) throws {
        #if canImport(Darwin)
        let descriptor = Darwin.open(url.path, O_RDONLY)
        #elseif canImport(Android)
        let descriptor = Android.open(url.path, O_RDONLY)
        #elseif canImport(Glibc)
        let descriptor = Glibc.open(url.path, O_RDONLY)
        #else
        let descriptor: Int32 = -1
        #endif
        guard descriptor >= 0 else {
            throw BrowserDownloadError.sinkFailed("the staged file cannot be verified on disk")
        }
        #if canImport(Darwin)
        defer { Darwin.close(descriptor) }
        _ = Darwin.fcntl(descriptor, F_FULLFSYNC)
        _ = Darwin.fsync(descriptor)
        #elseif canImport(Android)
        defer { Android.close(descriptor) }
        _ = Android.fsync(descriptor)
        #elseif canImport(Glibc)
        defer { Glibc.close(descriptor) }
        _ = Glibc.fsync(descriptor)
        #endif
    }
}
