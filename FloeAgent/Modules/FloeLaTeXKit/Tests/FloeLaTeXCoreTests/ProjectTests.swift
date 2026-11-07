// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeLaTeXCore
import FloeLaTeXParsing
import FloeLaTeXReferences
import FloeLaTeXResources

final class ProjectTests: XCTestCase, @unchecked Sendable {
    func temporary() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("FloeLaTeXTests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }; return root
    }
    func store(_ root:URL) throws -> LaTeXProjectStore {
        try .create(root:root,owner:.init(kind:.space,id:UUID()),title:"Paper",files:["main.tex":Data("\\documentclass{article}\n\\begin{document}\n中文 hello\n\\end{document}\n".utf8)])
    }
    func testTransactionalSaveCASHistoryAndIdempotency() async throws {
        let root=try temporary(), store=try store(root), id=UUID()
        let first=try await store.apply([.put(path:"chapters/a.tex",data:Data("Chapter".utf8)),.title("Revised")],expectedRevision:0,requestID:id)
        XCTAssertEqual(first.revision,1)
        let replay=try await store.apply([.put(path:"chapters/a.tex",data:Data("Chapter".utf8)),.title("Revised")],expectedRevision:0,requestID:id)
        XCTAssertTrue(replay.replayed)
        do { _ = try await store.apply([.title("Conflict")],expectedRevision:0); XCTFail("CAS accepted stale revision") }
        catch LaTeXError.revisionConflict(let expected,let actual) { XCTAssertEqual(expected,0);XCTAssertEqual(actual,1) }
        _ = try await store.restore(revision:0,expectedRevision:1)
        let reopened=try LaTeXProjectStore(root:root)
        let manifest=try await reopened.manifest()
        XCTAssertEqual(manifest.title,"Paper");XCTAssertEqual(manifest.revision,2)
        XCTAssertEqual(manifest.files.count,1)
        let history=try await reopened.history();XCTAssertEqual(history.count,3)
    }
    func testRollbackAfterInterruptedFileCommit() async throws {
        let root=try temporary(), normal=try store(root)
        let faulty=try LaTeXProjectStore(root:root) { _ in throw CocoaError(.fileWriteOutOfSpace) }
        do { _ = try await faulty.apply([.put(path:"main.tex",data:Data("changed".utf8)),.put(path:"extra.tex",data:Data("extra".utf8))],expectedRevision:0);XCTFail("Fault was ignored") } catch {}
        let manifest=try await normal.manifest(), text=try await normal.text("main.tex")
        XCTAssertEqual(manifest.revision,0);XCTAssertTrue(text.contains("中文 hello"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("Source/extra.tex").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("Transaction.json").path))
    }
    func testTwoStoresSerializeAndRejectExternalMutation() async throws {
        let root=try temporary(), first=try store(root), second=try LaTeXProjectStore(root:root)
        _ = try await first.apply([.title("First")],expectedRevision:0)
        do { _ = try await second.apply([.title("Second")],expectedRevision:0);XCTFail("Cross-instance stale update") } catch LaTeXError.revisionConflict {}
        try Data("external".utf8).write(to:root.appendingPathComponent("Source/main.tex"))
        do { _ = try await first.apply([.title("Overwrite")],expectedRevision:1);XCTFail("External mutation was lost") } catch LaTeXError.changedFile {}
    }
    func testImmutableSnapshotAndZIPRoundtrip() async throws {
        let root=try temporary(), store=try store(root)
        let snapshot=try await store.snapshot()
        _ = try await store.apply([.put(path:"main.tex",data:Data("new".utf8))],expectedRevision:0)
        XCTAssertTrue(try String(contentsOf:snapshot.sourceRoot.appendingPathComponent("main.tex"),encoding:.utf8).contains("hello"))
        let zip=root.appendingPathComponent("export.zip")
        try LaTeXProjectArchive.export(snapshot,to:zip)
        let files=try LaTeXProjectArchive.inspect(zip)
        XCTAssertEqual(files.count,1);XCTAssertEqual(try LaTeXProjectArchive.recommendedMainFile(files),"main.tex")
        XCTAssertEqual(files["main.tex"],try Data(contentsOf:snapshot.sourceRoot.appendingPathComponent("main.tex")))
        try await store.releaseSnapshot(snapshot)
    }
    func testFileDirectoryTransitionRollsBackWithoutLosingOriginal() async throws {
        let root=try temporary(), normal=try store(root)
        _ = try await normal.apply([.put(path:"chapter",data:Data("original".utf8))],expectedRevision:0)
        let faulty=try LaTeXProjectStore(root:root) { index in if index==1 { throw CocoaError(.fileWriteOutOfSpace) } }
        do { _ = try await faulty.apply([.delete(path:"chapter"),.put(path:"chapter/part.tex",data:Data("new".utf8))],expectedRevision:1);XCTFail("Expected interrupted transaction") } catch {}
        let old=try await normal.text("chapter"), current=try await normal.manifest()
        XCTAssertEqual(old,"original");XCTAssertEqual(current.revision,1)
        do { _ = try await normal.apply([.put(path:"chapter/a.tex",data:Data())],expectedRevision:1);XCTFail("File-directory prefix collision") } catch LaTeXError.duplicatePath {}
    }
    func testPathsSymlinksAndUnicodeRange() async throws {
        let root=try temporary(), store=try store(root)
        for path in ["../escape.tex","/absolute.tex","a/../../x","a\\b.tex","a//b.tex"] {
            do { _ = try await store.apply([.put(path:path,data:Data())],expectedRevision:0);XCTFail(path) } catch LaTeXError.invalidPath {}
        }
        let outside=try temporary()
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("Source/link"),withDestinationURL:outside)
        do { _ = try await store.apply([.put(path:"link/x.tex",data:Data())],expectedRevision:0);XCTFail("Symlink escaped") } catch LaTeXError.invalidPath {}
        XCTAssertEqual(try LaTeXSourceRange(start:3,length:3).replacing(in:"中文",with:"字"),"中字")
        XCTAssertThrowsError(try LaTeXSourceRange(start:1,length:2).replacing(in:"中文",with:"x"))
    }
    func testCustomMacrosCommentsAndVerbatimRemainExact() throws {
        let source=#"""
        \documentclass{article}
        \newcommand{\custom}[1]{\textbf{#1}}
        \begin{document}
        % keep this comment
        \section{中文标题}
        Text \custom{unchanged} and $x^2$.

        \begin{verbatim}
        \end{fake} % not a comment
        \end{verbatim}
        \label{a}\ref{a}\cite{one,two}
        \end{document}
        """#
        let tree=LaTeXParser.parse(source)
        XCTAssertEqual(tree.source,source)
        XCTAssertEqual(tree.blocks.first(where:{$0.kind == .heading})?.content,"中文标题")
        XCTAssertTrue(tree.blocks.contains(where:{$0.kind == .code && $0.content.contains("end{fake}")}))
        XCTAssertTrue(tree.diagnostics.isEmpty)
        XCTAssertEqual(tree.citations,["one","two"])
        let heading=try XCTUnwrap(tree.blocks.first(where:{$0.kind == .heading}))
        let changed=try heading.contentRange.replacing(in:source,with:"新标题")
        XCTAssertTrue(changed.contains("\\custom{unchanged}"));XCTAssertTrue(changed.contains("% keep this comment"))
    }
    func testBibTeXNestedValuesStringsAndDuplicates() throws {
        let source=#"""
        @string{venue = "Journal" # " of Tests"}
        @article{one, title={A {Nested} Title}, author="姓名 and Author", journal=venue, year=2026}
        @book{one, title={Duplicate}}
        """#
        let value=LaTeXBibParser.parse(source)
        XCTAssertTrue(value.diagnostics.isEmpty);XCTAssertEqual(value.entries.count,2)
        XCTAssertEqual(value.entries[0].field("journal"),"Journal of Tests")
        XCTAssertEqual(value.entries[0].field("title"),"A {Nested} Title")
        XCTAssertEqual(value.duplicateKeys,["one"]);XCTAssertEqual(value.missingCitations(["missing","one"]),["missing"])
        let entry=try LaTeXBibParser.source(type:"article",key:"new2026",fields:["title":"A {Preserved} Title","year":"2026"])
        XCTAssertEqual(LaTeXBibParser.parse(entry).entries.first?.key,"new2026")
    }
    func testAllTemplatesCreateAndReopen() async throws {
        for template in LaTeXTemplates.all {
            let root=try temporary()
            let store=try LaTeXProjectStore.create(root:root,owner:.init(kind:.space,id:UUID()),title:template.englishTitle,files:template.files,mainFile:template.mainFile,engine:template.engine)
            let snapshot=try await store.snapshot()
            XCTAssertTrue(try String(contentsOf:snapshot.sourceRoot.appendingPathComponent("main.tex"),encoding:.utf8).contains("\\end{document}"))
            XCTAssertEqual(snapshot.manifest.files.count,template.files.count)
        }
    }
}
