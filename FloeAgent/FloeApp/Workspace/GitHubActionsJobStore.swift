// SPDX-License-Identifier: MPL-2.0
//
// GitHubActionsJobStore — durable, file-backed records for IDE GitHub Actions
// runs. A GitHub Actions run continues on GitHub after the app exits, so it
// deliberately does NOT reuse `BackgroundJobStore`: that table marks every
// non-terminal in-process tool job `interrupted` at launch, which would be a
// false claim for a remote CI run. The record here stores no credential and no
// file contents — only identities, SHAs and bounded status text, so a relaunch
// can re-query GitHub honestly.
//
// Writes are staged to a sibling file and atomically replaced, so a crash can
// never leave a half-written record.

import Foundation

enum GitHubActionsJobState: String, Codable, Sendable, CaseIterable {
    case preparing
    case snapshotPublished
    case dispatching
    /// The dispatch succeeded but the run could not yet be uniquely tied to
    /// the snapshot. The record keeps the receipt so a retry can re-associate
    /// without dispatching again.
    case associationPending
    case queued
    case running
    /// The user requested a cancel; the run is not yet confirmed cancelled.
    /// A relaunch keeps reconciling instead of treating the HTTP 202 as done.
    case cancelling
    case completed
    case failed
    case cancelled
    /// A local failure before a run existed; safe to retry from scratch.
    case error

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .error: return true
        default: return false
        }
    }

    /// A remote run may still be alive even though Floe is not polling, so the
    /// UI must not call these states "background running locally".
    var mayHaveLiveRemoteRun: Bool {
        switch self {
        case .dispatching, .associationPending, .queued, .running, .cancelling: return true
        default: return false
        }
    }
}

struct GitHubActionsArtifactRecord: Codable, Sendable, Equatable, Identifiable {
    var id: Int64
    var name: String
    var sizeInBytes: Int64
    var expired: Bool
    var createdAt: Date
    var expiresAt: Date?
    /// SHA-256 of a successful local download, when one happened.
    var downloadedSHA256: String?
    var downloadedRelativePath: String?
    /// The digest GitHub reported for this artifact, when it reported one.
    /// `nil` means the local checksum is checksum-only and not a verified
    /// download.
    var remoteDigest: String? = nil
    /// True only when the downloaded bytes matched a non-empty `remoteDigest`.
    /// A self-computed hash is never recorded as a verified download.
    var downloadVerified: Bool? = nil
}

struct GitHubActionsSnapshotEntryRecord: Codable, Sendable, Equatable {
    var path: String
    var byteCount: Int
    var sha256: String
}

