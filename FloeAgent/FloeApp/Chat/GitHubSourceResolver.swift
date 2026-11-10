// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeModels
import FloeGit
import FloePersistence
import FloeAgentRuntime

/// Created by the native event renderer, never from Markdown or tool arguments.
nonisolated struct GitHubSourceReference: Sendable, Hashable, Identifiable {
    let conversationID: UUID
    let runID: UUID
    let eventID: UUID
    let sequence: Int
    let callID: String
    var id: UUID { eventID }

    static func make(result: RunEventRecord?, conversationID: UUID?) -> Self? {
        guard let result, let conversationID, result.kind == .toolResult,
              result.sequence > 0, let payload = GitHubSourceResolver.payload(result),
              payload["tool"] == GitHubReadLinkTool.name, payload["status"] == "ok",
              payload["outcomeUnknown"] != "true", let call = payload["id"], !call.isEmpty else { return nil }
        return .init(conversationID: conversationID, runID: result.runID,
            eventID: result.id, sequence: result.sequence, callID: call)
    }
}

nonisolated struct ResolvedGitHubSource: Sendable {
    let reference: GitHubSourceReference
    let snapshot: GitHubLinkSnapshot
    /// Only an explicit native producer pin that still matches the durable
    /// conversation binding. A legacy result never borrows a later project.
    let workspaceID: UUID?
    var opensCollaboration: Bool { snapshot.link.kind == .issue || snapshot.link.kind == .pullRequest }
}

nonisolated enum GitHubSourceResolutionError: Error, Equatable {
    case wrongOwner, unavailable, incomplete, invalidSource
}

/// Reuses the canonical result retention service. No new full-output store,
/// path interpretation, account, or remote read is performed while opening.
nonisolated enum GitHubSourceResolver {
    private struct ReadResult: Decodable { let source: GitHubLinkSnapshot }

    static func resolve(_ reference: GitHubSourceReference,
                        conversations: any ConversationStore, runs: any RunStore,
                        workspaces: any WorkspaceStore, captures: ToolResultCaptureStore) async throws -> ResolvedGitHubSource {
        try Task.checkCancellation()
        guard let conversation = try await conversations.conversation(id: reference.conversationID),
              conversation.purpose != .temporary,
              let run = try await runs.run(id: reference.runID), run.conversationID == reference.conversationID else {
            throw GitHubSourceResolutionError.wrongOwner
        }
        // Exact persisted row, not a similarly named call from another run.
        let page = try await runs.events(runID: reference.runID, afterSequence: reference.sequence - 1, limit: 1)
        guard let event = page.first, event.id == reference.eventID,
              event.runID == reference.runID, event.sequence == reference.sequence,
              GitHubSourceReference.make(result: event, conversationID: reference.conversationID) == reference,
              let fields = payload(event) else { throw GitHubSourceResolutionError.unavailable }
        let summary = fields["summary"] ?? ""
        let text: String
        if let capture = await captures.retainedCapture(conversationID: reference.conversationID,
            ref: ToolResultCaptureStore.reference(runID: reference.runID, callID: reference.callID)) {
            guard capture.conversationID == reference.conversationID, capture.runID == reference.runID,
                  capture.callID == reference.callID, capture.toolName == GitHubReadLinkTool.name,
                  capture.status == "ok" else { throw GitHubSourceResolutionError.wrongOwner }
            guard !capture.retentionTruncated, !capture.executionReportedTruncation else {
                throw GitHubSourceResolutionError.incomplete
            }
            // The retained bytes and event preview must describe this same
            // completion. Runtime redaction can make outputDigest refer to
            // the redacted preview, so it is not a full-capture seal.
            guard !summary.isEmpty, capture.text.hasPrefix(summary) else {
                throw GitHubSourceResolutionError.invalidSource
            }
            text = capture.text
        } else {
            // Small legacy completions remain readable without a capture,
            // but a truncated preview is never repaired by guessing JSON.
            guard fields["outputDigest"] == FloeDigest.sha256Hex(Data(summary.utf8)) else {
                throw GitHubSourceResolutionError.unavailable
            }
            text = summary
        }
        guard text.utf8.count <= 8 * 1_024 * 1_024 else { throw GitHubSourceResolutionError.incomplete }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let result = try? decoder.decode(ReadResult.self, from: Data(text.utf8)) else {
            throw GitHubSourceResolutionError.incomplete
        }
        let snapshot = result.source
        guard UUID(uuidString: snapshot.association.taskID ?? "") == reference.conversationID,
              let parsed = try? GitHubLinkParser.parse(snapshot.source.originalURL.absoluteString),
              parsed == snapshot.link, snapshot.repository.identity == parsed.repository,
              snapshot.source.repository == parsed.repository,
              (try? GitHubLinkParser.parse(snapshot.source.resolvedURL.absoluteString).repository) == parsed.repository else {
            throw GitHubSourceResolutionError.invalidSource
        }
        var workspace: UUID?
        if let raw = snapshot.association.projectID {
            guard let proposed = UUID(uuidString: raw) else { throw GitHubSourceResolutionError.invalidSource }
            if try await workspaces.workspaceID(conversationID: reference.conversationID) == proposed,
               let record = try await workspaces.workspace(id: proposed), record.kind == .project {
                workspace = proposed
            } else { workspace = nil }
        } else { workspace = nil }
        // Deletion/reassignment can race decoding. No result resurrects its
        // task; later project assignment does not upgrade a legacy read.
        try Task.checkCancellation()
        guard let current = try await conversations.conversation(id: reference.conversationID), current.purpose != .temporary,
              try await runs.run(id: reference.runID)?.conversationID == reference.conversationID else {
            throw GitHubSourceResolutionError.wrongOwner
        }
        if let pinned = workspace, try await workspaces.workspaceID(conversationID: reference.conversationID) != pinned {
            workspace = nil
        }
        return .init(reference: reference, snapshot: snapshot, workspaceID: workspace)
    }

    static func payload(_ event: RunEventRecord) -> [String: String]? {
        guard event.payloadJSON.utf8.count <= 2 * 1_024 * 1_024 else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: Data(event.payloadJSON.utf8))
    }
}

/// Captured by the actual ThreadDetailView host. Embedded Notes selects its
/// original run in place; ordinary Chat may additionally open its router.
nonisolated struct GitHubSourceReturnAction: Sendable {
    let conversationID: UUID
    let perform: @MainActor @Sendable (UUID) -> Void
    @MainActor func callAsFunction(_ reference: GitHubSourceReference) {
        guard reference.conversationID == conversationID else { return }
        perform(reference.runID)
    }
}
