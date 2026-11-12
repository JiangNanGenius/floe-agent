// FloeCore — bounded POSIX primitives for the sparse disk rewrite.
//
// Everything here is relative to an already-open directory fd. Source and
// stage opens use O_NOFOLLOW and a final fstat regular-file check. No helper
// accepts an absolute path after admission, and no helper removes a path
// without an exact device/inode proof supplied by the caller.
//
// Memory is fixed-size: one read buffer (<= 4 MiB), one zero comparator
// (<= 1 MiB), and bounded xattr values (<= 1 MiB total). The implementation
// never loads the disk into Data and never uses FileHandle.read loops that
// accumulate autoreleased buffers.

#if canImport(Darwin)
import Foundation
import Darwin
import Crypto
#if canImport(CFloeSparseRewriteShim)
import CFloeSparseRewriteShim
#endif

struct StorageSparseDiskResolvedPath {
    let directoryFD: Int32
    let leaf: String
    /// True when `directoryFD` is a newly opened intermediate directory and
    /// the caller owns closing it. False means it is the caller's root fd.
    let ownsDirectory: Bool
}

enum StorageSparseDiskOpenPurpose {
    case source
    case stageCreate
    case stageOpen
}

struct StorageSparseDiskVolumeSpace: Sendable, Equatable {
    var availableBytes: Int64
    var totalBytes: Int64
}

struct StorageSparseDiskVolumeCapabilities: Sendable, Equatable {
    var cloning: Bool
    var sparse: Bool
    var zeroRuns: Bool
}

struct StorageSparseDiskCountingResult: Sendable, Equatable {
    var digestSHA512: String
    var nonzeroBytes: Int64
    var zeroBytes: Int64
    var lastNonzeroEnd: Int64
    var nonzeroBlocks: Int64
    var zeroBlocks: Int64
}

struct StorageSparseDiskPunchResult: Sendable, Equatable {
    var punchedBytes: Int64
    var unsupportedErrno: Int32?
}

struct StorageSparseDiskPathObservation: Sendable, Equatable {
    var exists: Bool
    var identity: StorageSparseDiskIdentity?
    var isSymlink: Bool
    var errorErrno: Int32?
}

struct StorageSparseDiskMetadataSnapshot: Sendable, Equatable {
    var mode: UInt32
    var ownerUID: UInt32
    var ownerGID: UInt32
    var fileFlags: UInt32
    var modificationSeconds: Int64
    var modificationNanoseconds: Int64
    var birthSeconds: Int64
    var birthNanoseconds: Int64
    var aclExternalRepresentation: Data
    var accessSeconds: Int64
    var accessNanoseconds: Int64
    var protectionClass: Int32?
    var xattrs: [String: Data]
    var skippedXattrNames: [String]
}

private struct StorageSparseDiskMetadataFingerprintPayload: Codable {
    var birthSeconds: Int64
    var birthNanoseconds: Int64
    var aclExternalRepresentation: String
    var mode: UInt32
    var ownerUID: UInt32
    var ownerGID: UInt32
    var fileFlags: UInt32
    var modificationSeconds: Int64
    var modificationNanoseconds: Int64
    var protectionClass: Int32?
    var xattrs: [String: String]
}

enum StorageSparseDiskPOSIX {
    static let metadataXattrTotalLimit = 1_048_576
    static let metadataXattrValueLimit = 262_144
    static let metadataXattrCountLimit = 64
    static let journalRecordLimit = 1_048_576

    /// Filesystem-managed xattrs that a normal process must not copy blindly
    /// onto a new inode. They are reported as skipped, never silently treated
    /// as preserved user metadata. File protection and backup exclusion do not
    /// live only in this list: protection is copied through F_SETPROTECTIONCLASS
    /// and backup exclusion is an ordinary user-copyable xattr on this platform.
    static let skippedSystemXattrNames: Set<String> = [
        "com.apple.provenance",
        "com.apple.rootless",
        "com.apple.system.Security",
        "com.apple.decmpfs",
        "com.apple.protectionclass"
    ]

    // MARK: - Names and admission

    static func validateJobID(_ jobID: String) throws {
        guard !jobID.isEmpty, jobID.utf8.count <= 64 else {
            throw StorageSparseDiskRewriteError.invalidRequest("job-id")
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard jobID.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw StorageSparseDiskRewriteError.invalidRequest("job-id")
        }
    }

