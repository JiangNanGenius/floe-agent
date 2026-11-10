// FloeModels — typed, evidence-backed execution experience.
//
// Execution experience is deliberately SEPARATE from:
//  * durable user facts / profile memory (MemoryDreamService path), and
//  * executable installed skills (SkillDreamService / skill store).
//
// Contract enforced by these types and their consumers:
//  * A record captures only reusable procedure STRUCTURE — tool names,
//    outcome/recovery CATEGORIES, observed ordering roles and evidence
//    identity (opaque run/call identifiers and the deterministic capture
//    ref). It never carries raw arguments, output text, summaries, digests,
//    filenames, addresses, project data, secrets, environment identifiers,
//    permissions or model-authored standing authority.
//  * An observation of a settled tool sequence is NOT proof that the final
//    artifact is correct. `sealedOutputEvidence` means the runtime actually
//    attached a sealed run-output/artifact receipt to a completed step; it
//    is still a lower-authority historical signal.
//  * A dispatch receipt that never settled (a `pending` toolRequest or a
//    job-start without a terminal receipt) has no representation here at
//    all; the ingestion bridge rejects it.
//  * Workspace-scoped records recall only inside the exact same workspace;
//    generic records must not contain project literals (guaranteed by
//    construction plus `structuralValidationIssue()`).
//  * Temporary conversations never feed this store; ingestion rejects the
//    flag before anything is derived.

import Foundation
import FloeCore

// MARK: - Scope

/// Where an experience record may be recalled. `.workspace` records are
/// fenced to the exact workspace identity; `.generic` records are the only
/// cross-workspace surface and must remain literal-free.
public enum ExecutionExperienceScope: Sendable, Codable, Hashable {
    case generic
    case workspace(UUID)

    /// Canonical, stable string used in signature/identity hashing and SQL.
    public var canonical: String {
        switch self {
        case .generic: return "g"
        case .workspace(let id): return "w:" + id.uuidString.lowercased()
        }
    }

    public var workspaceID: UUID? {
        if case .workspace(let id) = self { return id }
        return nil
    }

    public init(canonical: String) throws {
        if canonical == "g" {
            self = .generic
        } else if canonical.hasPrefix("w:"),
                  canonical.count == 2 + 36,
                  let id = UUID(uuidString: String(canonical.dropFirst(2))) {
            self = .workspace(id)
        } else {
            throw FloeError.validationFailed("Unknown execution experience scope")
        }
    }
}

// MARK: - Outcome vocabulary

/// Mirrors the runtime's `ToolOutcomeClassification.Kind` raw values. It is
/// the only outcome truth an experience record may carry; waiting, partial,
/// denied and cancelled states can NEVER be promoted to completion.
public enum ExecutionOutcomeKind: String, Sendable, Codable, Hashable, CaseIterable {
    case completed
    case partial
    case failed
    case recoverableDesign
    case waitingForUser
    case waitingForResource
    case denied
    case cancelled
    case noProgress

    public var isCompleted: Bool { self == .completed }

    /// Terminal, non-completed outcomes that count as honest failures.
    public var isFailureLike: Bool {
        switch self {
        case .failed, .denied, .cancelled, .noProgress: return true
        case .partial, .recoverableDesign: return false
        case .completed, .waitingForUser, .waitingForResource: return false
        }
    }

    public var isPartialLike: Bool { self == .partial || self == .recoverableDesign }
    public var isWaitingLike: Bool { self == .waitingForUser || self == .waitingForResource }
}

/// Mirrors `ToolOutcomeClassification.Recovery` raw values.
public enum ExecutionToolRecovery: String, Sendable, Codable, Hashable, CaseIterable {
    case none
    case fixArgumentsOrTarget
    case satisfyPrerequisite
    case requestApproval
    case waitForResource
    case readCapturedResult
    case reportBlocker
}

/// Typed task conclusion category (mirrors `TaskRunConclusion`). It is only
/// counted as `closedRunObservations` when a run actually concluded
/// completed under the existing authoritative gates.
public enum ExecutionRunConclusion: String, Sendable, Codable, Hashable, CaseIterable {
    case completed
    case failed
    case checkpointed
    case cancelled
}

