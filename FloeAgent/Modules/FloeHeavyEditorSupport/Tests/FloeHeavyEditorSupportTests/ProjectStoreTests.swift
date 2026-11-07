// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeHeavyEditorSupport

@Test func commitChecksRevisionAcrossStoreInstances() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID(), document = HeavyEditorDocument(id: id, kind: .gis, title: "Map", content: .object(["layers": .array([])]))
    let first = try HeavyEditorProjectStore(directory: root, documentID: id, kind: .gis)
    let second = try HeavyEditorProjectStore(directory: root, documentID: id, kind: .gis)
    try await first.create(document)
    let changed = try await second.commit(content: .object(["value": .number(42)]), expectedRevision: 0)
    #expect(changed.revision == 1)
    do { _ = try await first.commit(content: .null, expectedRevision: 0); Issue.record("Stale edit accepted") }
    catch HeavyEditorError.revisionConflict { }
    #expect(try await first.read().content == .object(["value": .number(42)]))
}
@Test func wrongOriginalCannotBeOpened() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = HeavyEditorDocument(kind: .font, title: "Typeface", content: .object([:]))
    let store = try HeavyEditorProjectStore(directory: root, documentID: document.id, kind: .font)
    try await store.create(document)
    let wrong = try HeavyEditorProjectStore(directory: root, documentID: UUID(), kind: .font)
    do { _ = try await wrong.read(); Issue.record("Wrong original accepted") }
    catch HeavyEditorError.wrongDocument { }
}
