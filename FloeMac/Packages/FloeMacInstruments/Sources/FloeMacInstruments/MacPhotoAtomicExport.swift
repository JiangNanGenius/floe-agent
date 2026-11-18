import Darwin
import Foundation
import FloeToolboxCore

enum MacPhotoExportOutcome: Equatable, Sendable {
    case committed
    case committedDurabilityUncertain
    case committedUnverified
}

/// Cancelling and beginning the commit are serialized. Once the commit starts,
/// the operation reports its real outcome even if its caller is cancelled.
final class MacPhotoExportControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var committing = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws {
        try Task.checkCancellation()
        guard !lock.withLock({ cancelled }) else { throw CancellationError() }
    }
    func beginCommit() throws {
        try Task.checkCancellation()
        try lock.withLock {
            guard !cancelled, !committing else { throw CancellationError() }
            committing = true
        }
    }
}

/// tmpfile supplies an already-unlinked file. It is verified before any
/// image bytes are written and is destroyed automatically when closed.
enum MacPhotoAtomicExport {
    static func write(_ data: Data, to url: URL, control: MacPhotoExportControl = MacPhotoExportControl(),
                      beforeCommit: (@Sendable (URL) throws -> Void)? = nil,
                      clone: @Sendable (Int32, Int32, String) -> Int32 = { fclonefileat($0, $1, $2, 0) },
                      syncDirectory: @Sendable (Int32) -> Bool = { fsync($0) == 0 }) throws -> MacPhotoExportOutcome {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try control.check()
        guard url.isFileURL, !url.lastPathComponent.isEmpty,
              url.lastPathComponent != ".", url.lastPathComponent != "..",
              data.count <= MacPhotoDecoder.maximumExportBytes else { throw ToolboxError.invalid("export destination") }
        let parent = url.deletingLastPathComponent()
        var pathInfo = stat()
        guard lstat(parent.path, &pathInfo) == 0,
              (pathInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { throw ToolboxError.invalid("export directory") }
        let parentFD = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw posixError() }
        defer { _ = Darwin.close(parentFD) }
        var openedParent = stat(), existing = stat()
        guard fstat(parentFD, &openedParent) == 0, sameObject(pathInfo, openedParent) else { throw ToolboxError.invalid("export directory changed") }
        guard fstatat(parentFD, url.lastPathComponent, &existing, AT_SYMLINK_NOFOLLOW) != 0,
              errno == ENOENT else { throw ToolboxError.denied }
        guard let stream = tmpfile() else { throw posixError() }
        defer { fclose(stream) }
        let fileFD = fileno(stream)
        var staged = stat()
        guard fileFD >= 0, fstat(fileFD, &staged) == 0,
              (staged.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), staged.st_nlink == 0,
              staged.st_uid == geteuid(), (staged.st_mode & 0o777) == 0o600,
              staged.st_dev == openedParent.st_dev else {
            throw ToolboxError.invalid("anonymous temporary file unavailable on destination volume")
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try control.check()
                let written = Darwin.write(fileFD, bytes.baseAddress!.advanced(by: offset), min(65_536, bytes.count - offset))
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw posixError() }
                offset += written
            }
        }
        try control.check()
        guard fsync(fileFD) == 0 else { throw posixError() }
        guard fileMatches(fileFD, data: data), parentMatches(parent.path, expected: openedParent) else {
            throw ToolboxError.invalid("export staging changed")
        }
        try beforeCommit?(parent)
        try control.check()
        guard fileMatches(fileFD, data: data), parentMatches(parent.path, expected: openedParent) else {
            throw ToolboxError.invalid("export directory changed")
        }
        try control.beginCommit()
        guard clone(fileFD, parentFD, url.lastPathComponent) == 0 else { throw posixError() }
        // The target may now exist even if verification or fsync fails.
        let targetFD = openat(parentFD, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard targetFD >= 0 else { return .committedUnverified }
        defer { _ = Darwin.close(targetFD) }
        var target = stat(), namedTarget = stat()
        guard fstat(targetFD, &target) == 0,
              (target.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              fstatat(parentFD, url.lastPathComponent, &namedTarget, AT_SYMLINK_NOFOLLOW) == 0,
              sameObject(target, namedTarget), fileMatches(targetFD, data: data),
              parentMatches(parent.path, expected: openedParent) else { return .committedUnverified }
        guard fsync(targetFD) == 0, syncDirectory(parentFD) else { return .committedDurabilityUncertain }
        return .committed
    }

    private static func sameObject(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && (a.st_mode & mode_t(S_IFMT)) == (b.st_mode & mode_t(S_IFMT))
    }
    private static func parentMatches(_ path: String, expected: stat) -> Bool {
        var value = stat()
        return lstat(path, &value) == 0 && sameObject(value, expected)
    }
    private static func fileMatches(_ fd: Int32, data: Data) -> Bool {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size == Int64(data.count), lseek(fd, 0, SEEK_SET) == 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var offset = 0
        while offset < data.count {
            let count = Darwin.read(fd, &buffer, min(buffer.count, data.count - offset))
            if count < 0 && errno == EINTR { continue }
            guard count > 0, data.subdata(in: offset..<(offset + count)) == Data(buffer.prefix(count)) else { return false }
            offset += count
        }
        return true
    }
    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
