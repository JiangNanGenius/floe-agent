// FloeWorkbench — PreparedCore: per-object journal and transaction engine.
//
// An edit group is one AI instruction (or one direct user commit). The journal
// records, for every touched object, its before/after snapshot and revision.
// Undo applies only those inverses: disjoint later edits survive, while a
// later edit to the SAME object refuses the whole undo atomically. The journal
// and document content are written together by `MediaProjectStore` with an
// expected revision; this file never persists anything itself.

import Foundation
import FloeCore

// MARK: - Track metadata snapshot

/// Track snapshot WITHOUT clips. Clip edits are journaled as their own objects
/// so undoing one clip can never overwrite a later edit to a sibling clip.
public struct MediaPreparedTrackMetadata: Sendable, Codable, Hashable {
    public var id: UUID
    public var kind: MediaPreparedTrackKind
    public var name: String
    public var isMuted: Bool
    public var isLocked: Bool
    public var volume: Double
    public var revision: UInt64

    public init(id: UUID, kind: MediaPreparedTrackKind, name: String,
                isMuted: Bool, isLocked: Bool, volume: Double, revision: UInt64) {
        self.id = id
        self.kind = kind
        self.name = name
        self.isMuted = isMuted
        self.isLocked = isLocked
        self.volume = volume
        self.revision = revision
    }
}

public extension MediaPreparedTrack {
    var metadata: MediaPreparedTrackMetadata {
        MediaPreparedTrackMetadata(id: id, kind: kind, name: name, isMuted: isMuted,
                                   isLocked: isLocked, volume: volume, revision: revision)
    }

    mutating func apply(_ metadata: MediaPreparedTrackMetadata) {
        kind = metadata.kind
        name = metadata.name
        isMuted = metadata.isMuted
        isLocked = metadata.isLocked
        volume = metadata.volume
        revision = metadata.revision
    }
}

// MARK: - Object state / changes

public struct MediaPreparedAssetState: Sendable, Codable, Hashable {
    public var reference: MediaAssetReference
    public var revision: UInt64
    public init(reference: MediaAssetReference, revision: UInt64) {
        self.reference = reference; self.revision = revision
    }
}

public struct MediaPreparedCaptionStyleState: Sendable, Codable, Hashable {
    public var style: CaptionStyle?
    public var revision: UInt64
    public init(style: CaptionStyle?, revision: UInt64) { self.style = style; self.revision = revision }
}

public struct MediaPreparedCanvasState: Sendable,Codable,Hashable {
    public var canvas:MediaCanvas?
    public var revision:UInt64
    public init(canvas:MediaCanvas?,revision:UInt64) { self.canvas=canvas;self.revision=revision }
}
public enum MediaPreparedObjectState: Sendable, Codable, Hashable {
    case canvas(MediaPreparedCanvasState)
    case captionStyle(MediaPreparedCaptionStyleState)
    case asset(MediaPreparedAssetState)
    case layer(MediaPreparedLayer)
    case track(MediaPreparedTrackMetadata)
    case clip(trackID: UUID, clip: MediaPreparedClip)
}

public struct MediaPreparedObjectChange: Sendable, Codable, Hashable {
    public var ref: MediaPreparedObjectRef
    /// Track ID for clips; parent group ID for a layer insertion/move.
    public var containerID: UUID?
    /// Array index at the time of the first touch (used to restore a deletion).
    public var position: Int?
    /// nil means the group created this object.
    public var before: MediaPreparedObjectState?
    /// nil means the group deleted this object.
    public var after: MediaPreparedObjectState?

    public init(ref: MediaPreparedObjectRef, containerID: UUID? = nil,
                position: Int? = nil, before: MediaPreparedObjectState?,
                after: MediaPreparedObjectState?) {
        self.ref = ref
        self.containerID = containerID
        self.position = position
        self.before = before
        self.after = after
    }
}

// MARK: - Journal

public enum MediaPreparedJournalStatus: String, Sendable, Codable, Hashable {
    case committed
    case undone
    case discarded
}

/// Durable record of one edit group. `operationIDs` is the replay/dedupe set;
/// `changes` is the per-object inverse. `baseRevision` is the document
/// revision before the first apply, `committedRevision` the latest persisted
/// revision after an apply.
public struct MediaPreparedJournalEntry: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var documentID: UUID
    public var actor: MediaPreparedActorKind
    public var operationIDs: [UUID]
    public var changes: [MediaPreparedObjectChange]
    public var status: MediaPreparedJournalStatus
    public var baseRevision: Int64
    public var committedRevision: Int64
    public var startedAt: Date
    public var committedAt: Date
    /// Exact post-undo generations plus forward restore snapshots. Old journals decode without these fields.
    public var redoChanges: [MediaPreparedObjectChange]?
    public var undoneRevision: Int64?
    /// A projected editor may undo only canonical edits in its own source scope.
    public var compoundScopeID:UUID?

    public init(id: UUID, documentID: UUID, actor: MediaPreparedActorKind,
                operationIDs: [UUID], changes: [MediaPreparedObjectChange],
                status: MediaPreparedJournalStatus, baseRevision: Int64,
                committedRevision: Int64, startedAt: Date, committedAt: Date,
                redoChanges: [MediaPreparedObjectChange]? = nil, undoneRevision: Int64? = nil) {
        self.id = id
        self.documentID = documentID
        self.actor = actor
        self.operationIDs = operationIDs
        self.changes = changes
        self.status = status
        self.baseRevision = baseRevision
        self.committedRevision = committedRevision
        self.startedAt = startedAt
        self.committedAt = committedAt
        self.redoChanges = redoChanges
        self.undoneRevision = undoneRevision
        self.compoundScopeID = nil
    }

    public var touched: [MediaPreparedObjectRef] { changes.map(\.ref) }
}

public struct MediaPreparedJournal: Sendable, Codable, Hashable {
    public var entries: [MediaPreparedJournalEntry]

    public init(entries: [MediaPreparedJournalEntry] = []) {
        self.entries = entries
    }

    public func entry(_ id: UUID) -> MediaPreparedJournalEntry? {
        entries.first { $0.id == id }
    }

    public var nextUndo: MediaPreparedJournalEntry? {
        entries.filter { $0.status == .committed }.max { $0.committedRevision < $1.committedRevision }
    }
    public var nextRedo: MediaPreparedJournalEntry? {
        entries.filter { $0.status == .undone && $0.redoChanges != nil && $0.undoneRevision != nil }
            .max { $0.undoneRevision! < $1.undoneRevision! }
    }
    /// Retain dedupe IDs when a fresh edit abandons the redo branch.
    mutating func discardRedo(preserving active: Set<UUID>) {
        for index in entries.indices where entries[index].status == .undone && !active.contains(entries[index].id) {
            entries[index].status = .discarded; entries[index].redoChanges = nil; entries[index].undoneRevision = nil
        }
    }
    public var operationIDs: Set<UUID> {
        Set(entries.flatMap(\.operationIDs))
    }

