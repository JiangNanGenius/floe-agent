//
//  FloeCADDocument+NativeQueries.swift
//  FloeCADKit
//
//  Public read/check/export surface for the unified `cad.document` actions on
//  a native `.floecad` document: scoped queries over the real model graph,
//  handle location, structural checks and exact export bytes. Everything here
//  reads the live session graph (never a render image) and returns JSON-shaped
//  payloads through `CADCommandOutcome`, matching the rest of the facade.
//
//  SPDX-License-Identifier: MPL-2.0
//

import Foundation
import simd

public extension FloeCADDocument {

    /// Kernel build string (OCCT version) for capability discovery.
    static var kernelVersion: String { OCCTKernel.version }

    /// The typed native operation vocabulary this build advertises as
    /// executable. Guaranteed-refusal operations are not part of this list.
    static var nativeOperationNames: [String] { AgentExec.opNames }

    /// Guaranteed-refusal operations that remain parseable for historical
    /// callers. Capability discovery reports them as unavailable instead of
    /// advertising them as executable, while the executor keeps returning the
    /// original stable refusal. `available` is a real JSON boolean.
    static var unavailableNativeOperations: [[String: Any]] {
        AgentExec.unavailableOps.map { $0.jsonObject }
    }

    // MARK: Query

    /// One native read scope. Scopes handled here are model scopes; the host
    /// composes `assembly`/`drawings` from their services (the services own
    /// those JSON blobs and their report semantics).
    func nativeQueryJSON(_ payload: [String: Any]) -> CADCommandOutcome {
        let scope = payload["scope"] as? String ?? "snapshot"
        let document = session.document
        let limit = min(max(payload["limit"] as? Int ?? 200, 1), 500)
        let offset = max(payload["offset"] as? Int ?? 0, 0)

        func gatedDiscovery(_ value: Any) -> Any {
            if let fields = value as? [String: Any] {
                var result: [String: Any] = [:]
                for (key, child) in fields {
                    if key == "actions" || key.hasSuffix("_action") || key.hasSuffix("_actions") { continue }
                    result[key] = key == "editable" ? false : gatedDiscovery(child)
                }
                return result
            }
            if let rows = value as? [Any] { return rows.map(gatedDiscovery) }
            return value
        }
        func ok(_ object: [String: Any]) -> CADCommandOutcome {
            guard let block = session.writeBlock else { return Self.jsonOutcome(status: 200, object: object) }
            var gated = gatedDiscovery(object) as? [String: Any] ?? object
            gated["write_block"] = ["code": block.code, "message": block.message]
            return Self.jsonOutcome(status: 200, object: gated)
        }
        func fail(_ code: String, _ message: String) -> CADCommandOutcome {
            Self.jsonOutcome(status: 400, object: ["ok": false, "error": code, "message": message])
        }
        func window<T>(_ rows: [T]) -> [T] {
            guard offset < rows.count else { return [] }
            return Array(rows[offset..<min(offset + limit, rows.count)])
        }

        switch scope {
        case "snapshot":
            return CADCommandOutcome(status: 200, payload: snapshotJSON(),
                                     errorCode: nil, message: nil)

        case "scene":
            return ok(["ok": true, "scope": scope, "summary": sceneSummaryJSON()])

        case "camera":
            // Read-only: the selected projection/framing a scene was authored
            // with, plus every saved view. Selecting or saving a view is an
            // ordinary document edit, never a query side effect.
            return ok(["ok": true, "scope": scope, "camera": cameraSummaryJSON()])

        case "bodies":
            let rows: [[String: Any]] = document.bodies.map { body in
                var row: [String: Any] = [
                    "id": body.id.raw.uuidString,
                    "name": body.name,
                    "hidden": body.isHidden,
                    "analyticBRep": body.brep != nil,
                    "openSurfaceBRep": body.surfaceBRep != nil,
                    "volumeApplicable": body.brep?.containsSolid == true || (body.brep == nil && body.surfaceBRep == nil),
                    "triangles": body.render.indices.count / 3,
                    "volumeMM3": MeasureKit.volume(of: body),
                    "edgeSegments": body.edges.segments.count / 2,
                ]
                if let bounds = MeasureKit.boundingBox(bodies: [body]) {
                    row["bounds"] = [Self.vector(bounds.min), Self.vector(bounds.max)]
                }
                if let brep = body.brep {
                    let faces = OCCTKernel.faceInfo(brep)
                    row["faceCount"] = faces.count
                    row["planarFaces"] = faces.filter { $0.signature?.kind == .planar }.count
                }
                let generation = CADGeometryQueryGeneration(
                    scope: "faces", bodyID: body.id.raw,
                    documentRevision: revision, changeCount: session.changeCount,
                    meshRevision: body.meshRevision)
                row["query_token"] = generation.token
                row["generation"] = generation.jsonObject
                if let material = body.material {
                    row["material"] = material.summaryJSON
                }
                if !body.materialFaceBindings.isEmpty {
                    let resolutions = CADFaceMaterialResolver.resolve(body.materialFaceBindings,
                                                                      in: body)
                    let resolved = resolutions.compactMap { resolution -> [String: Any]? in
                        guard let index = resolution.resolvedIndex else { return nil }
                        return ["face_index": index,
                                "material_name": resolution.binding.material.materialName ?? "Material",
                                "material_id": resolution.binding.material.materialID ?? ""]
                    }
                    let unresolved = resolutions.filter { $0.resolvedIndex == nil }.count
                    row["face_material_bindings"] = [
                        "count": body.materialFaceBindings.count,
                        "resolved": resolved,
                        "unresolved_count": unresolved,
                    ]
                }
                return row
            }
            return ok(["ok": true, "scope": scope, "total": rows.count, "rows": window(rows)])

        case "sketches":
            // Entity detail is what makes an existing hole edit addressable:
            // the cut profile's diameter lives on its circle, so a caller must
            // be able to read that circle's stable entity id and CURRENT radius
            // (then atomically edit it through parameters updateSketchEntity).
            // `entities` stays the historical COUNT for compatibility; the
            // typed rows are `entityRows`.
            var usedBySketch: [SketchID: [String]] = [:]
            for node in document.features.nodes {
                for sketchID in node.referencedSketchIDs {
                    usedBySketch[sketchID, default: []].append(node.id.raw.uuidString)
                }
            }
            let entityRowLimit = 512
            let rows: [[String: Any]] = document.sketches.map { sketch in
                let entityRows: [[String: Any]] = sketch.entities.prefix(entityRowLimit).map { entity in
                    var row: [String: Any] = [
                        "id": entity.id.uuidString,
                        "construction": sketch.constructionEntityIDs.contains(entity.id),
                    ]
                    switch entity {
                    case let .line(_, a, b):
                        row["kind"] = "line"
                        row["a"] = [a.x, a.y]
                        row["b"] = [b.x, b.y]
                        row["lengthMM"] = simd_length(b - a)
                        row["editable"] = true
                        row["update_action"] = "updateSketchEntity"
                        row["update_fields"] = ["a", "b"]
                    case let .rect(_, low, high):
                        row["kind"] = "rect"
                        row["min"] = [low.x, low.y]
                        row["max"] = [high.x, high.y]
                        row["widthMM"] = abs(high.x - low.x)
                        row["heightMM"] = abs(high.y - low.y)
                        row["editable"] = true
                        row["update_action"] = "updateSketchEntity"
                        row["update_fields"] = ["min", "max", "center", "width", "height"]
                    case let .circle(_, center, radius):
                        row["kind"] = "circle"
                        row["center"] = [center.x, center.y]
                        row["radius"] = radius
                        row["diameterMM"] = radius * 2
                        row["parameter"] = "radius"
                        row["editable"] = true
                        row["update_action"] = "updateSketchEntity"
                        row["update_fields"] = ["center", "radius", "diameter"]
                    case let .arc(_, center, radius, startAngle, endAngle):
                        row["kind"] = "arc"
                        row["center"] = [center.x, center.y]
                        row["radius"] = radius
                        row["diameterMM"] = radius * 2
                        row["startAngleRadians"] = startAngle
                        row["endAngleRadians"] = endAngle
                        row["startAngleDegrees"] = startAngle * 180 / .pi
                        row["endAngleDegrees"] = endAngle * 180 / .pi
                        row["sweepAngleDegrees"] = SketchEntity.arcSweep(
                            startAngle: startAngle, endAngle: endAngle) * 180 / .pi
                        row["editable"] = true
                        row["update_action"] = "updateSketchEntity"
                        row["update_fields"] = ["center", "radius", "diameter",
                                               "start_angle_deg", "end_angle_deg",
                                               "sweep_angle_deg"]
                    case let .ellipse(_, center, radiusX, radiusY, rotation):
                        row["kind"] = "ellipse"
                        row["center"] = [center.x, center.y]
                        row["radiusX"] = radiusX
                        row["radiusY"] = radiusY
                        row["rotationRadians"] = rotation
                        row["rotationDegrees"] = rotation * 180 / .pi
                        row["editable"] = true
                        row["update_action"] = "updateSketchEntity"
                        row["update_fields"] = ["center", "radius_x", "radius_y",
                                               "rotation_deg"]
                    case let .polygon(_, center, radius, sides, rotation):
                        row["kind"] = "polygon"
                        row["center"] = [center.x, center.y]
                        row["radius"] = radius
                        row["sides"] = sides
                        row["rotationRadians"] = rotation
                        row["rotationDegrees"] = rotation * 180 / .pi
                        // Polygon remains query-only; its side/rotation edit
                        // has not been promoted with the M01 evidence.
                        row["editable"] = false
                    case let .spline(_, points, closed):
                        row["kind"] = "spline"
                        row["closed"] = closed
                        row["pointCount"] = points.count
                        row["points"] = points.map { [$0.x, $0.y] }
                        row["point_identity"] = "zero-based index in points"
                        // A legacy/degenerate spline with fewer than two fit
                        // points cannot be meaningfully edited or solved.
                        if points.count >= 2 {
                            row["editable"] = true
                            row["update_action"] = "updateSketchEntity"
                            row["update_fields"] = ["points", "point_index", "point"]
                        } else {
                            row["editable"] = false
                        }
                    }
                    row["constraint_count"] = sketch.constraints.filter {
                        $0.refs.contains(where: { $0.entityID == entity.id })
                    }.count
                    row["dimension_ids"] = sketch.dimensions.filter {
                        $0.refs.contains(where: { $0.entityID == entity.id })
                    }.map { $0.id.uuidString }
                    // Explicit one-entity deletion is discoverable from the row
                    // itself. Reference ownership (shared refs / pattern links)
                    // is enforced by the service, not by dropping the action.
                    row["delete_action"] = "deleteSketchEntity"
                    return row
                }
                var row: [String: Any] = [
                    "id": sketch.id.raw.uuidString,
                    "name": sketch.name,
                    "hidden": sketch.isHidden,
                    "entities": sketch.entities.count,
                    "entityRows": entityRows,
                    "entityRowLimit": entityRowLimit,
                    "entityRowsTruncated": sketch.entities.count > entityRowLimit,
                    "constructionEntities": sketch.constructionEntityIDs.count,
                    "constraints": sketch.constraints.count,
                    "dimensions": sketch.dimensions.count,
                    "plane": [
                        "origin": Self.vector(sketch.plane.origin),
                        "xAxis": Self.vector(sketch.plane.xAxis),
                        "yAxis": Self.vector(sketch.plane.yAxis),
                        "normal": Self.vector(sketch.plane.normal),
                    ],
                    "planeNormal": Self.vector(sketch.plane.normal),
                ]
                row["support"] = CADDatumService.supportJSON(sketch)
                if session.writeBlock == nil { row["set_support_action"] = "sketch.setSupport" }
                if isReadOnly {
                    row["support_status"] = "read_only"
                    row["support_frame_status"] = "cached"
                    if project.hasOpaqueAssociations { row["support"] = ["kind": "unsupported", "semantics": "opaque"] }
                    else if var support = row["support"] as? [String: Any] {
                        support.removeValue(forKey: "clear_action"); row["support"] = support
                    }
                } else if let block = session.writeBlock {
                    row["support_status"] = block.code
                    row["support_frame_status"] = "cached"
                    if var support = row["support"] as? [String: Any] {
                        support.removeValue(forKey: "clear_action"); row["support"] = support
                    }
                } else if let error = session.lastReferenceErrors[.sketch(sketch.id)] {
                    row["support_status"] = "error"
                    row["support_error"] = error.message
                } else { row["support_status"] = sketch.support == nil ? "explicit" : "resolved" }
                if let featureIDs = usedBySketch[sketch.id] {
                    row["usedByFeatureIDs"] = featureIDs.sorted()
                }
                return row
            }
            return ok(["ok": true, "scope": scope, "total": rows.count, "rows": window(rows),
                       "revision": revision, "change_count": session.changeCount])

        case "planes":
            let rows = CADDatumService.planeRows(document: self)
            return ok(["ok": true, "scope": scope, "total": rows.count, "rows": window(rows),
                       "actions": session.writeBlock == nil ? CADDatumService.actions : [], "revision": revision, "change_count": session.changeCount])

        case "constraints":
            // Only rows with a real typed mutation carry `editable: true`:
            // the geometric constraints are read-only here, while a driving
            // dimension can be changed/removed through the parameter actions
            // this same service advertises.
            var rows: [[String: Any]] = []
            for sketch in document.sketches {
                let definition = SketchSolverBridge.definitionReport(sketch)
                let blame = definition.conflicting
                    ? SketchSolverBridge.conflictAttribution(sketch) : nil
                let sketchSolverState = !definition.converged ? "nonconverged"
                    : definition.conflicting ? "conflicting"
                    : !definition.unsupportedRelationIDs.isEmpty ? "unsupported" : "satisfied"
                func decorate(_ row: inout [String: Any], id: UUID, conflicted: Bool) {
                    row["sketch_solver_state"] = sketchSolverState
                    row["relation_state"] = definition.unsupportedRelationIDs.contains(id)
                        ? "unsupported" : conflicted ? "conflicting"
                        : !definition.converged ? "nonconverged" : "satisfied"
                    row["sketch_dof"] = definition.dof
                    row["sketch_fully_defined"] = definition.isFullyDefined
                }
                for constraint in sketch.constraints {
                    var row = Self.encodedObject(constraint) ?? ["kind": String(describing: constraint.kind)]
                    row["sketchID"] = sketch.id.raw.uuidString
                    row["sketchName"] = sketch.name
                    row["row_kind"] = "constraint"
                    row["editable"] = false
                    decorate(&row, id: constraint.id,
                             conflicted: blame?.constraintIDs.contains(constraint.id) == true)
                    rows.append(row)
                }
                for dimension in sketch.dimensions {
                    var row = Self.encodedObject(dimension) ?? [:]
                    row["sketchID"] = sketch.id.raw.uuidString
                    row["sketchName"] = sketch.name
                    row["isDimension"] = true
                    row["row_kind"] = "dimension"
                    row["editable"] = true
                    row["update_action"] = "setSketchDimension"
                    row["remove_action"] = "removeSketchDimension"
                    row["unit"] = dimension.kind == .angle ? "deg" : "mm"
                    row["display_value"] = dimension.kind == .angle
                        ? dimension.value * 180 / .pi
                        : dimension.value
                    row["stored_unit"] = dimension.kind == .angle ? "rad" : "mm"
                    // The formula source is authored in the DISPLAY unit
                    // (degrees for an angle) while value is stored in the
                    // stored unit. Variable fan-out applies that conversion;
                    // expose both sides so a caller never conflates them.
                    row["formula"] = dimension.formula ?? NSNull()
                    row["formula_unit"] = dimension.kind == .angle ? "deg" : "mm"
                    row["formula_reference_names"] = dimension.formula.map {
                        ExpressionEvaluator.identifiers(in: $0).sorted()
                    } ?? []
                    decorate(&row, id: dimension.id,
                             conflicted: blame?.dimensionIDs.contains(dimension.id) == true)
                    rows.append(row)
                }
            }
            return ok(["ok": true, "scope": scope, "total": rows.count, "rows": window(rows),
                       "editable_count": rows.filter { $0["editable"] as? Bool == true }.count,
                       "revision": revision, "change_count": session.changeCount])

        case "features":
            let rows: [[String: Any]] = document.features.nodes.map { node in
                var row = CADParameterService.describe(node, document: document)
                row["referencedSketches"] = node.referencedSketchIDs.map { $0.raw.uuidString }
                return row
            }
            return ok(["ok": true, "scope": scope, "total": rows.count, "rows": window(rows)])

        case "edges":
            let rows: [[String: Any]] = document.bodies.map { body in
                var row: [String: Any] = [
                    "bodyID": body.id.raw.uuidString,
                    "name": body.name,
                    "segments": body.edges.segments.count / 2,
                ]
                let generation = CADGeometryQueryGeneration(
                    scope: "edges", bodyID: body.id.raw,
                    documentRevision: revision, changeCount: session.changeCount,
                    meshRevision: body.meshRevision)
                row["query_token"] = generation.token
                row["generation"] = generation.jsonObject
                if let brep = body.brep {
                    let midpoints = OCCTKernel.edgeMidpoints(brep)
                    row["kernelEdges"] = midpoints.count
                    row["edges"] = Array(midpoints.keys.sorted().prefix(512)).map { index in
                        let midpoint = midpoints[index] ?? .zero
                        return ["index": index,
                                "midpoint": Self.vector(midpoint)]
                    }
                }
                return row
            }
            return ok(["ok": true, "scope": scope, "total": rows.count, "rows": window(rows)])

        case "faces":
            var rows: [[String: Any]] = []
            let sourceBodyIDs = Set(document.bodies.filter {
                $0.brep != nil && session.lastNamingRevisions[$0.id] == $0.meshRevision
                    && !(session.lastKernelNames[$0.id] ?? [:]).isEmpty
            }.map(\.id))
            let sources = session.associativeSources(for: sourceBodyIDs)
            for body in document.bodies {
                guard let brep = body.brep else { continue }
                let generation = CADGeometryQueryGeneration(
                    scope: "faces", bodyID: body.id.raw,
                    documentRevision: revision, changeCount: session.changeCount,
                    meshRevision: body.meshRevision)
                let faces = OCCTKernel.faceInfo(brep)
                let descriptors = CADDatumService.sourceDescriptors(document: self, body: body,
                    planarIndices: Set(faces.filter { $0.signature?.kind == .planar }.map(\.index)),
                    acquired: sources[body.id])
                for face in faces {
                    var row: [String: Any] = [
                        "bodyID": body.id.raw.uuidString,
                        "body": body.name,
                        "index": face.index,
                        "areaMM2": face.area,
                        "centroid": Self.vector(face.centroid),
                        "normal": Self.vector(face.normal),
                        "signature": face.signature.map { String(describing: $0) } ?? "unsupported_surface",
                    ]
                    // Typed surface identity for discovery. A cylindrical row's
                    // radiusMM is the actual kernel radius; pair it with the
                    // query_token below (a generation proof, never permission).
                    switch face.signature?.kind {
                    case .planar:
                        row["kind"] = "planar"
                    case let .cylindrical(radius):
                        row["kind"] = "cylindrical"
                        row["radiusMM"] = radius
                    case nil:
                        row["kind"] = "other"
                        row["referenceable"] = false
                    }
                    row["signature_text"] = row["signature"]
                    row.merge(face.stableFaceJSON) { _, new in new }
                    row.merge(descriptors[face.index] ?? ["datum_source_supported": false]) { _, new in new }
                    row["face_index_space"] = "occt_kernel_1_based"
                    row["query_token"] = generation.token
                    row["generation"] = generation.jsonObject
                    rows.append(row)
                }
            }
            return ok(["ok": true, "scope": scope, "total": rows.count, "rows": window(rows)])

        case "variables":
            // Shared with the variable service, so a discovered id/action and
            // the executable add/edit/delete contract cannot disagree. Rows
            // carry the exact expression source, the resolved scalar, the unit
            // contract (variables are unitless scalars) and both directions of
            // the reference set deletion/rename must respect.
            let rows = CADParameterService.variableRows(in: document)
            return ok(["ok": true, "scope": scope, "total": rows.count, "rows": window(rows),
                       "revision": revision, "change_count": session.changeCount])

        case "materials":
            let library = CADMaterialLibraryCodec.decode(document.materialLibraryData)
            var applied: [String: Set<String>] = [:]
            for body in document.bodies {
                if let id = body.material?.materialID {
                    applied[id, default: []].insert(body.id.raw.uuidString)
                }
                for binding in body.materialFaceBindings {
                    if let id = binding.material.materialID {
                        applied[id, default: []].insert(body.id.raw.uuidString)
                    }
                }
            }
            let rows = library.entries.map { entry -> [String: Any] in
                var row = entry.summaryJSON
                row["applied_body_ids"] = (applied[entry.id.raw.uuidString] ?? []).sorted()
                return row
            }
            return ok(["ok": true, "scope": scope, "total": rows.count,
                       "schema_version": library.schemaVersion, "rows": window(rows)])

        case "detail":
            var detail: [String: Any] = [
                "ok": true,
                "scope": scope,
                "name": name,
                "revision": revision,
                "contentSHA256": contentSHA256,
                "bodies": document.bodies.count,
                "sketches": document.sketches.count,
                "features": document.features.nodes.count,
                "variables": document.variables.count,
                "material_library_entries": CADMaterialLibraryCodec.decode(document.materialLibraryData).entries.count,
                "face_material_bindings": document.bodies.reduce(0) { $0 + $1.materialFaceBindings.count },
            ]
            if let rollback = document.features.rollbackIndex {
                detail["rollbackIndex"] = rollback
            }
            return ok(detail)

        default:
            return fail("unsupported_scope",
                        "Scope '\(scope)' is not served by the model query; use bodies, sketches, "
                        + "planes, constraints, features, edges, faces, variables, materials, assembly, drawings, detail or snapshot.")
        }
    }