struct GitHubActionsJobRecord: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    /// Opaque, unique per dispatch intent. It is the idempotency key: a
    /// relaunch reconciles a record by this id and never creates a duplicate
    /// request for the same intent.
    var requestID: String
    var workspaceID: UUID?
    var environmentID: String?
    var workspaceRootPath: String?
    var languageID: String
    var role: String
    var repositoryFullName: String
    var owner: String
    var repository: String
    var baseRef: String
    var runBranch: String
    var workflowPath: String?
    /// GitHub's numeric workflow id, resolved before the trigger and persisted
    /// so a relaunch can re-associate without re-resolving the workflow.
    var workflowID: Int64?
    var installsTemplate: Bool
    var expectedArtifactName: String?
    var snapshotCommitSHA: String?
    var snapshotTreeSHA: String?
    var snapshotFiles: [GitHubActionsSnapshotEntryRecord]
    var snapshotTotalBytes: Int
    var baselineRunIDs: [Int64]
    var dispatchedAt: Date?
    var runID: Int64?
    var remoteStatus: String?
    var remoteConclusion: String?
    var remoteHTMLURL: String?
    var state: GitHubActionsJobState
    var lastError: String?
    /// Set when the user requested a cancel. The record stays non-terminal
    /// until GitHub reports the run `cancelled`, so a relaunch keeps checking
    /// instead of treating the HTTP 202 as a finished stop.
    var cancelRequestedAt: Date?
    /// Last time Floe actually sent the cancel request. Durable so a relaunch
    /// resumes the same stop without spamming GitHub, and so a lost response
    /// is retried until the run is terminal.
    var cancelLastAttemptAt: Date?
    var artifacts: [GitHubActionsArtifactRecord]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(), requestID: String, workspaceID: UUID?, environmentID: String?,
        workspaceRootPath: String?,
        languageID: String, role: String, repositoryFullName: String,
        owner: String, repository: String, baseRef: String, runBranch: String,
        workflowPath: String?, workflowID: Int64? = nil,
        installsTemplate: Bool, expectedArtifactName: String?,
        snapshotCommitSHA: String?, snapshotTreeSHA: String?,
        snapshotFiles: [GitHubActionsSnapshotEntryRecord], snapshotTotalBytes: Int,
        baselineRunIDs: [Int64] = [], dispatchedAt: Date? = nil, runID: Int64? = nil,
        remoteStatus: String? = nil, remoteConclusion: String? = nil,
        remoteHTMLURL: String? = nil, state: GitHubActionsJobState = .preparing,
        lastError: String? = nil, cancelRequestedAt: Date? = nil,
        cancelLastAttemptAt: Date? = nil,
        artifacts: [GitHubActionsArtifactRecord] = [],
        createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id; self.requestID = requestID; self.workspaceID = workspaceID
        self.environmentID = environmentID; self.workspaceRootPath = workspaceRootPath
        self.languageID = languageID; self.role = role; self.repositoryFullName = repositoryFullName
        self.owner = owner; self.repository = repository; self.baseRef = baseRef
        self.runBranch = runBranch; self.workflowPath = workflowPath
        self.workflowID = workflowID
        self.installsTemplate = installsTemplate; self.expectedArtifactName = expectedArtifactName
        self.snapshotCommitSHA = snapshotCommitSHA; self.snapshotTreeSHA = snapshotTreeSHA
        self.snapshotFiles = snapshotFiles; self.snapshotTotalBytes = snapshotTotalBytes
        self.baselineRunIDs = baselineRunIDs; self.dispatchedAt = dispatchedAt; self.runID = runID
        self.remoteStatus = remoteStatus; self.remoteConclusion = remoteConclusion
        self.remoteHTMLURL = remoteHTMLURL; self.state = state; self.lastError = lastError
        self.cancelRequestedAt = cancelRequestedAt; self.cancelLastAttemptAt = cancelLastAttemptAt
        self.artifacts = artifacts
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// Result of reading the durable store. `corruptFiles` is empty on a healthy
/// directory; a non-empty list means those files were left untouched and must
/// be surfaced rather than silently skipped.
struct GitHubActionsStoreLoad: Sendable, Equatable {
    let records: [GitHubActionsJobRecord]
    let corruptFiles: [String]
}

