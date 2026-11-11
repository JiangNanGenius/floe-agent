// FloeApp — Task-center projection for document-bound file assistants.
//
// SPDX-License-Identifier: MPL-2.0
//
// Pure classification logic: which task-center rows are ordinary chats and
// which are file (document-bound) assistants, plus every section the task
// center renders (running / failed / completed / the persisted file area).
// Binding truth is the durable `document_assistants` set owned by
// StudioDocumentAccess — never a title heuristic and never the archive
// flag. Kept free of App-runtime dependencies (Foundation + FloePersistence
// only, no UIKit) so the exact production entry the views consume is
// directly testable on any Apple platform.

import Foundation
import FloePersistence

enum FileAssistantTaskProjection {

    /// One row of the persisted file-task area.
    struct FileTask: Equatable, Identifiable {
        var id: UUID { conversation.id }
        var conversation: ConversationRecord
        /// Latest run state name, nil when the assistant has no runs yet.
        var state: String?
    }

    /// The full task-center section set. `running` and `failed` are MERGED
    /// buckets (ordinary rows plus globally-visible file tasks), so a bound
    /// conversation appears there OR in the file area — never duplicated.
    /// `completed` holds ordinary rows only: a finished file task returns
    /// to the file area instead of inflating the global list.
    struct TaskCenterSections: Equatable {
        var ordinary: [ConversationRecord]
        var fileArea: [FileTask]
        var running: [ConversationRecord]
        var failed: [ConversationRecord]
        var completed: [ConversationRecord]
    }

    /// Terminal states mirror RunStateLocalizer.isTerminal (§6.2 mapping)
    /// without importing the UI layer, so this helper compiles for the app
    /// target and for focused component tests alike.
    static let terminalStates: Set<String> = [
        "completed", "failed", "recoveryFailed", "interrupted", "cancelled",
        "noProgress", "budgetLimited", "truncated", "checkpointed",
    ]
    /// Attention states mirror the task center's failed/interrupted bucket.
    static let attentionStates: Set<String> = ["failed", "interrupted", "checkpointed"]

    /// Classifies `records` into the task-center sections.
    /// `boundConversationIDs` is the caller's durable binding truth;
    /// `latestRunState` resolves the newest run state per id (nil when
    /// unknown). Input order is preserved within every output bucket, and
    /// no conversation id appears in more than one rendered bucket.
    static func sections(
        records: [ConversationRecord],
        boundConversationIDs: Set<UUID>,
        latestRunState: (UUID) -> String?
    ) -> TaskCenterSections {
        var ordinary: [ConversationRecord] = []
        var fileArea: [FileTask] = []
        var running: [ConversationRecord] = []
        var failed: [ConversationRecord] = []
        var completed: [ConversationRecord] = []
        var seen: Set<UUID> = []
        for record in records where record.purpose == .ordinary {
            guard seen.insert(record.id).inserted else { continue }
            let state = latestRunState(record.id)
            guard boundConversationIDs.contains(record.id) || record.editorOwnership != nil else {
                ordinary.append(record)
                guard let state else { continue }
                if !terminalStates.contains(state), state != "waitingApproval" {
                    running.append(record)
                } else if attentionStates.contains(state) {
                    failed.append(record)
                } else if state == "completed" {
                    completed.append(record)
                }
                continue
            }
            if let state, !terminalStates.contains(state), state != "waitingApproval" {
                running.append(record)
            } else if let state, attentionStates.contains(state) {
                failed.append(record)
            } else {
                fileArea.append(FileTask(conversation: record, state: state))
            }
        }
        return TaskCenterSections(ordinary: ordinary, fileArea: fileArea,
                                  running: running, failed: failed, completed: completed)
    }

    /// Backward-compatible view of the same classification for callers that
    /// need the file-assistant buckets without the merged global sections.
    struct Projection: Equatable {
        var ordinary: [ConversationRecord]
        var fileArea: [FileTask]
        var running: [ConversationRecord]
        var failed: [ConversationRecord]
    }

    static func project(
        records: [ConversationRecord],
        boundConversationIDs: Set<UUID>,
        latestRunState: (UUID) -> String?
    ) -> Projection {
        let value = sections(
            records: records,
            boundConversationIDs: boundConversationIDs,
            latestRunState: latestRunState)
        return Projection(ordinary: value.ordinary, fileArea: value.fileArea,
                          running: value.running, failed: value.failed)
    }
}
