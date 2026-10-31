// SPDX-License-Identifier: MPL-2.0
//
// G07.3A visible-thread-search projection tests.
//
// The in-chat find must address the text the reader sees: Markdown syntax and
// hidden link targets never become hits, code fence markers are dropped while
// code stays searchable, user text is verbatim, and offsets are into the same
// visible string (Unicode case/diacritic/width folded matching still returns
// original character ranges).
import XCTest
import FloeCore
import FloeModels
import GRDB
@testable import FloeAndroidCore

final class ThreadSearchVisibleTextTests: XCTestCase {

    func testAssistantIdentifiersKeepSingleAndRepeatedIntrawordUnderscores() {
        let source = "ALPHA19_NOTE_OK, alpha__beta, 中文_标识, 𐐀_𐐁 and e\u{301}_note"
        let visible = ThreadSearchText.visibleText(role: "assistant", content: source)
        XCTAssertEqual(visible, source)
        for identifier in ["ALPHA19_NOTE_OK", "alpha__beta", "中文_标识", "𐐀_𐐁", "e\u{301}_note"] {
            XCTAssertTrue(ThreadSearchQuery(raw: identifier).matches(visible))
        }
    }

    func testEmphasisCodeAndEscapesKeepIdentifierContent() {
        let source = #"**ALPHA19_NOTE_OK** / _alpha_beta_ / __alpha__beta__ / ___alpha_beta___ / `a_b` / \_literal\_"#
        XCTAssertEqual(
            ThreadSearchText.visibleText(role: "assistant", content: source),
            "ALPHA19_NOTE_OK / alpha_beta / alpha__beta / alpha_beta / a_b / _literal_"
        )
    }

    func testIdentifierHighlightOffsetsAddressOriginalVisibleUnicodeText() throws {
        let visible = ThreadSearchText.visibleText(
            role: "assistant", content: "🙂 **ALPHA19_NOTE_OK** 中文_标识")
        let ranges = ThreadSearchQuery(raw: "alpha19_note_ok").ranges(in: visible)
        XCTAssertEqual(ranges.count, 1)
        let range = try XCTUnwrap(ranges.first)
        let lower = visible.index(visible.startIndex, offsetBy: range.lowerBound)
        let upper = visible.index(visible.startIndex, offsetBy: range.upperBound)
        XCTAssertEqual(String(visible[lower..<upper]), "ALPHA19_NOTE_OK")
    }

    func testNativeSQLitePredicateFindsAssistantIdentifierWithoutHiddenLinkHits() throws {
        let database = try DatabaseQueue(path: ":memory:")
        try database.write { db in
            db.add(function: ThreadSearchQuery.visibleMatchFunction)
            let identifierHit = try Int.fetchOne(
                db,
                sql: "SELECT floe_thread_search_match(?, ?, ?)",
                arguments: ["assistant", "Result: ALPHA19_NOTE_OK", "ALPHA19_NOTE_OK"]
            )
            XCTAssertEqual(identifierHit, 1)
            let hiddenTargetHit = try Int.fetchOne(
                db,
                sql: "SELECT floe_thread_search_match(?, ?, ?)",
                arguments: ["assistant", "[visible](https://example.test/ALPHA19_NOTE_OK)",
                            "ALPHA19_NOTE_OK"]
            )
            XCTAssertEqual(hiddenTargetHit, 0)
        }
    }

    func testVisibleProjectionDropsHiddenLinkTargetButKeepsLabel() {
        let source = "Read [docs](https://secret.example/private) and **now**."
        let visible = ThreadSearchText.visibleText(role: "assistant", content: source)
        XCTAssertEqual(visible, "Read docs and now.")
        let query = ThreadSearchQuery(raw: "secret")
        XCTAssertFalse(query.matches(visible))
        XCTAssertTrue(ThreadSearchQuery(raw: "docs").matches(visible))
    }

    func testFencedCodeIsSearchableWithoutFenceMarkers() {
        let source = "intro\n```kotlin\nval hidden = 1\n```\nend"
        let visible = ThreadSearchText.visibleText(role: "assistant", content: source)
        XCTAssertTrue(visible.contains("val hidden = 1"))
        XCTAssertFalse(visible.contains("```"))
        XCTAssertEqual(visible, "intro\nval hidden = 1\nend")
    }

    func testUserTextIsVerbatim() {
        let source = "literal [not a link](x) **stars**"
        XCTAssertEqual(
            ThreadSearchText.visibleText(role: "user", content: source),
            source
        )
    }

    func testWhitespaceAndQuotedPhraseParse() {
        let query = ThreadSearchQuery(raw: "  alpha \"beta gamma\" ALPHA ")
        XCTAssertEqual(query.terms.count, 2)
        XCTAssertEqual(query.terms[1].text, "beta gamma")
        XCTAssertTrue(query.matches("alpha x beta gamma"))
        XCTAssertFalse(query.matches("alpha only"))
        XCTAssertTrue(ThreadSearchQuery(raw: "   ").isEmpty)
    }

    func testDiacriticWidthFoldedRangesMapToOriginalVisibleText() {
        let text = "Café Ｆｌｏｅ"
        let cafe = ThreadSearchQuery(raw: "cafe")
        XCTAssertTrue(cafe.matches(text))
        let offsets = cafe.ranges(in: text).first
        XCTAssertNotNil(offsets)
        if let offsets {
            let lower = text.index(text.startIndex, offsetBy: offsets.lowerBound)
            let upper = text.index(text.startIndex, offsetBy: offsets.upperBound)
            XCTAssertEqual(String(text[lower..<upper]), "Café")
        }

        let wide = ThreadSearchQuery(raw: "floe")
        XCTAssertTrue(wide.matches(text))
        let wideRange = wide.ranges(in: text).first
        XCTAssertNotNil(wideRange)
        if let wideRange {
            let lower = text.index(text.startIndex, offsetBy: wideRange.lowerBound)
            let upper = text.index(text.startIndex, offsetBy: wideRange.upperBound)
            XCTAssertEqual(String(text[lower..<upper]), "Ｆｌｏｅ")
        }
    }

    func testSnippetStaysOnTheMatchingVisibleLine() {
        let text = "first line\nsecond line has needle here\nthird"
        let snippet = ThreadSearchText.snippet(
            in: text, query: ThreadSearchQuery(raw: "needle"))
        XCTAssertTrue(snippet.contains("needle"))
        XCTAssertFalse(snippet.contains("first line"))
    }

    func testSearchRequestIsBoundedAndRejectsUnknownFields() throws {
        let request = try ThreadSearchRequest.parse(.object([
            "query": .string("hello"),
            "limit": .integer(10),
        ]))
        XCTAssertEqual(request.limit, 10)
        XCTAssertThrowsError(try ThreadSearchRequest.parse(.object([
            "query": .string("hello"),
            "extra": .boolean(true),
        ])))
        XCTAssertThrowsError(try ThreadSearchRequest.parse(.object([
            "query": .string(String(repeating: "x", count: 600)),
        ])))
    }

    func testWindowRequestBounds() throws {
        let id = UUID()
        let request = try ThreadMessageWindowRequest.parse(.object([
            "messageID": .string(id.uuidString),
            "before": .integer(40),
            "after": .integer(4),
        ]))
        XCTAssertEqual(request.messageID, id)
        XCTAssertEqual(request.before, 40)
        XCTAssertEqual(request.after, 4)
        XCTAssertThrowsError(try ThreadMessageWindowRequest.parse(.object([
            "messageID": .string(id.uuidString),
            "before": .integer(201),
        ])))
    }
}
