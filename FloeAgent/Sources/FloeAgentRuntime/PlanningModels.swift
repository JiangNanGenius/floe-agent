import Foundation
import FloeCore
import FloePersistence
import FloeSecurity

/// The execution contract selected for a conversation turn.
public enum ConversationMode: String, Sendable, Codable, Hashable, CaseIterable {
    /// A normal single-turn conversation. Compiled tools may be available.
    case chat
    /// Read-only discovery that may persist only Floe-owned plan drafts.
    case plan
    /// A persistent, budgeted run that works toward evidence-backed criteria.
    case goal
}

/// The model's recommendation is advisory and visible before acceptance. A
/// user may always force ordinary execution or durable Goal execution.
public enum PlanExecutionRecommendation: String, Sendable, Codable, Hashable, CaseIterable {
    case normal
    case goal
}

public enum PlanStatus: String, Sendable, Codable, Hashable, CaseIterable {
    case drafting
    case awaitingInput
    case ready
    case accepted
    case superseded
    case archived
}

public struct PlanSourceReference: Sendable, Codable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case message
        case conversation
        case file
        case web
        case artifact
    }

    public var id: UUID
    public var kind: Kind
    public var locator: String
    public var title: String?

    public init(id: UUID = UUID(), kind: Kind, locator: String, title: String? = nil) {
        self.id = id
        self.kind = kind
        self.locator = locator
        self.title = title
    }
}

public struct PlanSection: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var body: String
    public var order: Int
    public var sourceReferenceIDs: [UUID]

    public init(
        id: UUID = UUID(),
        title: String,
        body: String,
        order: Int,
        sourceReferenceIDs: [UUID] = []
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.order = order
        self.sourceReferenceIDs = sourceReferenceIDs
    }
}

public struct PlanAssumption: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var text: String
    public var isAccepted: Bool

    public init(id: UUID = UUID(), text: String, isAccepted: Bool = false) {
        self.id = id
        self.text = text
        self.isAccepted = isAccepted
    }
}

public struct PlanRisk: Sendable, Codable, Hashable, Identifiable {
    public enum Severity: String, Sendable, Codable, Hashable, Comparable {
        case low
        case medium
        case high

        public static func < (lhs: Self, rhs: Self) -> Bool {
            let order: [Self] = [.low, .medium, .high]
            return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
        }
    }

    public var id: UUID
    public var text: String
    public var mitigation: String?
    public var severity: Severity

    public init(
        id: UUID = UUID(),
        text: String,
        mitigation: String? = nil,
        severity: Severity = .medium
    ) {
        self.id = id
        self.text = text
        self.mitigation = mitigation
        self.severity = severity
    }
}

public struct PlanCriterion: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var text: String
    public var verification: String

    public init(id: UUID = UUID(), text: String, verification: String) {
        self.id = id
        self.text = text
        self.verification = verification
    }
}

