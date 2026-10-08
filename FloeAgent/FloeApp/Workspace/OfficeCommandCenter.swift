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
    private let grants = OfficeProposalGrantStore()
    private var appliedReceipts: [String: OfficeCommandReceipt] = [:]
    private var requestPayloads: [String: String] = [:]
    private var gates: [String: CadDocumentGate] = [:]
    private let maximumDocumentBytes = 128 * 1024 * 1024

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
        proposalAccess[proposal.id] = access
        return proposal
    }

    func storeProposal(_ proposal: OfficeCommandProposal) async throws {
        proposals[proposal.id] = proposal
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
                    batchID: proposal.id.uuidString)
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
        if FileManager.default.fileExists(atPath: outputURL.path) {
            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: outputURL)
        }
        return OfficeExportReceipt(documentID: resolved.relativePath, relativePath: output,
                                   sha256: verified.sha256, byteCount: data.count,
                                   note: "Source document unchanged")
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

    /// The conversation that proposed this proposal, for the adopt/reject
    /// notification. Nil for workspace-originated proposals.
    func proposalOwnerConversation(proposalID: UUID) -> UUID? {
        proposalAccess[proposalID]?.conversationID
    }

    func discardProposal(id: UUID) {
        proposals.removeValue(forKey: id)
        proposalAccess.removeValue(forKey: id)
    }

    @discardableResult
    func approveAndApply(proposal: OfficeCommandProposal) async throws -> OfficeCommandReceipt {
        guard let access = proposalAccess[proposal.id] else { throw FloeError.unauthorized }
        let grant = await grants.issueGrant(proposal: proposal)
        let receipt = try await apply(proposal: proposal, grantID: grant,
                                      requestID: "ui-\(proposal.id.uuidString)", access: access)
        proposals.removeValue(forKey: proposal.id)
        return receipt
    }

    private func replayKey(action: String, access: OfficeCommandAccess, documentID: String,
                           requestID: String, payload: String) -> String {
        [action, access.environmentID ?? "-", access.workspacePath ?? "-",
         access.ownerKind ?? "-", access.ownerID?.uuidString ?? "-",
         documentID, requestID, payload].joined(separator: "|")
    }
}
