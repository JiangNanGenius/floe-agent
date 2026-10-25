// FloeApp — Widget snapshot production.
//
// Converts the durable run/conversation truth into the bounded snapshot the
// widget extension reads. This is a projection only: it never creates a
// second task store, never reads message bodies and never launches work.
// Deleted conversations disappear because the snapshot is rebuilt from the
// actual stores on every publish; temporary and document-assistant owners are
// excluded explicitly.

import Foundation
import FloeCore
import FloePersistence

/// One bounded, non-terminal run candidate.
struct WidgetSnapshotRun: Sendable, Equatable {
    var id: UUID
    var conversationID: UUID
    var state: String
    var startedAt: Date
}

/// The conversation fields the snapshot needs. `title` is already the durable
/// task title, never a message body.
struct WidgetSnapshotConversation: Sendable, Equatable {
    var id: UUID
    var title: String
    var updatedAt: Date
    var isArchived: Bool
    var isOrdinary: Bool
}

protocol WidgetSnapshotRunSource: Sendable {
    /// Returns at most `limit` non-terminal runs, newest run first.
    func nonTerminalRuns(limit: Int) async throws -> [WidgetSnapshotRun]
}

protocol WidgetSnapshotConversationSource: Sendable {
    func conversation(id: UUID) async throws -> WidgetSnapshotConversation?
}

struct RunStoreWidgetSnapshotSource: WidgetSnapshotRunSource {
    let store: any RunStore

    func nonTerminalRuns(limit: Int) async throws -> [WidgetSnapshotRun] {
        let runs = try await store.nonTerminalRuns()
        return runs
            .sorted {
                if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
                return $0.id.uuidString > $1.id.uuidString
            }
            .prefix(max(1, limit))
            .map {
                WidgetSnapshotRun(
                    id: $0.id,
                    conversationID: $0.conversationID,
                    state: $0.state,
                    startedAt: $0.startedAt
                )
            }
    }
}

struct ConversationStoreWidgetSnapshotSource: WidgetSnapshotConversationSource {
    let store: any ConversationStore

    func conversation(id: UUID) async throws -> WidgetSnapshotConversation? {
        guard let record = try await store.conversation(id: id) else { return nil }
        return WidgetSnapshotConversation(
            id: record.id,
            title: record.title,
            updatedAt: record.updatedAt,
            isArchived: record.archivedAt != nil,
            isOrdinary: record.purpose == .ordinary && record.visibility == .normal
        )
    }
}

/// The write surface the producer needs. `WidgetTaskSnapshotStore` is the
/// production implementation; tests inject a failing or recording store.
protocol WidgetSnapshotStoring: Sendable {
    func write(_ snapshot: WidgetTaskSnapshot) throws
    func load(now: Date) -> WidgetTaskSnapshotLoadResult
}

extension WidgetTaskSnapshotStore: WidgetSnapshotStoring {}

struct WidgetSnapshotPublishResult: Equatable, Sendable {
    var publishedAt: Date
    var taskCount: Int
}

enum WidgetSnapshotPublishFailure: Error, Equatable, Sendable {
    case readFailed
    case writeFailed(WidgetTaskSnapshotStoreError)
    case invalidSnapshot(WidgetTaskSnapshotError)

    var logKind: String {
        switch self {
        case .readFailed: "read_failed"
        case .writeFailed(let error): "write_\(error.logKind)"
        case .invalidSnapshot(let error): "invalid_\(error.logKind)"
        }
    }
}

enum WidgetSnapshotPublishOutcome: Equatable, Sendable {
    case published(WidgetSnapshotPublishResult)
    case failed(WidgetSnapshotPublishFailure)
    case cancelled
}

protocol WidgetSnapshotPublishing: Sendable {
    func publish(
        now: Date,
        excludingConversationIDs: Set<UUID>
    ) async -> WidgetSnapshotPublishOutcome
}

