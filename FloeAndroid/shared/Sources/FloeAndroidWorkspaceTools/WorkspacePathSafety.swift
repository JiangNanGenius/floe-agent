// FloeAndroidWorkspaceTools — relative-path safety for workspace transfer.
//
// Android-owned (job-ade884c46eb84ec1). The rules mirror the ORIGINAL
// containment authorities this lane reuses instead of copying:
//  * `DesignWorkspace.contained(relativePath:in:)` (FloeCore) — RAW component
//    validation before any filesystem call, NUL refusal, standardized
//    containment check;
//  * `G02WorkspaceCleaning` (FloeAndroidCore, G02ProviderImplementations.swift)
//    — non-following `lstat` metadata at every managed level, a symlink is a
//    typed refusal that touches NOTHING, only authoritative ENOENT is absence,
//    other errnos are failures, never absence;
//  * `FloeArtifactStore.resolve` — namespace/containment defense-in-depth.
// Everything runs on RAW relative strings; `URL(fileURLWithPath:)` is never
// used for validation because it resolves against the process CWD.

import Foundation
import Crypto
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif

/// Workspace-relative path safety. All entry points are pure string checks
/// first and touch the filesystem only through the no-follow helpers below.
public enum WorkspaceRelativePath {
    public static let maximumComponentBytes = 255
    public static let maximumComponents = 256

    /// Validates the RAW relative path. Returns the component list on
    /// success. Refusals are typed with a stable short code.
    public static func validate(_ raw: String, budgets: WorkspaceTransferBudgets) throws -> [String] {
        guard !raw.isEmpty else { throw WorkspaceTransferError.pathUnsafe(code: "empty") }
        guard raw.utf8.count <= budgets.maximumRelativePathBytes else {
            throw WorkspaceTransferError.pathUnsafe(code: "overlongTotal")
        }
        guard !raw.hasPrefix("/"), !raw.hasPrefix("~") else {
            throw WorkspaceTransferError.pathUnsafe(code: "absolute")
        }
        guard raw.unicodeScalars.allSatisfy({ $0.value > 0x1F && $0.value != 0x7F }) else {
            // Rejects NUL and every C0 control (incl. newline/tab in names)
            // BEFORE any filesystem call, exactly like G02WorkspaceCleaning.
            throw WorkspaceTransferError.pathUnsafe(code: "controlChar")
        }
        let components = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.count <= maximumComponents else {
            throw WorkspaceTransferError.pathUnsafe(code: "tooDeep")
        }
        for component in components {
            guard !component.isEmpty, component != ".", component != ".." else {
                throw WorkspaceTransferError.pathUnsafe(code: "badComponent")
            }
            guard component.utf8.count <= maximumComponentBytes else {
                throw WorkspaceTransferError.pathUnsafe(code: "overlongComponent")
            }
            // Internal staging/commit namespaces are never workspace data:
            // reject them so an attacker-crafted runtime entry cannot collide
            // with AtomicFileCommitter temporaries or transfer journals.
            guard !component.hasPrefix(".floe-commit-"),
                  !component.hasPrefix(".floe-wt-"),
                  !component.hasPrefix(".workspace-bridge") else {
                throw WorkspaceTransferError.pathUnsafe(code: "reservedName")
            }
        }
        return components
    }

    /// Case-fold key used for on-actual-FS collision detection. Simple
    /// lowercasing is the conservative over-approximation (flags more
    /// potential collisions than a specific FS would merge; that is the safe
    /// direction — a real collision can never hide).
    public static func caseFoldKey(_ raw: String) -> String {
        raw.lowercased()
    }

    // MARK: - Symlink target safety

    /// Classifies a recorded link target WITHOUT following anything.
    /// `.relativeContained` means: relative, and textual resolution from the
    /// link's own directory stays inside the workspace root after removing
    /// `..` segments. `node_modules/.bin`-style links survive; anything
    /// absolute, escaping or malformed is `.external` and never replicated
    /// into either tree by this engine.
    public enum LinkTargetSafety: Equatable {
        case relativeContained
        case external
    }

