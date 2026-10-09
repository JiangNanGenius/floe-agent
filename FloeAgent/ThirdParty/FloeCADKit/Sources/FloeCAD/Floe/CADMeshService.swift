//
//  CADMeshService.swift
//  FloeCADKit
//
//  Mesh-level editing for one FloeCAD document: combine, Euclid CSG booleans,
//  transforms, normal recomputation, boundary/loose-edge reporting, welding
//  repair, cluster simplification and materials.
//
//  Exactness rules (AGENTS.md / kernel invariants):
//   * combine / boolean / repair / simplify rebuild the render mesh from
//     triangles. A body with an analytic B-rep is REFUSED unless the caller
//     passes `forceMesh:true`; the refused op changes nothing. A forced
//     result is marked `"exactness":"mesh"` and drops the B-rep.
//   * transform / recomputeNormals / boundary / material / image keep any
//     B-rep untouched and report `"exactness":"preserved"`.
//   * Every successful geometry edit goes through the document's undoable
//     command path in ONE step and returns `"mutated":true`.
//
//  Bounds: at most 16 input bodies and 500k input triangles per operation, a
//  10-second wall-clock deadline, and cancellation checks inside every loop
//  (Euclid CSG receives the same `isCancelled` closure). No file paths are
//  accepted anywhere; image bytes arrive base64-encoded or via an existing
//  document image.
//
//  Actions / args (all share `bodyID` or `bodyIDs`):
//   * combine          bodyIDs, name? -> new body (world transforms baked).
//   * boolean          op (union|subtract|intersect), target, tools, name?
//                      -> new body; empty result is refused.
//   * transform        bodyID, translate [x,y,z]?, rotate
//                      {axis:[x,y,z], angleDegrees}?, scale? — rotation and
//                      scale pivot on the body's current placement
//                      (translation); never drops a B-rep.
//   * recomputeNormals bodyID(s) — area-weighted normals from triangles.
//   * boundary         bodyID(s) — boundary/non-manifold edge counts+bounds.
//   * repair           bodyID(s), tolerance (mm, default 1e-3) — weld +
//                      drop degenerate triangles.
//   * simplify         bodyID(s), ratio (0…1) or tolerance (mm) — cluster
//                      decimation, never below 4 triangles.
//   * material         bodyID(s), color [r,g,b(,a)], metallic?, roughness?,
//                      opacity? (0…1) — non-destructive.
//   * image            bodyID(s), imageBase64 (PNG/JPEG) or imageID of an
//                      inserted document image — sets the material texture.
//   * text             always refused with `text_mesh_unavailable`.
//  Destructive actions accept `forceMesh:true` to acknowledge dropping an
//  analytic B-rep; without it they return `brep_body_refused`.
//

import Foundation
import CoreFoundation
import simd
import Euclid

@MainActor
public final class CADMeshService {
    public static let maxInputBodies = 16
    public static let maxInputTriangles = 500_000
    public static let wallClockLimitSeconds: Double = 10
    public static let maxImageBytes = 8 * 1024 * 1024

    private let document: FloeCADDocument

    public init(document: FloeCADDocument) {
        self.document = document
    }

    // MARK: Action router

    public func handle(action: String, args: [String: Any]) -> [String: Any] {
        switch action {
        case "combine": return combine(args)
        case "boolean": return boolean(args)
        case "transform": return transform(args)
        case "recomputeNormals": return recomputeNormals(args)
        case "boundary": return boundary(args)
        case "repair": return repair(args)
        case "simplify": return simplify(args)
        case "material": return material(args)
        case "text": return text(args)
        case "image": return image(args)
        default:
            return Self.fail("unknown_action",
                             "Unknown mesh action '\(action)'. Use combine, boolean, transform, "
                             + "recomputeNormals, boundary, repair, simplify, material, text or image.")
        }
    }

    // MARK: combine

    private func combine(_ args: [String: Any]) -> [String: Any] {
        let clock = EvaluationDeadlineClock(seconds: Self.wallClockLimitSeconds)
        guard case let .ok(bodies) = resolveBodies(args) else {
            return resolutionFailure(args)
        }
        if let refusal = verifyMeshOnly(bodies, args: args, action: "combine") { return refusal }
        let name = sanitizeName(args["name"]) ?? "Combined"

        var result = Euclid.Mesh.empty
        for body in bodies {
            guard !clock.expired else { return limitTime() }
            result = result.merge(Self.worldMesh(body))
        }
        guard !clock.expired else { return limitTime() }
        guard !result.polygons.isEmpty else {
            return Self.fail("empty_geometry", "The combined mesh is empty; nothing changed.")
        }
        let renderResult = EuclidBridge.renderMesh(from: result)
        let gate = previewGate(action: "combine", args: args, meshes: [renderResult])
        if let refusal = gate.refusal { return refusal }
        if let reply = gate.reply { return reply }

        let body = makeResultBody(name: name, mesh: result)
        commit(body, consuming: bodies, title: "Combine")
        return Self.mutationResult(action: "combine",
                                   body: body,
                                   extra: ["sourceBodyCount": bodies.count])
    }

    // MARK: boolean

    private enum BooleanOp: String {
        case union, subtract, intersect
    }

