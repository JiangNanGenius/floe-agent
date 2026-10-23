// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloePersistence

/// Bridge-side deferral authority shared between the live editor and
/// unattended Canvas writers. Owners are weak because `CanvasDocumentStore`
/// is file-private, and a deallocated editor must never leave a canvas
/// pinned busy forever. Gestures and publication both live on the
/// MainActor, so isolated storage plus the synchronous publish hop is
/// sufficient — no locks, no per-stroke file IO.
@MainActor
final class CanvasInteractiveActivityRegistry {
    static let shared = CanvasInteractiveActivityRegistry()

    private struct OwnerEntry {
        weak var target: AnyObject?
        let canvasID: UUID
    }

    private var owners: [ObjectIdentifier: OwnerEntry] = [:]
    private var publishedRevisions: [UUID: Int64] = [:]

    private init() {}

    /// A gesture owns its canvas draft from begin until finish or dealloc.
    func begin(owner: AnyObject, canvasID: UUID) {
        pruneOwners()
        owners[ObjectIdentifier(owner)] = OwnerEntry(target: owner, canvasID: canvasID)
    }

    func end(owner: AnyObject) {
        owners[ObjectIdentifier(owner)] = nil
        pruneOwners()
    }

    func hasBusyOwner(for canvasID: UUID) -> Bool {
        pruneOwners()
        return owners.values.contains { $0.target != nil && $0.canvasID == canvasID }
    }

    /// Newest externally published file revision per canvas. The editor
    /// consults this before starting a gesture, so a lost change
    /// notification can never let a new stroke begin from a stale base
    /// revision that the bridge already moved.
    func markPublished(canvasID: UUID, revision: Int64) {
        publishedRevisions[canvasID] = max(publishedRevisions[canvasID] ?? 0, revision)
    }

    func hasNewerPublishedRevision(for canvasID: UUID, than revision: Int64) -> Bool {
        guard let published = publishedRevisions[canvasID] else { return false }
        return published > revision
    }

    private func pruneOwners() {
        owners = owners.filter { $0.value.target != nil }
    }
}

@MainActor
final class CanvasExternalImportCommitter: CanvasDestinationCommitting {
    private let ingestion: CreativeAssetIngestionService
    private let assets: CreativeAssetStore
    private let sync: CanvasSyncOperationStore
    /// Focused-test seam for the destination directory; nil (production)
    /// resolves through `WorkspaceCanvasRegistry`.
    private let canvasDirectoryOverride: URL?

    init(ingestion: CreativeAssetIngestionService, assets: CreativeAssetStore,
         sync: CanvasSyncOperationStore, canvasDirectoryOverride: URL? = nil) {
        self.ingestion = ingestion
        self.assets = assets
        self.sync = sync
        self.canvasDirectoryOverride = canvasDirectoryOverride
    }

