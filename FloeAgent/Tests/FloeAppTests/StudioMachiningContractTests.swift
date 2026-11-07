// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloePersistence
import FloeTools
import FloeCAD
import FloeManufacturingCore
import FloePrintCore
import FloeAgentRuntime
import FloeSecurity
import FloeTestSupport
@testable import FloeApp

/// Registered App runners, genuine CAD solids, and their existing durable
/// services. No shaft fixture, fake mesh backend or second environment.
@Suite("Registered CAD machining contracts",.serialized)
@MainActor struct StudioMachiningContractTests {
    private struct Inspection {
        let revision:String
        let state:[String:Any]
    }
    private enum ContractError:Error { case invalidPage }
    private func json(_ output:ToolExecutionOutput) throws -> [String:Any] {
        try #require(JSONSerialization.jsonObject(with:Data((output.capturedOutput ?? output.summary).utf8)) as? [String:Any])
    }
    private func invoke(_ name:String,_ args:[String:Any],_ context:ToolContext) async throws -> ToolExecutionOutput {
        let runner = try #require(ToolRunnerRegistry.shared.runner(named:name))
        return try await runner.execute(argumentsJSON:JSONSerialization.data(withJSONObject:args),context:context)
    }
    private func withContexts(_ body:@MainActor (ToolContext,ToolContext) async throws -> Void) async throws {
        let environment = FloeAgentApp.liveEnvironment
        try await environment.ensureDurableAutomationReady()
        var contexts = [ToolContext](),ids = [UUID]()
        do {
            for label in ["owner","other"] {
                let id = UUID(),runID = UUID(),now = Date();ids.append(id)
                try await environment.conversationStore.saveConversation(.init(id:id,title:"Machining contract \(label)",createdAt:now,updatedAt:now))
                _ = try await SQLiteWorkspaceStore(database:environment.database).ensureWorkspace(conversationID:id,title:"Machining contract \(label)")
                try await environment.conversationStore.setArchived(id:id,archived:true)
                try await environment.runStore.saveRun(.init(id:runID,conversationID:id,state:"executing",goal:"Machining contract",startedAt:now))
                var context = ToolContext(runID:runID,toolCallID:"create-owned-cad",allowedToolNames:StudioCoordinator.names,
                    cancellation:CancellationToken(),conversationID:id)
                context.frozenEffectiveCatalogNames = StudioCoordinator.names
                context.approvalGrantID = UUID() // Trusted host test seam, not a model-authored grant.
                contexts.append(context)
            }
            try await body(contexts[0],contexts[1])
        }
        catch { for id in ids { try? await environment.conversationStore.deleteConversation(id:id) };throw error }
        for id in ids { try await environment.conversationStore.deleteConversation(id:id) }
    }
    private func createCAD(_ context:ToolContext) async throws -> UUID {
        let output = try json(try await invoke("studio.create",["kind":"cad3D","title":"Contract CAD \(UUID().uuidString.prefix(8))"],context))
        let record = try #require(output["record"] as? [String:Any])
        let id = try #require(record["id"] as? String)
        return try #require(UUID(uuidString:id))
    }
    private func addBox(_ document:FloeCADDocument,min:[Double],max:[Double],height:Double) async throws {
        let sketch = document.execute(["op":"sketch.create","args":["name":"Actual contract part"]])
        try #require(sketch.isOK,"Native sketch.create must make an actual sketch")
        let payload = try #require(JSONSerialization.jsonObject(with:sketch.payload) as? [String:Any])
        let id = try #require(payload["sketchID"] as? String)
        for command:[String:Any] in [
            ["op":"sketch.addEntities","args":["sketchID":id,"entities":[["kind":"rect","min":min,"max":max]]]],
            ["op":"feature.extrude","args":["sketchID":id,"seedPoint":[(min[0]+max[0])/2,(min[1]+max[1])/2],"distance":height]]
        ] {
            let result = document.execute(command)
            try #require(result.isOK,"Native sketch and extrude commands must make an actual solid")
        }
        let save = await document.save()
        try #require(save.succeeded,"The real CAD document must save")
    }
    /// Concatenates the actual returned character pages and refuses a mixed
    /// revision. No assumption that a full CAD state fits in the first page.
    private func inspect(_ id:UUID,_ context:ToolContext,tool:String = "studio.machining") async throws -> Inspection {
        var offset = 0,text = "",revision:String?
        for _ in 0..<128 {
            var args:[String:Any] = ["projectID":id.uuidString,"offset":offset,"limit":1024]
            if tool == "studio.machining" { args["action"] = "inspect" }
            let page = try json(try await invoke(tool,args,context))
            let current = try #require(page["revision"] as? String)
            if let revision { #expect(current == revision);guard current == revision else { throw ContractError.invalidPage } }
            else { revision = current }
            text += try #require(page["contentJSON"] as? String)
            guard let next = page["nextOffset"] as? Int else {
                return Inspection(revision:try #require(revision),state:try #require(JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any]))
            }
            #expect(next>offset);guard next>offset else { throw ContractError.invalidPage };offset = next
        }
        throw ContractError.invalidPage
    }
    private func study(_ inspection:Inspection) throws -> ManufacturingStudy {
        let machining = try #require(inspection.state["machining"] as? [String:Any])
        return try JSONDecoder().decode(ManufacturingStudy.self,
            from:JSONSerialization.data(withJSONObject:try #require(machining["study"] as? [String:Any])))
    }
    private func expectForeignDenial(_ name:String,_ args:[String:Any],_ context:ToolContext) async {
        do { _ = try await invoke(name,args,context);Issue.record("Another task accessed an unbound CAD/print original") }
        catch let FloeError.validationFailed(message) { #expect(message.contains("Open this work")) }
        catch { Issue.record("Isolation failed for an unrelated reason: \(error)") }
    }
    @Test func inspectPrepareConfigureAndCalculateKeepCADOwnershipAndRejectStaleEdits() async throws {
        try await withContexts { owner,other in
            var context = owner
            let id = try await createCAD(context),library = try await PersonalContentService.shared.library()
            let location = try await library.resolve(id),directory = location.url.appendingPathComponent("Manufacturing")
            let document = try await PersonalCADSessions.open(id:id,directory:location.url)
            try await addBox(document,min:[-4,-3],max:[4,3],height:4)
            let cadRevision = document.revision,cadContent = document.contentSHA256
            var unapproved = context;unapproved.approvalGrantID = nil;unapproved.toolCallID = "unapproved-prepare"
            let before = try await inspect(id,unapproved)
            #expect((before.state["machining"] as? [String:Any])?["study"] == nil)
            #expect(!FileManager.default.fileExists(atPath:directory.path))
            #expect(document.revision == cadRevision && document.contentSHA256 == cadContent)
            do { _ = try await invoke("studio.machining",["projectID":id.uuidString,"action":"prepare","expectedRevision":before.revision],unapproved);Issue.record("Prepare accepted a missing grant") }
            catch let FloeError.validationFailed(message) { #expect(message.contains("approval grant")) }
            #expect(!FileManager.default.fileExists(atPath:directory.path))
            context.toolCallID = "prepare-real-cad"
            _ = try await invoke("studio.machining",["projectID":id.uuidString,"action":"prepare","expectedRevision":before.revision],context)
            let draftURL = directory.appendingPathComponent("draft.json"),draftBytes = try Data(contentsOf:draftURL)
            let actual = try JSONDecoder().decode(ManufacturingStudy.self,from:draftBytes)
            #expect(actual.source.documentID == "cad:"+id.uuidString.lowercased())
            #expect(actual.cam?.partMesh?.triangles.isEmpty == false)
            #expect(actual.stock.isBox && !actual.turning.enabled)
            let prepared = try await inspect(id,context),editable = try study(prepared)
            #expect(editable.cam?.partMesh == nil,"Inspection elides the CAD-owned mesh")
            #expect(editable.id == actual.id && editable.source == actual.source && editable.profile == actual.profile)
            for replaceGeometry in [false,true] {
                var forged = editable
                if replaceGeometry { forged.cam?.partMesh = .init(vertices:[[0,0,0],[1,0,0],[0,1,0]],triangles:[[0,1,2]]) }
                else { forged.source.documentID = "fixture:unrelated-part" }
                context.toolCallID = replaceGeometry ? "reject-foreign-mesh" : "reject-foreign-source"
                do { _ = try await invoke("studio.machining",["projectID":id.uuidString,"action":"configure","expectedRevision":prepared.revision,
                    "studyJSON":String(decoding:try forged.encoded(),as:UTF8.self)],context);Issue.record("Configure replaced CAD-owned input") }
                catch let FloeError.validationFailed(message) { #expect(message.contains("CAD-owned")) }
                #expect(try Data(contentsOf:draftURL) == draftBytes)
            }
            var configured = try editable.applyingMachineSetup(.init(kind:.milling3Axis,coordinateFrame:.init(originMM:[0,0,4])))
            let tool = ManufacturingCAM.Tool(id:"contract-mill",name:"Contract end mill",diameterMM:2,cuttingLengthMM:8)
            var operation = ManufacturingCAM.Operation(id:"contract-face",name:"Face",strategy:"face",toolID:tool.id)
            operation.frame.originMM = [0,0,4];operation.minUVMM = [-4,-3];operation.maxUVMM = [4,3]
            operation.depthMM = 0.5;operation.stepDownMM = 0.5;operation.stepOverMM = 1
            configured.cam?.tools = [tool];configured.cam?.operations = [operation]
            context.toolCallID = "configure-real-machine-and-operation"
            let configuredJSON = String(decoding:try configured.encoded(),as:UTF8.self)
            _ = try await invoke("studio.machining",["projectID":id.uuidString,"action":"configure","expectedRevision":prepared.revision,"studyJSON":configuredJSON],context)
            let committedBytes = try Data(contentsOf:draftURL),committed = try JSONDecoder().decode(ManufacturingStudy.self,from:committedBytes)
            #expect(committed.source == actual.source && committed.profile == actual.profile && committed.cam?.partMesh == actual.cam?.partMesh)
            #expect(committed.machineSetup?.kind == .milling3Axis)
            #expect(committed.cam?.tools.first?.id == tool.id && committed.cam?.operations.first?.id == operation.id)
            context.toolCallID = "reject-stale-configure"
            do { _ = try await invoke("studio.machining",["projectID":id.uuidString,"action":"configure","expectedRevision":prepared.revision,"studyJSON":configuredJSON],context);Issue.record("A stale configure committed") }
            catch PersonalContentError.changedDocument {}
            #expect(try Data(contentsOf:draftURL) == committedBytes)
            let ready = try await inspect(id,context)
            context.toolCallID = "calculate-owned-cad"
            let calculated = try json(try await invoke("studio.machining",["projectID":id.uuidString,"action":"calculate","expectedRevision":ready.revision],context))
            let archive = directory.appendingPathComponent("latest.floemanufacturing"),archiveBytes = try Data(contentsOf:archive)
            #expect(StudioToolOutput.hash(archiveBytes) == (calculated["sha256"] as? String))
            let result = try ManufacturingArchive.open(archive)
            #expect(result.0.source == committed.source && result.0.cam?.partMesh == actual.cam?.partMesh)
            #expect(result.1.inputSHA256 == (try result.0.fingerprint()))
            #expect(result.1.result.paths.contains { $0.operationID == operation.id && $0.toolID == tool.id && !$0.points.isEmpty })
            await expectForeignDenial("studio.machining",["projectID":id.uuidString,"action":"inspect"],other)
            // A real CAD change must fence export of the old result, even if
            // the caller freshly reads the outer document revision.
            try await addBox(document,min:[8,8],max:[9,9],height:1)
            let changed = try await inspect(id,context)
            context.toolCallID = "reject-old-source-export"
            do { _ = try await invoke("studio.machining",["projectID":id.uuidString,"action":"exportToolpath","expectedRevision":changed.revision],context);Issue.record("Old-source toolpath was exported") }
            catch ManufacturingError.stale {}
            #expect(try Data(contentsOf:archive) == archiveBytes)
        }
    }
    /// A real multi-spindle archive is produced once by the existing engine.
    /// Readback must return these bytes and measurements, not calculate again.
    private func saveCell(in directory:URL) throws -> (ManufacturingCellProject,CellSimulationArtifact,URL) {
        var project = ManufacturingCellProject.demonstration()
        project.cell.name = "Saved multi-spindle contract \(UUID().uuidString.prefix(8))"
        var artifact = try CellManufacturingEngine().compute(project)
        artifact.elapsedSeconds = 867.5309 // Valid stored metadata; recalculation cannot preserve this marker.
        let file = directory.appendingPathComponent("cell/latest.floecell")
        try ManufacturingCellArchive.save(project:project,artifact:artifact,to:file)
        return (project,artifact,file)
    }
    private func cell(_ page:[String:Any]) throws -> CADManufacturingCellInspection {
        try JSONDecoder().decode(CADManufacturingCellInspection.self,
            from:JSONSerialization.data(withJSONObject:try #require(page["manufacturingCell"] as? [String:Any])))
    }
    @Test func savedManufacturingCellIsSeparateFromOrdinaryCAMAndVisibleToBothAuthorizedChats() async throws {
        try await withContexts { owner,other in
            var context = owner
            let environment = FloeAgentApp.liveEnvironment
            let id = try await createCAD(context),library = try await PersonalContentService.shared.library()
            let location = try await library.resolve(id),directory = location.url.appendingPathComponent("Manufacturing")
            let document = try await PersonalCADSessions.open(id:id,directory:location.url)
            try await addBox(document,min:[-2,-2],max:[2,2],height:2)
            let before = try await inspect(id,context)
            context.toolCallID = "prepare-empty-ordinary-cam"
            _ = try await invoke("studio.machining",["projectID":id.uuidString,"action":"prepare","expectedRevision":before.revision],context)
            let (project,artifact,file) = try saveCell(in:directory)
            let archive = try Data(contentsOf:file),draft = try Data(contentsOf:directory.appendingPathComponent("draft.json"))
            let cadRevision = document.revision,cadContent = document.contentSHA256
            context.approvalGrantID = nil
            let page = try json(try await invoke("studio.machining",["projectID":id.uuidString,"action":"inspect","limit":1],context))
            #expect((page["contentJSON"] as? String)?.count == 1 && page["nextOffset"] != nil)
            let observation = try cell(page),saved = try #require(observation.savedResult)
            #expect(observation.status == .saved && observation.family == "manufacturingCell" && observation.ownerCADProjectID == id)
            #expect(saved.cellProjectID == project.id && saved.name == project.cell.name)
            #expect(saved.archiveSHA256 == ManufacturingStudy.digest(archive) && saved.archiveByteCount == archive.count)
            #expect(saved.inputSHA256 == artifact.inputSHA256 && saved.calculationElapsedSeconds == 867.5309)
            #expect(saved.scheduleTotalSeconds == artifact.schedule.totalSeconds)
            #expect(saved.computedOperationCount == artifact.jobs.count && saved.transferRecordCount == artifact.schedule.transfers.count)
            #expect(saved.remainingWorkpieces.count == artifact.finalStock.count)
            for stock in saved.remainingWorkpieces { #expect(stock.remainingVolumeMM3 == artifact.finalStock[stock.workpieceID]?.remainingMM3) }
            let complete = try await inspect(id,context),main = try #require(complete.state["machining"] as? [String:Any])
            let ordinary = try study(complete)
            #expect(ordinary.cam?.operations.isEmpty == true && ordinary.cam?.tools.isEmpty == true)
            #expect(main["hasSavedResult"] as? Bool == false,"A saved cell cannot masquerade as a computed ordinary CAM study")
            let nested = try JSONDecoder().decode(CADManufacturingCellInspection.self,
                from:JSONSerialization.data(withJSONObject:try #require(main["manufacturingCell"] as? [String:Any])))
            #expect(nested.savedResult?.archiveSHA256 == saved.archiveSHA256)
            await expectForeignDenial("studio.machining",["projectID":id.uuidString,"action":"inspect"],other)

            // The actual work assistant and the original ordinary chat share
            // their existing binding service, not a model-supplied path.
            let assistant = try await environment.studioCoordinator.assistant(for:location.record)
            let assistantRun = UUID(),now = Date()
            try await environment.runStore.saveRun(.init(id:assistantRun,conversationID:assistant,state:"executing",goal:"Read saved cell",startedAt:now))
            var assistantContext = ToolContext(runID:assistantRun,toolCallID:"read-cell-from-work-assistant",allowedToolNames:StudioCoordinator.names,
                cancellation:CancellationToken(),conversationID:assistant)
            assistantContext.frozenEffectiveCatalogNames = StudioCoordinator.names
            do {
                let assistantPage = try json(try await invoke("studio.machining",["projectID":id.uuidString,"action":"inspect","limit":1],assistantContext))
                #expect(try cell(assistantPage).savedResult?.archiveSHA256 == saved.archiveSHA256)
                try await environment.conversationStore.deleteConversation(id:assistant)
            } catch { try? await environment.conversationStore.deleteConversation(id:assistant);throw error }
            #expect(try Data(contentsOf:file) == archive && Data(contentsOf:directory.appendingPathComponent("draft.json")) == draft)
            #expect(document.revision == cadRevision && document.contentSHA256 == cadContent)

            // Real discovery, dispatch, capture and subsequent provider input.
            // Only provider transport is scripted, never the native result.
            let runner = try #require(ToolRunnerRegistry.shared.runner(named:"studio.machining"))
            let observed = AsyncLock<ToolExecutionOutput?>(nil),registry = ToolRunnerRegistry()
            registry.register(AnyAgentTool(descriptor:runner.descriptor,run:{ args,ctx in
                let result = try await runner.run(args,ctx)
                observed.withLock { $0 = result };return result
            },validateArguments:runner.validateArguments,preflightSubmission:runner.preflightSubmission,routing:ToolEnvironmentRouting()))
            let discovery = try TestFixtures.toolCall(id:"find-saved-cell",toolName:"tools.search",arguments:#"{"query":"多主轴 多刀塔 制造单元"}"#)
            let call = try TestFixtures.toolCall(id:"inspect-saved-cell",toolName:"studio.machining",
                arguments:String(decoding:JSONSerialization.data(withJSONObject:["projectID":id.uuidString,"action":"inspect","limit":12000]),as:UTF8.self))
            let adapter = MockAdapter(),provider = TestFixtures.localhostProvider(),checkpoints = MockCheckpointStore()
            adapter.script = [
                [.toolRequest(discovery),.completed(.init(stopReason:.toolUse))],
                [.toolRequest(call),.completed(.init(stopReason:.toolUse))],
                [.textDelta(.init(text:"Saved manufacturing-cell measurements received.")),.completed(.init(stopReason:.endTurn))]
            ]
            let captures = FileManager.default.temporaryDirectory.appendingPathComponent("cell-readback-captures-\(UUID())")
            defer { try? FileManager.default.removeItem(at:captures) }
            let runtime = FloeAgentRuntime(configuration:.init(conversationID:try #require(context.conversationID),provider:provider,
                model:TestFixtures.testModel(providerID:provider.id),allowedToolNames:["studio.machining"],maxToolSteps:4,
                serviceStorePaths:await library.typedServiceStorePaths(),toolResultCaptureRoot:captures),
                adapter:adapter,policy:HumanApprovalPolicy(),executor:CatalogToolExecutor(runners:registry),checkpointStore:checkpoints,runID:context.runID)
            try await runtime.start(goal:"Read the already saved 多主轴 多刀塔 制造单元 result. Do not calculate or edit.")
            #expect(await runtime.state.name == "completed")
            #expect(adapter.requests.count == 3)
            let searched = try #require(adapter.requests.dropFirst().first?.toolResults.first { $0.callID == discovery.id }?.output)
            #expect(searched.contains("studio.machining") || searched.contains("studio_machining"))
            let output = try #require(observed.withLock { $0 }),full = output.capturedOutput ?? output.summary
            #expect(!output.capturedOutputTruncated && output.fullOutputSHA256 == FloeDigest.sha256Hex(Data(full.utf8)))
            let wire = try #require(adapter.requests.last?.toolResults.first { $0.callID == call.id }?.output)
            #expect(wire.contains("trustedSourceID") && wire.hasSuffix(full),"The next provider request receives the real complete JSON")
            let delivered = try cell(try #require(JSONSerialization.jsonObject(with:Data(full.utf8)) as? [String:Any]))
            #expect(delivered.savedResult?.archiveSHA256 == saved.archiveSHA256)
            #expect(delivered.savedResult?.remainingWorkpieces.last?.remainingVolumeMM3 == saved.remainingWorkpieces.last?.remainingVolumeMM3)
            #expect(checkpoints.saved.flatMap(\.pendingToolResults).contains { $0.callID == call.id && $0.status == .ok })
            #expect(try Data(contentsOf:file) == archive && Data(contentsOf:directory.appendingPathComponent("draft.json")) == draft)
        }
    }
    @Test func missingTamperedLinkedAndCancelledSavedCellsNeverBecomeDemoResults() async throws {
        try await withContexts { owner,other in
            var context = owner
            let id = try await createCAD(context),library = try await PersonalContentService.shared.library()
            let location = try await library.resolve(id),directory = location.url.appendingPathComponent("Manufacturing")
            context.approvalGrantID = nil
            let missing = try cell(try json(try await invoke("studio.machining",["projectID":id.uuidString,"action":"inspect","limit":1],context)))
            #expect(missing.status == .none && missing.savedResult == nil)
            #expect(!FileManager.default.fileExists(atPath:directory.path),"A missing result creates neither directories nor a demonstration")
            let (_,artifact,file) = try saveCell(in:directory),original = try Data(contentsOf:file)
            var envelope = try #require(JSONSerialization.jsonObject(with:original) as? [String:Any])
            var output = try #require(envelope["output"] as? [String:Any]),schedule = try #require(output["schedule"] as? [String:Any])
            schedule["totalSeconds"] = -1;output["schedule"] = schedule;envelope["output"] = output
            let tampered = try JSONSerialization.data(withJSONObject:envelope,options:.sortedKeys)
            try tampered.write(to:file,options:.atomic)
            do { _ = try await invoke("studio.machining",["projectID":id.uuidString,"action":"inspect"],context);Issue.record("Tampered cell returned a result or silently fell back to ordinary CAM") }
            catch ManufacturingError.archive {}
            #expect(try Data(contentsOf:file) == tampered)
            // Recomputing the envelope digest must not bypass the existing
            // artifact/scheduler validator in the new Data entry point.
            var invalidArtifact = artifact
            invalidArtifact.schedule.totalSeconds += 1
            envelope["output"] = try JSONSerialization.jsonObject(with:ManufacturingStudy.encoder.encode(invalidArtifact))
            envelope["outputSHA256"] = try ResearchArchive.digest(invalidArtifact)
            let invalidChain = try JSONSerialization.data(withJSONObject:envelope,options:.sortedKeys)
            try invalidChain.write(to:file,options:.atomic)
            do { _ = try await invoke("studio.machining",["projectID":id.uuidString,"action":"inspect"],context);Issue.record("A digest-valid invalid cell schedule bypassed artifact validation") }
            catch ManufacturingError.archive {}
            #expect(try Data(contentsOf:file) == invalidChain)
            var wrongFamily = try #require(JSONSerialization.jsonObject(with:original) as? [String:Any])
            wrongFamily["family"] = "engineeringAnalysis"
            do { _ = try ManufacturingCellArchive.open(data:JSONSerialization.data(withJSONObject:wrongFamily));Issue.record("A different research family was accepted as a cell") }
            catch ManufacturingError.archive {}
            await expectForeignDenial("studio.machining",["projectID":id.uuidString,"action":"inspect"],other)
            try original.write(to:file,options:.atomic)
            let outside = location.url.appendingPathComponent("original-cell-recovery.floecell")
            try FileManager.default.moveItem(at:file,to:outside)
            try FileManager.default.createSymbolicLink(at:file,withDestinationURL:outside)
            do { _ = try await invoke("studio.machining",["projectID":id.uuidString,"action":"inspect"],context);Issue.record("A linked cell escaped the descriptor-bound source") }
            catch ManufacturingError.archive {}
            #expect(try Data(contentsOf:outside) == original)
            try FileManager.default.removeItem(at:file)
            try FileManager.default.moveItem(at:outside,to:file)
            context.cancellation.cancel()
            do { _ = try await invoke("studio.machining",["projectID":id.uuidString,"action":"inspect"],context);Issue.record("A cancelled inspect returned data") }
            catch FloeError.cancelled {}
            #expect(try Data(contentsOf:file) == original)
        }
    }

    @Test func approvedPrintPreparationReplaysItsEditedChildAndKeepsOtherTasksOut() async throws {
        try await withContexts { owner,other in
            var context = owner
            let id = try await createCAD(context),library = try await PersonalContentService.shared.library()
            let location = try await library.resolve(id),document = try await PersonalCADSessions.open(id:id,directory:location.url)
            try await addBox(document,min:[-2,-2],max:[2,2],height:2)
            let sourceMesh:PrintMesh
            switch document.nativePrintGeometrySnapshot(expectedRevision:document.revision,expectedChangeCount:document.exchangeChangeCount,
                expectedContentSHA256:document.contentSHA256) {
            case .success(let bytes,_,let coverage):
                sourceMesh = try PrintMesh(binarySTL:bytes)
                #expect(coverage.includedCount == 1 && coverage.excludedCount == 0)
            default: throw ContractError.invalidPage
            }
            let source = try await inspect(id,context)
            context.toolCallID = "approved-print-preparation"
            let approved = context
            let args:[String:Any] = ["projectID":id.uuidString,"action":"preparePrint","expectedRevision":source.revision,"title":"Contract print \(UUID().uuidString.prefix(8))"]
            let prepared = try json(try await invoke("studio.machining",args,approved))
            let record = try #require(prepared["record"] as? [String:Any])
            let childText = try #require(record["id"] as? String)
            let childID = try #require(UUID(uuidString:childText))
            #expect(childID != id)
            let child = try await inspect(childID,context,tool:"studio.read")
            let childDocument = try JSONDecoder().decode(PrintProjectDocument.self,from:JSONSerialization.data(withJSONObject:child.state))
            #expect(childDocument.sourceSnapshot?.sourceOwnerID == id.uuidString)
            #expect(childDocument.sourceSnapshot?.kind == .cad)
            #expect(childDocument.sourceSnapshot?.includedBodyIDs.count == 1)
            #expect(childDocument.sourceSnapshot?.savedCADRevision == document.revision)
            #expect(childDocument.sourceSnapshot?.sourceContentSHA256 == document.contentSHA256)
            #expect(childDocument.sourceSnapshot?.geometrySHA256 == sourceMesh.sha256)
            let provenance = try #require(childDocument.sourceSnapshot)
            let placement = try #require(provenance.initialPlacement)
            #expect(placement.sourceFrame == .cadWorldYUp)
            #expect(placement.rotationRows == [1,0,0,0,0,-1,0,1,0])
            let childLocation = try await library.resolve(childID),printing = childLocation.url.appendingPathComponent("Printing")
            let disk = PrintProjectDisk(root:printing)
            #expect(try await disk.meshAsset(provenance.geometryAsset) == sourceMesh,
                "The exact captured CAD world mesh must remain independently recoverable.")
            let placedMesh = try await disk.mesh(childDocument)
            #expect(placedMesh == (try placement.applying(to:sourceMesh)))
            #expect(placedMesh.sha256 == placement.geometrySHA256)
            #expect(placedMesh.triangleCount == sourceMesh.triangleCount)
            #expect(childDocument.meshAsset == placement.geometryAsset)
            var low = [Float](repeating:.infinity,count:3),high = [Float](repeating:-.infinity,count:3)
            for i in stride(from:0,to:placedMesh.positions.count,by:3) {
                for axis in 0..<3 { low[axis] = min(low[axis],placedMesh.positions[i+axis]);high[axis] = max(high[axis],placedMesh.positions[i+axis]) }
            }
            #expect(low == [-2,-2,0] && high == [2,2,2])
            _ = try PrintInput(mesh:placedMesh,preset:childDocument.preset)
            #expect(childDocument.objects?.count == 1 && childDocument.meshAsset != nil)
            #expect(!FileManager.default.fileExists(atPath:location.url.appendingPathComponent("Manufacturing/draft.json").path))
            context.toolCallID = "edit-returned-print-child"
            _ = try await invoke("studio.edit",["projectID":childID.uuidString,"expectedRevision":child.revision,
                "operationsJSON":"[{\"action\":\"settings\",\"layerHeight\":0.25}]"],context)
            context.toolCallID = "slice-returned-print-child"
            let sliced = try json(try await invoke("studio.run",["projectID":childID.uuidString,"action":"slice"],context))
            let saved = try await disk.load()
            #expect(saved.layerHeight == 0.25 && saved.resultLayerCount == 8)
            #expect(try await disk.mesh(saved).sha256 == placement.geometrySHA256)
            #expect(try await disk.meshAsset(provenance.geometryAsset) == sourceMesh)
            #expect(saved.sourceSnapshot?.initialPlacement == placement)
            switch document.nativePrintGeometrySnapshot(expectedRevision:document.revision,expectedChangeCount:document.exchangeChangeCount,
                expectedContentSHA256:document.contentSHA256) {
            case .success(let bytes,_,_): #expect(try PrintMesh(binarySTL:bytes) == sourceMesh)
            default: Issue.record("Preparing and slicing a copy changed its CAD source")
            }
            let resultFile = try #require(try await disk.resultURL(saved)),bytes = try Data(contentsOf:resultFile)
            #expect(!bytes.isEmpty && StudioToolOutput.hash(bytes) == (sliced["sha256"] as? String))
            let beforeReplay = try Data(contentsOf:printing.appendingPathComponent("print.json"))
            let listedBefore = try json(try await invoke("studio.list",[:],context))
            let boundBefore = Set((listedBefore["works"] as? [[String:Any]] ?? []).compactMap { $0["id"] as? String })
            let replay = try json(try await invoke("studio.machining",args,approved))
            #expect(((replay["record"] as? [String:Any])?["id"] as? String) == childID.uuidString)
            #expect(try Data(contentsOf:printing.appendingPathComponent("print.json")) == beforeReplay,"Replay must retain settings and saved slicing output")
            let listedAfter = try json(try await invoke("studio.list",[:],context))
            #expect(Set((listedAfter["works"] as? [[String:Any]] ?? []).compactMap { $0["id"] as? String }) == boundBefore)
            var different = args;different["title"] = "Different intent for the same approved call"
            do { _ = try await invoke("studio.machining",different,approved);Issue.record("An approved call was rebound to another print intent") }
            catch PersonalContentError.changedDocument {}
            #expect(try Data(contentsOf:printing.appendingPathComponent("print.json")) == beforeReplay)
            await expectForeignDenial("studio.read",["projectID":childID.uuidString],other)
            await expectForeignDenial("studio.edit",["projectID":childID.uuidString,"expectedRevision":String(saved.revision),
                "operationsJSON":"[{\"action\":\"settings\",\"layerHeight\":0.5}]"],other)
            #expect(try Data(contentsOf:printing.appendingPathComponent("print.json")) == beforeReplay)
            await expectForeignDenial("studio.machining",["projectID":id.uuidString,"action":"inspect"],other)
        }
    }
}
#endif
