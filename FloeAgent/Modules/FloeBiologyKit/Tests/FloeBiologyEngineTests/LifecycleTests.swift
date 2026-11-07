import XCTest
import FloeBiologyCore
import FloeBiologyEngine
import FloeBiologySamples

private actor WaitingBackend:BiologyBackend {
    nonisolated let environmentID="qualified.waiting"
    nonisolated let engineVersion="test-owned-worker"
    nonisolated let methods:Set<String>=["sequence.stats"]
    var entered=false
    var stopped=false
    var acknowledged=false
    func evaluate(projectID:UUID,asset:BiologyAsset,method:String,options:JSONValue,runID:UUID,owner:BiologyExecutionOwner?) async throws -> BiologyAnalysisResult {
        entered=true
        do {try await Task.sleep(for:.seconds(30));return .init(summary:"unexpected completion")}
        catch {stopped=true;throw error}
    }
    func cancel(runID:UUID) async throws {acknowledged=true}
}

final class BiologyLifecycleTests:XCTestCase,@unchecked Sendable {
    private func root()->URL {FileManager.default.temporaryDirectory.appendingPathComponent("BiologyLifecycle-"+UUID().uuidString)}
    func testCrossInstanceCASHistoryAndCorruptHead() async throws {
        let url=root();defer{try? FileManager.default.removeItem(at:url)}
        let one=try BiologyProjectStore(root:url),two=try BiologyProjectStore(root:url)
        let p=try await one.create(title:"Project")
        let changed=try await one.update(p.id,expectedRevision:p.revision){$0.notes="saved"}
        do {_=try await two.update(p.id,expectedRevision:p.revision){$0.notes="stale"};XCTFail("Stale write accepted")}
        catch BiologyError.conflict {} // The other instance must see the actual HEAD.
        let read=try await two.load(p.id);XCTAssertEqual(read.notes,"saved")
        do {_=try await two.update(p.id){$0.id=UUID()};XCTFail("Identity changed")}
        catch BiologyError.invalid {}
        let restored=try await two.restore(p.id,revision:1,expectedRevision:changed.revision)
        XCTAssertEqual(restored.notes,"");XCTAssertGreaterThan(restored.revision,changed.revision)
        let history=try await one.history(p.id);XCTAssertEqual(history,[3,2,1])
        let dir=url.appendingPathComponent(p.id.uuidString.lowercased())
        try Data("corrupt".utf8).write(to:dir.appendingPathComponent("revisions/3.json"))
        do {_=try await one.load(p.id);XCTFail("Corrupt saved bytes accepted")} catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath:dir.appendingPathComponent("revisions/2.json").path))
        let absent=UUID()
        do {_=try await one.history(absent);XCTFail("Created missing history")} catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:url.appendingPathComponent(absent.uuidString.lowercased()).path))
    }
    func testSnapshotResultCannotApplyAfterEditAndRestorationAvoidsABA() async throws {
        let url=root();defer{try? FileManager.default.removeItem(at:url)}
        let service=try BiologyService(store:BiologyProjectStore(root:url),authorize:{_ in})
        let p=try await service.create(title:"Sequence")
        let original=Data("@measured\nATGC\n+\nIIII\n".utf8)
        let a=try await service.importAsset(p.id,title:"measured",format:"fastq",data:original)
        let before=try await service.project(p.id)
        let run=try await service.start(p.id,assetID:a.id,expectedAssetRevision:1,method:"sequence.reverseComplement")
        let completed=try await service.wait(p.id,runID:run.id);XCTAssertEqual(completed.status,.succeeded);XCTAssertEqual(completed.result?.text,"GCAT")
        try await service.editSequence(p.id,assetID:a.id,expectedAssetRevision:1,record:0,start:1,end:2,replacement:"AA")
        let edited=try await service.project(p.id)
        XCTAssertEqual(edited.assets[0].revision,2)
        guard case .sequence(let records)=edited.assets[0].payload else {return XCTFail("Sequence missing")}
        XCTAssertEqual(records[0].sequence,"AAAGC");XCTAssertNil(records[0].quality)
        let exported=try await service.exportAsset(p.id,assetID:a.id,format:"original");XCTAssertEqual(exported,original)
        do {_=try await service.applySequenceResult(p.id,runID:run.id);XCTFail("Historical output applied to new input")} catch {}
        let restored=try await service.restore(p.id,revision:before.revision,expectedRevision:edited.revision)
        XCTAssertGreaterThan(restored.assets[0].revision,edited.assets[0].revision)
        do {try await service.editSequence(p.id,assetID:a.id,expectedAssetRevision:1,record:0,start:0,end:1,replacement:"T");XCTFail("ABA stale edit accepted")} catch {}
        let encoded=try await service.exportProject(p.id)
        let imported=try await service.importProject(encoded)
        XCTAssertNotEqual(imported.id,p.id);XCTAssertEqual(imported.assets,restored.assets)
        let reopened=try BiologyService(store:BiologyProjectStore(root:url),authorize:{_ in})
        let disk=try await reopened.project(imported.id);XCTAssertEqual(disk,imported)
    }
    func testServiceOwnsWorkerAndCancellationReallyStopsBeforeDeletion() async throws {
        let url=root();defer{try? FileManager.default.removeItem(at:url)}
        let backend=WaitingBackend()
        let store=try BiologyProjectStore(root:url)
        let service=try BiologyService(store:store,backends:[backend],authorize:{_ in})
        let p=try await service.create(title:"Worker")
        let a=try await service.importAsset(p.id,title:"DNA",format:"fasta",data:Data(">A\nATGC\n".utf8))
        let run=try await service.start(p.id,assetID:a.id,expectedAssetRevision:1,method:"sequence.stats",environmentID:backend.environmentID)
        for _ in 0..<1000 {if await backend.entered {break};try await Task.sleep(for:.milliseconds(2))}
        let entered=await backend.entered;XCTAssertTrue(entered)
        do {try await service.delete(p.id);XCTFail("Deleted active worker data")} catch {}
        let current=try await service.project(p.id)
        do {_=try await service.restore(p.id,revision:1,expectedRevision:current.revision);XCTFail("Restored over active worker")} catch {}
        try await service.cancel(p.id,runID:run.id)
        let stopped=await backend.stopped,ack=await backend.acknowledged
        XCTAssertTrue(stopped);XCTAssertTrue(ack)
        let terminal=try await service.wait(p.id,runID:run.id);XCTAssertEqual(terminal.status,.cancelled);XCTAssertNil(terminal.result)
        try await service.delete(p.id)
        let remaining=try await service.projects();XCTAssertTrue(remaining.isEmpty)
        let trash=try FileManager.default.contentsOfDirectory(at:url.appendingPathComponent("Trash"),includingPropertiesForKeys:nil)
        XCTAssertEqual(trash.count,1)
    }
    func testHostAuthorizationAndToolScopeAreNotArguments() async throws {
        let url=root();defer{try? FileManager.default.removeItem(at:url)}
        let store=try BiologyProjectStore(root:url)
        let service=try BiologyService(store:store,authorize:{access in if access.action == .delete {throw BiologyError.unavailable("Host denied deletion")}})
        let a=try await service.create(title:"Authorized"),b=try await service.create(title:"Foreign")
        let owner=BiologyExecutionOwner(taskID:UUID(),hostRunID:UUID())
        let tools=BiologyToolSession(service:service,authorizedProjectIDs:[a.id],owner:owner)
        do {_=try await tools.invoke(name:"biology.read",arguments:.object(["projectID":.string(b.id.uuidString),"authorized":.bool(true)]));XCTFail("Model granted foreign scope")} catch {}
        do {_=try await tools.invoke(name:"biology.create",arguments:.object(["title":.string("unauthorized")]));XCTFail("Created outside scope")} catch {}
        do {try await service.delete(a.id);XCTFail("Bypassed host authorizer")} catch {}
        let read=try await service.project(a.id);XCTAssertEqual(read.title,"Authorized")
        let asset=try await service.importAsset(a.id,title:"DNA",format:"fasta",data:Data(">A\nATGC\n".utf8))
        let run=try await service.start(a.id,assetID:asset.id,expectedAssetRevision:1,method:"sequence.stats",owner:.init(taskID:UUID(),hostRunID:UUID()))
        _=try await service.wait(a.id,runID:run.id)
        do {_=try await tools.invoke(name:"biology.job",arguments:.object(["projectID":.string(a.id.uuidString),"runID":.string(run.id.uuidString)]));XCTFail("Observed another task's job")} catch {}
    }
    func testAIToolsImportRunDeriveAndExportActualBytes() async throws {
        let url=root();defer{try? FileManager.default.removeItem(at:url)}
        let service=try BiologyService(store:BiologyProjectStore(root:url),authorize:{_ in})
        let p=try await service.create(title:"AI tools")
        let tools=BiologyToolSession(service:service,authorizedProjectIDs:[p.id],owner:.init(taskID:UUID(),hostRunID:UUID()))
        let original=Data(">DNA\nATGGCT\n".utf8)
        let imported=try await tools.invoke(name:"biology.import",arguments:.object(["projectID":.string(p.id.uuidString),"title":.string("DNA"),"format":.string("fasta"),"base64":.string(original.base64EncodedString())]))
        let assetID=try XCTUnwrap(imported["id"]?.string)
        let overview=try await tools.invoke(name:"biology.read",arguments:.object(["projectID":.string(p.id.uuidString)]))
        XCTAssertNil(overview["assets"]?.array?.first?["originalData"])
        XCTAssertNil(overview["assets"]?.array?.first?["payload"])
        let started=try await tools.invoke(name:"biology.analyze",arguments:.object(["projectID":.string(p.id.uuidString),"assetID":.string(assetID),"expectedRevision":.number(1),"method":.string("sequence.translate")]))
        let runID=try XCTUnwrap(started["id"]?.string)
        let result=try await tools.invoke(name:"biology.job",arguments:.object(["projectID":.string(p.id.uuidString),"runID":.string(runID)]))
        XCTAssertEqual(result["status"]?.string,"succeeded");XCTAssertEqual(result["result"]?["text"]?.string,"MA")
        let derived=try await tools.invoke(name:"biology.derive",arguments:.object(["projectID":.string(p.id.uuidString),"runID":.string(runID),"expectedRevision":.number(1)]))
        XCTAssertNotEqual(derived["id"]?.string,assetID)
        let actual=try await tools.invoke(name:"biology.read",arguments:.object(["projectID":.string(p.id.uuidString),"assetID":.string(try XCTUnwrap(derived["id"]?.string))]))
        XCTAssertEqual(actual["payload"]?["sequence"]?["_0"]?.array?.first?["sequence"]?.string,"MA")
        let export=try await tools.invoke(name:"biology.export",arguments:.object(["projectID":.string(p.id.uuidString),"assetID":.string(assetID),"format":.string("original")]))
        XCTAssertEqual(Data(base64Encoded:try XCTUnwrap(export["base64"]?.string)),original)
        XCTAssertEqual(export["sha256"]?.string,BiologyProjectStore.digest(original))
        let descriptions=await tools.descriptors()
        XCTAssertFalse(descriptions.contains{$0.name=="biology.create"})
        for descriptor in descriptions {XCTAssertEqual(descriptor.parameters["type"]?.string,"object")}
    }
}
