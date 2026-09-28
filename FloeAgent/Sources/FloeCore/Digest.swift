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
    #if canImport(Darwin) || canImport(Glibc)
    private static let transientErrnos: Set<Int32> = {
        var values: Set<Int32> = [EINTR, EAGAIN, EBUSY, EDEADLK]
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
    public static func sha256Hex(ofFileAt url: URL, chunkSize: Int = 1 << 20) throws -> String {
        var hasher = SHA256()
        try streamBytes(ofFileAt: url, chunkSize: chunkSize) { hasher.update(data: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha512Hex(_ data: Data) -> String {
        SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Streaming SHA-512 for guest image artifacts (BIOS/kernel/initrd/disk).
    /// The image manifest binds artifact digests, so verification must hash the
    /// actual bytes and never trust a size or a user-written `qualified` flag.
    public static func sha512Hex(ofFileAt url: URL, chunkSize: Int = 1 << 20) throws -> String {
        var hasher = SHA512()
        try streamBytes(ofFileAt: url, chunkSize: chunkSize) { hasher.update(data: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Streams the file through `consume` using Foundation `FileHandle`,
    /// recovering the underlying POSIX errno from the NSError chain on an
    /// open/read failure. Foundation retries EINTR internally, so no raw
    /// syscall layer is needed here.
    private static func streamBytes(
        ofFileAt url: URL,
        chunkSize: Int,
        consume: (Data) -> Void
    ) throws {
        let boundedChunk = max(4096, min(chunkSize, 1 << 20))
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw FloeFileIOError(stage: .open, underlying: error, path: url.path)
        }
        defer { try? handle.close() }
        while true {
            do {
                let chunk = try handle.read(upToCount: boundedChunk) ?? Data()
                if chunk.isEmpty { break }
                consume(chunk)
            } catch {
                throw FloeFileIOError(stage: .read, underlying: error, path: url.path)
            }
        }
    }

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