    public mutating func upsert(_ entry: MediaPreparedJournalEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    @discardableResult
    public mutating func markUndone(_ id: UUID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].status == .committed else { return false }
        entries[index].status = .undone
        return true
    }

    /// Bounds the durable journal. Active groups are never trimmed; undone
    /// entries are trimmed before committed ones.
    public mutating func trim(maximumEntries: Int, preserving: Set<UUID>) {
        guard maximumEntries > 0 else { entries.removeAll(); return }
        while entries.count > maximumEntries {
            if let index = entries.firstIndex(where: {
                ($0.status == .undone || $0.status == .discarded) && !preserving.contains($0.id)
            }) {
                entries.remove(at: index)
            } else if let index = entries.firstIndex(where: {
                !preserving.contains($0.id)
            }) {
                entries.remove(at: index)
            } else {
                break
            }
        }
    }
}

// MARK: - Mutation / commit results

public struct MediaPreparedMutation: Sendable, Hashable {
    public var documentID: UUID
    public var revision: Int64
    public var changes: [MediaPreparedObjectChange]

    public init(documentID: UUID, revision: Int64, changes: [MediaPreparedObjectChange]) {
        self.documentID = documentID
        self.revision = revision
        self.changes = changes
    }

    public var isEmpty: Bool { changes.isEmpty }
}

public struct MediaPreparedCommit: Sendable, Hashable {
    public var groupID: UUID
    public var documentID: UUID
    public var revision: Int64
    public var touched: [MediaPreparedObjectRef]
    public var created: [MediaPreparedObjectRef]
    public var deleted: [MediaPreparedObjectRef]
    public var operationCount: Int

    public init(groupID: UUID, documentID: UUID, revision: Int64,
                touched: [MediaPreparedObjectRef], created: [MediaPreparedObjectRef],
                deleted: [MediaPreparedObjectRef], operationCount: Int) {
        self.groupID = groupID
        self.documentID = documentID
        self.revision = revision
        self.touched = touched
        self.created = created
        self.deleted = deleted
        self.operationCount = operationCount
    }
}

// MARK: - Engine

public enum MediaPreparedEngine {
    /// Applies one batch atomically to a COPY of the document. Every operation
    /// is validated before the result is assigned; on any failure the passed
    /// document is untouched. A batch advances the document revision at most
    /// once, and only when it actually changes something.
    public static func apply(_ operations: [MediaPreparedOperation],
                             to document: inout MediaPreparedDocument) throws -> MediaPreparedMutation {
        guard !operations.isEmpty else {
            return MediaPreparedMutation(documentID: document.id,
                                         revision: document.revision, changes: [])
        }
        guard operations.count <= MediaPreparedSchema.maximumOperationsPerApply else {
            throw MediaPreparedCoreError.limitsExceeded(
                "at most \(MediaPreparedSchema.maximumOperationsPerApply) operations per apply")
        }
        var operationIDs = Set<UUID>()
        for operation in operations {
            guard operationIDs.insert(operation.id).inserted else {
                throw MediaPreparedCoreError.duplicateOperation(operation.id)
            }
        }

        var draft = document
        var changes: [MediaPreparedObjectChange] = []
        for operation in operations {
            let produced = try apply(operation.action, to: &draft)
            for change in produced {
                merge(change, into: &changes)
            }
        }
        changes.removeAll(where: isNetNoOp)
        guard !changes.isEmpty else {
            return MediaPreparedMutation(documentID: document.id,
                                         revision: document.revision, changes: [])
        }
        if draft.trackGraph.tracks.contains(where: { $0.clips.contains(where: { $0.compound != nil }) }) { draft.schemaVersion = max(3,draft.schemaVersion) }
        draft.revision += 1
        draft.updatedAt = Date()
        try MediaPreparedIntegrity.validate(draft)
        document = draft
        return MediaPreparedMutation(documentID: draft.id, revision: draft.revision,
                                     changes: changes)
    }

    /// Applies the recorded inverses for one committed group. Validation is
    /// complete before any mutation, so a conflict leaves the document
    /// untouched. Disjoint user edits are preserved because only the stored
    /// object refs are restored.
    public static func undo(_ entry: MediaPreparedJournalEntry,
                            in document: inout MediaPreparedDocument) throws {
        guard entry.documentID == document.id else {
            throw MediaPreparedCoreError.invalidOperation(
                "journal entry belongs to a different document")
        }
        guard entry.status == .committed else {
            throw MediaPreparedCoreError.groupAlreadyUndone(entry.id)
        }
        guard !entry.changes.isEmpty else {
            throw MediaPreparedCoreError.invalidOperation("journal entry has no changes to undo")
        }

        let restoresCanvas=entry.changes.contains{$0.ref.kind == .canvas}
        let createdRefs = Set(entry.changes.filter { $0.before == nil }.map(\.ref))
        for change in entry.changes {
            let current = currentState(of: change.ref, in: document)
            switch (change.after, current) {
            case (nil, nil):
                continue
            case (nil, .some(_)):
                throw MediaPreparedCoreError.conflict(
                    "created object \(change.ref.id.uuidString) was not removable; its content changed")
            case (.some(let expected), .some(let actual)):
                guard stateMatches(actual, expected, ref: change.ref) else {
                    if stateKindMatches(actual, expected) {
                        throw MediaPreparedCoreError.staleObject(change.ref)
                    }
                    throw MediaPreparedCoreError.conflict(
                        "object \(change.ref.id.uuidString) (\(change.ref.kind.rawValue)) changed kind")
                }
            case (.some(_), nil):
                throw MediaPreparedCoreError.conflict(
                    "object \(change.ref.id.uuidString) (\(change.ref.kind.rawValue)) is missing")
            }
            if case .layer(let layer) = current, layer.isLocked,
               !isLockTransition(change),!(restoresCanvas && isCanvasLayoutTransition(change)) {
                throw MediaPreparedCoreError.lockedObject(change.ref)
            }
            if case .track(let track) = current, track.isLocked,
               !isTrackLockTransition(change) {
                throw MediaPreparedCoreError.lockedObject(change.ref)
            }
            // Undoing a creation must never delete work added later by another
            // group. Children/clips created by THIS group are removed first.
            if case .layer(let layer) = current, change.before == nil,
               document.layers.contains(where: {
                   $0.parentID == layer.id
                       && !createdRefs.contains(MediaPreparedObjectRef(kind: .layer, id: $0.id))
               }) {
                throw MediaPreparedCoreError.conflict(
                    "group \(layer.id.uuidString) gained children after creation")
            }
            if change.ref.kind == .track, change.before == nil,
               let track = document.trackGraph.tracks.first(where: { $0.id == change.ref.id }),
               track.clips.contains(where: {
                   !createdRefs.contains(MediaPreparedObjectRef(kind: .clip, id: $0.id))
               }) {
                throw MediaPreparedCoreError.conflict(
                    "track \(track.id.uuidString) gained clips after creation")
            }
            if case .layer(let layer) = current, change.after == nil,
               document.layers.contains(where: { $0.parentID == layer.id }) {
                throw MediaPreparedCoreError.conflict(
                    "group \(layer.id.uuidString) gained children after deletion")
            }
            if change.ref.kind == .track, change.after == nil,
               let track = document.trackGraph.tracks.first(where: { $0.id == change.ref.id }),
               !track.clips.isEmpty {
                throw MediaPreparedCoreError.conflict(
                    "track \(track.id.uuidString) gained clips after deletion")
            }
        }

        var draft = document
        // Order restorations by dependency: remove creations newest-first
        // (clips before tracks, children before groups), apply updates, then
        // reinsert deletions oldest-first (parents/tracks before children).
        let created = entry.changes.filter { $0.before == nil }
        let updated = entry.changes.filter { $0.before != nil && $0.after != nil }
        let deleted = entry.changes.filter { $0.after == nil }
        for change in created.reversed() {
            try restore(change, in: &draft)
        }
        for change in updated {
            try restore(change, in: &draft)
        }
        for change in deleted.reversed() {
            try restore(change, in: &draft)
        }
        draft.revision += 1
        draft.updatedAt = Date()
        try MediaPreparedIntegrity.validate(draft)
        document = draft
    }

