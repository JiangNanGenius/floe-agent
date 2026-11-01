//
//  ProjectMergeKit.swift
//  openshape3d
//
//  Spec §6.5 Insert Project — bring another project into the open one WITH its
//  history, so its feature steps appear individually and stay editable (the
//  Wall Clock tutorial inserts a motor reference model this way).
//
//  What makes this more than appending arrays: every identity in the incoming
//  project — feature, body, sketch, construction plane, sketch entity — has to
//  be re-minted, and every reference to those identities rewritten in step. Two
//  projects created from the same template genuinely can carry the same UUIDs,
//  and a collision would silently rewire the host's history to the guest's
//  geometry. Re-minting unconditionally is the only safe rule, and it costs
//  nothing when there is no collision.
//
//  Everything is a pure value transform on `DesignDocument`, so the caller can
//  wrap it in one undoable command.
//

import Foundation
import simd

nonisolated enum ProjectMergeKit {

    nonisolated enum MergeError: Error, Equatable {
        case associativeVariableCollision([String])
        case missingAssociativeReferences([String])
        case invalidAssociativeExpressions([String])
        case associativeRollback
    }

    /// The result of an insert: the merged document plus what the guest's IDs
    /// became, so a caller can select or name the newly inserted work.
    nonisolated struct Insertion: Sendable {
        var document: DesignDocument
        var featureIDs: [FeatureID]
        var bodyIDs: [BodyID]
        var sketchIDs: [SketchID]
        /// M08 reference geometry that travelled with the insert.
        var axisIDs: [ConstructionAxisID] = []
        var datumPointIDs: [DatumPointID] = []
    }

    /// Insert `guest` into `host`, offsetting the incoming geometry by
    /// `translation` (the spec repositions with Move/Rotate afterwards; an
    /// offset just keeps it from landing inside the host).
    ///
    /// The guest's feature nodes are APPENDED, so the host's history is
    /// untouched and the inserted steps are individually editable at the end.
    /// Associated guests refuse unresolved identities or formula namespaces.
    /// If either document has associations, rollback markers are unsupported;
    /// throwing leaves both input values untouched.
    static func insert(
        _ guest: DesignDocument, into host: DesignDocument,
        translation: SIMD3<Double> = .zero
    ) throws -> Insertion {
        let associative = guest.planes.contains { $0.definition != nil }
            || guest.sketches.contains { $0.support != nil }
            || guest.axes.contains { $0.definition != nil }
            || guest.datumPoints.contains { $0.definition != nil }
        let hostAssociative = host.planes.contains { $0.definition != nil }
            || host.sketches.contains { $0.support != nil }
            || host.axes.contains { $0.definition != nil }
            || host.datumPoints.contains { $0.definition != nil }
        // One ordered rollback prefix cannot represent two independently
        // active histories. In particular, adding the guest count to a host
        // marker would activate the host's formerly rolled-back suffix.
        if (associative || hostAssociative),
           host.features.rollbackIndex != nil || guest.features.rollbackIndex != nil {
            throw MergeError.associativeRollback
        }
        if associative {
            // A formula keeps its source meaning only when all guest names
            // remain guest-owned. Do not silently bind it to a host variable.
            let hostNames = Set(host.variables.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() })
            let collisions = guest.variables.map(\.name).filter {
                hostNames.contains($0.trimmingCharacters(in: .whitespaces).lowercased())
            }
            guard collisions.isEmpty else {
                throw MergeError.associativeVariableCollision(collisions.sorted())
            }
            for plane in guest.planes {
                guard let definition = plane.definition else { continue }
                switch definition {
                case let .offset(payload): try payload.validate()
                case let .angle(payload): try payload.validate()
                case let .threePoints(payload): try payload.validate()
                }
            }
            for axis in guest.axes {
                guard let definition = axis.definition else { continue }
                guard definition.isSupportedSemanticVersion else {
                    throw MergeError.missingAssociativeReferences(
                        ["axis-definition-version:\(axis.id.raw.uuidString)"])
                }
                switch definition {
                case let .face(payload): try payload.validate()
                case let .edge(payload): try payload.validate()
                case let .cylinder(payload): try payload.validate()
                case let .twoPoints(payload): try payload.validate()
                case let .twoPlanes(payload): try payload.validate()
                }
            }
            for point in guest.datumPoints {
                guard let definition = point.definition else { continue }
                guard definition.isSupportedSemanticVersion else {
                    throw MergeError.missingAssociativeReferences(
                        ["point-definition-version:\(point.id.raw.uuidString)"])
                }
                switch definition {
                case let .faceCenter(payload): try payload.validate()
                case let .edgePoint(payload): try payload.validate()
                case let .twoPointMidpoint(payload): try payload.validate()
                case let .axisPoint(payload): try payload.validate()
                case let .axisPlane(payload): try payload.validate()
                }
            }
            try validateAssociativeExpressions(in: guest)
        }
        let map = IDMap(guest, rejectUnknownReferences: associative)
        var merged = host

        // Sketches, planes, images, symbols: identity re-minted, geometry kept.
        for sketch in guest.sketches {
            merged.sketches.append(map.remap(sketch, translation: translation))
        }
        for plane in guest.planes {
            merged.planes.append(map.remap(plane, translation: translation))
        }
        // M08 reference geometry travels with the insert (absolute axes used to
        // be dropped here); identities are re-minted like every other record.
        var axisIDs = [ConstructionAxisID]()
        for axis in guest.axes {
            let remapped = try map.remap(axis, translation: translation)
            axisIDs.append(remapped.id)
            merged.axes.append(remapped)
        }
        var datumPointIDs = [DatumPointID]()
        for point in guest.datumPoints {
            let remapped = map.remap(point, translation: translation)
            datumPointIDs.append(remapped.id)
            merged.datumPoints.append(remapped)
        }
        merged.images += guest.images
        merged.symbols += guest.symbols

        // Bodies carry the baked geometry that renders before the first rebuild.
        for body in guest.bodies {
            merged.bodies.append(map.remap(body, translation: translation))
        }

        // History last: its refs point at everything remapped above.
        var featureIDs = [FeatureID]()
        for node in guest.features.nodes {
            let remapped = map.remap(node, translation: translation)
            featureIDs.append(remapped.id)
            merged.features.nodes.append(remapped)
        }
        // The host's rollback marker counts ITS nodes; appending past it would
        // silently un-roll-back the inserted steps, so extend it to match.
        if let rollback = host.features.rollbackIndex {
            merged.features.rollbackIndex = rollback + guest.features.nodes.count
        }

        // Variables are named, not identified — a name already in use belongs
        // to the host, and overwriting it would retarget the host's formulas.
        let existing = Set(host.variables.map(\.name))
        let incomingVariables = guest.variables.filter { !existing.contains($0.name) }
        merged.variables += associative ? incomingVariables.map {
            Variable(name: $0.name, expression: $0.expression, value: $0.value)
        } : incomingVariables

        // Remapping visits every reference before publishing the pure result.
        // A broken guest reference must never be healed by a host UUID clash.
        guard map.missingReferences.isEmpty else {
            throw MergeError.missingAssociativeReferences(map.missingReferences.sorted())
        }
        return Insertion(
            document: merged,
            featureIDs: featureIDs,
            bodyIDs: map.bodies.values.map { $0 },
            sketchIDs: map.sketches.values.map { $0 },
            axisIDs: axisIDs,
            datumPointIDs: datumPointIDs)
    }

    /// Names in `guest` that clash with a host variable and are therefore
    /// dropped by `insert` — surface these so the user is not silently ignored.
    static func droppedVariableNames(
        inserting guest: DesignDocument, into host: DesignDocument
    ) -> [String] {
        let existing = Set(host.variables.map(\.name))
        return guest.variables.map(\.name).filter { existing.contains($0) }
    }

    /// Validate formulas in the guest namespace before host names exist. This
    /// uses the same slot table and parser as parameter edits; a missing guest
    /// variable must not become a valid, differently bound host expression.
    private static func validateAssociativeExpressions(in guest: DesignDocument) throws {
        let resolution = VariableTable.resolve(guest.variables)
        var failures = guest.variables.filter { resolution.errors[$0.id] != nil }.map {
            "variable:\($0.name)"
        }
        func validate(_ formula: String?, label: String) {
            guard let formula else { return }
            guard let value = ExpressionEvaluator.evaluate(formula, variables: resolution.values),
                  value.isFinite else { failures.append(label); return }
        }
        for node in guest.features.nodes {
            for slot in DocumentSession.expressionSlots(in: node.kind) {
                validate(slot.expr.formula, label: "feature:\(node.id.raw.uuidString):\(slot.name)")
            }
        }
        for plane in guest.planes {
            guard let definition = plane.definition else { continue }
            for slot in definition.expressionSlots {
                validate(slot.expr.formula,
                         label: "plane:\(plane.id.raw.uuidString):\(slot.name)")
            }
        }
        for axis in guest.axes {
            guard let definition = axis.definition else { continue }
            for slot in definition.expressionSlots {
                validate(slot.expr.formula,
                         label: "axis:\(axis.id.raw.uuidString):\(slot.name)")
            }
        }
        for point in guest.datumPoints {
            guard let definition = point.definition else { continue }
            for slot in definition.expressionSlots {
                validate(slot.expr.formula,
                         label: "point:\(point.id.raw.uuidString):\(slot.name)")
            }
        }
        for sketch in guest.sketches {
            for dimension in sketch.dimensions {
                validate(dimension.formula, label: "sketch:\(sketch.id.raw.uuidString):\(dimension.id.uuidString)")
            }
        }
        guard failures.isEmpty else {
            throw MergeError.invalidAssociativeExpressions(failures.sorted())
        }
    }

    // MARK: - Identity remapping

    /// Fresh identities for everything in the guest, minted once up front so a
    /// reference can be rewritten before the thing it points at is visited.
    private nonisolated final class IDMap {
        var features = [FeatureID: FeatureID]()
        var bodies = [BodyID: BodyID]()
        var sketches = [SketchID: SketchID]()
        var planes = [ConstructionPlaneID: ConstructionPlaneID]()
        var axes = [ConstructionAxisID: ConstructionAxisID]()
        var datumPoints = [DatumPointID: DatumPointID]()
        var entities = [UUID: UUID]()

        let rejectUnknownReferences: Bool
        private(set) var missingReferences = Set<String>()

        init(_ guest: DesignDocument, rejectUnknownReferences: Bool) {
            self.rejectUnknownReferences = rejectUnknownReferences
            for node in guest.features.nodes {
                features[node.id] = FeatureID()
                for id in node.outputBodyIDs { bodies[id] = BodyID() }
            }
            for body in guest.bodies where bodies[body.id] == nil {
                bodies[body.id] = BodyID()
            }
            for sketch in guest.sketches {
                sketches[sketch.id] = SketchID()
                for entity in sketch.entities { entities[entity.id] = UUID() }
            }
            for plane in guest.planes { planes[plane.id] = ConstructionPlaneID() }
            for axis in guest.axes { axes[axis.id] = ConstructionAxisID() }
            for point in guest.datumPoints { datumPoints[point.id] = DatumPointID() }
        }

        // Legacy absolute documents retain the old broken-reference behavior.
        // Associated guests reject unresolved identities before returning a
        // result, including provenance and recursively nested element names.
        private func missing(_ kind: String, _ id: UUID) {
            if rejectUnknownReferences { missingReferences.insert("\(kind):\(id.uuidString)") }
        }
        func newFeature(_ id: FeatureID) -> FeatureID {
            guard let result = features[id] else { missing("feature", id.raw); return id }
            return result
        }
        func newBody(_ id: BodyID) -> BodyID {
            guard let result = bodies[id] else { missing("body", id.raw); return id }
            return result
        }
        func newSketch(_ id: SketchID) -> SketchID {
            guard let result = sketches[id] else { missing("sketch", id.raw); return id }
            return result
        }
        func newPlane(_ id: ConstructionPlaneID) -> ConstructionPlaneID {
            guard let result = planes[id] else { missing("plane", id.raw); return id }
            return result
        }
        func newEntity(_ id: UUID) -> UUID {
            guard let result = entities[id] else { missing("entity", id); return id }
            return result
        }
        func newAxis(_ id: ConstructionAxisID) -> ConstructionAxisID {
            guard let result = axes[id] else { missing("axis", id.raw); return id }
            return result
        }
        func newDatumPoint(_ id: DatumPointID) -> DatumPointID {
            guard let result = datumPoints[id] else { missing("point", id.raw); return id }
            return result
        }

        // MARK: Model objects

        func remap(_ sketch: Sketch, translation: SIMD3<Double>) -> Sketch {
            Sketch(
                id: newSketch(sketch.id), name: sketch.name,
                plane: moved(sketch.plane, by: translation),
                entities: sketch.entities.map { reidentified($0, newEntity($0.id)) },
                isHidden: sketch.isHidden,
                constructionEntityIDs: Set(sketch.constructionEntityIDs.map(newEntity)),
                constraints: sketch.constraints.map {
                    SketchConstraint(id: UUID(), kind: $0.kind, refs: $0.refs.map(remap),
                                     circleTangency: $0.circleTangency)
                },
                dimensions: sketch.dimensions.map {
                    SketchDimension(id: UUID(), kind: $0.kind, refs: $0.refs.map(remap),
                                    value: $0.value, formula: $0.formula, labelOffset: $0.labelOffset,
                                    displayExpression: $0.displayExpression, rectangleLabelEdges: $0.rectangleLabelEdges,
                                    rectangleDrivingEdge: $0.rectangleDrivingEdge)
                },
                patternLinks: sketch.patternLinks.map {
                    SketchPatternLink(
                        id: UUID(), seedIDs: $0.seedIDs.map(newEntity),
                        instanceIDs: $0.instanceIDs.map { $0.map(newEntity) }, spec: $0.spec)
                },
                rectangleSizingAnchors: Dictionary(uniqueKeysWithValues:
                    sketch.rectangleSizingAnchors.map { (newEntity($0.key), $0.value) }),
                rotatedRectangleEdges: Dictionary(uniqueKeysWithValues:
                    sketch.rotatedRectangleEdges.map { (newEntity($0.key), $0.value.map(newEntity)) }),
                disconnectedEndpoints: sketch.disconnectedEndpoints.map(remap),
                circleRadiusDirections: Dictionary(uniqueKeysWithValues:
                    sketch.circleRadiusDirections.map { (newEntity($0.key), $0.value) }),
                lineDimensionKinds: Dictionary(uniqueKeysWithValues:
                    sketch.lineDimensionKinds.map { (newEntity($0.key), $0.value) }),
                support: sketch.support.map { remap($0, translation: translation) })
        }

        func remap(_ ref: ConstraintRef) -> ConstraintRef {
            ConstraintRef(entityID: newEntity(ref.entityID), role: ref.role, rectangleEdge: ref.rectangleEdge)
        }

        func remap(_ plane: ConstructionPlane, translation: SIMD3<Double>) -> ConstructionPlane {
            ConstructionPlane(
                id: newPlane(plane.id), plane: moved(plane.plane, by: translation),
                size: plane.size, isHidden: plane.isHidden,
                definition: plane.definition.map { remap($0, translation: translation) })
        }

        // MARK: M08 reference geometry

        /// `ConstructionAxis` validates its direction/length, so a corrupt
        /// guest row refuses the whole insert instead of being published with
        /// invented geometry.
        func remap(_ axis: ConstructionAxis, translation: SIMD3<Double>) throws -> ConstructionAxis {
            guard let remapped = ConstructionAxis(
                id: newAxis(axis.id),
                origin: axis.origin + translation,
                direction: axis.direction,
                length: axis.length,
                name: axis.name,
                isHidden: axis.isHidden,
                definition: axis.definition.map { remap($0, translation: translation) })
            else {
                throw MergeError.missingAssociativeReferences(
                    ["axis-geometry:\(axis.id.raw.uuidString)"])
            }
            return remapped
        }

        func remap(_ point: DatumPoint, translation: SIMD3<Double>) -> DatumPoint {
            DatumPoint(
                id: newDatumPoint(point.id),
                position: point.position + translation,
                name: point.name,
                isHidden: point.isHidden,
                definition: point.definition.map { remap($0, translation: translation) })
        }

        func remap(_ source: DatumPointSource) -> DatumPointSource {
            switch source {
            case let .sketchAnchor(anchor):
                return .sketchAnchor(SketchAnchorRef(
                    sketchID: newSketch(anchor.sketchID),
                    entityID: newEntity(anchor.entityID),
                    role: anchor.role))
            case let .datumPoint(id):
                return .datumPoint(newDatumPoint(id))
            }
        }

        func remap(_ definition: ConstructionAxisDefinition,
                   translation: SIMD3<Double>) -> ConstructionAxisDefinition {
            switch definition {
            case let .face(face):
                return .face(FaceAxisDefinition(
                    version: face.version,
                    source: remap(face.source, translation: translation),
                    sourceVersion: GeometryVersionRef(
                        bodyID: newBody(face.sourceVersion.bodyID),
                        writer: newFeature(face.sourceVersion.writer)),
                    attachment: face.attachment,
                    offset: face.offset))
            case let .edge(edge):
                return .edge(EdgeAxisDefinition(
                    version: edge.version,
                    source: remap(edge.source, translation: translation),
                    sourceVersion: GeometryVersionRef(
                        bodyID: newBody(edge.sourceVersion.bodyID),
                        writer: newFeature(edge.sourceVersion.writer)),
                    reference: edge.reference,
                    offset: edge.offset))
            case let .cylinder(cylinder):
                return .cylinder(CylinderAxisDefinition(
                    version: cylinder.version,
                    source: remap(cylinder.source, translation: translation),
                    sourceVersion: GeometryVersionRef(
                        bodyID: newBody(cylinder.sourceVersion.bodyID),
                        writer: newFeature(cylinder.sourceVersion.writer))))
            case let .twoPoints(twoPoint):
                return .twoPoints(TwoPointAxisDefinition(
                    version: twoPoint.version,
                    points: twoPoint.points.map(remap)))
            case let .twoPlanes(twoPlane):
                return .twoPlanes(TwoPlaneAxisDefinition(
                    version: twoPlane.version,
                    planes: twoPlane.planes.map(newPlane)))
            }
        }

        func remap(_ definition: DatumPointDefinition,
                   translation: SIMD3<Double>) -> DatumPointDefinition {
            switch definition {
            case let .faceCenter(face):
                return .faceCenter(FaceCenterPointDefinition(
                    version: face.version,
                    source: remap(face.source, translation: translation),
                    sourceVersion: GeometryVersionRef(
                        bodyID: newBody(face.sourceVersion.bodyID),
                        writer: newFeature(face.sourceVersion.writer))))
            case let .edgePoint(edge):
                return .edgePoint(EdgePointDefinition(
                    version: edge.version,
                    source: remap(edge.source, translation: translation),
                    sourceVersion: GeometryVersionRef(
                        bodyID: newBody(edge.sourceVersion.bodyID),
                        writer: newFeature(edge.sourceVersion.writer)),
                    offset: edge.offset))
            case let .twoPointMidpoint(midpoint):
                return .twoPointMidpoint(TwoPointMidpointDefinition(
                    version: midpoint.version,
                    points: midpoint.points.map(remap)))
            case let .axisPoint(axisPoint):
                return .axisPoint(AxisPointDefinition(
                    version: axisPoint.version,
                    axis: newAxis(axisPoint.axis),
                    offset: axisPoint.offset))
            case let .axisPlane(axisPlane):
                return .axisPlane(AxisPlanePointDefinition(
                    version: axisPlane.version,
                    axis: newAxis(axisPlane.axis),
                    plane: newPlane(axisPlane.plane)))
            }
        }

        /// `Body.id` is `let`, so the remapped body is rebuilt around its
        /// existing render mesh rather than mutated.
        func remap(_ body: Body, translation: SIMD3<Double>) -> Body {
            var result = Body(
                id: newBody(body.id), name: body.name, transform: body.transform,
                primitive: body.primitive, render: body.render,
                revision: body.meshRevision)
            result.transform.translation += translation
            result.isHidden = body.isHidden
            result.material = body.material
            result.materialFaceBindings = body.materialFaceBindings.map { binding in
                var mapped = binding
                // The material signature is body-local and does not translate.
                mapped.key.elementName = binding.key.elementName.map(remap)
                return mapped
            }
            // Carry the CSG mesh and analytic solid: an inserted project's
            // smooth cylinders must not degrade to their tessellation
            // (2026-08-25 review, C4).
            result.euclid = body.euclid
            result.brep = body.brep
            result.surfaceBRep = body.surfaceBRep
            return result
        }

        func remap(_ node: FeatureNode, translation: SIMD3<Double>) -> FeatureNode {
            FeatureNode(
                id: newFeature(node.id), name: node.name,
                kind: remap(node.kind, translation: translation),
                suppressed: node.suppressed,
                outputBodyIDs: node.outputBodyIDs.map(newBody))
        }

        // MARK: References inside a feature

        func remap(_ ref: BodyRef) -> BodyRef {
            BodyRef(producer: newFeature(ref.producer), bodyID: newBody(ref.bodyID))
        }

        func remap(_ ref: ProfileRef) -> ProfileRef {
            ProfileRef(
                sketchID: newSketch(ref.sketchID),
                entityIDs: ref.entityIDs.map(newEntity),
                holeEntityIDs: ref.holeEntityIDs.map { $0.map(newEntity) },
                seedPoint: ref.seedPoint)
        }

        func remap(_ ref: PlaneRef, translation: SIMD3<Double>) -> PlaneRef {
            switch ref.source {
            case let .sketch(id): PlaneRef(source: .sketch(newSketch(id)))
            case let .construction(id): PlaneRef(source: .construction(newPlane(id)))
            case .ground:
                translation == .zero ? ref : PlaneRef(source: .explicit(moved(.ground, by: translation)))
            case let .explicit(p): PlaneRef(source: .explicit(moved(p, by: translation)))
            }
        }

        /// A `RevolveAxis` is plane-LOCAL, so no translation appears here — the
        /// plane it belongs to carries the move.
        func remap(_ ref: AxisRef) -> AxisRef {
            switch ref.source {
            case let .sketchLine(id, entityID):
                AxisRef(source: .sketchLine(newSketch(id), newEntity(entityID)))
            case .explicit:
                ref
            case let .constructionAxis(id):
                // The axis row travels with the insert (re-minted above), so
                // the revolve keeps following its own source instead of being
                // rebound to an id that does not exist in the host.
                AxisRef(source: .constructionAxis(newAxis(id)))
            }
        }

        func remap(_ ref: FaceRef, translation: SIMD3<Double>) -> FaceRef {
            var result = ref
            result.body = remap(ref.body)
            result.creator = newFeature(ref.creator)
            result.elementName = ref.elementName.map(remap)
            result.signature.centroid += translation
            // The plane offset is n·centroid, so it moves with the geometry.
            result.signature.planeOffset += simd_dot(ref.signature.normal, translation)
            return result
        }

        func remap(_ ref: EdgeRef, translation: SIMD3<Double>) -> EdgeRef {
            var result = ref
            result.body = remap(ref.body)
            result.faceNames = ref.faceNames.map(remap)
            result.signature.midpoint += translation
            return result
        }

        func remap(_ name: ElementName) -> ElementName {
            let source: ElementName.Source
            switch name.source {
            case let .profileWall(entity, occurrence):
                source = .profileWall(entity: newEntity(entity), occurrence: occurrence)
            case let .opFace(operation, parents, index):
                source = .opFace(operation: newFeature(operation), parents: parents.map(remap), index: index)
            case let .operationFace(version, operation, parents, neighbors):
                source = .operationFace(version: version, operation: newFeature(operation),
                                        parents: parents.map(remap), neighbors: neighbors.map(remap))
            case .primitiveFace, .profileCap, .kernelFace, .holeFace(_):
                source = name.source
            }
            return ElementName(creator: newFeature(name.creator), source: source)
        }

        func remap(_ name: EdgeName) -> EdgeName {
            EdgeName(faceA: remap(name.faceA), faceB: remap(name.faceB), occurrence: name.occurrence,
                     schemeVersion: name.schemeVersion)
        }

        func remap(_ definition: ConstructionPlaneDefinition,
                   translation: SIMD3<Double>) -> ConstructionPlaneDefinition {
            switch definition {
            case let .offset(offset):
                return .offset(OffsetPlaneDefinition(
                    version: offset.version,
                    source: remap(offset.source, translation: translation),
                    sourceVersion: GeometryVersionRef(
                        bodyID: newBody(offset.sourceVersion.bodyID),
                        writer: newFeature(offset.sourceVersion.writer)),
                    distance: offset.distance,
                    // This frame is centroid-relative and body-local. Source
                    // geometry and placement already account for translation.
                    attachment: offset.attachment))
            case let .angle(angle):
                return .angle(AnglePlaneDefinition(
                    version: angle.version,
                    source: remap(angle.source, translation: translation),
                    sourceVersion: GeometryVersionRef(
                        bodyID: newBody(angle.sourceVersion.bodyID),
                        writer: newFeature(angle.sourceVersion.writer)),
                    hinge: angle.hinge,
                    angle: angle.angle,
                    attachment: angle.attachment))
            case let .threePoints(threePoint):
                // Anchor identities are sketch/entity ids, not coordinates;
                // remap both and let the resolver derive world millimetres
                // from the inserted sketches' own support planes.
                return .threePoints(ThreePointPlaneDefinition(
                    version: threePoint.version,
                    points: threePoint.points.map {
                        SketchAnchorRef(sketchID: newSketch($0.sketchID),
                                        entityID: newEntity($0.entityID),
                                        role: $0.role)
                    }))
            }
        }

        func remap(_ intent: BooleanIntent) -> BooleanIntent {
            BooleanIntent(op: intent.op, resolvedTargets: intent.resolvedTargets.map(remap))
        }

        func remap(_ kind: FeatureKind, translation t: SIMD3<Double>) -> FeatureKind {
            switch kind {
            case let .primitive(spec, placement):
                var moved = placement
                moved.translation += t
                return .primitive(spec: spec, placement: moved)
            case let .extrude(profile, plane, distance, symmetric, boolean, extra):
                return .extrude(
                    profile: remap(profile), plane: remap(plane, translation: t),
                    distance: distance, symmetric: symmetric, boolean: remap(boolean),
                    extraProfiles: extra.map(remap))
            case let .draftExtrude(profile, plane, distance, taperAngle, symmetric, boolean):
                return .draftExtrude(
                    profile: remap(profile), plane: remap(plane, translation: t),
                    distance: distance, taperAngle: taperAngle,
                    symmetric: symmetric, boolean: remap(boolean))
            case let .revolve(profile, plane, axis, angle, boolean):
                return .revolve(
                    profile: remap(profile), plane: remap(plane, translation: t),
                    axis: remap(axis), angle: angle, boolean: remap(boolean))
            case let .sweep(profile, plane, spine, boolean, helix):
                var movedHelix = helix
                movedHelix?.axisPoint += t          // the exact spine moves with the sampled one
                return .sweep(
                    profile: remap(profile), plane: remap(plane, translation: t),
                    spine: spine.map { PointWrapper($0.point + t) }, boolean: remap(boolean),
                    helix: movedHelix)
            case let .loft(sections, boolean):
                return .loft(sections: sections.map(remap), boolean: remap(boolean))
            case let .hole(target, profile, plane, spec):
                // Placement lives in the sketch/plane (both remapped); the
                // hole owns only type/depth/recess/direction.
                return .hole(target: remap(target), profile: remap(profile),
                             plane: remap(plane, translation: t), spec: spec)
            case let .boolean(op, target, tools):
                return .boolean(kind: op, target: remap(target), tools: tools.map(remap))
            case let .transform(body, delta):
                // Conjugate the world delta by the insertion translation:
                // delta' ∘ (T ∘ placement) = T ∘ delta ∘ placement.
                var translated = delta
                translated.translation += t - delta.rotation.act(t * delta.scale)
                return .transform(body: remap(body), delta: translated)
            case let .mirror(body, plane, keepOriginal):
                return .mirror(body: remap(body), plane: remap(plane, translation: t),
                               keepOriginal: keepOriginal)
            case let .pattern(body, spec):
                var translated = spec
                // The cached line moves with the insert; an ASSOCIATIVE axis
                // reference is re-minted and resolves its own (already moved)
                // source, so the cache is display-only there.
                if translated.kind == .circular { translated.center += t }
                if let ref = translated.axisRef {
                    translated.axisRef = ConstructionAxisRef(newAxis(ref.axisID))
                }
                return .pattern(body: remap(body), spec: translated)
            case let .pushPull(face, distance, mode):
                return .pushPull(face: remap(face, translation: t),
                                 distance: distance, mode: mode)
            case let .moveFace(face, delta):
                // The delta is intrinsic to the face's basis, so a translation
                // only remaps the face reference.
                return .moveFace(face: remap(face, translation: t), delta: delta)
            case let .scaleFace(face, factor):
                return .scaleFace(face: remap(face, translation: t), factor: factor)
            case let .rotateFace(face, angle, axis):
                // Angle + axis are intrinsic to the face's basis, so a translation
                // only remaps the face reference.
                return .rotateFace(face: remap(face, translation: t), angle: angle, axis: axis)
            case let .draftFace(face, origin, normal, angle):
                // The neutral plane is a WORLD plane, so its origin travels with
                // the merge while its normal (a direction) does not.
                return .draftFace(
                    face: remap(face, translation: t),
                    neutralOrigin: PointWrapper(origin.point + t),
                    neutralNormal: normal, angle: angle)
            case let .chamfer(body, edges, setback):
                return .chamfer(body: remap(body),
                                edges: edges.map { remap($0, translation: t) },
                                setback: setback)
            case let .fillet(body, edges, radius):
                return .fillet(body: remap(body),
                               edges: edges.map { remap($0, translation: t) },
                               radius: radius)
            case let .shell(body, openFaces, thickness):
                return .shell(body: remap(body),
                              openFaces: openFaces.map { remap($0, translation: t) },
                              thickness: thickness)
            case let .deleteFace(body, faces):
                return .deleteFace(body: remap(body),
                                   faces: faces.map { remap($0, translation: t) })
            case let .replaceFace(face, targetOrigin, targetNormal, flip):
                // The target ORIGIN is a point and moves with the merge; the
                // NORMAL is a direction and must not.
                return .replaceFace(
                    face: remap(face, translation: t),
                    targetOrigin: PointWrapper(targetOrigin.point + t),
                    targetNormal: targetNormal,
                    flip: flip)
            }
        }

        // MARK: Geometry

        private func moved(_ plane: SketchPlane, by t: SIMD3<Double>) -> SketchPlane {
            var result = plane
            result.origin += t
            return result
        }

        /// Re-stamp an entity with a new ID, keeping its geometry.
        private func reidentified(_ entity: SketchEntity, _ id: UUID) -> SketchEntity {
            switch entity {
            case let .line(_, a, b): .line(id: id, a: a, b: b)
            case let .rect(_, lo, hi): .rect(id: id, min: lo, max: hi)
            case let .circle(_, c, r): .circle(id: id, center: c, radius: r)
            case let .arc(_, c, r, s, e): .arc(id: id, center: c, radius: r, startAngle: s, endAngle: e)
            case let .ellipse(_, c, rx, ry, rot):
                .ellipse(id: id, center: c, radiusX: rx, radiusY: ry, rotation: rot)
            case let .polygon(_, c, r, n, rot):
                .polygon(id: id, center: c, radius: r, sides: n, rotation: rot)
            case let .spline(_, pts, closed): .spline(id: id, points: pts, closed: closed)
            }
        }
    }
}
