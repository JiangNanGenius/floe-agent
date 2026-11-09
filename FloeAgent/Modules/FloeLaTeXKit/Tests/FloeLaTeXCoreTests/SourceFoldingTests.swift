import XCTest
import FloeLaTeXParsing

final class SourceFoldingTests: XCTestCase {
    private let source = """
    \\begin{document}
    \\section{中文 😀}
    Before the environment.
    \\begin{custom}
    PRIVATE hidden 中 é 😀
    \\begin{equation}
    E=mc^2
    \\end{equation}
    \\end{custom}
    \\subsection{Nested}
    More words.
    \\section{Conclusion}
    Final words.
    \\end{document}
    """
    func testHiddenSourceSurvivesVisibleUnicodeEditsAndWholeDocumentCopy() throws {
        var folding = LaTeXSourceFolding(source: source)
        let header = (source as NSString).range(of: "\\begin{custom}")
        _ = folding.perform(.toggleCurrent, selection: NSRange(location: header.location, length: 0))
        XCTAssertEqual(folding.folded.count, 1)
        let before = folding.projection
        XCTAssertFalse(before.text.contains("PRIVATE"))
        XCTAssertEqual(before.source, source)
        let all = before.sourceRange(NSRange(location: 0, length: before.text.utf16.count))
        XCTAssertEqual((source as NSString).substring(with: all), source)
        let position = (before.text as NSString).range(of: "Before").location
        let edit = NSRange(location: position, length: 0), value = "中文😀 "
        let changed = (before.text as NSString).replacingCharacters(in: edit, with: value)
        let canonical = before.sourceRange(edit)
        let caret = try folding.accept(displayText: changed, selection: NSRange(location: position + value.utf16.count, length: 0))
        XCTAssertEqual(folding.source, (source as NSString).replacingCharacters(in: canonical, with: value))
        XCTAssertEqual(caret.location, canonical.location + value.utf16.count)
        XCTAssertTrue(folding.source.contains("PRIVATE hidden 中 é 😀"))
        XCTAssertEqual(folding.folded.count, 1)
        folding.reset(source)
        XCTAssertEqual(folding.projection.text, source)
        XCTAssertTrue(folding.folded.isEmpty)
    }
    func testNestedRegionsIgnoreCommentsAndVerbatimCommandsAndRevealExactSource() {
        let value = source.replacingOccurrences(of: "More words.", with: "% \\begin{fake}\n\\begin{verbatim}\n\\section{Not a heading}\n\\begin{fake}\n\\end{verbatim}\nMore words.")
        let regions = LaTeXSourceFolding.regions(in: value)
        XCTAssertGreaterThanOrEqual(regions.count, 5)
        XCTAssertFalse(regions.contains { (value as NSString).substring(with: $0.header).contains("fake") })
        var folding = LaTeXSourceFolding(source: value)
        _ = folding.perform(.collapseAll, selection: NSRange(location: 0, length: 0))
        let projection = folding.projection
        for pair in zip(projection.hidden, projection.hidden.dropFirst()) { XCTAssertLessThanOrEqual(NSMaxRange(pair.0.display), pair.1.display.location) }
        let target = (value as NSString).range(of: "PRIVATE hidden")
        folding.reveal(target)
        XCTAssertEqual(folding.projection.sourceRange(folding.projection.displayRange(target)), target)
        XCTAssertTrue(folding.projection.text.contains("PRIVATE hidden"))
        _ = folding.perform(.expandAll, selection: target)
        XCTAssertEqual(folding.projection.text, value)
        let sameLine = "\\begin{document}\n\\section{A}\\begin{custom}\nhidden\n\\end{custom}\nafter\n\\end{document}\n"
        let sameRegions = LaTeXSourceFolding.regions(in: sameLine)
        XCTAssertEqual(Set(sameRegions.map(\.id)).count, sameRegions.count)
        var inline = LaTeXSourceFolding(source: sameLine)
        _ = inline.perform(.collapseAll, selection: NSRange(location: 0, length: 0))
        XCTAssertFalse(inline.projection.text.contains("after"), "An enclosing section wins equal-start nested folds")
    }
    func testCRLFSurrogatesAndInvalidSelectionsStayWithinCanonicalBounds() {
        let value = source.replacingOccurrences(of: "\n", with: "\r\n")
        var folding = LaTeXSourceFolding(source: value, chinese: true)
        _ = folding.perform(.collapseAll, selection: NSRange(location: 0, length: 0))
        XCTAssertFalse(folding.projection.hidden.isEmpty)
        XCTAssertTrue(folding.folded.allSatisfy { $0.lineCount > 0 })
        let invalid = NSRange(location: NSNotFound, length: Int.max)
        XCTAssertEqual(folding.projection.sourceRange(invalid), NSRange(location: value.utf16.count, length: 0))
        let projection = folding.projection
        let last = (value as NSString).range(of: "\\end{document}")
        XCTAssertEqual(projection.sourceRange(projection.displayRange(last)), last)
        XCTAssertEqual(folding.source, value)
    }
    func testDisplayMarkerCannotEnterSavedSourceAndStructuralEditRevealsFolds() throws {
        var folding = LaTeXSourceFolding(source: source)
        _ = folding.perform(.collapseAll, selection: NSRange(location: 0, length: 0))
        let before = folding.projection, marker = try XCTUnwrap(before.hidden.first)
        let changed = (before.text as NSString).replacingCharacters(in: marker.display, with: "corrupted")
        XCTAssertThrowsError(try folding.accept(displayText: changed, selection: NSRange(location: marker.display.location, length: 0)))
        XCTAssertEqual(folding.source, source)
        let value = "\n"
        let inserted = value + before.text
        _ = try folding.accept(displayText: inserted, selection: NSRange(location: 1, length: 0))
        XCTAssertEqual(folding.source, value + source)
        XCTAssertTrue(folding.folded.isEmpty)
        XCTAssertEqual(folding.projection.text, value + source)
    }
}
