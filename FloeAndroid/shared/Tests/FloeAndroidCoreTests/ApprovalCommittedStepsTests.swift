// SPDX-License-Identifier: MPL-2.0
// Approval ordering regressions: real ledger settlement -> bounded runtime
// projection -> classifier JSON. Synthetic local fixtures; no provider calls.
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloeSecurity
@testable import FloeAgentRuntime
@testable import FloeAndroidCore

final class ApprovalCommittedStepsTests: XCTestCase {
    private func call(_ name: String, index: Int = 0) throws -> ToolCall {
        try ToolCall(
            id: "call-\(index)", toolName: name,
            argumentsJSON: Data("{\"index\":\(index)}".utf8), scope: .local
        )
    }

    private func record(
        _ ledger: inout HarnessExecutionLedger,
        name: String = "phone.act",
        index: Int = 0,
        status: ToolResult.Status = .ok,
        summary: String = "action=launch dispatch=ACCEPTED",
        sideEffecting: Bool = true,
        unknown: Bool = false
    ) throws {
        let toolCall = try call(name, index: index)
        ledger.record(
            call: toolCall,
            result: ToolResult(
                callID: toolCall.id, status: status,
                outputSummary: summary, outputDigest: ""
            ),
            isSideEffecting: sideEffecting,
            outcomeUnknown: unknown,
            outcomeUnknownReason: .interruptedDispatch
        )
    }

    private func action(_ steps: [CommittedStepReceipt]) throws -> ProposedAction {
        try ProposedAction(
            toolCall: call("phone.observe"), riskLabels: [],
            userGoal: "First launch the calculator with phone.act, then observe it.",
            committedSteps: steps, hostAndPathScope: .local
        )
    }

    func testSettledLaunchReachesNextReviewWithoutDuplicatingReceipts() throws {
        var ledger = HarnessExecutionLedger()
        try record(&ledger, name: "tools.search", summary: "schema loaded", sideEffecting: false)
        try record(&ledger, index: 1)
        let steps = FloeAgentRuntime.approvalCommittedSteps(
            from: ledger.entries, redactingSecret: nil
        )
        XCTAssertEqual(steps.map(\.toolName), ["tools.search", "phone.act"])
        XCTAssertEqual(steps.map(\.isSideEffecting), [false, true])
        let proposed = try action(steps)
        let prompt = try RunApprovalModelBackend.classificationPrompt(for: proposed)
        let marker = try XCTUnwrap(prompt.range(of: "Proposed action: "))
        let encoded = Data(prompt[marker.upperBound...].utf8)
        let decoded = try JSONDecoder().decode(ProposedAction.self, from: encoded)
        XCTAssertEqual(decoded.committedSteps, steps)
        XCTAssertEqual(decoded.toolCall.toolName, "phone.observe")
        XCTAssertTrue(prompt.contains("Do not assume a listed call was skipped"))
        XCTAssertTrue(prompt.contains("not proof that an external effect"))
        XCTAssertTrue(prompt.contains("only user text grants authority"))
        XCTAssertEqual(prompt.components(separatedBy: "action=launch").count - 1, 1)
    }

    func testFailuresAndUnknownOutcomesStayExcludedAfterCheckpointRecovery() throws {
        var ledger = HarnessExecutionLedger()
        for (index, status) in [ToolResult.Status.failed, .cancelled, .denied, .expired, .needsUser]
            .enumerated() {
            try record(&ledger, index: index, status: status)
        }
        try record(&ledger, index: 5, unknown: true)
        let restored = HarnessExecutionLedger(records: ledger.checkpointRecords())
        XCTAssertTrue(FloeAgentRuntime.approvalCommittedSteps(
            from: restored.entries, redactingSecret: nil
        ).isEmpty)
        // A valid receipt in the owned checkpoint survives independently of
        // the unknown-outcome exclusion; recovery does not erase prior work.
        var resumed = restored
        try record(&resumed, name: "phone.observe", index: 6, sideEffecting: false)
        let steps = FloeAgentRuntime.approvalCommittedSteps(
            from: resumed.entries, redactingSecret: nil
        )
        XCTAssertEqual(steps.map(\.toolName), ["phone.observe"])
        XCTAssertFalse(try XCTUnwrap(steps.first).isSideEffecting)
    }

