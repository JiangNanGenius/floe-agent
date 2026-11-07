import XCTest
import Foundation
import FloeBiologyCore
import FloeBiologyEngine

private final class CancellationFlag:@unchecked Sendable {
    private let lock=NSLock();private var value=false
    func set(){lock.withLock{value=true}}
    func get()->Bool{lock.withLock{value}}
}
private actor OwnedFixtureBackend:BiologyBackend {
    nonisolated let environmentID="fixture.owner"
    nonisolated let engineVersion="contract"
    nonisolated let methods:Set<String>=["sequence.stats"]
    let uncertain:Bool
    var entered=false
    var stopped=false
    init(uncertain:Bool=false){self.uncertain=uncertain}
    func evaluate(projectID:UUID,asset:BiologyAsset,method:String,options:JSONValue,runID:UUID,owner:BiologyExecutionOwner?) async throws -> BiologyAnalysisResult {
        entered=true
        if uncertain {throw BiologyWorkerStopUnconfirmed("Fixture lost the worker acknowledgement")}
        do{try await Task.sleep(for:.seconds(30));return .init(summary:"Unexpected completion")}catch{stopped=true;throw error}
    }
    func cancel(runID:UUID) async throws {if uncertain{throw BiologyWorkerStopUnconfirmed("No stop proof")}}
}
final class BiologyCancellationAndExportTests:XCTestCase,@unchecked Sendable {
    func root()->URL{FileManager.default.temporaryDirectory.appendingPathComponent("BiologyCancel-"+UUID().uuidString)}
    func testHostCancellationPropagatesToAlreadySubmittedTaskAndJoinsWorker() async throws {
        let url=root();defer{try? FileManager.default.removeItem(at:url)}
        let backend=OwnedFixtureBackend(),service=try BiologyService(store:BiologyProjectStore(root:url),backends:[backend],authorize:{_ in}),flag=CancellationFlag()
        let p=try await service.create(title:"Owned"),a=try await service.importAsset(p.id,title:"DNA",format:"fasta",data:Data(">A\nATGC\n".utf8))
        let run=try await service.start(p.id,assetID:a.id,expectedAssetRevision:1,method:"sequence.stats",environmentID:backend.environmentID,cancellationCheck:{flag.get()})
        for _ in 0..<100 {if await backend.entered{break};try await Task.sleep(for:.milliseconds(10))}
        flag.set();let completed=try await service.wait(p.id,runID:run.id)
        XCTAssertEqual(completed.status,.cancelled);let stopped=await backend.stopped;XCTAssertTrue(stopped)
        try await service.delete(p.id)
    }
    func testUnconfirmedStopSurvivesReopenAndBlocksDeletionUntilExactHostReconciliation() async throws {
        let url=root();defer{try? FileManager.default.removeItem(at:url)}
        let backend=OwnedFixtureBackend(uncertain:true),owner=BiologyExecutionOwner(taskID:UUID(),hostRunID:UUID()),service=try BiologyService(store:BiologyProjectStore(root:url),backends:[backend],authorize:{_ in})
        let p=try await service.create(title:"Unknown worker"),a=try await service.importAsset(p.id,title:"DNA",format:"fasta",data:Data(">A\nATGC\n".utf8))
        let run=try await service.start(p.id,assetID:a.id,expectedAssetRevision:1,method:"sequence.stats",environmentID:backend.environmentID,owner:owner)
        let completed=try await service.wait(p.id,runID:run.id);XCTAssertTrue(completed.isActive);XCTAssertEqual(completed.workerStopUnconfirmed,true)
        let reopened=try BiologyService(store:BiologyProjectStore(root:url),authorize:{_ in})
        do{try await reopened.delete(p.id);XCTFail("Deleted while the processor may still be running")}catch{}
        do{try await reopened.reconcileStoppedWorker(p.id,runID:run.id,owner:.init(taskID:UUID(),hostRunID:UUID()),environmentID:backend.environmentID);XCTFail("Foreign reconciliation accepted")}catch{}
        try await reopened.reconcileStoppedWorker(p.id,runID:run.id,owner:owner,environmentID:backend.environmentID)
        try await reopened.delete(p.id)
    }
    func testConcurrentAndReopenedExportReplayUsesTheSameRealFile() async throws {
        let url=root();defer{try? FileManager.default.removeItem(at:url)}
        let files=try BiologyWorkspaceFiles(root:url.appendingPathComponent("files"),environmentID:"fixture",authorize:{_,_ in}),store=try BiologyProjectStore(root:url.appendingPathComponent("projects")),service=try BiologyService(store:store,fileAccess:files,authorize:{_ in})
        let p=try await service.create(title:"Export"),owner=BiologyExecutionOwner(taskID:UUID(),hostRunID:UUID()),tools=BiologyToolSession(service:service,authorizedProjectIDs:[p.id],owner:owner)
        let args=JSONValue.object(["projectID":.string(p.id.uuidString),"destination":.string("file")])
        async let a=tools.invoke(name:"biology.export",arguments:args,requestID:"export")
        async let b=tools.invoke(name:"biology.export",arguments:args,requestID:"export")
        let (one,two)=try await (a,b);XCTAssertEqual(one,two)
        let fresh=try BiologyService(store:BiologyProjectStore(root:store.root),fileAccess:files,authorize:{_ in}),session=BiologyToolSession(service:fresh,authorizedProjectIDs:[p.id],owner:owner)
        let replay=try await session.invoke(name:"biology.export",arguments:args,requestID:"export");XCTAssertEqual(one,replay)
        let directory=files.root.appendingPathComponent(p.id.uuidString.lowercased()),copies=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).filter{$0.pathExtension=="bin"}
        XCTAssertEqual(copies.count,1)
    }
    func testLargeNativeOriginalExportPreservesBytesAndRejectsChangedOriginal() async throws {
        let url=root();defer{try? FileManager.default.removeItem(at:url)}
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        let source=url.appendingPathComponent("large.tiff"),bytes=Data(repeating:137,count:17*1024*1024)
        try bytes.write(to:source)
        let files=try BiologyWorkspaceFiles(root:url.appendingPathComponent("files"),environmentID:"fixture",authorize:{_,_ in}),service=try BiologyService(store:BiologyProjectStore(root:url.appendingPathComponent("projects")),fileAccess:files,authorize:{_ in})
        let project=try await service.create(title:"Large original"),asset=try await service.importURL(project.id,trustedSourceURL:source)
        XCTAssertTrue(asset.originalData.isEmpty);XCTAssertEqual(asset.fileReference?.byteCount,UInt64(bytes.count))
        let export=try await service.nativeOriginalExport(project.id,assetID:asset.id)
        XCTAssertEqual(export.url.lastPathComponent,"large.tiff")
        XCTAssertEqual(BiologyProjectStore.digest(try Data(contentsOf:export.url)),asset.fileReference?.sha256)
        await service.finishNativeExport(export);XCTAssertFalse(FileManager.default.fileExists(atPath:export.url.path))
        do{_=try await service.nativeOriginalExport(UUID(),assetID:asset.id);XCTFail("Foreign original exported")}catch{}
        let ref=try XCTUnwrap(asset.fileReference),path=files.root.appendingPathComponent(ref.projectID.uuidString.lowercased()).appendingPathComponent(ref.id.uuidString.lowercased()+".bin")
        let handle=try FileHandle(forWritingTo:path);try handle.write(contentsOf:Data([0]));try handle.close()
        do{_=try await service.nativeOriginalExport(project.id,assetID:asset.id);XCTFail("Changed original exported")}catch{}
        let staged=try FileManager.default.contentsOfDirectory(at:files.root.appendingPathComponent(".native-exports"),includingPropertiesForKeys:nil)
        XCTAssertTrue(staged.isEmpty)
    }
    func testAIImportsSavedProjectViaScopedFileWithoutLargeArguments() async throws {
        let url=root();defer{try? FileManager.default.removeItem(at:url)}
        let files=try BiologyWorkspaceFiles(root:url.appendingPathComponent("files"),environmentID:"fixture",authorize:{_,_ in}),service=try BiologyService(store:BiologyProjectStore(root:url.appendingPathComponent("projects")),fileAccess:files,authorize:{_ in})
        let project=try await service.create(title:"File roundtrip"),owner=BiologyExecutionOwner(taskID:UUID(),hostRunID:UUID()),notes=String(repeating:"data ",count:14000)
        try await service.saveNotes(project.id,text:notes,expectedRevision:project.revision)
        let file=try await service.exportFile(project.id,assetID:nil,format:"json",owner:owner)
        XCTAssertGreaterThan(file.byteCount,65536)
        let tools=BiologyToolSession(service:service,authorizedProjectIDs:[project.id],owner:owner,canCreate:true)
        var args:[String:JSONValue]=["sourceProjectID":.string(project.id.uuidString),"fileID":.string(file.fileID.uuidString)]
        let imported=try await tools.invoke(name:"biology.importProject",arguments:.object(args),requestID:"file-project-import")
        let freshID=try XCTUnwrap(imported["id"]?.string.flatMap(UUID.init(uuidString:))),fresh=try await service.project(freshID)
        XCTAssertNotEqual(fresh.id,project.id);XCTAssertEqual(fresh.notes,notes)
        let replay=try await tools.invoke(name:"biology.importProject",arguments:.object(args),requestID:"file-project-import");XCTAssertEqual(replay["id"],imported["id"])
        args["sourceProjectID"] = .string(UUID().uuidString)
        do{_=try await tools.invoke(name:"biology.importProject",arguments:.object(args));XCTFail("Foreign file project imported")}catch{}
        args["sourceProjectID"] = .string(project.id.uuidString);args["base64"] = .string("e30=")
        do{_=try await tools.invoke(name:"biology.importProject",arguments:.object(args));XCTFail("Ambiguous input accepted")}catch{}
    }
}
