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
    /// M08 associative construction axis (the consumer relationship a circular
    /// pattern stores instead of a baked world line).
    case axis(ConstructionAxisID)
    /// M08 associative datum point.
    case datumPoint(DatumPointID)
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
    // M08 construction axes / datum points.
    case missingAxis(ConstructionAxisID)
    case missingDatumPoint(DatumPointID)
    /// The frozen writer snapshot has no current edge matching the persisted
    /// reference (or more than one equally good match) — never a nearest-edge
    /// fallback.
    case missingEdge(GeometryVersionRef)
    case ambiguousEdge(GeometryVersionRef)
    /// The source face/edge kind cannot define this datum (a non-planar face
    /// axis, a non-straight edge).
    case unsupportedAxisSource(GeometryVersionRef)
    /// A cylinder axis whose named face is no longer a cylindrical kernel
    /// face (or whose exact axis point is missing). Never falls back to a
    /// planar/nearest-face or a centroid-built line.
    case exactNamedCylinderRequired(GeometryVersionRef)
    case coincidentAxisPoints(String)
    case degenerateAxis(String)
    case parallelSources(String)

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

/// One resolved M08 construction axis for a single consumer epoch.
nonisolated struct ResolvedAssociativeAxis: Sendable {
    var geometry: ResolvedAxisGeometry
    var stamp: UInt64
}

/// One resolved M08 datum point for a single consumer epoch.
nonisolated struct ResolvedAssociativePoint: Sendable {
    var geometry: ResolvedDatumPointGeometry
    var stamp: UInt64
}

