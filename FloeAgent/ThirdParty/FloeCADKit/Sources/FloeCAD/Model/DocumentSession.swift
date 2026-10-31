//
//  DocumentSession.swift
//  openshape3d
//
//  Owns the in-memory DesignDocument for one open project, routes commands
//  through the undo stack, and mirrors changes back to SwiftData with a
//  debounced autosave.
//

import Foundation
import Observation

@MainActor
@Observable
final class DocumentSession {
    let project: Project
    private let modelContext: CADModelContext

    private(set) var document = DesignDocument()
    let undoStack = UndoStack()

    /// Topological-naming strategy used when replaying the feature graph
    /// (labels faces, propagates labels through booleans/push-pull, re-resolves
    /// persisted `FaceRef`s against rebuilt geometry). Phase D, Task C1.
    let naming: TopoNaming = SignatureNaming()

    /// Per-node errors from the most recent `rebuildFrom` evaluation, surfaced
    /// to the editor/history panel (broken-ref / empty-geometry / kernel-failure
    /// badges). Empty when the last rebuild was clean.
    /// The replay memo (docs/INCREMENTAL_EVAL_DESIGN.md): per feature node, the
    /// fingerprint of its inputs and the delta it produced last time, so a
    /// rebuild re-runs only what changed. Threaded through `performRebuild`
    /// and adopted to the document's bodies after each apply; the read-only
    /// replays (`refreshEvalErrors`, `inputBody`) use a discarded copy.
    private var evalCache = EvalCache()
    private(set) var lastEvalErrors: [FeatureID: FeatureError] = [:]
    private(set) var lastReferenceErrors: [AssociativeReferenceKey: AssociativeReferenceError] = [:]
    private(set) var lastBodyWriters: [BodyID: FeatureID] = [:]
    /// Diagnostics from a refused speculative rebuild; live diagnostics still
    /// describe the unchanged document. Services must not report that as success.
    private(set) var lastRebuildRejection: [AssociativeReferenceKey: AssociativeReferenceError] = [:]
    private(set) var lastRejectedFeatureErrors: [FeatureID: FeatureError] = [:]

    /// The face tables of the most recent APPLIED rebuild — the tables whose
    /// triangle indices are valid against the documents' CURRENT renders,
    /// which is what lets a live pick read a face's `elementName` at mint
    /// time (TOPO_NAMING_HISTORY_DESIGN step 4). Deliberately NOT populated
    /// by `refreshEvalErrors()`: that replay discards its bodies, so its
    /// tables describe scratch renders, and a name minted off a misaligned
    /// table would be a WRONG name — worse than the nil a fresh load mints.
    private(set) var lastFaceTables: [BodyID: FaceTable] = [:]

    /// Per-body kernel-face name maps from the same rebuild — what edge
    /// picks mint `EdgeName`s from (step 4b).
    private(set) var lastKernelNames: [BodyID: [Int: ElementName]] = [:]

    /// The `meshRevision` each retained table/name map describes. Live tools
    /// replace bodies WITHOUT re-evaluating (ReplaceBodyCommand), so the
    /// retained maps go stale the moment one runs — and a stale map could
    /// mint a WRONG name. Mint sites must check the body's current revision
    /// against this before trusting either map.
    private(set) var lastNamingRevisions: [BodyID: UInt64] = [:]

    /// Bumped on every document mutation; the editor observes this to rebuild
    /// the viewport scene.
    private(set) var changeCount = 0
    /// Dirty/save identity only. Preview epochs still advance changeCount for
    /// runtime/query fencing without making an unchanged baseline need a save.
    private(set) var persistenceChangeCount = 0
    private var lastSavedPersistenceChangeCount = 0
    /// Successful durable identity only. Computed facade readers participate
    /// in this existing Session's Observation tracking, including save-only
    /// changes that do not advance a geometry/query generation.
    private(set) var savedIdentity: CADSaveOutcome

    @discardableResult
    func adoptCommittedIdentity(_ receipt: CADSaveOutcome, persistenceCount: Int) -> Bool {
        guard receipt.succeeded, receipt.revision > savedIdentity.revision else { return false }
        lastSavedPersistenceChangeCount = persistenceCount
        savedIdentity = receipt
        recordSaveResult(nil)
        // The command (and anything after it) is now durable. Drop the large
        // pre-command checkpoint but keep a token-only marker so a late host
        // callback still gets the honest `.alreadyCommitted` answer without
        // retaining an old document snapshot for the session lifetime.
        if let owned = lastOwnedCommandReceipt {
            lastCommittedOwnedToken = owned.token
            lastOwnedCommandReceipt = nil
        }
        return true
    }

    /// One host-owned command that may need an exact rollback after an
    /// asynchronous commit attempt. The checkpoint captures the document plus
    /// both undo/redo histories and derived caches BEFORE the command; the
    /// counters bind the receipt to that one still-uncommitted generation.
    /// Only `performOwned` mints these, and only `rollbackOwnedCommand` can
    /// consume one. This is NOT a second transaction system: it is the
    /// existing checkpoint/undo/storage-marking machinery applied to a
    /// command whose commit happens after a suspension point.
    nonisolated struct OwnedCommandReceipt {
        let token: UUID
        let tag: String
        let commandTitle: String
        let checkpoint: CADEditCheckpoint
        let changeCount: Int
        let persistenceChangeCount: Int
        let savedRevision: Int
        let undoDepth: Int

        var reference: CADOwnedCommandRef {
            CADOwnedCommandRef(token: token, tag: tag)
        }
    }

    nonisolated enum OwnedCommandRollback: Sendable, Equatable {
        case reverted
        case superseded
        case alreadyCommitted
        case unavailable
    }

    /// The most recent owned command that has not been rolled back or
    /// superseded. One host operation per document is expected; a newer owned
    /// command replaces the previous receipt, so an older callback can never
    /// undo the newer one.
    private(set) var lastOwnedCommandReceipt: OwnedCommandReceipt?
    /// Token of the most recent owned command already made durable by a save.
    /// No document snapshot is retained for it.
    private var lastCommittedOwnedToken: UUID?

    /// Release any owned-command checkpoint when the document closes. A late
    /// callback after release is `unavailable`, never a rollback.
    func discardOwnedCommandReceipts() {
        lastOwnedCommandReceipt = nil
        lastCommittedOwnedToken = nil
    }

    /// Perform one host-owned command and mint its rollback receipt. Returns
    /// nil when the session refuses the write; the command is then not applied.
    @discardableResult
    func performOwned(_ command: DocumentCommand, tag: String) -> OwnedCommandReceipt? {
        guard requireWritable() else { return nil }
        let checkpoint = captureEditCheckpoint()
        undoStack.perform(command, on: &document)
        didChange()
        lastCommittedOwnedToken = nil
        let receipt = OwnedCommandReceipt(
            token: UUID(),
            tag: tag,
            commandTitle: command.title,
            checkpoint: checkpoint,
            changeCount: changeCount,
            persistenceChangeCount: persistenceChangeCount,
            savedRevision: savedIdentity.revision,
            undoDepth: undoStack.undoCommands.count)
        lastOwnedCommandReceipt = receipt
        return receipt
    }

    /// Roll back the EXACT owned command only when it is still the newest
    /// uncommitted change. Any later edit, undo/redo, checkpoint restore or
    /// successful save invalidates the receipt and is preserved untouched.
    /// A refused rollback never guesses or restores an older document over
    /// newer work.
    @discardableResult
    func rollbackOwnedCommand(token: UUID) -> OwnedCommandRollback {
        guard let receipt = lastOwnedCommandReceipt, receipt.token == token else {
            guard lastCommittedOwnedToken == token else { return .unavailable }
            if lastSavedPersistenceChangeCount == persistenceChangeCount {
                recordSaveResult(nil)
            }
            return .alreadyCommitted
        }
        lastOwnedCommandReceipt = nil
        if savedIdentity.revision != receipt.savedRevision {
            // Another save committed this command (and possibly later edits).
            // When the committed persistence marker also covers the current
            // state, a stale failed-save error must not keep the document
            // falsely "dirty"; if later edits are pending, keep the error.
            if lastSavedPersistenceChangeCount == persistenceChangeCount {
                recordSaveResult(nil)
            }
            return .alreadyCommitted
        }
        guard !isReadOnly,
              changeCount == receipt.changeCount,
              persistenceChangeCount == receipt.persistenceChangeCount,
              undoStack.undoCommands.count == receipt.undoDepth,
              undoStack.undoCommands.last?.title == receipt.commandTitle else {
            return .superseded
        }
        // The checkpoint is the document + undo/redo + cache state from just
        // before this command. No later change exists (the counters matched),
        // so restoring it removes only this command and keeps a pre-existing
        // redo history; the command itself never becomes redoable.
        restoreCheckpointState(receipt.checkpoint, autosave: false)
        if lastSavedPersistenceChangeCount == persistenceChangeCount {
            recordSaveResult(nil)
        } else {
            // The pre-command document already had unsaved edits; keep them
            // pending instead of silently dropping their persistence need.
            scheduleAutosave()
        }
        return .reverted
    }

    /// IDs of persisted rows this build could not decode at `load()` — an
    /// unknown feature kind written by a newer build, a newer `MeshBlob`
    /// version, or a corrupt blob. They are absent from `document`, but
    /// `save()` MUST treat them as live: skipping a row is recoverable, while
    /// letting the save diff delete it is permanent data loss (2026-08-25
    /// review, finding C1). A preserved feature row's `orderIndex` can drift
    /// relative to renumbered live rows; a fuzzy position on later recovery
    /// beats deletion.
    private var unreadableRows = UnreadableRows()

    private struct UnreadableRows {
        var bodies: Set<UUID> = []
        var sketches: Set<UUID> = []
        var planes: Set<UUID> = []
        var axes: Set<UUID> = []
        var images: Set<UUID> = []
        var symbols: Set<UUID> = []
        var features: Set<UUID> = []
        /// Bodies whose row decoded but one COLUMN did not — the column's
        /// blob must not be overwritten by the nil we decoded to.
        var bodyPrimitive: Set<UUID> = []
        var bodyMaterial: Set<UUID> = []
        var bodyFaceMaterials: Set<UUID> = []
        var bodyBrep: Set<UUID> = []
        /// The Items-folder blob failed to decode — leave the column alone.
        var itemFolders = false
        /// Whole rows that could not be decoded (absent from the document).
        var rowCount: Int {
            bodies.count + sketches.count + planes.count + axes.count
                + images.count + symbols.count + features.count
        }
        /// Bodies present in the document but missing some detail.
        var partialBodyCount: Int {
            bodyPrimitive.union(bodyMaterial).union(bodyFaceMaterials).union(bodyBrep).count
        }
        var count: Int { rowCount + partialBodyCount }
    }

    /// Legacy property name: true for a newer format OR opaque association
    /// semantics. The original store bytes remain available for viewing.
    /// The document still opens for viewing, but `save()` refuses to run —
    /// an older app must never rewrite a newer store.
    private(set) var storeIsNewerThanApp = false

    var isReadOnly: Bool {
        storeIsNewerThanApp || project.formatVersion > Project.currentFormatVersion || project.hasOpaqueAssociations
    }
    var readOnlyMessage: String {
        project.hasOpaqueAssociations ? CADDocumentFormat.opaqueReadOnlyMessage
            : "This CAD document uses a newer format and is read-only."
    }
    @discardableResult
    private func requireWritable() -> Bool {
        if let block = writeBlock { recordWriteBlock(block.message); return false }
        return true
    }

    /// One-shot user-facing warning from `load()` (newer-format store, or
    /// "N items couldn't be read"); the editor surfaces it once on open.
    private(set) var loadWarning: String?

    /// Most recent `modelContext.save()` failure, nil after a clean save.
    /// Swallowing these silently was part of review finding C1.
    private(set) var lastSaveError: String?

