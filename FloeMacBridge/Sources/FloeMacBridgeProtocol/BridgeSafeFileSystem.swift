import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin

/// Descriptor-relative commit: a directory swapped for a symbolic link while
/// network IO is suspended can never redirect the final write outside root.
public enum BridgeSafeFileSystem {
    /// A held capability for one already-authorized directory. The initializer
    /// duplicates, rather than consumes, the caller's descriptor. It verifies
    /// file type, current-user ownership and private permissions, but it does
    /// not authenticate how the caller obtained the descriptor or prove the
    /// directory will retain any particular pathname.
    public final class Anchor: @unchecked Sendable {
        public enum CreateOutcome: Equatable, Sendable {
            case published
            /// The name became visible but syncing its directory failed; it
            /// must not be retried as if no publication occurred.
            case publishedUnconfirmed
            /// This invocation did not complete publication. The stage name
            /// is only a recovery hint: another writer may have replaced or
            /// removed the entry. Never delete it without revalidation.
            case notPublished(stagedName: String, errorCode: Int32)
        }

        public static let maximumCreateBytes = 4 * 1_024 * 1_024
        private let descriptor: Int32
        private let syncDirectory: @Sendable (Int32) -> Int32
        private let beforePublish: @Sendable (Int32, String) -> Void

        public convenience init(directoryFD: Int32) throws {
            try self.init(directoryFD: directoryFD, syncDirectory: { Darwin.fsync($0) })
        }

