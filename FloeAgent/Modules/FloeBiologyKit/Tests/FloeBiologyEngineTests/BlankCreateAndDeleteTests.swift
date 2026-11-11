import XCTest
import FloeBiologyCore
import FloeBiologyEngine

private actor BlankWaitingBackend:BiologyBackend {
    nonisolated let environmentID="qualified.blank.waiting"
    nonisolated let engineVersion="test-owned-worker"
    nonisolated let methods:Set<String>=["sequence.stats"]
    var entered=false
    var stopped=false
    func evaluate(projectID:UUID,asset:BiologyAsset,method:String,options:JSONValue,runID:UUID,owner:BiologyExecutionOwner?) async throws -> BiologyAnalysisResult {
        entered=true
        do {try await Task.sleep(for:.seconds(30));return .init(summary:"unexpected completion")}
        catch {stopped=true;throw error}
    }
    func cancel(runID:UUID) async throws {}
}

final class BiologyBlankCreateAndDeleteTests:XCTestCase,@unchecked Sendable {
    private func root()->URL {FileManager.default.temporaryDirectory.appendingPathComponent("BiologyBlank-"+UUID().uuidString)}

    func testBlankSequenceAnnotationAndNetworkCreatePersistAndReopen() async throws {
        let url=root();defer{try? FileManager.default.removeItem(at:url)}
        let service=try BiologyService(store:BiologyProjectStore(root:url),authorize:{_ in})
        let p=try await service.create(title:"Blank board")
        let head=try await service.project(p.id)
        let created=try await service.update(p.id,operation:"asset.create",assetID:nil,expectedRevision:head.revision,parameters:.object([
            "title":.string("Construct A"),"kind":.string("sequence"),"recordName":.string("insert"),
            "sequence":.string("atg gct agc act gag t"),
            "annotation":.object(["name":.string("CDS"),"start":.number(0),"end":.number(15),"strand":.number(1)])]))
        let assetID=try XCTUnwrap(created["assetID"]?.string).lowercased()
        let project=try await service.project(p.id)
        let asset=try XCTUnwrap(project.assets.first(where:{$0.id.uuidString.lowercased()==assetID}))
        XCTAssertEqual(asset.revision,1);XCTAssertEqual(asset.kind,.sequence)
        XCTAssertEqual(project.activeAssetID,asset.id)
        guard case .sequence(let records)=asset.payload else {return XCTFail("Sequence payload missing")}
        XCTAssertEqual(records.count,1);XCTAssertEqual(records[0].name,"insert")
        XCTAssertEqual(records[0].sequence,"ATGGCTAGCACTGAGT");XCTAssertEqual(records[0].alphabet,"dna")
        XCTAssertEqual(records[0].annotations.count,1);XCTAssertEqual(records[0].annotations[0].name,"CDS")
        XCTAssertEqual(asset.originalFormat,"fasta")
        XCTAssertEqual(String(decoding:asset.originalData,as:UTF8.self),">insert\nATGGCTAGCACTGAGT\n")
        // Starter network is valid with one species and no reactions.
        let network=try await service.update(p.id,operation:"asset.create",assetID:nil,expectedRevision:project.revision,parameters:.object(["title":.string("Pathway"),"kind":.string("biochemicalNetwork")]))
        let networkID=try XCTUnwrap(network["assetID"]?.string)
        let withNetwork=try await service.project(p.id)
        let networkAsset=try XCTUnwrap(withNetwork.assets.first(where:{$0.id.uuidString==networkID}))
        guard case .biochemicalNetwork(let model)=networkAsset.payload else {return XCTFail("Network payload missing")}
        XCTAssertEqual(model.species.map(\.id),["S1"]);XCTAssertTrue(model.reactions.isEmpty)
        XCTAssertEqual(networkAsset.originalFormat,"network.json")
        // Full custom network also passes the same validated path.
        let custom=try await service.update(p.id,operation:"asset.create",assetID:nil,expectedRevision:withNetwork.revision,parameters:.object([
            "title":.string("Cycle"),"kind":.string("biochemicalNetwork"),
            "network":.object(["species":.array([.object(["id":.string("A"),"initialAmount":.number(1)]),.object(["id":.string("B"),"initialAmount":.number(0)])]),
                "reactions":.array([.object(["id":.string("r1"),"reactants":.object(["A":.number(1)]),"products":.object(["B":.number(1)]),"rateConstant":.number(0.5)])]),
                "timeUnit":.string("s"),"amountUnit":.string("nmol")])]))
        let customProject=try await service.project(p.id)
        guard case .biochemicalNetwork(let customModel)=try XCTUnwrap(customProject.assets.first(where:{$0.id.uuidString==(custom["assetID"]?.string ?? "")})).payload else {return XCTFail("Custom network missing")}
        XCTAssertEqual(customModel.species.count,2);XCTAssertEqual(customModel.reactions.count,1)
        // Everything survives a fresh service on the same durable store.
        let reopened=try BiologyService(store:BiologyProjectStore(root:url),authorize:{_ in})
        let disk=try await reopened.project(p.id)
        XCTAssertEqual(disk.assets.count,3)
        XCTAssertEqual(disk.assets.first(where:{$0.id==asset.id}),asset)
        XCTAssertEqual(disk.activeAssetID,customProject.activeAssetID)
    }

