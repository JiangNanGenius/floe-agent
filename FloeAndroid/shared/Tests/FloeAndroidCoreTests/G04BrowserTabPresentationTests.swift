// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeAndroidCore
@testable import FloeBrowser

final class G04BrowserTabPresentationTests: XCTestCase {
    private func proof(operation: String = "close", target: UUID?, ids: [UUID],
                       count: Int? = nil, limit: Int = 6) -> BrowserTabApprovalProof {
        BrowserTabApprovalProof(
            owner: BrowserOwnerID(taskID: UUID(), workspaceID: UUID(), rootEpoch: 7),
            sessionID: UUID(), operation: operation, tabID: target, activeTabID: ids.last,
            documentID: target == nil ? nil : "document", navigationRevision: target == nil ? nil : 1,
            url: nil, title: nil, tabCount: count ?? ids.count, maximumTabs: limit, tabIDs: ids)
    }

    func testTargetIndexUsesBoundTabOrderAndOneBasedEndpoints() throws {
        let first = UUID(), middle = UUID(), last = UUID()
        let ids = [first, middle, last]
        for (index, id) in ids.enumerated() {
            let args = G04BrowserTabTool.Arguments(action: "close", tabID: id)
            let page = try XCTUnwrap(G04BrowserTabApprovalPresentation.details(for: args,
                proof: proof(target: id, ids: ids)))
            XCTAssertEqual(page["tabIndex"], .integer(Int64(index + 1)))
            XCTAssertEqual(page["tabCount"], .integer(3))
            XCTAssertEqual(page["tabID"], .string(id.uuidString.lowercased()))
        }
    }

    func testInvalidTargetOrderOrCountNeverProducesPresentation() {
        let a = UUID(), b = UUID(), missing = UUID()
        func page(_ target: UUID, _ candidate: BrowserTabApprovalProof) -> [String: SettingsDomainV1.JSONValue]? {
            G04BrowserTabApprovalPresentation.details(
                for: G04BrowserTabTool.Arguments(action: "close", tabID: target), proof: candidate)
        }
        XCTAssertNil(page(missing, proof(target: missing, ids: [a, b])))
        XCTAssertNil(page(a, proof(target: a, ids: [a, a])))
        XCTAssertNil(page(a, proof(target: a, ids: [a, b], count: 3)))
        XCTAssertNil(page(a, proof(target: a, ids: [a, b], limit: 1)))
        XCTAssertNil(page(a, proof(target: a, ids: [a])))
    }

    func testCreateRetainsOriginalFourFieldPresentation() throws {
        let args = G04BrowserTabTool.Arguments(action: "create", tabID: nil)
        let page = try XCTUnwrap(G04BrowserTabApprovalPresentation.details(for: args,
            proof: proof(operation: "create", target: nil, ids: [UUID()])))
        XCTAssertEqual(Set(page.keys), Set(["kind", "operation", "url", "title"]))
        XCTAssertNil(page["tabIndex"])
        XCTAssertNil(page["tabCount"])
    }
}
