// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import Foundation
import FloeCAD
import FloeInteriorCore

/// Public MainActor facade for one native building/interior CAD document.
///
/// It owns no separate geometry, undo stack or persistence path: all edits go
/// through the supplied `FloeCADDocument`, whose save/CAS/undo rules remain
/// authoritative. The binding manifest is a portable value record for the
/// project/Records layer; it is never embedded by a private document schema.
@MainActor
public final class FloeBuildingCADSession {
    public let document: FloeCADDocument
    public private(set) var manifest: FloeBuildingCADManifest
    /// Where verified cabinet sheet snapshots are published. It must remain
    /// inside the document's parent directory so the manifest path is portable.
    public var snapshotDirectory: URL
    private var mutationInProgress = false

    public static func create(at url: URL, name: String) async throws -> FloeBuildingCADSession {
        let document = try await FloeCADDocument.create(at: url, name: name)
        var identity = document.savedIdentity
        if identity.modelSHA256.isEmpty {
            let saved = await document.save()
            guard saved.succeeded, !saved.modelSHA256.isEmpty else {
                document.close()
                throw FloeBuildingCADError.invalidNativeState(saved.error ?? "The new document has no verified model identity.")
            }
            identity = saved
        }
        let snapshotDirectory = url.deletingLastPathComponent()
            .appendingPathComponent("CabinetSheets", isDirectory: true)
        let session = FloeBuildingCADSession(
            document: document,
            manifest: FloeBuildingCADManifest(documentName: name,
                documentIdentity: FloeBuildingCADNativeIdentity(
                    revision: identity.revision,
                    contentSHA256: identity.contentSHA256,
                    modelSHA256: identity.modelSHA256),
                updatedAtISO8601: FloeBuildingCADGeometry.iso8601Now()),
            snapshotDirectory: snapshotDirectory)
        return session
    }

    public static func open(at url: URL) async throws -> FloeBuildingCADSession {
        let document = try await FloeCADDocument.open(at: url)
        let saved = document.savedIdentity
        let identity: FloeBuildingCADNativeIdentity? = saved.modelSHA256.isEmpty ? nil :
            FloeBuildingCADNativeIdentity(revision: saved.revision,
                                          contentSHA256: saved.contentSHA256,
                                          modelSHA256: saved.modelSHA256)
        let snapshotDirectory = url.deletingLastPathComponent()
            .appendingPathComponent("CabinetSheets", isDirectory: true)
        return FloeBuildingCADSession(
            document: document,
            manifest: FloeBuildingCADManifest(documentName: document.name,
                documentIdentity: identity,
                updatedAtISO8601: FloeBuildingCADGeometry.iso8601Now()),
            snapshotDirectory: snapshotDirectory)
    }

    private init(document: FloeCADDocument,
                 manifest: FloeBuildingCADManifest,
                 snapshotDirectory: URL) {
        self.document = document
        self.manifest = manifest
        self.snapshotDirectory = snapshotDirectory
    }

    /// Wrap a document the host already owns (for example a working copy of a
    /// published generation). The session never creates a second document or
    /// silently closes the host's one.
    public init(document: FloeCADDocument, snapshotDirectory: URL? = nil) {
        self.document = document
        let base = snapshotDirectory ?? document.url.deletingLastPathComponent()
            .appendingPathComponent("CabinetSheets", isDirectory: true)
        self.snapshotDirectory = base
        let saved = document.savedIdentity
        let identity: FloeBuildingCADNativeIdentity? = saved.modelSHA256.isEmpty ? nil :
            FloeBuildingCADNativeIdentity(revision: saved.revision,
                                          contentSHA256: saved.contentSHA256,
                                          modelSHA256: saved.modelSHA256)
        self.manifest = FloeBuildingCADManifest(documentName: document.name,
            documentIdentity: identity,
            updatedAtISO8601: FloeBuildingCADGeometry.iso8601Now())
    }

    public var isClosed: Bool { document.isClosed }
    public var isReadOnly: Bool { document.isReadOnly }

    /// The document's real undo/change generation, used only as a rollback
    /// fence for this bridge's own failed mutation batch.
    public var nativeChangeCount: Int { document.buildingChangeCount }

    public func close() {
        document.close()
    }

    /// The verified identity of the last commit. `modelSHA256` is required so
    /// a binding never records a preview-only or unverifiable identity.
    public func currentIdentity() throws -> FloeBuildingCADNativeIdentity {
        guard !document.isClosed else { throw FloeBuildingCADError.documentClosed }
        let saved = document.savedIdentity
        guard !saved.modelSHA256.isEmpty else { throw FloeBuildingCADError.missingNativeIdentity }
        return FloeBuildingCADNativeIdentity(revision: saved.revision,
                                             contentSHA256: saved.contentSHA256,
                                             modelSHA256: saved.modelSHA256)
    }

