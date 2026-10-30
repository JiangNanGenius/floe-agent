// SPDX-License-Identifier: MPL-2.0
// FloePersistence — Shared Documents store (S5 C4 local Files backend).
//
// A small, fully owned SQLite/GRDB store backing the Floe local Files
// provider location. It lives at a DEDICATED root inside the
// `group.org.floeagent.ios` App Group — never inside the main app database,
// the task database, credential storage, the Share inbox, or Notes/Canvas
// editor state. Both the app process and the File Provider extension process
// open the same file and rely on real SQLite write transactions (BEGIN
// IMMEDIATE) plus OS `flock` leases for cross-process mutual exclusion; no
// in-memory flag is claimed as a cross-process guarantee.
//
// Content ownership: committed bytes are immutable, addressed by
// `<item id>/<content version>` under the store's blob directory. Metadata
// (name, parent, versions) is transactional. Every mutation verifies an
// expected base version (compare-and-swap); a mismatch throws
// `.versionConflict` with the actual committed state. Staged writes are
// streamed with bounded buffers, fsynced, and atomically renamed into the
// blob directory; a cancel or disk error before commit preserves the prior
// committed bytes/version, and after commit the committed state is the truth
// (no fake cancellation rollback). An interruption between the blob rename
// and the journal commit leaves an unreferenced orphan that
// `recoverInterruptedOperations()` reclaims — only when it can lease the
// per-item lock exclusively, so a live committer is never disturbed.
//
// Enumeration: keyset pagination by (name COLLATE NOCASE, id) with an opaque
// page token; changes are journaled (insert/update/delete + tombstones) with
// a monotonic sequence that doubles as the per-domain sync anchor. The
// high-water sequence is persisted independently of live rows, so pruning
// the whole journal can move the expiry floor forward without ever moving
// the anchor backwards. Anchors below the journal retention floor report
// expiry honestly instead of returning a false clean diff; a change batch is
// read from one consistent SQLite snapshot (floor, high-water and rows), so
// a concurrent prune can neither skip changes silently nor expire a valid
// anchor mid-answer.
//
// Snapshots: `withLeasedContentSnapshot` pairs the exact committed item with
// the exact committed byte URL in one read under the per-item lease, and
// keeps the lease across the caller's copy, so a replace/delete/recovery
// pass cannot remove the bytes being copied. All streamed file I/O uses one
// preallocated POSIX buffer (never `FileHandle.readData` autorelease loops),
// enforces the per-item size ceiling on the bytes actually moved, and cleans
// up the destination it created on failure or cancellation.

import Foundation
import GRDB
import FloeCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Layout

/// On-disk layout of the Shared Documents backend. Blob paths are addressed
/// by validated item identity only; user-controlled names are never joined
/// into filesystem paths.
public enum SharedDocumentsStoreLayout {
    public static let appGroupID = "group.org.floeagent.ios"

    /// Default dedicated backend root inside the App Group container.
    public static func backendRoot(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Floe", isDirectory: true)
            .appendingPathComponent("SharedDocuments", isDirectory: true)
    }

    static func databaseURL(root: URL) -> URL {
        root.appendingPathComponent("store", isDirectory: true)
            .appendingPathComponent("shared_documents.sqlite")
    }

    static func blobsURL(root: URL) -> URL {
        root.appendingPathComponent("store", isDirectory: true)
            .appendingPathComponent("blobs", isDirectory: true)
    }

    static func stagingURL(root: URL) -> URL {
        root.appendingPathComponent("store", isDirectory: true)
            .appendingPathComponent("staging", isDirectory: true)
    }

    /// Single committed write per item may not exceed this size.
    public static let maxItemBytes: Int64 = 512 * 1024 * 1024
    /// Streamed staging chunk; bounds memory during copy+hash.
    public static let stageChunkBytes = 1 << 20
    /// Case-insensitive name uniqueness bound per folder.
    public static let maxChildrenPerFolder = 50_000
    /// Recursive delete bounds.
    public static let maxDeleteRecursionDepth = 64
    public static let maxDeleteItemCount = 20_000
    /// Enumeration page bounds.
    public static let defaultPageSize = 200
    public static let maxPageSize = 500
    /// Change journal batch bounds.
    public static let defaultChangeBatch = 200
    public static let maxChangeBatch = 1_000
    /// User-visible filename bound.
    public static let maxNameLength = 255
}

// MARK: - Model

public enum SharedDocumentsItemKind: String, Sendable, Equatable {
    case file
    case folder
}

public struct SharedDocumentsItem: Sendable, Equatable {
    /// Stable provider-assigned identity (UUID string). Never derived from
    /// the filename, so renames never change identity.
    public var id: String
    /// "root" for top-level items, otherwise the parent's stable id.
    public var parentID: String
    public var name: String
    public var kind: SharedDocumentsItemKind
    /// Starts at 1 on first content commit; folders stay at 0. Bumps only.
    public var contentVersion: Int
    /// Starts at 1; bumps on rename/move. Bumps only.
    public var metadataVersion: Int
    public var byteCount: Int64
    /// Lowercase SHA-256 of the committed content; nil for folders.
    public var sha256: String?
    public var creationDate: Date
    public var modificationDate: Date

    public init(
        id: String,
        parentID: String,
        name: String,
        kind: SharedDocumentsItemKind,
        contentVersion: Int,
        metadataVersion: Int,
        byteCount: Int64,
        sha256: String?,
        creationDate: Date,
        modificationDate: Date
    ) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.kind = kind
        self.contentVersion = contentVersion
        self.metadataVersion = metadataVersion
        self.byteCount = byteCount
        self.sha256 = sha256
        self.creationDate = creationDate
        self.modificationDate = modificationDate
    }

    /// The committed pair to supply as the expected base of a mutation.
    public var versions: SharedDocumentsExpectedVersions {
        SharedDocumentsExpectedVersions(content: contentVersion, metadata: metadataVersion)
    }
}

/// Compare-and-swap base versions for one mutation.
public struct SharedDocumentsExpectedVersions: Sendable, Equatable {
    public var content: Int
    public var metadata: Int

    public init(content: Int, metadata: Int) {
        self.content = content
        self.metadata = metadata
    }
}

public struct SharedDocumentsItemVersions: Sendable, Equatable {
    public var content: Int
    public var metadata: Int

    public init(content: Int, metadata: Int) {
        self.content = content
        self.metadata = metadata
    }
}

public struct SharedDocumentsContentStage: Sendable, Equatable {
    public let operationID: UUID
    /// Exclusive staged file. Not part of the provider hierarchy.
    public let stagedFileURL: URL
    public let byteCount: Int64
    public let sha256: String
}

public enum SharedDocumentsChangeKind: String, Sendable, Equatable {
    case insert
    case update
    case delete
}

public struct SharedDocumentsChange: Sendable, Equatable {
    public var sequence: Int
    public var itemID: String
    public var kind: SharedDocumentsChangeKind
    /// Post-change metadata snapshot (delete carries the last known values).
    public var item: SharedDocumentsItem
}

public struct SharedDocumentsRecoveryReport: Sendable, Equatable {
    /// Abandoned staging directories reclaimed (dead lease holders).
    public var reclaimedStages: Int
    /// Unreferenced committed blobs reclaimed.
    public var reclaimedOrphans: Int
    /// Items whose recorded content file is missing. Surfaced, not hidden:
    /// callers decide how to present unrecoverable local bytes.
    public var missingContentItemIDs: [String]

    public init(reclaimedStages: Int, reclaimedOrphans: Int, missingContentItemIDs: [String]) {
        self.reclaimedStages = reclaimedStages
        self.reclaimedOrphans = reclaimedOrphans
        self.missingContentItemIDs = missingContentItemIDs
    }
}

// MARK: - Errors

public enum SharedDocumentsError: Error, Sendable, Equatable, LocalizedError {
    case invalidName(String)
    case invalidItemID(String)
    case invalidCursor
    case itemNotFound(String)
    case parentNotFound(String)
    case parentNotAFolder(String)
    case folderNotEmpty(String)
    case deleteLimitExceeded(String)
    case nameCollision(String)
    case versionConflict(itemID: String, expected: SharedDocumentsExpectedVersions, actual: SharedDocumentsItemVersions)
    case contentDigestMismatch(expected: String, actual: String)
    case contentTooLarge(maxBytes: Int64)
    case specialFileRefused
    case cancelled
    case storageCorrupted(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName: "Invalid file name"
        case .invalidItemID: "Invalid item identifier"
        case .invalidCursor: "Invalid enumeration cursor"
        case .itemNotFound: "Item not found"
        case .parentNotFound: "Folder not found"
        case .parentNotAFolder: "Not a folder"
        case .folderNotEmpty: "Folder is not empty"
        case .deleteLimitExceeded: "Folder exceeds the safe-delete limit"
        case .nameCollision: "An item with this name already exists here"
        case .versionConflict: "The file changed elsewhere; refresh and try again"
        case .contentDigestMismatch: "Content checksum mismatch"
        case .contentTooLarge(let max): "Content exceeds the \(max)-byte limit"
        case .specialFileRefused: "Only regular files and folders are supported"
        case .cancelled: "Cancelled"
        case .storageCorrupted: "Shared Documents storage is corrupted"
        }
    }
}

/// Cancellation token checked between staged chunks and before commit.
public protocol SharedDocumentsOperationCancellation: Sendable {
    func isCancelled() -> Bool
}

// MARK: - Leased content snapshot

/// Immutable, lease-protected view of one committed file. The item metadata
/// and the content URL are read in a single transaction while the per-item
/// lease is held, so `contentVersion`/`sha256` always describe exactly the
/// bytes at `contentURL`. Committed bytes are immutable and the lease is
/// held across the consumer's copy, so replace/delete/recovery cannot race
/// byte deletion underneath the reader.
public struct SharedDocumentsLeasedContentSnapshot: Sendable, Equatable {
    public let item: SharedDocumentsItem
    /// Absolute URL of the committed, immutable bytes for `item.contentVersion`.
    public let contentURL: URL

    public init(item: SharedDocumentsItem, contentURL: URL) {
        self.item = item
        self.contentURL = contentURL
    }

    public var contentVersion: Int { item.contentVersion }
    public var sha256: String? { item.sha256 }
    public var byteCount: Int64 { item.byteCount }
}

// MARK: - Enumeration signal targets

/// Framework-neutral description of a container the app or extension asks
/// the system to re-enumerate after a committed mutation. The real
/// `NSFileProviderManager.signalEnumerator` call lives behind the
/// `signalProvider` seam so prepared tests can record intents without a
/// mounted domain. Signalling is advisory and idempotent: a signal failure
/// never changes the committed truth and never duplicates committed data.
public struct SharedDocumentsSignalContainer: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable, Equatable, Hashable {
        case item
        case root
        case workingSet
    }

    public let kind: Kind
    /// Provider item identifier for `.item`; the stable root id for `.root`.
    public let rawIdentifier: String

    public init(kind: Kind, rawIdentifier: String) {
        self.kind = kind
        self.rawIdentifier = rawIdentifier
    }

    public static let workingSet = SharedDocumentsSignalContainer(
        kind: .workingSet,
        rawIdentifier: "working-set"
    )
    public static let rootContainer = SharedDocumentsSignalContainer(
        kind: .root,
        rawIdentifier: SharedDocumentsIdentity.rootItemID
    )

    public static func item(_ id: String) -> SharedDocumentsSignalContainer {
        SharedDocumentsSignalContainer(kind: .item, rawIdentifier: id)
    }
}

