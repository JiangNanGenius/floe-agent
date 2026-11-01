//
//  AssociativeGeometryResolver.swift
//  FloeCAD
//
//  Per-replay adapter over the existing feature journal and OCCT names.
//  No persisted body versions, extra kernel, or document mutation lives here.
//

import Foundation

nonisolated enum AssociativeReferenceKey: Codable, Hashable, Sendable {
    case plane(ConstructionPlaneID)
    case sketch(SketchID)
    case feature(FeatureID)
}

nonisolated enum AssociativeReferenceError: Error, Codable, Equatable, Sendable {
    case missingPlane(ConstructionPlaneID)
    case missingSketch(SketchID)
    case missingWriter(GeometryVersionRef)
    case suppressedWriter(GeometryVersionRef)
    case rolledBackWriter(GeometryVersionRef)
    case forwardSource(GeometryVersionRef)
    case failedWriter(GeometryVersionRef)
    case missingBodyVersion(GeometryVersionRef)
    case cycle([AssociativeReferenceKey])
    case unsupportedSketchSupport(SketchID)
    case exactNamedPlaneRequired(GeometryVersionRef)
    case missingNamedFace(GeometryVersionRef)
    case ambiguousFace(GeometryVersionRef)
    case missingAnchorEntity(sketch: SketchID, entity: UUID)
    case unsupportedAnchorRole(sketch: SketchID, entity: UUID, role: String)
    case invalidHingeAxis(String)
    case degenerateAnchorPoints(String)
    case invalidDefinition(String)
    case invalidFormula(String)

    var message: String { String(describing: self) }
}

/// A shared value snapshot of one actual journal PUT. A later in-place writer
/// or live-body removal never changes this version. OCCT handles/mesh buffers
/// retain their existing shared immutable storage.
nonisolated struct GeometryVersionSnapshot: Sendable {
    var body: Body
    var faceTable: FaceTable
    var kernelNames: [Int: ElementName]
    var stamp: UInt64
}

nonisolated struct ResolvedAssociativePlane: Sendable {
    var plane: SketchPlane
    var stamp: UInt64
}

nonisolated struct ResolvedAssociativeSketch: Sendable {
    var sketch: Sketch
    var stamp: UInt64
}

