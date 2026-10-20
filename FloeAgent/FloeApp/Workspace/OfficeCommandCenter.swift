// SPDX-License-Identifier: MPL-2.0
// FloeApp — document.office.edit host: the single authority for engine-level
// Office edits used by the visible editor and by agent tools.
//
// The center routes every proposal through the live editor session that owns
// the document (registered by `OfficeFileSession`): dispatch, working-copy
// flush, saved-package verification and the CAS commit all happen inside that
// one session. Ownership, exact-SHA binding, single-use UI grants, per-document
// transaction serialization and idempotent replay are enforced here, the same
// way `CadDocumentCenter` does for drawings. If the document is not open in the
// engine editor, engine actions are refused with a precise hint instead of
// pretending a package-level rewrite is an engine edit.

import Foundation
import FloeCore
import FloeTools
import FloeDocuments
import FloeWorkbench
import FloeWorkspace
#if canImport(UIKit)
import UIKit
#endif
#if canImport(WebKit)
import WebKit
#endif
#if canImport(FloeOfficeNative)
import FloeOfficeNative
#endif

/// Registers the Office edit tool with both the compile-time catalog and the
/// runtime runner registry; both are required for discovery/execution.
@MainActor
func registerOfficeEditTools(center: OfficeCommandCenter, registry: ToolRunnerRegistry = .shared) {
    ToolCatalog.register(OfficeEditTool.self)
    registry.register(OfficeEditTool(host: center, workspaceRoot: WorkspaceCenter.toolRootProvider))
}

/// Write-ahead journal for a committed Office engine batch. The entry is
/// PREPARED with the verified post-edit SHA and the pre-batch snapshot before
/// the file commit, then marked committed. Retry reconciliation only trusts a
/// prepared entry when the file's current SHA equals the expected SHA, so a
/// crash between commit and completion is recoverable and an uncertain state
/// fails closed. Package-private by design; no private details are logged.
final class OfficeCommittedBatchJournal: @unchecked Sendable {
    struct Entry: Codable, Sendable {
        var batchID: String
        var documentID: String
        var workspacePath: String?
        var operationID: String
        var expectedSHA256: String
        var snapshotPath: String?
        var snapshotSHA256: String?
        var commands: [String]
        var preparedAt: Date
        var committedAt: Date?
        var note: String?

        var isCommitted: Bool { committedAt != nil }
    }

    static let shared = OfficeCommittedBatchJournal()

    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "floe.office.committed-batches")
    private let fileURL: URL
    private var loaded = false
    private var entries: [String: Entry] = [:]
    private let maximumEntries = 100

    private init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("FloeAgent/Office", isDirectory: true)
        if let root {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            fileURL = root.appendingPathComponent("committed-batches.json")
        } else {
            fileURL = URL(fileURLWithPath: "/dev/null")
        }
    }

    /// Journal a batch before the file commit. Throws when the durable write
    /// fails so the caller refuses to commit (no unrecoverable gap).
    func prepare(_ entry: Entry) throws {
        try mutate { staged in staged[entry.batchID] = entry }
    }

    /// Mark the prepared entry committed after the CAS commit succeeded.
    @discardableResult
    func complete(batchID: String, committedAt: Date = Date()) throws -> Entry? {
        var updated: Entry?
        try mutate { staged in
            guard var entry = staged[batchID] else { return }
            entry.committedAt = committedAt
            staged[batchID] = entry
            updated = entry
        }
        return updated
    }

    func entry(batchID: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        return entries[batchID]
    }

    /// Most recent COMMITTED entry for a document (revert after reopen).
    func latestCommitted(documentID: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        return entries.values
            .filter { $0.documentID == documentID && $0.isCommitted }
            .max { ($0.committedAt ?? .distantPast) < ($1.committedAt ?? .distantPast) }
    }

    func remove(batchID: String) {
        try? mutate { staged in staged[batchID] = nil }
    }

    private func mutate(_ body: (inout [String: Entry]) -> Void) throws {
        let url = fileURL
        try writeQueue.sync {
            lock.lock(); defer { lock.unlock() }
            loadLocked()
            var staged = entries
            body(&staged)
            if staged.count > maximumEntries {
                let ordered = staged.sorted { $0.value.preparedAt > $1.value.preparedAt }
                staged = Dictionary(uniqueKeysWithValues: ordered.prefix(maximumEntries).map { ($0.key, $0.value) })
            }
            guard fileURL.path != "/dev/null" else {
                throw FloeError.storageCorrupted("Office commit journal is unavailable")
            }
            let data = try JSONEncoder().encode(staged)
            try data.write(to: url, options: .atomic)
            entries = staged
        }
    }

    private func loadLocked() {
        guard !loaded else { return }
        loaded = true
        guard fileURL.path != "/dev/null", let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = decoded
    }
}

/// Reconciliation of a journaled (possibly prepared) batch against the actual
/// file bytes. Never infers a commit from ordering.
enum OfficeBatchReconciliation: Equatable {
    case committed
    case preparedNotCommitted
    case unknown

    static func decide(entry: OfficeCommittedBatchJournal.Entry, currentFileSHA: String?) -> Self {
        guard let current = currentFileSHA?.lowercased() else { return .unknown }
        if current == entry.expectedSHA256.lowercased() {
            // The exact expected bytes are on disk: the commit landed even if
            // the completion marker was lost.
            return .committed
        }
        if entry.isCommitted { return .unknown }
        return .preparedNotCommitted
    }
}