    // MARK: Action application

    private static func apply(_ action: MediaPreparedAction,
                              to document: inout MediaPreparedDocument) throws -> [MediaPreparedObjectChange] {
        switch action {
        case .editCompound(let clipID,let expectedRevision,let operations):
            let generated = try MediaPreparedCompounds.innerEditOperations(clipID:clipID, expectedRevision:expectedRevision, operations:operations, in:document)
            var result:[MediaPreparedObjectChange]=[]
            for operation in generated {
                for change in try apply(operation.action,to:&document) { merge(change,into:&result) }
            }
            return result
        case .layoutCanvas(let expected,let canvas,let mode):
            guard document.kind == .image,let old=document.canvas else { throw MediaPreparedCoreError.invalidOperation("image canvas required") }
            let ref=MediaPreparedObjectRef(kind:.canvas,id:document.id),revision=document.canvasRevision ?? 0
            try requireRevision(revision,expected,ref:ref)
            try MediaCanvasLayout.validate(canvas)
            guard old != canvas else { return [] }
            guard revision<UInt64.max-1 else { throw MediaPreparedCoreError.limitsExceeded("canvas generation") }
            let mapping=try MediaCanvasLayout.mapping(from:old,to:canvas,mode:mode)
            var changes:[MediaPreparedObjectChange]=[]
            for index in document.layers.indices where document.layers[index].parentID == nil {
                let before=document.layers[index]
                guard before.revision<UInt64.max-1 else { throw MediaPreparedCoreError.limitsExceeded("layer generation") }
                var after=before,space=before.canvasSpace ?? .init(referenceCanvas:old)
                space.transform=mapping.composed(after:space.transform);try space.validate()
                after.canvasSpace=space;after.revision+=1;document.layers[index]=after
                changes.append(.init(ref:.init(kind:.layer,id:before.id),before:.layer(before),after:.layer(after)))
            }
            document.canvas=canvas;document.canvasRevision=revision+1
            changes.append(.init(ref:ref,before:.canvas(.init(canvas:old,revision:revision)),after:.canvas(.init(canvas:canvas,revision:revision+1))))
            return changes
        case .setVideoColorProfile(let expected,let profile):
            guard document.kind == .video, let old = document.canvas else { throw MediaPreparedCoreError.invalidOperation("video color settings require a video canvas") }
            let ref = MediaPreparedObjectRef(kind: .canvas,id: document.id), revision = document.canvasRevision ?? 0
            try requireRevision(revision,expected,ref: ref)
            guard old.videoColorProfile != profile else { return [] }
            guard revision < UInt64.max-1 else { throw MediaPreparedCoreError.limitsExceeded("canvas generation") }
            var next = old;next.videoColorProfile = profile
            document.canvas = next;document.canvasRevision = revision+1
            return [.init(ref: ref,before: .canvas(.init(canvas: old,revision: revision)),after: .canvas(.init(canvas: next,revision: revision+1)))]
        case .setLayerCanvasSpace(let id,let expected,let space):
            guard let index=document.layers.firstIndex(where:{$0.id == id}) else { throw MediaPreparedCoreError.unknownObject(.init(kind:.layer,id:id)) }
            let before=document.layers[index],ref=MediaPreparedObjectRef(kind:.layer,id:id)
            try requireRevision(before.revision,expected,ref:ref)
            guard !before.isLocked else { throw MediaPreparedCoreError.lockedObject(ref) }
            try space?.validate();guard before.canvasSpace != space else { return [] }
            guard before.revision<UInt64.max-1 else { throw MediaPreparedCoreError.limitsExceeded("layer generation") }
            var after=before;after.canvasSpace=space;after.revision+=1;document.layers[index]=after
            return [.init(ref:ref,before:.layer(before),after:.layer(after))]
        case .setCaptionStyle(let expected, let style):
            guard document.kind == .video else {
                throw MediaPreparedCoreError.invalidOperation("caption style requires a video document")
            }
            let ref = MediaPreparedObjectRef(kind: .captionStyle, id: document.id)
            let revision = document.trackGraph.captionStyleRevision ?? 0
            try requireRevision(revision, expected, ref: ref)
            if let style { try MediaPreparedIntegrity.validateCaptionStyle(style) }
            guard document.trackGraph.captionStyle != style else { return [] }
            guard revision < UInt64.max - 1 else { throw MediaPreparedCoreError.limitsExceeded("caption style generation") }
            let before = MediaPreparedCaptionStyleState(style: document.trackGraph.captionStyle, revision: revision)
            document.trackGraph.captionStyle = style
            document.trackGraph.captionStyleRevision = revision + 1
            return [.init(ref: ref, before: .captionStyle(before),
                          after: .captionStyle(.init(style: style, revision: revision + 1)))]
        case .insertAsset(let asset):
            guard document.assets.count < 4_096, document.asset(asset.id) == nil,
                  !asset.relativePath.isEmpty else {
                throw MediaPreparedCoreError.invalidOperation("duplicate, empty or excessive asset reference")
            }
            document.assets.append(asset)
            document.assetRevisions = document.assetRevisions ?? [:]
            document.assetRevisions?[asset.id] = 1
            return [.init(ref: .init(kind: .asset, id: asset.id), position: document.assets.count - 1,
                          before: nil, after: .asset(.init(reference: asset, revision: 1)))]
        case .replaceAsset(let expected, let generation, let replacement):
            let ref = MediaPreparedObjectRef(kind: .asset, id: expected.id)
            guard let index = document.assets.firstIndex(where: { $0.id == expected.id }) else {
                throw MediaPreparedCoreError.unknownObject(ref)
            }
            guard document.assets[index] == expected,
                  (document.assetRevisions?[expected.id] ?? 0) == generation else {
                throw MediaPreparedCoreError.staleObject(ref)
            }
            guard replacement.id == expected.id, replacement.kind == expected.kind,
                  !replacement.relativePath.isEmpty, generation < UInt64.max else {
                throw MediaPreparedCoreError.invalidOperation("asset replacement identity or generation")
            }
            guard replacement != expected else { return [] }
            // Replace references only. Original file bytes are never overwritten.
            document.assets[index] = replacement
            document.assetRevisions = document.assetRevisions ?? [:]
            document.assetRevisions?[expected.id] = generation + 1
            return [.init(ref: ref, before: .asset(.init(reference: expected, revision: generation)),
                          after: .asset(.init(reference: replacement, revision: generation + 1)))]
        case .insertLayer(let layer, let parentID, let index):
            guard document.layers.count < MediaPreparedSchema.maximumLayers else {
                throw MediaPreparedCoreError.limitsExceeded("layer count")
            }
            guard !document.layers.contains(where: { $0.id == layer.id }) else {
                throw MediaPreparedCoreError.invalidOperation("layer \(layer.id.uuidString) already exists")
            }
            guard !layer.isLocked else {
                throw MediaPreparedCoreError.lockedObject(.init(kind: .layer, id: layer.id))
            }
            try validateParent(parentID, for: layer.id, in: document)
            if let parentID, let parent = document.layer(parentID), parent.isLocked {
                throw MediaPreparedCoreError.lockedObject(.init(kind: .layer, id: parentID))
            }
            let position = try resolvedIndex(index, count: document.layers.count)
            var inserted = layer
            inserted.parentID = parentID
            inserted.revision = 1
            document.layers.insert(inserted, at: position)
            return [MediaPreparedObjectChange(
                ref: .init(kind: .layer, id: inserted.id), containerID: parentID,
                position: position, before: nil, after: .layer(inserted))]

        case .removeLayer(let id, let expectedRevision):
            let ref = MediaPreparedObjectRef(kind: .layer, id: id)
            let index = try layerIndex(id, in: document)
            let layer = document.layers[index]
            try requireRevision(layer.revision, expectedRevision, ref: ref)
            try requireUnlockedLayer(layer)
            guard !document.layers.contains(where: { $0.parentID == id }) else {
                throw MediaPreparedCoreError.invalidOperation("remove child layers before their group")
            }
            guard !document.layers.contains(where: { $0.clip?.baseLayerID == id }) else {
                throw MediaPreparedCoreError.invalidOperation("remove or re-clip layers that clip to this layer")
            }
            document.layers.remove(at: index)
            return [MediaPreparedObjectChange(
                ref: ref, containerID: layer.parentID, position: index,
                before: .layer(layer), after: nil)]

        case .replaceLayerContent(let id, let expectedRevision, let content):
            let ref = MediaPreparedObjectRef(kind: .layer, id: id)
            let index = try layerIndex(id, in: document)
            try requireRevision(document.layers[index].revision, expectedRevision, ref: ref)
            try requireUnlockedLayer(document.layers[index])
            let before = document.layers[index]
            var updated = before
            updated.content = content
            guard !sameLayerIgnoringRevision(before, updated) else { return [] }
            updated.revision += 1
            document.layers[index] = updated
            return [MediaPreparedObjectChange(
                ref: ref, containerID: updated.parentID, position: nil,
                before: .layer(before), after: .layer(updated))]

        case .updateLayerTransform(let id, let expectedRevision, let transform):
            let ref = MediaPreparedObjectRef(kind: .layer, id: id)
            let index = try layerIndex(id, in: document)
            try requireRevision(document.layers[index].revision, expectedRevision, ref: ref)
            try requireUnlockedLayer(document.layers[index])
            let before = document.layers[index]
            var updated = before
            updated.transform = transform
            guard !sameLayerIgnoringRevision(before, updated) else { return [] }
            updated.revision += 1
            document.layers[index] = updated
            return [MediaPreparedObjectChange(
                ref: ref, containerID: updated.parentID, position: nil,
                before: .layer(before), after: .layer(updated))]

        case .updateLayerAdjustment(let id, let expectedRevision, let adjustment):
            let ref = MediaPreparedObjectRef(kind: .layer, id: id)
            let index = try layerIndex(id, in: document)
            try requireRevision(document.layers[index].revision, expectedRevision, ref: ref)
            try requireUnlockedLayer(document.layers[index])
            let before = document.layers[index]
            var updated = before
            updated.adjustment = adjustment
            guard !sameLayerIgnoringRevision(before, updated) else { return [] }
            updated.revision += 1
            document.layers[index] = updated
            return [MediaPreparedObjectChange(
                ref: ref, containerID: updated.parentID, position: nil,
                before: .layer(before), after: .layer(updated))]

        case .updateLayerFlags(let id, let expectedRevision, let name,
                               let isVisible, let isLocked, let opacity):
            let ref = MediaPreparedObjectRef(kind: .layer, id: id)
            let index = try layerIndex(id, in: document)
            try requireRevision(document.layers[index].revision, expectedRevision, ref: ref)
            if let name, name.isEmpty {
                throw MediaPreparedCoreError.invalidOperation("layer name must not be empty")
            }
            if let opacity, !(opacity.isFinite && (0...1).contains(opacity)) {
                throw MediaPreparedCoreError.invalidOperation("layer opacity must be 0...1")
            }
            let before = document.layers[index]
            var updated = before
            if let name { updated.name = name }
            if let isVisible { updated.isVisible = isVisible }
            if let isLocked { updated.isLocked = isLocked }
            if let opacity { updated.opacity = opacity }
            guard !sameLayerIgnoringRevision(before, updated) else { return [] }
            updated.revision += 1
            document.layers[index] = updated
            return [MediaPreparedObjectChange(
                ref: ref, containerID: updated.parentID, position: nil,
                before: .layer(before), after: .layer(updated))]

        case .moveLayer(let id, let expectedRevision, let parentID, let index):
            let ref = MediaPreparedObjectRef(kind: .layer, id: id)
            let sourceIndex = try layerIndex(id, in: document)
            try requireRevision(document.layers[sourceIndex].revision, expectedRevision, ref: ref)
            try requireUnlockedLayer(document.layers[sourceIndex])
            try validateParent(parentID, for: id, in: document)
            if let parentID, let parent = document.layer(parentID), parent.isLocked {
                throw MediaPreparedCoreError.lockedObject(.init(kind: .layer, id: parentID))
            }
            let before = document.layers[sourceIndex]
            let destination = try resolvedIndex(index, count: document.layers.count - 1)
            if destination == sourceIndex, before.parentID == parentID { return [] }
            var moved = before
            moved.parentID = parentID
            moved.revision += 1
            document.layers.remove(at: sourceIndex)
            document.layers.insert(moved, at: destination)
            return [MediaPreparedObjectChange(
                ref: ref, containerID: parentID, position: sourceIndex,
                before: .layer(before), after: .layer(moved))]

        case .setLayerMask(let id, let expectedRevision, let mask):
            let ref = MediaPreparedObjectRef(kind: .layer, id: id)
            let index = try layerIndex(id, in: document)
            try requireRevision(document.layers[index].revision, expectedRevision, ref: ref)
            try requireUnlockedLayer(document.layers[index])
            let before = document.layers[index]
            var updated = before
            updated.mask = mask
            guard !sameLayerIgnoringRevision(before, updated) else { return [] }
            updated.revision += 1
            document.layers[index] = updated
            return [MediaPreparedObjectChange(
                ref: ref, containerID: updated.parentID, position: nil,
                before: .layer(before), after: .layer(updated))]

        case .setLayerClip(let id, let expectedRevision, let clip):
            let ref = MediaPreparedObjectRef(kind: .layer, id: id)
            let index = try layerIndex(id, in: document)
            try requireRevision(document.layers[index].revision, expectedRevision, ref: ref)
            try requireUnlockedLayer(document.layers[index])
            if let clip {
                guard clip.baseLayerID != id else {
                    throw MediaPreparedCoreError.invalidOperation("a layer cannot clip to itself")
                }
                guard let baseIndex = document.layers.firstIndex(where: { $0.id == clip.baseLayerID }) else {
                    throw MediaPreparedCoreError.unknownObject(
                        .init(kind: .layer, id: clip.baseLayerID))
                }
                guard document.layers[baseIndex].clip == nil else {
                    throw MediaPreparedCoreError.invalidOperation("clip chains are not supported")
                }
            }
            let before = document.layers[index]
            var updated = before
            updated.clip = clip
            guard !sameLayerIgnoringRevision(before, updated) else { return [] }
            updated.revision += 1
            document.layers[index] = updated
            return [MediaPreparedObjectChange(
                ref: ref, containerID: updated.parentID, position: nil,
                before: .layer(before), after: .layer(updated))]

        case .insertTrack(let track, let index):
            guard document.trackGraph.tracks.count < MediaPreparedSchema.maximumTracks else {
                throw MediaPreparedCoreError.limitsExceeded("track count")
            }
            guard !document.trackGraph.tracks.contains(where: { $0.id == track.id }) else {
                throw MediaPreparedCoreError.invalidOperation("track \(track.id.uuidString) already exists")
            }
            guard !track.isLocked else {
                throw MediaPreparedCoreError.lockedObject(.init(kind: .track, id: track.id))
            }
            let position = try resolvedIndex(index, count: document.trackGraph.tracks.count)
            var inserted = track
            inserted.revision = 1
            for clipIndex in inserted.clips.indices {
                inserted.clips[clipIndex].revision = 1
            }
            document.trackGraph.tracks.insert(inserted, at: position)
            var changes = [MediaPreparedObjectChange(
                ref: .init(kind: .track, id: inserted.id), position: position,
                before: nil, after: .track(inserted.metadata))]
            // Track metadata deliberately omits its children. Record initial
            // clips separately so creation, undo and redo retain their exact
            // ownership, position and generation, just as insertClip does.
            for (index, clip) in inserted.clips.enumerated() {
                changes.append(.init(ref:.init(kind:.clip,id:clip.id),containerID:inserted.id,position:index,
                    before:nil,after:.clip(trackID:inserted.id,clip:clip)))
            }
            return changes

        case .removeTrack(let id, let expectedRevision):
            let ref = MediaPreparedObjectRef(kind: .track, id: id)
            let index = try trackIndex(id, in: document)
            let track = document.trackGraph.tracks[index]
            try requireRevision(track.revision, expectedRevision, ref: ref)
            try requireUnlockedTrack(track)
            guard track.clips.isEmpty else {
                throw MediaPreparedCoreError.invalidOperation("remove clips before their track")
            }
            document.trackGraph.tracks.remove(at: index)
            return [MediaPreparedObjectChange(
                ref: ref, position: index,
                before: .track(track.metadata), after: nil)]

        case .updateTrackFlags(let id, let expectedRevision, let name,
                               let isMuted, let isLocked, let volume):
            let ref = MediaPreparedObjectRef(kind: .track, id: id)
            let index = try trackIndex(id, in: document)
            try requireRevision(document.trackGraph.tracks[index].revision,
                                expectedRevision, ref: ref)
            if let name, name.isEmpty {
                throw MediaPreparedCoreError.invalidOperation("track name must not be empty")
            }
            if let volume, !(volume.isFinite && (0...4).contains(volume)) {
                throw MediaPreparedCoreError.invalidOperation("track volume must be 0...4")
            }
            let before = document.trackGraph.tracks[index]
            var updated = before
            if let name { updated.name = name }
            if let isMuted { updated.isMuted = isMuted }
            if let isLocked { updated.isLocked = isLocked }
            if let volume { updated.volume = volume }
            guard !sameTrackIgnoringRevision(before, updated) else { return [] }
            updated.revision += 1
            document.trackGraph.tracks[index] = updated
            return [MediaPreparedObjectChange(
                ref: ref, position: index,
                before: .track(before.metadata), after: .track(updated.metadata))]

        case .insertClip(let trackID, let clip, let index):
            let trackIndex = try trackIndex(trackID, in: document)
            try requireUnlockedTrack(document.trackGraph.tracks[trackIndex])
            guard document.trackGraph.clip(id: clip.id) == nil else {
                throw MediaPreparedCoreError.invalidOperation("clip \(clip.id.uuidString) already exists")
            }
            guard document.trackGraph.tracks.reduce(0, { $0 + $1.clips.count })
                    < MediaPreparedSchema.maximumClips else {
                throw MediaPreparedCoreError.limitsExceeded("clip count")
            }
            let position = try resolvedIndex(index, count: document.trackGraph.tracks[trackIndex].clips.count)
            var inserted = clip
            inserted.revision = 1
            document.trackGraph.tracks[trackIndex].clips.insert(inserted, at: position)
            document.trackGraph.tracks[trackIndex].revision += 1
            return [MediaPreparedObjectChange(
                ref: .init(kind: .clip, id: inserted.id), containerID: trackID,
                position: position, before: nil,
                after: .clip(trackID: trackID, clip: inserted))]

        case .removeClip(let trackID, let clipID, let expectedRevision):
            let ref = MediaPreparedObjectRef(kind: .clip, id: clipID)
            let trackIndex = try trackIndex(trackID, in: document)
            try requireUnlockedTrack(document.trackGraph.tracks[trackIndex])
            let clipIndex = try clipIndex(clipID, inTrack: trackIndex, in: document)
            let clip = document.trackGraph.tracks[trackIndex].clips[clipIndex]
            try requireRevision(clip.revision, expectedRevision, ref: ref)
            document.trackGraph.tracks[trackIndex].clips.remove(at: clipIndex)
            document.trackGraph.tracks[trackIndex].revision += 1
            return [MediaPreparedObjectChange(
                ref: ref, containerID: trackID, position: clipIndex,
                before: .clip(trackID: trackID, clip: clip), after: nil)]

        case .replaceClip(let trackID, let clipID, let expectedRevision, var updated):
            let ref = MediaPreparedObjectRef(kind: .clip, id: clipID)
            let trackIndex = try trackIndex(trackID, in: document)
            try requireUnlockedTrack(document.trackGraph.tracks[trackIndex])
            let clipIndex = try clipIndex(clipID, inTrack: trackIndex, in: document)
            let before = document.trackGraph.tracks[trackIndex].clips[clipIndex]
            try requireRevision(before.revision, expectedRevision, ref: ref)
            guard before.compound == nil || updated.compound != nil else { throw MediaPreparedCoreError.invalidOperation("Expand or explicitly remove a compound instead of discarding its editable source") }
            guard updated.id == clipID else { throw MediaPreparedCoreError.invalidOperation("clip identity cannot change") }
            guard !sameClipIgnoringRevision(before, updated) else { return [] }
            updated.revision = before.revision + 1
            document.trackGraph.tracks[trackIndex].clips[clipIndex] = updated
            document.trackGraph.tracks[trackIndex].revision += 1
            return [MediaPreparedObjectChange(ref: ref, containerID: trackID, position: clipIndex,
                before: .clip(trackID: trackID, clip: before), after: .clip(trackID: trackID, clip: updated))]

        case .replaceClipKeyframes(let trackID, let clipID, let expectedRevision,
                                   let keyframeTracks):
            let ref = MediaPreparedObjectRef(kind: .clip, id: clipID)
            let trackIndex = try trackIndex(trackID, in: document)
            try requireUnlockedTrack(document.trackGraph.tracks[trackIndex])
            let clipIndex = try clipIndex(clipID, inTrack: trackIndex, in: document)
            let before = document.trackGraph.tracks[trackIndex].clips[clipIndex]
            try requireRevision(before.revision, expectedRevision, ref: ref)
            var updated = before
            updated.keyframeTracks = keyframeTracks
            guard !sameClipIgnoringRevision(before, updated) else { return [] }
            updated.revision += 1
            document.trackGraph.tracks[trackIndex].clips[clipIndex] = updated
            document.trackGraph.tracks[trackIndex].revision += 1
            return [MediaPreparedObjectChange(
                ref: ref, containerID: trackID, position: clipIndex,
                before: .clip(trackID: trackID, clip: before),
                after: .clip(trackID: trackID, clip: updated))]

        case .updateClipRange(let trackID, let clipID, let expectedRevision,
                              let timelineRange, let sourceRange):
            let ref = MediaPreparedObjectRef(kind: .clip, id: clipID)
            let trackIndex = try trackIndex(trackID, in: document)
            try requireUnlockedTrack(document.trackGraph.tracks[trackIndex])
            let clipIndex = try clipIndex(clipID, inTrack: trackIndex, in: document)
            let before = document.trackGraph.tracks[trackIndex].clips[clipIndex]
            try requireRevision(before.revision, expectedRevision, ref: ref)
            var updated = before
            updated.timelineRange = timelineRange
            updated.sourceRange = sourceRange
            guard !sameClipIgnoringRevision(before, updated) else { return [] }
            updated.revision += 1
            document.trackGraph.tracks[trackIndex].clips[clipIndex] = updated
            document.trackGraph.tracks[trackIndex].revision += 1
            return [MediaPreparedObjectChange(
                ref: ref, containerID: trackID, position: clipIndex,
                before: .clip(trackID: trackID, clip: before),
                after: .clip(trackID: trackID, clip: updated))]
        }
    }

