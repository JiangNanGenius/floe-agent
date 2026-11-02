// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
@testable import FloeAndroidCore

final class C08NotesTaskLaunchTests: XCTestCase {
    private func selection(conversationID: UUID = UUID(), receiptID: UUID = UUID()) -> C08NotesTaskLaunchSelection {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return C08NotesTaskLaunchSelection(receiptID: receiptID, notesEpoch: 7,
            conversationID: conversationID, documentID: UUID(), documentRevision: 1,
            resources: [C08NotesTaskLaunchResource(resourceID: UUID(), sha256: String(repeating: "a", count: 64),
                byteCount: 32, fileName: "drawing.pdf", mediaType: "application/pdf")],
            createdAtMillis: now, expiresAtMillis: now + 60_000)
    }

    func testReceiptIsImmutableAndScopedToItsConversation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = selection()
        let store = C08NotesTaskLaunchFileReceiptStore()
        let prepared = try store.prepare(input, receiptRoot: root)
        XCTAssertEqual(try store.prepare(input, receiptRoot: root), prepared)
        XCTAssertNil(try store.pending(forConversation: UUID(), receiptRoot: root, now: Date()))
        XCTAssertEqual(try store.pending(forConversation: input.conversationID, receiptRoot: root, now: Date()), input)
        var changed = input
        changed.resources[0].fileName = "different.pdf"
        XCTAssertThrowsError(try store.prepare(changed, receiptRoot: root))
        XCTAssertEqual(try store.pending(forConversation: input.conversationID, receiptRoot: root, now: Date()), input)
    }

    func testWrongOwnerCannotDiscardAndCompletedReceiptIsGone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = selection()
        let store = C08NotesTaskLaunchFileReceiptStore()
        _ = try store.prepare(input, receiptRoot: root)
        XCTAssertFalse(try store.discard(receiptID: input.receiptID, conversationID: UUID(), receiptRoot: root))
        XCTAssertNotNil(try store.pending(forConversation: input.conversationID, receiptRoot: root, now: Date()))
        try store.complete(receiptID: input.receiptID, receiptRoot: root)
        XCTAssertNil(try store.pending(forConversation: input.conversationID, receiptRoot: root, now: Date()))
    }

    func testOversizedResourceRefusesBeforeReceiptDirectoryCreation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var input = selection()
        input.resources[0].byteCount = Int64.max
        XCTAssertThrowsError(try C08NotesTaskLaunchFileReceiptStore().prepare(input, receiptRoot: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testManifestRequiresEveryExactCommittedDestination() {
        let id = UUID()
        let destination = C08NotesTaskLaunchDestination(resourceID: UUID(), relativePath: "NotesImports/document/source.pdf")
        let full = C08NotesTaskLaunchManifest.combined(prompt: "Read the PDF", receiptID: id, destinations: [destination])
        XCTAssertEqual(C08NotesTaskLaunchManifest.mention(in: full, receiptID: id, destinations: [destination]), .complete)
        XCTAssertEqual(C08NotesTaskLaunchManifest.mention(in: id.uuidString, receiptID: id, destinations: [destination]), .partial)
        XCTAssertEqual(C08NotesTaskLaunchManifest.mention(in: "Changed my mind", receiptID: id, destinations: [destination]), .absent)
    }

    func testIndependentStoreInstancesShareTheImmutableReceiptLock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = selection()
        let accepted = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<8 {
                var input = base
                input.resources[0].fileName = "version-\(index).pdf"
                let frozen = input
                group.addTask {
                    (try? C08NotesTaskLaunchFileReceiptStore().prepare(frozen, receiptRoot: root)) != nil
                }
            }
            var count = 0
            for await success in group { if success { count += 1 } }
            return count
        }
        XCTAssertEqual(accepted, 1)
        XCTAssertNotNil(try C08NotesTaskLaunchFileReceiptStore().pending(
            forConversation: base.conversationID, receiptRoot: root, now: Date()))
    }
}