    // MARK: Locate

    /// Locate one `body:<uuid>`, `face:<uuid>:<index>` or `edge:<uuid>:<index>`
    /// handle. Face/edge indices are the 1-based kernel indices the snapshot
    /// and History panels use.
    func nativeLocateJSON(_ payload: [String: Any]) -> CADCommandOutcome {
        let handle = (payload["handle"] as? String) ?? ""
        let parts = handle.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count >= 2, let uuid = UUID(uuidString: parts[1]),
              let body = session.document.bodies.first(where: { $0.id.raw == uuid }) else {
            return Self.jsonOutcome(status: 404, object: [
                "ok": false, "error": "unknown_handle",
                "message": "No body matches '\(handle)'. Use body:<uuid>, face:<uuid>:<index> or edge:<uuid>:<index>.",
            ])
        }
        func ok(_ object: [String: Any]) -> CADCommandOutcome {
            Self.jsonOutcome(status: 200, object: object)
        }
        switch parts[0] {
        case "body":
            var object: [String: Any] = [
                "ok": true,
                "kind": "body",
                "bodyID": body.id.raw.uuidString,
                "name": body.name,
                "analyticBRep": body.brep != nil,
                "openSurfaceBRep": body.surfaceBRep != nil,
                "volumeApplicable": body.brep?.containsSolid == true || (body.brep == nil && body.surfaceBRep == nil),
                "volumeMM3": MeasureKit.volume(of: body),
                "triangles": body.render.indices.count / 3,
            ]
            if let bounds = MeasureKit.boundingBox(bodies: [body]) {
                object["bounds"] = [Self.vector(bounds.min), Self.vector(bounds.max)]
            }
            return ok(object)
        case "face":
            guard parts.count == 3, let index = Int(parts[2]), index >= 1, let brep = body.brep else {
                return Self.jsonOutcome(status: 400, object: ["ok": false, "error": "bad_handle",
                                                               "message": "A face handle is face:<uuid>:<1-based index>."])
            }
            let faces = OCCTKernel.faceInfo(brep)
            guard let face = faces.first(where: { $0.index == index }) else {
                return Self.jsonOutcome(status: 404, object: ["ok": false, "error": "unknown_face",
                                                               "message": "Body '\(body.name)' has no face \(index)."])
            }
            return ok(["ok": true, "kind": "face", "bodyID": body.id.raw.uuidString,
                       "index": face.index, "areaMM2": face.area,
                       "centroid": Self.vector(face.centroid), "normal": Self.vector(face.normal)])
        case "edge":
            guard parts.count == 3, let index = Int(parts[2]), index >= 1, let brep = body.brep else {
                return Self.jsonOutcome(status: 400, object: ["ok": false, "error": "bad_handle",
                                                               "message": "An edge handle is edge:<uuid>:<1-based index>."])
            }
            let midpoints = OCCTKernel.edgeMidpoints(brep)
            guard let midpoint = midpoints[index] else {
                return Self.jsonOutcome(status: 404, object: ["ok": false, "error": "unknown_edge",
                                                               "message": "Body '\(body.name)' has no kernel edge \(index)."])
            }
            return ok(["ok": true, "kind": "edge", "bodyID": body.id.raw.uuidString,
                       "index": index, "midpoint": Self.vector(midpoint)])
        default:
            return Self.jsonOutcome(status: 400, object: [
                "ok": false, "error": "bad_handle",
                "message": "Handle prefix must be body, face or edge.",
            ])
        }
    }

