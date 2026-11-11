#if os(macOS)
import Foundation
import CryptoKit
import Darwin
import FloeMacBridgeProtocol

extension BridgeService {
    /// Read-only absolute-path access for the currently paired client. This
    /// never creates a transfer, writes a file or enters a command string.
    func readAbsoluteFile(_ payload: [String: BridgeValue]) async throws -> [String: BridgeValue] {
        guard let path = payload["path"]?.string, BridgeAbsoluteFileRead.validPath(path) else {
            throw BridgeFailure.unsafePath
        }
        let offset = payload["offset"]?.integer ?? 0
        let limitValue = payload["limit"]?.integer ?? Int64(BridgeWire.pageBytes)
        guard offset >= 0,
              limitValue > 0, limitValue <= Int64(BridgeAbsoluteFileRead.maximumChunkBytes) else {
            throw BridgeFailure.unsafePath
        }
        let expectedIdentity = payload["expectedIdentity"]?.string
        if let expectedIdentity, !BridgeAbsoluteFileRead.validDigest(expectedIdentity) {
            throw BridgeFailure.invalidResponse
        }
        return try BridgeAbsoluteFileReader.read(
            path: path,
            offset: offset,
            limit: Int(limitValue),
            expectedIdentity: expectedIdentity,
            verifySHA256: payload["sha256"]?.bool == true
        )
    }
}