    private var saveTask: Task<Void, Never>?
    private var inFlightSaveCount = 0
    private var lastSaveErrorIsWriteBlock = false
    var saveFailureRequiresRetry: Bool { lastSaveError != nil && !lastSaveErrorIsWriteBlock }
    var hasUncommittedPersistenceChanges: Bool {
        persistenceChangeCount != lastSavedPersistenceChangeCount || saveFailureRequiresRetry
    }
    private func recordWriteBlock(_ message: String) {
        // An editing refusal must not hide a real failed commit/CAS error.
        if lastSaveError == nil || lastSaveErrorIsWriteBlock {
            lastSaveError = message
            lastSaveErrorIsWriteBlock = true
        }
    }
    private func recordSaveResult(_ error: String?) {
        lastSaveError = error
        lastSaveErrorIsWriteBlock = false
    }
    #if DEBUG
    /// Deterministic, session-local suspension inside prewarm for race tests.
    /// Absent in release; no store/network/global synchronization is replaced.
    var savePrewarmSuspensionForTesting: (@MainActor () async -> Void)?
    /// Deterministic suspension ON the detached snapshot serializer: fires
    /// after the independently-owned snapshots are taken, before any bytes
    /// are produced, so a test can mutate/replace/close the live document
    /// through the REAL kernel while the background serialization is in
    /// flight. Absent in release; it never replaces the real serializer, the
    /// store, the CAS fence or the generation guard.
    var brepSerializationSuspensionForTesting: (@Sendable () async -> Void)?
    /// One-shot failure injected AFTER prewarm (where real IO/CAS failures
    /// surface) for the exact async host commit path. Absent in release; it
    /// never replaces the store, CAS fence or lock.
    var saveFailureForTesting: String?
    var committedIdentityDeliveryForTesting: (@MainActor (CADSaveOutcome) async -> Void)?
    var hasPendingAutosaveForTesting: Bool { saveTask != nil }
    #endif

    /// One native sketch gesture may preview only its source sketch. The
    /// existing checkpoint remains the sole baseline and history authority.
    nonisolated struct SketchPreviewToken: Hashable, Sendable {
        fileprivate let id: UUID
        fileprivate init() { id = UUID() }
    }
    private struct SketchPreview {
        var token: SketchPreviewToken
        var sketchID: SketchID
        var title: String
        var baseline: CADEditCheckpoint
        var ownedChangeCount: Int
        var baselineSaveWasPending: Bool
    }
    private var sketchPreview: SketchPreview?
    var isSketchPreviewActive: Bool { sketchPreview != nil }
    var previewSketchID: SketchID? { sketchPreview?.sketchID }
    var writeBlock: (code: String, message: String)? {
        if isReadOnly { return ("read_only", readOnlyMessage) }
        if isSketchPreviewActive {
            return ("edit_in_progress", FloeCADStrings.text("cad.sketch.finishCurrentEdit", "Finish or cancel the sketch edit first."))
        }
        return nil
    }
    private nonisolated enum SketchPreviewWriteError: LocalizedError {
        case editing
        var errorDescription: String? { FloeCADStrings.text("cad.sketch.finishCurrentEdit", "Finish or cancel the sketch edit first.") }
    }

    /// Begin before Copy/decomposition or the first changed solver frame.
    /// A second owner cannot replace a token or its baseline.
    func beginSketchPreview(sketchID: SketchID, title: String = "Edit Sketch") -> SketchPreviewToken? {
        guard requireWritable(), Self.hasAssociations(document),
              document.sketches.contains(where: { $0.id == sketchID }) else { return nil }
        let pending = saveTask != nil || inFlightSaveCount > 0
        saveTask?.cancel()
        saveTask = nil
        let baseline = captureEditCheckpoint()
        // Begin alone fences old save/NativeEditCommit continuations before
        // the first accepted gesture frame arrives.
        didChange(autosave: false, persistedChange: false)
        let token = SketchPreviewToken()
        sketchPreview = SketchPreview(token: token, sketchID: sketchID, title: title,
                                      baseline: baseline, ownedChangeCount: changeCount,
                                      baselineSaveWasPending: pending)
        return token
    }

    /// Update only the owned sketch; unrelated command, body, graph or metadata
    /// writes have no owner bypass. Geometry stays a transient source preview.
    @discardableResult
    func updateSketchPreview(_ sketch: Sketch, token: SketchPreviewToken) -> Bool {
        guard var owner = sketchPreview, owner.token == token,
              owner.ownedChangeCount == changeCount, !isReadOnly,
              sketch.id == owner.sketchID,
              let index = document.sketches.firstIndex(where: { $0.id == sketch.id }) else { return false }
        document.sketches[index] = sketch
        didChange(autosave: false, persistedChange: false)
        owner.ownedChangeCount = changeCount
        sketchPreview = owner
        return true
    }

    /// Restore the ORIGINAL source and exact redo/cache before validation, then
    /// make the complete source/solver/constraint edit and derived rebuild one
    /// ordinary transaction. A rejected rebuild leaves the original baseline.
    @discardableResult
    func commitSketchPreview(_ token: SketchPreviewToken) -> Bool {
        guard let owner = sketchPreview, owner.token == token,
              owner.ownedChangeCount == changeCount,
              let before = owner.baseline.document.sketches.first(where: { $0.id == owner.sketchID }),
              let after = document.sketches.first(where: { $0.id == owner.sketchID }) else { return false }
        sketchPreview = nil
        restoreCheckpointState(owner.baseline, autosave: false)
        guard before != after else { resumeBaselineSaveIfNeeded(owner); return true }
        let accepted = performWithSketchRebuild(
            ReplaceSketchGeometryCommand(title: owner.title, before: before, after: after),
            sketchID: owner.sketchID)
        if !accepted { resumeBaselineSaveIfNeeded(owner) }
        return accepted
    }

    /// Late/stale callbacks cannot restore a newer owner's baseline. A
    /// generation mismatch is never repaired by overwriting an outside edit.
    @discardableResult
    func cancelSketchPreview(_ token: SketchPreviewToken) -> Bool {
        guard let owner = sketchPreview, owner.token == token,
              owner.ownedChangeCount == changeCount else { return false }
        sketchPreview = nil
        restoreCheckpointState(owner.baseline, autosave: false)
        resumeBaselineSaveIfNeeded(owner)
        return true
    }

    private func resumeBaselineSaveIfNeeded(_ owner: SketchPreview) {
        guard owner.baselineSaveWasPending, !isReadOnly,
              lastSavedPersistenceChangeCount != owner.baseline.persistenceChangeCount else { return }
        scheduleAutosave()
    }

    /// Trusted document lifecycle boundary, before its final baseline flush
    /// and store revoke. No editor callback can retain a usable owner token.
    func cancelSketchPreviewForClose() {
        if let token = sketchPreview?.token { cancelSketchPreview(token) }
    }

    init(project: Project, modelContext: CADModelContext) {
        self.project = project
        self.modelContext = modelContext
        self.savedIdentity = modelContext.store?.committedIdentity
            ?? CADSaveOutcome(revision: 0, contentSHA256: "", error: nil)
        load()
    }

    // MARK: - Mutations

    func perform(_ command: DocumentCommand) {
        guard requireWritable() else { return }
        undoStack.perform(command, on: &document)
        didChange()
    }

    /// Coalesce with the previous command (live drags, slider edits).
    func amend(_ command: DocumentCommand) {
        guard requireWritable() else { return }
        undoStack.amendLast(command, on: &document)
        didChange()
    }

    /// Transient (non-undoable) document update, e.g. live transform during a
    /// drag before the final command is pushed on gesture end.
    func preview(_ mutate: (inout DesignDocument) -> Void) {
        guard requireWritable() else { return }
        mutate(&document)
        didChange(autosave: false)
    }

    func undo() {
        guard requireWritable() else { return }
        undoStack.undo(on: &document)
        // A rebuild's errors were computed for the state being undone;
        // recompute for the restored state so badges track the document
        // rather than the last live edit (review S6 residual).
        refreshEvalErrors()
        didChange()
    }

    func redo() {
        guard requireWritable() else { return }
        undoStack.redo(on: &document)
        refreshEvalErrors()
        didChange()
    }

    private func didChange(autosave: Bool = true, persistedChange: Bool = true) {
        changeCount += 1
        if persistedChange { persistenceChangeCount = changeCount }
        if autosave {
            scheduleAutosave()
        }
    }

    /// A refreshed projection changes only derived source fingerprints. It
    /// must be saved, but cannot consume the user's next undo or erase redo.
    /// Semantic drawing edits still use SetDrawingsDataCommand.
    func refreshDrawingProjectionData(_ data: Data) {
        guard requireWritable(), document.drawingsData != data else { return }
        document.drawingsData = data
        didChange()
    }

    // MARK: - Feature graph (Phase D, Task C1)

    /// Record a new feature node in the history as its own undoable step.
    ///
    /// Recording/undo approach: the undoable primitive is `AppendFeatureCommand`.
    /// When a feature is born alongside geometry (a primitive box, a new-body
    /// extrude), the editor bundles `AppendFeatureCommand` into the SAME
    /// `CompositeCommand` as the geometry command (`AddBodyCommand`,
    /// `BooleanCommand`, …) and performs that — so one undo drops both the mesh
    /// and the node. `record(_:)` is the standalone convenience for a node that
    /// has no paired geometry command; routing it through `perform` keeps it
    /// undoable and never leaves an orphan node behind on undo.
    func record(_ node: FeatureNode) {
        perform(AppendFeatureCommand(node: node))
    }

    /// Re-evaluate the feature graph and commit the resulting mesh changes as a
    /// single undo step, optionally applying a pending parameter edit first.
    ///
    /// Flow: apply `edit` to a graph copy so `evaluate` sees the new parameters →
    /// replay → diff the produced bodies against the current feature-owned bodies
    /// → build `ReplaceBody` (changed) / `AddBody` (new) / `DeleteBodies`
    /// (consumed) commands → bundle them with `edit` into one
    /// `CompositeCommand(title)` (default "Edit Feature") and `perform` it, so
    /// a single undo reverts BOTH the parameter change and every downstream
    /// mesh under the operation's own title.
    ///
    /// Non-feature bodies (imported meshes, copies) are untouched — only IDs a
    /// node minted (`FeatureNode.outputBodyIDs`, reused across rebuilds) are
    /// diffed. User-owned metadata evaluate doesn't model (name, transform,
    /// visibility, material) is carried forward onto rebuilt bodies so a param
    /// edit doesn't clobber a rename / gizmo move / hide / material.
    ///
    /// The `id` names the edited node for callers/telemetry; the replay itself is
    /// whole-graph (tranche 1 has no partial/rollback replay). Any evaluation
    /// errors are stored in `lastEvalErrors`; the good bodies are still applied.
    /// The body a feature CONSUMES, as it was before that feature ran.
    ///
    /// Read-only: replays a copy of the graph truncated just before `featureID`
    /// and hands back the requested body from that state. Nothing is committed
    /// and the document's revision counter is untouched — a local counter feeds
    /// the replay, because the result is a transient source for a preview and
    /// must not consume revisions the real document will hand out later.
    ///
    /// Needed because a blend REPLACES its body in place: by the time the user
    /// asks to edit the feature, the body under that `BodyID` already has the
    /// blend on it, and re-picking edges against it would pick the edges of the
    /// result rather than of the input.
    func inputBody(for featureID: FeatureID, bodyID: BodyID) -> Body? {
        guard !isReadOnly else { return nil }
        var graph = document.features
        guard let index = graph.index(of: featureID) else { return nil }
        graph.rollbackIndex = index
        var counter: UInt64 = 1
        var scratch = evalCache   // read-only use of the memo; discarded
        let result = graph.evaluate(
            sketches: document.sketches,
            planes: document.planes,
            naming: naming,
            nextRevision: { counter &+= 1; return counter },
            cache: &scratch,
            variables: variableValues()
        )
        return result.bodies.first { $0.id == bodyID }
    }

    func rebuildFrom(_ id: FeatureID, edit: EditFeatureCommand? = nil,
                     title: String = "Edit Feature") {
        // Graph with the pending parameter edit applied, so replay sees the new
        // parameters without mutating the live document yet.
        var editedGraph = document.features
        if let edit, let index = editedGraph.index(of: edit.featureID) {
            editedGraph.nodes[index].kind = edit.after
        }
        let leading: [DocumentCommand] = edit.map { [$0] } ?? []
        performRebuild(editedGraph, leadingCommands: leading, title: title)
    }

