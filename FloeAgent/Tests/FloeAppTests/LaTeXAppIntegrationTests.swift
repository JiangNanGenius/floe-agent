// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && DEBUG
import XCTest
import UIKit
import PDFKit
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
    func testNativeLaTeXMetadataRequiresExactDurableStatus() throws {
        let runID=UUID(),taskID=UUID(),projectID=UUID(),environmentID="synthetic-latex-environment"
        let operations:[LaTeXNativeRunMetadata.Operation]=[.preparation,.typesetting,.maintenance]
        for operation in operations {
            let metadata=LaTeXNativeRunMetadata(runID:runID,conversationID:taskID,projectID:projectID,
                environmentID:environmentID,operation:operation)
            let event=RunEventRecord(runID:runID,sequence:0,kind:.status,payloadJSON:try metadata.payloadJSON())
            func matches(_ value:RunEventRecord,run:UUID?=nil,task:UUID?=nil,tool:String="exec.shell",environment:String?="synthetic-latex-environment")->Bool {
                LaTeXNativeRunMetadata.matches(value,runID:run ?? runID,conversationID:task ?? taskID,
                    targetTool:tool,environmentID:environment)
            }
            XCTAssertTrue(matches(event))
            XCTAssertFalse(matches(event,run:UUID()));XCTAssertFalse(matches(event,task:UUID()))
            XCTAssertFalse(matches(event,tool:"exec.localService"));XCTAssertFalse(matches(event,environment:nil))
            XCTAssertFalse(matches(event,environment:"another-environment"))
            XCTAssertFalse(matches(.init(runID:UUID(),sequence:0,kind:.status,payloadJSON:event.payloadJSON)))
            XCTAssertFalse(matches(.init(runID:runID,sequence:0,kind:.toolResult,payloadJSON:event.payloadJSON)))
            let data=try XCTUnwrap(event.payloadJSON.data(using:.utf8))
            let valid=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
            for (key,value) in [("activity","other" as Any),("version",2),("source","runtime"),("targetTool","exec.localService"),("operation","unknown")] {
                var invalid=valid;invalid[key]=value
                let payload=String(decoding:try JSONSerialization.data(withJSONObject:invalid),as:UTF8.self)
                XCTAssertFalse(matches(.init(runID:runID,sequence:0,kind:.status,payloadJSON:payload)))
            }
            XCTAssertFalse(matches(.init(runID:runID,sequence:0,kind:.status,payloadJSON:"{}")))
        }
    }

    func testAppleNativeRunProofRejectsWrongIdentityAndDuplicateStatus() throws {
        let runID=UUID(),taskID=UUID(),projectID=UUID(),owner=LaTeXOwner(kind:.task,id:taskID)
        let proof=LaTeXAppleNativeRunProof(runID:runID,conversationID:taskID,projectID:projectID,
            owner:owner,revision:7,operation:"prepare")
        let payload=String(decoding:try JSONEncoder().encode(proof),as:UTF8.self)
        let event=RunEventRecord(runID:runID,sequence:0,kind:.status,payloadJSON:payload)
        XCTAssertEqual(LaTeXAppleNativeRunProof.read([event],runID:runID,taskID:taskID)?.revision,7)
        XCTAssertNil(LaTeXAppleNativeRunProof.read([event],runID:UUID(),taskID:taskID))
        XCTAssertNil(LaTeXAppleNativeRunProof.read([event],runID:runID,taskID:UUID()))
        XCTAssertNil(LaTeXAppleNativeRunProof.read([event,event],runID:runID,taskID:taskID))
        XCTAssertNil(LaTeXAppleNativeRunProof.read([.init(runID:runID,sequence:0,kind:.toolResult,payloadJSON:payload)],runID:runID,taskID:taskID))
        let valid=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(payload.utf8)) as? [String:Any])
        for (key,value) in [("activity","runtime" as Any),("version",1),("backend","linuxVM"),
                            ("targetTool","exec.shell"),("operation","stop")] {
            var invalid=valid;invalid[key]=value
            let changed=String(decoding:try JSONSerialization.data(withJSONObject:invalid),as:UTF8.self)
            XCTAssertNil(LaTeXAppleNativeRunProof.read([.init(runID:runID,sequence:0,kind:.status,payloadJSON:changed)],runID:runID,taskID:taskID))
        }
    }

    /// Real App approval/original services; no compiler, guest, or package
    /// operation is invoked. This is a permission contract, not a PDF test.
    func testNativeTypesetApprovalNeedsCompiledIntentAndLiveOriginalWithoutShell() async throws {
        let app=try await appQualificationEnvironment(),host=try await app.latexComposition.host()
        let notes=try await NotesRepository.shared.store()
        let note=try await notes.create(NoteDocument(title:"QA-LaTeX-native-authority-"+UUID().uuidString.prefix(8)))
        let original=try await app.latexComposition.createNative(owner:.init(kind:.note,id:note.id),title:"Native authority contract",templateID:"article")
        let taskID=try await app.latexComposition.assistantForNativeOriginal(original),runID=UUID()
        let manifest=try await LaTeXProjectStore(root:original.root).manifest()
        let workspace=try NotesRepository.assistantWorkspace(conversationID:taskID)
        let policies=SQLiteWorkspaceStore(database:app.database)
        let defaultPolicy=try await policies.taskPolicy(conversationID:taskID)
        XCTAssertNil(defaultPolicy.allowedToolNames);XCTAssertNil(defaultPolicy.networkAllowed)
        try await app.runStore.saveRun(.init(id:runID,conversationID:taskID,state:"preparing",goal:"Native LaTeX approval contract",startedAt:Date(),executionBinding:nil))
        let proof=LaTeXAppleNativeRunProof(runID:runID,conversationID:taskID,projectID:original.id,
            owner:original.owner,revision:manifest.revision,operation:"prepare")
        _ = try await app.runStore.appendEvent(runID:runID,kind:.status,payloadJSON:String(decoding:try JSONEncoder().encode(proof),as:UTF8.self))
        print("FLOE_LATEX_NATIVE_AUTHORITY_OWNED note=\(note.id) task=\(taskID) project=\(original.id) run=\(runID)")
        do {
            let runner=try XCTUnwrap(host.registry.runner(named:"latex.typeset"))
            let arguments=try JSONSerialization.data(withJSONObject:["projectID":original.id.uuidString,"action":"prepare","expectedRevision":manifest.revision,"offline":true],options:[.sortedKeys])
            let call=try ToolCall(id:"latex.native.permission."+UUID().uuidString.lowercased(),toolName:"latex.typeset",argumentsJSON:arguments,scope:.local)
            var context=ToolContext(runID:runID,scope:.local,allowedToolNames:["latex.typeset"],workspaceRootURL:workspace,
                serviceStorePaths:app.latexComposition.typedServiceStorePaths,cancellation:CancellationToken(),conversationID:taskID,
                clientSessionID:"latex.native."+runID.uuidString.lowercased(),frozenEffectiveCatalogNames:["latex.typeset"])
            context.executionToolName="latex.typeset";context.toolCallID=call.id;context.toolIdempotencyKey=call.idempotencyKey
            let intent=LaTeXNativeUIIntent(runID:runID,conversationID:taskID,projectID:original.id,owner:original.owner,
                revision:manifest.revision,requestID:call.id,operation:"prepare")
            func approve(_ value:ToolContext,_ intent:LaTeXNativeUIIntent?,callOverride:ToolCall?=nil,
                         changePolicyAfterReceipt:Bool=false) async throws -> ApprovalGrant {
                let selected=callOverride ?? call
                let selectedAction=ProposedAction(toolCall:selected,riskLabels:Set(runner.descriptor.riskLabels.map(\.rawValue)),
                    userGoal:"Prepare selected original",hostAndPathScope:.local)
                return try await app.conversationCenter.recordNativeWorkbenchApproval(selectedAction,context:value,descriptor:runner.descriptor,
                    projectID:original.id,requestID:selected.id,payloadDigest:RuntimeAuthorityDigest.payloadDigest(arguments),
                    allowedToolNames:["latex.typeset"],requiredPurpose:.notes,nativeLaTeXIntent:intent,validateOriginal:{
                        _ = try await app.latexComposition.authorizeOriginal(original.id,context:value,editing:true)
                        if changePolicyAfterReceipt {
                            let events=try await app.runStore.events(runID:runID)
                            let recorded=events.contains {event in
                                guard event.kind == .approval,
                                      let object=try? JSONSerialization.jsonObject(with:Data(event.payloadJSON.utf8)) as? [String:Any] else {return false}
                                return object["nativeRequestID"] as? String == selected.id
                            }
                            if recorded {
                                var revoked=try await policies.taskPolicy(conversationID:taskID)
                                revoked.allowedToolNames=["latex.inspect"];revoked.updatedAt=Date()
                                try await policies.saveTaskPolicy(revoked)
                            }
                        }
                    })
            }
            func rejects(_ value:ToolContext,_ intent:LaTeXNativeUIIntent?,_ message:String) async {
                do {_ = try await approve(value,intent);XCTFail(message)} catch {}
            }
            await rejects(context,nil,"An unbound model-style context must not receive native UI authority")
            var temporary=context;temporary.temporaryReadOnly=true
            await rejects(temporary,intent,"Temporary chat must not receive native document authority")
            var publicWeb=context;publicWeb.publicWebOnly=true
            await rejects(publicWeb,intent,"A public-web-only context must not receive native document authority")
            var unknownEnvironment=context;unknownEnvironment.environmentID="model-supplied-unbound-environment"
            await rejects(unknownEnvironment,intent,"An arbitrary environment label must not receive the no-environment exception")
            var wrongTool=context;wrongTool.executionToolName="exec.shell"
            await rejects(wrongTool,intent,"The native intent must never authorize a shell execution context")
            let wrongRevision=LaTeXNativeUIIntent(runID:runID,conversationID:taskID,projectID:original.id,owner:original.owner,
                revision:manifest.revision+1,requestID:call.id,operation:"prepare")
            await rejects(context,wrongRevision,"The selected source revision must match the exact prepared action")
            // The first grant reads the genuine unset/default policy twice;
            // fresh read timestamps must not reject an unchanged policy.
            let grant=try await approve(context,intent)
            XCTAssertTrue(grant.scope.singleUse);XCTAssertNil(grant.scope.hostID)
            XCTAssertEqual(grant.scope.toolName,"latex.typeset")
            await rejects(context,intent,"The same native request must not receive a second approval")
            try await policies.saveTaskPolicy(.init(conversationID:taskID,allowedToolNames:["latex.typeset"],networkAllowed:false))
            let restrictedCall=try ToolCall(id:"latex.native.restricted."+UUID().uuidString.lowercased(),toolName:"latex.typeset",argumentsJSON:arguments,scope:.local)
            var restricted=context;restricted.toolCallID=restrictedCall.id;restricted.toolIdempotencyKey=restrictedCall.idempotencyKey
            let restrictedIntent=LaTeXNativeUIIntent(runID:runID,conversationID:taskID,projectID:original.id,owner:original.owner,
                revision:manifest.revision,requestID:restrictedCall.id,operation:"prepare")
            let restrictedGrant=try await approve(restricted,restrictedIntent,callOverride:restrictedCall)
            XCTAssertEqual(restrictedGrant.scope.toolName,"latex.typeset","A saved policy without exec.shell must still allow native preparation")
            let changedCall=try ToolCall(id:"latex.native.policy-change."+UUID().uuidString.lowercased(),toolName:"latex.typeset",argumentsJSON:arguments,scope:.local)
            var policyChanged=context;policyChanged.toolCallID=changedCall.id;policyChanged.toolIdempotencyKey=changedCall.idempotencyKey
            let changedIntent=LaTeXNativeUIIntent(runID:runID,conversationID:taskID,projectID:original.id,owner:original.owner,
                revision:manifest.revision,requestID:changedCall.id,operation:"prepare")
            do {_ = try await approve(policyChanged,changedIntent,callOverride:changedCall,changePolicyAfterReceipt:true)
                XCTFail("A real policy change after the persisted approval receipt must prevent grant return")
            } catch let error as NativeWorkbenchApprovalError {
                guard case .changed=error else {throw error}
            }
            let taskBinding=try await TaskExecutionBindingStore(database:app.database).binding(conversationID:taskID)
            XCTAssertNil(taskBinding,"Native UI preparation must not create a command environment binding")
            let saved=try await app.runStore.run(id:runID)
            XCTAssertNil(saved?.executionBinding)
            try await app.runStore.updateRunState(id:runID,state:"completed",endedAt:Date())
            do {_ = try await app.latexComposition.authorizeOriginal(original.id,context:context,editing:true)
                XCTFail("A terminal run must not reuse native original authority") } catch {}
        } catch {
            try? await app.runStore.updateRunState(id:runID,state:"failed",endedAt:Date())
            let current=try await notes.document(note.id)
            _ = try? await notes.setTrashed(note.id,expectedRevision:current.revision,trashed:true)
            throw error
        }
        let current=try await notes.document(note.id)
        _ = try await notes.setTrashed(note.id,expectedRevision:current.revision,trashed:true)
    }

    /// Explicit actual App-host entry: the same editor prepares real resources,
    /// typesets its unmodified article/math original, and reopens the saved PDF.
    /// Online cache misses and cache hits are recorded separately, never inferred.
    func testNativeArticlePreparesResourcesAndReopensSameOriginalPDF() async throws {
        guard ProcessInfo.processInfo.environment["FLOE_LATEX_NATIVE_REAL_PDF_QA"]=="1" else {
            throw XCTSkip("Opt in to the real native resource/PDF qualification")
        }
        let app=try await appQualificationEnvironment(),host=try await app.latexComposition.host()
        let capabilities=await host.builds.capabilities()
        XCTAssertTrue(capabilities.contains{$0.engine == .xeLaTeX && $0.isLocal && $0.environmentID==nil
            && $0.version==LaTeXAppleNativeEngine.engineVersion},"The actual new native binary and protected renderer must be linked")
        let id=UUID()
        let evidence=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
            .appendingPathComponent("FloeAgent/Qualification/LaTeXNativePDF/"+id.uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:evidence,withIntermediateDirectories:true)
        var receipt:[String:Any]=["kind":"actual-App-host-native-article-resources-and-same-original-PDF", "id":id.uuidString,
            "nativeVersion":LaTeXAppleNativeEngine.engineVersion,"cleanup":"Retain exact task/original/source/outputs for Root export and normal owned cleanup"]
        func saveReceipt() throws {
            try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys])
                .write(to:evidence.appendingPathComponent("owned-manifest.json"),options:.atomic)
        }
        print("FLOE_LATEX_NATIVE_PDF_EVIDENCE="+evidence.path)
        try saveReceipt()
        let task=try await app.conversationCenter.createConversation(title:"QA-Native-LaTeX-"+id.uuidString.prefix(8),purpose:.ordinary)
        receipt["taskID"]=task.id.uuidString;try saveReceipt()
        try await SQLiteWorkspaceStore(database:app.database).saveTaskPolicy(.init(conversationID:task.id,
            allowedToolNames:LaTeXHostTools.names,networkAllowed:true))
        let original=try await app.latexComposition.createNative(owner:.init(kind:.task,id:task.id),title:"Native article and math",templateID:"article")
        receipt["projectID"]=original.id.uuidString;receipt["originalRoot"]=original.root.path;try saveReceipt()
        let store=try LaTeXProjectStore(root:original.root),before=try await store.manifest()
        let source=try await store.read(before.mainFile),sourceHash=LaTeXDigest.hash(source)
        receipt["revision"]=before.revision;receipt["sourceSHA256"]=sourceHash;try saveReceipt()
        try LaTeXDigest.encode(before).write(to:evidence.appendingPathComponent("SourceManifest.json"),options:.atomic)
        do {
            let session=try await LaTeXProjectSession.open(id:original.id,composition:app.latexComposition)
            await session.prepareToolchain()
            XCTAssertNil(session.editor.error,session.editor.error ?? "")
            XCTAssertNil(session.workbenchOperation)
            guard session.editor.error==nil else {throw LaTeXError.unavailable(session.editor.error!)}
            let afterPreparation=try await store.manifest()
            XCTAssertEqual(afterPreparation,before)
            await session.editor.compile()
            XCTAssertNil(session.editor.error,session.editor.error ?? "")
            let build=try XCTUnwrap(session.editor.build)
            XCTAssertTrue(build.succeeded,build.diagnostics.map(\.message).joined(separator:"\n"))
            XCTAssertEqual(build.projectID,original.id);XCTAssertEqual(build.revision,before.revision)
            XCTAssertEqual(build.engineVersion,LaTeXAppleNativeEngine.engineVersion)
            XCTAssertEqual(build.workerStopped,true);XCTAssertNil(build.executionOwner?.environmentID)
            let pdf=try XCTUnwrap(session.editor.pdfURL),pdfBytes=try Data(contentsOf:pdf)
            XCTAssertEqual(pdfBytes.prefix(5),Data("%PDF-".utf8))
            let pageCount=try PDFKitGate.run {try withPDFExceptionGuard {CGPDFDocument(pdf as CFURL)?.numberOfPages ?? 0}}
            XCTAssertGreaterThan(pageCount,0)
            let renderedText=try PDFKitGate.run {try withPDFExceptionGuard {PDFDocument(url:pdf)?.string ?? ""}}
            XCTAssertFalse(renderedText.contains("1970"),"The article's default date must not be fixed to the Unix epoch")
            var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(secondsFromGMT:0)!
            XCTAssertTrue(renderedText.contains(String(calendar.component(.year,from:Date()))),"The article must use the current typesetting year")
            try Data(renderedText.utf8).write(to:evidence.appendingPathComponent("RenderedText.txt"),options:.atomic)
            let reopened=try await LaTeXProjectSession.open(id:original.id,composition:app.latexComposition)
            XCTAssertEqual(reopened.original.id,original.id);XCTAssertTrue(reopened.editor.pdfIsCurrent)
            let reopenedPDF=try XCTUnwrap(reopened.editor.pdfURL)
            XCTAssertEqual(LaTeXDigest.hash(try Data(contentsOf:reopenedPDF)),LaTeXDigest.hash(pdfBytes))
            let after=try await store.manifest(),savedSource=try await store.read(before.mainFile)
            XCTAssertEqual(after,before);XCTAssertEqual(LaTeXDigest.hash(savedSource),sourceHash)
            let taskBinding=try await TaskExecutionBindingStore(database:app.database).binding(conversationID:task.id)
            XCTAssertNil(taskBinding,"Native UI work must not create a command environment")
            let runs=try await app.runStore.runs(conversationID:task.id)
            XCTAssertEqual(runs.count,2)
            for run in runs {
                XCTAssertNil(run.executionBinding);XCTAssertEqual(run.state,"completed");XCTAssertNotNil(run.endedAt)
                let events=try await app.runStore.events(runID:run.id)
                XCTAssertNotNil(LaTeXAppleNativeRunProof.read(events,runID:run.id,taskID:task.id))
                let jobs=try await BackgroundJobStore(database:app.database).jobs(conversationID:task.id)
                XCTAssertFalse(jobs.contains{$0.runID==run.id && $0.targetTool=="exec.shell"})
            }
            let preparations=try FileManager.default.contentsOfDirectory(at:original.root.appendingPathComponent("Preparation"),includingPropertiesForKeys:[.isDirectoryKey])
            XCTAssertEqual(preparations.count,2)
            var downloads=[[String:Any]]()
            for (index,directory) in preparations.sorted(by:{$0.lastPathComponent<$1.lastPathComponent}).enumerated() {
                let nativeData=try Data(contentsOf:directory.appendingPathComponent("Output/NativeResponse.json"))
                let value=try XCTUnwrap(JSONSerialization.jsonObject(with:nativeData) as? [String:Any])
                XCTAssertEqual(value["prepared"] as? Bool,true);XCTAssertEqual(value["success"] as? Bool,true)
                XCTAssertEqual(value["resourceTimeoutSeconds"] as? Int,60);XCTAssertEqual(value["resourceTotalTimeoutSeconds"] as? Int,600)
                let count=try XCTUnwrap(value["resourceRequestCount"] as? Int)
                XCTAssertGreaterThanOrEqual(count,0)
                downloads.append(["preparationID":directory.lastPathComponent,"resourceRequestCount":count,
                    "resourceReceivedBytes":value["resourceReceivedBytes"] ?? 0,"resourceElapsedMilliseconds":value["resourceElapsedMilliseconds"] ?? 0])
                try nativeData.write(to:evidence.appendingPathComponent("NativePreparationResponse-\(index).json"),options:.atomic)
            }
            let buildDirectory=original.root.appendingPathComponent("Builds/"+build.id.uuidString)
            let rendererData=try Data(contentsOf:buildDirectory.appendingPathComponent("Output/NativePDFReceipt.json"))
            let rendered=try JSONDecoder().decode(LaTeXApplePDFReceipt.self,from:rendererData)
            XCTAssertEqual(rendered.sha256,LaTeXDigest.hash(pdfBytes));XCTAssertEqual(rendered.pageCount,pageCount)
            XCTAssertGreaterThan(rendered.glyphCount+rendered.legacyGlyphCount,0)
            for (name,data) in [("Build.json",try Data(contentsOf:buildDirectory.appendingPathComponent("Build.json"))),
                                ("NativeResponse.json",try Data(contentsOf:buildDirectory.appendingPathComponent("Output/NativeResponse.json"))),
                                ("NativePDFReceipt.json",rendererData),("output.pdf",pdfBytes)] {
                try data.write(to:evidence.appendingPathComponent(name),options:.atomic)
            }
            receipt["status"]="completed";receipt["buildID"]=build.id.uuidString
            receipt["pdfPath"]=pdf.path;receipt["pdfSHA256"]=LaTeXDigest.hash(pdfBytes);receipt["pageCount"]=pageCount
            receipt["resourcePreparations"]=downloads
            receipt["observedOnlineDownloads"]=downloads.contains{($0["resourceRequestCount"] as? Int ?? 0)>0}
            receipt["runIDs"]=runs.map{$0.id.uuidString};try saveReceipt()
        } catch {
            receipt["status"]="failed";receipt["failure"]=error.localizedDescription
            receipt["ownerRetained"]=app.latexComposition.nativeRuntime.operations[original.id] != nil
            try? saveReceipt()
            throw error
        }
    }

    func testNativeSupportRejectsBiberAndOtherEnginesWithoutFallback() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        func validate(_ source:String,engine:LaTeXEngine = .xeLaTeX) throws {
            let data=Data(source.utf8)
            try data.write(to:root.appendingPathComponent("main.tex"),options:.atomic)
            var manifest=LaTeXProjectManifest(owner:.init(kind:.task,id:UUID()),title:"Native support contract",engine:engine)
            manifest.files=[.init(path:"main.tex",data:data)]
            try LaTeXNativeDocumentSupport.validate(.init(id:UUID(),manifest:manifest,sourceRoot:root,fingerprint:LaTeXDigest.hash(data)))
        }
        XCTAssertNoThrow(try validate(#"\documentclass{article}\begin{document}Math: $E=mc^2$\end{document}"#))
        XCTAssertNoThrow(try validate(#"\RequirePackage[backend=bibtex]{biblatex}"#))
        for source in [#"\usepackage{biblatex}"#,#"\usepackage[backend=biber]{biblatex}"#,
                       #"\usepackage[backend=bibtex8]{biblatex}"#,
                       #"\usepackage[backend=bibtex]{unrelated}\usepackage{biblatex}"#,
                       #"\usepackage[backend=bibtex,backend=biber]{biblatex}"#] {
            XCTAssertThrowsError(try validate(source)) {error in
                guard let latex=error as? LaTeXError,case .unavailable=latex else {return XCTFail("Expected an explicit unsupported native backend")}
            }
        }
        XCTAssertThrowsError(try validate("",engine:.luaLaTeX))
        XCTAssertThrowsError(try validate("",engine:.pdfLaTeX))
    }

    /// Saved model pins use real SQLite/Notes checks. The synthetic targets
    /// below are identities only: no environment/runtime is created or started.
    func testNotesSavedModelPinRetainsLinuxAndLocalBoundary() async throws {
        let app=try await appQualificationEnvironment(),notes=try await NotesRepository.shared.store()
        let remoteID=UUID()
        let cases:[(TaskExecutionTarget.Backend,UUID?,Bool)]=[(.linuxVM,nil,true),(.macBridge,nil,false),(.linuxVM,remoteID,false)]
        for (backend,remoteHostID,accepted) in cases {
            let note=try await notes.create(NoteDocument(title:"QA-LaTeX-notes-pin-"+UUID().uuidString.prefix(8)))
            let original=try await app.latexComposition.createNative(owner:.init(kind:.note,id:note.id),title:"Notes saved-pin contract",templateID:"article")
            let taskID=try await app.latexComposition.assistantForNativeOriginal(original),runID=UUID()
            let target=TaskExecutionTarget(environmentID:"synthetic-notes-pin-"+UUID().uuidString.lowercased(),backend:backend,
                remoteHostID:remoteHostID,operatingSystem:backend == .macBridge ? "macos":"linux",architecture:"arm64")
            let binding=try await TaskExecutionBindingStore(database:app.database).bindInitial(.init(conversationID:taskID,target:target))
            XCTAssertEqual(binding.target,target)
            try await app.runStore.saveRun(.init(id:runID,conversationID:taskID,state:"executing",goal:"Notes saved-pin boundary",startedAt:Date(),executionBinding:binding))
            print("FLOE_LATEX_NOTES_PIN_OWNED note=\(note.id) task=\(taskID) project=\(original.id) run=\(runID)")
            var context=ToolContext(runID:runID,scope:remoteHostID.map(ToolScope.host) ?? .local,
                allowedToolNames:["latex.typeset"],workspaceRootURL:try NotesRepository.assistantWorkspace(conversationID:taskID),
                serviceStorePaths:app.latexComposition.typedServiceStorePaths,cancellation:CancellationToken(),environmentID:target.environmentID,
                executionBindingGeneration:binding.generation,conversationID:taskID,frozenEffectiveCatalogNames:["latex.typeset"])
            context.executionToolName="latex.typeset"
            do {
                if accepted {
                    let verifiedTask=try await app.latexComposition.verify(context)
                    XCTAssertEqual(verifiedTask,taskID)
                } else {
                    do {_ = try await app.latexComposition.verify(context)
                        XCTFail("An actual saved/current pin must still fail the original Notes linuxVM/local boundary")
                    } catch let error as PersonalContentError {
                        guard case .changedDocument=error else {throw error}
                    }
                }
                try await app.runStore.updateRunState(id:runID,state:"completed",endedAt:Date())
            } catch {
                try? await app.runStore.updateRunState(id:runID,state:"failed",endedAt:Date())
                let current=try await notes.document(note.id)
                _ = try? await notes.setTrashed(note.id,expectedRevision:current.revision,trashed:true)
                throw error
            }
            let current=try await notes.document(note.id)
            _ = try await notes.setTrashed(note.id,expectedRevision:current.revision,trashed:true)
        }
    }

    /// Real native C cancellation, explicitly selected. No controlled tool,
    /// guest, C callback or PDF output substitutes for the production service.
    func testNativeCancellationAfterActualCEntryKeepsPriorPDFAndSettlesOwner() async throws {
        guard ProcessInfo.processInfo.environment["FLOE_LATEX_NATIVE_REAL_CANCEL_QA"]=="1" else {
            throw XCTSkip("Opt in to actual native C cancellation qualification")
        }
        func require(_ condition:Bool,_ message:String) throws {
            guard condition else {throw FloeError.validationFailed(message)}
        }
        let app=try await appQualificationEnvironment(),host=try await app.latexComposition.host()
        let capabilities=await host.builds.capabilities()
        try require(capabilities.contains{$0.engine == .xeLaTeX && $0.isLocal && $0.environmentID==nil
            && $0.version==LaTeXAppleNativeEngine.engineVersion},"The actual native binary and protected renderer must be linked")
        let id=UUID(),fm=FileManager.default
        let evidence=try fm.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
            .appendingPathComponent("FloeAgent/Qualification/LaTeXNativeCancel/"+id.uuidString,isDirectory:true)
        try fm.createDirectory(at:evidence,withIntermediateDirectories:true)
        var receipt:[String:Any]=["kind":"actual-App-host-native-C-cancel-after-entry", "id":id.uuidString,
            "nativeVersion":LaTeXAppleNativeEngine.engineVersion,"status":"creating-owned-original",
            "cleanup":"Retain task/original/snapshots/PDF/failed outputs for Root export and normal owned cleanup",
            "terminalBeforeInternalOwnerRelease":"source-reviewed: finish awaits updateRunState before removing owner; runtime checks terminal plus public operation drain, not the private instant"]
        func saveReceipt() throws {
            try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys])
                .write(to:evidence.appendingPathComponent("owned-manifest.json"),options:.atomic)
        }
        func export(_ source:URL,_ name:String) throws {
            try Data(contentsOf:source).write(to:evidence.appendingPathComponent(name),options:.atomic)
        }
        print("FLOE_LATEX_NATIVE_CANCEL_EVIDENCE="+evidence.path);try saveReceipt()
        let task=try await app.conversationCenter.createConversation(title:"QA-Native-LaTeX-Cancel-"+id.uuidString.prefix(8),purpose:.ordinary)
        receipt["taskID"]=task.id.uuidString;try saveReceipt()
        try await SQLiteWorkspaceStore(database:app.database).saveTaskPolicy(.init(conversationID:task.id,
            allowedToolNames:["latex.typeset"],networkAllowed:true))
        let original=try await app.latexComposition.createNative(owner:.init(kind:.task,id:task.id),title:"Native cancellation boundary",templateID:"article")
        receipt["projectID"]=original.id.uuidString;receipt["originalRoot"]=original.root.path;try saveReceipt()
        let store=try LaTeXProjectStore(root:original.root),initial=try await store.manifest()
        var cancelling:LaTeXProjectSession?,compiling:Task<Void,Never>?
        do {
            let warm=try await LaTeXProjectSession.open(id:original.id,composition:app.latexComposition)
            receipt["status"]="warming-real-article-PDF";try saveReceipt()
            await warm.editor.compile()
            try require(warm.editor.error==nil,warm.editor.error ?? "The warm article failed")
            let success=try XCTUnwrap(warm.editor.build),pdf=try XCTUnwrap(warm.editor.pdfURL)
            try require(success.succeeded && success.workerStopped==true,"A real successful native PDF is a prerequisite")
            try require(success.engineVersion==LaTeXAppleNativeEngine.engineVersion && success.projectID==original.id,"Warm output must belong to this actual native original")
            let pdfBytes=try Data(contentsOf:pdf),pdfHash=LaTeXDigest.hash(pdfBytes)
            try require(pdfBytes.prefix(5)==Data("%PDF-".utf8),"The warm output must be actual PDF bytes")
            let buildJSON=original.root.appendingPathComponent("Builds/"+success.id.uuidString+"/Build.json")
            let buildBytes=try Data(contentsOf:buildJSON),warmRuns=try await app.runStore.runs(conversationID:task.id)
            let warmRunIDs=Set(warmRuns.map(\.id)),warmHistory=try await host.builds.history(store:store)
            try require(warmRuns.count==1 && warmRuns.allSatisfy{$0.state=="completed" && $0.endedAt != nil && $0.executionBinding==nil},"The warm native run must settle before the cancellation case")
            let preparations=original.root.appendingPathComponent("Preparation",isDirectory:true)
            let priorPreparations=Set(try fm.contentsOfDirectory(atPath:preparations.path))
            try export(pdf,"WarmOutput.pdf");try export(buildJSON,"WarmBuild.json")
            try LaTeXDigest.encode(initial).write(to:evidence.appendingPathComponent("WarmSourceManifest.json"),options:.atomic)
            receipt["warmBuildID"]=success.id.uuidString;receipt["warmPDFPath"]=pdf.path;receipt["warmPDFSHA256"]=pdfHash
            receipt["warmRunIDs"]=warmRuns.map{$0.id.uuidString}
            receipt["workspaceID"]=try await SQLiteWorkspaceStore(database:app.database).workspaceID(conversationID:task.id)?.uuidString
            try saveReceipt()
            // The ordinary CAS edit changes only this QA original. This loop
            // keeps the genuine TeX scanner busy without growing a page tree.
            let loop=#"\documentclass{article}\begin{document}\loop\relax\iftrue\repeat\end{document}"#+"\n"
            let input=Data(loop.utf8),inputHash=LaTeXDigest.hash(input),mutationID=UUID()
            let mutation=try await store.apply([.put(path:initial.mainFile,data:input)],expectedRevision:initial.revision,
                requestID:mutationID,label:"QA native cancellation",origin:"user")
            let changed=try await store.manifest()
            try require(changed.revision==mutation.revision && changed.revision==initial.revision+1,"The owned source edit must use the original CAS revision")
            try LaTeXDigest.encode(changed).write(to:evidence.appendingPathComponent("CancelSourceManifest.json"),options:.atomic)
            try input.write(to:evidence.appendingPathComponent("CancelInput.tex"),options:.atomic)
            receipt["cancelRevision"]=changed.revision;receipt["mutationID"]=mutationID.uuidString;receipt["cancelInputSHA256"]=inputHash
            let session=try await LaTeXProjectSession.open(id:original.id,composition:app.latexComposition)
            cancelling=session;session.editor.offline=true // warm cached article inputs; no HTTP wait in the cancellation phase
            let work=Task { @MainActor in await session.editor.compile() };compiling=work
            receipt["status"]="waiting-for-actual-C-entry";try saveReceipt()
            let entryDeadline=Date().addingTimeInterval(30)
            var enteredSequence:UInt64?
            while Date()<entryDeadline {
                if let phase=app.latexComposition.nativeRuntime.operations[original.id]?.preparationProgress,phase.sequence>=2 {
                    enteredSequence=phase.sequence;break
                }
                if let error=session.editor.error {throw LaTeXError.unavailable(error)}
                try await Task.sleep(for:.milliseconds(10))
            }
            let sequence=try XCTUnwrap(enteredSequence,"Checking sequence 1 is only service setup; require the real C callback at sequence >=2")
            let runs=try await app.runStore.runs(conversationID:task.id)
            let cancelRuns=runs.filter{!warmRunIDs.contains($0.id)}
            try require(cancelRuns.count==1,"Exactly one new native run must own this cancellation")
            let run=try XCTUnwrap(cancelRuns.first),events=try await app.runStore.events(runID:run.id)
            let proof=try XCTUnwrap(LaTeXAppleNativeRunProof.read(events,runID:run.id,taskID:task.id))
            try require(proof.projectID==original.id && proof.owner==original.owner && proof.revision==changed.revision && proof.operation=="start","The C-entry observation must belong to this exact source/run")
            try require(run.state=="preparing" && run.endedAt==nil && run.executionBinding==nil,"Cancel only a live unbound native run after actual C entry")
            receipt["cancelRunID"]=run.id.uuidString;receipt["actualCEntrySequence"]=sequence
            receipt["status"]="actual-C-entered-cancel-requested";try saveReceipt()
            let cancellationStarted=ProcessInfo.processInfo.systemUptime
            session.cancelPreparation() // the real editor Stop, not a pre-cancelled or fake processor
            await work.value;compiling=nil // real native call and service settlement must return
            receipt["cancelWaitSeconds"]=ProcessInfo.processInfo.systemUptime-cancellationStarted
            let ended=try await app.runStore.run(id:run.id)
            try require(ended?.state=="cancelled" && ended?.endedAt != nil,"The saved native run must be terminal after the actual join")
            try require(app.latexComposition.nativeRuntime.operations[original.id]==nil && session.workbenchOperation==nil && !session.editor.isBuilding,"The public native operation must drain after terminal settlement")
            let newPreparations=Set(try fm.contentsOfDirectory(atPath:preparations.path)).subtracting(priorPreparations)
            try require(newPreparations.count==1,"The cancelled native preparation must have one exact evidence directory")
            let preparation=preparations.appendingPathComponent(try XCTUnwrap(newPreparations.first),isDirectory:true)
            let actualSource=try JSONDecoder().decode(LaTeXProjectManifest.self,from:Data(contentsOf:preparation.appendingPathComponent("SourceManifest.json")))
            try require(actualSource==changed,"C cancellation evidence must retain the same immutable source revision")
            let responseURL=preparation.appendingPathComponent("Output/NativeResponse.json"),failureURL=preparation.appendingPathComponent("NativePreparationFailure.json")
            let response=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:responseURL)) as? [String:Any])
            let failure=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:failureURL)) as? [String:Any])
            try export(responseURL,"CancelNativeResponse.json");try export(failureURL,"CancelNativePreparationFailure.json")
            receipt["preparationRoot"]=preparation.path;try saveReceipt()
            try require(response["success"] as? Bool == false && response["cancelled"] as? Bool == true,"The real C receipt must report cancellation; a Swift waiter or compiler timeout is not enough")
            try require(failure["cancelled"] as? Bool == true && failure["workerStopped"] as? Bool == true,"Require the actual native failure's worker-join receipt, never infer it from nil environment")
            let snapshotID=try XCTUnwrap(failure["snapshotID"] as? String)
            let retained=original.root.appendingPathComponent("Snapshots/"+snapshotID).appendingPathComponent(changed.mainFile)
            try require(LaTeXDigest.hash(try Data(contentsOf:retained))==inputHash,"The cancelled source snapshot must remain recoverable")
            let current=try await store.manifest(),source=try await store.read(changed.mainFile)
            try require(current==changed && LaTeXDigest.hash(source)==inputHash,"Cancellation must not reset or overwrite the owned CAS source")
            let history=try await host.builds.history(store:store)
            try require(history.map(\.id)==warmHistory.map(\.id),"Cancelled preparation must not fabricate or replace a saved PDF build")
            try require(LaTeXDigest.hash(try Data(contentsOf:pdf))==pdfHash && (try Data(contentsOf:buildJSON))==buildBytes,"The previously successful PDF/build bytes must be unchanged")
            let reopened=try await LaTeXProjectSession.open(id:original.id,composition:app.latexComposition)
            try require(reopened.editor.pdfBuild?.id==success.id && !reopened.editor.pdfIsCurrent,"The old success remains available and visibly stale for the cancelled revision")
            let binding=try await TaskExecutionBindingStore(database:app.database).binding(conversationID:task.id)
            let jobs=try await BackgroundJobStore(database:app.database).jobs(conversationID:task.id)
            try require(binding==nil && ended?.executionBinding==nil && !jobs.contains{$0.targetTool=="exec.shell"},"Native cancellation must not create a Linux binding or shell job")
            receipt["status"]="completed";receipt["savedRunState"]=ended?.state
            receipt["actualCCancelled"]=true;receipt["actualWorkerStoppedReceipt"]=true
            receipt["priorPDFSHA256After"]=LaTeXDigest.hash(try Data(contentsOf:pdf));receipt["sourceSHA256After"]=LaTeXDigest.hash(source)
            receipt["publicOperationDrained"]=true;try saveReceipt()
        } catch {
            receipt["status"]="failed-evidence-retained";receipt["failure"]=error.localizedDescription
            receipt["publicOperationOwnedAtFailure"]=app.latexComposition.nativeRuntime.operations[original.id] != nil
            try? saveReceipt()
            cancelling?.cancelPreparation()
            if let compiling {await compiling.value} // keep waiting for the real service even on failure
            receipt["cleanupWaiterReturned"]=true
            receipt["publicOperationOwnedAfterCleanup"]=app.latexComposition.nativeRuntime.operations[original.id] != nil
            try? saveReceipt()
            throw error
        }
    }

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
        let preparation=Task {await first.prepareToolchain()}
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
        controlled.run={arguments,context in
            if let output=try laTeXMissingEngineProbe(arguments) {return output}
            return await probe.waitForStop(context)
        }
        host.registry.register(controlled)
        defer {host.registry.register(shell)}
        let first=try await LaTeXProjectSession.open(id:original.id,composition:app.latexComposition)
        // Project-specific preparation owns a real durable job; editor Stop
        // must reach that job without a separate external cancel action.
        let preparation=Task {await first.prepareToolchain()}
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
            let nativeEvents=try await app.runStore.events(runID:runID)
            XCTAssertTrue(nativeEvents.contains {LaTeXNativeRunMetadata.matches($0,runID:runID,
                conversationID:taskID,targetTool:submitted.targetTool,environmentID:submitted.environmentID)})
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
        let preparation=Task {await first.prepareToolchain()}
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