/// Process-wide serialization for service-owned automatic Office sessions.
///
/// The pinned engine is ONE shared runtime (single web-server and document
/// workspace). Concurrent hidden sessions compete for it and its teardown can
/// abort; automatic execution therefore holds one bounded lease at a time.
/// The wait is bounded and honors the operation's cancellation token so a
/// cancelled job leaves at its safe pre-effect boundary instead of queueing
/// forever. A session whose close was not acknowledged quarantines the gate:
/// the engine may still hold a working copy, so no further shared-engine
/// automatic work is admitted until the app restarts. The interactive editor
/// is untouched (it owns its visible session).
actor OfficeAutomaticExecutionGate {
    static let shared = OfficeAutomaticExecutionGate()

    enum Outcome: Sendable, Equatable {
        case acquired
        case cancelledBeforeStart
        case timedOut
        case hostQuarantined(String)
    }

    private var busy = false
    private var quarantineReason: String?

    /// Bounded, cancellation-aware lease acquisition that honors BOTH the
    /// operation token and Task cancellation. A cancelled sleep ends the wait
    /// immediately (never a busy spin to the deadline).
    func acquire(cancellation: CancellationToken? = nil, timeout: TimeInterval = 120) async -> Outcome {
        if let quarantineReason { return .hostQuarantined(quarantineReason) }
        if cancellation?.isCancelled == true || Task.isCancelled { return .cancelledBeforeStart }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let quarantineReason { return .hostQuarantined(quarantineReason) }
            if cancellation?.isCancelled == true || Task.isCancelled { return .cancelledBeforeStart }
            if !busy {
                busy = true
                return .acquired
            }
            if Date() >= deadline { return .timedOut }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return .cancelledBeforeStart
            }
        }
    }

    /// Releases the lease. `closeAcknowledged == false` quarantines the gate:
    /// the engine may still hold a working copy, so no further shared-engine
    /// automatic session is admitted until the app restarts.
    func release(closeAcknowledged: Bool, failureReason: String? = nil) {
        if !closeAcknowledged {
            quarantineReason = failureReason ?? "a previous engine session was not acknowledged"
        }
        busy = false
    }

    /// Quarantines the gate after a session reported an unacknowledged close
    /// (called by the session itself so every path is covered).
    func markHostQuarantined(reason: String) {
        quarantineReason = reason
    }

    var isQuarantined: Bool { quarantineReason != nil }

    #if DEBUG
    /// Test-only reset (the DEBUG App test bundle); production keeps the
    /// quarantine sticky until the app restarts.
    func resetForTesting() {
        quarantineReason = nil
        busy = false
    }
    #endif
}

