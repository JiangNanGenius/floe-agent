// FloeApp — anchored publication of one exported file.
//
// Pure core: Foundation, CryptoKit and POSIX only, no UI or WebKit dependency,
// so this file object-compiles and unit-tests standalone while the
// WebKit-bound service consumes it unchanged.
//
// THE TWO ENDS OF ONE PUBLICATION. The bytes are staged in a service-owned
// PRIVATE directory that is not part of any workspace, and they are published
// into a destination directory that is anchored by descriptor under the
// authorized workspace root. Neither end is addressed by a caller-supplied path
// after anchoring, so a concurrent writer — including model-authored code
// running in the resolved Linux environment, whose host-side file operations
// run as this same uid inside the mounted workspace — cannot retarget either
// the staged bytes or the committed name.
//
// WHY NOT THE EXISTING COMMIT HELPERS. The project's staged-commit paths
// (`AtomicFileCommitter`, `EnvironmentFileTransaction.copy`, the document-intake
// durable writer) publish with a path-based `moveItem` / `replaceItemAt` /
// `rename` decided by an earlier path check. An export must never overwrite an
// existing destination, so publication here needs a primitive whose exclusion is
// atomic. Two are available and both are verified against the shipping SDK:
//   * `renameatx_np(..., RENAME_EXCL)` — declared in `sys/stdio.h` for iOS 10+
//     in the iPhoneOS and iPhoneSimulator SDKs, and `URLResourceValues
//     .volumeSupportsExclusiveRenaming` reports the volume capability. It
//     creates the destination and consumes the staging name in ONE atomic step,
//     and fails with EEXIST when anything occupies the destination.
//   * `linkat` between two directory descriptors — POSIX requires only that
//     both names are on the same filesystem, not the same directory, so the
//     private staging directory and the anchored destination directory may
//     differ. EEXIST is again the exclusion.
// The first is preferred; the second is the fallback for a volume that refuses
// the exclusive rename. A cross-device pair (EXDEV) fails closed: there is no
// copy-and-overwrite fallback anywhere in this file.
//
// WHY DESCRIPTORS. A path-based "check the parent, create the staging file
// exclusively, then publish it" sequence is atomic only for the final name.
// Every earlier step is a name lookup that can be redirected: an ancestor
// directory can be replaced by a symlink or moved. Note this is not purely
// adversarial — `URL.resolvingSymlinksInPath` leaves a symlinked ancestor
// unresolved when the tail does not exist yet, so a create-new destination
// under a symlinked directory keeps a path that a textual containment check
// accepts while the real target may lie outside the workspace. Here the
// authorized root is opened with `O_NOFOLLOW`, every remaining component with
// `openat` + `O_NOFOLLOW`, and the resulting directory descriptor is proven to
// sit under the root by walking `..` back to the root's own (device, inode)
// identity and to still be the directory the authorized relative path names.
//
// GUARANTEES, stated exactly.
// 1. Containment: the committed name is created only inside a directory inode
//    proven, immediately before and after publication, to be inside the
//    authorized root and to be the directory the authorized relative path names.
// 2. No overwrite: publication fails with EEXIST when the destination name is
//    occupied by anything — file, symlink or directory — and an existing file or
//    symlink target is never modified or followed.
// 3. No foreign inode: the staging name is identity-checked immediately before
//    publication and the destination name immediately after it, so a substituted
//    staging file is never published.
// 4. Content: the digest reported for a delivery is recomputed from the
//    committed inode itself, through this transaction's own descriptor, after
//    publication. A payload tampered with during the pull is therefore never
//    reported as delivered.
// 5. Staging privacy: the staged bytes never exist inside a workspace, so no
//    workspace writer can plant, replace or read a staging name, and cleanup
//    touches only this transaction's private directory.
// 6. No destructive rollback: once the destination name exists, this file never
//    removes it. A failed verification leaves the bytes in place, recoverable
//    and inspectable, and reports the failure instead of claiming a delivery.
//
// RESIDUAL LIMITS, stated exactly. Nothing here closes these, and no comment
// claims otherwise:
// * A rename of an ancestor landing between the last anchor proof and the
//   publication syscall still creates the name inside the verified directory
//   inode. The post-publication re-verification then fails the export rather
//   than reporting it, and the file stays where it landed. A competing writer
//   can make an export fail; it cannot make one succeed somewhere else.
// * The identity checks around retirement of the private staging name are
//   `fstatat` then `unlinkat`, not one atomic operation. Because that directory
//   is service-owned private storage outside every mounted workspace, no other
//   writer can name a file inside it; the sequence is uncontested by
//   construction rather than by atomicity.
// * A writer that already holds a descriptor to the staged inode can rewrite its
//   bytes after the post-publication digest is computed. From that moment the
//   file is an ordinary delivered workspace file, and modification of it is
//   indistinguishable from the user editing it — which is why the receipt
//   reports the digest measured at publication and never promises the file is
//   immutable afterwards.

import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin

/// Stable identity of one filesystem object.
struct StagedExportFileIdentity: Equatable, Sendable, CustomStringConvertible {
    let device: Int64
    let inode: UInt64

