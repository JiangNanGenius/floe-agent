// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore

/// Binary editors resolve conflicts as complete versions, never as text hunks.
public struct WorkspaceBinaryEditConflict: LocalizedError, Sendable {
    public let originalPath: String
    public let recoveryPath: String
    public let currentSHA256: String?
    public var errorDescription: String? {
        "The file changed or was removed while you were editing. Your version is saved at \(recoveryPath)."
    }
}

public struct WorkspaceBinaryEditOutcome: Sendable {
    public let write: WriteOutcome
    /// Exact previous bytes, retained before replacing a managed binary file.
    public let previousVersionPath: String
}

extension WorkspaceFileService {
    /// Commits a fully validated binary document using the editor's original
    /// baseline. The caller must reparse its output before invoking this method.
    /// A changed/deleted source is never overwritten or silently recreated.
    public func commitBinaryEdit(path: String, data: Data, expectedSHA256: String) throws -> WorkspaceBinaryEditOutcome {
        guard expectedSHA256.count == 64, expectedSHA256.allSatisfy(\.isHexDigit) else {
            throw WorkspaceToolError.invalidArguments("A complete original SHA-256 is required")
        }
        try guardResolver.assertWritableSize(bytes: data.count)
        let lock = WorkspaceMutationLocks.lock(for: guardResolver.rootURL)
        lock.lock(); defer { lock.unlock() }
        let destination = try guardResolver.resolve(path)
        try guardResolver.assertWritable(destination)
        let manager = FileManager.default
        var previous: Data?
        if manager.fileExists(atPath: destination.path) {
            try guardResolver.assertReadableSize(destination)
            previous = try Data(contentsOf: destination)
        }
        let currentSHA = previous.map(FloeDigest.sha256Hex)
        guard let previous, currentSHA?.lowercased() == expectedSHA256.lowercased() else {
            let recovery = try preserveBinaryVersion(path: path, data: data)
            throw WorkspaceBinaryEditConflict(originalPath: path, recoveryPath: recovery, currentSHA256: currentSHA)
        }
        let backup = try preserveBinaryVersion(path: path, data: previous)
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            // Preserve the draft when possible; never mask a storage failure as
            // a successful commit. The pre-edit original was already retained.
            if let recovery = try? preserveBinaryVersion(path: path, data: data) {
                throw WorkspaceDraftRecoveryError(recoveryPath: recovery, reason: error.localizedDescription)
            }
            throw error
        }
        let metadata = try self.metadata(path)
        return WorkspaceBinaryEditOutcome(write: WriteOutcome(bytesWritten: data.count,
            sha256: metadata.sha256, mtime: metadata.mtime), previousVersionPath: backup)
    }

    private func preserveBinaryVersion(path: String, data: Data) throws -> String {
        try guardResolver.assertWritableSize(bytes: data.count)
        let pathDigest = FloeDigest.sha256Hex(Data(path.utf8)).prefix(16)
        let digest = FloeDigest.sha256Hex(data)
        let suffix = (path as NSString).pathExtension.lowercased()
        // Do not allow an extension supplied by an editor to become a path.
        let safeSuffix = suffix.count <= 16 && suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? suffix : "bin"
        let recovery = "Recovered Edits/\(pathDigest)-\(digest).\(safeSuffix.isEmpty ? "bin" : safeSuffix)"
        let url = try guardResolver.resolve(recovery)
        try guardResolver.assertWritable(url)
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            try guardResolver.assertReadableSize(url)
            guard FloeDigest.sha256Hex(try Data(contentsOf: url)) == digest else {
                throw WorkspaceToolError.conflict(expected: digest, actual: "Recovery copy changed")
            }
        } else {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // The shared managed-mutation lock covers the existence check and
            // atomic rename. Existing content-addressed copies are never changed.
            try data.write(to: url, options: .atomic)
        }
        return recovery
    }
}
