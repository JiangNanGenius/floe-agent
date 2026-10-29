//
//  CADEditCheckpoint.swift
//  FloeCADKit
//
//  Exact in-memory checkpoint around a speculative document edit / save.
//  Restoring it puts back the document AND both undo/redo histories, so a
//  rejected parameter rebuild cannot become redoable and a failed save does
//  not destroy a pre-existing redo stack. The live `changeCount` is deliberately
//  NOT restored: it advances so stale query generations and GPU caches fence.
//

import Foundation

/// Opaque value held by the app bridge between a service call and its save.
/// Only `FloeCADDocument.captureEditCheckpoint`/`restoreEditCheckpoint` can
/// create or consume it; the app cannot inspect or fabricate the contents.
public nonisolated struct CADEditCheckpoint {
    var document: DesignDocument
    var undo: UndoStack.Checkpoint
    var evalCache: EvalCache
    var lastEvalErrors: [FeatureID: FeatureError]
    var lastFaceTables: [BodyID: FaceTable]
    var lastKernelNames: [BodyID: [Int: ElementName]]
    var lastNamingRevisions: [BodyID: UInt64]

    init(document: DesignDocument,
         undo: UndoStack.Checkpoint,
         evalCache: EvalCache,
         lastEvalErrors: [FeatureID: FeatureError],
         lastFaceTables: [BodyID: FaceTable],
         lastKernelNames: [BodyID: [Int: ElementName]],
         lastNamingRevisions: [BodyID: UInt64]) {
        self.document = document
        self.undo = undo
        self.evalCache = evalCache
        self.lastEvalErrors = lastEvalErrors
        self.lastFaceTables = lastFaceTables
        self.lastKernelNames = lastKernelNames
        self.lastNamingRevisions = lastNamingRevisions
    }
}

@MainActor
public extension FloeCADDocument {
    /// Capture the document + exact undo/redo histories BEFORE a speculative
    /// edit. The value is opaque to callers.
    func captureEditCheckpoint() -> CADEditCheckpoint {
        session.captureEditCheckpoint()
    }

    /// Restore a checkpoint. Used only when no concurrent editor changed the
    /// document (the caller fences with `liveChangeCount`). The generation
    /// advances; the restore is itself a document change.
    func restoreEditCheckpoint(_ checkpoint: CADEditCheckpoint) {
        session.restoreEditCheckpoint(checkpoint)
    }
}
