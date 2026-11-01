// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 closed media-purpose workspace egress (lane job-f279001daa564f5f).
//
// The ORIGINAL G04 source host freezes a native working copy into a
// materialized snapshot for save/export and bounds that copy at
// `G04WorkspaceSourceCoordinator.maximumProviderCopyBytes` (1 GiB). That is
// the generic provider-file budget and it stays EXACTLY as delivered: the
// Office/Notes save and export callers, the 4 MiB editable-document mailbox
// and the 256 MiB Office stager are not touched or widened here.
//
// The reviewed R2 large-import policy already accepts image 128 MiB / audio
// 1 GiB / video 8 GiB, so a workspace video above 1 GiB was refused by the
// native channel itself (software gap, not a platform limit). This file adds
// ONE additive, closed media-purpose channel for the App's media route:
//
//   * `G04WorkspaceMediaKind` is the closed kind + extension + ceiling table.
//     Native derives the kind from the logical path's final extension and
//     requires the caller's kind to EQUAL it before any owner lookup, so a
//     caller-supplied kind (or a path/intent) can never widen a ceiling or
//     route a non-media file through this lane.
//   * The owner is still resolved through the EXISTING G04 authority:
//     `G04WorkspaceSourceCoordinator.prepareMediaEgress` revalidates the
//     exact ordinary task/workspace binding, holds a REAL `.conversation`
//     owned-work lease, and resolves the path with the same guard resolver as
//     the generic snapshot path. No new root, no first-project or temporary
//     directory fallback, and no caller path can grant authority.
//   * The bytes are NOT copied into a second 8 GiB snapshot. The channel
//     opens ONE `O_NOFOLLOW` descriptor of the resolved regular file and
//     proves it twice with `fstat` (device/inode/size/mtime) around a full
//     bounded SHA-256 pass. That digest is the header digest the App streams
//     and verifies. A same-inode in-place mutation is rejected on the next
//     read (identity recheck) and by the incremental digest of exactly the
//     bytes served; a path swap cannot move the stream to another inode
//     because pread always uses the pinned descriptor.
//   * The lease (owned-work token + descriptor) is held until the host
//     session is closed. `close()` is exactly-once: it abandons an
//     unread body without claiming content, closes the descriptor and ends
//     the owned-work lease. Root retirement cancels the owned-work token, so
//     the next chunk refuses typed and Root drain sees the real work until
//     the App's close actually settles.
//
// There is no new journal, registry, allocator or storage authority here.
// The generic snapshot/stream-copy path is unchanged.
import Foundation
import Crypto
import FloeTools
import FloeAndroidWorkspaceTools
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif

/// Closed media-purpose kind. The extension sets are byte-aligned with the
/// App's `MediaWorkspaceStagingPolicy`; a path whose final extension is not in
/// the requested kind's set is refused BEFORE the owner lookup or any read.
public enum G04WorkspaceMediaKind: String, Sendable, CaseIterable, Equatable {
    case image
    case audio
    case video

    /// Reviewed R2 large-import ceilings. These apply ONLY to this closed
    /// media lane; `G04WorkspaceSourceCoordinator.maximumProviderCopyBytes`
    /// (1 GiB) still bounds every generic/Office/save/export copy.
    public static let maximumImageBytes = 128 * 1024 * 1024
    public static let maximumAudioBytes = Int(Int64(1) << 30)
    public static let maximumVideoBytes = Int(Int64(8) << 30)

    public var maximumBytes: Int {
        switch self {
        case .image: return Self.maximumImageBytes
        case .audio: return Self.maximumAudioBytes
        case .video: return Self.maximumVideoBytes
        }
    }

    /// Closed extension table (lowercase, final path component only).
    public var fileExtensions: Set<String> {
        switch self {
        case .image: return ["png", "jpg", "jpeg", "webp", "gif", "bmp", "heic", "heif"]
        case .audio: return ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus"]
        case .video: return ["mp4", "mov", "m4v"]
        }
    }

    /// The kind a logical path actually names, or nil for every other file.
    public static func kind(forLogicalPath path: String) -> G04WorkspaceMediaKind? {
        let name = (path as NSString).lastPathComponent
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let suffix = name[name.index(after: dot)...].lowercased()
        guard !suffix.isEmpty, !suffix.contains("/") else { return nil }
        return allCases.first { $0.fileExtensions.contains(suffix) }
    }
}