    /// Append feature nodes and rebuild in ONE undo step (the appends ride as
    /// the composite's leading commands, so a single undo removes the nodes
    /// and reverts every body they moved or made). The interactive transform
    /// tools commit through here: a gizmo move becomes a `.transform` node,
    /// and from then on the graph owns the placement — `RebuildPlanner`
    /// deliberately resets document-level transforms on every replay.
    ///
    /// `extra` rides in the same composite after the appends — the sketch
    /// auto-hides a committing create tool owes (spec §11), so one undo
    /// also brings the sketch back.
    func recordAndRebuild(_ nodes: [FeatureNode], extra: [DocumentCommand] = [], title: String) {
        guard !nodes.isEmpty else { return }
        var editedGraph = document.features
        editedGraph.nodes.append(contentsOf: nodes)
        let appends: [DocumentCommand] = nodes.map { AppendFeatureCommand(node: $0, title: title) }
        performRebuild(editedGraph, leadingCommands: appends + extra, title: title)
    }

    /// Suppress / un-suppress a node and rebuild everything downstream in one
    /// undo step (History panel eye toggle). No-op if the flag is unchanged.
    func setSuppressed(_ id: FeatureID, _ value: Bool) {
        guard let node = document.features.node(id), node.suppressed != value else { return }
        var edited = document.features
        if let index = edited.index(of: id) { edited.nodes[index].suppressed = value }
        let cmd = SetFeatureSuppressedCommand(featureID: id, before: node.suppressed, after: value)
        performRebuild(edited, leadingCommands: [cmd], title: cmd.title)
    }

    /// Move (or clear, `nil`) the feature-graph rollback marker and rebuild
    /// everything downstream in one undo step (History panel roll-back). Nodes
    /// at/after the marker are no longer replayed, so their bodies are removed by
    /// the diff; returning to `nil` (latest) replays and restores them. Mirrors
    /// `setSuppressed`: no-op if the marker is unchanged.
    func setRollback(_ newIndex: Int?) {
        guard document.features.rollbackIndex != newIndex else { return }
        var edited = document.features
        edited.rollbackIndex = newIndex
        let cmd = SetRollbackCommand(before: document.features.rollbackIndex, after: newIndex)
        performRebuild(edited, leadingCommands: [cmd], title: cmd.title)
    }

    /// Delete a node from the history and rebuild everything downstream in one
    /// undo step (History panel delete). The node's exclusively-owned bodies are
    /// removed; bodies still produced by surviving nodes are replaced.
    func deleteFeature(_ id: FeatureID) {
        guard let node = document.features.node(id),
              let index = document.features.index(of: id) else { return }
        let beforeRollback = document.features.rollbackIndex
        var edited = document.features
        edited.nodes.removeAll { $0.id == id }
        // Keep the evaluation graph's marker consistent with what
        // RemoveFeatureCommand.apply will set the live marker to: deleting an
        // ACTIVE node shortens the active prefix. Without this, `evaluate`'s
        // `prefix(rollbackIndex)` would pull a rolled-back node into the active
        // set and spuriously re-add its body while the real marker drops.
        if let cut = beforeRollback, index < cut { edited.rollbackIndex = cut - 1 }
        let cmd = RemoveFeatureCommand(index: index, node: node, beforeRollback: beforeRollback)
        performRebuild(edited, leadingCommands: [cmd], title: cmd.title)
    }

    /// Reorder a node to `newIndex` and rebuild everything downstream in one undo
    /// step (History panel drag-to-reorder). `evaluate` replays nodes in array
    /// order, so moving a node before one it references breaks that reference and
    /// surfaces a `.brokenRef` error on the dependent node (Shapr3D-style — the
    /// reorder is allowed, the error is shown). The rollback marker is a positional
    /// count and is left unchanged. No-op if the position doesn't actually change.
    func moveFeature(_ id: FeatureID, to newIndex: Int) {
        guard let from = document.features.index(of: id) else { return }
        var edited = document.features
        let node = edited.nodes.remove(at: from)
        let clamped = min(max(newIndex, 0), edited.nodes.count)
        guard clamped != from else { return }
        edited.nodes.insert(node, at: clamped)
        let cmd = MoveFeatureCommand(featureID: id, from: from, to: clamped)
        performRebuild(edited, leadingCommands: [cmd], title: cmd.title)
    }

    /// Guards `performRebuild` against re-entrancy. `performRebuild` ends by
    /// `perform`ing one internal `CompositeCommand`; that document mutation must
    /// never start a nested replay (e.g. via a sketch-driven rebuild). Set for
    /// the duration of `performRebuild`'s body (see the `defer` there).
    private var isRebuilding = false

    /// Sketch-edit hook: after a sketch-mutating command has already run (so
    /// `document.sketches` holds the NEW geometry), replay the feature graph if —
    /// and only if — some node references `sketchID`. A node's
    /// `referencedSketchIDs` union covers its profile / extra-profile / loft-section
    /// / plane / revolve-axis references, so this fires exactly when the edited
    /// sketch feeds a downstream feature.
    ///
    /// Because `performRebuild` evaluates against the current (already-mutated)
    /// `document.sketches`, the replay picks up the new geometry with NO graph
    /// edit and `leadingCommands` is empty. Skips entirely when nothing depends on
    /// the sketch (no undo noise) and when a rebuild is already in flight.
    ///
    /// This lands as its own undo step for the plain-document legacy drag
    /// fallback and finishSketch's belt-and-suspenders pass. Associated sketch
    /// gestures use scoped preview + full-sketch commit instead. Other direct
    /// edits use `performWithSketchRebuild` for one atomic step.
    func rebuildForSketchChange(_ sketchID: SketchID) {
        guard !isRebuilding else { return }
        guard Self.hasAssociations(document) || document.features.nodes.contains(where: {
            $0.referencedSketchIDs.contains(sketchID)
        }) else { return }
        performRebuild(document.features, leadingCommands: [], title: "Update Sketch")
    }

    /// Perform a sketch-mutating command AND the downstream feature rebuild as
    /// ONE undo step (2026-08-25 review, S6 — as separate steps, one undo
    /// reverted only the rebuild, leaving new sketch geometry with old solids,
    /// permanently desynced once the redo stack cleared). The command becomes
    /// the composite's first entry; evaluation runs against a preview copy
    /// that already has it applied, since the live document is only mutated
    /// when the composite performs. Falls back to a plain `perform` when no
    /// feature references any of the touched sketches.
    ///
    /// The plain-document legacy drag fallback may still amend a source
    /// command before this rebuild. Associated gestures instead own a scoped
    /// preview and submit their final whole Sketch through this guarded path.
    @discardableResult
    func performWithSketchRebuild(_ command: DocumentCommand, sketchIDs: Set<SketchID>) -> Bool {
        guard requireWritable(), !isRebuilding else { return false }
        var preview = document
        command.apply(to: &preview)
        // A support/definition can be invalid even with no solid consuming it.
        // Check the complete prospective records rather than direct consumers
        // alone, including the first support introduced by this command.
        guard Self.hasAssociations(document) || Self.hasAssociations(preview)
                || document.features.nodes.contains(where: {
                    !$0.referencedSketchIDs.isDisjoint(with: sketchIDs)
                }) else {
            perform(command)
            return true
        }
        return performRebuild(preview.features, leadingCommands: [command], title: command.title,
                              sketches: preview.sketches, previewDocument: preview)
    }

    @discardableResult
    func performWithSketchRebuild(_ command: DocumentCommand, sketchID: SketchID) -> Bool {
        performWithSketchRebuild(command, sketchIDs: [sketchID])
    }

    /// Core of every graph-driven rebuild: replay `editedGraph`, diff the
    /// produced bodies against the current feature-owned bodies, and commit the
    /// mesh changes plus `leadingCommands` (the graph mutation itself) as ONE
    /// undoable `CompositeCommand`. Shared by `rebuildFrom`, `setSuppressed`, and
    /// `deleteFeature` so all three stay a single undo step.
    @discardableResult
    private func performRebuild(
        _ editedGraph: FeatureGraph, leadingCommands: [DocumentCommand], title: String,
        sketches: [Sketch]? = nil, previewDocument: DesignDocument? = nil
    ) -> Bool {
        // Re-entrancy guard: this method ends by `perform`ing one internal
        // `CompositeCommand`; if that mutation ever routes back into a rebuild
        // (e.g. a sketch-change hook observing the change), we must NOT start a
        // nested replay. Normal callers — rebuildFrom / setSuppressed /
        // deleteFeature / rebuildForSketchChange — are unaffected: the flag is
        // false on entry, so each performs exactly as before; the guard only
        // short-circuits a RE-ENTRANT (nested) call.
        guard requireWritable(), !isRebuilding else { return false }
        lastRebuildRejection = [:]
        lastRejectedFeatureErrors = [:]
        isRebuilding = true
        defer { isRebuilding = false }

        // Evaluate against complete prospective records, never half-applied
        // definitions/support. Scratch counters/cache are committed only after
        // validation, so a refusal cannot dirty persistence or destroy redo.
        var prospective = previewDocument ?? document
        if previewDocument == nil {
            for command in leadingCommands { command.apply(to: &prospective) }
            if let sketches { prospective.sketches = sketches }
        }
        prospective.features = editedGraph
        let associative = Self.hasAssociations(document) || Self.hasAssociations(prospective)
        var plannedCache = evalCache
        var revisionDocument = document
        let plan = RebuildPlanner.plan(
            editedGraph: editedGraph, previousGraph: document.features,
            document: document, sketches: prospective.sketches, planes: prospective.planes,
            naming: naming, cache: &plannedCache,
            nextRevision: { revisionDocument.nextRevision() },
            leadingCommands: leadingCommands, title: title,
            previewDocument: prospective,
            variables: VariableTable.resolve(prospective.variables).values)
        if associative {
            var baselineCache = evalCache
            var counter: UInt64 = 0
            let baseline = document.features.evaluate(
                sketches: document.sketches, planes: document.planes, naming: naming,
                nextRevision: { counter &+= 1; return counter }, cache: &baselineCache,
                variables: variableValues())
            let captured = AssociativeDependencyGraph(
                graph: document.features, sketches: document.sketches, planes: document.planes,
                featureDependencies: CADParameterService.bodyWriterDependencies(in: document.features.nodes))
            let beforeDependencies = captured.validationErrors(in: document.features)
            var newReferences = plan.referenceErrors.filter { baseline.referenceErrors[$0.key] != $0.value }
            for (key, error) in captured.validationErrors(in: editedGraph)
            where beforeDependencies[key] != error { newReferences[key] = error }
            let newFeatures = plan.errors.filter { key, error in
                baseline.errors[key].map { String(describing: $0) } != String(describing: error)
            }
            if !newReferences.isEmpty || !newFeatures.isEmpty {
                lastRebuildRejection = newReferences
                lastRejectedFeatureErrors = newFeatures
                // Only the generation advances. No autosave is scheduled and
                // no Project/format metadata has been touched.
                didChange(autosave: false, persistedChange: false)
                return false
            }
        }
        document = revisionDocument
        evalCache = plannedCache
        lastEvalErrors = plan.errors
        lastFaceTables = plan.faceTables
        lastKernelNames = plan.kernelNames
        lastReferenceErrors = plan.referenceErrors
        lastBodyWriters = plan.lastBodyWriters

        guard !plan.commands.isEmpty else {
            captureNamingRevisions(for: plan.resultBodyIDs)
            adoptCachedBodies()
            return true
        }
        perform(CompositeCommand(title: title, commands: plan.commands))
        // AFTER the commands: ReplaceBodyCommand.apply re-mints meshRevision,
        // so revisions captured from the replay's bodies would mark every
        // replace-path rebuild stale and silently disable name minting (found
        // live: the guard tripped right after a successful exec fillet). The
        // retained tables/names describe these bodies exactly — the replay
        // built them — only the revision stamps had moved.
        captureNamingRevisions(for: plan.resultBodyIDs)
        adoptCachedBodies()
        return true
    }

    /// Read-only source acquisition for the datum adapter. Two bounded memo
    /// replays discover the actual successful last PUT, then retain precisely
    /// that version. No live counters, naming upgrades, commands or caches are
    /// adopted. Callers still fence their selection against current document
    /// generation/body revision; scratch render indices are never live picks.
    func associativeSource(for bodyID: BodyID) -> (version: GeometryVersionRef, snapshot: GeometryVersionSnapshot)? {
        associativeSources(for: [bodyID])[bodyID]
    }