// MARK: - Bounded streamed file I/O

/// Single-preallocation POSIX streaming for user-file bytes. This mirrors
/// `FloeDigest.streamBytes`: `FileHandle.readData(ofLength:` retains one
/// autoreleased buffer per chunk on Darwin, so a long synchronous copy of a
/// large file grows resident memory with the file size; the fixed buffer
/// here stays flat. Every loop checks the cancellation token between chunks
/// and translates it (and the `CancellationError` thrown by digest helpers)
/// into `SharedDocumentsError.cancelled`. Read/write failures surface as
/// `FloeFileIOError` with the real errno, never as a digest or success
/// verdict. `copyRegularFile` removes the destination it created when the
/// copy fails or is cancelled — the destination is owned temp storage.
public enum SharedDocumentsStreamedIO {
    static let ioChunkBytes = 1 << 20

    public static func throwIfCancelled(
        _ cancellation: (any SharedDocumentsOperationCancellation)?
    ) throws {
        if cancellation?.isCancelled() == true { throw SharedDocumentsError.cancelled }
    }

    /// Translates the cancellation vocabulary shared with FloeCore digest
    /// helpers into the store's typed cancellation.
    static func translateCancellation(_ error: Error) -> Error {
        if error is CancellationError { return SharedDocumentsError.cancelled }
        return error
    }

    /// Validates that `url` names a readable regular file (never a symlink,
    /// directory, or special file) within the per-item size ceiling. The
    /// ceiling is re-enforced on the bytes actually streamed, because
    /// reported sizes can lie; this is only the cheap early refusal.
    public static func validateRegularFileSource(_ url: URL) throws {
        guard url.isFileURL else { throw SharedDocumentsError.specialFileRefused }
        #if canImport(Darwin) || canImport(Glibc)
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw FloeFileIOError(
                stage: .open,
                posixErrno: errno,
                detail: "source file cannot be inspected",
                domain: NSPOSIXErrorDomain,
                code: Int(errno)
            )
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw SharedDocumentsError.specialFileRefused
        }
        #else
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SharedDocumentsError.specialFileRefused
        }
        #endif
        let reportedSize = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
        guard reportedSize <= SharedDocumentsStoreLayout.maxItemBytes else {
            throw SharedDocumentsError.contentTooLarge(maxBytes: SharedDocumentsStoreLayout.maxItemBytes)
        }
    }

    /// Streams `url` through `handle` with one preallocated buffer.
    /// `handle` receives each chunk in order; throwing aborts the stream.
    public static func streamRegularFile(
        _ url: URL,
        cancellation: (any SharedDocumentsOperationCancellation)?,
        handle: (Data) async throws -> Void
    ) async throws {
        try validateRegularFileSource(url)
        try throwIfCancelled(cancellation)
        #if canImport(Darwin) || canImport(Glibc)
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            let code = errno
            throw FloeFileIOError(
                stage: .open,
                posixErrno: code,
                detail: "source file cannot be opened",
                domain: NSPOSIXErrorDomain,
                code: Int(code)
            )
        }
        defer { _ = close(descriptor) }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: ioChunkBytes,
            alignment: MemoryLayout<UInt8>.alignment
        )
        defer { buffer.deallocate() }
        while true {
            try throwIfCancelled(cancellation)
            let count = read(descriptor, buffer, ioChunkBytes)
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                throw FloeFileIOError(
                    stage: .read,
                    posixErrno: code,
                    detail: "source file read failed",
                    domain: NSPOSIXErrorDomain,
                    code: Int(code)
                )
            }
            if count == 0 { break }
            let chunk = Data(bytes: buffer, count: count)
            try await handle(chunk)
        }
        #else
        let handleIO = try FileHandle(forReadingFrom: url)
        defer { try? handleIO.close() }
        while true {
            try throwIfCancelled(cancellation)
            let chunk = try handleIO.read(upToCount: ioChunkBytes) ?? Data()
            if chunk.isEmpty { break }
            try await handle(chunk)
        }
        #endif
    }

    /// Copies `source` to `destination` (created 0600, truncated, fsynced)
    /// with bounded buffers. On failure or cancellation the partially
    /// written destination — owned temp storage created here — is removed
    /// before the error propagates.
    public static func copyRegularFile(
        _ source: URL,
        to destination: URL,
        cancellation: (any SharedDocumentsOperationCancellation)?,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) async throws {
        try validateRegularFileSource(source)
        try throwIfCancelled(cancellation)
        #if canImport(Darwin) || canImport(Glibc)
        let input = open(source.path, O_RDONLY)
        guard input >= 0 else {
            let code = errno
            throw FloeFileIOError(
                stage: .open,
                posixErrno: code,
                detail: "source file cannot be opened",
                domain: NSPOSIXErrorDomain,
                code: Int(code)
            )
        }
        let output = open(destination.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard output >= 0 else {
            let code = errno
            _ = close(input)
            throw FloeFileIOError(
                stage: .open,
                posixErrno: code,
                detail: "destination cannot be created",
                domain: NSPOSIXErrorDomain,
                code: Int(code)
            )
        }
        var copied: Int64 = 0
        var copyError: Error?
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: ioChunkBytes,
            alignment: MemoryLayout<UInt8>.alignment
        )
        defer { buffer.deallocate() }
        copyLoop: while true {
            do { try throwIfCancelled(cancellation) } catch {
                copyError = error
                break
            }
            let count = read(input, buffer, ioChunkBytes)
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                copyError = FloeFileIOError(
                    stage: .read,
                    posixErrno: code,
                    detail: "source file read failed",
                    domain: NSPOSIXErrorDomain,
                    code: Int(code)
                )
                break
            }
            if count == 0 { break }
            var written = 0
            while written < count {
                let result = write(output, buffer.advanced(by: written), count - written)
                if result < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    copyError = FloeFileIOError(
                        stage: .read,
                        posixErrno: code,
                        detail: "destination write failed",
                        domain: NSPOSIXErrorDomain,
                        code: Int(code)
                    )
                    break copyLoop
                }
                written += result
            }
            copied += Int64(count)
            guard copied <= SharedDocumentsStoreLayout.maxItemBytes else {
                copyError = SharedDocumentsError.contentTooLarge(
                    maxBytes: SharedDocumentsStoreLayout.maxItemBytes
                )
                break
            }
            progress?(copied)
        }
        if copyError == nil, fsync(output) != 0 {
            let code = errno
            copyError = FloeFileIOError(
                stage: .read,
                posixErrno: code,
                detail: "destination flush failed",
                domain: NSPOSIXErrorDomain,
                code: Int(code)
            )
        }
        _ = close(input)
        _ = close(output)
        if let copyError {
            try? FileManager.default.removeItem(at: destination)
            throw copyError
        }
        #else
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            try throwIfCancelled(cancellation)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw rethrowCancellation(error)
        }
        #endif
    }
}

// MARK: - Store protocol

public protocol SharedDocumentsStore: Sendable {
    func item(id: String) async throws -> SharedDocumentsItem
    func item(parentID: String, name: String) async throws -> SharedDocumentsItem?
    /// Absolute URL of the committed content for a live file item; nil for
    /// folders. Callers must treat it as read-only and copy before handing
    /// it to any consumer that takes ownership.
    func committedContentURL(id: String) async throws -> URL?
    func children(
        parentID: String,
        cursorToken: Data?,
        limit: Int
    ) async throws -> (items: [SharedDocumentsItem], nextCursorToken: Data?)
    /// Working-set listing: every live item across the hierarchy, keyset
    /// paged by the same (name COLLATE NOCASE, id) order.
    func allItems(
        cursorToken: Data?,
        limit: Int
    ) async throws -> (items: [SharedDocumentsItem], nextCursorToken: Data?)
    func allLiveItems() async throws -> [SharedDocumentsItem]

    func beginContentStage(cancellation: (any SharedDocumentsOperationCancellation)?) async throws -> UUID
    func writeContent(_ data: Data, operationID: UUID, cancellation: (any SharedDocumentsOperationCancellation)?) async throws
    func finishContentStage(operationID: UUID, cancellation: (any SharedDocumentsOperationCancellation)?) async throws -> SharedDocumentsContentStage
    func discardContentStage(operationID: UUID) async throws

    /// Streams a regular file at `sourceURL` into a leased stage with bounded
    /// buffers and chunk-boundary cancellation, verifying regular-file type
    /// and the per-item size ceiling on the bytes actually read. The staged
    /// descriptor is finished (fsync + digest) and ready to commit; on any
    /// failure or cancellation the stage is discarded. One real
    /// implementation shared by the extension bridge and the app export
    /// path — never a per-caller copy loop.
    func stageContentFromURL(
        _ sourceURL: URL,
        cancellation: (any SharedDocumentsOperationCancellation)?,
        progress: (@Sendable (Int64) -> Void)?
    ) async throws -> SharedDocumentsContentStage

    /// Creates a file (with staged content) or folder under `parentID`.
    /// Name collisions throw `.nameCollision`; the caller decides whether to
    /// surface a provider collision or pick a new name (no silent rename).
    /// Cancellation is checked at admission and inside the committing
    /// transaction; a pre-commit failure leaves the store untouched.
    @discardableResult
    func commitCreate(
        parentID: String,
        name: String,
        kind: SharedDocumentsItemKind,
        stage: SharedDocumentsContentStage?,
        cancellation: (any SharedDocumentsOperationCancellation)?
    ) async throws -> SharedDocumentsItem

    /// Replaces content; bumps `contentVersion`. CAS on the expected versions.
    /// A leftover file at exactly the next version can only be an orphan from
    /// a crash between this rename and the committing transaction, so it is
    /// removed under the lease: the retry converges instead of colliding
    /// forever, and versions stay exact.
    @discardableResult
    func commitReplace(
        id: String,
        stage: SharedDocumentsContentStage,
        expected: SharedDocumentsExpectedVersions,
        cancellation: (any SharedDocumentsOperationCancellation)?
    ) async throws -> SharedDocumentsItem

    /// Rename/move; bumps `metadataVersion`. CAS on the expected versions.
    @discardableResult
    func commitMetadata(
        id: String,
        newName: String?,
        newParentID: String?,
        expected: SharedDocumentsExpectedVersions,
        cancellation: (any SharedDocumentsOperationCancellation)?
    ) async throws -> SharedDocumentsItem

    /// ONE combined metadata+content commit for the FileProvider
    /// `modifyItem` contract (the plist advertises atomic changes): the
    /// staged bytes publish at the next content version and the name/parent
    /// move commit in a single SQLite transaction with one CAS check and one
    /// journal row. Any failure or cancellation rolls the transaction back:
    /// the prior committed bytes, name and versions are untouched (the
    /// renamed staged bytes become an unreferenced orphan that recovery
    /// reclaims under the lease).
    @discardableResult
    func commitModify(
        id: String,
        newName: String?,
        newParentID: String?,
        stage: SharedDocumentsContentStage,
        expected: SharedDocumentsExpectedVersions,
        cancellation: (any SharedDocumentsOperationCancellation)?
    ) async throws -> SharedDocumentsItem

