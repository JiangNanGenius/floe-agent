import Foundation
import Crypto
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// File I/O failure captured while streaming a hash. It preserves the stage
/// (`open`/`read`) and the underlying POSIX errno (walked out of the
/// Foundation/NSError underlying chain) so a caller can tell a transient,
/// retryable file-access failure from content corruption.
///
/// `detail` is a path-sanitized description: Foundation error descriptions
/// embed the absolute file path (and sometimes the volume name), but this
/// type is surfaced in UI messages and diagnostics, so any path the failure
/// names is redacted while the error domain, code and errno are kept. Use
/// `FloeFileIOError(stage:underlying:path:)` to build one from a real error.
public struct FloeFileIOError: Error, LocalizedError, Equatable {
    public enum Stage: String, Sendable, Equatable {
        case open
        case read
    }

    public let stage: Stage
    /// Underlying POSIX errno recovered from the NSError chain; 0 when the
    /// platform supplied no POSIX error (then the failure is not classified
    /// as transient).
    public let posixErrno: Int32
    /// Sanitized, path-free description safe to export in UI/diagnostics.
    public let detail: String
    /// Foundation error domain the failure originated from, when one exists.
    public let domain: String?
    /// Foundation error code inside `domain`, when one exists.
    public let code: Int?

    public init(
        stage: Stage,
        posixErrno: Int32,
        detail: String,
        domain: String? = nil,
        code: Int? = nil
    ) {
        self.stage = stage
        self.posixErrno = posixErrno
        self.detail = detail
        self.domain = domain
        self.code = code
    }

    /// Builds a typed failure from an underlying error, redacting `path` and
    /// every other filesystem path the description mentions. The domain/code
    /// of the outermost NSError are preserved for classification.
    public init(stage: Stage, underlying: Error, path: String) {
        let ns = underlying as NSError
        self.init(
            stage: stage,
            posixErrno: FloeDigest.posixErrno(of: underlying),
            detail: FloeFileIOError.sanitizedDescription(of: underlying, redacting: path),
            domain: ns.domain,
            code: ns.code
        )
    }

    public var errorDescription: String? { detail }

    /// Redacts filesystem paths from an error description. The known `path`
    /// and its parent directory are replaced first, then any remaining
    /// POSIX-looking absolute path token is collapsed to `<path>` so an error
    /// from a nested file (e.g. a volume root) cannot leak through. A bare
    /// filename is left intact: it is not a path, and replacing short names
    /// would mangle ordinary prose.
    static func sanitizedDescription(of error: Error, redacting path: String) -> String {
        var text = (error as NSError).localizedDescription
        let candidates = [path, (path as NSString).deletingLastPathComponent]
            .filter { $0.count > 1 && $0 != "/" }
        for candidate in candidates {
            text = text.replacingOccurrences(of: candidate, with: "<path>")
        }
        // Any absolute path token that survived (a different nested file, a
        // symlink-resolved form) still points at the filesystem. Collapse
        // POSIX-ish absolute path runs; English prose never contains them.
        text = text.replacingOccurrences(
            of: #"/(?:[A-Za-z0-9._\-]+/)+[A-Za-z0-9._\-]+"#,
            with: "<path>",
            options: .regularExpression
        )
        return text
    }

    /// Errno values that describe a transient, retryable access condition.
    /// Permission failures (EACCES/EPERM) are deliberately excluded: a
    /// permanent denial must not be called transient without reason, and an
    /// unknown error (errno 0) never defaults to transient.
    ///
    /// ENOMEM belongs here: `read(2)` reports it when the kernel cannot provide
    /// the read buffer under memory pressure — the errno=12 the device raised
    /// while hashing — and the same bytes can be read again once pressure
    /// clears. It is a local condition, never evidence that the hashed content
    /// is wrong.
    #if canImport(Darwin) || canImport(Glibc)
    private static let transientErrnos: Set<Int32> = {
        var values: Set<Int32> = [EINTR, EAGAIN, EBUSY, EDEADLK, ENOMEM]
        // EWOULDBLOCK is a separate constant on some platforms.
        values.insert(EWOULDBLOCK)
        return values
    }()
    #endif

    /// True only for a known transient, retryable access condition. Never
    /// evidence that the hashed bytes are wrong.
    public var isTransientAccessFailure: Bool {
        #if canImport(Darwin) || canImport(Glibc)
        guard posixErrno != 0 else { return false }
        return Self.transientErrnos.contains(posixErrno)
        #else
        return false
        #endif
    }
}

/// Shared digest helpers. One implementation replaces the inline
/// `SHA256.hash(...).map { String(format: "%02x", $0) }` copies scattered
/// across tools and services. Named `FloeDigest` to avoid colliding with
/// `Crypto.Digest` in files that import swift-crypto directly.
public enum FloeDigest {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func shortSHA256(_ data: Data, length: Int = 16) -> String {
        String(sha256Hex(data).prefix(max(1, length)))
    }