    @discardableResult
    public func save() async throws -> FloeBuildingCADNativeIdentity {
        guard !mutationInProgress else { throw FloeBuildingCADError.busy }
        return try await saveUnlocked()
    }

    /// Save used by an already-exclusive bridge batch (and by snapshot/export
    /// preparation). Public `save()` rejects re-entry while that batch is live.
    @discardableResult
    func saveUnlocked() async throws -> FloeBuildingCADNativeIdentity {
        guard !document.isClosed else { throw FloeBuildingCADError.documentClosed }
        guard !document.isReadOnly else { throw FloeBuildingCADError.readOnly }
        let saved = await document.save()
        guard saved.succeeded, !saved.modelSHA256.isEmpty else {
            throw FloeBuildingCADError.invalidNativeState(saved.error ?? "The native save produced no verified model identity.")
        }
        let identity = FloeBuildingCADNativeIdentity(revision: saved.revision,
                                                     contentSHA256: saved.contentSHA256,
                                                     modelSHA256: saved.modelSHA256)
        manifest.documentIdentity = identity
        manifest.documentName = document.name
        manifest.updatedAtISO8601 = FloeBuildingCADGeometry.iso8601Now()
        return identity
    }

    /// Install a manifest loaded by the project/Records owner. Structural
    /// uniqueness is checked now; live geometry is checked per operation.
    public func installManifest(_ value: FloeBuildingCADManifest) throws {
        guard value.schemaVersion == 1 else {
            throw FloeBuildingCADError.invalidInput("Unsupported building CAD manifest schema \(value.schemaVersion).")
        }
        guard Set(value.cabinets.map(\.cabinetID)).count == value.cabinets.count else {
            throw FloeBuildingCADError.invalidBinding("Duplicate cabinet id.")
        }
        guard Set(value.sheets.map(\.cabinetID)).count == value.sheets.count else {
            throw FloeBuildingCADError.invalidBinding("More than one sheet binding for one cabinet.")
        }
        guard Set(value.furniture.map(\.instanceID)).count == value.furniture.count else {
            throw FloeBuildingCADError.invalidBinding("Duplicate furniture instance id.")
        }
        var updated = value
        if updated.documentName.isEmpty { updated.documentName = document.name }
        if updated.documentIdentity == nil, !document.savedIdentity.modelSHA256.isEmpty {
            let saved = document.savedIdentity
            updated.documentIdentity = FloeBuildingCADNativeIdentity(
                revision: saved.revision, contentSHA256: saved.contentSHA256,
                modelSHA256: saved.modelSHA256)
        }
        manifest = updated
    }

    /// The document plus its manifest must be saved and byte-verified before a
    /// static copy (sheet snapshot or independent native copy) is captured.
    @discardableResult
    func ensureVerifiedSavedIdentity() async throws -> FloeBuildingCADNativeIdentity {
        guard !document.isClosed else { throw FloeBuildingCADError.documentClosed }
        if document.hasUnsavedChanges {
            _ = try await saveUnlocked()
        }
        let identity = try currentIdentity()
        guard let stored = await FloeCADDocument.storedIdentity(at: document.url) else {
            throw FloeBuildingCADError.invalidNativeState("The saved package identity could not be read back.")
        }
        guard stored.revision == identity.revision,
              stored.contentSHA256 == identity.contentSHA256,
              stored.modelSHA256 == identity.modelSHA256 else {
            throw FloeBuildingCADError.sourceNotSaved
        }
        return identity
    }

    // MARK: - Manifest mutation

    func putCabinet(_ binding: FloeBuildingCADCabinetBinding) {
        if let index = manifest.cabinets.firstIndex(where: { $0.cabinetID == binding.cabinetID }) {
            manifest.cabinets[index] = binding
        } else {
            manifest.cabinets.append(binding)
        }
    }

    func putSheet(_ binding: FloeBuildingCADSheetBinding) {
        if let index = manifest.sheets.firstIndex(where: { $0.cabinetID == binding.cabinetID }) {
            manifest.sheets[index] = binding
        } else {
            manifest.sheets.append(binding)
        }
    }

    func putFurniture(_ binding: FloeBuildingCADFurnitureBinding) {
        if let index = manifest.furniture.firstIndex(where: { $0.instanceID == binding.instanceID }) {
            manifest.furniture[index] = binding
        } else {
            manifest.furniture.append(binding)
        }
    }

