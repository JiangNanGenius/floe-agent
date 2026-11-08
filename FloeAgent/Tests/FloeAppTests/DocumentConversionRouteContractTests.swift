#if canImport(UIKit) && DEBUG
import Foundation
import XCTest
import FloeCore
import FloeModels
import FloeTools
import FloeSecurity
import FloePersistence
import FloeAgentRuntime
import FloeTestSupport
@testable import FloeApp

@MainActor final class DocumentConversionRouteContractTests: XCTestCase {
    func testReportedNonPDFPayloadNamesCorrectToolAndCompleteJSON() throws {
        let arguments = DocumentConversionArguments(inputPath: "interactive-charts/index.html",
            outputPath: "interactive-charts/unused.txt", format: "text")
        try DocumentConvertTool().validate(arguments)
        XCTAssertThrowsError(try PDFConvertTool().validate(arguments)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("Call document.convert with"), message)
            guard let start = message.firstIndex(of: "{"), let end = message.lastIndex(of: "}") else {
                XCTFail("The correction omitted its complete payload"); return
            }
            let data = Data(message[start...end].utf8)
            let corrected = try? JSONDecoder().decode(DocumentConversionArguments.self, from: data)
            XCTAssertEqual(corrected?.inputPath, arguments.inputPath)
            XCTAssertEqual(corrected?.outputPath, arguments.outputPath)
            XCTAssertEqual(corrected?.format, "text")
        }
        let pdf = DocumentConversionArguments(inputPath: "source.pdf", outputPath: "copy.txt", format: "text")
        try PDFConvertTool().validate(pdf)
        XCTAssertThrowsError(try DocumentConvertTool().validate(pdf)) {
            XCTAssertTrue($0.localizedDescription.contains("Call document.pdf.convert with"))
        }
    }

    func testMismatchedExtensionsAndUnsupportedSourceHaveSpecificErrors() throws {
        let mismatched = DocumentConversionArguments(inputPath: "index.html", outputPath: "unused.pdf", format: "text")
        XCTAssertThrowsError(try DocumentConvertTool().validate(mismatched)) {
            XCTAssertTrue($0.localizedDescription.contains("outputPath must have the .txt extension"))
        }
        let excel = DocumentConversionArguments(inputPath: "source.xlsx", outputPath: "unused.txt", format: "text")
        XCTAssertThrowsError(try DocumentConvertTool().validate(excel)) {
            XCTAssertTrue($0.localizedDescription.contains("use document.pdf.convert, format=pdf"))
        }
    }

    func testRegisteredHTMLToTextPersistsVerifiedOutputAndPreservesSource() async throws {
        executionTimeAllowance = 180
        let environment = FloeAgentApp.liveEnvironment
        try await environment.ensureDurableAutomationReady()
        // Inspect actual App composition: no replacement runner, output receipt,
        // authority record, converter or approval grant is injected.
        for name in [DocumentConvertTool.name, PDFConvertTool.name] {
            let registered = try XCTUnwrap(ToolRunnerRegistry.shared.runner(named: name))
            XCTAssertEqual(registered.descriptor.name, name)
        }
        let task = UUID(), run = UUID(), now = Date()
        try await environment.conversationStore.saveConversation(.init(id: task,
            title: "QA HTML conversion " + task.uuidString, createdAt: now, updatedAt: now, titleOrigin: .manual))
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let root = documents.appendingPathComponent("Qualification/DocumentConversionRoute-" + task.uuidString)
        let input = root.appendingPathComponent("interactive-charts/index.html")
        let output = root.appendingPathComponent("interactive-charts/unused.txt")
        try FileManager.default.createDirectory(at: input.deletingLastPathComponent(), withIntermediateDirectories: true)
        let source = Data("<!doctype html><html><body><h1>原生图表 Chart</h1><p>保留这份原件。Keep the source.</p></body></html>".utf8)
        try source.write(to: input, options: .atomic)
        let payload = #"{"format":"text","inputPath":"interactive-charts/index.html","outputPath":"interactive-charts/unused.txt"}"#
        let bad = try ToolCall(id: "wrong-pdf-route", toolName: PDFConvertTool.name,
            argumentsJSON: Data(payload.utf8), scope: .local)
        let schema = try ToolCall(id: "correct-schema", toolName: "tools.search",
            argumentsJSON: Data(#"{"queries":["document.convert"]}"#.utf8), scope: .local)
        let good = try ToolCall(id: "correct-html-text", toolName: DocumentConvertTool.name,
            argumentsJSON: Data(payload.utf8), scope: .local)
        let overwrite = try ToolCall(id: "refuse-overwrite", toolName: DocumentConvertTool.name,
            argumentsJSON: Data(payload.utf8), scope: .local)
        let adapter = MockAdapter()
        adapter.script = [bad, schema, good, overwrite].map { [.toolRequest($0)] }
            + [[.textDelta(.init(text: "Conversion finished; the existing output was preserved.")), .completed(.init(stopReason: .endTurn))]]
        let provider = TestFixtures.localhostProvider()
        let service = ConversationRunService(configuration: .init(conversationID: task, provider: provider,
            model: TestFixtures.testModel(providerID: provider.id),
            allowedToolNames: [DocumentConvertTool.name, PDFConvertTool.name], workspaceRootURL: root,
            pauseTimeout: 0.5, verifyFinalAnswer: false, maxProviderRetries: 0),
            adapter: adapter, policy: AutomaticApprovalPolicy(), executor: CatalogToolExecutor(),
            conversationStore: environment.conversationStore, runStore: environment.runStore, runID: run)
        try await service.start(goal: "Convert this synthetic existing HTML file to new text, without modifying the original or overwriting any file.")
        XCTAssertEqual(try Data(contentsOf: input), source)
        let bytes = try Data(contentsOf: output), text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains("原生图表"), text)
        XCTAssertTrue(text.contains("Keep the source."), text)
        XCTAssertFalse(text.contains("<html>"), text)
        let events = try await environment.runStore.events(runID: run)
        let results = try events.filter { $0.kind == .toolResult }.map {
            try JSONDecoder().decode([String: String].self, from: Data($0.payloadJSON.utf8))
        }
        XCTAssertEqual(results.first { $0["id"] == bad.id }?["status"], "failed")
        XCTAssertTrue(results.first { $0["id"] == bad.id }?["summary"]?.contains("Call document.convert with") == true)
        XCTAssertEqual(results.first { $0["id"] == good.id }?["status"], "ok")
        XCTAssertEqual(results.first { $0["id"] == overwrite.id }?["status"], "failed")
        XCTAssertTrue(results.first { $0["id"] == overwrite.id }?["summary"]?.contains("Output exists") == true)
        let reader = SQLiteRunOutputReader(database: environment.database)
        let rows = try await reader.manifestRows(runID: run, expectedConversationID: task)
        let row = try XCTUnwrap(rows.first { $0.callID == good.id })
        let receipt = try XCTUnwrap(row.receipts.first)
        XCTAssertEqual(receipt.taskID, task)
        XCTAssertEqual(receipt.producerTool, DocumentConvertTool.name)
        XCTAssertEqual(receipt.producerCallID, good.id)
        XCTAssertTrue(receipt.hasRuntimeConsistentIdentity)
        XCTAssertEqual(receipt.sha256, FloeDigest.sha256Hex(bytes))
        guard case .verified(let snapshot) = RunOutputSnapshotStore.verify(receipt) else {
            XCTFail("Persisted output did not reopen through the real snapshot verifier"); return
        }
        XCTAssertEqual(try Data(contentsOf: snapshot), bytes)
        let foreign = try await reader.manifestRows(runID: run, expectedConversationID: UUID())
        XCTAssertTrue(foreign.isEmpty)
        // Kept only until Root exports proof and completes this owned fixture's
        // cleanup through the ordinary task-deletion lifecycle.
        print("FLOE_CONVERSION_ROUTE_CONTRACT|task=\(task)|run=\(run)|root=\(root.path)|sha256=\(receipt.sha256)")
    }
}
#endif
