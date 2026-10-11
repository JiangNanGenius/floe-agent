// FloeCoreTests — Canvas authority snapshot (canvas.getState).
//
// The snapshot's per-node migration context is DERIVED from the node's real
// typed metadata on every read (legacy marker JSON, native CAD binding) and
// must stay backward compatible with snapshots serialized before the field
// existed. No second state store is created.

import Foundation
import Testing
@testable import FloeCore

@Suite("Canvas authority snapshot migration metadata")
struct CanvasOperationsTests {

    private func project(documentID: UUID, nodes: [CanvasNode]) -> CanvasProject {
        CanvasProject(
            id: UUID(), name: "Snapshot",
            documents: [CanvasDocument(id: documentID, name: "Main", nodes: nodes)],
            selectedDocumentID: documentID,
            revision: 4)
    }

    private func sceneNode(
        id: UUID = UUID(),
        scene: CanvasScene3D,
        metadata: [String: String] = [:]
    ) -> CanvasNode {
        CanvasNode(
            id: id, kind: .scene3D, text: "Scene",
            position: .init(x: 20, y: 30), size: .init(width: 320, height: 240),
            zIndex: 1, scene3D: scene, metadata: metadata)
    }

    private func nativeNode(
        id: UUID = UUID(),
        assetPath: String? = nil,
        assetHash: String? = nil,
        metadata: [String: String] = [:]
    ) -> CanvasNode {
        CanvasNode(
            id: id, kind: .file, text: "CAD Model",
            position: .init(x: 40, y: 60), size: .init(width: 420, height: 300),
            zIndex: 2,
            asset: assetPath.map {
                CanvasAssetReference(
                    id: UUID(), contentHash: assetHash,
                    localRelativePath: $0, mimeType: "application/octet-stream",
                    byteCount: 1024)
            },
            metadata: metadata)
    }

    private func markerJSON(sceneDigest: String) throws -> String {
        let marker = LegacySceneMigrationMarker(
            sceneDigest: sceneDigest, objectCount: 1)
        let data = try JSONEncoder().encode(marker)
        return try #require(String(data: data, encoding: .utf8))
    }

    @Test("legacy, migrated and conflict nodes are classified from real node state")
    func migrationStatesAreDerived() throws {
        let documentID = UUID()
        let scene = CanvasScene3D.starter()
        let digest = LegacySceneMigration.canonicalDigest(of: scene)
        let legacyID = UUID()
        let migratedID = UUID()
        let conflictID = UUID()
        let nodes = [
            sceneNode(id: legacyID, scene: scene),
            sceneNode(
                id: migratedID, scene: scene,
                metadata: [CADCanvasNodePlanner.MetadataKeys.legacyMigration:
                    try markerJSON(sceneDigest: digest)]),
            sceneNode(
                id: conflictID, scene: scene,
                metadata: [CADCanvasNodePlanner.MetadataKeys.legacyMigration:
                    try markerJSON(sceneDigest: String(repeating: "0", count: 64))]),
        ]
        let snapshot = try CanvasCommandService.snapshot(
            project: project(documentID: documentID, nodes: nodes),
            documentID: documentID)

        let context = try #require(snapshot.nodeMetadata)
        #expect(context.count == 3)
        let byID = Dictionary(uniqueKeysWithValues: context.map { ($0.nodeID, $0) })
        #expect(byID[legacyID]?.migrationState == "legacyUnchanged")
        #expect(byID[migratedID]?.migrationState == "migrated")
        #expect(byID[conflictID]?.migrationState == "conflict")
        // The embedded original is preserved on the migrated node (the
        // classification is real, not a marker-only shortcut).
        #expect(snapshot.nodes.first { $0.id == migratedID }?.scene3D != nil)
    }

    @Test("native CAD nodes report the actual recorded package binding")
    func nativePackageBindingIsReported() throws {
        let documentID = UUID()
        let boundID = UUID()
        let firstImportID = UUID()
        let nodes = [
            nativeNode(
                id: boundID,
                metadata: [
                    CADCanvasNodePlanner.MetadataKeys.sourcePath: "canvas-cad:\(documentID.uuidString)/model.floecad",
                    CADCanvasNodePlanner.MetadataKeys.sourceHash: String(repeating: "a", count: 64),
                ]),
            // Not yet applied: the live asset IS the package.
            nativeNode(
                id: firstImportID,
                assetPath: "Materials/imported.floecad",
                assetHash: String(repeating: "b", count: 64)),
        ]
        let snapshot = try CanvasCommandService.snapshot(
            project: project(documentID: documentID, nodes: nodes),
            documentID: documentID)
        let context = try #require(snapshot.nodeMetadata)
        let byID = Dictionary(uniqueKeysWithValues: context.map { ($0.nodeID, $0) })
        #expect(byID[boundID]?.migrationState == nil)
        #expect(byID[boundID]?.nativePackagePath?
            .contains("model.floecad") == true)
        #expect(byID[boundID]?.nativePackageHash == String(repeating: "a", count: 64))
        #expect(byID[firstImportID]?.nativePackagePath == "Materials/imported.floecad")
        #expect(byID[firstImportID]?.nativePackageHash == String(repeating: "b", count: 64))
    }

    @Test("Snapshots without migration context stay nil and never invent entries")
    func plainSnapshotsHaveNoContext() throws {
        let documentID = UUID()
        let node = CanvasNode(
            kind: .text, text: "note",
            position: .init(x: 0, y: 0), size: .init(width: 200, height: 100))
        let snapshot = try CanvasCommandService.snapshot(
            project: project(documentID: documentID, nodes: [node]),
            documentID: documentID)
        #expect(snapshot.nodeMetadata == nil)
    }

    @Test("New snapshots round-trip and old serialized snapshots decode unchanged")
    func snapshotDecodingIsBackwardCompatible() throws {
        let documentID = UUID()
        let scene = CanvasScene3D.starter()
        let node = sceneNode(scene: scene)
        let snapshot = try CanvasCommandService.snapshot(
            project: project(documentID: documentID, nodes: [node]),
            documentID: documentID)
        #expect(snapshot.nodeMetadata?.count == 1)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(snapshot)
        #expect(try decoder.decode(CanvasContextSnapshot.self, from: data) == snapshot)

        // Simulate a snapshot persisted by an older build: the new key is
        // absent entirely.
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("snapshot did not encode as an object"); return
        }
        object.removeValue(forKey: "nodeMetadata")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try decoder.decode(CanvasContextSnapshot.self, from: legacyData)
        #expect(legacy.nodeMetadata == nil)
        #expect(legacy.nodes.count == snapshot.nodes.count)
        #expect(legacy.revision == snapshot.revision)
        #expect(legacy.canvasID == snapshot.canvasID)
    }
}
