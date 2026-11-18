import Foundation
import Darwin
import FloeToolboxUtilities

public enum MacScanExportFormat: String, CaseIterable, Sendable, Equatable {
    case png
    case pdf
    case txt
    /// CSV is used by the sound analyzer export; the scanner itself exports
    /// PNG/PDF/TXT only.
    case csv

    public var fileExtension: String { rawValue }
}

/// A completely rendered export held in memory until the user confirms a save
/// panel location. Nothing is written by scanning or recognition itself.
public struct MacExportArtifact: Sendable, Equatable {
    public let format: MacScanExportFormat
    public let data: Data
    public let suggestedFilename: String

    public init(format: MacScanExportFormat, data: Data, suggestedFilename: String) {
        self.format = format
        self.data = data
        self.suggestedFilename = suggestedFilename
    }
}

public enum MacExportNaming {
    /// Stable, filesystem-safe name. Date/time is the only variable part, which
    /// keeps deterministic tests possible without a clock dependency.
    public static func suggestedName(
        format: MacScanExportFormat,
        prefix: String = "floe-scan",
        date: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(prefix)-\(formatter.string(from: date)).\(format.fileExtension)"
    }
}

/// Bounded, read-only image import from a user-selected file. The caller owns
/// security-scoped access (`startAccessingSecurityScopedResource`); this reader
/// never invokes NSOpenPanel, never touches the Photos library and never writes.
public enum MacFileImageReader {
    /// Aligns with `OpticsImageDecoder.maximumEncodedBytes` (20 MiB).
    public static let maximumBytes = OpticsImageDecoder.maximumEncodedBytes
    private static let chunkSize = 64 * 1_024

    public static func readImageData(
        at url: URL,
        maximumBytes: Int = MacFileImageReader.maximumBytes
    ) throws -> Data {
        try readImageData(at: url, maximumBytes: maximumBytes, afterOpen: nil)
    }

    static func readImageData(at url: URL, maximumBytes: Int = MacFileImageReader.maximumBytes,
                              afterOpen: (() throws -> Void)?) throws -> Data {
        guard url.isFileURL else { throw MacMediaFailure.fileNotRegular }
        let limit = max(1, min(maximumBytes, 256 * 1_024 * 1_024))
        // Validate the opened object, not a prior URL metadata lookup. The
        // no-follow flag closes the final-component symlink replacement race;
        // nonblocking open prevents an unexpected FIFO from hanging the UI.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw MacMediaFailure.fileIsSymbolicLink }
            throw MacMediaFailure.unreadable
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else { throw MacMediaFailure.unreadable }
        guard opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw MacMediaFailure.fileNotRegular
        }
        guard opened.st_size <= off_t(Int.max) else { throw MacMediaFailure.fileTooLarge }
        let size = Int(opened.st_size)
        guard size > 0 else { throw MacMediaFailure.unreadable }
        guard size <= limit else { throw MacMediaFailure.fileTooLarge }
        try afterOpen?()

        var data = Data()
        data.reserveCapacity(min(size, limit))
        do {
            while true {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { break }
                guard data.count + chunk.count <= limit else { throw MacMediaFailure.fileTooLarge }
                data.append(chunk)
            }
        } catch let failure as MacMediaFailure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MacMediaFailure.unreadable
        }
        // Fail if the opened file changed during the read, or the selected
        // path no longer names that same file. Do not silently import a stale
        // selection after a concurrent replacement.
        var finished = stat()
        var named = stat()
        guard fstat(descriptor, &finished) == 0,
              Darwin.lstat(url.path, &named) == 0,
              named.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              opened.st_dev == finished.st_dev, opened.st_ino == finished.st_ino,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
              opened.st_size == finished.st_size,
              opened.st_mtimespec.tv_sec == finished.st_mtimespec.tv_sec,
              opened.st_mtimespec.tv_nsec == finished.st_mtimespec.tv_nsec,
              opened.st_ctimespec.tv_sec == finished.st_ctimespec.tv_sec,
              opened.st_ctimespec.tv_nsec == finished.st_ctimespec.tv_nsec,
              data.count == size else { throw MacMediaFailure.unreadable }
        return data
    }
}

/// Writes an already user-approved export. The save panel is the authorization
/// step. This first implementation only creates a new destination; replacing
/// an existing file is deliberately unavailable until a conflict-safe replace
/// transaction exists. Staged content is verified before atomic publication.
public enum MacSafeFileWriter {
    public static let maximumBytes = 64 * 1_024 * 1_024

