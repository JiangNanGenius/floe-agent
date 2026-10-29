import Foundation
import FloeCore

/// How a commit behaves when the destination already exists.
public struct FileCommitPolicy: Sendable {
    public enum Conflict: Sendable {
        /// Default tool-output semantics: never overwrite.
        case failIfExists
        /// Replace only when the caller (after user/model consent) allows it.
        case replaceAtomically(consent: Bool)
        /// Optimistic concurrency: replace only when the current file still
        /// matches what the caller last read.
        case replaceIfUnchanged(expectedSHA256: String?, expectedMTime: Date?, mtimeTolerance: TimeInterval)
    }

    public var conflict: Conflict
    public var maxBytes: Int?
    /// Runs against the staged file before the destination changes, so a
    /// failed verification never leaves a broken output behind.
    public var verifyBeforeCommit: (@Sendable (URL) throws -> Void)?
    public var checkCancellation: (@Sendable () throws -> Void)?

    public init(
        conflict: Conflict = .failIfExists,
        maxBytes: Int? = nil,
        verifyBeforeCommit: (@Sendable (URL) throws -> Void)? = nil,
        checkCancellation: (@Sendable () throws -> Void)? = nil
    ) {
        self.conflict = conflict
        self.maxBytes = maxBytes
        self.verifyBeforeCommit = verifyBeforeCommit
        self.checkCancellation = checkCancellation
    }
}

public struct FileCommitReceipt: Sendable {
    public let url: URL
    public let byteCount: Int
    public let sha256: String
    public let replacedExisting: Bool
}

/// The single staged commit path for tool outputs: write a sibling temp file,
/// verify it, then one atomic move/replace. No destination change happens
/// before verification passes, which removes the TOCTOU and post-commit
/// verification divergences between PDF, Office, workspace and download code.
public enum AtomicFileCommitter {
    @discardableResult
    public static func commit(
        _ data: Data,
        to destination: URL,
        policy: FileCommitPolicy = FileCommitPolicy()
    ) throws -> FileCommitReceipt {
        try policy.checkCancellation?()
        if let maxBytes = policy.maxBytes, data.count > maxBytes {
            throw FloeError.validationFailed("Payload exceeds the \(maxBytes)-byte limit")
        }

        let fileManager = FileManager.default
        let existed = fileManager.fileExists(atPath: destination.path)
        if existed {
            try checkConflict(destination: destination, policy: policy)
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".floe-commit-\(UUID().uuidString)")
        do {
            try data.write(to: staged, options: [.withoutOverwriting])
            try policy.verifyBeforeCommit?(staged)
            try policy.checkCancellation?()
            if existed {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
            } else {
                try fileManager.moveItem(at: staged, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: staged)
            throw error
        }
        return FileCommitReceipt(
            url: destination,
            byteCount: data.count,
            sha256: FloeDigest.sha256Hex(data),
            replacedExisting: existed
        )
    }

    /// Commits an already-staged file (e.g. a completed URLSession download)
    /// with the same conflict/verification policy, avoiding a full read into
    /// memory for large payloads.
    @discardableResult
    public static func commit(
        stagedFile: URL,
        to destination: URL,
        policy: FileCommitPolicy = FileCommitPolicy()
    ) throws -> FileCommitReceipt {
        try policy.checkCancellation?()
        let byteCount = (try? stagedFile.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if let maxBytes = policy.maxBytes, byteCount > maxBytes {
            throw FloeError.validationFailed("Payload exceeds the \(maxBytes)-byte limit")
        }
        let fileManager = FileManager.default
        let existed = fileManager.fileExists(atPath: destination.path)
        if existed {
            try checkConflict(destination: destination, policy: policy)
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try policy.verifyBeforeCommit?(stagedFile)
        try policy.checkCancellation?()
        if existed {
            _ = try fileManager.replaceItemAt(destination, withItemAt: stagedFile)
        } else {
            try fileManager.moveItem(at: stagedFile, to: destination)
        }
        let digest = (try? FloeDigest.sha256Hex(ofFileAt: destination)) ?? ""
        return FileCommitReceipt(
            url: destination,
            byteCount: byteCount,
            sha256: digest,
            replacedExisting: existed
        )
    }

    private static func checkConflict(destination: URL, policy: FileCommitPolicy) throws {
        switch policy.conflict {
        case .failIfExists:
            throw FloeError.validationFailed("Destination already exists; choose a new path")
        case .replaceAtomically(let consent):
            guard consent else {
                throw FloeError.validationFailed("Destination already exists; explicit overwrite consent is required")
            }
        case .replaceIfUnchanged(let expectedSHA256, let expectedMTime, let tolerance):
            if let expectedSHA256 {
                let actual = try FloeDigest.sha256Hex(ofFileAt: destination)
                guard actual == expectedSHA256.lowercased() else {
                    throw FloeError.validationFailed("Write conflict: the file changed since it was read")
                }
            }
            if let expectedMTime,
               let actualMTime = try? destination.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                guard abs(actualMTime.timeIntervalSince(expectedMTime)) <= tolerance else {
                    throw FloeError.validationFailed("Write conflict: the file changed since it was read")
                }
            }
        }
    }
}
