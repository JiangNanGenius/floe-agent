// SPDX-License-Identifier: MPL-2.0
//
// Authored C07 full-data tests. These exercise the pure package contract and
// the real ZIPFoundation reader/writer; no App, database, device, SAF
// provider, credential or network service is touched.
import XCTest
import Foundation
import ZIPFoundation
@testable import FloeAndroidDataExchange

final class C07OwnedDataTests: XCTestCase {
    private final class Fixture {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("c07-owned-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ data: Data) throws -> URL {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        }
        func destination(_ name: String) -> URL { root.appendingPathComponent(name) }
    }

    // MARK: - Row codec

    func testDatabaseValueRoundTripPreservesStorageClass() throws {
        let values: [C07DBValue] = [
            .null, .int(Int64.max), .double(1.5), .string("hello"),
            .data(Data([0, 1, 2, 255])),
        ]
        let encoded = try JSONEncoder().encode(values)
        let decoded = try JSONDecoder().decode([C07DBValue].self, from: encoded)
        XCTAssertEqual(decoded, values)
        XCTAssertEqual(decoded[1].integer, Int64.max)
        XCTAssertEqual(decoded[4].blob, Data([0, 1, 2, 255]))
        XCTAssertTrue(decoded[0].isNull)
    }

    func testNonFiniteRealIsRejected() {
        let json = Data(#"{"kind":"real","real":1e999}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(C07DBValue.self, from: json))
    }

    func testRowStreamRoundTripAndBounds() throws {
        let fixture = try Fixture()
        let url = fixture.destination("rows.jsonl")
        let writer = try C07RowStream.makeWriter(at: url)
        try writer.append(["id": .string("a"), "n": .int(1)])
        try writer.append(["id": .string("b"), "n": .null])
        try writer.finish()
        XCTAssertEqual(writer.rowCount, 2)
        var rows: [C07DBRow] = []
        try C07RowStream.rows(in: url, table: "sample") { rows.append($0) }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1]["id"]?.stringValue, "b")
        XCTAssertTrue(rows[1]["n"]?.isNull == true)
    }

    // MARK: - Secret and replay policy

