import XCTest
import FloeLaTeXCore
import FloeLaTeXParsing
import FloeLaTeXReferences
import FloeLaTeXEngine
import FloeLaTeXResources

private struct UnconfirmedFixtureEngine:LaTeXEngineRunning {
    func capabilities() async->[LaTeXEngineCapability] {[]}
    func run(_ request:LaTeXEngineRequest,progress:@escaping @Sendable (String)->Void) async throws->LaTeXEngineOutput {throw LaTeXEngineFailure("Fixture worker stop is unknown",workerStopped:false)}
}
private final class LifetimeCounter:@unchecked Sendable {
    private let lock=NSLock();private var count=0
    func increment() {lock.withLock{count+=1}}
    var value:Int {lock.withLock{count}}
}
private final class CountedLifetime:LaTeXBuildLifetime,Sendable {
    let counter:LifetimeCounter
    init(_ counter:LifetimeCounter) {self.counter=counter}
    deinit {counter.increment()}
}
final class EditingContractTests:XCTestCase,@unchecked Sendable {
    func testInvalidImportLeavesReservedDirectoryAvailableForCorrectedRetry() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let owner=LaTeXOwner(kind:.task,id:UUID())
        XCTAssertThrowsError(try LaTeXProjectStore.create(root:root,owner:owner,title:"Import",files:["main.tex":Data("Valid".utf8),"z.tex":Data([0xff])]))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("Source").path))
        XCTAssertThrowsError(try LaTeXProjectStore.create(root:root,owner:owner,title:"Import",files:["main.tex":Data("Valid".utf8),"Folder":Data(),"folder/data.csv":Data()]))
        let store=try LaTeXProjectStore.create(root:root,owner:owner,title:"Import",files:["main.tex":Data("Corrected".utf8)])
        let text=try await store.text("main.tex");XCTAssertEqual(text,"Corrected")
    }
    func testUnconfirmedWorkerRetainsOwnerUntilHostAcknowledgesActualStop() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let store=try LaTeXProjectStore.create(root:root.appendingPathComponent("Project"),owner:.init(kind:.task,id:UUID()),title:"Test",files:["main.tex":Data("Source".utf8)])
        let service=try LaTeXBuildService(cacheRoot:root.appendingPathComponent("Cache"),engine:UnconfirmedFixtureEngine()),counter=LifetimeCounter()
        let build=try await service.start(store:store,lifetime:CountedLifetime(counter))
        _=try await service.wait(build.id)
        XCTAssertEqual(counter.value,0)
        try await service.releaseAfterConfirmedWorkerStop(build.id)
        XCTAssertEqual(counter.value,1)
    }
    func testSourceCompletionPreservesUnicodeExistingBracesAndCitationList() throws {
        let text="中文 \\se{Existing}"
        let completion=try XCTUnwrap(LaTeXSourceCompletion.suggestions(source:text,offset:"中文 \\se".utf8.count,labels:[],citations:[]).first)
        XCTAssertEqual(try completion.range.replacing(in:text,with:completion.replacement),"中文 \\section{Existing}")
        let cite="文献 \\cite{first,rea}"
        let suggestion=try XCTUnwrap(LaTeXSourceCompletion.suggestions(source:cite,offset:cite.utf8.count-1,labels:["wrong"],citations:["realKey","first"]).first)
        XCTAssertEqual(try suggestion.range.replacing(in:cite,with:suggestion.replacement),"文献 \\cite{first,realKey}")
        let comment="% \\se"
        XCTAssertTrue(LaTeXSourceCompletion.suggestions(source:comment,offset:comment.utf8.count,labels:[],citations:[]).isEmpty)
    }
    func testWritingCountsExcludePreambleCommandsCommentsAndMath() {
        let source="\\documentclass{article}\n\\title{Metadata outside body}\n\\begin{document}\n% hidden words\n中文 Hello \\textbf{world} $x+y$\n\\bibliographystyle{plain}\n\\end{document}"
        let counts=LaTeXWritingStatistics(source:source)
        XCTAssertEqual(counts.words,2);XCTAssertEqual(counts.hanCharacters,2);XCTAssertEqual(counts.formulas,1);XCTAssertTrue(counts.estimated)
    }
    func testTextIndexDoesNotCopyBinaryAssetsOrCreateBuildSnapshots() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let store=try LaTeXProjectStore.create(root:root,owner:.init(kind:.task,id:UUID()),title:"Test",files:["main.tex":Data("Text".utf8),"Assets/picture.png":Data([0,1,2,3])])
        let inputs=try await store.textFiles()
        XCTAssertEqual(inputs.files,["main.tex":"Text"]);XCTAssertEqual(inputs.manifest.files.count,2)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("Snapshots").path))
    }
    func testInterruptedEnvironmentBuildRemainsBlockedAfterRestart() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let store=try LaTeXProjectStore.create(root:root.appendingPathComponent("Project"),owner:.init(kind:.task,id:UUID()),title:"Test",files:["main.tex":Data("source".utf8)])
        let snapshot=try await store.snapshot()
        var record=LaTeXBuildRecord(snapshot:snapshot);record.state = .compiling
        record.executionOwner = .init(taskID:UUID(),runID:UUID(),environmentID:"explicit-linux")
        let directory=store.root.appendingPathComponent("Builds/"+record.id.uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try LaTeXDigest.encode(record).write(to:directory.appendingPathComponent("Build.json"))
        try LaTeXDigest.encode(snapshot.manifest).write(to:directory.appendingPathComponent("SourceManifest.json"))
        let service=try LaTeXBuildService(cacheRoot:root.appendingPathComponent("Cache"))
        let history=try await service.history(store:store)
        XCTAssertEqual(history.first?.workerStopped,false);XCTAssertEqual(history.first?.state,.interrupted)
        do {_=try await service.start(store:store);XCTFail("A process restart cannot prove a Linux worker stopped")}catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath:snapshot.sourceRoot.path))
    }
    func testSnapshotRejectsStaleRevisionAndSourceReadStaysAtomic() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let store=try LaTeXProjectStore.create(root:root,owner:.init(kind:.task,id:UUID()),title:"Test",files:["main.tex":Data("First".utf8)])
        _=try await store.apply([.put(path:"main.tex",data:Data("Second".utf8))],expectedRevision:0)
        do {_=try await store.snapshot(expectedRevision:0);XCTFail("A stale typeset/export request must not capture newer source")}catch let error as LaTeXError {XCTAssertEqual(error,.revisionConflict(expected:0,actual:1))}
        let captured=try await store.file("main.tex")
        XCTAssertEqual(captured.manifest.revision,1);XCTAssertEqual(String(decoding:captured.data,as:UTF8.self),"Second")
    }
    func testDocumentCommandsDoNotAppearAsOrdinaryProseAndListPreservesBraces() throws {
        let source="\\begin{document}\n\\maketitle\n\\section{Title}\nText.\n\\bibliographystyle{plain}\n\\bibliography{references}\n\\end{document}"
        let index=LaTeXParser.parse(source)
        XCTAssertTrue(index.blocks.contains{$0.name=="maketitle" && $0.kind == .environment})
        XCTAssertFalse(index.blocks.filter{$0.kind == .paragraph}.contains{$0.content.contains("plain")})
        let content="\n\\item {Braced} \\textbf{first}\n\\item[Term] Next \\begin{itemize}\\item Nested\\end{itemize}\n\\item Last\n"
        let list=try XCTUnwrap(LaTeXListProjection(content:content))
        XCTAssertEqual(list.items.count,3);XCTAssertTrue(list.items[0].content.hasPrefix("{Braced}"));XCTAssertEqual(list.items[1].label,"Term")
        XCTAssertTrue(list.items[1].content.contains("\\item Nested"))
    }
    func testUnconfirmedWorkerRetainsSnapshotAcrossServiceRestart() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let store=try LaTeXProjectStore.create(root:root.appendingPathComponent("Project"),owner:.init(kind:.task,id:UUID()),title:"Test",files:["main.tex":Data("source".utf8)])
        let service=try LaTeXBuildService(cacheRoot:root.appendingPathComponent("Cache"),engine:UnconfirmedFixtureEngine())
        let started=try await service.start(store:store),record=try await service.wait(started.id)
        XCTAssertEqual(record.workerStopped,false);XCTAssertEqual(record.state,.interrupted)
        XCTAssertTrue(FileManager.default.fileExists(atPath:store.root.appendingPathComponent("Snapshots/"+record.snapshotID.uuidString).path))
        let reopened=try LaTeXBuildService(cacheRoot:root.appendingPathComponent("Cache"),engine:UnconfirmedFixtureEngine())
        do {_=try await reopened.start(store:store);XCTFail("An unconfirmed worker must block another launch")}catch {}
        let busy=await reopened.isBusy(projectID:record.projectID);XCTAssertTrue(busy)
        try await reopened.releaseAfterConfirmedWorkerStop(record.id)
        let stopped=await reopened.isBusy(projectID:record.projectID);XCTAssertFalse(stopped)
        let history=try await reopened.history(store:store);XCTAssertEqual(history.first?.workerStopped,true)
    }
    func testCitationActivatesOneBibliographyAndRetainsSource() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let source="\\documentclass{article}\n\\begin{document}\nText.\n\\bibliographystyle{plain}\n% \\bibliography{references}\n\\end{document}\n"
        let bib=try LaTeXBibParser.source(type:"article",key:"realKey",fields:["title":"Fixture"])
        let store=try LaTeXProjectStore.create(root:root,owner:.init(kind:.task,id:UUID()),title:"Test",files:["main.tex":Data(source.utf8),"references.bib":Data(bib.utf8)])
        let offset=try XCTUnwrap(source.range(of:"Text.")).upperBound
        let position=source.utf8.distance(from:source.utf8.startIndex,to:offset)
        _=try await LaTeXProjectEditing.insertCitation(store:store,path:"main.tex",offset:position,key:"realKey",expectedRevision:0)
        let text=try await store.text("main.tex"),index=LaTeXParser.parse(text)
        XCTAssertEqual(index.commands.filter{$0.name=="bibliographystyle"}.count,1)
        XCTAssertEqual(index.commands.filter{$0.name=="bibliography"}.count,1)
        XCTAssertEqual(index.citations,["realKey"]);XCTAssertTrue(text.contains("% \\bibliography{references}"))
    }
    func testTableCellsPreserveEscapedSeparatorsAndMacros() throws {
        let text="\\begin{tabular}{ll}\n\\toprule\n{A} & \\textbf{B \\& C} \\\\\n\\midrule\nD & E \\\\\n\\bottomrule\n\\end{tabular}"
        let table=try XCTUnwrap(LaTeXTableProjection(source:text))
        XCTAssertEqual(table.rows.count,2);XCTAssertEqual(table.rows[0].map(\.source),["{A}","\\textbf{B \\& C}"])
        let cell=table.rows[1][1],changed=try cell.range.replacing(in:text,with:"New")
        XCTAssertTrue(changed.contains("D & New"));XCTAssertTrue(changed.contains("\\bottomrule"))
    }
    func testMissingZeroByteResourceIsNotInstalled() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let item=LaTeXResourcePackage(id:"empty",version:"1",license:"MIT",files:[.init(path:"empty.tex",sha256:LaTeXDigest.hash(Data()),byteCount:0,downloadURL:URL(string:"https://example.com/empty.tex")!)])
        let resources=try LaTeXResourceStore(root:root,packages:[item]);let status=try await resources.status("empty")
        XCTAssertFalse(status.installed);XCTAssertEqual(status.bytesToDownload,0)
    }
    func testPaperInformationOnlyChangesRequestedPreambleFields() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let source="\\documentclass{article}\n% preserved\n\\title{Old \\custom{title}}\n\\author{Original}\n\\begin{document}\nBody.\n\\end{document}\n"
        let store=try LaTeXProjectStore.create(root:root,owner:.init(kind:.task,id:UUID()),title:"Test",files:["main.tex":Data(source.utf8)])
        let edits=try LaTeXProjectEditing.preambleEdits(source:source,path:"main.tex",values:["title":"New \\textbf{title}","date":"2026"])
        _=try await store.apply(edits,expectedRevision:0)
        let text=try await store.text("main.tex")
        XCTAssertTrue(text.contains("% preserved\n\\title{New \\textbf{title}}"));XCTAssertTrue(text.contains("\\author{Original}"));XCTAssertTrue(text.contains("Body."));XCTAssertTrue(text.contains("\\date{2026}"))
    }
}