    private func boolean(_ args: [String: Any]) -> [String: Any] {
        guard let opString = args["op"] as? String, let op = BooleanOp(rawValue: opString) else {
            return Self.fail("bad_request", "'op' must be union, subtract or intersect.")
        }
        guard let targetID = args["target"] as? String else {
            return Self.fail("bad_request", "'target' is required.")
        }
        let toolIDs = stringList(args["tools"])
        guard !toolIDs.isEmpty else {
            return Self.fail("bad_request", "'tools' must list at least one body.")
        }
        guard case let .ok(target) = resolveBodies(ids: [targetID]) else {
            return resolutionFailure(ids: [targetID])
        }
        guard case let .ok(tools) = resolveBodies(ids: toolIDs) else {
            return resolutionFailure(ids: toolIDs)
        }
        let inputs = target + tools
        guard Set([targetID] + toolIDs).count == inputs.count else {
            return Self.fail("bad_request", "'tools' must not repeat the target or each other.")
        }
        guard inputs.count <= Self.maxInputBodies else {
            return Self.fail("too_many_bodies",
                             "At most \(Self.maxInputBodies) bodies per operation; got \(inputs.count).")
        }
        let totalTriangles = inputs.reduce(0) { $0 + $1.render.triangleCount }
        guard totalTriangles <= Self.maxInputTriangles else {
            return Self.fail("too_many_triangles",
                             "Input exceeds \(Self.maxInputTriangles) triangles.")
        }
        if let refusal = verifyMeshOnly(inputs, args: args, action: "boolean") { return refusal }

        let clock = EvaluationDeadlineClock(seconds: Self.wallClockLimitSeconds)
        let cancel: @Sendable () -> Bool = { clock.isExpired() }
        var result = Self.worldMesh(target[0])
        for tool in tools {
            guard !clock.expired else { return limitTime() }
            let toolMesh = Self.worldMesh(tool)
            switch op {
            case .union:
                result = result.union(toolMesh, isCancelled: cancel)
            case .subtract:
                result = result.subtracting(toolMesh, isCancelled: cancel)
            case .intersect:
                result = result.intersection(toolMesh, isCancelled: cancel)
            }
            guard !clock.expired else { return limitTime() }
        }
        result = result.makeWatertight(isCancelled: cancel)
        guard !clock.expired else { return limitTime() }
        guard !result.polygons.isEmpty else {
            return Self.fail("empty_geometry",
                             "The \(opString) result is empty; nothing changed.")
        }
        let renderResult = EuclidBridge.renderMesh(from: result)
        let gate = previewGate(action: "boolean", args: args, meshes: [renderResult])
        if let refusal = gate.refusal { return refusal }
        if let reply = gate.reply { return reply }

        let name = sanitizeName(args["name"]) ?? "Boolean"
        let body = makeResultBody(name: name, mesh: result)
        commit(body, consuming: inputs, title: opString.capitalized)
        return Self.mutationResult(action: "boolean",
                                   body: body,
                                   extra: ["op": opString,
                                           "sourceBodyCount": inputs.count])
    }

    // MARK: transform (non-destructive)

    private func transform(_ args: [String: Any]) -> [String: Any] {
        guard let bodyID = args["bodyID"] as? String else {
            return Self.fail("bad_request", "'bodyID' is required.")
        }
        guard case let .ok(bodies) = resolveBodies(ids: [bodyID]) else {
            return resolutionFailure(ids: [bodyID])
        }
        let body = bodies[0]
        var next = body.transform
        var changed = false

        if let rawTranslate = args["translate"] {
            guard let vector = Self.doubles(rawTranslate), vector.count == 3 else {
                return Self.fail("bad_request", "'translate' must be [x, y, z] in mm.")
            }
            next.translation += SIMD3(vector[0], vector[1], vector[2])
            changed = true
        }
        if let rawRotate = args["rotate"] as? [String: Any] {
            guard let axisValues = Self.doubles(rawRotate["axis"]), axisValues.count == 3,
                  let angle = Self.number(rawRotate["angleDegrees"]) else {
                return Self.fail("bad_request",
                                 "'rotate' must be {\"axis\":[x,y,z],\"angleDegrees\":degrees}.")
            }
            let axis = SIMD3(axisValues[0], axisValues[1], axisValues[2])
            let length = simd_length(axis)
            guard length > 1e-12 else {
                return Self.fail("bad_request", "'rotate.axis' must be non-zero.")
            }
            let delta = simd_quatd(angle: angle * .pi / 180, axis: axis / length)
            // About the body's current placement: translation stays the pivot,
            // the delta pre-multiplies the existing orientation.
            next.rotation = simd_normalize(delta * next.rotation)
            changed = true
        }
        if let rawScale = args["scale"] {
            guard let scale = Self.number(rawScale), scale > 0 else {
                return Self.fail("bad_request", "'scale' must be a positive number.")
            }
            next.scale *= scale
            changed = true
        }
        guard changed else {
            return Self.fail("bad_request", "Provide 'translate', 'rotate' and/or 'scale'.")
        }
        guard next.translation.x.isFinite, next.translation.y.isFinite, next.translation.z.isFinite,
              next.scale.isFinite, next.scale > 0 else {
            return Self.fail("bad_request", "The resulting transform is not finite.")
        }

        document.session.perform(TransformBodiesCommand(title: "Transform",
                                                        before: [body.id: body.transform],
                                                        after: [body.id: next]))
        return ["ok": true,
                "action": "transform",
                "mutated": true,
                "exactness": "preserved",
                "bodyID": body.id.raw.uuidString,
                "translate": [next.translation.x, next.translation.y, next.translation.z],
                "scale": next.scale]
    }