    public static func classifyLinkTarget(_ target: String,
                                          linkComponents: [String],
                                          budgets: WorkspaceTransferBudgets) -> LinkTargetSafety {
        guard !target.isEmpty,
              target.utf8.count <= budgets.maximumLinkTargetBytes,
              !target.hasPrefix("/"), !target.hasPrefix("~"),
              target.unicodeScalars.allSatisfy({ $0.value > 0x1F && $0.value != 0x7F })
        else { return .external }
        let targetComponents = target.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !targetComponents.isEmpty else { return .external }
        // Depth of the link's parent directory inside the workspace.
        var depth = linkComponents.count - 1
        for component in targetComponents {
            if component.isEmpty || component == "." { continue }
            if component == ".." {
                guard depth > 0 else { return .external }
                depth -= 1
                continue
            }
            guard component.utf8.count <= maximumComponentBytes, component != "..", component != "." else {
                return .external
            }
            depth += 1
            guard depth <= maximumComponents else { return .external }
        }
        // A final component may be "." or ".."-free depth >= 0; remaining at
        // or above root is still inside the tree.
        return depth >= 0 ? .relativeContained : .external
    }
}

// MARK: - Non-following filesystem kinds

public enum WorkspaceEntryKind: String, Sendable, Equatable {
    case file
    case directory
    case symlink
    /// FIFO/socket/device: never transferred, typed refusal (the runtime
    /// side cannot legitimately create these inside the workspace through
    /// this bridge, and a hostile tree must not smuggle them).
    case special
    case missing
    /// A non-ENOENT lstat failure: never treated as absence.
    case unreadable
}

public enum WorkspaceNoFollow {
    /// Non-following kind of one absolute path (lstat). ENOENT is the ONLY
    /// authoritative `.missing`; anything else (EACCES/EIO/ENOTDIR/...) is
    /// `.unreadable` — the G02WorkspaceCleaning discipline.
    public static func kind(_ path: String) -> WorkspaceEntryKind {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return errno == ENOENT ? .missing : .unreadable
        }
        let type = info.st_mode & mode_t(S_IFMT)
        switch type {
        case mode_t(S_IFREG): return .file
        case mode_t(S_IFDIR): return .directory
        case mode_t(S_IFLNK): return .symlink
        default: return .special
        }
    }

    /// lstat with the stat buffer (callers need size/mode/digest fields).
    public static func metadata(_ path: String) -> (kind: WorkspaceEntryKind, size: Int64, mode: Int32, mtimeSeconds: Int64)? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return (.missing, 0, 0, 0) }
            return nil
        }
        let kind: WorkspaceEntryKind
        switch info.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG): kind = .file
        case mode_t(S_IFDIR): kind = .directory
        case mode_t(S_IFLNK): kind = .symlink
        default: kind = .special
        }
        #if canImport(Darwin)
        let mtime = Int64(info.st_mtimespec.tv_sec)
        #else
        // Glibc and Android both expose the timespec field directly; the C
        // `st_mtime` macro is not visible to Swift.
        let mtime = Int64(info.st_mtim.tv_sec)
        #endif
        return (kind, Int64(info.st_size), Int32(info.st_mode & 0o7777), mtime)
    }

    /// Open one fd with O_NOFOLLOW for a final regular file (digest/open path).
    /// Returns fd >= 0 or a typed refusal carrying the real errno.
    public static func openRegularNoFollow(_ path: String) -> Result<Int32, WorkspaceTransferError> {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Android)
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            return .failure(.ioFailed(stage: "open", errnoCode: Int32(errno)))
        }
        var info = stat()
        if fstat(fd, &info) != 0 {
            let code = errno
            close(fd)
            return .failure(.ioFailed(stage: "fstat", errnoCode: Int32(code)))
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            close(fd)
            return .failure(.pathUnsafe(code: "notRegularFile"))
        }
        return .success(fd)
        #else
        return .failure(.ioFailed(stage: "open", errnoCode: -1))
        #endif
    }

    /// ACTUAL `fstat` proof that a CALLER-OWNED fd is a regular file,
    /// returning its real size (the claim in a stage header is never
    /// authoritative for planning). Performs no read, never closes the fd,
    /// and rejects pipes/Sockets/etc. with a typed refusal BEFORE any IO
    /// could block Core. The fd's ownership stays with the caller.
    public static func regularFileProof(_ fd: Int32) -> Result<Int64, WorkspaceTransferError> {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Android)
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            return .failure(.ioFailed(stage: "sourceFstat", errnoCode: Int32(errno)))
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            return .failure(.pathUnsafe(code: "sourceNotRegular"))
        }
        return .success(Int64(info.st_size))
        #else
        return .failure(.ioFailed(stage: "sourceFstat", errnoCode: -1))
        #endif
    }

    /// readlink of one exact path (never follows past the link itself).
    public static func readlink(_ path: String, limit: Int) -> String? {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Android)
        var buffer = [CChar](repeating: 0, count: limit + 1)
        // The syscall is qualified so this static helper does not resolve to
        // itself (the same shadowing class as the baseline manifest writer).
        #if canImport(Darwin)
        let length = Darwin.readlink(path, &buffer, limit)
        #elseif canImport(Android)
        let length = Android.readlink(path, &buffer, limit)
        #else
        let length = Glibc.readlink(path, &buffer, limit)
        #endif
        guard length >= 0, length <= limit else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #else
        return nil
        #endif
    }

    /// Free-bytes check against the reserve (statvfs on the volume owning
    /// `path`). Returns false when the filesystem cannot be queried —
    /// unknown space is unmet space (fail closed).
    public static func meetsFreeReserve(path: String, reserveBytes: Int64, projectedBytes: Int64) -> Bool {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Android)
        var info = statvfs()
        guard statvfs(path, &info) == 0 else { return false }
        let blocksize = Int64(info.f_frsize > 0 ? info.f_frsize : info.f_bsize)
        let available = Int64(info.f_bavail) * blocksize
        return available - projectedBytes >= reserveBytes
        #else
        return false
        #endif
    }

    /// fsync of a directory path (durability marker for rename/unlink
    /// effects). Best-effort at the commit boundary; failures are surfaced
    /// by the journal state machine, not hidden.
    @discardableResult
    public static func fsyncDirectory(_ path: String) -> Bool {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Android)
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return fsync(fd) == 0
        #else
        return false
        #endif
    }
}

