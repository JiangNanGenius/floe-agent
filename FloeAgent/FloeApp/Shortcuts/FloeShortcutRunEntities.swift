#if canImport(AppIntents)
import AppIntents
import Foundation
import FloeCore

/// Stable system-facing states; internal execution phases stay in Floe.
enum FloeShortcutRunDisplayState: String, AppEnum {
    case running, waitingApproval, paused, checkpointed, cancelling
    case completed, failed, cancelled, interrupted, incomplete, unavailable

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "shortcuts.run.state.type")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .running: .init(title: "shortcuts.run.state.running"),
        .waitingApproval: .init(title: "shortcuts.run.state.waitingApproval"),
        .paused: .init(title: "shortcuts.run.state.paused"),
        .checkpointed: .init(title: "shortcuts.run.state.checkpointed"),
        .cancelling: .init(title: "shortcuts.run.state.cancelling"),
        .completed: .init(title: "shortcuts.run.state.completed"),
        .failed: .init(title: "shortcuts.run.state.failed"),
        .cancelled: .init(title: "shortcuts.run.state.cancelled"),
        .interrupted: .init(title: "shortcuts.run.state.interrupted"),
        .incomplete: .init(title: "shortcuts.run.state.incomplete"),
        .unavailable: .init(title: "shortcuts.run.state.unavailable")
    ]
}

/// A refreshable reference to one execution, suitable for passing between
/// Shortcuts actions. Status fields describe the returned snapshot only.
struct FloeShortcutRunEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "shortcuts.run.entity.type")
    static let defaultQuery = FloeShortcutRunEntityQuery()

    @Property(title: "shortcuts.run.property.run_id") var runID: String
    @Property(title: "shortcuts.run.property.task_id") var conversationID: String
    @Property(title: "shortcuts.run.property.title") var title: String
    @Property(title: "shortcuts.run.property.state") var state: FloeShortcutRunDisplayState
    @Property(title: "shortcuts.run.property.finished") var isFinished: Bool
    @Property(title: "shortcuts.run.property.successful") var isSuccessful: Bool
    @Property(title: "shortcuts.run.property.needs_action") var requiresUserAction: Bool
    @Property(title: "shortcuts.run.property.wait_timed_out") var waitTimedOut: Bool
    @Property(title: "shortcuts.run.property.cancel_requested") var cancellationRequested: Bool

    var id: String { runID }

    var displayRepresentation: DisplayRepresentation {
        .init(title: "\(title)", subtitle: "\(FloeL10n.l("shortcuts.run.state." + state.rawValue))")
    }

    init(runID: UUID, conversationID: UUID?, title: String,
         state: FloeShortcutRunDisplayState, isFinished: Bool, isSuccessful: Bool,
         requiresUserAction: Bool, waitTimedOut: Bool = false,
         cancellationRequested: Bool = false) {
        self.runID = runID.uuidString
        self.conversationID = conversationID?.uuidString ?? ""
        self.title = title
        self.state = state
        self.isFinished = isFinished
        self.isSuccessful = isSuccessful
        self.requiresUserAction = requiresUserAction
        self.waitTimedOut = waitTimedOut
        self.cancellationRequested = cancellationRequested
    }
}

struct FloeShortcutRunEntityQuery: EntityQuery {
    @AppDependency private var environment: AppEnvironment

    @MainActor
    func entities(for identifiers: [String]) async throws -> [FloeShortcutRunEntity] {
        // Rehydrate only explicitly supplied execution identities. A query
        // never substitutes a conversation's latest run or starts another.
        var result: [FloeShortcutRunEntity] = []
        for identifier in identifiers {
            guard let runID = UUID(uuidString: identifier) else { continue }
            result.append(try await FloeShortcutRunIntentBridge.snapshot(
                runID: runID, expectedConversationID: nil, environment: { environment }))
        }
        return result
    }

    func suggestedEntities() async throws -> [FloeShortcutRunEntity] { [] }
}
#endif