    // MARK: Restoration

    private static func restore(_ change: MediaPreparedObjectChange,
                                in document: inout MediaPreparedDocument) throws {
        switch change.ref.kind {
        case .canvas:
            guard change.ref.id == document.id,case .canvas(let before)?=change.before else { throw MediaPreparedCoreError.invalidOperation("canvas journal identity") }
            let revision=document.canvasRevision ?? 0
            guard revision<UInt64.max-1 else { throw MediaPreparedCoreError.limitsExceeded("canvas generation") }
            document.canvas=before.canvas;document.canvasRevision=revision+1
        case .captionStyle:
            guard change.ref.id == document.id, case .captionStyle(let before)? = change.before else {
                throw MediaPreparedCoreError.invalidOperation("caption style journal identity")
            }
            let revision = document.trackGraph.captionStyleRevision ?? 0
            guard revision < UInt64.max - 1 else { throw MediaPreparedCoreError.limitsExceeded("caption style generation") }
            document.trackGraph.captionStyle = before.style
            document.trackGraph.captionStyleRevision = revision + 1
        case .asset:
            if let before = change.before {
                guard case .asset(let state) = before else {
                    throw MediaPreparedCoreError.invalidOperation("asset journal state")
                }
                let revision = document.assetRevisions?[change.ref.id] ?? state.revision
                guard revision < UInt64.max else { throw MediaPreparedCoreError.limitsExceeded("asset generation") }
                if let index = document.assets.firstIndex(where: { $0.id == change.ref.id }) {
                    document.assets[index] = state.reference
                } else {
                    document.assets.insert(state.reference, at: min(change.position ?? document.assets.count, document.assets.count))
                }
                document.assetRevisions = document.assetRevisions ?? [:]
                document.assetRevisions?[change.ref.id] = revision + 1
            } else {
                document.assets.removeAll { $0.id == change.ref.id }
                document.assetRevisions?.removeValue(forKey: change.ref.id)
            }
        case .layer: try restoreLayer(change, in: &document)
        case .track: try restoreTrack(change, in: &document)
        case .clip: try restoreClip(change, in: &document)
        }
    }