    // MARK: recomputeNormals (non-destructive)

    private func recomputeNormals(_ args: [String: Any]) -> [String: Any] {
        guard case let .ok(bodies) = resolveBodies(args) else {
            return resolutionFailure(args)
        }
        let clock = EvaluationDeadlineClock(seconds: Self.wallClockLimitSeconds)
        var replacements: [(before: Body, after: Body)] = []
        var entries: [[String: Any]] = []
        for body in bodies {
            guard !clock.expired else { return limitTime() }
            var after = body
            after.render = RenderMesh(
                positions: body.render.positions,
                normals: MeshImportKit.computedNormals(positions: body.render.positions,
                                                       indices: body.render.indices),
                indices: body.render.indices,
                texcoords: body.render.texcoords)
            after.edges = FeatureEdgeExtractor.edges(from: after.render)
            // The render normals were rewritten; force the CSG cache to be
            // rebuilt from the new render rather than keeping stale normals.
            after.euclid = nil
            replacements.append((before: body, after: after))
            entries.append(["bodyID": body.id.raw.uuidString,
                            "triangleCount": after.render.triangleCount])
        }
        performReplacements(replacements, title: "Recompute Normals")
        return ["ok": true,
                "action": "recomputeNormals",
                "mutated": true,
                "exactness": "preserved",
                "bodies": entries]
    }

    // MARK: boundary (read-only)

    private func boundary(_ args: [String: Any]) -> [String: Any] {
        guard case let .ok(bodies) = resolveBodies(args) else {
            return resolutionFailure(args)
        }
        let clock = EvaluationDeadlineClock(seconds: Self.wallClockLimitSeconds)
        var entries: [[String: Any]] = []
        var totalBoundary = 0
        var totalNonManifold = 0
        for body in bodies {
            guard !clock.expired else { return limitTime() }
            guard let stats = Self.edgeStats(body.render, clock: clock) else {
                return limitTime()
            }
            totalBoundary += stats.boundary
            totalNonManifold += stats.nonManifold
            var entry: [String: Any] = ["bodyID": body.id.raw.uuidString,
                                        "triangleCount": stats.triangleCount,
                                        "edgeCount": stats.edgeCount,
                                        "boundaryEdgeCount": stats.boundary,
                                        "nonManifoldEdgeCount": stats.nonManifold]
            if let bounds = Self.worldBounds(of: stats.boundarySegments, transform: body.transform) {
                entry["bounds"] = bounds
            }
            entries.append(entry)
        }
        return ["ok": true,
                "action": "boundary",
                "mutated": false,
                "exactness": "preserved",
                "boundaryEdgeCount": totalBoundary,
                "nonManifoldEdgeCount": totalNonManifold,
                "bodies": entries]
    }

    // MARK: repair

    private func repair(_ args: [String: Any]) -> [String: Any] {
        guard case let .ok(bodies) = resolveBodies(args) else {
            return resolutionFailure(args)
        }
        if let refusal = verifyMeshOnly(bodies, args: args, action: "repair") { return refusal }
        let tolerance: Double
        if let raw = args["tolerance"] {
            guard let value = Self.number(raw), value > 0 else {
                return Self.fail("bad_request", "'tolerance' must be a positive distance in mm.")
            }
            tolerance = value
        } else {
            tolerance = 1e-3
        }

        let clock = EvaluationDeadlineClock(seconds: Self.wallClockLimitSeconds)
        var replacements: [(before: Body, after: Body)] = []
        var entries: [[String: Any]] = []
        var previewMeshes: [RenderMesh] = []
        for body in bodies {
            guard let welded = Self.weldAndClean(body.render, tolerance: tolerance, clock: clock) else {
                if clock.expired { return limitTime() }
                return Self.fail("invalid_mesh",
                                 "Body '\(body.name)' has non-finite coordinates; nothing changed.")
            }
            guard !welded.mesh.indices.isEmpty else {
                return Self.fail("empty_geometry",
                                 "Repairing '\(body.name)' would remove every triangle; nothing changed.")
            }
            previewMeshes.append(welded.mesh)
            entries.append(["bodyID": body.id.raw.uuidString,
                            "beforeTriangles": body.render.triangleCount,
                            "afterTriangles": welded.mesh.triangleCount,
                            "weldedVertices": welded.weldedVertices,
                            "removedTriangles": welded.removedTriangles])
            guard welded.weldedVertices > 0 || welded.removedTriangles > 0 else { continue }
            var after = body
            after.render = welded.mesh
            after.edges = FeatureEdgeExtractor.edges(from: welded.mesh)
            after.euclid = nil
            after.brep = nil
            after.primitive = nil
            replacements.append((before: body, after: after))
        }
        let gate = previewGate(action: "repair", args: args, meshes: previewMeshes)
        if let refusal = gate.refusal { return refusal }
        if let reply = gate.reply { return reply }
        performReplacements(replacements, title: "Repair Mesh")
        return ["ok": true,
                "action": "repair",
                "mutated": !replacements.isEmpty,
                "exactness": "mesh",
                "tolerance": tolerance,
                "bodies": entries]
    }

