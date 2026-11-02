// SPDX-License-Identifier: MPL-2.0
//
// C07 descriptor-safe streaming file I/O.
//
// The historical `copyVerified` trusted URL resource metadata and then opened
// `FileHandle(forReadingFrom:)` / `FileHandle(forWritingTo:)` by path. A
// symlink or ancestor-component swap between the metadata check and the open
// silently redirected the stream, and a digest/mtime check after the copy
// cannot establish which root the bytes actually came from.
//
// This helper closes that boundary for every C07 stream:
//
//   * BOTH the source and the destination are addressed relative to an
//     explicit, caller-fixed trusted ROOT. Root admission walks every
//     component from "/" with O_NOFOLLOW and holds the resulting directory
//     descriptor; the only normalization is a fixed table of OS-shipped
//     leading aliases (/var, /tmp, /etc -> /private/... on Darwin). No
//     arbitrary caller, model, archive or package component is resolved
//     through the filesystem into new authority.
//   * Every descendant is opened relative to that held descriptor with
//     openat(O_DIRECTORY | O_NOFOLLOW). A symlink at ANY level — root,
//     ancestor or leaf — is a typed refusal that touches nothing outside the
//     tree the descriptors already own. Renaming or replacing an ancestor
//     after admission cannot redirect the held descriptors.
//   * The source leaf is opened O_NOFOLLOW and validated with fstat
//     (regular file, bounded size, expected size) BEFORE the first read;
//     identity (st_dev/st_ino), size and mtime are re-checked on the same fd
//     AFTER the last read, so a file that changed mid-stream fails instead of
//     producing a mixed snapshot.
//   * The destination leaf is created O_EXCL | O_NOFOLLOW with an explicit
//     mode, written with bounded chunks, fsync'ed, and then verified through
//     fstatat on the opened parent to still name the exact opened inode.
//     A partial destination is removed only while the name still identifies
//     that inode, so a concurrent replacement is never deleted.
//   * Intermediate destination directories are created with mkdirat(2)
//     relative to the already-opened parent descriptor (never by joining an
//     absolute pathname), so a planted or swapped ancestor cannot make the
//     mkdir land outside the tree the descriptors already own.
//
// This is ownership of one app-managed tree at a time, not a new sandbox
// claim: the caller must pass a root it already owns (project root, artifact
// root, staging root). Bounds, cancellation and staged-failure cleanup match
// the existing C07 contract: a failed copy never leaves a destination file.
import Foundation
import Crypto
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif

public enum C07RootedFileIO {
    public static let maximumComponents = 128
    public static let maximumComponentBytes = 255

    /// One fixed, OS-shipped leading path alias. This is a NAME mapping, not
    /// a filesystem lookup: `/var` is replaced by `/private/var` before the
    /// walk even when the entry at `/var` is (or has become) a symlink. That
    /// keeps the legitimate Darwin aliases working without ever following a
    /// link or granting the link target new authority.
    private struct ProtectedRootAlias: Sendable {
        let name: String
        let replacement: [String]
    }

    #if canImport(Darwin)
    private static let protectedRootAliases: [ProtectedRootAlias] = [
        ProtectedRootAlias(name: "var", replacement: ["private", "var"]),
        ProtectedRootAlias(name: "tmp", replacement: ["private", "tmp"]),
        ProtectedRootAlias(name: "etc", replacement: ["private", "etc"]),
    ]
    #else
    private static let protectedRootAliases: [ProtectedRootAlias] = []
    #endif

    /// Canonical absolute path of an admitted trusted root. Components are
    /// validated and walked from "/" with O_NOFOLLOW; the only accepted
    /// normalization is the explicit OS-prefix aliases above. Throws when the
    /// root is absent, contains a symlink (including an ancestor), is not a
    /// directory, or is not an absolute path. No filesystem symlink is ever
    /// resolved into authority.
    public static func canonicalRootPath(_ url: URL) throws -> String {
        try RootHandle(url: url).canonicalPath
    }

