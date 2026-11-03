// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeCore
@testable import FloeAndroidToolResults

final class ToolResultCaptureStoreTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-tool-results-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    private func capture(
        _ store: ToolResultCaptureStore,
        task: UUID,
        run: UUID,
        call: String,
        text: String,
        truncated: Bool = false,
        digest: String? = nil
    ) async -> ToolResultCaptureReceipt {
        await store.capture(
            conversationID: task,
            runID: run,
            callID: call,
            toolName: "exec.shell",
            status: "ok",
            text: text,
            temporary: false,
            executionReportedTruncation: truncated,
            originalDigest: digest
        )
    }

    func testUTF8PagesReassembleExactlyWithoutSyntheticBytes() async throws {
        let root = try temporaryRoot()
        let store = ToolResultCaptureStore(durableRoot: root, caps: .durableStandard)
        let task = UUID()
        let run = UUID()
        let text = String(repeating: "head-😀-中文-tail\n", count: 400)
        let receipt = await capture(store, task: task, run: run, call: "call-1", text: text)
        XCTAssertTrue(receipt.retained)
        XCTAssertEqual(receipt.totalBytes, text.utf8.count)

        var offset = 0
        var assembled = ""
        var pages = 0
        while true {
            let read = await store.page(
                conversationID: task, ref: receipt.ref, offset: offset, maxBytes: 7
            )
            guard case .page(let page) = read else {
                return XCTFail("unexpected read \(read)")
            }
            XCTAssertEqual(page.offset, offset)
            XCTAssertEqual(page.text.utf8.count, page.endOffset - page.offset)
            XCTAssertGreaterThan(page.text.utf8.count, 0)
            if let next = page.nextOffset {
                XCTAssertEqual(next, page.endOffset)
                XCTAssertGreaterThan(next, offset)
            }
            assembled += page.text
            pages += 1
            if page.nextOffset == nil { break }
            offset = page.nextOffset!
            XCTAssertLessThan(pages, 100_000)
        }
        XCTAssertGreaterThan(pages, 100)
        XCTAssertEqual(assembled, text)
        XCTAssertEqual(FloeDigest.sha256Hex(Data(assembled.utf8)), try XCTUnwrap(receipt.sha256))
    }

    func testRestartReloadsTheSameRetainedBytesWithoutReexecution() async throws {
        let root = try temporaryRoot()
        let task = UUID()
        let run = UUID()
        let text = "restart-visible-中文-" + String(repeating: "x", count: 20_000)
        let writer = ToolResultCaptureStore(durableRoot: root, caps: .durableStandard)
        let receipt = await capture(writer, task: task, run: run, call: "call-restart", text: text)

        let reader = ToolResultCaptureStore(durableRoot: root, caps: .durableStandard)
        let read = await reader.page(
            conversationID: task, ref: receipt.ref, offset: 0, maxBytes: 20_000
        )
        guard case .page(let page) = read else { return XCTFail("expected restored page") }
        XCTAssertTrue(page.restoredFromDisk)
        XCTAssertEqual(page.capture.durability, .durable)
        XCTAssertEqual(page.offset, 0)
        XCTAssertEqual(page.text, ToolResultUTF8.prefix(text, maxBytes: 20_000))
        XCTAssertEqual(page.endOffset, page.text.utf8.count)
        XCTAssertEqual(page.totalBytes, text.utf8.count)

        let index = await reader.taskIndex(conversationID: task, limit: 10)
        guard case .index(let rows, _) = index else { return XCTFail("expected index") }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].ref, receipt.ref)
        XCTAssertEqual(rows[0].sha256, try XCTUnwrap(receipt.sha256))
    }

    func testOtherTaskCannotReadByRefOrCallID() async throws {
        let root = try temporaryRoot()
        let store = ToolResultCaptureStore(durableRoot: root, caps: .durableStandard)
        let taskA = UUID()
        let taskB = UUID()
        let run = UUID()
        let receipt = await capture(store, task: taskA, run: run, call: "shared-call", text: "A-only")

        let byRef = await store.page(
            conversationID: taskB, ref: receipt.ref, offset: 0, maxBytes: 100
        )
        guard case .missing = byRef else { return XCTFail("cross-task ref leaked") }
        let byCall = await store.page(
            conversationID: taskB, runID: run, callID: "shared-call", offset: 0, maxBytes: 100
        )
        guard case .missing = byCall else { return XCTFail("cross-task call id leaked") }
    }

    func testChangedCaptureIsRefusedInsteadOfMixingRevisions() async throws {
        let root = try temporaryRoot()
        let store = ToolResultCaptureStore(durableRoot: root, caps: .durableStandard)
        let task = UUID()
        let run = UUID()
        let first = await capture(store, task: task, run: run, call: "c", text: "first revision")
        let second = await capture(store, task: task, run: run, call: "c", text: "second revision")
        XCTAssertNotEqual(first.sha256, second.sha256)

        let changed = await store.page(
            conversationID: task,
            ref: second.ref,
            offset: 0,
            maxBytes: 100,
            expectedSHA256: first.sha256
        )
        guard case .changed(_, let expected, let actual) = changed else {
            return XCTFail("expected changed")
        }
        XCTAssertEqual(expected, first.sha256)
        XCTAssertEqual(actual, second.sha256)
    }

    func testDeletedAndCorruptDurableRecordsFailClosed() async throws {
        let root = try temporaryRoot()
        let task = UUID()
        let run = UUID()
        let writer = ToolResultCaptureStore(durableRoot: root, caps: .durableStandard)
        let first = await capture(writer, task: task, run: run, call: "delete-me", text: "bytes")
        let directory = root.appendingPathComponent(task.uuidString, isDirectory: true)
        let firstURL = directory.appendingPathComponent(
            ToolResultCaptureStore.durableFileName(runID: run, callID: "delete-me")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        try FileManager.default.removeItem(at: firstURL)

        let reader = ToolResultCaptureStore(durableRoot: root, caps: .durableStandard)
        let deleted = await reader.page(
            conversationID: task, ref: first.ref, offset: 0, maxBytes: 100
        )
        guard case .missing = deleted else { return XCTFail("deleted record resurrected") }

        let second = await capture(reader, task: task, run: run, call: "corrupt-me", text: "bytes")
        let secondURL = directory.appendingPathComponent(
            ToolResultCaptureStore.durableFileName(runID: run, callID: "corrupt-me")
        )
        try Data("{not-json".utf8).write(to: secondURL)

        let reloaded = ToolResultCaptureStore(durableRoot: root, caps: .durableStandard)
        let corrupt = await reloaded.page(
            conversationID: task, ref: second.ref, offset: 0, maxBytes: 100
        )
        guard case .missing = corrupt else { return XCTFail("corrupt record was served") }
    }

    func testTemporaryAndNilRootStoresAreRAMOnly() async throws {
        let store = ToolResultCaptureStore(durableRoot: nil, caps: .memoryStandard)
        let task = UUID()
        let receipt = await store.capture(
            conversationID: task,
            runID: UUID(),
            callID: "temp",
            toolName: "web.fetch",
            status: "ok",
            text: "temporary bytes",
            temporary: true
        )
        XCTAssertEqual(try XCTUnwrap(receipt.durability), .memoryOnlyTemporary)
        let read = await store.page(
            conversationID: task, ref: receipt.ref, offset: 0, maxBytes: 100
        )
        guard case .page(let page) = read else { return XCTFail("RAM page missing") }
        XCTAssertEqual(page.text, "temporary bytes")

        let other = ToolResultCaptureStore(durableRoot: nil, caps: .memoryStandard)
        let missing = await other.page(
            conversationID: task, ref: receipt.ref, offset: 0, maxBytes: 100
        )
        guard case .missing = missing else { return XCTFail("RAM leaked across stores") }
    }

    func testCapsEvictOldestAndReportHonestTruncation() async throws {
        let root = try temporaryRoot()
        let store = ToolResultCaptureStore(
            durableRoot: root,
            caps: .init(perResultBytes: 16, perTaskBytes: 64, perTaskResults: 3)
        )
        let task = UUID()
        let run = UUID()
        var receipts: [ToolResultCaptureReceipt] = []
        for index in 0..<5 {
            receipts.append(await capture(
                store, task: task, run: run, call: "c\(index)",
                text: String(repeating: "\(index)", count: 40)
            ))
        }
        XCTAssertTrue(receipts[4].retentionTruncated)
        XCTAssertEqual(receipts[4].retainedBytes, 16)

        let indexRead = await store.taskIndex(conversationID: task, limit: 20)
        guard case .index(let rows, let evicted) = indexRead else {
            return XCTFail("expected index")
        }
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(evicted, 2)
        XCTAssertEqual(try XCTUnwrap(rows.first?.callID), "c4")

        let oldest = await store.page(
            conversationID: task, runID: run, callID: "c0", offset: 0, maxBytes: 100
        )
        guard case .missing = oldest else { return XCTFail("evicted record survived") }
        let retained = await store.page(
            conversationID: task, runID: run, callID: "c4", offset: 0, maxBytes: 100
        )
        guard case .page(let page) = retained else { return XCTFail("retained page missing") }
        XCTAssertTrue(page.capture.retentionTruncated)
        XCTAssertEqual(page.totalBytes, 16)
    }

    func testSearchIsLiteralBoundedAndUsesWholeScalarExcerpts() async throws {
        let root = try temporaryRoot()
        let store = ToolResultCaptureStore(durableRoot: root, caps: .durableStandard)
        let task = UUID()
        let run = UUID()
        _ = await capture(
            store, task: task, run: run, call: "search",
            text: "prefix 中文 needle \u{1F600} suffix"
        )
        let read = await store.search(conversationID: task, query: "needle")
        guard case .search(let result) = read else { return XCTFail("expected search") }
        XCTAssertEqual(result.hits.count, 1)
        XCTAssertTrue(result.hits[0].excerpt.contains("needle"))
        XCTAssertEqual(result.hits[0].callID, "search")
        XCTAssertEqual(result.searchedCaptures, 1)

        let absent = await store.search(conversationID: task, query: "not-present")
        guard case .search(let empty) = absent else { return XCTFail("expected search") }
        XCTAssertTrue(empty.hits.isEmpty)
    }

    func testPurgeFencesLateCaptureAndReads() async throws {
        let root = try temporaryRoot()
        let store = ToolResultCaptureStore(durableRoot: root, caps: .durableStandard)
        let task = UUID()
        let run = UUID()
        let receipt = await capture(store, task: task, run: run, call: "purged", text: "bytes")
        let purge = await store.purge(conversationID: task)
        XCTAssertTrue(purge.succeeded)
        XCTAssertTrue(purge.removedDurableDirectory)

        let read = await store.page(
            conversationID: task, ref: receipt.ref, offset: 0, maxBytes: 100
        )
        guard case .missing = read else { return XCTFail("purged record survived") }
        let late = await capture(store, task: task, run: run, call: "late", text: "late bytes")
        XCTAssertEqual(late.outcome, .taskFenced)
    }

    func testReferenceShapeRejectsFreeFormLookupKeys() {
        XCTAssertTrue(ToolResultCaptureStore.isGeneratedReference(
            ToolResultCaptureStore.reference(runID: UUID(), callID: "x")
        ))
        XCTAssertFalse(ToolResultCaptureStore.isGeneratedReference("../etc/passwd"))
        XCTAssertFalse(ToolResultCaptureStore.isGeneratedReference("tr_"))
        XCTAssertFalse(ToolResultCaptureStore.isGeneratedReference("tr_ABCDEF0123456789ABCDEF01"))
    }
}
