// FloeCoreTests — typed CAD revision history policy (Build265 follow-up).
import Foundation
import Testing
@testable import FloeCore

@Suite("Canvas CAD revision history")
struct CanvasDrawingRevisionHistoryTests {

    private func drawingNode(
        id nodeID: UUID = UUID(),
        assetPath: String = "Materials/original.dwg",
        hash: String? = nil
    ) -> CanvasNode {
        let hash = hash ?? String(repeating: "a", count: 64)
        let asset = CanvasAssetReference(
            id: UUID(), contentHash: hash,
            localRelativePath: assetPath, mimeType: "image/vnd.dwg",
            byteCount: 100)
        return CanvasNode(
            id: nodeID, kind: .file, text: "图纸",
            position: .init(x: 0, y: 0), size: .init(width: 200, height: 120),
            asset: asset)
    }

    private func revision(
        kind: CanvasDrawingRevision.Kind,
        path: String,
        hashCharacter: Character = "a",
        sourceRevisionID: UUID? = nil
    ) -> CanvasDrawingRevision {
        CanvasDrawingRevision(
            assetID: UUID(),
            contentHash: String(repeating: hashCharacter, count: 64),
            relativePath: path, byteCount: 50,
            kind: kind, sourceRevisionID: sourceRevisionID)
    }

    @Test("a node without an entry reads absent and may seed an original")
    func absentSeedsOriginal() throws {
        let subject = drawingNode()
        #expect(CanvasDrawingRevisionHistory.read(from: subject) == .absent)
        let original = try #require(CanvasDrawingRevisionHistory.seedOriginal(for: subject))
        #expect(original.kind == .original)
        #expect(original.relativePath == "Materials/original.dwg")
    }

    @Test("an unknown revision kind fails decoding instead of mapping to adopt")
    func unknownKindIsRaw() throws {
        // Build a syntactically valid list carrying an unknown kind without
        // going through the strict encoder.
        let unknownJSON = """
        [{"schemaVersion":1,"id":"\(UUID().uuidString)","assetID":"\(UUID().uuidString)",
        "contentHash":"\(String(repeating: "a", count: 64))","relativePath":"Materials/x.dwg",
        "byteCount":1,"createdAt":"2026-01-01T00:00:00Z","kind":"futureKind"}]
        """
        var subject = drawingNode()
        subject.metadata[CanvasDrawingRevisionHistory.metadataKey] = unknownJSON
        guard case .unsupported(let raw, let reason) = CanvasDrawingRevisionHistory.read(from: subject) else {
            Issue.record("expected unsupported read")
            return
        }
        #expect(raw == unknownJSON)
        #expect(reason == "malformed")
        // Empty/filtered convenience reads must not permit mutation: a later
        // appender sees the raw entry and refuses.
        #expect(CanvasDrawingRevisionHistory.revisions(from: subject).isEmpty)
        #expect(!CanvasDrawingRevisionHistory.hasUsableHistory(on: subject))
    }

    @Test("higher schema entries preserve the whole list read-only")
    func higherSchemaIsRaw() throws {
        var subject = drawingNode()
        var future = revision(kind: .original, path: "Materials/future.dwg")
        future.schemaVersion = 99
        let data = try JSONEncoder().encode([future])
        subject.metadata[CanvasDrawingRevisionHistory.metadataKey] =
            try #require(String(data: data, encoding: .utf8))
        guard case .unsupported(_, let reason) = CanvasDrawingRevisionHistory.read(from: subject) else {
            Issue.record("expected unsupported read")
            return
        }
        #expect(reason == "unsupportedSchema")
    }

