// SPDX-License-Identifier: MPL-2.0
//
// N10 next-maintenance task continuity (Android 1.0.5/code113 source batch).
//
// This file owns the two native projections the Android host needs for the
// three related continuity features and keeps them OUT of the platform UI:
//
//   * `N113RunTerminal` — the ONE durable terminal classification shared by
//     the run snapshot wire and the additive checklist summary. A transient
//     provider/tool error event is NOT a terminal state by itself; only the
//     durable run row (or an explicitly live parked state) decides.
//   * `ConversationChecklistWire` — the bounded checklist summary carried by
//     `conversation.get`. It is projected ONLY while its owning run is the
//     current runtime-active run, so the App's top strip can never present a
//     previous round's unfinished/failed steps as current progress. The full
//     canonical row remains available through the existing bounded
//     `conversation.get.detail{kind:"checklist"}` read.
//
// No new table, migration, persistence file or wire command is introduced.
import Foundation
import FloeCore
import FloePersistence
import FloeAgentRuntime

// MARK: - Durable terminal classification

/// Distinct user-visible outcomes. `suspended` (checkpointed/interrupted) and
/// `waiting` (a live parked approval) are deliberately NOT folded into
/// `failed`: a retrying/live run is never announced as a whole-task failure.
public enum N113RunTerminalDisposition: String, Sendable, Equatable, CaseIterable {
    case none
    case completed
    case failed
    case cancelled
    /// Durable checkpoint/interruption: recoverable, not a failure.
    case suspended
    /// Live parked state that needs the user (approval), never terminal.
    case waiting
}

public enum N113RunTerminal {
    /// The original durable AgentState vocabulary that still has a live
    /// owner. The runtime-layer `TaskRunActivity` is the single vocabulary;
    /// `FacadeRunDomain.activeRunStates` mirrors the same set for the façade.
    public static let runtimeActiveStates: Set<String> = TaskRunActivity.activeStates

    public static let durableTerminalStates: Set<String> = [
        "completed", "failed", "cancelled", "checkpointed", "interrupted",
    ]

    public static func isDurableTerminal(_ state: String) -> Bool {
        durableTerminalStates.contains(state)
    }

    public static func isRuntimeActive(_ state: String) -> Bool {
        runtimeActiveStates.contains(state)
    }

    /// A live owner always wins over an intermediate durable row: a run that
    /// is still owned/retrying is not announced as failed. `waitingApproval`
    /// is the only live state surfaced as `waiting`; every other live state
    /// is `none`.
    public static func disposition(state: String, isLiveOwner: Bool) -> N113RunTerminalDisposition {
        if isLiveOwner {
            if state == "waitingApproval" || state == "paused" { return .waiting }
            return .none
        }
        switch state {
        case "completed": return .completed
        case "failed": return .failed
        case "cancelled": return .cancelled
        case "checkpointed", "interrupted": return .suspended
        case "waitingApproval", "paused": return isLiveOwner ? .waiting : .none
        default: return .none
        }
    }
}

// MARK: - Bounded checklist summary for `conversation.get`

/// The additive `conversation.get.checklist` summary. It carries only real
/// durable values: identity, revision, the original step statuses and the
/// localized progress line. Never a synthesized completion.
public struct ConversationChecklistWire: Sendable, Equatable {
    public struct StepWire: Sendable, Equatable {
        public let id: String
        public let title: String
        public let status: String
        public let evidence: [String]

        public init(step: TaskChecklist.Step) {
            id = step.id
            title = step.title
            status = step.status.rawValue
            evidence = step.evidence
        }

        public var wireObject: [String: Any] {
            ["id": id, "title": title, "status": status, "evidence": evidence]
        }
    }

    public let runID: UUID
    public let revision: Int
    public let title: String
    public let isFinished: Bool
    public let wasReset: Bool
    public let completedCount: Int
    public let cancelledCount: Int
    public let currentStepTitle: String?
    public let progressSummary: String
    public let steps: [StepWire]

    public init(checklist: TaskChecklist) {
        runID = checklist.runID
        revision = checklist.revision
        title = checklist.title
        isFinished = checklist.isFinished
        wasReset = checklist.wasReset == true
        completedCount = checklist.completedCount
        cancelledCount = checklist.cancelledCount
        currentStepTitle = checklist.currentStep?.title
        progressSummary = checklist.progressSummary
        steps = checklist.steps.map(StepWire.init(step:))
    }

    public var wireObject: [String: Any] {
        [
            "runID": runID.uuidString,
            "revision": revision,
            "title": title,
            "isFinished": isFinished,
            "wasReset": wasReset,
            "completedCount": completedCount,
            "cancelledCount": cancelledCount,
            "currentStepTitle": currentStepTitle ?? NSNull(),
            "progressSummary": progressSummary,
            "steps": steps.map(\.wireObject),
        ]
    }

    /// Projects the summary only while the SAME run is the current ordinary
    /// runtime-active round. A finished/reset checklist, a run that already
    /// ended, a foreign owner and a missing row are all honest absence.
    public static func project(checklist: TaskChecklist?,
                               runID: UUID?,
                               runState: String?,
                               runEnded: Bool) -> ConversationChecklistWire? {
        guard let checklist, checklist.wasReset != true, !checklist.isFinished else {
            return nil
        }
        guard let runID, runID == checklist.runID, !runEnded,
              let runState, N113RunTerminal.isRuntimeActive(runState),
              !N113RunTerminal.isDurableTerminal(runState) else {
            return nil
        }
        return ConversationChecklistWire(checklist: checklist)
    }
}

// MARK: - Plan presentation identity

/// One canonical presentation marker (`plan id:revision`) shared by the
/// native read/accept proof and the App's durable presentation acknowledgement.
/// It grants no execution or tool permission; `plan.accept` still validates
/// the plan id/revision/digest against the latest durable row.
public enum N113PlanPresentation {
    public static func marker(planID: UUID, revision: Int) -> String {
        "\(planID.uuidString):\(revision)"
    }
}