    /// Validates one absolute caller root and applies only the explicit
    /// OS-prefix aliases above. Empty, duplicate, `.` and `..` components are
    /// refused instead of being normalized into a different directory.
    private static func rootComponents(_ url: URL) throws -> [String] {
        let raw = url.path
        guard !raw.isEmpty, !raw.contains("\0"), raw.hasPrefix("/") else {
            throw C07DataExchangeError.unsafePath(raw)
        }
        var parts = raw.split(
            separator: "/", omittingEmptySubsequences: false).map(String.init)
        // Exactly one leading empty component is the absolute-path marker;
        // one trailing empty component is an optional directory spelling.
        parts.removeFirst()
        if parts.last == "" { parts.removeLast() }
        for part in parts {
            guard !part.isEmpty, part != ".", part != "..",
                  part.utf8.count <= maximumComponentBytes,
                  part.unicodeScalars.allSatisfy({
                      $0.value > 0x1F && $0.value != 0x7F
                  }) else {
                throw C07DataExchangeError.unsafePath(raw)
            }
        }
        if let first = parts.first,
           let alias = protectedRootAliases.first(where: { $0.name == first }) {
            parts.replaceSubrange(0..<1, with: alias.replacement)
        }
        guard parts.count <= maximumComponents else {
            throw C07DataExchangeError.unsafePath(raw)
        }
        return parts
    }

    fileprivate final class RootHandle {
        let fd: Int32
        let device: dev_t
        let canonicalPath: String

        init(url: URL) throws {
            let path = try rootComponents(url)
            let opened = try RootHandle.openAdmitted(path)
            var info = stat()
            guard fstat(opened, &info) == 0,
                  (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                close(opened)
                throw C07DataExchangeError.storageUnavailable("rootNotDirectory")
            }
            fd = opened
            device = info.st_dev
            canonicalPath = path.isEmpty
                ? "/"
                : "/" + path.joined(separator: "/")
        }
        init(adopting opened: Int32, canonicalPath: String) throws {
            var info = stat()
            guard fstat(opened, &info) == 0,
                  (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                close(opened)
                throw C07DataExchangeError.storageUnavailable("rootNotDirectory")
            }
            fd = opened
            device = info.st_dev
            self.canonicalPath = canonicalPath
        }
        deinit { close(fd) }

        /// Opens the already-validated components one at a time from "/".
        /// Every open is O_NOFOLLOW and every descent uses the descriptor of
        /// the directory just verified, so an ancestor rename or replacement
        /// after admission cannot redirect the held root.
        fileprivate static func openAdmitted(_ path: [String], create: Bool = false) throws -> Int32 {
            let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            var current = "/".withCString { open($0, flags) }
            guard current >= 0 else {
                throw C07DataExchangeError.storageUnavailable(
                    "rootOpen:\(errno)")
            }
            for component in path {
                var next = component.withCString {
                    openat(current, $0, flags)
                }
                if next < 0, create, errno == ENOENT {
                    let result = component.withCString { mkdirat(current, $0, mode_t(0o700)) }
                    if result != 0 && errno != EEXIST {
                        let code = errno
                        close(current)
                        throw C07DataExchangeError.storageUnavailable("directoryCreate:\(code)")
                    }
                    next = component.withCString { openat(current, $0, flags) }
                }
                guard next >= 0 else {
                    let code = errno
                    var entry = stat()
                    let linkResult = component.withCString {
                        fstatat(current, $0, &entry, AT_SYMLINK_NOFOLLOW)
                    }
                    let isLink = linkResult == 0
                        && (entry.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK)
                    close(current)
                    if isLink || code == ELOOP {
                        throw C07DataExchangeError.symlinkUnsupported(component)
                    }
                    if code == ENOENT {
                        throw C07DataExchangeError.storageUnavailable(
                            "rootMissing")
                    }
                    throw C07DataExchangeError.storageUnavailable(
                        "rootOpen:\(code)")
                }
                var info = stat()
                guard fstat(next, &info) == 0,
                      (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                    close(next)
                    close(current)
                    throw C07DataExchangeError.storageUnavailable(
                        "rootNotDirectory")
                }
                close(current)
                current = next
            }
            return current
        }
    }