/// Capture this from the ORIGINAL graph/records, then validate a proposed
/// reorder/delete/suppress against it. No source writer is inferred or rebound
/// from the candidate order. The existing M26 body-version dependency map can
/// be supplied as featureDependencies; it remains the authority for body refs.
nonisolated struct AssociativeDependencyGraph: Sendable {
    private var edges: [AssociativeReferenceKey: Set<AssociativeReferenceKey>] = [:]
    /// Writer version each DATUM freezes, regardless of kind. M07 planes and
    /// M08 axes/points share one map so the M26 writer validation is one walk.
    private var versionsByReference: [AssociativeReferenceKey: GeometryVersionRef] = [:]
    private var definitionPlaneIDs: Set<ConstructionPlaneID> = []
    private var definitionAxisIDs: Set<ConstructionAxisID> = []
    private var definitionPointIDs: Set<DatumPointID> = []
    private var featureIDs: Set<FeatureID> = []
    private var planeIDs: Set<ConstructionPlaneID> = []
    private var axisIDs: Set<ConstructionAxisID> = []
    private var pointIDs: Set<DatumPointID> = []
    private var sketchIDs: Set<SketchID> = []

    init(graph: FeatureGraph, sketches: [Sketch], planes: [ConstructionPlane],
         axes: [ConstructionAxis] = [], datumPoints: [DatumPoint] = [],
         featureDependencies: [FeatureID: Set<FeatureID>] = [:]) {
        for node in graph.nodes {
            featureIDs.insert(node.id)
            edges[.feature(node.id)] = Set(node.referencedSketchIDs.map { .sketch($0) })
                .union(node.referencedConstructionPlaneIDs.map { .plane($0) })
                .union(node.referencedConstructionAxisIDs.map { .axis($0) })
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
                versionsByReference[.plane(plane.id)] = definition.sourceVersion
                edges[.plane(plane.id)] = [.feature(definition.sourceVersion.writer)]
            case let .angle(definition)?:
                definitionPlaneIDs.insert(plane.id)
                versionsByReference[.plane(plane.id)] = definition.sourceVersion
                edges[.plane(plane.id)] = [.feature(definition.sourceVersion.writer)]
            case let .threePoints(definition)?:
                definitionPlaneIDs.insert(plane.id)
                // Every point sketch is a real support writer dependency:
                // a sketch may itself be supported by another associative
                // plane, so the walk continues through its own edges.
                edges[.plane(plane.id)] = Set(definition.points.map { .sketch($0.sketchID) })
            }
        }
        for axis in axes {
            axisIDs.insert(axis.id)
            guard let definition = axis.definition else { continue }
            definitionAxisIDs.insert(axis.id)
            edges[.axis(axis.id)] = Self.dependencies(
                of: definition, frozen: { versionsByReference[.axis(axis.id)] = $0 })
        }
        for point in datumPoints {
            pointIDs.insert(point.id)
            guard let definition = point.definition else { continue }
            definitionPointIDs.insert(point.id)
            edges[.datumPoint(point.id)] = Self.dependencies(
                of: definition, frozen: { versionsByReference[.datumPoint(point.id)] = $0 })
        }
    }

    /// One axis definition's dependency edges. Face/edge sources depend on the
    /// writer whose snapshot they read; a two-point/axis-plane relation depends
    /// on the sketches/planes/axes/points it names, so removing or moving a
    /// parent is diagnosed even when no feature currently consumes the datum.
    private static func dependencies(
        of definition: ConstructionAxisDefinition,
        frozen: (GeometryVersionRef) -> Void
    ) -> Set<AssociativeReferenceKey> {
        switch definition {
        case let .face(payload):
            frozen(payload.sourceVersion)
            return [.feature(payload.sourceVersion.writer)]
        case let .edge(payload):
            frozen(payload.sourceVersion)
            return [.feature(payload.sourceVersion.writer)]
        case let .cylinder(payload):
            frozen(payload.sourceVersion)
            return [.feature(payload.sourceVersion.writer)]
        case let .twoPoints(payload):
            return Set(payload.points.map(Self.dependency(of:)))
        case let .twoPlanes(payload):
            return Set(payload.planes.map { .plane($0) })
        }
    }

    private static func dependencies(
        of definition: DatumPointDefinition,
        frozen: (GeometryVersionRef) -> Void
    ) -> Set<AssociativeReferenceKey> {
        switch definition {
        case let .faceCenter(payload):
            frozen(payload.sourceVersion)
            return [.feature(payload.sourceVersion.writer)]
        case let .edgePoint(payload):
            frozen(payload.sourceVersion)
            return [.feature(payload.sourceVersion.writer)]
        case let .twoPointMidpoint(payload):
            return Set(payload.points.map(Self.dependency(of:)))
        case let .axisPoint(payload):
            return [.axis(payload.axis)]
        case let .axisPlane(payload):
            return [.axis(payload.axis), .plane(payload.plane)]
        }
    }

    private static func dependency(of source: DatumPointSource) -> AssociativeReferenceKey {
        switch source {
        case let .sketchAnchor(anchor): return .sketch(anchor.sketchID)
        case let .datumPoint(id): return .datumPoint(id)
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
            case let .axis(id):
                guard axisIDs.contains(id) else { throw AssociativeReferenceError.missingAxis(id) }
            case let .datumPoint(id):
                guard pointIDs.contains(id) else { throw AssociativeReferenceError.missingDatumPoint(id) }
            case .feature: break
            }
            visiting.insert(key)
            path.append(key)
            if let version = versionsByReference[key] { versions.insert(version) }
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
            .union(definitionAxisIDs.map { .axis($0) })
            .union(definitionPointIDs.map { .datumPoint($0) })
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
        case let .axis(id): return "a:" + id.raw.uuidString
        case let .datumPoint(id): return "p:" + id.raw.uuidString
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
    private let axes: [ConstructionAxisID: ConstructionAxis]
    private let datumPoints: [DatumPointID: DatumPoint]
    private let variables: [String: Double]
    private let requestedVersions: Set<GeometryVersionRef>
    private let indices: [FeatureID: Int]
    private var consumer: FeatureID?
    private var planeMemo: [ConstructionPlaneID: ResolvedAssociativePlane] = [:]
    private var sketchMemo: [SketchID: ResolvedAssociativeSketch] = [:]
    private var axisMemo: [ConstructionAxisID: ResolvedAssociativeAxis] = [:]
    private var pointMemo: [DatumPointID: ResolvedAssociativePoint] = [:]
    private var failedWriters: Set<FeatureID> = []
    private var dependencyGraph: AssociativeDependencyGraph

    private(set) var snapshots: [GeometryVersionRef: GeometryVersionSnapshot] = [:]
    private(set) var lastBodyWriters: [BodyID: FeatureID] = [:]
    private(set) var resolvedPlaneUpdates: [ConstructionPlaneID: SketchPlane] = [:]
    private(set) var resolvedSketchSupportUpdates: [SketchID: SketchPlane] = [:]
    private(set) var resolvedAxisUpdates: [ConstructionAxisID: ResolvedAxisGeometry] = [:]
    private(set) var resolvedDatumPointUpdates: [DatumPointID: ResolvedDatumPointGeometry] = [:]
    private(set) var referenceErrors: [AssociativeReferenceKey: AssociativeReferenceError] = [:]

    init(graph: FeatureGraph, sketches: [Sketch], planes: [ConstructionPlane],
         axes: [ConstructionAxis] = [], datumPoints: [DatumPoint] = [],
         variables: [String: Double] = [:], requestedVersions: Set<GeometryVersionRef> = []) {
        self.graph = graph
        self.sketches = Dictionary(sketches.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.planes = Dictionary(planes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.axes = Dictionary(axes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.datumPoints = Dictionary(datumPoints.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.variables = variables
        dependencyGraph = AssociativeDependencyGraph(
            graph: graph, sketches: sketches, planes: planes,
            axes: axes, datumPoints: datumPoints)
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
        for axis in axes {
            if let version = axis.definition?.writerVersion { requested.insert(version) }
        }
        for point in datumPoints {
            if let version = point.definition?.writerVersion { requested.insert(version) }
        }
        self.requestedVersions = requested
    }

    mutating func begin(_ node: FeatureNode) {
        consumer = node.id
        planeMemo.removeAll(keepingCapacity: true)
        sketchMemo.removeAll(keepingCapacity: true)
        axisMemo.removeAll(keepingCapacity: true)
        pointMemo.removeAll(keepingCapacity: true)
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
        axes: [ConstructionAxisID: UInt64],
        error: AssociativeReferenceError?
    ) {
        var sketchHashes: [SketchID: UInt64] = [:]
        var planeHashes: [ConstructionPlaneID: UInt64] = [:]
        var axisHashes: [ConstructionAxisID: UInt64] = [:]
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
        for id in node.referencedConstructionAxisIDs.sorted(by: { $0.raw.uuidString < $1.raw.uuidString }) {
            do { axisHashes[id] = try axis(id).stamp }
            catch {
                let error = typed(error)
                remember(error, at: .axis(id))
                axisHashes[id] = failureStamp(key: .axis(id), error: error)
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { remember(firstError, at: .feature(node.id)) }
        return (sketchHashes, planeHashes, axisHashes, firstError)
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

    // MARK: M08 construction axes and datum points

    /// Resolve one construction axis for the current consumer epoch.
    ///
    /// A nil definition is the legacy absolute line and the ONLY case allowed
    /// to use the cached frame. Every present definition kind resolves from
    /// CURRENT source geometry; an unknown semantic version, a missing or
    /// degenerate source, a cycle or a forward/suppressed/rolled-back writer
    /// throws (reported as a broken reference), never a cached-line fallback.
    mutating func axis(_ id: ConstructionAxisID) throws -> ResolvedAssociativeAxis {
        if let memo = axisMemo[id] { return memo }
        do {
            try dependencyGraph.checkCycle(from: .axis(id))
            guard let record = axes[id] else { throw AssociativeReferenceError.missingAxis(id) }
            guard let definition = record.definition else {
                let value = ResolvedAssociativeAxis(
                    geometry: record.resolvedLine, stamp: EvalFingerprint.hash(record))
                axisMemo[id] = value
                return value
            }
            guard definition.isSupportedSemanticVersion else {
                throw AssociativeReferenceError.invalidDefinition(
                    "unsupported construction-axis definition version \(definition.semanticVersion)")
            }
            var stamps: [UInt64] = []
            let geometry: ResolvedAxisGeometry
            switch definition {
            case let .face(payload):
                var edited = payload
                if let formula = payload.offset.formula {
                    guard let value = ExpressionEvaluator.evaluate(formula, variables: variables),
                          value.isFinite else {
                        throw AssociativeReferenceError.invalidFormula(formula)
                    }
                    edited.offset.value = value
                }
                try edited.validate()
                let snapshot = try version(payload.sourceVersion)
                let source = try Self.exactFaceWithArea(
                    source: payload.source, version: payload.sourceVersion, snapshot: snapshot)
                let extent = max(source.area.squareRoot() * snapshot.body.transform.scale, 1e-6)
                geometry = try edited.resolvedAxis(
                    face: source.geometry, bodyTransform: snapshot.body.transform, extent: extent)
                stamps.append(snapshot.stamp)
            case let .edge(payload):
                var edited = payload
                if let formula = payload.offset.formula {
                    guard let value = ExpressionEvaluator.evaluate(formula, variables: variables),
                          value.isFinite else {
                        throw AssociativeReferenceError.invalidFormula(formula)
                    }
                    edited.offset.value = value
                }
                try edited.validate()
                let snapshot = try version(payload.sourceVersion)
                let edge = try Self.exactEdgeGeometry(
                    source: payload.source, version: payload.sourceVersion, snapshot: snapshot)
                geometry = try edited.resolvedAxis(
                    edge: edge, bodyTransform: snapshot.body.transform,
                    scale: snapshot.body.transform.scale)
                stamps.append(snapshot.stamp)
            case let .cylinder(payload):
                // A cylinder axis follows the face's analytic line and has no
                // offset slot, so there is no formula to re-evaluate here.
                try payload.validate()
                let snapshot = try version(payload.sourceVersion)
                let cylinder = try Self.exactCylinderSource(
                    source: payload.source, version: payload.sourceVersion, snapshot: snapshot)
                geometry = try payload.resolvedAxis(
                    cylinder: cylinder, bodyTransform: snapshot.body.transform,
                    scale: snapshot.body.transform.scale)
                stamps.append(snapshot.stamp)
            case let .twoPoints(payload):
                try payload.validate()
                var world: [SIMD3<Double>] = []
                for source in payload.points {
                    world.append(try worldPoint(source, stamps: &stamps))
                }
                geometry = try payload.resolvedAxis(worldPoints: world)
            case let .twoPlanes(payload):
                try payload.validate()
                var frames: [SketchPlane] = []
                var sizes: [Double] = []
                for planeID in payload.planes {
                    let resolved = try plane(PlaneRef(source: .construction(planeID)))
                    frames.append(resolved.plane)
                    sizes.append(planes[planeID]?.size ?? 100)
                    stamps.append(resolved.stamp)
                }
                geometry = try payload.resolvedAxis(planes: frames, sizes: sizes)
            }
            var f = EvalFingerprint()
            f.combine(EvalFingerprint.hash(definition))
            for stamp in stamps { f.combine(stamp) }
            f.combine(EvalFingerprint.hash(geometry))
            let value = ResolvedAssociativeAxis(geometry: geometry, stamp: f.value)
            axisMemo[id] = value
            resolvedAxisUpdates[id] = geometry
            return value
        } catch {
            let error = typed(error)
            remember(error, at: .axis(id))
            throw error
        }
    }

    /// Resolve one datum point for the current consumer epoch. Same rules as
    /// `axis(_:)`: current sources, explicit refusal, no cached-position
    /// fallback for a present definition.
    mutating func point(_ id: DatumPointID) throws -> ResolvedAssociativePoint {
        if let memo = pointMemo[id] { return memo }
        do {
            try dependencyGraph.checkCycle(from: .datumPoint(id))
            guard let record = datumPoints[id] else {
                throw AssociativeReferenceError.missingDatumPoint(id)
            }
            guard let definition = record.definition else {
                let value = ResolvedAssociativePoint(
                    geometry: ResolvedDatumPointGeometry(position: record.position),
                    stamp: EvalFingerprint.hash(record))
                pointMemo[id] = value
                return value
            }
            guard definition.isSupportedSemanticVersion else {
                throw AssociativeReferenceError.invalidDefinition(
                    "unsupported datum-point definition version \(definition.semanticVersion)")
            }
            var stamps: [UInt64] = []
            let geometry: ResolvedDatumPointGeometry
            switch definition {
            case let .faceCenter(payload):
                try payload.validate()
                let snapshot = try version(payload.sourceVersion)
                let source = try Self.exactFaceWithArea(
                    source: payload.source, version: payload.sourceVersion, snapshot: snapshot)
                geometry = try payload.resolvedPoint(
                    face: source.geometry, bodyTransform: snapshot.body.transform)
                stamps.append(snapshot.stamp)
            case let .edgePoint(payload):
                var edited = payload
                if let formula = payload.offset.formula {
                    guard let value = ExpressionEvaluator.evaluate(formula, variables: variables),
                          value.isFinite else {
                        throw AssociativeReferenceError.invalidFormula(formula)
                    }
                    edited.offset.value = value
                }
                try edited.validate()
                let snapshot = try version(payload.sourceVersion)
                let edge = try Self.exactEdgeGeometry(
                    source: payload.source, version: payload.sourceVersion, snapshot: snapshot)
                geometry = try edited.resolvedPoint(
                    edge: edge, bodyTransform: snapshot.body.transform)
                stamps.append(snapshot.stamp)
            case let .twoPointMidpoint(payload):
                try payload.validate()
                var world: [SIMD3<Double>] = []
                for source in payload.points {
                    world.append(try worldPoint(source, stamps: &stamps))
                }
                geometry = try payload.resolvedPoint(worldPoints: world)
            case let .axisPoint(payload):
                var edited = payload
                if let formula = payload.offset.formula {
                    guard let value = ExpressionEvaluator.evaluate(formula, variables: variables),
                          value.isFinite else {
                        throw AssociativeReferenceError.invalidFormula(formula)
                    }
                    edited.offset.value = value
                }
                try edited.validate()
                let resolvedAxis = try axis(payload.axis)
                geometry = try edited.resolvedPoint(axis: resolvedAxis.geometry)
                stamps.append(resolvedAxis.stamp)
            case let .axisPlane(payload):
                try payload.validate()
                let resolvedAxis = try axis(payload.axis)
                let resolvedPlane = try plane(PlaneRef(source: .construction(payload.plane)))
                stamps.append(resolvedAxis.stamp)
                stamps.append(resolvedPlane.stamp)
                geometry = try payload.resolvedPoint(
                    axis: resolvedAxis.geometry, plane: resolvedPlane.plane)
            }
            var f = EvalFingerprint()
            f.combine(EvalFingerprint.hash(definition))
            for stamp in stamps { f.combine(stamp) }
            f.combine(EvalFingerprint.hash(geometry))
            let value = ResolvedAssociativePoint(geometry: geometry, stamp: f.value)
            pointMemo[id] = value
            resolvedDatumPointUpdates[id] = geometry
            return value
        } catch {
            let error = typed(error)
            remember(error, at: .datumPoint(id))
            throw error
        }
    }

    /// One persisted point source in world millimetres, through the same
    /// current-resolution rules the rest of the resolver uses.
    private mutating func worldPoint(
        _ source: DatumPointSource,
        stamps: inout [UInt64]
    ) throws -> SIMD3<Double> {
        switch source {
        case let .sketchAnchor(anchor):
            let resolved = try sketch(anchor.sketchID)
            let local = try Self.anchorPoint(anchor, in: resolved.sketch)
            stamps.append(resolved.stamp)
            return resolved.sketch.plane.toWorld(local)
        case let .datumPoint(id):
            let resolved = try point(id)
            stamps.append(resolved.stamp)
            return resolved.geometry.position
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
        for id in axes.keys.sorted(by: { $0.raw.uuidString < $1.raw.uuidString })
        where axes[id]?.definition != nil {
            _ = try? axis(id)
        }
        for id in datumPoints.keys.sorted(by: { $0.raw.uuidString < $1.raw.uuidString })
        where datumPoints[id]?.definition != nil {
            _ = try? point(id)
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
        try exactFaceWithArea(source: source, version: version, snapshot: snapshot).geometry
    }

    /// The same exact named planar face plus its area (the display extent an
    /// M08 face axis uses). Still planar-only: a curved face cannot produce an
    /// exact axis from this contract.
    private static func exactFaceWithArea(source: FaceRef,
                                          version: GeometryVersionRef,
                                          snapshot: GeometryVersionSnapshot)
        throws -> (geometry: SourceFaceGeometry, area: Double) {
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
        return (SourceFaceGeometry(bodyID: version.bodyID, centroid: face.centroid,
                                   normal: face.normal),
                face.area)
    }

    /// The frozen writer's CURRENT geometry for a persisted CYLINDRICAL face.
    ///
    /// Two independent checks gate this, both against the exact kernel face at
    /// the persisted stable name in the frozen writer's snapshot:
    ///   1. the document's `FaceRef` signature says "cylindrical", and
    ///   2. the face at that name IS a cylinder right now with a finite
    ///      analytic axis point.
    /// A face that stopped being a cylinder, a missing/ambiguous name and a
    /// missing axis point all refuse. There is no planar, nearest-face or
    /// centroid-built fallback: an axis slid along the wrong line would still
    /// look plausible while every consumer revolved about the wrong geometry.
    private static func exactCylinderSource(
        source: FaceRef,
        version: GeometryVersionRef,
        snapshot: GeometryVersionSnapshot
    ) throws -> SourceCylinderGeometry {
        guard case .cylindrical = source.signature.kind,
              let name = source.elementName,
              let brep = snapshot.body.brep else {
            throw AssociativeReferenceError.exactNamedCylinderRequired(version)
        }
        if case .kernelFace = name.source {
            throw AssociativeReferenceError.exactNamedCylinderRequired(version)
        }
        let indices = snapshot.kernelNames.compactMap { $0.value == name ? $0.key : nil }
        guard !indices.isEmpty else { throw AssociativeReferenceError.missingNamedFace(version) }
        guard indices.count == 1 else { throw AssociativeReferenceError.ambiguousFace(version) }
        let faces = OCCTKernel.faceInfo(brep).filter { $0.index == indices[0] }
        guard faces.count == 1, let face = faces.first,
              face.area.isFinite, face.area > 0,
              let signature = face.signature, case let .cylindrical(radius) = signature.kind,
              radius.isFinite, radius > 0,
              let axisPoint = face.axisPoint else {
            throw AssociativeReferenceError.exactNamedCylinderRequired(version)
        }
        // Display-only axial size: a cylinder face's own bounded extent is not
        // part of the face contract, so keep the R1 rule (sqrt area, which is
        // the exact square/circle size for a planar face) but never shorter
        // than the diameter, which is the face's smallest meaningful span.
        let extent = max(2 * radius, face.area.squareRoot())
        return SourceCylinderGeometry(
            bodyID: version.bodyID, centroid: face.centroid,
            axisPoint: axisPoint, axisDirection: face.normal,
            radius: radius, extent: extent)
    }

    /// The frozen writer's CURRENT geometry for a persisted straight edge.
    ///
    /// The `EdgeRef` signature is the document's existing edge identity policy
    /// (M26 owns how an edge is re-found); a miss refuses — there is no
    /// nearest-edge, index or lookalike fallback, and the source body is
    /// always the FROZEN writer's snapshot, never another body that happens to
    /// carry a similar crease.
    private static func exactEdgeGeometry(
        source: EdgeRef,
        version: GeometryVersionRef,
        snapshot: GeometryVersionSnapshot
    ) throws -> SourceAxisGeometry {
        let available = EdgeTopology.selectableEdges(from: snapshot.body.render)
        guard !available.isEmpty else { throw AssociativeReferenceError.missingEdge(version) }
        let aabb = snapshot.body.render.localAABB
        let scale = Double(simd_length(aabb.max - aabb.min))
        guard let resolved = EdgeTopology.resolve(
            source.signature, in: available, sizeScale: scale) else {
            throw AssociativeReferenceError.missingEdge(version)
        }
        func d(_ v: SIMD3<Float>) -> SIMD3<Double> {
            SIMD3<Double>(Double(v.x), Double(v.y), Double(v.z))
        }
        return SourceAxisGeometry.alongEdge(
            bodyID: version.bodyID, start: d(resolved.start), end: d(resolved.end))
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
        if let axisError = error as? AssociativeAxisPointError {
            switch axisError {
            case let .coincidentPoints(reason):
                return .coincidentAxisPoints(reason)
            case let .parallelSources(reason):
                return .parallelSources(reason)
            case let .degenerateDirection(reason), let .degenerateReference(reason):
                return .degenerateAxis(reason)
            case let .axisNotInPlane(reason):
                return .degenerateAxis(reason)
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