    static func validateRelativePath(_ relativePath: String) throws -> [String] {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\0"),
              relativePath.utf8.count <= 1_024
        else {
            throw StorageSparseDiskRewriteError.invalidRequest("relative-path")
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 })
        else {
            throw StorageSparseDiskRewriteError.invalidRequest("relative-path")
        }
        return components
    }

    static func validateSingleName(_ name: String, field: String) throws {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\0"),
              name.utf8.count <= 255
        else {
            throw StorageSparseDiskRewriteError.invalidRequest(field)
        }
    }

    static func randomHexToken() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }

    static func makeStageName(sourceLeaf: String, jobID: String) throws -> String {
        let visible = String(sourceLeaf.prefix(40))
        let name = ".\(visible).sparse-\(jobID)-\(randomHexToken()).stage"
        try validateSingleName(name, field: "stage-name")
        guard name != sourceLeaf else {
            throw StorageSparseDiskRewriteError.invalidRequest("stage-name")
        }
        return name
    }

    // MARK: - Directory and file opens

    static func openDirectory(_ url: URL) throws -> Int32 {
        let fd = url.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else {
            throw StorageSparseDiskRewriteError.directoryOpenFailed(errno: errno)
        }
        return fd
    }

    static func openParent(rootFD: Int32, relativePath: String) throws -> StorageSparseDiskResolvedPath {
        let components = try validateRelativePath(relativePath)
        var current = rootFD
        var ownsCurrent = false
        do {
            for component in components.dropLast() {
                let next = component.withCString {
                    openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else {
                    let code = errno
                    if code == ELOOP || code == ENOTDIR {
                        throw StorageSparseDiskRewriteError.symbolicLink
                    }
                    throw StorageSparseDiskRewriteError.directoryOpenFailed(errno: code)
                }
                if ownsCurrent { _ = Darwin.close(current) }
                current = next
                ownsCurrent = true
            }
            guard let leaf = components.last else {
                throw StorageSparseDiskRewriteError.invalidRequest("relative-path")
            }
            return StorageSparseDiskResolvedPath(
                directoryFD: current,
                leaf: leaf,
                ownsDirectory: ownsCurrent
            )
        } catch {
            if ownsCurrent { _ = Darwin.close(current) }
            throw error
        }
    }

    static func openRegular(
        parentFD: Int32,
        leaf: String,
        flags: Int32,
        purpose: StorageSparseDiskOpenPurpose
    ) throws -> Int32 {
        try validateSingleName(leaf, field: "leaf")
        let fd = leaf.withCString {
            openat(parentFD, $0, flags | O_NOFOLLOW | O_CLOEXEC, mode_t(0))
        }
        guard fd >= 0 else {
            let code = errno
            switch purpose {
            case .source:
                if code == ELOOP { throw StorageSparseDiskRewriteError.symbolicLink }
                throw StorageSparseDiskRewriteError.sourceOpenFailed(errno: code)
            case .stageCreate:
                if code == EEXIST { throw StorageSparseDiskRewriteError.stageExists }
                throw StorageSparseDiskRewriteError.stageCreateFailed(errno: code)
            case .stageOpen:
                if code == ELOOP { throw StorageSparseDiskRewriteError.symbolicLink }
                throw StorageSparseDiskRewriteError.sourceOpenFailed(errno: code)
            }
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let code = errno
            _ = Darwin.close(fd)
            throw StorageSparseDiskRewriteError.readFailed(errno: code)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            _ = Darwin.close(fd)
            throw StorageSparseDiskRewriteError.notRegularFile
        }
        return fd
    }

    /// A clone inherits the source's POSIX mode. A read-only source therefore
    /// produces a read-only clone even though the stage is ours. Open it
    /// read-only and make only that job-owned stage writable before reopening;
    /// the source inode is never chmodded. The source mode is applied back to
    /// the stage before commit.
    static func openStageForRewrite(parentFD: Int32, name: String) throws -> Int32 {
        do {
            return try openRegular(
                parentFD: parentFD,
                leaf: name,
                flags: O_RDWR,
                purpose: .stageOpen
            )
        } catch StorageSparseDiskRewriteError.sourceOpenFailed(let code)
            where code == EACCES || code == EPERM {
            let readOnlyFD = try openRegular(
                parentFD: parentFD,
                leaf: name,
                flags: O_RDONLY,
                purpose: .stageOpen
            )
            guard fchmod(readOnlyFD, mode_t(0o600)) == 0 else {
                let failure = errno
                _ = Darwin.close(readOnlyFD)
                throw StorageSparseDiskRewriteError.metadataFailed(
                    field: "stage-mode",
                    errno: failure
                )
            }
            _ = Darwin.close(readOnlyFD)
            return try openRegular(
                parentFD: parentFD,
                leaf: name,
                flags: O_RDWR,
                purpose: .stageOpen
            )
        }
    }

    static func createStage(
        parentFD: Int32,
        name: String,
        mode: mode_t = mode_t(0o600)
    ) throws -> Int32 {
        let fd = name.withCString {
            openat(
                parentFD,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode
            )
        }
        guard fd >= 0 else {
            let code = errno
            if code == EEXIST { throw StorageSparseDiskRewriteError.stageExists }
            throw StorageSparseDiskRewriteError.stageCreateFailed(errno: code)
        }
        return fd
    }

    static func observe(parentFD: Int32, name: String) -> StorageSparseDiskPathObservation {
        var info = stat()
        let result = name.withCString {
            fstatat(parentFD, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            let code = errno
            if code == ENOENT {
                return StorageSparseDiskPathObservation(
                    exists: false,
                    identity: nil,
                    isSymlink: false,
                    errorErrno: nil
                )
            }
            return StorageSparseDiskPathObservation(
                exists: false,
                identity: nil,
                isSymlink: false,
                errorErrno: code
            )
        }
        if (info.st_mode & S_IFMT) == S_IFLNK {
            return StorageSparseDiskPathObservation(
                exists: true,
                identity: nil,
                isSymlink: true,
                errorErrno: nil
            )
        }
        return StorageSparseDiskPathObservation(
            exists: true,
            identity: identity(from: info),
            isSymlink: false,
            errorErrno: nil
        )
    }

    // MARK: - stat / space

    static func identity(of fd: Int32) throws -> StorageSparseDiskIdentity {
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw StorageSparseDiskRewriteError.readFailed(errno: errno)
        }
        return identity(from: info)
    }

    static func identity(from info: stat) -> StorageSparseDiskIdentity {
        StorageSparseDiskIdentity(
            device: UInt64(UInt32(bitPattern: info.st_dev)),
            inode: UInt64(info.st_ino),
            sizeBytes: Int64(info.st_size),
            linkCount: UInt32(info.st_nlink),
            mode: UInt32(info.st_mode),
            ownerUID: UInt32(info.st_uid),
            ownerGID: UInt32(info.st_gid),
            fileFlags: UInt32(info.st_flags),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changeSeconds: Int64(info.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
    }

    static func validateSourceShape(_ identity: StorageSparseDiskIdentity) throws {
        guard (identity.mode & UInt32(S_IFMT)) == UInt32(S_IFREG) else {
            throw StorageSparseDiskRewriteError.notRegularFile
        }
        guard identity.linkCount == 1 else {
            throw StorageSparseDiskRewriteError.hardLinked(linkCount: identity.linkCount)
        }
        guard identity.sizeBytes > 0 else {
            throw StorageSparseDiskRewriteError.emptySource
        }
        guard identity.sizeBytes <= StorageSparseDiskRewrite.maximumSourceBytes else {
            throw StorageSparseDiskRewriteError.oversizedSource(
                bytes: identity.sizeBytes,
                limit: StorageSparseDiskRewrite.maximumSourceBytes
            )
        }
        let blockedFlags = UInt32(UF_IMMUTABLE)
            | UInt32(SF_IMMUTABLE)
            | UInt32(UF_APPEND)
            | UInt32(SF_APPEND)
        guard identity.fileFlags & blockedFlags == 0 else {
            throw StorageSparseDiskRewriteError.immutableSource
        }
        guard identity.fileFlags & UInt32(UF_COMPRESSED) == 0 else {
            throw StorageSparseDiskRewriteError.compressedSource
        }
    }

    static func requireExpectedIdentity(
        _ actual: StorageSparseDiskIdentity,
        expected: StorageSparseDiskIdentity,
        phase: String
    ) throws {
        guard actual.matchesFully(expected) else {
            throw StorageSparseDiskRewriteError.sourceIdentityMismatch(phase: phase)
        }
    }

    static func requireSourceUnchanged(
        fd: Int32,
        expected: StorageSparseDiskIdentity,
        phase: String
    ) throws {
        let actual = try identity(of: fd)
        guard actual.matchesFully(expected) else {
            throw StorageSparseDiskRewriteError.sourceChanged(phase: phase)
        }
    }

    static func requireStageUnchanged(
        fd: Int32,
        expected: StorageSparseDiskIdentity,
        phase: String
    ) throws {
        let actual = try identity(of: fd)
        guard actual.matchesFully(expected) else {
            throw StorageSparseDiskRewriteError.stageIdentityMismatch(phase: phase)
        }
    }

    /// Inode-level check for a stage whose mtime/size legitimately changed
    /// during staging or hole punching. Only a proven job-owned inode may be
    /// cleaned up; the source inode is different and is never matched here.
    static func requireStageInodeUnchanged(
        fd: Int32,
        expected: StorageSparseDiskIdentity,
        phase: String
    ) throws {
        let actual = try identity(of: fd)
        guard actual.matchesInode(expected) else {
            throw StorageSparseDiskRewriteError.stageIdentityMismatch(phase: phase)
        }
    }

    static func validateStageInitial(
        _ stage: StorageSparseDiskIdentity,
        source: StorageSparseDiskIdentity
    ) throws {
        guard (stage.mode & UInt32(S_IFMT)) == UInt32(S_IFREG) else {
            throw StorageSparseDiskRewriteError.notRegularFile
        }
        guard stage.linkCount == 1 else {
            throw StorageSparseDiskRewriteError.hardLinked(linkCount: stage.linkCount)
        }
        guard stage.device == source.device else {
            throw StorageSparseDiskRewriteError.invalidRequest("stage-volume")
        }
    }

    static func allocatedBytes(of fd: Int32) throws -> Int64 {
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw StorageSparseDiskRewriteError.readFailed(errno: errno)
        }
        let blocks = Int64(info.st_blocks)
        guard blocks >= 0 else { return 0 }
        let (bytes, overflow) = blocks.multipliedReportingOverflow(by: 512)
        return overflow ? Int64.max : bytes
    }

    static func volumeSpace(
        directoryFD: Int32,
        availableOverride: (@Sendable (Int32) -> Int64?)? = nil
    ) throws -> StorageSparseDiskVolumeSpace {
        var filesystem = statfs()
        guard fstatfs(directoryFD, &filesystem) == 0 else {
            throw StorageSparseDiskRewriteError.readFailed(errno: errno)
        }
        let blockSize = max(Int64(1), Int64(filesystem.f_bsize))
        let available: Int64
        if let fake = availableOverride?(directoryFD) {
            available = max(0, fake)
        } else {
            let blocks = min(filesystem.f_bavail, UInt64(Int64.max / blockSize))
            available = Int64(blocks) * blockSize
        }
        let totalBlocks = min(filesystem.f_blocks, UInt64(Int64.max / blockSize))
        let total = Int64(totalBlocks) * blockSize
        return StorageSparseDiskVolumeSpace(availableBytes: available, totalBytes: total)
    }

    static func volumeCapabilities(
        rootURL: URL,
        relativePath: String
    ) -> StorageSparseDiskVolumeCapabilities {
        let parentURL: URL
        if let slash = relativePath.lastIndex(of: "/") {
            let relativeParent = String(relativePath[..<slash])
            parentURL = rootURL.appendingPathComponent(relativeParent, isDirectory: true)
        } else {
            parentURL = rootURL
        }
        do {
            let values = try parentURL.resourceValues(forKeys: [
                .volumeSupportsFileCloningKey,
                .volumeSupportsSparseFilesKey,
                .volumeSupportsZeroRunsKey,
            ])
            return StorageSparseDiskVolumeCapabilities(
                cloning: values.volumeSupportsFileCloning ?? false,
                sparse: values.volumeSupportsSparseFiles ?? false,
                zeroRuns: values.volumeSupportsZeroRuns ?? false
            )
        } catch {
            return StorageSparseDiskVolumeCapabilities(cloning: false, sparse: false, zeroRuns: false)
        }
    }

    static func physicalBlockSize(directoryFD: Int32) -> Int64 {
        var filesystem = statfs()
        guard fstatfs(directoryFD, &filesystem) == 0 else { return 4_096 }
        return max(4_096, min(65_536, Int64(filesystem.f_bsize)))
    }

    static func preflightSpace(
        directoryFD: Int32,
        requiredBytes: Int64,
        hooksOverride: (@Sendable (Int32) -> Int64?)?,
        phase: String
    ) throws {
        let available = try volumeSpace(directoryFD: directoryFD, availableOverride: hooksOverride).availableBytes
        guard requiredBytes >= 0, available >= requiredBytes else {
            throw StorageSparseDiskRewriteError.insufficientSpace(
                required: requiredBytes,
                available: available,
                phase: phase
            )
        }
    }

    // MARK: - Bounded reads/writes

    static func readAll(fd: Int32, maxBytes: Int) throws -> Data {
        guard maxBytes > 0 else { return Data() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(65_536, maxBytes))
        while true {
            let count: Int = buffer.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return -1 }
                return read(fd, base, raw.count)
            }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                throw StorageSparseDiskRewriteError.readFailed(errno: code)
            }
            if count == 0 { return data }
            data.append(contentsOf: buffer[0..<count])
            guard data.count <= maxBytes else {
                throw StorageSparseDiskRewriteError.invalidRequest("read-limit")
            }
        }
    }

    /// Fill exactly `count` bytes at `offset` unless EOF is reached first.
    /// Returns the number of bytes read (0...count); EOF is reported as a
    /// short result, never as success.
    static func readChunk(
        fd: Int32,
        buffer: UnsafeMutableRawPointer,
        count: Int,
        offset: Int64
    ) throws -> Int {
        guard count > 0 else { return 0 }
        var total = 0
        while total < count {
            let result = pread(
                fd,
                buffer.advanced(by: total),
                count - total,
                off_t(offset) + off_t(total)
            )
            if result < 0 {
                let code = errno
                if code == EINTR { continue }
                throw StorageSparseDiskRewriteError.readFailed(errno: code)
            }
            if result == 0 { break }
            total += result
        }
        return total
    }

    static func writeAll(
        fd: Int32,
        data: Data
    ) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            try writeAll(fd: fd, buffer: base, count: raw.count)
        }
    }

    static func writeAll(
        fd: Int32,
        buffer: UnsafeRawPointer,
        count: Int
    ) throws {
        guard count > 0 else { return }
        var written = 0
        while written < count {
            let result = write(fd, buffer.advanced(by: written), count - written)
            if result < 0 {
                let code = errno
                if code == EINTR { continue }
                throw StorageSparseDiskRewriteError.writeFailed(errno: code)
            }
            if result == 0 {
                throw StorageSparseDiskRewriteError.writeFailed(errno: EIO)
            }
            written += result
        }
    }

    static func writeAll(
        fd: Int32,
        buffer: UnsafeRawPointer,
        count: Int,
        offset: Int64,
        directoryFD: Int32,
        hooksOverride: (@Sendable (Int32) -> Int64?)?,
        phase: String
    ) throws {
        guard count > 0 else { return }
        var written = 0
        while written < count {
            let result = pwrite(
                fd,
                buffer.advanced(by: written),
                count - written,
                off_t(offset) + off_t(written)
            )
            if result < 0 {
                let code = errno
                if code == EINTR { continue }
                if code == ENOSPC || code == EDQUOT {
                    let available = (try? volumeSpace(directoryFD: directoryFD, availableOverride: hooksOverride))?.availableBytes ?? 0
                    throw StorageSparseDiskRewriteError.insufficientSpace(
                        required: Int64(count - written),
                        available: available,
                        phase: phase
                    )
                }
                throw StorageSparseDiskRewriteError.writeFailed(errno: code)
            }
            if result == 0 {
                throw StorageSparseDiskRewriteError.writeFailed(errno: EIO)
            }
            written += result
        }
    }

    static func truncate(fd: Int32, size: Int64) throws {
        guard ftruncate(fd, off_t(size)) == 0 else {
            throw StorageSparseDiskRewriteError.truncateFailed(errno: errno)
        }
    }

    static func fsyncFD(_ fd: Int32) throws {
        while fsync(fd) != 0 {
            let code = errno
            if code == EINTR { continue }
            throw StorageSparseDiskRewriteError.fsyncFailed(errno: code)
        }
    }

    static func fsyncDirectory(_ fd: Int32) throws {
        while fsync(fd) != 0 {
            let code = errno
            if code == EINTR { continue }
            throw StorageSparseDiskRewriteError.fsyncFailed(errno: code)
        }
    }

    // MARK: - Counting and hashing

    static func countSource(
        fd: Int32,
        size: Int64,
        chunkBytes: Int,
        probeBytes: Int,
        isCancelled: @escaping @Sendable () -> Bool,
        progress: (@Sendable (StorageSparseDiskRewriteProgress) -> Void)?
    ) throws -> StorageSparseDiskCountingResult {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkBytes, alignment: 4_096)
        defer { buffer.deallocate() }
        let zero = UnsafeMutableRawPointer.allocate(byteCount: probeBytes, alignment: 4_096)
        defer { zero.deallocate() }
        memset(zero, 0, probeBytes)

        var hasher = SHA512()
        var offset: Int64 = 0
        var nonzeroBytes: Int64 = 0
        var zeroBytes: Int64 = 0
        var lastNonzeroEnd: Int64 = 0
        var nonzeroBlocks: Int64 = 0
        var zeroBlocks: Int64 = 0
        var lastReported: Int64 = -1

        while offset < size {
            if isCancelled() { throw CancellationError() }
            let want = Int(min(Int64(chunkBytes), size - offset))
            let got = try readChunk(fd: fd, buffer: buffer, count: want, offset: offset)
            guard got > 0 else {
                throw StorageSparseDiskRewriteError.sourceChanged(phase: "counting-eof")
            }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: UnsafeRawPointer(buffer), count: got))
            var blockOffset = 0
            while blockOffset < got {
                let blockLength = min(probeBytes, got - blockOffset)
                let pointer = buffer.advanced(by: blockOffset)
                let isZero = memcmp(UnsafeRawPointer(pointer), UnsafeRawPointer(zero), blockLength) == 0
                if isZero {
                    zeroBlocks += 1
                    zeroBytes += Int64(blockLength)
                } else {
                    nonzeroBlocks += 1
                    nonzeroBytes += Int64(blockLength)
                    lastNonzeroEnd = offset + Int64(blockOffset + blockLength)
                }
                blockOffset += blockLength
            }
            offset += Int64(got)
            if let progress, offset - lastReported >= 16 * 1_024 * 1_024 || offset == size {
                progress(StorageSparseDiskRewriteProgress(
                    phase: .counting,
                    processedBytes: offset,
                    totalBytes: size
                ))
                lastReported = offset
            }
        }
        guard offset == size else {
            throw StorageSparseDiskRewriteError.sourceChanged(phase: "counting-length")
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return StorageSparseDiskCountingResult(
            digestSHA512: digest,
            nonzeroBytes: nonzeroBytes,
            zeroBytes: zeroBytes,
            lastNonzeroEnd: lastNonzeroEnd,
            nonzeroBlocks: nonzeroBlocks,
            zeroBlocks: zeroBlocks
        )
    }

    static func sha512(
        fd: Int32,
        size: Int64,
        chunkBytes: Int,
        phase: StorageSparseDiskRewriteProgress.Phase,
        isSource: Bool,
        isCancelled: @escaping @Sendable () -> Bool,
        progress: (@Sendable (StorageSparseDiskRewriteProgress) -> Void)?
    ) throws -> String {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkBytes, alignment: 4_096)
        defer { buffer.deallocate() }
        var hasher = SHA512()
        var offset: Int64 = 0
        var lastReported: Int64 = -1
        while offset < size {
            if isCancelled() { throw CancellationError() }
            let want = Int(min(Int64(chunkBytes), size - offset))
            let got = try readChunk(fd: fd, buffer: buffer, count: want, offset: offset)
            guard got > 0 else {
                if isSource {
                    throw StorageSparseDiskRewriteError.sourceChanged(phase: phase.rawValue)
                }
                throw StorageSparseDiskRewriteError.verificationFailed(phase: phase.rawValue)
            }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: UnsafeRawPointer(buffer), count: got))
            offset += Int64(got)
            if let progress, offset - lastReported >= 16 * 1_024 * 1_024 || offset == size {
                progress(StorageSparseDiskRewriteProgress(
                    phase: phase,
                    processedBytes: offset,
                    totalBytes: size
                ))
                lastReported = offset
            }
        }
        guard offset == size else {
            if isSource {
                throw StorageSparseDiskRewriteError.sourceChanged(phase: phase.rawValue)
            }
            throw StorageSparseDiskRewriteError.verificationFailed(phase: phase.rawValue)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Sparse write / punch

    static func writeSparseStage(
        sourceFD: Int32,
        stageFD: Int32,
        size: Int64,
        chunkBytes: Int,
        probeBytes: Int,
        counting: StorageSparseDiskCountingResult,
        directoryFD: Int32,
        safetyMarginBytes: Int64,
        hooks: StorageSparseDiskRewrite.TestHooks,
        isCancelled: @escaping @Sendable () -> Bool,
        progress: (@Sendable (StorageSparseDiskRewriteProgress) -> Void)?
    ) throws -> Int64 {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkBytes, alignment: 4_096)
        defer { buffer.deallocate() }
        let zero = UnsafeMutableRawPointer.allocate(byteCount: probeBytes, alignment: 4_096)
        defer { zero.deallocate() }
        memset(zero, 0, probeBytes)

        var offset: Int64 = 0
        var written: Int64 = 0
        var lastSpaceCheck: Int64 = 0
        var lastReported: Int64 = -1
        while offset < size {
            if isCancelled() { throw CancellationError() }
            let want = Int(min(Int64(chunkBytes), size - offset))
            let got = try readChunk(fd: sourceFD, buffer: buffer, count: want, offset: offset)
            guard got > 0 else {
                throw StorageSparseDiskRewriteError.sourceChanged(phase: "staging-eof")
            }
            if written - lastSpaceCheck >= 16 * 1_024 * 1_024 {
                let remaining = max(0, counting.nonzeroBytes - written)
                let required = remaining + safetyMarginBytes
                try preflightSpace(
                    directoryFD: directoryFD,
                    requiredBytes: required,
                    hooksOverride: hooks.availableBytesOverride,
                    phase: "staging-recheck"
                )
                lastSpaceCheck = written
            }
            var blockOffset = 0
            while blockOffset < got {
                let blockLength = min(probeBytes, got - blockOffset)
                let pointer = buffer.advanced(by: blockOffset)
                if memcmp(UnsafeRawPointer(pointer), UnsafeRawPointer(zero), blockLength) != 0 {
                    try hooks.beforeWrite?(offset + Int64(blockOffset), blockLength)
                    try writeAll(
                        fd: stageFD,
                        buffer: UnsafeRawPointer(pointer),
                        count: blockLength,
                        offset: offset + Int64(blockOffset),
                        directoryFD: directoryFD,
                        hooksOverride: hooks.availableBytesOverride,
                        phase: "staging-write"
                    )
                    written += Int64(blockLength)
                }
                blockOffset += blockLength
            }
            offset += Int64(got)
            if let progress, offset - lastReported >= 16 * 1_024 * 1_024 || offset == size {
                progress(StorageSparseDiskRewriteProgress(
                    phase: .staging,
                    processedBytes: offset,
                    totalBytes: size
                ))
                lastReported = offset
            }
        }
        try truncate(fd: stageFD, size: size)
        return written
    }

    static func punchZeroRuns(
        sourceFD: Int32,
        stageFD: Int32,
        size: Int64,
        chunkBytes: Int,
        probeBytes: Int,
        directoryFD: Int32,
        hooks: StorageSparseDiskRewrite.TestHooks,
        isCancelled: @escaping @Sendable () -> Bool,
        progress: (@Sendable (StorageSparseDiskRewriteProgress) -> Void)?
    ) throws -> StorageSparseDiskPunchResult {
        if hooks.forcePunchUnsupported {
            return StorageSparseDiskPunchResult(punchedBytes: 0, unsupportedErrno: ENOTSUP)
        }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkBytes, alignment: 4_096)
        defer { buffer.deallocate() }
        let zero = UnsafeMutableRawPointer.allocate(byteCount: probeBytes, alignment: 4_096)
        defer { zero.deallocate() }
        memset(zero, 0, probeBytes)
        let alignment = physicalBlockSize(directoryFD: directoryFD)
        var offset: Int64 = 0
        var runStart: Int64?
        var runEnd: Int64 = 0
        var punched: Int64 = 0
        var lastReported: Int64 = -1

        func flushRun() throws -> Int32? {
            guard let start = runStart else { return nil }
            runStart = nil
            let alignedStart = alignUp(start, alignment: alignment)
            let alignedEnd = alignDown(runEnd, alignment: alignment)
            guard alignedEnd > alignedStart else { return nil }
            let length = alignedEnd - alignedStart
            try hooks.beforePunch?(alignedStart, length)
            let result = punchHole(fd: stageFD, offset: alignedStart, length: length)
            guard result == 0 else {
                let code = errno
                if code == EINTR { return code }
                return code
            }
            punched += length
            return 0
        }

        while offset < size {
            if isCancelled() { throw CancellationError() }
            let want = Int(min(Int64(chunkBytes), size - offset))
            let got = try readChunk(fd: sourceFD, buffer: buffer, count: want, offset: offset)
            guard got > 0 else {
                throw StorageSparseDiskRewriteError.sourceChanged(phase: "punch-eof")
            }
            var blockOffset = 0
            while blockOffset < got {
                let blockLength = min(probeBytes, got - blockOffset)
                let pointer = buffer.advanced(by: blockOffset)
                let isZero = memcmp(UnsafeRawPointer(pointer), UnsafeRawPointer(zero), blockLength) == 0
                let blockStart = offset + Int64(blockOffset)
                let blockEnd = blockStart + Int64(blockLength)
                if isZero {
                    if runStart == nil { runStart = blockStart }
                    runEnd = blockEnd
                } else if runStart != nil {
                    let flushCode = try flushRun()
                    if let code = flushCode, code != 0 {
                        if code == ENOTSUP || code == EOPNOTSUPP || code == EINVAL {
                            return StorageSparseDiskPunchResult(punchedBytes: punched, unsupportedErrno: code)
                        }
                        throw StorageSparseDiskRewriteError.punchFailed(errno: code)
                    }
                }
                blockOffset += blockLength
            }
            offset += Int64(got)
            if let progress, offset - lastReported >= 16 * 1_024 * 1_024 || offset == size {
                progress(StorageSparseDiskRewriteProgress(
                    phase: .staging,
                    processedBytes: offset,
                    totalBytes: size
                ))
                lastReported = offset
            }
        }
        let flushCode = try flushRun()
        if let code = flushCode, code != 0 {
            if code == ENOTSUP || code == EOPNOTSUPP || code == EINVAL {
                return StorageSparseDiskPunchResult(punchedBytes: punched, unsupportedErrno: code)
            }
            throw StorageSparseDiskRewriteError.punchFailed(errno: code)
        }
        try fsyncFD(stageFD)
        return StorageSparseDiskPunchResult(punchedBytes: punched, unsupportedErrno: nil)
    }

    /// One public F_PUNCHHOLE call through the tiny C target. The C shim is
    /// used only because Swift's imported variadic `fcntl` cannot express the
    /// `fpunchhole_t *` argument reliably across SDK/toolchain revisions. When
    /// the target is not linked, punch is reported unsupported and the
    /// clone-only rewrite fails closed without replacing the original.
    static func punchHole(fd: Int32, offset: Int64, length: Int64) -> Int32 {
        #if canImport(CFloeSparseRewriteShim)
        while true {
            let result = floe_sparse_punch_hole(fd, off_t(offset), off_t(length))
            if result == 0 { return 0 }
            let code = errno
            if code == EINTR { continue }
            return -1
        }
        #else
        errno = ENOTSUP
        return -1
        #endif
    }

    static func alignUp(_ value: Int64, alignment: Int64) -> Int64 {
        guard alignment > 0 else { return value }
        let remainder = value % alignment
        return remainder == 0 ? value : value + (alignment - remainder)
    }

    static func alignDown(_ value: Int64, alignment: Int64) -> Int64 {
        guard alignment > 0 else { return value }
        return value - (value % alignment)
    }

    // MARK: - Clone / swap / unlink

    static func cloneFile(sourceFD: Int32, directoryFD: Int32, name: String) -> Int32 {
        name.withCString {
            fclonefileat(sourceFD, directoryFD, $0, 0)
        }
    }

    static func renameSwap(
        directoryFD: Int32,
        firstName: String,
        secondName: String
    ) -> Int32 {
        firstName.withCString { first in
            secondName.withCString { second in
                renameatx_np(directoryFD, first, directoryFD, second, UInt32(RENAME_SWAP))
            }
        }
    }

    static func unlinkName(directoryFD: Int32, name: String) -> Int32 {
        name.withCString { unlinkat(directoryFD, $0, 0) }
    }

    // MARK: - Metadata

    // Clone-only metadata contract. ACL and birthtime are captured and hashed;
    // unreadable ACLs and unknown required iOS protection fail before staging.
    // atime follows normal read semantics and is deliberately not fingerprinted.
    static func captureMetadata(
        fd: Int32,
        metadataReadFault: (@Sendable (String) throws -> Void)? = nil
    ) throws -> StorageSparseDiskMetadataSnapshot {
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw StorageSparseDiskRewriteError.metadataFailed(field: "stat", errno: errno)
        }
        try metadataReadFault?("protection-class")
        let protection = try readProtectionClass(fd: fd)
        #if os(iOS)
        _ = try requireKnownProtectionClass(protection)
        #endif
        try metadataReadFault?("acl")
        let acl = try readACLSnapshot(fd: fd)
        let (xattrs, skipped) = try readXattrs(fd: fd)
        return StorageSparseDiskMetadataSnapshot(
            mode: UInt32(info.st_mode),
            ownerUID: UInt32(info.st_uid),
            ownerGID: UInt32(info.st_gid),
            fileFlags: UInt32(info.st_flags),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            birthSeconds: Int64(info.st_birthtimespec.tv_sec),
            birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec),
            aclExternalRepresentation: acl,
            accessSeconds: Int64(info.st_atimespec.tv_sec),
            accessNanoseconds: Int64(info.st_atimespec.tv_nsec),
            protectionClass: protection,
            xattrs: xattrs,
            skippedXattrNames: skipped
        )
    }

    static func requireKnownProtectionClass(_ value: Int32?) throws -> Int32 {
        guard let value, value > 0 else {
            throw StorageSparseDiskRewriteError.metadataUnavailable(field: "protection-class")
        }
        return value
    }

    static func readACLSnapshot(fd: Int32) throws -> Data {
        #if canImport(CFloeSparseRewriteShim)
        let limit = 65_536
        var bytes = [UInt8](repeating: 0, count: limit)
        var used: Int = 0
        let result: Int32 = bytes.withUnsafeMutableBytes { raw in
            floe_sparse_acl_snapshot(fd, raw.baseAddress, raw.count, &used)
        }
        guard result == 0 else {
            throw StorageSparseDiskRewriteError.metadataFailed(field: "acl", errno: errno)
        }
        guard used >= 0, used <= limit else {
            throw StorageSparseDiskRewriteError.metadataUnavailable(field: "acl-size")
        }
        return Data(bytes.prefix(used))
        #else
        throw StorageSparseDiskRewriteError.metadataUnavailable(field: "acl-capability")
        #endif
    }

    static func readProtectionClass(fd: Int32) throws -> Int32? {
        let value = fcntl(fd, F_GETPROTECTIONCLASS, 0)
        if value < 0 {
            let code = errno
            if code == ENOTSUP || code == EOPNOTSUPP || code == ENOENT
                || code == ENOATTR || code == EINVAL {
                return nil
            }
            throw StorageSparseDiskRewriteError.metadataFailed(field: "protection-class", errno: code)
        }
        return value == 0 ? nil : value
    }

    static func setProtectionClass(fd: Int32, value: Int32) throws {
        let result = fcntl(fd, F_SETPROTECTIONCLASS, value)
        guard result == 0 else {
            throw StorageSparseDiskRewriteError.metadataFailed(
                field: "protection-class",
                errno: errno
            )
        }
    }

    static func readXattrs(fd: Int32) throws -> ([String: Data], [String]) {
        let listSize = flistxattr(fd, nil, 0, 0)
        if listSize < 0 {
            let code = errno
            if code == ENOENT || code == ENOATTR { return ([:], []) }
            if code == ENOTSUP || code == EOPNOTSUPP {
                throw StorageSparseDiskRewriteError.metadataUnavailable(field: "xattr-capability")
            }
            throw StorageSparseDiskRewriteError.metadataFailed(field: "xattr-list", errno: code)
        }
        guard listSize <= metadataXattrTotalLimit else {
            throw StorageSparseDiskRewriteError.xattrLimitExceeded("list")
        }
        if listSize == 0 { return ([:], []) }
        var names = [CChar](repeating: 0, count: Int(listSize))
        let readSize: Int = names.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return -1 }
            return flistxattr(fd, base, buffer.count, 0)
        }
        guard readSize >= 0 else {
            throw StorageSparseDiskRewriteError.metadataFailed(field: "xattr-list", errno: errno)
        }
        guard readSize <= Int(listSize) else {
            throw StorageSparseDiskRewriteError.xattrLimitExceeded("list-read")
        }
        var xattrs: [String: Data] = [:]
        var skipped: [String] = []
        var totalValueBytes = 0
        var index = 0
        while index < readSize {
            let start = index
            while index < readSize && names[index] != 0 { index += 1 }
            guard index < readSize else {
                throw StorageSparseDiskRewriteError.metadataFailed(field: "xattr-name", errno: EINVAL)
            }
            let nameBytes = Array(names[start..<index]) + [0]
            let name = String(
                decoding: nameBytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            index += 1
            guard !name.isEmpty else { continue }
            if skippedSystemXattrNames.contains(name) {
                skipped.append(name)
                continue
            }
            let valueSize: Int = name.withCString {
                fgetxattr(fd, $0, nil, 0, 0, 0)
            }
            if valueSize < 0 {
                throw StorageSparseDiskRewriteError.metadataFailed(field: "xattr-size", errno: errno)
            }
            guard valueSize <= metadataXattrValueLimit,
                  xattrs.count < metadataXattrCountLimit,
                  totalValueBytes + Int(valueSize) <= metadataXattrTotalLimit
            else {
                throw StorageSparseDiskRewriteError.xattrLimitExceeded("value")
            }
            if valueSize == 0 {
                xattrs[name] = Data()
                continue
            }
            var value = [UInt8](repeating: 0, count: Int(valueSize))
            let actual: Int = name.withCString { namePointer in
                value.withUnsafeMutableBytes { raw in
                    guard let base = raw.baseAddress else { return -1 }
                    return fgetxattr(fd, namePointer, base, raw.count, 0, 0)
                }
            }
            guard actual == Int(valueSize) else {
                throw StorageSparseDiskRewriteError.metadataFailed(field: "xattr-value", errno: errno)
            }
            let data = Data(value)
            xattrs[name] = data
            totalValueBytes += data.count
        }
        return (xattrs, skipped.sorted())
    }

    static func applyMetadata(
        sourceFD: Int32,
        stageFD: Int32,
        snapshot: StorageSparseDiskMetadataSnapshot
    ) throws {
        var stageInfo = stat()
        guard fstat(stageFD, &stageInfo) == 0 else {
            throw StorageSparseDiskRewriteError.metadataFailed(field: "stage-stat", errno: errno)
        }
        if UInt32(stageInfo.st_uid) != snapshot.ownerUID
            || UInt32(stageInfo.st_gid) != snapshot.ownerGID {
            guard fchown(stageFD, uid_t(snapshot.ownerUID), gid_t(snapshot.ownerGID)) == 0 else {
                throw StorageSparseDiskRewriteError.metadataFailed(field: "owner", errno: errno)
            }
        }
        for name in snapshot.xattrs.keys.sorted() {
            guard let value = snapshot.xattrs[name] else { continue }
            let result: Int32 = name.withCString { namePointer in
                value.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else {
                        return fsetxattr(stageFD, namePointer, nil, 0, 0, 0)
                    }
                    return fsetxattr(stageFD, namePointer, base, raw.count, 0, 0)
                }
            }
            guard result == 0 else {
                throw StorageSparseDiskRewriteError.metadataFailed(field: "xattr", errno: errno)
            }
        }
        if let protection = snapshot.protectionClass {
            try setProtectionClass(fd: stageFD, value: protection)
        }
        if snapshot.fileFlags != 0 {
            guard fchflags(stageFD, snapshot.fileFlags) == 0 else {
                throw StorageSparseDiskRewriteError.metadataFailed(field: "flags", errno: errno)
            }
        }
        var times = [
            timespec(
                tv_sec: time_t(snapshot.accessSeconds),
                tv_nsec: Int(snapshot.accessNanoseconds)
            ),
            timespec(
                tv_sec: time_t(snapshot.modificationSeconds),
                tv_nsec: Int(snapshot.modificationNanoseconds)
            ),
        ]
        let timeResult: Int32 = times.withUnsafeBufferPointer { buffer in
            futimens(stageFD, buffer.baseAddress)
        }
        guard timeResult == 0 else {
            throw StorageSparseDiskRewriteError.metadataFailed(field: "times", errno: errno)
        }
        // A clone may receive a fresh birthtime on some native versions.
        // Change only the job-owned stage, then the full snapshot is read back.
        var finalTimes = stat()
        guard fstat(stageFD, &finalTimes) == 0 else {
            throw StorageSparseDiskRewriteError.metadataFailed(field: "birthtime-stat", errno: errno)
        }
        if Int64(finalTimes.st_birthtimespec.tv_sec) != snapshot.birthSeconds
            || Int64(finalTimes.st_birthtimespec.tv_nsec) != snapshot.birthNanoseconds {
            #if canImport(CFloeSparseRewriteShim)
            guard floe_sparse_set_birthtime(
                stageFD, snapshot.birthSeconds, snapshot.birthNanoseconds
            ) == 0 else {
                throw StorageSparseDiskRewriteError.metadataFailed(field: "birthtime", errno: errno)
            }
            #else
            throw StorageSparseDiskRewriteError.metadataUnavailable(field: "birthtime-capability")
            #endif
        }
        // Apply the exact POSIX mode last: xattr/timestamp operations above
        // must not run against a stage that has just become read-only.
        guard fchmod(stageFD, mode_t(snapshot.mode & 0o7777)) == 0 else {
            throw StorageSparseDiskRewriteError.metadataFailed(field: "mode", errno: errno)
        }
        _ = sourceFD
    }

    static func metadataFingerprint(_ snapshot: StorageSparseDiskMetadataSnapshot) throws -> String {
        let payload = StorageSparseDiskMetadataFingerprintPayload(
            birthSeconds: snapshot.birthSeconds,
            birthNanoseconds: snapshot.birthNanoseconds,
            aclExternalRepresentation: snapshot.aclExternalRepresentation.base64EncodedString(),
            mode: snapshot.mode,
            ownerUID: snapshot.ownerUID,
            ownerGID: snapshot.ownerGID,
            fileFlags: snapshot.fileFlags,
            modificationSeconds: snapshot.modificationSeconds,
            modificationNanoseconds: snapshot.modificationNanoseconds,
            protectionClass: snapshot.protectionClass,
            xattrs: snapshot.xattrs.mapValues { $0.base64EncodedString() }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        let digest = SHA512.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

#endif