/// One prepared media egress: the exact authority lease, the resolved source
/// URL and the immutable sources of the header metadata. Produced by
/// `G04WorkspaceSourceCoordinator.prepareMediaEgress`; consumed by
/// `G04WorkspaceMediaEgressLease.open` OUTSIDE the coordinator actor so the
/// bounded full-file hash never blocks every other source operation.
public struct G04WorkspaceMediaEgressPreparation: Sendable {
    public let kind: G04WorkspaceMediaKind
    public let sourceURL: URL
    public let sourceID: UUID?
    public let sourceRevision: String?
    public let cancellation: CancellationToken
    /// Ends the exact owned-work lease exactly once (idempotent in the run
    /// domain's own bookkeeping).
    public let release: @Sendable () async -> Void

    public init(kind: G04WorkspaceMediaKind, sourceURL: URL, sourceID: UUID?,
                sourceRevision: String?, cancellation: CancellationToken,
                release: @escaping @Sendable () async -> Void) {
        self.kind = kind
        self.sourceURL = sourceURL
        self.sourceID = sourceID
        self.sourceRevision = sourceRevision
        self.cancellation = cancellation
        self.release = release
    }
}

/// A live, closed media egress over ONE pinned source descriptor.
///
/// Reads are strictly sequential 64 KiB `pread` calls at the exact captured
/// offset; the same buffer bytes feed an incremental SHA-256 that must equal
/// the digest computed at open before any content verdict is reported. The
/// source `fstat` identity is rechecked on every read, so an in-place change
/// (size or mtime) is a typed refusal rather than silently streamed bytes.
public final class G04WorkspaceMediaEgressLease: @unchecked Sendable {
    public enum CloseOutcome: Sendable, Equatable {
        /// The full body was served and its digest equals the open digest.
        case verified
        /// The body was abandoned before the last byte: no content claim.
        case abandoned
        /// The full body was served but the bytes/identity changed.
        case digestMismatch(expected: String, actual: String)
    }

    public static let maximumReadBytes = 65_536
    private static let hashChunkBytes = 65_536

