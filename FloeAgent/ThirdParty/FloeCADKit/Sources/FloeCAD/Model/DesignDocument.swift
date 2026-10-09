//
//  DesignDocument.swift
//  openshape3d
//
//  In-memory document: plain value type mirrored to SwiftData by
//  DocumentSession. Sketches join in the sketch build step.
//

import Foundation

nonisolated struct DesignDocument: Sendable {
    var bodies: [Body] = []
    var sketches: [Sketch] = []
    var planes: [ConstructionPlane] = []
    /// Construction axes (spec §6.2). Reference geometry only — they feed
    /// Revolve, circular patterns and rotates, and never produce a body.
    var axes: [ConstructionAxis] = []
    var images: [InsertedImage] = []
    var symbols: [Symbol] = []

    /// Items Manager folders (spec §11). Membership lives here, on the
    /// folders — see `ItemFolders.swift`. Empty for documents that never
    /// made one; stored as one JSON column (`Project.itemFoldersData`).
    var itemFolders: [ItemFolder] = []

    /// Phase D (Task C1) parametric feature history. Lives on the document so
    /// undoable commands mutate it via `inout document` like every other piece
    /// of model state. Empty for pre-Phase-D projects (they render from their
    /// baked `PersistedBody` meshes until the first parametric edit). Not
    /// serialized whole — `DocumentSession.save` diffs it into `PersistedFeature`
    /// rows, mirroring the `PersistedBody` path.
    var features = FeatureGraph(nodes: [])

    /// Phase D (Task A2) parametric variables. Ordered by creation; each resolves
    /// against earlier variables only (`VariableTable.resolve`). Empty for
    /// pre-Phase-D projects. Serialized per-row into `PersistedVariable` by
    /// `DocumentSession.save` (wired in task B1), mirroring the feature path.
    var variables: [Variable] = []

    /// Monotonic revision source for mesh changes (GPU cache invalidation).
    private var revisionCounter: UInt64 = 0

    mutating func nextRevision() -> UInt64 {
        revisionCounter += 1
        return revisionCounter
    }

    /// Every scene item a folder may hold, as it exists right now.
    var itemKeys: Set<DocumentItemKey> {
        var keys = Set<DocumentItemKey>()
        for body in bodies { keys.insert(.body(body.id)) }
        for sketch in sketches { keys.insert(.sketch(sketch.id)) }
        for plane in planes { keys.insert(.plane(plane.id)) }
        for axis in axes { keys.insert(.axis(axis.id)) }
        for image in images { keys.insert(.image(image.id)) }
        return keys
    }

    func body(with id: BodyID) -> Body? {
        bodies.first { $0.id == id }
    }

    func bodyIndex(of id: BodyID) -> Int? {
        bodies.firstIndex { $0.id == id }
    }

    /// Auto-name like "Box 2" based on what's already in the document.
    func uniqueBodyName(base: String) -> String {
        let existing = Set(bodies.map(\.name))
        if !existing.contains(base) { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Sketches number from 1 ("Sketch 1", "Sketch 2", …), Shapr3D style.
    func uniqueSketchName(base: String = "Sketch") -> String {
        let existing = Set(sketches.map(\.name))
        var n = 1
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    func imageIndex(of id: InsertedImageID) -> Int? {
        images.firstIndex { $0.id == id }
    }

    /// Images number from 1 ("Image 1", "Image 2", …) like sketches.
    func uniqueImageName(base: String = "Image") -> String {
        let existing = Set(images.map(\.name))
        var n = 1
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Symbols number from 1 ("Symbol 1", "Symbol 2", …) like sketches.
    func uniqueSymbolName(base: String = "Symbol") -> String {
        let existing = Set(symbols.map(\.name))
        var n = 1
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
