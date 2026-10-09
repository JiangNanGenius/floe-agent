//
//  AgentExec.swift
//  openshape3d
//
//  The parameterized half of the DEBUG-only agent bridge.
//
//  `/v1/command` ARMS a tool: it presses the same button a person would press,
//  and the tool then waits for a drag or a typed number that an agent has no
//  way to supply. That is fine for navigating and inspecting, and useless for
//  building anything — "extrude" without "12 mm" is not a modeling operation.
//
//  `/v1/exec` is the other half: one request carries the operation AND its
//  numbers, so a model can be built without a gesture. It deliberately does NOT
//  puppet the interactive state machine (`beginCreate` → drag → `commitTool`).
//  It goes to the seam the architecture already mandates — `DocumentCommand`
//  for mutations, `FeatureKind` for parametric intent — so an exec'd model is
//  byte-identical to a hand-built one, replays through the same graph, and
//  appears in History like any other feature. Anything else would be testing a
//  second code path that no user ever exercises.
//
//  This file is PURE: JSON in, a typed op or a precise error out, no editor.
//  That split is the same one `AgentRouter`/`AgentBridge` already make, and for
//  the same reason — the unit suite cannot build an `EditorViewModel` at all
//  (STATUS gotcha 1), so everything worth asserting on has to live somewhere it
//  can be reached without one.
//
//  UNITS: millimetres and degrees, matching what the UI displays and what a
//  person would type — and, as it happens, matching what the feature graph
//  already stores. `FeatureKind.revolve` holds DEGREES and `FeatureGraph`
//  converts to radians once, at the OCCT boundary. This file must therefore
//  NOT convert: doing so produced a 6.28-degree revolve that rendered as a
//  perfectly plausible solid instead of failing, which is the worst way for a
//  unit bug to behave.
//


import Foundation
import simd

// MARK: - Failure

/// `code` is stable and machine-readable; `message` is for a human reading a log.
/// Both travel to the client, because an agent that cannot tell "you spelled the
/// op wrong" from "that body does not exist" will retry the wrong thing forever
/// — the same reasoning that shaped `AgentRouter`'s three-way command split.
nonisolated struct AgentExecError: Error, Sendable, Equatable {
    var code: String
    var message: String
}

// MARK: - What was asked for

/// One ordered section of a loft: which sketch, and a seed point inside the
/// closed region on it. A struct (not a tuple) so `AgentExecOp` stays `Equatable`.
nonisolated struct LoftSection: Sendable, Equatable {
    let sketch: SketchID
    let seed: SIMD2<Double>
}

nonisolated enum AgentExecOp: Sendable, Equatable {
    case createSketch(name: String, plane: SketchPlane)
    /// Import a mesh file (glb/gltf/usdz/obj/zip) from a path on the host
    /// — the simulator shares the Mac's file system — exactly as the Import
    /// menu would. `fileName` overrides the name the parts are labelled with.
    case importFile(path: String, fileName: String?, unitScale: Double?)
    case addEntities(sketch: SketchID, entities: [SketchEntity], constructionIndices: Set<Int>)
    /// `taperDegrees` ≠ 0 makes this a DRAFT extrude (the profile lofts to an
    /// offset copy, walls sloped by the angle — cast/mould release); 0 is a
    /// plain straight prism. Positive contracts the section along the extrude.
    /// `end` (Through All / Up To Next) replaces `distance`: the bridge
    /// resolves it against the document's bodies at record time, so the
    /// node still carries a plain distance (see `ExtrudeEndKit`).
    case extrude(sketch: SketchID, seed: SIMD2<Double>, distance: Double,
                 symmetric: Bool, taperDegrees: Double,
                 boolean: BooleanIntent.Op, targets: [BodyID], end: ExtrudeEnd?)
    /// Degrees, NOT radians. `FeatureKind.revolve`'s `Expr` stores degrees and
    /// `FeatureGraph` converts once at the OCCT boundary (`angle.value * .pi / 180`).
    /// Converting here too silently produced a 6.28-DEGREE revolve that still
    /// looked like a plausible solid — a wrong model, not an error.
    case revolve(sketch: SketchID, seed: SIMD2<Double>, axis: RevolveAxis,
                 angleDegrees: Double, boolean: BooleanIntent.Op, targets: [BodyID])
    case pattern(body: BodyID, spec: PatternSpec)
    case mirror(body: BodyID, plane: SketchPlane, keepOriginal: Bool)
    /// Move a body in place (same id): a rigid delta, rotation already folded
    /// about its centre. Scale is never set here.
    case transform(body: BodyID, delta: Transform3D)
    /// `kind` stays a String here so this file needs no `BooleanKind`, which is
    /// main-actor-isolated under the project's `SWIFT_DEFAULT_ACTOR_ISOLATION`.
    /// `AgentBridge` maps it on the far side of the hop. Validated here anyway,
    /// so a typo is a 400 and never a silent no-op.
    case boolean(kind: String, target: BodyID, tools: [BodyID])
    /// Edges are 1-based kernel edge indices from `GET /v1/edges?body=` —
    /// the same numbering the whole identity layer shares
    /// (TOPO_NAMING_HISTORY_DESIGN step 4b unblocked expressing this over
    /// the wire: the recorded refs carry durable `EdgeName`s, so the feature
    /// replays by identity like a hand-picked blend).
    case blend(body: BodyID, isFillet: Bool, amount: Double, edges: [Int])
    /// Open faces are 1-based kernel face indices from `GET /v1/faces?body=`;
    /// EMPTY means a fully-enclosed hollow.
    case shell(body: BodyID, thickness: Double, openFaces: [Int])
    /// Spine points are WORLD-space mm, ≥2 — the same representation
    /// `FeatureKind.sweep` stores (a sweep's path is routinely drawn on a
    /// different plane than its profile, so plane-local would be ambiguous).
    case sweep(sketch: SketchID, seed: SIMD2<Double>, spine: [SIMD3<Double>],
               boolean: BooleanIntent.Op, targets: [BodyID], helix: HelixSpec?)
    /// ≥2 ordered sections, each a (sketch, seed) that resolves to a profile
    /// on that sketch's plane; OCCT lofts a solid through them in order. Each
    /// section is on its OWN sketch/plane — that is the whole point of a loft.
    case loft(sections: [LoftSection],
              boolean: BooleanIntent.Op, targets: [BodyID])
    /// Push/pull one planar (or cylindrical) face by `distance` mm — the
    /// direct-modeling move that grows or shrinks the solid. Face is a 1-based
    /// kernel index from `GET /v1/faces?body=`. `radial` picks the
    /// cylinder-radial mode (resize a bore/boss) over the default planar-axial.
    case pushPull(body: BodyID, face: Int, distance: Double, radial: Bool)
    /// Face translate (spec §5): move one face by `[du, dv, dn]` in its OWN
    /// (u, v, n) basis, mm — a normal move grows/shrinks, a lateral move
    /// shears the solid.
    case moveFace(body: BodyID, face: Int, delta: SIMD3<Double>)
    /// Face scale (spec §5): scale one face about its centre by `factor`
    /// (> 0), tapering the solid.
    case scaleFace(body: BodyID, face: Int, factor: Double)
    /// Face rotate (spec §5): rotate one face by `angleDegrees` about a line
    /// through its centre, `axis` in the face's own (u, v, n) basis.
    case rotateFace(body: BodyID, face: Int, angleDegrees: Double, axis: SIMD3<Double>)
    /// Faces are 1-based kernel indices from `GET /v1/faces?body=` — OCCT
    /// heals the surrounding faces over the removed ones (spec §4.16).
    case deleteFace(body: BodyID, faces: [Int])
    /// Draft an EXISTING face about its intersection with a world neutral
    /// plane (SOLIDWORKS Draft). Positive narrows the body away from that
    /// plane; the face keeps its neighbours' planes, unlike `rotateFace`.
    case draftFace(body: BodyID, face: Int, neutralOrigin: SIMD3<Double>,
                   neutralNormal: SIMD3<Double>, angleDegrees: Double)
    /// Extend/trim one face until it lies on the given world plane
    /// (spec §4.12). The target is a PLANE, not a face ref — same v1
    /// limitation as the interactive tool, for the same reason.
    case replaceFace(body: BodyID, face: Int, targetOrigin: SIMD3<Double>,
                     targetNormal: SIMD3<Double>, flip: Bool)
    /// The Material sheet's Apply: one appearance over a set of bodies, one
    /// undo step. Not a feature — appearance lives on the body, not in the
    /// graph — so it goes through `SetMaterialCommand` like the sheet does.
    case setMaterial(bodies: [BodyID], material: BodyMaterialSpec)
    /// The Items panel's eye: hide or show bodies, sketches or planes by id
    /// (the bridge resolves which kind each is), or every sketch at once —
    /// `/v1/state` lists no sketch ids, and a finished model usually wants
    /// all its profiles out of the way.
    case setHidden(ids: [UUID], allSketches: Bool, hidden: Bool)
}

