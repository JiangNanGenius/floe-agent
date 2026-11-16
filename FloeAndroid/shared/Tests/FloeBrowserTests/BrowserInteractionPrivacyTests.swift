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
}