    // MARK: Check

    /// Structural model check: rebuild errors, empty meshes, non-finite
    /// vertices (bounded scan) and per-body topology counts. Deterministic and
    /// read-only; no rendered pixel is inspected.
    func nativeCheckJSON(_ payload: [String: Any]) -> CADCommandOutcome {
        let tolerance = payload["tolerance"] as? Double ?? 1e-3
        let document = session.document
        var issues: [[String: Any]] = []
        var bodyRows: [[String: Any]] = []
        for body in document.bodies {
            let triangles = body.render.indices.count / 3
            var row: [String: Any] = [
                "id": body.id.raw.uuidString,
                "name": body.name,
                "triangles": triangles,
                "analyticBRep": body.brep != nil,
                "openSurfaceBRep": body.surfaceBRep != nil,
            ]
            if triangles == 0 {
                issues.append(["kind": "empty_mesh", "bodyID": body.id.raw.uuidString, "body": body.name])
            }
            let vertexCount = body.render.positions.count
            var nonFinite = 0
            if vertexCount <= 200_000 {
                for position in body.render.positions where !(position.x.isFinite && position.y.isFinite && position.z.isFinite) {
                    nonFinite += 1
                }
            } else {
                row["nonFiniteScan"] = "skipped_large"
            }
            if nonFinite > 0 {
                row["nonFiniteVertices"] = nonFinite
                issues.append(["kind": "non_finite_vertices", "bodyID": body.id.raw.uuidString,
                               "body": body.name, "count": nonFinite])
            }
            bodyRows.append(row)
        }
        let evalErrors = session.lastEvalErrors.map { id, error -> [String: Any] in
            [
                "featureID": id.raw.uuidString,
                "feature": document.features.node(id)?.name ?? id.raw.uuidString,
                "error": String(describing: error),
            ]
        }
        if !evalErrors.isEmpty {
            for entry in evalErrors { issues.append(["kind": "feature_rebuild", "detail": entry]) }
        }
        let object: [String: Any] = [
            "ok": true,
            "model": [
                "bodies": bodyRows,
                "rebuildErrors": evalErrors,
                "unit": project.unitRaw ?? "mm",
                "toleranceMM": tolerance,
                "canUndo": session.undoStack.canUndo,
                "canRedo": session.undoStack.canRedo,
            ],
            "issues": issues,
            "issueCount": issues.count,
        ]
        return Self.jsonOutcome(status: 200, object: object)
    }