    /// A synchronous creation transaction over one held directory. Only flat
    /// files created by this transaction may be removed on failure. This
    /// object deliberately cannot be constructed from a model-supplied token.
    public final class CreatedDirectory {
        fileprivate let root: RootHandle
        fileprivate let parentFd: Int32
        fileprivate let leaf: String
        fileprivate let identity: stat
        private var created: [(String, stat)] = []
        fileprivate var finished = false

        fileprivate init(root: RootHandle, parentFd: Int32, leaf: String) throws {
            self.root = root
            self.parentFd = parentFd
            self.leaf = leaf
            var value = stat()
            guard fstat(root.fd, &value) == 0 else {
                close(parentFd)
                throw C07DataExchangeError.storageUnavailable("directoryStat")
            }
            identity = value
        }
        deinit { close(parentFd) }

        fileprivate func admit(_ path: [String], rootURL: URL) throws {
            let namedRoot = "/" + (try C07RootedFileIO.rootComponents(rootURL)).joined(separator: "/")
            guard !finished, path.count == 1, created.count < 4096,
                  namedRoot == root.canonicalPath else {
                throw C07DataExchangeError.storageUnavailable("directoryTransactionClosedOrFull")
            }
        }
        fileprivate func record(_ leaf: String, _ info: stat) { created.append((leaf, info)) }

        fileprivate func stillAttached() -> Bool {
            var current = stat()
            return leaf.withCString { fstatat(parentFd, $0, &current, AT_SYMLINK_NOFOLLOW) } == 0
                && current.st_dev == identity.st_dev && current.st_ino == identity.st_ino
                && (current.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
        }

        fileprivate func rollback() {
            // Operate on the held directory even if its original pathname was
            // replaced. Never recurse into unrecorded or substituted entries.
            for (name, expected) in created.reversed() {
                var current = stat()
                if name.withCString({ fstatat(root.fd, $0, &current, AT_SYMLINK_NOFOLLOW) }) == 0,
                   current.st_dev == expected.st_dev, current.st_ino == expected.st_ino,
                   (current.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) {
                    _ = name.withCString { unlinkat(root.fd, $0, 0) }
                }
            }
            if stillAttached() {
                _ = leaf.withCString { unlinkat(parentFd, $0, AT_REMOVEDIR) }
            }
        }
    }