    /// Batch discovery uses the same two scratch replays for all requested
    /// bodies. Face queries must not replay the entire graph twice per body.
    func associativeSources(for bodyIDs: Set<BodyID>) -> [BodyID: (version: GeometryVersionRef, snapshot: GeometryVersionSnapshot)] {
        guard !isReadOnly, !bodyIDs.isEmpty else { return [:] }
        let requestedBodies = bodyIDs.intersection(Set(document.bodies.map(\.id)))
        guard !requestedBodies.isEmpty else { return [:] }
        var scratch = evalCache
        var revision: UInt64 = 0
        let values = variableValues()
        let initial = document.features.evaluate(sketches: document.sketches, planes: document.planes,
            naming: naming, nextRevision: { revision &+= 1; return revision }, cache: &scratch,
            variables: values)
        var requestedVersions: [BodyID: GeometryVersionRef] = [:]
        for bodyID in requestedBodies {
            guard let writer = initial.lastBodyWriters[bodyID] else { continue }
            requestedVersions[bodyID] = GeometryVersionRef(bodyID: bodyID, writer: writer)
        }
        guard !requestedVersions.isEmpty else { return [:] }
        let result = document.features.evaluate(sketches: document.sketches, planes: document.planes,
            naming: naming, nextRevision: { revision &+= 1; return revision }, cache: &scratch,
            variables: values, requestedVersions: Set(requestedVersions.values))
        var sources: [BodyID: (version: GeometryVersionRef, snapshot: GeometryVersionSnapshot)] = [:]
        for (bodyID, version) in requestedVersions {
            guard result.errors[version.writer] == nil, let snapshot = result.geometryVersions[version] else { continue }
            sources[bodyID] = (version, snapshot)
        }
        return sources
    }

    private static func hasAssociations(_ document: DesignDocument) -> Bool {
        document.planes.contains { $0.definition != nil } || document.sketches.contains { $0.support != nil }
    }

    /// Domain seam for definition/support edits. Semantic edits and all derived
    /// planes, sketches and solids commit together, or nothing is applied.
    @discardableResult
    func performAssociativeTransaction(_ commands: [DocumentCommand], title: String) -> Bool {
        guard requireWritable(), !commands.isEmpty, !isRebuilding else { return false }
        var preview = document
        for command in commands { command.apply(to: &preview) }
        let resolved = VariableTable.resolve(preview.variables)
        let fanOut = Self.variableFanOutPlan(document: preview, resolved: resolved)
        preview.features = fanOut.graph
        preview.sketches = fanOut.sketches
        preview.planes = fanOut.planes
        return performRebuild(preview.features, leadingCommands: commands + fanOut.featureCommands
                              + fanOut.sketchCommands + fanOut.planeCommands, title: title,
                              previewDocument: preview)
    }

    /// The memo's bodies take the DOCUMENT's post-apply geometry and revision
    /// (shared storage, the re-minted stamp), so the next replay's splices
    /// compare equal to what is live and the memo does not double the
    /// geometry it remembers — see `EvalCache.adopt`.
    private func adoptCachedBodies() {
        evalCache.adopt(Dictionary(uniqueKeysWithValues: document.bodies.map { ($0.id, $0) }),
                        order: document.features.nodes.map(\.id))
    }

    /// Stamp which body revisions `lastFaceTables`/`lastKernelNames`
    /// describe, from the DOCUMENT's post-apply state.
    private func captureNamingRevisions<S: Sequence>(for ids: S) where S.Element == BodyID {
        let wanted = Set(ids)
        lastNamingRevisions = Dictionary(uniqueKeysWithValues:
            document.bodies.filter { wanted.contains($0.id) }
                .map { ($0.id, $0.meshRevision) })
    }

    /// Convenience for the editor/VM: change a feature node's parameters and
    /// rebuild everything downstream in one undo step. Builds the
    /// `EditFeatureCommand` (capturing the current kind as `before`) and defers
    /// to `rebuildFrom`. No-op if the node is gone.
    ///
    /// `title` is the single undo-history label for the whole edit (the
    /// parameter swap plus every rebuilt body). Callers with a specific
    /// operation pass e.g. "Edit Hole"; the generic editor default stays
    /// "Edit Feature". The leading command keeps its own type title for
    /// internal ordering; the ONE user-visible step is the composite.
    func editFeature(_ id: FeatureID, to newKind: FeatureKind,
                     title: String = "Edit Feature") {
        guard let node = document.features.node(id) else { return }
        let edit = EditFeatureCommand(featureID: id, before: node.kind, after: newKind)
        rebuildFrom(id, edit: edit, title: title)
    }

    /// Edit a pattern feature's `PatternSpec` and rebuild everything downstream in
    /// one undo step. Unlike `editFeature`, a pattern edit can change how many
    /// instance bodies the node owns (its `count`), so this resizes the node's
    /// `outputBodyIDs` alongside the spec:
    ///
    /// - `desiredCopies = max(0, spec.count - 1)` (the original is the source body,
    ///   not an emitted copy — see `evalPattern`, which emits ids `1..<count`).
    /// - GROW: append fresh `BodyID()`s to the node's current `outputBodyIDs` until
    ///   it holds `desiredCopies`. The extra ids aren't in the live graph's owned
    ///   set, so `performRebuild`'s diff sees them only in the produced bodies →
    ///   `AddBody`.
    /// - SHRINK: `prefix(desiredCopies)` the current ids; the dropped tail ids stay
    ///   in the live node's `outputBodyIDs`, so `performRebuild` unions them into
    ///   `ownedIDs`, finds the replay no longer produces them → `DeleteBodies`.
    ///
    /// The `EditFeatureOutputsCommand` (swapping BOTH kind and outputBodyIDs) rides
    /// the SAME `performRebuild` as the mesh diff — so one undo reverts the spec,
    /// the ownership change, and every instance mesh. The graph copy handed to
    /// `performRebuild` has both the new spec and the resized ids, so `evaluate`
    /// has exactly enough ids to emit `desiredCopies` instances. No-op unless the
    /// node exists and is a `.pattern`.
    func editPatternFeature(_ id: FeatureID, spec: PatternSpec) {
        guard let node = document.features.node(id),
              case let .pattern(bodyRef, _) = node.kind else { return }

        let desiredCopies = max(0, spec.count - 1)
        var afterOutputs = node.outputBodyIDs
        if afterOutputs.count > desiredCopies {
            afterOutputs = Array(afterOutputs.prefix(desiredCopies))
        } else {
            while afterOutputs.count < desiredCopies { afterOutputs.append(BodyID()) }
        }

        let afterKind = FeatureKind.pattern(body: bodyRef, spec: spec)
        let cmd = EditFeatureOutputsCommand(
            featureID: id,
            beforeKind: node.kind,
            afterKind: afterKind,
            beforeOutputs: node.outputBodyIDs,
            afterOutputs: afterOutputs
        )

        // Graph copy with the new spec AND resized ids so `evaluate` sees the new
        // parameters and has exactly enough ids to emit `desiredCopies` copies —
        // mirroring `rebuildFrom`'s edited-graph pattern.
        var editedGraph = document.features
        if let index = editedGraph.index(of: id) {
            editedGraph.nodes[index].kind = afterKind
            editedGraph.nodes[index].outputBodyIDs = afterOutputs
        }
        performRebuild(editedGraph, leadingCommands: [cmd], title: cmd.title)
    }

    // MARK: - Variables (Phase D, Task B1 / spec §6.6)

    /// The current `[name: value]` map of successfully-resolved document
    /// variables (creation-order rule; failed/forward refs are absent). Feature
    /// `Expr` formulas and sketch `SketchDimension` formulas evaluate against this.
    func variableValues() -> [String: Double] {
        VariableTable.resolve(document.variables).values
    }

    // MARK: - Formula-capable feature parameters

    /// One scalar feature parameter that can carry a variable formula.
    ///
    /// `unit` is the PUBLIC unit a caller reads/writes, while `storedUnit` is
    /// the unit of the persisted `Expr.value`. They differ only for
    /// `rotateFace.angle` (public degrees, persisted radians); the scales make
    /// that conversion explicit instead of letting a degree formula land in a
    /// radian slot. Every other slot has unit == storedUnit and scale 1.
    nonisolated struct FeatureExpressionSlot: Sendable, Equatable {
        var name: String
        var unit: String
        var storedUnit: String
        var expr: Expr
        /// stored -> public
        var publicScale: Double
        /// public -> stored
        var storedScale: Double

        init(name: String, unit: String, storedUnit: String = "mm", expr: Expr,
             publicScale: Double = 1, storedScale: Double = 1) {
            self.name = name
            self.unit = unit
            self.storedUnit = storedUnit
            self.expr = expr
            self.publicScale = publicScale
            self.storedScale = storedScale
        }

        var publicValue: Double { expr.value * publicScale }

        var formulaReferences: [String] {
            guard let formula = expr.formula else { return [] }
            return ExpressionEvaluator.identifiers(in: formula).sorted()
        }
    }

    /// Every formula-capable scalar of `kind`, in descriptor order. This is the
    /// ONE list the expression setters, reference rewrites, variable fan-out and
    /// feature query share, so a discovered expression parameter is executable
    /// and a rename cannot miss a formula it does not know about.
    ///
    /// Deliberately absent: parameters that are plain numbers today (primitive
    /// dimensions, pattern count/spacing/total_angle, booleans, vectors) and
    /// features with no scalar `Expr`. They are reported as unsupported rather
    /// than turned into a value-only mutation that silently drops intent.
    nonisolated static func expressionSlots(in kind: FeatureKind) -> [FeatureExpressionSlot] {
        let radiansToDegrees = 180 / Double.pi
        let degreesToRadians = Double.pi / 180
        switch kind {
        case let .extrude(_, _, distance, _, _, _):
            return [FeatureExpressionSlot(name: "distance", unit: "mm", expr: distance)]
        case let .draftExtrude(_, _, distance, taperAngle, _, _):
            return [FeatureExpressionSlot(name: "distance", unit: "mm", expr: distance),
                    FeatureExpressionSlot(name: "taper_angle", unit: "deg",
                                          storedUnit: "deg", expr: taperAngle)]
        case let .revolve(_, _, _, angle, _):
            return [FeatureExpressionSlot(name: "angle", unit: "deg",
                                          storedUnit: "deg", expr: angle)]
        case let .pushPull(_, distance, _):
            return [FeatureExpressionSlot(name: "distance", unit: "mm", expr: distance)]
        case let .scaleFace(_, factor):
            return [FeatureExpressionSlot(name: "factor", unit: "unitless",
                                          storedUnit: "unitless", expr: factor)]
        case let .rotateFace(_, angle, _):
            return [FeatureExpressionSlot(name: "angle", unit: "deg",
                                          storedUnit: "rad", expr: angle,
                                          publicScale: radiansToDegrees,
                                          storedScale: degreesToRadians)]
        case let .draftFace(_, _, _, angle):
            return [FeatureExpressionSlot(name: "angle", unit: "deg",
                                          storedUnit: "deg", expr: angle)]
        case let .chamfer(_, _, setback):
            return [FeatureExpressionSlot(name: "setback", unit: "mm", expr: setback)]
        case let .fillet(_, _, radius):
            return [FeatureExpressionSlot(name: "radius", unit: "mm", expr: radius)]
        case let .shell(_, _, thickness):
            return [FeatureExpressionSlot(name: "thickness", unit: "mm", expr: thickness)]
        case let .hole(_, _, _, spec):
            // Every STORED scalar participates in formula resolution, rename
            // rewrites and guarded fan-out — including recess values hidden by
            // the current type. A nil scalar has no author-owned expression to
            // report, so it is absent rather than invented.
            var slots: [FeatureExpressionSlot] = []
            if let depth = spec.depth {
                slots.append(FeatureExpressionSlot(name: "depth", unit: "mm", expr: depth))
            }
            if let diameter = spec.counterboreDiameter {
                slots.append(FeatureExpressionSlot(
                    name: "counterbore_diameter", unit: "mm", expr: diameter))
            }
            if let depth = spec.counterboreDepth {
                slots.append(FeatureExpressionSlot(
                    name: "counterbore_depth", unit: "mm", expr: depth))
            }
            if let diameter = spec.countersinkDiameter {
                slots.append(FeatureExpressionSlot(
                    name: "countersink_diameter", unit: "mm", expr: diameter))
            }
            if let angle = spec.countersinkAngle {
                slots.append(FeatureExpressionSlot(
                    name: "countersink_angle", unit: "deg",
                    storedUnit: "deg", expr: angle))
            }
            return slots
        case .primitive, .sweep, .loft, .boolean, .transform, .mirror, .pattern,
             .moveFace, .deleteFace, .replaceFace:
            return []
        }
    }