/// One regular-file read over the authenticated bridge. Path resolution is
/// canonical component-by-component (ordinary `/tmp` links become
/// `/private/tmp`) and the final open uses `O_NOFOLLOW` plus `F_GETPATH`, so a
/// swapped path component or final symlink cannot redirect the read.
enum BridgeAbsoluteFileReader {
    static func read(
        path: String,
        offset: Int64,
        limit: Int,
        expectedIdentity: String?,
        verifySHA256: Bool
    ) throws -> [String: BridgeValue] {
        var resolved = try resolve(path)
        var intended = try regularFileStat(resolved)
        // O_NONBLOCK makes admission of a FIFO/device non-hanging before
        // `fstat` rejects it; it has no effect on ordinary regular files.
        var descriptor = Darwin.open(resolved, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0, errno == ELOOP {
            // An intermediate directory was swapped for a link between
            // canonicalization and open. Resolve and re-admit once; the
            // verified canonical path is still entirely a data path.
            resolved = try resolve(path)
            intended = try regularFileStat(resolved)
            descriptor = Darwin.open(resolved, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw failure("open") }
        defer { Darwin.close(descriptor) }

        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else { throw failure("inspect") }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw BridgeFailure.remote("Only regular files can be read from the Mac.")
        }
        // Path-spelling equality is wrong for legitimate Mac aliases: for
        // example `/Users/...` and `/System/Volumes/Data/Users/...` open the
        // same file, while F_GETPATH reports the `/Users` spelling for both.
        // Admit by the intended target's device/inode instead. A substituted
        // path must present a different inode and is rejected; the read's
        // version identity is captured from the opened descriptor below.
        guard intended.st_dev == info.st_dev, intended.st_ino == info.st_ino else {
            throw BridgeFailure.remote("The Mac file changed during the read. Read it again.")
        }
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard Darwin.fcntl(descriptor, F_GETPATH, &pathBuffer) != -1 else { throw failure("inspect") }
        let openedPath = URL(fileURLWithPath: cString(pathBuffer)).standardizedFileURL.path
        guard openedPath.hasPrefix("/") else { throw BridgeFailure.unsafeAbsolutePath }
        // Secret exclusion applies to the actual opened target and to the
        // canonical target spelling, not the caller's link name. An innocent
        // name resolving into ~/.ssh/.aws/.gnupg, key material, .env*/id_* or
        // .git/config is denied before any bytes are returned.
        guard !BridgeAbsoluteFileRead.isSecretPath(openedPath),
              !BridgeAbsoluteFileRead.isSecretPath(resolved) else {
            throw BridgeFailure.protectedSecretPath
        }

        let identity = identity(of: info)
        if let expectedIdentity, expectedIdentity != identity {
            throw BridgeFailure.remote("The Mac file changed during the read. Read it again.")
        }
        let size = Int64(info.st_size)
        guard offset <= size else {
            throw BridgeFailure.remote("The read offset is beyond the end of the Mac file.")
        }

        var digest: String?
        if verifySHA256 {
            guard size <= Int64(BridgeAbsoluteFileRead.maximumReceiptBytes) else {
                throw BridgeFailure.remote("This Mac file is too large for a whole-file receipt.")
            }
            digest = try wholeFileDigest(descriptor: descriptor, size: size)
            // A whole-file receipt is only meaningful when the same file
            // identity that supplied the requested chunk supplied the hash.
            var current = stat()
            guard Darwin.fstat(descriptor, &current) == 0,
                  Self.identity(of: current) == identity else {
                throw BridgeFailure.remote("The Mac file changed during the read. Read it again.")
            }
        }
        guard Darwin.lseek(descriptor, off_t(offset), SEEK_SET) >= 0 else { throw failure("read") }
        let data = try readExactly(descriptor: descriptor, maximum: limit)
        // The returned identity is only a receipt for these exact bytes.
        // Re-check after the read (not only after a whole-file hash); a
        // same-size rewrite with restored mtime still advances ctime.
        var afterRead = stat()
        guard Darwin.fstat(descriptor, &afterRead) == 0,
              Self.identity(of: afterRead) == identity else {
            throw BridgeFailure.remote("The Mac file changed during the read. Read it again.")
        }
        guard !data.isEmpty || offset == size else {
            throw BridgeFailure.remote("The Mac file changed during the read. Read it again.")
        }
        var result: [String: BridgeValue] = [
            "data": .string(data.base64EncodedString()),
            "offset": .integer(offset + Int64(data.count)),
            "totalBytes": .integer(size),
            "identity": .string(identity),
        ]
        if let digest { result["sha256"] = .string(digest) }
        return result
    }

    /// Canonical target of an absolute Mac path, resolving every symbolic
    /// link (bounded) and normalizing `.`/`..`. The final target must exist;
    /// `read` still verifies the opened descriptor is a regular file.
    static func resolve(_ path: String) throws -> String {
        guard BridgeAbsoluteFileRead.validPath(path) else { throw BridgeFailure.unsafePath }
        var pending = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var index = 0, links = 0
        var current = "/"
        while index < pending.count {
            let name = pending[index]
            index += 1
            if name == "." { continue }
            if name == ".." {
                current = (current as NSString).deletingLastPathComponent
                if current.isEmpty { current = "/" }
                continue
            }
            let next = current == "/" ? "/" + name : current + "/" + name
            var details = stat()
            if Darwin.lstat(next, &details) != 0 { throw failure("inspect") }
            if details.st_mode & S_IFMT == S_IFLNK {
                links += 1
                guard links <= 40 else {
                    throw BridgeFailure.remote("The Mac path contains too many symbolic links.")
                }
                var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                let count = Darwin.readlink(next, &buffer, buffer.count)
                // readlink does not NUL-terminate and returns the buffer size
                // on truncation. Decode exactly the returned bytes; never let
                // String(cString:) read past an unproven terminator.
                guard count > 0, count < buffer.count else {
                    throw BridgeFailure.remote("The Mac symbolic-link target is missing or too long.")
                }
                let bytes = buffer.withUnsafeBufferPointer { pointer -> [UInt8] in
                    guard let base = pointer.baseAddress else { return [] }
                    return Array(UnsafeRawBufferPointer(start: base, count: count))
                }
                guard let target = String(bytes: bytes, encoding: .utf8), !target.isEmpty else {
                    throw BridgeFailure.remote("The Mac symbolic-link target is not a valid path.")
                }
                let tail = Array(pending[index...])
                pending = target.split(separator: "/", omittingEmptySubsequences: true).map(String.init) + tail
                index = 0
                if target.hasPrefix("/") { current = "/" }
                continue
            }
            current = next
        }
        // Every component, including the final one, was lstat'ed above.
        // `read` re-admits the final target as a regular file and verifies it
        // against the opened descriptor.
        return current
    }

    private static func cString(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Admission identity for the intended canonical target. The caller must
    /// still match this device/inode against the opened descriptor: path
    /// spelling and F_GETPATH are not reliable identities on macOS firmlinks.
    private static func regularFileStat(_ path: String) throws -> stat {
        var value = stat()
        guard Darwin.lstat(path, &value) == 0 else { throw failure("inspect") }
        guard value.st_mode & S_IFMT == S_IFREG else {
            throw BridgeFailure.remote("Only regular files can be read from the Mac.")
        }
        return value
    }

    static func identity(of info: stat) -> String {
        BridgeAbsoluteFileRead.identity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
    }

    private static func wholeFileDigest(descriptor: Int32, size: Int64) throws -> String {
        guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else { throw failure("read") }
        var hasher = SHA256()
        var remaining = size
        var buffer = [UInt8](repeating: 0, count: 256 * 1_024)
        while remaining > 0 {
            let want = min(remaining, Int64(buffer.count))
            let count = Darwin.read(descriptor, &buffer, Int(want))
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw BridgeFailure.remote("The Mac file changed during the read. Read it again.") }
            hasher.update(data: Data(buffer[0..<count]))
            remaining -= Int64(count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func readExactly(descriptor: Int32, maximum: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(min(maximum, 64 * 1_024))
        var buffer = [UInt8](repeating: 0, count: min(maximum, 256 * 1_024))
        while data.count < maximum {
            let wanted = min(buffer.count, maximum - data.count)
            let count = Darwin.read(descriptor, &buffer, wanted)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw failure("read") }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    private static func failure(_ action: String) -> BridgeFailure {
        .remote("The Mac could not \(action) the requested file: \(String(cString: strerror(errno))).")
    }
}
#endif