    // MARK: Import

    /// Import exact STEP bytes, IGES bytes, or mesh STL/OBJ as undoable body
    /// adds. IGES is read honestly: closed solids become exact `Body.brep`
    /// bodies while shells/faces become exact `Body.surfaceBRep` bodies —
    /// reported as surfaces, never as solids, and never flattened to a
    /// render-only mesh.
    func nativeImportData(_ data: Data,
                          format rawFormat: String,
                          fileName: String?,
                          unitScale: Double?,
                          limits: MeshImportLimits = .standard,
                          cancellation: (any MeshImportCancellationChecking)? = nil)
        -> CADCommandOutcome {
        let budget = MeshImportBudget(limits: limits, cancellation: cancellation,
                                      fileName: fileName ?? "import")
        if let block = session.writeBlock {
            return Self.jsonOutcome(status: 409, object: ["ok": false, "error": block.code,
                "message": block.message, "mutated": false])
        }
        guard !isClosed else {
            return Self.jsonOutcome(status: 409, object: ["ok": false, "error": "read_only",
                "message": "The CAD document is closed.", "mutated": false])
        }
        let format = rawFormat.lowercased()
        let baseName = (fileName?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 } ?? "Imported"
        var imported: [(id: BodyID, name: String, analytic: Bool)] = []
        func fail(_ code: String, _ message: String) -> CADCommandOutcome {
            Self.jsonOutcome(status: 422, object: ["ok": false, "error": code, "message": message])
        }
        func fail(_ error: MeshImportError) -> CADCommandOutcome {
            switch error {
            case .cancelled:
                return fail("cancelled", "Import cancelled; nothing was imported.")
            case .overBudget(let detail):
                return fail("import_over_budget",
                            "The import exceeds the import budget: \(detail). Nothing was imported; "
                            + "the source and document are unchanged.")
            case .unsupportedFormat(let what):
                return fail("unsupported_format", "The \(what) format is not supported by this import.")
            case .empty:
                return fail("empty_mesh", "The file produced no triangle meshes; nothing was imported.")
            case .malformed(let what):
                return fail("mesh_parse_failed", "The file could not be parsed: \(what)")
            }
        }
        /// No mutation may be performed once the owner cancelled: STEP builds
        /// every body first and commits them together, so a cancel during
        /// tessellation (or between solids) leaves the document untouched.
        func cancelled() -> CADCommandOutcome {
            fail("cancelled", "Import cancelled; nothing was imported.")
        }
        do {
            try budget.checkCancellation()
        } catch let error as MeshImportError {
            return fail(error)
        } catch {
            return fail("cancelled", "Import cancelled; nothing was imported.")
        }
        switch format {
        case "step", "stp", "iges", "igs":
            // E31-R2: the STEP/IGES parse is one shared implementation with
            // `CADExactImportService`; the synchronous legacy entry keeps the
            // historical per-body undo granularity. The App/tool paths call
            // `parseOffMain` + `.singleStep` instead, so a user-facing import
            // never reads/tessellates on the MainActor.
            return CADExactImportService.importSync(
                data, format: format, fileName: fileName, unitScale: unitScale,
                limits: limits, cancellation: cancellation, to: self)
        case "stl", "obj":
            let render: RenderMesh
            do {
                if format == "stl" {
                    render = try STLImporter.importSTL(data, unitScale: unitScale ?? 1,
                                                       budget: budget)
                } else {
                    render = try OBJImporter.importSingleMesh(data, unitScale: unitScale ?? 1,
                                                              budget: budget)
                }
            } catch let error as MeshImportError {
                return fail(error)
            } catch {
                return fail("mesh_parse_failed",
                            "The \(format.uppercased()) mesh could not be parsed: \(error.localizedDescription)")
            }
            guard !render.indices.isEmpty else {
                return fail("empty_mesh", "The \(format.uppercased()) file produced no triangles.")
            }
            do { try budget.addPart(baseName); try budget.checkCancellation() }
            catch let error as MeshImportError { return fail(error) }
            catch { return cancelled() }
            var localDocument = session.document
            var body = Body(id: BodyID(),
                            name: localDocument.uniqueBodyName(base: baseName),
                            transform: .identity,
                            primitive: nil,
                            render: render,
                            revision: localDocument.nextRevision())
            body.euclid = EuclidBridge.euclidMesh(from: render)
            session.perform(AddBodyCommand(body: body, title: "Import \(body.name)"))
            imported.append((body.id, body.name, false))
        default:
            return fail("unsupported_format",
                        "Native import supports STEP (.step/.stp), IGES (.igs/.iges) "
                        + "and mesh STL/OBJ; got '\(format)'.")
        }
        return Self.jsonOutcome(status: 200, object: [
            "ok": true,
            "imported": imported.map { ["bodyID": $0.id.raw.uuidString, "name": $0.name, "analyticBRep": $0.analytic] },
            "count": imported.count,
            "mutated": true,
        ])
    }