    static func expressionSlot(in kind: FeatureKind,
                               named name: String) -> FeatureExpressionSlot? {
        expressionSlots(in: kind).first { $0.name == name }
    }

    /// The same kind with ONE named scalar `Expr` replaced, preserving every
    /// other value/reference/unit. Nil when the kind has no such slot.
    static func replacingExpression(in kind: FeatureKind, named name: String,
                                    with expr: Expr) -> FeatureKind? {
        switch kind {
        case let .extrude(profile, plane, distance, symmetric, boolean, extras):
            guard name == "distance" else { return nil }
            return .extrude(profile: profile, plane: plane, distance: expr,
                            symmetric: symmetric, boolean: boolean,
                            extraProfiles: extras)
        case let .draftExtrude(profile, plane, distance, taperAngle, symmetric, boolean):
            switch name {
            case "distance":
                return .draftExtrude(profile: profile, plane: plane, distance: expr,
                                     taperAngle: taperAngle, symmetric: symmetric,
                                     boolean: boolean)
            case "taper_angle":
                return .draftExtrude(profile: profile, plane: plane, distance: distance,
                                     taperAngle: expr, symmetric: symmetric,
                                     boolean: boolean)
            default:
                return nil
            }
        case let .revolve(profile, plane, axis, angle, boolean):
            guard name == "angle" else { return nil }
            return .revolve(profile: profile, plane: plane, axis: axis,
                            angle: expr, boolean: boolean)
        case let .pushPull(face, distance, mode):
            guard name == "distance" else { return nil }
            return .pushPull(face: face, distance: expr, mode: mode)
        case let .scaleFace(face, factor):
            guard name == "factor" else { return nil }
            return .scaleFace(face: face, factor: expr)
        case let .rotateFace(face, angle, axis):
            guard name == "angle" else { return nil }
            return .rotateFace(face: face, angle: expr, axis: axis)
        case let .draftFace(face, origin, normal, angle):
            guard name == "angle" else { return nil }
            return .draftFace(face: face, neutralOrigin: origin,
                              neutralNormal: normal, angle: expr)
        case let .chamfer(body, edges, setback):
            guard name == "setback" else { return nil }
            return .chamfer(body: body, edges: edges, setback: expr)
        case let .fillet(body, edges, radius):
            guard name == "radius" else { return nil }
            return .fillet(body: body, edges: edges, radius: expr)
        case let .shell(body, openFaces, thickness):
            guard name == "thickness" else { return nil }
            return .shell(body: body, openFaces: openFaces, thickness: expr)
        case let .hole(target, profile, plane, spec):
            var updated = spec
            switch name {
            case "depth":
                guard spec.depth != nil else { return nil }
                updated.depth = expr
            case "counterbore_diameter":
                guard spec.counterboreDiameter != nil else { return nil }
                updated.counterboreDiameter = expr
            case "counterbore_depth":
                guard spec.counterboreDepth != nil else { return nil }
                updated.counterboreDepth = expr
            case "countersink_diameter":
                guard spec.countersinkDiameter != nil else { return nil }
                updated.countersinkDiameter = expr
            case "countersink_angle":
                guard spec.countersinkAngle != nil else { return nil }
                updated.countersinkAngle = expr
            default:
                return nil
            }
            return .hole(target: target, profile: profile, plane: plane, spec: updated)
        case .primitive, .sweep, .loft, .boolean, .transform, .mirror, .pattern,
             .moveFace, .deleteFace, .replaceFace:
            return nil
        }
    }

    /// Apply `transform` to every formula-capable scalar, returning a rebuilt
    /// kind only when at least one `Expr` actually changed. Sharing this walk
    /// keeps re-evaluation, rename rewriting and discovery from drifting apart.
    static func mapExpressions(
        in kind: FeatureKind,
        _ transform: (FeatureExpressionSlot) -> Expr?
    ) -> FeatureKind? {
        var result = kind
        var changed = false
        for slot in expressionSlots(in: kind) {
            guard let replacement = transform(slot), replacement != slot.expr else { continue }
            guard let replaced = replacingExpression(in: result, named: slot.name,
                                                     with: replacement) else { continue }
            result = replaced
            changed = true
        }
        return changed ? result : nil
    }

    /// Re-evaluate every formula-bearing `Expr` on `kind` against `values`,
    /// returning a new kind if ANY of its values changed, or `nil` when nothing
    /// changed (so callers only emit an edit for genuinely affected nodes).
    /// `FeatureKind` is not Equatable, so change detection is per-`Expr` value.
    /// The `formula` is always preserved on the rebuilt `Expr`.
    static func reevaluatedKind(
        _ kind: FeatureKind, with values: [String: Double]
    ) -> FeatureKind? {
        mapExpressions(in: kind) { slot in
            guard let formula = slot.expr.formula else { return nil }  // not variable-driven
            // A formula that no longer resolves — its variable was deleted or
            // renamed — errors to 0 (spec §6.6). Propagate the 0 so the breakage
            // surfaces (the step goes empty/errored) rather than silently keeping
            // the last resolved value with a now-dangling formula.
            let v = ExpressionEvaluator.evaluate(formula, variables: values) ?? 0
            guard v != slot.expr.value else { return nil }
            return Expr(value: v, formula: formula)
        }
    }

    /// Rewrite variable references inside every formula-capable scalar without
    /// touching values, references or stored units. Used by a variable rename so
    /// one token-aware rewrite covers features and sketches atomically.
    static func rewrittenKind(
        _ kind: FeatureKind,
        rewriting: (String) -> String?
    ) -> FeatureKind? {
        mapExpressions(in: kind) { slot in
            guard let formula = slot.expr.formula,
                  let rewritten = rewriting(formula),
                  rewritten != formula else { return nil }
            return Expr(value: slot.expr.value, formula: rewritten)
        }
    }

    /// Pre-resolve feature `Expr` formulas against the current variable values,
    /// writing the fresh `.value` into `document.features` IN PLACE. Optional hook
    /// for a rebuild triggered by means OTHER than a variable edit (so it still
    /// honours current variable values): `evaluate()` reads `Expr.value`, never
    /// `.formula`, so the graph must already hold the resolved values before any
    /// `performRebuild`. Not undoable — `.value` is a derived cache of `.formula`.
    func resolveExprFormulas() {
        guard requireWritable() else { return }
        let values = variableValues()
        for index in document.features.nodes.indices {
            if let newKind = Self.reevaluatedKind(document.features.nodes[index].kind, with: values) {
                document.features.nodes[index].kind = newKind
            }
        }
        for index in document.planes.indices {
            guard case var .offset(definition)? = document.planes[index].definition,
                  let formula = definition.distance.formula,
                  let value = ExpressionEvaluator.evaluate(formula, variables: values), value.isFinite else { continue }
            definition.distance.value = value
            document.planes[index].definition = .offset(definition)
        }
    }

    /// Everything one variable transaction must rebuild, computed against a
    /// PREVIEW document (the variable commands applied, formulas already
    /// rewritten) and then committed as one `performRebuild`.
    private struct VariableFanOutPlan {
        var graph: FeatureGraph
        var featureCommands: [DocumentCommand]
        var sketchCommands: [DocumentCommand]
        var sketches: [Sketch]
        var planes: [ConstructionPlane]
        var planeCommands: [DocumentCommand]
    }

    /// Resolve the prospective variables, then plan every downstream feature
    /// and sketch change. The plan contains only commands/sketches; nothing is
    /// written until the caller performs it.
    private static func variableFanOutPlan(
        document: DesignDocument,
        resolved: (resolved: [Variable], values: [String: Double], errors: [VariableID: String])
    ) -> VariableFanOutPlan {
        let values = resolved.values

        // FEATURE fan-out: formulas are re-evaluated against the new values.
        // Every changed node becomes an EditFeatureCommand in the SAME rebuild.
        var graph = document.features
        var featureCommands: [DocumentCommand] = []
        for (index, node) in document.features.nodes.enumerated() {
            guard let newKind = reevaluatedKind(node.kind, with: values) else { continue }
            featureCommands.append(EditFeatureCommand(
                featureID: node.id, before: node.kind, after: newKind))
            graph.nodes[index].kind = newKind
        }

        // SKETCH fan-out: each formula-bearing driving value is recomputed and
        // every affected sketch re-solved; all entities/dimensions land in the
        // same transaction instead of one undo step per sketch.
        var sketches = document.sketches
        var sketchCommands: [DocumentCommand] = []
        for sketchIndex in sketches.indices {
            let sketch = sketches[sketchIndex]
            var proposed = sketch
            var dimensionCommands: [DocumentCommand] = []
            for dimensionIndex in sketch.dimensions.indices {
                let before = sketch.dimensions[dimensionIndex]
                guard let formula = before.formula else { continue }
                // Broken formula (deleted/renamed variable) errors to 0 — surface
                // it rather than silently keeping the stale dimension value.
                let evaluated = ExpressionEvaluator.evaluate(formula, variables: values) ?? 0
                // A sketch angle is authored in DEGREES by the inline field but
                // persisted in RADIANS. Convert here, exactly once: storing the
                // degree result directly was interpreted as radians and made a
                // variable-driven angle jump by 57.3x.
                let value = before.kind == .angle ? evaluated * .pi / 180 : evaluated
                guard value != before.value else { continue }
                var after = before
                after.value = value
                proposed.dimensions[dimensionIndex] = after
                dimensionCommands.append(UpdateSketchDimensionCommand(
                    sketchID: sketch.id, before: before, after: after))
            }
            guard !dimensionCommands.isEmpty else { continue }

            let outcome = SketchSolverBridge.solveOutcome(
                proposed, movingEntity: nil, dragTarget: nil)
            var commands = dimensionCommands
            // Same gate as the drag path (R2-3): if the new dimension values
            // make the system CONFLICTING, the dimensions still update (they
            // are what the user's variable edit means) but the solver's
            // best-fit compromise is NOT written over the geometry.
            if outcome.structuralResidual <= 1e-3 {
                for (before, after) in zip(sketch.entities, outcome.entities) where before != after {
                    commands.append(UpdateSketchEntityCommand(
                        sketchID: sketch.id, before: before, after: after))
                }
                proposed.entities = outcome.entities
            }
            sketches[sketchIndex] = proposed
            sketchCommands.append(contentsOf: commands)
        }

        var planes = document.planes
        var planeCommands: [DocumentCommand] = []
        for index in planes.indices {
            guard case var .offset(definition)? = planes[index].definition,
                  let formula = definition.distance.formula,
                  let value = ExpressionEvaluator.evaluate(formula, variables: values), value.isFinite,
                  value != definition.distance.value else { continue }
            let before = planes[index].definition
            definition.distance.value = value
            planes[index].definition = .offset(definition)
            planeCommands.append(EditConstructionPlaneDefinitionCommand(
                planeID: planes[index].id, before: before, after: planes[index].definition))
        }
        return VariableFanOutPlan(graph: graph, featureCommands: featureCommands,
                                  sketchCommands: sketchCommands, sketches: sketches,
                                  planes: planes, planeCommands: planeCommands)
    }

