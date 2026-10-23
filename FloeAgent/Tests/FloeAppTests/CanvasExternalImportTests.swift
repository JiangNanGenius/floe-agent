#if canImport(UIKit)
import Foundation
import Testing
import GRDB
import FloeCore
import FloePersistence
@testable import FloeApp

@Suite("Canvas external import publication")
struct CanvasExternalImportTests {
    private func asset(_ name: String) -> CreativeAssetRecord {
        .init(id: UUID(), contentHash: String(repeating: "a", count: 64),
              kind: .document, displayName: name, localRelativePath: "Materials/fixture.pdf", byteCount: 64)
    }

    @Test("New canvas is populated atomically; receipt retry does not create or append again")
    func newCanvasRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("canvas.json")
        let operation = UUID(), canvas = UUID(), node = UUID()
        let items = [CanvasExternalImportPublication.Item(nodeID: node, asset: asset("Report"))]
        let first = try CanvasExternalImportPublication.publish(
            operationID: operation, canvasID: canvas, creating: true,
            items: items, syncEnabled: true, at: url)
        let bytes = try Data(contentsOf: url)
        let retry = try CanvasExternalImportPublication.publish(
            operationID: operation, canvasID: canvas, creating: true,
            items: items, syncEnabled: true, at: url)
        #expect(first.documents.flatMap(\.nodes).map(\.id) == [node])
        #expect(retry.id == first.id)
        #expect(retry.revision == first.revision)
        #expect(retry.documents.flatMap(\.nodes) == first.documents.flatMap(\.nodes))
        #expect(try Data(contentsOf: url) == bytes)
        #expect(first.sync.revision == 1)
    }

    @Test("Existing canvas retains its content, selection and workspace; another import has its own identity")
    func existingCanvasPreservesContent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("canvas.json")
        let originalNode = CanvasNode(kind: .text, text: "Keep me", position: .init(x: 10, y: 20), size: .init(width: 120, height: 80))
        let document = CanvasDocument(name: "Work", nodes: [originalNode])
        let original = CanvasProject(id: UUID(), workspaceID: UUID(), name: "Original", documents: [document], selectedDocumentID: document.id)
        try CanvasProjectFileWriter.shared.compareAndSwap(original, at: url, expectedRevision: 0,
                                                         requireRevisionAdvance: false, allowCreateIfMissing: true)
        let record = asset("Imported")
        let firstID = UUID(), secondID = UUID()
        _ = try CanvasExternalImportPublication.publish(
            operationID: UUID(), canvasID: original.id, creating: false,
            items: [.init(nodeID: firstID, asset: record)], syncEnabled: false, at: url)
        let final = try CanvasExternalImportPublication.publish(
            operationID: UUID(), canvasID: original.id, creating: false,
            items: [.init(nodeID: secondID, asset: record)], syncEnabled: false, at: url)
        #expect(final.documents[0].nodes[0] == originalNode)
        #expect(final.documents[0].nodes.map(\.id) == [originalNode.id, firstID, secondID])
        #expect(final.selectedDocumentID == document.id)
        #expect(final.workspaceID == original.workspaceID)
        #expect(final.revision == 2)
        #expect(final.sync.revision == 0)
    }

    @Test("Invalid, missing or conflicting targets never create an empty canvas or replace existing content")
    func failedPublicationPreservesDestination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("canvas.json"), operation = UUID(), canvas = UUID()
        #expect(throws: (any Error).self) {
            try CanvasExternalImportPublication.publish(operationID: operation, canvasID: canvas,
                creating: true, items: [], syncEnabled: false, at: url)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let item = CanvasExternalImportPublication.Item(nodeID: UUID(), asset: asset("First"))
        #expect(throws: (any Error).self) {
            try CanvasExternalImportPublication.publish(operationID: operation, canvasID: canvas,
                creating: false, items: [item], syncEnabled: false, at: url)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        _ = try CanvasExternalImportPublication.publish(operationID: operation, canvasID: canvas,
            creating: true, items: [item], syncEnabled: false, at: url)
        let bytes = try Data(contentsOf: url)
        #expect(throws: (any Error).self) {
            try CanvasExternalImportPublication.publish(operationID: UUID(), canvasID: canvas,
                creating: true, items: [.init(nodeID: UUID(), asset: asset("Other"))], syncEnabled: false, at: url)
        }
        #expect(try Data(contentsOf: url) == bytes)
    }
}