actor OfficeCommandCenter: OfficeCommandHost {
    struct Resolved {
        var root: URL
        var relativePath: String
        var url: URL
        var format: OfficeDocumentFormat

        /// Gate key: canonical workspace path + relative document.
        var key: String { "\(root.path)|\(relativePath)" }
    }

    private var proposals: [UUID: OfficeCommandProposal] = [:]
    private var proposalAccess: [UUID: OfficeCommandAccess] = [:]
    private var proposalBindings: [UUID: OfficeProposalSessionBinding] = [:]
    nonisolated static let proposalsDidChange = Notification.Name("FloeOfficeProposalsDidChange")
    private let grants = OfficeProposalGrantStore()
    private var appliedReceipts: [String: OfficeCommandReceipt] = [:]
    private var requestPayloads: [String: String] = [:]
    private var gates: [String: CadDocumentGate] = [:]
    private let maximumDocumentBytes = 128 * 1024 * 1024
    /// Authorized automatic copy execution (service-owned engine session).
    private let automaticExecutor: OfficeAutomaticExecutor

    init() {
        automaticExecutor = OfficeAutomaticExecutor(
            factory: OfficeServiceNativeSessionFactory.makeDefault())
    }

    private func gate(for key: String) -> CadDocumentGate {
        if let existing = gates[key] { return existing }
        let gate = CadDocumentGate()
        gates[key] = gate
        return gate
    }

    private func withDocumentGate<T>(_ key: String, _ body: () async throws -> T) async throws -> T {
        let gate = gate(for: key)
        try await gate.acquire()
        do {
            let result = try await body()
            await gate.release()
            return result
        } catch {
            await gate.release()
            throw error
        }
    }

    private func resolve(documentID: String, access: OfficeCommandAccess) throws -> Resolved {
        guard let workspace = access.workspacePath, !workspace.isEmpty else {
            throw FloeError.notFound("Office workspace")
        }
        let root = URL(fileURLWithPath: workspace, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        var relative = documentID
        if relative.hasPrefix("/") {
            // An absolute path is only accepted when its CANONICAL location is
            // inside the canonical workspace root (aliases/symlinks cannot
            // redefine authority).
            let canonical = URL(fileURLWithPath: relative).standardizedFileURL.resolvingSymlinksInPath()
            guard canonical.path.hasPrefix(root.path + "/") else {
                throw FloeError.validationFailed("Office document must be inside the task workspace")
            }
            relative = String(canonical.path.dropFirst(root.path.count + 1))
        }
        guard let format = OfficeDocumentFormat(fileExtension: (relative as NSString).pathExtension) else {
            throw FloeError.validationFailed("document.office.edit supports .docx, .xlsx and .pptx")
        }
        // Validated resolution: `..` traversal and symlink escapes are refused
        // by the same guard every workspace tool uses; the model-supplied path
        // can never widen workspace authority.
        let guardResolver = WorkspacePathGuard(
            rootURL: root,
            maxReadBytes: maximumDocumentBytes,
            maxWriteBytes: maximumDocumentBytes,
            mounts: WorkspaceMountRegistry.shared.mounts(for: root)
        )
        let url = try guardResolver.resolve(relative)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, Int64(values.fileSize ?? 0) <= Int64(maximumDocumentBytes) else {
            throw FloeError.notFound("Office document \(relative)")
        }
        return Resolved(root: root, relativePath: relative, url: url, format: format)
    }

    /// The live editor session for this exact workspace document, when one is
    /// registered. A session recorded for one task is never reachable from
    /// another task; a caller presenting a chat origin without its task
    /// identity is refused outright.
    private func liveSession(_ resolved: Resolved,
                             access: OfficeCommandAccess) async throws -> OfficeFileSession? {
        if access.ownerKind == "chat", access.conversationID == nil, access.ownerID == nil {
            throw FloeError.unauthorized
        }
        let session = await MainActor.run {
            OfficeLiveSessionRegistry.shared.session(root: resolved.root,
                                                     relativePath: resolved.relativePath)
        }
        guard let session else { return nil }
        let owner = await MainActor.run { session.liveOwnerConversationID }
        if let owner {
            guard access.conversationID == owner else { throw FloeError.unauthorized }
        }
        return session
    }

    private func requireLiveSession(_ resolved: Resolved,
                                    access: OfficeCommandAccess) async throws -> OfficeFileSession {
        guard let session = try await liveSession(resolved, access: access) else {
            throw FloeError.validationFailed(
                "Open \(resolved.relativePath) in the Office editor first; engine edits run in the live document session")
        }
        return session
    }

    // MARK: - OfficeCommandHost

    func authorizeAccess(_ access: OfficeCommandAccess) async throws {
        guard let workspace = access.workspacePath, !workspace.isEmpty else {
            throw FloeError.unauthorized
        }
        // A chat-origin call must present its task identity; a caller cannot
        // claim workspace ownership while carrying chat-only context.
        if access.ownerKind == "chat", access.conversationID == nil, access.ownerID == nil {
            throw FloeError.unauthorized
        }
    }

    func status(documentID: String, access: OfficeCommandAccess) async throws -> OfficeLiveStatus {
        let resolved = try resolve(documentID: documentID, access: access)
        if let session = try await liveSession(resolved, access: access) {
            do {
                let live = try await session.liveEngineStatus()
                return OfficeLiveStatus(documentID: resolved.relativePath,
                                        format: resolved.format.rawValue,
                                        revisionSHA256: live.sha256,
                                        liveSession: true,
                                        editable: live.editable,
                                        readOnlyReason: live.unavailableReason,
                                        hasUnsavedChanges: live.unsavedChanges)
            } catch {
                // Fall through to the file-only status below.
            }
        }
        let sha = try FloeDigest.sha256Hex(ofFileAt: resolved.url)
        return OfficeLiveStatus(documentID: resolved.relativePath,
                                format: resolved.format.rawValue,
                                revisionSHA256: sha,
                                liveSession: false,
                                editable: false,
                                readOnlyReason: "Open the document in the editor to apply engine edits",
                                hasUnsavedChanges: nil)
    }

    func prepareProposal(documentID: String, baseSHA256: String, summary: String,
                         commandsJSON: String, access: OfficeCommandAccess) async throws -> OfficeCommandProposal {
        let resolved = try resolve(documentID: documentID, access: access)
        let commands = try OfficeCommandCodec.decode(commandsJSON)
        guard !commands.isEmpty else {
            throw FloeError.validationFailed("commands must contain 1...64 entries")
        }
        for command in commands where command.format != resolved.format {
            throw OfficeEngineCommandError.unsupportedFormat(command.id, resolved.format.rawValue)
        }
        let session = try await requireLiveSession(resolved, access: access)
        guard let binding = await session.proposalReviewBinding else { throw FloeError.unauthorized }
        let live = try await session.liveEngineStatus()
        guard live.editable else {
            throw FloeError.validationFailed(live.unavailableReason
                ?? "The document is not editable (preview or read-only); no proposal was created")
        }
        guard !live.unsavedChanges else {
            throw FloeError.validationFailed(
                "The editor has unsaved changes; save or discard them before proposing an engine edit")
        }
        guard live.sha256.lowercased() == baseSHA256.lowercased() else {
            throw FloeError.validationFailed(
                "The document changed after it was read (expected \(baseSHA256.prefix(12))…, current \(live.sha256.prefix(12))…); read it again")
        }
        // Selection-relative commands bind the live selection identity; when
        // the engine cannot expose one, the command is gated here instead of
        // being applied against an unknown target.
        var fingerprint: String?
        if commands.contains(where: \.requiresSelectionFingerprint) {
            guard let captured = await session.liveSelectionFingerprint() else {
                throw FloeError.validationFailed(
                    "The current selection cannot be identified in this engine build, so this selection-relative edit is unavailable. "
                        + "Apply it from the editor UI or use an explicit-cell command.")
            }
            fingerprint = captured
        }
        let targetSummary = commands.map(\.targetSummary).joined(separator: "; ")
        let proposal = OfficeCommandProposal(documentID: resolved.relativePath,
                                             format: resolved.format.rawValue,
                                             baseSHA256: baseSHA256.lowercased(),
                                             summary: summary,
                                             commandsJSON: commandsJSON,
                                             expectations: OfficeCommandCodec.expectations(commands),
                                             selectionFingerprint: fingerprint,
                                             targetSummary: targetSummary)
        guard await session.proposalReviewBinding == binding else { throw FloeError.unauthorized }
        proposalAccess[proposal.id] = access
        proposalBindings[proposal.id] = binding
        return proposal
    }

    func storeProposal(_ proposal: OfficeCommandProposal) async throws {
        guard proposalAccess[proposal.id] != nil, proposalBindings[proposal.id] != nil else {
            throw FloeError.unauthorized
        }
        proposals[proposal.id] = proposal
        NotificationCenter.default.post(name: Self.proposalsDidChange, object: nil)
    }

    func loadProposal(id: UUID, access: OfficeCommandAccess) async throws -> OfficeCommandProposal? {
        guard let recorded = proposalAccess[id], recorded == access else { return nil }
        return proposals[id]
    }

    func verifyProposalBinding(_ proposal: OfficeCommandProposal, documentID: String,
                               access: OfficeCommandAccess) async throws {
        guard let recorded = proposalAccess[proposal.id], recorded == access else {
            throw FloeError.unauthorized
        }
        let resolved = try resolve(documentID: documentID, access: access)
        guard resolved.relativePath == proposal.documentID else {
            throw FloeError.validationFailed(
                "proposal \(proposal.id.uuidString) belongs to \(proposal.documentID), not \(resolved.relativePath)")
        }
    }

    func removeProposal(id: UUID) async throws {
        proposals.removeValue(forKey: id)
        proposalAccess.removeValue(forKey: id)
        proposalBindings.removeValue(forKey: id)
        NotificationCenter.default.post(name: Self.proposalsDidChange, object: nil)
    }

    func consumeGrant(grantID: String, proposalID: UUID, documentID: String,
                      sha256: String) async -> OfficeGrantDecision {
        await grants.consume(grantID: grantID, proposalID: proposalID,
                             documentID: documentID, sha256: sha256)
    }

    func apply(proposal: OfficeCommandProposal, grantID: String, requestID: String,
               access: OfficeCommandAccess) async throws -> OfficeCommandReceipt {
        let resolved = try resolve(documentID: proposal.documentID, access: access)
        return try await withDocumentGate(resolved.key) {
            let payload = proposal.baseSHA256 + "|" + proposal.commandsJSON
            let key = replayKey(action: "apply", access: access, documentID: resolved.relativePath,
                                requestID: requestID, payload: payload)
            if let replay = appliedReceipts[key] {
                var receipt = replay
                receipt.replay = true
                return receipt
            }
            // Reconcile across a restart/crash: the durable journal is the
            // receipt of record when the in-memory map is gone. Only a prepared
            // or completed entry whose exact expected SHA matches the file
            // counts as committed; anything else fails closed.
            if let journaled = OfficeCommittedBatchJournal.shared.entry(batchID: proposal.id.uuidString),
               journaled.documentID == resolved.relativePath,
               let current = try? FloeDigest.sha256Hex(ofFileAt: resolved.url),
               OfficeBatchReconciliation.decide(entry: journaled, currentFileSHA: current) == .committed {
                let receipt = OfficeCommandReceipt(documentID: resolved.relativePath,
                                                   sha256: journaled.expectedSHA256,
                                                   commands: journaled.commands,
                                                   verified: ["recovered from the committed batch journal"],
                                                   saved: true, replay: true,
                                                   note: "recovered committed outcome")
                appliedReceipts[key] = receipt
                return receipt
            }
            if let existing = requestPayloads[key], existing != payload {
                throw FloeError.validationFailed("request_id was already used with different content")
            }
            requestPayloads[key] = payload
            let session = try await requireLiveSession(resolved, access: access)
            guard proposals[proposal.id] == proposal, proposalAccess[proposal.id] == access,
                  let binding = proposalBindings[proposal.id],
                  await session.proposalReviewBinding == binding else { throw FloeError.unauthorized }
            switch await grants.reserve(grantID: grantID, proposalID: proposal.id,
                                        documentID: resolved.relativePath,
                                        sha256: proposal.baseSHA256) {
            case .reserved:
                break
            case .unknownGrant, .documentMismatch:
                throw FloeError.unauthorized
            case .expired:
                throw FloeError.validationFailed("The confirmation grant expired; ask the user to confirm again.")
            case .alreadyConsumed, .alreadyReserved:
                throw FloeError.validationFailed("The confirmation grant was already used.")
            case .shaMismatch(let expected, let actual):
                throw FloeError.validationFailed(
                    "The document content changed (expected \(expected.prefix(12))…, actual \(actual.prefix(12))…); regenerate the proposal.")
            }
            do {
                let commands = try OfficeCommandCodec.decode(proposal.commandsJSON)
                let result = try await session.applyEngineCommands(
                    commands, expectedSelectionFingerprint: proposal.selectionFingerprint,
                    batchID: proposal.id.uuidString, expectedSHA256: proposal.baseSHA256,
                    expectedProposalBinding: binding)
                let receipt = OfficeCommandReceipt(documentID: resolved.relativePath,
                                                   sha256: result.sha256,
                                                   commands: commands.map(\.id),
                                                   verified: result.facts,
                                                   saved: true)
                _ = await grants.commitReservation(grantID: grantID)
                appliedReceipts[key] = receipt
                return receipt
            } catch {
                await grants.releaseReservation(grantID: grantID)
                throw error
            }
        }
    }

    func export(documentID: String, relativeOutput: String,
                access: OfficeCommandAccess) async throws -> OfficeExportReceipt {
        let resolved = try resolve(documentID: documentID, access: access)
        var output = relativeOutput
        if output.hasPrefix("/") {
            guard output.hasPrefix(resolved.root.path + "/") else {
                throw FloeError.validationFailed("Export path must be inside the workspace")
            }
            output = String(output.dropFirst(resolved.root.path.count + 1))
        }
        let outputURL = resolved.root.appendingPathComponent(output)
        guard outputURL.standardizedFileURL != resolved.url.standardizedFileURL else {
            throw FloeError.validationFailed("Export path must differ from the source document")
        }
        // The exported copy is the saved document: unsaved editor changes must
        // be saved first, never silently left out of a "current" export.
        if let session = try await liveSession(resolved, access: access) {
            let live = try await session.liveEngineStatus()
            if live.unsavedChanges {
                throw FloeError.validationFailed(
                    "The editor has unsaved changes; save them before exporting")
            }
        }
        // Bounded copy + digest verification; the source is never modified.
        let values = try resolved.url.resourceValues(forKeys: [.fileSizeKey])
        guard Int64(values.fileSize ?? 0) <= Int64(maximumDocumentBytes) else {
            throw FloeError.validationFailed("Document is too large to export")
        }
        let data = try Data(contentsOf: resolved.url, options: [.mappedIfSafe])
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let temporary = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".floe-office-export-\(UUID().uuidString).\(outputURL.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        let verified = try OfficeOutputSnapshot.capture(url: temporary)
        guard verified.sha256 == FloeDigest.sha256Hex(data) else {
            throw FloeError.validationFailed("Exported copy failed digest verification")
        }
        // Export only ever writes a NEW file. An existing file is preserved
        // unless it is byte-identical to the verified export (an idempotent
        // re-run); a different file is NEVER replaced, and the commit below
        // fails instead of replacing if a concurrent writer appears between
        // the check and the move.
        if FileManager.default.fileExists(atPath: outputURL.path) {
            let existing = (try? FloeDigest.sha256Hex(ofFileAt: outputURL))?.lowercased()
            guard existing == verified.sha256.lowercased() else {
                throw FloeError.validationFailed(
                    "An existing file with different content is already at \(output); "
                        + "export never overwrites it. Choose a different output name.")
            }
            return OfficeExportReceipt(documentID: resolved.relativePath, relativePath: output,
                                       sha256: verified.sha256, byteCount: data.count,
                                       note: "Identical verified copy already exported; the existing file was preserved")
        }
        do {
            try FileManager.default.moveItem(at: temporary, to: outputURL)
        } catch {
            guard FileManager.default.fileExists(atPath: outputURL.path) else {
                throw FloeError.validationFailed(
                    "The export could not be committed: \(error.localizedDescription)")
            }
            // A concurrent writer appeared after the existence check: the
            // move refused (never replaced), so the file is preserved.
            throw FloeError.validationFailed(
                "An existing file with different content is already at \(output); "
                    + "export never overwrites it. Choose a different output name.")
        }
        return OfficeExportReceipt(documentID: resolved.relativePath, relativePath: output,
                                   sha256: verified.sha256, byteCount: data.count,
                                   note: "Source document unchanged")
    }

    // MARK: - Authorized automatic copy execution (T4)

    /// Runs a runtime-approved apply as an isolated verified copy through a
    /// service-owned engine session; the original document is only read.
    /// The tool already consumed the single-use runtime authority for the
    /// exact call; this method performs the execution and verification.
    func applyAutomatic(proposal: OfficeCommandProposal,
                        authorization: OfficeAutomaticAuthorization,
                        relativeOutput: String?,
                        requestID: String,
                        access: OfficeCommandAccess) async throws -> OfficeAutomaticReceipt {
        try await applyAutomatic(proposal: proposal, authorization: authorization,
                                 relativeOutput: relativeOutput, requestID: requestID,
                                 access: access, cancellation: nil)
    }

    func applyAutomatic(proposal: OfficeCommandProposal,
                        authorization: OfficeAutomaticAuthorization,
                        relativeOutput: String?,
                        requestID: String,
                        access: OfficeCommandAccess,
                        cancellation: CancellationToken?) async throws -> OfficeAutomaticReceipt {
        // One shared engine runtime: serialize service-owned automatic
        // sessions with a bounded, cancellation-aware lease and release only
        // after the session closed and acknowledged.
        switch await OfficeAutomaticExecutionGate.shared.acquire(cancellation: cancellation) {
        case .acquired:
            break
        case .cancelledBeforeStart:
            throw FloeError.cancelled
        case .timedOut:
            throw OfficeServiceSessionFailure(
                reason: "another automatic Office session is still running; try again shortly")
        case .hostQuarantined(let reason):
            throw OfficeServiceSessionFailure(
                reason: "shared automatic engine work is suspended after an unacknowledged session close: \(reason)")
        }
        do {
            let receipt = try await automaticExecutor.execute(proposal: proposal,
                                                              authorization: authorization,
                                                              relativeOutput: relativeOutput,
                                                              requestID: requestID,
                                                              access: access,
                                                              cancellation: cancellation)
            await OfficeAutomaticExecutionGate.shared.release(closeAcknowledged: true)
            return receipt
        } catch {
            let unsafe = (error as? OfficeAutomaticExecutionError)?.isUnsafeResourceState == true
            await OfficeAutomaticExecutionGate.shared.release(
                closeAcknowledged: !unsafe,
                failureReason: (error as? LocalizedError)?.errorDescription)
            throw error
        }
    }

    // MARK: - UI confirmation path

    /// Trusted UI path: the editor mints a single-use grant after the user
    /// accepts a pending proposal, then applies it.
    func issueUserGrant(for proposal: OfficeCommandProposal) async -> String {
        await grants.issueGrant(proposal: proposal)
    }

    func pendingProposals(documentID: String, access: OfficeCommandAccess) -> [OfficeCommandProposal] {
        proposals.values.filter { proposal in
            proposal.documentID == documentID && proposalAccess[proposal.id] == access
        }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Trusted editor UI: every pending proposal for the open document,
    /// regardless of which task proposed it. The UI shows the exact document
    /// and target summary before the user accepts; apply still enforces the
    /// recorded owner access.
    func pendingProposals(documentID: String) -> [OfficeCommandProposal] {
        proposals.values.filter { $0.documentID == documentID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Trusted UI query: no cross-workspace filename match, no stale controller.
    func pendingProposals(binding: OfficeProposalSessionBinding) async -> [OfficeCommandProposal] {
        let candidates = proposals.values.filter { proposalBindings[$0.id] == binding }
        guard let first = candidates.first, let access = proposalAccess[first.id],
              let resolved = try? resolve(documentID: first.documentID, access: access),
              let session = try? await requireLiveSession(resolved, access: access),
              await session.proposalReviewBinding == binding,
              let live = try? await session.liveEngineStatus(), live.editable,
              !live.unsavedChanges,
              await session.proposalReviewBinding == binding else { return [] }
        return candidates.filter {
            proposals[$0.id] == $0 && proposalBindings[$0.id] == binding
                && $0.baseSHA256.lowercased() == live.sha256.lowercased()
        }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func discardProposal(id: UUID, expectedBinding: OfficeProposalSessionBinding) async throws {
        guard proposalBindings[id] == expectedBinding,
              let proposal = proposals[id], let access = proposalAccess[id],
              let resolved = try? resolve(documentID: proposal.documentID, access: access),
              let session = try? await requireLiveSession(resolved, access: access),
              await session.proposalReviewBinding == expectedBinding else { throw FloeError.unauthorized }
        discardProposal(id: id)
    }

    /// The conversation that proposed this proposal, for the adopt/reject
    /// notification. Nil for workspace-originated proposals.
    func proposalOwnerConversation(proposalID: UUID) -> UUID? {
        proposalAccess[proposalID]?.conversationID
    }

    func discardProposal(id: UUID) {
        proposals.removeValue(forKey: id)
        proposalAccess.removeValue(forKey: id)
        proposalBindings.removeValue(forKey: id)
        NotificationCenter.default.post(name: Self.proposalsDidChange, object: nil)
    }

    @discardableResult
    func approveAndApply(proposal: OfficeCommandProposal,
                         expectedBinding: OfficeProposalSessionBinding? = nil) async throws -> OfficeCommandReceipt {
        guard proposals[proposal.id] == proposal, let access = proposalAccess[proposal.id],
              let binding = proposalBindings[proposal.id],
              expectedBinding == nil || expectedBinding == binding else { throw FloeError.unauthorized }
        let grant = await grants.issueGrant(proposal: proposal)
        let receipt = try await apply(proposal: proposal, grantID: grant,
                                      requestID: "ui-\(proposal.id.uuidString)", access: access)
        try await removeProposal(id: proposal.id)
        return receipt
    }

    private func replayKey(action: String, access: OfficeCommandAccess, documentID: String,
                           requestID: String, payload: String) -> String {
        [action, access.environmentID ?? "-", access.workspacePath ?? "-",
         access.ownerKind ?? "-", access.ownerID?.uuidString ?? "-",
         documentID, requestID, payload].joined(separator: "|")
    }
}

// MARK: - Service-owned engine session (authorized automatic copy execution)

/// Builds the service-owned session used by authorized automatic execution.
/// A build without the pinned engine framework keeps an explicit unavailable
/// factory so the executor reports an honest failure instead of a fabricated
/// edit.
enum OfficeServiceNativeSessionFactory {
    static func makeDefault() -> any OfficeServiceEngineSessionFactory {
        #if canImport(UIKit) && canImport(WebKit) && canImport(FloeOfficeNative)
        return OfficeServiceNativeSessionFactoryImpl()
        #else
        return OfficeServiceUnavailableSessionFactory()
        #endif
    }
}

struct OfficeServiceUnavailableSessionFactory: OfficeServiceEngineSessionFactory {
    struct Unavailable: LocalizedError {
        var errorDescription: String? {
            "The pinned Office engine is not linked in this build; automatic engine edits are unavailable."
        }
    }
    func openServiceSession(workingCopyURL: URL, format: OfficeDocumentFormat,
                            originalURL: URL,
                            access: OfficeCommandAccess) async throws -> any OfficeServiceEngineSession {
        throw Unavailable()
    }
}

#if canImport(UIKit) && canImport(WebKit) && canImport(FloeOfficeNative)

/// Off-document host for one service-owned engine session. It mounts the
/// pinned controller in a dedicated, non-user-facing window so an automatic
/// edit never steals the user's editor, their document, or their selection.
/// Readiness follows the same truthful contract as the visible editor: the
/// open/permission report is not render evidence, and a presentation that
/// never paints is reported as a bounded failure instead of an edit that
/// "worked".
@MainActor
final class OfficeServiceNativeSessionFactoryImpl: OfficeServiceEngineSessionFactory {
    func openServiceSession(workingCopyURL: URL, format: OfficeDocumentFormat,
                            originalURL: URL,
                            access: OfficeCommandAccess) async throws -> any OfficeServiceEngineSession {
        try await OfficeServiceNativeSession.open(workingCopyURL: workingCopyURL,
                                                  format: format,
                                                  readOnly: false)
    }

    func verifyEngineReopen(savedCopyURL: URL, format: OfficeDocumentFormat,
                            access: OfficeCommandAccess) async -> OfficeEngineReopenEvidence {
        do {
            let session = try await OfficeServiceNativeSession.open(workingCopyURL: savedCopyURL,
                                                                    format: format,
                                                                    readOnly: true)
            try? await session.close()
            return .engineOpened
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .unavailable(reason: reason)
        }
    }
}

@MainActor
final class OfficeServiceNativeSession: OfficeServiceEngineSession {
    // Immutable Sendable values witness the protocol's nonisolated
    // requirements directly; every other requirement is async and hops to the
    // main actor.
    nonisolated let workingCopyURL: URL
    nonisolated let engineLabel = "floe-office-native"

    private let native: FloeOfficeNativeViewController
    private let container: UIViewController
    private let readOnly: Bool
    private let requiresVisibleRender: Bool
    private var window: UIWindow?
    /// Close lifecycle: references are only released after the engine
    /// acknowledged the close; a failed close quarantines the session.
    enum CloseState { case open, closing, closed, quarantined }
    private var closeState: CloseState = .open

    // Open readiness state. Callbacks may settle before a wait attaches and
    // vice versa; the settled outcome is retained and replayed.
    private var openSettled: Result<Bool, Error>?
    private var openWaiter: CheckedContinuation<Bool, Error>?
    private var renderSettled: Result<Void, Error>?
    private var renderWaiter: CheckedContinuation<Void, Error>?

    private init(workingCopyURL: URL,
                 format: OfficeDocumentFormat,
                 readOnly: Bool,
                 native: FloeOfficeNativeViewController,
                 container: UIViewController) {
        self.workingCopyURL = workingCopyURL
        self.readOnly = readOnly
        self.requiresVisibleRender = OfficeRenderRequirement.forDocument(
            pathExtension: workingCopyURL.pathExtension) == .visibleRenderRequired
        self.native = native
        self.container = container
        installCallbacks()
    }

    // MARK: Opening

    static func open(workingCopyURL: URL,
                     format: OfficeDocumentFormat,
                     readOnly: Bool) async throws -> OfficeServiceNativeSession {
        try await prepareRuntime()
        let sessionDirectory = workingCopyURL.deletingLastPathComponent()
        let native: FloeOfficeNativeViewController
        do {
            native = try FloeOfficeNativeViewController(workingFileURL: workingCopyURL,
                                                        sessionDirectory: sessionDirectory,
                                                        readOnly: readOnly)
        } catch {
            throw OfficeServiceSessionFailure(
                reason: "the pinned engine could not open the working copy: \(error.localizedDescription)")
        }
        // Install the command adapter before the engine page loads; the
        // hidden service session dispatches engine commands but never had the
        // bridge script injected.
        try OfficeCommandBridge.install(controller: native)
        let container = UIViewController()
        container.view.backgroundColor = .clear
        let session = OfficeServiceNativeSession(workingCopyURL: workingCopyURL,
                                                 format: format,
                                                 readOnly: readOnly,
                                                 native: native,
                                                 container: container)
        session.mount()
        do {
            try await session.awaitOpen()
            if !readOnly, await session.engineReportsReadOnly() {
                throw OfficeServiceSessionFailure(reason: "the engine kept the working copy read-only")
            }
            if session.requiresVisibleRender {
                try await session.awaitVisibleRender()
            }
            // The document-open callback is not proof that the engine page has
            // installed its command bridge; a hidden-window session must wait
            // for it or the first dispatch would be an invalid response.
            try await session.awaitCommandBridgeReady()
            return session
        } catch {
            // A failed open must never leak a mounted engine session; if the
            // cleanup close cannot be acknowledged, report the unsafe state so
            // the caller retains the working copy instead of deleting it.
            do {
                try await session.close()
            } catch let closeError {
                throw OfficeAutomaticExecutionError.sessionOpenUnsafe(
                    (closeError as? LocalizedError)?.errorDescription ?? closeError.localizedDescription)
            }
            throw error
        }
    }

    private static func prepareRuntime(timeout: TimeInterval = 30) async throws {
        try await withBoundedCompletion(timeout: timeout,
                                        timeoutError: OfficeServiceSessionFailure(
                                            reason: "the pinned engine runtime did not start in time")) { completion in
            FloeOfficeNativeRuntime.shared.prepare { error in
                completion(error.map { .failure($0) } ?? .success(()))
            }
        }
    }

    private func installCallbacks() {
        native.onWorkingCopyOpened = { [weak self] success in
            Task { @MainActor in
                guard let self, !success else { return }
                self.resolveOpen(.failure(OfficeServiceSessionFailure(
                    reason: "the pinned engine reported the working copy open failed")))
            }
        }
        native.onWorkingCopyOpenedWithPermission = { [weak self] success, engineReadOnly in
            Task { @MainActor in
                guard let self else { return }
                guard success else {
                    self.resolveOpen(.failure(OfficeServiceSessionFailure(
                        reason: "the pinned engine reported the working copy open failed")))
                    return
                }
                self.resolveOpen(.success(engineReadOnly))
            }
        }
        native.onVisibleRenderReady = { [weak self] _, _ in
            Task { @MainActor in self?.resolveRender(.success(())) }
        }
        native.onVisibleRenderFailed = { [weak self] error in
            Task { @MainActor in
                self?.resolveRender(.failure(OfficeServiceSessionFailure(
                    reason: "the engine produced no visible render: \(error.localizedDescription)")))
            }
        }
        native.onWebContentProcessTerminated = { [weak self] in
            Task { @MainActor in
                let failure = OfficeServiceSessionFailure(
                    reason: "the engine renderer process terminated")
                self?.resolveOpen(.failure(failure))
                self?.resolveRender(.failure(failure))
            }
        }
    }

    private func mount() {
        // A dedicated hidden window keeps the engine's web process running
        // without presenting anything to the user. It is released with the
        // session; the user's own editor and selection are never touched.
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(x: -50_000, y: -50_000, width: 1_024, height: 768))
        }
        window.frame = CGRect(x: -50_000, y: -50_000, width: 1_024, height: 768)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
        window.alpha = 0.02
        window.rootViewController = container
        container.view.frame = window.bounds
        container.addChild(native)
        native.view.frame = window.bounds
        native.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.view.addSubview(native.view)
        native.didMove(toParent: container)
        window.isHidden = false
        self.window = window
    }

    private func awaitOpen(timeout: TimeInterval = 45) async throws {
        if let settled = openSettled {
            _ = try settled.get()
            return
        }
        let engineReadOnly = try await withCheckedThrowingContinuation { continuation in
            openWaiter = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.resolveOpen(.failure(OfficeServiceSessionFailure(
                    reason: "the working copy did not finish opening in time")))
            }
        }
        _ = engineReadOnly
    }

    /// Bounded wait for the engine page's command bridge after open.
    private func awaitCommandBridgeReady(timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await OfficeCommandBridge.isReady(controller: native) { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        throw OfficeServiceSessionFailure(
            reason: "the engine command bridge did not become ready in time")
    }

    private func awaitVisibleRender(timeout: TimeInterval = 60) async throws {
        if let settled = renderSettled {
            try settled.get()
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            renderWaiter = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.resolveRender(.failure(OfficeServiceSessionFailure(
                    reason: "the presentation produced no visible render in time; automatic engine edits are unavailable for it")))
            }
        }
    }

    private func engineReportsReadOnly() async -> Bool {
        if readOnly { return true }
        let ack = OfficeEditEntryAck()
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            ack.resolve((true, false))
        }
        Task { @MainActor in
            self.native.enterEditMode { readOnly, error in
                let pendingPassword = (error as NSError?)?.code == 42
                ack.resolve((readOnly, pendingPassword))
            }
        }
        let result = await ack.wait()
        timeoutTask.cancel()
        return result.readOnly
    }

    private func resolveOpen(_ result: Result<Bool, Error>) {
        if let waiter = openWaiter {
            openWaiter = nil
            waiter.resume(with: result)
            return
        }
        if openSettled == nil { openSettled = result }
    }

    private func resolveRender(_ result: Result<Void, Error>) {
        if let waiter = renderWaiter {
            renderWaiter = nil
            waiter.resume(with: result)
            return
        }
        if renderSettled == nil { renderSettled = result }
    }

    // MARK: OfficeServiceEngineSession

    @MainActor func status() async throws -> OfficeServiceSessionStatus {
        if let settled = openSettled, case .failure(let error) = settled {
            throw error
        }
        guard native.isViewLoaded else {
            return OfficeServiceSessionStatus(editable: false,
                                              unavailableReason: "the engine surface is not mounted")
        }
        let engineReadOnly = native.isReadOnly || native.sessionIsReadOnly
        return OfficeServiceSessionStatus(editable: !readOnly && !engineReadOnly,
                                          unavailableReason: engineReadOnly
                                            ? "the engine reports the working copy read-only"
                                            : nil,
                                          hasUnsavedChanges: false)
    }

    @MainActor func apply(commands: [OfficeEngineCommand], batchID: String) async throws {
        guard !commands.isEmpty else {
            throw OfficeServiceSessionFailure(reason: "no commands were supplied")
        }
        do {
            _ = try await OfficeCommandBridge.dispatch(commands, controller: native)
        } catch let error as OfficeCommandBridgeError {
            throw OfficeServiceSessionFailure(
                reason: error.errorDescription ?? "the engine rejected the command batch")
        }
    }

    @MainActor func save() async throws {
        try await Self.withBoundedCompletion(timeout: 30,
                                             timeoutError: OfficeServiceSessionFailure(
                                                reason: "the engine did not finish saving the working copy in time")) { completion in
            native.saveWorkingCopy { error in
                completion(error.map { .failure($0) } ?? .success(()))
            }
        }
    }

    @MainActor func close() async throws {
        switch closeState {
        case .closed:
            return
        case .closing:
            throw OfficeServiceSessionFailure(reason: "the engine session is already closing")
        case .quarantined:
            throw OfficeServiceSessionFailure(
                reason: "the engine session is quarantined after an unacknowledged close; restart the app to recover the engine")
        case .open:
            break
        }
        closeState = .closing
        do {
            try await Self.withBoundedCompletion(timeout: 20,
                                                  timeoutError: OfficeServiceSessionFailure(
                                                    reason: "the engine did not acknowledge the close in time")) { completion in
                native.closeWorkingCopy { error in
                    completion(error.map { .failure($0) } ?? .success(()))
                }
            }
        } catch {
            // Unacknowledged close: KEEP the native host, its window and its
            // working copy mounted. Releasing references while the engine may
            // still use them risks the retained mutex/worker race, so the
            // session is quarantined and shared engine work is suspended.
            closeState = .quarantined
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await OfficeAutomaticExecutionGate.shared.markHostQuarantined(reason: reason)
            throw OfficeServiceSessionFailure(
                reason: "the engine did not acknowledge the close; the native session is retained and shared automatic engine work is suspended until the app restarts")
        }
        closeState = .closed
        let pendingOpen = openWaiter
        let pendingRender = renderWaiter
        openWaiter = nil
        renderWaiter = nil
        pendingOpen?.resume(throwing: OfficeServiceSessionFailure(reason: "the session was closed"))
        pendingRender?.resume(throwing: OfficeServiceSessionFailure(reason: "the session was closed"))
        native.willMove(toParent: nil)
        native.view.removeFromSuperview()
        native.removeFromParent()
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
    }

    /// Bounds one native completion: the receipt settles on the native
    /// callback OR the deadline, whichever is first; the settled outcome is
    /// retained for a late waiter.
    private static func withBoundedCompletion(
        timeout: TimeInterval,
        timeoutError: @autoclosure @escaping () -> Error,
        _ operation: (@escaping (Result<Void, Error>) -> Void) -> Void
    ) async throws {
        let receipt = OfficeSaveReceipt()
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0.1, timeout) * 1_000_000_000))
            receipt.resolve(.failure(timeoutError()))
        }
        operation { result in
            receipt.resolve(result)
        }
        do {
            try await receipt.wait()
            timeoutTask.cancel()
        } catch {
            timeoutTask.cancel()
            throw error
        }
    }
}

struct OfficeServiceSessionFailure: LocalizedError {
    var reason: String
    var errorDescription: String? { "The service-owned Office session failed: \(reason)" }
}

#endif
