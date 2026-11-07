// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeTools
import FloeModels
import FloeProviders
import FloeSecurity
import FloeAgentRuntime
import FloeTestSupport
@testable import FloeApp

@Suite("Native studio ordinary-edit approval", .serialized)
@MainActor
struct NativeStudioApprovalIntegrationTests {
    private nonisolated final class DenyingBackend: ModelApprovalPolicy.DecisionBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var calls:Int { lock.withLock { count } }
        private func record() { lock.withLock { count += 1 } }
        func decide(_ action:ProposedAction) async throws -> ApprovalDecision {
            record(); return .deny(reason:"Fixture reviewer must not guess the old object's identity")
        }
    }
    private func root() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("native-studio-policy-\(UUID())")
        try FileManager.default.createDirectory(at:value,withIntermediateDirectories:true)
        return value
    }
    private func descriptor(_ name:String) throws -> ToolCatalog.Descriptor {
        try #require(ToolCatalog.descriptor(named:name),"The actual App must register \(name)")
    }
    private func edit(_ id:UUID) -> [String:Any] {
        ["projectID":id.uuidString,"expectedRevision":"1",
         "operationsJSON":#"[{"action":"transform","objectID":"CA1CE345-0000-4000-8000-000000000001","scale":0.5}]"#]
    }
    private func proposal(_ name:String,_ args:[String:Any],paths:[String:String],workspace:URL,
        scope:ToolScope = .local,environment:ApprovalEnvironmentClass = .localNative,
        extraRisks:Set<String> = [],descriptor supplied:ToolCatalog.Descriptor? = nil) throws -> ProposedAction {
        let descriptor = try supplied ?? self.descriptor(name)
        let data = try JSONSerialization.data(withJSONObject:args,options:.sortedKeys)
        let call = try ToolCall(id:UUID().uuidString,toolName:name,argumentsJSON:data,scope:scope)
        let resolved = MutationTargetResolver.resolve(for:call,descriptor:descriptor,workspaceRootURL:workspace,serviceStorePaths:paths)
        return ProposedAction(toolCall:call,riskLabels:Set(descriptor.riskLabels.map(\.rawValue)).union(extraRisks),
            userGoal:"Scale the newly added object by 0.5; preserve the older 20 mm original.",hostAndPathScope:scope,
            trustedContext:.init(environmentClass:environment,mutableTargetPaths:resolved.mutableTargets.map(\.path),
                hasUnresolvedExtent:resolved.hasUnresolvedExtent,typedContractCovered:resolved.contractCovered,
                workspaceRootPath:workspace.resolvingSymlinksInPath().path,
                nativeStudioContainerPath:TypedMutationContract.nativeStudioContainerPath(serviceStorePaths:paths)))
    }

    @Test("The real producer's container covers a newly created record without inventing a record path")
    func actualLibraryContainerAndNewRecord() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let custom = root.appendingPathComponent("Custom migrated library")
        let service = PersonalContentService(root:custom), library = try await service.library()
        let frozen = await library.typedServiceStorePaths()
        let expected = custom.standardizedFileURL.resolvingSymlinksInPath().path
        #expect(frozen[TypedMutationContract.nativeStudioLibraryStoreKey] == expected)
        let record = try await service.create(kind:.diagram,title:"Created after the run froze its service root")
        let actual = try await library.resolve(record.id)
        let action = try proposal("studio.edit",edit(record.id),paths:frozen,workspace:root)
        #expect(action.trustedContext?.typedContractCovered == true)
        #expect(action.trustedContext?.mutableTargetPaths == [expected])
        #expect(action.trustedContext?.mutableTargetPaths != [actual.url.path])
        #expect(DeterministicLocalApprovalPolicy.isExempt(action))
        #expect(RuntimeAuthorityDigest.canonicalTarget(for:action.toolCall,descriptor:try descriptor("studio.edit"),
            workspaceRootURL:root,serviceStorePaths:frozen) == "file:"+expected)
        var forged = edit(record.id); forged["storeRoot"] = "/tmp/model-cannot-mint-a-root"
        #expect(!DeterministicLocalApprovalPolicy.isExempt(try proposal("studio.edit",forged,paths:frozen,workspace:root)))
    }

    @Test("Ordinary automatic and human modes bypass a second reviewer; explicit model mode remains a choice")
    func automaticAndHumanSkipReviewer() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let paths = await PersonalContentLibrary(root:root.appendingPathComponent("Library")).typedServiceStorePaths()
        let backend = DenyingBackend(), automatic = AutomaticApprovalPolicy(backend:backend)
        for (name,args) in [
            ("studio.edit",edit(UUID())),
            ("studio.media",["projectID":UUID().uuidString,"toolID":"image.text","inputJSON":#"{"expectedRevision":1,"text":"Native text"}"#] as [String:Any])
        ] {
            let action = try proposal(name,args,paths:paths,workspace:root)
            #expect(!automatic.requiresModelReview(action))
            guard case .allow(let scope,_) = try await automatic.decide(action) else { Issue.record("Ordinary edit reached review"); return }
            #expect(scope.singleUse && scope.toolName == name)
            #expect(try await HumanApprovalPolicy().decide(action).permitsExecution)
            #expect(backend.calls == 0)
        }
        let action = try proposal("studio.edit",edit(UUID()),paths:paths,workspace:root)
        let explicit = ModelApprovalPolicy(backend:backend)
        #expect(explicit.requiresModelReview(action))
        #expect(!(try await explicit.decide(action)).permitsExecution)
        #expect(backend.calls == 1)
    }

    @Test("Closed native action coverage matches the audited local dispatcher")
    func closedActionTable() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let paths = await PersonalContentLibrary(root:root.appendingPathComponent("Library")).typedServiceStorePaths()
        #expect(TypedMutationContract.nativeStudioMediaToolIDs == MediaV2Session.localToolIDs.union(StudioMediaSourceContracts.hostToolIDs))
        for (name,actions) in [
            ("studio.run",["calculate","exportSTL","exportToolpath","slice","renderWAV","renderMP3","exportMedia","exportOriginal","exportORA","exportPSD","exportOTIO","inspectAudio"]),
            ("studio.machining",["inspect","prepare","configure","calculate","exportSTL","exportToolpath","preparePrint"]),
            ("studio.chemistry",["capabilities","history","calculate","status","cancel","apply","export"])
        ] {
            for operation in actions {
                var args:[String:Any] = ["projectID":UUID().uuidString,"action":operation]
                if name == "studio.machining" { args["expectedRevision"] = "1" }
                #expect(DeterministicLocalApprovalPolicy.isExempt(try proposal(name,args,paths:paths,workspace:root)),"\(name) \(operation)")
            }
        }
        let create = try proposal("studio.create",["kind":"diagram","title":"Native work","format":NSNull()],paths:paths,workspace:root)
        #expect(DeterministicLocalApprovalPolicy.isExempt(create))
        #expect(!DeterministicLocalApprovalPolicy.isExempt(try proposal("studio.create",["kind":"futureRemoteApp","title":"No"],paths:paths,workspace:root)))
    }

    @Test("Unknown names/actions, extra risks, missing roots and remote contexts keep review")
    func unresolvedAndSensitiveCallsStayReviewed() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let paths = await PersonalContentLibrary(root:root.appendingPathComponent("Library")).typedServiceStorePaths()
        let unknown = ToolCatalog.Descriptor(name:"studio.future",riskLabels:[.persistsPersonalData],isSideEffecting:true,effect:.internalState)
        let actions = [
            try proposal("studio.edit",edit(UUID()),paths:[:],workspace:root),
            try proposal("studio.run",["projectID":UUID().uuidString,"action":"sendToCloud"],paths:paths,workspace:root),
            try proposal("studio.media",["projectID":UUID().uuidString,"toolID":"image.remote","inputJSON":"{}"],paths:paths,workspace:root),
            try proposal("studio.chemistry",["projectID":UUID().uuidString,"action":"calculate","inputJSON":#"{"environmentID":"remote.user"}"#],paths:paths,workspace:root),
            try proposal("studio.edit",edit(UUID()),paths:paths,workspace:root,scope:.host(UUID())),
            try proposal("studio.edit",edit(UUID()),paths:paths,workspace:root,environment:.remote),
            try proposal("studio.edit",edit(UUID()),paths:paths,workspace:root,environment:.unknown),
            try proposal("studio.edit",edit(UUID()),paths:paths,workspace:root,extraRisks:["networkAccess"]),
            try proposal("studio.edit",edit(UUID()),paths:paths,workspace:root,extraRisks:["accessesCredentials"]),
            try proposal("studio.edit",edit(UUID()),paths:paths,workspace:root,extraRisks:["executesLocalCode"]),
            try proposal("studio.future",["projectID":UUID().uuidString],paths:paths,workspace:root,descriptor:unknown)
        ]
        for action in actions {
            #expect(!DeterministicLocalApprovalPolicy.isExempt(action))
            let backend = DenyingBackend()
            #expect(!(try await AutomaticApprovalPolicy(backend:backend).decide(action)).permitsExecution)
            #expect(backend.calls == 1)
        }
        var mismatched = try proposal("studio.edit",edit(UUID()),paths:paths,workspace:root)
        mismatched.trustedContext?.mutableTargetPaths = [root.appendingPathComponent("Unrelated original").path]
        #expect(!DeterministicLocalApprovalPolicy.isExempt(mismatched))
        let repo = root.appendingPathComponent("Repository")
        try FileManager.default.createDirectory(at:repo.appendingPathComponent(".git"),withIntermediateDirectories:true)
        let repoPaths = await PersonalContentLibrary(root:repo.appendingPathComponent("Library")).typedServiceStorePaths()
        #expect(!DeterministicLocalApprovalPolicy.isExempt(try proposal("studio.edit",edit(UUID()),paths:repoPaths,workspace:root)))
    }

    @Test("Meeting payloads retain review while their independent Notes extent is unbound")
    func independentMeetingNotesAreNotClaimedInsideContainer() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let paths = await PersonalContentLibrary(root:root.appendingPathComponent("Library")).typedServiceStorePaths()
        for operation in ["note","todo","decision","summary"] {
            let json = String(decoding:try JSONSerialization.data(withJSONObject:["action":operation,"text":"Meeting text"]),as:UTF8.self)
            var args = edit(UUID()); args["operationsJSON"] = json
            #expect(!DeterministicLocalApprovalPolicy.isExempt(try proposal("studio.edit",args,paths:paths,workspace:root)))
        }
    }

    @Test("Actual Runtime resolves internalState studio calls before ordinary approval")
    func runtimeDoesNotAskBackendToGuessObjectIdentity() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let content = PersonalContentService(root:root.appendingPathComponent("Library")), library = try await content.library()
        let frozen = await library.typedServiceStorePaths()
        let created = try await content.create(kind:.diagram,title:"Created after roots were frozen")
        let adapter = MockAdapter(), executor = MockExecutor(), backend = DenyingBackend()
        executor.descriptors["studio.edit"] = try descriptor("studio.edit")
        let json = String(decoding:try JSONSerialization.data(withJSONObject:edit(created.id)),as:UTF8.self)
        adapter.script = [
            [.toolRequest(try TestFixtures.toolCall(id:"new-object-scale",toolName:"studio.edit",arguments:json)),.completed(.init(stopReason:.toolUse))],
            [.textDelta(.init(text:"处理完成。")),.completed(.init(stopReason:.endTurn))]
        ]
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(configuration:.init(provider:provider,model:TestFixtures.testModel(providerID:provider.id),
                pauseTimeout:0.1,verifyFinalAnswer:false,serviceStorePaths:frozen),adapter:adapter,
            policy:AutomaticApprovalPolicy(backend:backend),executor:executor,checkpointStore:MockCheckpointStore())
        try await runtime.start(goal:"把新对象缩放到0.5，保留旧20mm原件")
        #expect(backend.calls == 0)
        #expect(executor.executedCalls.map(\.id) == ["new-object-scale"])
        #expect(await runtime.state.name == "completed")
    }

    @Test("Waveform reads use ordinary local read routing while explicit model mode remains intact")
    func audioInspectionDoesNotNeedASecondModel() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let action = try proposal("audio.inspect",["path":"source.caf","bins":64],paths:[:],workspace:root)
        let backend = DenyingBackend(), automatic = AutomaticApprovalPolicy(backend:backend)
        #expect(!automatic.requiresModelReview(action))
        #expect(try await automatic.decide(action).permitsExecution)
        #expect(try await HumanApprovalPolicy().decide(action).permitsExecution)
        #expect(backend.calls == 0)
        #expect(!(try await ModelApprovalPolicy(backend:backend).decide(action)).permitsExecution)
        #expect(backend.calls == 1)
        for unsafe in [
            try proposal("audio.inspect",["path":"source.caf"],paths:[:],workspace:root,extraRisks:["writesFiles"]),
            try proposal("audio.inspect",["path":"source.caf"],paths:[:],workspace:root,scope:.host(UUID())),
            try proposal("audio.inspect",["path":"/etc/hosts"],paths:[:],workspace:root)
        ] { #expect(!DeterministicLocalApprovalPolicy.isExempt(unsafe)) }
        var unresolved = action; unresolved.trustedContext?.workspaceRootPath = nil
        #expect(!DeterministicLocalApprovalPolicy.isExempt(unresolved))
        #expect(TemporaryChatToolPolicy.readOnlyDescriptor(try descriptor("audio.inspect")) == nil)
    }

    @Test("A resolved library container never grants another task or another original")
    func nativeProjectBindingsRemainAuthoritative() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let authority = try StudioDocumentAccess(root:root.appendingPathComponent("Authority"))
        let task = UUID(), stranger = UUID(), owned = UUID(), original = UUID()
        try await authority.finishCreation(conversationID:task,projectID:owned)
        #expect(try await authority.canAccess(conversationID:task,projectID:owned,editing:true))
        #expect(try await !authority.canAccess(conversationID:stranger,projectID:owned,editing:true))
        #expect(try await !authority.canAccess(conversationID:task,projectID:original,editing:true))
        let reopened = try StudioDocumentAccess(root:root.appendingPathComponent("Authority"))
        #expect(try await !reopened.canAccess(conversationID:stranger,projectID:owned,editing:false))
    }
}
#endif
