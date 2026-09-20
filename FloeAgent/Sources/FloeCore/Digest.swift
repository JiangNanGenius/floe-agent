import Foundation
import Crypto

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
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha512Hex(_ data: Data) -> String {
        SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Streaming SHA-512 for guest image artifacts (BIOS/kernel/initrd/disk).
    /// The image manifest binds artifact digests, so verification must hash the
    /// actual bytes and never trust a size or a user-written `qualified` flag.
    public static func sha512Hex(ofFileAt url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA512()
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
