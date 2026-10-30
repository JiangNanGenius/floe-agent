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
@testable import FloeAndroidCore

final class ThreadSearchVisibleTextTests: XCTestCase {

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