    var description: String { "dev=\(device) ino=\(inode)" }

    init(device: Int64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }

    init(_ info: stat) {
        device = Int64(info.st_dev)
        inode = UInt64(info.st_ino)
    }
}

/// How the staged inode is published into the anchored destination directory.
enum StagedExportPublication: String, Sendable {
    /// `renameatx_np` with `RENAME_EXCL`: creates the destination and consumes
    /// the staging name atomically. Preferred.
    case exclusiveRename
    /// `linkat` between the two directory descriptors, then retirement of the
    /// private staging name. Fallback for a volume that refuses the exclusive
    /// rename.
    case hardLink
}

/// Why one anchored staging/commit transaction refused to proceed. Reasons are
/// content-free: they name the failed invariant, never file content.
enum StagedExportFileTransactionError: Error, Equatable {
    /// The requested anchor is malformed (empty, traversing or oversized
    /// component), the private staging directory is not usable, or a component
    /// could not be opened without following a symlink.
    case anchorRefused(String)
    /// The private staging directory and the destination are on different
    /// filesystems. There is no copy fallback.
    case crossDevice(String)
    /// The anchored directory is no longer inside the authorized root, or is no
    /// longer the directory the authorized relative path names.
    case containmentLost(String)
    /// Something already occupies the destination name. Nothing is overwritten.
    case destinationOccupied(String)
    /// The staging name no longer refers to the inode this transaction wrote.
    case stagedNameReplaced(String)
    /// Publication succeeded but the destination name does not refer to the
    /// verified inode. The bytes are left in place and nothing is delivered.
    case commitIdentityMismatch(String)
    /// The published inode's content does not match the digest the caller
    /// verified. The bytes are left in place and nothing is delivered.
    case commitContentChanged(String)
    /// A write, flush, stat, rename, link or unlink failed.
    case storage(String)
}

/// One anchored publication: private staging plus an exclusive commit into a
/// destination directory that was proven to belong to the authorized workspace.
final class StagedExportFileTransaction {
    /// Bounds on the authorized relative path. The workspace path guard already
    /// rejects traversal; these keep the descriptor walk itself bounded.
    static let maxComponents = 64
    static let maxComponentBytes = 255
    /// Bound on the `..` walk back to the root identity.
    static let maxAncestorSteps = 128
    /// Chunk size for the descriptor-relative content re-read.
    private static let verifyChunkBytes = 1 << 20
    /// Staging is private while it is being filled; the published deliverable
    /// carries the ordinary workspace file mode so the task's own verification
    /// and publication steps can read it.
    private static let stagingMode = mode_t(0o600)
    static let committedMode = mode_t(0o644)

    /// What one successful publication established.
    struct Commit: Equatable {
        /// Identity of the committed destination inode (the staged inode).
        let destinationIdentity: StagedExportFileIdentity
        /// Bytes the destination inode holds, measured after publication.
        let bytes: Int64
        /// SHA-256 recomputed from the committed inode after publication.
        let contentSHA256: String
        /// Which primitive published the file.
        let publishedBy: StagedExportPublication
        /// False when the private staging name survived publication and could
        /// not be retired. The verified commit stands; the leftover is reported
        /// honestly instead of failing an export that was delivered.
        let stagingRetired: Bool
    }

    /// Descriptor ownership is single: exactly one of `open` (before the
    /// transaction exists) and the transaction (after) closes any descriptor.
    private let stagingDirectoryDescriptor: Int32
    private let stagingDirectoryIdentity: StagedExportFileIdentity
    private let stagingName: String
    private let stagingDescriptor: Int32
    private let stagingIdentity: StagedExportFileIdentity
    private let rootDescriptor: Int32
    private let rootIdentity: StagedExportFileIdentity
    private let directoryDescriptor: Int32
    private let directoryIdentity: StagedExportFileIdentity
    private let directoryComponents: [String]
    private let destinationName: String
    private let publication: StagedExportPublication
    private var bytesWritten: Int64 = 0
    private var sealed = false
    private var stagingConsumed = false
    private var stagingDiscarded = false
    private var descriptorsClosed = false

    private init(
        stagingDirectoryDescriptor: Int32,
        stagingDirectoryIdentity: StagedExportFileIdentity,
        stagingName: String,
        stagingDescriptor: Int32,
        stagingIdentity: StagedExportFileIdentity,
        rootDescriptor: Int32,
        rootIdentity: StagedExportFileIdentity,
        directoryDescriptor: Int32,
        directoryIdentity: StagedExportFileIdentity,
        directoryComponents: [String],
        destinationName: String,
        publication: StagedExportPublication
    ) {
        self.stagingDirectoryDescriptor = stagingDirectoryDescriptor
        self.stagingDirectoryIdentity = stagingDirectoryIdentity
        self.stagingName = stagingName
        self.stagingDescriptor = stagingDescriptor
        self.stagingIdentity = stagingIdentity
        self.rootDescriptor = rootDescriptor
        self.rootIdentity = rootIdentity
        self.directoryDescriptor = directoryDescriptor
        self.directoryIdentity = directoryIdentity
        self.directoryComponents = directoryComponents
        self.destinationName = destinationName
        self.publication = publication
    }