    // MARK: simplify

    private func simplify(_ args: [String: Any]) -> [String: Any] {
        guard case let .ok(bodies) = resolveBodies(args) else {
            return resolutionFailure(args)
        }
        if let refusal = verifyMeshOnly(bodies, args: args, action: "simplify") { return refusal }
        let ratio = args["ratio"].flatMap { Self.number($0) }
        let tolerance = args["tolerance"].flatMap { Self.number($0) }
        if tolerance == nil {
            guard let ratio, ratio > 0, ratio < 1 else {
                return Self.fail("bad_request",
                                 "Provide 'ratio' in (0, 1) or a positive 'tolerance' in mm.")
            }
        } else if let tolerance, tolerance <= 0 {
            return Self.fail("bad_request", "'tolerance' must be a positive distance in mm.")
        }

        let clock = EvaluationDeadlineClock(seconds: Self.wallClockLimitSeconds)
        var replacements: [(before: Body, after: Body)] = []
        var entries: [[String: Any]] = []
        var previewMeshes: [RenderMesh] = []
        for body in bodies {
            let before = body.render.triangleCount
            guard before >= 4 else {
                return Self.fail("too_few_triangles",
                                 "Body '\(body.name)' has \(before) triangles; simplification "
                                 + "never goes below 4.")
            }
            let simplified: RenderMesh
            if let tolerance {
                // Tolerance takes precedence when both are given.
                guard let welded = Self.weldAndClean(body.render, tolerance: tolerance,
                                                     clock: clock) else {
                    if clock.expired { return limitTime() }
                    return Self.fail("invalid_mesh",
                                     "Body '\(body.name)' has non-finite coordinates; nothing changed.")
                }
                guard welded.mesh.triangleCount >= 4 else {
                    return Self.fail("simplify_too_aggressive",
                                     "That tolerance would leave fewer than 4 triangles; "
                                     + "nothing changed.")
                }
                simplified = welded.mesh
                entries.append(["bodyID": body.id.raw.uuidString,
                                "beforeTriangles": before,
                                "afterTriangles": welded.mesh.triangleCount,
                                "tolerance": tolerance])
            } else {
                guard let ratio else {
                    return Self.fail("bad_request", "Provide 'ratio' in (0, 1) or 'tolerance'.")
                }
                let target = max(4, Int((Double(before) * ratio).rounded()))
                var cell = max(Self.diagonal(body.render) * 0.01, 1e-9)
                var best: RenderMesh?
                var bestCell = cell
                for _ in 0..<28 {
                    guard let welded = Self.weldAndClean(body.render, tolerance: cell,
                                                         clock: clock) else {
                        if clock.expired { return limitTime() }
                        return Self.fail("invalid_mesh",
                                         "Body '\(body.name)' has non-finite coordinates; nothing changed.")
                    }
                    let candidate = welded.mesh
                    guard candidate.triangleCount >= 4 else { break }
                    best = candidate
                    bestCell = cell
                    if candidate.triangleCount <= target { break }
                    cell *= 1.6
                }
                guard let simplifiedMesh = best else {
                    return Self.fail("simplify_too_aggressive",
                                     "No cluster size kept at least 4 triangles; nothing changed.")
                }
                simplified = simplifiedMesh
                entries.append(["bodyID": body.id.raw.uuidString,
                                "beforeTriangles": before,
                                "afterTriangles": simplifiedMesh.triangleCount,
                                "targetTriangles": target,
                                "cellSize": bestCell])
            }
            var after = body
            after.render = simplified
            after.edges = FeatureEdgeExtractor.edges(from: simplified)
            after.euclid = nil
            after.brep = nil
            after.primitive = nil
            previewMeshes.append(simplified)
            replacements.append((before: body, after: after))
        }
        let gate = previewGate(action: "simplify", args: args, meshes: previewMeshes)
        if let refusal = gate.refusal { return refusal }
        if let reply = gate.reply { return reply }
        performReplacements(replacements, title: "Simplify Mesh")
        return ["ok": true,
                "action": "simplify",
                "mutated": true,
                "exactness": "mesh",
                "bodies": entries]
    }

    // MARK: material (non-destructive)