    private func destinationURL(canvasID: UUID, creating: Bool) throws -> URL {
        guard let directory = canvasDirectoryOverride else {
            return try WorkspaceCanvasRegistry.projectURL(canvasID: canvasID, createDirectory: creating)
        }
        if creating {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent("\(canvasID.uuidString).json")
    }

    func canvasImportTargets() throws -> [CanvasImportTarget] {
        try WorkspaceCanvasRegistry.checkedSummaries()
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { CanvasImportTarget(id: $0.id, name: $0.name) }
    }

    func commitImport(_ operation: CanvasImportOperation) async -> CanvasCommitResult {
        do {
            let canvasID: UUID
            let creating: Bool
            switch operation.target {
            case .existing(let id):
                canvasID = id
                creating = false
            case .newCanvas:
                guard let id = operation.plannedNewCanvasID else {
                    throw FloeError.validationFailed("Missing canvas import identity")
                }
                canvasID = id
                creating = true
            }
            guard !operation.units.isEmpty else {
                throw FloeError.validationFailed("Empty canvas import")
            }
            // Future defense, not chunking: production Share transport caps
            // items via `ShareInboxLimits.maxItems` (default 5), so >100
            // units is unreachable today. Splitting into several patches
            // would break the single atomic populated-creation guarantee
            // for new canvases. Failing before any ingestion keeps the
            // source/operation identities in the Share journal and never
            // leaves an empty canvas behind.
            guard operation.units.count <= CanvasExternalImportPublication.maximumUnitsPerOperation else {
                throw FloeError.validationFailed("Canvas import exceeds the patch operation limit")
            }
            // A live editor owns an in-memory draft while a gesture is in
            // flight; publishing under that draft would strand the next
            // stroke on a stale base revision. Defer before ANY ingestion
            // or file work — nothing lands on disk.
            guard !CanvasInteractiveActivityRegistry.shared.hasBusyOwner(for: canvasID) else {
                throw FloeError.validationFailed("Canvas import deferred: editor is drawing")
            }
            var items: [CanvasExternalImportPublication.Item] = []
            for unit in operation.units {
                try Task.checkCancellation()
                let asset = try await ingestion.importLocalFile(unit.payloadURL, displayName: unit.displayName)
                // The ingestion boundary owns the persisted record's
                // resolved (trimmed, never-empty) name. A meaningful unit
                // alias labels the inserted node only; an empty alias
                // falls back to that resolved name. The material record is
                // never re-titled here, so a content-dedup hit keeps its
                // established display name in the library and DB.
                let alias = unit.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                items.append(.init(nodeID: unit.plannedNodeID, asset: asset,
                                   displayName: alias.isEmpty ? nil : alias))
            }
            try Task.checkCancellation()
            let enabled = UserDefaults.standard.object(forKey: "creative.canvas.sync.enabled") as? Bool ?? true
            // The bridge and the editor are both MainActor-isolated and
            // this check→publish→mark block has no suspension point, so no
            // gesture can begin mid-publication.
            guard !CanvasInteractiveActivityRegistry.shared.hasBusyOwner(for: canvasID) else {
                throw FloeError.validationFailed("Canvas import deferred: editor is drawing")
            }
            let url = try destinationURL(canvasID: canvasID, creating: creating)
            let project = try CanvasExternalImportPublication.publish(
                operationID: operation.operationID, canvasID: canvasID, creating: creating,
                items: items, syncEnabled: enabled, at: url
            )
            CanvasInteractiveActivityRegistry.shared.markPublished(
                canvasID: canvasID, revision: project.revision
            )
            NotificationCenter.default.post(name: .floeCanvasProjectDidChange, object: nil,
                                            userInfo: ["canvasID": canvasID])
            // The source remains staged until these receipt-idempotent
            // operations succeed too. A retry uses the same planned nodes.
            for item in items {
                try await assets.applyReferenceOp(
                    opID: "canvas-external-import:\(item.nodeID.uuidString)",
                    assetID: item.asset.id, delta: 1
                )
            }
            if enabled && project.sync.isEnabled {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try CanvasProjectCodec.encode(project, encoder: encoder)
                let operationID = CanvasExternalImportPublication.identity(
                    "sync:\(project.sync.revision):\(FloeDigest.sha256Hex(data))",
                    operationID: operation.operationID
                )
                try await sync.enqueue(CanvasSyncOperation(
                    operationID: operationID, canvasID: canvasID, entityKind: .project,
                    entityID: canvasID, mutation: .upsert, revision: project.sync.revision,
                    payload: data, assetHashes: project.documents.flatMap(\.nodes)
                        .compactMap { $0.asset?.contentHash }
                ))
            }
            return .committed(canvasID: canvasID, nodeIDs: items.map(\.nodeID))
        } catch {
            FloeLogger(category: .app).error("canvasExternalImportFailed")
            return .failed(message: FloeL10n.l("share.intake.failed"))
        }
    }
}

/// The destination journal supplies these identities before file ingestion.
/// Publication uses the same file CAS as the editor; it never owns an editor.
enum CanvasExternalImportPublication {
    /// One publish must fit the shared `CanvasCommandService` patch
    /// contract (1...100 operations per patch, see CanvasOperations.swift).
    static let maximumUnitsPerOperation = 100

    struct Item {
        let nodeID: UUID
        let asset: CreativeAssetRecord
        /// Meaningful trimmed unit alias for the inserted node label; nil
        /// (or blank) resolves to the ingestion-proven asset displayName.
        let displayName: String?

        init(nodeID: UUID, asset: CreativeAssetRecord, displayName: String? = nil) {
            self.nodeID = nodeID
            self.asset = asset
            self.displayName = displayName
        }