    deinit {
        discardStagingName()
        closeDescriptors()
    }

    // MARK: - Destination anchoring

    /// One anchored destination: the physical workspace root plus the real
    /// directory components and file name of the guard-resolved destination.
    struct Anchor: Equatable {
        let rootPath: String
        let directoryComponents: [String]
        let destinationName: String
    }

    /// Derives the anchor from the authorized workspace root and the path
    /// guard's resolved destination, and re-proves that the declared relative
    /// path still resolves to that same physical file.
    ///
    /// The caller's path guard already decided containment, mounts and secret
    /// exclusions; this does not repeat that policy. It converts the guard's
    /// answer into the only form a descriptor-relative publication can use — a
    /// physical root plus components the caller then re-opens with `O_NOFOLLOW`
    /// — and refuses when the declared path no longer resolves to the guard's
    /// destination, which is what an ancestor swapped after authorization looks
    /// like. A symlinked destination directory is not resolved away here; the
    /// nofollow walk refuses it, which is what keeps the write inside the
    /// workspace.
    static func anchor(
        workspaceRootURL: URL,
        destinationURL: URL,
        relativePath: String
    ) throws -> Anchor {
        let rootPath = workspaceRootURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard rootPath.hasPrefix("/"), rootPath.count > 1 else {
            throw StagedExportFileTransactionError.anchorRefused(
                "the task workspace root is not a usable absolute directory")
        }
        let guardedPath = destinationURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard guardedPath.hasPrefix(rootPath + "/") else {
            throw StagedExportFileTransactionError.anchorRefused(
                "the export destination belongs to a different workspace")
        }
        // Repeat the guard's own join-and-resolve for the declared relative
        // path. Equal results mean the authorized destination is still the file
        // that path names.
        let normalized = (relativePath as NSString).standardizingPath
        guard !normalized.split(separator: "/").contains("..") else {
            throw StagedExportFileTransactionError.anchorRefused(
                "the destination must not traverse upward")
        }
        let recomputed = URL(fileURLWithPath: rootPath)
            .appendingPathComponent(normalized)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        guard recomputed == guardedPath else {
            throw StagedExportFileTransactionError.anchorRefused(
                "the destination no longer resolves to the authorized workspace path")
        }

        let remainder = String(guardedPath.dropFirst(rootPath.count + 1))
        var components = remainder
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        components.removeAll { $0 == "." }
        guard !components.isEmpty, !components.contains("..") else {
            throw StagedExportFileTransactionError.anchorRefused(
                "the destination must name a file inside the task workspace")
        }
        for component in components {
            guard component.utf8.count <= maxComponentBytes else {
                throw StagedExportFileTransactionError.anchorRefused(
                    "a destination path component exceeds \(maxComponentBytes) bytes")
            }
        }
        guard components.count <= maxComponents else {
            throw StagedExportFileTransactionError.anchorRefused(
                "the destination is deeper than \(maxComponents) directories")
        }
        return Anchor(
            rootPath: rootPath,
            directoryComponents: Array(components.dropLast()),
            destinationName: components[components.count - 1])
    }

    // MARK: - Opening

    /// Opens the private staging directory and the anchored destination
    /// directory, proves they are distinct directories on one filesystem, proves
    /// the destination sits under the authorized root and is still named by the
    /// authorized relative path, and creates the staging file exclusively.
    ///
    /// - Parameters:
    ///   - stagingDirectoryPath: service-owned private directory, outside every
    ///     mounted workspace. Refused when it is the workspace root, inside it,
    ///     or the destination directory itself.
    ///   - stagingName: single component for the staged file inside it.
    ///   - rootPath: physical workspace root, already symlink-resolved by the
    ///     caller's path guard. Opened with `O_NOFOLLOW`, so a root replaced by
    ///     a symlink since that resolution fails closed here.
    ///   - directoryComponents: the destination's parent directory relative to
    ///     the root. Empty when the destination sits in the root itself.
    ///   - destinationName: single component for the publication target.
    ///   - publication: the preferred publication primitive.
    static func open(
        stagingDirectoryPath: String,
        stagingName: String,
        rootPath: String,
        directoryComponents: [String],
        destinationName: String,
        publication: StagedExportPublication = .exclusiveRename
    ) throws -> StagedExportFileTransaction {
        try validate(component: stagingName, role: "staging name")
        try validate(component: destinationName, role: "destination name")
        guard directoryComponents.count <= maxComponents else {
            throw StagedExportFileTransactionError.anchorRefused(
                "the destination is deeper than \(maxComponents) directories")
        }
        for component in directoryComponents {
            try validate(component: component, role: "destination directory")
        }
        let stagingPath = stagingDirectoryPath.hasSuffix("/")
            ? String(stagingDirectoryPath.dropLast()) : stagingDirectoryPath
        guard stagingPath.hasPrefix("/"), stagingPath.count > 1 else {
            throw StagedExportFileTransactionError.anchorRefused(
                "the private staging directory is not a usable absolute directory")
        }
        // The staging directory must be private: never the workspace root, never
        // inside it, so no workspace writer can name a file inside it.
        guard !stagingPath.hasPrefix(rootPath + "/"), stagingPath != rootPath else {
            throw StagedExportFileTransactionError.anchorRefused(
                "the private staging directory must live outside the task workspace")
        }

        let stagingDirectoryDescriptor = stagingPath.withCString { path in
            Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, 0)
        }
        guard stagingDirectoryDescriptor >= 0 else {
            throw StagedExportFileTransactionError.anchorRefused(
                "the private staging directory could not be opened (errno \(errno))")
        }
        var stagingDirectoryInfo = stat()
        guard fstat(stagingDirectoryDescriptor, &stagingDirectoryInfo) == 0,
              isDirectory(stagingDirectoryInfo) else {
            Darwin.close(stagingDirectoryDescriptor)
            throw StagedExportFileTransactionError.anchorRefused(
                "the private staging directory is not a directory")
        }
        let stagingDirectoryIdentity = StagedExportFileIdentity(stagingDirectoryInfo)