    private static func restoreLayer(_ change: MediaPreparedObjectChange,
                                     in document: inout MediaPreparedDocument) throws {
        switch (change.before, change.after) {
        case (nil, .some(_)):
            guard let index = document.layers.firstIndex(where: { $0.id == change.ref.id }) else {
                throw MediaPreparedCoreError.conflict("created layer disappeared before undo")
            }
            document.layers.remove(at: index)
        case (.some(let before), nil):
            guard case .layer(let layer) = before else {
                throw MediaPreparedCoreError.invalidOperation("layer journal state mismatch")
            }
            guard !document.layers.contains(where: { $0.id == layer.id }) else {
                throw MediaPreparedCoreError.conflict("deleted layer was recreated before undo")
            }
            var restored = layer
            restored.revision += 1
            let position = min(max(change.position ?? document.layers.count, 0),
                               document.layers.count)
            document.layers.insert(restored, at: position)
        case (.some(let before), .some(let after)):
            guard case .layer(let original) = before, case .layer(_) = after,
                  let index = document.layers.firstIndex(where: { $0.id == change.ref.id }) else {
                throw MediaPreparedCoreError.conflict("layer changed before undo")
            }
            var restored = original
            restored.revision = document.layers[index].revision + 1
            // Only a structural change (moveLayer) records a position. Other
            // updates restore in place so a disjoint insertion stays put.
            document.layers.remove(at: index)
            let position = change.position.map {
                min(max($0, 0), document.layers.count)
            } ?? index
            document.layers.insert(restored, at: position)
        case (nil, nil):
            throw MediaPreparedCoreError.invalidOperation("empty layer journal change")
        }
    }

