// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeLaTeXCore
import FloeLaTeXParsing
import FloeLaTeXReferences
import FloeLaTeXResources

final class InlineAndResourceTests: XCTestCase, @unchecked Sendable {
    func testVisualProjectionPreservesUnknownMacrosAndComments() throws {
        let source="A \\textbf{bold 中文} and \\custom{keep {nested}} with $x^2$.% comment\n"
        let document=LaTeXInlineDocument(source:source)
        XCTAssertEqual(document.source,source)
        XCTAssertEqual(document.visibleText,"A bold 中文 and \u{FFFC} with \u{FFFC}.")
        XCTAssertEqual(document.attachments().count,2)
        let result=try document.replacing(NSRange(location:2,length:4),with:"strong")
        XCTAssertTrue(result.contains("\\custom{keep {nested}}"))
        XCTAssertTrue(result.contains("% comment\n"))
        XCTAssertEqual(LaTeXInlineDocument(source:result).visibleText,"A strong 中文 and \u{FFFC} with \u{FFFC}.")
        XCTAssertTrue(LaTeXInlineDocument(source:result).styleRanges().contains(where:{$0.command=="textbf"}))
    }
    func testVisualEditCrossesFormattingWithoutUnbalancingTeX() throws {
        let doc=LaTeXInlineDocument(source:"One \\emph{two three} four")
        let edited=try doc.replacing(NSRange(location:2,length:8),with:"X & Y")
        XCTAssertEqual(LaTeXInlineDocument(source:edited).visibleText,"OnX & Yree four")
        XCTAssertTrue(edited.contains("\\&"))
        XCTAssertTrue(LaTeXParser.parse(edited).diagnostics.isEmpty)
        let formatted=try doc.formatting(NSRange(location:4,length:3),command:"textbf")
        XCTAssertEqual(LaTeXInlineDocument(source:formatted).visibleText,doc.visibleText)
        XCTAssertTrue(formatted.contains("\\textbf{"))
    }
    func testBracesAndEscapedTextKeepTheirMeaning() throws {
        let source=#"A {group} and 50\% \& cost \$5."#
        let doc=LaTeXInlineDocument(source:source)
        XCTAssertEqual(doc.source,source)
        XCTAssertEqual(doc.visibleText,"A group and 50% & cost $5.")
        let edited=try doc.replacing(NSRange(location:2,length:5),with:"中文")
        XCTAssertEqual(LaTeXInlineDocument(source:edited).visibleText,"A 中文 and 50% & cost $5.")
    }
    func testCitationArgumentsDoNotConsumeFollowingGroups() {
        let tree=LaTeXParser.parse(#"\cite[see][p.~2]{one,two} {ordinary text} \label{a} {next}"#)
        XCTAssertEqual(tree.citations,["one","two"]);XCTAssertEqual(tree.labels,["a"])
    }
    func testUnicodeSearchAndTableBuilder() throws {
        let hits=try LaTeXSourceSearch.search("第一行\n中文研究\n",path:"main.tex",query:"研究")
        XCTAssertEqual(hits.first?.line,2);XCTAssertEqual(hits.first?.range.length,6)
        let table=try LaTeXBlockBuilder.table([["A & B","中文"],["50%","x_1"]],caption:"Results")
        XCTAssertTrue(table.contains("A \\& B"));XCTAssertTrue(table.contains("50\\%"));XCTAssertTrue(table.contains("\\bottomrule"))
        XCTAssertTrue(table.contains(" \\\\\n"))
    }
    func testResourceDependenciesAndExecutableRejection() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("FloeResources-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let a=LaTeXResourcePackage(id:"a",version:"1",license:"LPPL",files:[])
        let b=LaTeXResourcePackage(id:"b",version:"1",license:"LPPL",dependencies:["a"],files:[])
        let store=try LaTeXResourceStore(root:root,packages:[a,b])
        let order=try await store.dependencyOrder(["b"])
        XCTAssertEqual(order.map(\.id),["a","b"])
        let bad=LaTeXResourcePackage(id:"bad",version:"1",license:"MIT",files:[.init(path:"plugin.dylib",sha256:String(repeating:"a",count:64),byteCount:1,downloadURL:URL(string:"https://example.invalid/plugin.dylib")!)])
        XCTAssertThrowsError(try LaTeXResourceStore(root:root,packages:[bad]))
        let cycle=try LaTeXResourceStore(root:root,packages:[.init(id:"a",version:"1",license:"MIT",dependencies:["a"],files:[])])
        do{_=try await cycle.dependencyOrder(["a"]);XCTFail("Circular dependency") }catch LaTeXError.unavailable{}
    }
}
