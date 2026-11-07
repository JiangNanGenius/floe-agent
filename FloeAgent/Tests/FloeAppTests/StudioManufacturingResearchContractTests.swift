// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloeTools
import FloePersistence
import FloeSecurity
import FloeCAD
import FloeManufacturingCore
@testable import FloeApp

@Suite("Registered CAD research program workflows", .serialized)
@MainActor struct StudioManufacturingResearchContractTests {
    private func call(_ name:String,_ arguments:[String:Any],_ context:ToolContext) async throws -> [String:Any] {
        let runner = try #require(ToolRunnerRegistry.shared.runner(named:name))
        let output = try await runner.execute(argumentsJSON:JSONSerialization.data(withJSONObject:arguments),context:context)
        let bytes = Data((output.capturedOutput ?? output.summary).utf8)
        #expect(output.fullOutputSHA256 == StudioToolOutput.hash(bytes))
        return try #require(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
    }
    private func research(_ id:UUID,_ action:String,_ request:[String:Any],revision:String? = nil,context:ToolContext) async throws -> [String:Any] {
        let json = String(decoding:try JSONSerialization.data(withJSONObject:request),as:UTF8.self)
        var arguments:[String:Any] = ["projectID":id.uuidString,"action":action,"researchJSON":json]
        arguments["expectedRevision"] = revision
        return try await call("studio.machining",arguments,context)
    }
    private func withCAD(_ body:@MainActor (UUID,URL,FloeCADDocument,ToolContext,ToolContext) async throws -> Void) async throws {
        let environment = FloeAgentApp.liveEnvironment;try await environment.ensureDurableAutomationReady()
        var ids:[UUID] = [],contexts:[ToolContext] = [],ownedDirectory:URL?,document:FloeCADDocument?
        func removeFixture() { document?.close();if let ownedDirectory { try? FileManager.default.removeItem(at:ownedDirectory) } }
        do {
            for _ in 0..<2 {
                let id = UUID(),runID = UUID(),now = Date();ids.append(id)
                try await environment.conversationStore.saveConversation(.init(id:id,title:"Research native contract",createdAt:now,updatedAt:now))
                _ = try await SQLiteWorkspaceStore(database:environment.database).ensureWorkspace(conversationID:id,title:"Research native contract")
                try await environment.conversationStore.setArchived(id:id,archived:true)
                try await environment.runStore.saveRun(.init(id:runID,conversationID:id,state:"executing",goal:"Research native contract",startedAt:now))
                var context = ToolContext(runID:runID,toolCallID:"native-research-contract",allowedToolNames:StudioCoordinator.names,
                    cancellation:CancellationToken(),conversationID:id)
                context.frozenEffectiveCatalogNames = StudioCoordinator.names;context.approvalGrantID = UUID();contexts.append(context)
            }
            let result = try await call("studio.create",["kind":"cad3D","title":"Research fixture \(UUID())"],contexts[0])
            let record = try #require(result["record"] as? [String:Any]),raw = try #require(record["id"] as? String),id = try #require(UUID(uuidString:raw))
            let location = try await PersonalContentService.shared.library().resolve(id);ownedDirectory = location.url
            let value = try await PersonalCADSessions.open(id:id,directory:location.url);document = value
            try #require((await value.save()).succeeded)
            try await body(id,location.url,value,contexts[0],contexts[1])
        } catch { removeFixture();for id in ids { try? await environment.conversationStore.deleteConversation(id:id) };throw error }
        removeFixture();for id in ids { try await environment.conversationStore.deleteConversation(id:id) }
    }
    @Test func registeredConfigureCalculateAndColdReadUseOneRealSavedAnalysisWithoutCADMeshSubstitution() async throws {
        try await withCAD { id,directory,document,context,_ in
            let family = "engineeringAnalysis"
            let empty = try await research(id,"research.inspect",["family":family],context:context)
            #expect((empty["active"] as? [String:Any])?["state"] as? String == "none")
            #expect(!FileManager.default.fileExists(atPath:directory.appendingPathComponent("Manufacturing").path))
            let page = try await call("studio.read",["projectID":id.uuidString,"offset":0,"limit":1000],context)
            let revision = try #require(page["revision"] as? String),fingerprint = try #require(empty["fingerprint"] as? String)
            let input = EngineeringAnalysisProject.demonstration()
            let inputJSON = String(decoding:try ManufacturingStudy.encoder.encode(input),as:UTF8.self)
            let prepared = try await research(id,"research.configure",["family":family,"expectedFingerprint":fingerprint,"inputJSON":inputJSON],revision:revision,context:context)
            #expect(prepared["configurationSaved"] as? Bool == true && prepared["resultSaved"] as? Bool == false)
            let ready = try #require(prepared["fingerprint"] as? String)
            let result = try await research(id,"research.calculate",["family":family,"expectedFingerprint":ready],revision:revision,context:context)
            #expect(result["resultSaved"] as? Bool == true && (result["active"] as? [String:Any])?["hasResult"] as? Bool == true)
            let archive = directory.appendingPathComponent("Manufacturing/engineering/latest.floeanalysis"),bytes = try Data(contentsOf:archive)
            let actual = try EngineeringAnalysisArchive.open(archive)
            #expect(actual.0.id == input.id && actual.0.source.documentID == input.source.documentID)
            #expect(actual.0.source.documentID != "cad:"+id.uuidString.lowercased())
            document.close()
            let reopened = try await PersonalCADSessions.open(id:id,directory:directory);defer { reopened.close() }
            let restored = try await research(id,"research.inspect",["family":family,"content":"savedResult"],context:context)
            #expect((restored["saved"] as? [String:Any])?["status"] as? String == "saved")
            #expect(restored["resultSaved"] as? Bool == false && (restored["active"] as? [String:Any])?["hasResult"] as? Bool == true)
            #expect((restored["saved"] as? [String:Any])?["archiveSHA256"] as? String == ManufacturingStudy.digest(bytes))
            #expect(try Data(contentsOf:archive) == bytes)
        }
    }
    @Test func wrongScopeStaleUIAndUnknownResearchPathsAreRefusedWithoutWriting() async throws {
        try await withCAD { id,directory,document,context,other in
            let request:[String:Any] = ["family":"engineeringAnalysis"]
            let empty = try await research(id,"research.inspect",request,context:context)
            do { _ = try await research(id,"research.inspect",request,context:other);Issue.record("Another task read this CAD program") }
            catch let FloeError.validationFailed(message) { #expect(message.contains("Open this work")) }
            catch { Issue.record("Wrong-scope read failed for an unrelated reason: \(error)") }
            do { _ = try await research(id,"research.inspect",["family":"engineeringAnalysis","path":"/outside"],context:context);Issue.record("A model path was accepted") }
            catch let FloeError.validationFailed(message) { #expect(message.contains("no path")) }
            catch { Issue.record("Path refusal failed for an unrelated reason: \(error)") }
            let sessions = try ManufacturingSessions.researchSessions(document:document,directory:directory.appendingPathComponent("Manufacturing"),ownerID:id)
            let active = try sessions.snapshot(.engineeringAnalysis)
            _ = try sessions.configure(.engineeringAnalysis,inputJSON:ManufacturingStudy.encoder.encode(EngineeringAnalysisProject.demonstration()),expectedFingerprint:active.fingerprint)
            let before = try Data(contentsOf:directory.appendingPathComponent("Manufacturing/engineering/draft.json"))
            let page = try await call("studio.read",["projectID":id.uuidString,"offset":0,"limit":1000],context)
            do {
                _ = try await research(id,"research.configure",["family":"engineeringAnalysis","expectedFingerprint":try #require(empty["fingerprint"] as? String),
                    "inputJSON":String(decoding:before,as:UTF8.self)],revision:try #require(page["revision"] as? String),context:context)
                Issue.record("A stale research configuration overwrote the UI input")
            } catch ManufacturingError.stale { }
            catch { Issue.record("Research CAS failed for an unrelated reason: \(error)") }
            #expect(try Data(contentsOf:directory.appendingPathComponent("Manufacturing/engineering/draft.json")) == before)
        }
    }
    @Test func registeredResearchApprovalRolesUseTheActualNativeContainerAndDoNotProveReadOnlyWrites() async throws {
        let environment = FloeAgentApp.liveEnvironment;try await environment.ensureDurableAutomationReady()
        let descriptor = try #require(ToolCatalog.descriptor(named:"studio.machining"))
        let paths = try await PersonalContentService.shared.library().typedServiceStorePaths()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ResearchPolicy-\(UUID())")
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        func arguments(_ action:String,extra:[String:Any] = [:]) throws -> [String:Any] {
            var request:[String:Any] = ["family":"engineeringAnalysis"]
            request.merge(extra) { _,new in new }
            return ["projectID":UUID().uuidString,"action":action,"expectedRevision":"actual-CAD-revision",
                "researchJSON":String(decoding:try JSONSerialization.data(withJSONObject:request),as:UTF8.self)]
        }
        for action in ["research.inspect","research.status"] {
            #expect(OrdinaryDocumentActionProfile.role(forToolName:"studio.machining",arguments:try arguments(action)) == .readOnly)
        }
        for action in ["research.cancel","research.openSaved"] {
            var extra:[String:Any] = ["expectedFingerprint":"actual-state"]
            if action == "research.cancel" { extra["operationID"] = UUID().uuidString }
            #expect(OrdinaryDocumentActionProfile.role(forToolName:"studio.machining",arguments:try arguments(action,extra:extra)) == .draftOnly)
        }
        let input = String(decoding:try ManufacturingStudy.encoder.encode(EngineeringAnalysisProject.demonstration()),as:UTF8.self)
        let args = try arguments("research.configure",extra:["expectedFingerprint":"actual-state","inputJSON":input])
        let call = try ToolCall(id:UUID().uuidString,toolName:"studio.machining",argumentsJSON:JSONSerialization.data(withJSONObject:args),scope:.local)
        let resolved = MutationTargetResolver.resolve(for:call,descriptor:descriptor,workspaceRootURL:root,serviceStorePaths:paths)
        #expect(resolved.contractCovered && !resolved.hasUnresolvedExtent)
        let container = try #require(TypedMutationContract.nativeStudioContainerPath(serviceStorePaths:paths))
        #expect(resolved.mutableTargets.map(\.path) == [container])
        let proposed = ProposedAction(toolCall:call,riskLabels:Set(descriptor.riskLabels.map(\.rawValue)),
            userGoal:"Edit this authorized native analysis",hostAndPathScope:.local,
            trustedContext:.init(environmentClass:.localNative,mutableTargetPaths:resolved.mutableTargets.map(\.path),
                hasUnresolvedExtent:resolved.hasUnresolvedExtent,typedContractCovered:resolved.contractCovered,
                workspaceRootPath:root.path,nativeStudioContainerPath:container))
        #expect(DeterministicLocalApprovalPolicy.isExempt(proposed))
        #expect(OrdinaryDocumentActionProfile.role(forToolName:"studio.machining",arguments:try arguments("research.inspect",extra:["path":"/outside"])) == nil)
        #expect(OrdinaryDocumentActionProfile.role(forToolName:"studio.machining",arguments:try arguments("research.unknown")) == nil)
    }
}
#endif