// MARK: - Parsing

nonisolated enum AgentExec {

    /// Every op this build accepts, for `/v1/commands`-style discovery and for
    /// naming the alternatives in an `unknown_op` message.
    static let opNames = [
        "sketch.create", "sketch.addEntities",
        "feature.extrude", "feature.revolve",
        "feature.pattern", "feature.mirror", "feature.transform", "feature.boolean",
        "feature.fillet", "feature.chamfer", "feature.shell",
        "feature.sweep", "feature.loft", "feature.pushPull",
        "feature.moveFace", "feature.scaleFace", "feature.rotateFace",
        "feature.deleteFace", "feature.replaceFace", "feature.draftFace",
        "body.setMaterial", "item.setHidden",
    ]

    static let booleanKinds = ["union", "subtract", "intersect"]
    static let booleanOps = ["newBody", "union", "subtract", "intersect"]

    static func parse(_ body: [String: Any]?) -> Result<AgentExecOp, AgentExecError> {
        guard let body else {
            return .failure(.init(code: "missing_body",
                                  message: #"POST JSON like {"op":"sketch.create","args":{…}}."#))
        }
        guard let op = body["op"] as? String, !op.isEmpty else {
            return .failure(.init(code: "missing_op",
                                  message: "Body needs an \"op\". Known ops: \(opNames.joined(separator: ", "))."))
        }
        let args = body["args"] as? [String: Any] ?? [:]

        switch op {
        case "sketch.create":      return parseCreateSketch(args)
        case "document.import":    return parseImportFile(args)
        case "sketch.addEntities": return parseAddEntities(args)
        case "feature.extrude":    return parseExtrude(args)
        case "feature.revolve":    return parseRevolve(args)
        case "feature.pattern":    return parsePattern(args)
        case "feature.mirror":     return parseMirror(args)
        case "feature.transform":  return parseTransform(args)
        case "feature.boolean":    return parseBoolean(args)
        case "feature.fillet":     return parseBlend(args, isFillet: true)
        case "feature.chamfer":    return parseBlend(args, isFillet: false)
        case "feature.shell":      return parseShell(args)
        case "feature.sweep":      return parseSweep(args)
        case "feature.loft":       return parseLoft(args)
        case "feature.pushPull":   return parsePushPull(args)
        case "feature.moveFace":   return parseMoveFace(args)
        case "feature.scaleFace":  return parseScaleFace(args)
        case "feature.rotateFace": return parseRotateFace(args)
        case "feature.deleteFace": return parseDeleteFace(args)
        case "feature.draftFace":  return parseDraftFace(args)
        case "feature.replaceFace": return parseReplaceFace(args)
        case "body.setMaterial":   return parseSetMaterial(args)
        case "item.setHidden":     return parseSetHidden(args)
        default:
            return .failure(.init(code: "unknown_op",
                                  message: "No exec op '\(op)'. Known ops: \(opNames.joined(separator: ", "))."))
        }
    }

    // MARK: Ops

    private static func parseImportFile(_ a: [String: Any]) -> Result<AgentExecOp, AgentExecError> {
        guard let path = a["path"] as? String, !path.isEmpty else {
            return .failure(.init(code: "missing_path",
                                  message: "\"path\" is required (an absolute file path on the host)."))
        }
        // Optional units: "mm" | "cm" | "m" | "in" | "ft" (or a numeric
        // "unitScale" in mm per file unit). Absent → the detected unit.
        var unitScale: Double?
        if let units = a["units"] as? String {
            guard let unit = MeshImportUnit.parse(units) else {
                return .failure(.init(code: "bad_units",
                                      message: "\"units\" must be one of mm, cm, m, in, ft."))
            }
            unitScale = unit.millimetresPerUnit
        } else if let scale = a["unitScale"] as? Double, scale > 0 {
            unitScale = scale
        }
        return .success(.importFile(path: path, fileName: a["fileName"] as? String, unitScale: unitScale))
    }

    private static func parseCreateSketch(_ a: [String: Any]) -> Result<AgentExecOp, AgentExecError> {
        let name = a["name"] as? String ?? "Sketch"
        // No plane given means the ground plane — by far the common case, and
        // it keeps a first call down to {"op":"sketch.create"}.
        guard a["origin"] != nil || a["xAxis"] != nil || a["yAxis"] != nil else {
            return .success(.createSketch(name: name, plane: .ground))
        }
        do {
            let origin = try vector3(a, "origin", default: .zero)
            let x = try vector3(a, "xAxis", default: SIMD3(1, 0, 0))
            let y = try vector3(a, "yAxis", default: SIMD3(0, 0, -1))
            guard simd_length(x) > 1e-9, simd_length(y) > 1e-9 else {
                return .failure(.init(code: "degenerate_plane",
                                      message: "xAxis and yAxis must be non-zero."))
            }
            guard simd_length(simd_cross(x, y)) > 1e-9 else {
                return .failure(.init(code: "degenerate_plane",
                                      message: "xAxis and yAxis are parallel, so the plane has no normal."))
            }
            return .success(.createSketch(
                name: name,
                plane: SketchPlane(origin: origin,
                                   xAxis: simd_normalize(x),
                                   yAxis: simd_normalize(y))))
        } catch let e as AgentExecError { return .failure(e) } catch { return .failure(unexpected) }
    }

    private static func parseAddEntities(_ a: [String: Any]) -> Result<AgentExecOp, AgentExecError> {
        do {
            let sketch = SketchID(raw: try uuid(a, "sketchID"))
            guard let raw = a["entities"] as? [[String: Any]], !raw.isEmpty else {
                return .failure(.init(code: "missing_entities",
                                      message: #"args.entities must be a non-empty array of {"kind":…} objects."#))
            }
            var entities: [SketchEntity] = []
            for (i, item) in raw.enumerated() {
                switch entity(item, index: i) {
                case .success(let e): entities.append(e)
                case .failure(let f): return .failure(f)
                }
            }
            let construction = Set((a["construction"] as? [Int] ?? []).filter { $0 >= 0 && $0 < entities.count })
            return .success(.addEntities(sketch: sketch, entities: entities, constructionIndices: construction))
        } catch let e as AgentExecError { return .failure(e) } catch { return .failure(unexpected) }
    }

    private static func parseExtrude(_ a: [String: Any]) -> Result<AgentExecOp, AgentExecError> {
        do {
            let sketch = SketchID(raw: try uuid(a, "sketchID"))
            let seed = try vector2(a, "seedPoint")
            // "end": "throughAll" | "upToNext" — then "distance" is optional
            // and only its SIGN matters (which way along the plane normal).
            var end: ExtrudeEnd? = nil
            if let raw = a["end"] {
                guard let s = raw as? String, let parsed = ExtrudeEnd(rawValue: s) else {
                    return .failure(.init(code: "unknown_end",
                                          message: "\"end\" must be one of \(ExtrudeEnd.allCases.map(\.rawValue).joined(separator: ", "))."))
                }
                end = parsed == .blind ? nil : parsed
            }
            let distance = try optionalDouble(a, "distance") ?? (end != nil ? 1 : 0)
            guard abs(distance) > 1e-9 else {
                return .failure(.init(code: "zero_distance",
                                      message: "A zero-distance extrude produces nothing. Give a non-zero \"distance\" in mm, or an \"end\" of throughAll / upToNext."))
            }
            let taper = try optionalDouble(a, "taperDegrees") ?? 0
            guard abs(taper) < 89 else {
                return .failure(.init(code: "bad_taper",
                                      message: #""taperDegrees" must be within ±89 (0 = straight)."#))
            }
            guard end == nil || abs(taper) < 1e-9 else {
                return .failure(.init(code: "end_with_taper",
                                      message: "\"end\" conditions apply to straight extrudes; drop \"taperDegrees\" or give a distance."))
            }
            let (op, targets) = try booleanIntent(a)
            return .success(.extrude(sketch: sketch, seed: seed, distance: distance,
                                     symmetric: a["symmetric"] as? Bool ?? false,
                                     taperDegrees: taper, boolean: op, targets: targets, end: end))
        } catch let e as AgentExecError { return .failure(e) } catch { return .failure(unexpected) }
    }

    private static func parseRevolve(_ a: [String: Any]) -> Result<AgentExecOp, AgentExecError> {
        do {
            let sketch = SketchID(raw: try uuid(a, "sketchID"))
            let seed = try vector2(a, "seedPoint")
            let point = try vector2(a, "axisPoint")
            let direction = try vector2(a, "axisDirection")
            guard simd_length(direction) > 1e-9 else {
                return .failure(.init(code: "degenerate_axis",
                                      message: "\"axisDirection\" must be non-zero — a revolve needs a line to spin about."))
            }
            let degrees = try angleDegrees(a, "angleDegrees", default: 360)
            let (op, targets) = try booleanIntent(a)
            return .success(.revolve(
                sketch: sketch, seed: seed,
                axis: RevolveAxis(point: point, direction: simd_normalize(direction)),
                angleDegrees: degrees,
                boolean: op, targets: targets))
        } catch let e as AgentExecError { return .failure(e) } catch { return .failure(unexpected) }
    }

    private static func parsePattern(_ a: [String: Any]) -> Result<AgentExecOp, AgentExecError> {
        do {
            let body = BodyID(raw: try uuid(a, "bodyID"))
            let kindName = a["kind"] as? String ?? "circular"
            guard let kind = PatternSpec.Kind(rawValue: kindName) else {
                return .failure(.init(code: "unknown_pattern_kind",
                                      message: "\"kind\" must be linear or circular, not '\(kindName)'."))
            }
            let count = a["count"] as? Int ?? 0
            guard count >= 1 else {
                return .failure(.init(code: "bad_count",
                                      message: "\"count\" is the TOTAL number of instances including the original, so it must be >= 1."))
            }
            let axis = try vector3(a, "axis", default: SIMD3(0, 1, 0))
            guard simd_length(axis) > 1e-9 else {
                return .failure(.init(code: "degenerate_axis", message: "\"axis\" must be non-zero."))
            }
            let spec = PatternSpec(
                kind: kind,
                axis: simd_normalize(axis),
                center: try vector3(a, "center", default: .zero),
                count: count,
                spacing: try optionalDouble(a, "spacing") ?? 0,
                totalAngle: (try angleDegrees(a, "totalAngleDegrees", default: 360)) * .pi / 180,
                rotateInstances: a["rotateInstances"] as? Bool ?? true)
            return .success(.pattern(body: body, spec: spec))
        } catch let e as AgentExecError { return .failure(e) } catch { return .failure(unexpected) }
    }

    private static func parseMirror(_ a: [String: Any]) -> Result<AgentExecOp, AgentExecError> {
        do {
            let body = BodyID(raw: try uuid(a, "bodyID"))
            let origin = try vector3(a, "planeOrigin", default: .zero)
            let normal = try vector3(a, "planeNormal", default: SIMD3(1, 0, 0))
            guard simd_length(normal) > 1e-9 else {
                return .failure(.init(code: "degenerate_plane", message: "\"planeNormal\" must be non-zero."))
            }
            return .success(.mirror(body: body,
                                    plane: plane(origin: origin, normal: simd_normalize(normal)),
                                    keepOriginal: a["keepOriginal"] as? Bool ?? true))
        } catch let e as AgentExecError { return .failure(e) } catch { return .failure(unexpected) }
    }

    /// `feature.transform {bodyID, translation? [x,y,z], rotationAxis? [x,y,z],
    /// rotationDegrees?, rotationCenter? [x,y,z]}` — moves the body IN PLACE
    /// (it keeps its id). A rotation about centre c is folded into the delta as
    /// T(c)·R·T(−c), then the translation is added. An identity is refused:
    /// a move that moves nothing is a script bug, not a feature.
    private static func parseTransform(_ a: [String: Any]) -> Result<AgentExecOp, AgentExecError> {
        do {
            let body = BodyID(raw: try uuid(a, "bodyID"))
            let t = try vector3(a, "translation", default: .zero)
            let degrees = try optionalDouble(a, "rotationDegrees") ?? 0
            let scale = try optionalDouble(a, "scale") ?? 1
            guard scale > 1e-12 else {
                return .failure(.init(code: "bad_scale", message: "\"scale\" must be a positive factor."))
            }
            // Rotation and scale about `rotationCenter` c fold into the delta as
            // T(c)·R·S·T(−c), then the translation is added: c − R(s·c) + t.
            var delta = Transform3D()
            delta.scale = scale
            let centre = try vector3(a, "rotationCenter", default: .zero)
            if abs(degrees) > 1e-12 {
                let axis = try vector3(a, "rotationAxis", default: SIMD3(0, 0, 1))
                guard simd_length(axis) > 1e-9 else {
                    return .failure(.init(code: "degenerate_axis", message: "\"rotationAxis\" must be non-zero."))
                }
                delta.rotation = simd_quatd(angle: degrees * .pi / 180, axis: simd_normalize(axis))
            }
            delta.translation = centre - delta.rotation.act(centre * scale) + t
            guard simd_length(t) > 1e-12 || abs(degrees) > 1e-12 || abs(scale - 1) > 1e-12 else {
                return .failure(.init(code: "identity_transform",
                                      message: "Give a non-zero \"translation\", \"rotationDegrees\" and/or a \"scale\" ≠ 1 — an identity move does nothing."))
            }
            return .success(.transform(body: body, delta: delta))
        } catch let e as AgentExecError { return .failure(e) } catch { return .failure(unexpected) }
    }

    private static func parseBoolean(_ a: [String: Any]) -> Result<AgentExecOp, AgentExecError> {
        do {
            let kind = a["kind"] as? String ?? ""
            guard booleanKinds.contains(kind) else {
                return .failure(.init(code: "unknown_boolean_kind",
                                      message: "\"kind\" must be one of \(booleanKinds.joined(separator: ", "))."))
            }
            let target = BodyID(raw: try uuid(a, "targetBodyID"))
            guard let toolStrings = a["toolBodyIDs"] as? [String], !toolStrings.isEmpty else {
                return .failure(.init(code: "missing_tools",
                                      message: "\"toolBodyIDs\" must be a non-empty array of body id strings."))
            }
            var tools: [BodyID] = []
            for s in toolStrings {
                guard let u = UUID(uuidString: s) else {
                    return .failure(.init(code: "bad_uuid",
                                          message: "'\(s)' in toolBodyIDs is not a UUID. Body ids come from /v1/state."))
                }
                tools.append(BodyID(raw: u))
            }
            guard !tools.contains(target) else {
                return .failure(.init(code: "self_boolean",
                                      message: "A body cannot be its own boolean tool."))
            }
            return .success(.boolean(kind: kind, target: target, tools: tools))
        } catch let e as AgentExecError { return .failure(e) } catch { return .failure(unexpected) }
    }

    // MARK: Blends + shell (identity-addressed, step 4b/5)

    private static func parseBlend(_ a: [String: Any],
                                   isFillet: Bool) -> Result<AgentExecOp, AgentExecError> {
        do {
            let body = BodyID(raw: try uuid(a, "bodyID"))
            let key = isFillet ? "radius" : "setback"
            let amount = try double(a, key)
            guard amount > 0 else {
                return .failure(.init(code: "bad_\(key)",
                                      message: "args.\(key) must be > 0 mm."))
            }
            let edges = try edgeIndices(a, "edges", allowEmpty: false)
            return .success(.blend(body: body, isFillet: isFillet,
                                   amount: amount, edges: edges))
        } catch let e as AgentExecError { return .failure(e) } catch { return .failure(unexpected) }
    }

    private static func parseShell(_ a: [String: Any]) -> Result<AgentExecOp, AgentExecError> {
        do {
            let body = BodyID(raw: try uuid(a, "bodyID"))
            let thickness = try double(a, "thickness")
            guard thickness != 0, thickness.isFinite else {
                return .failure(.init(code: "bad_thickness",
                                      message: "args.thickness must be a non-zero wall in mm: positive hollows inward, negative grows outward."))
            }
            // Empty (or absent) openFaces = a fully-enclosed hollow.
            let openFaces = try edgeIndices(a, "openFaces", allowEmpty: true)
            return .success(.shell(body: body, thickness: thickness,
                                   openFaces: openFaces))
        } catch let e as AgentExecError { return .failure(e) } catch { return .failure(unexpected) }
    }

    private static func parseSweep(_ a: [String: Any]) -> Result<AgentExecOp, AgentExecError> {
        do {
            let sketch = SketchID(raw: try uuid(a, "sketchID"))
            let seed = try vector2(a, "seedPoint")
            // An exact helix may replace the polyline: the render mesh then
            // follows a polyline SAMPLED from the same spec, so the two agree.
            let helix = try parseHelix(a["helix"])
            let spine: [SIMD3<Double>]
            if let raw = a["spine"] as? [[Double]] {
                guard raw.count >= 2,
                      raw.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }) else {
                    return .failure(.init(code: "missing_spine",
                                          message: "args.spine must be ≥2 world-space "
                                          + "[x, y, z] points in mm."))
                }
                spine = raw.map { SIMD3($0[0], $0[1], $0[2]) }
            } else if let helix {
                spine = helix.sampledSpine()
            } else {
                return .failure(.init(code: "missing_spine",
                                      message: "args.spine must be ≥2 world-space "
                                      + "[x, y, z] points in mm — or give \"helix\"."))
            }
            let (op, targets) = try booleanIntent(a)
            return .success(.sweep(sketch: sketch, seed: seed, spine: spine,
                                   boolean: op, targets: targets, helix: helix))
        } catch let e as AgentExecError { return .failure(e) } catch { return .failure(unexpected) }
    }

    /// `"helix": {axisPoint, axisDirection, radius, pitch, turns,
    /// referenceDirection?, startAngle?}` — an EXACT helical spine. Positive
    /// pitch is right-handed about `axisDirection`; `referenceDirection` is
    /// where angle 0 points (any perpendicular when omitted).
    private static func parseHelix(_ raw: Any?) throws -> HelixSpec? {
        guard let raw else { return nil }
        guard let h = raw as? [String: Any] else {
            throw AgentExecError(code: "bad_helix",
                                 message: "\"helix\" must be an object: {axisPoint, axisDirection, "
                                 + "radius, pitch, turns, referenceDirection?, startAngle?}.")
        }
        let axisPoint = try vector3(h, "axisPoint", default: .zero)
        let axisDirection = try vector3(h, "axisDirection", default: SIMD3(0, 1, 0))
        guard simd_length(axisDirection) > 1e-9 else {
            throw AgentExecError(code: "bad_helix", message: "helix.axisDirection must be non-zero.")
        }
        let n = simd_normalize(axisDirection)
        var reference = try vector3(h, "referenceDirection", default: .zero)
        reference -= simd_dot(reference, n) * n
        if simd_length(reference) < 1e-9 {
            let pick: SIMD3<Double> = abs(n.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
            reference = simd_cross(n, pick)
        }
        let radius = try double(h, "radius"), pitch = try double(h, "pitch"), turns = try double(h, "turns")
        guard radius > 0, turns > 0, abs(pitch) > 1e-9 else {
            throw AgentExecError(code: "bad_helix",
                                 message: "helix.radius and helix.turns must be > 0 and helix.pitch non-zero.")
        }
        let startAngle = try optionalDouble(h, "startAngle") ?? 0
        return HelixSpec(axisPoint: axisPoint, axisDirection: n,
                         referenceDirection: simd_normalize(reference),
                         radius: radius, pitch: pitch, turns: turns, startAngle: startAngle)
    }

    private static func parseLoft(_ a: [String: Any]) -> Result<AgentExecOp, AgentExecError> {
        do {
            guard let raw = a["sections"] as? [[String: Any]], raw.count >= 2 else {
                return .failure(.init(code: "missing_sections",
                                      message: "args.sections must be ≥2 "
                                      + #"{"sketchID":…,"seedPoint":[x,y]} entries."#))
            }
            var sections: [LoftSection] = []
            for (i, s) in raw.enumerated() {
                do {
                    sections.append(LoftSection(sketch: SketchID(raw: try uuid(s, "sketchID")),
                                                seed: try vector2(s, "seedPoint")))
                } catch let e as AgentExecError {
                    return .failure(.init(code: e.code, message: "sections[\(i)]: \(e.message)"))
                }
            }
            let (op, targets) = try booleanIntent(a)
            return .success(.loft(sections: sections, boolean: op, targets: targets))
        } catch let e as AgentExecError { return .failure(e) } catch { return .failure(unexpected) }
    }

    private static func parsePushPull(_ a: [String: Any]) -> Result<AgentExecOp, AgentExecError> {
        do {
            let body = BodyID(raw: try uuid(a, "bodyID"))
            let faces = try edgeIndices(a, "face", allowEmpty: false)
            guard faces.count == 1 else {
                return .failure(.init(code: "one_face_only",
                                      message: "push/pull acts on exactly one \"face\"."))
            }
            let distance = try double(a, "distance")
            guard abs(distance) > 1e-9 else {
                return .failure(.init(code: "zero_distance",
                                      message: "A zero-distance push/pull does nothing. "
                                      + "Give a non-zero \"distance\" in mm (negative pushes in)."))
            }
            let mode = a["mode"] as? String ?? "planarAxial"
            guard mode == "planarAxial" || mode == "cylinderRadial" else {
                return .failure(.init(code: "bad_mode",
                                      message: #""mode" must be "planarAxial" or "cylinderRadial"."#))
            }
            return .success(.pushPull(body: body, face: faces[0], distance: distance,
                                      radial: mode == "cylinderRadial"))
        } catch let e as AgentExecError { return .failure(e) } catch { return .failure(unexpected) }
    }

    /// Body + exactly one 1-based face index — the front half of every
    /// single-face op (push/pull, move/scale/rotate face).
    private static func oneFace(_ a: [String: Any]) throws -> (BodyID, Int) {
        let body = BodyID(raw: try uuid(a, "bodyID"))
        let faces = try edgeIndices(a, "face", allowEmpty: false)
        guard faces.count == 1 else {
            throw AgentExecError(code: "one_face_only", message: "this op acts on exactly one \"face\".")
        }
        return (body, faces[0])
    }

    private static func parseMoveFace(_ a: [String: Any]) -> Result<AgentExecOp, AgentExecError> {
        do {
            let (body, face) = try oneFace(a)
            guard a["delta"] != nil else {
                return .failure(.init(code: "missing_delta",
                                      message: "\"delta\" must be [du, dv, dn] in the face's own "
                                      + "basis (mm): du/dv shear, dn moves along the normal."))
            }
            let delta = try vector3(a, "delta", default: .zero)
            guard simd_length(delta) > 1e-9 else {
                return .failure(.init(code: "zero_delta", message: "a zero move does nothing."))
            }
            return .success(.moveFace(body: body, face: face, delta: delta))
        } catch let e as AgentExecError { return .failure(e) } catch { return .failure(unexpected) }
    }

    private static func parseScaleFace(_ a: [String: Any]) -> Result<AgentExecOp, AgentExecError> {
        do {
            let (body, face) = try oneFace(a)
            let factor = try double(a, "factor")
            guard factor > 1e-9 else {
                return .failure(.init(code: "bad_factor",
                                      message: "\"factor\" must be > 0 (1.0 is no change)."))
            }
            return .success(.scaleFace(body: body, face: face, factor: factor))
        } catch let e as AgentExecError { return .failure(e) } catch { return .failure(unexpected) }
    }

    private static func parseDraftFace(_ a: [String: Any]) -> Result<AgentExecOp, AgentExecError> {
        do {
            let (body, face) = try oneFace(a)
            let angle = try angleDegrees(a, "angleDegrees", default: .nan)
            guard angle.isFinite else {
                return .failure(.init(code: "missing_angleDegrees",
                                      message: "\"angleDegrees\" is required (the draft angle, ±89)."))
            }
            guard abs(angle) > 1e-9 else {
                return .failure(.init(code: "zero_angle", message: "a zero draft does nothing."))
            }
            guard abs(angle) < 89 else {
                return .failure(.init(code: "draft_too_steep",
                                      message: "\"angleDegrees\" must be under 89° — at 90° the face folds flat."))
            }
            // The neutral plane is a WORLD plane: where the draft pivots and
            // what nothing moves on. Defaults to the ground (y = 0, +Y up).
            let origin = try vector3(a, "neutralOrigin", default: .zero)
            let normal = try vector3(a, "neutralNormal", default: SIMD3(0, 1, 0))
            guard simd_length(normal) > 1e-9 else {
                return .failure(.init(code: "degenerate_normal",
                                      message: "\"neutralNormal\" must be non-zero."))
            }
            return .success(.draftFace(body: body, face: face, neutralOrigin: origin,
                                       neutralNormal: normal, angleDegrees: angle))
        } catch let e as AgentExecError { return .failure(e) } catch { return .failure(unexpected) }
    }

    private static func parseRotateFace(_ a: [String: Any]) -> Result<AgentExecOp, AgentExecError> {
        do {
            let (body, face) = try oneFace(a)
            let angle = try angleDegrees(a, "angleDegrees", default: .nan)
            guard angle.isFinite else {
                return .failure(.init(code: "missing_angleDegrees",
                                      message: "\"angleDegrees\" is required (±360)."))
            }
            guard abs(angle) > 1e-9 else {
                return .failure(.init(code: "zero_angle", message: "a zero rotation does nothing."))
            }
            // axis in the face's own (u, v, n) basis; defaults to the normal (n),
            // which twists the face in place.
            let axis = try vector3(a, "axis", default: SIMD3(0, 0, 1))
            guard simd_length(axis) > 1e-9 else {
                return .failure(.init(code: "degenerate_axis", message: "\"axis\" must be non-zero."))
            }
            return .success(.rotateFace(body: body, face: face,
                                        angleDegrees: angle, axis: axis))
        } catch let e as AgentExecError { return .failure(e) } catch { return .failure(unexpected) }
    }

    private static func parseDeleteFace(_ a: [String: Any]) -> Result<AgentExecOp, AgentExecError> {
        do {
            let body = BodyID(raw: try uuid(a, "bodyID"))
            let faces = try edgeIndices(a, "faces", allowEmpty: false)
            return .success(.deleteFace(body: body, faces: faces))
        } catch let e as AgentExecError { return .failure(e) } catch { return .failure(unexpected) }
    }

    private static func parseReplaceFace(_ a: [String: Any]) -> Result<AgentExecOp, AgentExecError> {
        do {
            let body = BodyID(raw: try uuid(a, "bodyID"))
            let faces = try edgeIndices(a, "face", allowEmpty: false)
            guard faces.count == 1 else {
                return .failure(.init(code: "bad_face",
                                      message: "args.face must be exactly ONE kernel face index."))
            }
            let origin = try vector3(a, "targetOrigin", default: .zero)
            guard a["targetOrigin"] != nil else {
                return .failure(.init(code: "missing_targetOrigin",
                                      message: "args.targetOrigin must be a world [x, y, z] on the target plane."))
            }
            let normal = try vector3(a, "targetNormal", default: .zero)
            guard simd_length(normal) > 1e-9 else {
                return .failure(.init(code: "missing_targetNormal",
                                      message: "args.targetNormal must be a non-zero world [x, y, z]."))
            }
            return .success(.replaceFace(body: body, face: faces[0],
                                         targetOrigin: origin,
                                         targetNormal: simd_normalize(normal),
                                         flip: a["flip"] as? Bool ?? false))
        } catch let e as AgentExecError { return .failure(e) } catch { return .failure(unexpected) }
    }

    /// 1-based kernel sub-shape indices (the numbering /v1/edges and
    /// /v1/faces report). Zero and negatives are refused HERE so a typo'd
    /// index is a 400 with a pointer, never a kernel-side mystery.
    private static func edgeIndices(_ a: [String: Any], _ key: String,
                                    allowEmpty: Bool) throws -> [Int] {
        let raw = a[key]
        if raw == nil, allowEmpty { return [] }
        guard let values = raw as? [Int] else {
            throw AgentExecError(code: "missing_\(key)",
                                 message: "args.\(key) must be an array of "
                                 + "1-based kernel indices (GET /v1/edges or /v1/faces).")
        }
        guard allowEmpty || !values.isEmpty else {
            throw AgentExecError(code: "missing_\(key)",
                                 message: "args.\(key) must name at least one index.")
        }
        guard values.allSatisfy({ $0 >= 1 }) else {
            throw AgentExecError(code: "bad_index",
                                 message: "args.\(key) indices are 1-based; "
                                 + "0 or negative is a typo.")
        }
        return values
    }

    // MARK: Sketch entities

    /// Every `SketchEntity` kind: the four the Shapr3D format uses (line, arc,
    /// circle, spline) plus rect/polygon/ellipse — the closed primitives that
    /// let a caller draw a box or a hex without spelling out its edges as a
    /// line loop. `unknown_entity_kind` still names the full set so an
    /// unsupported kind is visible instead of mysterious.
    private static func entity(_ a: [String: Any], index: Int) -> Result<SketchEntity, AgentExecError> {
        func fail(_ code: String, _ message: String) -> Result<SketchEntity, AgentExecError> {
            .failure(.init(code: code, message: "entities[\(index)]: \(message)"))
        }
        let kind = a["kind"] as? String ?? ""
        do {
            switch kind {
            case "line":
                let a0 = try vector2(a, "a"), b0 = try vector2(a, "b")
                guard simd_distance(a0, b0) > 1e-12 else {
                    return fail("degenerate_line", "start and end are the same point.")
                }
                return .success(.line(id: UUID(), a: a0, b: b0))

            case "circle":
                let r = try double(a, "radius")
                guard r > 1e-12 else { return fail("bad_radius", "radius must be > 0.") }
                return .success(.circle(id: UUID(), center: try vector2(a, "center"), radius: r))

            case "arc":
                let r = try double(a, "radius")
                guard r > 1e-12 else { return fail("bad_radius", "radius must be > 0.") }
                return .success(.arc(id: UUID(), center: try vector2(a, "center"), radius: r,
                                     startAngle: try double(a, "startAngle"),
                                     endAngle: try double(a, "endAngle")))

            case "spline":
                guard let pts = a["points"] as? [[Double]], pts.count >= 2 else {
                    return fail("bad_spline", "\"points\" needs at least 2 [x,y] pairs.")
                }
                var points: [SIMD2<Double>] = []
                for p in pts {
                    guard p.count == 2 else { return fail("bad_spline", "each point must be [x,y].") }
                    points.append(SIMD2(p[0], p[1]))
                }
                return .success(.spline(id: UUID(), points: points, closed: a["closed"] as? Bool ?? false))

            case "rect":
                // Two opposite corners; normalize so `min` is the lower-left,
                // which the model and ProfileDetector both expect.
                let c0 = try vector2(a, "min"), c1 = try vector2(a, "max")
                guard abs(c1.x - c0.x) > 1e-9, abs(c1.y - c0.y) > 1e-9 else {
                    return fail("degenerate_rect",
                                "\"min\" and \"max\" must differ in both x and y.")
                }
                return .success(.rect(
                    id: UUID(),
                    min: SIMD2(Swift.min(c0.x, c1.x), Swift.min(c0.y, c1.y)),
                    max: SIMD2(Swift.max(c0.x, c1.x), Swift.max(c0.y, c1.y))))

            case "polygon":
                let r = try double(a, "radius")
                guard r > 1e-12 else { return fail("bad_radius", "radius must be > 0.") }
                let sidesValue = try double(a, "sides")
                let sides = Int(sidesValue.rounded())
                // Same ceiling as the keypad's side-count edit. The reference
                // app accepts any count but its cost grows with the square of
                // it (3000 sides ≈ 2 min there); here the command returns in
                // ~40 ms at any count, but a million-sided polygon then pinned
                // the app for minutes — the bound is a guard, not parity.
                guard sides >= 3, sides <= 10_000, Double(sides) == sidesValue else {
                    return fail("bad_sides", "\"sides\" must be a whole number from 3 to 10000.")
                }
                // `radius` is the circumscribed-circle radius (vertices lie on
                // it); `rotation` (optional, radians, like arc angles) places
                // the first vertex. Across-flats = 2·radius·cos(π/sides).
                return .success(.polygon(
                    id: UUID(), center: try vector2(a, "center"), radius: r,
                    sides: sides, rotation: try optionalDouble(a, "rotation") ?? 0))

            case "ellipse":
                let rx = try double(a, "radiusX"), ry = try double(a, "radiusY")
                guard rx > 1e-12, ry > 1e-12 else {
                    return fail("bad_radius", "\"radiusX\" and \"radiusY\" must be > 0.")
                }
                // `rotation` (optional, radians) turns the axis-aligned radii.
                return .success(.ellipse(
                    id: UUID(), center: try vector2(a, "center"),
                    radiusX: rx, radiusY: ry,
                    rotation: try optionalDouble(a, "rotation") ?? 0))

            default:
                return fail("unknown_entity_kind",
                            "kind '\(kind)' is not supported. Use line, circle, arc, "
                            + "spline, rect, polygon or ellipse.")
            }
        } catch let e as AgentExecError {
            return fail(e.code, e.message)
        } catch {
            return fail("unexpected", "could not be decoded.")
        }
    }

    // MARK: Small decoders

    private static let unexpected = AgentExecError(
        code: "unexpected", message: "The request could not be decoded.")

    /// A mirror plane from a normal: any two axes spanning it will do, since
    /// `FeatureKind.mirror` only reads the plane's normal and origin.
    private static func plane(origin: SIMD3<Double>, normal: SIMD3<Double>) -> SketchPlane {
        let seed = abs(normal.y) > 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        let x = simd_normalize(simd_cross(seed, normal))
        return SketchPlane(origin: origin, xAxis: x, yAxis: simd_normalize(simd_cross(normal, x)))
    }

    private static func booleanIntent(_ a: [String: Any]) throws -> (BooleanIntent.Op, [BodyID]) {
        // Distinguish "boolean absent" (the intended newBody default) from
        // "boolean present but the wrong TYPE". A caller who writes
        // {"boolean":{"kind":"subtract",...}} or {"boolean":1} used to get a
        // silent newBody — a cut that quietly became a stray solid — because
        // `as? String` on a non-string yields nil and fell to the default.
        // Refuse it loudly instead; the op is a bare string, targets go in
        // "booleanTargets".
        let name: String
        if let present = a["boolean"] {
            guard let s = present as? String else {
                throw AgentExecError(
                    code: "bad_boolean_type",
                    message: "\"boolean\" must be a string — one of "
                           + "\(booleanOps.joined(separator: ", ")). Put the bodies "
                           + "it acts on in \"booleanTargets\", not inside \"boolean\".")
            }
            name = s
        } else {
            name = "newBody"
        }
        let op: BooleanIntent.Op
        switch name {
        case "newBody":   op = .newBody
        case "union":     op = .union
        case "subtract":  op = .subtract
        case "intersect": op = .intersect
        default:
            throw AgentExecError(code: "unknown_boolean_op",
                                 message: "\"boolean\" must be one of \(booleanOps.joined(separator: ", ")).")
        }
        var targets: [BodyID] = []
        for s in (a["booleanTargets"] as? [String] ?? []) {
            guard let u = UUID(uuidString: s) else {
                throw AgentExecError(code: "bad_uuid",
                                     message: "'\(s)' in booleanTargets is not a UUID.")
            }
            targets.append(BodyID(raw: u))
        }
        if op != .newBody && targets.isEmpty {
            throw AgentExecError(
                code: "missing_boolean_targets",
                message: "boolean '\(name)' needs \"booleanTargets\": which existing bodies it acts on. "
                       + "Body ids come from /v1/state.")
        }
        return (op, targets)
    }

    /// A preset by the name the Material sheet shows, or a raw `color`; either
    /// way `metallic`/`roughness` may override. Out-of-range values are refused
    /// rather than clamped — a 255-based color is a caller bug worth naming.
    private static func parseSetMaterial(_ a: [String: Any]) -> Result<AgentExecOp, AgentExecError> {
        do {
            guard let raw = a["bodyIDs"] as? [String], !raw.isEmpty else {
                return .failure(.init(code: "missing_bodyIDs",
                                      message: "args.bodyIDs must be a non-empty array of body ids from /v1/state."))
            }
            let bodies = try raw.map { s -> BodyID in
                guard let u = UUID(uuidString: s) else {
                    throw AgentExecError(code: "bad_uuid",
                                         message: "args.bodyIDs entry '\(s)' is not a UUID. Ids come from /v1/state.")
                }
                return BodyID(raw: u)
            }
            var spec: BodyMaterialSpec
            if let name = a["preset"] as? String {
                guard let preset = MaterialPreset.library.first(where: {
                    $0.name.caseInsensitiveCompare(name) == .orderedSame
                }) else {
                    return .failure(.init(code: "unknown_preset",
                                          message: "No material preset '\(name)'. Known: "
                                                 + MaterialPreset.library.map(\.name).joined(separator: ", ") + "."))
                }
                spec = preset.spec
            } else if let rgba = a["color"] as? [Double] {
                guard (3...4).contains(rgba.count), rgba.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                    return .failure(.init(code: "bad_color",
                                          message: "args.color must be [r, g, b] or [r, g, b, a], each 0…1."))
                }
                spec = BodyMaterialSpec(baseColor: SIMD4(rgba[0], rgba[1], rgba[2], rgba.count == 4 ? rgba[3] : 1))
            } else {
                return .failure(.init(code: "missing_material",
                                      message: "args needs a \"preset\" name or a \"color\" [r, g, b]."))
            }
            for key in ["metallic", "roughness"] {
                guard let v = try optionalDouble(a, key) else { continue }
                guard (0...1).contains(v) else {
                    return .failure(.init(code: "bad_\(key)", message: "args.\(key) must be 0…1."))
                }
                if key == "metallic" { spec.metallic = v } else { spec.roughness = v }
            }
            return .success(.setMaterial(bodies: bodies, material: spec))
        } catch let e as AgentExecError { return .failure(e) } catch { return .failure(unexpected) }
    }

    private static func parseSetHidden(_ a: [String: Any]) -> Result<AgentExecOp, AgentExecError> {
        let allSketches = a["allSketches"] as? Bool ?? false
        let raw = a["ids"] as? [String] ?? []
        guard allSketches || !raw.isEmpty else {
            return .failure(.init(code: "missing_ids",
                                  message: "args.ids must list body, sketch or plane ids, or pass \"allSketches\": true."))
        }
        var ids: [UUID] = []
        for s in raw {
            guard let u = UUID(uuidString: s) else {
                return .failure(.init(code: "bad_uuid",
                                      message: "args.ids entry '\(s)' is not a UUID. Ids come from /v1/state or a previous exec reply."))
            }
            ids.append(u)
        }
        return .success(.setHidden(ids: ids, allSketches: allSketches, hidden: a["hidden"] as? Bool ?? true))
    }

    private static func uuid(_ a: [String: Any], _ key: String) throws -> UUID {
        guard let s = a[key] as? String else {
            throw AgentExecError(code: "missing_\(key)", message: "args.\(key) is required.")
        }
        guard let u = UUID(uuidString: s) else {
            throw AgentExecError(code: "bad_uuid",
                                 message: "args.\(key) = '\(s)' is not a UUID. Ids come from /v1/state or a previous exec reply.")
        }
        return u
    }

    private static func double(_ a: [String: Any], _ key: String) throws -> Double {
        guard let n = a[key] as? NSNumber else {
            throw AgentExecError(code: "missing_\(key)", message: "args.\(key) must be a number (mm).")
        }
        let v = n.doubleValue
        guard v.isFinite else {
            throw AgentExecError(code: "non_finite", message: "args.\(key) must be finite.")
        }
        return v
    }

    private static func optionalDouble(_ a: [String: Any], _ key: String) throws -> Double? {
        a[key] == nil ? nil : try double(a, key)
    }

    /// Degrees, bounded to a full turn either way. A 3600° revolve is a typo,
    /// not a request, and the kernel would spend real time on it before failing.
    private static func angleDegrees(_ a: [String: Any], _ key: String, default fallback: Double) throws -> Double {
        guard let v = try optionalDouble(a, key) else { return fallback }
        guard abs(v) <= 360 else {
            throw AgentExecError(code: "angle_out_of_range",
                                 message: "args.\(key) = \(v) is outside ±360 degrees.")
        }
        return v
    }

    private static func vector2(_ a: [String: Any], _ key: String) throws -> SIMD2<Double> {
        guard let raw = a[key] as? [Double], raw.count == 2 else {
            throw AgentExecError(code: "missing_\(key)", message: "args.\(key) must be [x, y] in mm.")
        }
        guard raw.allSatisfy(\.isFinite) else {
            throw AgentExecError(code: "non_finite", message: "args.\(key) must be finite.")
        }
        return SIMD2(raw[0], raw[1])
    }

    private static func vector3(_ a: [String: Any], _ key: String, default fallback: SIMD3<Double>) throws -> SIMD3<Double> {
        guard let raw = a[key] else { return fallback }
        guard let v = raw as? [Double], v.count == 3 else {
            throw AgentExecError(code: "bad_\(key)", message: "args.\(key) must be [x, y, z].")
        }
        guard v.allSatisfy(\.isFinite) else {
            throw AgentExecError(code: "non_finite", message: "args.\(key) must be finite.")
        }
        return SIMD3(v[0], v[1], v[2])
    }
}

