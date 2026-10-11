// SPDX-License-Identifier: MPL-2.0
// FloeApp — first-edit migration of a legacy Canvas 3D scene into the unified
// FloeCAD workbench.
//
// The legacy 3D Director is retired for editing: an existing `scene3D` canvas
// node migrates ON FIRST EDIT through THIS service, which:
//   1. reads the canvas fresh and classifies the node
//      (`CanvasNode.legacySceneMigrationState`) — never guesses;
//   2. validates the WHOLE scene (`LegacySceneMigration.evaluate`). Anything
//      unrepresentable refuses before any write: the legacy node, its embedded
//      scene and its preview stay fully intact and the caller shows the
//      reasons;
//   3. preserves a recoverable original: the exact scene JSON and the whole
//      node are written to `<canvas>/migration-backups/<node>-<digest>.json`
//      BEFORE a package exists, and the node keeps its embedded `scene3D`;
//   4. reserves ONE canvas-owned `.floecad` package through a node-keyed
//      pending record (crash/cancel recovery reuses the same package and
//      overwrites it in place — never a second orphan file);
//   5. imports the scene (windows: bodies + presentation), saves, verifies the
//      stored identity, exports the viewport PNG and persists the render
//      asset. The preview must be a REAL viewport render: the bridge's empty
//      placeholder is refused, leaving the legacy node and backup untouched;
//   6. CAS-updates the SAME node id in ONE revision: kind `.file`, the
//      canvas-owned binding, the migration marker, the render asset. Name,
//      position, size, rotation and every edge are preserved by the patch.
//
// The result carries the bounded visual approximations (intensity
// normalization, planar ground shadow) that the canvas/editor UI must
// disclose; the same list is persisted in the package provenance.
//
// Idempotency: a migrated node resolves its package (reopening is a no-op); a
// crash between package save and node commit is recovered by the idempotent
// re-import returning the recorded bodies; a conflict (embedded scene edited
// after migration) is surfaced, never silently re-migrated.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCAD
import FloeCore
import FloePersistence

@MainActor
enum LegacySceneMigrationService {

    // MARK: - Outcomes

    struct Success: Sendable, Equatable {
        public let canvasID: UUID
        public let documentID: UUID
        public let nodeID: UUID
        /// `canvas-cad:<canvas>/<file>` binding recorded on the node.
        public let sourceKey: String
        public let objectCount: Int
        /// The knowingly bounded visual differences of this migration
        /// (intensity normalization; planar ground shadow). T6 discloses
        /// these with the migrated presentation; the same list is persisted
        /// in the package provenance (`CADSceneSettings.legacy`).
        public let visualApproximations: [CADLegacyVisualApproximation]
    }

    enum Outcome: Sendable, Equatable {
        /// Migrated (or recovered) and the node was CAS-updated.
        case migrated(Success)
        /// Already migrated before this call; the package resolves.
        case alreadyMigrated(Success)
        /// At least one value cannot be represented. NOTHING was written.
        case unsupported([LegacySceneMigrationReason])
        /// Marker and embedded scene disagree — the node must not be
        /// auto-resolved; the native document stays authoritative.
        case conflict(embeddedDigest: String, markerDigest: String)
        /// Transient/durable failure. `retryable` tells the caller whether a
        /// retry can succeed without user action (pending package is kept).
        case failed(message: String, retryable: Bool)
    }

    // MARK: - State classification

    /// The node's migration state for routing (T6 reads this before opening
    /// the workbench). Pure; no I/O.
    static func migrationState(of node: CanvasNode) -> LegacyNodeMigrationState {
        node.legacySceneMigrationState
    }

    // MARK: - First edit

