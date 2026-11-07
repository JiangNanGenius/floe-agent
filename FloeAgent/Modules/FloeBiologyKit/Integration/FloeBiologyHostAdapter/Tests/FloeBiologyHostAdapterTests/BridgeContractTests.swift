import XCTest
import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloePersistence
import FloeExecution
import FloeEnvironments
import FloeBiologyCore
import FloeBiologyEngine
#if canImport(FloeBiologyHostAdapter)
@testable import FloeBiologyHostAdapter
#endif

/// This fixture tests the real registry, durable jobs, environment ownership,
/// cancellation and wire protocol. It does not claim Python/Linux execution.
private actor ScientificShellFixture {
    var envelope:JSONValue?
    var response=Data()
    var block=false
    var entered=false
    func configureBlock(){block=true;entered=false}
    func run(_ data:Data,_ context:ToolContext) async throws -> ToolExecutionOutput {
        let args=try JSONDecoder().decode(LocalShellTool.Arguments.self,from:data),script=args.script ?? ""
        func match(_ pattern:String)->String? {
            guard let expression=try? NSRegularExpression(pattern:pattern),let m=expression.firstMatch(in:script,range:NSRange(script.startIndex...,in:script)),let range=Range(m.range(at:1),in:script) else{return nil};return String(script[range])
        }
        func receipt(_ value:JSONValue) throws -> ToolExecutionOutput {let text="exit=0\n--- stdout ---\nBIOLOGY_RECEIPT "+(try BiologyCoding.encode(value)).base64EncodedString();return .init(digesting:text,exitStatus:0)}
        if script.contains("(root/'inputs').mkdir()"),script.contains("json.loads(base64") {
            let encoded=try XCTUnwrap(match("json.loads\\(base64.b64decode\\('([A-Za-z0-9+/=]+)'\\)\\)")),bytes=try XCTUnwrap(Data(base64Encoded:encoded)),files=try JSONDecoder().decode([String:String].self,from:bytes)
            let request=try XCTUnwrap(files["request.json"].flatMap{Data(base64Encoded:$0)})
            envelope=try JSONDecoder().decode(JSONValue.self,from:request)
            return try receipt(.object(["staged":.bool(true)]))
        }
        if script.contains("worker.log") {
            entered=true
            if block {while !context.cancellation.isCancelled{try await Task.sleep(for:.milliseconds(10))};throw CancellationError()}
            let value=try XCTUnwrap(envelope),inner=try JSONDecoder().decode(JSONValue.self,from:Data(try XCTUnwrap(value["requestJSON"]?.string).utf8)),snapshot=try XCTUnwrap(inner["snapshotJSON"]?.string),asset=try JSONDecoder().decode(BiologyAsset.self,from:Data(snapshot.utf8))
            let result=try BiologyNativeAnalysis.run(asset:asset,method:"sequence.translate",options:.object([:]))
            let reply=JSONValue.object(["protocol":.string("floe.biology.worker"),"version":.number(1),"identity":value["identity"]!,"requestDigest":value["requestDigest"]!,"complete":.bool(true),"success":.bool(true),"result":try BiologyCoding.json(result)])
            response=try BiologyCoding.encode(reply)
            return try receipt(.object(["bytes":.number(Double(response.count)),"sha256":.string(BiologyProjectStore.digest(response))]))
        }
        if script.contains("BIOLOGY_BYTES ") {
            let offset=Int(try XCTUnwrap(match("f.seek\\(([0-9]+)\\)")))!,length=Int(try XCTUnwrap(match("f.read\\(([0-9]+)\\)")))!
            return .init(digesting:"exit=0\nBIOLOGY_BYTES "+response.subdata(in:offset..<offset+length).base64EncodedString(),exitStatus:0)
        }
        throw BiologyError.invalid("Unexpected compiled scientific phase")
    }
}
final class BiologyBridgeContractTests:XCTestCase,@unchecked Sendable {
    func root()->URL {FileManager.default.temporaryDirectory.appendingPathComponent("BiologyBridge-"+UUID().uuidString)}
    func testActualFloeRegistryCallsAndCapabilityCeilings() async throws {
        let url=root();defer{try? FileManager.default.removeItem(at:url)}
        let service=try BiologyService(store:BiologyProjectStore(root:url),authorize:{_ in}),project=try await service.create(title:"Registry"),foreign=try await service.create(title:"Foreign")
        let asset=try await service.importAsset(project.id,title:"DNA",format:"fasta",data:Data(">DNA\nATGGCT\n".utf8)),registry=ToolRunnerRegistry(),contexts=BiologyExecutionContexts()
        let bridge=BiologyToolBridge(service:service,contexts:contexts,grant:{_ in .init(projects:[project.id])},registerCreatedProject:{_,_ in})
        try await bridge.register(in:registry)
        let taskID=UUID(),runID=UUID(),token=CancellationToken()
        func context(_ call:String)->ToolContext {.init(runID:runID,toolCallID:call,cancellation:token,conversationID:taskID)}
        func invoke(_ name:String,_ args:[String:JSONValue],call:String) async throws -> JSONValue {
            let runner=try XCTUnwrap(registry.runner(named:name)),output=try await runner.execute(argumentsJSON:BiologyCoding.encode(JSONValue.object(args)),context:context(call))
            return try JSONDecoder().decode(JSONValue.self,from:Data((output.capturedOutput ?? output.summary).utf8))
        }
        let started=try await invoke("biology.analyze",["projectID":.string(project.id.uuidString),"assetID":.string(asset.id.uuidString),"expectedRevision":.number(1),"method":.string("sequence.translate")],call:"analyze")
        let run=try XCTUnwrap(started["id"]?.string)
        let result=try await invoke("biology.job",["projectID":.string(project.id.uuidString),"runID":.string(run)],call:"wait")
        XCTAssertEqual(result["status"]?.string,"succeeded");XCTAssertEqual(result["result"]?["text"]?.string,"MA")
        do {_=try await invoke("biology.read",["projectID":.string(foreign.id.uuidString)],call:"foreign");XCTFail("Foreign scope accepted")}catch{}
        var temporary=context("temporary");temporary.temporaryReadOnly=true
        let descriptors=try await bridge.descriptors(for:temporary);XCTAssertTrue(descriptors.isEmpty)
        do {_=try await registry.runner(named:"biology.read")!.execute(argumentsJSON:BiologyCoding.encode(JSONValue.object(["projectID":.string(project.id.uuidString)])),context:temporary);XCTFail("Temporary chat read a private dataset")}catch{}
        var restricted=context("ceiling");restricted.allowedToolNames=["web.search"]
        let filtered=try await bridge.descriptors(for:restricted);XCTAssertTrue(filtered.isEmpty)
        let current=try await service.project(project.id);XCTAssertEqual(current.runs.count,1)
    }
    func testRealBackgroundJobsRoundtripAndCancellation() async throws {
        let url=root();try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:url)}
        let db=try DatabaseManager.inMemory();try await db.migrate()
        let taskID=UUID(),hostRunID=UUID(),now=ISO8601DateFormatter().string(from:Date())
        try await db.writer{db in
            try db.execute(sql:"INSERT INTO conversations(id,title,created_at,updated_at) VALUES (?, 'Biology fixture', ?, ?)",arguments:[taskID.uuidString,now,now])
            try db.execute(sql:"INSERT INTO runs(id,conversation_id,state,goal,started_at) VALUES (?, ?, 'running', 'Biology fixture', ?)",arguments:[hostRunID.uuidString,taskID.uuidString,now])
        }
        let environments=EnvironmentRegistry(roots:.init(rootURL:url.appendingPathComponent("env")),baseRevision:"contract-fixture")
        let record=try await environments.ensureProjectContainer(workspaceID:UUID().uuidString,workspaceRootPath:url.path,executionBackend:.linuxVM)
        let environment=ToolEnvironment(id:record.id,writableLayerURL:url,layerURLs:[url],variables:[:]),routing=ToolEnvironmentRouting()
        routing.configure{context in var c=context;c.environment=environment;return .init(context:c)}
        let fixture=ScientificShellFixture(),registry=ToolRunnerRegistry()
        registry.register(AnyAgentTool(descriptor:.init(name:"exec.shell",parametersJSON:LocalShellTool.parametersJSON,riskLabels:[.executesLocalCode],isSideEffecting:true),run:{data,context in try await fixture.run(data,context)},routing:routing))
        let jobs=BackgroundJobService(store:BackgroundJobStore(database:db),registry:registry),contexts=BiologyExecutionContexts(),transport=BiologyScientificJobs(jobs:jobs,registry:registry,environments:environments,contexts:contexts)
        let backend=try await transport.backend(qualified:.init(environmentID:record.id,methods:["seq.translate"],engines:.object(["engine":.string("contract fixture")]),unavailable:.object([:]),resourceDigest:"fixture"))
        let service=try BiologyService(store:BiologyProjectStore(root:url.appendingPathComponent("projects")),backends:[backend],authorize:{_ in}),project=try await service.create(title:"Jobs"),asset=try await service.importAsset(project.id,title:"DNA",format:"fasta",data:Data(">A\nATGGCT\n".utf8))
        let context=ToolContext(runID:hostRunID,cancellation:CancellationToken(),environmentID:record.id,conversationID:taskID,environment:environment)
        var launch=context;launch.workspaceRootURL=url
        let owner=try await contexts.authorizeNative(launch)
        let started=try await service.start(project.id,assetID:asset.id,expectedAssetRevision:1,method:"seq.translate",environmentID:record.id,owner:owner)
        let completed=try await service.wait(project.id,runID:started.id);XCTAssertEqual(completed.status,.succeeded,completed.error ?? "");XCTAssertEqual(completed.result?.text,"MA")
        let records=try await BackgroundJobStore(database:db).jobs(conversationID:taskID);XCTAssertEqual(records.count,2);XCTAssertTrue(records.allSatisfy{$0.runID==hostRunID && $0.environmentID==record.id && $0.state == .completed})
        await fixture.configureBlock();_=try await contexts.authorizeNative(launch)
        let second=try await service.start(project.id,assetID:asset.id,expectedAssetRevision:1,method:"seq.translate",environmentID:record.id,owner:owner)
        for _ in 0..<200 {if await fixture.entered{break};try await Task.sleep(for:.milliseconds(10))}
        let entered=await fixture.entered;XCTAssertTrue(entered)
        try await service.cancel(project.id,runID:second.id)
        let stopped=try await service.wait(project.id,runID:second.id);XCTAssertEqual(stopped.status,.cancelled);XCTAssertNil(stopped.result)
        let final=try await BackgroundJobStore(database:db).jobs(conversationID:taskID);XCTAssertFalse(final.contains{$0.state == .running || $0.state == .queued})
    }
}