    /// Tombstones the item (and bounded descendants for recursive deletes).
    func commitDelete(
        id: String,
        expected: SharedDocumentsExpectedVersions,
        recursive: Bool,
        cancellation: (any SharedDocumentsOperationCancellation)?
    ) async throws -> (deletedIDs: [String], byteCount: Int64)

    /// Append-only restore: copies the recorded `targetContentVersion` bytes
    /// into a NEW content version (history is never rewritten).
    @discardableResult
    func restoreContent(
        id: String,
        targetContentVersion: Int,
        expected: SharedDocumentsExpectedVersions,
        cancellation: (any SharedDocumentsOperationCancellation)?
    ) async throws -> SharedDocumentsItem

    /// Reads the committed item and its exact content URL in one transaction
    /// while holding the per-item lease, then runs `body` with the lease
    /// still held. Replace/delete/recovery therefore cannot remove the bytes
    /// mid-copy, and the returned metadata always describes exactly the
    /// bytes at the snapshot URL.
    func withLeasedContentSnapshot<T: Sendable>(
        id: String,
        cancellation: (any SharedDocumentsOperationCancellation)?,
        _ body: @Sendable (SharedDocumentsLeasedContentSnapshot) async throws -> T
    ) async throws -> T

    func currentAnchor() async throws -> Data
    /// Changes strictly after `anchor`, bounded by `limit`. Floor, persisted
    /// high-water and rows come from one consistent SQLite read snapshot; a
    /// read error throws (never a false empty diff), an anchor below the
    /// floor or above the high-water reports `.invalidCursor`.
    func changes(anchor: Data, limit: Int) async throws -> (changes: [SharedDocumentsChange], nextAnchor: Data, more: Bool)
    /// Deletes journal rows older than `cutoff` and advances the anchor
    /// floor; anchors below the floor then report expiry. The high-water is
    /// monotonic: pruning every row never moves the anchor backwards.
    @discardableResult
    func pruneChanges(olderThan cutoff: Date) async throws -> Int
    func anchorExpiryFloor() async throws -> Int

    func recoverInterruptedOperations() async throws -> SharedDocumentsRecoveryReport
    func close() async throws
}

// MARK: - SQLite implementation

/// Owns the injected Foundation manager behind one synchronous I/O boundary.
/// GRDB transaction closures and the store actor may call this object from
/// different executors. The manager never escapes, and every call into it is
/// protected by the same lock; no lock is held across an await or a DB call.
/// This does not replace the per-item cross-process file lease or SQL CAS.
final class SharedDocumentsFileIO: @unchecked Sendable {
    private let manager: FileManager
    private let lock = NSLock()

    init(manager: FileManager) { self.manager = manager }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool) throws {
        try synchronized { try manager.createDirectory(at: url, withIntermediateDirectories: createIntermediates) }
    }

    @discardableResult
    func createFile(atPath path: String, contents: Data?) -> Bool {
        synchronized { manager.createFile(atPath: path, contents: contents) }
    }

    func fileExists(atPath path: String) -> Bool {
        synchronized { manager.fileExists(atPath: path) }
    }

    func contentsOfDirectory(atPath path: String) throws -> [String] {
        try synchronized { try manager.contentsOfDirectory(atPath: path) }
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try synchronized { try manager.moveItem(at: source, to: destination) }
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try synchronized { try manager.copyItem(at: source, to: destination) }
    }

    func removeItem(at url: URL) throws {
        try synchronized { try manager.removeItem(at: url) }
    }
}

