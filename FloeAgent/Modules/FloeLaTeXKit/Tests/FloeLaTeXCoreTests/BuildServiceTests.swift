import XCTest
import FloeLaTeXCore
import FloeLaTeXEngine

private struct FixtureEngine:LaTeXEngineRunning {
    var delay:Duration = .milliseconds(10)
    func capabilities() async -> [LaTeXEngineCapability] {[.init(engine:.xeLaTeX,version:"test-fixture",bibliography:[],isLocal:true)]}
    func run(_ request:LaTeXEngineRequest,progress:@escaping @Sendable (String)->Void) async throws -> LaTeXEngineOutput {
        progress("Fixture engine is running")
        try await Task.sleep(for:delay)
        try FileManager.default.createDirectory(at:request.outputRoot,withIntermediateDirectories:true)
        let pdf=request.outputRoot.appendingPathComponent("main.pdf")
        try Data("%PDF-1.4\nfixture-only\n".utf8).write(to:pdf)
        return .init(pdf:pdf,version:"test-fixture",messages:["Fixture complete"])
    }
}
final class BuildServiceTests:XCTestCase,@unchecked Sendable {
    func testSnapshotBuildStatusPersistsAndSourceIsReleased() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try LaTeXProjectStore.create(root:root.appendingPathComponent("Project"),owner:.init(kind:.task,id:UUID()),title:"Test",files:["main.tex":Data("中文 document".utf8)])
        let service=try LaTeXBuildService(cacheRoot:root.appendingPathComponent("Cache"),engine:FixtureEngine())
        let start=try await service.start(store:store,expectedRevision:0)
        let repeated=try await service.start(store:store,expectedRevision:0)
        XCTAssertEqual(start.id,repeated.id)
        _=try await store.apply([.put(path:"main.tex",data:Data("Newer source".utf8))],expectedRevision:0)
        let completed=try await service.wait(start.id)
        XCTAssertEqual(completed.state,.succeeded);XCTAssertEqual(completed.revision,0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:store.root.appendingPathComponent("Snapshots").path).isEmpty)
        let reopened=try LaTeXBuildService(cacheRoot:root.appendingPathComponent("Cache"),engine:FixtureEngine())
        let history=try await reopened.history(store:store)
        XCTAssertEqual(history.first?.id,start.id);XCTAssertEqual(history.first?.state,.succeeded)
        let waited=try await reopened.wait(start.id);XCTAssertEqual(waited.engineVersion,"test-fixture")
    }
    func testCancellationJoinsEngineBeforeReleasingSnapshot() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try LaTeXProjectStore.create(root:root.appendingPathComponent("Project"),owner:.init(kind:.task,id:UUID()),title:"Test",files:["main.tex":Data("source".utf8)])
        let service=try LaTeXBuildService(cacheRoot:root.appendingPathComponent("Cache"),engine:FixtureEngine(delay:.seconds(10)))
        let start=try await service.start(store:store)
        await service.cancel(start.id)
        let result=try await service.wait(start.id)
        XCTAssertEqual(result.state,.cancelled)
        let busy=await service.isBusy(projectID:result.projectID);XCTAssertFalse(busy)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:store.root.appendingPathComponent("Snapshots").path).isEmpty)
    }
    func testToolReadUsesUTF8PagesAndTypedMutationCAS() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try LaTeXProjectStore.create(root:root,owner:.init(kind:.task,id:UUID()),title:"Test",files:["main.tex":Data("中文🙂abc".utf8)])
        let first=try await LaTeXToolOperations.read(store:store,path:"main.tex",limit:1)
        XCTAssertEqual(first.text,"中");XCTAssertEqual(first.nextOffset,3)
        let second=try await LaTeXToolOperations.read(store:store,path:"main.tex",offset:3,limit:4)
        XCTAssertEqual(second.text,"文");XCTAssertEqual(second.nextOffset,6)
        let id=UUID(),operations=[LaTeXFileOperation(operation:.replace,path:"main.tex",text:"English",start:0,length:6)]
        let result=try await LaTeXToolOperations.apply(store:store,operations:operations,expectedRevision:0,mutationID:id,origin:"ai")
        let replay=try await LaTeXToolOperations.apply(store:store,operations:operations,expectedRevision:0,mutationID:id,origin:"ai")
        XCTAssertEqual(result.revision,1);XCTAssertTrue(replay.replayed)
        let text=try await store.text("main.tex");XCTAssertEqual(text,"English🙂abc")
    }
    func testSourceMapResolvesNestedSourceAndPDFCoordinates() throws {
        let root=URL(fileURLWithPath:"/project/snapshot")
        let text="SyncTeX Version:1\nInput:1:/project/snapshot/main.tex\nInput:2:/project/snapshot/chapter.tex\nUnit:1\nMagnification:1000\n{1\n(1,7:6553600,13107200:655360,327680,65536\nx2,12:6553600,26214400\n}1\n"
        let map=LaTeXSyncTeX(text:text,sourceRoot:root,mainFile:"main.tex")
        XCTAssertEqual(map.forward(path:"main.tex",line:7)?.page,1)
        let location=try XCTUnwrap(map.forward(path:"chapter.tex",line:12))
        XCTAssertEqual(map.reverse(page:1,x:location.x,y:location.y)?.path,"chapter.tex")
    }
}