    /// Apply one variable-add/edit/delete AND every dependent feature/sketch
    /// rebuild as ONE undoable transaction. `commands` are the variable-side
    /// mutations (including reference rewrites a rename requires); their
    /// resolved values drive the fan-out computed against a preview.
    ///
    /// A rejected service validation never reaches this method. Associative
    /// rebuild errors are refused before commit. Legacy no-association kernel
    /// errors retain the service checkpoint rollback path. Both preserve redo
    /// and advance query generations instead of rewinding.
    @discardableResult
    func performVariableTransaction(_ commands: [DocumentCommand], title: String) -> Bool {
        guard requireWritable() else { return false }
        guard !isRebuilding, !commands.isEmpty else { return false }
        var preview = document
        for command in commands {
            command.apply(to: &preview)
        }
        let resolved = VariableTable.resolve(preview.variables)
        var variableCacheCommands: [DocumentCommand] = []
        for index in preview.variables.indices where index < resolved.resolved.count {
            let before = preview.variables[index]
            let after = resolved.resolved[index]
            if before.value != after.value {
                variableCacheCommands.append(EditVariableCommand(before: before, after: after))
                preview.variables[index] = after
            }
        }
        let plan = Self.variableFanOutPlan(document: preview, resolved: resolved)
        let leading = commands + variableCacheCommands + plan.featureCommands + plan.sketchCommands + plan.planeCommands
        guard !leading.isEmpty else { return false }
        preview.features = plan.graph
        preview.sketches = plan.sketches
        preview.planes = plan.planes
        return performRebuild(plan.graph, leadingCommands: leading, title: title,
                              previewDocument: preview)
    }

    /// Fan-out after any variable add/edit/delete performed through the legacy
    /// UI path (the VM performs the mutating command, then calls this). Feature
    /// AND sketch formula rebuilds now land in ONE undo step; the variable
    /// command itself remains the VM's separate leading step.
    ///
    /// Guarded by `isRebuilding` so a rebuild already in flight never re-enters.
    func variablesDidChange() {
        guard requireWritable() else { return }
        guard !isRebuilding else { return }

        let resolved = VariableTable.resolve(document.variables)
        var cacheChanged = false
        for index in document.variables.indices where index < resolved.resolved.count {
            if document.variables[index].value != resolved.resolved[index].value {
                document.variables[index].value = resolved.resolved[index].value
                cacheChanged = true
            }
        }
        let plan = Self.variableFanOutPlan(document: document, resolved: resolved)
        let leading = plan.featureCommands + plan.sketchCommands + plan.planeCommands
        guard !leading.isEmpty else {
            if cacheChanged { didChange(autosave: false) }
            return
        }
        var preview = document
        preview.features = plan.graph
        preview.sketches = plan.sketches
        preview.planes = plan.planes
        performRebuild(plan.graph, leadingCommands: leading, title: "Variables",
                       previewDocument: preview)
    }

    // MARK: - Transaction checkpoints

    /// Exact document + undo/redo/cache state before a speculative edit. Kept
    /// in memory only; restoring it does not touch the package or the store.
    func captureEditCheckpoint() -> CADEditCheckpoint {
        CADEditCheckpoint(document: document,
                          persistenceChangeCount: persistenceChangeCount,
                          undo: undoStack.checkpoint(),
                          evalCache: evalCache,
                          lastEvalErrors: lastEvalErrors,
                          lastReferenceErrors: lastReferenceErrors,
                          lastBodyWriters: lastBodyWriters,
                          lastFaceTables: lastFaceTables,
                          lastKernelNames: lastKernelNames,
                          lastNamingRevisions: lastNamingRevisions)
    }

    /// Restore a speculative-edit checkpoint. The change count is NOT rolled
    /// back: it advances through `didChange()` so query generations and mesh
    /// caches can never mistake the restored state for the rejected edit.
    /// Undo AND redo arrays are restored verbatim, so a pre-existing redo
    /// history survives and the rejected edit is never redoable.
    func restoreEditCheckpoint(_ checkpoint: CADEditCheckpoint) {
        guard requireWritable() else { return }
        restoreCheckpointState(checkpoint, autosave: true)
    }

    private func restoreCheckpointState(_ checkpoint: CADEditCheckpoint, autosave: Bool) {
        document = checkpoint.document
        persistenceChangeCount = checkpoint.persistenceChangeCount
        undoStack.restore(checkpoint.undo)
        evalCache = checkpoint.evalCache
        lastEvalErrors = checkpoint.lastEvalErrors
        lastReferenceErrors = checkpoint.lastReferenceErrors
        lastBodyWriters = checkpoint.lastBodyWriters
        lastRebuildRejection = [:]
        lastRejectedFeatureErrors = [:]
        lastFaceTables = checkpoint.lastFaceTables
        lastKernelNames = checkpoint.lastKernelNames
        lastNamingRevisions = checkpoint.lastNamingRevisions
        didChange(autosave: autosave, persistedChange: false)
    }

    // MARK: - Persistence

    private func load() {
        let associationAssessment = try? CADDocumentFormat.assess(
            planes: project.planes.map { CADBlobRecord(blobID: $0.planeID, data: $0.planeData, sha256: "") },
            sketches: project.sketches.map { CADBlobRecord(blobID: $0.sketchID, data: $0.sketchData, sha256: "") },
            features: project.features.map {
                CADFeatureRecord(featureID: $0.featureID, orderIndex: $0.orderIndex,
                                 name: $0.name, suppressed: $0.suppressed,
                                 kind: $0.kindData, outputBodyIDs: $0.outputBodyIDData)
            },
            drawings: project.drawingsData)
        project.hasOpaqueAssociations = project.hasOpaqueAssociations || associationAssessment?.isOpaqueReadOnly == true
        storeIsNewerThanApp = project.formatVersion > Project.currentFormatVersion || project.hasOpaqueAssociations
        #if DEBUG
        OpenTiming.mark("load start")
        #endif
        var loaded = DesignDocument()
        for persisted in project.bodies {
            guard let render = try? MeshBlob.decode(persisted.meshData),
                  let transform = try? JSONDecoder().decode(Transform3D.self, from: persisted.transformData)
            else {
                unreadableRows.bodies.insert(persisted.bodyID)
                continue
            }
            // Per-COLUMN decode failures need the same protection as whole
            // rows: the row itself is fine, so it isn't in `unreadableRows`,
            // and save() would happily write the decoded `nil` back over a
            // blob it merely failed to read — losing an analytic brep, a
            // material or a primitive spec permanently (2026-08-25 review
            // round 2). Record them so save() leaves those columns alone.
            let primitive = persisted.primitiveData.flatMap { data -> PrimitiveSpec? in
                let decoded = try? JSONDecoder().decode(PrimitiveSpec.self, from: data)
                if decoded == nil { unreadableRows.bodyPrimitive.insert(persisted.bodyID) }
                return decoded
            }
            var body = Body(
                id: BodyID(raw: persisted.bodyID),
                name: persisted.name,
                transform: transform,
                primitive: primitive,
                render: render,
                revision: loaded.nextRevision()
            )
            body.isHidden = persisted.isHidden
            body.material = persisted.materialData.flatMap { data -> BodyMaterialSpec? in
                let decoded = try? JSONDecoder().decode(BodyMaterialSpec.self, from: data)
                if decoded == nil { unreadableRows.bodyMaterial.insert(persisted.bodyID) }
                return decoded
            }
            // Stable per-face material snapshots. A corrupt/unknown blob is
            // preserved (never overwritten) and the body simply keeps its
            // whole-body appearance; geometry is untouched.
            body.materialFaceBindings = persisted.faceMaterialsData.flatMap { data -> [CADFaceMaterialBinding]? in
                let decoded = try? JSONDecoder().decode([CADFaceMaterialBinding].self, from: data)
                if decoded == nil { unreadableRows.bodyFaceMaterials.insert(persisted.bodyID) }
                return decoded
            } ?? []
            // Restore the analytic B-rep so a reloaded cylinder stays round and
            // can still compose booleans. An unreadable blob (truncated, or
            // written by a newer OCCT) leaves the body Euclid-only for this
            // session — the persisted render mesh is already correct — but the
            // stored blob is PRESERVED rather than overwritten with nil.
            body.brep = persisted.brepData.flatMap { data -> BRepHandle? in
                let decoded = OCCTKernel.deserialize(data)
                if decoded == nil { unreadableRows.bodyBrep.insert(persisted.bodyID) }
                return decoded
            }
            loaded.bodies.append(body)
        }
        #if DEBUG
        OpenTiming.mark("\(loaded.bodies.count) bodies decoded (mesh, brep)")
        #endif
        for persisted in project.sketches {
            do {
                loaded.sketches.append(try JSONDecoder().decode(Sketch.self, from: persisted.sketchData))
            } catch {
                unreadableRows.sketches.insert(persisted.sketchID)
                if associationAssessment?.opaqueSketches.contains(persisted.sketchID) == true,
                   let cache = try? CADDocumentFormat.cachedSketch(from: persisted.sketchData) {
                    loaded.sketches.append(cache) // view-only; original bytes are not replaced
                }
            }
        }
        #if DEBUG
        OpenTiming.mark("\(loaded.sketches.count) sketches decoded")
        #endif
        for persisted in project.planes {
            do {
                loaded.planes.append(try JSONDecoder().decode(ConstructionPlane.self, from: persisted.planeData))
            } catch {
                unreadableRows.planes.insert(persisted.planeID)
                if associationAssessment?.opaquePlanes.contains(persisted.planeID) == true,
                   let cache = try? CADDocumentFormat.cachedPlane(from: persisted.planeData) {
                    loaded.planes.append(cache) // display cache, never editable/solve input
                }
            }
        }
        for persisted in project.axes {
            if let axis = try? JSONDecoder().decode(ConstructionAxis.self, from: persisted.axisData) {
                loaded.axes.append(axis)
            } else {
                unreadableRows.axes.insert(persisted.axisID)
            }
        }
        for persisted in project.images {
            if var image = try? JSONDecoder().decode(InsertedImage.self, from: persisted.infoData) {
                image.imageData = persisted.imageData
                loaded.images.append(image)
            } else {
                unreadableRows.images.insert(persisted.imageID)
            }
        }
        for persisted in project.symbols {
            if let symbol = try? JSONDecoder().decode(Symbol.self, from: persisted.symbolData) {
                loaded.symbols.append(symbol)
            } else {
                unreadableRows.symbols.insert(persisted.symbolID)
            }
        }
        // Items Manager folders (spec §11): one JSON column, absent for
        // documents that never made a folder.
        if let data = project.itemFoldersData {
            if let folders = try? JSONDecoder().decode([ItemFolder].self, from: data) {
                loaded.itemFolders = folders
            } else {
                unreadableRows.itemFolders = true
            }
        }
        // Phase D feature graph: replay order is `orderIndex` (SwiftData
        // relationships are unordered). A node whose kind blob won't decode is
        // skipped (decodeFeature -> nil), not fatal. Pre-Phase-D projects have no
        // PersistedFeature rows -> empty graph, and render from their baked
        // PersistedBody meshes until the first parametric edit.
        // The rollback marker is a positional count of active leading nodes. If a
        // node that sat BEFORE the marker fails to decode and is skipped, the
        // active prefix shrinks, so shift the marker down by the number of such
        // skips to keep it on the same logical boundary.
        #if DEBUG
        OpenTiming.mark("planes/axes/images/symbols decoded")
        #endif
        let savedMarker = project.rollbackIndex
        var skippedBeforeMarker = 0
        for (position, persisted) in project.features
            .sorted(by: { $0.orderIndex < $1.orderIndex }).enumerated() {
            if let node = decodeFeature(persisted) {
                loaded.features.nodes.append(node)
            } else {
                unreadableRows.features.insert(persisted.featureID)
                if let marker = savedMarker, position < marker {
                    skippedBeforeMarker += 1
                }
            }
        }
        // Phase D (Tranche 5) rollback marker: a scalar column on Project. Pre-
        // rollback stores have `rollbackIndex == nil` (all nodes active).
        loaded.features.rollbackIndex = savedMarker.map {
            max(0, min($0 - skippedBeforeMarker, loaded.features.nodes.count))
        }
        // Phase D variables (spec §6.6): ordered by `orderIndex` (SwiftData
        // relationships are unordered) so the creation-order resolution rule
        // survives the round-trip. Pre-tranche-3 projects have no PersistedVariable
        // rows -> empty list. `try?`-per-item is defensive symmetry with the other
        // decode loops (decodeVariable itself is non-throwing).
        for persisted in project.variables.sorted(by: { $0.orderIndex < $1.orderIndex }) {
            loaded.variables.append(decodeVariable(persisted))
        }
        // Floe workbench record blobs: opaque JSON owned by the assembly,
        // drawing and script services. They ride on the document so their
        // edits are undoable commands; save() writes them back to the project.
        loaded.assemblyData = project.assemblyData
        loaded.drawingsData = project.drawingsData
        loaded.scriptsData = project.scriptsData
        loaded.sceneSettingsData = project.sceneSettingsData
        loaded.materialLibraryData = project.materialsData
        loaded.animationData = project.animationData
        document = loaded
        evalCache = EvalCache()   // a fresh memo for a freshly loaded document
        #if DEBUG
        OpenTiming.mark("\(loaded.features.nodes.count) features decoded, load done")
        #endif
        if project.hasOpaqueAssociations {
            loadWarning = CADDocumentFormat.opaqueReadOnlyMessage
        } else if storeIsNewerThanApp {
            loadWarning = """
            This project was saved by a newer version of the app. It opens \
            read-only here — changes will not be saved. Update the app to \
            edit it.
            """
        } else {
            // Both conditions can hold at once — report each, rather than
            // letting the row message hide which shapes lost detail.
            var parts: [String] = []
            if unreadableRows.rowCount > 0 {
                parts.append("""
                \(unreadableRows.rowCount) item(s) in this project couldn't be \
                read by this version of the app. They stay safely stored and \
                are hidden from the editor; nothing has been deleted.
                """)
            }
            if unreadableRows.partialBodyCount > 0 {
                parts.append("""
                \(unreadableRows.partialBodyCount) shape(s) opened without some \
                detail this version couldn't read. The stored data is kept \
                untouched, so nothing is lost.
                """)
            }
            loadWarning = parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        }
        changeCount += 1
        // A document saved with broken refs used to reopen with NO badges,
        // because errors only existed after the first live rebuild (review
        // R4-N6). Surface them without holding the open: see below.
        scheduleLoadEvalRefresh()
    }