        // Narrow test seam for the post-publication durability failure.
        internal init(directoryFD: Int32, syncDirectory: @escaping @Sendable (Int32) -> Int32,
                      beforePublish: @escaping @Sendable (Int32, String) -> Void = { _, _ in }) throws {
            let duplicate = Darwin.fcntl(directoryFD, F_DUPFD_CLOEXEC, 0)
            guard duplicate >= 0 else { throw BridgeFailure.unsafePath }
            var info = stat()
            guard Darwin.fstat(duplicate, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == geteuid(), (info.st_mode & 0o077) == 0 else {
                Darwin.close(duplicate); throw BridgeFailure.unsafePath
            }
            self.descriptor = duplicate
            self.syncDirectory = syncDirectory
            self.beforePublish = beforePublish
        }

        deinit { Darwin.close(descriptor) }

        /// Reads one private regular file relative to the held directory. The
        /// metadata recheck detects ordinary replacement during the read; it
        /// does not prevent a later mutation or prove an atomic snapshot.
        public func readExisting(named name: String, maximumBytes: Int = maximumCreateBytes) throws -> Data {
            guard Self.validName(name), maximumBytes >= 0, maximumBytes <= Self.maximumCreateBytes else {
                throw BridgeFailure.unsafePath
            }
            try validateDirectory()
            let file = Darwin.openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard file >= 0 else { throw BridgeFailure.unsafePath }
            defer { Darwin.close(file) }
            var before = stat()
            guard Darwin.fstat(file, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
                  before.st_uid == geteuid(), before.st_nlink == 1, (before.st_mode & 0o077) == 0,
                  before.st_size >= 0, before.st_size <= Int64(maximumBytes) else { throw BridgeFailure.unsafePath }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            while true {
                let count = Darwin.read(file, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw BridgeFailure.unsafePath }
                if count == 0 { break }
                guard data.count <= maximumBytes - count else { throw BridgeFailure.unsafePath }
                data.append(contentsOf: buffer.prefix(count))
            }
            var after = stat(), named = stat()
            guard Darwin.fstat(file, &after) == 0,
                  Darwin.fstatat(descriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  after.st_dev == before.st_dev, after.st_ino == before.st_ino,
                  named.st_dev == before.st_dev, named.st_ino == before.st_ino,
                  after.st_mode & S_IFMT == S_IFREG, named.st_mode & S_IFMT == S_IFREG,
                  after.st_nlink == 1, named.st_nlink == 1, after.st_size == before.st_size,
                  named.st_size == after.st_size, after.st_uid == geteuid(), named.st_uid == geteuid(),
                  (after.st_mode & 0o077) == 0, (named.st_mode & 0o077) == 0,
                  after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
                  after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
                  after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
                  after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec,
                  named.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  named.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  named.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  named.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
                  Int64(data.count) == before.st_size else { throw BridgeFailure.unsafePath }
            try validateDirectory()
            return data
        }

        /// Publishes only a new basename; no path traversal or replacement.
        /// It does not provide cross-process locking, compare-and-swap, or
        /// authentication against a non-cooperating same-user writer.
        public func createNew(_ data: Data, named name: String) throws -> CreateOutcome {
            guard Self.validName(name), data.count <= Self.maximumCreateBytes else { throw BridgeFailure.unsafePath }
            try validateDirectory()
            let staged = ".floe-stage-" + UUID().uuidString
            let file = Darwin.openat(descriptor, staged, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard file >= 0 else { throw BridgeFailure.unsafePath }
            defer { Darwin.close(file) }
            var errorCode: Int32 = 0
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    guard let base = raw.baseAddress else { errorCode = EINVAL; break }
                    let count = Darwin.write(file, base.advanced(by: offset), raw.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { errorCode = count < 0 ? errno : EIO; break }
                    offset += count
                }
            }
            if errorCode != 0 { return .notPublished(stagedName: staged, errorCode: errorCode) }
            guard Darwin.fsync(file) == 0 else { return .notPublished(stagedName: staged, errorCode: errno) }
            beforePublish(descriptor, staged)
            guard entryMatchesOpenFile(named: staged, file: file, byteCount: data.count) else {
                return .notPublished(stagedName: staged, errorCode: ESTALE)
            }
            do { try validateDirectory() }
            catch { return .notPublished(stagedName: staged, errorCode: EACCES) }
            guard Darwin.renameatx_np(descriptor, staged, descriptor, name, UInt32(RENAME_EXCL)) == 0 else {
                return .notPublished(stagedName: staged, errorCode: errno)
            }
            guard syncDirectory(descriptor) == 0 else { return .publishedUnconfirmed }
            do { try validateDirectory() } catch { return .publishedUnconfirmed }
            guard entryMatchesOpenFile(named: name, file: file, byteCount: data.count) else {
                return .publishedUnconfirmed
            }
            return .published
        }

        // Detect observable replacement before/after rename. This is not an
        // atomic compare-and-rename and cannot exclude another same-user
        // writer between or after the checks.
        private func entryMatchesOpenFile(named name: String, file: Int32, byteCount: Int) -> Bool {
            var held = stat(), entry = stat()
            guard Darwin.fstat(file, &held) == 0,
                  Darwin.fstatat(descriptor, name, &entry, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
            return held.st_mode & S_IFMT == S_IFREG && entry.st_mode & S_IFMT == S_IFREG
                && held.st_uid == geteuid() && entry.st_uid == geteuid()
                && (held.st_mode & 0o077) == 0 && (entry.st_mode & 0o077) == 0
                && held.st_nlink == 1 && entry.st_nlink == 1
                && held.st_dev == entry.st_dev && held.st_ino == entry.st_ino
                && held.st_size == Int64(byteCount) && entry.st_size == held.st_size
        }

        private func validateDirectory() throws {
            var info = stat()
            guard Darwin.fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == geteuid(), (info.st_mode & 0o077) == 0 else { throw BridgeFailure.unsafePath }
        }

        private static func validName(_ name: String) -> Bool {
            !name.isEmpty && name != "." && name != ".." && !name.hasPrefix(".floe-stage-")
                && !name.contains("/") && !name.contains("\0") && name.utf8.count <= 255
        }
    }

    public static func commit(staged source: URL, relativePath: String, under root: URL, expectedSHA256: String?,
                              checkCancellation: () throws -> Void = {}) throws {
        try checkCancellation()
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relativePath.hasPrefix("/"), !relativePath.contains("\0"), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw BridgeFailure.unsafePath }
        var parent = try openRoot(root)
        guard parent >= 0 else { throw BridgeFailure.unsafePath }
        defer { Darwin.close(parent) }
        for component in parts.dropLast() {
            if Darwin.mkdirat(parent, component, 0o700) != 0, errno != EEXIST { throw BridgeFailure.unsafePath }
            let next = Darwin.openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw BridgeFailure.unsafePath }
            Darwin.close(parent); parent = next
        }
        guard let name = parts.last else { throw BridgeFailure.unsafePath }
        let mode = try checkExisting(name, parent: parent, expected: expectedSHA256, check: checkCancellation)
        let input = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw BridgeFailure.unsafePath }
        defer { Darwin.close(input) }
        var inputStat = stat()
        guard Darwin.fstat(input, &inputStat) == 0, inputStat.st_mode & S_IFMT == S_IFREG else { throw BridgeFailure.unsafePath }
        let temporary = ".floe-commit-" + UUID().uuidString
        let output = Darwin.openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard output >= 0 else { throw BridgeFailure.unsafePath }
        defer { Darwin.close(output); Darwin.unlinkat(parent, temporary, 0) }
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try checkCancellation()
            let count = Darwin.read(input, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw BridgeFailure.remote("Cannot read the transferred file.") }
            if count == 0 { break }
            try buffer.withUnsafeBytes { bytes in
                guard let address = bytes.baseAddress else { throw BridgeFailure.unsafePath }
                var offset = 0
                while offset < count {
                    let written = Darwin.write(output, address.advanced(by: offset), count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw BridgeFailure.remote("Cannot save the transferred file.") }
                    offset += written
                }
            }
        }
        guard Darwin.fsync(output) == 0 else { throw BridgeFailure.remote("Cannot save the transferred file.") }
        _ = try checkExisting(name, parent: parent, expected: expectedSHA256, check: checkCancellation)
        try checkCancellation()
        guard Darwin.renameat(parent, temporary, parent, name) == 0 else { throw BridgeFailure.remote("Cannot commit the transferred file.") }
        _ = Darwin.fsync(parent)
    }
    public static func moveToRecovery(relativePath: String, under root: URL, expectedSHA256: String,
                                      recoveryRoot: URL, checkCancellation: () throws -> Void = {}) throws {
        try checkCancellation()
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relativePath.hasPrefix("/"), !relativePath.contains("\0"), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw BridgeFailure.unsafePath }
        var parent = try openRoot(root)
        defer { Darwin.close(parent) }
        for component in parts.dropLast() {
            let next = Darwin.openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw BridgeFailure.unsafePath }
            Darwin.close(parent); parent = next
        }
        guard let name = parts.last else { throw BridgeFailure.unsafePath }
        _ = try checkExisting(name, parent: parent, expected: expectedSHA256, check: checkCancellation)
        let recovery = try openRoot(recoveryRoot)
        defer { Darwin.close(recovery) }
        try checkCancellation()
        guard Darwin.renameat(parent, name, recovery, name) == 0 else { throw BridgeFailure.remote("Cannot retain the removed file for recovery.") }
    }
    private static func openRoot(_ root: URL) throws -> Int32 {
        guard root.isFileURL, root.path.hasPrefix("/") else { throw BridgeFailure.unsafePath }
        // A sandbox grants access to the selected workspace, not directory
        // enumeration on every ancestor up to /. Open that capability first.
        // F_GETPATH verifies the opened directory itself: an ancestor swapped
        // for a link must not redirect this descriptor outside the frozen,
        // canonical root. Every path below it still uses openat/O_NOFOLLOW.
        let expected = root.standardizedFileURL.path
        let descriptor = Darwin.open(expected, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw BridgeFailure.unsafePath }
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard Darwin.fcntl(descriptor, F_GETPATH, &pathBuffer) != -1 else {
            Darwin.close(descriptor); throw BridgeFailure.unsafePath
        }
        let actual = URL(fileURLWithPath: String(cString: pathBuffer)).standardizedFileURL.path
        guard actual == expected else { Darwin.close(descriptor); throw BridgeFailure.unsafePath }
        return descriptor
    }
    private static func checkExisting(_ name: String, parent: Int32, expected: String?, check: () throws -> Void) throws -> mode_t {
        let descriptor = Darwin.openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            guard errno == ENOENT, expected == nil else { throw BridgeFailure.remote("The destination changed. Both copies were retained.") }
            return 0o600
        }
        defer { Darwin.close(descriptor) }
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0, details.st_mode & S_IFMT == S_IFREG else { throw BridgeFailure.unsafePath }
        guard let expected else { throw BridgeFailure.remote("The destination changed. Both copies were retained.") }
        let reader = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var digest = SHA256()
        while let chunk = try reader.read(upToCount: 256 * 1_024), !chunk.isEmpty { try check(); digest.update(data: chunk) }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == expected else {
            throw BridgeFailure.remote("The destination changed. Both copies were retained.")
        }
        return details.st_mode & 0o777
    }
}
#endif
