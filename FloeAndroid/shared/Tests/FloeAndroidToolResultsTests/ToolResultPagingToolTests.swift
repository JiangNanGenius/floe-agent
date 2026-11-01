// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeCore
import FloeModels
import FloeTools
@testable import FloeAndroidToolResults

final class ToolResultPagingToolTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-tool-paging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    private func context(
        task: UUID?,
        temporary: Bool = false
    ) -> ToolContext {
        ToolContext(
            runID: UUID(),
            toolCallID: "read-call",
            cancellation: CancellationToken(),
            conversationID: task,
            temporaryReadOnly: temporary
        )
    }

    func testPageUsesActualNextOffsetAndReturnsWholeUTF8Windows() async throws {
        let root = try temporaryRoot()
        let store = ToolResultCaptureStore(durableRoot: root, caps: .durableStandard)
        let task = UUID()
        let text = String(repeating: "值😀abc", count: 3_000)
        let receipt = await store.capture(
            conversationID: task,
            runID: UUID(),
            callID: "page-call",
            toolName: "exec.shell",
            status: "ok",
            text: text,
            temporary: false
        )
        let tool = ToolResultPagingTool(store: store)
        var offset = 0
        var assembled = ""
        var pageCount = 0
        while true {
            let output = try await tool.execute(
                .init(callID: "page-call", offset: offset, length: 257),
                context: context(task: task)
            )
            XCTAssertEqual(try XCTUnwrap(output.exitStatus), 0)
            let rendered = output.summary
            XCTAssertTrue(rendered.contains("status=ok"))
            XCTAssertTrue(rendered.contains("sha256=\(try XCTUnwrap(receipt.sha256))"))
            guard let body = rendered.components(separatedBy: "\n--- output ---\n").last else {
                return XCTFail("page body missing")
            }
            XCTAssertFalse(body.isEmpty)
            let header = rendered.components(separatedBy: "\n--- output ---\n").first ?? ""
            let end = try XCTUnwrap(intField("endOffset", in: header))
            let next = intField("nextOffset", in: header)
            XCTAssertEqual(body.utf8.count, end - offset)
            assembled += body
            pageCount += 1
            if next == nil { break }
            XCTAssertEqual(next, end)
            XCTAssertGreaterThan(next!, offset)
            offset = next!
            XCTAssertLessThan(pageCount, 10_000)
        }
        XCTAssertGreaterThan(pageCount, 10)
        XCTAssertEqual(assembled, text)
        XCTAssertEqual(FloeDigest.sha256Hex(Data(assembled.utf8)), try XCTUnwrap(receipt.sha256))
    }

    func testIndexListsStableRefsAndMissingPagesStayHonest() async throws {
        let root = try temporaryRoot()
        let store = ToolResultCaptureStore(durableRoot: root, caps: .durableStandard)
        let task = UUID()
        let receipt = await store.capture(
            conversationID: task,
            runID: UUID(),
            callID: "indexed",
            toolName: "web.fetch",
            status: "ok",
            text: "indexed bytes",
            temporary: false
        )
        let tool = ToolResultPagingTool(store: store)
        let index = try await tool.execute(.init(), context: context(task: task))
        XCTAssertTrue(index.summary.contains("status=ok mode=index retained=1"))
        XCTAssertTrue(index.summary.contains("ref=\(receipt.ref)"))

        let missing = try await tool.execute(
            .init(callID: "never-ran"),
            context: context(task: task)
        )
        XCTAssertEqual(try XCTUnwrap(missing.exitStatus), 66)
        XCTAssertTrue(missing.summary.contains("status=missing"))
        XCTAssertFalse(missing.summary.contains("--- output ---"))

        let otherTask = try await tool.execute(
            .init(ref: receipt.ref),
            context: context(task: UUID())
        )
        XCTAssertEqual(try XCTUnwrap(otherTask.exitStatus), 66)
        XCTAssertTrue(otherTask.summary.contains("status=missing"))
    }

    func testChangedDigestRefusesRatherThanMixingBytes() async throws {
        let root = try temporaryRoot()
        let store = ToolResultCaptureStore(durableRoot: root, caps: .durableStandard)
        let task = UUID()
        let run = UUID()
        let first = await store.capture(
            conversationID: task, runID: run, callID: "rev",
            toolName: "exec.shell", status: "ok", text: "revision one", temporary: false
        )
        let second = await store.capture(
            conversationID: task, runID: run, callID: "rev",
            toolName: "exec.shell", status: "ok", text: "revision two", temporary: false
        )
        let tool = ToolResultPagingTool(store: store)
        let output = try await tool.execute(
            .init(ref: second.ref, offset: 0, expectedSHA256: first.sha256),
            context: context(task: task)
        )
        XCTAssertEqual(try XCTUnwrap(output.exitStatus), 0)
        XCTAssertTrue(output.summary.contains("status=changed"))
        XCTAssertFalse(output.summary.contains("--- output ---"))
    }

    func testTemporaryRunCannotReadPersistentResults() async throws {
        let root = try temporaryRoot()
        let store = ToolResultCaptureStore(durableRoot: root, caps: .durableStandard)
        let task = UUID()
        _ = await store.capture(
            conversationID: task, runID: UUID(), callID: "persisted",
            toolName: "exec.shell", status: "ok", text: "persisted bytes", temporary: false
        )
        let tool = ToolResultPagingTool(store: store)
        let output = try await tool.execute(
            .init(callID: "persisted"),
            context: context(task: task, temporary: true)
        )
        XCTAssertEqual(try XCTUnwrap(output.exitStatus), 66)
        XCTAssertTrue(output.summary.contains("status=unavailable"))
        XCTAssertFalse(output.summary.contains("persisted bytes"))
    }

    func testValidationRefusesOversizeAndAmbiguousRequests() {
        let tool = ToolResultPagingTool(
            store: ToolResultCaptureStore(durableRoot: nil, caps: .memoryStandard)
        )
        XCTAssertThrowsError(try tool.validate(.init(ref: "../../etc/passwd")))
        XCTAssertThrowsError(try tool.validate(.init(offset: -1)))
        XCTAssertThrowsError(try tool.validate(.init(length: 0)))
        XCTAssertThrowsError(try tool.validate(.init(length: 32_001)))
        XCTAssertThrowsError(try tool.validate(.init(maxBytes: 255)))
        XCTAssertThrowsError(try tool.validate(.init(query: "x", callID: "y")))
        XCTAssertThrowsError(try tool.validate(.init(expectedSHA256: "not-a-digest")))
        XCTAssertNoThrow(try tool.validate(.init(callID: "ok", offset: 0, maxBytes: 4_096)))
    }

    func testProjectionNoteIsIdempotentAndBounded() {
        let ref = ToolResultCaptureStore.reference(runID: UUID(), callID: "c")
        let once = ToolResultProjection.annotated(
            "summary", ref: ref, totalBytes: 12_345,
            retentionTruncated: false,
            executionReportedTruncation: true
        )
        XCTAssertTrue(once.contains("ref=\(ref)"))
        XCTAssertTrue(once.contains("bytes=12345"))
        XCTAssertTrue(once.contains("executionReportedTruncation") == false)
        XCTAssertTrue(once.contains("the tool reported truncating its own output"))
        let twice = ToolResultProjection.annotated(once, ref: ref, totalBytes: 12_345)
        XCTAssertEqual(once, twice)
        XCTAssertLessThanOrEqual(
            once.utf8.count - "summary".utf8.count,
            ToolResultProjection.maximumReferenceNoteBytes
        )
    }

    private func intField(_ name: String, in header: String) -> Int? {
        for component in header.split(separator: " ") {
            if component.hasPrefix("\(name)=") {
                let value = component.dropFirst(name.count + 1)
                if value == "none" { return nil }
                return Int(value)
            }
        }
        return nil
    }
}