/// An immutable revision of a plan. Editing creates a new value with a
/// monotonically increasing revision and a digest supplied by persistence.
public struct PlanDraft: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var conversationID: UUID
    public var workspaceID: UUID?
    public var revision: Int
    public var status: PlanStatus
    public var title: String
    public var summary: String
    public var sections: [PlanSection]
    public var assumptions: [PlanAssumption]
    public var risks: [PlanRisk]
    public var acceptanceCriteria: [PlanCriterion]
    public var sourceMessageIDs: [UUID]
    public var sourceReferences: [PlanSourceReference]
    public var executionRecommendation: PlanExecutionRecommendation?
    public var recommendationReason: String?
    public var digest: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        workspaceID: UUID? = nil,
        revision: Int = 1,
        status: PlanStatus = .drafting,
        title: String,
        summary: String,
        sections: [PlanSection] = [],
        assumptions: [PlanAssumption] = [],
        risks: [PlanRisk] = [],
        acceptanceCriteria: [PlanCriterion] = [],
        sourceMessageIDs: [UUID] = [],
        sourceReferences: [PlanSourceReference] = [],
        executionRecommendation: PlanExecutionRecommendation? = .normal,
        recommendationReason: String? = nil,
        digest: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        precondition(revision > 0, "Plan revisions start at one")
        self.id = id
        self.conversationID = conversationID
        self.workspaceID = workspaceID
        self.revision = revision
        self.status = status
        self.title = title
        self.summary = summary
        self.sections = sections
        self.assumptions = assumptions
        self.risks = risks
        self.acceptanceCriteria = acceptanceCriteria
        self.sourceMessageIDs = sourceMessageIDs
        self.sourceReferences = sourceReferences
        self.executionRecommendation = executionRecommendation
        self.recommendationReason = recommendationReason
        self.digest = digest
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var hasUnresolvedDecisions: Bool {
        status == .awaitingInput || assumptions.contains { !$0.isAccepted }
    }

    /// Only unfinished drafts belong in the persistent confirmation area.
    public var awaitsConfirmation: Bool {
        status == .drafting || status == .awaitingInput || status == .ready
    }

    public var isDecisionComplete: Bool {
        (status == .ready || status == .accepted)
            && !hasUnresolvedDecisions
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sections.isEmpty
            && !acceptanceCriteria.isEmpty
            && !acceptanceCriteria.contains {
                $0.verification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }

    /// Creates a new revision without mutating the source revision.
    public func revised(
        status: PlanStatus = .drafting,
        title: String? = nil,
        summary: String? = nil,
        sections: [PlanSection]? = nil,
        assumptions: [PlanAssumption]? = nil,
        risks: [PlanRisk]? = nil,
        acceptanceCriteria: [PlanCriterion]? = nil,
        sourceMessageIDs: [UUID]? = nil,
        sourceReferences: [PlanSourceReference]? = nil,
        executionRecommendation: PlanExecutionRecommendation? = nil,
        recommendationReason: String? = nil,
        digest: String = "",
        now: Date = Date()
    ) -> PlanDraft {
        PlanDraft(
            id: id,
            conversationID: conversationID,
            workspaceID: workspaceID,
            revision: revision + 1,
            status: status,
            title: title ?? self.title,
            summary: summary ?? self.summary,
            sections: sections ?? self.sections,
            assumptions: assumptions ?? self.assumptions,
            risks: risks ?? self.risks,
            acceptanceCriteria: acceptanceCriteria ?? self.acceptanceCriteria,
            sourceMessageIDs: sourceMessageIDs ?? self.sourceMessageIDs,
            sourceReferences: sourceReferences ?? self.sourceReferences,
            executionRecommendation: executionRecommendation ?? self.executionRecommendation,
            recommendationReason: recommendationReason ?? self.recommendationReason,
            digest: digest,
            createdAt: createdAt,
            updatedAt: now
        )
    }
}

/// Value snapshot stored on the existing user message, never a live lookup
/// of latestPlan. Revisions and later Goal edits cannot rewrite this card.
public struct PlanConfirmationSnapshot: Codable, Sendable, Hashable {
    public static let metadataKey = "floe.plan.confirmation.v1"
    public let schemaVersion: Int
    public let plan: PlanDraft
    public let sourceRevision: Int
    public let execution: PlanExecutionRecommendation
    public let executionRunID: UUID
    public let goalID: UUID?
    public let executionPrompt: String

    public init(plan: PlanDraft, sourceRevision: Int, execution: PlanExecutionRecommendation,
                executionRunID: UUID, goalID: UUID?, executionPrompt: String) {
        self.schemaVersion = 1; self.plan = plan; self.sourceRevision = sourceRevision
        self.execution = execution; self.executionRunID = executionRunID
        self.goalID = goalID; self.executionPrompt = executionPrompt
    }