    // MARK: Export

    /// Exact/format export bytes for the native document. STEP writes exact
    /// closed solids only; IGES writes exact closed solids AND open surface
    /// bodies (`Body.surfaceBRep`); mesh-only bodies are skipped and reported
    /// in both cases. Mesh formats use the tessellation; drawing formats
    /// render real projected geometry for the requested page.
    ///
    /// This is the RAW writer. Callers that claim export completeness go
    /// through `nativePartExport`, which gates these bytes on a truthful
    /// coverage receipt.
    func nativeExportData(format rawFormat: String,
                          pageID: UUID?) -> Result<(data: Data, note: String), CADDocumentError> {
        nativeExportData(format: rawFormat, pageID: pageID,
                         bodies: session.document.bodies)
    }

    /// The same writers over an explicit body set. `nativePartExport` passes
    /// exactly the bodies its receipt included; drawing-format calls ignore
    /// the supplied bodies and keep their own page-scoped path.
    internal func nativeExportData(format rawFormat: String,
                                   pageID: UUID?,
                                   bodies: [Body]) -> Result<(data: Data, note: String), CADDocumentError> {
        var format = rawFormat.lowercased()
        if format == "igs" { format = "iges" }
        func failure(_ code: String, _ message: String) -> Result<(data: Data, note: String), CADDocumentError> {
            .failure(CADDocumentError(code: code, message: message))
        }
        switch format {
        case "iges":
            switch IGESKit.export(bodies: bodies) {
            case .success(let data, let skipped):
                let note = skipped.isEmpty
                    ? "exact OCCT B-rep IGES (closed solids and open surfaces), \(bodies.count) body/bodies, millimetres; no history, PMI, materials or assembly metadata"
                    : "exact OCCT B-rep IGES; bodies without an exact B-rep skipped: \(skipped.joined(separator: ", "))"
                return .success((data, note))
            case .nothingAnalytic(let skipped):
                return failure("no_analytic_geometry",
                               "No exact B-rep body (closed solid or open surface) to export; "
                               + "mesh-only: \(skipped.joined(separator: ", ")). "
                               + "No mesh was substituted for an IGES export.")
            case .failed:
                return failure("iges_export_failed",
                               "The IGES writer refused the export; nothing was written.")
            }
        case "step":
            switch STEPKit.export(bodies: bodies) {
            case .success(let data, let skipped):
                let note = skipped.isEmpty
                    ? "exact OCCT B-rep STEP AP214, \(bodies.count) body/bodies"
                    : "exact OCCT B-rep STEP AP214; mesh-only bodies skipped: \(skipped.joined(separator: ", "))"
                return .success((data, note))
            case .nothingAnalytic(let skipped):
                return failure("no_analytic_geometry",
                               "No analytic B-rep body to export; mesh-only: \(skipped.joined(separator: ", ")). "
                               + "No mesh was substituted for a STEP export.")
            case .failed:
                return failure("step_export_failed", "The STEP writer refused the export; nothing was written.")
            }
        case "stl":
            return .success((STLExporter.binarySTL(bodies: bodies),
                             "binary STL tessellation (mesh representation)"))
        case "obj":
            guard let data = OBJExporter.obj(bodies: bodies).data(using: .utf8) else {
                return failure("encode_failed", "The OBJ writer produced no bytes.")
            }
            return .success((data, "Wavefront OBJ tessellation with UVs (mesh representation); "
                + OBJExporter.materialLimitationNote))
        case "obj_bundle":
            // A true self-contained OBJ appearance: model.obj + model.mtl +
            // relative texture resources in one ZIP. Face-material ranges use
            // the session's one prepared tables/revisions exactly like GLB, so
            // a stale table falls back and is reported instead of painting a
            // guessed range. The host still owns atomic promotion.
            let faceRanges = session.faceRangeTables(for: bodies)
            let report = OBJBundleExporter.export(
                bodies: bodies,
                faceTables: faceRanges.tables,
                faceTableRevisions: faceRanges.revisions)
            if let data = report.data, report.diagnostics.isEmpty {
                return .success((data, report.receipt?.noteText
                    ?? "OBJ bundle (ZIP) with materials and relative textures"))
            }
            guard let first = report.diagnostics.first else {
                return failure("obj_bundle_export_failed",
                               "The OBJ bundle writer produced no bytes; nothing was written.")
            }
            let details = report.diagnostics.prefix(4).map { diagnostic -> String in
                var text = "\(diagnostic.code): \(diagnostic.message)"
                if let bodyID = diagnostic.bodyID {
                    text += " (body \(bodyID.uuidString))"
                }
                if let slot = diagnostic.textureSlot {
                    text += " [texture \(slot.rawValue)]"
                }
                return text
            }.joined(separator: "; ")
            return failure(first.code, details)
        case "3mf":
            return .success((ThreeMFExporter.threeMF(bodies: bodies),
                             "3MF tessellation (mesh representation)"))
        case "glb":
            // Pass the session's prepared face tables (an applied rebuild's
            // table when current, otherwise one derived from the restored
            // render); the exporter uses them for resolved per-face materials
            // and reports stale/missing mappings in glTF extras instead of
            // silently painting the whole body.
            let faceRanges = session.faceRangeTables(for: bodies)
            return .success((GLBExporter.glb(bodies: bodies,
                                             faceTables: faceRanges.tables,
                                             faceTableRevisions: faceRanges.revisions),
                             "binary glTF tessellation with applied PBR/UV/textures (mesh representation)"))
        case "usdz":
            // The exporter reports WHY a body/material/resource could not be
            // packaged instead of returning nil. A material or texture refusal
            // is therefore surfaced with its real code (never disguised as
            // "USDZ unavailable"); only an actually unsupported platform keeps
            // the stable usdz_unavailable contract.
            let report = USDZExporter.export(bodies: bodies)
            if let data = report.data, report.diagnostics.isEmpty {
                return .success((data, "USDZ tessellation (presentation mesh)"))
            }
            if !USDZExporter.isSupported {
                return failure("usdz_unavailable",
                               "USDZ export is not available on this platform/build.")
            }
            guard let first = report.diagnostics.first else {
                return failure("usdz_export_failed",
                               "The USDZ writer produced no bytes; nothing was written.")
            }
            let details = report.diagnostics.prefix(4).map { diagnostic -> String in
                var text = "\(diagnostic.code): \(diagnostic.message)"
                if let bodyID = diagnostic.bodyID {
                    text += " (body \(bodyID.uuidString))"
                }
                if let slot = diagnostic.textureSlot {
                    text += " [texture \(slot.rawValue)]"
                }
                return text
            }.joined(separator: "; ")
            return failure(first.code, details)
        case "pdf", "svg", "dxf", "csv":
            guard let pageID else {
                return failure("page_required",
                               "A \(format.uppercased()) drawing export needs a drawing page id.")
            }
            do {
                let data = try CADDrawingService(document: self).exportData(pageID: pageID, format: format)
                let note = format == "csv"
                    ? "complete BOM table as UTF-8 CSV (RFC 4180), all rows and columns"
                    : "real projected 2D drawing geometry (\(format.uppercased()))"
                return .success((data, note))
            } catch let error as CADDocumentError {
                // Preserve the service's exact refusal (for example
                // `bom_output_incomplete` with actualRows/capacity/nextAction)
                // instead of flattening every drawing failure into one code.
                return .failure(error)
            } catch {
                return failure("drawing_export_failed",
                               "The \(format.uppercased()) drawing export failed: \(error.localizedDescription)")
            }
        case "png":
            // Canvas-presentable raster of the SAME real projected geometry
            // the vector exports use (offscreen CoreGraphics, never a live
            // viewport capture). Without an explicit page the first drawing
            // page of the set is used; an empty set asks the caller to create
            // a sheet first instead of inventing one.
            let set: CADDrawingSet
            do {
                set = try CADDrawingSet.decode(from: session.document.drawingsData)
            } catch {
                return failure("corrupt_drawings",
                               "The stored drawing set JSON could not be read; it was left untouched.")
            }
            let page = pageID.flatMap { id in set.pages.first(where: { $0.id == id }) }
                ?? set.pages.first
            guard let page else {
                return failure("no_drawing_page",
                               "The native document has no drawing page to rasterize yet; "
                               + "create one in the Drawings panel (Standard sheet) first.")
            }
            do {
                let data = try CADDrawingService(document: self).exportData(pageID: page.id, format: "png")
                return .success((data, "offscreen raster of the projected drawing page (PNG, 1024pt)"))
            } catch let error as CADDocumentError {
                return .failure(error)
            } catch {
                return failure("drawing_export_failed",
                               "The PNG drawing export failed: \(error.localizedDescription)")
            }
        default:
            return failure("unsupported_format",
                           "Native export supports step, iges, stl, obj, obj_bundle, 3mf, glb, usdz "
                           + "and drawing pdf/svg/dxf/csv/png.")
        }
    }

    // MARK: Helpers

    static func jsonOutcome(status: Int, object: [String: Any]) -> CADCommandOutcome {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        let error = object["error"] as? String
        let message = object["message"] as? String
        return CADCommandOutcome(status: status, payload: data, errorCode: error, message: message)
    }

    static func vector(_ value: SIMD3<Double>) -> [Double] {
        [value.x, value.y, value.z]
    }

    static func encodedObject<T: Encodable>(_ value: T) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return object
    }
}