    func testProviderSecretsAreClearedOnExportAndRestore() {
        let row: C07DBRow = [
            "id": .string(UUID().uuidString),
            "kind": .string("openai"),
            "wire_protocol": .string("chatCompletions"),
            "base_url": .string("https://user:pass@example.com/v1?api_key=secret"),
            "secret_ref_account": .string("vault://account"),
            "secret_ref_synchronizable": .string("vault://sync"),
            "non_secret_headers_json": .string(#"{"Authorization":"Bearer x"}"#),
            "is_enabled": .int(1),
        ]
        let exported = C07OwnedDataPolicy.exportedRow(
            table: "providers", row: row)
        XCTAssertTrue(exported["secret_ref_account"]?.isNull == true)
        XCTAssertTrue(exported["secret_ref_synchronizable"]?.isNull == true)
        XCTAssertEqual(exported["non_secret_headers_json"]?.stringValue, "{}")
        let restored = C07OwnedDataPolicy.restoredRow(
            table: "providers", row: exported)
        XCTAssertEqual(restored["is_enabled"]?.integerValue, 0)
        XCTAssertEqual(restored["non_secret_headers_json"]?.stringValue, "{}")
        XCTAssertFalse(restored["base_url"]?.stringValue?.contains("pass") ?? true)
        XCTAssertFalse(restored["base_url"]?.stringValue?.contains("api_key") ?? true)
    }

    func testActionPayloadsAreReceiptsOnly() {
        let event: C07DBRow = [
            "id": .string(UUID().uuidString),
            "run_id": .string(UUID().uuidString),
            "sequence": .int(1),
            "kind": .string("toolRequest"),
            "payload_json": .string(#"{"arguments":{"apiKey":"sk-secret"}}"#),
            "created_at": .string("2026-01-01T00:00:00Z"),
        ]
        let exported = C07OwnedDataPolicy.exportedRow(
            table: "run_events", row: event)
        XCTAssertEqual(exported["payload_json"]?.stringValue,
                       #"{"redacted":"secretBearingActionPayload","kind":"toolRequest"}"#)
        XCTAssertFalse(exported["payload_json"]?.stringValue?.contains("sk-secret") ?? true)
    }

    func testNonReplayingStateNormalization() {
        let run: C07DBRow = [
            "id": .string(UUID().uuidString),
            "conversation_id": .string(UUID().uuidString),
            "state": .string("executingTool"),
            "goal": .string("work"),
            "started_at": .string("2026-01-01T00:00:00Z"),
        ]
        XCTAssertEqual(C07OwnedDataPolicy.restoredRow(
            table: "runs", row: run)["state"]?.stringValue, "interrupted")

        let schedule: C07DBRow = [
            "id": .string(UUID().uuidString),
            "is_enabled": .int(1),
            "next_expected_at": .string("2026-01-02T00:00:00Z"),
            "policy_json": .string(#"{"approved":true}"#),
            "permission_json": .string(#"{"remote":true}"#),
            "environment_id": .string("env"),
        ]
        let restoredSchedule = C07OwnedDataPolicy.restoredRow(
            table: "task_schedules", row: schedule)
        XCTAssertEqual(restoredSchedule["is_enabled"]?.integerValue, 0)
        XCTAssertTrue(restoredSchedule["next_expected_at"]?.isNull == true)
        XCTAssertEqual(restoredSchedule["policy_json"]?.stringValue, "{}")
        XCTAssertEqual(restoredSchedule["permission_json"]?.stringValue, "{}")
        XCTAssertTrue(restoredSchedule["environment_id"]?.isNull == true)

        let occurrence: C07DBRow = [
            "id": .string(UUID().uuidString),
            "schedule_id": .string(UUID().uuidString),
            "state": .string("running"),
        ]
        XCTAssertEqual(C07OwnedDataPolicy.restoredRow(
            table: "task_schedule_occurrences", row: occurrence)["state"]?.stringValue,
                       "interrupted")

        let question: C07DBRow = [
            "question_id": .string("q"),
            "request_id": .string("r"),
            "conversation_id": .string(UUID().uuidString),
            "run_id": .string(UUID().uuidString),
            "status": .string("pending"),
            "delivered_at": .string("2026-01-01T00:00:00Z"),
        ]
        let restoredQuestion = C07OwnedDataPolicy.restoredRow(
            table: "user_questions", row: question)
        XCTAssertEqual(restoredQuestion["status"]?.stringValue, "expired")
        XCTAssertTrue(restoredQuestion["delivered_at"]?.isNull == true)

        let goal: C07DBRow = [
            "id": .string(UUID().uuidString),
            "conversation_id": .string(UUID().uuidString),
            "status": .string("active"),
            "blocking_fingerprint": .string("x"),
            "consecutive_blocked_cycles": .int(3),
        ]
        let restoredGoal = C07OwnedDataPolicy.restoredRow(
            table: "conversation_goals", row: goal)
        XCTAssertEqual(restoredGoal["status"]?.stringValue, "interrupted")
        XCTAssertTrue(restoredGoal["blocking_fingerprint"]?.isNull == true)
        XCTAssertEqual(restoredGoal["consecutive_blocked_cycles"]?.integerValue, 0)
    }

    func testTemporaryConversationRowIsNotExportable() {
        XCTAssertFalse(C07OwnedDataPolicy.shouldExportRow(
            table: "conversations",
            row: ["id": .string(UUID().uuidString),
                  "purpose": .string("temporary")]))
        XCTAssertTrue(C07OwnedDataPolicy.shouldExportRow(
            table: "conversations",
            row: ["id": .string(UUID().uuidString),
                  "purpose": .string("ordinary")]))
    }

    // MARK: - Identity mapping

    func testIDRewriteOnlyReplacesMappedTokens() throws {
        let oldConversation = UUID()
        let oldRun = UUID()
        let unrelated = UUID()
        var map = C07IDMap()
        try map.insert(.conversation, old: oldConversation.uuidString,
                       new: UUID().uuidString)
        try map.insert(.run, old: oldRun.uuidString, new: UUID().uuidString)
        let json = #"{"conversationID":"\#(oldConversation.uuidString)","runID":"\#(oldRun.uuidString)","note":"\#(unrelated.uuidString)"}"#
        let rewritten = try C07IDRewrite.rewriteJSONColumn(
            .string(json), mapping: map)
        XCTAssertFalse(rewritten.stringValue?.contains(oldConversation.uuidString) ?? true)
        XCTAssertFalse(rewritten.stringValue?.contains(oldRun.uuidString) ?? true)
        XCTAssertTrue(rewritten.stringValue?.contains(unrelated.uuidString) ?? false)
    }

    func testFreshIdentityIsDeterministic() {
        let restore = UUID()
        let first = C07IDDerivation.fresh(
            restoreID: restore, table: "run_events", old: "old")
        let second = C07IDDerivation.fresh(
            restoreID: restore, table: "run_events", old: "old")
        let other = C07IDDerivation.fresh(
            restoreID: restore, table: "run_errors", old: "old")
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, other)
        XCTAssertNotNil(UUID(uuidString: first))
    }

    // MARK: - Artifact/manifest validation

    func testArtifactCatalogRejectsTraversalAndDuplicateEntries() throws {
        let canvasID = UUID()
        let badPath = C07ArtifactRecord(
            role: .canvasMaterial, ownerID: nil, containerID: canvasID,
            logicalPath: "../escape", entry: "artifacts/canvas-materials/x",
            byteCount: 1, sha256: String(repeating: "a", count: 64))
        XCTAssertThrowsError(try C07ArtifactCatalog(records: [badPath]).validate())

        let good = C07ArtifactRecord(
            role: .canvasMaterial, ownerID: nil, containerID: canvasID,
            logicalPath: "image.png",
            entry: "artifacts/canvas-materials/\(canvasID.uuidString)/image.png",
            byteCount: 1, sha256: String(repeating: "a", count: 64))
        XCTAssertNoThrow(try C07ArtifactCatalog(records: [good]).validate())
        XCTAssertThrowsError(try C07ArtifactCatalog(records: [good, good]).validate())
    }

    func testManifestV2RequiresFullScopeAndOptionalEvidenceMayBeAbsent() throws {
        var tables: [C07OwnedTableRecord] = []
        for name in C07OwnedDataPolicy.mandatoryTableNames(
            forSchema: 52).sorted() {
            tables.append(C07OwnedTableRecord(
                name: name, entry: c07OwnedTableEntry(name), rowCount: 0,
                byteCount: 0, sha256: String(repeating: "a", count: 64)))
        }
        let manifest = C07OwnedDataManifest(
            sourceAppSchemaVersion: 52,
            tables: tables,
            workspaceCount: 0,
            workspaceByteCount: 2,
            workspaceSHA256: String(repeating: "b", count: 64),
            counts: C07OwnedDataCounts(),
            excluded: C07ScopePolicy.excluded,
            linuxCheckpointPort: "unavailable",
            linuxCheckpointReason: "c01CheckpointPortNotInstalled")
        XCTAssertNoThrow(try manifest.validate())
        XCTAssertEqual(C07OwnedDataPolicy.evidenceTableNames.count, 4)

        var scope = C07BackupScope(
            excluded: C07ScopePolicy.excluded, databaseMode: "logicalRows")
        // A package written by the first v2 build is still readable.
        scope.included = Array(C07BackupScope.legacyV2IncludedIDs)
        XCTAssertNoThrow(try C07ScopePolicy.validate(scope, formatVersion: 2))
        scope.included = Array(C07BackupScope.includedIDs.dropLast())
        XCTAssertThrowsError(try C07ScopePolicy.validate(scope, formatVersion: 2))
        var legacy = scope
        legacy.databaseMode = nil
        legacy.included = C07BackupScope.legacyIncludedIDs
        XCTAssertNoThrow(try C07ScopePolicy.validate(legacy, formatVersion: 1))
    }

    // MARK: - Canvas package

    private func syntheticCanvas() throws -> (Fixture, UUID, URL) {
        let fixture = try Fixture()
        let canvasID = UUID()
        let childID = UUID()
        let canvas: [String: Any] = [
            "id": canvasID.uuidString,
            "schemaVersion": 7,
            "name": "Test canvas",
            "documents": [[
                "id": UUID().uuidString,
                "nodes": [[
                    "id": UUID().uuidString,
                    "kind": "image",
                    "text": "",
                    "asset": [
                        "id": UUID().uuidString,
                        "localRelativePath": "Materials/picture.png",
                    ],
                    "metadata": [
                        "canvas.childProject": #"{"schemaVersion":1,"projectID":"\#(childID.uuidString)","appliedRevision":1}"#,
                    ],
                ]],
            ]],
            "selectedDocumentID": UUID().uuidString,
            "revision": 1,
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-01T00:00:00Z",
        ]
        let canvasURL = try fixture.write(
            "canvas.json", try JSONSerialization.data(withJSONObject: canvas,
                                                       options: [.sortedKeys]))
        let media: [String: Any] = [
            "id": childID.uuidString,
            "schemaVersion": 1,
            "ownerKind": "canvas",
            "ownerID": canvasID.uuidString,
            "assets": [[
                "id": UUID().uuidString,
                "relativePath": "Workbench/Assets/asset.png",
                "mimeType": "image/png",
            ]],
        ]
        let mediaURL = try fixture.write(
            "media.json", try JSONSerialization.data(withJSONObject: media,
                                                      options: [.sortedKeys]))
        _ = mediaURL
        return (fixture, canvasID, canvasURL)
    }

    func testCanvasPackageRoundTripCarriesCanvasMediaAndMaterials() async throws {
        let (fixture, canvasID, canvasURL) = try syntheticCanvas()
        let childID = UUID()
        // Rebuild a canvas whose child id matches the media project above.
        var object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: canvasURL)) as! [String: Any]
        var documents = object["documents"] as! [[String: Any]]
        var nodes = documents[0]["nodes"] as! [[String: Any]]
        nodes[0]["metadata"] = [
            "canvas.childProject": #"{"schemaVersion":1,"projectID":"\#(childID.uuidString)","appliedRevision":1}"#,
        ]
        documents[0]["nodes"] = nodes
        object["documents"] = documents
        let canvasData = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys])
        try canvasData.write(to: canvasURL)
        let media: [String: Any] = [
            "id": childID.uuidString,
            "schemaVersion": 1,
            "ownerKind": "canvas",
            "ownerID": canvasID.uuidString,
            "assets": [[
                "id": UUID().uuidString,
                "relativePath": "Workbench/Assets/asset.png",
                "mimeType": "image/png",
            ]],
        ]
        let mediaURL = try fixture.write(
            "media.json", try JSONSerialization.data(withJSONObject: media,
                                                      options: [.sortedKeys]))
        let material = try fixture.write("picture.png", Data("png".utf8))
        let asset = try fixture.write("asset.png", Data("asset".utf8))
        let source = C07CanvasSource(
            canvasURL: canvasURL,
            childProjects: [childID: mediaURL],
            materials: ["picture.png": material],
            assets: ["Workbench/Assets/asset.png": asset])
        let destination = fixture.destination("canvas.flocanvas")
        let built = try await C07CanvasPackage.build(
            source: source, destination: destination,
            stagingRoot: fixture.root.appendingPathComponent("stage"))
        XCTAssertGreaterThan(built.byteCount, 0)
        let inspected = try C07CanvasPackage.inspect(
            archiveURL: destination,
            stagingRoot: fixture.root.appendingPathComponent("inspect"))
        XCTAssertEqual(inspected.manifest.canvasID, canvasID)
        XCTAssertEqual(inspected.manifest.childProjects.count, 1)
        XCTAssertEqual(inspected.manifest.materials.count, 1)
        XCTAssertEqual(inspected.manifest.assets.count, 1)
        XCTAssertEqual(try Data(contentsOf: inspected.materials["picture.png"]!),
                       Data("png".utf8))
    }

