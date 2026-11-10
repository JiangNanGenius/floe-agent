// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeGit

/// Frozen origin for one native operation. It holds only this operation's
/// security scope; cancellation never releases a different workspace lease.
final class SourceControlOperationLease: @unchecked Sendable {
    let id = UUID()
    let workspaceRoot: URL?
    let repositoryRoot: URL?
    let workspaceID: UUID?
    private let lock = NSLock()
    private var cancelled = false
    private var latestProgress: GitRemoteProgress?
    private let ownsSecurityScope: Bool

    init(workspaceRoot: URL?, repositoryRoot: URL?, workspaceID: UUID?) {
        self.workspaceRoot = workspaceRoot; self.repositoryRoot = repositoryRoot
        self.workspaceID = workspaceID
        ownsSecurityScope = workspaceRoot?.startAccessingSecurityScopedResource() ?? false
    }
    deinit { if ownsSecurityScope { workspaceRoot?.stopAccessingSecurityScopedResource() } }
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
        try Task.checkCancellation()
    }
    func report(_ value: GitRemoteProgress) { lock.withLock { if !cancelled { latestProgress = value } } }
    func takeProgress() -> GitRemoteProgress? {
        lock.withLock { let value = latestProgress; latestProgress = nil; return value }
    }
    func matches(root: URL?, workspaceID: UUID?) -> Bool {
        self.workspaceID == workspaceID && self.workspaceRoot?.standardizedFileURL == root?.standardizedFileURL
    }
}
