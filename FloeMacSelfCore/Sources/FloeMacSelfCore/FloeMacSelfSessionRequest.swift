// SPDX-License-Identifier: MPL-2.0
//
// Bounded launch request for one Mac session. This is a native host request,
// not model-authored data. It supports the existing Floe conversation modes:
// ordinary chat, Plan (read-only discovery that persists only Floe-owned plan
// drafts), Goal (a durable, budgeted run), and the execution launch of an
// accepted plan. Modes this build cannot compose fail closed instead of being
// silently half-wired.

import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime

/// Bounded non-secret context injected as a system message for one run.
/// Imported content is reference data; it never grants tools or permissions.
public struct FloeMacSelfRunContext: Sendable, Hashable {
    public let workspaceName: String?
    public let selectedRelativePath: String?
    public let executionTarget: String?
    public let projectInstructions: String?
    public let workspaceNotes: [String]
    public let workspaceListing: String?
    public let activeSkillIDs: Set<String>
    public let skillInstructions: String?

    public init(
        workspaceName: String? = nil,
        selectedRelativePath: String? = nil,
        executionTarget: String? = nil,
        projectInstructions: String? = nil,
        workspaceNotes: [String] = [],
        workspaceListing: String? = nil,
        activeSkillIDs: Set<String> = [],
        skillInstructions: String? = nil
    ) {
        self.workspaceName = workspaceName
        self.selectedRelativePath = selectedRelativePath
        self.executionTarget = executionTarget
        self.projectInstructions = projectInstructions
        self.workspaceNotes = workspaceNotes
        self.workspaceListing = workspaceListing
        self.activeSkillIDs = activeSkillIDs
        self.skillInstructions = skillInstructions
    }
}

/// One durable file attachment for a Mac session. The host supplies a
/// read-only security-scoped bookmark created at pick time; the composition
/// persists only metadata and the digest beside the launch transaction.
/// Images and supported text documents are included in the model request
/// after verification. Other documents remain available in task history.
public struct FloeMacSelfSessionAttachment: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case image
        case document
    }

    public let id: UUID
    public let kind: Kind
    public let displayName: String
    public let uti: String
    public let byteCount: Int
    /// Lowercase SHA-256 hex of the picked bytes; verified after prepare.
    public let sha256: String
    /// Read-only security-scoped bookmark for the picked file.
    public let bookmark: Data

    public init(
        id: UUID = UUID(),
        kind: Kind,
        displayName: String,
        uti: String,
        byteCount: Int,
        sha256: String,
        bookmark: Data
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.uti = uti
        self.byteCount = byteCount
        self.sha256 = sha256
        self.bookmark = bookmark
    }
}

/// Exact durable Goal binding for a launch that executes an already-confirmed
/// plan (or continues a known Goal round). Persistence validates the live
/// Goal revision in the same transaction as the run; the composition only
/// carries the host-observed identity.
public struct FloeMacSelfExpectedGoal: Sendable, Hashable {
    public let id: UUID
    public let revision: Int

    public init(id: UUID, revision: Int) {
        self.id = id
        self.revision = revision
    }
}

/// Exact launch inputs for the execution run of an accepted plan, produced
/// only by `FloeMacSelfRuntime.prepareAcceptedPlanExecution`. Every field
/// mirrors the committed confirmation record; the host feeds them verbatim
/// into `startSession` and must not re-author the prompt or identities.
public struct FloeMacSelfAcceptedPlanExecution: Sendable, Hashable {
    public let conversationID: UUID
    /// The confirmation's planned run identity (`executionRunID`).
    public let runID: UUID
    /// The confirmation message consumed exactly once by the launch.
    public let userMessageID: UUID
    /// The single execution prompt committed at confirmation time.
    public let goal: String
    /// `.goal` when the confirmation created a durable Goal; otherwise chat.
    public let conversationMode: ConversationMode
    public let goalID: UUID?
    public let goalRevision: Int?

    public init(
        conversationID: UUID,
        runID: UUID,
        userMessageID: UUID,
        goal: String,
        conversationMode: ConversationMode,
        goalID: UUID?,
        goalRevision: Int?
    ) {
        self.conversationID = conversationID
        self.runID = runID
        self.userMessageID = userMessageID
        self.goal = goal
        self.conversationMode = conversationMode
        self.goalID = goalID
        self.goalRevision = goalRevision
    }

