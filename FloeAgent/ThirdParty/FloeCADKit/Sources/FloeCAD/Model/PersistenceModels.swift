//
//  PersistenceModels.swift
//  FloeCADKit
//
//  Persistence graph, adapted from OpenShape3D's SwiftData `@Model` classes
//  (MIT, Laan Labs and contributors). FloeCAD keeps the same per-record
//  columns and the same load/save diff semantics in `DocumentSession`, but the
//  records are plain classes owned by `CADModelContext` and written by a
//  `CADDocumentStore` (see Floe/FileCADDocumentStore.swift). There is no
//  SwiftData dependency: a FloeCAD project is a versioned file package with
//  JSON metadata and separate binary B-rep/mesh blobs.
//

import Foundation

/// One FloeCAD project's persisted state.
final class Project {
    var name: String = "Untitled"
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    var thumbnail: Data?

    var bodies: [PersistedBody] = []
    var sketches: [PersistedSketch] = []
    var planes: [PersistedPlane] = []
    var axes: [PersistedAxis] = []
    var images: [PersistedImage] = []
    var symbols: [PersistedSymbol] = []
    var features: [PersistedFeature] = []
    var variables: [PersistedVariable] = []

    /// Feature-graph rollback marker: the number of ACTIVE (leading) nodes.
    /// `nil` means all nodes are active.
    var rollbackIndex: Int? = nil

    /// Store format version, bumped ONLY on a non-additive change to a
    /// persisted payload. A store whose version is NEWER than this build's
    /// `Project.currentFormatVersion` opens for viewing but `save()` refuses
    /// to touch it.
    var formatVersion: Int = 1

    /// The newest store format this build reads AND writes.
    static let currentFormatVersion = 1

    /// Gallery folder this design sits in; `nil` = top level.
    var folderID: UUID? = nil

    /// Items Manager folders as one JSON blob (`[ItemFolder]`).
    var itemFoldersData: Data? = nil

    /// Document display unit (raw `DisplayUnit`), mm storage regardless.
    var unitRaw: String? = nil

    /// Document modelling tolerance in millimetres (0 = kernel default).
    var tolerance: Double? = nil

    /// Extra workbench state owned by Floe (assembly / drawings). JSON blobs,
    /// separate from the body/feature records so the kernel schema can move
    /// independently.
    var assemblyData: Data? = nil
    var drawingsData: Data? = nil

    init(name: String) {
        self.name = name
        self.createdAt = Date()
        self.modifiedAt = Date()
    }
}

final class PersistedBody {
    var bodyID: UUID = UUID()
    var name: String = "Body"
    /// JSON-encoded Transform3D (tiny).
    var transformData: Data = Data()
    /// JSON-encoded PrimitiveSpec, nil once the body is baked.
    var primitiveData: Data?
    /// Compact binary mesh blob ("OS3D" format).
    var meshData: Data = Data()
    /// Items Manager visibility.
    var isHidden: Bool = false
    /// JSON-encoded BodyMaterialSpec; nil keeps the legacy default look.
    var materialData: Data?
    /// OCCT BRep blob, so analytic geometry survives a reload.
    var brepData: Data?
    weak var project: Project?

    init(bodyID: UUID, name: String, transformData: Data, primitiveData: Data?, meshData: Data) {
        self.bodyID = bodyID
        self.name = name
        self.transformData = transformData
        self.primitiveData = primitiveData
        self.meshData = meshData
    }
}

final class PersistedSketch {
    var sketchID: UUID = UUID()
    /// JSON-encoded Sketch (plane + entities, tiny).
    var sketchData: Data = Data()
    weak var project: Project?

    init(sketchID: UUID, sketchData: Data) {
        self.sketchID = sketchID
        self.sketchData = sketchData
    }
}

final class PersistedImage {
    var imageID: UUID = UUID()
    /// JSON-encoded InsertedImage with the picture blob stripped (tiny).
    var infoData: Data = Data()
    /// Original PNG/JPEG bytes exactly as picked.
    var imageData: Data = Data()
    weak var project: Project?

    init(imageID: UUID, infoData: Data, imageData: Data) {
        self.imageID = imageID
        self.infoData = infoData
        self.imageData = imageData
    }
}