    struct SourceIdentity: Sendable, Equatable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
    }

    public let kind: G04WorkspaceMediaKind
    /// Native-observed SHA-256 of the EXACT captured body (the App's header
    /// digest). Never a caller claim.
    public let sha256: String
    public let bytes: Int
    public let sourceID: UUID?
    public let sourceRevision: String?

    private let cancellation: CancellationToken
    private let release: @Sendable () async -> Void
    private let identity: SourceIdentity
    private let lock = NSLock()
    private var descriptor: Int32
    private var hasher = SHA256()
    private var cursor: Int64 = 0
    private var verified = false
    private var closed = false
    private var failure: G04SourceCoordinatorError?
    private var closeTask: Task<CloseOutcome, Never>?

    init(kind: G04WorkspaceMediaKind, descriptor: Int32, identity: SourceIdentity,
         sha256: String, bytes: Int, sourceID: UUID?, sourceRevision: String?,
         cancellation: CancellationToken,
         release: @escaping @Sendable () async -> Void) {
        self.kind = kind
        self.descriptor = descriptor
        self.identity = identity
        self.sha256 = sha256
        self.bytes = bytes
        self.sourceID = sourceID
        self.sourceRevision = sourceRevision
        self.cancellation = cancellation
        self.release = release
    }

    // MARK: - Open (bounded, cancellable, no second copy)

    /// Opens the prepared source: no-follow regular-file proof, closed media
    /// cap before any byte is read, one bounded full SHA-256 pass, then a
    /// second `fstat` identity proof. Throws a typed coordinator refusal and
    /// leaves no descriptor/lease behind on every failure path.
    static func open(_ preparation: G04WorkspaceMediaEgressPreparation) throws
        -> G04WorkspaceMediaEgressLease {
        let path = preparation.sourceURL.path
        guard let metadata = WorkspaceNoFollow.metadata(path) else {
            throw G04SourceCoordinatorError.invalidWorkingCopy("notRegularFile")
        }
        switch metadata.kind {
        case .file:
            break
        case .missing:
            throw G04SourceCoordinatorError.sourceMissing
        case .symlink:
            throw G04SourceCoordinatorError.invalidWorkingCopy("symlink")
        case .directory, .special, .unreadable:
            throw G04SourceCoordinatorError.invalidWorkingCopy("notRegularFile")
        }
        guard metadata.size > 0 else {
            throw G04SourceCoordinatorError.invalidWorkingCopy("notRegularFile")
        }
        guard metadata.size <= Int64(preparation.kind.maximumBytes),
              metadata.size <= Int64(Int.max) else {
            // The closed per-kind ceiling is the ONLY reason this lane
            // refuses on size; it reports the size status (-509), never the
            // generic invalidWorkingCopy/stateConflict refusal.
            throw G04SourceCoordinatorError.tooLarge(limit: preparation.kind.maximumBytes)
        }
        let descriptor: Int32
        switch WorkspaceNoFollow.openRegularNoFollow(path) {
        case .success(let opened):
            descriptor = opened
        case .failure(let error):
            throw Self.mapOpenFailure(error)
        }
        var handedOff = false
        defer { if !handedOff { Self.closeDescriptor(descriptor) } }

        // The lstat above is never authority for the descriptor we actually
        // read: prove the OPENED file and capture its exact identity.
        var before = stat()
        guard fstat(descriptor, &before) == 0 else {
            throw G04SourceCoordinatorError.providerFailed(code: "io")
        }
        let identity = Self.identity(of: before)
        guard identity.size > 0 else {
            throw G04SourceCoordinatorError.invalidWorkingCopy("notRegularFile")
        }
        guard identity.size <= Int64(preparation.kind.maximumBytes),
              identity.size <= Int64(Int.max) else {
            throw G04SourceCoordinatorError.tooLarge(limit: preparation.kind.maximumBytes)
        }

        var hasher = SHA256()
        var offset: Int64 = 0
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.hashChunkBytes, alignment: 1)
        defer { buffer.deallocate() }
        while offset < identity.size {
            if preparation.cancellation.isCancelled {
                throw G04SourceCoordinatorError.transitionRefused("cancelled")
            }
            let want = Int(min(Int64(Self.hashChunkBytes), identity.size - offset))
            let count = pread(descriptor, buffer, want, off_t(offset))
            if count < 0 {
                if errno == EINTR { continue }
                throw G04SourceCoordinatorError.providerFailed(code: "io")
            }
            if count == 0 { throw G04SourceCoordinatorError.readbackMismatch }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
            offset += Int64(count)
        }
        guard offset == identity.size else {
            throw G04SourceCoordinatorError.readbackMismatch
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        var after = stat()
        guard fstat(descriptor, &after) == 0 else {
            throw G04SourceCoordinatorError.providerFailed(code: "io")
        }
        guard Self.identity(of: after) == identity else {
            throw G04SourceCoordinatorError.digestMismatch(expected: digest,
                                                            actual: "sourceChanged")
        }
        if preparation.cancellation.isCancelled {
            throw G04SourceCoordinatorError.transitionRefused("cancelled")
        }
        let lease = G04WorkspaceMediaEgressLease(
            kind: preparation.kind, descriptor: descriptor, identity: identity,
            sha256: digest, bytes: Int(identity.size),
            sourceID: preparation.sourceID, sourceRevision: preparation.sourceRevision,
            cancellation: preparation.cancellation, release: preparation.release)
        handedOff = true
        return lease
    }

    // MARK: - Streaming reads (bounded; exact captured content only)

    /// Copies at most one bounded chunk at `offset` into the caller buffer.
    /// Returns 0 only at the exact captured EOF (after the digest/identity
    /// proof). Every mutation, short read or out-of-order offset is a typed
    /// refusal and becomes sticky for the rest of the session.
    func read(offset: Int64, into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw G04SourceCoordinatorError.transitionRefused("closed") }
        if let failure { throw failure }
        try checkCancellationLocked()
        guard count > 0, count <= Self.maximumReadBytes, offset >= 0 else {
            throw G04SourceCoordinatorError.transitionRefused("mediaRead")
        }
        let total = Int64(bytes)
        if offset == total {
            guard cursor == total else {
                throw G04SourceCoordinatorError.transitionRefused("offset")
            }
            try verifyIdentityLocked()
            try verifyDigestLocked()
            return 0
        }
        guard offset < total, offset == cursor else {
            throw G04SourceCoordinatorError.transitionRefused("offset")
        }
        let want = Int(min(total - offset, Int64(count)))
        try verifyIdentityLocked()
        var done = 0
        while done < want {
            let readCount = pread(descriptor, buffer.advanced(by: done),
                                  want - done, off_t(offset) + off_t(done))
            if readCount < 0 {
                if errno == EINTR { continue }
                throw remember(.providerFailed(code: "io"))
            }
            if readCount == 0 { throw remember(.readbackMismatch) }
            done += readCount
        }
        hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: done))
        cursor += Int64(done)
        if cursor == total {
            try verifyDigestLocked()
        }
        return done
    }

    // MARK: - Close (exactly once; lease + descriptor)

    /// Closes the pinned descriptor and ends the exact owned-work lease. Safe
    /// to call more than once and concurrently: all callers await the same
    /// one-shot close task.
    @discardableResult
    public func close() async -> CloseOutcome {
        await closeOperation().value
    }

    // Keep mutex operations synchronous: Swift 6 forbids NSLock.lock/unlock
    // in an async function. Only awaiting the shared task suspends.
    private func closeOperation() -> Task<CloseOutcome, Never> {
        let task: Task<CloseOutcome, Never>
        lock.lock()
        if let existing = closeTask {
            task = existing
            lock.unlock()
        } else {
            let created = Task<CloseOutcome, Never> { [self] in
                let outcome = finish()
                await release()
                return outcome
            }
            closeTask = created
            lock.unlock()
            task = created
        }
        return task
    }

    private func finish() -> CloseOutcome {
        lock.lock()
        var outcome: CloseOutcome = .abandoned
        if !closed {
            if let failure, case .digestMismatch(let expected, let actual) = failure {
                // A mutation/short-read refusal already consumed the hash
                // state during `read`; keep the exact typed verdict.
                outcome = .digestMismatch(expected: expected, actual: actual)
            } else if cursor == Int64(bytes) {
                do {
                    try verifyDigestLocked()
                    outcome = .verified
                } catch let error as G04SourceCoordinatorError {
                    if case .digestMismatch(let expected, let actual) = error {
                        outcome = .digestMismatch(expected: expected, actual: actual)
                    }
                } catch {
                    outcome = .abandoned
                }
            }
            closed = true
            if descriptor >= 0 {
                Self.closeDescriptor(descriptor)
                descriptor = -1
            }
        } else if verified {
            outcome = .verified
        }
        lock.unlock()
        return outcome
    }

    // MARK: - Proof helpers (all under the lease lock)

    private func checkCancellationLocked() throws {
        if cancellation.isCancelled {
            throw remember(.transitionRefused("cancelled"))
        }
    }

    private func remember(_ error: G04SourceCoordinatorError) -> G04SourceCoordinatorError {
        failure = error
        return error
    }

    private func verifyIdentityLocked() throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw remember(.providerFailed(code: "io"))
        }
        guard Self.identity(of: info) == identity else {
            throw remember(.digestMismatch(expected: sha256, actual: "sourceChanged"))
        }
    }

    private func verifyDigestLocked() throws {
        if verified { return }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == sha256 else {
            throw remember(.digestMismatch(expected: sha256, actual: actual))
        }
        verified = true
    }

    // MARK: - POSIX helpers

    static func identity(of info: stat) -> SourceIdentity {
        #if canImport(Darwin)
        let times = info.st_mtimespec
        #else
        let times = info.st_mtim
        #endif
        return SourceIdentity(device: Int64(info.st_dev),
                              inode: UInt64(info.st_ino),
                              size: Int64(info.st_size),
                              modifiedSeconds: Int64(times.tv_sec),
                              modifiedNanoseconds: Int64(times.tv_nsec))
    }

    private static func closeDescriptor(_ descriptor: Int32) {
        guard descriptor >= 0 else { return }
        #if canImport(Darwin)
        _ = Darwin.close(descriptor)
        #elseif canImport(Glibc)
        _ = Glibc.close(descriptor)
        #elseif canImport(Android)
        _ = Android.close(descriptor)
        #endif
    }

    /// Maps the workspace-tools open proof onto the coordinator vocabulary
    /// WITHOUT ever turning a size refusal into a generic working-copy one.
    private static func mapOpenFailure(_ error: WorkspaceTransferError)
        -> G04SourceCoordinatorError {
        switch error {
        case .pathUnsafe(let code):
            return .invalidWorkingCopy(String(code.prefix(64)))
        case .cancelled:
            return .transitionRefused("cancelled")
        case .ioFailed(let stage, _):
            return .providerFailed(code: String(stage.prefix(32)))
        case .notConfigured, .proofRefused, .budgetExceeded, .diskReserveUnmet,
             .commitRefused, .noSession, .malformed:
            return .providerFailed(code: "io")
        @unknown default:
            return .providerFailed(code: "io")
        }
    }
}
