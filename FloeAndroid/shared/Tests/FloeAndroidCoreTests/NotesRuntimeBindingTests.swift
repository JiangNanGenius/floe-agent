// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
@testable import FloeAndroidCore

/// Focused proof that the accepted CoreRoot (not Linux, provider or model
/// setup) is sufficient to bind the Notes channel, and that one explicit
/// command reaches the real service-owned NotesStore through `floe.notes/4`.
final class NotesRuntimeBindingTests: XCTestCase {
    private let token = "a06f0e50000000000000000000000001"
    private var root: String?

    override func tearDown() async throws {
        await NotesDomainService.shared.retire(epoch: 42)
        G02RuntimeComposition.shared.resetForTesting()
        AndroidRuntimeBootstrap.resetForTesting()
        if let root { try? FileManager.default.removeItem(atPath: root) }
        root = nil
        try await super.tearDown()
    }

    private func freshRoot() throws -> String {
        let value = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("floe-g06-notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        root = value.standardizedFileURL.path
        return root!
    }

    private func waitForStoreReady(timeout: TimeInterval = 20) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if AndroidRuntimeBootstrap.statusSnapshotJSON().contains("\"ownedStoreReady\":true") {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    private func waitForShutdownTerminal(_ pump: FacadeEffectPump, receipt: String,
                                         timeout: TimeInterval = 20) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .page(let items, _, _, _) = pump.poll(receipt: receipt, afterSequence: 0),
               items.contains(where: { $0.isTerminal }) {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func testAcceptedCoreRootAloneBindsAndPersistsAnExplicitNotesMessage() async throws {
        let root = try freshRoot()
        guard case .accepted(let bootstrapReceipt) =
                AndroidRuntimeBootstrap.start(rootPath: root, ownerToken: token, epoch: 42) else {
            return XCTFail("runtime start")
        }
        let storeReady = await waitForStoreReady()
        XCTAssertTrue(storeReady, "CoreRoot store never became ready")
        let generation = try XCTUnwrap(AndroidRuntimeBootstrap.currentGenerationForTesting())
        let receipt = bootstrapReceipt
        XCTAssertFalse(receipt.isEmpty)

        let bind = BridgeV4.handle(
            requestData: Data("""
            {"version":4,"requestID":"bind-1","operation":"bind","epoch":42,"ownerToken":"\(token)"}
            """.utf8),
            fallbackRequestID: "bind-1")
        XCTAssertEqual(bind["ok"] as? Bool, true)
        XCTAssertEqual(bind["bound"] as? Bool, true)
        XCTAssertEqual(bind["storeOpen"] as? Bool, false)

        let command = BridgeV4.handle(
            requestData: Data("""
            {"version":4,"requestID":"cmd-1","operation":"command","epoch":42,
             "action":"document.saveMessage","payload":{"text":"Runtime-bound note","title":"Runtime"}}
            """.utf8),
            fallbackRequestID: "cmd-1")
        XCTAssertEqual(command["ok"] as? Bool, true)
        let document = try XCTUnwrap(command["document"] as? [String: Any])
        XCTAssertEqual(document["kind"] as? String, "notebook")
        XCTAssertEqual((document["pages"] as? [[String: Any]])?.count, 1)

        let list = BridgeV4.handle(
            requestData: Data("""
            {"version":4,"requestID":"list-1","operation":"command","epoch":42,
             "action":"document.list","payload":{"limit":10}}
            """.utf8),
            fallbackRequestID: "list-1")
        XCTAssertEqual(list["ok"] as? Bool, true)
        let documents = try XCTUnwrap(list["documents"] as? [[String: Any]])
        XCTAssertEqual(documents.count, 1)
        XCTAssertEqual(documents.first?["title"] as? String, "Runtime")
        XCTAssertEqual(documents.first?["kind"] as? String, "notebook")

        guard case .accepted(let control) =
                AndroidRuntimeBootstrap.shutdown(expectedEpoch: 42, ownerToken: token) else {
            return XCTFail("runtime shutdown admission")
        }
        let settled = await waitForShutdownTerminal(generation.effects, receipt: control)
        XCTAssertTrue(settled, "runtime generation did not settle")
    }
}