/// Honest evidence ladder. Ordering matters for ranking; nothing here ever
/// claims verified final-artifact correctness, only what was observed.
public enum ExecutionEvidenceStrength: String, Sendable, Codable, Hashable, Comparable {
    case observedCompletion
    case sealedOutputEvidence

    public static func < (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.observedCompletion, .sealedOutputEvidence): return true
        default: return false
        }
    }

    public static func maximum(_ lhs: Self, _ rhs: Self) -> Self {
        lhs < rhs ? rhs : lhs
    }
}

/// Derived structural role of a completed step inside the procedure.
public enum ExecutionStepRole: String, Sendable, Codable, Hashable {
    case prerequisite
    case primary
    case verification
}

// MARK: - Limits

/// Single source of truth for the bounds the whole loop must respect.
public enum ExecutionExperienceLimits {
    public static let maximumStepsPerObservation = 32
    public static let minimumSettledSteps = 1
    public static let maximumRetainedProcedureSteps = 12
    public static let retainedProcedureLeadCount = 4
    public static let maximumRecoveryPatterns = 8
    public static let maximumEvidenceAnchors = 16
    public static let maximumToolNameLength = 64
    public static let maximumCallIDLength = 128
    public static let maximumCaptureRefLength = 27
    public static let maximumRecordsPerScope = 48
    public static let maximumTotalRecords = 256
    public static let recallDefaultMaxRecords = 3
    public static let recallCharacterBudget = 1_600
    public static let recallMaxAgeDays = 90
    public static let retentionDays = 180
    public static let maximumCounter = 1_000_000

    /// Tool names are canonical catalog identifiers (`domain.action`).
    public static func isSafeToolName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumToolNameLength else { return false }
        var first = true
        for character in value {
            if first {
                guard character.isLetter || character.isNumber else { return false }
                first = false
            }
            if character.isLetter || character.isNumber { continue }
            if character == "." || character == "_" || character == "-" || character == ":" {
                continue
            }
            return false
        }
        return true
    }

    /// Provider-assigned call ids: opaque tokens, never free text.
    public static func isSafeCallID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumCallIDLength else { return false }
        return value.allSatisfy {
            $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII
                || $0 == "-" || $0 == "_" || $0 == ":"
        }
    }

    /// The deterministic `tr_`-prefixed capture reference produced by the
    /// runtime retention store. It is an identity, never content.
    public static func isSafeCaptureRef(_ value: String) -> Bool {
        if value.isEmpty { return false }
        guard value.utf8.count <= maximumCaptureRefLength else { return false }
        guard value.hasPrefix("tr_"), value.count == 27 else { return false }
        return value.dropFirst(3).allSatisfy { character in
            character.isASCII && character.isHexDigit
        }
    }

    /// Whitelist used for the data-minimal property check. Every persisted
    /// string leaf must match this set (tool names, enum raw values,
    /// call ids, capture refs, hashes).
    public static func isMinimalToken(_ value: String) -> Bool {
        guard value.utf8.count <= 128 else { return false }
        return value.allSatisfy { character in
            (character.isASCII && (character.isLetter || character.isNumber))
                || character == "." || character == "-" || character == "_"
                || character == ":"
        }
    }

    /// Deterministic ids in this loop are SHA-256 hex digests.
    public static func isSafeDigestID(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        return value.allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}

// MARK: - Observation inputs

/// One settled tool receipt as observed by the native capture path.
/// Built ONLY from the persisted lifecycle facts (tool id, typed outcome,
/// dispatch flag, capture ref) — never from assistant text, raw arguments
/// or output summaries. The step deliberately carries NO sealed-output
/// field: sealing is a verdict the caller supplies separately, only when
/// an actual native receipt passed integrity verification (sealed
/// run-output/artifact digest re-check or a retained capture receipt),
/// never because an `artifactRefsJSON` field appeared in some payload.
public struct ExecutionStepObservation: Sendable, Codable, Hashable {
    public var toolName: String
    public var callID: String
    public var outcome: ExecutionOutcomeKind
    public var recovery: ExecutionToolRecovery
    /// True only when the native record actually dispatched the call.
    public var dispatched: Bool
    /// Deterministic `tr_` ref when a retention receipt exists.
    public var captureRef: String?
    public var settledAt: Date
    /// Attested happens-before relation to the NEXT step. Parallel calls
    /// requested in one batch are NOT causally ordered, so the collector
    /// must set this to false across unordered boundaries; derivation
    /// then canonically sorts the group instead of inventing a sequence.
    public var orderAttestedBeforeNext: Bool