    /// The load-time badge refresh, off the open path. It is the whole graph
    /// replayed against an EMPTY memo — 5.7 s of a 6.2 s open for a
    /// 13-feature document on an iPad Pro in Debug (2026-09-13, "any drawing
    /// takes a second or two to open") — so it runs detached on value copies,
    /// as the boolean CSG does, and only its error map comes back, and only
    /// if the document has not changed meanwhile (an edit's own rebuild has
    /// fresher errors). The scratch memo is NOT adopted: its revision stamps
    /// come from a scratch counter, not the document's, so the first live
    /// rebuild still warms the memo itself.
    private func scheduleLoadEvalRefresh() {
        guard !isReadOnly else { return }
        guard !document.features.nodes.isEmpty || Self.hasAssociations(document) else {
            lastEvalErrors = [:]
            lastReferenceErrors = [:]
            lastBodyWriters = [:]
            return
        }
        let features = document.features
        let sketches = document.sketches
        let planes = document.planes
        let naming = naming
        let values = variableValues()
        let generation = changeCount
        Task.detached(priority: .utility) { [weak self] in
            var counter: UInt64 = 1
            var scratch = EvalCache()
            let result = features.evaluate(
                sketches: sketches,
                planes: planes,
                naming: naming,
                nextRevision: { counter &+= 1; return counter },
                cache: &scratch, variables: values
            )
            await self?.adoptLoadEvalErrors(result.errors, referenceErrors: result.referenceErrors,
                                           writers: result.lastBodyWriters, generation: generation)
        }
    }

    /// The main-actor half of `scheduleLoadEvalRefresh`: keep the replay's
    /// errors only if no edit has happened since it was scheduled.
    private func adoptLoadEvalErrors(_ errors: [FeatureID: FeatureError],
                                     referenceErrors: [AssociativeReferenceKey: AssociativeReferenceError],
                                     writers: [BodyID: FeatureID], generation: Int) {
        guard changeCount == generation else { return }
        lastEvalErrors = errors
        lastReferenceErrors = referenceErrors
        lastBodyWriters = writers
    }

    /// Recompute `lastEvalErrors` WITHOUT touching any body: replay the
    /// feature graph against a scratch revision counter and keep only the
    /// error map. Bodies are discarded, so the replay can't disturb the
    /// live document (nothing is applied — the C4 path-dependence caveat
    /// doesn't bite). Called on load and after undo/redo, the two paths
    /// that used to leave stale or missing badges (R4-N6 / S6).
    private func refreshEvalErrors() {
        guard !isReadOnly else { return }
        lastRebuildRejection = [:]
        lastRejectedFeatureErrors = [:]
        guard !document.features.nodes.isEmpty || Self.hasAssociations(document) else {
            lastEvalErrors = [:]
            lastReferenceErrors = [:]
            lastBodyWriters = [:]
            return
        }
        var counter: UInt64 = 1
        // Against a COPY of the memo: as fast as a live rebuild for unchanged
        // nodes, and still incapable of mutating the document or the memo.
        var scratch = evalCache
        let result = document.features.evaluate(
            sketches: document.sketches,
            planes: document.planes,
            naming: naming,
            nextRevision: { counter &+= 1; return counter },
            cache: &scratch,
            variables: variableValues()
        )
        lastEvalErrors = result.errors
        lastReferenceErrors = result.referenceErrors
        lastBodyWriters = result.lastBodyWriters
        lastRebuildRejection = [:]
        lastRejectedFeatureErrors = [:]
    }

    /// Cancel a pending debounced autosave and commit now. Called when the
    /// workbench closes so a just-made edit is never lost to the debounce.
    func flushPendingAutosave() {
        guard saveTask != nil else { return }
        save()
    }