    public static func messageID(conversationID: UUID, planID: UUID, sourceRevision: Int) -> UUID {
        let hash = Array(FloeDigest.sha256Hex(Data(
            "floe.plan.confirmation.v1|\(conversationID)|\(planID)|\(sourceRevision)".utf8)).prefix(32))
        let value = String(hash[0..<8]) + "-" + String(hash[8..<12]) + "-"
            + String(hash[12..<16]) + "-" + String(hash[16..<20]) + "-" + String(hash[20..<32])
        return UUID(uuidString: value)!
    }

    public var messageID: UUID {
        Self.messageID(conversationID: plan.conversationID, planID: plan.id, sourceRevision: sourceRevision)
    }

    public func encoded() throws -> String {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public static func decode(_ value: String) throws -> Self {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let result = try decoder.decode(Self.self, from: Data(value.utf8))
        guard result.schemaVersion == 1, result.sourceRevision > 0,
              result.sourceRevision < Int.max,
              result.plan.revision == result.sourceRevision + 1,
              result.plan.status == .accepted, result.plan.isDecisionComplete,
              (result.execution == .goal) == (result.goalID != nil),
              !result.executionPrompt.isEmpty else {
            throw FloeError.storageCorrupted(FloeL10n.isChinese ? "已确认的计划记录无法读取，请重新打开任务。" : "The confirmed plan snapshot is invalid")
        }
        return result
    }

    public static func from(message: PersistedMessage) -> Self? {
        guard message.role == "user", let part = message.parts.first(where: {
            $0.kind == .text && $0.messageID == message.id && $0.partIndex == 0
        }), let raw = part.metadata[metadataKey], let value = try? decode(raw),
              value.messageID == message.id, value.plan.conversationID == message.conversationID,
              value.executionPrompt == message.content,
              message.runID == nil || message.runID == value.executionRunID else { return nil }
        return value
    }
}

public struct PlanConfirmationReceipt: Sendable {
    public let snapshot: PlanConfirmationSnapshot
    public let goal: ConversationGoal?
    public let wasCreated: Bool
}

/// Uses the ordinary ingress scanner before writing a new confirmation.
/// Captures stay in memory until the App's existing credential boundary has
/// stored them; only their references enter the accepted revision and card.
struct PlanConfirmationIngress: Sendable {
    let plan: PlanDraft
    let executionPrompt: String
    let captures: [CapturedSecret]

    init(_ source: PlanDraft) throws {
        var captures: [CapturedSecret] = []
        var safe = source.mappingConfirmationText { text in
            let result = SecretIngressScanner.scan(text)
            captures.append(contentsOf: result.captures)
            return result.sanitizedText
        }
        // Formatting can bring a label and its value from separate fields
        // together. Scan the final prompt too, then redact those same values
        // in the frozen display data; never persist raw text in metadata.
        let prompt = SecretIngressScanner.scan(GoalFromPlanFactory.implementationPrompt(from: safe))
        captures.append(contentsOf: prompt.captures)
        if !prompt.captures.isEmpty {
            safe = safe.mappingConfirmationText { text in
                prompt.captures.reduce(text) { value, capture in
                    value.replacingOccurrences(of: String(decoding: capture.value, as: UTF8.self),
                                               with: capture.placeholder)
                }
            }
        }
        let canonical = prompt.sanitizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let checked = SecretIngressScanner.scan(canonical)
        guard !canonical.isEmpty, checked.captures.isEmpty, checked.sanitizedText == canonical,
              canonical == GoalFromPlanFactory.implementationPrompt(from: safe)
                .trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw FloeError.validationFailed(FloeL10n.isChinese
                ? "计划暂时无法安全确认，请修改后重试。" : "The plan could not be safely confirmed. Revise it and try again.")
        }
        self.plan = safe; self.executionPrompt = canonical; self.captures = captures
    }
}