    private static func restoreTrack(_ change: MediaPreparedObjectChange,
                                     in document: inout MediaPreparedDocument) throws {
        switch (change.before, change.after) {
        case (nil, .some(_)):
            guard let index = document.trackGraph.tracks.firstIndex(where: { $0.id == change.ref.id }) else {
                throw MediaPreparedCoreError.conflict("created track disappeared before undo")
            }
            document.trackGraph.tracks.remove(at: index)
        case (.some(let before), nil):
            guard case .track(let metadata) = before else {
                throw MediaPreparedCoreError.invalidOperation("track journal state mismatch")
            }
            guard !document.trackGraph.tracks.contains(where: { $0.id == metadata.id }) else {
                throw MediaPreparedCoreError.conflict("deleted track was recreated before undo")
            }
            let restored = MediaPreparedTrack(id: metadata.id, kind: metadata.kind,
                                              name: metadata.name, isMuted: metadata.isMuted,
                                              isLocked: metadata.isLocked, volume: metadata.volume,
                                              revision: metadata.revision + 1)
            let position = min(max(change.position ?? document.trackGraph.tracks.count, 0),
                               document.trackGraph.tracks.count)
            document.trackGraph.tracks.insert(restored, at: position)
        case (.some(let before), .some(let after)):
            guard case .track(let original) = before, case .track(_) = after,
                  let index = document.trackGraph.tracks.firstIndex(where: { $0.id == change.ref.id }) else {
                throw MediaPreparedCoreError.conflict("track changed before undo")
            }
            var metadata = original
            metadata.revision = document.trackGraph.tracks[index].revision + 1
            document.trackGraph.tracks[index].apply(metadata)
        case (nil, nil):
            throw MediaPreparedCoreError.invalidOperation("empty track journal change")
        }
    }

