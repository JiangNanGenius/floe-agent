// FloeAgentRuntime — UI-facing activity state that is NOT conversation
// content.
//
// Three runtime facts otherwise have no honest, typed surface before the final
// answer:
//
//  * compression: whether history compaction is being considered, running,
//    succeeded, failed, or was triggered by a provider overflow. The UI shows
//    a compact inline state, never a modal, and the run keeps working.
//  * outcome classification: a first-design missing target/binding or an
//    approval/resource wait is not a hidden budget failure and must not be
//    rendered as one. Every settled call gets a deterministic class and the
//    recovery the model may still attempt.
// Slow tool arguments reuse the existing provider liveness path
// (`ProviderStreamRequest.onToolArgumentsProgress` -> `handleToolArgumentsProgress`
// -> `.preparingToolCall`); this file only carries the delayed-phase note, not
// a parallel state machine.
//
// These values are presentation/diagnostic state. They never grant authority,
// never change provider context, and never mark unverified work as done.

import Foundation
import FloeModels

public struct ContextCompressionSnapshot: Sendable, Codable, Hashable {
    public enum Phase: String, Sendable, Codable, Hashable {
        case idle
        /// Sizing the real request before dispatch (system/history/schemas/
        /// images/output reserve).
        case sizing
        /// History compaction is running.
        case compacting
        /// Compaction committed; `messages` now hold the verified summary and
        /// the recent exact tail.
        case compacted
        /// Compaction failed and the old records were preserved.
        case failed
        /// A real provider context-overflow was observed and one bounded
        /// recovery is in progress.
        case overflowRecovery
        /// Fixed tool schemas were reduced to complete definitions that fit,
        /// so history compaction is not attempted for a schema-only overflow.
        case schemasReduced
    }

    public var phase: Phase
    public var reason: String?
    public var beforeTokens: Int?
    public var afterTokens: Int?
    public var availableInputTokens: Int?
    public var toolSchemaTokens: Int?
    /// Number of older messages replaced by the summary (0 for a no-op).
    public var compactedMessageCount: Int
    public var at: Date

    public init(
        phase: Phase,
        reason: String? = nil,
        beforeTokens: Int? = nil,
        afterTokens: Int? = nil,
        availableInputTokens: Int? = nil,
        toolSchemaTokens: Int? = nil,
        compactedMessageCount: Int = 0,
        at: Date = Date()
    ) {
        self.phase = phase
        self.reason = reason
        self.beforeTokens = beforeTokens
        self.afterTokens = afterTokens
        self.availableInputTokens = availableInputTokens
        self.toolSchemaTokens = toolSchemaTokens
        self.compactedMessageCount = max(0, compactedMessageCount)
        self.at = at
    }
}

public struct ToolOutcomeClassification: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case completed
        /// Some evidence was produced but the tool reported an incomplete or
        /// partially executed outcome.
        case partial
        case failed
        /// The design is recoverable by a concrete argument/target change.
        case recoverableDesign
        /// A human approval/open panel is required before the run can proceed.
        case waitingForUser
        /// A finite resource (job, environment, download, lock) is still in
        /// progress.
        case waitingForResource
        /// A policy/permission decision denied this call.
        case denied
        case cancelled
        /// The same unchanged route repeated without progress.
        case noProgress
    }

    public enum Recovery: String, Sendable, Codable, Hashable {
        case none
        case fixArgumentsOrTarget
        case satisfyPrerequisite
        case requestApproval
        case waitForResource
        case readCapturedResult
        case reportBlocker
    }

    public var callID: String
    public var toolName: String
    public var status: String
    public var kind: Kind
    public var recovery: Recovery
    /// Bounded, user-safe explanation. Never contains raw tool output.
    public var reason: String

    public init(
        callID: String,
        toolName: String,
        status: String,
        kind: Kind,
        recovery: Recovery,
        reason: String
    ) {
        self.callID = callID
        self.toolName = toolName
        self.status = status
        self.kind = kind
        self.recovery = recovery
        self.reason = String(reason.prefix(400))
    }

    /// True for outcomes that are a wait/design/permission state rather than
    /// evidence of a hidden budget or a dead end. The loop guard may warn but
    /// must not convert a first one into "all tools disabled".
    public var isRecoverableWithoutDisablingTools: Bool {
        switch kind {
        case .waitingForUser, .waitingForResource, .denied, .cancelled:
            return true
        case .recoverableDesign, .partial:
            return true
        case .completed, .failed, .noProgress:
            return false
        }
    }
}