    public init(
        toolName: String,
        callID: String,
        outcome: ExecutionOutcomeKind,
        recovery: ExecutionToolRecovery,
        dispatched: Bool,
        captureRef: String?,
        settledAt: Date,
        orderAttestedBeforeNext: Bool = true
    ) {
        self.toolName = toolName
        self.callID = callID
        self.outcome = outcome
        self.recovery = recovery
        self.dispatched = dispatched
        self.captureRef = captureRef
        self.settledAt = settledAt
        self.orderAttestedBeforeNext = orderAttestedBeforeNext
    }

    public func structuralValidationIssue() -> String? {
        if !ExecutionExperienceLimits.isSafeToolName(toolName) {
            return "Unsafe tool identifier in step observation"
        }
        if !ExecutionExperienceLimits.isSafeCallID(callID) {
            return "Unsafe call identifier in step observation"
        }
        if let captureRef, !ExecutionExperienceLimits.isSafeCaptureRef(captureRef) {
            return "Unsafe capture reference in step observation"
        }
        // A completed outcome without an actual dispatch is a contradictory
        // receipt (e.g. a job-start projected as success). Never admitted.
        if outcome.isCompleted && !dispatched {
            return "Completed outcome without a dispatch receipt"
        }
        return nil
    }
}

/// One bounded settled sequence from a single run — the ingestion unit.
public struct ExecutionSequenceObservation: Sendable, Codable, Identifiable, Hashable {
    public var id: String
    public var conversationID: UUID
    public var runID: UUID
    /// nil ⇒ the capture path attests this is not bound to a workspace, so
    /// only a literal-free generic record may derive from it.
    public var workspaceID: UUID?
    public var isTemporaryConversation: Bool
    public var steps: [ExecutionStepObservation]
    public var runConclusion: ExecutionRunConclusion?
    public var observedAt: Date

    public init(
        conversationID: UUID,
        runID: UUID,
        workspaceID: UUID?,
        isTemporaryConversation: Bool,
        steps: [ExecutionStepObservation],
        runConclusion: ExecutionRunConclusion?,
        observedAt: Date = Date()
    ) {
        self.conversationID = conversationID
        self.runID = runID
        self.workspaceID = workspaceID
        self.isTemporaryConversation = isTemporaryConversation
        self.steps = steps
        self.runConclusion = runConclusion
        self.observedAt = observedAt
        self.id = Self.deterministicID(
            runID: runID,
            callIDs: steps.map(\.callID)
        )
    }

    /// Deterministic, reorder-stable ingestion identity: hash of the run
    /// identity plus the ordered settled call ids.
    public static func deterministicID(runID: UUID, callIDs: [String]) -> String {
        var material = "v1|obs|" + runID.uuidString.lowercased()
        for callID in callIDs {
            material += "|" + callID
        }
        return FloeDigest.sha256Hex(Data(material.utf8))
    }

    public func structuralValidationIssue() -> String? {
        if isTemporaryConversation {
            return "Temporary conversations never feed the experience store"
        }
        if steps.isEmpty {
            return "Experience observation has no settled steps"
        }
        if steps.count > ExecutionExperienceLimits.maximumStepsPerObservation {
            return "Experience observation exceeds the step bound"
        }
        var seenCallIDs = Set<String>()
        for step in steps {
            if let issue = step.structuralValidationIssue() { return issue }
            if seenCallIDs.contains(step.callID) {
                return "Duplicate call id inside one observation"
            }
            seenCallIDs.insert(step.callID)
        }
        let expected = Self.deterministicID(runID: runID, callIDs: steps.map(\.callID))
        if id != expected {
            return "Observation identity does not match its settled receipts"
        }
        return nil
    }
}