    private func material(_ args: [String: Any]) -> [String: Any] {
        guard case let .ok(bodies) = resolveBodies(args) else {
            return resolutionFailure(args)
        }
        var color: SIMD4<Double>?
        if let rawColor = args["color"] {
            guard let values = Self.doubles(rawColor), values.count == 3 || values.count == 4,
                  values.allSatisfy({ $0 >= 0 && $0 <= 1 }) else {
                return Self.fail("bad_request", "'color' must be [r, g, b] or [r, g, b, a] in 0…1.")
            }
            color = SIMD4(values[0], values[1], values[2], values.count == 4 ? values[3] : 1)
        }
        var opacity: Double?
        if let raw = args["opacity"] {
            guard let value = Self.number(raw), value >= 0, value <= 1 else {
                return Self.fail("bad_request", "'opacity' must be in 0…1.")
            }
            opacity = value
        }
        var metallic: Double?
        if let raw = args["metallic"] {
            guard let value = Self.number(raw), value >= 0, value <= 1 else {
                return Self.fail("bad_request", "'metallic' must be in 0…1.")
            }
            metallic = value
        }
        var roughness: Double?
        if let raw = args["roughness"] {
            guard let value = Self.number(raw), value >= 0, value <= 1 else {
                return Self.fail("bad_request", "'roughness' must be in 0…1.")
            }
            roughness = value
        }
        guard color != nil || opacity != nil || metallic != nil || roughness != nil else {
            return Self.fail("bad_request",
                             "Provide at least one of 'color', 'opacity', 'metallic' or 'roughness'.")
        }

        var commands: [DocumentCommand] = []
        for body in bodies {
            var spec = body.material ?? BodyMaterialSpec.default
            if let color { spec.baseColor = color }
            if let opacity { spec.baseColor.w = opacity }
            if let metallic { spec.metallic = metallic }
            if let roughness { spec.roughness = roughness }
            commands.append(SetMaterialCommand(bodyIDs: [body.id],
                                               material: spec.clamped,
                                               document: document.session.document))
        }
        performCommands(commands, title: "Material")
        return ["ok": true,
                "action": "material",
                "mutated": true,
                "exactness": "preserved",
                "bodyCount": bodies.count]
    }

    // MARK: text

    private func text(_ args: [String: Any]) -> [String: Any] {
        _ = args
        return Self.fail("text_mesh_unavailable",
                         "Text outlines are produced as sketch entities (TextSketch) and become "
                         + "solids through the sketch → extrude pipeline; this mesh service has "
                         + "no standalone text-to-mesh path.")
    }

    // MARK: image

    private func image(_ args: [String: Any]) -> [String: Any] {
        guard case let .ok(bodies) = resolveBodies(args) else {
            return resolutionFailure(args)
        }
        let data: Data
        if let base64 = args["imageBase64"] as? String {
            guard base64.utf8.count <= (Self.maxImageBytes + 2) / 3 * 4 else {
                return Self.fail("too_large_image",
                                 "Encoded image exceeds \(Self.maxImageBytes) bytes.")
            }
            guard let decoded = Data(base64Encoded: base64), !decoded.isEmpty,
                  decoded.count <= Self.maxImageBytes else {
                return Self.fail("bad_request", "'imageBase64' is not valid base64 image data.")
            }
            data = decoded
        } else if let imageID = args["imageID"] as? String,
                  let uuid = UUID(uuidString: imageID),
                  let inserted = document.session.document.images.first(where: { $0.id.raw == uuid }) {
            guard !inserted.imageData.isEmpty, inserted.imageData.count <= Self.maxImageBytes else {
                return Self.fail("bad_request",
                                 "The document image '\(inserted.name)' carries no usable bytes.")
            }
            data = inserted.imageData
        } else {
            return Self.fail("bad_request",
                             "Provide 'imageBase64' (PNG/JPEG bytes) or an existing 'imageID'.")
        }
        guard Self.isPNG(data) || Self.isJPEG(data) else {
            return Self.fail("unsupported_image", "Image bytes must be PNG or JPEG.")
        }

        var commands: [DocumentCommand] = []
        var textured: [[String: Any]] = []
        for body in bodies {
            var spec = body.material ?? BodyMaterialSpec.default
            spec.baseColorTexture = data
            commands.append(SetMaterialCommand(bodyIDs: [body.id],
                                               material: spec.clamped,
                                               document: document.session.document))
            textured.append(["bodyID": body.id.raw.uuidString,
                             "uvs": body.render.texcoords != nil])
        }
        performCommands(commands, title: "Image Material")
        return ["ok": true,
                "action": "image",
                "mutated": true,
                "exactness": "preserved",
                "textureBytes": data.count,
                "bodies": textured]
    }

    // MARK: Body resolution / limits

    private enum BodyResolution {
        case ok([Body])
        case failed([String: Any])
    }

    private func resolveBodies(_ args: [String: Any]) -> BodyResolution {
        var ids = stringList(args["bodyIDs"])
        if ids.isEmpty, let single = args["bodyID"] as? String { ids = [single] }
        guard !ids.isEmpty else {
            return .failed(Self.fail("bad_request", "Provide 'bodyID' or 'bodyIDs'."))
        }
        return resolveBodies(ids: ids)
    }

    private func resolveBodies(ids: [String]) -> BodyResolution {
        guard ids.count <= Self.maxInputBodies else {
            return .failed(Self.fail("too_many_bodies",
                                     "At most \(Self.maxInputBodies) bodies per operation; got \(ids.count)."))
        }
        guard Set(ids).count == ids.count else {
            return .failed(Self.fail("bad_request", "'bodyIDs' must not repeat a body."))
        }
        let live = document.session.document
        var bodies: [Body] = []
        var triangles = 0
        for idString in ids {
            guard let uuid = UUID(uuidString: idString),
                  let body = live.bodies.first(where: { $0.id.raw == uuid }) else {
                return .failed(Self.fail("unknown_body", "No body with id \(idString)."))
            }
            triangles += body.render.triangleCount
            guard triangles <= Self.maxInputTriangles else {
                return .failed(Self.fail("too_many_triangles",
                                         "Input exceeds \(Self.maxInputTriangles) triangles."))
            }
            bodies.append(body)
        }
        return .ok(bodies)
    }