/// Serialized snapshot builder/writer. Each call rebuilds from the actual
/// stores, so a deletion or terminal transition is reflected by the next
/// publish rather than by mutating an old snapshot in place.
actor WidgetSnapshotProducer: WidgetSnapshotPublishing {
    private let store: (any WidgetSnapshotStoring)?
    private let runSource: any WidgetSnapshotRunSource
    private let conversationSource: any WidgetSnapshotConversationSource
    private let maximumCandidateRuns: Int
    /// Defensive terminal vocabulary. `RunStore.nonTerminalRuns()` already
    /// excludes these, but a legacy/stray row must never be relabelled as an
    /// active widget task.
    private static let terminalRunStates: Set<String> = [
        "completed", "failed", "checkpointed", "interrupted", "cancelled", "canceled"
    ]

    init(
        store: (any WidgetSnapshotStoring)?,
        runSource: any WidgetSnapshotRunSource,
        conversationSource: any WidgetSnapshotConversationSource,
        maximumCandidateRuns: Int = 32
    ) {
        self.store = store
        self.runSource = runSource
        self.conversationSource = conversationSource
        self.maximumCandidateRuns = max(1, maximumCandidateRuns)
    }

    func publish(
        now: Date = Date(),
        excludingConversationIDs: Set<UUID> = []
    ) async -> WidgetSnapshotPublishOutcome {
        guard !Task.isCancelled else { return .cancelled }
        guard let store else {
            return .failed(.writeFailed(.appGroupUnavailable))
        }

        let candidates: [WidgetSnapshotRun]
        do {
            candidates = try await runSource.nonTerminalRuns(limit: maximumCandidateRuns)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(.readFailed)
        }

        var seenConversations: Set<UUID> = []
        var items: [WidgetTaskSnapshot.Item] = []
        for run in candidates {
            guard !Task.isCancelled else { return .cancelled }
            guard !Self.terminalRunStates.contains(run.state) else { continue }
            guard !excludingConversationIDs.contains(run.conversationID) else { continue }
            // A task can have more than one non-terminal row after a resume;
            // only the newest run becomes the row identity and its state.
            guard seenConversations.insert(run.conversationID).inserted else { continue }
            let conversation: WidgetSnapshotConversation?
            do {
                conversation = try await conversationSource.conversation(id: run.conversationID)
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed(.readFailed)
            }
            guard let conversation,
                  conversation.id == run.conversationID,
                  conversation.isOrdinary,
                  !conversation.isArchived else {
                continue
            }
            items.append(
                WidgetTaskSnapshot.Item(
                    id: conversation.id,
                    runID: run.id,
                    title: WidgetTaskSnapshot.sanitizedTitle(conversation.title),
                    state: WidgetTaskState(runState: run.state),
                    updatedAt: max(conversation.updatedAt, run.startedAt)
                )
            )
        }

        let ordered = items.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.runID.uuidString > $1.runID.uuidString
        }
        let snapshot = WidgetTaskSnapshot(
            generatedAt: now,
            tasks: Array(ordered.prefix(WidgetTaskSnapshot.maximumTasks))
        )

        guard !Task.isCancelled else { return .cancelled }
        do {
            try store.write(snapshot)
        } catch let error as WidgetTaskSnapshotStoreError {
            return .failed(.writeFailed(error))
        } catch let error as WidgetTaskSnapshotError {
            return .failed(.invalidSnapshot(error))
        } catch {
            return .failed(.writeFailed(.writeFailed))
        }

        return .published(
            WidgetSnapshotPublishResult(
                publishedAt: now,
                taskCount: snapshot.tasks.count
            )
        )
    }
}

extension WidgetTaskSnapshotStoreError {
    /// Log-safe classifier; never includes a path or snapshot content.
    var logKind: String {
        switch self {
        case .appGroupUnavailable: "app_group_unavailable"
        case .unsafePath: "unsafe_path"
        case .readFailed: "read_failed"
        case .writeFailed: "write_failed"
        case .tooLarge: "too_large"
        case .malformed: "malformed"
        case .invalidSnapshot(let error): "invalid_\(error.logKind)"
        }
    }
}

extension WidgetTaskSnapshotError {
    var logKind: String {
        switch self {
        case .unsupportedSchema: "schema"
        case .tooManyTasks: "too_many_tasks"
        case .duplicateTaskID: "duplicate_task"
        case .duplicateRunID: "duplicate_run"
        case .titleTooLong: "title_too_long"
        case .invalidTitle: "invalid_title"
        case .invalidDate: "invalid_date"
        }
    }
}