/// Standalone file-backed store. Owns its own `DatabasePool` and schema
/// (schema version 1, private to this store) — intentionally NOT registered
/// in the shared `DatabaseManager` migration chain, because the File Provider
/// extension process opens this file directly and user-file I/O must never
/// route through the task database.
public actor SQLiteSharedDocumentsStore: SharedDocumentsStore {
    public nonisolated let rootURL: URL
    private let pool: DatabasePool
    private nonisolated let fileManager: SharedDocumentsFileIO
    nonisolated let blobRoot: URL
    nonisolated let stagingRoot: URL
    private var openStages: [UUID: OpenStage] = [:]
    private(set) var storageSuspended = false
    private var suspensionGeneration: UInt64 = 0
    private var suspendedStageIDs: Set<UUID> = []
    private var activeItemLeases = 0
    private var leaseDrainWaiters: [CheckedContinuation<Void, Never>] = []

    private struct OpenStage {
        let directoryURL: URL
        let contentURL: URL
        let contentHandle: FileHandle
        let lockHandle: FileHandle
        let budget: StorageOperationLease
        var bytesWritten: Int64
    }

    public init(root: URL, fileManager: FileManager = .default) throws {
        self.rootURL = root
        let fileIO = SharedDocumentsFileIO(manager: fileManager)
        self.fileManager = fileIO
        let storeRoot = root.appendingPathComponent("store", isDirectory: true)
        self.blobRoot = SharedDocumentsStoreLayout.blobsURL(root: root)
        self.stagingRoot = SharedDocumentsStoreLayout.stagingURL(root: root)
        try fileIO.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        try fileIO.createDirectory(at: blobRoot, withIntermediateDirectories: true)
        try fileIO.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        var configuration = Configuration()
        configuration.observesSuspensionNotifications = true
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        self.pool = try DatabasePool(
            path: SharedDocumentsStoreLayout.databaseURL(root: root).path,
            configuration: configuration
        )
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_shared_documents") { db in
            try db.execute(sql: """
                CREATE TABLE shared_documents_meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE shared_documents_items (
                    id TEXT PRIMARY KEY,
                    parent_id TEXT NOT NULL,
                    name TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    content_version INTEGER NOT NULL DEFAULT 0,
                    metadata_version INTEGER NOT NULL DEFAULT 0,
                    byte_count INTEGER NOT NULL DEFAULT 0,
                    sha256 TEXT,
                    content_path TEXT,
                    creation_date TEXT NOT NULL,
                    modification_date TEXT NOT NULL,
                    deleted INTEGER NOT NULL DEFAULT 0,
                    change_seq INTEGER NOT NULL DEFAULT 0
                )
                """)
            try db.execute(sql: """
                CREATE INDEX shared_documents_items_parent
                ON shared_documents_items(parent_id, deleted, name COLLATE NOCASE, id)
                """)
            try db.execute(sql: """
                CREATE TABLE shared_documents_changes (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    item_id TEXT NOT NULL,
                    change_type TEXT NOT NULL,
                    name TEXT NOT NULL,
                    parent_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    content_version INTEGER NOT NULL DEFAULT 0,
                    metadata_version INTEGER NOT NULL DEFAULT 0,
                    byte_count INTEGER NOT NULL DEFAULT 0,
                    sha256 TEXT,
                    change_time TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE INDEX shared_documents_changes_seq
                ON shared_documents_changes(seq)
                """)
            try db.execute(sql: """
                INSERT INTO shared_documents_meta(key, value) VALUES ('schema_version', '1')
                """)
            try db.execute(sql: """
                INSERT INTO shared_documents_meta(key, value) VALUES ('anchor_floor_seq', '0')
                """)
        }
        try migrator.migrate(pool)
    }

    // MARK: Reads

    public func item(id: String) async throws -> SharedDocumentsItem {
        try Self.validateItemID(id)
        if id == SharedDocumentsIdentity.rootItemID {
            return SharedDocumentsIdentity.rootItem
        }
        return try await read { db in
            guard let row = try Self.fetchLiveRow(db, id: id) else {
                throw SharedDocumentsError.itemNotFound(id)
            }
            return try Self.decodeItem(row)
        }
    }

    public func item(parentID: String, name: String) async throws -> SharedDocumentsItem? {
        try Self.validateItemID(parentID)
        try Self.validateName(name)
        return try await read { db in
            guard let row = try Row.fetchOne(
                db, sql: """
                    SELECT * FROM shared_documents_items
                    WHERE parent_id = ? AND deleted = 0 AND name = ? COLLATE NOCASE
                    """,
                arguments: [parentID, name]
            ) else {
                return nil
            }
            return try Self.decodeItem(row)
        }
    }

    public func committedContentURL(id: String) async throws -> URL? {
        try Self.validateItemID(id)
        guard id != SharedDocumentsIdentity.rootItemID else { return nil }
        let item = try await self.item(id: id)
        guard item.kind == .file else { return nil }
        let url = committedBlobURL(itemID: id, contentVersion: item.contentVersion)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    public func children(
        parentID: String,
        cursorToken: Data?,
        limit: Int
    ) async throws -> (items: [SharedDocumentsItem], nextCursorToken: Data?) {
        try Self.validateItemID(parentID)
        let pageSize = min(max(limit, 1), SharedDocumentsStoreLayout.maxPageSize)
        let cursor = try cursorToken.map { try Self.parseCursor($0) }
        return try await read { db in
            let rows: [Row]
            if let cursor {
                rows = try Row.fetchAll(
                    db, sql: """
                        SELECT * FROM shared_documents_items
                        WHERE parent_id = ? AND deleted = 0
                          AND (name COLLATE NOCASE > ? OR (name COLLATE NOCASE = ? AND id > ?))
                        ORDER BY name COLLATE NOCASE, id
                        LIMIT ?
                        """,
                    arguments: [parentID, cursor.name, cursor.name, cursor.id, pageSize + 1]
                )
            } else {
                rows = try Row.fetchAll(
                    db, sql: """
                        SELECT * FROM shared_documents_items
                        WHERE parent_id = ? AND deleted = 0
                        ORDER BY name COLLATE NOCASE, id
                        LIMIT ?
                        """,
                    arguments: [parentID, pageSize + 1]
                )
            }
            let page = Array(rows.prefix(pageSize))
            let items = try page.map { try Self.decodeItem($0) }
            if rows.count > pageSize, let last = items.last {
                return (items, try Self.makeCursor(name: last.name, id: last.id))
            }
            return (items, nil)
        }
    }

    public func allItems(
        cursorToken: Data?,
        limit: Int
    ) async throws -> (items: [SharedDocumentsItem], nextCursorToken: Data?) {
        let pageSize = min(max(limit, 1), SharedDocumentsStoreLayout.maxPageSize)
        let cursor = try cursorToken.map { try Self.parseCursor($0) }
        return try await read { db in
            let rows: [Row]
            if let cursor {
                rows = try Row.fetchAll(
                    db, sql: """
                        SELECT * FROM shared_documents_items
                        WHERE deleted = 0
                          AND (name COLLATE NOCASE > ? OR (name COLLATE NOCASE = ? AND id > ?))
                        ORDER BY name COLLATE NOCASE, id
                        LIMIT ?
                        """,
                    arguments: [cursor.name, cursor.name, cursor.id, pageSize + 1]
                )
            } else {
                rows = try Row.fetchAll(
                    db, sql: """
                        SELECT * FROM shared_documents_items
                        WHERE deleted = 0
                        ORDER BY name COLLATE NOCASE, id
                        LIMIT ?
                        """,
                    arguments: [pageSize + 1]
                )
            }
            let page = Array(rows.prefix(pageSize))
            let items = try page.map { try Self.decodeItem($0) }
            if rows.count > pageSize, let last = items.last {
                return (items, try Self.makeCursor(name: last.name, id: last.id))
            }
            return (items, nil)
        }
    }

    public func allLiveItems() async throws -> [SharedDocumentsItem] {
        try await read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT * FROM shared_documents_items WHERE deleted = 0 ORDER BY name COLLATE NOCASE, id"
            )
            return try rows.map { try Self.decodeItem($0) }
        }
    }

    // MARK: Staging

    public func beginContentStage(
        cancellation: (any SharedDocumentsOperationCancellation)? = nil
    ) async throws -> UUID {
        guard !storageSuspended else { throw SharedDocumentsError.cancelled }
        let generation = suspensionGeneration
        let budget = try await StorageOperationBudget.begin()
        var adoptedBudget = false
        defer { if !adoptedBudget { budget.finish() } }
        guard !storageSuspended, generation == suspensionGeneration else { throw SharedDocumentsError.cancelled }
        try budget.check()
        if cancellation?.isCancelled() == true { throw SharedDocumentsError.cancelled }
        let operationID = UUID()
        let dir = stagingRoot.appendingPathComponent(operationID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let contentURL = dir.appendingPathComponent("content")
        let lockURL = dir.appendingPathComponent("lock")
        fileManager.createFile(atPath: lockURL.path, contents: nil)
        let lockHandle = try FileHandle(forUpdating: lockURL)
        guard Self.acquireExclusiveLock(lockHandle) else {
            try? lockHandle.close()
            throw SharedDocumentsError.storageCorrupted("staged lock contested at create")
        }
        let contentHandle: FileHandle
        do {
            // The content file does not exist yet. Create it exclusively
            // while holding this stage's lease; never truncate or follow an
            // unexpected existing leaf, and keep ownership of the descriptor.
            contentHandle = try Self.createOwnedStageContentHandle(at: contentURL)
        } catch {
            try? lockHandle.close()
            try? fileManager.removeItem(at: dir)
            throw error
        }
        openStages[operationID] = OpenStage(
            directoryURL: dir,
            contentURL: contentURL,
            contentHandle: contentHandle,
            lockHandle: lockHandle,
            budget: budget,
            bytesWritten: 0
        )
        adoptedBudget = true
        return operationID
    }

    public func writeContent(
        _ data: Data,
        operationID: UUID,
        cancellation: (any SharedDocumentsOperationCancellation)? = nil
    ) async throws {
        guard !storageSuspended else { throw SharedDocumentsError.cancelled }
        guard var stage = openStages[operationID] else {
            if suspendedStageIDs.contains(operationID) { throw SharedDocumentsError.cancelled }
            throw SharedDocumentsError.storageCorrupted("unknown staging operation \(operationID.uuidString)")
        }
        try stage.budget.check()
        if cancellation?.isCancelled() == true { throw SharedDocumentsError.cancelled }
        let newTotal = stage.bytesWritten + Int64(data.count)
        guard newTotal <= SharedDocumentsStoreLayout.maxItemBytes else {
            throw SharedDocumentsError.contentTooLarge(maxBytes: SharedDocumentsStoreLayout.maxItemBytes)
        }
        try stage.contentHandle.write(contentsOf: data)
        stage.bytesWritten = newTotal
        openStages[operationID] = stage
    }

    public func finishContentStage(
        operationID: UUID,
        cancellation: (any SharedDocumentsOperationCancellation)? = nil
    ) async throws -> SharedDocumentsContentStage {
        guard !storageSuspended else { throw SharedDocumentsError.cancelled }
        guard let stage = openStages[operationID] else {
            if suspendedStageIDs.contains(operationID) { throw SharedDocumentsError.cancelled }
            throw SharedDocumentsError.storageCorrupted("unknown staging operation \(operationID.uuidString)")
        }
        try stage.budget.check()
        if cancellation?.isCancelled() == true { throw SharedDocumentsError.cancelled }
        try stage.contentHandle.synchronize()
        // FloeDigest throws raw CancellationError when `isCancelled` fires;
        // the store's cancellation vocabulary is `SharedDocumentsError.cancelled`
        // so the bridge can map it to NSUserCancelledError (not cannotSynchronize).
        let digest: String
        do {
            digest = try FloeDigest.sha256Hex(
                ofFileAt: stage.contentURL,
                chunkSize: SharedDocumentsStoreLayout.stageChunkBytes,
                isCancelled: { cancellation?.isCancelled() == true }
            )
        } catch let error as CancellationError {
            throw SharedDocumentsError.cancelled
        }
        return SharedDocumentsContentStage(
            operationID: operationID,
            stagedFileURL: stage.contentURL,
            byteCount: stage.bytesWritten,
            sha256: digest
        )
    }

    public func discardContentStage(operationID: UUID) async throws {
        suspendedStageIDs.remove(operationID)
        guard let stage = openStages.removeValue(forKey: operationID) else { return }
        closeStage(stage)
        try? fileManager.removeItem(at: stage.directoryURL)
    }

    public func stageContentFromURL(
        _ sourceURL: URL,
        cancellation: (any SharedDocumentsOperationCancellation)? = nil,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> SharedDocumentsContentStage {
        try SharedDocumentsStreamedIO.validateRegularFileSource(sourceURL)
        let operationID = try await beginContentStage(cancellation: cancellation)
        do {
            var streamed: Int64 = 0
            try await SharedDocumentsStreamedIO.streamRegularFile(
                sourceURL,
                cancellation: cancellation
            ) { chunk in
                streamed += Int64(chunk.count)
                guard streamed <= SharedDocumentsStoreLayout.maxItemBytes else {
                    throw SharedDocumentsError.contentTooLarge(
                        maxBytes: SharedDocumentsStoreLayout.maxItemBytes
                    )
                }
                try await self.writeContent(chunk, operationID: operationID, cancellation: cancellation)
                progress?(streamed)
            }
            return try await finishContentStage(operationID: operationID, cancellation: cancellation)
        } catch {
            // The stage (handles + leased directory) is always ours; never
            // leak it after a failed or cancelled stream.
            try? await discardContentStage(operationID: operationID)
            throw SharedDocumentsStreamedIO.translateCancellation(error)
        }
    }

    // MARK: Commits

    public func commitCreate(
        parentID: String,
        name: String,
        kind: SharedDocumentsItemKind,
        stage: SharedDocumentsContentStage?,
        cancellation: (any SharedDocumentsOperationCancellation)? = nil
    ) async throws -> SharedDocumentsItem {
        if let stage { try requireCurrentStage(stage) }
        try Self.validateItemID(parentID)
        try Self.validateName(name)
        if cancellation?.isCancelled() == true { throw SharedDocumentsError.cancelled }
        if stage == nil, kind == .file {
            throw SharedDocumentsError.storageCorrupted("file create requires staged content")
        }
        if stage != nil, kind == .folder {
            throw SharedDocumentsError.specialFileRefused
        }
        let id = UUID().uuidString
        let now = PersistenceCodec.encode(Date())
        return try await publishUnderItemLease(id: id) {
            let committedPath: String?
            let sha: String?
            let bytes: Int64
            if let stage {
                try await self.requireCurrentStage(stage)
                let target = self.committedBlobURL(itemID: id, contentVersion: 1)
                try self.prepareCommittedBlobTarget(target)
                try self.fileManager.moveItem(at: stage.stagedFileURL, to: target)
                await self.closeStage(operationID: stage.operationID)
                try? self.fileManager.removeItem(at: stage.stagedFileURL.deletingLastPathComponent())
                committedPath = target.lastPathComponent
                sha = stage.sha256
                bytes = stage.byteCount
            } else {
                committedPath = nil
                sha = nil
                bytes = 0
            }
            return try await self.write { db in
                // Cancellation at the actual SQL boundary: throwing here rolls
                // the whole transaction back, so a cancelled create commits
                // nothing (the renamed staged bytes stay an unreferenced
                // orphan that recovery reclaims under the lease).
                if cancellation?.isCancelled() == true { throw SharedDocumentsError.cancelled }
                // The stable root is a virtual folder, as in item(id:) and
                // metadata moves. It intentionally has no SQLite item row.
                if parentID != SharedDocumentsIdentity.rootItemID {
                    guard let parent = try Self.fetchLiveRow(db, id: parentID) else {
                        throw SharedDocumentsError.parentNotFound(parentID)
                    }
                    guard (parent["kind"] as String?) == SharedDocumentsItemKind.folder.rawValue else {
                        throw SharedDocumentsError.parentNotAFolder(parentID)
                    }
                }
                if try Self.nameCollisionExists(db, parentID: parentID, name: name, excluding: nil) {
                    throw SharedDocumentsError.nameCollision(name)
                }
                let seq = try Self.appendChange(
                    db,
                    itemID: id,
                    changeType: .insert,
                    name: name,
                    parentID: parentID,
                    kind: kind,
                    contentVersion: kind == .file ? 1 : 0,
                    metadataVersion: 1,
                    byteCount: bytes,
                    sha256: sha
                )
                try db.execute(sql: """
                    INSERT INTO shared_documents_items(
                        id, parent_id, name, kind, content_version, metadata_version,
                        byte_count, sha256, content_path, creation_date, modification_date,
                        deleted, change_seq
                    ) VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, 0, ?)
                    """, arguments: [
                        id, parentID, name, kind.rawValue,
                        kind == .file ? 1 : 0, bytes, sha, committedPath, now, now, seq
                    ])
                guard let row = try Self.fetchLiveRow(db, id: id) else {
                    throw SharedDocumentsError.storageCorrupted("created item not readable")
                }
                return try Self.decodeItem(row)
            }
        }
    }

    public func commitReplace(
        id: String,
        stage: SharedDocumentsContentStage,
        expected: SharedDocumentsExpectedVersions,
        cancellation: (any SharedDocumentsOperationCancellation)? = nil
    ) async throws -> SharedDocumentsItem {
        try requireCurrentStage(stage)
        try Self.validateItemID(id)
        guard id != SharedDocumentsIdentity.rootItemID else { throw SharedDocumentsError.invalidItemID(id) }
        if cancellation?.isCancelled() == true { throw SharedDocumentsError.cancelled }
        return try await publishUnderItemLease(id: id) {
            // Probe the next version number, rename the staged bytes, then
            try await self.requireCurrentStage(stage)
            // re-verify inside the committing transaction: another writer may
            // have committed in between. A failed re-verify leaves only an
            // unreferenced orphan (recovery reclaims it); the prior committed
            // bytes/version are untouched.
            let newVersion = try await self.write { db in
                if cancellation?.isCancelled() == true { throw SharedDocumentsError.cancelled }
                let row = try Self.requireLiveRow(db, id: id)
                guard (row["kind"] as String?) == SharedDocumentsItemKind.file.rawValue else {
                    throw SharedDocumentsError.specialFileRefused
                }
                try Self.checkVersions(row, id: id, expected: expected)
                return (row["content_version"] as Int? ?? 0) + 1
            }
            let target = self.committedBlobURL(itemID: id, contentVersion: newVersion)
            try self.prepareCommittedBlobTarget(target)
            if self.fileManager.fileExists(atPath: target.path) {
                // Exactly-next-version leftover: while we hold the lease the
                // items row still names the prior version, so this file can
                // only be an orphan from a crash between a previous rename
                // and its committing transaction. Removing it keeps the
                // bounded retry converging at the exact next version instead
                // of colliding forever; real removal failures throw.
                try self.fileManager.removeItem(at: target)
            }
            try self.fileManager.moveItem(at: stage.stagedFileURL, to: target)
            await self.closeStage(operationID: stage.operationID)
            try? self.fileManager.removeItem(at: stage.stagedFileURL.deletingLastPathComponent())
            let now = PersistenceCodec.encode(Date())
            let updated = try await self.write { db in
                if cancellation?.isCancelled() == true { throw SharedDocumentsError.cancelled }
                let row = try Self.requireLiveRow(db, id: id)
                guard (row["kind"] as String?) == SharedDocumentsItemKind.file.rawValue else {
                    throw SharedDocumentsError.specialFileRefused
                }
                try Self.checkVersions(row, id: id, expected: expected)
                let priorPath = row["content_path"] as String?
                let version = (row["content_version"] as Int? ?? 0) + 1
                let seq = try Self.appendChange(
                    db,
                    itemID: id,
                    changeType: .update,
                    name: row["name"] as String? ?? "",
                    parentID: row["parent_id"] as String? ?? SharedDocumentsIdentity.rootItemID,
                    kind: .file,
                    contentVersion: version,
                    metadataVersion: row["metadata_version"] as Int? ?? 1,
                    byteCount: stage.byteCount,
                    sha256: stage.sha256
                )
                try db.execute(sql: """
                    UPDATE shared_documents_items
                    SET content_version = ?, byte_count = ?, sha256 = ?, content_path = ?,
                        modification_date = ?, change_seq = ?
                    WHERE id = ? AND deleted = 0
                    """, arguments: [
                        version, stage.byteCount, stage.sha256, target.lastPathComponent,
                        now, seq, id
                    ])
                guard let updatedRow = try Self.fetchLiveRow(db, id: id) else {
                    throw SharedDocumentsError.storageCorrupted("replaced item not readable")
                }
                return (try Self.decodeItem(updatedRow), priorPath)
            }
            if let priorPath = updated.1 {
                Self.removeCommittedBlobIfUnreferenced(self.blobRoot.appendingPathComponent(id, isDirectory: true), name: priorPath)
            }
            return updated.0
        }
    }

    public func commitMetadata(
        id: String,
        newName: String?,
        newParentID: String?,
        expected: SharedDocumentsExpectedVersions,
        cancellation: (any SharedDocumentsOperationCancellation)? = nil
    ) async throws -> SharedDocumentsItem {
        try Self.validateItemID(id)
        guard id != SharedDocumentsIdentity.rootItemID else { throw SharedDocumentsError.invalidItemID(id) }
        if let newName { try Self.validateName(newName) }
        if let newParentID { try Self.validateItemID(newParentID) }
        if cancellation?.isCancelled() == true { throw SharedDocumentsError.cancelled }
        let now = PersistenceCodec.encode(Date())
        return try await write { db in
            if cancellation?.isCancelled() == true { throw SharedDocumentsError.cancelled }
            let row = try Self.requireLiveRow(db, id: id)
            try Self.checkVersions(row, id: id, expected: expected)
            let targetName = newName ?? (row["name"] as String? ?? "")
            let targetParent = newParentID ?? (row["parent_id"] as String? ?? SharedDocumentsIdentity.rootItemID)
            if targetParent != SharedDocumentsIdentity.rootItemID {
                guard let parentRow = try Self.fetchLiveRow(db, id: targetParent),
                      (parentRow["kind"] as String?) == SharedDocumentsItemKind.folder.rawValue else {
                    throw SharedDocumentsError.parentNotFound(targetParent)
                }
            }
            if try (targetParent == id || Self.isDescendant(db, ancestorID: id, of: targetParent)) {
                throw SharedDocumentsError.storageCorrupted("move would create a folder cycle")
            }
            if try Self.nameCollisionExists(db, parentID: targetParent, name: targetName, excluding: id) {
                throw SharedDocumentsError.nameCollision(targetName)
            }
            let kind = SharedDocumentsItemKind(rawValue: row["kind"] as String? ?? "") ?? .file
            let version = (row["metadata_version"] as Int? ?? 1) + 1
            let seq = try Self.appendChange(
                db,
                itemID: id,
                changeType: .update,
                name: targetName,
                parentID: targetParent,
                kind: kind,
                contentVersion: row["content_version"] as Int? ?? 0,
                metadataVersion: version,
                byteCount: row["byte_count"] as Int64? ?? 0,
                sha256: row["sha256"] as String?
            )
            try db.execute(sql: """
                UPDATE shared_documents_items
                SET name = ?, parent_id = ?, metadata_version = ?, modification_date = ?, change_seq = ?
                WHERE id = ? AND deleted = 0
                """, arguments: [targetName, targetParent, version, now, seq, id])
            guard let updated = try Self.fetchLiveRow(db, id: id) else {
                throw SharedDocumentsError.storageCorrupted("renamed item not readable")
            }
            return try Self.decodeItem(updated)
        }
    }

    public func commitModify(
        id: String,
        newName: String?,
        newParentID: String?,
        stage: SharedDocumentsContentStage,
        expected: SharedDocumentsExpectedVersions,
        cancellation: (any SharedDocumentsOperationCancellation)? = nil
    ) async throws -> SharedDocumentsItem {
        try requireCurrentStage(stage)
        try Self.validateItemID(id)
        guard id != SharedDocumentsIdentity.rootItemID else { throw SharedDocumentsError.invalidItemID(id) }
        if let newName { try Self.validateName(newName) }
        if let newParentID { try Self.validateItemID(newParentID) }
        if cancellation?.isCancelled() == true { throw SharedDocumentsError.cancelled }
        return try await publishUnderItemLease(id: id) {
            // Admission probe: validates the CAS base, resolves the target
            try await self.requireCurrentStage(stage)
            // name/parent (collision + cycle checks) and computes the exact
            // next versions. The staged rename happens only after this
            // passes; the committing transaction below re-verifies the CAS
            // base inside the write transaction, so a concurrent committer
            // cannot interleave between probe and commit.
            let probe = try await self.write { db in
                if cancellation?.isCancelled() == true { throw SharedDocumentsError.cancelled }
                let row = try Self.requireLiveRow(db, id: id)
                guard (row["kind"] as String?) == SharedDocumentsItemKind.file.rawValue else {
                    throw SharedDocumentsError.specialFileRefused
                }
                try Self.checkVersions(row, id: id, expected: expected)
                let targetName = newName ?? (row["name"] as String? ?? "")
                let targetParent = newParentID ?? (row["parent_id"] as String? ?? SharedDocumentsIdentity.rootItemID)
                if targetParent != SharedDocumentsIdentity.rootItemID {
                    guard let parentRow = try Self.fetchLiveRow(db, id: targetParent),
                          (parentRow["kind"] as String?) == SharedDocumentsItemKind.folder.rawValue else {
                        throw SharedDocumentsError.parentNotFound(targetParent)
                    }
                }
                if try (targetParent == id || Self.isDescendant(db, ancestorID: id, of: targetParent)) {
                    throw SharedDocumentsError.storageCorrupted("move would create a folder cycle")
                }
                if try Self.nameCollisionExists(db, parentID: targetParent, name: targetName, excluding: id) {
                    throw SharedDocumentsError.nameCollision(targetName)
                }
                let nextContentVersion = (row["content_version"] as Int? ?? 0) + 1
                let nextMetadataVersion = (newName != nil || newParentID != nil)
                    ? (row["metadata_version"] as Int? ?? 1) + 1
                    : (row["metadata_version"] as Int? ?? 1)
                return (
                    targetName: targetName,
                    targetParent: targetParent,
                    nextContentVersion: nextContentVersion,
                    nextMetadataVersion: nextMetadataVersion
                )
            }
            // Publish the staged bytes at the exact next content version. A
            // leftover at exactly this version can only be a crash orphan from
            // a previous attempt at the same commit (the items row still
            // names the prior version while we hold the lease), so removing
            // it makes the bounded retry converge at the exact version.
            let target = self.committedBlobURL(itemID: id, contentVersion: probe.nextContentVersion)
            try self.prepareCommittedBlobTarget(target)
            if self.fileManager.fileExists(atPath: target.path) {
                try self.fileManager.removeItem(at: target)
            }
            try self.fileManager.moveItem(at: stage.stagedFileURL, to: target)
            await self.closeStage(operationID: stage.operationID)
            try? self.fileManager.removeItem(at: stage.stagedFileURL.deletingLastPathComponent())
            // ONE committing transaction: metadata and content become visible
            // together, with one CAS re-verification and one journal row
            // carrying the coherent final state. Any throw here rolls the
            // transaction back — the prior committed bytes, name and versions
            // stay untouched, and the renamed staged bytes remain an
            // unreferenced orphan for recovery to reclaim.
            let now = PersistenceCodec.encode(Date())
            let updated = try await self.write { db in
                if cancellation?.isCancelled() == true { throw SharedDocumentsError.cancelled }
                let row = try Self.requireLiveRow(db, id: id)
                guard (row["kind"] as String?) == SharedDocumentsItemKind.file.rawValue else {
                    throw SharedDocumentsError.specialFileRefused
                }
                try Self.checkVersions(row, id: id, expected: expected)
                // The admission read precedes staged I/O. Another process may
                // delete the destination folder or claim its name in between;
                // revalidate those shared invariants inside the commit too.
                if probe.targetParent != SharedDocumentsIdentity.rootItemID {
                    guard let parent = try Self.fetchLiveRow(db, id: probe.targetParent),
                          (parent["kind"] as String?) == SharedDocumentsItemKind.folder.rawValue else {
                        throw SharedDocumentsError.parentNotFound(probe.targetParent)
                    }
                }
                if try Self.nameCollisionExists(db, parentID: probe.targetParent,
                                                name: probe.targetName, excluding: id) {
                    throw SharedDocumentsError.nameCollision(probe.targetName)
                }
                let priorPath = row["content_path"] as String?
                let seq = try Self.appendChange(
                    db,
                    itemID: id,
                    changeType: .update,
                    name: probe.targetName,
                    parentID: probe.targetParent,
                    kind: .file,
                    contentVersion: probe.nextContentVersion,
                    metadataVersion: probe.nextMetadataVersion,
                    byteCount: stage.byteCount,
                    sha256: stage.sha256
                )
                try db.execute(sql: """
                    UPDATE shared_documents_items
                    SET name = ?, parent_id = ?, content_version = ?, metadata_version = ?,
                        byte_count = ?, sha256 = ?, content_path = ?,
                        modification_date = ?, change_seq = ?
                    WHERE id = ? AND deleted = 0
                    """, arguments: [
                        probe.targetName, probe.targetParent,
                        probe.nextContentVersion, probe.nextMetadataVersion,
                        stage.byteCount, stage.sha256, target.lastPathComponent,
                        now, seq, id
                    ])
                guard let updatedRow = try Self.fetchLiveRow(db, id: id) else {
                    throw SharedDocumentsError.storageCorrupted("modified item not readable")
                }
                return (try Self.decodeItem(updatedRow), priorPath)
            }
            if let priorPath = updated.1 {
                Self.removeCommittedBlobIfUnreferenced(self.blobRoot.appendingPathComponent(id, isDirectory: true), name: priorPath)
            }
            return updated.0
        }
    }

    public func commitDelete(
        id: String,
        expected: SharedDocumentsExpectedVersions,
        recursive: Bool,
        cancellation: (any SharedDocumentsOperationCancellation)? = nil
    ) async throws -> (deletedIDs: [String], byteCount: Int64) {
        let budget = try await beginOwnedFileOperation()
        defer { endOwnedFileOperation(budget) }
        try Self.validateItemID(id)
        guard id != SharedDocumentsIdentity.rootItemID else { throw SharedDocumentsError.invalidItemID(id) }
        if cancellation?.isCancelled() == true { throw SharedDocumentsError.cancelled }
        let now = PersistenceCodec.encode(Date())
        let summary = try await write { db in
            if cancellation?.isCancelled() == true { throw SharedDocumentsError.cancelled }
            let row = try Self.requireLiveRow(db, id: id)
            try Self.checkVersions(row, id: id, expected: expected)
            var victims: [Row] = [row]
            if (row["kind"] as String?) == SharedDocumentsItemKind.folder.rawValue {
                let descendants = try Self.descendants(
                    db,
                    of: id,
                    maxDepth: SharedDocumentsStoreLayout.maxDeleteRecursionDepth,
                    maxItems: SharedDocumentsStoreLayout.maxDeleteItemCount
                )
                if !descendants.isEmpty, !recursive {
                    throw SharedDocumentsError.folderNotEmpty(id)
                }
                victims.append(contentsOf: descendants)
            }
            var totalBytes: Int64 = 0
            var ids: [String] = []
            for victim in victims {
                let victimID: String = victim["id"]
                let victimBytes: Int64 = victim["byte_count"] ?? 0
                totalBytes += victimBytes
                ids.append(victimID)
                let seq = try Self.appendChange(
                    db,
                    itemID: victimID,
                    changeType: .delete,
                    name: victim["name"] ?? "",
                    parentID: victim["parent_id"] ?? SharedDocumentsIdentity.rootItemID,
                    kind: SharedDocumentsItemKind(rawValue: victim["kind"] ?? "") ?? .file,
                    contentVersion: victim["content_version"] ?? 0,
                    metadataVersion: victim["metadata_version"] ?? 1,
                    byteCount: victimBytes,
                    sha256: victim["sha256"] as String?
                )
                try db.execute(sql: """
                    UPDATE shared_documents_items
                    SET deleted = 1, content_path = NULL, modification_date = ?, change_seq = ?
                    WHERE id = ?
                    """, arguments: [now, seq, victimID])
            }
            return (deletedIDs: ids, byteCount: totalBytes)
        }
        // Content bytes are removed only after the delete commits; a failure
        // here leaves an orphan that recoverInterruptedOperations() reclaims.
        for victimID in summary.deletedIDs {
            // Metadata already committed: retain cleanup orphans on expiry
            // and return the real deletion receipt, never fake rollback.
            do { try budget.check() } catch { break }
            let dir = blobRoot.appendingPathComponent(victimID, isDirectory: true)
            guard let names = try? fileManager.contentsOfDirectory(atPath: dir.path), !names.isEmpty else { continue }
            let lock = dir.appendingPathComponent("lock")
            Self.withExclusiveFileLeaseIfAvailable(lock) {
                for name in names where name != "lock" {
                    try? self.fileManager.removeItem(at: dir.appendingPathComponent(name))
                }
            }
        }
        return summary
    }

    public func restoreContent(
        id: String,
        targetContentVersion: Int,
        expected: SharedDocumentsExpectedVersions,
        cancellation: (any SharedDocumentsOperationCancellation)? = nil
    ) async throws -> SharedDocumentsItem {
        try Self.validateItemID(id)
        guard id != SharedDocumentsIdentity.rootItemID else { throw SharedDocumentsError.invalidItemID(id) }
        guard targetContentVersion >= 1 else {
            throw SharedDocumentsError.storageCorrupted("no such version \(targetContentVersion)")
        }
        if cancellation?.isCancelled() == true { throw SharedDocumentsError.cancelled }
        return try await publishUnderItemLease(id: id) {
            let history = try await self.read { db in
                if cancellation?.isCancelled() == true { throw SharedDocumentsError.cancelled }
                let row = try Self.requireLiveRow(db, id: id)
                guard (row["kind"] as String?) == SharedDocumentsItemKind.file.rawValue else {
                    throw SharedDocumentsError.specialFileRefused
                }
                try Self.checkVersions(row, id: id, expected: expected)
                guard let change = try Row.fetchOne(
                    db, sql: """
                        SELECT sha256, byte_count FROM shared_documents_changes
                        WHERE item_id = ? AND content_version = ? AND change_type != 'delete'
                        ORDER BY seq DESC LIMIT 1
                        """,
                    arguments: [id, targetContentVersion]
                ) else {
                    throw SharedDocumentsError.storageCorrupted("no recorded version \(targetContentVersion) for \(id)")
                }
                let sha: String? = change["sha256"]
                let bytes: Int64 = change["byte_count"] ?? 0
                return (sha256: sha, byteCount: bytes)
            }
            let source = self.committedBlobURL(itemID: id, contentVersion: targetContentVersion)
            let temp = self.blobRoot.appendingPathComponent(id, isDirectory: true)
                .appendingPathComponent(".restore-\(UUID().uuidString)")
            try self.prepareCommittedBlobTarget(temp)
            try self.fileManager.copyItem(at: source, to: temp)
            let copiedDigest = try FloeDigest.sha256Hex(ofFileAt: temp)
            guard copiedDigest == history.sha256 else {
                try? self.fileManager.removeItem(at: temp)
                throw SharedDocumentsError.contentDigestMismatch(
                    expected: history.sha256 ?? "unknown",
                    actual: copiedDigest
                )
            }
            let now = PersistenceCodec.encode(Date())
            return try await self.write { db in
                if cancellation?.isCancelled() == true { throw SharedDocumentsError.cancelled }
                let row = try Self.requireLiveRow(db, id: id)
                try Self.checkVersions(row, id: id, expected: expected)
                let version = (row["content_version"] as Int? ?? 0) + 1
                let target = self.committedBlobURL(itemID: id, contentVersion: version)
                if self.fileManager.fileExists(atPath: target.path) {
                    // Same bounded-retry story as commitReplace: while the
                    // lease is held and the row still names the prior
                    // version, an exact-next-version file can only be a crash
                    // orphan. Removal failures throw honestly.
                    try self.fileManager.removeItem(at: target)
                }
                try self.fileManager.moveItem(at: temp, to: target)
                let seq = try Self.appendChange(
                    db,
                    itemID: id,
                    changeType: .update,
                    name: row["name"] as String? ?? "",
                    parentID: row["parent_id"] as String? ?? SharedDocumentsIdentity.rootItemID,
                    kind: .file,
                    contentVersion: version,
                    metadataVersion: row["metadata_version"] as Int? ?? 1,
                    byteCount: history.byteCount,
                    sha256: history.sha256
                )
                try db.execute(sql: """
                    UPDATE shared_documents_items
                    SET content_version = ?, byte_count = ?, sha256 = ?, content_path = ?,
                        modification_date = ?, change_seq = ?
                    WHERE id = ? AND deleted = 0
                    """, arguments: [
                        version, history.byteCount, history.sha256,
                        target.lastPathComponent, now, seq, id
                    ])
                guard let updated = try Self.fetchLiveRow(db, id: id) else {
                    throw SharedDocumentsError.storageCorrupted("restored item not readable")
                }
                return try Self.decodeItem(updated)
            }
        }
    }

    // MARK: Leased content snapshot

    public func withLeasedContentSnapshot<T: Sendable>(
        id: String,
        cancellation: (any SharedDocumentsOperationCancellation)? = nil,
        _ body: @Sendable (SharedDocumentsLeasedContentSnapshot) async throws -> T
    ) async throws -> T {
        try Self.validateItemID(id)
        guard id != SharedDocumentsIdentity.rootItemID else { throw SharedDocumentsError.invalidItemID(id) }
        if cancellation?.isCancelled() == true { throw SharedDocumentsError.cancelled }
        return try await publishUnderItemLease(id: id) {
            if cancellation?.isCancelled() == true { throw SharedDocumentsError.cancelled }
            // Item and content URL come from ONE read while the lease is
            // held: the version/sha256 in the item describe exactly the bytes
            // at contentURL (no "newer bytes paired with older metadata").
            let snapshot = try await self.read { db in
                let row = try Self.requireLiveRow(db, id: id)
                guard (row["kind"] as String?) == SharedDocumentsItemKind.file.rawValue else {
                    throw SharedDocumentsError.specialFileRefused
                }
                guard (row["content_path"] as String?) != nil else {
                    throw SharedDocumentsError.storageCorrupted("committed content path missing for \(id)")
                }
                let item = try Self.decodeItem(row)
                let url = self.committedBlobURL(itemID: id, contentVersion: item.contentVersion)
                guard self.fileManager.fileExists(atPath: url.path) else {
                    // Read/storage failures remain failures — only a true
                    // itemNotFound maps to absence, and that was answered by
                    // requireLiveRow. Missing committed bytes are corruption.
                    throw SharedDocumentsError.storageCorrupted("committed content missing for \(id)")
                }
                return SharedDocumentsLeasedContentSnapshot(item: item, contentURL: url)
            }
            // The lease stays held across body: replace/delete/recovery all
            // acquire the same flock before removing committed bytes, so the
            // snapshot bytes cannot vanish mid-copy.
            if cancellation?.isCancelled() == true { throw SharedDocumentsError.cancelled }
            return try await body(snapshot)
        }
    }

    // MARK: Anchors / changes

    public func currentAnchor() async throws -> Data {
        // The anchor is the persisted high-water sequence, never MAX(seq) of
        // whatever rows happen to be live: after a full prune MAX(seq) drops
        // to 0 while the floor advanced, and a fresh enumerator would start
        // below the floor and be told its brand-new anchor expired. The
        // high-water is monotonic across pruneChanges.
        let high = try await read { db in
            try Self.anchorHighSeq(db)
        }
        return Self.makeAnchor(sequence: high)
    }

    /// High-water = max(persisted `anchor_high_seq`, live MAX(seq)). Reading
    /// both covers databases written before the high-water key existed.
    private static func anchorHighSeq(_ db: Database) throws -> Int {
        let maxSeq = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(seq), 0) FROM shared_documents_changes") ?? 0
        let storedHigh: String? = try String.fetchOne(
            db, sql: "SELECT value FROM shared_documents_meta WHERE key = 'anchor_high_seq'"
        )
        return max(storedHigh.flatMap(Int.init) ?? 0, maxSeq)
    }

    public func changes(
        anchor: Data,
        limit: Int
    ) async throws -> (changes: [SharedDocumentsChange], nextAnchor: Data, more: Bool) {
        let fromSeq = try Self.parseAnchor(anchor)
        let batch = min(max(limit, 1), SharedDocumentsStoreLayout.maxChangeBatch)
        // ONE consistent SQLite read snapshot: floor, high-water and the row
        // batch. A concurrent prune between separate reads could advance the
        // floor after validation and make rows vanish without expiry; here it
        // either lands before the snapshot (expiry is reported) or after (the
        // batch answers from the snapshot). Read errors throw — never a
        // false empty diff.
        let snapshot = try await read { db in
            let floorValue: String? = try String.fetchOne(
                db, sql: "SELECT value FROM shared_documents_meta WHERE key = 'anchor_floor_seq'"
            )
            let high = try Self.anchorHighSeq(db)
            let rows = try Row.fetchAll(
                db, sql: """
                    SELECT * FROM shared_documents_changes
                    WHERE seq > ? ORDER BY seq LIMIT ?
                    """,
                arguments: [fromSeq, batch]
            )
            let mapped = try rows.map(Self.decodeChange)
            return (floor: floorValue.flatMap(Int.init) ?? 0, high: high, changes: mapped)
        }
        // An anchor from the future, or one below the journal retention
        // floor, is reported as expired — never answered with a false clean.
        guard fromSeq <= snapshot.high, fromSeq >= snapshot.floor else {
            throw SharedDocumentsError.invalidCursor
        }
        let lastSeq = snapshot.changes.last?.sequence ?? fromSeq
        let head = max(lastSeq, snapshot.high)
        return (snapshot.changes, Self.makeAnchor(sequence: head), snapshot.high > head)
    }

    public func pruneChanges(olderThan cutoff: Date) async throws -> Int {
        let cutoffString = PersistenceCodec.encode(cutoff)
        return try await write { db in
            guard let maxPrunable = try Int.fetchOne(
                db, sql: "SELECT COALESCE(MAX(seq), 0) FROM shared_documents_changes WHERE change_time < ?",
                arguments: [cutoffString]
            ), maxPrunable > 0 else {
                return 0
            }
            try db.execute(sql: "DELETE FROM shared_documents_changes WHERE seq <= ?", arguments: [maxPrunable])
            try db.execute(
                sql: "UPDATE shared_documents_meta SET value = ? WHERE key = 'anchor_floor_seq'",
                arguments: [String(maxPrunable)]
            )
            // Tombstone rows for deleted items keep item(for:) honest
            // (noSuchItem) after their journal row is gone; purging them is a
            // separate, explicit decision.
            return maxPrunable
        }
    }

    public func anchorExpiryFloor() async throws -> Int {
        try await read { db in
            let value: String? = try String.fetchOne(
                db, sql: "SELECT value FROM shared_documents_meta WHERE key = 'anchor_floor_seq'"
            )
            return value.flatMap(Int.init) ?? 0
        }
    }

    // MARK: Recovery

    public func recoverInterruptedOperations() async throws -> SharedDocumentsRecoveryReport {
        let budget = try await beginOwnedFileOperation()
        defer { endOwnedFileOperation(budget) }
        var reclaimedStages = 0
        var reclaimedOrphans = 0
        var missingContent: [String] = []

        // 1) Staging directories whose lock is not held by a live process.
        //    Counters reflect ACTUAL deletions only: a removal that fails
        //    (or a lease that cannot even be probed) leaves the directory
        //    untouched and uncounted, so the next recovery pass can retry
        //    instead of permanently losing track of live staged bytes.
        if let stageNames = try? fileManager.contentsOfDirectory(atPath: stagingRoot.path) {
            for name in stageNames {
                try budget.check()
                let dir = stagingRoot.appendingPathComponent(name, isDirectory: true)
                let lock = dir.appendingPathComponent("lock")
                guard fileManager.fileExists(atPath: lock.path) else {
                    if (try? fileManager.removeItem(at: dir)) != nil {
                        reclaimedStages += 1
                    }
                    continue
                }
                var removed = false
                Self.withExclusiveFileLeaseIfAvailable(lock) {
                    do {
                        try self.fileManager.removeItem(at: dir)
                        removed = true
                    } catch {
                        // Retained for a future pass; not counted.
                    }
                }
                if removed { reclaimedStages += 1 }
            }
        }

        // 2) Blob directories. The referenced-paths read happens AFTER the
        //    per-item lease is acquired: a committing process holds the same
        //    lease across rename+transaction, so a snapshot taken earlier
        //    could otherwise mistake a just-published blob for an orphan.
        if let itemNames = try? fileManager.contentsOfDirectory(atPath: blobRoot.path) {
            for itemName in itemNames where Self.isValidStoredItemName(itemName) {
                try budget.check()
                let dir = blobRoot.appendingPathComponent(itemName, isDirectory: true)
                let lock = dir.appendingPathComponent("lock")
                if !fileManager.fileExists(atPath: lock.path) {
                    fileManager.createFile(atPath: lock.path, contents: nil)
                }
                guard let handle = try? FileHandle(forUpdating: lock),
                      Self.acquireExclusiveLock(handle) else {
                    continue
                }
                defer { try? handle.close() }
                // A failed metadata read cannot establish that a blob is an
                // orphan. Retain all content and surface the failure.
                let referenced = try await self.read { db in
                    try String.fetchAll(
                        db, sql: "SELECT content_path FROM shared_documents_items WHERE id = ? AND deleted = 0",
                        arguments: [itemName]
                    )
                }
                let names = try fileManager.contentsOfDirectory(atPath: dir.path)
                for fileName in names where fileName != "lock" {
                    try budget.check()
                    if !referenced.contains(fileName), !fileName.hasPrefix(".restore-") {
                        try fileManager.removeItem(at: dir.appendingPathComponent(fileName))
                        reclaimedOrphans += 1
                    }
                }
                for ref in referenced where !fileManager.fileExists(atPath: dir.appendingPathComponent(ref).path) {
                    missingContent.append(itemName)
                }
                try? handle.close()
            }
        }
        return SharedDocumentsRecoveryReport(
            reclaimedStages: reclaimedStages,
            reclaimedOrphans: reclaimedOrphans,
            missingContentItemIDs: missingContent
        )
    }

    public func close() async throws {
        let stages = openStages
        openStages.removeAll()
        for stage in stages.values {
            closeStage(stage)
        }
        try await pool.close()
    }

    // MARK: - Internals

    private func read<T: Sendable>(_ block: @Sendable (Database) throws -> T) async throws -> T {
        try await pool.read { db in try block(db) }
    }

    private func write<T: Sendable>(_ block: @Sendable (Database) throws -> T) async throws -> T {
        guard !storageSuspended else { throw SharedDocumentsError.cancelled }
        let generation = suspensionGeneration
        let budget = try await StorageOperationBudget.begin()
        defer { budget.finish() }
        guard !storageSuspended, generation == suspensionGeneration else { throw SharedDocumentsError.cancelled }
        return try await pool.write { db in
            try budget.check()
            return try block(db)
        }
    }

    /// Stop stage admission first; await any item-level publish/copy lease
    /// before releasing its stage handles. Partial stage files remain on disk
    /// for the existing recovery policy, never presented as committed bytes.
    public func suspendForBackground() async {
        suspensionGeneration &+= 1
        let generation = suspensionGeneration
        storageSuspended = true
        if activeItemLeases > 0 {
            await withCheckedContinuation { leaseDrainWaiters.append($0) }
        }
        guard storageSuspended, generation == suspensionGeneration else { return }
        let stages = openStages
        openStages.removeAll()
        suspendedStageIDs.formUnion(stages.keys)
        for stage in stages.values { closeStage(stage) }
        // Actor reentrancy means a metadata write can still be inside
        // `pool.write` after `storageSuspended` flips. New writes are refused
        // above, and this empty barrier is queued behind any in-flight one, so
        // returning here proves the store's writer no longer owns a SQLite
        // lock. The host can then surrender its last execution assertion
        // without leaving the shared App Group database locked in suspension.
        _ = try? await pool.writeWithoutTransaction { (_: Database) in () }
    }

    public func resumeAfterSuspension() {
        suspensionGeneration &+= 1
        storageSuspended = false
    }

    private nonisolated func committedBlobURL(itemID: String, contentVersion: Int) -> URL {
        blobRoot.appendingPathComponent(itemID, isDirectory: true)
            .appendingPathComponent("v\(contentVersion)")
    }

    /// Opens only a newly created private regular leaf. The caller owns the
    /// generated stage directory and holds its lease. Returning the actual
    /// created descriptor avoids a create-then-reopen path race.
    nonisolated static func createOwnedStageContentHandle(at url: URL) throws -> FileHandle {
        #if canImport(Darwin) || canImport(Glibc)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else {
            let code = errno
            throw FloeFileIOError(
                stage: .open,
                posixErrno: code,
                detail: "staged content could not be created exclusively",
                domain: NSPOSIXErrorDomain,
                code: Int(code)
            )
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        #else
        try Data().write(to: url, options: .withoutOverwriting)
        return try FileHandle(forWritingTo: url)
        #endif
    }

    private nonisolated func prepareCommittedBlobTarget(_ url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let lock = dir.appendingPathComponent("lock")
        if !fileManager.fileExists(atPath: lock.path) {
            fileManager.createFile(atPath: lock.path, contents: nil)
        }
    }

    /// Runs the body while holding the per-item `flock`. Cross-process
    /// committers of the same item serialize on this lease; recovery only
    /// reclaims when the lease is free.
    private func publishUnderItemLease<T: Sendable>(
        id: String,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        let budget = try await beginOwnedFileOperation()
        defer { endOwnedFileOperation(budget) }
        let dir = blobRoot.appendingPathComponent(id, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let lock = dir.appendingPathComponent("lock")
        if !fileManager.fileExists(atPath: lock.path) {
            fileManager.createFile(atPath: lock.path, contents: nil)
        }
        let handle = try FileHandle(forUpdating: lock)
        defer { try? handle.close() }
        guard Self.acquireExclusiveLock(handle) else {
            throw SharedDocumentsError.storageCorrupted("item \(id) is locked by another live process")
        }
        return try await body()
    }

    private func beginOwnedFileOperation() async throws -> StorageOperationLease {
        guard !storageSuspended else { throw SharedDocumentsError.cancelled }
        let generation = suspensionGeneration
        let budget = try await StorageOperationBudget.begin()
        do {
            guard !storageSuspended, generation == suspensionGeneration else { throw SharedDocumentsError.cancelled }
            try budget.check()
        } catch { budget.finish(); throw error }
        activeItemLeases += 1
        return budget
    }

    private func endOwnedFileOperation(_ budget: StorageOperationLease) {
        budget.finish()
        activeItemLeases -= 1
        if activeItemLeases == 0 {
            let waiters = leaseDrainWaiters
            leaseDrainWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    private func closeStage(operationID: UUID) {
        guard let stage = openStages.removeValue(forKey: operationID) else { return }
        closeStage(stage)
    }

    private func requireCurrentStage(_ stage: SharedDocumentsContentStage) throws {
        guard !storageSuspended else { throw SharedDocumentsError.cancelled }
        guard let current = openStages[stage.operationID],
              current.contentURL == stage.stagedFileURL else {
            if suspendedStageIDs.contains(stage.operationID) { throw SharedDocumentsError.cancelled }
            throw SharedDocumentsError.storageCorrupted("staging operation is no longer owned")
        }
        try current.budget.check()
    }

    private nonisolated func closeStage(_ stage: OpenStage) {
        try? stage.contentHandle.close()
        // Closing the lock handle releases the flock held since begin.
        try? stage.lockHandle.close()
        stage.budget.finish()
    }

    private nonisolated static func removeCommittedBlobIfUnreferenced(_ dir: URL, name: String) {
        withExclusiveFileLeaseIfAvailable(dir.appendingPathComponent("lock")) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // MARK: Validation

    static func validateItemID(_ id: String) throws {
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/"), !id.contains("\0") else {
            throw SharedDocumentsError.invalidItemID(id)
        }
        if id == SharedDocumentsIdentity.rootItemID { return }
        guard UUID(uuidString: id) != nil else {
            throw SharedDocumentsError.invalidItemID(id)
        }
    }

    static func validateName(_ name: String) throws {
        guard !name.isEmpty else { throw SharedDocumentsError.invalidName(name) }
        guard name != ".", name != ".." else { throw SharedDocumentsError.invalidName(name) }
        guard name.count <= SharedDocumentsStoreLayout.maxNameLength else {
            throw SharedDocumentsError.invalidName(name)
        }
        guard !name.contains("/"), !name.contains("\0") else { throw SharedDocumentsError.invalidName(name) }
        for scalar in name.unicodeScalars where scalar.value < 0x20 {
            throw SharedDocumentsError.invalidName(name)
        }
    }

    private static func isValidStoredItemName(_ name: String) -> Bool {
        UUID(uuidString: name) != nil
    }

    // MARK: Row decoding

    static func decodeItem(_ row: Row) throws -> SharedDocumentsItem {
        let id: String = row["id"]
        let parentID: String = row["parent_id"]
        let name: String = row["name"]
        let kindRaw: String = row["kind"]
        let contentVersion: Int = row["content_version"]
        let metadataVersion: Int = row["metadata_version"]
        let byteCount: Int64 = row["byte_count"] ?? 0
        let sha: String? = row["sha256"]
        let creationRaw: String = row["creation_date"]
        let modificationRaw: String = row["modification_date"]
        return SharedDocumentsItem(
            id: id,
            parentID: parentID,
            name: name,
            kind: SharedDocumentsItemKind(rawValue: kindRaw) ?? .file,
            contentVersion: contentVersion,
            metadataVersion: metadataVersion,
            byteCount: byteCount,
            sha256: sha,
            creationDate: try PersistenceCodec.decodeDate(creationRaw),
            modificationDate: try PersistenceCodec.decodeDate(modificationRaw)
        )
    }

    static func fetchLiveRow(_ db: Database, id: String) throws -> Row? {
        try Row.fetchOne(
            db, sql: "SELECT * FROM shared_documents_items WHERE id = ? AND deleted = 0",
            arguments: [id]
        )
    }

    static func requireLiveRow(_ db: Database, id: String) throws -> Row {
        guard let row = try fetchLiveRow(db, id: id) else {
            throw SharedDocumentsError.itemNotFound(id)
        }
        return row
    }

    static func nameCollisionExists(
        _ db: Database,
        parentID: String,
        name: String,
        excluding: String?
    ) throws -> Bool {
        if let excluding {
            return try Row.fetchOne(
                db, sql: """
                    SELECT id FROM shared_documents_items
                    WHERE parent_id = ? AND deleted = 0 AND name = ? COLLATE NOCASE AND id != ?
                    LIMIT 1
                    """,
                arguments: [parentID, name, excluding]
            ) != nil
        }
        return try Row.fetchOne(
            db, sql: """
                SELECT id FROM shared_documents_items
                WHERE parent_id = ? AND deleted = 0 AND name = ? COLLATE NOCASE
                LIMIT 1
                """,
            arguments: [parentID, name]
        ) != nil
    }

    static func checkVersions(_ row: Row, id: String, expected: SharedDocumentsExpectedVersions) throws {
        let actual = SharedDocumentsItemVersions(
            content: row["content_version"] ?? 0,
            metadata: row["metadata_version"] ?? 1
        )
        guard actual.content == expected.content, actual.metadata == expected.metadata else {
            throw SharedDocumentsError.versionConflict(
                itemID: id,
                expected: expected,
                actual: actual
            )
        }
    }

    @discardableResult
    static func appendChange(
        _ db: Database,
        itemID: String,
        changeType: SharedDocumentsChangeKind,
        name: String,
        parentID: String,
        kind: SharedDocumentsItemKind,
        contentVersion: Int,
        metadataVersion: Int,
        byteCount: Int64,
        sha256: String?
    ) throws -> Int {
        try db.execute(sql: """
            INSERT INTO shared_documents_changes(
                item_id, change_type, name, parent_id, kind,
                content_version, metadata_version, byte_count, sha256, change_time
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                itemID, changeType.rawValue, name, parentID, kind.rawValue,
                contentVersion, metadataVersion, byteCount, sha256,
                PersistenceCodec.encode(Date())
            ])
        let seq = Int(db.lastInsertedRowID)
        // Persist the monotonic high-water BEFORE any other write touches
        // lastInsertedRowID: pruning the whole journal must never move the
        // anchor backwards.
        try db.execute(sql: """
            INSERT INTO shared_documents_meta(key, value) VALUES ('anchor_high_seq', ?)
            ON CONFLICT(key) DO UPDATE SET value = MAX(CAST(value AS INTEGER), CAST(excluded.value AS INTEGER))
            """, arguments: [String(seq)])
        return seq
    }

    /// Decodes one journal row. Creation/modification dates are not part of
    /// the journal schema; change consumers get the committed identity,
    /// name, parent, kind and versions (the working set re-reads live items
    /// when it needs dates).
    static func decodeChange(_ row: Row) throws -> SharedDocumentsChange {
        let kindRaw: String = row["change_type"]
        let itemID: String = row["item_id"]
        let parentID: String = row["parent_id"]
        let name: String = row["name"]
        let kindRawValue: String = row["kind"]
        let contentVersion: Int = row["content_version"]
        let metadataVersion: Int = row["metadata_version"]
        let byteCount: Int64 = row["byte_count"] ?? 0
        let sha: String? = row["sha256"]
        let seq: Int = row["seq"]
        let item = SharedDocumentsItem(
            id: itemID,
            parentID: parentID,
            name: name,
            kind: SharedDocumentsItemKind(rawValue: kindRawValue) ?? .file,
            contentVersion: contentVersion,
            metadataVersion: metadataVersion,
            byteCount: byteCount,
            sha256: sha,
            creationDate: Date(timeIntervalSince1970: 0),
            modificationDate: Date(timeIntervalSince1970: 0)
        )
        return SharedDocumentsChange(
            sequence: seq,
            itemID: itemID,
            kind: SharedDocumentsChangeKind(rawValue: kindRaw) ?? .update,
            item: item
        )
    }

    /// Iterative bounded descendant walk (no recursion, no unbounded scan).
    static func descendants(
        _ db: Database,
        of itemID: String,
        maxDepth: Int,
        maxItems: Int
    ) throws -> [Row] {
        var result: [Row] = []
        var frontier: [(id: String, depth: Int)] = [(itemID, 0)]
        while let (current, depth) = frontier.first {
            frontier.removeFirst()
            guard depth < maxDepth else { throw SharedDocumentsError.deleteLimitExceeded(current) }
            let children = try Row.fetchAll(
                db, sql: "SELECT * FROM shared_documents_items WHERE parent_id = ? AND deleted = 0",
                arguments: [current]
            )
            for child in children {
                result.append(child)
                guard result.count <= maxItems else {
                    throw SharedDocumentsError.deleteLimitExceeded(current)
                }
                if (child["kind"] as String?) == SharedDocumentsItemKind.folder.rawValue {
                    let childID: String = child["id"]
                    frontier.append((childID, depth + 1))
                }
            }
        }
        return result
    }

    static func isDescendant(_ db: Database, ancestorID: String, of itemID: String) throws -> Bool {
        var current = itemID
        var visited = Set<String>()
        while current != SharedDocumentsIdentity.rootItemID {
            guard visited.insert(current).inserted else { return true }
            guard current != ancestorID else { return true }
            guard let row = try Row.fetchOne(
                db, sql: "SELECT parent_id FROM shared_documents_items WHERE id = ? AND deleted = 0",
                arguments: [current]
            ) else { return false }
            let parent: String = row["parent_id"]
            current = parent
        }
        return false
    }

    // MARK: Cursor / anchor codecs

    static func makeCursor(name: String, id: String) throws -> Data {
        let object: [String: String] = ["n": name, "i": id]
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func parseCursor(_ token: Data) throws -> (name: String, id: String) {
        guard let object = try JSONSerialization.jsonObject(with: token) as? [String: String],
              let name = object["n"], let id = object["i"], !id.isEmpty else {
            throw SharedDocumentsError.invalidCursor
        }
        return (name, id)
    }

    static func makeAnchor(sequence: Int) -> Data {
        Data("v1.\(sequence)".utf8)
    }

    static func parseAnchor(_ anchor: Data) throws -> Int {
        guard let string = String(data: anchor, encoding: .utf8),
              string.hasPrefix("v1."),
              let seq = Int(string.dropFirst(3)), seq >= 0 else {
            throw SharedDocumentsError.invalidCursor
        }
        return seq
    }

    // MARK: OS leases

    private nonisolated static func acquireExclusiveLock(_ handle: FileHandle) -> Bool {
        #if canImport(Darwin)
        return flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0
        #else
        return true
        #endif
    }

    private nonisolated static func withExclusiveFileLeaseIfAvailable(
        _ url: URL,
        _ body: () throws -> Void
    ) rethrows {
        guard let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        guard acquireExclusiveLock(handle) else { return }
        try body()
    }
}

// MARK: - Identity

public enum SharedDocumentsIdentity {
    /// Stable, non-user-visible domain identifier.
    public static let domainIdentifier = "shared-documents"
    /// Provider-side item identifier for the hierarchy root.
    public static let rootItemID = "root"

    /// Root filename follows the device locale at first access; the domain
    /// display name is chosen the same way by SharedDocumentsCenter.
    public static var rootItemName: String {
        Locale.current.language.languageCode?.identifier.hasPrefix("zh") == true
            ? "Floe 共享文档"
            : "Floe Shared Documents"
    }

    public static let rootItem = SharedDocumentsItem(
        id: rootItemID,
        parentID: rootItemID,
        name: rootItemName,
        kind: .folder,
        contentVersion: 0,
        metadataVersion: 1,
        byteCount: 0,
        sha256: nil,
        creationDate: Date(timeIntervalSince1970: 0),
        modificationDate: Date(timeIntervalSince1970: 0)
    )
}