    private func resolutionFailure(_ args: [String: Any]) -> [String: Any] {
        var ids = stringList(args["bodyIDs"])
        if ids.isEmpty, let single = args["bodyID"] as? String { ids = [single] }
        return resolutionFailure(ids: ids)
    }

    private func resolutionFailure(ids: [String]) -> [String: Any] {
        if case let .failed(response) = resolveBodies(ids: ids) { return response }
        return Self.fail("bad_request", "Bodies could not be resolved.")
    }

    /// Refuses destructive mesh ops on analytic B-rep bodies unless the
    /// caller acknowledged the downgrade with `forceMesh:true`.
    private func verifyMeshOnly(_ bodies: [Body], args: [String: Any], action: String) -> [String: Any]? {
        guard !Self.boolean(args["forceMesh"]) else { return nil }
        let analytic = bodies.filter { $0.brep != nil }
        guard analytic.isEmpty else {
            return Self.fail("brep_body_refused",
                             "'\(action)' rebuilds meshes and would drop the analytic B-rep of "
                             + "\(analytic.count) body(ies): "
                             + analytic.map(\.name).joined(separator: ", ")
                             + ". Pass forceMesh:true to acknowledge the downgrade.")
        }
        return nil
    }

    /// Preview/apply gate for destructive mesh operations.
    ///
    /// `preview:true` returns the transient result geometry (a bounded mesh
    /// snapshot a UI can draw) plus an order-independent content hash and the
    /// document revision/change-count it was computed against — WITHOUT
    /// touching the document. A subsequent apply may pass those values as
    /// `expectedPreviewHash` / `expectedRevision` / `expectedChangeCount`; a
    /// mismatch refuses with `preview_stale` instead of committing geometry
    /// the user never saw.
    private func previewGate(action: String, args: [String: Any],
                             meshes: [RenderMesh]) -> (reply: [String: Any]?,
                                                       refusal: [String: Any]?) {
        guard let hash = CADTransientMeshPreview.hash(of: meshes) else {
            return (nil, Self.fail("invalid_mesh",
                                   "The '\(action)' result has non-finite geometry; nothing changed."))
        }
        let revision = document.store.revision
        let changeCount = document.session.changeCount
        if let expected = args["expectedPreviewHash"] as? String, !expected.isEmpty {
            guard expected == hash else {
                return (nil, Self.fail("preview_stale",
                                       "The geometry changed since the preview; preview again before applying."))
            }
            if let expectedRevision = Self.integer(args["expectedRevision"]),
               expectedRevision != revision {
                return (nil, Self.fail("preview_stale",
                                       "The document changed since the preview; preview again before applying."))
            }
            if let expectedChangeCount = Self.integer(args["expectedChangeCount"]),
               expectedChangeCount != changeCount {
                return (nil, Self.fail("preview_stale",
                                       "The document changed since the preview; preview again before applying."))
            }
        }
        if Self.boolean(args["preview"]) {
            guard let snapshot = CADTransientMeshPreview.snapshot(of: meshes) else {
                return (nil, Self.fail("invalid_mesh", "The '\(action)' preview is empty."))
            }
            return (["ok": true,
                     "action": action,
                     "mutated": false,
                     "preview": true,
                     "exactness": "mesh",
                     "previewHash": hash,
                     "previewRevision": revision,
                     "previewChangeCount": changeCount,
                     "triangleCount": meshes.reduce(0) { $0 + $1.triangleCount },
                     "mesh": CADTransientMeshPreview.payload(snapshot)],
                    nil)
        }
        return (nil, nil)
    }

    private static func integer(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let number = raw as? NSNumber { return number.intValue }
        return nil
    }

    // MARK: Session commit helpers

    private func makeResultBody(name: String, mesh: Euclid.Mesh) -> Body {
        var localDocument = document.session.document
        return Body(name: localDocument.uniqueBodyName(base: name),
                    transform: .identity,
                    primitive: nil,
                    euclidMesh: mesh,
                    revision: localDocument.nextRevision())
    }

    /// Adds the result body and consumes the inputs in ONE undo step.
    private func commit(_ body: Body, consuming inputs: [Body], title: String) {
        var commands: [DocumentCommand] = [AddBodyCommand(body: body, title: title)]
        if !inputs.isEmpty {
            commands.append(DeleteBodiesCommand(ids: Set(inputs.map(\.id)),
                                                document: document.session.document))
        }
        performCommands(commands, title: title)
    }

    private func performReplacements(_ replacements: [(before: Body, after: Body)], title: String) {
        guard !replacements.isEmpty else { return }
        let commands = replacements.map {
            ReplaceBodyCommand(title: title, before: $0.before, after: $0.after)
        }
        performCommands(commands, title: title)
    }

    private func performCommands(_ commands: [DocumentCommand], title: String) {
        guard !commands.isEmpty else { return }
        if commands.count == 1 {
            document.session.perform(commands[0])
        } else {
            document.session.perform(CompositeCommand(title: title, commands: commands))
        }
    }

    private static func mutationResult(action: String,
                                       body: Body,
                                       extra: [String: Any]) -> [String: Any] {
        var response: [String: Any] = ["ok": true,
                                       "action": action,
                                       "mutated": true,
                                       "exactness": "mesh",
                                       "outputBodyID": body.id.raw.uuidString,
                                       "bodyName": body.name,
                                       "triangleCount": body.render.triangleCount]
        for (key, value) in extra { response[key] = value }
        return response
    }