/// Capture this from the ORIGINAL graph/records, then validate a proposed
/// reorder/delete/suppress against it. No source writer is inferred or rebound
/// from the candidate order. The existing M26 body-version dependency map can
/// be supplied as featureDependencies; it remains the authority for body refs.
nonisolated struct AssociativeDependencyGraph: Sendable {
    private var edges: [AssociativeReferenceKey: Set<AssociativeReferenceKey>] = [:]
    private var versionsByPlane: [ConstructionPlaneID: GeometryVersionRef] = [:]
    private var definitionPlaneIDs: Set<ConstructionPlaneID> = []
    private var featureIDs: Set<FeatureID> = []
    private var planeIDs: Set<ConstructionPlaneID> = []
    private var sketchIDs: Set<SketchID> = []

    init(graph: FeatureGraph, sketches: [Sketch], planes: [ConstructionPlane],
         featureDependencies: [FeatureID: Set<FeatureID>] = [:]) {
        for node in graph.nodes {
            featureIDs.insert(node.id)
            edges[.feature(node.id)] = Set(node.referencedSketchIDs.map { .sketch($0) })
                .union(node.referencedConstructionPlaneIDs.map { .plane($0) })
                .union((featureDependencies[node.id] ?? []).map { .feature($0) })
        }
        for sketch in sketches {
            sketchIDs.insert(sketch.id)
            guard let support = sketch.support else { continue }
            switch support.source {
            case let .construction(id): edges[.sketch(sketch.id)] = [.plane(id)]
            case let .sketch(id): edges[.sketch(sketch.id)] = [.sketch(id)]
            case .ground, .explicit: break
            }
        }
        for plane in planes {
            planeIDs.insert(plane.id)
            switch plane.definition {
            case nil:
                break
            case let .offset(definition)?:
                definitionPlaneIDs.insert(plane.id)
                versionsByPlane[plane.id] = definition.sourceVersion
                edges[.plane(plane.id)] = [.feature(definition.sourceVersion.writer)]
            case let .angle(definition)?:
                definitionPlaneIDs.insert(plane.id)
                versionsByPlane[plane.id] = definition.sourceVersion
                edges[.plane(plane.id)] = [.feature(definition.sourceVersion.writer)]
            case let .threePoints(definition)?:
                definitionPlaneIDs.insert(plane.id)
                // Every point sketch is a real support writer dependency:
                // a sketch may itself be supported by another associative
                // plane, so the walk continues through its own edges.
                edges[.plane(plane.id)] = Set(definition.points.map { .sketch($0.sketchID) })
            }
        }
    }

    func dependencies(of key: AssociativeReferenceKey) -> [AssociativeReferenceKey] {
        (edges[key] ?? []).sorted { Self.order($0) < Self.order($1) }
    }

    /// Enrich during replay from actual preceding PUT writers. This never
    /// changes a datum's frozen sourceVersion or M26's persisted provenance.
    mutating func addFeatureDependencies(_ feature: FeatureID, writers: Set<FeatureID>) {
        edges[.feature(feature), default: []].formUnion(writers.map { .feature($0) })
    }

    func sourceVersions(reachableFrom start: AssociativeReferenceKey) throws -> Set<GeometryVersionRef> {
        var path: [AssociativeReferenceKey] = []
        var visiting: Set<AssociativeReferenceKey> = []
        var visited: Set<AssociativeReferenceKey> = []
        var versions: Set<GeometryVersionRef> = []
        func walk(_ key: AssociativeReferenceKey) throws {
            if visiting.contains(key) { throw AssociativeReferenceError.cycle(path + [key]) }
            guard !visited.contains(key) else { return }
            switch key {
            case let .plane(id):
                guard planeIDs.contains(id) else { throw AssociativeReferenceError.missingPlane(id) }
            case let .sketch(id):
                guard sketchIDs.contains(id) else { throw AssociativeReferenceError.missingSketch(id) }
            case .feature: break
            }
            visiting.insert(key)
            path.append(key)
            if case let .plane(id) = key, let version = versionsByPlane[id] { versions.insert(version) }
            for next in dependencies(of: key) { try walk(next) }
            path.removeLast()
            visiting.remove(key)
            visited.insert(key)
        }
        try walk(start)
        return versions
    }

    func checkCycle(from start: AssociativeReferenceKey) throws {
        _ = try sourceVersions(reachableFrom: start)
    }

    /// Keys include unused datums, so deleting/suppressing their source is
    /// diagnosed even if no feature currently consumes that datum.
    func validationErrors(in candidate: FeatureGraph) -> [AssociativeReferenceKey: AssociativeReferenceError] {
        let indices = Dictionary(candidate.nodes.enumerated().map { ($0.element.id, $0.offset) },
                                 uniquingKeysWith: { first, _ in first })
        var errors: [AssociativeReferenceKey: AssociativeReferenceError] = [:]
        let roots = Set(featureIDs.map { AssociativeReferenceKey.feature($0) })
            .union(definitionPlaneIDs.map { .plane($0) })
        for root in roots.sorted(by: { Self.order($0) < Self.order($1) }) {
            var consumerIndex: Int?
            if case let .feature(id) = root {
                guard let index = indices[id], !candidate.nodes[index].suppressed,
                      index < (candidate.rollbackIndex ?? candidate.nodes.count) else { continue }
                consumerIndex = index
            }
            do {
                let versions = try sourceVersions(reachableFrom: root).sorted {
                    if $0.writer != $1.writer { return $0.writer.raw.uuidString < $1.writer.raw.uuidString }
                    return $0.bodyID.raw.uuidString < $1.bodyID.raw.uuidString
                }
                for version in versions {
                    guard let index = indices[version.writer] else {
                        errors[root] = .missingWriter(version); break
                    }
                    if candidate.nodes[index].suppressed {
                        errors[root] = .suppressedWriter(version); break
                    }
                    if index >= (candidate.rollbackIndex ?? candidate.nodes.count) {
                        errors[root] = .rolledBackWriter(version); break
                    }
                    if let consumerIndex, index >= consumerIndex {
                        errors[root] = .forwardSource(version); break
                    }
                }
            } catch let error as AssociativeReferenceError { errors[root] = error }
            catch { errors[root] = .invalidDefinition(error.localizedDescription) }
        }
        return errors
    }

    private static func order(_ key: AssociativeReferenceKey) -> String {
        switch key {
        case let .plane(id): return "p:" + id.raw.uuidString
        case let .sketch(id): return "s:" + id.raw.uuidString
        case let .feature(id): return "f:" + id.raw.uuidString
        }
    }
}