    /// The bounded session request for the execution run. Tool-enabled
    /// executions pass the host's verified tool binding as usual.
    public func sessionRequest(
        workspaceID: UUID? = nil,
        chatFastMode: Bool = false
    ) -> FloeMacSelfSessionRequest {
        FloeMacSelfSessionRequest(
            conversationID: conversationID,
            workspaceID: workspaceID,
            goal: goal,
            mode: conversationMode,
            runID: runID,
            chatFastMode: chatFastMode,
            reusingUserMessageID: userMessageID,
            expectedGoal: goalID.map {
                FloeMacSelfExpectedGoal(id: $0, revision: goalRevision ?? 1)
            }
        )
    }
}

/// Native launch request. `conversationID` resumes an existing durable task;
/// `newConversationID` reserves a known identity for a new one. Passing both
/// is rejected by the composition layer.
public struct FloeMacSelfSessionRequest: Sendable, Hashable {
    public let conversationID: UUID?
    public let newConversationID: UUID?
    public let workspaceID: UUID?
    public let conversationTitle: String
    public let goal: String
    public let mode: ConversationMode
    public let initialPolicy: DraftTaskPolicy
    public let runID: UUID?
    public let context: FloeMacSelfRunContext
    /// Durable file attachments staged for this run. Attachments never grant
    /// tools or permissions; they are reference data bound to the user turn.
    /// An accepted-plan execution launch cannot add attachments: its user
    /// turn is the exact committed confirmation message.
    public let attachments: [FloeMacSelfSessionAttachment]
    /// True selects the existing Floe chat envelope (brief conversational
    /// instructions). Set false for task-style tool work. This flag never
    /// grants a tool; the tool binding still requires the explicit ceiling.
    /// Plan and Goal launches always use the full task envelope.
    public let chatFastMode: Bool
    public let chatReasoningPreference: ChatReasoningPreference?
    /// The host supplies an interactive question surface for this session.
    public let allowsUserQuestions: Bool
    public let verifyFinalAnswer: Bool
    /// Host-authored acceptance criteria for a new durable Goal (mode
    /// `.goal`). 1...12 items, each non-empty and bounded; these become the
    /// Goal's `acceptanceCriteria` verbatim. Empty for every other mode.
    public let goalCriteria: [String]
    /// Optional host budgets for the new durable Goal. Nil keeps the existing
    /// `GoalBudgets()` defaults; budgets are stored on the Goal and mirrored
    /// into the runtime's harness budget ledger for this run.
    public let goalBudgets: GoalBudgets?
    /// Accepted-plan execution launch only: the exact confirmation user
    /// message written by `confirmPlan`. The launch transaction consumes it
    /// once after validating its embedded plan-confirmation proof.
    public let reusingUserMessageID: UUID?
    /// Accepted-plan execution launch (or known-Goal round) only: the durable
    /// Goal to bind in the same transaction as the run.
    public let expectedGoal: FloeMacSelfExpectedGoal?
    /// Automatic Goal continuation is authorized by one exact prior completed round.
    public let automaticGoalPredecessor: UUID?
    public let startedAt: Date

    public init(
        conversationID: UUID? = nil,
        newConversationID: UUID? = nil,
        workspaceID: UUID? = nil,
        conversationTitle: String = "",
        goal: String,
        mode: ConversationMode = .chat,
        initialPolicy: DraftTaskPolicy = DraftTaskPolicy(),
        runID: UUID? = nil,
        context: FloeMacSelfRunContext = FloeMacSelfRunContext(),
        attachments: [FloeMacSelfSessionAttachment] = [],
        chatFastMode: Bool = true,
        chatReasoningPreference: ChatReasoningPreference? = nil,
        allowsUserQuestions: Bool = false,
        verifyFinalAnswer: Bool = false,
        goalCriteria: [String] = [],
        goalBudgets: GoalBudgets? = nil,
        reusingUserMessageID: UUID? = nil,
        expectedGoal: FloeMacSelfExpectedGoal? = nil,
        automaticGoalPredecessor: UUID? = nil,
        startedAt: Date = Date()
    ) {
        self.conversationID = conversationID
        self.newConversationID = newConversationID
        self.workspaceID = workspaceID
        self.conversationTitle = conversationTitle
        self.goal = goal
        self.mode = mode
        self.initialPolicy = initialPolicy
        self.runID = runID
        self.context = context
        self.attachments = attachments
        self.chatFastMode = chatFastMode
        self.chatReasoningPreference = chatReasoningPreference
        self.allowsUserQuestions = allowsUserQuestions
        self.verifyFinalAnswer = verifyFinalAnswer
        self.goalCriteria = goalCriteria
        self.goalBudgets = goalBudgets
        self.reusingUserMessageID = reusingUserMessageID
        self.expectedGoal = expectedGoal
        self.automaticGoalPredecessor = automaticGoalPredecessor
        self.startedAt = startedAt
    }
}