    // MARK: Geometry helpers

    private static func worldMesh(_ body: Body) -> Euclid.Mesh {
        body.euclidMesh().transformed(by: body.transform.euclid)
    }

    private static func diagonal(_ mesh: RenderMesh) -> Double {
        let aabb = mesh.localAABB
        return simd_length(SIMD3(Double(aabb.max.x - aabb.min.x),
                                 Double(aabb.max.y - aabb.min.y),
                                 Double(aabb.max.z - aabb.min.z)))
    }

    /// Grid-quantized vertex welding; triangles that collapse to a repeated
    /// index or zero area are dropped. Returns nil for non-finite input or
    /// deadline expiry (the caller distinguishes with `clock.expired`).
    private static func weldAndClean(_ mesh: RenderMesh,
                                     tolerance: Double,
                                     clock: EvaluationDeadlineClock)
        -> (mesh: RenderMesh, weldedVertices: Int, removedTriangles: Int)? {
        for position in mesh.positions
        where !position.x.isFinite || !position.y.isFinite || !position.z.isFinite {
            return nil
        }
        guard mesh.normals.count == mesh.positions.count, tolerance > 0 else { return nil }

        var lookup = [ClusterKey: Int]()
        var sums = [SIMD3<Double>]()
        var normalSums = [SIMD3<Double>]()
        var counts = [Int]()
        var remap = [UInt32](repeating: 0, count: mesh.positions.count)
        for (index, position) in mesh.positions.enumerated() {
            if clock.isExpired() { return nil }
            let key = ClusterKey(position, cell: tolerance)
            let cluster: Int
            if let existing = lookup[key] {
                cluster = existing
            } else {
                cluster = sums.count
                lookup[key] = cluster
                sums.append(.zero)
                normalSums.append(.zero)
                counts.append(0)
            }
            sums[cluster] += SIMD3(Double(position.x), Double(position.y), Double(position.z))
            let normal = mesh.normals[index]
            normalSums[cluster] += SIMD3(Double(normal.x), Double(normal.y), Double(normal.z))
            counts[cluster] += 1
            remap[index] = UInt32(cluster)
        }

        var positions = [SIMD3<Float>]()
        var normals = [SIMD3<Float>]()
        positions.reserveCapacity(sums.count)
        normals.reserveCapacity(sums.count)
        for cluster in sums.indices {
            let count = Double(counts[cluster])
            positions.append(SIMD3(Float(sums[cluster].x / count),
                                   Float(sums[cluster].y / count),
                                   Float(sums[cluster].z / count)))
            let normal = normalSums[cluster]
            if simd_length(normal) > 1e-12 {
                let unit = simd_normalize(normal)
                normals.append(SIMD3(Float(unit.x), Float(unit.y), Float(unit.z)))
            } else {
                normals.append(SIMD3(0, 1, 0))
            }
        }

        var indices = [UInt32]()
        var removed = 0
        var triangle = 0
        while triangle < mesh.triangleCount {
            if clock.isExpired() { return nil }
            let base = triangle * 3
            triangle += 1
            let a = remap[Int(mesh.indices[base])]
            let b = remap[Int(mesh.indices[base + 1])]
            let c = remap[Int(mesh.indices[base + 2])]
            guard a != b, b != c, c != a else { removed += 1; continue }
            let pa = positions[Int(a)], pb = positions[Int(b)], pc = positions[Int(c)]
            guard simd_length(simd_cross(pb - pa, pc - pa)) > 1e-12 else {
                removed += 1
                continue
            }
            indices.append(contentsOf: [a, b, c])
        }
        let cleaned = RenderMesh(positions: positions, normals: normals, indices: indices)
        return (cleaned,
                mesh.positions.count - sums.count,
                removed)
    }

    private struct ClusterKey: Hashable {
        let x, y, z: Int64
        init(_ position: SIMD3<Float>, cell: Double) {
            x = MeshQuantize.key64(Double(position.x), quantum: cell)
            y = MeshQuantize.key64(Double(position.y), quantum: cell)
            z = MeshQuantize.key64(Double(position.z), quantum: cell)
        }
    }

    private struct PositionKey: Hashable {
        let x, y, z: Int64
        init(_ position: SIMD3<Float>) {
            let inverse: Float = 1 / 1e-5
            x = MeshQuantize.key64(position.x, inverseQuantum: inverse)
            y = MeshQuantize.key64(position.y, inverseQuantum: inverse)
            z = MeshQuantize.key64(position.z, inverseQuantum: inverse)
        }
    }

    private struct EdgeKey: Hashable {
        let a, b: Int
        init(_ i: Int, _ j: Int) {
            if i < j { a = i; b = j } else { a = j; b = i }
        }
    }

    private struct EdgeStats {
        var triangleCount: Int
        var edgeCount: Int
        var boundary: Int
        var nonManifold: Int
        var boundarySegments: [(SIMD3<Float>, SIMD3<Float>)]
    }