    private static func restoreClip(_ change: MediaPreparedObjectChange,
                                    in document: inout MediaPreparedDocument) throws {
        guard let trackID = change.containerID else {
            throw MediaPreparedCoreError.invalidOperation("clip journal change has no track")
        }
        guard let trackIndex = document.trackGraph.tracks.firstIndex(where: { $0.id == trackID }) else {
            throw MediaPreparedCoreError.conflict("clip track is missing")
        }
        switch (change.before, change.after) {
        case (nil, .some(_)):
            guard let index = document.trackGraph.tracks[trackIndex].clips
                .firstIndex(where: { $0.id == change.ref.id }) else {
                throw MediaPreparedCoreError.conflict("created clip disappeared before undo")
            }
            document.trackGraph.tracks[trackIndex].clips.remove(at: index)
        case (.some(let before), nil):
            guard case .clip(_, let clip) = before else {
                throw MediaPreparedCoreError.invalidOperation("clip journal state mismatch")
            }
            guard !document.trackGraph.tracks[trackIndex].clips
                .contains(where: { $0.id == clip.id }) else {
                throw MediaPreparedCoreError.conflict("deleted clip was recreated before undo")
            }
            var restored = clip
            restored.revision += 1
            let position = min(max(change.position ?? document.trackGraph.tracks[trackIndex].clips.count, 0),
                               document.trackGraph.tracks[trackIndex].clips.count)
            document.trackGraph.tracks[trackIndex].clips.insert(restored, at: position)
        case (.some(let before), .some(let after)):
            guard case .clip(_, let original) = before, case .clip(_, _) = after,
                  let index = document.trackGraph.tracks[trackIndex].clips
                    .firstIndex(where: { $0.id == change.ref.id }) else {
                throw MediaPreparedCoreError.conflict("clip changed before undo")
            }
            var restored = original
            restored.revision = document.trackGraph.tracks[trackIndex].clips[index].revision + 1
            document.trackGraph.tracks[trackIndex].clips[index] = restored
        case (nil, nil):
            throw MediaPreparedCoreError.invalidOperation("empty clip journal change")
        }
        document.trackGraph.tracks[trackIndex].revision += 1
    }

    // MARK: Lookup / comparison helpers

    private static func layerIndex(_ id: UUID,
                                   in document: MediaPreparedDocument) throws -> Int {
        guard let index = document.layers.firstIndex(where: { $0.id == id }) else {
            throw MediaPreparedCoreError.unknownObject(.init(kind: .layer, id: id))
        }
        return index
    }

    private static func trackIndex(_ id: UUID,
                                   in document: MediaPreparedDocument) throws -> Int {
        guard let index = document.trackGraph.tracks.firstIndex(where: { $0.id == id }) else {
            throw MediaPreparedCoreError.unknownObject(.init(kind: .track, id: id))
        }
        return index
    }

    private static func clipIndex(_ id: UUID, inTrack trackIndex: Int,
                                  in document: MediaPreparedDocument) throws -> Int {
        guard let index = document.trackGraph.tracks[trackIndex].clips
            .firstIndex(where: { $0.id == id }) else {
            throw MediaPreparedCoreError.unknownObject(.init(kind: .clip, id: id))
        }
        return index
    }

    private static func resolvedIndex(_ index: Int?, count: Int) throws -> Int {
        guard let index else { return count }
        guard (0...count).contains(index) else {
            throw MediaPreparedCoreError.invalidOperation("index \(index) is out of range 0...\(count)")
        }
        return index
    }