    /// Record the building binding captured by the building authoring batch.
    /// This stays a narrow internal mutation, like `putCabinet`/`putSheet`;
    /// the public manifest remains read-only outside this module. The caller
    /// has already saved and verified the native identity under its mutation
    /// lease, so no revision may advance here.
    func putBuilding(_ binding: FloeBuildingCADBuildingBinding?) {
        manifest.building = binding
    }

    // MARK: - Exact mutation rollback via the public edit checkpoint

    /// State used to prove a failed bridge batch was fully reverted. The
    /// checkpoint restores the document AND its undo/redo histories; these
    /// values are independently re-read afterwards, and an ownership lease
    /// refuses the restore if another CAD writer advanced the live generation.
    struct MutationState {
        var summary: CADDocumentSummary
        var bodyIDs: Set<UUID>
        var sketchIDs: Set<UUID>
        var featureIDs: Set<UUID>
        var instanceIDs: Set<UUID>
        var pageIDs: Set<UUID>
        var building: CADBuildingDocument?
    }

    @MainActor
    final class MutationLease {
        let checkpoint: CADEditCheckpoint
        let state: MutationState
        let session: FloeBuildingCADSession
        private(set) var ownedChangeCount: Int
        var interleaved = false

        init(session: FloeBuildingCADSession, checkpoint: CADEditCheckpoint,
             state: MutationState) {
            self.session = session
            self.checkpoint = checkpoint
            self.state = state
            self.ownedChangeCount = session.document.buildingChangeCount
        }

        /// Call immediately after one synchronous mutation made by this
        /// bridge. The monotonic changeCount is used only as an ownership
        /// fence, never as an undo-stack position.
        func noteOwnedWrite() {
            ownedChangeCount = session.document.buildingChangeCount
        }

        func verifyOwnership() throws {
            let live = session.document.buildingChangeCount
            guard live == ownedChangeCount else {
                interleaved = true
                throw FloeBuildingCADError.rollbackFailed(
                    "Another CAD writer advanced the document during the bridge batch "
                    + "(live \(live), bridge-owned \(ownedChangeCount)); the live state was preserved.")
            }
        }
    }

    func captureMutationState() throws -> MutationState {
        guard !document.isClosed else { throw FloeBuildingCADError.documentClosed }
        let native = try nativeState()
        return MutationState(summary: document.summary(),
                             bodyIDs: try drawingBodyIDs(),
                             sketchIDs: Set(native.sketches.keys),
                             featureIDs: Set(native.features.keys),
                             instanceIDs: Set(native.instances.keys),
                             pageIDs: try drawingPageIDs(),
                             building: try document.building())
    }

    func drawingBodyIDs() throws -> Set<UUID> {
        let reply = document.nativeQueryJSON(["scope": "bodies", "limit": 500])
        guard reply.isOK,
              let payload = FloeBuildingCADGeometry.object(reply),
              let rows = payload["rows"] as? [[String: Any]] else {
            throw FloeBuildingCADError.invalidNativeState(
                reply.message ?? "The native body list could not be read.")
        }
        return Set(rows.compactMap { FloeBuildingCADGeometry.uuid($0["id"]) })
    }

    func drawingPageIDs() throws -> Set<UUID> {
        let reply = CADDrawingService(document: document).handle(action: "pages", args: [:])
        guard reply["ok"] as? Bool == true else {
            throw FloeBuildingCADError.invalidNativeState(
                reply["message"] as? String ?? "The drawing page list could not be read.")
        }
        let rows = reply["pages"] as? [[String: Any]] ?? []
        return Set(rows.compactMap { FloeBuildingCADGeometry.uuid($0["id"]) })
    }

    /// Run one bridge-owned mutation batch. Same-session bridge mutations are
    /// rejected while another batch is active. The ownership lease records the
    /// generation after each of OUR synchronous writes; before/after every
    /// await the caller must verify it. A failed batch restores the exact
    /// checkpoint only when no other writer advanced the live generation, then
    /// re-reads counts, instances, building and pages. On interleaving the
    /// live document is preserved and `rollbackFailed` reports the conflict.
    func withMutationRollback<T>(_ body: (MutationLease) async throws -> T) async throws -> T {
        guard !document.isClosed else { throw FloeBuildingCADError.documentClosed }
        guard !document.isReadOnly else { throw FloeBuildingCADError.readOnly }
        guard !mutationInProgress else { throw FloeBuildingCADError.busy }
        mutationInProgress = true
        defer { mutationInProgress = false }
        let checkpoint = document.captureEditCheckpoint()
        let state = try captureMutationState()
        let lease = MutationLease(session: self, checkpoint: checkpoint, state: state)
        let manifestBefore = manifest
        do {
            return try await body(lease)
        } catch {
            manifest = manifestBefore
            if lease.interleaved || document.buildingChangeCount != lease.ownedChangeCount {
                lease.interleaved = true
                throw FloeBuildingCADError.rollbackFailed(
                    "The operation failed and another CAD write interleaved; live state was preserved. "
                    + "Original failure: \(error.localizedDescription)")
            }
            do {
                try restoreMutation(checkpoint, to: state)
            } catch let rollback as FloeBuildingCADError {
                throw FloeBuildingCADError.rollbackFailed(
                    "\(rollback.localizedDescription) Original failure: \(error.localizedDescription)")
            } catch {
                throw FloeBuildingCADError.rollbackFailed(
                    "The exact checkpoint restore failed: \(error.localizedDescription). "
                    + "Original failure: \(error.localizedDescription)")
            }
            throw error
        }
    }

