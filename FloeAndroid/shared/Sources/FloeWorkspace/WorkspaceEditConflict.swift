import Foundation
import FloeCore

/// Serializes only filesystem transactions, never an editing session or an
/// Agent run. The shared recursive lock also covers metadata/diff helpers.
enum WorkspaceMutationLocks {
    static func lock(for root: URL) -> NSRecursiveLock {
        ManagedFileMutationLock.shared
    }
}

public struct WorkspaceDraftRecoveryError: LocalizedError, Sendable {
    public let recoveryPath: String
    public let reason: String
    public var errorDescription: String? { "The original could not be reviewed. Your draft is saved at \(recoveryPath). \(reason)" }
}

public struct WorkspaceEditConflict: Identifiable, Sendable {
    public let id = UUID()
    public let path: String
    public let base: String?
    public let draft: String
    public let current: String
    public let currentSHA256: String
    public let currentMtime: Double
    public let recoveryPath: String?
    public var plan: TextMergePlan { TextMergePlan(base: base, mine: draft, current: current) }
}

extension WorkspaceFileService {
    public func editConflict(path: String, base: String?, draft: String, preserveDraft: Bool = false) throws -> WorkspaceEditConflict {
        let lock = WorkspaceMutationLocks.lock(for: guardResolver.rootURL)
        lock.lock(); defer { lock.unlock() }
        var recoveryPath: String?
        if preserveDraft {
            // A content-addressed copy survives dismissal/relaunch. Never
            // delete another user's draft or replace the shared original.
            let name = FloeDigest.sha256Hex(Data(path.utf8)).prefix(16)
            let digest = FloeDigest.sha256Hex(Data(draft.utf8))
            let copy = "Recovered Edits/\(name)-\(digest).txt"
            do { try createDirectory("Recovered Edits") }
            catch WorkspaceToolError.alreadyExists { /* Existing recovery directory. */ }
            do { _ = try createFile(copy, content: draft, overwrite: false) }
            catch WorkspaceToolError.alreadyExistsOverwritable {
                guard try metadata(copy).sha256 == digest else {
                    throw WorkspaceToolError.conflict(expected: digest, actual: "recovery copy changed")
                }
            }
            recoveryPath = copy
        }
        let current: String
        let snapshotMetadata: WorkspaceFileMetadata
        do {
            current = try readFileForEditing(path).text
            snapshotMetadata = try metadata(path)
            // Never silently recode a non-UTF8 file during conflict recovery.
            guard FloeDigest.sha256Hex(Data(current.utf8)) == snapshotMetadata.sha256 else {
                throw WorkspaceToolError.invalidArguments("Conflict review requires a complete UTF-8 snapshot")
            }
        } catch {
            if let recoveryPath { throw WorkspaceDraftRecoveryError(recoveryPath: recoveryPath, reason: error.localizedDescription) }
            throw error
        }
        return WorkspaceEditConflict(path: path, base: base, draft: draft, current: current,
                                     currentSHA256: snapshotMetadata.sha256, currentMtime: snapshotMetadata.mtime, recoveryPath: recoveryPath)
    }

    @discardableResult public func resolveConflict(_ conflict: WorkspaceEditConflict, content: String) throws -> WriteOutcome {
        // Another edit after the review opened is a new conflict. Never retry
        // without these expectations or force the old resolution onto disk.
        try writeFile(conflict.path, content: content, expectedMtime: conflict.currentMtime,
                      expectedSHA256: conflict.currentSHA256)
    }
}
