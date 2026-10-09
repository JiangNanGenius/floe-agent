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
                return row
            }
            return ok(["ok": true, "scope": scope, "total": rows.count, "rows": window(rows)])

        case "sketches":
            let rows: [[String: Any]] = document.sketches.map { sketch in
                [
                    "id": sketch.id.raw.uuidString,
                    "name": sketch.name,
                    "hidden": sketch.isHidden,
                    "entities": sketch.entities.count,
                    "constructionEntities": sketch.constructionEntityIDs.count,
                    "constraints": sketch.constraints.count,
                    "dimensions": sketch.dimensions.count,
                    "planeNormal": Self.vector(sketch.plane.normal),
                ]
            }
            return ok(["ok": true, "scope": scope, "total": rows.count, "rows": window(rows)])

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
                [
                    "id": node.id.raw.uuidString,
                    "name": node.name,
                    "suppressed": node.suppressed,
                    "outputBodyIDs": node.outputBodyIDs.map(\.raw.uuidString),
                    "referencedSketches": node.referencedSketchIDs.map { $0.raw.uuidString },
                ]
            }
            return ok(["ok": true, "scope": scope, "total": rows.count, "rows": window(rows)])

        case "edges":
            let rows: [[String: Any]] = document.bodies.map { body in
                var row: [String: Any] = [
                    "bodyID": body.id.raw.uuidString,
                    "name": body.name,
                    "segments": body.edges.segments.count / 2,
                ]
                if let brep = body.brep {
                    let midpoints = OCCTKernel.edgeMidpoints(brep)
                    row["kernelEdges"] = midpoints.count
                }
                return row
            }
            return ok(["ok": true, "scope": scope, "total": rows.count, "rows": window(rows)])

        case "faces":
            var rows: [[String: Any]] = []
            for body in document.bodies {
                guard let brep = body.brep else { continue }
                for face in OCCTKernel.faceInfo(brep) {
                    rows.append([
                        "bodyID": body.id.raw.uuidString,
                        "body": body.name,
                        "index": face.index,
                        "areaMM2": face.area,
                        "centroid": Self.vector(face.centroid),
                        "normal": Self.vector(face.normal),
                        "signature": face.signature.map { String(describing: $0) } ?? "unsupported_surface",
                    ])
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
            ]
            if let rollback = document.features.rollbackIndex {
                detail["rollbackIndex"] = rollback
            }
            return ok(detail)

        default:
            return fail("unsupported_scope",
                        "Scope '\(scope)' is not served by the model query; use bodies, sketches, "
                        + "constraints, features, edges, faces, variables, assembly, drawings, detail or snapshot.")
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
            return .success((GLBExporter.glb(bodies: bodies),
                             "binary glTF tessellation (mesh representation)"))
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
