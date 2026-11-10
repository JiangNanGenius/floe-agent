import Foundation

/// A data-minimal bridge from native, settled run records to historical
/// workflow evidence. Callers construct events/outcomes from the owning
/// service/store, never from assistant prose or model-supplied evidence IDs.
/// This collector does not establish final artifact correctness.
public enum ExecutionExperienceEvidenceCollector {
    public struct Event: Sendable {
        public enum Kind: Sendable { case request, result }
        public let id: UUID
        public let runID: UUID
        public let sequence: Int
        public let kind: Kind
        public let payloadJSON: String
        public let createdAt: Date

        public init(id: UUID, runID: UUID, sequence: Int, kind: Kind, payloadJSON: String,
                    createdAt: Date = .distantPast) {
            self.id = id; self.runID = runID; self.sequence = sequence
            self.kind = kind; self.payloadJSON = payloadJSON; self.createdAt = createdAt
        }
    }

    public struct NativeOutcome: Sendable {
        public let callID: String
        public let toolName: String
        public let status: String
        /// Raw value of the native ToolOutcomeClassification.Kind.
        public let kind: String
        /// Raw value of the native ToolOutcomeClassification.Recovery.
        public let recovery: String

        public init(callID: String, toolName: String, status: String, kind: String,
                    recovery: String = "none") {
            self.callID = callID; self.toolName = toolName
            self.status = status; self.kind = kind; self.recovery = recovery
        }
    }

    public struct SettledCall: Sendable, Equatable {
        public let callID: String
        public let toolName: String
        public let requestEventID: UUID
        public let resultEventID: UUID
        public let requestSequence: Int
        public let resultSequence: Int
        public let status: String
        public let outcomeKind: String
        public let recovery: String
        public let outputDigest: String?
        public let settledAt: Date

        /// An observed happens-before relation, not proof of a prerequisite.
        /// Calls requested in one parallel batch have no inferred ordering.
        public func wasObservedBefore(_ other: Self) -> Bool {
            resultSequence < other.requestSequence
        }
    }

    public struct Snapshot: Sendable {
        public enum Rejection: String, Sendable { case temporary, unfinishedRun, mixedRun, ambiguousOrder }
        public let calls: [SettledCall]
        public let rejection: Rejection?
        public let omittedEventCount: Int
        public let ignoredCallCount: Int
    }

    public static let maximumEvents = 192
    public static let maximumCalls = 24
    public static let maximumPayloadBytes = 128 * 1_024

    public static func collect(
        runID: UUID,
        isTemporary: Bool,
        sourceRunCompleted: Bool,
        events: [Event],
        outcomes: [NativeOutcome],
        availableToolNames: Set<String>
    ) -> Snapshot {
        func rejected(_ reason: Snapshot.Rejection) -> Snapshot {
            .init(calls: [], rejection: reason, omittedEventCount: 0, ignoredCallCount: 0)
        }
        guard !isTemporary else { return rejected(.temporary) }
        guard sourceRunCompleted else { return rejected(.unfinishedRun) }
        guard events.allSatisfy({ $0.runID == runID }) else { return rejected(.mixedRun) }
        guard Set(events.map(\.id)).count == events.count,
              Set(events.map(\.sequence)).count == events.count,
              events.allSatisfy({ $0.sequence >= 0 }) else {
            return rejected(.ambiguousOrder)
        }
        let ordered = events.sorted { $0.sequence < $1.sequence }
        let bounded = Array(ordered.suffix(maximumEvents))
        let omitted = ordered.count - bounded.count
        var requests: [String: (Event, String)] = [:]
        var results: [String: (Event, [String: String])] = [:]
        var conflicts = Set<String>()
        for event in bounded {
            guard let payload = payload(event.payloadJSON),
                  let callID = payload["id"], identifier(callID, maximum: 256),
                  let name = payload["tool"], identifier(name, maximum: 128),
                  availableToolNames.contains(name) else { continue }
            switch event.kind {
            case .request:
                if requests[callID] != nil { conflicts.insert(callID) }
                else { requests[callID] = (event, name) }
            case .result:
                if results[callID] != nil { conflicts.insert(callID) }
                else { results[callID] = (event, payload) }
            }
        }
        var classifications: [String: NativeOutcome] = [:]
        for outcome in outcomes.suffix(maximumEvents) {
            if classifications[outcome.callID] != nil { conflicts.insert(outcome.callID) }
            else { classifications[outcome.callID] = outcome }
        }
        var captured: [SettledCall] = []
        for (callID, (request, name)) in requests {
            guard !conflicts.contains(callID),
                  let (result, body) = results[callID],
                  request.sequence < result.sequence,
                  body["tool"] == name, body["dispatched"] == "true",
                  let status = body["status"],
                  let classification = classifications[callID],
                  classification.toolName == name, classification.status == status else { continue }
            // jobs.submit/status/result return an OK *query/acceptance*
            // receipt even while the underlying native job is unfinished.
            // The general outcome classifier therefore cannot establish its
            // completion. Read only the native JobView envelope, never the
            // job's output text, and require its actual terminal success.
            guard jobReceiptCompleted(toolName: name, summary: body["summary"]) else { continue }
            // Waits, partial work, denial, cancellation and unchanged-route
            // suppression are never promoted into successful procedures.
            let completed = status == "ok" && classification.kind == "completed"
            let failed = status == "failed" &&
                ["failed", "recoverableDesign"].contains(classification.kind)
            guard completed || failed else { continue }
            let digest = body["outputDigest"].flatMap { value in
                value.range(of: #"^[a-fA-F0-9]{64}$"#, options: .regularExpression) == nil ? nil : value
            }
            captured.append(.init(callID: callID, toolName: name,
                requestEventID: request.id, resultEventID: result.id,
                requestSequence: request.sequence, resultSequence: result.sequence,
                status: status, outcomeKind: classification.kind, recovery: classification.recovery,
                outputDigest: digest, settledAt: result.createdAt))
        }
        captured.sort { $0.requestSequence < $1.requestSequence }
        let kept = Array(captured.suffix(maximumCalls))
        return .init(calls: kept, rejection: nil, omittedEventCount: omitted,
                     ignoredCallCount: requests.count - kept.count)
    }

    private static func payload(_ json: String) -> [String: String]? {
        guard json.utf8.count <= maximumPayloadBytes,
              let data = json.data(using: .utf8) else { return nil }
        // Decode the native string-map shape. Raw input, summary and output
        // references are deliberately never copied into the returned value.
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    private static func jobReceiptCompleted(toolName: String, summary: String?) -> Bool {
        guard ["jobs.submit", "jobs.status", "jobs.result"].contains(toolName) else { return true }
        guard let summary, summary.utf8.count <= maximumPayloadBytes,
              let data = summary.data(using: .utf8),
              let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        let job = envelope["job"] as? [String: Any] ?? envelope
        guard let jobID = job["jobID"] as? String, UUID(uuidString: jobID) != nil else { return false }
        return job["state"] as? String == "completed"
    }

    private static func identifier(_ value: String, maximum: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximum else { return false }
        return value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) ||
                [UInt8(95), 46, 58, 47, 45].contains($0)
        }
    }
}