    /// Serialize operations that read/copy the document but do not use the
    /// mutation checkpoint (verified snapshots and exports).
    func beginExclusiveOperation() throws {
        guard !document.isClosed else { throw FloeBuildingCADError.documentClosed }
        guard !mutationInProgress else { throw FloeBuildingCADError.busy }
        mutationInProgress = true
    }

    func endExclusiveOperation() {
        mutationInProgress = false
    }

    /// Wrap one synchronous mutation (or one synchronous helper that may
    /// perform several commands). If it throws after a partial write, the
    /// lease still claims the writes as bridge-owned so the checkpoint restore
    /// is allowed; the live generation is never used as an undo position.
    func withOwnedWrite<T>(_ lease: MutationLease,
                           _ body: () throws -> T) rethrows -> T {
        do {
            let value = try body()
            lease.noteOwnedWrite()
            return value
        } catch {
            lease.noteOwnedWrite()
            throw error
        }
    }

    func restoreMutation(_ checkpoint: CADEditCheckpoint,
                         to state: MutationState) throws {
        guard !document.isClosed else {
            throw FloeBuildingCADError.rollbackFailed("The document closed before rollback.")
        }
        guard !document.isReadOnly else {
            throw FloeBuildingCADError.rollbackFailed("The document became read-only before rollback.")
        }
        document.restoreEditCheckpoint(checkpoint)
        let after = document.summary()
        guard after.bodyCount == state.summary.bodyCount,
              after.sketchCount == state.summary.sketchCount,
              after.featureCount == state.summary.featureCount,
              after.variableCount == state.summary.variableCount,
              after.hasAssembly == state.summary.hasAssembly,
              after.drawingPageCount == state.summary.drawingPageCount else {
            throw FloeBuildingCADError.rollbackFailed(
                "The restored counts do not match the pre-mutation state "
                + "(bodies \(after.bodyCount)/\(state.summary.bodyCount), "
                + "sketches \(after.sketchCount)/\(state.summary.sketchCount), "
                + "features \(after.featureCount)/\(state.summary.featureCount), "
                + "pages \(after.drawingPageCount)/\(state.summary.drawingPageCount)).")
        }
        guard try drawingBodyIDs() == state.bodyIDs else {
            throw FloeBuildingCADError.rollbackFailed(
                "The restored body ids do not match the pre-mutation set.")
        }
        let afterNative = try nativeState()
        guard Set(afterNative.sketches.keys) == state.sketchIDs,
              Set(afterNative.features.keys) == state.featureIDs,
              Set(afterNative.instances.keys) == state.instanceIDs else {
            throw FloeBuildingCADError.rollbackFailed(
                "The restored sketch/feature/instance identities do not match the pre-mutation set.")
        }
        let afterBuilding = try document.building()
        guard afterBuilding == state.building else {
            throw FloeBuildingCADError.rollbackFailed(
                "The restored building model does not match the pre-mutation model.")
        }
        let afterPages = try drawingPageIDs()
        guard afterPages == state.pageIDs else {
            throw FloeBuildingCADError.rollbackFailed(
                "The restored drawing page ids do not match the pre-mutation set.")
        }
    }

    #if DEBUG
    /// Test-only deterministic failure injection at named checkpoints. It is
    /// compiled out of release and never changes production behaviour.
    nonisolated(unsafe) static var testMutationFailure: (@Sendable (String) throws -> Void)?

    func testMutationCheckpoint(_ name: String) throws {
        if let failure = Self.testMutationFailure { try failure(name) }
    }
    #else
    func testMutationCheckpoint(_ name: String) {}
    #endif

    // MARK: - Capability limitations