    private static func validateParent(_ parentID: UUID?, for layerID: UUID,
                                       in document: MediaPreparedDocument) throws {
        guard let parentID else { return }
        guard parentID != layerID else {
            throw MediaPreparedCoreError.invalidOperation("a layer cannot be its own parent")
        }
        guard let parent = document.layer(parentID) else {
            throw MediaPreparedCoreError.unknownObject(.init(kind: .layer, id: parentID))
        }
        guard parent.contentKind == .group else {
            throw MediaPreparedCoreError.invalidOperation("parent layer is not a group")
        }
        var cursor: UUID? = parentID
        var visited = Set<UUID>()
        while let current = cursor, let layer = document.layer(current) {
            guard visited.insert(current).inserted else {
                throw MediaPreparedCoreError.invalidOperation("layer hierarchy contains a cycle")
            }
            if current == layerID {
                throw MediaPreparedCoreError.invalidOperation("cannot move a layer under its own descendant")
            }
            cursor = layer.parentID
        }
    }

    private static func requireRevision(_ actual: UInt64, _ expected: UInt64,
                                        ref: MediaPreparedObjectRef) throws {
        guard actual == expected else {
            throw MediaPreparedCoreError.staleObject(ref)
        }
    }

    private static func requireUnlockedLayer(_ layer: MediaPreparedLayer) throws {
        guard !layer.isLocked else {
            throw MediaPreparedCoreError.lockedObject(.init(kind: .layer, id: layer.id))
        }
    }

    private static func requireUnlockedTrack(_ track: MediaPreparedTrack) throws {
        guard !track.isLocked else {
            throw MediaPreparedCoreError.lockedObject(.init(kind: .track, id: track.id))
        }
    }

    private static func sameLayerIgnoringRevision(_ lhs: MediaPreparedLayer,
                                                  _ rhs: MediaPreparedLayer) -> Bool {
        var left = lhs
        var right = rhs
        left.revision = 0
        right.revision = 0
        return left == right
    }

    private static func sameTrackIgnoringRevision(_ lhs: MediaPreparedTrack,
                                                  _ rhs: MediaPreparedTrack) -> Bool {
        var left = lhs.metadata
        var right = rhs.metadata
        left.revision = 0
        right.revision = 0
        return left == right
    }

    private static func sameClipIgnoringRevision(_ lhs: MediaPreparedClip,
                                                 _ rhs: MediaPreparedClip) -> Bool {
        var left = lhs
        var right = rhs
        left.revision = 0
        right.revision = 0
        return left == right
    }

    private static func merge(_ change: MediaPreparedObjectChange,
                              into changes: inout [MediaPreparedObjectChange]) {
        if let index = changes.firstIndex(where: { $0.ref == change.ref }) {
            // `before` is the state before the GROUP's first touch and must
            // never be replaced by an intermediate state. In particular, a
            // nil before means "created by this group" and must survive later
            // updates so undo removes the created object.
            changes[index].after = change.after
            if changes[index].position == nil { changes[index].position = change.position }
            if changes[index].containerID == nil { changes[index].containerID = change.containerID }
        } else {
            changes.append(change)
        }
    }

    /// A created-then-removed or updated-back-to-original change has no net
    /// effect and must not become an empty journal entry. A non-nil position
    /// marks a STRUCTURAL change (insert/remove/move); equal object content
    /// does not make a reorder a no-op.
    static func isNetNoOp(_ change: MediaPreparedObjectChange) -> Bool {
        switch (change.before, change.after) {
        case (nil, nil):
            return true
        case (.some(_), .some(_)) where change.position != nil:
            return false
        case (.some(let before), .some(let after)):
            switch (before, after) {
            case (.canvas(let lhs),.canvas(let rhs)): return lhs.canvas == rhs.canvas
            case (.captionStyle(let lhs), .captionStyle(let rhs)):
                return lhs.style == rhs.style
            case (.layer(let lhs), .layer(let rhs)):
                return sameLayerIgnoringRevision(lhs, rhs)
            case (.track(let lhs), .track(let rhs)):
                var left = lhs
                var right = rhs
                left.revision = 0
                right.revision = 0
                return left == right
            case (.clip(let leftTrack, let lhs), .clip(let rightTrack, let rhs)):
                return leftTrack == rightTrack && sameClipIgnoringRevision(lhs, rhs)
            default:
                return false
            }
        default:
            return false
        }
    }

    static func currentState(of ref: MediaPreparedObjectRef,
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
            return document.layers.first(where: { $0.id == ref.id }).map(MediaPreparedObjectState.layer)
        case .track:
            return document.trackGraph.tracks.first(where: { $0.id == ref.id })
                .map { .track($0.metadata) }
        case .clip:
            for track in document.trackGraph.tracks {
                if let clip = track.clips.first(where: { $0.id == ref.id }) {
                    return .clip(trackID: track.id, clip: clip)
                }
            }
            return nil
        }
    }

    private static func stateMatches(_ actual: MediaPreparedObjectState,
                                     _ expected: MediaPreparedObjectState,
                                     ref: MediaPreparedObjectRef) -> Bool {
        switch (actual, expected) {
        case (.canvas(let lhs),.canvas(let rhs)): return lhs == rhs
        case (.captionStyle(let lhs), .captionStyle(let rhs)): return lhs == rhs
        case (.asset(let lhs), .asset(let rhs)): return lhs == rhs
        case (.layer(let lhs), .layer(let rhs)):
            return lhs == rhs
        case (.track(let lhs), .track(let rhs)):
            var left = lhs
            var right = rhs
            left.revision = 0
            right.revision = 0
            return left == right
        case (.clip(let leftTrack, let lhs), .clip(let rightTrack, let rhs)):
            return leftTrack == rightTrack && lhs == rhs
        default:
            _ = ref
            return false
        }
    }

    private static func stateKindMatches(_ lhs: MediaPreparedObjectState,
                                         _ rhs: MediaPreparedObjectState) -> Bool {
        switch (lhs, rhs) {
        case (.canvas,.canvas),(.captionStyle, .captionStyle), (.asset, .asset), (.layer, .layer), (.track, .track), (.clip, .clip): return true
        default: return false
        }
    }

    private static func isCanvasLayoutTransition(_ change:MediaPreparedObjectChange) -> Bool {
        guard case .layer(var before)?=change.before,case .layer(var after)?=change.after,before.parentID == nil,after.parentID == nil else { return false }
        before.revision=0;after.revision=0;before.canvasSpace=nil;after.canvasSpace=nil
        return before == after
    }
    private static func isLockTransition(_ change: MediaPreparedObjectChange) -> Bool {
        guard case .layer(let before)? = change.before,
              case .layer(let after)? = change.after,
              before.isLocked != after.isLocked else { return false }
        var left = before
        var right = after
        left.isLocked = false
        right.isLocked = false
        left.revision = 0
        right.revision = 0
        return left == right
    }

    private static func isTrackLockTransition(_ change: MediaPreparedObjectChange) -> Bool {
        guard case .track(let before)? = change.before,
              case .track(let after)? = change.after,
              before.isLocked != after.isLocked else { return false }
        var left = before
        var right = after
        left.isLocked = false
        right.isLocked = false
        left.revision = 0
        right.revision = 0
        return left == right
    }
}