    /// Migrate a legacy `scene3D` node on first edit. See the file header for
    /// the exact ordering and failure semantics.
    static func migrateOnFirstEdit(
        canvasID: UUID,
        documentID: UUID,
        nodeID: UUID,
        assetStore: CreativeAssetStore
    ) async -> Outcome {
        let project: CanvasProject
        do {
            project = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        } catch {
            return .failed(message: error.localizedDescription, retryable: true)
        }
        guard let located = locateNode(project: project, documentID: documentID, nodeID: nodeID) else {
            return .failed(message: NSLocalizedString(
                "workspace.canvas_cad.migration_node_missing",
                value: "The 3D scene node no longer exists.",
                comment: "Legacy scene migration: node not found"), retryable: false)
        }
        let node = located.node

        switch node.legacySceneMigrationState {
        case .notLegacyScene:
            return .failed(message: NSLocalizedString(
                "workspace.canvas_cad.migration_not_legacy",
                value: "This node is not a legacy 3D scene.",
                comment: "Legacy scene migration: wrong node kind"), retryable: false)

        case .conflict(let embeddedDigest, let markerDigest):
            // Never auto-resolve: the embedded legacy payload was edited after
            // migration. The native document stays authoritative.
            return .conflict(embeddedDigest: embeddedDigest, markerDigest: markerDigest)

        case .migrated(_, _):
            guard let key = node.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath],
                  let url = CanvasCADStorage.packageURL(forKey: key),
                  FileManager.default.fileExists(atPath: url.path) else {
                return .failed(message: NSLocalizedString(
                    "workspace.canvas_cad.migration_package_missing",
                    value: "The migrated CAD document for this node is missing on this device.",
                    comment: "Legacy scene migration: package missing"), retryable: false)
            }
            clearPending(canvasID: canvasID, nodeID: nodeID)
            return .alreadyMigrated(Success(
                canvasID: canvasID, documentID: located.documentID, nodeID: nodeID,
                sourceKey: key, objectCount: node.scene3D?.objects.count ?? 0,
                visualApproximations: node.scene3D.map {
                    Self.visualApproximations(for: $0)
                } ?? []))

        case .legacyUnchanged(let scene):
            return await migrate(
                canvasID: canvasID, documentID: located.documentID,
                node: node, scene: scene, assetStore: assetStore)
        }
    }

    /// The presentation T6 opens after a successful migration.
    static func presentation(for success: Success) -> CanvasNativeCADPresentation {
        CanvasNativeCADPresentation(
            id: success.nodeID, canvasID: success.canvasID,
            documentID: success.documentID,
            sourceKey: success.sourceKey)
    }

    // MARK: - Disclosures + preview gate

    /// A migrated scene's canvas preview must be a REAL viewport render. The
    /// bridge falls back to an explicit empty placeholder when the device
    /// cannot render; new-document creation may accept that, but committing
    /// it for a migration would present a blank image as the migrated scene.
    /// Returning nil means "do not commit": the legacy node, its embedded
    /// scene and the backup stay intact and the reserved package is reused on
    /// retry.
    static func migrationRender(
        from exported: CADCanvasActionBridge.ExportedRender
    ) -> CADCanvasActionBridge.ExportedRender? {
        exported.isPlaceholder ? nil : exported
    }

    /// Mirrors the importer's persisted approximation list
    /// (`CADLegacyScene.visualApproximations` in FloeCADKit) for the
    /// already-migrated path. An app test compares both lists so the two
    /// cannot drift; the package provenance stays authoritative once written.
    static func visualApproximations(
        for scene: CanvasScene3D
    ) -> [CADLegacyVisualApproximation] {
        var approximations: [CADLegacyVisualApproximation] = [.lightingIntensityNormalized]
        if scene.lighting.castsShadows { approximations.append(.planarGroundShadow) }
        return approximations
    }

    // MARK: - Migration core

    private static func migrate(
        canvasID: UUID,
        documentID: UUID,
        node: CanvasNode,
        scene: CanvasScene3D,
        assetStore: CreativeAssetStore
    ) async -> Outcome {
        // 1. Full pre-flight validation: refuse BEFORE any write.
        let evaluation = LegacySceneMigration.evaluate(scene)
        guard evaluation.isFullyRepresentable else {
            return .unsupported(evaluation.reasons)
        }

        // 2. Canonical source bytes (same encoding as the digest).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let sourceJSON = try? encoder.encode(scene) else {
            return .failed(message: NSLocalizedString(
                "workspace.canvas_cad.migration_encode_failed",
                value: "The 3D scene could not be encoded for migration.",
                comment: "Legacy scene migration: encode failure"), retryable: false)
        }

        // 3. Recoverable original BEFORE the package exists.
        do {
            try writeBackup(canvasID: canvasID, documentID: documentID,
                            node: node, sourceJSON: sourceJSON,
                            digest: evaluation.canonicalDigest)
        } catch {
            return .failed(message: error.localizedDescription, retryable: true)
        }

        // 4. Reserve ONE package through the node-keyed pending record.
        let url: URL
        let overwrite: Bool
        do {
            let reserved = try reservePackage(
                canvasID: canvasID, nodeID: node.id,
                displayName: node.text, digest: evaluation.canonicalDigest)
            url = reserved.url
            overwrite = reserved.overwrite
        } catch {
            return .failed(message: error.localizedDescription, retryable: true)
        }
        let sourceKey = CADCanvasActionBridge.sourcePathKey(packageURL: url)

        // 5. Package: create or reopen, import (idempotent), save, verify.
        let document: FloeCADDocument
        do {
            if overwrite || !FileManager.default.fileExists(atPath: url.path) {
                document = try await FloeCADDocument.create(
                    at: url, name: packageBaseName(node),
                    overwrite: FileManager.default.fileExists(atPath: url.path))
            } else {
                document = try await FloeCADDocument.open(at: url)
            }
        } catch {
            return .failed(message: error.localizedDescription, retryable: true)
        }
        defer { document.close() }

        do {
            let payload = cadScene(from: scene, digest: evaluation.canonicalDigest,
                                   sourceJSON: sourceJSON)
            let imported = try document.importLegacyScene(payload)
            let save = await document.save()
            guard save.succeeded else {
                return .failed(message: save.error ?? NSLocalizedString(
                    "workspace.canvas_cad.migration_save_failed",
                    value: "The CAD document could not be saved.",
                    comment: "Legacy scene migration: save failed"), retryable: true)
            }
            // Verify the stored identity and the recorded provenance: the
            // canvas must never be pointed at an unverified package.
            guard let identity = await FloeCADDocument.storedIdentity(at: url),
                  identity.contentSHA256 == save.contentSHA256,
                  let stored = document.sceneSettings?.legacy,
                  stored.sceneDigest == evaluation.canonicalDigest,
                  stored.objectCount == scene.objects.count else {
                return .failed(message: NSLocalizedString(
                    "workspace.canvas_cad.migration_verify_failed",
                    value: "The migrated CAD document failed verification; nothing was changed on the canvas.",
                    comment: "Legacy scene migration: verification failed"), retryable: true)
            }

            // 6. Render + node commit (same primitives as the CAD bridge).
            // A migration preview must be a REAL viewport render: the bridge's
            // empty placeholder is acceptable for a deliberately blank new
            // document, but committing it here would present a blank image as
            // the migrated scene. A render failure keeps the legacy node, its
            // embedded scene and the backup intact; the reserved package stays
            // in place for a safe retry.
            let exported = try await CADCanvasActionBridge.exportPNG(document: document, url: url)
            guard let renderSource = migrationRender(from: exported) else {
                return .failed(message: NSLocalizedString(
                    "workspace.canvas_cad.migration_render_failed",
                    value: "The migrated CAD viewport could not be rendered; the legacy scene is unchanged and the migration can be retried.",
                    comment: "Legacy scene migration: viewport render placeholder refused"),
                    retryable: true)
            }
            let render = try await CADCanvasActionBridge.persistRender(
                renderSource, document: document, node: node, assetStore: assetStore)
            let marker = LegacySceneMigrationMarker(
                sceneDigest: evaluation.canonicalDigest,
                objectCount: scene.objects.count)
            let operation = try CADCanvasNodePlanner.legacyMigrationPatch(
                liveNode: node,
                sourcePath: sourceKey,
                sourceAssetHash: exported.packageSHA256,
                renderedAsset: render,
                marker: marker,
                extraMetadata: [
                    // Always "viewport": placeholders are refused above.
                    "preview": "viewport",
                    "appliedRevision": String(exported.revision),
                    "appliedContentHash": exported.hash,
                    "migratedLegacyObjectCount": String(imported.bodyIDs.count)
                ])
            guard try await CADCanvasActionBridge.commit(
                operations: [operation], nodeID: node.id,
                canvasID: canvasID, documentID: documentID,
                assetStore: assetStore) != nil else {
                return .failed(message: NSLocalizedString(
                    "workspace.canvas_cad.migration_commit_failed",
                    value: "The canvas write failed; the legacy scene is unchanged and the migration can be retried.",
                    comment: "Legacy scene migration: CAS commit failed"), retryable: true)
            }
            clearPending(canvasID: canvasID, nodeID: node.id)
            return .migrated(Success(
                canvasID: canvasID, documentID: documentID, nodeID: node.id,
                sourceKey: sourceKey, objectCount: scene.objects.count,
                visualApproximations: imported.visualApproximations))
        } catch let error as CADLegacySceneImportError {
            // The package exists but is incomplete; pending + backup stay for
            // a retry. Never a partial canvas write.
            return .failed(message: error.localizedDescription, retryable: true)
        } catch {
            return .failed(message: error.localizedDescription, retryable: true)
        }
    }

    // MARK: - Scene mapping

    /// Canvas scene → the neutral FloeCAD import payload. Every field is
    /// carried; units and Euler order are handled by the importer.
    static func cadScene(from scene: CanvasScene3D, digest: String,
                         sourceJSON: Data) -> CADLegacyScene {
        let objects = scene.objects.map { object in
            CADLegacyScene.Object(
                id: object.id,
                name: object.name,
                kind: cadKind(object.kind),
                positionX: object.position.x, positionY: object.position.y,
                positionZ: object.position.z,
                rotationX: object.rotation.x, rotationY: object.rotation.y,
                rotationZ: object.rotation.z,
                scaleX: object.scale.x, scaleY: object.scale.y, scaleZ: object.scale.z,
                colorHex: object.colorHex,
                roughness: object.roughness,
                metallic: object.metallic,
                isHidden: object.isHidden)
        }
        let camera = CADLegacyScene.Camera(
            yawDegrees: scene.camera.orbitYaw,
            pitchDegrees: scene.camera.orbitPitch,
            distance: scene.camera.distance,
            targetX: scene.camera.target.x, targetY: scene.camera.target.y,
            targetZ: scene.camera.target.z,
            fieldOfViewDegrees: scene.camera.fieldOfView)
        let lighting = CADLegacyScene.Lighting(
            keyIntensity: scene.lighting.keyIntensity,
            fillIntensity: scene.lighting.fillIntensity,
            castsShadows: scene.lighting.castsShadows)
        return CADLegacyScene(
            objects: objects, camera: camera, lighting: lighting,
            background: cadBackground(scene.background),
            showsGrid: scene.showsGrid,
            sourceDigest: digest, sourceSceneJSON: sourceJSON)
    }

    private static func cadKind(_ kind: CanvasSceneObjectKind) -> CADLegacyScene.Object.Kind {
        switch kind {
        case .box: .box
        case .sphere: .sphere
        case .cylinder: .cylinder
        case .cone: .cone
        case .plane: .plane
        }
    }

    private static func cadBackground(_ background: CanvasSceneBackground) -> CADLegacyScene.Background {
        switch background {
        case .studio: .studio
        case .graphite: .graphite
        case .midnight: .midnight
        case .chromaGreen: .chromaGreen
        }
    }

    // MARK: - Node location

    private struct LocatedNode {
        let documentID: UUID
        let node: CanvasNode
    }

    private static func locateNode(project: CanvasProject, documentID: UUID,
                                   nodeID: UUID) -> LocatedNode? {
        if let document = project.documents.first(where: { $0.id == documentID }),
           let node = document.nodes.first(where: { $0.id == nodeID }) {
            return LocatedNode(documentID: documentID, node: node)
        }
        for document in project.documents {
            if let node = document.nodes.first(where: { $0.id == nodeID }) {
                return LocatedNode(documentID: document.id, node: node)
            }
        }
        return nil
    }

    // MARK: - Pending reservation (per canvas, keyed by node)

    struct PendingRecord: Codable, Equatable {
        var fileName: String
        var digest: String
        var createdAt: Date
    }

    static func pendingFileURL(canvasID: UUID) -> URL? {
        guard let dir = try? CanvasCADStorage.directory(canvasID: canvasID) else { return nil }
        return dir.appendingPathComponent("legacy-migration-pending.json")
    }

    static func loadPending(canvasID: UUID) -> [String: PendingRecord] {
        guard let url = pendingFileURL(canvasID: canvasID),
              let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([String: PendingRecord].self, from: data) else {
            return [:]
        }
        return records
    }

    static func storePending(_ records: [String: PendingRecord], canvasID: UUID) {
        guard let url = pendingFileURL(canvasID: canvasID) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(records) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    static func pendingRecord(canvasID: UUID, nodeID: UUID) -> PendingRecord? {
        loadPending(canvasID: canvasID)[nodeID.uuidString]
    }

    static func clearPending(canvasID: UUID, nodeID: UUID) {
        var records = loadPending(canvasID: canvasID)
        records.removeValue(forKey: nodeID.uuidString)
        storePending(records, canvasID: canvasID)
    }

    /// Reserve the package this node will bind to. One package per node:
    /// an existing pending file is REUSED (and overwritten in place when the
    /// scene digest changed — the store keeps the previous commit under
    /// `previous/`), so a crash/cancel can never leave two orphans.
    private static func reservePackage(
        canvasID: UUID, nodeID: UUID, displayName: String?, digest: String
    ) throws -> (url: URL, overwrite: Bool) {
        var records = loadPending(canvasID: canvasID)
        let key = nodeID.uuidString
        let dir = try CanvasCADStorage.directory(canvasID: canvasID)

        if let record = records[key] {
            let candidate = dir.appendingPathComponent(record.fileName).standardizedFileURL
            // Containment: the recorded file must stay inside this canvas.
            if candidate.path.hasPrefix(dir.standardizedFileURL.path + "/") {
                let exists = FileManager.default.fileExists(atPath: candidate.path)
                // Same digest: reopen and finish the interrupted commit. A
                // changed digest overwrites the same package IN PLACE (the
                // store keeps the previous commit), so no second orphan.
                let overwrite = exists && record.digest != digest
                records[key] = PendingRecord(fileName: record.fileName, digest: digest,
                                             createdAt: record.createdAt)
                storePending(records, canvasID: canvasID)
                return (candidate, overwrite)
            }
        }
        let url = try CanvasCADStorage.uniquePackageURL(
            canvasID: canvasID,
            baseName: displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? displayName! : "Legacy Scene")
        records[key] = PendingRecord(fileName: url.lastPathComponent, digest: digest,
                                     createdAt: Date())
        storePending(records, canvasID: canvasID)
        return (url, false)
    }

    private static func packageBaseName(_ node: CanvasNode) -> String {
        let trimmed = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Legacy Scene" : trimmed
    }

    // MARK: - Recoverable original

    /// The original node + scene, written before any migration write and kept
    /// after success. The node itself also keeps its embedded `scene3D`.
    struct BackupRecord: Codable {
        var schemaVersion: Int
        var nodeID: UUID
        var canvasID: UUID
        var documentID: UUID
        var sceneDigest: String
        var createdAt: Date
        var node: CanvasNode
    }

    static func backupDirectory(canvasID: UUID) -> URL? {
        guard let dir = try? CanvasCADStorage.directory(canvasID: canvasID) else { return nil }
        return dir.appendingPathComponent("migration-backups", isDirectory: true)
    }

    static func backupFileURL(canvasID: UUID, nodeID: UUID, digest: String) -> URL? {
        guard let dir = backupDirectory(canvasID: canvasID) else { return nil }
        return dir.appendingPathComponent(
            "\(nodeID.uuidString)-\(digest.prefix(8)).json")
    }

    private static func writeBackup(canvasID: UUID, documentID: UUID,
                                    node: CanvasNode, sourceJSON: Data,
                                    digest: String) throws {
        guard let directory = backupDirectory(canvasID: canvasID),
              let url = backupFileURL(canvasID: canvasID, nodeID: node.id, digest: digest) else {
            throw CADDocumentError(code: "migration_backup_unavailable",
                                   message: NSLocalizedString(
                                       "workspace.canvas_cad.migration_backup_failed",
                                       value: "The original 3D scene could not be backed up; migration was not started.",
                                       comment: "Legacy scene migration: backup unavailable"))
        }
        if FileManager.default.fileExists(atPath: url.path) { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = BackupRecord(
            schemaVersion: 1, nodeID: node.id, canvasID: canvasID,
            documentID: documentID, sceneDigest: digest, createdAt: Date(), node: node)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(record).write(to: url, options: [.atomic])
    }
}
#endif
