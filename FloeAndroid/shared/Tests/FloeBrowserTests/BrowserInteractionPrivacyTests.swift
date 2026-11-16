// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
@testable import FloeBrowser

final class BrowserInteractionPrivacyTests: XCTestCase {
    func testTypeReturnsReceiptWithoutEchoingInputOrPostActionPage() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (_, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let observed = await harness.center.execute(BrowserCommand(sessionID: sessionID, action: .observe(cursor: nil)), in: owner)
        let documentID = try XCTUnwrap(observed.page?.documentID)
        let secret = "synthetic-private-value"
        // A later page read could contain the same input in value or ordinary
        // DOM text; the type result itself must never include any page data.
        await harness.renderer.setSnapshot("{\"revision\":3,\"viewportWidth\":1280,\"viewportHeight\":800,\"nodes\":[{\"ref\":\"n1\",\"role\":\"input\",\"name\":\"\",\"text\":\"\(secret)\",\"value\":\"\(secret)\",\"state\":{},\"bounds\":{\"x\":0,\"y\":0,\"width\":10,\"height\":10}}],\"nextCursor\":null}")
        let result = await harness.center.execute(BrowserCommand(sessionID: sessionID,
            expectedDocumentID: documentID,
            action: .type(.element(ref: "n1", documentID: documentID), text: secret, submit: true)), in: owner)
        XCTAssertEqual(result.status, .ok)
        XCTAssertNil(result.page)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains(secret))
    }
    func testVisualEvidenceExpiresWhileScreenshotIsBeingRechecked() {
        let captured = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(BrowserTaskSession.visualEvidenceIsFresh(capturedAt: captured,
            now: captured.addingTimeInterval(119)))
        // Rechecking after an asynchronous capture crosses the 120 s limit.
        XCTAssertFalse(BrowserTaskSession.visualEvidenceIsFresh(capturedAt: captured,
            now: captured.addingTimeInterval(121)))
        XCTAssertFalse(BrowserTaskSession.visualEvidenceIsFresh(capturedAt: captured,
            now: captured.addingTimeInterval(-1)))
    }

    func testApprovedVisualPointRefusesChangedScreenshotBeforeDispatch() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let tabs = await session.tabSnapshots()
        let tabID = try XCTUnwrap(tabs.first?.id)
        let observed = await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID,
            action: .observe(cursor: nil)))
        let documentID = try XCTUnwrap(observed.page?.documentID)
        let screenshot = await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID, action: .screenshot))
        let artifact = try XCTUnwrap(screenshot.page?.screenshotArtifact)
        let action = BrowserAction.click(.point(x: 10, y: 20))
        let proof = try await session.approvalInteractionProof(action: action, tabID: tabID,
            visualSHA256: artifact.sha256, visualReason: "insufficientStructuredInformation", visualDocument: documentID)
        await harness.renderer.setScreenshot(Data([0xff, 0xd8, 0xff, 0xe0, 0x01]), width: 1280, height: 800)
        let before = await harness.renderer.evaluations.filter { $0.expression.contains("p.perform(") }.count
        let result = await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID,
            expectedDocumentID: documentID, visualEvidenceSHA256: artifact.sha256,
            visualFallbackReason: "insufficientStructuredInformation", interactionApprovalProof: proof, action: action))
        let after = await harness.renderer.evaluations.filter { $0.expression.contains("p.perform(") }.count
        XCTAssertNotEqual(result.status, .ok)
        XCTAssertEqual(after, before, "A changed screenshot must not reach the click actuator")
    }

}