    /// Streaming hash so large files never load fully into memory.
    ///
    /// `progress` receives `(hashedBytes, totalBytes)` after every chunk;
    /// `totalBytes` is the size captured with `fstat` at open time (-1 when
    /// the platform cannot report it). `isCancelled` is checked before every
    /// read: a true answer throws `CancellationError` and no digest is
    /// produced. Both parameters default to nil/absent, so existing callers
    /// keep the plain digest contract.
    public static func sha256Hex(
        ofFileAt url: URL,
        chunkSize: Int = 1 << 20,
        progress: ((_ hashedBytes: Int64, _ totalBytes: Int64) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil
    ) throws -> String {
        var hasher = SHA256()
        try streamBytes(ofFileAt: url, chunkSize: chunkSize, progress: progress, isCancelled: isCancelled) {
            hasher.update(bufferPointer: $0)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha512Hex(_ data: Data) -> String {
        SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Streaming SHA-512 for guest image artifacts (BIOS/kernel/initrd/disk).
    /// The image manifest binds artifact digests, so verification must hash the
    /// actual bytes and never trust a size or a user-written `qualified` flag.
    ///
    /// See `sha256Hex(ofFileAt:)` for the `progress`/`isCancelled` contract.
    public static func sha512Hex(
        ofFileAt url: URL,
        chunkSize: Int = 1 << 20,
        progress: ((_ hashedBytes: Int64, _ totalBytes: Int64) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil
    ) throws -> String {
        var hasher = SHA512()
        try streamBytes(ofFileAt: url, chunkSize: chunkSize, progress: progress, isCancelled: isCancelled) {
            hasher.update(bufferPointer: $0)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Streams the file through `consume` with one preallocated POSIX buffer.
    ///
    /// This deliberately does NOT use `FileHandle.read(upToCount:)`: on Darwin
    /// each returned Foundation buffer is autoreleased, and a long synchronous
    /// hash loop never drains the enclosing pool, so resident memory grows
    /// with the file size. Measured on the host (macOS, 1 GiB sparse file,
    /// 1 MiB chunks) the former loop sampled 383–704 MiB resident versus a
    /// flat ~7 MiB here. The device reported a read failure with errno 12
    /// while verifying a Linux image whose download archive was 587.2 MB
    /// (UI-reported size; the expanded disk size on the device was not
    /// measured), so the source-level link between retained buffers and that
    /// failure is a bounded diagnosis, not a device-proven jetsam. Hashing the
    /// real bytes is unchanged (no size-only or cached-digest shortcut).
    ///
    /// `read(2)` is retried on EINTR; any other failure becomes the typed
    /// `FloeFileIOError` with the real POSIX errno, never a digest verdict.
    private static func streamBytes(
        ofFileAt url: URL,
        chunkSize: Int,
        progress: ((_ hashedBytes: Int64, _ totalBytes: Int64) -> Void)?,
        isCancelled: (() -> Bool)?,
        consume: (UnsafeRawBufferPointer) -> Void
    ) throws {
        let boundedChunk = max(4096, min(chunkSize, 1 << 20))
        #if canImport(Darwin) || canImport(Glibc)
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            // Capture errno immediately, before any formatting call can
            // observe (or overwrite) it.
            let code = errno
            throw FloeFileIOError(
                stage: .open,
                posixErrno: code,
                detail: posixDetail(code),
                domain: NSPOSIXErrorDomain,
                code: Int(code)
            )
        }
        defer { _ = close(descriptor) }
        let total = fileSize(descriptor: descriptor)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: boundedChunk, alignment: MemoryLayout<UInt8>.alignment)
        defer { buffer.deallocate() }
        var hashed: Int64 = 0
        while true {
            if isCancelled?() == true { throw CancellationError() }
            let count = read(descriptor, buffer, boundedChunk)
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                throw FloeFileIOError(
                    stage: .read,
                    posixErrno: code,
                    detail: posixDetail(code),
                    domain: NSPOSIXErrorDomain,
                    code: Int(code)
                )
            }
            if count == 0 { break }
            consume(UnsafeRawBufferPointer(start: buffer, count: count))
            hashed += Int64(count)
            progress?(hashed, total)
        }
        #else
        // No POSIX layer: a Foundation fallback for unsupported platforms.
        // The supported Darwin/Glibc targets always take the fixed-buffer path
        // above, which is the one that carries the bounded-memory promise.
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw FloeFileIOError(stage: .open, underlying: error, path: url.path)
        }
        defer { try? handle.close() }
        var total: Int64 = -1
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? NSNumber {
            total = size.int64Value
        }
        var hashed: Int64 = 0
        while true {
            if isCancelled?() == true { throw CancellationError() }
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: boundedChunk) ?? Data()
            } catch {
                throw FloeFileIOError(stage: .read, underlying: error, path: url.path)
            }
            if chunk.isEmpty { break }
            chunk.withUnsafeBytes { consume($0) }
            hashed += Int64(chunk.count)
            progress?(hashed, total)
        }
        #endif
    }

    #if canImport(Darwin) || canImport(Glibc)
    /// Size captured from the already-open descriptor, so progress cannot race
    /// a path swap. -1 when `fstat` is unavailable.
    private static func fileSize(descriptor: Int32) -> Int64 {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return -1 }
        return Int64(info.st_size)
    }

    /// Human-readable POSIX error text, used path-free in `FloeFileIOError`.
    private static func posixDetail(_ code: Int32) -> String {
        guard let message = strerror(code) else { return "errno \(code)" }
        return String(cString: message)
    }
    #endif

    /// Walks the Foundation NSError underlying chain and returns the POSIX
    /// errno when the failure originates at a syscall. 0 otherwise.
    static func posixErrno(of error: Error) -> Int32 {
        var current = error as NSError
        while true {
            if current.domain == NSPOSIXErrorDomain {
                return Int32(current.code)
            }
            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError {
                current = underlying
                continue
            }
            return 0
        }
    }
}