/// Only the short discovery response is controlled here. The actual
/// dependency preparer must then submit its installation to the production
/// BackgroundJobService, where the existing Stop/exit assertions apply.
private func laTeXMissingEngineProbe(_ arguments:Data) throws -> ToolExecutionOutput? {
    let command=try JSONDecoder().decode(LocalShellTool.Arguments.self,from:arguments)
    guard let script=command.script else {return nil}
    let regex=try NSRegularExpression(pattern:#"INPUT=json.loads\(base64.b64decode\('([A-Za-z0-9+/=]+)'\)\)"#)
    let source=script as NSString
    guard let match=regex.firstMatch(in:script,range:NSRange(location:0,length:source.length)),
          let data=Data(base64Encoded:source.substring(with:match.range(at:1))),
          let input=try JSONSerialization.jsonObject(with:data) as? [String:Any],input["action"] as? String == "probe" else {return nil}
    guard let programs=input["programs"] as? [String],programs.contains("xelatex"),
          let projectID=input["projectID"],let revision=input["revision"],let digest=input["inputDigest"] else {
        throw FloeError.validationFailed("The controlled preparation probe must match this project's actual engine and revision")
    }
    let envelope:[String:Any]=["protocolName":"floe.latex.dependencies","version":1,
        "projectID":projectID,"revision":revision,"inputDigest":digest,
        "result":["missingPrograms":["xelatex"],"missingFiles":[],"missingFonts":[],"resolved":[:]]]
    let result=try JSONSerialization.data(withJSONObject:envelope,options:[.sortedKeys])
    return ToolExecutionOutput(summary:"exit=0 cwd=controlled-probe\nFLOE_LATEX_DEPENDENCIES "+result.base64EncodedString()+"\n",
        fullOutputSHA256:"controlled-missing-engine-probe",exitStatus:0)
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
            // A nonnil classifier switches this policy to approval-model,
            // whose contract intentionally reviews even harmless reads.
            // Exercise the normal automatic path, as the App Font contract
            // does, without changing the production reviewing policy.
            let policy=AutomaticApprovalPolicy(),provider=TestFixtures.localhostProvider()
            let running=ConversationRunService(configuration:.init(
                conversationID:fixture.taskID,provider:provider,model:TestFixtures.testModel(providerID:provider.id),
                allowedToolNames:["latex.inspect",tool,"exec.shell"],workspaceRootURL:root.url,
                allowedWorkspacePaths:taskPolicy.filePaths,
                pauseTimeout:0.2,verifyFinalAnswer:false,maxProviderRetries:0,
                environmentID:fixture.environmentID,executionBinding:pin,localLinuxGuestEnvironment:true,
                serviceStorePaths:paths),adapter:adapter,policy:policy,
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
            facts["approvalPolicy"]=policy.policyName
            try retain("production-run-returned")
            try require(results.count==2,"Inspect and requested tool must both execute")
            try require(results.allSatisfy{$0["status"]=="ok"},"A real registered tool rejected the runtime request")
            try require(results.allSatisfy{$0["dispatched"]=="true"},"Both exact tools must actually dispatch")
            try require(Set(results.compactMap{$0["id"]})==Set([inspect.id,call.id]),"Persisted results must belong to the exact inspection and requested call")
            try require(policy.policyName=="automatic","This contract must use ordinary automatic approval")
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


}

@MainActor private enum LaTeXModelProbeOwners {
    struct Owner {
        let root:WorkspaceCenter.TaskRootLease
        let service:ConversationRunService?
    }
    static var unconfirmed=[UUID:Owner]()
}
#endif