enum FloeMacSelfRequestValidator {
    static let maximumGoalBytes = 1_048_576
    static let maximumTitleBytes = 200
    static let maximumWorkspaceNameBytes = 200
    static let maximumSelectedPathBytes = 1_024
    static let maximumExecutionTargetBytes = 500
    static let maximumProjectInstructionsBytes = 131_072
    static let maximumWorkspaceNotes = 32
    static let maximumWorkspaceNoteBytes = 500
    static let maximumWorkspaceListingBytes = 32_768
    static let maximumAttachments = 8
    static let maximumAttachmentNameBytes = 200
    static let maximumAttachmentBytes = 32 * 1_024 * 1_024
    static let maximumAttachmentBookmarkBytes = 16 * 1_024
    static let maximumGoalCriteria = 12
    static let maximumGoalCriterionBytes = 1_000

    static func validate(_ request: FloeMacSelfSessionRequest) throws {
        guard request.conversationID == nil || request.newConversationID == nil else {
            throw FloeMacSelfCoreError.invalidRequest(
                "choose an existing or a new conversation identity, not both"
            )
        }
        guard !request.goal.utf8.contains(0), !request.conversationTitle.utf8.contains(0) else {
            throw FloeMacSelfCoreError.invalidRequest("the goal and title must not contain NUL")
        }
        let goal = request.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else {
            throw FloeMacSelfCoreError.invalidRequest("the goal must not be empty")
        }
        guard goal.utf8.count <= maximumGoalBytes else {
            throw FloeMacSelfCoreError.invalidRequest("the goal exceeds the bounded message size")
        }
        guard request.conversationTitle.utf8.count <= maximumTitleBytes else {
            throw FloeMacSelfCoreError.invalidRequest("the conversation title is too long")
        }
        switch request.mode {
        case .chat:
            guard request.goalCriteria.isEmpty, request.goalBudgets == nil,
                  request.expectedGoal == nil else {
                throw FloeMacSelfCoreError.invalidRequest(
                    "ordinary chat cannot carry Goal criteria, budgets or a Goal binding"
                )
            }
        case .plan:
            guard request.goalCriteria.isEmpty, request.goalBudgets == nil,
                  request.expectedGoal == nil, request.reusingUserMessageID == nil else {
                throw FloeMacSelfCoreError.invalidRequest(
                    "plan discovery cannot carry Goal inputs or reuse a confirmation message"
                )
            }
        case .goal:
            if let expectedGoal = request.expectedGoal {
                // A known-Goal round: either the execution of an accepted
                // plan (which consumes its confirmation message) or an
                // ordinary next round of an active durable Goal. The exact
                // id/revision is CAS-validated by the launch transaction;
                // the host never sends criteria or budgets for a bound Goal.
                _ = expectedGoal
                guard request.goalCriteria.isEmpty, request.goalBudgets == nil else {
                    throw FloeMacSelfCoreError.invalidRequest(
                        "a bound-Goal round cannot redefine the confirmed Goal criteria or budgets"
                    )
                }
            } else if request.reusingUserMessageID == nil {
                // A new durable Goal must be authored from the named host
                // criteria field; a prompt-only Goal is never simulated.
                try validateGoalCriteria(request.goalCriteria)
            } else {
                throw FloeMacSelfCoreError.invalidRequest(
                    "an accepted-plan Goal execution requires the exact Goal binding"
                )
            }
        }
        if request.reusingUserMessageID != nil {
            guard request.conversationID != nil, request.runID != nil else {
                throw FloeMacSelfCoreError.invalidRequest(
                    "an accepted-plan execution launch requires the existing conversation and the planned run identity"
                )
            }
            guard request.attachments.isEmpty else {
                throw FloeMacSelfCoreError.invalidRequest(
                    "an accepted-plan execution cannot add attachments to the confirmed turn"
                )
            }
        } else if request.expectedGoal != nil {
            // A known-Goal continuation round addresses an existing
            // conversation; the Goal row itself proves the task identity.
            guard request.conversationID != nil else {
                throw FloeMacSelfCoreError.invalidRequest(
                    "a known-Goal round requires the existing conversation"
                )
            }
        }
        try validate(request.attachments)
        try validate(request.context)
    }

