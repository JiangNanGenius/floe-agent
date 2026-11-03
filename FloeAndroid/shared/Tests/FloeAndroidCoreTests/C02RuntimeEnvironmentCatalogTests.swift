// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeAndroidCore

final class C02RuntimeEnvironmentCatalogTests: XCTestCase {
    private let projectID = UUID(uuidString: "17D27F98-8FAC-43B3-BDD3-D0E31C564232")!
    private let owner = String(repeating: "a", count: 64)

    private func row(_ id: String, kind: String, owner: String, parent: String? = nil) -> [String: Any] {
        var result: [String: Any] = ["id": id, "kind": kind, "ownerID": owner,
            "state": "active", "baseRevision": "base", "requiresRebuild": false,
            "executionBackend": "linuxPRoot", "layerFormat": 1]
        if let parent { result["parentID"] = parent }
        return result
    }
    private func payload(_ rows: [[String: Any]], project: UUID? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["phase": "ready",
            "projectID": (project ?? projectID).uuidString,
            "workspaceOwnerID": owner, "environments": rows])
    }

    func testRuntimeOwnerIsVerifiedBeforeProjectOwnerProjection() throws {
        let rows = try C02RuntimeEnvironmentCatalog.decode(payload([
            row("project", kind: "project", owner: owner),
            row("session", kind: "session", owner: "task", parent: "project")
        ]), projectID: projectID)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].targetFacts(projectOwner: "app-project").ownerID, "app-project")
        XCTAssertEqual(rows[1].targetFacts(projectOwner: "app-project").ownerID, "task")
    }

    func testOtherProjectOrUnrelatedSessionCannotEnterCatalog() throws {
        XCTAssertThrowsError(try C02RuntimeEnvironmentCatalog.decode(payload([
            row("project", kind: "project", owner: String(repeating: "b", count: 64))
        ]), projectID: projectID))
        XCTAssertThrowsError(try C02RuntimeEnvironmentCatalog.decode(payload([
            row("session", kind: "session", owner: "task", parent: "foreign")
        ]), projectID: projectID))
        XCTAssertThrowsError(try C02RuntimeEnvironmentCatalog.decode(payload([], project: UUID()), projectID: projectID))
    }

    func testDuplicateIdentitiesAreRefusedAndMissingEnvironmentIsEmpty() throws {
        let project = row("project", kind: "project", owner: owner)
        XCTAssertThrowsError(try C02RuntimeEnvironmentCatalog.decode(payload([project, project]), projectID: projectID))
        XCTAssertTrue(try C02RuntimeEnvironmentCatalog.decode(payload([]), projectID: projectID).isEmpty)
    }
}