final class PersistedSymbol {
    var symbolID: UUID = UUID()
    /// JSON-encoded Symbol (entities in symbol-local coordinates).
    var symbolData: Data = Data()
    weak var project: Project?

    init(symbolID: UUID, symbolData: Data) {
        self.symbolID = symbolID
        self.symbolData = symbolData
    }
}

final class PersistedPlane {
    var planeID: UUID = UUID()
    /// JSON-encoded ConstructionPlane (tiny).
    var planeData: Data = Data()
    weak var project: Project?

    init(planeID: UUID, planeData: Data) {
        self.planeID = planeID
        self.planeData = planeData
    }
}

/// A construction axis (spec §6.2), persisted.
final class PersistedAxis {
    var axisID: UUID = UUID()
    /// JSON-encoded ConstructionAxis (tiny).
    var axisData: Data = Data()
    weak var project: Project?

    init(axisID: UUID, axisData: Data) {
        self.axisID = axisID
        self.axisData = axisData
    }
}

/// One node of the parametric feature graph, persisted.
final class PersistedFeature {
    var featureID: UUID = UUID()
    var orderIndex: Int = 0
    var name: String = "Feature"
    var suppressed: Bool = false
    /// JSON-encoded `FeatureKind`.
    var kindData: Data = Data()
    /// JSON-encoded `[BodyID]` (the node's minted-once output body IDs).
    var outputBodyIDData: Data = Data()
    weak var project: Project?

    init(featureID: UUID,
         orderIndex: Int,
         name: String,
         suppressed: Bool,
         kindData: Data,
         outputBodyIDData: Data) {
        self.featureID = featureID
        self.orderIndex = orderIndex
        self.name = name
        self.suppressed = suppressed
        self.kindData = kindData
        self.outputBodyIDData = outputBodyIDData
    }
}

/// One parametric `Variable`, persisted.
final class PersistedVariable {
    var variableID: UUID = UUID()
    var orderIndex: Int = 0
    var name: String = ""
    var expression: String = ""
    var value: Double = 0
    weak var project: Project?

    init(variableID: UUID,
         orderIndex: Int,
         name: String,
         expression: String,
         value: Double) {
        self.variableID = variableID
        self.orderIndex = orderIndex
        self.name = name
        self.expression = expression
        self.value = value
    }
}

// MARK: - Model context

/// Minimal record graph context replacing upstream's `ModelContext`.
///
/// `insert` files a record into its `Project` collection; `delete` removes it;
/// `save` writes the whole graph through the attached `CADDocumentStore`.
/// Records inserted without a `project` back-reference are ignored, matching
/// the upstream requirement that callers set `record.project` first.
@MainActor
final class CADModelContext {
    let project: Project
    /// Nonisolated so a background commit can perform the staged write while
    /// the payload is built on the session actor. `FileCADDocumentStore` is
    /// `@unchecked Sendable` and guards its revision with a lock.
    nonisolated let store: FileCADDocumentStore?

    init(project: Project, store: FileCADDocumentStore? = nil) {
        self.project = project
        self.store = store
    }

    func insert(_ record: AnyObject) {
        switch record {
        case let record as PersistedBody:
            guard record.project === project else { return }
            if !project.bodies.contains(where: { $0 === record }) { project.bodies.append(record) }
        case let record as PersistedSketch:
            guard record.project === project else { return }
            if !project.sketches.contains(where: { $0 === record }) { project.sketches.append(record) }
        case let record as PersistedPlane:
            guard record.project === project else { return }
            if !project.planes.contains(where: { $0 === record }) { project.planes.append(record) }
        case let record as PersistedAxis:
            guard record.project === project else { return }
            if !project.axes.contains(where: { $0 === record }) { project.axes.append(record) }
        case let record as PersistedImage:
            guard record.project === project else { return }
            if !project.images.contains(where: { $0 === record }) { project.images.append(record) }
        case let record as PersistedSymbol:
            guard record.project === project else { return }
            if !project.symbols.contains(where: { $0 === record }) { project.symbols.append(record) }
        case let record as PersistedFeature:
            guard record.project === project else { return }
            if !project.features.contains(where: { $0 === record }) { project.features.append(record) }
        case let record as PersistedVariable:
            guard record.project === project else { return }
            if !project.variables.contains(where: { $0 === record }) { project.variables.append(record) }
        default:
            break
        }
    }

