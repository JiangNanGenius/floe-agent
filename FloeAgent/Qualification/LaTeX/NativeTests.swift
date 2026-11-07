import XCTest
import CoreGraphics
import FloeLaTeXCore
import FloeLaTeXEngine
import FloeLaTeXNativeExperiment
import UIKit
@testable import FloeLaTeXUI

final class LaTeXNativeTests:XCTestCase,@unchecked Sendable {
    @MainActor func testVisualTypingBeforeParentRefreshPreservesEveryEdit() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let id=UUID(),text="\\documentclass{article}\n\\begin{document}\n\\begin{abstract}Base.\\end{abstract}\n\\end{document}\n"
        let store=try LaTeXProjectStore.create(root:root.appendingPathComponent("Project"),id:id,owner:.init(kind:.task,id:id),title:"Typing",files:["main.tex":Data(text.utf8)])
        let session=LaTeXEditorSession(store:store,builds:try LaTeXBuildService(cacheRoot:root.appendingPathComponent("Cache")))
        await session.load()
        let block=try XCTUnwrap(session.structure.blocks.first(where:{$0.name=="abstract"}))
        let editor=LaTeXRichTextEditor(source:block.content,onChange:{original,value in
            session.update(range:.init(start:block.contentRange.start,length:original.utf8.count),original:original,replacement:value)
        },onFocus:{},onAttachment:{_,_ in})
        let coordinator=editor.makeCoordinator(),view=UITextView(usingTextLayoutManager:false)
        view.delegate=coordinator;coordinator.render(view)
        // Deliberately retain the original parent/block while UIKit delivers a
        // burst of edits, including Unicode and TeX-special characters.
        for character in " rapid 中文 & safe" {
            view.selectedRange=NSRange(location:view.text.utf16.count,length:0)
            view.insertText(String(character));coordinator.textViewDidChange(view)
        }
        XCTAssertNil(session.error)
        XCTAssertEqual(coordinator.document.visibleText,"Base. rapid 中文 & safe")
        XCTAssertTrue(session.source.contains("Base. rapid 中文 \\& safe\\end{abstract}"))
        try await session.save()
        let saved=try await store.text("main.tex");XCTAssertEqual(saved,session.source)
    }
    func testActualNativePDFAndSourceMap() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let id=UUID()
        let source="\\documentclass{article}\n\\begin{document}\nNative iPad PDF $E=mc^2$.\n\\input{chapter}\n\\end{document}\n"
        let store=try LaTeXProjectStore.create(root:root.appendingPathComponent("Project"),id:id,owner:.init(kind:.externalDocument,id:id),title:"Native",files:["main.tex":Data(source.utf8),"chapter.tex":Data("Included source.\n".utf8)])
        let cache=try FileManager.default.url(for:.documentDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("TypesettingCache")
        let service=try LaTeXBuildService(cacheRoot:cache,engine:LaTeXNativeExperiment())
        let capabilities=await service.capabilities()
        XCTAssertEqual(capabilities.first?.engine,.xeLaTeX)
        let start=try await service.start(store:store)
        let result=try await service.wait(start.id)
        XCTAssertEqual(result.state,.succeeded,result.diagnostics.map(\.message).joined(separator:"\n"))
        guard let relative=result.pdfRelativePath else {return XCTFail("No actual PDF")}
        let pdf=root.appendingPathComponent("Project/Builds/"+result.id.uuidString).appendingPathComponent(relative)
        let document=try XCTUnwrap(CGPDFDocument(pdf as CFURL));XCTAssertGreaterThan(document.numberOfPages,0)
        let sync=try XCTUnwrap(result.synctexRelativePath)
        let map=try LaTeXSyncTeX(url:root.appendingPathComponent("Project/Builds/"+result.id.uuidString).appendingPathComponent(sync),sourceRoot:store.root.appendingPathComponent("Snapshots/"+result.snapshotID.uuidString),mainFile:"main.tex")
        XCTAssertNotNil(map.forward(path:"main.tex",line:3));XCTAssertNotNil(map.forward(path:"chapter.tex",line:1))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:store.root.appendingPathComponent("Snapshots").path).isEmpty)
    }
    func testNativeBibTeXAndRecoveryAfterCancellation() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let id=UUID(),store=try LaTeXProjectStore.create(root:root.appendingPathComponent("Project"),id:id,owner:.init(kind:.task,id:id),title:"Recovery",files:["main.tex":Data("\\documentclass{article}\n\\begin{document}\n\\def\\forever{\\forever}\\forever\n\\end{document}\n".utf8)])
        let cache=try FileManager.default.url(for:.documentDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("TypesettingCache")
        let service=try LaTeXBuildService(cacheRoot:cache,engine:LaTeXNativeExperiment())
        let first=try await service.start(store:store)
        try await Task.sleep(for:.milliseconds(200));await service.cancel(first.id)
        let stopped=try await service.wait(first.id);XCTAssertEqual(stopped.state,.cancelled)
        let source="\\documentclass{article}\n\\begin{document}\nSynthetic fixture \\cite{fixture}.\n\\bibliographystyle{plain}\n\\bibliography{references}\n\\end{document}\n"
        let bib="@book{fixture,author={Example Author},title={Synthetic Bibliography Fixture},year={2026},publisher={Example Publisher}}\n"
        _=try await store.apply([.put(path:"main.tex",data:Data(source.utf8)),.put(path:"references.bib",data:Data(bib.utf8))],expectedRevision:0)
        let second=try await service.start(store:store,configuration:.init(offline:false))
        let result=try await service.wait(second.id)
        XCTAssertEqual(result.state,.succeeded,result.diagnostics.map(\.message).joined(separator:"\n"))
        let bbl=store.root.appendingPathComponent("Builds/"+result.id.uuidString+"/Output/main.bbl")
        let bibliography=try String(contentsOf:bbl,encoding:.utf8)
        XCTAssertTrue(bibliography.contains("Synthetic Bibliography Fixture"))
    }
}