actor GitHubActionsJobStore {
    private let directory: URL
    private let fileManager = FileManager.default

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.directory = base
                .appendingPathComponent("FloeAgent", isDirectory: true)
                .appendingPathComponent("GitHubActionsJobs", isDirectory: true)
        }
    }

    /// Merge-safe staging write. The store is the single serialization point
    /// for a record, so a caller that read a record before a long network wait
    /// cannot clobber a newer cancellation intent, run id or downloaded
    /// artifact metadata written in the meantime.
    func save(_ record: GitHubActionsJobRecord) throws {
        try ensureDirectory()
        var updated = record
        if let existing = try? decode(fileURL(for: record.id)) {
            updated = Self.merge(existing: existing, incoming: updated)
        }
        updated.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(updated)
        let destination = fileURL(for: record.id)
        let staging = destination.appendingPathExtension("staging")
        try data.write(to: staging, options: .atomic)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
    }

    /// Monotonic merge. Identity fields are only ever filled in, a set cancel
    /// intent is never cleared, and artifact download metadata survives a
    /// concurrent refresh.
    static func merge(existing: GitHubActionsJobRecord, incoming: GitHubActionsJobRecord) -> GitHubActionsJobRecord {
        var merged = incoming
        merged.runID = incoming.runID ?? existing.runID
        merged.workflowID = incoming.workflowID ?? existing.workflowID
        merged.snapshotCommitSHA = incoming.snapshotCommitSHA ?? existing.snapshotCommitSHA
        merged.snapshotTreeSHA = incoming.snapshotTreeSHA ?? existing.snapshotTreeSHA
        merged.dispatchedAt = incoming.dispatchedAt ?? existing.dispatchedAt
        if incoming.baselineRunIDs.isEmpty { merged.baselineRunIDs = existing.baselineRunIDs }
        merged.remoteStatus = incoming.remoteStatus ?? existing.remoteStatus
        merged.remoteConclusion = incoming.remoteConclusion ?? existing.remoteConclusion
        merged.remoteHTMLURL = incoming.remoteHTMLURL ?? existing.remoteHTMLURL
        // Terminal observation is monotonic for the same immutable run: a stale
        // save that read the record while it was still running (for example an
        // artifact list that loaded first and saved after a poll completed)
        // must not resurrect `running`/`cancelling` over a terminal state. The
        // run id is immutable, so a matching id identifies the same run.
        if let existingRun = existing.runID, existingRun == incoming.runID,
           existing.state.isTerminal, !incoming.state.isTerminal {
            merged.state = existing.state
            merged.remoteStatus = existing.remoteStatus ?? incoming.remoteStatus
            merged.remoteConclusion = existing.remoteConclusion ?? incoming.remoteConclusion
            merged.remoteHTMLURL = existing.remoteHTMLURL ?? incoming.remoteHTMLURL
        }
        merged.cancelRequestedAt = incoming.cancelRequestedAt ?? existing.cancelRequestedAt
        switch (incoming.cancelLastAttemptAt, existing.cancelLastAttemptAt) {
        case let (incoming?, existing?): merged.cancelLastAttemptAt = max(incoming, existing)
        case let (nil, existing?): merged.cancelLastAttemptAt = existing
        case let (incoming?, nil): merged.cancelLastAttemptAt = incoming
        case (nil, nil): merged.cancelLastAttemptAt = nil
        }
        if merged.cancelRequestedAt != nil, !merged.state.isTerminal, merged.state != .cancelling {
            merged.state = .cancelling
        }
        merged.artifacts = Self.mergeArtifacts(existing: existing.artifacts, incoming: incoming.artifacts)
        return merged
    }

    private static func mergeArtifacts(
        existing: [GitHubActionsArtifactRecord],
        incoming: [GitHubActionsArtifactRecord]
    ) -> [GitHubActionsArtifactRecord] {
        var byID: [Int64: GitHubActionsArtifactRecord] = [:]
        for artifact in existing { byID[artifact.id] = artifact }
        for artifact in incoming {
            guard var merged = byID[artifact.id] else {
                byID[artifact.id] = artifact
                continue
            }
            merged = artifact
            merged.downloadedSHA256 = artifact.downloadedSHA256 ?? byID[artifact.id]?.downloadedSHA256
            merged.downloadedRelativePath = artifact.downloadedRelativePath ?? byID[artifact.id]?.downloadedRelativePath
            merged.remoteDigest = artifact.remoteDigest ?? byID[artifact.id]?.remoteDigest
            merged.downloadVerified = artifact.downloadVerified ?? byID[artifact.id]?.downloadVerified
            byID[artifact.id] = merged
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    func record(id: UUID) throws -> GitHubActionsJobRecord? {
        let url = fileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try decode(url)
    }

    /// Idempotency lookup for a dispatch intent. Reusing a request id must
    /// return the original record rather than creating a second request.
    func record(requestID: String) throws -> GitHubActionsJobRecord? {
        try load().records.first { $0.requestID == requestID }
    }

    /// Reads every record and reports files that could not be decoded instead
    /// of silently dropping them.
    func load() throws -> GitHubActionsStoreLoad {
        try ensureDirectory()
        let urls = try fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
        var records: [GitHubActionsJobRecord] = []
        var corrupt: [String] = []
        for url in urls {
            do {
                records.append(try decode(url))
            } catch {
                corrupt.append(url.lastPathComponent)
            }
        }
        return GitHubActionsStoreLoad(
            records: records.sorted { $0.createdAt > $1.createdAt },
            corruptFiles: corrupt.sorted()
        )
    }

    func all() throws -> [GitHubActionsJobRecord] {
        try load().records
    }

    /// Records for one workspace, newest first.
    func records(workspaceID: UUID) throws -> [GitHubActionsJobRecord] {
        try load().records.filter { $0.workspaceID == workspaceID }
    }

    func delete(id: UUID) throws {
        let url = fileURL(for: id)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    /// Records whose remote run may still be alive; used at launch to mark
    /// that Floe is no longer polling without claiming the run stopped.
    func liveRemoteRecords() throws -> [GitHubActionsJobRecord] {
        try load().records.filter { $0.state.mayHaveLiveRemoteRun }
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func decode(_ url: URL) throws -> GitHubActionsJobRecord {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitHubActionsJobRecord.self, from: data)
    }

    private func ensureDirectory() throws {
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

/// The store is the single serialization point for the engine's durable
/// records. Its actor-isolated methods witness the engine protocol's async
/// requirements.
extension GitHubActionsJobStore: GitHubActionsJobStoring {}

// MARK: - Recovery reconciliation

/// The bounded, network-free decision for one persisted record at launch or
/// foreground. It never says "resubmit": a request whose dispatch outcome is
/// unknown is re-queried by its snapshot identity, and only an explicit user
/// action may create a new dispatch.
enum IDEGitHubActionsRecoveryAction: Sendable, Equatable {
    /// The run id is known; query it directly.
    case queryKnownRun(runID: Int64)
    /// The snapshot was published and the trigger may have been sent, but no
    /// run id was saved. Re-associate by commit SHA/baseline only.
    case reAssociateSnapshot(commitSHA: String)
    /// No snapshot exists (crash before publish). Never auto-resubmit.
    case awaitingManualRedispatch
    /// A finished run has an artifact that was never downloaded. Retrieval is
    /// resumable and must not overwrite a user file without consent.
    case resumeArtifactDownload(artifactID: Int64)
}

enum IDEGitHubActionsReconciler {
    /// Ordered actions for a recovered record. A terminal record yields only
    /// artifact retrieval; a cancel-waiting record is queried until GitHub
    /// reports `cancelled`.
    static func actions(for record: GitHubActionsJobRecord) -> [IDEGitHubActionsRecoveryAction] {
        if record.state.isTerminal {
            guard record.state == .completed else { return [] }
            return record.artifacts
                .filter { !$0.expired && $0.downloadedRelativePath == nil }
                .map { .resumeArtifactDownload(artifactID: $0.id) }
        }
        if let runID = record.runID {
            return [.queryKnownRun(runID: runID)]
        }
        if let commit = record.snapshotCommitSHA, !commit.isEmpty,
           record.workflowID != nil, record.dispatchedAt != nil {
            // Covers `.snapshotPublished`, `.dispatching` and
            // `.associationPending`: the trigger may or may not have landed,
            // so the snapshot identity is the only safe key. The persisted
            // baseline forbids adopting a run that already existed.
            return [.reAssociateSnapshot(commitSHA: commit)]
        }
        return [.awaitingManualRedispatch]
    }

    /// True when at least one reconciliation step can make remote progress.
    /// A record with no snapshot (crash before publish) is deliberately
    /// excluded from the poller: it must never be resubmitted automatically
    /// and would otherwise loop forever.
    static func hasActionableStep(_ record: GitHubActionsJobRecord) -> Bool {
        actions(for: record).contains { action in
            if case .awaitingManualRedispatch = action { return false }
            return true
        }
    }
}
