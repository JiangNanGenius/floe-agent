// SPDX-License-Identifier: MPL-2.0
// Real original bootstrap/DB/registry/fences, without a model request.
import XCTest
import Foundation
@testable import FloeAndroidCore

final class G04WorkspaceOwnedLeaseTests: XCTestCase {
    private var fixture: RunDomainFixture!
    private var held: [(FacadeRunDomain, G04WorkspaceOwnedOperation)] = []

    override func setUp() async throws { fixture = try await RunDomainFixture.make() }
    override func tearDown() async throws {
        for (domain, operation) in held { await domain.endG04WorkspaceOperation(operation) }
        held.removeAll()
        await fixture.tearDown()
    }

    func testDeletionCancelsOnlyTargetAndCallerCancellationNeverDetachesIO() async throws {
        let domain = fixture.makeDomain()
        let firstID = try await fixture.makeOrdinaryConversation(goal: "first workspace")
        let secondID = try await fixture.makeOrdinaryConversation(goal: "unrelated workspace")
        let firstValue = await domain.beginG04WorkspaceOperation(conversationID: firstID, expectedEpoch: fixture.epoch)
        let secondValue = await domain.beginG04WorkspaceOperation(conversationID: secondID, expectedEpoch: fixture.epoch)
        let first = try XCTUnwrap(firstValue), second = try XCTUnwrap(secondValue)
        held = [(domain, first), (domain, second)]
        let lifecycle = RunDomainDeletionLifecycle(domain: domain)
        let fence = try await lifecycle.beginDeletionFence(conversationID: firstID, epoch: fixture.epoch,
                                                            operationID: UUID())
        XCTAssertTrue(first.cancellation.isCancelled)
        XCTAssertFalse(second.cancellation.isCancelled)
        XCTAssertTrue(RuntimeOwnedWorkRegistry.shared.isAttached(first.token))
        let refused = await domain.beginG04WorkspaceOperation(conversationID: firstID, expectedEpoch: fixture.epoch)
        XCTAssertNil(refused)

        // Cancellation of the waiting DELETE must see pending workspace IO
        // and refuse its drain; it cannot return zero or detach the writer.
        let draining = Task { try await lifecycle.drainOwnedWork(fence: fence) }
        draining.cancel()
        do {
            _ = try await draining.value
            XCTFail("Delete reported quiescence while a real workspace lease was attached")
        } catch ConversationDeletionLifecycleFailure.drainUnavailable(let reason) {
            XCTAssertEqual(reason, "callerCancelled")
        }
        XCTAssertTrue(RuntimeOwnedWorkRegistry.shared.isAttached(first.token))
        XCTAssertTrue(RuntimeOwnedWorkRegistry.shared.isAttached(second.token))

        await domain.endG04WorkspaceOperation(first)
        let report = try await lifecycle.drainOwnedWork(fence: fence)
        let observations = try XCTUnwrap(report.targetOwnedWork)
        XCTAssertTrue(observations.contains { $0.token == first.token && !$0.stillAttached })
        XCTAssertFalse(observations.contains { $0.token == second.token })
        XCTAssertTrue(RuntimeOwnedWorkRegistry.shared.isAttached(second.token))
        _ = await lifecycle.abortDeletionFence(fence)
    }

    func testGlobalFenceAndRootRetirementCancelButWaitForActualRelease() async throws {
        let domain = fixture.makeDomain()
        let conversationID = try await fixture.makeOrdinaryConversation()
        let firstValue = await domain.beginG04WorkspaceOperation(conversationID: conversationID,
                                                                  expectedEpoch: fixture.epoch)
        let first = try XCTUnwrap(firstValue)
        held.append((domain, first))
        let fence = try await domain.beginGlobalAdmissionFence(expectedEpoch: fixture.epoch)
        XCTAssertTrue(first.cancellation.isCancelled)
        XCTAssertTrue(RuntimeOwnedWorkRegistry.shared.isAttached(first.token))
        let fenced = await domain.beginG04WorkspaceOperation(conversationID: conversationID,
                                                              expectedEpoch: fixture.epoch)
        XCTAssertNil(fenced)
        await domain.endG04WorkspaceOperation(first)
        let finished = await domain.finishGlobalAdmissionFence(fence, committed: false)
        XCTAssertTrue(finished)

        let resumedValue = await domain.beginG04WorkspaceOperation(conversationID: conversationID,
                                                                   expectedEpoch: fixture.epoch)
        let resumed = try XCTUnwrap(resumedValue)
        held.append((domain, resumed))
        await domain.beginGenerationRetirement()
        XCTAssertTrue(resumed.cancellation.isCancelled)
        XCTAssertTrue(RuntimeOwnedWorkRegistry.shared.isAttached(resumed.token))
        let retired = await domain.beginG04WorkspaceOperation(conversationID: conversationID,
                                                              expectedEpoch: fixture.epoch)
        XCTAssertNil(retired)
        await domain.endG04WorkspaceOperation(resumed)
        XCTAssertFalse(RuntimeOwnedWorkRegistry.shared.isAttached(resumed.token))
    }
}
