// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
@testable import FloeAndroidDataExchange

final class C07ManagedFontRoleTests: XCTestCase {
    func testManagedFontRoleKeepsOnlyCatalogueAndExactDigestPayloads() throws {
        let id = String(repeating: "a", count: 64)
        XCTAssertTrue(try C07ArtifactPath.entry(role: .managedFont, containerID: nil,
            ownerID: nil, logicalPath: id + ".ttf").hasSuffix("/fonts/" + id + ".ttf"))
        for name in ["../catalog.json", "catalog.json.bak", "Font.ttf", id + ".ttf/child"] {
            XCTAssertThrowsError(try C07ArtifactPath.entry(role: .managedFont, containerID: nil,
                ownerID: nil, logicalPath: name))
        }
        XCTAssertThrowsError(try C07ArtifactPath.entry(role: .managedFont, containerID: nil,
            ownerID: UUID(), logicalPath: "catalog.json"))
    }
    func testOldDurablePlanWithoutFontFieldStillDecodes() throws {
        let plan = C07OwnedDataRestorePlanFile(restoreID: UUID(), idMap: C07IDMap(),
            artifactRoots: [], attachmentPaths: [:], workspaceIDs: [], counts: C07OwnedDataCounts(), warnings: [])
        let encoded = try JSONEncoder().encode(plan)
        let decoded = try C07OwnedDataRestorePlanFile.decode(encoded)
        XCTAssertNil(decoded.managedFontCount)
    }
}
