// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeTools
import FloePersistence
import FloeChemistryCore
import FloeChemistryEngine
@testable import FloeApp

@MainActor @Suite("Registered scientific result to data and saved outputs", .serialized)
struct ChemistryResultWorkflowTests {
    private func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),as:UTF8.self)
    }
    private func parsed(_ output: ToolExecutionOutput) throws -> [String:Any] {
        try #require(JSONSerialization.jsonObject(with:Data((output.capturedOutput ?? output.summary).utf8)) as? [String:Any])
    }
    private func invoke(_ name: String, _ arguments: [String:Any], _ context: ToolContext) async throws -> ToolExecutionOutput {
        let runner = try #require(ToolRunnerRegistry.shared.runner(named:name))
        return try await runner.execute(argumentsJSON:JSONSerialization.data(withJSONObject:arguments),context:context)
    }
    @Test("A saved result export checks the existing service export authorization before reading data")
    func savedResultExportRequiresTheExistingExportAccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Chemistry-export-authority-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ChemistryProjectStore(root: root)
        let service = try ChemistryService(store: store, backends: []) { access in
            if access.action == .export { throw ChemistryError.unavailable("Export denied by the existing authorizer") }
        }
        do {
            _ = try await service.savedResultForExport(UUID(), runID: UUID())
            Issue.record("A project-read permission was used as an export grant")
        } catch let error as ChemistryError { #expect(error == .unavailable("Export denied by the existing authorizer")) }
    }
    @Test("The real registered native engine returns all samples, pages and exports actual CSV/JSON, then native statistics and saved Office outputs reuse those values")
    func realRegisteredSpectrumCSVStatisticsAndSavedPresentation() async throws {
        let environment = FloeAgentApp.liveEnvironment
        try await environment.ensureDurableAutomationReady()
        let conversation = UUID(), runID = UUID(), now = Date()
        try await environment.conversationStore.saveConversation(.init(id:conversation,title:"Scientific result contract",createdAt:now,updatedAt:now))
        try await environment.conversationStore.setArchived(id:conversation,archived:true)
        let workspace = try await SQLiteWorkspaceStore(database:environment.database).ensureWorkspace(conversationID:conversation,title:"Scientific result contract")
        let lease = try await environment.workspaceCenter.acquireTaskRoot(workspace,conversationID:conversation)
        defer { lease.release(); try? FileManager.default.removeItem(at:lease.url) }
        try await environment.runStore.saveRun(.init(id:runID,conversationID:conversation,state:"executing",goal:"Read actual native scientific results",startedAt:now))
        let names = StudioCoordinator.names.union(["data.analyze","document.createWorkbook","document.readSheet","document.presentation.createDeck","workspace.createFile","workspace.readFile","workspace.publishOutput"])
        var context = ToolContext(runID:runID,toolCallID:"science-create",allowedToolNames:names,
            workspaceRootURL:lease.url,cancellation:CancellationToken(),conversationID:conversation)
        context.frozenEffectiveCatalogNames = names; context.approvalGrantID = UUID() // Existing trusted host fixture, not model-minted authority.
        var originalID: UUID?
        func cleanup() async {
            if let originalID, let record = try? await PersonalContentService.shared.library().resolve(originalID).record {
                try? await PersonalLibraryFileActions.delete(record,environment:environment)
            }
            try? await environment.conversationStore.deleteConversation(id:conversation)
            if let root = try? FloeArtifactStore.root() { try? FileManager.default.removeItem(at:root.appendingPathComponent("RunOutputs/"+runID.uuidString)) }
        }
        do {
            let created = try parsed(try await invoke("studio.create",["kind":"chemistry","title":"Scientific contract " + String(UUID().uuidString.prefix(8))],context))
            let record = try #require(created["record"] as? [String:Any]), id = try #require((record["id"] as? String).flatMap(UUID.init(uuidString:)))
            originalID = id
            let location = try await PersonalContentService.shared.library().resolve(id)
            let session = try await ChemistryProjectSession.open(id:id,directory:location.url,environment:environment)
            let initial = try await session.projectForRead()
            context.toolCallID = "science-create-input-file"
            let sourceCSV = "x,y\n0,0\n1,2\n2,0"
            let inputFile = try await invoke("workspace.createFile",["path":"Measured-spectrum.csv","content":sourceCSV],context)
            #expect((inputFile.exitStatus ?? 0) == 0)
            #expect(inputFile.summary.contains("bytes=\(sourceCSV.utf8.count)") && inputFile.summary.contains("sha256=" + StudioToolOutput.hash(Data(sourceCSV.utf8))))
            context.toolCallID = "science-read-input-file"
            let read = try await invoke("workspace.readFile",["path":"Measured-spectrum.csv"],context)
            let inputText = read.capturedOutput ?? read.summary
            #expect((read.exitStatus ?? 0) == 0 && inputText.contains("truncated=false"))
            let csvSource = try #require(inputText.split(separator:"\n",maxSplits:1,omittingEmptySubsequences:false).last.map(String.init))
            #expect(csvSource == sourceCSV)
            context.toolCallID = "science-import-measured-spectrum"
            _ = try await invoke("studio.edit",["projectID":id.uuidString,"expectedRevision":String(initial.revision),
                "operationsJSON":try json(["action":"importObject","title":"Measured spectrum","kind":"spectrum","format":"csv","source":csvSource])],context)
            let imported = try #require(try await session.projectForRead().objects.first)
            context.toolCallID = "science-native-spectrum"
            let computed = try parsed(try await invoke("studio.chemistry",["projectID":id.uuidString,"action":"calculate",
                "inputJSON":try json(["objectID":imported.id.uuidString,"expectedObjectRevision":imported.revision,"method":"spectrum.analyze"])],context))
            #expect(computed["status"] as? String == "succeeded" && computed["resultComplete"] as? Bool == true)
            let actual = try #require(computed["result"] as? [String:Any]), points = try #require(actual["points"] as? [[String:Any]])
            #expect(points.count == 3 && actual["area"] as? Double == 2)
            let calculationID = try #require(computed["runID"] as? String), digest = try #require(computed["resultSHA256"] as? String)
            let saved = try await session.projectForRead()
            context.toolCallID = "science-page"
            let first = try parsed(try await invoke("studio.chemistry",["projectID":id.uuidString,"action":"result",
                "inputJSON":try json(["runID":calculationID,"resultKey":"points","limit":2])],context))
            let page = try #require(first["page"] as? [String:Any])
            #expect(page["returnedItems"] as? Int == 2 && page["nextOffset"] as? Int == 2)
            context.toolCallID = "science-page-continuation"
            let last = try parsed(try await invoke("studio.chemistry",["projectID":id.uuidString,"action":"result",
                "inputJSON":try json(["runID":calculationID,"resultKey":"points","offset":2,"limit":2,"expectedResultSHA256":digest])],context))
            #expect((last["page"] as? [String:Any])?["returnedItems"] as? Int == 1)
            context.toolCallID = "science-result-csv"
            let arguments: [String:Any] = ["projectID":id.uuidString,"action":"export","inputJSON":try json(["runID":calculationID,"format":"csv","resultKey":"points","expectedResultSHA256":digest])]
            let exported = try await invoke("studio.chemistry",arguments,context)
            #expect(exported.outputFiles.count == 2 && Set(exported.outputFiles.map(\.outputID)).count == 2)
            var csvBytes: Data?
            for file in exported.outputFiles {
                #expect(file.runID == runID && file.taskID == conversation && file.producerCallID == "science-result-csv" && file.producerTool == "studio.chemistry")
                guard case .verified(let url) = RunOutputSnapshotStore.verify(file) else { Issue.record("Result snapshot was not verifiable"); return }
                let bytes = try Data(contentsOf:url)
                #expect(bytes.count == file.byteCount && StudioToolOutput.hash(bytes) == file.sha256)
                if file.displayName.hasSuffix(".csv") { csvBytes = bytes }
                else {
                    let metadata = try #require(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
                    let provenance = try #require(metadata["provenance"] as? [String:Any])
                    #expect(provenance["resultSHA256"] as? String == digest && provenance["inputRevision"] as? String == String(imported.revision))
                    #expect((provenance["calculationOwner"] as? [String:Any])?["hostRunID"] as? String == runID.uuidString)
                }
            }
            let csv = try #require(csvBytes), reread = try SpectrumAnalysis.csv(String(decoding:csv,as:UTF8.self))
            #expect(reread.points.count == 3 && reread.area == 2 && reread.peaks.count == 1)
            #expect(try await invoke("studio.chemistry",arguments,context).outputFiles == exported.outputFiles)
            context.toolCallID = "science-writeback-result-csv"
            let writtenFile = try await invoke("workspace.createFile",["path":"Native-spectrum-result.csv","content":String(decoding:csv,as:UTF8.self)],context)
            #expect((writtenFile.exitStatus ?? 0) == 0)
            #expect(writtenFile.summary.contains("bytes=\(csv.count)") && writtenFile.summary.contains("sha256=" + StudioToolOutput.hash(csv)))
            context.toolCallID = "science-read-written-csv"
            let written = try await invoke("workspace.readFile",["path":"Native-spectrum-result.csv"],context)
            let writtenText = written.capturedOutput ?? written.summary
            #expect((written.exitStatus ?? 0) == 0 && writtenText.contains("truncated=false") && writtenText.hasSuffix(String(decoding:csv,as:UTF8.self)))
            context.toolCallID = "science-publish-written-csv"
            let republished = try await invoke("workspace.publishOutput",["path":"Native-spectrum-result.csv"],context)
            #expect(republished.outputFiles.first?.sha256 == StudioToolOutput.hash(csv))
            context.toolCallID = "science-result-json"
            let whole = try await invoke("studio.chemistry",["projectID":id.uuidString,"action":"export","inputJSON":try json(["runID":calculationID,"format":"json"])],context)
            let jsonFile = try #require(whole.outputFiles.first)
            guard case .verified(let jsonURL) = RunOutputSnapshotStore.verify(jsonFile) else { Issue.record("Full result JSON missing"); return }
            let wholeJSON = try #require(JSONSerialization.jsonObject(with:Data(contentsOf:jsonURL)) as? [String:Any])
            #expect((wholeJSON["result"] as? [String:Any])?["area"] as? Double == 2)
            let y = try points.map { try #require($0["y"] as? Double) }
            context.toolCallID = "science-native-statistics"
            let statistics = try parsed(try await invoke("data.analyze",["action":"summarize","values":y],context))
            let summary = try #require(statistics["summary"] as? [String:Any]), mean = try #require(summary["mean"] as? Double)
            #expect(abs(mean - 2.0/3.0) < 1e-12)
            context.toolCallID = "science-workbook"
            let book = try await invoke("document.createWorkbook",["path":"Scientific-results.xlsx","sheets":[["name":"NativeResults","rows":[["x","signal"],["0","0"],["1","2"],["2","0"],["Native mean",String(mean)]]]]],context)
            #expect(book.exitStatus == 0 && book.outputFiles.count == 1)
            context.toolCallID = "science-read-workbook"
            let grid = try await invoke("document.readSheet",["path":"Scientific-results.xlsx","sheet":"NativeResults"],context)
            #expect(grid.exitStatus == 0 && (grid.capturedOutput ?? grid.summary).contains("Native mean"))
            context.toolCallID = "science-measured-chart-deck"
            let deck = try await invoke("document.presentation.createDeck",["path":"Scientific-results.pptx","title":"Measured spectrum",
                "slides":[["title":"Actual samples","objects":[["kind":"chart","layout":"full","chart":["chartType":"line","categories":["0","1","2"],"series":[["name":"Signal","values":y]]]]]]]],context)
            #expect(deck.exitStatus == 0 && deck.outputFiles.count == 1)
            for file in book.outputFiles + deck.outputFiles {
                guard case .verified(let url) = RunOutputSnapshotStore.verify(file) else { Issue.record("Saved presentation/workbook output missing"); return }
                #expect(try Data(contentsOf:url).count == file.byteCount)
            }
            #expect(try await session.projectForRead() == saved)
            context.toolCallID = "science-reject-nontable-csv"
            do { _ = try await invoke("studio.chemistry",["projectID":id.uuidString,"action":"export","inputJSON":try json(["runID":calculationID,"format":"csv","resultKey":"area"])],context); Issue.record("A scalar was faked as a numeric table") } catch {}
            var foreign = context; foreign.conversationID = UUID(); foreign.runID = UUID(); foreign.toolCallID = "foreign-science-read"
            do { _ = try await invoke("studio.chemistry",["projectID":id.uuidString,"action":"result","inputJSON":try json(["runID":calculationID])],foreign); Issue.record("A different task read the bound original") } catch {}
            await cleanup()
        } catch { await cleanup(); throw error }
    }
}
#endif