    static func validateGoalCriteria(_ criteria: [String]) throws {
        guard !criteria.isEmpty, criteria.count <= maximumGoalCriteria else {
            throw FloeMacSelfCoreError.invalidRequest(
                "a durable Goal requires 1...\(maximumGoalCriteria) acceptance criteria"
            )
        }
        for criterion in criteria {
            let trimmed = criterion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.utf8.count <= maximumGoalCriterionBytes,
                  !criterion.utf8.contains(0) else {
                throw FloeMacSelfCoreError.invalidRequest(
                    "a Goal criterion is empty, unbounded or contains NUL"
                )
            }
        }
    }

    static func validate(_ attachments: [FloeMacSelfSessionAttachment]) throws {
        guard attachments.count <= maximumAttachments else {
            throw FloeMacSelfCoreError.invalidRequest("too many attachments for one Mac run")
        }
        var seen = Set<UUID>()
        for attachment in attachments {
            guard seen.insert(attachment.id).inserted else {
                throw FloeMacSelfCoreError.invalidRequest("duplicate attachment identity")
            }
            let name = attachment.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.utf8.count <= maximumAttachmentNameBytes else {
                throw FloeMacSelfCoreError.invalidRequest("an attachment name is empty or too long")
            }
            guard attachment.byteCount > 0, attachment.byteCount <= maximumAttachmentBytes else {
                throw FloeMacSelfCoreError.invalidRequest("an attachment size is outside the bounded range")
            }
            guard attachment.sha256.utf8.count == 64,
                  attachment.sha256.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else {
                throw FloeMacSelfCoreError.invalidRequest("an attachment digest is not a lowercase SHA-256 hex")
            }
            guard !attachment.bookmark.isEmpty,
                  attachment.bookmark.count <= maximumAttachmentBookmarkBytes else {
                throw FloeMacSelfCoreError.invalidRequest("an attachment bookmark is missing or unbounded")
            }
            guard !attachment.displayName.utf8.contains(0) else {
                throw FloeMacSelfCoreError.invalidRequest("an attachment name must not contain NUL")
            }
        }
    }

    static func validate(_ context: FloeMacSelfRunContext) throws {
        if let name = context.workspaceName {
            guard name.utf8.count <= maximumWorkspaceNameBytes else {
                throw FloeMacSelfCoreError.invalidRequest("the workspace name is too long")
            }
        }
        if let selected = context.selectedRelativePath {
            guard selected.utf8.count <= maximumSelectedPathBytes,
                  !selected.hasPrefix("/"),
                  !selected.split(separator: "/", omittingEmptySubsequences: false)
                    .contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else {
                throw FloeMacSelfCoreError.invalidRequest("the selected file path must be bounded and workspace-relative")
            }
        }
        if let target = context.executionTarget {
            guard target.utf8.count <= maximumExecutionTargetBytes else {
                throw FloeMacSelfCoreError.invalidRequest("the execution target label is too long")
            }
        }
        if let instructions = context.projectInstructions {
            guard instructions.utf8.count <= maximumProjectInstructionsBytes else {
                throw FloeMacSelfCoreError.invalidRequest("the project instructions exceed the bounded context size")
            }
        }
        guard context.activeSkillIDs.count <= 64,
              context.activeSkillIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
              (context.skillInstructions?.utf8.count ?? 0) <= maximumProjectInstructionsBytes else {
            throw FloeMacSelfCoreError.invalidRequest("skill context exceeds the bounded context size")
        }
        if let listing = context.workspaceListing {
            guard listing.utf8.count <= maximumWorkspaceListingBytes else {
                throw FloeMacSelfCoreError.invalidRequest("the workspace listing exceeds the bounded context size")
            }
        }
        guard context.workspaceNotes.count <= maximumWorkspaceNotes,
              context.workspaceNotes.allSatisfy({ $0.utf8.count <= maximumWorkspaceNoteBytes }) else {
            throw FloeMacSelfCoreError.invalidRequest("workspace notes exceed the bounded context size")
        }
    }

