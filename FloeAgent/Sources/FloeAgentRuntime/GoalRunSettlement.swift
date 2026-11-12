// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Cumulative usage of one exact admitted run, never a request to resume or
/// redefine its long-term Goal. Native Core derives these values from events.
public struct GoalRunSettlementInput: Sendable {
    public let runID: UUID
    public let conversationID: UUID
    public let goalID: UUID
    public let admissionRevision: Int?
    public let admissionDefinitionFingerprint: String?
    public let modelCallCount: Int
    public let toolIterationCount: Int
    public let evidence: [GoalEvidence]
    public let completed: Bool
    public init(runID: UUID, conversationID: UUID, goalID: UUID, admissionRevision: Int?,
                admissionDefinitionFingerprint: String?, modelCallCount: Int, toolIterationCount: Int,
                evidence: [GoalEvidence], completed: Bool) {
        self.runID = runID; self.conversationID = conversationID; self.goalID = goalID
        self.admissionRevision = admissionRevision; self.admissionDefinitionFingerprint = admissionDefinitionFingerprint
        self.modelCallCount = modelCallCount; self.toolIterationCount = toolIterationCount
        self.evidence = evidence; self.completed = completed
    }
}
public struct GoalRunSettlementResult: Sendable {
    public let goal: ConversationGoal
    public let definitionMatched: Bool
    public let didRecordChange: Bool
    public let cycleCounted: Bool
}
/// Stored only in existing goal_events under the fixed native kind. It is
/// not Goal evidence and cannot satisfy a criterion or grant any permission.
struct GoalRunAccountingReceipt: Codable, Sendable {
    let runID: UUID
    let goalID: UUID
    let admissionRevision: Int?
    let admissionDefinitionFingerprint: String?
    let modelCallCount: Int
    let toolIterationCount: Int
    let cycleCounted: Bool
}

struct GoalRunAdmissionPayload: Decodable {
    let kind: String?
    let state: String?
    let goalID: UUID?
    let hasGoalIdentity: Bool
    let goalRevision: Int?
    let goalDefinitionFingerprint: String?
    var isNativeAdmission: Bool { kind == "goalRoundAdmission" || state == "preparing" }

    private enum CodingKeys: String, CodingKey {
        case kind, state, goalID, goalRevision, goalDefinitionFingerprint
    }
    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        kind = try fields.decodeIfPresent(String.self, forKey: .kind)
        state = try fields.decodeIfPresent(String.self, forKey: .state)
        hasGoalIdentity = fields.contains(.goalID) && (try? fields.decodeNil(forKey: .goalID)) != true
        goalID = (try? fields.decode(String.self, forKey: .goalID)).flatMap(UUID.init(uuidString:))
        if let value = try? fields.decode(String.self, forKey: .goalRevision) {
            goalRevision = Int(value)
        } else {
            goalRevision = try? fields.decode(Int.self, forKey: .goalRevision)
        }
        goalDefinitionFingerprint = try fields.decodeIfPresent(String.self, forKey: .goalDefinitionFingerprint)
    }
}

/// Native event projection. Unknown receipt fields (including numeric timing
/// and Bool flags) cannot invalidate otherwise valid identity/result fields.
/// A successful-looking model string is never a dispatch receipt.
struct GoalRunEventPayload: Decodable {
    let kind: String?
    let status: String?
    let id: String?
    let tool: String?
    let input: String?
    let summary: String?
    let outputDigest: String?
    let dispatched: Bool

    private enum CodingKeys: String, CodingKey {
        case kind, status, id, tool, input, summary, outputDigest, dispatched
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        kind = try fields.decodeIfPresent(String.self, forKey: .kind)
        status = try fields.decodeIfPresent(String.self, forKey: .status)
        id = try fields.decodeIfPresent(String.self, forKey: .id)
        tool = try fields.decodeIfPresent(String.self, forKey: .tool)
        input = try fields.decodeIfPresent(String.self, forKey: .input)
        summary = try fields.decodeIfPresent(String.self, forKey: .summary)
        outputDigest = try fields.decodeIfPresent(String.self, forKey: .outputDigest)
        if let value = try? fields.decode(Bool.self, forKey: .dispatched) {
            dispatched = value
        } else {
            dispatched = (try? fields.decode(String.self, forKey: .dispatched)) == "true"
        }
    }
}
