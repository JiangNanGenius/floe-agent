// SPDX-License-Identifier: MPL-2.0
// Authored for unified qualification; NOT RUN during source implementation.
import Foundation
import XCTest
@testable import FloeAndroidCore

final class C02CuratedSearchPageTests: XCTestCase {
    private let revision = String(repeating: "a", count: 64)

    func testEveryCardRemainsReachableAcrossItemLimitedPages() throws {
        let cards = (0..<123).map { ["id": "skill-\($0)", "name": "Entry \($0)"] }
        var token: String?
        var seen: [String] = []
        repeat {
            let page = try C02CuratedSearchPage.make(
                cards: cards, query: "", catalogSHA256: revision, pageToken: token)
            let visible = try XCTUnwrap(page["cards"] as? [[String: Any]])
            XCTAssertLessThanOrEqual(visible.count, 50)
            XCTAssertEqual(page["count"] as? Int, 123)
            seen += visible.compactMap { $0["id"] as? String }
            token = page["nextPageToken"] as? String
            XCTAssertEqual(page["hasMore"] as? Bool, token != nil)
        } while token != nil
        XCTAssertEqual(seen, (0..<123).map { "skill-\($0)" })
    }

    func testUTF8ByteBudgetStopsBeforeTheItemLimitWithoutDroppingCards() throws {
        let cards: [[String: Any]] = (0..<12).map {
            ["id": "skill-\($0)", "summary": String(repeating: "界", count: 4_000)]
        }
        let first = try C02CuratedSearchPage.make(
            cards: cards, query: "", catalogSHA256: revision, pageToken: nil)
        let visible = try XCTUnwrap(first["cards"] as? [[String: Any]])
        XCTAssertGreaterThan(visible.count, 0)
        XCTAssertLessThan(visible.count, cards.count)
        let encoded = try XCTUnwrap(ConfigJSON.canonicalData(first))
        XCTAssertLessThanOrEqual(encoded.count, ConfigPageBudget.maximumPageItemsBytes)
        let next = try C02CuratedSearchPage.make(
            cards: cards, query: "", catalogSHA256: revision,
            pageToken: try XCTUnwrap(first["nextPageToken"] as? String))
        let nextCards = try XCTUnwrap(next["cards"] as? [[String: Any]])
        XCTAssertEqual(nextCards.first?["id"] as? String, "skill-\(visible.count)")
    }

    func testChangedQueryOrCatalogRefusesAnOldPageToken() throws {
        let cards: [[String: Any]] = (0..<60).map { ["id": "skill-\($0)"] }
        let first = try C02CuratedSearchPage.make(
            cards: cards, query: " Test ", catalogSHA256: revision, pageToken: nil)
        let token = try XCTUnwrap(first["nextPageToken"] as? String)
        XCTAssertNoThrow(try C02CuratedSearchPage.make(
            cards: cards, query: "test", catalogSHA256: revision, pageToken: token))
        XCTAssertThrowsError(try C02CuratedSearchPage.make(
            cards: cards, query: "other", catalogSHA256: revision, pageToken: token))
        XCTAssertThrowsError(try C02CuratedSearchPage.make(
            cards: cards, query: "test", catalogSHA256: String(repeating: "b", count: 64),
            pageToken: token))
    }

    func testMalformedAndOversizedInputsFailWithoutAClaimOfCompletion() throws {
        for token in ["", "not-base64!", String(repeating: "a", count: 2_049)] {
            XCTAssertThrowsError(try C02CuratedSearchPage.make(
                cards: [], query: "", catalogSHA256: revision, pageToken: token))
        }
        XCTAssertThrowsError(try C02CuratedSearchPage.make(
            cards: [], query: String(repeating: "界", count: 171),
            catalogSHA256: revision, pageToken: nil))
        XCTAssertThrowsError(try C02CuratedSearchPage.make(
            cards: [["id": "large", "summary": String(repeating: "x", count: 50_000)]],
            query: "", catalogSHA256: revision, pageToken: nil))
    }

    func testEmptySearchHasNoContinuation() throws {
        let page = try C02CuratedSearchPage.make(
            cards: [], query: "", catalogSHA256: revision, pageToken: nil)
        XCTAssertEqual(page["hasMore"] as? Bool, false)
        XCTAssertEqual(page["pageCount"] as? Int, 0)
        XCTAssertTrue(page["nextPageToken"] is NSNull)
    }

    // MARK: - Whole-reply snapshot bound

    func testBoundedSnapshotKeepsTheWholeReplyUnderBudgetAndReachable() throws {
        let base: [String: Any] = [
            "catalog": ["state": "ready", "packages": (0..<4).map {
                ["id": "legacy-\($0)", "version": "1.0.0", "sha256": String(repeating: "a", count: 64)]
            }],
            "curated": ["state": "ready", "cardsPaged": true, "cardCount": 1234,
                        "catalogSHA256": String(repeating: "b", count: 64)],
            "pendingReviews": [["reviewToken": "eff:v1:abc", "skillID": "s", "kind": "install"]],
            "settings": ["autoScriptedUpdates": false,
                         "revision": ["resourceID": "skills.settings", "version": "sha256"]],
        ]
        let rows: [[String: Any]] = (0..<123).map { index in
            ["id": "skill-\(index)", "name": "Skill \(index)",
             "description": String(repeating: "界", count: 900),
             "revision": ["resourceID": "skill.\(index)",
                          "version": String(repeating: "c", count: 64)]]
        }
        var cursor = 0
        var seen: [String] = []
        var pages = 0
        repeat {
            let page = try C02BoundedSkillSnapshot.compose(
                base: base, rows: rows, cursor: cursor)
            let encoded = try XCTUnwrap(ConfigJSON.canonicalData(page.payload))
            XCTAssertLessThanOrEqual(encoded.count, ConfigPageBudget.maximumPageItemsBytes)
            let visible = try XCTUnwrap(page.payload["skills"] as? [[String: Any]])
            XCTAssertLessThanOrEqual(visible.count, ConfigPageBudget.maximumItemsPerPage)
            XCTAssertEqual(page.payload["hasMore"] as? Bool, page.hasMore)
            seen += visible.compactMap { $0["id"] as? String }
            pages += 1
            if let next = page.nextCursor {
                XCTAssertTrue(next.allSatisfy(\.isNumber))
                cursor = try XCTUnwrap(Int(next))
            } else {
                cursor = rows.count
            }
        } while cursor < rows.count
        XCTAssertEqual(seen, (0..<123).map { "skill-\($0)" })
        XCTAssertGreaterThan(pages, 1)
    }

    func testBoundedSnapshotRefusesAnOversizedFirstRowInsteadOfDroppingIt() {
        let base: [String: Any] = ["environment": "test"]
        let rows: [[String: Any]] = [["id": "large",
                                     "description": String(repeating: "x", count: 60_000)]]
        XCTAssertThrowsError(try C02BoundedSkillSnapshot.compose(
            base: base, rows: rows, cursor: 0))
    }

    func testBoundedSnapshotRefusesMetadataThatCannotFitTheFrame() {
        let base: [String: Any] = ["catalog": ["blob": String(repeating: "x", count: 60_000)]]
        XCTAssertThrowsError(try C02BoundedSkillSnapshot.compose(
            base: base, rows: [["id": "one"]], cursor: 0))
    }
}
