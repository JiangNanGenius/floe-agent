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
import FloeExecution
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
    func testReopenedEditorObservesAndStopsTheSameNativePreparation() async throws {
        let app=try await appQualificationEnvironment(),host=try await app.latexComposition.host()
        let notes=try await NotesRepository.shared.store(),note=try await notes.create(NoteDocument(title:"QA-LaTeX-reopen-"+UUID().uuidString.prefix(8)))
        let original=try await app.latexComposition.createNative(owner:.init(kind:.note,id:note.id),title:"Synthetic preparation reopen",templateID:"article")
        let shell=try XCTUnwrap(host.registry.runner(named:"exec.shell")),probe=LaTeXPreparationProbeGate()
        var controlled=shell
        controlled.run={_,context in await probe.waitForStop(context)}
        host.registry.register(controlled)
        defer {host.registry.register(shell)}
        let first=try await LaTeXProjectSession.open(id:original.id,composition:app.latexComposition)
        let preparation=Task {await first.prepareToolchain(profile:nil)}
        do {
            let deadline=Date().addingTimeInterval(10)
            while await probe.runID==nil,Date()<deadline {try await Task.sleep(for:.milliseconds(10))}
            let observedRunID=await probe.runID
            let runID=try XCTUnwrap(observedRunID,"The real native approval and environment binding must reach the controlled probe")
            let reopened=try await LaTeXProjectSession.open(id:original.id,composition:app.latexComposition)
            XCTAssertFalse(first.editor === reopened.editor)
            XCTAssertTrue(reopened.editor.isBuilding);XCTAssertNotNil(reopened.workbenchOperation)
            XCTAssertNil(reopened.editor.build)
            // This is the newly opened editor's Stop action, not the task or
            // session that originally started preparation.
            reopened.workbenchOperation?.stop()
            await preparation.value
            XCTAssertNil(reopened.workbenchOperation);XCTAssertFalse(reopened.editor.isBuilding)
            XCTAssertNil(first.editor.error)
            let run=try await app.runStore.run(id:runID)
            XCTAssertEqual(run?.state,"cancelled");XCTAssertNotNil(run?.endedAt)
        } catch {
            first.cancelPreparation();await preparation.value
            let current=try await notes.document(note.id);_ = try? await notes.setTrashed(note.id,expectedRevision:current.revision,trashed:true)
            throw error
        }
        let current=try await notes.document(note.id);_ = try await notes.setTrashed(note.id,expectedRevision:current.revision,trashed:true)
    }
    /// The processor is controlled, but submission, cancellation, GRDB job
    /// persistence, native approval and owner settlement are the real App
    /// services. This does not install packages or stand in for a PDF run.
    func testNativePreparationStopDrainsDurableJobBeforeReleasingOwner() async throws {
        let app=try await appQualificationEnvironment(),host=try await app.latexComposition.host()
        let jobs=try XCTUnwrap(app.backgroundJobService)
        let notes=try await NotesRepository.shared.store(),note=try await notes.create(NoteDocument(title:"QA-LaTeX-job-stop-"+UUID().uuidString.prefix(8)))
        let original=try await app.latexComposition.createNative(owner:.init(kind:.note,id:note.id),title:"Synthetic durable preparation stop",templateID:"article")
        let taskID=try await app.latexComposition.assistantForNativeOriginal(original)
        let shell=try XCTUnwrap(host.registry.runner(named:"exec.shell")),probe=LaTeXPreparationProbeGate()
        var controlled=shell
        controlled.run={_,context in await probe.waitForStop(context)}
        host.registry.register(controlled)
        defer {host.registry.register(shell)}
        let first=try await LaTeXProjectSession.open(id:original.id,composition:app.latexComposition)
        // The install branch uses real BackgroundJobService rather than the
        // direct short-command path exercised by the older reopen test.
        let preparation=Task {await first.prepareToolchain(profile:"standard")}
        var submittedID:UUID?
        do {
            let startedDeadline=Date().addingTimeInterval(10)
            while await probe.runID==nil,Date()<startedDeadline {try await Task.sleep(for:.milliseconds(10))}
            let observedRunID=await probe.runID,runID=try XCTUnwrap(observedRunID)
            let records=try await BackgroundJobStore(database:app.database).jobs(conversationID:taskID)
            let submitted=try XCTUnwrap(records.first{$0.runID==runID && $0.targetTool=="exec.shell"})
            submittedID=submitted.id
            let savedRun=try await app.runStore.run(id:runID)
            XCTAssertEqual(submitted.environmentID,savedRun?.executionBinding?.target.environmentID)
            XCTAssertEqual(submitted.conversationID,taskID)
            let reopened=try await LaTeXProjectSession.open(id:original.id,composition:app.latexComposition)
            XCTAssertNotNil(reopened.workbenchOperation)
            // Stop on the initiating editor cancels its Swift preparation
            // waiter too. The service must still request/drain the real job.
            first.workbenchOperation?.stop()
            var stoppedByEditor=false
            let stoppedDeadline=Date().addingTimeInterval(10)
            while Date()<stoppedDeadline {
                if let current=try await jobs.job(id:submitted.id),current.state.isTerminal {stoppedByEditor=true;break}
                try await Task.sleep(for:.milliseconds(20))
            }
            // Cleanup uses a fresh XCTest task if the regression recurs; it
            // cannot turn the assertion into a successful editor Stop.
            if !stoppedByEditor {_ = try await jobs.cancel(id:submitted.id)}
            await preparation.value
            XCTAssertTrue(stoppedByEditor,"Editor Stop must reach the durable job without external cancellation")
            let terminal=try await jobs.job(id:submitted.id)
            XCTAssertEqual(terminal?.state,.cancelled)
            XCTAssertTrue(terminal?.resultSummary?.hasPrefix("exit=130 ") == true)
            XCTAssertNotNil(terminal?.completedAt)
            let run=try await app.runStore.run(id:runID)
            XCTAssertEqual(run?.state,"cancelled");XCTAssertNotNil(run?.endedAt)
            XCTAssertNil(app.latexComposition.nativeRuntime.operations[original.id])
            XCTAssertNil(reopened.workbenchOperation);XCTAssertNil(first.editor.error)
        } catch {
            first.cancelPreparation()
            if let submittedID {_ = try? await jobs.cancel(id:submittedID)}
            await preparation.value
            let current=try await notes.document(note.id);_ = try? await notes.setTrashed(note.id,expectedRevision:current.revision,trashed:true)
            throw error
        }
        let current=try await notes.document(note.id);_ = try await notes.setTrashed(note.id,expectedRevision:current.revision,trashed:true)
    }

    func testReopenedEditorReceivesNativePreparationFailure() async throws {
        let app=try await appQualificationEnvironment(),host=try await app.latexComposition.host()
        let notes=try await NotesRepository.shared.store(),note=try await notes.create(NoteDocument(title:"QA-LaTeX-failure-"+UUID().uuidString.prefix(8)))
        let original=try await app.latexComposition.createNative(owner:.init(kind:.note,id:note.id),title:"Synthetic preparation failure",templateID:"article")
        let shell=try XCTUnwrap(host.registry.runner(named:"exec.shell")),probe=LaTeXPreparationFailureGate()
        var controlled=shell
        controlled.run={_,context in await probe.waitForFailure(context)}
        host.registry.register(controlled)
        defer {host.registry.register(shell)}
        let first=try await LaTeXProjectSession.open(id:original.id,composition:app.latexComposition)
        let preparation=Task {await first.prepareToolchain(profile:nil)}
        do {
            let deadline=Date().addingTimeInterval(10)
            while await probe.runID==nil,Date()<deadline {try await Task.sleep(for:.milliseconds(10))}
            let observed=await probe.runID
            let runID=try XCTUnwrap(observed)
            let reopened=try await LaTeXProjectSession.open(id:original.id,composition:app.latexComposition)
            XCTAssertFalse(first.editor === reopened.editor)
            XCTAssertNotNil(reopened.workbenchOperation)
            await probe.fail();await preparation.value
            XCTAssertNil(reopened.workbenchOperation)
            XCTAssertEqual(reopened.nativeFailureID,runID)
            reopened.presentNativeFailure()
            XCTAssertFalse(reopened.editor.error?.isEmpty ?? true)
            let again=try await LaTeXProjectSession.open(id:original.id,composition:app.latexComposition)
            again.presentNativeFailure()
            XCTAssertEqual(again.editor.error,reopened.editor.error)
            let run=try await app.runStore.run(id:runID)
            XCTAssertEqual(run?.state,"failed");XCTAssertNotNil(run?.endedAt)
            let events=try await app.runStore.events(runID:runID)
            let failures=try events.filter{$0.kind == .error}.map {
                try JSONDecoder().decode([String:String].self,from:Data($0.payloadJSON.utf8))
            }
            XCTAssertTrue(failures.contains{$0["source"]=="latex.native" && $0["projectID"]==original.id.uuidString && $0["message"]==reopened.editor.error})
        } catch {
            first.cancelPreparation();await probe.fail();await preparation.value
            let current=try await notes.document(note.id);_ = try? await notes.setTrashed(note.id,expectedRevision:current.revision,trashed:true)
            throw error
        }
        let current=try await notes.document(note.id);_ = try await notes.setTrashed(note.id,expectedRevision:current.revision,trashed:true)
    }

    /// Opt-in real App service regression. No environment is created, selected
    /// afresh or deleted, and no process env is supplied to exec.shell.
    func testOrdinaryShellDefaultsUseRetainedProjectEnvironment() async throws {
        let input=ProcessInfo.processInfo.environment
        guard input["FLOE_LATEX_LIVE_DEFAULTS"]=="1" else {throw XCTSkip("Select explicitly with the retained synthetic fixture")}
        let taskID=try XCTUnwrap(input["FLOE_LATEX_QA_TASK_ID"].flatMap(UUID.init(uuidString:)))
        let projectID=try XCTUnwrap(input["FLOE_LATEX_QA_PROJECT_ID"].flatMap(UUID.init(uuidString:)))
        let expectedEnvironmentID=try XCTUnwrap(input["FLOE_LATEX_QA_ENVIRONMENT_ID"])
        let app=try await appQualificationEnvironment()
        func require(_ value:Bool,_ message:String)throws {if !value {throw FloeError.validationFailed(message)}}
        guard let task=try await app.conversationStore.conversation(id:taskID) else {throw PersonalContentError.missingDocument}
        try require(task.purpose == .ordinary,"Retained QA task must be ordinary")
        let priorRuns=try await app.runStore.runs(conversationID:taskID)
        try require(priorRuns.allSatisfy{$0.endedAt != nil},"Do not overlap, adopt or revive an existing run")
        let bindingStore=TaskExecutionBindingStore(database:app.database)
        let savedPin=try await bindingStore.binding(conversationID:taskID)
        let priorPin=try XCTUnwrap(savedPin)
        try require(priorPin.target.backend == .linuxVM && priorPin.target.environmentID==expectedEnvironmentID,"Retained Linux pin changed")
        let workspaces=SQLiteWorkspaceStore(database:app.database)
        let savedWorkspaceID=try await workspaces.workspaceID(conversationID:taskID)
        let workspaceID=try XCTUnwrap(savedWorkspaceID)
        let savedWorkspace=try await workspaces.workspace(id:workspaceID)
        let workspace=try XCTUnwrap(savedWorkspace)
        let policy=try await workspaces.taskPolicy(conversationID:taskID)
        try require(policy.allowedToolNames?.contains("exec.shell") != false,"Task policy does not permit ordinary exec.shell")
        let root=try await app.workspaceCenter.acquireTaskRoot(workspace,conversationID:taskID)
        let runID=UUID(),cancellation=CancellationToken()
        let evidence=URL.applicationSupportDirectory.appendingPathComponent("FloeAgent/QualificationEvidence/LaTeXDefaults/"+runID.uuidString,isDirectory:true)
        var facts=["kind":"real-App-ordinary-exec-shell-not-model-not-UI","runID":runID.uuidString,"taskID":taskID.uuidString,"projectID":projectID.uuidString,"environmentID":expectedEnvironmentID,"callerEnvironmentOverride":"false"]
        func retain(_ phase:String)throws {
            facts["phase"]=phase
            try FileManager.default.createDirectory(at:evidence,withIntermediateDirectories:true)
            try JSONEncoder().encode(facts).write(to:evidence.appendingPathComponent("receipt.json"),options:.atomic)
        }
        var layers:ToolEnvironmentLease?,original:LaTeXHostProject?
        var saved=false,invoked=false,stopped=false
        do {
            let pin=try await app.taskExecutionEnvironments.resolveBinding(conversationID:taskID,runID:runID,root:root.url,workspace:workspace)
            try require(pin.target==priorPin.target && pin.generation==priorPin.generation,"Normal resolution must reuse the exact retained binding")
            let environmentIDs=Set(await app.environmentRegistry.all().map(\.id))
            try await app.runStore.saveRun(.init(id:runID,conversationID:taskID,state:"executing",goal:"Check ordinary Linux process defaults",startedAt:Date(),executionBinding:pin))
            saved=true
            let base=ToolContext(runID:runID,scope:.local,allowedToolNames:["exec.shell"],workspaceRootURL:root.url,
                serviceStorePaths:app.latexComposition.typedServiceStorePaths,cancellation:cancellation,environmentID:pin.target.environmentID,
                executionBindingGeneration:pin.generation,conversationID:taskID,clientSessionID:"latex.defaults.qa."+runID.uuidString.lowercased(),frozenEffectiveCatalogNames:["exec.shell"])
            layers=try await ToolEnvironmentRouting.shared.acquire(base)
            let lease=try XCTUnwrap(layers)
            original=try await app.latexComposition.acquire(projectID,context:lease.context,editing:false)
            let access=try XCTUnwrap(original),manifest=try await access.store.manifest()
            try require(manifest.id==projectID && manifest.owner == .init(kind:.space,id:projectID),"Retained original identity changed")
            let script=#"""
            set -eu
            # Deliberately no export, env argument, activation or directory override.
            # Invoke with ordinary exec.shell in the existing saved QA task/environment.
            test "${HOME-}" = /floe/env/home
            test "${TMPDIR-}" = /floe/env/tmp
            test "${TMP-}" = /floe/env/tmp
            test "${TEMP-}" = /floe/env/tmp
            test "${LANG-}" = C.UTF-8
            test "${LC_ALL-}" = C.UTF-8
            test -d "$HOME"
            test -w "$HOME"
            test -d "$TMPDIR"
            test -w "$TMPDIR"
            qa_latex_probe_dir=$(mktemp -d)
            case "$qa_latex_probe_dir" in "$TMPDIR"/*) ;; *) exit 65 ;; esac
            trap 'rm -f "$qa_latex_probe_dir/defaults.txt"; rmdir "$qa_latex_probe_dir"' EXIT HUP INT TERM
            printf 'FLOE_ORDINARY_DEFAULTS' > "$qa_latex_probe_dir/defaults.txt"
            qa_latex_python_path=$(command -v python3)
            qa_latex_node_path=$(command -v node || true)
            python3 - "$qa_latex_probe_dir" "$qa_latex_python_path" "$qa_latex_node_path" <<'FLOE_DEFAULTS_PY'
            import base64,json,os,pathlib,sys
            directory,python_path,node_path=sys.argv[1:]
            selected={key:os.environ.get(key) for key in ('HOME','TMPDIR','TMP','TEMP','LANG','LC_ALL','PATH')}
            assert all(not value or ('/Users/' not in value and '/Applications/' not in value) for value in selected.values()),'native host path reached Linux defaults'
            assert pathlib.Path(directory,'defaults.txt').read_text()=='FLOE_ORDINARY_DEFAULTS'
            python_prefix='/floe/env/python/venv/bin'
            node_prefix='/floe/env/usr/bin'
            parts=selected['PATH'].split(':')
            if os.access(python_prefix+'/python3',os.X_OK):
                assert python_path==python_prefix+'/python3','Python activation was replaced'
            if os.path.isdir(node_prefix):
                assert node_prefix in parts,'Node prefix activation was replaced'
                if '/usr/bin' in parts:assert parts.index(node_prefix)<parts.index('/usr/bin')
            result={'defaults':selected,'pythonCommand':python_path,'pythonExecutable':sys.executable,'nodeCommand':node_path,'mktempDirectory':directory,'readWriteVerified':True,'cwd':os.getcwd()}
            print('FLOE_SHELL_DEFAULTS '+base64.b64encode(json.dumps(result,sort_keys=True).encode()).decode(),flush=True)
            FLOE_DEFAULTS_PY
            rm "$qa_latex_probe_dir/defaults.txt"
            rmdir "$qa_latex_probe_dir"
            trap - EXIT HUP INT TERM
            test ! -e "$qa_latex_probe_dir"
            printf 'FLOE_SHELL_DEFAULTS_CLEANUP=1\n'
            """#
            let data=try JSONSerialization.data(withJSONObject:["script":script,"cwd":".","maxOutputBytes":8192])
            let parameters=try JSONSerialization.jsonObject(with:data) as! [String:Any]
            try require(parameters["env"]==nil && parameters["environment"]==nil,"Probe must not override process defaults")
            let runner=try XCTUnwrap(ToolRunnerRegistry.shared.runner(named:"exec.shell"))
            try require(runner.isAvailable(),"Registered shell tool is unavailable")
            try runner.validateArguments(data)
            if let preflight=runner.preflightSubmission {try await preflight(data,root.url)}
            _ = try await app.latexComposition.authorizeOriginal(projectID,context:lease.context,editing:false)
            let callID="qa.defaults."+runID.uuidString.lowercased()
            var context=lease.context
            context.executionToolName="exec.shell";context.toolCallID=callID;context.toolIdempotencyKey=callID
            facts["bindingGeneration"]=String(pin.generation);try retain("validated-before-execution")
            invoked=true
            let output=try await runner.execute(argumentsJSON:data,context:context)
            stopped = !output.outcomeUnknown && output.exitStatus != nil
            let text=output.capturedOutput ?? output.summary
            facts["workerStopped"]=String(stopped);facts["exitStatus"]=output.exitStatus.map{String($0)} ?? "unknown";facts["output"]=String(text.prefix(8192))
            try retain("returned")
            try require(stopped,"Processor exit is unconfirmed; retain this run and its real leases")
            try require(output.exitStatus==0 && !output.capturedOutputTruncated,"Ordinary defaults probe failed; original output retained")
            let line=try XCTUnwrap(text.split(separator:"\n").first{$0.hasPrefix("FLOE_SHELL_DEFAULTS ")})
            let body=try XCTUnwrap(Data(base64Encoded:String(line.dropFirst("FLOE_SHELL_DEFAULTS ".count))))
            let result=try XCTUnwrap(try JSONSerialization.jsonObject(with:body) as? [String:Any])
            try require(result["readWriteVerified"] as? Bool == true && text.contains("FLOE_SHELL_DEFAULTS_CLEANUP=1"),"Temporary file cleanup/readback is unverified")
            _ = try await app.latexComposition.authorizeOriginal(projectID,context:lease.context,editing:false)
            let afterPin=try await bindingStore.binding(conversationID:taskID)
            try require(afterPin?.target==priorPin.target && afterPin?.generation==priorPin.generation,"Probe changed the task pin")
            try require(Set(await app.environmentRegistry.all().map(\.id))==environmentIDs,"Probe created or deleted an environment")
            try await app.runStore.updateRunState(id:runID,state:"completed",endedAt:Date())
            await lease.finish();layers=nil;original=nil;root.release()
            try retain("completed-and-leases-released")
            print("FLOE_LATEX_DEFAULTS_EVIDENCE="+evidence.path)
        } catch {
            facts["failure"]=String(error.localizedDescription.prefix(1200))
            if !invoked || stopped {
                if saved {try await app.runStore.updateRunState(id:runID,state:"failed",endedAt:Date())}
                if let layers {await layers.finish()};original=nil;root.release()
                try? retain("failed-with-confirmed-stop")
            } else {
                if saved {try? await app.runStore.updateRunState(id:runID,state:"waitingRecovery",endedAt:nil)}
                LaTeXDefaultsProbeOwners.unconfirmed[runID] = .init(root:root,layers:layers,original:original,cancellation:cancellation)
                try? retain("unconfirmed-stop-owner-retained")
            }
            print("FLOE_LATEX_DEFAULTS_FAILURE_EVIDENCE="+evidence.path)
            throw error
        }
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

private actor LaTeXPreparationProbeGate {
    private(set) var runID:UUID?
    func waitForStop(_ context:ToolContext) async -> ToolExecutionOutput {
        runID=context.runID
        while !context.cancellation.isCancelled {try? await Task.sleep(for:.milliseconds(10))}
        // A controlled processor exit makes cancellation deterministic; no
        // actual Linux command, package install or PDF result is simulated.
        return ToolExecutionOutput(summary:"exit=130 status=cancelled",fullOutputSHA256:"controlled-stop",exitStatus:130)
    }
}

private actor LaTeXPreparationFailureGate {
    private(set) var runID:UUID?
    private var released=false
    func fail() {released=true}
    func waitForFailure(_ context:ToolContext) async -> ToolExecutionOutput {
        runID=context.runID
        while !released && !context.cancellation.isCancelled {try? await Task.sleep(for:.milliseconds(10))}
        // Controlled known processor failure, no Linux execution or PDF stub.
        return ToolExecutionOutput(summary:"exit=1 status=synthetic-preparation-failure",fullOutputSHA256:"controlled-failure",exitStatus:1)
    }
}

@MainActor private enum LaTeXDefaultsProbeOwners {
    struct Owner {
        let root:WorkspaceCenter.TaskRootLease
        let layers:ToolEnvironmentLease?
        let original:LaTeXHostProject?
        let cancellation:CancellationToken
    }
    static var unconfirmed=[UUID:Owner]()
}
#endif

// SPDX-License-Identifier: MPL-2.0
// App-hosted retained-fixture qualification; opt in explicitly.
// The provider is scripted. ConversationRunService, AutomaticApprovalPolicy,
// authority issuance, registered LaTeX tools, SQLite and Linux are production.
// No tool output, approval grant, runtime authority or PDF is hand-seeded.
#if canImport(UIKit) && DEBUG
import XCTest
import FloeCore
import FloeModels
import FloeTools
import FloeSecurity
import FloeProviders
import FloeAgentRuntime
import FloePersistence
import FloeLaTeXCore
import FloeLaTeXEngine
import FloeLaTeXHostAdapter
import FloeTestSupport
@testable import FloeApp

@MainActor final class LaTeXModelRuntimeLiveTests:XCTestCase {
    func testRetainedProjectEditUsesConversationRunServiceAuthority() async throws {
        let fixture=try await retainedFixture()
        let before=try await fixture.store.manifest(),source=try await fixture.store.text(before.mainFile)
        let marker="QA-MODEL-RUNTIME-"+UUID().uuidString
        let edited=source+"\n% "+marker+"\n"
        let runID=try await execute(fixture,tool:"latex.edit",arguments:[
            "projectID":fixture.projectID.uuidString,"expectedRevision":before.revision,
            "mutationID":UUID().uuidString,
            "operations":[["operation":"write","path":before.mainFile,"text":edited]]
        ])
        let after=try await fixture.store.manifest(),saved=try await fixture.store.text(after.mainFile)
        XCTAssertEqual(after.revision,before.revision+1)
        XCTAssertEqual(saved,edited)
        XCTAssertEqual(after.owner,before.owner)
        let history=try await fixture.store.history()
        XCTAssertTrue(history.contains{$0.manifest.revision==after.revision && $0.origin=="ai:"+runID.uuidString})
    }

    // Run only after the native UI has restored the SAME retained toolchain.
    // A missing engine or unsuccessful build is a failure, never a fake PDF.
    func testRetainedProjectTypesetUsesConversationRunServiceAuthority() async throws {
        let fixture=try await retainedFixture()
        let before=try await fixture.store.manifest()
        let runID=try await execute(fixture,tool:"latex.typeset",arguments:[
            "projectID":fixture.projectID.uuidString,"action":"start",
            "expectedRevision":before.revision,"offline":true,"wait":true
        ])
        let host=try await fixture.app.latexComposition.host()
        let history=try await host.builds.history(store:fixture.store)
        let record=try XCTUnwrap(history.first{$0.executionOwner?.runID==runID})
        XCTAssertTrue(record.succeeded)
        XCTAssertEqual(record.workerStopped,true)
        XCTAssertEqual(record.revision,before.revision)
        XCTAssertEqual(record.executionOwner?.taskID,fixture.taskID)
        XCTAssertEqual(record.executionOwner?.environmentID,fixture.environmentID)
        XCTAssertNotNil(record.pdfRelativePath)
        XCTAssertNotNil(record.synctexRelativePath)
        let after=try await fixture.store.manifest()
        XCTAssertEqual(after.revision,before.revision)
    }

    private struct Fixture {
        let app:AppEnvironment
        let taskID:UUID
        let projectID:UUID
        let environmentID:String
        let store:LaTeXProjectStore
    }

    private func retainedFixture() async throws -> Fixture {
        let input=ProcessInfo.processInfo.environment
        guard input["FLOE_LATEX_LIVE_MODEL_RUNTIME"]=="1" else {
            throw XCTSkip("Opt in explicitly to the retained synthetic project and task")
        }
        let taskID=try XCTUnwrap(input["FLOE_LATEX_QA_TASK_ID"].flatMap(UUID.init(uuidString:)))
        let projectID=try XCTUnwrap(input["FLOE_LATEX_QA_PROJECT_ID"].flatMap(UUID.init(uuidString:)))
        let environmentID=try XCTUnwrap(input["FLOE_LATEX_QA_ENVIRONMENT_ID"])
        let app=try await appQualificationEnvironment()
        _ = try await app.latexComposition.host()
        let savedTask=try await app.conversationStore.conversation(id:taskID)
        let task=try XCTUnwrap(savedTask)
        try require(task.purpose == .ordinary,"Use only the retained ordinary QA assistant")
        let runs=try await app.runStore.runs(conversationID:taskID)
        try require(runs.allSatisfy{$0.endedAt != nil},"Existing QA run is not terminal")
        let original=try await app.latexComposition.original(projectID)
        try require(original.owner == .init(kind:.space,id:projectID),"Original ownership changed")
        return Fixture(app:app,taskID:taskID,projectID:projectID,environmentID:environmentID,
            store:try LaTeXProjectStore(root:original.root))
    }

    private func execute(_ fixture:Fixture,tool:String,arguments:[String:Any]) async throws -> UUID {
        let app=fixture.app,runID=UUID()
        let pinStore=TaskExecutionBindingStore(database:app.database)
        let savedPin=try await pinStore.binding(conversationID:fixture.taskID)
        let priorPin=try XCTUnwrap(savedPin)
        try require(priorPin.target.backend == .linuxVM && priorPin.target.environmentID==fixture.environmentID,"Retained Linux pin changed")
        let workspaces=SQLiteWorkspaceStore(database:app.database)
        let savedWorkspaceID=try await workspaces.workspaceID(conversationID:fixture.taskID)
        let workspaceID=try XCTUnwrap(savedWorkspaceID)
        let savedWorkspace=try await workspaces.workspace(id:workspaceID)
        let workspace=try XCTUnwrap(savedWorkspace)
        let taskPolicy=try await workspaces.taskPolicy(conversationID:fixture.taskID)
        for name in ["latex.inspect",tool,"exec.shell"] {
            try require(taskPolicy.allowedToolNames?.contains(name) != false,"Saved task policy does not permit "+name)
        }
        let root=try await app.workspaceCenter.acquireTaskRoot(workspace,conversationID:fixture.taskID)
        var service:ConversationRunService?
        var startAttempted=false
        let evidence=URL.applicationSupportDirectory.appendingPathComponent("FloeAgent/QualificationEvidence/LaTeXModelRuntime/"+runID.uuidString,isDirectory:true)
        var facts=["kind":"scripted-provider-real-App-runtime-not-live-model-not-UI","tool":tool,
            "runID":runID.uuidString,"taskID":fixture.taskID.uuidString,"projectID":fixture.projectID.uuidString,
            "environmentID":fixture.environmentID,"callerAuthorityMinted":"false","nativeUIApprovalUsed":"false"]
        func retain(_ phase:String)throws {
            facts["phase"]=phase
            try FileManager.default.createDirectory(at:evidence,withIntermediateDirectories:true)
            try JSONEncoder().encode(facts).write(to:evidence.appendingPathComponent("receipt.json"),options:.atomic)
        }
        do {
            let pin=try await app.taskExecutionEnvironments.resolveBinding(conversationID:fixture.taskID,runID:runID,root:root.url,workspace:workspace)
            try require(pin.target==priorPin.target && pin.generation==priorPin.generation,"Normal resolution selected a different environment")
            let environmentIDs=Set(await app.environmentRegistry.all().map(\.id))
            var paths=app.latexComposition.typedServiceStorePaths
            let library=try await PersonalContentService.shared.library()
            paths.merge(await library.typedServiceStorePaths()){_,actual in actual}
            let host=try await app.latexComposition.host()
            let call=try ToolCall(id:"qa.model."+runID.uuidString,toolName:tool,
                argumentsJSON:JSONSerialization.data(withJSONObject:arguments,options:.sortedKeys),scope:.local)
            let inspect=try ToolCall(id:"qa.inspect."+runID.uuidString,toolName:"latex.inspect",
                argumentsJSON:JSONSerialization.data(withJSONObject:["projectID":fixture.projectID.uuidString,"action":"project"]),scope:.local)
            let adapter=MockAdapter()
            adapter.script=[
                [.toolRequest(inspect),.completed(.init(stopReason:.toolUse))],
                [.toolRequest(call),.completed(.init(stopReason:.toolUse))],
                [.textDelta(.init(text:"The retained QA project operation completed.")),.completed(.init(stopReason:.endTurn))]
            ]
            let backend=UnexpectedReviewBackend(),provider=TestFixtures.localhostProvider()
            let running=ConversationRunService(configuration:.init(
                conversationID:fixture.taskID,provider:provider,model:TestFixtures.testModel(providerID:provider.id),
                allowedToolNames:["latex.inspect",tool,"exec.shell"],workspaceRootURL:root.url,
                allowedWorkspacePaths:taskPolicy.filePaths,
                pauseTimeout:0.2,verifyFinalAnswer:false,maxProviderRetries:0,
                environmentID:fixture.environmentID,executionBinding:pin,localLinuxGuestEnvironment:true,
                serviceStorePaths:paths),adapter:adapter,policy:AutomaticApprovalPolicy(backend:backend),
                executor:CatalogToolExecutor(runners:host.registry),checkpointStore:MockCheckpointStore(),
                conversationStore:app.conversationStore,runStore:app.runStore,runID:runID)
            service=running
            try retain("before-production-run")
            startAttempted=true
            try await running.start(goal:"Run the authorized synthetic LaTeX operation in this task's existing project and Linux environment.")
            let rows=try await app.runStore.events(runID:runID)
            let results=try rows.filter{$0.kind == .toolResult}.map {
                try JSONDecoder().decode([String:String].self,from:Data($0.payloadJSON.utf8))
            }
            facts["toolResultCount"]=String(results.count)
            facts["toolResults"]=String(String(decoding:try JSONEncoder().encode(results),as:UTF8.self).prefix(16384))
            facts["reviewBackendCalls"]=String(backend.calls)
            try retain("production-run-returned")
            try require(results.count==2,"Inspect and requested tool must both execute")
            try require(results.allSatisfy{$0["status"]=="ok"},"A real registered tool rejected the runtime request")
            try require(backend.calls==0,"Ordinary scoped document operation unexpectedly required a second review")
            let savedRun=try await app.runStore.run(id:runID)
            let ended=try XCTUnwrap(savedRun)
            try require(ended.state=="completed" && ended.endedAt != nil,"Actual run is not terminal and successful")
            let afterPin=try await pinStore.binding(conversationID:fixture.taskID)
            try require(afterPin?.target==priorPin.target && afterPin?.generation==priorPin.generation,"Task pin changed")
            try require(Set(await app.environmentRegistry.all().map(\.id))==environmentIDs,"An environment was created or deleted")
            root.release();try retain("completed-and-root-released")
            print("FLOE_LATEX_MODEL_RUNTIME_EVIDENCE="+evidence.path)
            return runID
        } catch {
            facts["failure"]=String(error.localizedDescription.prefix(1200))
            if let service {await service.cancel()}
            var stopped = !startAttempted
            if startAttempted {
                do {
                    let saved=try await app.runStore.run(id:runID)
                    let host=try await app.latexComposition.host()
                    let history=try await host.builds.history(store:fixture.store)
                    stopped=saved?.endedAt != nil && !history.contains {
                        $0.executionOwner?.runID==runID && ($0.isActive || $0.workerStopped==false)
                    }
                } catch {stopped=false}
            }
            if stopped {
                root.release();try? retain("failed-with-no-active-run")
            } else {
                LaTeXModelProbeOwners.unconfirmed[runID] = .init(root:root,service:service)
                try? retain("unconfirmed-run-owner-retained")
            }
            print("FLOE_LATEX_MODEL_RUNTIME_FAILURE_EVIDENCE="+evidence.path)
            throw error
        }
    }

    private func require(_ value:Bool,_ message:String)throws {
        if !value {throw FloeError.validationFailed(message)}
    }

    private nonisolated final class UnexpectedReviewBackend:ModelApprovalPolicy.DecisionBackend,@unchecked Sendable {
        private let lock=NSLock()
        private var count=0
        var calls:Int {lock.withLock{count}}
        func decide(_ action:ProposedAction) async throws -> ApprovalDecision {
            lock.withLock{count+=1}
            return .deny(reason:"Synthetic regression must use the ordinary task policy, not a manufactured extra approval")
        }
    }
}

@MainActor private enum LaTeXModelProbeOwners {
    struct Owner {
        let root:WorkspaceCenter.TaskRootLease
        let service:ConversationRunService?
    }
    static var unconfirmed=[UUID:Owner]()
}
#endif