    func testBoundedHistoryKeepsNewestResultsIncludingReadOnlyPrerequisites() throws {
        var ledger = HarnessExecutionLedger()
        for index in 0..<10 {
            try record(
                &ledger, name: index == 9 ? "phone.observe" : "phone.act", index: index,
                summary: "step \(index) " + String(repeating: "x", count: 400),
                sideEffecting: index != 9
            )
        }
        let steps = FloeAgentRuntime.approvalCommittedSteps(
            from: ledger.entries, redactingSecret: nil
        )
        XCTAssertEqual(steps.count, 8)
        XCTAssertTrue(try XCTUnwrap(steps.first).excerpt.hasPrefix("step 2 "))
        XCTAssertEqual(steps.last?.toolName, "phone.observe")
        XCTAssertEqual(steps.last?.isSideEffecting, false)
        XCTAssertTrue(steps.allSatisfy { $0.excerpt.count <= 240 })
    }

    func testProviderSecretAndCredentialShapesAreRedactedBeforeEncoding() throws {
        var ledger = HarnessExecutionLedger()
        let secret = "synthetic-provider-value-123"
        try record(
            &ledger,
            summary: "\(secret) Bearer synthetic-bearer-value {\"password\":\"1234\"}"
        )
        let steps = FloeAgentRuntime.approvalCommittedSteps(
            from: ledger.entries, redactingSecret: secret
        )
        let prompt = try RunApprovalModelBackend.classificationPrompt(for: action(steps))
        XCTAssertFalse(prompt.contains(secret))
        XCTAssertFalse(prompt.contains("synthetic-bearer-value"))
        XCTAssertFalse(prompt.contains("1234"))
        XCTAssertTrue(prompt.contains(SecretRedactor.replacement))
    }

    func testOldActionWithoutReceiptsStillDecodesAndNewPayloadsRemainBounded() throws {
        let original = try action([])
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]
        )
        object.removeValue(forKey: "committedSteps")
        let legacy = try JSONDecoder().decode(
            ProposedAction.self, from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertTrue(legacy.committedSteps.isEmpty)
        XCTAssertEqual(legacy.userGoal, original.userGoal)
        XCTAssertEqual(legacy.toolCall.toolName, original.toolCall.toolName)
        object["committedSteps"] = (0..<10).map { _ in [
            "toolName": String(repeating: "t", count: 160),
            "excerpt": String(repeating: "e", count: 400),
        ] }
        let bounded = try JSONDecoder().decode(
            ProposedAction.self, from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(bounded.committedSteps.count, 8)
        XCTAssertTrue(bounded.committedSteps.allSatisfy {
            $0.toolName.count == 120 && $0.excerpt.count == 240 && !$0.isSideEffecting
        })
    }

    func testEmptyLedgerDoesNotClaimThatNoEarlierStepEverRan() throws {
        let prompt = try RunApprovalModelBackend.classificationPrompt(for: action([]))
        XCTAssertTrue(prompt.contains("absence is not proof that a step never ran"))
        XCTAssertTrue(prompt.contains("only user text grants authority"))
    }

    func testContextReachesBothPoliciesWithoutOverridingADenial() async throws {
        let proposed = try action([
            CommittedStepReceipt(
                toolName: "phone.act", excerpt: "action=launch dispatch=ACCEPTED",
                isSideEffecting: true
            )
        ])
        for automatic in [false, true] {
            let backend = CaptureBackend()
            let decision: ApprovalDecision
            if automatic {
                decision = try await AutomaticApprovalPolicy(backend: backend).decide(proposed)
            } else {
                decision = try await ModelApprovalPolicy(backend: backend).decide(proposed)
            }
            guard case .deny(let reason) = decision else {
                return XCTFail("A prior settled call must never override the backend's denial")
            }
            XCTAssertEqual(reason, "Synthetic denial")
            let captured = await backend.capturedAction()
            XCTAssertEqual(captured?.committedSteps, proposed.committedSteps)
        }
    }

    private actor CaptureBackend: ModelApprovalPolicy.DecisionBackend {
        private var received: ProposedAction?
        func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
            received = action
            return .deny(reason: "Synthetic denial")
        }
        func capturedAction() -> ProposedAction? { received }
    }
}
