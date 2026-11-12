import Foundation
import FloeCore
import FloeTools

/// One authenticated, read-only chunk of an absolute Mac path.
public struct MacAbsoluteFileChunk: Sendable, Equatable {
    public let data: Data
    public let byteOffset: Int
    public let totalBytes: Int
    public let identity: String
    public let sha256: String?

    public init(data: Data, byteOffset: Int, totalBytes: Int,
                identity: String, sha256: String? = nil) {
        self.data = data
        self.byteOffset = byteOffset
        self.totalBytes = totalBytes
        self.identity = identity
        self.sha256 = sha256
    }
}

public struct MacAbsoluteFileData: Sendable, Equatable {
    public let data: Data
    public let sha256: String

    public init(data: Data, sha256: String) {
        self.data = data
        self.sha256 = sha256
    }
}

/// App-injected read-only seam for Mac absolute paths.
///
/// `FloeWorkspace` deliberately does not import `FloeExecution`; the App wires
/// the paired Mac client behind this protocol. Returning `nil` means "this run
/// is not an authorized Mac Bridge task", which preserves the ordinary
/// workspace-relative path handling. A Mac task that cannot complete the read
/// throws the honest transport/OS error instead.
public protocol MacAbsoluteFileReading: Sendable {
    var maximumChunkBytes: Int { get }
    func readMacAbsoluteFileChunk(
        path: String,
        offset: Int,
        limit: Int,
        expectedIdentity: String?,
        verifySHA256: Bool,
        context: ToolContext
    ) async throws -> MacAbsoluteFileChunk?
}

public extension MacAbsoluteFileReading {
    var maximumChunkBytes: Int { 1_024 * 1_024 }

    /// Assemble a bounded whole file with a stable identity across every
    /// chunk and a verified whole-file digest. Mirrors the image pipeline's
    /// 20 MiB working limit at the caller.
    func readMacAbsoluteFileWhole(
        path: String,
        maximumBytes: Int,
        context: ToolContext
    ) async throws -> MacAbsoluteFileData? {
        try MacAbsolutePath.validate(path)
        guard maximumBytes > 0 else {
            throw FloeError.validationFailed("The whole-file read limit must be positive")
        }
        var assembled = Data()
        var identity: String?
        var total: Int?
        let limit = max(1, min(maximumChunkBytes, maximumBytes))
        while true {
            try context.cancellation.throwIfCancelled()
            let chunk = try await readMacAbsoluteFileChunk(
                path: path, offset: assembled.count, limit: limit,
                expectedIdentity: identity, verifySHA256: false, context: context)
            guard let chunk else {
                guard assembled.isEmpty else {
                    throw FloeError.validationFailed(
                        "The Mac execution target changed during the read; the partial result was discarded.")
                }
                return nil
            }
            // The generic assembler is itself a public entry point; it must
            // not trust a concrete reader to uphold the chunk contract.
            guard chunk.totalBytes >= 0 else {
                throw FloeError.validationFailed("The Mac file changed during the read. Read it again.")
            }
            if let total, total != chunk.totalBytes {
                throw FloeError.validationFailed("The Mac file changed during the read. Read it again.")
            }
            if let identity, identity != chunk.identity {
                throw FloeError.validationFailed("The Mac file changed during the read. Read it again.")
            }
            guard chunk.data.count <= limit,
                  chunk.byteOffset == assembled.count + chunk.data.count,
                  chunk.byteOffset <= chunk.totalBytes,
                  assembled.count + chunk.data.count <= maximumBytes,
                  assembled.count + chunk.data.count <= chunk.totalBytes else {
                throw FloeError.validationFailed("The Mac returned an invalid file page.")
            }
            if total == nil {
                total = chunk.totalBytes
                guard chunk.totalBytes <= maximumBytes else {
                    throw FloeError.validationFailed(
                        "This Mac file is \(chunk.totalBytes) bytes; the supported limit for one visual read is \(maximumBytes) bytes.")
                }
            }
            identity = chunk.identity
            assembled.append(chunk.data)
            if chunk.byteOffset >= chunk.totalBytes { break }
            guard !chunk.data.isEmpty else {
                throw FloeError.validationFailed("The Mac file changed during the read. Read it again.")
            }
        }
        let receipt = try await readMacAbsoluteFileChunk(
            path: path, offset: assembled.count, limit: 1,
            expectedIdentity: identity, verifySHA256: true, context: context)
        try context.cancellation.throwIfCancelled()
        guard let receipt, receipt.data.isEmpty,
              receipt.byteOffset == assembled.count,
              receipt.totalBytes == total, receipt.identity == identity,
              let expected = receipt.sha256,
              expected.count == 64 else {
            throw FloeError.validationFailed("The Mac file changed during the read. Read it again.")
        }
        let actual = FloeDigest.sha256Hex(assembled)
        guard actual == expected else {
            throw FloeError.validationFailed("The Mac file changed during the read. Read it again.")
        }
        return MacAbsoluteFileData(data: assembled, sha256: actual)
    }
}

/// Syntax of a Mac absolute path supplied as data. Never expanded from `~`,
/// never spliced into a command, and bounded before it enters the bridge.
public enum MacAbsolutePath {
    public static let maximumUTF8Bytes = 4_096

    public static func isAbsolute(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.hasPrefix("~")
    }

    public static func validate(_ path: String) throws {
        guard isAbsolute(path), !path.hasPrefix("//"),
              !path.contains("\0"),
              path.utf8.count <= maximumUTF8Bytes,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw FloeError.validationFailed(
                "Use an absolute Mac path such as /Users/name/file.png without control characters")
        }
    }
}

/// Runtime-issued authority checks shared by workspace and image tools.
/// `allowedWorkspacePaths` is a relative workspace ceiling, so an absolute
/// Mac path cannot be proven inside it; scoped children therefore keep their
/// existing ceiling. Temporary chat keeps its read-only, no-workspace ceiling.
public enum MacAbsoluteReadAuthorization {
    public static func authorize(_ path: String, context: ToolContext) throws {
        try context.cancellation.throwIfCancelled()
        try MacAbsolutePath.validate(path)
        guard context.scope == .local else {
            throw FloeError.validationFailed(
                "Absolute Mac paths are available only inside the task's local Mac execution scope.")
        }
        guard !context.temporaryReadOnly, !context.publicWebOnly else {
            throw FloeError.validationFailed(
                "Temporary chat cannot read absolute Mac files. Use an ordinary task on the paired Mac.")
        }
        guard context.allowedWorkspacePaths.isEmpty else {
            throw FloeError.validationFailed(
                "This task's file scope permits only the task workspace; absolute Mac paths require an unscoped task.")
        }
    }
}