    /// Boundary edges are used by exactly one triangle; non-manifold edges by
    /// more than two. Positions are topologically welded first, because the
    /// render mesh splits vertices along hard edges (position + normal).
    private static func edgeStats(_ mesh: RenderMesh,
                                  clock: EvaluationDeadlineClock) -> EdgeStats? {
        guard mesh.triangleCount > 0 else {
            return EdgeStats(triangleCount: 0, edgeCount: 0, boundary: 0,
                             nonManifold: 0, boundarySegments: [])
        }
        var lookup = [PositionKey: Int]()
        var topo = [Int](repeating: 0, count: mesh.positions.count)
        var unique = [SIMD3<Float>]()
        for (index, position) in mesh.positions.enumerated() {
            if clock.isExpired() { return nil }
            let key = PositionKey(position)
            if let existing = lookup[key] {
                topo[index] = existing
            } else {
                lookup[key] = unique.count
                topo[index] = unique.count
                unique.append(position)
            }
        }
        var edgeUses = [EdgeKey: Int]()
        var triangle = 0
        while triangle < mesh.triangleCount {
            if clock.isExpired() { return nil }
            let base = triangle * 3
            triangle += 1
            let i0 = Int(mesh.indices[base])
            let i1 = Int(mesh.indices[base + 1])
            let i2 = Int(mesh.indices[base + 2])
            let p0 = mesh.positions[i0], p1 = mesh.positions[i1], p2 = mesh.positions[i2]
            guard simd_length(simd_cross(p1 - p0, p2 - p0)) > 1e-12 else { continue }
            let t0 = topo[i0], t1 = topo[i1], t2 = topo[i2]
            guard t0 != t1, t1 != t2, t2 != t0 else { continue }
            edgeUses[EdgeKey(t0, t1), default: 0] += 1
            edgeUses[EdgeKey(t1, t2), default: 0] += 1
            edgeUses[EdgeKey(t2, t0), default: 0] += 1
        }
        var boundary = 0
        var nonManifold = 0
        var segments: [(SIMD3<Float>, SIMD3<Float>)] = []
        for (edge, uses) in edgeUses {
            if uses == 1 {
                boundary += 1
                segments.append((unique[edge.a], unique[edge.b]))
            } else if uses > 2 {
                nonManifold += 1
            }
        }
        return EdgeStats(triangleCount: mesh.triangleCount,
                         edgeCount: edgeUses.count,
                         boundary: boundary,
                         nonManifold: nonManifold,
                         boundarySegments: segments)
    }

    private static func worldBounds(of segments: [(SIMD3<Float>, SIMD3<Float>)],
                                    transform: Transform3D) -> [[Double]]? {
        guard !segments.isEmpty else { return nil }
        var minimum = SIMD3<Double>(repeating: .infinity)
        var maximum = SIMD3<Double>(repeating: -.infinity)
        for (a, b) in segments {
            for point in [a, b] {
                let world = transform.applying(to: SIMD3(Double(point.x),
                                                         Double(point.y),
                                                         Double(point.z)))
                minimum = simd_min(minimum, world)
                maximum = simd_max(maximum, world)
            }
        }
        guard minimum.x.isFinite, maximum.x.isFinite else { return nil }
        return [[minimum.x, minimum.y, minimum.z], [maximum.x, maximum.y, maximum.z]]
    }

    // MARK: Argument helpers

    private func stringList(_ raw: Any?) -> [String] {
        if let list = raw as? [String] { return list }
        if let list = raw as? [Any] { return list.compactMap { $0 as? String } }
        return []
    }

    private static func number(_ raw: Any?) -> Double? {
        guard let raw else { return nil }
        // `NSNumber(1) is Bool` is true under Swift bridging, so booleans are
        // distinguished from JSON numbers by their CoreFoundation type.
        if let nsNumber = raw as? NSNumber {
            guard CFGetTypeID(nsNumber) != CFBooleanGetTypeID() else { return nil }
            let value = nsNumber.doubleValue
            return value.isFinite ? value : nil
        }
        if raw is Bool { return nil }
        if let value = raw as? Double { return value.isFinite ? value : nil }
        if let value = raw as? Int { return Double(value) }
        return nil
    }

    private static func boolean(_ raw: Any?) -> Bool {
        guard let raw, let nsNumber = raw as? NSNumber else { return false }
        return CFGetTypeID(nsNumber) == CFBooleanGetTypeID()
    }

    private static func doubles(_ raw: Any?) -> [Double]? {
        guard let list = raw as? [Any] else {
            if let list = raw as? [Double] { return list }
            return nil
        }
        var values: [Double] = []
        values.reserveCapacity(list.count)
        for element in list {
            guard let value = number(element) else { return nil }
            values.append(value)
        }
        return values
    }

    private func sanitizeName(_ raw: Any?) -> String? {
        guard let text = raw as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(120))
    }

    private static func isPNG(_ data: Data) -> Bool {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= signature.count else { return false }
        return Array(data.prefix(signature.count)) == signature
    }

    private static func isJPEG(_ data: Data) -> Bool {
        guard data.count >= 3 else { return false }
        return data[data.startIndex] == 0xFF
            && data[data.startIndex + 1] == 0xD8
            && data[data.startIndex + 2] == 0xFF
    }

    // MARK: Response helpers

    private func limitTime() -> [String: Any] {
        Self.fail("limit_time",
                  "The mesh operation exceeded the \(Self.wallClockLimitSeconds)-second wall-clock limit; nothing changed.")
    }

    static func fail(_ code: String, _ message: String) -> [String: Any] {
        ["ok": false, "error": code, "message": message]
    }
}
