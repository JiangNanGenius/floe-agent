// SPDX-License-Identifier: MPL-2.0
//
// Regression for the global RAM payload cache in ToolResultCaptureStore.
// Main-owned test target; apply to shared/Tests/FloeAndroidToolResultsTests.
import XCTest
import Foundation
import FloeCore
@testable import FloeAndroidToolResults

final class C07PayloadCacheTests: XCTestCase {
    private func text(_ label: String, _ bytes: Int) -> String {
        var value = "task=\(label)\n"
        while value.utf8.count < bytes {
            value += "0123456789abcdef0123456789abcdef\n"
        }
        return String(value.prefix(bytes))
    }

    func testGlobalBoundEvictsWholeTaskAndReloadsDurableBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "c07-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        let caps = ToolResultCaptureStore.Caps(
            perResultBytes: 64 * 1024,
            perTaskBytes: 64 * 1024,
            perTaskResults: 4,
            totalPayloadBytes: 96 * 1024)
        let store = ToolResultCaptureStore(durableRoot: root, caps: caps)
        let tasks = (0..<3).map { _ in UUID() }
        var refs: [UUID: String] = [:]
        for (index, task) in tasks.enumerated() {
            let receipt = await store.capture(
                conversationID: task, runID: UUID(),
                callID: UUID().uuidString, toolName: "exec.shell",
                status: "ok", text: text("\(index)", 60 * 1024),
                temporary: false)
            XCTAssertEqual(receipt.outcome, .retained)
            XCTAssertEqual(receipt.durability, ToolResultCapture.Durability.durable)
            refs[task] = receipt.ref
        }
        let stats = await store.payloadCacheStats()
        XCTAssertLessThanOrEqual(stats.retainedBytes, caps.totalPayloadBytes)
        XCTAssertLessThanOrEqual(stats.retainedTasks, 2)
        XCTAssertEqual(stats.payloadCapBytes, caps.totalPayloadBytes)

        // The oldest task was evicted from RAM; its durable record must load
        // from disk with the same bytes and ref.
        let oldest = try XCTUnwrap(tasks.first)
        let ref = try XCTUnwrap(refs[oldest])
        let page = await store.page(
            conversationID: oldest, ref: ref, offset: 0, maxBytes: 4_096)
        guard case .page(let value) = page else {
            return XCTFail("expected reload page, got \(page)")
        }
        XCTAssertTrue(value.restoredFromDisk)
        XCTAssertEqual(value.capture.ref, ref)
        XCTAssertTrue(value.text.hasPrefix("task=0\n"))
        XCTAssertEqual(value.capture.sha256.utf8.count, 64)
    }

    func testWriteFailedRamOnlyCopyReportsEvictionWithoutDurableClaim() async throws {
        let badRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "c07-badroot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: badRoot) }
        try Data("not a directory".utf8).write(to: badRoot)
        let caps = ToolResultCaptureStore.Caps(
            perResultBytes: 16 * 1024,
            perTaskBytes: 16 * 1024,
            perTaskResults: 2,
            totalPayloadBytes: 16 * 1024)
        let store = ToolResultCaptureStore(durableRoot: badRoot, caps: caps)
        let failedTask = UUID()
        let failed = await store.capture(
            conversationID: failedTask, runID: UUID(),
            callID: UUID().uuidString, toolName: "exec.shell",
            status: "ok", text: text("failed", 10 * 1024),
            temporary: false)
        XCTAssertEqual(failed.outcome, .retained)
        XCTAssertEqual(failed.durability, ToolResultCapture.Durability.durableWriteFailed)

        // Fill the global cache with another task; the RAM-only copy is the
        // LRU victim and cannot be reloaded from disk.
        _ = await store.capture(
            conversationID: UUID(), runID: UUID(),
            callID: UUID().uuidString, toolName: "exec.shell",
            status: "ok", text: text("other", 10 * 1024), temporary: false)
        let stats = await store.payloadCacheStats()
        XCTAssertGreaterThanOrEqual(stats.evictedCopies, 1)
        XCTAssertLessThanOrEqual(stats.retainedBytes, caps.totalPayloadBytes)
        let missing = await store.page(
            conversationID: failedTask, ref: failed.ref,
            offset: 0, maxBytes: 1_024)
        guard case .missing(_, let reason) = missing else {
            return XCTFail("expected missing after eviction, got \(missing)")
        }
        XCTAssertTrue(reason.contains("evicted"))
    }

    func testDeletionFenceAndSurvivorDurability() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "c07-fence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        let store = ToolResultCaptureStore(
            durableRoot: root, caps: .durableStandard)
        let first = UUID()
        let second = UUID()
        let firstRef = (await store.capture(
            conversationID: first, runID: UUID(),
            callID: UUID().uuidString, toolName: "exec.shell",
            status: "ok", text: "first", temporary: false)).ref
        let secondRef = (await store.capture(
            conversationID: second, runID: UUID(),
            callID: UUID().uuidString, toolName: "exec.shell",
            status: "ok", text: "second", temporary: false)).ref
        let purged = await store.purge(conversationID: first)
        XCTAssertTrue(purged.succeeded)
        let late = await store.capture(
            conversationID: first, runID: UUID(),
            callID: UUID().uuidString, toolName: "exec.shell",
            status: "ok", text: "late", temporary: false)
        XCTAssertEqual(late.outcome, .taskFenced)
        let survivor = await store.retainedCapture(
            conversationID: second, ref: secondRef)
        XCTAssertEqual(survivor?.text, "second")
        // The first task's ref is not readable after the fence, and the
        // second task is unaffected.
        let fenced = await store.page(
            conversationID: first, ref: firstRef,
            offset: 0, maxBytes: 1_024)
        guard case .missing = fenced else {
            return XCTFail("expected fenced task to be missing")
        }
    }
}