// MARK: - Review-round regressions (live-editor deferral, unit guard, listing resilience, naming, bookkeeping retry)

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeAsset(_ name: String) -> CreativeAssetRecord {
    .init(id: UUID(), contentHash: String(repeating: "b", count: 64),
          kind: .document, displayName: name, localRelativePath: "Materials/fixture.pdf", byteCount: 64)
}

private func isRefused(_ result: CanvasCommitResult) -> Bool {
    if case .failed = result { return true }
    return false
}

@Suite("Canvas import library listing resilience")
struct CanvasImportListingTests {
    @Test("One corrupt canvas file keeps listing valid canvases for legacy callers while strict selection reports the real failure")
    func corruptFileSemantics() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let validID = UUID()
        let kept = CanvasNode(kind: .text, text: "Keep me", position: .init(x: 10, y: 20), size: .init(width: 120, height: 80))
        let document = CanvasDocument(name: "Page", nodes: [kept])
        let valid = CanvasProject(id: validID, workspaceID: nil, name: "Valid Canvas",
                                  documents: [document], selectedDocumentID: document.id)
        try CanvasProjectFileWriter.shared.compareAndSwap(
            valid, at: directory.appendingPathComponent("\(validID.uuidString).json"),
            expectedRevision: 0, requireRevisionAdvance: false, allowCreateIfMissing: true)
        let corruptID = UUID()
        try Data("{{{ not a canvas".utf8).write(
            to: directory.appendingPathComponent("\(corruptID.uuidString).json"))
        // Non-canvas JSON in the library directory is not a canvas and must
        // never poison either listing mode.
        try Data("{}".utf8).write(
            to: directory.appendingPathComponent("library-organization.json"))

        let bestEffort = try WorkspaceCanvasRegistry.readSummaries(in: directory, strict: false)
        #expect(bestEffort.map(\.id) == [validID])
        #expect(bestEffort.first?.name == "Valid Canvas")
        #expect(throws: (any Error).self) {
            _ = try WorkspaceCanvasRegistry.readSummaries(in: directory, strict: true)
        }
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("\(corruptID.uuidString).json"))
        #expect(try WorkspaceCanvasRegistry.readSummaries(in: directory, strict: true)
            .map(\.id) == [validID])
        // A missing library directory is legitimately empty, not unreadable.
        #expect(try WorkspaceCanvasRegistry.readSummaries(
            in: directory.appendingPathComponent("absent"), strict: true) == [])
    }
}

@Suite("Canvas import publication naming and patch limits")
struct CanvasImportPublicationSemanticsTests {
    @Test("Meaningful aliases label nodes and new canvases; blank or absent aliases keep the ingestion-resolved name")
    func aliasResolution() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let aliasedURL = directory.appendingPathComponent("alias.json")
        let aliased = try CanvasExternalImportPublication.publish(
            operationID: UUID(), canvasID: UUID(), creating: true,
            items: [.init(nodeID: UUID(), asset: makeAsset("Stored Record"), displayName: " Alias ")],
            syncEnabled: false, at: aliasedURL)
        #expect(aliased.name == "Alias")
        #expect(aliased.documents.flatMap(\.nodes).map(\.text) == ["Alias"])
        let fallbackURL = directory.appendingPathComponent("fallback.json")
        let fallback = try CanvasExternalImportPublication.publish(
            operationID: UUID(), canvasID: UUID(), creating: true,
            items: [.init(nodeID: UUID(), asset: makeAsset("Stored Record"), displayName: "   ")],
            syncEnabled: false, at: fallbackURL)
        #expect(fallback.name == "Stored Record")
        #expect(fallback.documents.flatMap(\.nodes).map(\.text) == ["Stored Record"])
        let blankURL = directory.appendingPathComponent("blank.json")
        #expect(throws: (any Error).self) {
            try CanvasExternalImportPublication.publish(
                operationID: UUID(), canvasID: UUID(), creating: true,
                items: [.init(nodeID: UUID(), asset: makeAsset("  "))],
                syncEnabled: false, at: blankURL)
        }
        #expect(!FileManager.default.fileExists(atPath: blankURL.path))
    }

    @Test("Plans above the shared 1...100 patch contract fail before any destination write")
    func oversizedPatchRejected() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("oversized.json")
        let oversized = (0...(CanvasExternalImportPublication.maximumUnitsPerOperation)).map {
            CanvasExternalImportPublication.Item(nodeID: UUID(), asset: makeAsset("N\($0)"))
        }
        #expect(oversized.count == 101)
        #expect(throws: (any Error).self) {
            try CanvasExternalImportPublication.publish(
                operationID: UUID(), canvasID: UUID(), creating: true,
                items: oversized, syncEnabled: false, at: url)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let boundary = (0..<CanvasExternalImportPublication.maximumUnitsPerOperation).map {
            CanvasExternalImportPublication.Item(nodeID: UUID(), asset: makeAsset("N\($0)"))
        }
        let created = try CanvasExternalImportPublication.publish(
            operationID: UUID(), canvasID: UUID(), creating: true,
            items: boundary, syncEnabled: false, at: url)
        #expect(created.documents.flatMap(\.nodes).count
            == CanvasExternalImportPublication.maximumUnitsPerOperation)
    }
}