    static func validate(
        toolsEnabled: Bool,
        request: FloeMacSelfSessionRequest,
        boundary: FloeMacSelfTaskBoundary?
    ) throws {
        guard toolsEnabled else { return }
        guard let boundary else {
            throw FloeMacSelfCoreError.toolCapabilityUnavailable(
                "a tool-enabled session requires an explicit task boundary"
            )
        }
        guard let requestedWorkspaceID = request.workspaceID else {
            throw FloeMacSelfCoreError.invalidTaskBoundary(
                "a tool-enabled session must name its existing task workspace"
            )
        }
        guard boundary.workspaceID == requestedWorkspaceID else {
            throw FloeMacSelfCoreError.invalidTaskBoundary(
                "the tool boundary workspace does not match the requested task workspace"
            )
        }
    }
}

/// Accepted-plan execution proof for the prepared user turn. The launch
/// transaction already validated the embedded plan-confirmation proof
/// (`floe.plan.confirmation.v1`: exact plan id/revision/digest, accepted
/// status, executionRunID == run, executionPrompt == goal) and consumed the
/// message exactly once. This read-back only re-checks the plain identity
/// facts; it never re-validates arbitrary historical messages.
enum FloeMacSelfPreparedConfirmationInput {
    static func verify(
        _ message: PersistedMessage,
        messageID: UUID,
        conversationID: UUID,
        runID: UUID,
        goal: String
    ) throws {
        guard message.id == messageID, message.conversationID == conversationID,
              message.runID == runID, message.role == "user",
              message.content.utf8.elementsEqual(goal.utf8) else {
            throw FloeMacSelfCoreError.preparedIdentityMismatch(
                "the consumed confirmation message does not match the planned execution"
            )
        }
        guard let textPart = message.parts.first(where: {
            $0.kind == .text && $0.messageID == message.id && $0.partIndex == 0
        }), textPart.text?.utf8.elementsEqual(goal.utf8) == true,
        textPart.metadata[PlanConfirmationSnapshot.metadataKey] != nil else {
            throw FloeMacSelfCoreError.preparedIdentityMismatch(
                "the consumed message is not the committed plan confirmation"
            )
        }
    }
}

/// Narrow chat proof for the prepared user turn: the exact text plus, in
/// order, one part per durable attachment. This is an observed database
/// read, not a request journal binding or an atomic lock against
/// independent writers.
enum FloeMacSelfPreparedInput {
    static func verify(
        _ message: PersistedMessage,
        messageID: UUID,
        conversationID: UUID,
        runID: UUID,
        goal: String,
        expectedAttachments: [AttachmentRef] = []
    ) throws {
        guard message.id == messageID, message.conversationID == conversationID,
              message.runID == runID, message.role == "user",
              message.content.utf8.elementsEqual(goal.utf8),
              message.parts.count == expectedAttachments.count + 1 else {
            throw FloeMacSelfCoreError.preparedIdentityMismatch("durable user input does not match the prepared run")
        }
        let textPart = message.parts[0]
        guard textPart.messageID == messageID, textPart.partIndex == 0,
              textPart.kind == .text, textPart.attachmentID == nil, textPart.metadata.isEmpty,
              let text = textPart.text, text.utf8.elementsEqual(goal.utf8) else {
            throw FloeMacSelfCoreError.preparedIdentityMismatch("durable user input does not match the prepared run")
        }
        for (offset, attachment) in expectedAttachments.enumerated() {
            let part = message.parts[offset + 1]
            let expectedKind: MessagePart.Kind = attachment.kind == .image ? .image : .file
            guard part.messageID == messageID, part.partIndex == offset + 1,
                  part.kind == expectedKind,
                  part.attachmentID == attachment.id,
                  part.text == nil,
                  part.metadata["name"] == attachment.displayName else {
                throw FloeMacSelfCoreError.preparedIdentityMismatch("durable attachment parts do not match the prepared run")
            }
        }
    }
}