    private func scheduleAutosave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            _ = await self?.saveAsync()
        }
    }

    /// Synchronous save used by tests and callers already off the hot path.
    func save() {
        saveTask?.cancel()
        saveTask = nil
        guard requireWritable() else { return }
        do {
            guard let payload = try buildSavePayload() else { return }
            guard let store = modelContext.store else { throw CADDocumentStoreError.noStoreAttached }
            let receipt = try store.performWriteWithIdentity(payload)
            adoptCommittedIdentity(receipt, persistenceCount: persistenceChangeCount)
        } catch {
            recordSaveResult(error.localizedDescription)
        }
    }

    /// Off-main save: OCCT B-rep serialization is pre-warmed in a detached
    /// task, then JSON encoding + SHA-256 + file I/O run detached against the
    /// revision-guarded store. Only the cheap record slice runs on the
    /// session actor.
    @discardableResult
    func saveAsync() async -> String? {
        let outcome = await saveWithIdentityAsync()
        return outcome.error
    }

    /// The one async writer. Callers receive THIS commit's immutable outcome;
    /// publishing the newest receipt for UI observation is a separate step.
    @discardableResult
    func saveWithIdentityAsync() async -> CADSaveOutcome {
        saveTask?.cancel()
        saveTask = nil
        if let block = writeBlock {
            recordWriteBlock(block.message)
            return failedSaveOutcome(block.message)
        }
        inFlightSaveCount += 1
        defer { inFlightSaveCount -= 1 }
        await prewarmBrepSerialization()
        // Preserve owner acquisition and local-error fences across the await.
        if let block = writeBlock {
            recordWriteBlock(block.message)
            return failedSaveOutcome(block.message)
        }
        #if DEBUG
        if let failure = saveFailureForTesting {
            saveFailureForTesting = nil
            recordSaveResult(failure)
            return failedSaveOutcome(failure)
        }
        #endif
        do {
            let savedPersistenceCount = persistenceChangeCount
            guard let payload = try buildSavePayload() else { return savedIdentity }
            guard let store = modelContext.store else { throw CADDocumentStoreError.noStoreAttached }
            let receipt = try await Task.detached(priority: .utility) {
                try CADModelContext.write(payload, to: store)
            }.value
            #if DEBUG
            // A deterministic local test seam AFTER real commit / BEFORE
            // delivery. Never replaces IO, CAS, or a store lock.
            if let delivery = committedIdentityDeliveryForTesting { await delivery(receipt) }
            #endif
            adoptCommittedIdentity(receipt, persistenceCount: savedPersistenceCount)
            return receipt
        } catch {
            let message = error.localizedDescription
            recordSaveResult(message)
            return failedSaveOutcome(message)
        }
    }

    private func failedSaveOutcome(_ message: String) -> CADSaveOutcome {
        var outcome = savedIdentity
        outcome.error = message
        return outcome
    }

    /// B-rep blobs are immutable once produced; cache the serialized bytes per
    /// body/meshRevision/handle so a save never re-serializes an unchanged
    /// solid and can pre-serialize changed ones off-main.
    private var brepBlobCache: [UUID: (handle: ObjectIdentifier, revision: UInt64, data: Data)] = [:]

    private func serializedBrep(for body: Body) -> Data? {
        guard let handle = body.brep else { return nil }
        let key = ObjectIdentifier(handle)
        if let cached = brepBlobCache[body.id.raw],
           cached.handle == key, cached.revision == body.meshRevision {
            return cached.data
        }
        let data = OCCTKernel.serialize(handle)
        if let data {
            brepBlobCache[body.id.raw] = (key, body.meshRevision, data)
        }
        return data
    }

    /// Serialize every changed analytic body off-main into the blob cache.
    ///
    /// Ownership: the detached serializer reads ONLY independently-owned deep
    /// copies (`OCCTKernel.independentSnapshot`) made here on the session
    /// actor. Live handles are aliased (undo snapshots retain the same
    /// instance; identity transforms return `self`) and tessellation writes
    /// their shared TShape (see `BRepHandle`'s caveat), so a background
    /// thread can never touch them. A body whose snapshot fails to copy is
    /// skipped here and serialized later on the session actor by
    /// `serializedBrep(for:)` — never shared off-main.
    ///
    /// Adoption after the await is generation-guarded: an entry enters the
    /// cache only while its body is still the exact (handle,
    /// `meshRevision`) generation that was snapshotted, so work that went
    /// stale during the suspension (an edit/undo, a nested newer save, a
    /// closing generation) can neither adopt a cache slot for a state it did
    /// not read nor overwrite a fresher entry.
    func prewarmBrepSerialization() async {
        #if DEBUG
        if let suspension = savePrewarmSuspensionForTesting { await suspension() }
        #endif
        let pending: [(id: UUID, revision: UInt64, liveKey: ObjectIdentifier, snapshot: BRepHandle)] =
            document.bodies.compactMap { body in
                guard let handle = body.brep else { return nil }
                if let cached = brepBlobCache[body.id.raw],
                   cached.handle == ObjectIdentifier(handle),
                   cached.revision == body.meshRevision {
                    return nil
                }
                guard let snapshot = OCCTKernel.independentSnapshot(handle) else { return nil }
                return (body.id.raw, body.meshRevision, ObjectIdentifier(handle), snapshot)
            }
        guard !pending.isEmpty else { return }
        #if DEBUG
        // Read on the session actor; the detached closure captures the value.
        let serializationSuspension = brepSerializationSuspensionForTesting
        #endif
        let serialized: [(UUID, UInt64, ObjectIdentifier, Data)] = await Task.detached(priority: .userInitiated) {
            #if DEBUG
            if let suspension = serializationSuspension { await suspension() }
            #endif
            return pending.compactMap { id, revision, liveKey, snapshot in
                guard let data = OCCTKernel.serialize(snapshot) else { return nil }
                return (id, revision, liveKey, data)
            }
        }.value
        for entry in serialized {
            guard let current = document.body(with: BodyID(raw: entry.0)),
                  current.meshRevision == entry.1,
                  let handle = current.brep,
                  ObjectIdentifier(handle) == entry.2 else { continue }
            brepBlobCache[entry.0] = (entry.2, entry.1, entry.3)
        }
    }

    /// Build the commit payload from the record graph. Runs on the session
    /// actor; contains no JSON/hash/file work (see `CADWritePayload`).
    private func buildSavePayload() throws -> CADWritePayload? {
        // A store written by a NEWER format must never be rewritten by this
        // build — the diffs below would delete every row it couldn't decode.
        // The user was warned at load (`loadWarning`).
        guard !isReadOnly else { throw CADDocumentFormatError.opaqueAssociations }
        guard !isSketchPreviewActive else { throw SketchPreviewWriteError.editing }
        try CADDocumentFormat.validateLiveAssociations(document)

        // Floe workbench record blobs are document state (undoable commands);
        // mirror them onto the project columns the package store slices
        // verbatim into document.json.
        project.assemblyData = document.assemblyData
        project.drawingsData = document.drawingsData
        project.scriptsData = document.scriptsData
        project.sceneSettingsData = document.sceneSettingsData
        project.materialsData = document.materialLibraryData
        project.animationData = document.animationData

        // Diff by ID against the persisted objects. Every deletion loop
        // excludes `unreadableRows` — rows load() couldn't decode are not in
        // `document`, but deleting them would turn a recoverable skip into
        // permanent data loss. Encode failures likewise skip the row update
        // (keeping the old blob) rather than writing empty Data; the ID is
        // recorded as live FIRST so the row survives the deletion diff.
        var persistedByID = [UUID: PersistedBody]()
        for persisted in project.bodies {
            persistedByID[persisted.bodyID] = persisted
        }

        var liveIDs = Set<UUID>()
        for body in document.bodies {
            liveIDs.insert(body.id.raw)
            guard let transformData = try? JSONEncoder().encode(body.transform) else { continue }
            let primitiveData = body.primitive.flatMap { try? JSONEncoder().encode($0) }
            let meshData = MeshBlob.encode(body.render)
            let materialData = body.material.flatMap { try? JSONEncoder().encode($0) }
            let faceMaterialsData = body.materialFaceBindings.isEmpty
                ? nil : try? JSONEncoder().encode(body.materialFaceBindings)
            // Analytic geometry, when this body has it — so roundness and boolean
            // composability survive a reload instead of degrading to triangles.
            // Cache-first: `saveAsync` pre-serializes changed solids off-main.
            let brepData = serializedBrep(for: body)

            if let persisted = persistedByID[body.id.raw] {
                let id = body.id.raw
                // Columns load() couldn't decode keep their stored blob: we
                // decoded them to nil, so writing that nil back would destroy
                // data this build merely couldn't read.
                //
                // But the GEOMETRY-tied columns (primitive spec, brep) may only
                // be preserved while the mesh they describe is UNCHANGED. If the
                // user reshaped the body, the preserved blob describes geometry
                // that no longer exists, and a newer build would load a stale
                // analytic solid alongside the new mesh — precisely the
                // mesh/brep divergence the B-rep work exists to prevent. So a
                // changed mesh drops them. This also covers the inverse case:
                // a body that GAINED a brep this session (rebuild composed one)
                // has a changed mesh too, so the new brep is written, not
                // discarded by the preservation rule.
                // Preserve a column ONLY while there is nothing real to put in
                // its place. Keying purely on "load couldn't decode it" would
                // freeze the column for the whole session and silently discard
                // the user's own later edits — applying a material to such a
                // body would never reach disk.
                func preserve(_ unreadable: Set<UUID>, _ encoded: Data?) -> Bool {
                    encoded == nil && unreadable.contains(id)
                }
                let preservesGeometry = unreadableRows.bodyPrimitive.contains(id)
                    || unreadableRows.bodyBrep.contains(id)
                // Only faults in the stored blob for the rare preserved rows.
                let meshUnchanged = preservesGeometry && persisted.meshData == meshData

                persisted.name = body.name
                persisted.transformData = transformData
                if !(preserve(unreadableRows.bodyPrimitive, primitiveData) && meshUnchanged) {
                    persisted.primitiveData = primitiveData
                }
                persisted.meshData = meshData
                persisted.isHidden = body.isHidden
                // Material is independent of geometry — no mesh condition.
                if !preserve(unreadableRows.bodyMaterial, materialData) {
                    persisted.materialData = materialData
                }
                if !preserve(unreadableRows.bodyFaceMaterials, faceMaterialsData) {
                    persisted.faceMaterialsData = faceMaterialsData
                }
                if !(preserve(unreadableRows.bodyBrep, brepData) && meshUnchanged) {
                    persisted.brepData = brepData
                }
            } else {
                let persisted = PersistedBody(
                    bodyID: body.id.raw,
                    name: body.name,
                    transformData: transformData,
                    primitiveData: primitiveData,
                    meshData: meshData
                )
                persisted.isHidden = body.isHidden
                persisted.materialData = materialData
                persisted.faceMaterialsData = faceMaterialsData
                persisted.brepData = brepData
                persisted.project = project
                modelContext.insert(persisted)
            }
        }
        for persisted in project.bodies
        where !liveIDs.contains(persisted.bodyID)
            && !unreadableRows.bodies.contains(persisted.bodyID) {
            modelContext.delete(persisted)
        }

        var persistedSketchByID = [UUID: PersistedSketch]()
        for persisted in project.sketches {
            persistedSketchByID[persisted.sketchID] = persisted
        }
        var liveSketchIDs = Set<UUID>()
        for sketch in document.sketches {
            liveSketchIDs.insert(sketch.id.raw)
            guard let data = try? JSONEncoder().encode(sketch) else { continue }
            if let persisted = persistedSketchByID[sketch.id.raw] {
                persisted.sketchData = data
            } else {
                let persisted = PersistedSketch(sketchID: sketch.id.raw, sketchData: data)
                persisted.project = project
                modelContext.insert(persisted)
            }
        }
        for persisted in project.sketches
        where !liveSketchIDs.contains(persisted.sketchID)
            && !unreadableRows.sketches.contains(persisted.sketchID) {
            modelContext.delete(persisted)
        }

        var persistedPlaneByID = [UUID: PersistedPlane]()
        for persisted in project.planes {
            persistedPlaneByID[persisted.planeID] = persisted
        }
        var livePlaneIDs = Set<UUID>()
        for plane in document.planes {
            livePlaneIDs.insert(plane.id.raw)
            guard let data = try? JSONEncoder().encode(plane) else { continue }
            if let persisted = persistedPlaneByID[plane.id.raw] {
                persisted.planeData = data
            } else {
                let persisted = PersistedPlane(planeID: plane.id.raw, planeData: data)
                persisted.project = project
                modelContext.insert(persisted)
            }
        }
        for persisted in project.planes
        where !livePlaneIDs.contains(persisted.planeID)
            && !unreadableRows.planes.contains(persisted.planeID) {
            modelContext.delete(persisted)
        }

        var persistedAxisByID = [UUID: PersistedAxis]()
        for persisted in project.axes {
            persistedAxisByID[persisted.axisID] = persisted
        }
        var liveAxisIDs = Set<UUID>()
        for axis in document.axes {
            liveAxisIDs.insert(axis.id.raw)
            guard let data = try? JSONEncoder().encode(axis) else { continue }
            if let persisted = persistedAxisByID[axis.id.raw] {
                persisted.axisData = data
            } else {
                let persisted = PersistedAxis(axisID: axis.id.raw, axisData: data)
                persisted.project = project
                modelContext.insert(persisted)
            }
        }
        for persisted in project.axes
        where !liveAxisIDs.contains(persisted.axisID)
            && !unreadableRows.axes.contains(persisted.axisID) {
            modelContext.delete(persisted)
        }

        var persistedImageByID = [UUID: PersistedImage]()
        for persisted in project.images {
            persistedImageByID[persisted.imageID] = persisted
        }
        var liveImageIDs = Set<UUID>()
        for image in document.images {
            liveImageIDs.insert(image.id.raw)
            // Blob lives in the externalStorage column; strip it from the JSON.
            var info = image
            info.imageData = Data()
            guard let infoData = try? JSONEncoder().encode(info) else { continue }
            if let persisted = persistedImageByID[image.id.raw] {
                persisted.infoData = infoData
                persisted.imageData = image.imageData
            } else {
                let persisted = PersistedImage(
                    imageID: image.id.raw, infoData: infoData, imageData: image.imageData
                )
                persisted.project = project
                modelContext.insert(persisted)
            }
        }
        for persisted in project.images
        where !liveImageIDs.contains(persisted.imageID)
            && !unreadableRows.images.contains(persisted.imageID) {
            modelContext.delete(persisted)
        }

        var persistedSymbolByID = [UUID: PersistedSymbol]()
        for persisted in project.symbols {
            persistedSymbolByID[persisted.symbolID] = persisted
        }
        var liveSymbolIDs = Set<UUID>()
        for symbol in document.symbols {
            liveSymbolIDs.insert(symbol.id.raw)
            guard let data = try? JSONEncoder().encode(symbol) else { continue }
            if let persisted = persistedSymbolByID[symbol.id.raw] {
                persisted.symbolData = data
            } else {
                let persisted = PersistedSymbol(symbolID: symbol.id.raw, symbolData: data)
                persisted.project = project
                modelContext.insert(persisted)
            }
        }
        for persisted in project.symbols
        where !liveSymbolIDs.contains(persisted.symbolID)
            && !unreadableRows.symbols.contains(persisted.symbolID) {
            modelContext.delete(persisted)
        }

        // Phase D feature graph: diff by featureID, mirroring the PersistedBody
        // block. `orderIndex` is the node's array position so replay order
        // survives the round-trip; kind/outputBodyIDs go through the A4 helpers.
        var persistedFeatureByID = [UUID: PersistedFeature]()
        for persisted in project.features {
            persistedFeatureByID[persisted.featureID] = persisted
        }
        var liveFeatureIDs = Set<UUID>()
        for (index, node) in document.features.nodes.enumerated() {
            liveFeatureIDs.insert(node.id.raw)
            let kindData = encodeFeatureKind(node.kind)
            let outputBodyIDData = encodeBodyIDs(node.outputBodyIDs)
            if let persisted = persistedFeatureByID[node.id.raw] {
                persisted.orderIndex = index
                persisted.name = node.name
                persisted.suppressed = node.suppressed
                persisted.kindData = kindData
                persisted.outputBodyIDData = outputBodyIDData
            } else {
                let persisted = encodeFeature(node, orderIndex: index)
                persisted.project = project
                modelContext.insert(persisted)
            }
        }
        for persisted in project.features
        where !liveFeatureIDs.contains(persisted.featureID)
            && !unreadableRows.features.contains(persisted.featureID) {
            modelContext.delete(persisted)
        }
        // Phase D (Tranche 5) rollback marker: mirror the in-memory graph's marker
        // onto the Project scalar column (nil = all nodes active).
        project.rollbackIndex = document.features.rollbackIndex

        // Phase D variables (spec §6.6): diff by variableID, mirroring the
        // PersistedFeature block. `orderIndex` is the variable's array position so
        // creation order survives the round-trip; name/expression/value map per
        // column via the A2 helpers.
        var persistedVariableByID = [UUID: PersistedVariable]()
        for persisted in project.variables {
            persistedVariableByID[persisted.variableID] = persisted
        }
        var liveVariableIDs = Set<UUID>()
        for (index, variable) in document.variables.enumerated() {
            liveVariableIDs.insert(variable.id.raw)
            if let persisted = persistedVariableByID[variable.id.raw] {
                persisted.orderIndex = index
                persisted.name = variable.name
                persisted.expression = variable.expression
                persisted.value = variable.value
            } else {
                let persisted = encodeVariable(variable, orderIndex: index)
                persisted.project = project
                modelContext.insert(persisted)
            }
        }
        for persisted in project.variables where !liveVariableIDs.contains(persisted.variableID) {
            modelContext.delete(persisted)
        }

        // Items Manager folders: members whose item is gone stay in memory
        // (undo of a delete puts the item back in its folder) but are pruned
        // on the way to disk. A blob load() couldn't decode is left alone.
        if !unreadableRows.itemFolders {
            let folders = ItemFolderTree(document.itemFolders).pruned(to: document.itemKeys)
            let data = folders.isEmpty ? nil : try? JSONEncoder().encode(folders)
            if project.itemFoldersData != data { project.itemFoldersData = data }
        }

        project.modifiedAt = Date()
        project.formatVersion = max(project.formatVersion, CADDocumentFormat.requiredFormat(document: document))
        return try modelContext.preparedPayload()
    }

    /// Commit the current document synchronously (tests, explicit close).
    /// Returns the store revision after the write, or nil when refused.
    @discardableResult
    func commitNow() -> Int? {
        save()
        return lastSaveError == nil && !isReadOnly ? modelContext.store?.revision : nil
    }
}