@MainActor
@Suite(.serialized)
struct CanvasExternalImportBridgeTests {
    private func bookkeeping() throws -> (database: DatabaseManager,
                                          assets: CreativeAssetStore,
                                          sync: CanvasSyncOperationStore) {
        let database = try DatabaseManager.inMemory()
        try database.migrate()
        return (database, CreativeAssetStore(database: database),
                CanvasSyncOperationStore(database: database))
    }

    private func rows(_ database: DatabaseManager, _ sql: String) async throws -> Int {
        try await database.reader { db in try Int.fetchOne(db, sql: sql) ?? -1 }
    }

    private func setSyncPreference(_ value: Bool) -> Any? {
        let key = "creative.canvas.sync.enabled"
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(value, forKey: key)
        return previous
    }

    private func restoreSyncPreference(_ previous: Any?) {
        let key = "creative.canvas.sync.enabled"
        if let previous { UserDefaults.standard.set(previous, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    private func stagedPayload(in directory: URL, named name: String, contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test("Deallocated editor owner never pins a canvas busy and publication marks keep the newest revision")
    func registryLifecycle() {
        let canvas = UUID()
        let registry = CanvasInteractiveActivityRegistry.shared
        var owner: NSObject? = NSObject()
        registry.begin(owner: owner!, canvasID: canvas)
        #expect(registry.hasBusyOwner(for: canvas))
        owner = nil
        #expect(!registry.hasBusyOwner(for: canvas))
        registry.markPublished(canvasID: canvas, revision: 5)
        registry.markPublished(canvasID: canvas, revision: 3)
        #expect(registry.hasNewerPublishedRevision(for: canvas, than: 4))
        #expect(!registry.hasNewerPublishedRevision(for: canvas, than: 5))
        #expect(!registry.hasNewerPublishedRevision(for: UUID(), than: 0))
    }

    @Test("A live draft defers import with zero disk mutation; the released same operation then commits")
    func liveDraftDefersThenSameOperationCommits() async throws {
        let canvasDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: canvasDirectory) }
        let ingestionBase = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: ingestionBase) }
        let payloads = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: payloads) }
        let book = try bookkeeping()
        let ingestion = CreativeAssetIngestionService(assetStore: book.assets, baseDirectory: ingestionBase)
        let committer = CanvasExternalImportCommitter(
            ingestion: ingestion, assets: book.assets, sync: book.sync,
            canvasDirectoryOverride: canvasDirectory)
        let plannedCanvas = UUID()
        let plannedNode = UUID()
        let operation = CanvasImportOperation(
            operationID: UUID(), originID: UUID(), target: .newCanvas,
            plannedNewCanvasID: plannedCanvas,
            units: [.init(key: "file", displayName: "Deferral",
                           payloadURL: try stagedPayload(in: payloads, named: "deferral.pdf", contents: "D"),
                           plannedNodeID: plannedNode)])
        let previous = setSyncPreference(false)
        defer { restoreSyncPreference(previous) }

        let editor = NSObject()
        CanvasInteractiveActivityRegistry.shared.begin(owner: editor, canvasID: plannedCanvas)
        let deferred = await committer.commitImport(operation)
        CanvasInteractiveActivityRegistry.shared.end(owner: editor)

        #expect(isRefused(deferred))
        // Nothing landed: no canvas file, no ingested material, no rows.
        #expect(!FileManager.default.fileExists(
            atPath: canvasDirectory.appendingPathComponent("\(plannedCanvas.uuidString).json").path))
        #expect(try await rows(book.database, "SELECT COUNT(*) FROM creative_assets") == 0)
        #expect(try await rows(book.database, "SELECT COUNT(*) FROM asset_reference_receipts") == 0)
        #expect(try await rows(book.database, "SELECT COUNT(*) FROM canvas_sync_operations") == 0)

        // The same operation identity (as the Share journal retries) commits
        // cleanly once the draft is released.
        let committed = await committer.commitImport(operation)
        guard case .committed(let canvasID, let nodeIDs) = committed else {
            Issue.record("Released draft must allow the same operation")
            return
        }
        #expect(canvasID == plannedCanvas)
        #expect(nodeIDs == [plannedNode])
        let url = canvasDirectory.appendingPathComponent("\(plannedCanvas.uuidString).json")
        let published = try CanvasProjectFileWriter.shared.project(canvasID: plannedCanvas, at: url)
        #expect(published.documents.flatMap(\.nodes).map(\.id) == [plannedNode])
        #expect(published.documents.flatMap(\.nodes).map(\.text) == ["Deferral"])
        // The stale-gesture gate the editor consults before beginning a
        // mutation: the published revision is newer than any older local
        // project, and matching the local revision clears the signal.
        #expect(CanvasInteractiveActivityRegistry.shared
            .hasNewerPublishedRevision(for: plannedCanvas, than: published.revision - 1))
        #expect(!CanvasInteractiveActivityRegistry.shared
            .hasNewerPublishedRevision(for: plannedCanvas, than: published.revision))
        #expect(try await rows(book.database, "SELECT COUNT(*) FROM canvas_sync_operations") == 0)
        #expect(try await rows(book.database, "SELECT COUNT(*) FROM asset_reference_receipts") == 1)
        #expect(try await rows(book.database, "SELECT reference_count FROM creative_assets") == 1)
    }

    @Test("An oversized unit plan fails before ingestion and never creates a canvas or material rows")
    func oversizedPlanRefusedBeforeWork() async throws {
        let canvasDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: canvasDirectory) }
        let ingestionBase = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: ingestionBase) }
        let payloads = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: payloads) }
        let book = try bookkeeping()
        let committer = CanvasExternalImportCommitter(
            ingestion: CreativeAssetIngestionService(assetStore: book.assets, baseDirectory: ingestionBase),
            assets: book.assets, sync: book.sync, canvasDirectoryOverride: canvasDirectory)
        // All payloads exist: only a pre-ingestion guard can keep the asset
        // table empty for an oversized plan.
        var units: [CanvasImportUnitPlan] = []
        for index in 0...CanvasExternalImportPublication.maximumUnitsPerOperation {
            units.append(.init(key: "u\(index)", displayName: "U\(index)",
                               payloadURL: try stagedPayload(in: payloads, named: "u\(index).pdf", contents: "P"),
                               plannedNodeID: UUID()))
        }
        let plannedCanvas = UUID()
        let operation = CanvasImportOperation(operationID: UUID(), originID: UUID(),
                                              target: .newCanvas, plannedNewCanvasID: plannedCanvas, units: units)
        #expect(isRefused(await committer.commitImport(operation)))
        #expect(try await rows(book.database, "SELECT COUNT(*) FROM creative_assets") == 0)
        #expect(try await rows(book.database, "SELECT COUNT(*) FROM asset_reference_receipts") == 0)
        #expect(!FileManager.default.fileExists(
            atPath: canvasDirectory.appendingPathComponent("\(plannedCanvas.uuidString).json").path))
    }

    @Test("Blank unit names resolve through ingestion and a dedup alias never renames the material record")
    func namingThroughCommit() async throws {
        let canvasDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: canvasDirectory) }
        let ingestionBase = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: ingestionBase) }
        let payloads = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: payloads) }
        let book = try bookkeeping()
        let committer = CanvasExternalImportCommitter(
            ingestion: CreativeAssetIngestionService(assetStore: book.assets, baseDirectory: ingestionBase),
            assets: book.assets, sync: book.sync, canvasDirectoryOverride: canvasDirectory)
        let previous = setSyncPreference(false)
        defer { restoreSyncPreference(previous) }

        // (a) Whitespace-only unit name falls back to the payload file name.
        let blankCanvas = UUID()
        let blankNode = UUID()
        let blankOperation = CanvasImportOperation(
            operationID: UUID(), originID: UUID(), target: .newCanvas, plannedNewCanvasID: blankCanvas,
            units: [.init(key: "file", displayName: "   ",
                           payloadURL: try stagedPayload(in: payloads, named: "staged-report.pdf", contents: "RPT"),
                           plannedNodeID: blankNode)])
        guard case .committed = await committer.commitImport(blankOperation) else {
            Issue.record("Blank display name must resolve through ingestion fallback")
            return
        }
        let blankURL = canvasDirectory.appendingPathComponent("\(blankCanvas.uuidString).json")
        let blankProject = try CanvasProjectFileWriter.shared.project(canvasID: blankCanvas, at: blankURL)
        #expect(blankProject.documents.flatMap(\.nodes).map(\.text) == ["staged-report"])
        let blankAsset = try await book.assets.asset(
            contentHash: FloeDigest.sha256Hex(Data("RPT".utf8)))
        #expect(blankAsset?.displayName == "staged-report")

        // (b) Two units over identical bytes: the second meaningful alias
        // labels only its node; the deduped material record keeps its
        // established display name.
        let sharedURL = try stagedPayload(in: payloads, named: "shared.pdf", contents: "SAME")
        let dedupCanvas = UUID()
        let firstNode = UUID()
        let secondNode = UUID()
        let dedupOperation = CanvasImportOperation(
            operationID: UUID(), originID: UUID(), target: .newCanvas, plannedNewCanvasID: dedupCanvas,
            units: [
                .init(key: "a", displayName: "Original", payloadURL: sharedURL, plannedNodeID: firstNode),
                .init(key: "b", displayName: "  Renamed Alias  ", payloadURL: sharedURL, plannedNodeID: secondNode),
            ])
        guard case .committed = await committer.commitImport(dedupOperation) else {
            Issue.record("Dedup-alias operation must commit")
            return
        }
        let dedupURL = canvasDirectory.appendingPathComponent("\(dedupCanvas.uuidString).json")
        let dedupProject = try CanvasProjectFileWriter.shared.project(canvasID: dedupCanvas, at: dedupURL)
        #expect(dedupProject.documents.flatMap(\.nodes).map(\.text) == ["Original", "Renamed Alias"])
        let sharedAsset = try await book.assets.asset(contentHash: FloeDigest.sha256Hex(Data("SAME".utf8)))
        #expect(sharedAsset?.displayName == "Original")
        let materialFiles = try FileManager.default.contentsOfDirectory(
            at: ingestionBase.appendingPathComponent("Materials"), includingPropertiesForKeys: nil)
        // One file per DISTINCT payload: the deduped alias pair shares the
        // same content-addressed bytes, so only the "staged-report" and
        // "SAME" payloads exist as material.
        #expect(materialFiles.count == 2)
    }

    @Test("Interrupted bookkeeping never acknowledges; the same operation retries to exactly one node, reference and sync row per unit")
    func interruptedBookkeepingRetryConverges() async throws {
        let canvasDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: canvasDirectory) }
        let ingestionBase = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: ingestionBase) }
        let payloads = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: payloads) }
        let database = try DatabaseManager.inMemory()
        try database.migrate()
        let committedStore = CreativeAssetStore(database: database)
        let syncStore = CanvasSyncOperationStore(database: database)
        // A second, bookkeeping-blind store receives the SAME op ids on the
        // first attempt: the receipt insert and reference update share one
        // SQLite transaction, so the failed update must roll the receipt
        // back — the exact interrupted-bookkeeping shape the journal retries.
        let interruptedDatabase = try DatabaseManager.inMemory()
        try interruptedDatabase.migrate()
        let interruptedStore = CreativeAssetStore(database: interruptedDatabase)
        let ingestion = CreativeAssetIngestionService(assetStore: committedStore, baseDirectory: ingestionBase)
        let plannedCanvas = UUID()
        let firstNode = UUID()
        let secondNode = UUID()
        let operation = CanvasImportOperation(
            operationID: UUID(), originID: UUID(), target: .newCanvas, plannedNewCanvasID: plannedCanvas,
            units: [
                .init(key: "a", displayName: "One",
                       payloadURL: try stagedPayload(in: payloads, named: "one.pdf", contents: "AAA"),
                       plannedNodeID: firstNode),
                .init(key: "b", displayName: "Two",
                       payloadURL: try stagedPayload(in: payloads, named: "two.pdf", contents: "BBB"),
                       plannedNodeID: secondNode),
            ])
        let previous = setSyncPreference(true)
        defer { restoreSyncPreference(previous) }
        let url = canvasDirectory.appendingPathComponent("\(plannedCanvas.uuidString).json")

        let firstCommitter = CanvasExternalImportCommitter(
            ingestion: ingestion, assets: interruptedStore, sync: syncStore,
            canvasDirectoryOverride: canvasDirectory)
        let first = await firstCommitter.commitImport(operation)
        // CAS publication landed but bookkeeping refused: no ack.
        #expect(isRefused(first))
        let afterInterruption = try CanvasProjectFileWriter.shared.project(canvasID: plannedCanvas, at: url)
        #expect(afterInterruption.documents.flatMap(\.nodes).map(\.id) == [firstNode, secondNode])
        let bytes = try Data(contentsOf: url)
        #expect(try await rows(interruptedDatabase, "SELECT COUNT(*) FROM asset_reference_receipts") == 0)
        #expect(try await rows(database, "SELECT COUNT(*) FROM asset_reference_receipts") == 0)
        #expect(try await rows(database, "SELECT COUNT(*) FROM canvas_sync_operations") == 0)
        #expect(try await committedStore.asset(contentHash: FloeDigest.sha256Hex(Data("AAA".utf8)))?.referenceCount == 0)

        // The journal retries the SAME operation identity against the real
        // receipt/outbox store.
        let retryCommitter = CanvasExternalImportCommitter(
            ingestion: ingestion, assets: committedStore, sync: syncStore,
            canvasDirectoryOverride: canvasDirectory)
        let retry = await retryCommitter.commitImport(operation)
        guard case .committed(let canvasID, let nodeIDs) = retry else {
            Issue.record("The retried operation must converge")
            return
        }
        #expect(canvasID == plannedCanvas)
        #expect(nodeIDs == [firstNode, secondNode])
        // Exactly one project, one page, one node per planned identity, and
        // the file is byte-identical (publication recognized its own nodes).
        #expect(try Data(contentsOf: url) == bytes)
        let final = try CanvasProjectFileWriter.shared.project(canvasID: plannedCanvas, at: url)
        #expect(final.documents.count == 1)
        #expect(final.documents.flatMap(\.nodes).map(\.id) == [firstNode, secondNode])
        // Exactly +1 reference per planned node (receipt idempotency) and
        // exactly one deterministic sync outbox row.
        #expect(try await rows(database, "SELECT COUNT(*) FROM asset_reference_receipts") == 2)
        #expect(try await committedStore.asset(contentHash: FloeDigest.sha256Hex(Data("AAA".utf8)))?.referenceCount == 1)
        #expect(try await committedStore.asset(contentHash: FloeDigest.sha256Hex(Data("BBB".utf8)))?.referenceCount == 1)
        let pendingSync = try await syncStore.pending()
        #expect(pendingSync.count == 1)
        #expect(pendingSync.first?.operation.canvasID == plannedCanvas)
    }
}
#endif