/// The deterministic evidence anchor of one settled receipt. Identities
/// only: they point into the runtime's existing authoritative ledgers.
public struct ExecutionExperienceEvidenceAnchor: Sendable, Codable, Hashable {
    public var runID: UUID
    public var callID: String
    public var captureRef: String?

    public init(runID: UUID, callID: String, captureRef: String?) {
        self.runID = runID
        self.callID = callID
        self.captureRef = captureRef
    }

    public func structuralValidationIssue() -> String? {
        if !ExecutionExperienceLimits.isSafeCallID(callID) {
            return "Unsafe call identifier in evidence anchor"
        }
        if let captureRef, !ExecutionExperienceLimits.isSafeCaptureRef(captureRef) {
            return "Unsafe capture reference in evidence anchor"
        }
        return nil
    }
}

// MARK: - Derived record

/// A single step of the retained procedure structure.
public struct ExecutionProcedureStep: Sendable, Codable, Hashable {
    public var toolName: String
    public var outcome: ExecutionOutcomeKind
    /// Derived positional tag (data heuristic, NOT a causality claim).
    public var role: ExecutionStepRole
    public var producesSealedOutput: Bool
    /// True order grouping. Steps with the SAME `groupId` were observed in
    /// one parallel batch with NO attested happens-before between them;
    /// their stored relative order is a canonical tiebreak, not a required
    /// sequence. Steps in strictly different groups have an attested
    /// happens-before from the earlier group to the later one.
    public var groupId: Int

    public init(
        toolName: String,
        outcome: ExecutionOutcomeKind,
        role: ExecutionStepRole,
        producesSealedOutput: Bool,
        groupId: Int
    ) {
        self.toolName = toolName
        self.outcome = outcome
        self.role = role
        self.producesSealedOutput = producesSealedOutput
        self.groupId = groupId
    }
}

/// An observed failure→later-success structure inside one run. Failure
/// kinds stay failure kinds; `resolved` only says a later completed step
/// of the same run followed it.
public struct ExecutionRecoveryPattern: Sendable, Codable, Hashable {
    public var failingTool: String
    public var failureKind: ExecutionOutcomeKind
    public var recovery: ExecutionToolRecovery
    public var resolvedWithTool: String?

    public init(
        failingTool: String,
        failureKind: ExecutionOutcomeKind,
        recovery: ExecutionToolRecovery,
        resolvedWithTool: String?
    ) {
        self.failingTool = failingTool
        self.failureKind = failureKind
        self.recovery = recovery
        self.resolvedWithTool = resolvedWithTool
    }

    public var isResolved: Bool { resolvedWithTool != nil }

    fileprivate var key: String {
        failingTool + "|" + failureKind.rawValue + "|" + recovery.rawValue
            + "|" + (resolvedWithTool ?? "")
    }
}

/// The persisted, data-minimal experience record.
public struct ExecutionExperienceRecord: Sendable, Codable, Identifiable, Hashable {
    public var id: String
    public var signature: String
    public var scope: ExecutionExperienceScope
    /// Opaque originating-workspace locator (UUID identity only, never a
    /// name/path). Set for every observation bound to a workspace,
    /// including ones explicitly derived as `generic` records, so the
    /// existing evidence trail stays followable and workspace deletion can
    /// clear the pointer. `scope` alone remains the recall authority.
    public var originWorkspaceID: UUID?
    public var steps: [ExecutionProcedureStep]
    public var recoveryPatterns: [ExecutionRecoveryPattern]
    public var evidence: ExecutionEvidenceStrength

    /// Number of distinct settled observations merged into this record.
    public var occurrenceCount: Int
    public var completedStepObservations: Int
    public var failedStepObservations: Int
    public var partialStepObservations: Int
    public var waitingStepObservations: Int
    public var recoveredFailureObservations: Int
    public var closedRunObservations: Int
    public var firstObservedAt: Date
    public var lastObservedAt: Date