    func testCanvasPackageCarriesOpaqueDonorCADSectionsReadOnly() throws {
        let canvasID = UUID()
        let nodeID = UUID()
        var manifest = C07CanvasPackageManifest(
            canvasID: canvasID, canvasName: "x", canvasSchemaVersion: 7,
            canvasByteCount: 1,
            canvasSHA256: String(repeating: "a", count: 64))
        manifest.cadDrafts = [C07CanvasCADDraft(
            nodeID: nodeID, canvasID: canvasID,
            descriptorFile: "caddrafts/draft-0.json",
            drawingFile: "caddrafts/draft-0.png",
            drawingByteCount: 2,
            drawingSHA256: String(repeating: "b", count: 64),
            descriptorByteCount: 2,
            descriptorSHA256: String(repeating: "c", count: 64))]
        XCTAssertNoThrow(try manifest.validate())
        // A draft owned by another canvas is a reference error, never a
        // silent drop.
        manifest.cadDrafts?[0].canvasID = UUID()
        XCTAssertThrowsError(try manifest.validate())
    }

    // MARK: - Portable documents

    private func makeDOCX(at url: URL, missingContentTypes: Bool = false) throws {
        let archive = try Archive(url: url, accessMode: .create)
        var entries: [(String, Data)] = [
            ("_rels/.rels", Data("<rels/>".utf8)),
            ("word/document.xml", Data("<document/>".utf8)),
        ]
        if !missingContentTypes {
            entries.append(("[Content_Types].xml", Data("<Types/>".utf8)))
        }
        for (path, data) in entries {
            try archive.addEntry(
                with: path, type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate) { position, size in
                    let start = Int(position)
                    return data.subdata(in: start..<min(start + size, data.count))
                }
        }
    }

