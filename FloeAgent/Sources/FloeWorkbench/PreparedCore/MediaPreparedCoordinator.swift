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

    private let compoundScope: MediaPreparedCompoundCoordinatorScope?
    var compoundRuns: [UUID: MediaPreparedCompoundScopedRun] = [:]
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
        self.compoundScope = nil
    }


    private init(store:MediaProjectStore,limits:Limits,scope:MediaPreparedCompoundCoordinatorScope) {
        self.store=store;self.limits=limits;self.compoundScope=scope
    }
    public func scopedToCompound(_ clipID:UUID,in documentID:UUID) async throws -> MediaPreparedCoordinator {
        guard compoundScope == nil else { throw MediaPreparedCoreError.invalidOperation("nested compounds are not supported") }
        let document=try await loadDocument(id:documentID)
        _ = try MediaPreparedCompounds.source(clipID:clipID,in:document)
        return MediaPreparedCoordinator(store:store,limits:limits,scope:.init(root:self,documentID:documentID,clipID:clipID))
    }
    public func loadProjectSnapshot(id:UUID,reload:Bool=false) async throws -> MediaProject {
        if let scope=compoundScope { return try await compoundProject(scope:scope,id:id,reload:reload) }
        if reload { _ = try await reloadDocument(id:id) }
        await acquireDocument(id);defer { releaseDocument(id) }
        return try await envelope(for:id)
    }

    // MARK: Loading

    /// Loads a prepared document. A v1 document is NOT upgraded implicitly:
    /// callers must ask for `upgradeDocument(id:)` explicitly.
    public func loadDocument(id: UUID) async throws -> MediaPreparedDocument {
        if let scope=compoundScope { return try await compoundProject(scope:scope,id:id,reload:false).prepared! }
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
        if let scope=compoundScope { return try await compoundProject(scope:scope,id:id,reload:true).prepared! }
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
        if let scope=compoundScope { return try await compoundProject(scope:scope,id:id,reload:false).prepared! }
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
                                 groupID: UUID = UUID(),
                                 inputAssetIDs: Set<UUID> = []) async throws -> MediaPreparedInstruction {
        if let scope=compoundScope { return try await beginCompound(scope:scope,documentID:documentID,targets:targets,actor:actor,groupID:groupID) }
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
                case .asset, .captionStyle, .canvas: break
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
        var assetIDs = inputAssetIDs
        guard assetIDs.allSatisfy({document.asset($0) != nil}) else { throw MediaPreparedCoreError.invalidOperation("instruction source asset is missing") }
        for target in targets {
            switch target.kind {
            case .captionStyle, .canvas: break
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
        if let scope=compoundScope { return try await applyCompound(scope:scope,operations:operations,instruction:instruction) }
        await acquireDocument(instruction.documentID)
        defer { releaseDocument(instruction.documentID) }
        try Task.checkCancellation()
        guard var run = runs[instruction.id], run.handle == instruction else {
            throw MediaPreparedCoreError.unknownInstruction(instruction.id)
        }
        guard !run.finished else {
            throw MediaPreparedCoreError.instructionFinished(instruction.id)
        }
        let replayIDs=try MediaPreparedCompounds.operationIDs(operations)
        guard replayIDs.count <= limits.maximumOperationsPerApply else {
            throw MediaPreparedCoreError.limitsExceeded(
                "at most \(limits.maximumOperationsPerApply) operations per apply")
        }
        guard run.operationIDs.count + replayIDs.count
                <= limits.maximumOperationsPerInstruction else {
            throw MediaPreparedCoreError.limitsExceeded(
                "instruction operation count exceeds \(limits.maximumOperationsPerInstruction)")
        }

        var batchIDs = Set<UUID>()
        for id in replayIDs {
            guard batchIDs.insert(id).inserted,!run.operationIDSet.contains(id),processedOperations[run.handle.documentID]?.contains(id) != true else { throw MediaPreparedCoreError.duplicateOperation(id) }
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
        if instruction.actor == .model { try MediaPreparedCompounds.validateModelInnerEdits(operations,in:prepared) }
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
        let operationIDs = run.operationIDs + replayIDs
        let operationIDSet = run.operationIDSet.union(batchIDs)
        let now = Date()
        var entry = MediaPreparedJournalEntry(
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

        let scopes=Set(operations.compactMap { op -> UUID? in if case .editCompound(let id,_,_) = op.action { return id };return nil })
        if scopes.count == 1 { entry.compoundScopeID=scopes.first }
        else if scopes.isEmpty {
            // Updating a verified proxy is part of this source's *canonical*
            // history too. The inner editor can first undo that update, then
            // undo the source edit; it never forks or bypasses the root undo.
            let refreshed=try mutation.changes.compactMap { change -> UUID? in
                guard case .clip(_,let before)?=change.before,case .clip(_,let after)?=change.after,
                      let old=before.compound,let next=after.compound,old.proxy.video.id != next.proxy.video.id,
                      try MediaPreparedCompounds.sourceSignature(old.source) == MediaPreparedCompounds.sourceSignature(next.source) else { return nil }
                return after.id
            }
            if Set(refreshed).count == 1 { entry.compoundScopeID=refreshed.first }
        }
        var journal = project.preparedJournal ?? MediaPreparedJournal()
        if merged.isEmpty {
            // The group's net effect vanished (for example a created object
            // was removed again); there is nothing to undo.
            journal.entries.removeAll { $0.id == run.handle.id }
        } else {
            journal.upsert(entry)
        }
        let activeGroups = Set(runs.values.filter { !$0.finished }.map(\.handle.id))
        journal.discardRedo(preserving: activeGroups)
        journal.trim(maximumEntries: limits.maximumJournalEntries,
                     preserving: activeGroups)

        var draft = project
        draft.prepared = prepared
        draft.schemaVersion = max(draft.schemaVersion,prepared.schemaVersion)
        draft.canvas = prepared.canvas
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
        if let scope=compoundScope { try await stopCompound(scope:scope,instruction:instruction);return }
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
        if let scope=compoundScope { return try await userCompound(scope:scope,operations:operations,documentID:documentID,groupID:groupID,actor:actor) }
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
        if let scope=compoundScope { return try await undoCompound(scope:scope,groupID:groupID,documentID:documentID,redo:false) }
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

        let beforeUndo = prepared
        try MediaPreparedEngine.undo(entry, in: &prepared)
        guard journal.markUndone(groupID) else {
            throw MediaPreparedCoreError.groupAlreadyUndone(groupID)
        }
        var undoneEntry = entry
        undoneEntry.status = .undone
        undoneEntry.redoChanges = MediaPreparedEngine.inverseChanges(entry.changes, before: beforeUndo, after: prepared)
        undoneEntry.undoneRevision = prepared.revision
        journal.upsert(undoneEntry)
        journal.rebaseUndoBoundary(changed: Set(entry.touched), document: prepared, excluding: groupID)
        let now = Date()
        var draft = project
        draft.prepared = prepared
        draft.schemaVersion = max(draft.schemaVersion,prepared.schemaVersion)
        draft.canvas = prepared.canvas
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

    /// Replays the most recently undone group against exact post-undo object
    /// generations. The forward content, branch and CAS are durable together.
    @discardableResult
    public func redoGroup(_ groupID: UUID, in documentID: UUID) async throws -> MediaPreparedCommit {
        if let scope=compoundScope { return try await undoCompound(scope:scope,groupID:groupID,documentID:documentID,redo:true) }
        await acquireDocument(documentID)
        defer { releaseDocument(documentID) }
        try Task.checkCancellation()
        let project = try await envelope(for: documentID)
        guard var prepared = project.prepared else { throw MediaPreparedCoreError.notPrepared(documentID) }
        var journal = project.preparedJournal ?? .init()
        guard var entry = journal.entry(groupID) else { throw MediaPreparedCoreError.unknownGroup(groupID) }
        guard entry.status == .undone, let changes = entry.redoChanges,
              journal.nextRedo?.id == groupID else {
            throw MediaPreparedCoreError.conflict("redo is unavailable or a newer undo must be redone first")
        }
        for change in changes {
            if let owner = leases[LeaseKey(documentID: documentID, ref: change.ref)], owner != groupID {
                throw MediaPreparedCoreError.busyObject(change.ref)
            }
        }
        var forward = entry; forward.status = .committed; forward.changes = changes
        try MediaPreparedEngine.undo(forward, in: &prepared)
        for index in entry.changes.indices {
            entry.changes[index].after = MediaPreparedEngine.currentState(of: entry.changes[index].ref, in: prepared)
        }
        entry.status = .committed; entry.committedRevision = prepared.revision
        entry.committedAt = Date(); entry.redoChanges = nil; entry.undoneRevision = nil
        journal.upsert(entry)
        journal.rebaseRedoBoundary(changed: Set(entry.touched), document: prepared, excluding: groupID)
        var draft = project; draft.prepared = prepared; draft.canvas = prepared.canvas; draft.preparedJournal = journal
        draft.revision = prepared.revision; draft.updatedAt = Date()
        do { try await store.save(draft, expectedRevision: project.revision) }
        catch { envelopes.removeValue(forKey: documentID); processedOperations.removeValue(forKey: documentID); throw error }
        envelopes[documentID] = draft
        return .init(groupID: groupID, documentID: documentID, revision: prepared.revision,
                     touched: entry.touched, created: entry.changes.filter { $0.before == nil }.map(\.ref),
                     deleted: entry.changes.filter { $0.after == nil }.map(\.ref), operationCount: 0)
    }

    // MARK: State helpers

    private func state(of ref: MediaPreparedObjectRef,
                       in document: MediaPreparedDocument) -> MediaPreparedObjectState? {
        switch ref.kind {
        case .canvas:
            guard ref.id == document.id else { return nil }
            return .canvas(.init(canvas:document.canvas,revision:document.canvasRevision ?? 0))
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
            case .editCompound(let id,_,let inner):
                guard let located=document.trackGraph.clip(id:id),located.clip.compound != nil else { throw MediaPreparedCoreError.unknownObject(.init(kind:.clip,id:id)) }
                target(.track,located.track.id);target(.clip,id)
                for edit in inner { if case .replaceAsset(let asset,_,_)=edit.action { target(.asset,asset.id) } }
            case .layoutCanvas:
                target(.canvas,document.id)
                for layer in document.layers where layer.parentID == nil { target(.layer,layer.id) }
            case .setVideoColorProfile: target(.canvas,document.id)
            case .setLayerCanvasSpace(let id,_,_): target(.layer,id)
            case .setCaptionStyle: target(.captionStyle, document.id)
            case .insertAsset(let asset): introduced(.asset, asset.id)
            case .replaceAsset(let expected, _, _), .removeAsset(let expected, _): target(.asset, expected.id)
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