    public init(
        signature: String,
        scope: ExecutionExperienceScope,
        originWorkspaceID: UUID?,
        steps: [ExecutionProcedureStep],
        recoveryPatterns: [ExecutionRecoveryPattern],
        evidence: ExecutionEvidenceStrength,
        occurrenceCount: Int,
        completedStepObservations: Int,
        failedStepObservations: Int,
        partialStepObservations: Int,
        waitingStepObservations: Int,
        recoveredFailureObservations: Int,
        closedRunObservations: Int,
        firstObservedAt: Date,
        lastObservedAt: Date
    ) {
        self.signature = signature
        self.scope = scope
        self.originWorkspaceID = originWorkspaceID
        self.steps = steps
        self.recoveryPatterns = recoveryPatterns
        self.evidence = evidence
        self.occurrenceCount = occurrenceCount
        self.completedStepObservations = completedStepObservations
        self.failedStepObservations = failedStepObservations
        self.partialStepObservations = partialStepObservations
        self.waitingStepObservations = waitingStepObservations
        self.recoveredFailureObservations = recoveredFailureObservations
        self.closedRunObservations = closedRunObservations
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
        self.id = Self.recordID(scope: scope, signature: signature)
    }

    // MARK: Identity

    /// Signature that binds the true order grouping: each attested group
    /// contributes its canonically sorted tool multiset, and groups appear
    /// in attested order. A parallel batch of two tools is therefore a
    /// DIFFERENT procedure from a verified sequential chain of the same
    /// tools, so nothing that was not proven ordered can be stored or
    /// rendered as if it were.
    public static func signature(
        scope: ExecutionExperienceScope,
        steps: [ExecutionProcedureStep]
    ) -> String {
        var material = "v1|sig2|" + scope.canonical
        var index = 0
        while index < steps.count {
            var end = index
            while end < steps.count, steps[end].groupId == steps[index].groupId {
                end += 1
            }
            let toolsInGroup = steps[index..<end].map(\.toolName).sorted()
            material += "|g" + String(steps[index].groupId) + ":"
                + toolsInGroup.joined(separator: ",")
            index = end
        }
        return FloeDigest.sha256Hex(Data(material.utf8))
    }

    public static func recordID(scope: ExecutionExperienceScope, signature: String) -> String {
        FloeDigest.sha256Hex(Data(("v1|exp|" + scope.canonical + "|" + signature).utf8))
    }

    /// Deterministic, monotonic merge. Same id/scope/signature records only;
    /// counters never decrease and evidence never weakens.
    public func merged(with newer: ExecutionExperienceRecord) -> ExecutionExperienceRecord {
        precondition(id == newer.id && scope == newer.scope && signature == newer.signature,
                     "Only same-identity records may merge")
        var steps = self.steps
        if steps.count == newer.steps.count {
            for index in steps.indices {
                steps[index].producesSealedOutput =
                    steps[index].producesSealedOutput || newer.steps[index].producesSealedOutput
            }
        }
        var patterns = recoveryPatterns
        var seen = Set(patterns.map(\.key))
        for pattern in newer.recoveryPatterns where !seen.contains(pattern.key) {
            patterns.append(pattern)
            seen.insert(pattern.key)
        }
        if patterns.count > ExecutionExperienceLimits.maximumRecoveryPatterns {
            // Deterministic trimming: resolved patterns first, then the
            // stable lexicographic order of their keys.
            patterns.sort { lhs, rhs in
                if lhs.isResolved != rhs.isResolved { return lhs.isResolved }
                return lhs.key < rhs.key
            }
            patterns = Array(patterns.prefix(ExecutionExperienceLimits.maximumRecoveryPatterns))
        }
        let clampCap = ExecutionExperienceLimits.maximumCounter
        func clamped(_ value: Int) -> Int { min(max(0, value), clampCap) }
        return ExecutionExperienceRecord(
            signature: signature,
            scope: scope,
            originWorkspaceID: originWorkspaceID ?? newer.originWorkspaceID,
            steps: steps,
            recoveryPatterns: patterns,
            evidence: ExecutionEvidenceStrength.maximum(evidence, newer.evidence),
            occurrenceCount: clamped(occurrenceCount + newer.occurrenceCount),
            completedStepObservations: clamped(completedStepObservations + newer.completedStepObservations),
            failedStepObservations: clamped(failedStepObservations + newer.failedStepObservations),
            partialStepObservations: clamped(partialStepObservations + newer.partialStepObservations),
            waitingStepObservations: clamped(waitingStepObservations + newer.waitingStepObservations),
            recoveredFailureObservations: clamped(recoveredFailureObservations + newer.recoveredFailureObservations),
            closedRunObservations: clamped(closedRunObservations + newer.closedRunObservations),
            firstObservedAt: min(firstObservedAt, newer.firstObservedAt),
            lastObservedAt: max(lastObservedAt, newer.lastObservedAt)
        )
    }

