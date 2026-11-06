import XCTest
@testable import FloeCanvasCore
@testable import FloeCanvasIntegration

final class StepExecutorTests: XCTestCase {
    private func makeRequest(attemptID: UUID = UUID()) -> CanvasStepExecutionRequest {
        let node = FlowNode(
            kind: .customScript,
            name: "enhance",
            ports: [FlowPort(name: "out", dataType: .string, direction: .output)],
            parameters: ["mode": .string("fast")],
            script: FlowScriptDescriptor(
                language: "bash", sourceHash: "sha256:script",
                signature: [FlowPort(name: "out", dataType: .string, direction: .output)])
        )
        let identity = FlowRunIdentity(
            canvasID: UUID(), canvasRevision: 7,
            flowGraphID: UUID(), flowGraphRevision: 2,
            environmentID: "env-test", owningTaskID: UUID())
        return CanvasStepExecutionRequest(
            runIdentity: identity,
            attemptID: attemptID,
            node: node,
            inputs: ["image": .asset(CanvasAssetLocator(id: UUID()))],
            context: CanvasRuntimeContext(
                canvasID: identity.canvasID, pageID: UUID(),
                revision: 7, owningTaskID: identity.owningTaskID,
                environmentID: "env-test")
        )
    }

    func testDuplicateAttemptReusesExistingWork() async throws {
        let executor = ControlledStepExecutor { nodeID in
            ControlledStepExecutor.ScriptedOutcome(
                status: .succeeded,
                outputs: ["out": .string("done")],
                producedAssets: [CanvasAssetLocator(id: UUID(), mimeType: "image/png")])
        }
        let request = makeRequest()
        let first = try await executor.submitStep(request)
        XCTAssertEqual(first.status, .succeeded)
        XCTAssertEqual(first.outputs["out"], .string("done"))
        XCTAssertEqual(first.producedAssets.count, 1)
        XCTAssertNotNil(first.hostTaskBinding)

        let replay = try await executor.submitStep(request)
        XCTAssertEqual(replay, first)
        // Exactly one execution was performed.
        let performed = await executor.performedAttemptIDs
        XCTAssertEqual(performed, [request.attemptID])
    }

    func testUnconfirmedSubmissionStaysUnknownUntilReconciled() async throws {
        let attemptID = UUID()
        let executor = ControlledStepExecutor(
            unconfirmedAttempts: [attemptID])
        let request = makeRequest(attemptID: attemptID)
        let result = try await executor.submitStep(request)
        XCTAssertEqual(result.status, .unknown)
        XCTAssertTrue(result.outputs.isEmpty)

        try await executor.reconcile(
            attemptID: attemptID,
            outcome: .init(status: .succeeded, outputs: ["out": .string("late")]))
        let queried = try await executor.queryStep(
            attemptID: attemptID, runID: request.runIdentity.runID)
        XCTAssertEqual(queried.status, .succeeded)
        XCTAssertEqual(queried.outputs["out"], .string("late"))
    }

    func testQueryUnknownAttemptThrows() async throws {
        let executor = ControlledStepExecutor()
        await XCTAssertThrowsErrorAsync({ try await executor.queryStep(
            attemptID: UUID(), runID: UUID())}) { error in
            guard case CanvasKitError.missingEntity = error else {
                XCTFail("expected missingEntity, got \(error)")
                return
            }
        }
    }

    func testQueryRunReturnsCheckpoint() async throws {
        let executor = ControlledStepExecutor()
        let checkpoint = try await executor.queryRun(runID: UUID())
        XCTAssertEqual(checkpoint.completedStepIDs, [])
    }
}
