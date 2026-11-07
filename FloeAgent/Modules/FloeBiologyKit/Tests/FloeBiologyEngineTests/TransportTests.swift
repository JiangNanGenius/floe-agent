import XCTest
import FloeBiologyCore
import FloeBiologyEngine
import FloeBiologyWorkerResources

final class BiologyTransportTests:XCTestCase,@unchecked Sendable {
    private func asset()->BiologyAsset {BiologyAsset(title:"DNA",payload:.sequence([.init(name:"DNA",sequence:"ATGGCT")] ),originalData:Data(">DNA\nATGGCT\n".utf8),originalFormat:"fasta")}
    private func receipt(_ request:BiologyTransportRequest,foreign:Bool=false,stopped:Bool=true,alterAttempt:Bool=false) throws -> BiologyTransportReceipt {
        var identity=try BiologyCoding.json(request.identity)
        if alterAttempt,var fields=identity.object {fields["attemptID"] = .string(UUID().uuidString.lowercased());identity = .object(fields)}
        var analysis=BiologyAnalysisResult(summary:"Real receipt validation");analysis.metrics=["length":6]
        let response=JSONValue.object(["protocol":.string("floe.biology.worker"),"version":.number(1),"identity":identity,"requestDigest":.string(request.requestDigest),"complete":.bool(true),"success":.bool(true),"result":try BiologyCoding.json(analysis)])
        return BiologyTransportReceipt(jobID:UUID(),projectID:foreign ? UUID():UUID(uuidString:request.identity.projectID)!,runID:UUID(uuidString:request.identity.runID)!,owner:.init(taskID:UUID(uuidString:request.identity.taskID)!,hostRunID:UUID(uuidString:request.identity.hostRunID)!),environmentID:request.identity.environmentID,requestDigest:request.requestDigest,workerStopped:stopped,exitCode:0,response:try BiologyCoding.encode(response))
    }
    func testTrustedReceiptRejectsForeignAttemptAndUnstoppedWorkers() async throws {
        let owner=BiologyExecutionOwner(taskID:UUID(),hostRunID:UUID())
        for mode in 0..<4 {
            let backend=try ConfiguredBiologyBackend(environmentID:"project.linux",engineVersion:"test",methods:["seq.stats"],execute:{[self] request in try receipt(request,foreign:mode==1,stopped:mode != 2,alterAttempt:mode==3)},stop:{_ in true})
            do {
                let result=try await backend.evaluate(projectID:UUID(),asset:asset(),method:"seq.stats",options:.object([:]),runID:UUID(),owner:owner)
                XCTAssertEqual(mode,0,"Accepted foreign/stale/unstopped result");XCTAssertEqual(result.metrics["length"],6)
            } catch {if mode==0 {throw error}}
        }
        let noStop=try ConfiguredBiologyBackend(environmentID:"project.linux",engineVersion:"test",methods:["seq.stats"],execute:{[self] in try receipt($0)},stop:{_ in false})
        do {try await noStop.cancel(runID:UUID());XCTFail("Unconfirmed cancellation accepted")} catch {}
        do {_=try await noStop.evaluate(projectID:UUID(),asset:asset(),method:"seq.stats",options:.object([:]),runID:UUID(),owner:nil);XCTFail("Host owner missing")} catch {}
    }
    func testOnlyUsableOpaqueFormatMethodsAreDiscovered() async throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("BiologyCaps-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:url)}
        let backend=try ConfiguredBiologyBackend(environmentID:"project.linux",engineVersion:"qualified",methods:["omics.qc","omics.import","seq.stats","net.sbml.import","net.simulate","micro.import"],execute:{[self] in try receipt($0)},stop:{_ in true})
        let service=try BiologyService(store:BiologyProjectStore(root:url),backends:[NativeBiologyBackend(),backend],authorize:{_ in})
        let h5ad=BiologyAsset(title:"counts",payload:.externalDataset("h5ad"),originalData:Data([0]),originalFormat:"h5ad")
        let caps=await service.capabilities(for:h5ad)
        XCTAssertEqual(caps["native.local"],[]);XCTAssertEqual(caps["project.linux"],["omics.import","omics.qc"])
        let sbml=BiologyAsset(title:"network",payload:.externalDataset("sbml"),originalData:Data([0]),originalFormat:"sbml")
        let network=await service.capabilities(for:sbml);XCTAssertEqual(network["project.linux"],["net.sbml.import"])
    }
    func testResourceIntegrityAndActualPythonReplyToSwiftEnvelope() async throws {
        let resources=try BiologyWorkerResources.verifiedFiles()
        XCTAssertTrue(resources.keys.contains("biology_worker.py"));XCTAssertTrue(resources.keys.contains("requirements.lock"))
        #if os(macOS)
        guard let python=ProcessInfo.processInfo.environment["FLOE_BIOLOGY_PYTHON"],python.hasPrefix("/") else {throw XCTSkip("Set FLOE_BIOLOGY_PYTHON to the explicitly qualified test interpreter. Production uses the resolved Linux transport.")}
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("BiologyWorker-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:folder)}
        for (name,data) in resources {try data.write(to:folder.appendingPathComponent(name))}
        let backend=try ConfiguredBiologyBackend(environmentID:"qualification.python",engineVersion:"qualified pinned libraries",methods:["seq.translate"],execute:{request in
            // Test harness only: shipping code contains no Process/interpreter.
            let process=Process(),input=Pipe(),output=Pipe(),errors=Pipe()
            process.executableURL=URL(fileURLWithPath:python)
            process.arguments=["-B",folder.appendingPathComponent("biology_worker.py").path]
            process.standardInput=input;process.standardOutput=output;process.standardError=errors
            try process.run();input.fileHandleForWriting.write(request.envelope);try input.fileHandleForWriting.close()
            let response=output.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
            guard process.terminationStatus==0 else {throw BiologyError.invalid(String(decoding:errors.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self))}
            let i=request.identity
            return .init(jobID:UUID(),projectID:UUID(uuidString:i.projectID)!,runID:UUID(uuidString:i.runID)!,owner:.init(taskID:UUID(uuidString:i.taskID)!,hostRunID:UUID(uuidString:i.hostRunID)!),environmentID:i.environmentID,requestDigest:request.requestDigest,workerStopped:!process.isRunning,exitCode:Int(process.terminationStatus),response:response)
        },stop:{_ in true})
        let result=try await backend.evaluate(projectID:UUID(),asset:asset(),method:"seq.translate",options:.object([:]),runID:UUID(),owner:.init(taskID:UUID(),hostRunID:UUID()))
        XCTAssertEqual(result.text,"MA");XCTAssertTrue(result.details["engine"]?.contains("Biopython")==true)
        #endif
    }
}
