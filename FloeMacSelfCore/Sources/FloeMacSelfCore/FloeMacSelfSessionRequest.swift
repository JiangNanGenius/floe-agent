// SPDX-License-Identifier: MPL-2.0
//
// Bounded launch request for one Mac chat session. This is a native host
// request, not model-authored data. It intentionally supports only ordinary
// chat in this stage: Goal and Plan composition remain later integration work
// and fail closed instead of being silently half-wired.

import Foundation
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

    public init(
        workspaceName: String? = nil,
        selectedRelativePath: String? = nil,
        executionTarget: String? = nil,
        projectInstructions: String? = nil,
        workspaceNotes: [String] = [],
        workspaceListing: String? = nil
    ) {
        self.workspaceName = workspaceName
        self.selectedRelativePath = selectedRelativePath
        self.executionTarget = executionTarget
        self.projectInstructions = projectInstructions
        self.workspaceNotes = workspaceNotes
        self.workspaceListing = workspaceListing
    }
}

/// One durable file attachment for a Mac session. The host supplies a
/// read-only security-scoped bookmark created at pick time; the composition
/// persists only metadata and the digest beside the launch transaction.
/// Image attachments are inlined into the model request by the existing
/// runtime; document attachments are durable-only in this stage and are not
/// model-visible yet.
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
    public let attachments: [FloeMacSelfSessionAttachment]
    /// True selects the existing Floe chat envelope (brief conversational
    /// instructions). Set false for task-style tool work. This flag never
    /// grants a tool; the tool binding still requires the explicit ceiling.
    public let chatFastMode: Bool
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
        guard request.mode == .chat else {
            throw FloeMacSelfCoreError.unsupportedConversationMode(
                request.mode == .goal
                    ? "durable Goal composition is not part of this stage"
                    : "Plan composition is not part of this stage"
            )
        }
        try validate(request.attachments)
        try validate(request.context)
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
