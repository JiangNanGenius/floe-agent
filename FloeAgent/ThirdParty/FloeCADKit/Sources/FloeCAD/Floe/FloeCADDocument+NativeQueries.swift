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

    /// The typed native operation vocabulary this build accepts.
    static var nativeOperationNames: [String] { AgentExec.opNames }

    // MARK: Query

    /// One native read scope. Scopes handled here are model scopes; the host
    /// composes `assembly`/`drawings` from their services (the services own
    /// those JSON blobs and their report semantics).
    func nativeQueryJSON(_ payload: [String: Any]) -> CADCommandOutcome {
        let scope = payload["scope"] as? String ?? "snapshot"
        let document = session.document
        let limit = min(max(payload["limit"] as? Int ?? 200, 1), 500)
        let offset = max(payload["offset"] as? Int ?? 0, 0)

        func ok(_ object: [String: Any]) -> CADCommandOutcome {
            Self.jsonOutcome(status: 200, object: object)
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

        case "bodies":
            let rows: [[String: Any]] = document.bodies.map { body in
                var row: [String: Any] = [
                    "id": body.id.raw.uuidString,
                    "name": body.name,
                    "hidden": body.isHidden,
                    "analyticBRep": body.brep != nil,
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
                    case let .rect(_, low, high):
                        row["kind"] = "rect"
                        row["min"] = [low.x, low.y]
                        row["max"] = [high.x, high.y]
                        row["widthMM"] = abs(high.x - low.x)
                        row["heightMM"] = abs(high.y - low.y)
                    case let .circle(_, center, radius):
                        row["kind"] = "circle"
                        row["center"] = [center.x, center.y]
                        row["radius"] = radius
                        row["diameterMM"] = radius * 2
                        row["parameter"] = "radius"
                        row["update_action"] = "updateSketchEntity"
                    case let .arc(_, center, radius, startAngle, endAngle):
                        row["kind"] = "arc"
                        row["center"] = [center.x, center.y]
                        row["radius"] = radius
                        row["startAngleRadians"] = startAngle
                        row["endAngleRadians"] = endAngle
                    case let .ellipse(_, center, radiusX, radiusY, rotation):
                        row["kind"] = "ellipse"
                        row["center"] = [center.x, center.y]
                        row["radiusX"] = radiusX
                        row["radiusY"] = radiusY
                        row["rotationRadians"] = rotation
                    case let .polygon(_, center, radius, sides, rotation):
                        row["kind"] = "polygon"
                        row["center"] = [center.x, center.y]
                        row["radius"] = radius
                        row["sides"] = sides
                        row["rotationRadians"] = rotation
                    case let .spline(_, points, closed):
                        row["kind"] = "spline"
                        row["closed"] = closed
                        row["pointCount"] = points.count
                    }
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
                if let featureIDs = usedBySketch[sketch.id] {
                    row["usedByFeatureIDs"] = featureIDs.sorted()
                }
                return row
            }
            return ok(["ok": true, "scope": scope, "total": rows.count, "rows": window(rows),
                       "revision": revision, "change_count": session.changeCount])

        case "constraints":
            var rows: [[String: Any]] = []
            for sketch in document.sketches {
                for constraint in sketch.constraints {
                    var row = Self.encodedObject(constraint) ?? ["kind": String(describing: constraint.kind)]
                    row["sketchID"] = sketch.id.raw.uuidString
                    row["sketchName"] = sketch.name
                    rows.append(row)
                }
                for dimension in sketch.dimensions {
                    var row = Self.encodedObject(dimension) ?? [:]
                    row["sketchID"] = sketch.id.raw.uuidString
                    row["sketchName"] = sketch.name
                    row["isDimension"] = true
                    rows.append(row)
                }
            }
            return ok(["ok": true, "scope": scope, "total": rows.count, "rows": window(rows)])

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
            for body in document.bodies {
                guard let brep = body.brep else { continue }
                let generation = CADGeometryQueryGeneration(
                    scope: "faces", bodyID: body.id.raw,
                    documentRevision: revision, changeCount: session.changeCount,
                    meshRevision: body.meshRevision)
                for face in OCCTKernel.faceInfo(brep) {
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
                    row["query_token"] = generation.token
                    row["generation"] = generation.jsonObject
                    rows.append(row)
                }
            }
            return ok(["ok": true, "scope": scope, "total": rows.count, "rows": window(rows)])

        case "variables":
            let rows: [[String: Any]] = document.variables.map { variable in
                ["name": variable.name,
                 "expression": variable.expression,
                 "value": variable.value]
            }
            return ok(["ok": true, "scope": scope, "total": rows.count, "rows": window(rows)])

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
                        + "constraints, features, edges, faces, variables, materials, assembly, drawings, detail or snapshot.")
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
    /// adds. IGES is read honestly: closed solids become exact bodies while
    /// shells/faces become render-only bodies that are reported as surfaces,
    /// never as solids.
    func nativeImportData(_ data: Data,
                          format rawFormat: String,
                          fileName: String?,
                          unitScale: Double?) -> CADCommandOutcome {
        let format = rawFormat.lowercased()
        let baseName = (fileName?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 } ?? "Imported"
        var imported: [(id: BodyID, name: String, analytic: Bool)] = []
        func fail(_ code: String, _ message: String) -> CADCommandOutcome {
            Self.jsonOutcome(status: 422, object: ["ok": false, "error": code, "message": message])
        }
        switch format {
        case "step", "stp":
            let solids = STEPKit.solids(from: data)
            guard !solids.isEmpty else {
                return fail("no_solids", "The STEP file carries no readable solid; nothing was imported.")
            }
            for (index, solid) in solids.enumerated() {
                let name = solids.count > 1 ? "\(baseName) \(index + 1)" : baseName
                var localDocument = session.document
                guard let body = STEPKit.body(from: solid, name: name,
                                              revision: localDocument.nextRevision()) else {
                    return fail("step_body_failed",
                                "Solid \(index + 1) could not be meshed; nothing was imported.")
                }
                session.perform(AddBodyCommand(body: body, title: "Import \(name)"))
                imported.append((body.id, body.name, true))
            }
        case "stl", "obj":
            let render: RenderMesh
            do {
                if format == "stl" {
                    render = try STLImporter.importSTL(data, unitScale: unitScale ?? 1)
                } else {
                    render = try OBJImporter.importSingleMesh(data, unitScale: unitScale ?? 1)
                }
            } catch {
                return fail("mesh_parse_failed",
                            "The \(format.uppercased()) mesh could not be parsed: \(error.localizedDescription)")
            }
            guard !render.indices.isEmpty else {
                return fail("empty_mesh", "The \(format.uppercased()) file produced no triangles.")
            }
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
        case "iges", "igs":
            // IGES is a SURFACE-exchange format: a file may carry closed
            // solids, shells, or isolated faces. The kernel reader keeps the
            // two apart (`OCCTKernel.readIGES`), and this branch reports the
            // counts honestly. Solids become exact bodies (`Body.adoptBRep`
            // through `STEPKit.body`); surfaces become render-only bodies
            // (`analyticBRep: false`) because a shell is not a solid and must
            // not enter boolean/fillet/shell operations. Nothing is committed
            // unless every listed solid converted, so a failed import really
            // leaves the document untouched.
            let iges = OCCTKernel.readIGES(data)
            guard iges.readSucceeded else {
                return fail("iges_read_failed",
                            "The IGES file could not be read (its records did not parse); "
                            + "nothing was imported.")
            }
            guard iges.rootCount > 0 else {
                return fail("iges_empty",
                            "The IGES file parsed but carries no transferable shape; "
                            + "nothing was imported.")
            }
            var pending: [(body: Body, analytic: Bool, kind: String, faceCount: Int?)] = []
            var localDocument = session.document
            let total = iges.solids.count + iges.surfaces.count
            for (index, solid) in iges.solids.enumerated() {
                let name = total > 1 ? "\(baseName) Solid \(index + 1)" : baseName
                guard let body = STEPKit.body(from: solid,
                                              name: localDocument.uniqueBodyName(base: name),
                                              revision: localDocument.nextRevision()) else {
                    return fail("iges_import_failed",
                                "The IGES file's solid \(index + 1) could not be tessellated; "
                                + "nothing was imported.")
                }
                let faceCount = index < iges.solidFaceCounts.count
                    ? iges.solidFaceCounts[index] : nil
                pending.append((body, true, "solid", faceCount))
            }
            var skippedSurfaces = 0
            for (index, surface) in iges.surfaces.enumerated() {
                let mesh = OCCTKernel.renderMesh(from: surface)
                guard !mesh.positions.isEmpty, !mesh.indices.isEmpty else {
                    skippedSurfaces += 1
                    continue
                }
                let name = total > 1 ? "\(baseName) Surface \(index + 1)"
                                     : "\(baseName) Surface"
                var body = Body(id: BodyID(),
                                name: localDocument.uniqueBodyName(base: name),
                                transform: .identity,
                                primitive: nil,
                                render: RenderMesh(positions: mesh.positions,
                                                   normals: mesh.normals,
                                                   indices: mesh.indices),
                                revision: localDocument.nextRevision())
                body.euclid = EuclidBridge.euclidMesh(from: body.render)
                let faceCount = index < iges.surfaceFaceCounts.count
                    ? iges.surfaceFaceCounts[index] : nil
                pending.append((body, false, "surface", faceCount))
            }
            guard !pending.isEmpty else {
                return fail("iges_import_failed",
                            "The IGES file's \(iges.rootCount) shape(s) did not survive "
                            + "validation and tessellation; nothing was imported.")
            }
            for entry in pending {
                session.perform(AddBodyCommand(body: entry.body,
                                               title: "Import \(entry.body.name)"))
            }
            let solidsImported = pending.filter { $0.analytic }.count
            let surfacesImported = pending.count - solidsImported
            var object: [String: Any] = [
                "ok": true,
                "imported": pending.map { entry -> [String: Any] in
                    var row: [String: Any] = [
                        "bodyID": entry.body.id.raw.uuidString,
                        "name": entry.body.name,
                        "analyticBRep": entry.analytic,
                        "kind": entry.kind,
                    ]
                    if let faceCount = entry.faceCount { row["faceCount"] = faceCount }
                    return row
                },
                "count": pending.count,
                "solidsImported": solidsImported,
                "surfacesImported": surfacesImported,
                "mutated": true,
            ]
            if surfacesImported > 0 || skippedSurfaces > 0 {
                var parts: [String] = []
                if surfacesImported > 0 {
                    parts.append("IGES surfaces are not solids: \(surfacesImported) shell/face "
                        + "body(ies) were imported as render-only bodies (analyticBRep: false) "
                        + "and cannot take boolean, fillet or shell operations.")
                }
                if skippedSurfaces > 0 {
                    parts.append("\(skippedSurfaces) surface(s) failed to tessellate and were skipped.")
                }
                object["note"] = parts.joined(separator: " ")
            }
            return Self.jsonOutcome(status: 200, object: object)
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

    /// Exact/format export bytes for the native document. STEP/IGES-class
    /// exchanges use the analytic B-rep (mesh-only bodies are skipped and
    /// reported); mesh formats use the tessellation; drawing formats render
    /// real projected geometry for the requested page.
    func nativeExportData(format rawFormat: String,
                          pageID: UUID?) -> Result<(data: Data, note: String), CADDocumentError> {
        let format = rawFormat.lowercased()
        let bodies = session.document.bodies
        func failure(_ code: String, _ message: String) -> Result<(data: Data, note: String), CADDocumentError> {
            .failure(CADDocumentError(code: code, message: message))
        }
        switch format {
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
            return .success((data, "Wavefront OBJ tessellation (mesh representation)"))
        case "3mf":
            return .success((ThreeMFExporter.threeMF(bodies: bodies),
                             "3MF tessellation (mesh representation)"))
        case "glb":
            // Pass the feature graph's face table ONLY when its revision still
            // matches the body; the exporter uses it for resolved per-face
            // materials and reports stale/missing mappings in glTF extras
            // instead of silently painting the whole body.
            return .success((GLBExporter.glb(bodies: bodies,
                                             faceTables: session.lastFaceTables,
                                             faceTableRevisions: session.lastNamingRevisions),
                             "binary glTF tessellation with applied PBR/UV/textures (mesh representation)"))
        case "usdz":
            guard USDZExporter.isSupported, let data = USDZExporter.usdz(bodies: bodies) else {
                return failure("usdz_unavailable", "USDZ export is not available on this platform/build.")
            }
            return .success((data, "USDZ tessellation (presentation mesh)"))
        case "pdf", "svg", "dxf":
            guard let pageID else {
                return failure("page_required",
                               "A \(format.uppercased()) drawing export needs a drawing page id.")
            }
            do {
                let data = try CADDrawingService(document: self).exportData(pageID: pageID, format: format)
                return .success((data, "real projected 2D drawing geometry (\(format.uppercased()))"))
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
            } catch {
                return failure("drawing_export_failed",
                               "The PNG drawing export failed: \(error.localizedDescription)")
            }
        default:
            return failure("unsupported_format",
                           "Native export supports step, stl, obj, 3mf, glb, usdz and drawing pdf/svg/dxf/png.")
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