        var resolvedName: String {
            if let displayName {
                let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            return asset.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func publish(
        operationID: UUID,
        canvasID: UUID,
        creating: Bool,
        items: [Item],
        syncEnabled: Bool,
        at url: URL
    ) throws -> CanvasProject {
        guard !items.isEmpty, items.count <= maximumUnitsPerOperation,
              Set(items.map(\.nodeID)).count == items.count,
              items.allSatisfy({ !$0.resolvedName.isEmpty }) else {
            throw FloeError.validationFailed("Invalid canvas import plan")
        }
        let writer = CanvasProjectFileWriter.shared
        for attempt in 0..<4 {
            let exists = FileManager.default.fileExists(atPath: url.path)
            let current: CanvasProject
            if exists {
                current = try writer.project(canvasID: canvasID, at: url)
            } else {
                guard creating else {
                    throw FloeError.validationFailed("Canvas no longer exists")
                }
                let document = CanvasDocument(
                    id: identity("document", operationID: operationID),
                    name: FloeL10n.l("workspace.workspace_canvas_view.canvas_1")
                )
                current = CanvasProject(
                    id: canvasID,
                    name: items[0].resolvedName,
                    documents: [document],
                    selectedDocumentID: document.id
                )
            }

            let nodes = current.documents.flatMap(\.nodes)
            let missing = try items.filter { item in
                guard let node = nodes.first(where: { $0.id == item.nodeID }) else { return true }
                guard node.asset?.id == item.asset.id,
                      node.metadata["externalImportID"] == operationID.uuidString else {
                    throw FloeError.validationFailed("Canvas import identity conflict")
                }
                return false
            }
            if missing.isEmpty { return current }
            // A new project is installed populated in one CAS. An unrelated
            // file at that planned identity must never become our destination.
            guard !creating || !exists else {
                throw FloeError.validationFailed("Canvas import project changed")
            }
            guard let document = current.documents.first(where: {
                $0.id == current.selectedDocumentID
            }) else { throw FloeError.validationFailed("Canvas page is unavailable") }

            let bottom = document.nodes.map { $0.position.y + $0.size.height }
                .max() ?? 0
            let operations = missing.enumerated().map { index, item in
                let asset = item.asset
                let kind: CanvasNodeKind = switch asset.kind {
                case .image: .image
                case .video: .video
                case .audio: .audio
                case .document: .file
                }
                return CanvasPatchOperation(
                    kind: .create, nodeID: item.nodeID, nodeKind: kind,
                    text: item.resolvedName,
                    position: .init(x: 120 + Double(index % 3) * 360,
                                    y: bottom + 120 + Double(index / 3) * 300),
                    size: .init(width: 320, height: kind == .video ? 220 : 260),
                    asset: CanvasAssetReference(
                        id: asset.id, contentHash: asset.contentHash,
                        localRelativePath: asset.localRelativePath,
                        cloudRecordName: asset.cloudRecordName,
                        mimeType: asset.mimeType, byteCount: asset.byteCount,
                        sourceURL: asset.sourceURL, license: asset.license
                    ),
                    metadata: ["artifactOrigin": "imported",
                               "externalImportID": operationID.uuidString]
                )
            }
            let patch = CanvasPatch(
                canvasID: canvasID, documentID: document.id,
                expectedRevision: current.revision, operations: operations
            )
            var (candidate, _) = try CanvasCommandService.applying(patch, to: current)
            if syncEnabled && candidate.sync.isEnabled { candidate.sync.revision += 1 }
            do {
                try writer.compareAndSwap(
                    candidate, at: url, expectedRevision: current.revision,
                    allowCreateIfMissing: !exists && creating
                )
                return candidate
            } catch {
                guard CanvasProjectFileWriter.isRevisionConflict(error), attempt < 3 else { throw error }
            }
        }
        throw FloeError.validationFailed("Canvas import could not commit")
    }

    static func identity(_ value: String, operationID: UUID) -> UUID {
        let hash = FloeDigest.sha256Hex(Data("canvas-import:\(operationID.uuidString):\(value)".utf8))
        let hex = Array(hash.prefix(32))
        let value = String(hex[0..<8]) + "-" + String(hex[8..<12]) + "-"
            + String(hex[12..<16]) + "-" + String(hex[16..<20]) + "-" + String(hex[20..<32])
        return UUID(uuidString: value)!
    }
}
#endif