    enum Checkpoint: Equatable { case staged, verified, beforeCommit }

    public static func write(_ data: Data, to url: URL) throws {
        try write(data, to: url, checkpoint: nil)
    }

    // The injectable checkpoints exercise real pre-commit cleanup without
    // making the production implementation depend on synthetic file APIs.
    static func write(_ data: Data, to url: URL,
                      checkpoint: ((Checkpoint) throws -> Void)?) throws {
        guard !data.isEmpty else { throw MacMediaFailure.emptyExport }
        guard data.count <= maximumBytes else { throw MacMediaFailure.exportTooLarge }
        guard url.isFileURL else { throw MacMediaFailure.writeFailed("not-file-url") }
        let parent = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw MacMediaFailure.writeFailed("invalid-name")
        }
        let directory = Darwin.open(parent.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else {
            throw MacMediaFailure.writeFailed("parent-missing")
        }
        defer { Darwin.close(directory) }
        var parentIdentity = stat()
        guard fstat(directory, &parentIdentity) == 0 else { throw MacMediaFailure.writeFailed("parent-missing") }
        let stagingName = ".floe-scan-" + UUID().uuidString
        guard mkdirat(directory, stagingName, 0o700) == 0 else { throw MacMediaFailure.writeFailed("staging") }
        defer { _ = unlinkat(directory, stagingName, AT_REMOVEDIR) }
        let staging = openat(directory, stagingName, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        guard staging >= 0 else { throw MacMediaFailure.writeFailed("staging") }
        defer { Darwin.close(staging) }
        let stageFile = "content"
        defer { _ = unlinkat(staging, stageFile, 0) }
        let fd = openat(staging, stageFile, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw MacMediaFailure.writeFailed("staging") }
        defer { Darwin.close(fd) }
        do {
            try Task.checkCancellation()
            try checkpoint?(.staged)
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { throw MacMediaFailure.emptyExport }
                var offset = 0
                while offset < raw.count {
                    try Task.checkCancellation()
                    let count = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw MacMediaFailure.writeFailed("staging-write") }
                    offset += count
                }
            }
            guard fchmod(fd, 0o600) == 0, fsync(fd) == 0,
                  lseek(fd, 0, SEEK_SET) == 0 else { throw MacMediaFailure.writeFailed("staging-sync") }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  info.st_size == data.count, info.st_mode & 0o777 == 0o600 else {
                throw MacMediaFailure.writeFailed("staging-metadata")
            }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { throw MacMediaFailure.emptyExport }
                var offset = 0
                while offset < raw.count {
                    try Task.checkCancellation()
                    let count = Darwin.read(fd, &buffer, min(buffer.count, raw.count - offset))
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0,
                          memcmp(buffer, base.advanced(by: offset), count) == 0 else {
                        throw MacMediaFailure.writeFailed("staging-verification")
                    }
                    offset += count
                }
            }
            try checkpoint?(.verified)
            // Refuse a renamed/replaced parent, and refuse every pre-existing
            // destination, even if a save panel previously confirmed it.
            var currentParent = stat()
            guard Darwin.lstat(parent.path, &currentParent) == 0,
                  currentParent.st_dev == parentIdentity.st_dev,
                  currentParent.st_ino == parentIdentity.st_ino else {
                throw MacMediaFailure.writeFailed("parent-changed")
            }
            try checkpoint?(.beforeCommit)
            try Task.checkCancellation()
            guard linkat(staging, stageFile, directory, name, 0) == 0 else {
                if errno == EEXIST {
                    var destination = stat()
                    if fstatat(directory, name, &destination, AT_SYMLINK_NOFOLLOW) == 0,
                       destination.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                        throw MacMediaFailure.writeFailed("destination-symbolic-link")
                    }
                    throw MacMediaFailure.writeFailed("destination-exists")
                }
                throw MacMediaFailure.writeFailed("commit")
            }
        } catch is CancellationError { throw CancellationError() }
        catch let failure as MacMediaFailure { throw failure }
        catch { throw MacMediaFailure.writeFailed("staging") }
    }

    public static func write(_ artifact: MacExportArtifact, to url: URL) throws {
        try write(artifact.data, to: url)
    }
}