    /// Creates the final directory exclusively through its held parent.
    /// Parent creation walks from / with the same no-follow alias policy as
    /// ordinary roots. No absolute mkdir or recursive pathname cleanup runs.
    public static func withExclusiveDirectory<T>(
        at url: URL, _ body: (CreatedDirectory) throws -> T
    ) throws -> T {
        let path = try rootComponents(url)
        guard let leaf = path.last else { throw C07DataExchangeError.unsafePath(url.path) }
        let parentFd = try RootHandle.openAdmitted(Array(path.dropLast()), create: true)
        guard leaf.withCString({ mkdirat(parentFd, $0, mode_t(0o700)) }) == 0 else {
            let code = errno
            close(parentFd)
            if code == EEXIST { throw C07DataExchangeError.artifactCollision("directoryExists") }
            throw C07DataExchangeError.storageUnavailable("directoryCreate:\(code)")
        }
        var createdIdentity = stat()
        guard leaf.withCString({ fstatat(parentFd, $0, &createdIdentity, AT_SYMLINK_NOFOLLOW) }) == 0,
              (createdIdentity.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            close(parentFd)
            throw C07DataExchangeError.storageUnavailable("directoryIdentity")
        }
        let opened = leaf.withCString {
            openat(parentFd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard opened >= 0 else {
            close(parentFd)
            throw C07DataExchangeError.storageUnavailable("directoryOpen")
        }
        let root: RootHandle
        do { root = try RootHandle(adopting: opened, canonicalPath: "/" + path.joined(separator: "/")) }
        catch { close(parentFd); throw error }
        let directory = try CreatedDirectory(root: root, parentFd: parentFd, leaf: leaf)
        defer { directory.finished = true }
        guard directory.identity.st_dev == createdIdentity.st_dev,
              directory.identity.st_ino == createdIdentity.st_ino else {
            // The opened replacement is not our created directory. Do not
            // enter rollback, even if the replacement happens to be empty.
            throw C07DataExchangeError.storageUnavailable("directoryReplaced")
        }
        do {
            let result = try body(directory)
            guard directory.stillAttached(), fsync(root.fd) == 0, fsync(parentFd) == 0 else {
                throw C07DataExchangeError.storageUnavailable("directoryReplacedOrUnsynced")
            }
            return result
        } catch {
            directory.rollback()
            throw error
        }
    }

    /// Validates one raw relative path and returns its components. Mirrors
    /// the C07 package-path rules (no absolute path, no `.`/`..`, no empty
    /// segment, no control characters) plus a component-count bound.
    private static func components(_ raw: String) throws -> [String] {
        let validated = try C07Path.validateRelative(raw)
        let parts = validated.split(
            separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.count <= maximumComponents else {
            throw C07DataExchangeError.unsafePath(raw)
        }
        for part in parts {
            guard !part.isEmpty, part != ".", part != "..",
                  part.utf8.count <= maximumComponentBytes,
                  part.unicodeScalars.allSatisfy({
                      $0.value > 0x1F && $0.value != 0x7F
                  }) else {
                throw C07DataExchangeError.unsafePath(raw)
            }
        }
        return parts
    }

    /// Descends `components.dropLast()` from `root` with no-follow opens.
    /// Existing directories must stay on the root device; a symlink or a
    /// non-directory at any level is a typed refusal. Missing owned
    /// directories are created with mkdirat(2) relative to the directory
    /// descriptor already opened for their parent — never through an
    /// absolute pathname, so a swapped ancestor cannot create anything
    /// outside the held tree. Returns the opened parent fd (caller closes it)
    /// and the leaf name.
    private static func openParent(
        root: RootHandle, path: [String], create: Bool
    ) throws -> (parentFd: Int32, leaf: String) {
        let leaf = path[path.count - 1]
        var current = dup(root.fd)
        guard current >= 0 else {
            throw C07DataExchangeError.storageUnavailable("dup:\(errno)")
        }
        let dirFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let directoryComponents = Array(path.dropLast())
        for component in directoryComponents {
            var next = component.withCString {
                openat(current, $0, dirFlags)
            }
            if next < 0, create, errno == ENOENT {
                let made = component.withCString {
                    mkdirat(current, $0, mode_t(0o700))
                }
                let createError = errno
                if made != 0 && createError != EEXIST {
                    close(current)
                    throw C07DataExchangeError.storageUnavailable(
                        "directoryCreate:\(createError)")
                }
                next = component.withCString {
                    openat(current, $0, dirFlags)
                }
            }
            guard next >= 0 else {
                let code = errno
                var entry = stat()
                let linkResult = component.withCString {
                    fstatat(current, $0, &entry, AT_SYMLINK_NOFOLLOW)
                }
                let isLink = linkResult == 0
                    && (entry.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK)
                close(current)
                if isLink || code == ELOOP {
                    throw C07DataExchangeError.symlinkUnsupported(component)
                }
                throw C07DataExchangeError.storageUnavailable(
                    "directoryOpen:\(code)")
            }
            var info = stat()
            guard fstat(next, &info) == 0,
                  (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
                  info.st_dev == root.device else {
                close(next)
                close(current)
                throw C07DataExchangeError.storageUnavailable(
                    "directoryUnsafe:\(component)")
            }
            close(current)
            current = next
        }
        return (current, leaf)
    }

    private static func fileMtimeNanoseconds(_ info: stat) -> Int64 {
        #if canImport(Darwin)
        return Int64(info.st_mtimespec.tv_sec) &* 1_000_000_000
            &+ Int64(info.st_mtimespec.tv_nsec)
        #else
        return Int64(info.st_mtim.tv_sec) &* 1_000_000_000
            &+ Int64(info.st_mtim.tv_nsec)
        #endif
    }

    private static func identityMatches(
        _ lhs: stat, _ rhs: stat, requireInode: Bool = true
    ) -> Bool {
        lhs.st_dev == rhs.st_dev
            && (!requireInode || lhs.st_ino == rhs.st_ino)
            && lhs.st_size == rhs.st_size
            && fileMtimeNanoseconds(lhs) == fileMtimeNanoseconds(rhs)
    }

    /// Streams one regular file from `sourceRoot/sourceRelativePath` to a new
    /// `destinationRoot/destinationRelativePath`. The destination must not
    /// already exist; intermediate destination directories are created owned
    /// (0700 leafward from the trusted root) when `createDestinationParents`
    /// is true. A failure removes only the exact destination inode this call
    /// created and never touches pre-existing user data. Each root is
    /// admitted and held once for the whole operation; its string form is
    /// never reopened.
    public static func copyFile(
        sourceRoot: URL,
        sourceRelativePath: String,
        destinationRoot: URL,
        destinationRelativePath: String,
        expectedSize: Int64? = nil,
        maximum: Int64 = C07DataExchangeLimits.maximumEntryBytes,
        mode: Int = 0o600,
        createDestinationParents: Bool = true,
        destinationDirectory: CreatedDirectory? = nil,
        shouldCancel: @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> (sha256: String, byteCount: Int64) {
        guard maximum >= 0 else { throw C07DataExchangeError.totalTooLarge }
        let sourcePath = try components(sourceRelativePath)
        let destinationPath = try components(destinationRelativePath)
        let source = try RootHandle(url: sourceRoot)
        try destinationDirectory?.admit(destinationPath, rootURL: destinationRoot)
        let destination = try destinationDirectory?.root ?? RootHandle(url: destinationRoot)

        // Source: no-follow leaf open + fstat regular-file/identity gate.
        let sourceParent = try openParent(
            root: source, path: sourcePath, create: false)
        defer { close(sourceParent.parentFd) }
        let sourceFd = sourceParent.leaf.withCString {
            openat(sourceParent.parentFd, $0,
                   O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard sourceFd >= 0 else {
            if errno == ELOOP {
                throw C07DataExchangeError.symlinkUnsupported(
                    sourceRelativePath)
            }
            throw C07DataExchangeError.storageUnavailable("sourceOpen:\(errno)")
        }
        var before = stat()
        guard fstat(sourceFd, &before) == 0 else {
            close(sourceFd)
            throw C07DataExchangeError.storageUnavailable("sourceStat")
        }
        guard (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            close(sourceFd)
            throw C07DataExchangeError.specialFileUnsupported(
                sourceRelativePath)
        }
        let sourceSize = Int64(before.st_size)
        if let expectedSize, sourceSize != expectedSize {
            close(sourceFd)
            throw C07DataExchangeError.sizeMismatch(sourceRelativePath)
        }
        guard sourceSize <= maximum else {
            close(sourceFd)
            throw C07DataExchangeError.entryTooLarge(sourceRelativePath)
        }

        // Destination: no-follow exclusive create under the opened root.
        let destinationParent = try openParent(
            root: destination, path: destinationPath,
            create: createDestinationParents)
        defer { close(destinationParent.parentFd) }
        let destinationFd = destinationParent.leaf.withCString {
            openat(destinationParent.parentFd, $0,
                   O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                   mode_t(0o600))
        }
        guard destinationFd >= 0 else {
            let code = errno
            throw destinationOpenFailure(
                parentFd: destinationParent.parentFd,
                leaf: destinationParent.leaf,
                relativePath: destinationRelativePath,
                code: code)
        }
        var opened = stat()
        guard fstat(destinationFd, &opened) == 0,
              (opened.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            close(destinationFd)
            throw C07DataExchangeError.storageUnavailable("destinationStat")
        }
        destinationDirectory?.record(destinationParent.leaf, opened)
        if fchmod(destinationFd, mode_t(mode & 0o777)) != 0 {
            let code = errno
            close(destinationFd)
            removeExactDestination(
                parentFd: destinationParent.parentFd,
                leaf: destinationParent.leaf,
                opened: opened)
            throw C07DataExchangeError.storageUnavailable("mode:\(code)")
        }

        var hasher = SHA256()
        var count: Int64 = 0
        var buffer = [UInt8](
            repeating: 0, count: C07DataExchangeLimits.copyChunkBytes)
        do {
            while true {
                if shouldCancel() {
                    try? close(sourceFd)
                    close(destinationFd)
                    removeExactDestination(
                        parentFd: destinationParent.parentFd,
                        leaf: destinationParent.leaf,
                        opened: opened)
                    throw C07DataExchangeError.cancelled
                }
                let chunk = buffer.withUnsafeMutableBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return read(sourceFd, base, raw.count)
                }
                if chunk < 0 {
                    if errno == EINTR { continue }
                    let code = errno
                    try? close(sourceFd)
                    close(destinationFd)
                    removeExactDestination(
                        parentFd: destinationParent.parentFd,
                        leaf: destinationParent.leaf,
                        opened: opened)
                    throw C07DataExchangeError.storageUnavailable(
                        "sourceRead:\(code)")
                }
                if chunk == 0 { break }
                count += Int64(chunk)
                guard count <= maximum else {
                    try? close(sourceFd)
                    close(destinationFd)
                    removeExactDestination(
                        parentFd: destinationParent.parentFd,
                        leaf: destinationParent.leaf,
                        opened: opened)
                    throw C07DataExchangeError.entryTooLarge(
                        sourceRelativePath)
                }
                hasher.update(data: Data(buffer[0..<chunk]))
                var written = 0
                while written < chunk {
                    let result = buffer[written..<chunk].withUnsafeBytes { raw -> Int in
                        guard let base = raw.baseAddress else { return -1 }
                        return write(destinationFd, base, raw.count)
                    }
                    if result < 0 {
                        if errno == EINTR { continue }
                        let code = errno
                        try? close(sourceFd)
                        close(destinationFd)
                        removeExactDestination(
                            parentFd: destinationParent.parentFd,
                            leaf: destinationParent.leaf,
                            opened: opened)
                        throw C07DataExchangeError.storageUnavailable(
                            "destinationWrite:\(code)")
                    }
                    written += result
                }
            }
            var after = stat()
            guard fstat(sourceFd, &after) == 0 else {
                try? close(sourceFd)
                close(destinationFd)
                removeExactDestination(
                    parentFd: destinationParent.parentFd,
                    leaf: destinationParent.leaf,
                    opened: opened)
                throw C07DataExchangeError.storageUnavailable("sourceStat")
            }
            try? close(sourceFd)
            guard identityMatches(before, after) else {
                close(destinationFd)
                removeExactDestination(
                    parentFd: destinationParent.parentFd,
                    leaf: destinationParent.leaf,
                    opened: opened)
                throw C07DataExchangeError.storageUnavailable("sourceChanged")
            }
            if fsync(destinationFd) != 0 {
                let code = errno
                close(destinationFd)
                removeExactDestination(
                    parentFd: destinationParent.parentFd,
                    leaf: destinationParent.leaf,
                    opened: opened)
                throw C07DataExchangeError.storageUnavailable("sync:\(code)")
            }
            close(destinationFd)
            // The NAME may have been replaced after the exclusive create;
            // only a name that still identifies our inode is our file.
            var current = stat()
            let statResult = destinationParent.leaf.withCString {
                fstatat(destinationParent.parentFd, $0, &current,
                        AT_SYMLINK_NOFOLLOW)
            }
            guard statResult == 0,
                  current.st_dev == opened.st_dev,
                  current.st_ino == opened.st_ino,
                  current.st_size == opened.st_size else {
                throw C07DataExchangeError.storageUnavailable(
                    "destinationReplaced")
            }
        }
        return (
            hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            count)
    }

    /// Writes one bounded in-memory payload to a new
    /// `destinationRoot/destinationRelativePath` with the same descriptor
    /// ownership as `copyFile`. Used for rewritten Canvas JSON and read-only
    /// recovery records; never overwrites.
    public static func writeFile(
        _ data: Data,
        destinationRoot: URL,
        destinationRelativePath: String,
        mode: Int = 0o600,
        expectedSHA256: String? = nil,
        createDestinationParents: Bool = true,
        destinationDirectory: CreatedDirectory? = nil
    ) throws -> (sha256: String, byteCount: Int64) {
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        if let expectedSHA256, expectedSHA256 != digest {
            throw C07DataExchangeError.hashMismatch(destinationRelativePath)
        }
        let destinationPath = try components(destinationRelativePath)
        try destinationDirectory?.admit(destinationPath, rootURL: destinationRoot)
        let destination = try destinationDirectory?.root ?? RootHandle(url: destinationRoot)
        let destinationParent = try openParent(
            root: destination, path: destinationPath,
            create: createDestinationParents)
        defer { close(destinationParent.parentFd) }
        let destinationFd = destinationParent.leaf.withCString {
            openat(destinationParent.parentFd, $0,
                   O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                   mode_t(0o600))
        }
        guard destinationFd >= 0 else {
            let code = errno
            throw destinationOpenFailure(
                parentFd: destinationParent.parentFd,
                leaf: destinationParent.leaf,
                relativePath: destinationRelativePath,
                code: code)
        }
        var opened = stat()
        guard fstat(destinationFd, &opened) == 0,
              (opened.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            close(destinationFd)
            throw C07DataExchangeError.storageUnavailable("destinationStat")
        }
        destinationDirectory?.record(destinationParent.leaf, opened)
        if fchmod(destinationFd, mode_t(mode & 0o777)) != 0 {
            let code = errno
            close(destinationFd)
            removeExactDestination(
                parentFd: destinationParent.parentFd,
                leaf: destinationParent.leaf,
                opened: opened)
            throw C07DataExchangeError.storageUnavailable("mode:\(code)")
        }
        do {
            try data.withUnsafeBytes { raw in
                var written = 0
                while written < raw.count {
                    let result = write(
                        destinationFd,
                        raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                            .advanced(by: written),
                        raw.count - written)
                    if result < 0 {
                        if errno == EINTR { continue }
                        throw C07DataExchangeError.storageUnavailable(
                            "destinationWrite:\(errno)")
                    }
                    written += result
                }
            }
            if fsync(destinationFd) != 0 {
                throw C07DataExchangeError.storageUnavailable("sync:\(errno)")
            }
        } catch let error as C07DataExchangeError {
            close(destinationFd)
            removeExactDestination(
                parentFd: destinationParent.parentFd,
                leaf: destinationParent.leaf,
                opened: opened)
            throw error
        } catch {
            close(destinationFd)
            removeExactDestination(
                parentFd: destinationParent.parentFd,
                leaf: destinationParent.leaf,
                opened: opened)
            throw C07DataExchangeError.storageUnavailable("write")
        }
        close(destinationFd)
        var current = stat()
        let statResult = destinationParent.leaf.withCString {
            fstatat(destinationParent.parentFd, $0, &current,
                    AT_SYMLINK_NOFOLLOW)
        }
        guard statResult == 0,
              current.st_dev == opened.st_dev,
              current.st_ino == opened.st_ino,
              current.st_size == opened.st_size else {
            throw C07DataExchangeError.storageUnavailable("destinationReplaced")
        }
        return (digest, Int64(data.count))
    }

    /// Classifies a failed exclusive destination open. `O_EXCL | O_NOFOLLOW`
    /// reports a symlink as `EEXIST` on some platforms and `ELOOP` on others;
    /// both are the same typed refusal, while a real pre-existing file stays
    /// `destinationExists`. Nothing is created or removed here.
    private static func destinationOpenFailure(
        parentFd: Int32, leaf: String, relativePath: String, code: Int32
    ) -> C07DataExchangeError {
        var entry = stat()
        let result = leaf.withCString {
            fstatat(parentFd, $0, &entry, AT_SYMLINK_NOFOLLOW)
        }
        let isLink = result == 0
            && (entry.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK)
        if code == ELOOP || isLink {
            return .symlinkUnsupported(relativePath)
        }
        if code == EEXIST {
            return .storageUnavailable("destinationExists")
        }
        return .storageUnavailable("destinationOpen:\(code)")
    }

    /// Removes the exact inode opened for `destinationFd` only while the
    /// directory entry still identifies that inode. A name that has already
    /// been replaced by another file is left untouched.
    private static func removeExactDestination(
        parentFd: Int32, leaf: String, opened: stat
    ) {
        var current = stat()
        let statResult = leaf.withCString {
            fstatat(parentFd, $0, &current, AT_SYMLINK_NOFOLLOW)
        }
        guard statResult == 0,
              current.st_dev == opened.st_dev,
              current.st_ino == opened.st_ino else { return }
        leaf.withCString { _ = unlinkat(parentFd, $0, 0) }
    }
}