    public var toolNames: Set<String> { Set(steps.map(\.toolName)) }

    /// True when every attested group of `self` is identical (equal tool
    /// sequences) to the corresponding group of `newer` — the precondition
    /// for a monotonic merge. Different grouping is a schema/data conflict,
    /// never silently reinterpreted.
    public func sameGroupedProcedureStructure(as newer: ExecutionExperienceRecord) -> Bool {
        guard steps.count == newer.steps.count else { return false }
        for (mine, theirs) in zip(steps, newer.steps) {
            if mine.groupId != theirs.groupId || mine.toolName != theirs.toolName {
                return false
            }
        }
        return true
    }

    /// Full structural + data-minimality validation. Used by both the
    /// deriving policy and the storing layer (defense in depth).
    public func structuralValidationIssue() -> String? {
        if case .workspace(let scopeID) = scope,
           let origin = originWorkspaceID, origin != scopeID {
            return "Workspace-scoped record's origin locator contradicts its scope"
        }
        if steps.isEmpty { return "Experience record has no procedure steps" }
        if steps.count > ExecutionExperienceLimits.maximumRetainedProcedureSteps {
            return "Experience record exceeds the retained step bound"
        }
        if recoveryPatterns.count > ExecutionExperienceLimits.maximumRecoveryPatterns {
            return "Experience record exceeds the recovery pattern bound"
        }
        var expectedGroup = -1
        for step in steps {
            if !ExecutionExperienceLimits.isSafeToolName(step.toolName) {
                return "Unsafe tool name in experience record"
            }
            if step.outcome != .completed {
                return "Only completed steps may form the procedure"
            }
            if step.groupId < 0 || step.groupId > expectedGroup + 1 {
                return "Procedure groups must start at 0 and rise by at most one"
            }
            if step.groupId == expectedGroup + 1 {
                expectedGroup += 1
            } else if step.groupId != expectedGroup {
                return "Procedure groups must form contiguous runs"
            }
        }
        for pattern in recoveryPatterns {
            if !ExecutionExperienceLimits.isSafeToolName(pattern.failingTool) {
                return "Unsafe failing tool name in recovery pattern"
            }
            if pattern.failureKind.isCompleted || pattern.failureKind.isWaitingLike {
                return "Recovery pattern failure kind must be terminal non-completed"
            }
            if let resolvedWithTool = pattern.resolvedWithTool,
               !ExecutionExperienceLimits.isSafeToolName(resolvedWithTool) {
                return "Unsafe resolving tool name in recovery pattern"
            }
        }
        if occurrenceCount < 1 || occurrenceCount > ExecutionExperienceLimits.maximumCounter {
            return "Experience occurrence counter out of range"
        }
        for counter in [completedStepObservations, failedStepObservations,
                        partialStepObservations, waitingStepObservations,
                        recoveredFailureObservations, closedRunObservations] {
            if counter < 0 || counter > ExecutionExperienceLimits.maximumCounter {
                return "Experience stat counter out of range"
            }
        }
        if firstObservedAt > lastObservedAt {
            return "Experience timeline is inverted"
        }
        if id != Self.recordID(scope: scope, signature: signature) {
            return "Experience identity does not match its canonical material"
        }
        if signature != Self.signature(scope: scope, steps: steps) {
            return "Experience signature does not match its procedure"
        }
        return nil
    }