public enum ToolOutcomeClassifier {
    /// Classifies one settled result. Deliberately text-pattern based over
    /// post-redaction output only: it never infers from the model name, and a
    /// failed status alone is not enough to call a result a hard error.
    public static func classify(
        call: ToolCall,
        result: ToolResult,
        noProgress: Bool = false
    ) -> ToolOutcomeClassification {
        let text = result.outputSummary.lowercased()
        if noProgress {
            return .init(
                callID: call.id,
                toolName: call.toolName,
                status: result.status.rawValue,
                kind: .noProgress,
                recovery: .reportBlocker,
                reason: "The unchanged route repeated without new evidence; change the approach or report the blocker."
            )
        }
        switch result.status {
        case .ok:
            if containsAny(text, partialMarkers) {
                return .init(
                    callID: call.id,
                    toolName: call.toolName,
                    status: result.status.rawValue,
                    kind: .partial,
                    recovery: .readCapturedResult,
                    reason: "The tool reported an incomplete outcome; read the retained result before concluding."
                )
            }
            return .init(
                callID: call.id,
                toolName: call.toolName,
                status: result.status.rawValue,
                kind: .completed,
                recovery: .none,
                reason: "The call completed."
            )
        case .needsUser:
            return .init(
                callID: call.id,
                toolName: call.toolName,
                status: result.status.rawValue,
                kind: .waitingForUser,
                recovery: .requestApproval,
                reason: "The call needs a visible user action or approval before it can continue."
            )
        case .denied:
            return .init(
                callID: call.id,
                toolName: call.toolName,
                status: result.status.rawValue,
                kind: .denied,
                recovery: .requestApproval,
                reason: "Policy or the user denied this call; the run keeps its other tools and may request authorization."
            )
        case .cancelled, .expired:
            return .init(
                callID: call.id,
                toolName: call.toolName,
                status: result.status.rawValue,
                kind: .cancelled,
                recovery: .none,
                reason: "The call did not complete because it was cancelled or expired."
            )
        case .failed:
            if containsAny(text, resourceWaitMarkers) {
                return .init(
                    callID: call.id,
                    toolName: call.toolName,
                    status: result.status.rawValue,
                    kind: .waitingForResource,
                    recovery: .waitForResource,
                    reason: "The result describes a finite resource/lifecycle wait, not a budget failure."
                )
            }
            if containsAny(text, prerequisiteMarkers) {
                return .init(
                    callID: call.id,
                    toolName: call.toolName,
                    status: result.status.rawValue,
                    kind: .recoverableDesign,
                    recovery: .satisfyPrerequisite,
                    reason: "A required predecessor state is missing; resolve it and retry."
                )
            }
            if containsAny(text, approvalMarkers) {
                return .init(
                    callID: call.id,
                    toolName: call.toolName,
                    status: result.status.rawValue,
                    kind: .waitingForUser,
                    recovery: .requestApproval,
                    reason: "The call needs an approval/open authorization action before it can run."
                )
            }
            if containsAny(text, designMarkers) {
                return .init(
                    callID: call.id,
                    toolName: call.toolName,
                    status: result.status.rawValue,
                    kind: .recoverableDesign,
                    recovery: .fixArgumentsOrTarget,
                    reason: "A missing target, binding or argument shape can be fixed without stopping the task."
                )
            }
            if containsAny(text, partialMarkers) {
                return .init(
                    callID: call.id,
                    toolName: call.toolName,
                    status: result.status.rawValue,
                    kind: .partial,
                    recovery: .readCapturedResult,
                    reason: "The call failed after producing partial evidence; the retained output is still available."
                )
            }
            return .init(
                callID: call.id,
                toolName: call.toolName,
                status: result.status.rawValue,
                kind: .failed,
                recovery: .reportBlocker,
                reason: "The call failed without a known recoverable design fix."
            )
        }
    }

    static func containsAny(_ text: String, _ markers: [String]) -> Bool {
        markers.contains { text.contains($0) }
    }

    static let partialMarkers = [
        "partial", "incomplete", "some files could not", "truncated", "timed out after producing",
        "未完成", "部分完成", "已截断"
    ]
    static let resourceWaitMarkers = [
        "still running", "in progress", "pending", "job is", "waiting for", "not ready",
        "try again after", "download in progress", "resource busy", "lock is held",
        "仍在运行", "等待", "尚未就绪", "占用中"
    ]
    static let prerequisiteMarkers = [
        "prerequisite", "requires state", "must be connected first", "not connected",
        "call environment.linuxstatus", "start the environment", "先连接", "需要先启动"
    ]
    static let approvalMarkers = [
        "approval", "approve", "authorization", "not authorized", "needs your permission",
        "request user action", "请批准", "需要授权"
    ]
    static let designMarkers = [
        "missing target", "target is required", "invalid target", "no target", "unbound",
        "missing binding", "not bound", "no task binding", "missing required", "required argument",
        "invalid argument", "unknown parameter",
        // A stale/missing CAD/document target is recoverable by refreshing the
        // binding or revision; it is not a budget failure and must not shut
        // down unrelated tools.
        "revision mismatch", "stale revision", "document not found", "no document",
        "staged document", "目标缺失", "未绑定", "缺少参数", "修订不一致", "版本不匹配", "文档不存在"
    ]
}
