// FloeWorkbench — PreparedCore: document/service coordinator.
//
// One actor owns the runtime coordination state that must NOT be persisted:
// temporary instruction leases, active instruction handles, processed
// operation IDs and per-document caches. Durable content, revision and the
// journal live in `MediaProject` and are written atomically by the shared
// `MediaProjectStore` with compare-and-swap on the expected revision.
//
// Authorization is intentionally not implemented here: callers reach this
// actor only after the existing task/tool/permission boundary has approved the
// operation. Leases are concurrency guards, not user consent, and there is no
// second approval service.

import Foundation
import FloeCore

public actor MediaPreparedCoordinator {
    public struct Limits: Sendable {
        public var maximumJournalEntries: Int
        public var maximumOperationsPerApply: Int
        public var maximumOperationsPerInstruction: Int
        public var maximumActiveInstructions: Int
        public var retainedFinishedInstructions: Int

        public init(maximumJournalEntries: Int = MediaPreparedSchema.maximumJournalEntries,
                    maximumOperationsPerApply: Int = MediaPreparedSchema.maximumOperationsPerApply,
                    maximumOperationsPerInstruction: Int = 4_096,
                    maximumActiveInstructions: Int = 256,
                    retainedFinishedInstructions: Int = 64) {
            self.maximumJournalEntries = maximumJournalEntries
            self.maximumOperationsPerApply = maximumOperationsPerApply
            self.maximumOperationsPerInstruction = maximumOperationsPerInstruction
            self.maximumActiveInstructions = maximumActiveInstructions
            self.retainedFinishedInstructions = retainedFinishedInstructions
        }
    }

    private struct LeaseKey: Hashable {
        let documentID: UUID
        let ref: MediaPreparedObjectRef
    }

    private struct Run {
        var handle: MediaPreparedInstruction
        var owned: Set<MediaPreparedObjectRef>
        var changes: [MediaPreparedObjectChange]
        var operationIDs: [UUID]
        var operationIDSet: Set<UUID>
        var finished: Bool
        var baseRevision: Int64
        var inputAssetRevisions: [UUID: UInt64]
    }

    private let store: MediaProjectStore
    private let limits: Limits
    private var envelopes: [UUID: MediaProject] = [:]
    private var leases: [LeaseKey: UUID] = [:]
    private var runs: [UUID: Run] = [:]
    private var processedOperations: [UUID: Set<UUID>] = [:]
    // Actor isolation does not serialize across store awaits. Hold a document
    // gate through each durable operation; unrelated documents remain free.
    private var activeDocuments: Set<UUID> = []
    private var documentWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    private func acquireDocument(_ id: UUID) async {
        if activeDocuments.insert(id).inserted { return }
        await withCheckedContinuation { documentWaiters[id, default: []].append($0) }
    }

    private func releaseDocument(_ id: UUID) {
        if var waiters = documentWaiters[id], !waiters.isEmpty {
            let next = waiters.removeFirst()
            documentWaiters[id] = waiters.isEmpty ? nil : waiters
            next.resume()
        } else {
            activeDocuments.remove(id)
        }
    }

    public init(store: MediaProjectStore, limits: Limits = Limits()) {
        self.store = store
        self.limits = limits
    }

    // MARK: Loading

    /// Loads a prepared document. A v1 document is NOT upgraded implicitly:
    /// callers must ask for `upgradeDocument(id:)` explicitly.
    public func loadDocument(id: UUID) async throws -> MediaPreparedDocument {
        await acquireDocument(id)
        defer { releaseDocument(id) }
        let project = try await envelope(for: id)
        guard let prepared = project.prepared else {
            throw MediaPreparedCoreError.notPrepared(id)
        }
        return prepared
    }

    /// Drops the in-memory cache and re-reads the document from the store.
    public func reloadDocument(id: UUID) async throws -> MediaPreparedDocument {
        await acquireDocument(id)
        defer { releaseDocument(id) }
        envelopes.removeValue(forKey: id)
        processedOperations.removeValue(forKey: id)
        let project = try await envelope(for: id)
        guard let prepared = project.prepared else {
            throw MediaPreparedCoreError.notPrepared(id)
        }
        return prepared
    }

    public func descriptor(id: UUID) async throws -> MediaPreparedDocumentDescriptor {
        try await loadDocument(id: id).descriptor
    }

    /// Explicit v1 -> v2 upgrade. The upgrade is one durable transaction with
    /// compare-and-swap; a concurrent write refuses instead of overwriting.
    @discardableResult
    public func upgradeDocument(id: UUID) async throws -> MediaPreparedDocument {
        await acquireDocument(id)
        defer { releaseDocument(id) }
        guard let project = try await store.loadProject(id: id) else {
            throw MediaPreparedCoreError.documentNotFound(id)
        }
        if let prepared = project.prepared {
            try MediaPreparedIntegrity.validateEnvelope(project)
            envelopes[id] = project
            processedOperations[id] = (project.preparedJournal ?? .init()).operationIDs
            return prepared
        }
        let upgraded = try MediaPreparedUpgrade.upgrade(project)
        try MediaPreparedIntegrity.validateEnvelope(upgraded)
        try await store.save(upgraded, expectedRevision: project.revision)
        envelopes[id] = upgraded
        processedOperations[id] = []
        guard let prepared = upgraded.prepared else {
            throw MediaPreparedCoreError.invalidDocument("upgrade produced no prepared document")
        }
        return prepared
    }

    private func envelope(for documentID: UUID) async throws -> MediaProject {
        if let cached = envelopes[documentID] { return cached }
        guard let project = try await store.loadProject(id: documentID) else {
            throw MediaPreparedCoreError.documentNotFound(documentID)
        }
        guard project.prepared != nil else {
            throw MediaPreparedCoreError.notPrepared(documentID)
        }
        try MediaPreparedIntegrity.validateEnvelope(project)
        envelopes[documentID] = project
        processedOperations[documentID] = (project.preparedJournal ?? .init()).operationIDs
        return project
    }

    // MARK: Instruction lifecycle

    /// Acquires every requested object lease or none. A model instruction
    /// refuses locked targets; a user instruction may lease a locked target so
    /// a subsequent explicit unlock flag change is possible (content edits on
    /// a locked object are still refused by the engine).
    public func beginInstruction(documentID: UUID,
                                 targets: Set<MediaPreparedObjectRef>,
                                 actor: MediaPreparedActorKind = .model,
                                 groupID: UUID = UUID()) async throws -> MediaPreparedInstruction {
        await acquireDocument(documentID)
        defer { releaseDocument(documentID) }
        let project = try await envelope(for: documentID)
        guard let document = project.prepared else {
            throw MediaPreparedCoreError.notPrepared(documentID)
        }
        guard runs.values.filter({ !$0.finished }).count < limits.maximumActiveInstructions else {
            throw MediaPreparedCoreError.limitsExceeded("too many active instructions")
        }
        guard runs[groupID] == nil,
              (project.preparedJournal ?? .init()).entry(groupID) == nil else {
            throw MediaPreparedCoreError.invalidOperation("instruction id was already used")
        }

        for target in targets {
            guard let state = state(of: target, in: document) else {
                throw MediaPreparedCoreError.unknownObject(target)
            }
            if actor == .model {
                switch state {
                case .asset, .captionStyle: break
                case .layer(let layer):
                    if layer.isLocked { throw MediaPreparedCoreError.lockedObject(target) }
                case .track(let metadata):
                    if metadata.isLocked { throw MediaPreparedCoreError.lockedObject(target) }
                case .clip(let trackID, _):
                    guard let track = document.trackGraph.track(trackID) else {
                        throw MediaPreparedCoreError.unknownObject(target)
                    }
                    if track.isLocked {
                        throw MediaPreparedCoreError.lockedObject(
                            .init(kind: .track, id: trackID))
                    }
                }
            }
            if let owner = leases[LeaseKey(documentID: documentID, ref: target)],
               owner != groupID {
                throw MediaPreparedCoreError.busyObject(target)
            }
        }

        // All checks passed: acquire atomically.
        for target in targets {
            leases[LeaseKey(documentID: documentID, ref: target)] = groupID
        }
        // Reading an asset does not take an exclusive write lease. Capture
        // its generation instead: a source update may proceed, while a later
        // callback based on old pixels must refuse rather than paint over it.
        var assetIDs = Set<UUID>()
        for target in targets {
            switch target.kind {
            case .captionStyle: break
            case .asset: assetIDs.insert(target.id)
            case .layer:
                if let layer = document.layer(target.id), case .raster(let raster) = layer.content,
                   case .asset(let id) = raster.source { assetIDs.insert(id) }
            case .clip:
                if let id = document.trackGraph.clip(id: target.id)?.clip.assetID { assetIDs.insert(id) }
            case .track:
                for clip in document.trackGraph.track(target.id)?.clips ?? [] {
                    if let id = clip.assetID { assetIDs.insert(id) }
                }
            }
        }
        let inputAssetRevisions = Dictionary(uniqueKeysWithValues: assetIDs.map {
            ($0, document.assetRevisions?[$0] ?? 0)
        })
        let handle = MediaPreparedInstruction(id: groupID, documentID: documentID,
                                              actor: actor, targets: targets)
        runs[groupID] = Run(handle: handle, owned: targets, changes: [],
                            operationIDs: [], operationIDSet: [], finished: false,
                            baseRevision: project.revision, inputAssetRevisions: inputAssetRevisions)
        return handle
    }

    /// Applies and persists one batch as part of the instruction's edit group.
    /// The document and journal are saved together with an expected revision;
    /// a failed validation or a stale store write leaves the durable document
    /// untouched.
    @discardableResult
    public func apply(_ operations: [MediaPreparedOperation],
                      instruction: MediaPreparedInstruction) async throws -> MediaPreparedCommit {
        await acquireDocument(instruction.documentID)
        defer { releaseDocument(instruction.documentID) }
        try Task.checkCancellation()
        guard var run = runs[instruction.id], run.handle == instruction else {
            throw MediaPreparedCoreError.unknownInstruction(instruction.id)
        }
        guard !run.finished else {
            throw MediaPreparedCoreError.instructionFinished(instruction.id)
        }
        guard operations.count <= limits.maximumOperationsPerApply else {
            throw MediaPreparedCoreError.limitsExceeded(
                "at most \(limits.maximumOperationsPerApply) operations per apply")
        }
        guard run.operationIDs.count + operations.count
                <= limits.maximumOperationsPerInstruction else {
            throw MediaPreparedCoreError.limitsExceeded(
                "instruction operation count exceeds \(limits.maximumOperationsPerInstruction)")
        }

        var batchIDs = Set<UUID>()
        for operation in operations {
            guard batchIDs.insert(operation.id).inserted else {
                throw MediaPreparedCoreError.duplicateOperation(operation.id)
            }
            guard !run.operationIDSet.contains(operation.id),
                  processedOperations[run.handle.documentID]?.contains(operation.id) != true else {
                throw MediaPreparedCoreError.duplicateOperation(operation.id)
            }
        }

        let project = try await envelope(for: run.handle.documentID)
        guard var prepared = project.prepared else {
            throw MediaPreparedCoreError.notPrepared(run.handle.documentID)
        }
        for (assetID, generation) in run.inputAssetRevisions {
            guard prepared.asset(assetID) != nil,
                  (prepared.assetRevisions?[assetID] ?? 0) == generation else {
                throw MediaPreparedCoreError.staleObject(.init(kind: .asset, id: assetID))
            }
        }
        let mutation = try MediaPreparedEngine.apply(operations, to: &prepared)
        guard !mutation.isEmpty else {
            return MediaPreparedCommit(groupID: run.handle.id,
                                       documentID: run.handle.documentID,
                                       revision: project.revision, touched: [],
                                       created: [], deleted: [], operationCount: 0)
        }

        var created: [MediaPreparedObjectRef] = []
        var deleted: [MediaPreparedObjectRef] = []
        for change in mutation.changes {
            if change.before == nil {
                if leases[LeaseKey(documentID: run.handle.documentID, ref: change.ref)] != nil {
                    throw MediaPreparedCoreError.busyObject(change.ref)
                }
                created.append(change.ref)
            } else {
                guard run.owned.contains(change.ref) else {
                    throw MediaPreparedCoreError.objectNotOwned(change.ref)
                }
                guard leases[LeaseKey(documentID: run.handle.documentID,
                                      ref: change.ref)] == run.handle.id else {
                    throw MediaPreparedCoreError.busyObject(change.ref)
                }
                if change.after == nil { deleted.append(change.ref) }
            }
        }

        var merged = run.changes
        for change in mutation.changes { merge(change, into: &merged) }
        merged.removeAll(where: MediaPreparedEngine.isNetNoOp)
        let operationIDs = run.operationIDs + operations.map(\.id)
        let operationIDSet = run.operationIDSet.union(batchIDs)
        let now = Date()
        let entry = MediaPreparedJournalEntry(
            id: run.handle.id,
            documentID: run.handle.documentID,
            actor: run.handle.actor,
            operationIDs: operationIDs,
            changes: merged,
            status: .committed,
            baseRevision: run.baseRevision,
            committedRevision: prepared.revision,
            startedAt: run.handle.startedAt,
            committedAt: now)

        var journal = project.preparedJournal ?? MediaPreparedJournal()
        if merged.isEmpty {
            // The group's net effect vanished (for example a created object
            // was removed again); there is nothing to undo.
            journal.entries.removeAll { $0.id == run.handle.id }
        } else {
            journal.upsert(entry)
        }
        let activeGroups = Set(runs.values.filter { !$0.finished }.map(\.handle.id))
        journal.trim(maximumEntries: limits.maximumJournalEntries,
                     preserving: activeGroups)

        var draft = project
        draft.prepared = prepared
        draft.preparedJournal = journal
        draft.revision = prepared.revision
        draft.updatedAt = now
        do {
            try await store.save(draft, expectedRevision: project.revision)
        } catch {
            // The durable state is authoritative; force a fresh read next time.
            envelopes.removeValue(forKey: run.handle.documentID)
            processedOperations.removeValue(forKey: run.handle.documentID)
            throw error
        }

        envelopes[run.handle.documentID] = draft
        run.changes = merged
        run.operationIDs = operationIDs
        run.operationIDSet = operationIDSet
        run.owned.formUnion(created)
        for change in mutation.changes where change.ref.kind == .asset {
            run.inputAssetRevisions[change.ref.id] = prepared.assetRevisions?[change.ref.id] ?? 0
        }
        for ref in created {
            leases[LeaseKey(documentID: run.handle.documentID, ref: ref)] = run.handle.id
        }
        runs[run.handle.id] = run
        processedOperations[run.handle.documentID, default: []].formUnion(batchIDs)
        return MediaPreparedCommit(groupID: run.handle.id,
                                   documentID: run.handle.documentID,
                                   revision: prepared.revision,
                                   touched: mutation.changes.map(\.ref),
                                   created: created, deleted: deleted,
                                   operationCount: operations.count)
    }

    /// Stops/fails one instruction: committed steps stay durable and undoable,
    /// only leases owned by this instruction are released, and later applies
    /// are fenced. Repeated stop is idempotent cleanup.
    public func stop(_ instruction: MediaPreparedInstruction) async throws {
        // Wait for an already admitted atomic commit before acknowledging stop.
        // No pending apply can revive the finished run after this returns.
        await acquireDocument(instruction.documentID)
        defer { releaseDocument(instruction.documentID) }
        guard var run = runs[instruction.id], run.handle == instruction else {
            throw MediaPreparedCoreError.unknownInstruction(instruction.id)
        }
        guard !run.finished else { return }
        run.finished = true
        runs[instruction.id] = run
        releaseLeases(documentID: run.handle.documentID, owned: run.owned,
                      groupID: run.handle.id)
        pruneFinishedRuns()
    }

    /// User/direct commit without an explicit begin. It derives the touched
    /// object set, takes temporary leases, applies one batch and stops, so the
    /// same journal/undo/lease contract covers UI edits and model edits.
    @discardableResult
    public func applyUserOperations(_ operations: [MediaPreparedOperation],
                                    to documentID: UUID,
                                    groupID: UUID = UUID(),
                                    actor: MediaPreparedActorKind = .user) async throws -> MediaPreparedCommit {
        let targets = try await targets(of: operations, in: documentID)
        let instruction = try await beginInstruction(documentID: documentID,
                                                     targets: targets,
                                                     actor: actor,
                                                     groupID: groupID)
        do {
            let commit = try await apply(operations, instruction: instruction)
            try await stop(instruction)
            return commit
        } catch {
            try? await stop(instruction)
            throw error
        }
    }

    // MARK: Undo

    /// Undoes exactly the recorded objects of one committed group. Every
    /// validation runs before the first mutation; later edits to a DIFFERENT
    /// object survive, a later edit to a TOUCHED object refuses the whole undo.
    @discardableResult
    public func undoGroup(_ groupID: UUID, in documentID: UUID) async throws -> MediaPreparedCommit {
        await acquireDocument(documentID)
        defer { releaseDocument(documentID) }
        try Task.checkCancellation()
        let project = try await envelope(for: documentID)
        guard var prepared = project.prepared else {
            throw MediaPreparedCoreError.notPrepared(documentID)
        }
        var journal = project.preparedJournal ?? MediaPreparedJournal()
        guard let entry = journal.entry(groupID) else {
            throw MediaPreparedCoreError.unknownGroup(groupID)
        }
        guard entry.status == .committed else {
            throw MediaPreparedCoreError.groupAlreadyUndone(groupID)
        }
        if let run = runs[groupID], !run.finished {
            throw MediaPreparedCoreError.instructionStillRunning(groupID)
        }
        for change in entry.changes {
            if let owner = leases[LeaseKey(documentID: documentID, ref: change.ref)],
               owner != groupID {
                throw MediaPreparedCoreError.busyObject(change.ref)
            }
        }

        try MediaPreparedEngine.undo(entry, in: &prepared)
        guard journal.markUndone(groupID) else {
            throw MediaPreparedCoreError.groupAlreadyUndone(groupID)
        }
        let now = Date()
        var draft = project
        draft.prepared = prepared
        draft.preparedJournal = journal
        draft.revision = prepared.revision
        draft.updatedAt = now
        do {
            try await store.save(draft, expectedRevision: project.revision)
        } catch {
            envelopes.removeValue(forKey: documentID)
            processedOperations.removeValue(forKey: documentID)
            throw error
        }
        envelopes[documentID] = draft
        runs.removeValue(forKey: groupID)
        return MediaPreparedCommit(groupID: groupID, documentID: documentID,
                                   revision: prepared.revision,
                                   touched: entry.changes.map(\.ref),
                                   created: entry.changes.filter { $0.before == nil }.map(\.ref),
                                   deleted: entry.changes.filter { $0.after == nil }.map(\.ref),
                                   operationCount: 0)
    }

    // MARK: State helpers

    private func state(of ref: MediaPreparedObjectRef,
                       in document: MediaPreparedDocument) -> MediaPreparedObjectState? {
        switch ref.kind {
        case .captionStyle:
            guard ref.id == document.id, document.kind == .video else { return nil }
            return .captionStyle(.init(style: document.trackGraph.captionStyle, revision: document.trackGraph.captionStyleRevision ?? 0))
        case .asset:
            return document.asset(ref.id).map { .asset(.init(reference: $0, revision: document.assetRevisions?[ref.id] ?? 0)) }
        case .layer:
            return document.layer(ref.id).map(MediaPreparedObjectState.layer)
        case .track:
            return document.trackGraph.track(ref.id).map { .track($0.metadata) }
        case .clip:
            if let match = document.trackGraph.clip(id: ref.id) {
                return .clip(trackID: match.track.id, clip: match.clip)
            }
            return nil
        }
    }

    private func targets(of operations: [MediaPreparedOperation],
                         in documentID: UUID) async throws -> Set<MediaPreparedObjectRef> {
        let project = try await envelope(for: documentID)
        guard let document = project.prepared else {
            throw MediaPreparedCoreError.notPrepared(documentID)
        }
        var refs = Set<MediaPreparedObjectRef>()
        // A parent/track created earlier in this atomic batch has no stored
        // object to lease yet. The engine still validates creation order,
        // duplicates, locks and revisions before any store mutation.
        var created = Set<MediaPreparedObjectRef>()
        func target(_ kind: MediaPreparedObjectKind, _ id: UUID) {
            let ref = MediaPreparedObjectRef(kind: kind, id: id)
            if !created.contains(ref) { refs.insert(ref) }
        }
        func introduced(_ kind: MediaPreparedObjectKind, _ id: UUID) {
            let ref = MediaPreparedObjectRef(kind: kind, id: id)
            if state(of: ref, in: document) == nil { created.insert(ref) }
        }
        for operation in operations {
            switch operation.action {
            case .setCaptionStyle: target(.captionStyle, document.id)
            case .insertAsset(let asset): introduced(.asset, asset.id)
            case .replaceAsset(let expected, _, _): target(.asset, expected.id)
            case .insertLayer(let layer, let parentID, _):
                if let parentID { target(.layer, parentID) }
                introduced(.layer, layer.id)
            case .removeLayer(let id, _),
                 .replaceLayerContent(let id, _, _),
                 .updateLayerTransform(let id, _, _),
                 .updateLayerAdjustment(let id, _, _),
                 .updateLayerFlags(let id, _, _, _, _, _),
                 .setLayerMask(let id, _, _),
                 .setLayerClip(let id, _, _):
                target(.layer, id)
            case .moveLayer(let id, _, let parentID, _):
                target(.layer, id)
                if let parentID { target(.layer, parentID) }
            case .insertTrack(let track, _):
                introduced(.track, track.id)
                for clip in track.clips { introduced(.clip, clip.id) }
            case .removeTrack(let id, _), .updateTrackFlags(let id, _, _, _, _, _):
                target(.track, id)
            case .insertClip(let trackID, let clip, _):
                target(.track, trackID); introduced(.clip, clip.id)
            case .removeClip(let trackID, let clipID, _),
                 .replaceClip(let trackID, let clipID, _, _),
                 .replaceClipKeyframes(let trackID, let clipID, _, _),
                 .updateClipRange(let trackID, let clipID, _, _, _):
                target(.track, trackID); target(.clip, clipID)
            }
        }
        // Do not silently drop an unknown target from a direct user commit.
        for ref in refs where state(of: ref, in: document) == nil {
            throw MediaPreparedCoreError.unknownObject(ref)
        }
        return refs
    }

    private func releaseLeases(documentID: UUID, owned: Set<MediaPreparedObjectRef>,
                               groupID: UUID) {
        for ref in owned {
            let key = LeaseKey(documentID: documentID, ref: ref)
            if leases[key] == groupID { leases.removeValue(forKey: key) }
        }
    }

    private func pruneFinishedRuns() {
        let finished = runs.values.filter(\.finished)
        guard finished.count > limits.retainedFinishedInstructions else { return }
        let excess = finished.count - limits.retainedFinishedInstructions
        let oldest = finished.sorted { $0.handle.startedAt < $1.handle.startedAt }.prefix(excess)
        for run in oldest { runs.removeValue(forKey: run.handle.id) }
    }

    private func merge(_ change: MediaPreparedObjectChange,
                       into changes: inout [MediaPreparedObjectChange]) {
        if let index = changes.firstIndex(where: { $0.ref == change.ref }) {
            // Preserve the group's original `before` (nil = created by this
            // group); only the latest `after` matters.
            changes[index].after = change.after
            if changes[index].position == nil { changes[index].position = change.position }
            if changes[index].containerID == nil { changes[index].containerID = change.containerID }
        } else {
            changes.append(change)
        }
    }
}