        let rootDescriptor = rootPath.withCString { path in
            Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, 0)
        }
        guard rootDescriptor >= 0 else {
            Darwin.close(stagingDirectoryDescriptor)
            throw StagedExportFileTransactionError.anchorRefused(
                "the authorized workspace could not be opened (errno \(errno))")
        }
        var rootInfo = stat()
        guard fstat(rootDescriptor, &rootInfo) == 0, isDirectory(rootInfo) else {
            Darwin.close(rootDescriptor)
            Darwin.close(stagingDirectoryDescriptor)
            throw StagedExportFileTransactionError.anchorRefused(
                "the authorized workspace is not a directory")
        }
        let rootIdentity = StagedExportFileIdentity(rootInfo)

        // Descriptor bookkeeping. Only the root and the leaf directory outlive
        // the walk, so each intermediate ancestor is closed as soon as the next
        // component is open: a deep destination costs no extra descriptors, and
        // a failure closes exactly what is open. `transferred` is the single
        // ownership handoff to the transaction.
        var current = rootDescriptor
        var currentIdentity = rootIdentity
        var leafDescriptor: Int32 = -1
        var stagingDescriptor: Int32 = -1
        var transferred = false
        do {
            for component in directoryComponents {
                let child = component.withCString { name in
                    openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, 0)
                }
                guard child >= 0 else {
                    let code = errno
                    // Refusing to follow a link reports ENOTDIR here, so the two
                    // causes are told apart by looking at the entry itself.
                    switch code {
                    case ENOENT:
                        throw StagedExportFileTransactionError.anchorRefused(
                            "the destination directory does not exist")
                    case ELOOP, ENOTDIR:
                        throw StagedExportFileTransactionError.anchorRefused(
                            isSymbolicLink(current, component)
                                ? "the destination directory is a symbolic link; export into a real directory of this task's workspace"
                                : "a component of the destination directory is not a directory")
                    default:
                        throw StagedExportFileTransactionError.anchorRefused(
                            "the destination directory could not be opened (errno \(code))")
                    }
                }
                var childInfo = stat()
                guard fstat(child, &childInfo) == 0, isDirectory(childInfo) else {
                    Darwin.close(child)
                    throw StagedExportFileTransactionError.anchorRefused(
                        "the destination directory changed while it was being opened")
                }
                // The previous intermediate ancestor is no longer needed. The
                // root is never closed here; the transaction owns it.
                if leafDescriptor >= 0 { Darwin.close(leafDescriptor) }
                leafDescriptor = child
                current = child
                currentIdentity = StagedExportFileIdentity(childInfo)
            }

            // Publication crosses directories, so both ends must be on one
            // filesystem. Checked before a single byte is staged: discovering
            // EXDEV after a long pull would waste the whole export.
            guard stagingDirectoryIdentity.device == Int64(currentIdentity.device) else {
                throw StagedExportFileTransactionError.crossDevice(
                    "the private staging volume and the task workspace are different filesystems")
            }
            guard stagingDirectoryIdentity != currentIdentity else {
                throw StagedExportFileTransactionError.anchorRefused(
                    "the private staging directory must not be the destination directory")
            }

            // O_RDWR, not O_WRONLY: the staged inode is read back through this
            // same descriptor to recompute its content digest after publication.
            stagingDescriptor = stagingName.withCString { name in
                openat(stagingDirectoryDescriptor, name,
                       O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, stagingMode)
            }
            guard stagingDescriptor >= 0 else {
                let code = errno
                throw StagedExportFileTransactionError.storage(
                    code == EEXIST
                        ? "the staging name is already in use"
                        : "the staging file could not be created (errno \(code))")
            }
            var stagingInfo = stat()
            guard fstat(stagingDescriptor, &stagingInfo) == 0,
                  isRegularFile(stagingInfo),
                  stagingInfo.st_size == 0,
                  stagingInfo.st_nlink == 1 else {
                Darwin.close(stagingDescriptor)
                stagingDescriptor = -1
                throw StagedExportFileTransactionError.storage(
                    "the staging file is not an empty regular file this operation exclusively owns")
            }

            let transaction = StagedExportFileTransaction(
                stagingDirectoryDescriptor: stagingDirectoryDescriptor,
                stagingDirectoryIdentity: stagingDirectoryIdentity,
                stagingName: stagingName,
                stagingDescriptor: stagingDescriptor,
                stagingIdentity: StagedExportFileIdentity(stagingInfo),
                rootDescriptor: rootDescriptor,
                rootIdentity: rootIdentity,
                directoryDescriptor: current,
                directoryIdentity: currentIdentity,
                directoryComponents: directoryComponents,
                destinationName: destinationName,
                publication: publication)
            // Single ownership handoff: from here the transaction alone closes
            // the staging directory, the staging file, the root and the leaf.
            transferred = true
            do {
                try transaction.verifyContainment()
                try transaction.verifyNameBinding()
            } catch {
                transaction.abort()
                throw error
            }
            return transaction
        } catch {
            if !transferred {
                if stagingDescriptor >= 0 { Darwin.close(stagingDescriptor) }
                if leafDescriptor >= 0 { Darwin.close(leafDescriptor) }
                Darwin.close(rootDescriptor)
                Darwin.close(stagingDirectoryDescriptor)
            }
            throw error
        }
    }

    // MARK: - Writing

    /// Appends to the staging descriptor. Because the write targets the
    /// descriptor inside a private directory, neither a rename of an ancestor
    /// nor a planted staging name can redirect these bytes.
    func append(_ data: Data) throws {
        guard !sealed else {
            throw StagedExportFileTransactionError.storage("the staged bytes are already sealed")
        }
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(stagingDescriptor, base.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw StagedExportFileTransactionError.storage(
                        "the staged write failed (errno \(errno))")
                }
                guard written > 0 else {
                    throw StagedExportFileTransactionError.storage("the staged write stalled")
                }
                offset += written
            }
        }
        bytesWritten += Int64(data.count)
    }

    var stagedBytes: Int64 { bytesWritten }

    /// Flushes the staged bytes to stable storage and proves the descriptor is
    /// still the same exclusively owned regular file holding exactly
    /// `expectedBytes`. A short or truncated staging file fails here, before any
    /// destination name exists, so a partial payload can never be published.
    ///
    /// This measures identity and LENGTH. It cannot see a writer that rewrote
    /// the staged inode's bytes without changing its length; that is what the
    /// post-publication content digest in `commit` is for.
    func seal(expectedBytes: Int64) throws {
        guard !sealed else {
            throw StagedExportFileTransactionError.storage("the staged bytes are already sealed")
        }
        guard bytesWritten == expectedBytes else {
            throw StagedExportFileTransactionError.storage(
                "staged \(bytesWritten) bytes instead of the \(expectedBytes) bytes to commit")
        }
        if fsync(stagingDescriptor) != 0, errno != EINVAL {
            throw StagedExportFileTransactionError.storage(
                "the staged bytes could not be flushed (errno \(errno))")
        }
        var info = stat()
        guard fstat(stagingDescriptor, &info) == 0, Self.isRegularFile(info) else {
            throw StagedExportFileTransactionError.storage("the staged file is no longer a regular file")
        }
        guard StagedExportFileIdentity(info) == stagingIdentity else {
            throw StagedExportFileTransactionError.stagedNameReplaced(
                "the staged file is no longer the inode this export wrote")
        }
        guard info.st_size == expectedBytes else {
            throw StagedExportFileTransactionError.storage(
                "the staged file holds \(info.st_size) bytes, not \(expectedBytes)")
        }
        guard info.st_nlink == 1 else {
            // Another name for the staging inode means somebody else can reach
            // it; publish only an inode this transaction alone owns by name.
            throw StagedExportFileTransactionError.stagedNameReplaced(
                "the staged file gained an unexpected additional name")
        }
        sealed = true
    }

    // MARK: - Publication

    /// Publishes the sealed staging inode into the anchored destination
    /// directory, verifies the committed inode's identity, length, mode and
    /// CONTENT, and re-verifies the anchor.
    ///
    /// `expectedSHA256` is the digest the caller verified for the payload (the
    /// digest the page declared for its own staged raster). It is recomputed
    /// from the committed inode through this transaction's own descriptor after
    /// publication, so a payload rewritten during the pull is reported as a
    /// failure instead of being delivered.
    ///
    /// A refused publication always retires this transaction's own private
    /// staging name and closes its descriptors. It never removes a destination
    /// name: once that name exists, the bytes are recoverable evidence and a
    /// competing writer could have substituted the name, so a failed
    /// verification reports honestly and leaves the file in place.
    ///
    /// The two preconditions below are the only refusals that leave the
    /// transaction usable, because nothing has been staged for publication yet.
    func commit(expectedSHA256: String) throws -> Commit {
        guard sealed else {
            throw StagedExportFileTransactionError.storage("the staged bytes were not sealed")
        }
        guard !descriptorsClosed else {
            throw StagedExportFileTransactionError.storage("the transaction is already finished")
        }
        do {
            return try performCommit(expectedBytes: bytesWritten, expectedSHA256: expectedSHA256)
        } catch {
            abort()
            throw error
        }
    }

    private func performCommit(expectedBytes: Int64, expectedSHA256: String) throws -> Commit {
        try verifyContainment()
        try verifyNameBinding()
        try verifyStagingNameStillOurs()

        // The deliverable carries the ordinary workspace file mode; staging
        // stayed private until this point.
        if fchmod(stagingDescriptor, Self.committedMode) != 0 {
            throw StagedExportFileTransactionError.storage(
                "the exported file's permissions could not be set (errno \(errno))")
        }

        // Honest early refusal for an occupied destination. The publication
        // syscall below is the authoritative exclusion; this only avoids a
        // pointless call and keeps the occupied cases distinguishable.
        var existing = stat()
        let occupied = withUnsafeMutablePointer(to: &existing) { info in
            destinationName.withCString { name in
                fstatat(directoryDescriptor, name, info, AT_SYMLINK_NOFOLLOW)
            }
        }
        if occupied == 0 {
            throw StagedExportFileTransactionError.destinationOccupied(Self.occupiedDescription(existing))
        }

        let publishedBy = try publish()

        // Post-publication verification: the name just created must refer to the
        // inode this transaction sealed, holding exactly the sealed length and
        // the deliverable mode.
        var committed = stat()
        let stated = withUnsafeMutablePointer(to: &committed) { info in
            destinationName.withCString { name in
                fstatat(directoryDescriptor, name, info, AT_SYMLINK_NOFOLLOW)
            }
        }
        guard stated == 0,
              Self.isRegularFile(committed),
              StagedExportFileIdentity(committed) == stagingIdentity,
              committed.st_size == expectedBytes,
              committed.st_nlink >= 1,
              committed.st_mode & UInt16(0o7777) == UInt16(Self.committedMode) else {
            // The destination name exists now, so it is never removed here: a
            // competing writer could have substituted it, and if it is ours the
            // bytes are recoverable evidence of a failed verification.
            throw StagedExportFileTransactionError.commitIdentityMismatch(
                "the published destination does not refer to the verified export bytes; it was left in place and not delivered")
        }

        // Content proof from the committed inode itself. The staging descriptor
        // and the destination name are the same inode after either publication
        // primitive, so this read is descriptor-relative and cannot be
        // redirected by a name change.
        let contentSHA256 = try recomputeContentSHA256(expectedBytes: expectedBytes)
        guard contentSHA256 == expectedSHA256.lowercased() else {
            throw StagedExportFileTransactionError.commitContentChanged(
                "the published file no longer holds the verified export bytes; it was left in place and not delivered")
        }

        // Persist the new directory entry before claiming delivery.
        if fsync(directoryDescriptor) != 0, errno != EINVAL {
            throw StagedExportFileTransactionError.storage(
                "the published directory entry could not be flushed (errno \(errno))")
        }

        // Re-prove the anchor after publication, so a directory renamed out of
        // the workspace — or replaced at the authorized path — during the commit
        // cannot be reported as a delivered export.
        do {
            try verifyContainment()
            try verifyNameBinding()
        } catch {
            throw StagedExportFileTransactionError.containmentLost(
                "the destination directory moved during the commit; the published file was left in place and not delivered")
        }

        // An exclusive rename already consumed the staging name; a hard link
        // leaves it to retire inside the private directory.
        let retired = stagingConsumed ? true : discardStagingName()
        if fsync(directoryDescriptor) != 0, errno != EINVAL {
            // The publication itself is durable and verified; a flush failure
            // after retirement is reported rather than turned into a lost export.
            throw StagedExportFileTransactionError.storage(
                "the retired staging entry could not be flushed (errno \(errno))")
        }
        closeDescriptors()
        return Commit(
            destinationIdentity: stagingIdentity,
            bytes: Int64(committed.st_size),
            contentSHA256: contentSHA256,
            publishedBy: publishedBy,
            stagingRetired: retired)
    }

    /// One atomic no-overwrite publication across the two descriptors.
    private func publish() throws -> StagedExportPublication {
        switch publication {
        case .exclusiveRename:
            let renamed = stagingName.withCString { source in
                destinationName.withCString { target in
                    renameatx_np(stagingDirectoryDescriptor, source,
                                 directoryDescriptor, target, UInt32(RENAME_EXCL))
                }
            }
            if renamed == 0 {
                stagingConsumed = true
                return .exclusiveRename
            }
            let code = errno
            switch code {
            case EEXIST:
                throw StagedExportFileTransactionError.destinationOccupied(
                    "a file appeared at the destination during the export")
            case EXDEV:
                throw StagedExportFileTransactionError.crossDevice(
                    "the private staging volume and the task workspace are different filesystems")
            case ENOTSUP, EINVAL, EPERM, ENOSYS:
                // The volume refuses the exclusive rename; fall back to the
                // POSIX hard-link publication, which has the same exclusion.
                break
            default:
                throw StagedExportFileTransactionError.storage(
                    "the export could not be published (errno \(code))")
            }
            return try publishByHardLink()
        case .hardLink:
            return try publishByHardLink()
        }
    }

    private func publishByHardLink() throws -> StagedExportPublication {
        let linked = stagingName.withCString { source in
            destinationName.withCString { target in
                linkat(stagingDirectoryDescriptor, source, directoryDescriptor, target, 0)
            }
        }
        guard linked == 0 else {
            let code = errno
            switch code {
            case EEXIST:
                throw StagedExportFileTransactionError.destinationOccupied(
                    "a file appeared at the destination during the export")
            case EXDEV:
                throw StagedExportFileTransactionError.crossDevice(
                    "the private staging volume and the task workspace are different filesystems")
            default:
                throw StagedExportFileTransactionError.storage(
                    "the export could not be published (errno \(code))")
            }
        }
        return .hardLink
    }

    /// Finishes the transaction: retires this transaction's private staging name
    /// if it still exists, never touches the destination name, and closes every
    /// descriptor. Idempotent, and safe after a failure, a fence, a cancellation
    /// or a successful publication.
    func abort() {
        discardStagingName()
        closeDescriptors()
    }

    // MARK: - Anchor proofs

    /// Walks `..` from the anchored directory back to the root identity. Every
    /// step is descriptor-relative, so a rename performed mid-walk cannot make
    /// an unrelated directory look contained.
    func verifyContainment() throws {
        guard !descriptorsClosed else {
            throw StagedExportFileTransactionError.storage("the transaction is already finished")
        }
        var walk = dup(directoryDescriptor)
        guard walk >= 0 else {
            throw StagedExportFileTransactionError.storage(
                "the destination directory could not be re-examined (errno \(errno))")
        }
        var previous: StagedExportFileIdentity?
        for _ in 0..<Self.maxAncestorSteps {
            var info = stat()
            guard fstat(walk, &info) == 0 else {
                let code = errno
                Darwin.close(walk)
                throw StagedExportFileTransactionError.storage(
                    "the destination directory could not be re-examined (errno \(code))")
            }
            let identity = StagedExportFileIdentity(info)
            if identity == rootIdentity {
                Darwin.close(walk)
                guard identityOfDirectory() == directoryIdentity else {
                    throw StagedExportFileTransactionError.containmentLost(
                        "the destination directory is no longer the anchored directory")
                }
                return
            }
            if identity == previous {
                // Reached the filesystem root without meeting the workspace root.
                Darwin.close(walk)
                throw StagedExportFileTransactionError.containmentLost(
                    "the destination directory is no longer inside the authorized workspace")
            }
            previous = identity
            let parent = openat(walk, "..", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, 0)
            guard parent >= 0 else {
                let code = errno
                Darwin.close(walk)
                throw StagedExportFileTransactionError.containmentLost(
                    "the destination directory's ancestry could not be proven (errno \(code))")
            }
            Darwin.close(walk)
            walk = parent
        }
        Darwin.close(walk)
        throw StagedExportFileTransactionError.containmentLost(
            "the destination directory's ancestry exceeds \(Self.maxAncestorSteps) levels")
    }

    /// Re-walks the authorized relative path from the root without following a
    /// symlink and requires it to arrive at the anchored directory inode. This
    /// is the name half of the anchor proof: containment alone would still allow
    /// a publication into a directory renamed away from the path the caller
    /// authorized.
    func verifyNameBinding() throws {
        guard !descriptorsClosed else {
            throw StagedExportFileTransactionError.storage("the transaction is already finished")
        }
        var current = dup(rootDescriptor)
        guard current >= 0 else {
            throw StagedExportFileTransactionError.storage(
                "the authorized workspace could not be re-examined (errno \(errno))")
        }
        do {
            for component in directoryComponents {
                let child = component.withCString { name in
                    openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, 0)
                }
                guard child >= 0 else {
                    let code = errno
                    let parent = current
                    if code == ENOENT {
                        throw StagedExportFileTransactionError.containmentLost(
                            "the authorized destination directory no longer exists")
                    }
                    throw StagedExportFileTransactionError.containmentLost(
                        Self.isSymbolicLink(parent, component)
                            ? "the authorized destination path now crosses a symbolic link"
                            : "the authorized destination path could not be re-walked (errno \(code))")
                }
                Darwin.close(current)
                current = child
            }
            var info = stat()
            guard fstat(current, &info) == 0 else {
                let code = errno
                throw StagedExportFileTransactionError.storage(
                    "the destination directory could not be re-examined (errno \(code))")
            }
            guard StagedExportFileIdentity(info) == directoryIdentity else {
                throw StagedExportFileTransactionError.containmentLost(
                    "the authorized destination path names a different directory than the anchored one")
            }
        } catch {
            Darwin.close(current)
            throw error
        }
        Darwin.close(current)
    }

    // MARK: - Internals

    /// Re-reads the staged inode through this transaction's own descriptor and
    /// returns its SHA-256. Bounded chunk buffer, no whole-file copy, and the
    /// length is re-checked at the end so growth during the read is a refusal.
    private func recomputeContentSHA256(expectedBytes: Int64) throws -> String {
        if lseek(stagingDescriptor, 0, SEEK_SET) == -1 {
            throw StagedExportFileTransactionError.storage(
                "the staged file could not be rewound for verification (errno \(errno))")
        }
        var digest = SHA256()
        var total: Int64 = 0
        let chunk = Self.verifyChunkBytes
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let count = Darwin.read(stagingDescriptor, buffer, chunk)
            if count < 0 {
                if errno == EINTR { continue }
                throw StagedExportFileTransactionError.storage(
                    "the staged file could not be read back for verification (errno \(errno))")
            }
            if count == 0 { break }
            total += Int64(count)
            guard total <= expectedBytes else {
                throw StagedExportFileTransactionError.storage(
                    "the staged file grew while it was being verified")
            }
            digest.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
        }
        guard total == expectedBytes else {
            throw StagedExportFileTransactionError.storage(
                "the staged file holds \(total) bytes, not \(expectedBytes)")
        }
        var info = stat()
        guard fstat(stagingDescriptor, &info) == 0,
              StagedExportFileIdentity(info) == stagingIdentity,
              info.st_size == expectedBytes else {
            throw StagedExportFileTransactionError.stagedNameReplaced(
                "the staged file changed while it was being verified")
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func identityOfDirectory() -> StagedExportFileIdentity? {
        var info = stat()
        guard fstat(directoryDescriptor, &info) == 0 else { return nil }
        return StagedExportFileIdentity(info)
    }

    private func verifyStagingNameStillOurs() throws {
        var info = stat()
        let stated = withUnsafeMutablePointer(to: &info) { pointer in
            stagingName.withCString { name in
                fstatat(stagingDirectoryDescriptor, name, pointer, AT_SYMLINK_NOFOLLOW)
            }
        }
        guard stated == 0 else {
            throw StagedExportFileTransactionError.stagedNameReplaced(
                "the staging file was removed before the commit")
        }
        // The name now belongs to somebody else: it is left alone and never
        // published.
        guard Self.isRegularFile(info), StagedExportFileIdentity(info) == stagingIdentity else {
            throw StagedExportFileTransactionError.stagedNameReplaced(
                "the staging name was replaced before the commit; a foreign file was not published")
        }
    }

    /// Retires the private staging name. Returns true when no staging name of
    /// this transaction is left behind.
    @discardableResult
    private func discardStagingName() -> Bool {
        guard !stagingDiscarded else { return true }
        stagingDiscarded = true
        guard !stagingConsumed else { return true }
        guard !descriptorsClosed else { return false }
        var info = stat()
        let stated = withUnsafeMutablePointer(to: &info) { pointer in
            stagingName.withCString { entry in
                fstatat(stagingDirectoryDescriptor, entry, pointer, AT_SYMLINK_NOFOLLOW)
            }
        }
        guard stated == 0 else {
            // Already gone: nothing of ours is left behind.
            return true
        }
        guard StagedExportFileIdentity(info) == stagingIdentity else {
            // Not our inode: leave it alone and report the leftover honestly.
            return false
        }
        return stagingName.withCString { entry in
            unlinkat(stagingDirectoryDescriptor, entry, 0)
        } == 0
    }

    private func closeDescriptors() {
        guard !descriptorsClosed else { return }
        descriptorsClosed = true
        Darwin.close(stagingDescriptor)
        if directoryDescriptor != rootDescriptor { Darwin.close(directoryDescriptor) }
        Darwin.close(rootDescriptor)
        Darwin.close(stagingDirectoryDescriptor)
    }

    /// True when one entry of an anchored directory is a symbolic link. Asked
    /// only after a nofollow open failed, so it can name the real cause without
    /// ever following the link.
    private static func isSymbolicLink(_ directory: Int32, _ name: String) -> Bool {
        var info = stat()
        let stated = withUnsafeMutablePointer(to: &info) { pointer in
            name.withCString { entry in fstatat(directory, entry, pointer, AT_SYMLINK_NOFOLLOW) }
        }
        guard stated == 0 else { return false }
        return (info.st_mode & UInt16(S_IFMT)) == UInt16(S_IFLNK)
    }

    private static func validate(component: String, role: String) throws {
        let bytes = component.utf8.count
        guard bytes > 0, bytes <= maxComponentBytes else {
            throw StagedExportFileTransactionError.anchorRefused(
                "the \(role) must be 1–\(maxComponentBytes) bytes")
        }
        guard component != ".", component != "..", !component.contains("/") else {
            throw StagedExportFileTransactionError.anchorRefused(
                "the \(role) must be a single directory component")
        }
        guard !component.contains("\0") else {
            throw StagedExportFileTransactionError.anchorRefused(
                "the \(role) must not contain a NUL byte")
        }
    }

    private static func isRegularFile(_ info: stat) -> Bool {
        (info.st_mode & UInt16(S_IFMT)) == UInt16(S_IFREG)
    }

    private static func isDirectory(_ info: stat) -> Bool {
        (info.st_mode & UInt16(S_IFMT)) == UInt16(S_IFDIR)
    }

    private static func occupiedDescription(_ info: stat) -> String {
        switch info.st_mode & UInt16(S_IFMT) {
        case UInt16(S_IFDIR): return "a directory already exists at the destination"
        case UInt16(S_IFLNK): return "a link already exists at the destination"
        default: return "a file already exists at the destination"
        }
    }
}
#endif