    func testBlankCreateRevisionConflictAndValidation() async throws {
        let url=root();defer{try? FileManager.default.removeItem(at:url)}
        let service=try BiologyService(store:BiologyProjectStore(root:url),authorize:{_ in})
        let p=try await service.create(title:"Guarded")
        let head=try await service.project(p.id)
        do {_=try await service.update(p.id,operation:"asset.create",assetID:nil,expectedRevision:head.revision+1,parameters:.object(["title":.string("X"),"kind":.string("sequence")]));XCTFail("Stale blank create accepted")}
        catch BiologyError.conflict {}
        do {_=try await service.update(p.id,operation:"asset.create",assetID:nil,expectedRevision:head.revision,parameters:.object(["title":.string("X"),"kind":.string("microscopyImage")]));XCTFail("Unsupported kind accepted")}
        catch BiologyError.invalid {}
        do {_=try await service.update(p.id,operation:"asset.create",assetID:nil,expectedRevision:head.revision,parameters:.object(["title":.string("Blank draft"),"kind":.string("sequence")]));XCTFail("Sequence dataset created without user sequence")}
        catch BiologyError.invalid {}
        do {_=try await service.update(p.id,operation:"asset.create",assetID:nil,expectedRevision:head.revision,parameters:.object(["title":.string("Blank draft"),"kind":.string("sequence"),"sequence":.string("   ")]));XCTFail("Sequence dataset created from whitespace")}
        catch BiologyError.invalid {}
        do {_=try await service.update(p.id,operation:"asset.create",assetID:nil,expectedRevision:head.revision,parameters:.object(["title":.string("X"),"kind":.string("sequence"),"sequence":.string("ATGC"),"annotation":.object(["name":.string("bad"),"start":.number(2),"end":.number(99)])]));XCTFail("Out-of-range annotation accepted")}
        catch BiologyError.invalid {}
        do {_=try await service.update(p.id,operation:"asset.create",assetID:nil,expectedRevision:head.revision,parameters:.object(["title":.string("X"),"kind":.string("sequence"),"sequence":.string("ATG1")]));XCTFail("Invalid symbols accepted")}
        catch BiologyError.invalid {}
        let unchanged=try await service.project(p.id)
        XCTAssertTrue(unchanged.assets.isEmpty)
        XCTAssertEqual(unchanged.revision,head.revision)
    }

    func testBlankCreateReplayReturnsSameAssetWithoutDuplicates() async throws {
        let url=root();defer{try? FileManager.default.removeItem(at:url)}
        let store=try BiologyProjectStore(root:url)
        let service=try BiologyService(store:store,authorize:{_ in})
        let p=try await service.create(title:"Replay")
        let owner=BiologyExecutionOwner(taskID:UUID(),hostRunID:UUID())
        let identity=BiologyMutationIdentity(owner:owner,requestID:"blank-replay-1",argumentDigest:BiologyProjectStore.digest(Data("blank".utf8)))
        let head=try await service.project(p.id)
        let blankArguments:[String:JSONValue]=["title":.string("Stable"),"kind":.string("sequence"),"sequence":.string("ATGGCT")]
        let first=try await service.update(p.id,operation:"asset.create",assetID:nil,expectedRevision:head.revision,parameters:.object(blankArguments),identity:identity)
        let mid=try await service.project(p.id)
        let second=try await service.update(p.id,operation:"asset.create",assetID:nil,expectedRevision:mid.revision,parameters:.object(blankArguments),identity:identity)
        XCTAssertEqual(first["assetID"],second["assetID"])
        let final=try await service.project(p.id)
        XCTAssertEqual(final.assets.count,1)
        let other=BiologyMutationIdentity(owner:owner,requestID:"blank-replay-1",argumentDigest:BiologyProjectStore.digest(Data("different".utf8)))
        do {_=try await service.update(p.id,operation:"asset.create",assetID:nil,expectedRevision:final.revision,parameters:.object(["title":.string("Other"),"kind":.string("sequence"),"sequence":.string("TTAA")]),identity:other);XCTFail("Reused call identity with different arguments")}
        catch BiologyError.invalid {}
    }

