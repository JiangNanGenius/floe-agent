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

    /// The result of an insert: the merged document plus what the guest's IDs
    /// became, so a caller can select or name the newly inserted work.
    nonisolated struct Insertion: Sendable {
        var document: DesignDocument
        var featureIDs: [FeatureID]
        var bodyIDs: [BodyID]
        var sketchIDs: [SketchID]
    }

    /// Insert `guest` into `host`, offsetting the incoming geometry by
    /// `translation` (the spec repositions with Move/Rotate afterwards; an
    /// offset just keeps it from landing inside the host).
    ///
    /// The guest's feature nodes are APPENDED, so the host's history is
    /// untouched and the inserted steps are individually editable at the end.
    static func insert(
        _ guest: DesignDocument, into host: DesignDocument,
        translation: SIMD3<Double> = .zero
    ) -> Insertion {
        let map = IDMap(guest)
        var merged = host

        // Sketches, planes, images, symbols: identity re-minted, geometry kept.
        for sketch in guest.sketches {
            merged.sketches.append(map.remap(sketch, translation: translation))
        }
        for plane in guest.planes {
            merged.planes.append(map.remap(plane, translation: translation))
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
        merged.variables += guest.variables.filter { !existing.contains($0.name) }

        return Insertion(
            document: merged,
            featureIDs: featureIDs,
            bodyIDs: map.bodies.values.map { $0 },
            sketchIDs: map.sketches.values.map { $0 })
    }

    /// Names in `guest` that clash with a host variable and are therefore
    /// dropped by `insert` — surface these so the user is not silently ignored.
    static func droppedVariableNames(
        inserting guest: DesignDocument, into host: DesignDocument
    ) -> [String] {
        let existing = Set(host.variables.map(\.name))
        return guest.variables.map(\.name).filter { existing.contains($0) }
    }

    // MARK: - Identity remapping

    /// Fresh identities for everything in the guest, minted once up front so a
    /// reference can be rewritten before the thing it points at is visited.
    private struct IDMap {
        var features = [FeatureID: FeatureID]()
        var bodies = [BodyID: BodyID]()
        var sketches = [SketchID: SketchID]()
        var planes = [ConstructionPlaneID: ConstructionPlaneID]()
        var entities = [UUID: UUID]()

        init(_ guest: DesignDocument) {
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
        }

        // Unknown ids keep their value: a ref into geometry the guest did not
        // carry is already broken, and inventing an id would hide that.
        func newFeature(_ id: FeatureID) -> FeatureID { features[id] ?? id }
        func newBody(_ id: BodyID) -> BodyID { bodies[id] ?? id }
        func newSketch(_ id: SketchID) -> SketchID { sketches[id] ?? id }
        func newPlane(_ id: ConstructionPlaneID) -> ConstructionPlaneID { planes[id] ?? id }
        func newEntity(_ id: UUID) -> UUID { entities[id] ?? id }

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
                lineDimensionKinds: Dictionary(uniqueKeysWithValues:
                    sketch.lineDimensionKinds.map { (newEntity($0.key), $0.value) }))
        }

        func remap(_ ref: ConstraintRef) -> ConstraintRef {
            ConstraintRef(entityID: newEntity(ref.entityID), role: ref.role, rectangleEdge: ref.rectangleEdge)
        }

        func remap(_ plane: ConstructionPlane, translation: SIMD3<Double>) -> ConstructionPlane {
            ConstructionPlane(
                id: newPlane(plane.id), plane: moved(plane.plane, by: translation),
                size: plane.size, isHidden: plane.isHidden)
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
            // Carry the CSG mesh and analytic solid: an inserted project's
            // smooth cylinders must not degrade to their tessellation
            // (2026-08-25 review, C4).
            result.euclid = body.euclid
            result.brep = body.brep
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
            case .ground: ref
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
            }
        }

        func remap(_ ref: FaceRef, translation: SIMD3<Double>) -> FaceRef {
            var result = ref
            result.body = remap(ref.body)
            result.creator = newFeature(ref.creator)
            result.signature.centroid += translation
            // The plane offset is n·centroid, so it moves with the geometry.
            result.signature.planeOffset += simd_dot(ref.signature.normal, translation)
            return result
        }

        func remap(_ ref: EdgeRef, translation: SIMD3<Double>) -> EdgeRef {
            var result = ref
            result.body = remap(ref.body)
            result.signature.midpoint += translation
            return result
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
                    distance: distance, symmetric: symmetric, boolean: boolean,
                    extraProfiles: extra.map(remap))
            case let .draftExtrude(profile, plane, distance, taperAngle, symmetric, boolean):
                return .draftExtrude(
                    profile: remap(profile), plane: remap(plane, translation: t),
                    distance: distance, taperAngle: taperAngle,
                    symmetric: symmetric, boolean: boolean)
            case let .revolve(profile, plane, axis, angle, boolean):
                return .revolve(
                    profile: remap(profile), plane: remap(plane, translation: t),
                    axis: remap(axis), angle: angle, boolean: boolean)
            case let .sweep(profile, plane, spine, boolean, helix):
                var movedHelix = helix
                movedHelix?.axisPoint += t          // the exact spine moves with the sampled one
                return .sweep(
                    profile: remap(profile), plane: remap(plane, translation: t),
                    spine: spine.map { PointWrapper($0.point + t) }, boolean: boolean,
                    helix: movedHelix)
            case let .loft(sections, boolean):
                return .loft(sections: sections.map(remap), boolean: boolean)
            case let .boolean(op, target, tools):
                return .boolean(kind: op, target: remap(target), tools: tools.map(remap))
            case let .transform(body, delta):
                return .transform(body: remap(body), delta: delta)
            case let .mirror(body, plane, keepOriginal):
                return .mirror(body: remap(body), plane: remap(plane, translation: t),
                               keepOriginal: keepOriginal)
            case let .pattern(body, spec):
                return .pattern(body: remap(body), spec: spec)
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
