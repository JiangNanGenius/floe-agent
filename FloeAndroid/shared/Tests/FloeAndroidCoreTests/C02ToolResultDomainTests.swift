// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeCore
import FloeTools
import FloeAndroidToolResults
@testable import FloeAndroidCore

final class C02ToolResultDomainTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        C02ToolResultIntegration.uninstall(epoch: 7)
        C02ToolResultIntegration.uninstall(epoch: 8)
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    private func temporaryArtifactRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-results-bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    private func request(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func capture(
        _ runtime: C02ToolResultRuntime,
        task: UUID,
        run: UUID,
        call: String,
        text: String
    ) async -> ToolResultCaptureReceipt {
        await runtime.store.capture(
            conversationID: task,
            runID: run,
            callID: call,
            toolName: "exec.shell",
            status: "ok",
            text: text,
            temporary: false,
            originalDigest: FloeDigest.sha256Hex(Data(text.utf8))
        )
    }

    func testOfferedCeilingAddsTheReaderOnlyForOrdinaryRuns() {
        let ordinary = C02ToolResultIntegration.offeredToolNames(["workspace.readFile"], temporary: false)
        XCTAssertTrue(ordinary?.contains(ToolResultPagingTool.name) == true)
        let temporary = C02ToolResultIntegration.offeredToolNames(["workspace.readFile"], temporary: true)
        XCTAssertEqual(temporary ?? [], Set(["workspace.readFile"]))
        XCTAssertNil(C02ToolResultIntegration.offeredToolNames(nil, temporary: false))
    }

    func testHandshakeBindsTheRegisteredModelToolAndLimits() throws {
        let root = try temporaryArtifactRoot()
        let registry = ToolRunnerRegistry()
        let runtime = C02ToolResultIntegration.install(
            epoch: 7, artifactRoot: root, registry: registry, liveEpoch: { 7 }
        )
        XCTAssertNotNil(registry.descriptor(named: ToolResultPagingTool.name))
        XCTAssertEqual(ToolResultPagingTool.name, "tools.readResult")

        let reply = runtime.handle(
            requestData: request([
                "version": 20,
                "schema": "floe.results/20",
                "operation": "handshake",
                "requestID": "r1",
            ]),
            fallbackRequestID: nil
        )
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["schema"] as? String, "floe.results/20")
        XCTAssertEqual(reply["coreReady"] as? Bool, true)
        XCTAssertEqual(reply["modelResultTool"] as? String, "tools.readResult")
        XCTAssertEqual(reply["maximumPageBytes"] as? Int, 32_000)
        XCTAssertEqual(reply["modelTools"] as? Bool, false)
    }

    func testPageAndIndexReturnExactBytesAndStableIdentity() async throws {
        let root = try temporaryArtifactRoot()
        let registry = ToolRunnerRegistry()
        let runtime = C02ToolResultIntegration.install(
            epoch: 7, artifactRoot: root, registry: registry, liveEpoch: { 7 }
        )
        let task = UUID()
        let run = UUID()
        let text = "bridge-中文-😀-" + String(repeating: "x", count: 3_000)
        let receipt = await capture(runtime, task: task, run: run, call: "bridge-call", text: text)

        let indexReply = runtime.handle(
            requestData: request([
                "version": 20, "schema": "floe.results/20",
                "operation": "c02.results.index", "taskID": task.uuidString,
            ]),
            fallbackRequestID: nil
        )
        XCTAssertEqual(indexReply["ok"] as? Bool, true)
        let rows = try XCTUnwrap(indexReply["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["ref"] as? String, receipt.ref)
        XCTAssertEqual(rows[0]["sha256"] as? String, try XCTUnwrap(receipt.sha256))
        XCTAssertEqual(try XCTUnwrap(rows[0]["totalBytes"] as? Int), text.utf8.count)

        var offset = 0
        var assembled = ""
        var pages = 0
        while true {
            let reply = runtime.handle(
                requestData: request([
                    "version": 20, "schema": "floe.results/20",
                    "operation": "c02.results.page", "taskID": task.uuidString,
                    "ref": receipt.ref, "offset": offset, "length": 13,
                    "expectedSHA256": receipt.sha256 ?? "",
                ]),
                fallbackRequestID: nil
            )
            XCTAssertEqual(reply["ok"] as? Bool, true)
            let pageText = try XCTUnwrap(reply["text"] as? String)
            let extent = try XCTUnwrap(reply["endOffset"] as? Int)
            XCTAssertEqual(pageText.utf8.count, extent - offset)
            assembled += pageText
            pages += 1
            guard let next = reply["nextOffset"] as? Int else { break }
            XCTAssertEqual(next, extent)
            XCTAssertGreaterThan(next, offset)
            offset = next
            XCTAssertLessThan(pages, 10_000)
        }
        XCTAssertGreaterThan(pages, 10)
        XCTAssertEqual(assembled, text)
        XCTAssertEqual(FloeDigest.sha256Hex(Data(assembled.utf8)), try XCTUnwrap(receipt.sha256))
    }

    func testCrossTaskTemporaryChangedAndMissingAreHonest() async throws {
        let root = try temporaryArtifactRoot()
        let registry = ToolRunnerRegistry()
        let runtime = C02ToolResultIntegration.install(
            epoch: 7, artifactRoot: root, registry: registry, liveEpoch: { 7 }
        )
        let task = UUID()
        let otherTask = UUID()
        let run = UUID()
        let text = "private task bytes"
        let receipt = await capture(runtime, task: task, run: run, call: "private", text: text)

        let cross = runtime.handle(
            requestData: request([
                "version": 20, "schema": "floe.results/20",
                "operation": "c02.results.page", "taskID": otherTask.uuidString,
                "callID": "private", "runID": run.uuidString, "offset": 0,
            ]),
            fallbackRequestID: nil
        )
        XCTAssertEqual(cross["ok"] as? Bool, false)
        XCTAssertEqual(cross["code"] as? String, "missing")

        let exactWrongRun = runtime.handle(
            requestData: request([
                "version": 20, "schema": "floe.results/20",
                "operation": "c02.results.page", "taskID": task.uuidString,
                "callID": "private", "runID": UUID().uuidString,
                "offset": 0, "exactRun": true,
            ]),
            fallbackRequestID: nil
        )
        XCTAssertEqual(exactWrongRun["ok"] as? Bool, false)
        XCTAssertEqual(exactWrongRun["code"] as? String, "missing")

        let temporary = runtime.handle(
            requestData: request([
                "version": 20, "schema": "floe.results/20",
                "operation": "c02.results.page", "taskID": task.uuidString,
                "callID": "private", "offset": 0, "temporary": true,
            ]),
            fallbackRequestID: nil
        )
        XCTAssertEqual(temporary["ok"] as? Bool, false)
        XCTAssertEqual(temporary["code"] as? String, "temporaryTaskRefused")

        let changed = runtime.handle(
            requestData: request([
                "version": 20, "schema": "floe.results/20",
                "operation": "c02.results.page", "taskID": task.uuidString,
                "ref": receipt.ref, "offset": 0,
                "expectedSHA256": String(repeating: "0", count: 64),
            ]),
            fallbackRequestID: nil
        )
        XCTAssertEqual(changed["ok"] as? Bool, false)
        XCTAssertEqual(changed["code"] as? String, "changed")
        XCTAssertEqual(changed["actualSHA256"] as? String, receipt.sha256)
        XCTAssertNil(changed["text"])
    }

    func testRetiredEpochCannotServeBytesAndUninstallDropsTheBridge() async throws {
        let root = try temporaryArtifactRoot()
        let registry = ToolRunnerRegistry()
        let runtime = C02ToolResultIntegration.install(
            epoch: 7, artifactRoot: root, registry: registry, liveEpoch: { 8 }
        )
        let task = UUID()
        let receipt = await capture(runtime, task: task, run: UUID(), call: "retired", text: "bytes")
        let reply = runtime.handle(
            requestData: request([
                "version": 20, "schema": "floe.results/20",
                "operation": "c02.results.page", "taskID": task.uuidString,
                "ref": receipt.ref, "offset": 0,
            ]),
            fallbackRequestID: nil
        )
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["code"] as? String, "rootEpochUnavailable")

        C02ToolResultIntegration.uninstall(epoch: 7)
        XCTAssertNil(C02ToolResultIntegration.current)
    }

    func testSearchIsTaskScopedAndReturnsMatchOffsets() async throws {
        let root = try temporaryArtifactRoot()
        let registry = ToolRunnerRegistry()
        let runtime = C02ToolResultIntegration.install(
            epoch: 7, artifactRoot: root, registry: registry, liveEpoch: { 7 }
        )
        let task = UUID()
        let other = UUID()
        _ = await capture(runtime, task: task, run: UUID(), call: "s1", text: "alpha needle omega")
        _ = await capture(runtime, task: other, run: UUID(), call: "s2", text: "other needle")

        let reply = runtime.handle(
            requestData: request([
                "version": 20, "schema": "floe.results/20",
                "operation": "c02.results.search", "taskID": task.uuidString,
                "query": "needle",
            ]),
            fallbackRequestID: nil
        )
        XCTAssertEqual(reply["ok"] as? Bool, true)
        let hits = try XCTUnwrap(reply["hits"] as? [[String: Any]])
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0]["callID"] as? String, "s1")
        XCTAssertEqual(try XCTUnwrap(hits[0]["matchOffset"] as? Int), 6)
        XCTAssertTrue((hits[0]["excerpt"] as? String)?.contains("needle") == true)
    }
}
