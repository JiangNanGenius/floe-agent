import Foundation
import CryptoKit

/// Additive absolute-file read contract for the paired same-Mac bridge.
///
/// This is deliberately separate from the workspace-relative `file.read`
/// contract: absolute paths are transported as data, are limited to ordinary
/// regular files, and never enter a shell command or a generic write path.
public enum BridgeAbsoluteFileRead {
    /// Advertised by an authenticated `ping`. A companion that predates the
    /// feature does not list it, so the client fails with an explicit update
    /// message instead of probing an unavailable method.
    public static let capability = "absoluteFileReadV1"
    public static let maximumPathBytes = 4_096
    /// One authenticated response stays below `BridgeWire.maximumFrameBytes`
    /// after base64 encoding, even with the JSON and signature envelope.
    public static let maximumChunkBytes = 1_024 * 1_024
    /// Whole-file receipts are bounded so a request cannot force unbounded
    /// hashing work on the companion. The image pipeline's 20 MiB limit is
    /// below this ceiling.
    public static let maximumReceiptBytes = 64 * 1_024 * 1_024

    public static func validPath(_ path: String) -> Bool {
        !path.isEmpty
            && path.hasPrefix("/")
            && !path.hasPrefix("//")
            && !path.hasPrefix("~")
            && !path.contains("\0")
            && path.utf8.count <= maximumPathBytes
    }

    public static func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    /// Opaque identity of the exact opened regular file. It is stable for an
    /// unchanged file and changes after replacement, truncation or a write.
    /// `ctime` is included because a same-size rewrite that restores `mtime`
    /// still advances the inode change time.
    public static func identity(
        device: UInt64,
        inode: UInt64,
        size: Int64,
        modifiedSeconds: Int64,
        modifiedNanoseconds: Int64,
        changedSeconds: Int64,
        changedNanoseconds: Int64
    ) -> String {
        let seed = "\(device):\(inode):\(size):\(modifiedSeconds):\(modifiedNanoseconds):\(changedSeconds):\(changedNanoseconds)"
        return SHA256.hash(data: Data(seed.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// The same basename/component denylist `WorkspacePathGuard` applies to
    /// workspace reads. Absolute reads are checked against the actual
    /// canonical target so an innocent requested name cannot resolve to
    /// credential material (for example a link to `~/.ssh/id_ed25519`).
    public static func isSecretPath(_ canonicalPath: String) -> Bool {
        let url = URL(fileURLWithPath: canonicalPath)
        let components = url.pathComponents
        for component in components where secretDirectories.contains(component) {
            return true
        }
        let name = url.lastPathComponent
        let lowered = name.lowercased()
        if secretExactNames.contains(lowered) { return true }
        if secretPrefixes.contains(where: { lowered.hasPrefix($0) }) { return true }
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty, secretExtensions.contains(ext) { return true }
        if components.count >= 2,
           let gitIndex = components.lastIndex(of: ".git"),
           gitIndex < components.count - 1 {
            let inside = components[(gitIndex + 1)...]
            if inside.first == "config" || inside.first == "credentials" { return true }
        }
        return false
    }

    private static let secretExactNames: Set<String> = [
        ".netrc", ".npmrc", ".pypirc", ".git-credentials", ".htpasswd",
    ]
    private static let secretPrefixes: [String] = [
        ".env", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", ".pgpass",
    ]
    private static let secretExtensions: Set<String> = [
        "pem", "key", "keystore", "p12", "pfx", "jks",
    ]
    private static let secretDirectories: Set<String> = [".ssh", ".aws", ".gnupg"]

    public struct Chunk: Sendable, Equatable {
        public let data: Data
        public let offset: Int64
        public let totalBytes: Int64
        public let identity: String
        public let sha256: String?

        public init(data: Data, offset: Int64, totalBytes: Int64,
                    identity: String, sha256: String? = nil) {
            self.data = data
            self.offset = offset
            self.totalBytes = totalBytes
            self.identity = identity
            self.sha256 = sha256
        }
    }

    /// Typed validation of one authenticated `file.readAbsolute` reply.
    /// `expectedTotal`/`expectedIdentity` let a multi-chunk reader reject a
    /// replacement between pages before any assembled bytes are trusted.
    public static func validateChunk(
        _ payload: [String: BridgeValue],
        requestedOffset: Int64,
        requestedLimit: Int,
        expectedTotal: Int64? = nil,
        expectedIdentity: String? = nil
    ) throws -> Chunk {
        guard requestedOffset >= 0,
              (1...maximumChunkBytes).contains(requestedLimit),
              let text = payload["data"]?.string,
              text.utf8.count <= ((requestedLimit + 2) / 3) * 4,
              let data = Data(base64Encoded: text),
              data.count <= requestedLimit,
              let returnedOffset = payload["offset"]?.integer,
              let total = payload["totalBytes"]?.integer,
              total >= 0,
              let identity = payload["identity"]?.string,
              validDigest(identity) else { throw BridgeFailure.invalidResponse }
        let (advanced, overflow) = requestedOffset.addingReportingOverflow(Int64(data.count))
        guard !overflow, advanced == returnedOffset, advanced <= total else {
            throw BridgeFailure.invalidResponse
        }
        if let expectedTotal, expectedTotal != total { throw BridgeFailure.invalidResponse }
        if let expectedIdentity, expectedIdentity != identity { throw BridgeFailure.invalidResponse }
        let digest: String?
        switch payload["sha256"] {
        case nil, .null?: digest = nil
        case .string(let value)? where validDigest(value): digest = value
        default: throw BridgeFailure.invalidResponse
        }
        // An empty page is valid only at the confirmed end of the file.
        guard !data.isEmpty || advanced == total else { throw BridgeFailure.invalidResponse }
        return Chunk(data: data, offset: advanced, totalBytes: total,
                     identity: identity, sha256: digest)
    }
}