// MARK: - Streaming copy

/// Bounded streaming between two fds: fixed frame buffer, per-frame
/// cancellation check, byte accounting against a maximum, digest of the
/// ACTUAL bytes transferred (claimed metadata is never authoritative).
public enum WorkspaceStreamCopier {
    public struct Outcome: Sendable, Equatable {
        public var bytes: Int64
        public var sha256: String
    }

    public enum Failure: Error {
        case transfer(WorkspaceTransferError)
        case overflow(Int64)
        case cancelled
    }

    /// Reads `fromFd` until EOF (or `maximumBytes` + 1 byte to detect an
    /// overflow) and writes every byte to `toFd`, hashing the bytes it
    /// actually moved. Does NOT trust any claimed size.
    public static func copy(fromFd: Int32, toFd: Int32, frameBytes: Int,
                            maximumBytes: Int64,
                            isCancelled: () -> Bool,
                            reserveGate: (Int64) -> WorkspaceTransferError? = { _ in nil }
    ) -> Result<Outcome, Failure> {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Android)
        // Descriptor/IO contract: prove the SOURCE is a real regular file via
        // fstat BEFORE the first read. A passed pipe/socket could otherwise
        // block Core IO and the stop path indefinitely. The caller's fd is
        // NOT closed here; the real stream digest/count below stays the
        // authority — a file that grows past `maximumBytes` mid-copy is
        // rejected by the per-frame bound, never silently truncated.
        if case .failure(let proofFailure) = WorkspaceNoFollow.regularFileProof(fromFd) {
            return .failure(.transfer(proofFailure))
        }
        var hasher = SHA256()
        let frame = max(4_096, min(frameBytes, 262_144))
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: frame, alignment: 1)
        defer { buffer.deallocate() }
        var moved: Int64 = 0
        while true {
            if isCancelled() { return .failure(.cancelled) }
            let readCount = read(fromFd, buffer, frame)
            if readCount < 0 {
                let code = errno
                if code == EINTR { continue }
                return .failure(.transfer(.ioFailed(stage: "read", errnoCode: Int32(code))))
            }
            if readCount == 0 { break }
            if moved + Int64(readCount) > maximumBytes {
                return .failure(.overflow(moved + Int64(readCount)))
            }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: readCount))
            var written = 0
            while written < readCount {
                let count = write(toFd, buffer + written, readCount - written)
                if count < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    return .failure(.transfer(.ioFailed(stage: "write", errnoCode: Int32(code))))
                }
                written += count
            }
            moved += Int64(readCount)
            // Bounded-growth guard (coordinator steer 20261022): the ONE
            // pre-copy reserve projection can only see the snapshot size; a
            // source that grows concurrently may consume up to
            // `maximumBytes`. Re-measure the ACTUAL destination free space
            // as staging grows; a violation refuses with the caller's typed
            // error (engine: diskReserveUnmet) WITHOUT closing either fd —
            // the recovery state (journal + prior staged entries) stays the
            // caller's to keep.
            if let reserveFailure = reserveGate(moved) {
                return .failure(.transfer(reserveFailure))
            }
        }
        if fsync(toFd) != 0 {
            return .failure(.transfer(.ioFailed(stage: "fsync", errnoCode: Int32(errno))))
        }
        return .success(Outcome(bytes: moved, sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()))
        #else
        return .failure(.transfer(.ioFailed(stage: "unsupported", errnoCode: -1)))
        #endif
    }
}
