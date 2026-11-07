import XCTest
import FloeCore
import FloeTools
import FloeModels
import FloeLaTeXCore
import FloeLaTeXEngine
@testable import FloeLaTeXHostAdapter

@MainActor private final class FixtureHost:LaTeXHostAccess {
    let store:LaTeXProjectStore
    let builds:LaTeXBuildService
    var acquired=0
    var prepareFailure:LaTeXEngineFailure?
    init(root:URL) throws {
        store=try .create(root:root.appendingPathComponent("Project"),owner:.init(kind:.task,id:UUID()),title:"Fixture",files:["main.tex":Data("Original".utf8)])
        builds=try .init(cacheRoot:root.appendingPathComponent("Cache"))
    }
    func acquire(projectID:UUID,context:ToolContext,editing:Bool) async throws->LaTeXHostProject {
        guard try await store.manifest().id==projectID else {throw LaTeXError.invalidProject}
        acquired+=1;return .init(store:store)
    }
    func create(title:String,templateID:String,context:ToolContext) async throws->LaTeXHostProject {throw LaTeXError.unavailable("Not a creation fixture")}
    func prepareEngine(project:LaTeXHostProject,context:ToolContext,binding:RuntimeAuthorityBinding?) async throws -> (any LaTeXEngineRunning)? {
        if let prepareFailure {throw prepareFailure};return nil
    }
    func publish(file:URL,project:LaTeXHostProject,context:ToolContext) async throws->ToolExecutionOutput {throw LaTeXError.unavailable("Not a publication fixture")}
}
@MainActor final class AuthorityTests:XCTestCase {
    func testUnconfirmedPreparationIsReportedAsUnknownRatherThanSuccess() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let host=try FixtureHost(root:root),registry=ToolRunnerRegistry()
        host.prepareFailure = .init("No final processor receipt",workerStopped:false)
        LaTeXHostTools.register(host:host,registry:registry)
        let runner=try XCTUnwrap(registry.runner(named:"latex.typeset")),id=try await host.store.manifest().id
        let data=try JSONSerialization.data(withJSONObject:["projectID":id.uuidString,"action":"prepare"])
        var context=ToolContext(runID:UUID(),toolCallID:"unknown.prepare",toolIdempotencyKey:"unknown.prepare",approvalGrantID:UUID(),
            allowedToolNames:LaTeXHostTools.names.union(["exec.shell"]),workspaceRootURL:root,cancellation:CancellationToken(),conversationID:UUID(),frozenEffectiveCatalogNames:LaTeXHostTools.names.union(["exec.shell"]))
        context.executionToolName="latex.typeset"
        var call=try ToolCall(id:context.toolCallID!,toolName:"latex.typeset",argumentsJSON:data,scope:.local);call.idempotencyKey=context.toolIdempotencyKey
        let target=RuntimeAuthorityDigest.canonicalTarget(for:call,descriptor:runner.descriptor,workspaceRootURL:root)
        let binding=context.runtimeAuthorityBinding(toolName:"latex.typeset",operation:"apply",canonicalTarget:target,baseRevision:nil,payloadDigest:RuntimeAuthorityDigest.payloadDigest(data))
        context.runtimeAuthority=await RuntimeAuthorityStore.shared.issue(.init(runID:context.runID,taskID:context.conversationID,
            environmentBinding:binding.environmentBinding,canonicalTarget:target,toolName:"latex.typeset",operation:"apply",operationID:call.id,
            idempotencyKey:call.idempotencyKey,baseRevision:nil,payloadDigest:binding.payloadDigest,approvalGrantID:context.approvalGrantID!))
        let result=try await runner.run(data,context)
        XCTAssertTrue(result.outcomeUnknown);XCTAssertNil(result.exitStatus)
        XCTAssertTrue(result.summary.contains("unknown"))
        let manifest=try await host.store.manifest();XCTAssertEqual(manifest.revision,0)
    }
    func testGrantIdentifierAloneCannotMutateAnOriginal() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let host=try FixtureHost(root:root),registry=ToolRunnerRegistry();LaTeXHostTools.register(host:host,registry:registry)
        let runner=try XCTUnwrap(registry.runner(named:"latex.edit")),id=try await host.store.manifest().id
        let raw=Data("{\"projectID\":\"\(id)\",\"expectedRevision\":0,\"mutationID\":\"\(UUID())\",\"operations\":[{\"operation\":\"write\",\"path\":\"main.tex\",\"text\":\"Unapproved\"}]}".utf8)
        var context=ToolContext(runID:UUID(),toolCallID:"missing.token",approvalGrantID:UUID(),allowedToolNames:LaTeXHostTools.names,cancellation:CancellationToken(),conversationID:UUID(),frozenEffectiveCatalogNames:LaTeXHostTools.names)
        context.executionToolName="latex.edit"
        do {_=try await runner.run(raw,context);XCTFail("A grant UUID is not runtime authority")}catch {}
        XCTAssertEqual(host.acquired,0)
        let saved=try await host.store.text("main.tex");XCTAssertEqual(saved,"Original")
    }
    func testExactRawApprovalAcceptsLowercaseIDsAndRejectsPayloadTampering() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let host=try FixtureHost(root:root),registry=ToolRunnerRegistry()
        LaTeXHostTools.register(host:host,registry:registry)
        let runner=try XCTUnwrap(registry.runner(named:"latex.edit")),project=try await host.store.manifest()
        let raw=Data("{\"projectID\":\"\(project.id.uuidString.lowercased())\",\"expectedRevision\":0,\"mutationID\":\"\(UUID().uuidString.lowercased())\",\"operations\":[{\"operation\":\"write\",\"path\":\"main.tex\",\"text\":\"Approved\"}]}".utf8)
        var context=ToolContext(runID:UUID(),toolCallID:"exact.call",toolIdempotencyKey:"exact.key",approvalGrantID:UUID(),allowedToolNames:LaTeXHostTools.names,workspaceRootURL:root,cancellation:CancellationToken(),conversationID:UUID(),frozenEffectiveCatalogNames:LaTeXHostTools.names)
        context.executionToolName="latex.edit"
        var call=try ToolCall(id:"exact.call",toolName:"latex.edit",argumentsJSON:raw,scope:.local);call.idempotencyKey="exact.key"
        let binding=context.runtimeAuthorityBinding(toolName:"latex.edit",operation:"apply",canonicalTarget:RuntimeAuthorityDigest.canonicalTarget(for:call,descriptor:runner.descriptor,workspaceRootURL:root),baseRevision:RuntimeAuthorityDigest.baseRevision(in:raw),payloadDigest:RuntimeAuthorityDigest.payloadDigest(raw))
        context.runtimeAuthority=await RuntimeAuthorityStore.shared.issue(.init(runID:context.runID,taskID:context.conversationID,environmentBinding:binding.environmentBinding,canonicalTarget:binding.canonicalTarget,toolName:binding.toolName,operation:binding.operation,operationID:binding.operationID,idempotencyKey:binding.idempotencyKey,baseRevision:binding.baseRevision,payloadDigest:binding.payloadDigest,approvalGrantID:context.approvalGrantID!))
        let tampered=Data(String(decoding:raw,as:UTF8.self).replacingOccurrences(of:"Approved",with:"Tampered").utf8)
        do {_=try await runner.run(tampered,context);XCTFail("A changed payload must not inherit the approval")}catch {}
        XCTAssertEqual(host.acquired,0)
        _=try await runner.run(raw,context)
        let saved=try await host.store.text("main.tex");XCTAssertEqual(saved,"Approved")
        if let token=context.runtimeAuthority {await RuntimeAuthorityStore.shared.revoke(id:token.id)}
    }
    func testTemporaryAndFrozenCeilingRejectBeforeOpeningOriginal() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let host=try FixtureHost(root:root),registry=ToolRunnerRegistry();LaTeXHostTools.register(host:host,registry:registry)
        let runner=try XCTUnwrap(registry.runner(named:"latex.inspect")),id=try await host.store.manifest().id
        let arguments=Data("{\"projectID\":\"\(id)\",\"action\":\"project\"}".utf8)
        var context=ToolContext(runID:UUID(),allowedToolNames:LaTeXHostTools.names,cancellation:CancellationToken(),conversationID:UUID(),temporaryReadOnly:true,frozenEffectiveCatalogNames:LaTeXHostTools.names);context.executionToolName="latex.inspect"
        do {_=try await runner.run(arguments,context);XCTFail("Temporary chat cannot inspect private originals")}catch {}
        context.temporaryReadOnly=false;context.frozenEffectiveCatalogNames=[]
        do {_=try await runner.run(arguments,context);XCTFail("A frozen tool ceiling must apply")}catch {}
        XCTAssertEqual(host.acquired,0)
    }
    func testOnlyProcessorExitAtStartOfCanonicalReceiptConfirmsStop() {
        XCTAssertEqual(LaTeXShellTransport.confirmedExit("exit=0 durationMs=2\n--- stdout ---\nreceipt"),0)
        XCTAssertEqual(LaTeXShellTransport.confirmedExit("exit=130 status=cancelled"),130)
        XCTAssertNil(LaTeXShellTransport.confirmedExit("status=outcomeUnknown\nexit=0"))
        XCTAssertNil(LaTeXShellTransport.confirmedExit("Unsafe resource state\nexit=0"))
    }
}