private extension PlanDraft {
    func mappingConfirmationText(_ transform: (String) -> String) -> PlanDraft {
        var value = self
        value.title = transform(title); value.summary = transform(summary)
        value.sections = sections.map { item in
            var item = item; item.title = transform(item.title); item.body = transform(item.body); return item
        }
        value.assumptions = assumptions.map { item in
            var item = item; item.text = transform(item.text); return item
        }
        value.risks = risks.map { item in
            var item = item; item.text = transform(item.text); item.mitigation = item.mitigation.map(transform); return item
        }
        value.acceptanceCriteria = acceptanceCriteria.map { item in
            var item = item; item.text = transform(item.text); item.verification = transform(item.verification); return item
        }
        value.sourceReferences = sourceReferences.map { item in
            var item = item; item.locator = transform(item.locator); item.title = item.title.map(transform); return item
        }
        value.recommendationReason = recommendationReason.map(transform)
        return value
    }
}

/// Strict payload for the internal `plan.submit` native tool. Unlike parsing
/// display Markdown, every field needed by the review/acceptance UI is typed.
public struct PlanSubmission: Sendable, Codable, Hashable {
    public struct Section: Sendable, Codable, Hashable {
        public var title: String
        public var body: String
        public init(title: String, body: String) { self.title = title; self.body = body }
    }

    public struct Risk: Sendable, Codable, Hashable {
        public var text: String
        public var mitigation: String
        public var severity: PlanRisk.Severity
        public init(text: String, mitigation: String, severity: PlanRisk.Severity) {
            self.text = text; self.mitigation = mitigation; self.severity = severity
        }
    }

    public struct Criterion: Sendable, Codable, Hashable {
        public var text: String
        public var verification: String
        public init(text: String, verification: String) {
            self.text = text; self.verification = verification
        }
    }

    public var title: String
    public var summary: String
    public var sections: [Section]
    public var assumptions: [String]
    public var risks: [Risk]
    public var acceptanceCriteria: [Criterion]
    public var executionRecommendation: PlanExecutionRecommendation
    public var recommendationReason: String

    public init(
        title: String,
        summary: String,
        sections: [Section],
        assumptions: [String] = [],
        risks: [Risk] = [],
        acceptanceCriteria: [Criterion],
        executionRecommendation: PlanExecutionRecommendation = .normal,
        recommendationReason: String = ""
    ) {
        self.title = title
        self.summary = summary
        self.sections = sections
        self.assumptions = assumptions
        self.risks = risks
        self.acceptanceCriteria = acceptanceCriteria
        self.executionRecommendation = executionRecommendation
        self.recommendationReason = recommendationReason
    }

