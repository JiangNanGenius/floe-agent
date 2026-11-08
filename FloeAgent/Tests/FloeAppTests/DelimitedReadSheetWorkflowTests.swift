#if canImport(UIKit) || FLOE_DELIMITED_QUALIFICATION
import Foundation
import Testing
import FloeCore
import FloeTools
import FloeModels
import FloeWorkspace
import FloeDocuments
import FloeExecution

@Suite("CSV existing native tool workflow", .serialized)
struct DelimitedReadSheetWorkflowTests {
    private func invoke(_ name: String, _ value: [String:Any], registry: ToolRunnerRegistry,
                        context: ToolContext) async throws -> ToolExecutionOutput {
        let runner = try #require(registry.runner(named: name))
        return try await runner.execute(argumentsJSON: JSONSerialization.data(withJSONObject: value), context: context)
    }
    private func fixtureRunner<T: AgentTool>(_ tool: T) -> AnyAgentTool {
        let original = AnyAgentTool(tool)
        // Use the existing test-owned routing seam, without mutating global
        // App environment configuration. The actual tool validation, path
        // authority, execution and artifact store implementations stay intact.
        return AnyAgentTool(descriptor: original.descriptor, run: original.run,
            validateArguments: original.validateArguments, preflightSubmission: original.preflightSubmission,
            routing: ToolEnvironmentRouting())
    }
    private func receipt(_ output: ToolExecutionOutput) throws -> DelimitedSheetOutput.Receipt {
        #expect(output.exitStatus == 0)
        return try JSONDecoder().decode(DelimitedSheetOutput.Receipt.self, from: Data(output.summary.utf8))
    }
    @Test func registeredCSVToNativeAnalysisAndSavedArtifacts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data([0xEF,0xBB,0xBF]) + Data("label,x,y\r\n\"oil,粉\",001,2\r\n\"two\r\nlines\",2,4\r\n=literal,3,6\r\n".utf8)
        try bytes.write(to: root.appendingPathComponent("input.csv"))
        let registry = ToolRunnerRegistry()
        registry.register(fixtureRunner(DocumentReadSheetTool(rootProvider: { nil })))
        registry.register(fixtureRunner(NativeDataAnalysisTool()))
        registry.register(fixtureRunner(PresentationArtifactTool(rootURLProvider: { root })))
        let context = ToolContext(runID: UUID(), toolCallID: "csv-read", workspaceRootURL: root, allowedWorkspacePaths: ["input.csv"], cancellation: CancellationToken(), conversationID: UUID())
        let read = try await invoke("document.readSheet", ["path":"input.csv","hasHeader":true,"numericColumns":[2,3],"analysis":"linearRegression"], registry: registry, context: context)
        let page = try receipt(read)
        #expect(page.source.sha256 == FloeDigest.sha256Hex(bytes)); #expect(page.source.bomBytes == 3)
        #expect(page.taskID == context.conversationID); #expect(page.runID == context.runID); #expect(page.callID == context.toolCallID)
        #expect(page.page.wholeFileData); #expect(page.page.totalDataRows == 3)
        #expect(page.page.rows.map(\.cells) == [["oil,粉","001","2"],["two\r\nlines","2","4"],["=literal","3","6"]])
        #expect(page.page.rows.map(\.lineStart) == [2,3,5]); #expect(page.page.rows.map(\.lineEnd) == [2,4,5])
        let numeric = try #require(page.numericSelection?.arguments)
        let encoded = try JSONEncoder().encode(numeric)
        let analysisRunner = try #require(registry.runner(named: "data.analyze"))
        let output = try await analysisRunner.execute(argumentsJSON: encoded, context: context)
        let report = try JSONDecoder().decode(ScientificDataAnalysis.Report.self, from: Data(output.summary.utf8))
        #expect(report.regression?.slope == 2); #expect(report.regression?.intercept == 0); #expect(report.inputCount == 3)
        let table = try #require(page.presentation.tableArguments)
        let chart = try #require(page.presentation.chartArguments)
        for arguments in [try JSONEncoder().encode(table), try JSONEncoder().encode(chart)] {
            let runner = try #require(registry.runner(named: "document.presentation.createInline"))
            let saved = try await runner.execute(argumentsJSON: arguments, context: context)
            let ref = try #require(saved.artifacts.first)
            let data = try Data(contentsOf: root.appendingPathComponent(ref.relativePath))
            #expect(data.count == ref.byteCount); #expect(FloeDigest.sha256Hex(data) == ref.sha256)
            let metadata = try #require(JSONSerialization.jsonObject(with: Data(saved.summary.utf8)) as? [String:String])
            let reference = try #require(ChatContentReference(kind: .artifact, ownerID: context.runID, contentID: ref.id.uuidString))
            #expect(metadata["inlineMarkdown"] == reference.markdown(title: table.title))
            if ref.mimeType == "application/vnd.floe.table+json" {
                let document = try JSONDecoder().decode(PresentationTableDocument.self, from: data)
                #expect(document.rows == page.page.rows.map(\.cells)); #expect(document.rows[2][0] == "=literal")
            } else {
                let document = try JSONDecoder().decode(PresentationChartDocument.self, from: data)
                #expect(document.series.count == 2); #expect(document.series[0].points.map(\.value) == [1,2,3])
                #expect(document.series[0].points.map(\.label) == ["Record 2","Record 3","Record 4"])
            }
        }
        #expect(try Data(contentsOf: root.appendingPathComponent("input.csv")) == bytes)
    }
    @Test func pagesRequireActualSourceHashAndNeverClaimWholeFileStatistics() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("page.csv"); try Data("n\n1\n2\n3\n".utf8).write(to: url)
        let tool = DocumentReadSheetTool(rootProvider: { root })
        let context = ToolContext(runID: UUID(), workspaceRootURL: root, cancellation: CancellationToken())
        let first = try receipt(await tool.execute(.init(path:"page.csv",maxRows:1,hasHeader:true,numericColumns:[1]),context:context))
        #expect(!first.page.wholeFileData); #expect(first.page.totalDataRows == 3); #expect(first.page.nextOffset == 1)
        #expect(first.numericSelection?.scope == "returned-page-only"); #expect(first.numericSelection?.arguments?.values == [1])
        let missing = try await tool.execute(.init(path:"page.csv",offset:1,hasHeader:true),context:context)
        #expect(missing.exitStatus == 2); #expect(missing.summary.contains("missing_revision"))
        let next = try receipt(await tool.execute(.init(path:"page.csv",maxRows:1,offset:1,expectedSHA256:first.source.sha256,hasHeader:true),context:context))
        #expect(next.page.rows.map(\.number) == [3]); #expect(next.page.rows.first?.cells == ["2"])
        try Data("n\n9\n2\n3\n".utf8).write(to:url,options:.atomic)
        let changed = try await tool.execute(.init(path:"page.csv",offset:2,expectedSHA256:first.source.sha256,hasHeader:true),context:context)
        #expect(changed.exitStatus == 2); #expect(!changed.summary.contains("org.floe.delimited-sheet"))
    }
    @Test func mixedRawValuesAndExplicitNullPairsRemainAligned() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mixed.tsv")
        try Data("x\ty\n1\t2\n\t4\n3\t6\n".utf8).write(to:url)
        let tool = DocumentReadSheetTool(rootProvider:{root}); let context = ToolContext(runID:UUID(),workspaceRootURL:root,cancellation:CancellationToken())
        let page = try receipt(await tool.execute(.init(path:"mixed.tsv",hasHeader:true,numericColumns:[1,2],analysis:.linearRegression,missingPolicy:.omit),context:context))
        let arguments = try #require(page.numericSelection?.arguments)
        #expect(arguments.values == [1,nil,3]); #expect(arguments.pairedValues == [2,4,6]); #expect(page.page.rows[1].cells == ["","4"])
        let request = try JSONDecoder().decode(ScientificDataAnalysis.Request.self,from:JSONEncoder().encode(arguments))
        let result = try ScientificDataAnalysis.analyze(request)
        #expect(result.inputCount == 3); #expect(result.omittedCount == 1); #expect(result.regression?.slope == 2)
        #expect(page.presentation.chartArguments == nil)
        try Data("x,y\n001,2\n 3,not-a-number\n1 kg,4\n".utf8).write(to:root.appendingPathComponent("invalid.csv"))
        let mixed = try receipt(await tool.execute(.init(path:"invalid.csv",hasHeader:true,numericColumns:[1,2],analysis:.linearRegression,missingPolicy:.omit),context:context))
        #expect(mixed.page.rows[1].cells == [" 3","not-a-number"]); #expect(mixed.page.rows[2].cells[0] == "1 kg")
        #expect(mixed.numericSelection?.arguments == nil); #expect(mixed.numericSelection?.issueCount == 3)
        #expect(mixed.numericSelection?.issues.map(\.record) == [3,3,4])
    }
    @Test @MainActor func cancelledReadDoesNotReturnAnErrorReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("n\n1\n".utf8).write(to: root.appendingPathComponent("input.csv"))
        let tool = DocumentReadSheetTool(rootProvider: { root })
        let context = ToolContext(runID: UUID(), workspaceRootURL: root, cancellation: CancellationToken())
        // This inherited MainActor task cannot start before the first await;
        // cancellation is deterministic and uses the actual owned read worker.
        let task = Task { try await tool.execute(.init(path: "input.csv"), context: context) }
        task.cancel()
        do { _ = try await task.value; Issue.record("A cancelled read returned an ordinary tool receipt.") }
        catch is CancellationError { }
        catch FloeError.cancelled { }
    }
    @Test func authorityTraversalAliasesIllegalQuotesAndCancellationReject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("allowed"),withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        try Data("private\n".utf8).write(to:root.appendingPathComponent("foreign.csv"))
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("allowed/alias.csv"),withDestinationURL:root.appendingPathComponent("foreign.csv"))
        let tool=DocumentReadSheetTool(rootProvider:{root})
        let context=ToolContext(runID:UUID(),workspaceRootURL:root,allowedWorkspacePaths:["allowed"],cancellation:CancellationToken())
        for path in ["../escape.csv","foreign.csv","allowed/alias.csv"] {
            let output=try await tool.execute(.init(path:path),context:context)
            #expect(output.exitStatus == 2); #expect(!output.summary.contains("org.floe.delimited-sheet"))
        }
        try Data("a,b\n\"bad\"x,2\n".utf8).write(to:root.appendingPathComponent("allowed/bad.csv"))
        let bad=try await tool.execute(.init(path:"allowed/bad.csv"),context:context)
        let failure=try JSONDecoder().decode(DelimitedSheetOutput.FailureReceipt.self,from:Data(bad.summary.utf8))
        #expect(failure.failure.code == "after_quote"); #expect(failure.failure.line == 2); #expect(failure.failure.column == 6)
        context.cancellation.cancel()
        await #expect(throws:(any Error).self) { try await tool.execute(.init(path:"allowed/bad.csv"),context:context) }
    }
}
#endif