    /// Serialized form with the store's canonical codec settings.
    public func canonicalJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// Data-minimality property shared by the deriving policy and the
    /// storing layer (single authority, defense in depth): the serialized
    /// record must contain nothing but whitelisted identifier tokens and
    /// enum raw values. Dates encode as numbers, so any string leaf outside
    /// the whitelist means content leaked into a "structure-only" record.
    public func satisfiesDataMinimality() -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(self),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            return false
        }
        var strings: [String] = []
        Self.collectStrings(root, into: &strings)
        return strings.allSatisfy { ExecutionExperienceLimits.isMinimalToken($0) }
    }

    private static func collectStrings(_ value: Any, into strings: inout [String]) {
        switch value {
        case let dictionary as [String: Any]:
            for (key, nested) in dictionary {
                strings.append(key)
                collectStrings(nested, into: &strings)
            }
        case let array as [Any]:
            for nested in array { collectStrings(nested, into: &strings) }
        case let string as String:
            strings.append(string)
        default:
            break
        }
    }
}

/// Explicit, caller-attested scope selection. Derivation NEVER infers the
/// scope from the presence or absence of a workspace id: choosing `.generic`
/// asserts that the value of this observation is its minimised tool/outcome/
/// order/recovery STRUCTURE alone (cross-task reusable), while `.workspace`
/// asserts the exact original workspace binding. The originating workspace
/// identity is retained as an opaque evidence locator even on generic
/// records, so workspace deletion can still clear the locator; faking a
/// missing workspace to "downgrade" a record into another scope is not
/// expressible here.
public enum ExecutionExperienceScopeChoice: String, Sendable, Codable, Hashable {
    case workspace
    case generic
}

// MARK: - Recall query

/// Scope+availability+relevance+bounds contract the persistence layer
/// enforces. Availability alone is NEVER sufficient: `availableToolNames`
/// is usually the whole enabled catalog, which cannot make an arbitrary
/// old procedure relevant. The current task's ACTIVATED/matched tool
/// family (`activatedToolNames`, e.g. the tools actually surfaced for
/// this task by discovery/selection) must overlap the procedure by at
/// least `activationMinimumOverlapRatio`, and a query without any
/// activation signal recalls NOTHING (fail-closed).
public struct ExecutionExperienceRecallQuery: Sendable, Codable, Hashable {
    /// Exact workspace being recalled INTO. nil ⇒ generic records only.
    public var workspaceID: UUID?
    /// The current catalog's enabled tool names. nil ⇒ availability is
    /// unknown and the store skips that filter (the runtime policy must
    /// supply the set whenever it renders guidance).
    public var availableToolNames: Set<String>?
    /// The tool family activated for THIS task. nil or empty ⇒ no recall.
    public var activatedToolNames: Set<String>?
    /// Fraction of a procedure's step tools that must be activated.
    public var activationMinimumOverlapRatio: Double
    public var notOlderThan: Date?
    public var minimumEvidence: ExecutionEvidenceStrength?
    public var maxRecords: Int?

    public init(
        workspaceID: UUID?,
        availableToolNames: Set<String>? = nil,
        activatedToolNames: Set<String>? = nil,
        activationMinimumOverlapRatio: Double = 0.5,
        notOlderThan: Date? = nil,
        minimumEvidence: ExecutionEvidenceStrength? = nil,
        maxRecords: Int? = nil
    ) {
        self.workspaceID = workspaceID
        self.availableToolNames = availableToolNames
        self.activatedToolNames = activatedToolNames
        self.activationMinimumOverlapRatio = min(max(0, activationMinimumOverlapRatio), 1)
        self.notOlderThan = notOlderThan
        self.minimumEvidence = minimumEvidence
        self.maxRecords = maxRecords
    }

    /// Activation overlap for one record: intersected step tools over the
    /// record's distinct step tools. Deterministic and id-independent.
    public static func activationOverlapRatio(
        record: ExecutionExperienceRecord,
        activated: Set<String>
    ) -> Double {
        guard !record.toolNames.isEmpty else { return 0 }
        let overlap = record.toolNames.intersection(activated).count
        return Double(overlap) / Double(record.toolNames.count)
    }
}