/// Only successful resolutions are memoized, and only for one consumer epoch.
/// A forward reference observed by an earlier consumer stays an error even if
/// a later final display-resolution can find that writer.
nonisolated struct AssociativeGeometryResolver: Sendable {
    private let graph: FeatureGraph
    private let sketches: [SketchID: Sketch]
    private let planes: [ConstructionPlaneID: ConstructionPlane]
    private let variables: [String: Double]
    private let requestedVersions: Set<GeometryVersionRef>
    private let indices: [FeatureID: Int]
    private var consumer: FeatureID?
    private var planeMemo: [ConstructionPlaneID: ResolvedAssociativePlane] = [:]
    private var sketchMemo: [SketchID: ResolvedAssociativeSketch] = [:]
    private var failedWriters: Set<FeatureID> = []
    private var dependencyGraph: AssociativeDependencyGraph

    private(set) var snapshots: [GeometryVersionRef: GeometryVersionSnapshot] = [:]
    private(set) var lastBodyWriters: [BodyID: FeatureID] = [:]
    private(set) var resolvedPlaneUpdates: [ConstructionPlaneID: SketchPlane] = [:]
    private(set) var resolvedSketchSupportUpdates: [SketchID: SketchPlane] = [:]
    private(set) var referenceErrors: [AssociativeReferenceKey: AssociativeReferenceError] = [:]

    init(graph: FeatureGraph, sketches: [Sketch], planes: [ConstructionPlane],
         variables: [String: Double] = [:], requestedVersions: Set<GeometryVersionRef> = []) {
        self.graph = graph
        self.sketches = Dictionary(sketches.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.planes = Dictionary(planes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.variables = variables
        dependencyGraph = AssociativeDependencyGraph(graph: graph, sketches: sketches, planes: planes)
        indices = Dictionary(graph.nodes.enumerated().map { ($0.element.id, $0.offset) },
                             uniquingKeysWith: { first, _ in first })
        var requested = requestedVersions
        for plane in planes {
            switch plane.definition {
            case let .offset(definition)?:
                requested.insert(definition.sourceVersion)
            case let .angle(definition)?:
                requested.insert(definition.sourceVersion)
            case .threePoints?:
                break
            case nil:
                break
            }
        }
        self.requestedVersions = requested
    }

    mutating func begin(_ node: FeatureNode) {
        consumer = node.id
        planeMemo.removeAll(keepingCapacity: true)
        sketchMemo.removeAll(keepingCapacity: true)
        dependencyGraph.addFeatureDependencies(node.id,
            writers: Set(node.consumedBodyIDs.compactMap { lastBodyWriters[$0] }))
    }

    /// Called at the SAME node-end boundary for both execution and cache hits.
    /// A failed node cannot advertise even a partial PUT as valid geometry.
    mutating func finish(_ node: FeatureNode, delta: EvalNodeDelta, stamp: UInt64) {
        if delta.error != nil {
            failedWriters.insert(node.id)
            for id in delta.putBodyIDs { lastBodyWriters[id] = nil }
            return
        }
        for op in delta.ops {
            switch op {
            case let .put(body, table, names):
                lastBodyWriters[body.id] = node.id
                let key = GeometryVersionRef(bodyID: body.id, writer: node.id)
                if requestedVersions.contains(key) {
                    snapshots[key] = GeometryVersionSnapshot(
                        body: body, faceTable: table, kernelNames: names ?? [:], stamp: stamp)
                }
            case let .remove(id):
                lastBodyWriters[id] = nil
                // Historical versions deliberately survive live-body removal.
            }
        }
    }

    /// Resolve every associative input BEFORE deciding whether the node can
    /// use its old delta. Legacy hashes stay byte-for-byte on their old path.
    mutating func prepare(_ node: FeatureNode) -> (
        sketches: [SketchID: UInt64], planes: [ConstructionPlaneID: UInt64],
        error: AssociativeReferenceError?
    ) {
        var sketchHashes: [SketchID: UInt64] = [:]
        var planeHashes: [ConstructionPlaneID: UInt64] = [:]
        var firstError: AssociativeReferenceError?
        for id in node.referencedSketchIDs.sorted(by: { $0.raw.uuidString < $1.raw.uuidString }) {
            guard sketches[id]?.support != nil else { continue }
            do { sketchHashes[id] = try sketch(id).stamp }
            catch {
                let error = typed(error)
                remember(error, at: .sketch(id))
                sketchHashes[id] = failureStamp(key: .sketch(id), error: error)
                if firstError == nil { firstError = error }
            }
        }
        for id in node.referencedConstructionPlaneIDs.sorted(by: { $0.raw.uuidString < $1.raw.uuidString }) {
            guard planes[id]?.definition != nil else { continue }
            do { planeHashes[id] = try plane(PlaneRef(source: .construction(id))).stamp }
            catch {
                let error = typed(error)
                remember(error, at: .plane(id))
                planeHashes[id] = failureStamp(key: .plane(id), error: error)
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { remember(firstError, at: .feature(node.id)) }
        return (sketchHashes, planeHashes, firstError)
    }

    mutating func plane(_ ref: PlaneRef) throws -> ResolvedAssociativePlane {
        switch ref.source {
        case let .sketch(id):
            let resolved = try sketch(id)
            return ResolvedAssociativePlane(plane: resolved.sketch.plane, stamp: resolved.stamp)
        case let .construction(id):
            if let memo = planeMemo[id] { return memo }
            do {
                try dependencyGraph.checkCycle(from: .plane(id))
                guard let record = planes[id] else { throw AssociativeReferenceError.missingPlane(id) }
                // Nil definition is the legacy absolute plane and is the ONLY
                // case allowed to use the cached frame. Every present
                // definition kind must resolve or report a broken reference;
                // an unknown/unsupported payload never reaches this switch
                // because ConstructionPlane decoding refuses it.
                guard let definition = record.definition else {
                    return ResolvedAssociativePlane(plane: record.plane, stamp: EvalFingerprint.hash(record))
                }
                let resolved: SketchPlane
                switch definition {
                case let .offset(payload):
                    try payload.validate()
                    let snapshot = try version(payload.sourceVersion)
                    let face = try Self.exactFace(source: payload.source,
                                                  version: payload.sourceVersion,
                                                  snapshot: snapshot)
                    var edited = payload
                    if let formula = payload.distance.formula {
                        guard let value = ExpressionEvaluator.evaluate(formula, variables: variables),
                              value.isFinite else {
                            throw AssociativeReferenceError.invalidFormula(formula)
                        }
                        edited.distance.value = value
                    }
                    resolved = try edited.resolvedPlane(face: face,
                                                        bodyTransform: snapshot.body.transform)
                case let .angle(payload):
                    try payload.validate()
                    let snapshot = try version(payload.sourceVersion)
                    let face = try Self.exactFace(source: payload.source,
                                                  version: payload.sourceVersion,
                                                  snapshot: snapshot)
                    var edited = payload
                    if let formula = payload.angle.formula {
                        guard let value = ExpressionEvaluator.evaluate(formula, variables: variables),
                              value.isFinite else {
                            throw AssociativeReferenceError.invalidFormula(formula)
                        }
                        edited.angle.value = value
                    }
                    resolved = try edited.resolvedPlane(face: face,
                                                        bodyTransform: snapshot.body.transform)
                case let .threePoints(payload):
                    try payload.validate()
                    var worldPoints: [SIMD3<Double>] = []
                    var stamps: [UInt64] = []
                    for anchor in payload.points {
                        let resolvedSketch = try sketch(anchor.sketchID)
                        let local = try Self.anchorPoint(anchor, in: resolvedSketch.sketch)
                        worldPoints.append(resolvedSketch.sketch.plane.toWorld(local))
                        stamps.append(resolvedSketch.stamp)
                    }
                    resolved = try payload.resolvedPlane(worldPoints: worldPoints)
                    var f = EvalFingerprint()
                    f.combine(EvalFingerprint.hash(definition))
                    for stamp in stamps { f.combine(stamp) }
                    f.combine(EvalFingerprint.hash(resolved))
                    let value = ResolvedAssociativePlane(plane: resolved, stamp: f.value)
                    planeMemo[id] = value
                    resolvedPlaneUpdates[id] = resolved
                    return value
                }
                var f = EvalFingerprint()
                f.combine(EvalFingerprint.hash(definition))
                // The geometry snapshot/fingerprint already includes the
                // definition, but keep the explicit snapshot stamp so a
                // writer whose definition bytes are unchanged still
                // invalidates a cached consumer.
                f.combine(try versionFingerprint(definition))
                f.combine(EvalFingerprint.hash(resolved))
                let value = ResolvedAssociativePlane(plane: resolved, stamp: f.value)
                planeMemo[id] = value
                resolvedPlaneUpdates[id] = resolved
                return value
            } catch {
                let error = typed(error)
                remember(error, at: .plane(id))
                throw error
            }
        case .ground:
            return ResolvedAssociativePlane(plane: .ground, stamp: EvalFingerprint.hash(SketchPlane.ground))
        case let .explicit(plane):
            return ResolvedAssociativePlane(plane: plane, stamp: EvalFingerprint.hash(plane))
        }
    }

    mutating func sketch(_ id: SketchID) throws -> ResolvedAssociativeSketch {
        if let memo = sketchMemo[id] { return memo }
        do {
            try dependencyGraph.checkCycle(from: .sketch(id))
            guard var record = sketches[id] else { throw AssociativeReferenceError.missingSketch(id) }
            guard let support = record.support else {
                return ResolvedAssociativeSketch(sketch: record, stamp: EvalFingerprint.hash(record))
            }
            // Only construction-plane support is a supported creation contract.
            // Cycle checking happens first, including malformed legacy chains.
            guard case .construction = support.source else {
                throw AssociativeReferenceError.unsupportedSketchSupport(id)
            }
            let resolved = try plane(support)
            record.plane = resolved.plane
            var f = EvalFingerprint()
            // Includes local entities/constraints/support but NEVER the stale
            // persisted cache plane. Replacing it above makes cold/hot equal.
            f.combine(EvalFingerprint.hash(record))
            f.combine(resolved.stamp)
            let value = ResolvedAssociativeSketch(sketch: record, stamp: f.value)
            sketchMemo[id] = value
            resolvedSketchSupportUpdates[id] = resolved.plane
            return value
        } catch {
            let error = typed(error)
            remember(error, at: .sketch(id))
            throw error
        }
    }

    /// Also update/diagnose unused datums and supported sketches. Resetting the
    /// epoch does NOT erase errors already observed by an earlier consumer.
    mutating func finishDisplayReferences() {
        consumer = nil
        planeMemo.removeAll(keepingCapacity: true)
        sketchMemo.removeAll(keepingCapacity: true)
        for id in planes.keys.sorted(by: { $0.raw.uuidString < $1.raw.uuidString })
        where planes[id]?.definition != nil {
            _ = try? plane(PlaneRef(source: .construction(id)))
        }
        for id in sketches.keys.sorted(by: { $0.raw.uuidString < $1.raw.uuidString })
        where sketches[id]?.support != nil {
            _ = try? sketch(id)
        }
    }

    private func version(_ ref: GeometryVersionRef) throws -> GeometryVersionSnapshot {
        guard let index = indices[ref.writer] else { throw AssociativeReferenceError.missingWriter(ref) }
        if graph.nodes[index].suppressed { throw AssociativeReferenceError.suppressedWriter(ref) }
        if index >= (graph.rollbackIndex ?? graph.nodes.count) {
            throw AssociativeReferenceError.rolledBackWriter(ref)
        }
        if let consumer, let consumerIndex = indices[consumer], index >= consumerIndex {
            throw AssociativeReferenceError.forwardSource(ref)
        }
        if failedWriters.contains(ref.writer) { throw AssociativeReferenceError.failedWriter(ref) }
        guard let snapshot = snapshots[ref] else { throw AssociativeReferenceError.missingBodyVersion(ref) }
        return snapshot
    }

    /// The frozen writer's replay stamp. Reuses the same `version()` checks so
    /// an angle datum cannot use a stale cache after its source writer moved.
    private func versionFingerprint(_ definition: ConstructionPlaneDefinition) throws -> UInt64 {
        switch definition {
        case let .offset(payload): return try version(payload.sourceVersion).stamp
        case let .angle(payload): return try version(payload.sourceVersion).stamp
        case .threePoints: return 0
        }
    }

    /// One semantic point on a resolved sketch. Missing/replaced identities
    /// refuse; no nearest-point or index-only fallback exists.
    private static func anchorPoint(_ ref: SketchAnchorRef, in sketch: Sketch) throws -> SIMD2<Double> {
        guard let entity = sketch.entities.first(where: { $0.id == ref.entityID }) else {
            throw AssociativeReferenceError.missingAnchorEntity(
                sketch: sketch.id, entity: ref.entityID)
        }
        guard let point = entity.anchorPoint(for: ref.role) else {
            throw AssociativeReferenceError.unsupportedAnchorRole(
                sketch: sketch.id, entity: ref.entityID, role: ref.role.rawValue)
        }
        return point
    }

    private static func exactFace(source: FaceRef,
                                  version: GeometryVersionRef,
                                  snapshot: GeometryVersionSnapshot) throws -> SourceFaceGeometry {
        // A name is resolved in the KERNEL map, never against render triangles.
        // We intentionally reject signature/nearest-face guesses in this slice.
        guard case .planar = source.signature.kind,
              let name = source.elementName,
              let brep = snapshot.body.brep else {
            throw AssociativeReferenceError.exactNamedPlaneRequired(version)
        }
        if case .kernelFace = name.source {
            throw AssociativeReferenceError.exactNamedPlaneRequired(version)
        }
        let indices = snapshot.kernelNames.compactMap { $0.value == name ? $0.key : nil }
        guard !indices.isEmpty else { throw AssociativeReferenceError.missingNamedFace(version) }
        guard indices.count == 1 else { throw AssociativeReferenceError.ambiguousFace(version) }
        let faces = OCCTKernel.faceInfo(brep).filter { $0.index == indices[0] }
        guard faces.count == 1, let face = faces.first,
              face.area.isFinite, face.area > 0,
              let signature = face.signature, case .planar = signature.kind else {
            throw AssociativeReferenceError.exactNamedPlaneRequired(version)
        }
        return SourceFaceGeometry(bodyID: version.bodyID, centroid: face.centroid, normal: face.normal)
    }

    private func typed(_ error: Error) -> AssociativeReferenceError {
        if let error = error as? AssociativeReferenceError { return error }
        if let geometry = error as? AssociativeGeometryError {
            switch geometry {
            case let .degenerateAnchorPoints(reason):
                return .degenerateAnchorPoints(reason)
            case let .invalidHingeAxis(reason):
                return .invalidHingeAxis(reason)
            default:
                break
            }
        }
        return .invalidDefinition(error.localizedDescription)
    }

    private mutating func remember(_ error: AssociativeReferenceError, at key: AssociativeReferenceKey) {
        if referenceErrors[key] == nil { referenceErrors[key] = error }
    }

    private func failureStamp(key: AssociativeReferenceKey, error: AssociativeReferenceError) -> UInt64 {
        var f = EvalFingerprint()
        f.combine(EvalFingerprint.hash(key))
        f.combine(EvalFingerprint.hash(error))
        return f.value
    }
}