    func testDOCXValidationAcceptsRealPackageAndRejectsMissingContentTypes() throws {
        let fixture = try Fixture()
        let valid = fixture.destination("valid.docx")
        try makeDOCX(at: valid)
        let inspected = try C07PortableDocumentInspector.inspect(
            fileURL: valid, displayName: "valid.docx")
        XCTAssertEqual(inspected.kind, .docx)

        let invalid = fixture.destination("invalid.docx")
        try makeDOCX(at: invalid, missingContentTypes: true)
        XCTAssertThrowsError(try C07PortableDocumentInspector.inspect(
            fileURL: invalid, displayName: "invalid.docx"))
    }

    func testTruncatedPDFIsRejected() throws {
        let fixture = try Fixture()
        let truncated = try fixture.write(
            "truncated.pdf", Data("%PDF-1.7\n1 0 obj\n".utf8))
        XCTAssertThrowsError(try C07PortableDocumentInspector.inspect(
            fileURL: truncated, displayName: "truncated.pdf"))
        let complete = try fixture.write(
            "complete.pdf",
            Data("%PDF-1.7\n1 0 obj\nendobj\nxref\n0 1\ntrailer\nstartxref\n9\n%%EOF\n".utf8))
        XCTAssertNoThrow(try C07PortableDocumentInspector.inspect(
            fileURL: complete, displayName: "complete.pdf"))
    }
}