    /// Honest limits of this closure. They are also written to the handoff;
    /// no limitation is silently converted into a complete-looking result.
    public static let limitations: [FloeBuildingCADLimitation] = [
        FloeBuildingCADLimitation(
            id: "in-project-cabinet-instance-filter",
            summary: "The five-view combination page lives directly in the project only when the assembly contains exactly this cabinet's panel instances. With other assembly instances the bridge publishes a verified instance-scoped snapshot. The internal/assembly/exploded detail pages always use verified cabinet-scoped snapshots so unrelated project instances cannot leak into them.",
            requiredHook: "Optional additive CADDrawingPage/CADDrawingSheetView sourceInstanceIDs (<=64), applied in projectionSources before the body filter, would allow live in-project detail pages. See REQUIRED_CORE_HOOKS.patch."),
        FloeBuildingCADLimitation(
            id: "internal-elevation-door-exclusion",
            summary: "The internal elevation deliberately excludes every panel whose role is front (door). The exact excluded panel and instance IDs are stored in the detail binding and receipt; this is an intentional scope, never a missing-panel projection. A cabinet without fronts simply has no exclusions.",
            requiredHook: "None; the scope is explicit. A future in-project instance-role filter could produce the same page without a snapshot."),
        FloeBuildingCADLimitation(
            id: "detail-pages-verified-snapshots",
            summary: "The assembly and exploded pages live in a verified cabinet-scoped native snapshot and the internal elevation in a second snapshot with the door instances removed. A refresh rebuilds new verified snapshot files (the previous files are retained), remaps ordinary annotations by view role and preserves dimension text positions/overrides; native annotation UUIDs are reminted rather than silently reused.",
            requiredHook: "A page clone/import action that can assign an existing CADDrawingTextAnnotation id, or the in-project instance filter above, would allow in-place detail-page refresh."),
        FloeBuildingCADLimitation(
            id: "whole-project-native2d-page",
            summary: "A whole-project native 3D copy always consumes the saved project document. Whole-project PDF/SVG/DXF or native 2D is produced only for an explicitly selected project drawing page; without one the export returns a typed unsupported operation and never falls back to a cabinet page, an empty sketch or a bounding box.",
            requiredHook: "None; this is an explicit scope rule."),
        FloeBuildingCADLimitation(
            id: "native2d-representation-loss",
            summary: "The independent native 2D document stores real editable sketch entities. Sheet frame/title block, drawing layers as a table, associative dimensions, and editable text objects are not native sketch concepts; layers become sketch names, dimensions become linework plus optional outline text, and every loss is written to the native 2D receipt.",
            requiredHook: "A native layer/annotation-text object model would remove the flattening loss."),
        FloeBuildingCADLimitation(
            id: "non-uniform-furniture-fit",
            summary: "Native assembly placement accepts one uniform scale. Catalog fits whose per-axis factors differ materially are refused; near-uniform real catalog fits are accepted only within an explicit maximumSizingErrorMM and are reported as a uniform approximation.",
            requiredHook: "If strict three-axis fits become required, an affine mesh/body placement hook is needed; the Core FurniturePlacementPlan math is not weakened."),
        FloeBuildingCADLimitation(
            id: "multiple-cabinet-instances",
            summary: "A second live cabinet using the SAME recipe id is refused; multiple placements sharing one recipe and per-instance overrides are not yet supported. Distinct recipes can keep independent bindings, but mixed-project sheet scoping still uses the snapshot/hook route.",
            requiredHook: "A cabinet placement/instance identity model plus per-instance panel binding ownership; no CAD core change is needed for the value record."),
        FloeBuildingCADLimitation(
            id: "project-to-snapshot-orphan-page",
            summary: "If a project-scoped cabinet page already exists and non-cabinet assembly instances are added later, the binding switches to a verified instance-scoped snapshot. The old project page remains unreferenced until a page-deletion/cleanup hook is available.",
            requiredHook: "Use the in-project sourceInstanceIDs filter above, or add an explicit page-delete/refresh action that can atomically retire the stale project page."),
        FloeBuildingCADLimitation(
            id: "snapshot-annotation-native-id",
            summary: "A normal snapshot refresh updates the SAME snapshot page in place, so native annotation/view ids and text positions stay stable. Only when that in-place route is impossible does the bridge rebuild a new snapshot: unbound ordinary annotations are remapped by view role and keep their logical stable ID, text and local position in the binding, but the native annotation UUID is reminted; bound annotations are marked orphaned and the old snapshot file is retained.",
            requiredHook: "A page clone/import action that can assign an existing CADDrawingTextAnnotation id (or the in-project sourceInstanceIDs filter above) would eliminate the remint fallback."),
    ]
}
#endif
