import XCTest
import FloeBiologyCore
import FloeBiologyEngine
import FloeBiologySamples

private actor TestModel:BiologyAssistantProvider {
    var index=0
    let project:UUID
    init(_ project:UUID){self.project=project}
    func respond(messages:[BiologyAssistantMessage],tools:[BiologyToolDescriptor]) async throws -> BiologyAssistantReply {
        defer{index+=1}
        if index==0 {return .init(text:"",calls:[.init(id:"read",name:"biology.read",arguments:.object(["projectID":.string(project.uuidString)]))])}
        if index==1 {return .init(text:"",calls:[.init(id:"notes",name:"biology.update",arguments:.object(["projectID":.string(project.uuidString),"operation":.string("project.notes"),"expectedRevision":.number(1),"parameters":.object(["text":.string("Saved through the model tool loop")])]))])}
        guard messages.last?.role=="tool",messages.last?.text.contains("revision")==true else {throw BiologyError.invalid("Tool output did not return to the provider.")}
        return .init(text:"Notes saved.")
    }
}
final class BiologyToolClosureTests:XCTestCase,@unchecked Sendable {
    func root()->URL {FileManager.default.temporaryDirectory.appendingPathComponent("BiologyToolClosure-"+UUID().uuidString)}
    func testAtomicReplaySurvivesReopenAndRestoreAndDoesNotDuplicateLargeImports() async throws {
        let url=root();defer{try? FileManager.default.removeItem(at:url)}
        let service=try BiologyService(store:BiologyProjectStore(root:url),authorize:{_ in}),owner=BiologyExecutionOwner(taskID:UUID(),hostRunID:UUID())
        let session=BiologyToolSession(service:service,authorizedProjectIDs:[],owner:owner,canCreate:true)
        let created=try await session.invoke(name:"biology.create",arguments:.object(["title":.string("Replay")]),requestID:"create")
        let id=try XCTUnwrap(created["id"]?.string.flatMap(UUID.init(uuidString:)))
        let repeated=try await session.invoke(name:"biology.create",arguments:.object(["title":.string("Replay")]),requestID:"create");XCTAssertEqual(created,repeated)
        let raw=Data((">A\n"+String(repeating:"ATGC",count:30000)+"\n").utf8)
        let args=JSONValue.object(["projectID":.string(id.uuidString),"title":.string("DNA"),"format":.string("fasta"),"base64":.string(raw.base64EncodedString())])
        let imported=try await session.invoke(name:"biology.import",arguments:args,requestID:"import")
        let reopened=try BiologyService(store:BiologyProjectStore(root:url),authorize:{_ in}),fresh=BiologyToolSession(service:reopened,authorizedProjectIDs:[id],owner:owner)
        let again=try await fresh.invoke(name:"biology.import",arguments:args,requestID:"import");XCTAssertEqual(imported,again)
        let p=try await reopened.project(id);XCTAssertEqual(p.assets.count,1)
        let assetID=p.assets[0].id
        let edit=JSONValue.object(["projectID":.string(id.uuidString),"assetID":.string(assetID.uuidString),"expectedRevision":.number(1),"record":.number(0),"start":.number(0),"end":.number(1),"replacement":.string("T")])
        _=try await fresh.invoke(name:"biology.edit",arguments:edit,requestID:"edit");_=try await fresh.invoke(name:"biology.edit",arguments:edit,requestID:"edit")
        let changed=try await reopened.project(id);XCTAssertEqual(changed.assets[0].revision,2)
        let restore=JSONValue.object(["projectID":.string(id.uuidString),"revision":.number(Double(p.revision)),"expectedRevision":.number(Double(changed.revision))])
        _=try await fresh.invoke(name:"biology.restore",arguments:restore,requestID:"restore");_=try await fresh.invoke(name:"biology.restore",arguments:restore,requestID:"restore")
        _=try await fresh.invoke(name:"biology.edit",arguments:edit,requestID:"edit") // Receipt survives history restoration.
        let restored=try await reopened.project(id);XCTAssertEqual(restored.revision,changed.revision+1);XCTAssertGreaterThan(restored.assets[0].revision,2)
        var wrong=edit.object!;wrong["replacement"] = .string("G")
        do {_=try await fresh.invoke(name:"biology.edit",arguments:.object(wrong),requestID:"edit");XCTFail("Reused call identity changed content")}catch{}
    }
    func testEveryDomainHasRealEditsSelectionsPaginationAndOriginals() async throws {
        let url=root();defer{try? FileManager.default.removeItem(at:url)}
        let service=try BiologyService(store:BiologyProjectStore(root:url),authorize:{_ in}),p=try await service.create(title:"Domains")
        let owner=BiologyExecutionOwner(taskID:UUID(),hostRunID:UUID()),tools=BiologyToolSession(service:service,authorizedProjectIDs:[p.id],owner:owner)
        let dna=try await service.importAsset(p.id,title:"DNA",format:"fasta",data:Data(">A\nATGC\n".utf8))
        func update(_ asset:BiologyAsset,_ op:String,_ parameters:JSONValue) async throws -> JSONValue {try await tools.invoke(name:"biology.update",arguments:.object(["projectID":.string(p.id.uuidString),"assetID":.string(asset.id.uuidString),"expectedRevision":.number(1),"operation":.string(op),"parameters":parameters]))}
        _=try await update(dna,"annotation.upsert",.object(["annotation":.object(["name":.string("feature"),"start":.number(0),"end":.number(3)])]))
        let pdb=try await service.importAsset(p.id,title:"Protein",format:"pdb",data:BiologySamples.data(for:.ubiquitinPDB))
        _=try await update(pdb,"structure.transform",.object(["translation":.array([10,0,0].map{.number(Double($0))})]))
        let img=try await service.importAsset(p.id,title:"Image",format:"json",data:BiologySamples.data(for:.microscopy))
        _=try await update(img,"image.calibrate",.object(["pixelSizeX":.number(0.25),"pixelSizeY":.number(0.5),"unit":.string("µm")]))
        let matrix=try await service.importAsset(p.id,title:"Matrix",format:"csv",data:BiologySamples.data(for:.expressionCounts))
        guard case .expressionMatrix(let counts)=matrix.payload else {return XCTFail("Matrix missing")}
        _=try await update(matrix,"matrix.filter",.object(["genes":.array([.string(counts.geneIDs[0])]),"cells":.array([.string(counts.cellIDs[0])])]))
        let net=try await service.importAsset(p.id,title:"Network",format:"json",data:BiologySamples.data(for:.reactionNetwork))
        guard case .biochemicalNetwork(var network)=net.payload else {return XCTFail("Network missing")};network.reactions[0].rateConstant=0.7
        _=try await update(net,"network.replace",.object(["network":try BiologyCoding.json(network)]))
        _=try await tools.invoke(name:"biology.select",arguments:.object(["projectID":.string(p.id.uuidString),"assetID":.string(dna.id.uuidString),"expectedRevision":.number(2),"selection":.object(["start":.number(1),"end":.number(3)])]))
        let read=try await tools.invoke(name:"biology.read",arguments:.object(["projectID":.string(p.id.uuidString),"assetID":.string(dna.id.uuidString),"view":.string("sequence"),"offset":.number(1),"limit":.number(2)]));XCTAssertEqual(read["sequence"]?.string,"TG")
        let reopened=try await BiologyProjectStore(root:url).load(p.id);XCTAssertEqual(reopened.activeAssetID,dna.id);XCTAssertEqual(reopened.assets.count,6)
        guard case .proteinStructure(let moved)=reopened.assets.first(where:{$0.id==pdb.id})?.payload,case .proteinStructure(let original)=pdb.payload else {return XCTFail("Protein missing")}
        XCTAssertEqual(moved.atoms[0].x,original.atoms[0].x+10,accuracy:1e-10)
        XCTAssertEqual(try BiologyExport.asset(reopened.assets.first(where:{$0.id==pdb.id})!,format:"original"),pdb.originalData)
        do {_=try await tools.invoke(name:"biology.select",arguments:.object(["projectID":.string(p.id.uuidString),"assetID":.string(dna.id.uuidString),"expectedRevision":.number(2),"selection":.object(["genes":.array([.string("wrong")])])]));XCTFail("Foreign domain selection accepted")}catch{}
    }
    func testTrashReadOnlySchemasFilesAndProviderLoop() async throws {
        let url=root();defer{try? FileManager.default.removeItem(at:url)}
        let files=try BiologyWorkspaceFiles(root:url.appendingPathComponent("files"),environmentID:"env",authorize:{_,_ in})
        let service=try BiologyService(store:BiologyProjectStore(root:url.appendingPathComponent("projects")),fileAccess:files,authorize:{_ in})
        let p=try await service.create(title:"Loop"),owner=BiologyExecutionOwner(taskID:UUID(),hostRunID:UUID()),tools=BiologyToolSession(service:service,authorizedProjectIDs:[p.id],owner:owner)
        let answer=try await BiologyAssistant(session:tools,provider:TestModel(p.id)).respond(to:"Save notes")
        XCTAssertEqual(answer,"Notes saved.")
        let saved=try await service.project(p.id);XCTAssertEqual(saved.notes,"Saved through the model tool loop")
        let receipt=try await service.exportFile(p.id,assetID:nil,format:"json",owner:owner)
        let bytes=try await service.readFile(p.id,fileID:receipt.fileID,offset:0,length:Int(receipt.byteCount),owner:owner)
        XCTAssertEqual(BiologyProjectStore.digest(bytes),receipt.sha256)
        do {_=try await service.readFile(UUID(),fileID:receipt.fileID,offset:0,length:1,owner:owner);XCTFail("Foreign file accepted")}catch{}
        let readonly=BiologyToolSession(service:service,authorizedProjectIDs:[p.id],owner:owner,canCreate:true,readOnly:true)
        let descriptors=await readonly.descriptors();XCTAssertTrue(descriptors.allSatisfy(\.isReadOnly))
        do {_=try await readonly.invoke(name:"biology.deleteProject",arguments:.object(["projectID":.string(p.id.uuidString),"expectedRevision":.number(Double(saved.revision))]));XCTFail("Read-only mutation accepted")}catch{}
        do {_=try await tools.invoke(name:"biology.read",arguments:.object(["projectID":.string(p.id.uuidString),"assetID":.string("not-a-UUID")]));XCTFail("Malformed ID fell back to project export")}catch{}
        let delete=JSONValue.object(["projectID":.string(p.id.uuidString),"expectedRevision":.number(Double(saved.revision))])
        _=try await tools.invoke(name:"biology.deleteProject",arguments:delete,requestID:"delete");_=try await tools.invoke(name:"biology.deleteProject",arguments:delete,requestID:"delete")
        let deleted=try await tools.invoke(name:"biology.deleted",arguments:.object([:]));XCTAssertEqual(deleted.array?.count,1)
        let trash=try XCTUnwrap(deleted.array?.first?["id"]?.string)
        _=try await tools.invoke(name:"biology.restoreDeleted",arguments:.object(["projectID":.string(p.id.uuidString),"trashID":.string(trash)]),requestID:"restore")
        let restored=try await service.project(p.id);XCTAssertEqual(restored.notes,saved.notes)
        let contract=try await readonly.invoke(name:"biology.describe",arguments:.object([:]));XCTAssertEqual(contract["edits"]?.array?.count,12)
    }
}