    func delete(_ record: AnyObject) {
        switch record {
        case let record as PersistedBody:
            project.bodies.removeAll { $0 === record }
        case let record as PersistedSketch:
            project.sketches.removeAll { $0 === record }
        case let record as PersistedPlane:
            project.planes.removeAll { $0 === record }
        case let record as PersistedAxis:
            project.axes.removeAll { $0 === record }
        case let record as PersistedImage:
            project.images.removeAll { $0 === record }
        case let record as PersistedSymbol:
            project.symbols.removeAll { $0 === record }
        case let record as PersistedFeature:
            project.features.removeAll { $0 === record }
        case let record as PersistedVariable:
            project.variables.removeAll { $0 === record }
        default:
            break
        }
    }

    func save() throws {
        guard let store else {
            throw CADDocumentStoreError.noStoreAttached
        }
        try store.write(project)
    }

    /// Cheap session-actor step: slice the record graph into a Sendable
    /// payload (no JSON, no hashing, no I/O).
    func preparedPayload() throws -> CADWritePayload {
        guard let store else { throw CADDocumentStoreError.noStoreAttached }
        return try store.makePayload(project)
    }

    /// Off-main step: encode, hash and commit the prepared payload.
    nonisolated static func write(_ payload: CADWritePayload, to store: FileCADDocumentStore) throws {
        _ = try store.performWrite(payload)
    }
}

// MARK: - Variable encode/decode helpers

/// Build a fresh `PersistedVariable` from a `Variable`. `orderIndex` is the
/// variable's position in `DesignDocument.variables`.
func encodeVariable(_ v: Variable, orderIndex: Int) -> PersistedVariable {
    PersistedVariable(
        variableID: v.id.raw,
        orderIndex: orderIndex,
        name: v.name,
        expression: v.expression,
        value: v.value
    )
}

/// Rebuild a `Variable` from a persisted row.
func decodeVariable(_ pv: PersistedVariable) -> Variable {
    Variable(
        id: VariableID(raw: pv.variableID),
        name: pv.name,
        expression: pv.expression,
        value: pv.value
    )
}

// MARK: - Feature encode/decode helpers

/// JSON-encode a `FeatureKind`; `Data()` on failure (empty decodes back to nil).
nonisolated func encodeFeatureKind(_ kind: FeatureKind) -> Data {
    (try? JSONEncoder().encode(kind)) ?? Data()
}

/// JSON-decode a `FeatureKind`; nil if the blob is empty/corrupt.
nonisolated func decodeFeatureKind(_ data: Data) -> FeatureKind? {
    try? JSONDecoder().decode(FeatureKind.self, from: data)
}

/// JSON-encode a node's `[BodyID]`; `Data()` on failure.
nonisolated func encodeBodyIDs(_ ids: [BodyID]) -> Data {
    (try? JSONEncoder().encode(ids)) ?? Data()
}

/// JSON-decode `[BodyID]`; nil if the blob is empty/corrupt (caller uses `?? []`).
nonisolated func decodeBodyIDs(_ data: Data) -> [BodyID]? {
    try? JSONDecoder().decode([BodyID].self, from: data)
}

/// Build a fresh `PersistedFeature` from a graph node.
func encodeFeature(_ node: FeatureNode, orderIndex: Int) -> PersistedFeature {
    PersistedFeature(
        featureID: node.id.raw,
        orderIndex: orderIndex,
        name: node.name,
        suppressed: node.suppressed,
        kindData: encodeFeatureKind(node.kind),
        outputBodyIDData: encodeBodyIDs(node.outputBodyIDs)
    )
}

/// Rebuild a `FeatureNode` from a persisted row; nil if the kind blob won't
/// decode (a broken/forward-incompatible node is skipped rather than crashing).
func decodeFeature(_ pf: PersistedFeature) -> FeatureNode? {
    guard let kind = decodeFeatureKind(pf.kindData) else { return nil }
    return FeatureNode(
        id: FeatureID(raw: pf.featureID),
        name: pf.name,
        kind: kind,
        suppressed: pf.suppressed,
        outputBodyIDs: decodeBodyIDs(pf.outputBodyIDData) ?? []
    )
}