    public var validationErrors: [String] {
        var errors: [String] = []
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("title") }
        if summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("summary") }
        if sections.isEmpty { errors.append("sections") }
        if sections.contains(where: { $0.title.isEmpty || $0.body.isEmpty }) { errors.append("section content") }
        if acceptanceCriteria.isEmpty { errors.append("acceptanceCriteria") }
        if acceptanceCriteria.contains(where: { $0.text.isEmpty || $0.verification.isEmpty }) {
            errors.append("criterion verification")
        }
        if executionRecommendation == .goal && recommendationReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Goal recommendation reason")
        }
        return errors
    }

    public func draft(conversationID: UUID, prior: PlanDraft? = nil) -> PlanDraft {
        let mappedSections = sections.enumerated().map {
            PlanSection(title: $0.element.title, body: $0.element.body, order: $0.offset)
        }
        let mappedAssumptions = assumptions.map { PlanAssumption(text: $0, isAccepted: true) }
        let mappedRisks = risks.map {
            PlanRisk(text: $0.text, mitigation: $0.mitigation, severity: $0.severity)
        }
        let mappedCriteria = acceptanceCriteria.map {
            PlanCriterion(text: $0.text, verification: $0.verification)
        }
        if let prior {
            return prior.revised(
                status: .ready,
                title: title,
                summary: summary,
                sections: mappedSections,
                assumptions: mappedAssumptions,
                risks: mappedRisks,
                acceptanceCriteria: mappedCriteria,
                executionRecommendation: executionRecommendation,
                recommendationReason: recommendationReason
            )
        }
        return PlanDraft(
            conversationID: conversationID,
            status: .ready,
            title: title,
            summary: summary,
            sections: mappedSections,
            assumptions: mappedAssumptions,
            risks: mappedRisks,
            acceptanceCriteria: mappedCriteria,
            executionRecommendation: executionRecommendation,
            recommendationReason: recommendationReason
        )
    }

    public static let toolName = "plan.submit"
    public static let clarificationGuidance = """
    Resolve material ambiguity through user.ask before plan.submit. Before finalizing a plan, identify decisions that change the goal, scope, acceptance or a costly tradeoff. Reuse prior answers and narrow factual reads. If a material decision remains, use user.ask when offered (otherwise ask concise choices plainly), keeping its custom-answer field BEFORE plan.submit; important direction uses required with no timer/default. A request for a complete plan or uninterrupted work does not turn an unresolved user decision into permission to guess. Low-impact choices retain the configured optional deadline/default rules. Do not add ceremonial questions to a clear task. Example: “Build a site” with no audience or required outcome → ask the outcome choices first, then plan from the answer. “Rename this file to report.csv; preserve its contents” → no redundant QA. Each plan step states an action, concrete deliverable, verification and dependencies or none; split by executable outcomes, never to meet a fixed count.
    """
    public static let toolDescription =
        "Submit the reviewed implementation plan only after material goal/scope/acceptance and costly tradeoffs are clarified with user.ask. Do not invent a product direction to finish a plan. Every ordered step needs a concrete action, deliverable, verification and dependencies (or none); split by executable outcomes, not a fixed count. Call once when ready after read-only investigation and necessary answers; never emit pseudo tool-call text."
    public static let parametersJSON = #"""
    {
      "type":"object",
      "properties":{
        "title":{"type":"string"},
        "summary":{"type":"string"},
        "sections":{"type":"array","description":"Ordered executable steps at the task's actual scale; no fixed step count and no vague catch-all phases.","items":{"type":"object","properties":{"title":{"type":"string","description":"Specific action and its target."},"body":{"type":"string","description":"State the action, concrete deliverable, acceptance/verification evidence, and dependencies/prerequisites or explicitly none. Split independent outcomes so each step can be executed and checked."}},"required":["title","body"],"additionalProperties":false}},
        "assumptions":{"type":"array","items":{"type":"string"}},
        "risks":{"type":"array","items":{"type":"object","properties":{"text":{"type":"string"},"mitigation":{"type":"string"},"severity":{"type":"string","enum":["low","medium","high"]}},"required":["text","mitigation","severity"],"additionalProperties":false}},
        "acceptanceCriteria":{"type":"array","items":{"type":"object","properties":{"text":{"type":"string"},"verification":{"type":"string"}},"required":["text","verification"],"additionalProperties":false}},
        "executionRecommendation":{"type":"string","enum":["normal","goal"]},
        "recommendationReason":{"type":"string"}
      },
      "required":["title","summary","sections","assumptions","risks","acceptanceCriteria","executionRecommendation","recommendationReason"],
      "additionalProperties":false
    }
    """#
}

public struct PlanReadinessReview: Sendable, Codable, Hashable {
    public var missingDecisions: [String]
    public var missingEvidence: [String]
    public var reviewModelVerified: Bool

    public init(
        missingDecisions: [String] = [],
        missingEvidence: [String] = [],
        reviewModelVerified: Bool = false
    ) {
        self.missingDecisions = missingDecisions
        self.missingEvidence = missingEvidence
        self.reviewModelVerified = reviewModelVerified
    }

    public var isReady: Bool { missingDecisions.isEmpty && missingEvidence.isEmpty }
}

/// Deterministic portion of Plan-mode readiness. Model review is advisory:
/// if unavailable, the draft may still be ready but is marked unverified.
public enum PlanReadinessGate {
    public static func evaluate(
        _ draft: PlanDraft,
        referencedEnvironmentVerified: Bool,
        modelReview: PlanReadinessReview? = nil
    ) -> PlanReadinessReview {
        var decisions: [String] = []
        var evidence: [String] = []
        if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            decisions.append("title")
        }
        if draft.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            decisions.append("summary")
        }
        if draft.sections.isEmpty { decisions.append("implementation sections") }
        if draft.hasUnresolvedDecisions { decisions.append("unresolved assumptions or questions") }
        if draft.acceptanceCriteria.isEmpty { evidence.append("acceptance criteria") }
        if draft.acceptanceCriteria.contains(where: {
            $0.verification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            evidence.append("criterion verification")
        }
        if !referencedEnvironmentVerified { evidence.append("environment references") }
        if let modelReview {
            decisions.append(contentsOf: modelReview.missingDecisions)
            evidence.append(contentsOf: modelReview.missingEvidence)
        }
        return PlanReadinessReview(
            missingDecisions: Array(Set(decisions)).sorted(),
            missingEvidence: Array(Set(evidence)).sorted(),
            reviewModelVerified: modelReview?.reviewModelVerified ?? false
        )
    }
}

public enum GoalFromPlanFactory {
    /// The execution objective is derived from the accepted implementation
    /// structure. A planning-stage summary remains historical plan content;
    /// it must not become the next stage's operative instructions.
    public static func implementationObjective(from plan: PlanDraft) -> String {
        let steps = plan.sections.sorted { $0.order < $1.order }.map { "- \($0.title)" }.joined(separator: "\n")
        let criteria = plan.acceptanceCriteria.map { "- \($0.text) (\($0.verification))" }.joined(separator: "\n")
        let title = FloeL10n.isChinese ? "实现并交付已确认计划：" : "Implement and deliver the accepted plan: "
        let outcomes = FloeL10n.isChinese ? "实施结果：" : "Implementation outcomes:"
        let verification = FloeL10n.isChinese ? "验收标准：" : "Verify completion against:"
        return "\(title)\(plan.title)\n\(outcomes)\n\(steps)\n\(verification)\n\(criteria)"
    }

    public static func implementationPrompt(from plan: PlanDraft) -> String {
        let ordered = plan.sections.sorted { $0.order < $1.order }
            .map { "## \($0.title)\n\($0.body)" }.joined(separator: "\n\n")
        let criteria = plan.acceptanceCriteria.map { "- \($0.text): \($0.verification)" }.joined(separator: "\n")
        let assumptions = plan.assumptions.map { "- \($0.text)" }.joined(separator: "\n")
        let risks = plan.risks.map { "- \($0.text)\($0.mitigation.map { ": " + $0 } ?? "")" }.joined(separator: "\n")
        return """
        Execute the accepted implementation plan below. Preserve its ordering and verify each criterion with inspectable evidence. Continue until safe in-scope implementation and delivery are complete.
        # \(plan.title)
        \(ordered)
        Acceptance criteria:
        \(criteria)
        Accepted assumptions and constraints:
        \(assumptions)
        Risks and mitigations:
        \(risks)
        This is the implementation stage. The earlier planning summary describes the previous stage, not the current objective. Preserve the user's original explicit limits and existing task approvals. Plan acceptance does not authorize external sends or broader access.
        """
    }

    public static func makeGoal(
        from plan: PlanDraft,
        budgets: GoalBudgets = GoalBudgets()
    ) throws -> ConversationGoal {
        guard plan.isDecisionComplete else {
            throw PlanConversionError.planNotDecisionComplete
        }
        let criteria = plan.acceptanceCriteria.map {
            GoalCriterion(text: $0.text)
        }
        let steps = plan.sections.sorted(by: { $0.order < $1.order }).enumerated().map { index, section in
            GoalStep(title: section.title, detail: section.body, order: index)
        }
        return ConversationGoal(
            conversationID: plan.conversationID,
            sourcePlanID: plan.id,
            sourcePlanDigest: plan.digest,
            objective: implementationObjective(from: plan),
            acceptanceCriteria: criteria,
            steps: steps,
            budgets: budgets
        )
    }
}

public enum PlanConversionError: Error, Sendable, Codable, Hashable {
    case planNotDecisionComplete
}