    func testAssetDeleteWaitsForCalculationsAndUpdatesSelection() async throws {
        let url=root();defer{try? FileManager.default.removeItem(at:url)}
        let backend=BlankWaitingBackend()
        let service=try BiologyService(store:BiologyProjectStore(root:url),backends:[backend],authorize:{_ in})
        let p=try await service.create(title:"Deletion")
        let dna=try await service.importAsset(p.id,title:"DNA",format:"fasta",data:Data(">A\nATGGCTGACTGAGT\n".utf8))
        let protein=try await service.importAsset(p.id,title:"Protein",format:"fasta",data:Data(">B\nMKTAYIAK\n".utf8))
        _=try await service.select(p.id,assetID:dna.id,selection:.object(["record":.number(0),"start":.number(0),"end":.number(4)]),expectedAssetRevision:dna.revision)
        let run=try await service.start(p.id,assetID:dna.id,expectedAssetRevision:dna.revision,method:"sequence.stats",environmentID:backend.environmentID)
        for _ in 0..<1000 {if await backend.entered {break};try await Task.sleep(for:.milliseconds(2))}
        let entered=await backend.entered;XCTAssertTrue(entered)
        do {_=try await service.update(p.id,operation:"asset.delete",assetID:dna.id,expectedRevision:dna.revision,parameters:.object([:]));XCTFail("Deleted a dataset with a live calculation")}
        catch BiologyError.invalid {}
        try await service.cancel(p.id,runID:run.id)
        _=try await service.wait(p.id,runID:run.id)
        let beforeDelete=try await service.project(p.id)
        let removed=try await service.update(p.id,operation:"asset.delete",assetID:dna.id,expectedRevision:dna.revision,parameters:.object([:]))
        XCTAssertEqual(removed["deletedAssetID"]?.string,dna.id.uuidString)
        let after=try await service.project(p.id)
        XCTAssertFalse(after.assets.contains(where:{$0.id==dna.id}))
        XCTAssertEqual(after.activeAssetID,protein.id)
        XCTAssertNil(after.selections?[dna.id.uuidString])
        // Deletion is a durable revision: history restore brings the dataset back.
        let restored=try await service.restore(p.id,revision:beforeDelete.revision,expectedRevision:after.revision)
        XCTAssertTrue(restored.assets.contains(where:{$0.id==dna.id}))
        let reopened=try BiologyService(store:BiologyProjectStore(root:url),authorize:{_ in})
        let disk=try await reopened.project(p.id)
        XCTAssertTrue(disk.assets.contains(where:{$0.id==dna.id}))
    }

    func testBlankCreateThroughTaskToolSession() async throws {
        let url=root();defer{try? FileManager.default.removeItem(at:url)}
        let service=try BiologyService(store:BiologyProjectStore(root:url),authorize:{_ in})
        let p=try await service.create(title:"AI blank board")
        let tools=BiologyToolSession(service:service,authorizedProjectIDs:[p.id],owner:.init(taskID:UUID(),hostRunID:UUID()))
        let head=try await service.project(p.id)
        let created=try await tools.invoke(name:"biology.update",arguments:.object([
            "projectID":.string(p.id.uuidString),"operation":.string("asset.create"),"expectedRevision":.number(Double(head.revision)),
            "parameters":.object(["title":.string("AI construct"),"kind":.string("sequence"),"sequence":.string("GGATCC")])]))
        let assetID=try XCTUnwrap(created["assetID"]?.string)
        let project=try await service.project(p.id)
        let asset=try XCTUnwrap(project.assets.first(where:{$0.id.uuidString==assetID}))
        // The AI can start real work on the freshly created blank dataset.
        let started=try await tools.invoke(name:"biology.analyze",arguments:.object(["projectID":.string(p.id.uuidString),"assetID":.string(assetID),"expectedRevision":.number(1),"method":.string("sequence.stats")]))
        let runID=try XCTUnwrap(started["id"]?.string)
        let finished=try await tools.invoke(name:"biology.job",arguments:.object(["projectID":.string(p.id.uuidString),"runID":.string(runID)]))
        XCTAssertEqual(finished["status"]?.string,"succeeded")
        // Annotation add/remove round trip on the created sequence.
        let annotated=try await tools.invoke(name:"biology.update",arguments:.object([
            "projectID":.string(p.id.uuidString),"assetID":.string(assetID),"operation":.string("annotation.upsert"),"expectedRevision":.number(1),
            "parameters":.object(["record":.number(0),"annotation":.object(["name":.string("site"),"start":.number(1),"end":.number(5)])])]))
        XCTAssertEqual(annotated["revision"]?.number,2)
        let annotatedProject=try await service.project(p.id)
        let annotatedAsset=try XCTUnwrap(annotatedProject.assets.first(where:{$0.id==asset.id}))
        let annotationID=try XCTUnwrap(payloadAnnotationID(annotatedAsset))
        let removed=try await tools.invoke(name:"biology.update",arguments:.object([
            "projectID":.string(p.id.uuidString),"assetID":.string(assetID),"operation":.string("annotation.remove"),"expectedRevision":.number(2),
            "parameters":.object(["record":.number(0),"annotationID":.string(annotationID)])]))
        XCTAssertEqual(removed["revision"]?.number,3)
        let final=try await service.project(p.id)
        guard case .sequence(let records)=final.assets.first(where:{$0.id==asset.id})?.payload else {return XCTFail("Sequence missing")}
        XCTAssertTrue(records[0].annotations.isEmpty)
    }
    private func payloadAnnotationID(_ asset:BiologyAsset)->String? {
        if case .sequence(let records)=asset.payload {return records.first?.annotations.first?.id.uuidString}
        return nil
    }
}
