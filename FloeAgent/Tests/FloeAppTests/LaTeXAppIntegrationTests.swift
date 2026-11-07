// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && DEBUG
import XCTest
import UIKit
import FloeCore
import FloeModels
import FloePersistence
import FloeNotes
import FloeSecurity
import FloeTools
import FloeLaTeXCore
import FloeLaTeXUI
import FloeLaTeXEngine
import FloeLaTeXHostAdapter
@testable import FloeApp

@MainActor final class LaTeXAppIntegrationTests:XCTestCase {
    func testSpaceOriginalAndImportedZIPKeepNativeIdentity() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let service=PersonalContentService(root:root.appendingPathComponent("Library"))
        let record=try await service.createLaTeX(title:"Synthetic paper",templateID:"chinese",folders:["Papers"])
        let location=try await service.library().resolve(record.id)
        let store=try LaTeXProjectStore(root:location.url.appendingPathComponent("LaTeX")),manifest=try await store.manifest()
        XCTAssertEqual(manifest.id,record.id);XCTAssertEqual(manifest.owner,.init(kind:.space,id:record.id))
        let manifestURL=store.root.appendingPathComponent("LaTeXProject.json"),savedManifest=try Data(contentsOf:manifestURL)
        let preview=try await PersonalContentPreviewService().request(for:record,contentService:service,maximumPixelSize:160)
        let artifact=try await preview.produce()
        guard case .text(let text)=artifact.content else {return XCTFail("An uncompiled source preview must remain readable")}
        XCTAssertTrue(text.contains("documentclass"));XCTAssertEqual(savedManifest,try Data(contentsOf:manifestURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath:store.root.appendingPathComponent("Builds").path))
        let snapshot=try await store.snapshot(),zip=root.appendingPathComponent("Source.zip")
        try LaTeXProjectArchive.export(snapshot,to:zip);try await store.releaseSnapshot(snapshot)
        let imported=try await service.importLaTeX(zip,folders:[]),importLocation=try await service.library().resolve(imported.id)
        let importedStore=try LaTeXProjectStore(root:importLocation.url.appendingPathComponent("LaTeX")),copied=try await importedStore.manifest()
        XCTAssertNotEqual(copied.id,manifest.id);XCTAssertEqual(copied.owner,.init(kind:.space,id:imported.id))
        let old=try await store.read(manifest.mainFile),new=try await importedStore.read(copied.mainFile)
        XCTAssertEqual(old,new)
    }
    func testPreparationIsObservableAndCanBeCancelledBeforeBuildExists() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let template=try XCTUnwrap(LaTeXTemplates.all.first),store=try LaTeXProjectStore.create(root:root,id:UUID(),owner:.init(kind:.task,id:UUID()),title:"Synthetic pending",files:template.files)
        let builds=try LaTeXBuildService(cacheRoot:root.appendingPathComponent("Cache"))
        let session=LaTeXEditorSession(store:store,builds:builds,typesetAction:{_,_,_ in
            while true {try await Task.sleep(for:.milliseconds(10))}
        })
        await session.load();session.update(session.source+"\nSaved draft before cancellation.\n")
        let task=Task {await session.compile()}
        for _ in 0..<100 {if session.preparingTypeset {break};await Task.yield()}
        XCTAssertTrue(session.isBuilding);XCTAssertNil(session.build)
        session.stop();await task.value
        XCTAssertFalse(session.isBuilding);XCTAssertNil(session.error)
        let manifest=try await store.manifest();XCTAssertEqual(manifest.revision,1)
        let saved=try await store.text(manifest.mainFile);XCTAssertTrue(saved.contains("Saved draft before cancellation."))
    }
    func testActualNotesPinAndNativeApprovalRecheckRevokedGrant() async throws {
        let app=try await appQualificationEnvironment(),host=try await app.latexComposition.host()
        let notes=try await NotesRepository.shared.store(),note=try await notes.create(NoteDocument(title:"QA-LaTeX-"+UUID().uuidString.prefix(8)))
        let original=try await app.latexComposition.createNative(owner:.init(kind:.note,id:note.id),title:"Synthetic scoped original",templateID:"article")
        let taskID=try await app.latexComposition.assistantForNativeOriginal(original),runID=UUID()
        let scratch=try NotesRepository.assistantWorkspace(conversationID:taskID)
        let pin=try await app.taskExecutionEnvironments.resolveNotesBinding(conversationID:taskID,runID:runID,root:scratch)
        XCTAssertEqual(pin.target.backend,.linuxVM)
        try await app.runStore.saveRun(.init(id:runID,conversationID:taskID,state:"executing",goal:"Scoped LaTeX contract",startedAt:Date(),executionBinding:pin))
        let base=ToolContext(runID:runID,scope:.local,allowedToolNames:LaTeXHostTools.names.union(["exec.shell"]),workspaceRootURL:scratch,
            serviceStorePaths:app.latexComposition.typedServiceStorePaths,cancellation:CancellationToken(),environmentID:pin.target.environmentID,
            executionBindingGeneration:pin.generation,conversationID:taskID,frozenEffectiveCatalogNames:LaTeXHostTools.names.union(["exec.shell"]))
        let lease=try await ToolEnvironmentRouting.shared.acquire(base)
        do {
            let runner=try XCTUnwrap(host.registry.runner(named:"latex.edit")),before=try await LaTeXProjectStore(root:original.root).manifest()
            let data=try JSONSerialization.data(withJSONObject:["projectID":original.id.uuidString,"expectedRevision":before.revision,"mutationID":UUID().uuidString,
                "operations":[["operation":"write","path":"main.tex","text":"Should remain rejected"]]],options:[.sortedKeys])
            var context=lease.context
            context.executionToolName="latex.edit";context.toolCallID="latex.native.contract";context.toolIdempotencyKey="latex.native.contract"
            var call=try ToolCall(id:context.toolCallID!,toolName:"latex.edit",argumentsJSON:data,scope:.local);call.idempotencyKey=context.toolIdempotencyKey
            let action=ProposedAction(toolCall:call,riskLabels:Set(runner.descriptor.riskLabels.map(\.rawValue)),userGoal:"Synthetic scoped edit",hostAndPathScope:.local)
            let validation=context
            let grant=try await app.conversationCenter.recordNativeWorkbenchApproval(action,context:context,descriptor:runner.descriptor,projectID:original.id,
                requestID:call.id,payloadDigest:RuntimeAuthorityDigest.payloadDigest(data),allowedToolNames:LaTeXHostTools.names,requiredPurpose:.notes,validateOriginal:{
                    _ = try await app.latexComposition.authorizeOriginal(original.id,context:validation,editing:true)
                })
            let savedRun=try await app.runStore.run(id:runID);XCTAssertNotNil(savedRun?.executionBinding)
            context.approvalGrantID=grant.id
            let target=RuntimeAuthorityDigest.canonicalTarget(for:call,descriptor:runner.descriptor,workspaceRootURL:scratch,serviceStorePaths:context.serviceStorePaths)
            let binding=context.runtimeAuthorityBinding(toolName:"latex.edit",operation:"apply",canonicalTarget:target,baseRevision:RuntimeAuthorityDigest.baseRevision(in:data),payloadDigest:RuntimeAuthorityDigest.payloadDigest(data))
            context.runtimeAuthority=await RuntimeAuthorityStore.shared.issue(.init(runID:runID,taskID:taskID,environmentBinding:binding.environmentBinding,
                canonicalTarget:target,toolName:"latex.edit",operation:"apply",operationID:call.id,idempotencyKey:call.idempotencyKey,baseRevision:binding.baseRevision,
                payloadDigest:binding.payloadDigest,approvalGrantID:grant.id))
            try await notes.revokeAccess(conversationID:taskID,documentID:note.id)
            do {_ = try await runner.run(data,context);XCTFail("A revoked Notes grant must prevent the edit") }catch {}
            let after=try await LaTeXProjectStore(root:original.root).manifest();XCTAssertEqual(after.revision,before.revision)
            let stillRegistered=try await app.latexComposition.owned(by:.init(kind:.note,id:note.id))
            XCTAssertTrue(stillRegistered.contains{$0.id==original.id})
            let task=try await app.conversationStore.conversation(id:taskID);XCTAssertEqual(task?.purpose,.notes)
        } catch {
            await lease.finish();try? await app.runStore.updateRunState(id:runID,state:"failed",endedAt:Date())
            let current=try await notes.document(note.id);_ = try? await notes.setTrashed(note.id,expectedRevision:current.revision,trashed:true)
            throw error
        }
        _ = await RuntimeAuthorityStore.shared.revoke(runID:runID)
        try await app.runStore.updateRunState(id:runID,state:"completed",endedAt:Date());await lease.finish()
        let current=try await notes.document(note.id);_ = try await notes.setTrashed(note.id,expectedRevision:current.revision,trashed:true)
    }
}
#endif