    @Test("appending enforces unique ids, hash shape, safe paths and restore refs")
    func appendValidation() throws {
        let original = revision(kind: .original, path: "Materials/original.dwg", hashCharacter: "a")
        var revisions = [original]

        let adopted = revision(kind: .adopt, path: "Materials/adopted.dwg", hashCharacter: "b")
        revisions = try CanvasDrawingRevisionHistory.appending(adopted, to: revisions)
        // A duplicate id replaces in place.
        var replacement = adopted
        replacement.byteCount = 70
        revisions = try CanvasDrawingRevisionHistory.appending(replacement, to: revisions)
        #expect(revisions.count == 2)

        // Restore must reference a revision actually in the list.
        let danglingRestore = revision(
            kind: .restore, path: "Materials/r.dwg", hashCharacter: "c",
            sourceRevisionID: UUID())
        #expect(throws: FloeError.self) {
            _ = try CanvasDrawingRevisionHistory.appending(danglingRestore, to: revisions)
        }
        let validRestore = revision(
            kind: .restore, path: "Materials/r2.dwg", hashCharacter: "d",
            sourceRevisionID: original.id)
        revisions = try CanvasDrawingRevisionHistory.appending(validRestore, to: revisions)
        #expect(revisions.count == 3)

        // Invalid paths and malformed hashes are refused.
        var hostile = revision(kind: .adopt, path: "../escape.dwg")
        #expect(throws: FloeError.self) {
            _ = try CanvasDrawingRevisionHistory.appending(hostile, to: revisions)
        }
        // Nested WorkbenchRoot paths are inside the app-owned media root and
        // legitimate; escapes are what must be refused.
        hostile = revision(kind: .adopt, path: "WorkbenchRoot/../../escape.dwg")
        #expect(throws: FloeError.self) {
            _ = try CanvasDrawingRevisionHistory.appending(hostile, to: revisions)
        }
        hostile = revision(kind: .adopt, path: "Other/x.dwg")
        #expect(throws: FloeError.self) {
            _ = try CanvasDrawingRevisionHistory.appending(hostile, to: revisions)
        }
        var badHash = revision(kind: .adopt, path: "Materials/bad.dwg")
        badHash.contentHash = "nothex"
        #expect(throws: FloeError.self) {
            _ = try CanvasDrawingRevisionHistory.appending(badHash, to: revisions)
        }
    }

    @Test("metadata encodes and revision paths stay deterministic")
    func metadataAndPaths() throws {
        let subject = drawingNode()
        var original = try #require(CanvasDrawingRevisionHistory.seedOriginal(for: subject))
        var adopted = revision(kind: .adopt, path: "Materials/v2.dwg", hashCharacter: "b")
        let list = [original, adopted]
        let entry = try CanvasDrawingRevisionHistory.metadata(list)
        var withHistory = subject
        withHistory.metadata.merge(entry) { _, new in new }
        #expect(CanvasDrawingRevisionHistory.hasUsableHistory(on: withHistory))

        let document = CanvasDocument(name: "Doc", nodes: [withHistory])
        let project = CanvasProject(id: UUID(), name: "C", documents: [document],
                                    selectedDocumentID: document.id)
        #expect(CanvasDrawingRevisionHistory.revisionRelativePaths(in: project)
            == ["Materials/original.dwg", "Materials/v2.dwg"])

        // Path remapping rewrites and revalidates.
        let remapped = try CanvasDrawingRevisionHistory.remapping(
            list, pathRemap: ["Materials/v2.dwg": "Materials/v2-collision.dwg"])
        adopted.relativePath = "Materials/v2-collision.dwg"
        #expect(remapped == [original, adopted])
    }

    @Test("requireClosableHistory throws for a node with raw metadata")
    func requireClosable() throws {
        var subject = drawingNode()
        subject.metadata[CanvasDrawingRevisionHistory.metadataKey] = "{not json"
        let document = CanvasDocument(name: "D", nodes: [subject])
        let project = CanvasProject(id: UUID(), name: "C", documents: [document],
                                    selectedDocumentID: document.id)
        #expect(throws: FloeError.self) {
            try CanvasDrawingRevisionHistory.requireClosableHistory(in: project)
        }
    }

    // MARK: - Reachable-reference reconciliation (Build265 ownership review)

    private func projectWithHistory() throws -> (CanvasProject, UUID, UUID) {
        // One drawing node whose history retains the ORIGINAL asset after an
        // adopt: current asset B, history [original A, adopt B].
        var node = drawingNode(id: UUID(), assetPath: "Materials/v2.dwg",
                               hash: String(repeating: "b", count: 64))
        let original = CanvasDrawingRevision(
            assetID: UUID(),
            contentHash: String(repeating: "a", count: 64),
            relativePath: "Materials/original.dwg", byteCount: 50, kind: .original)
        let adopted = CanvasDrawingRevision(
            assetID: node.asset!.id,
            contentHash: node.asset!.contentHash!,
            relativePath: "Materials/v2.dwg", byteCount: 100, kind: .adopt)
        node.metadata = try CanvasDrawingRevisionHistory.metadata([original, adopted])
        let document = CanvasDocument(name: "Doc", nodes: [node])
        let project = CanvasProject(id: UUID(), name: "C", documents: [document],
                                    selectedDocumentID: document.id)
        return (project, original.assetID, node.asset!.id)
    }

    @Test("deleting a document releases its current asset but retains history-referenced bytes")
    func deleteDocumentDeltasRetainHistory() throws {
        let (project, originalAssetID, currentAssetID) = try projectWithHistory()
        // The other document still owns a node referencing the SAME original
        // asset through its CAD history (copy/import of the drawing node).
        var sharedNode = drawingNode(id: UUID(), assetPath: "Materials/other.dwg",
                                     hash: String(repeating: "c", count: 64))
        let sharedHistory = CanvasDrawingRevision(
            assetID: originalAssetID,
            contentHash: String(repeating: "a", count: 64),
            relativePath: "Materials/original.dwg", byteCount: 50, kind: .original)
        sharedNode.metadata = try CanvasDrawingRevisionHistory.metadata([sharedHistory])
        var surviving = project
        surviving.documents.append(CanvasDocument(name: "Doc2", nodes: [sharedNode]))

        // deleteDocument removes the FIRST document: deltas computed against
        // the pre-mutation project (the bug computed them post-mutation, so
        // they came out empty and every reference leaked). The current asset
        // is referenced twice before removal (live node + its `.adopt`
        // revision); the original is referenced by BOTH documents' history.
        var after = surviving
        after.documents.removeAll { $0.id == surviving.documents[0].id }
        let deltas = CanvasDrawingRevisionHistory.reachableDeltas(
            from: surviving, to: after)
        #expect(deltas[currentAssetID] == -2)
        #expect(deltas[originalAssetID] == -1)
        // The surviving document still reaches the original through its own
        // history: that owner must remain counted (exactly once).
        let survivingReferences = CanvasDrawingRevisionHistory.reachableAssetReferences(in: after)
        #expect(survivingReferences.filter { $0 == originalAssetID }.count == 1)
    }

    @Test("undoing a node delete restores the asset reference")
    func undoDeleteRestoresReferences() throws {
        let (project, originalAssetID, currentAssetID) = try projectWithHistory()
        var deleted = project
        deleted.documents[0].nodes.removeAll()
        let deltas = CanvasDrawingRevisionHistory.reachableDeltas(from: project, to: deleted)
        #expect(deltas[currentAssetID] == -2)
        #expect(deltas[originalAssetID] == -1)
        // Undo = back to the pre-delete project.
        let restore = CanvasDrawingRevisionHistory.reachableDeltas(from: deleted, to: project)
        #expect(restore[currentAssetID] == 2)
        #expect(restore[originalAssetID] == 1)
    }

    @Test("a failed pass retains ops, keeps decrements when an increment fails, and never spins")
    func reconciliationPassFailureSemantics() async throws {
        let incrementAsset = UUID(), decrementAsset = UUID()
        var queue = CanvasAssetReconciliation()
        queue.schedule([incrementAsset: 1, decrementAsset: -1])

        // Persistent increment failure: pass must fail, retain BOTH ops,
        // and must NOT process the decrement.
        var appliedAssets: [UUID] = []
        let outcome = await queue.runPass { op in
            appliedAssets.append(op.assetID)
            if op.assetID == incrementAsset { throw FloeError.storageCorrupted("persistent") }
        }
        #expect(outcome.completed == false)
        #expect(!appliedAssets.contains(decrementAsset),
                "decrement ran despite a failed prerequisite increment")
        #expect(queue.pending.count { $0.assetID == incrementAsset && $0.delta == 1 } == 1)
        #expect(queue.pending.count { $0.assetID == decrementAsset && $0.delta == -1 } == 1)

        // Second pass still fails the same way; state is stable (no growth,
        // no busy loop: each pass is one bounded attempt).
        let second = await queue.runPass { op in
            if op.assetID == incrementAsset { throw FloeError.storageCorrupted("persistent") }
        }
        #expect(second.completed == false)
        #expect(queue.pending.count == 2)
    }

    @Test("fail-once increment then success drains increments before decrements")
    func reconciliationFailOnceThenDrain() async throws {
        let incrementAsset = UUID(), decrementAsset = UUID()
        var queue = CanvasAssetReconciliation()
        var scheduled = 0
        queue.schedule([incrementAsset: 1, decrementAsset: -1],
                       idFactory: { scheduled += 1; return "op-\(scheduled)" })
        var order: [UUID] = []
        var failedOnce = false
        let first = await queue.runPass { op in
            order.append(op.assetID)
            if op.assetID == incrementAsset, !failedOnce {
                failedOnce = true
                throw FloeError.storageCorrupted("transient")
            }
            if op.assetID == decrementAsset && !order.contains(incrementAsset) {
                Issue.record("decrement ran before the increment completed")
            }
        }
        #expect(first.completed == false)
        #expect(queue.pending.count == 2)

        let second = await queue.runPass { op in order.append(op.assetID) }
        #expect(second.completed == true)
        #expect(queue.isEmpty)
        // Within the successful pass the increment was applied first.
        let successStart = order.lastIndex(of: incrementAsset)!
        let decrementAt = order.lastIndex(of: decrementAsset)!
        #expect(successStart < decrementAt)
    }

    @Test("mid-pass arrivals survive pass accounting (store merge semantics)")
    func reconciliationMidPassCoalescing() async throws {
        let a = UUID(), b = UUID()
        var queue = CanvasAssetReconciliation()
        queue.schedule([a: 1], idFactory: { "op-a" })
        // Mirror the store: the pass runs on a snapshot copy while new ops
        // schedule into the authoritative pending set; only applied op ids
        // are removed afterwards.
        var pass = queue
        let outcome = await pass.runPass { op in
            if op.assetID == a, op.delta == 1 {
                queue.schedule([a: -1, b: 1], idFactory: { "mid-\(op.id)" })
            }
        }
        let done = Set(outcome.applied)
        queue.markApplied(done)
        // a:+1 applied (receipt-idempotent in the real store); the mid-pass
        // a:-1 and b:+1 remain owed.
        #expect(outcome.applied == ["op-a"])
        #expect(queue.pending.count { $0.assetID == a && $0.delta == -1 } == 1)
        #expect(queue.pending.count { $0.assetID == b && $0.delta == 1 } == 1)
    }

    @Test("durable record round-trips pending ops")
    func reconciliationRecordRoundTrip() throws {
        let id = UUID()
        var queue = CanvasAssetReconciliation()
        queue.schedule([id: 2], idFactory: { "op-1" })
        let record = queue.record
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(CanvasAssetReconciliation.Record.self, from: data)
        let restored = CanvasAssetReconciliation(record: decoded)
        #expect(restored.pending == queue.pending)
    }
}
