//
//  CADCommandExecutor.swift
//  FloeCADKit
//
//  Headless CAD command executor over the vendored editor state machine.
//
//  Extracted from OpenShape3D's DEBUG agent bridge (`Agent/AgentExec.swift`,
//  `Agent/AgentBridge.swift`, `Agent/AgentRouter.swift`; MIT, Laan Labs and
//  contributors) with the transport/screenshot/capture/archive routes removed.
//  The operation vocabulary and its execution path are unchanged: every
//  mutation goes through `DocumentCommand` / `FeatureKind`, so an AI-applied
//  model is the same model the interactive tools build and replays through the
//  same feature graph. Floe's `cad.document` propose/apply gate calls this
//  executor; it never exposes it to the model directly.
//
//  See PATCHES.md for the exact extraction diff.
//

import Foundation
import simd


nonisolated struct AgentResponse: Sendable {
    var status: Int
    var reason: String
    var contentType: String = "application/json"
    var body: Data
    /// Facts about a binary body that the bytes cannot say for themselves
    /// (an export's overall size). Sent as `X-OS3D-<Key>` headers over REST and
    /// folded into the tool result over MCP.
    var info: [String: String] = [:]

    static func json(_ status: Int, _ reason: String, _ object: [String: Any]) -> AgentResponse {
        // `.sortedKeys` so responses are byte-stable — worth it for diffing a
        // log and for asserting on one in a test.
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data(#"{"ok":false,"error":"encoding_failed"}"#.utf8)
        return AgentResponse(status: status, reason: reason, body: data)
    }

    static func ok(_ object: [String: Any]) -> AgentResponse {
        var payload = object
        payload["ok"] = true
        return .json(200, "OK", payload)
    }

    /// `error` is a stable machine code; `message` is for a human reading a log.
    static func failure(_ status: Int, _ reason: String, error: String, message: String) -> AgentResponse {
        .json(status, reason, ["ok": false, "error": error, "message": message])
    }

    static func png(_ data: Data) -> AgentResponse {
        AgentResponse(status: 200, reason: "OK", contentType: "image/png", body: data)
    }

    static func image(_ data: Data, contentType: String) -> AgentResponse {
        AgentResponse(status: 200, reason: "OK", contentType: contentType, body: data)
    }
}

/// How `/v1/screenshot` encodes. PNG is lossless and what `curl` users expect;
/// JPEG under a byte budget is what an MCP tool result needs — Claude Desktop

/// The fabrication formats `/v1/export` writes — the Export menu's mesh
/// formats plus STEP. Millimetres, like everything else on the wire.
nonisolated enum AgentExportFormat: String, Sendable, CaseIterable {
    case stl, obj, threeMF = "3mf", step

    var contentType: String {
        switch self {
        case .stl: return "model/stl"
        case .obj: return "model/obj"
        case .threeMF: return "model/3mf"
        case .step: return "model/step"
        }
    }
}

@MainActor
final class CADCommandExecutor {
    let viewModel: EditorViewModel
    let documentName: String?

    init(viewModel: EditorViewModel, documentName: String? = nil) {
        self.viewModel = viewModel
        self.documentName = documentName
    }

    /// Run one parsed operation through the same path the interactive tools use.
    func run(_ op: AgentExecOp) -> AgentResponse {
        execute(op, on: viewModel)
    }

    /// Document state snapshot (bodies, sketches, features, units, selection,
    /// measurements) without any HTTP wrapper.
    func snapshot() -> [String: Any] {
        snapshot(of: viewModel)
    }

    /// Host platform label (upstream `AgentRouter.platformName`).
    static var platformName: String {
        #if targetEnvironment(macCatalyst)
        return "maccatalyst"
        #elseif targetEnvironment(simulator)
        return "simulator"
        #else
        return "device"
        #endif
    }

    /// Case name only, derived rather than switched (upstream helper).
    static func modeName(_ mode: EditorMode) -> String {
        let described = String(describing: mode)
        return described.split(separator: "(").first.map(String.init) ?? described
    }

    private func execute(_ op: AgentExecOp, on viewModel: EditorViewModel) -> AgentResponse {
        let session = viewModel.session

        switch op {

        case let .importFile(path, fileName, unitScale):
            let url = URL(fileURLWithPath: path)
            guard let data = try? Data(contentsOf: url) else {
                return .failure(404, "Not Found", error: "unreadable_path",
                                message: "Could not read \(path).")
            }
            let before = Set(session.document.bodies.map(\.id))
            viewModel.errorMessage = nil
            // A loose .obj/.gltf/.blend needs the files beside it; the host
            // directory is readable here, so hand them over.
            let loose = ["obj", "gltf", "blend"].contains(url.pathExtension.lowercased())
            viewModel.importMesh(data: data, fileName: fileName ?? url.lastPathComponent,
                                 siblings: loose ? MeshImportKit.folderSiblings(of: url) : [:],
                                 unitScale: unitScale)
            if let message = viewModel.errorMessage {
                return .failure(422, "Unprocessable Entity", error: "import_failed", message: message)
            }
            let added = session.document.bodies.filter { !before.contains($0.id) }
            return execOK(viewModel, [
                "bodyIDs": added.map { $0.id.raw.uuidString },
                "names": added.map(\.name),
                "textured": added.filter { $0.material?.baseColorTexture != nil }.count,
                "triangles": added.reduce(0) { $0 + $1.render.indices.count / 3 },
                "undoSteps": 1])

        case let .createSketch(name, plane):
            let sketch = Sketch(name: name, plane: plane)
            session.perform(AddSketchCommand(sketch: sketch, title: "Add \(name)"))
            return execOK(viewModel, ["sketchID": sketch.id.raw.uuidString,
                                      "name": name, "undoSteps": 1])

        case let .addEntities(sketchID, entities, constructionIndices):
            guard session.document.sketches.contains(where: { $0.id == sketchID }) else {
                return execMissing("sketch", sketchID.raw.uuidString)
            }
            // `AddSketchEntitiesCommand` flags the WHOLE batch construction or
            // not, so a mixed batch has to be two commands. Split rather than
            // refuse: a revolve axis is a construction line living in the same
            // sketch as the profile it spins, which is the common case, not an
            // exotic one.
            let normal = entities.enumerated().filter { !constructionIndices.contains($0.offset) }.map(\.element)
            let construction = entities.enumerated().filter { constructionIndices.contains($0.offset) }.map(\.element)
            var steps = 0
            if !normal.isEmpty {
                session.perform(AddSketchEntitiesCommand(sketchID: sketchID, entities: normal))
                steps += 1
            }
            if !construction.isEmpty {
                session.perform(AddSketchEntitiesCommand(
                    sketchID: sketchID, entities: construction, asConstruction: true))
                steps += 1
            }
            session.rebuildForSketchChange(sketchID)
            return execOK(viewModel, [
                "sketchID": sketchID.raw.uuidString,
                "entityIDs": entities.map { $0.id.uuidString },
                "constructionCount": construction.count,
                "undoSteps": steps,
            ])

        case let .extrude(sketchID, seed, requested, symmetric, taperDegrees, booleanOp, targets, end):
            guard let sketch = session.document.sketches.first(where: { $0.id == sketchID }) else {
                return execMissing("sketch", sketchID.raw.uuidString)
            }
            if let bad = missingBody(targets, session) { return bad }
            let intent = BooleanIntent(op: booleanOp, resolvedTargets: targets.map { bodyRef($0, session) })
            // An end condition resolves to the distance it stands for, from
            // the boolean's targets (or every body when there are none),
            // along the plane normal in the requested sign's direction.
            var distance = requested
            if let end {
                let candidates = targets.isEmpty
                    ? session.document.bodies
                    : session.document.bodies.filter { targets.contains($0.id) }
                let direction = requested >= 0 ? sketch.plane.normal : -sketch.plane.normal
                guard let resolved = ExtrudeEndKit.resolve(end, plane: sketch.plane, seed: seed,
                                                           direction: direction, symmetric: symmetric,
                                                           bodies: candidates) else {
                    return .failure(422, "Unprocessable Entity", error: "no_end_found",
                                    message: "\"end\": \(end.rawValue) found no face ahead of the profile "
                                           + "along the plane normal — give a \"distance\" instead.")
                }
                distance = requested >= 0 ? resolved : -resolved
            }
            let profile = execProfileRef(sketchID: sketchID, seed: seed, in: session)
            let plane = PlaneRef(source: .sketch(sketchID))
            // A non-zero taper is a genuinely different construction (a loft),
            // so it records as .draftExtrude; zero stays the straight prism.
            if abs(taperDegrees) > 1e-9 {
                return record(FeatureNode(
                    name: "Draft Extrude",
                    kind: .draftExtrude(profile: profile, plane: plane,
                                        distance: Expr(value: distance),
                                        taperAngle: Expr(value: taperDegrees),
                                        symmetric: symmetric, boolean: intent),
                    outputBodyIDs: [BodyID()]), on: viewModel)
            }
            return record(FeatureNode(
                name: "Extrude",
                kind: .extrude(
                    profile: profile, plane: plane,
                    distance: Expr(value: distance),
                    symmetric: symmetric,
                    boolean: intent,
                    extraProfiles: []),
                outputBodyIDs: [BodyID()]), on: viewModel)

        case let .revolve(sketchID, seed, axis, angleDegrees, booleanOp, targets):
            guard session.document.sketches.contains(where: { $0.id == sketchID }) else {
                return execMissing("sketch", sketchID.raw.uuidString)
            }
            if let bad = missingBody(targets, session) { return bad }
            let intent = BooleanIntent(op: booleanOp, resolvedTargets: targets.map { bodyRef($0, session) })
            return record(FeatureNode(
                name: "Revolve",
                kind: .revolve(
                    profile: execProfileRef(sketchID: sketchID, seed: seed,
                                            in: session),
                    plane: PlaneRef(source: .sketch(sketchID)),
                    axis: AxisRef(source: .explicit(axis)),
                    angle: Expr(value: angleDegrees),
                    boolean: intent),
                outputBodyIDs: [BodyID()]), on: viewModel)

        case let .pattern(bodyID, spec):
            if let bad = missingBody([bodyID], session) { return bad }
            // count includes the original, so a pattern emits count-1 NEW bodies.
            let outputs = (0..<max(0, spec.count - 1)).map { _ in BodyID() }
            return record(FeatureNode(
                name: spec.kind == .circular ? "Circular Pattern" : "Linear Pattern",
                kind: .pattern(body: bodyRef(bodyID, session), spec: spec),
                outputBodyIDs: outputs), on: viewModel)

        case let .mirror(bodyID, plane, keepOriginal):
            if let bad = missingBody([bodyID], session) { return bad }
            return record(FeatureNode(
                name: "Mirror",
                kind: .mirror(body: bodyRef(bodyID, session),
                              plane: PlaneRef(source: .explicit(plane)),
                              keepOriginal: keepOriginal),
                outputBodyIDs: [BodyID()]), on: viewModel)

        case let .transform(bodyID, delta):
            if let bad = missingBody([bodyID], session) { return bad }
            // In place, like a boolean: the body keeps its id; the fresh output
            // id is the graph's convention for "replaces, adds nothing".
            return record(FeatureNode(
                name: "Move",
                kind: .transform(body: bodyRef(bodyID, session), delta: delta),
                outputBodyIDs: [BodyID()]), on: viewModel)

        case let .boolean(kindName, target, tools):
            if let bad = missingBody([target] + tools, session) { return bad }
            guard let kind = BooleanKind(rawValue: kindName) else {
                return .failure(400, "Bad Request", error: "unknown_boolean_kind",
                                message: "'\(kindName)' is not a boolean kind.")
            }
            return record(FeatureNode(
                name: kindName.capitalized,
                kind: .boolean(kind: kind,
                               target: bodyRef(target, session),
                               tools: tools.map { bodyRef($0, session) }),
                outputBodyIDs: [BodyID()]), on: viewModel)

        case let .sweep(sketchID, seed, spine, booleanOp, targets, helix):
            guard session.document.sketches.contains(where: { $0.id == sketchID }) else {
                return execMissing("sketch", sketchID.raw.uuidString)
            }
            if let bad = missingBody(targets, session) { return bad }
            let intent = BooleanIntent(op: booleanOp, resolvedTargets: targets.map { bodyRef($0, session) })
            return record(FeatureNode(
                name: helix == nil ? "Sweep" : "Helix Sweep",
                kind: .sweep(
                    profile: execProfileRef(sketchID: sketchID, seed: seed,
                                            in: session),
                    plane: PlaneRef(source: .sketch(sketchID)),
                    spine: spine.map(PointWrapper.init),
                    boolean: intent,
                    helix: helix),
                outputBodyIDs: [BodyID()]), on: viewModel)

        case let .loft(sections, booleanOp, targets):
            for section in sections where !session.document.sketches.contains(where: { $0.id == section.sketch }) {
                return execMissing("sketch", section.sketch.raw.uuidString)
            }
            if let bad = missingBody(targets, session) { return bad }
            let intent = BooleanIntent(op: booleanOp, resolvedTargets: targets.map { bodyRef($0, session) })
            return record(FeatureNode(
                name: "Loft",
                kind: .loft(
                    sections: sections.map {
                        execProfileRef(sketchID: $0.sketch, seed: $0.seed, in: session)
                    },
                    boolean: intent),
                outputBodyIDs: [BodyID()]), on: viewModel)

        case let .blend(bodyID, isFillet, amount, edges):
            return execBlend(body: bodyID, isFillet: isFillet, amount: amount,
                             edgeIndices: edges, on: viewModel)

        case let .shell(bodyID, thickness, openFaces):
            return execShell(body: bodyID, thickness: thickness,
                             openFaces: openFaces, on: viewModel)

        case let .pushPull(bodyID, face, distance, radial):
            return execSingleFace(body: bodyID, face: face, name: "Push/Pull",
                                  on: viewModel) { ref in
                .pushPull(face: ref, distance: Expr(value: distance),
                          mode: radial ? .cylinderRadial : .planarAxial)
            }

        case let .moveFace(bodyID, face, delta):
            return execSingleFace(body: bodyID, face: face, name: "Move Face",
                                  on: viewModel) { .moveFace(face: $0, delta: PointWrapper(delta)) }

        case let .scaleFace(bodyID, face, factor):
            return execSingleFace(body: bodyID, face: face, name: "Scale Face",
                                  on: viewModel) { .scaleFace(face: $0, factor: Expr(value: factor)) }

        case let .rotateFace(bodyID, face, angleDegrees, axis):
            return execSingleFace(body: bodyID, face: face, name: "Rotate Face",
                                  on: viewModel) { ref in
                // FeatureKind.rotateFace's Expr is RADIANS; the wire is degrees.
                .rotateFace(face: ref, angle: Expr(value: angleDegrees * .pi / 180),
                            axis: PointWrapper(axis))
            }

        case let .deleteFace(bodyID, faces):
            return execDeleteFace(body: bodyID, faces: faces, on: viewModel)

        case let .draftFace(bodyID, face, neutralOrigin, neutralNormal, angleDegrees):
            return execDraftFace(body: bodyID, face: face, neutralOrigin: neutralOrigin,
                                 neutralNormal: neutralNormal, degrees: angleDegrees,
                                 on: viewModel)
        case let .replaceFace(bodyID, face, origin, normal, flip):
            return execReplaceFace(body: bodyID, face: face,
                                   targetOrigin: origin, targetNormal: normal,
                                   flip: flip, on: viewModel)

        case let .setMaterial(bodies, material):
            if let bad = missingBody(bodies, session) { return bad }
            session.perform(SetMaterialCommand(bodyIDs: Set(bodies), material: material.clamped,
                                               document: session.document))
            return execOK(viewModel, ["bodyIDs": bodies.map { $0.raw.uuidString }, "undoSteps": 1])

        case let .setHidden(ids, allSketches, hidden):
            let document = session.document
            var items: [DocumentItemRef] = allSketches ? document.sketches.map { .sketch($0.id) } : []
            for raw in ids {
                if document.bodies.contains(where: { $0.id.raw == raw }) {
                    items.append(.body(BodyID(raw: raw)))
                } else if document.sketches.contains(where: { $0.id.raw == raw }) {
                    items.append(.sketch(SketchID(raw: raw)))
                } else if document.planes.contains(where: { $0.id.raw == raw }) {
                    items.append(.plane(ConstructionPlaneID(raw: raw)))
                } else {
                    return execMissing("item", raw.uuidString)
                }
            }
            for item in items { session.perform(SetItemVisibilityCommand(item: item, isHidden: hidden)) }
            return execOK(viewModel, ["count": items.count, "undoSteps": items.count])
        }
    }

    /// Append a node and evaluate it. Reports the eval errors rather than a bare
    /// success: a feature that lands in History but produces no body is exactly
    /// the "silent no-op" failure this bridge exists to make visible.
    private func record(_ node: FeatureNode, on viewModel: EditorViewModel) -> AgentResponse {
        let session = viewModel.session
        // Revisions, not just ids. A boolean REPLACES its target in place, so it
        // adds no new body — reporting "produced nothing" on a subtract that had
        // just removed 4.5 million mm3 was the first thing this endpoint got
        // wrong in real use. What matters is whether the document moved at all.
        var before: [BodyID: UInt64] = [:]
        for body in session.document.bodies { before[body.id] = body.meshRevision }
        // Append and rebuild as ONE undo step, the way the interactive tools
        // commit. This used to be `record` + `rebuildFrom`: two steps when the
        // feature built, but ONE when it failed (a rebuild that changes no
        // body commits nothing), while the reply always said `undoSteps: 2`,
        // so a caller undoing twice after a failure also reverted the feature
        // before it (practice problems round 6, bug 4, 2026-09-16). And one
        // undo of a feature that built reverted only its rebuild, leaving the
        // node in History over the old bodies.
        session.recordAndRebuild([node], title: node.name)

        var produced: [BodyID] = []
        var changed: [BodyID] = []
        var surviving = Set<BodyID>()
        for body in session.document.bodies {
            surviving.insert(body.id)
            guard let was = before[body.id] else { produced.append(body.id); continue }
            if was != body.meshRevision { changed.append(body.id) }
        }
        let removed = before.keys.filter { !surviving.contains($0) }

        var payload: [String: Any] = [
            "featureID": node.id.raw.uuidString,
            "feature": node.name,
            "producedBodyIDs": produced.map(\.raw.uuidString),
            "changedBodyIDs": changed.map(\.raw.uuidString),
            "removedBodyIDs": removed.map(\.raw.uuidString),
            "undoSteps": 1,
        ]
        // Keyed by feature id, so an agent can tell ITS node failing from an
        // unrelated upstream node that was already broken.
        let errors = session.lastEvalErrors
        if !errors.isEmpty {
            payload["evalErrors"] = Dictionary(uniqueKeysWithValues:
                errors.map { ($0.key.raw.uuidString, String(describing: $0.value)) })
        }

        // THIS node failing is the signal that matters, and it has to be
        // unmissable. `changed` alone cannot carry it: `rebuildFrom` re-emits
        // bodies and bumps `meshRevision` on nodes it did not semantically
        // touch, so a failed feature can still look like it moved something.
        if let mine = errors[node.id] {
            payload["failed"] = true
            payload["message"] = "\(node.name) was recorded but did not build: \(mine). "
                + "For a profile feature the usual cause is a seed point outside any closed region."
        } else if produced.isEmpty && changed.isEmpty && removed.isEmpty {
            payload["warning"] = "The feature was recorded but changed nothing — no body was "
                + "added, modified or removed. For a boolean, check the tools actually "
                + "intersect the target."
        }
        return execOK(viewModel, payload)
    }

    /// The ProfileRef an exec'd profile feature records — minted the way the
    /// interactive commit mints one: the innermost region at the seed, with
    /// its HOLES detected and recorded explicitly. `resolveProfile` only
    /// punches holes named in `holeEntityIDs` (a persisted empty list must
    /// keep meaning "no holes" for old documents), so leaving them off here
    /// silently extruded a ring as its full outer disc — found live by the
    /// Motorcycle cover's boss band overshooting its volume by exactly the
    /// hole's area.
    private func execProfileRef(sketchID: SketchID, seed: SIMD2<Double>,
                                in session: DocumentSession) -> ProfileRef {
        guard let sketch = session.document.sketches.first(where: { $0.id == sketchID }),
              let outer = ProfileDetector.profiles(at: seed, in: sketch).first else {
            // No region at the seed: record the seed-only ref, and replay
            // reports the honest "seed point outside any closed region".
            return ProfileRef(sketchID: sketchID, entityIDs: [],
                              holeEntityIDs: [], seedPoint: seed)
        }
        let holes = ProfileDetector.holes(
            of: outer, among: ProfileDetector.detectProfiles(in: sketch))
        return ProfileRef(
            sketchID: sketchID,
            entityIDs: Array(outer.sourceEntityIDs),
            holeEntityIDs: holes.map { Array($0.sourceEntityIDs) },
            seedPoint: seed)
    }

    private func bodyRef(_ id: BodyID, _ session: DocumentSession) -> BodyRef {
        let producer = session.document.features.nodes.last { $0.outputBodyIDs.contains(id) }
        return BodyRef(producer: producer?.id ?? FeatureID(), bodyID: id)
    }

    private func missingBody(_ ids: [BodyID], _ session: DocumentSession) -> AgentResponse? {
        let known = Set(session.document.bodies.map(\.id))
        guard let missing = ids.first(where: { !known.contains($0) }) else { return nil }
        return execMissing("body", missing.raw.uuidString)
    }

    private func execMissing(_ what: String, _ id: String) -> AgentResponse {
        .failure(404, "Not Found", error: "unknown_\(what)",
                 message: "No \(what) with id \(id) in this document. GET /v1/state for what exists.")
    }

    /// Every exec reply carries the post-op state, so an agent never needs a
    /// second round trip to see what its own call did.
    /// Set while a PERSON has the channel on (Settings ▸ AI Assistant): they
    /// are watching an assistant build, so whenever an operation adds or
    /// changes a body the view re-frames the model. A new design's camera
    /// spans about 14 mm — without this, the first real Claude Desktop run
    /// showed its owner the INSIDE of a 110 mm pot until the assistant
    /// happened to fit the view a minute later. A developer's `OS3D_AGENT`
    /// session keeps the camera where its script put it.
    var framesAssistantWork = false

    private func execOK(_ viewModel: EditorViewModel, _ extra: [String: Any]) -> AgentResponse {
        if framesAssistantWork {
            let touched = ["producedBodyIDs", "changedBodyIDs"].contains { !((extra[$0] as? [Any]) ?? []).isEmpty }
            if touched { _ = viewModel.runCommand("view.fit") }
        }
        var payload = snapshot(of: viewModel)
        for (k, v) in extra { payload[k] = v }
        return .ok(payload)
    }

    // MARK: - Kernel sub-shape discovery + identity-addressed exec ops
    // (/v1/edges, /v1/faces, feature.fillet/chamfer/shell — step 4b/5 wiring)

    /// The analytic body with FRESH identity maps, or the reply explaining
    /// why not. Blends/shell over the wire address kernel indices, and an
    /// index against a stale build would blend the wrong thing — the same
    /// revision guard the interactive mint sites use.
    private enum IdentityContext {
        case ok(body: Body, brep: BRepHandle)
        case reply(AgentResponse)
    }

    private func identityContext(_ bodyID: BodyID,
                                 _ session: DocumentSession) -> IdentityContext {
        guard let body = session.document.bodies.first(where: { $0.id == bodyID }) else {
            return .reply(execMissing("body", bodyID.raw.uuidString))
        }
        guard let brep = body.brep else {
            return .reply(.failure(409, "Conflict", error: "mesh_only_body",
                message: "'\(body.name)' carries no analytic kernel shape, so it has "
                       + "no addressable edges or faces. Only brep bodies blend/shell over exec."))
        }
        // NO revision guard here: sub-shape GEOMETRY (adjacency, face info)
        // is read from the CURRENT brep and cannot be stale. Only the
        // retained NAME maps can be, and `freshNames` handles that — a
        // stale map yields refs without names, never wrong geometry. (The
        // old blanket stale_identity 409 made every undo a dead end.)
        return .ok(body: body, brep: brep)
    }

    /// The body's kernel-face names ONLY when they describe its current
    /// revision — the same staleness rule the interactive mint sites use. A
    /// stale map yields [:], and refs simply go name-less.
    private func freshNames(for body: Body,
                            _ session: DocumentSession) -> [Int: ElementName] {
        guard session.lastNamingRevisions[body.id] == body.meshRevision else {
            return [:]
        }
        return session.lastKernelNames[body.id] ?? [:]
    }

    /// JSON-safe rendering of an Encodable identity value.
    private func jsonObject<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// `GET /v1/section?body=&normal=&origin=&xAxis=&deflection=`: the plane
    /// cut through the body's PLACED solid (its transform applied, so pattern
    /// instances and moved bodies cut where they sit), chained into loops in
    /// the plane frame. Mesh-only bodies are refused like /v1/edges.
    private func section(bodyID: String, origin: SIMD3<Double>, normal: SIMD3<Double>,
                         xAxisHint: SIMD3<Double>?, deflection: Double,
                         on viewModel: EditorViewModel) -> AgentResponse {
        guard let uuid = UUID(uuidString: bodyID) else {
            return execMissing("body", bodyID)
        }
        let context: (body: Body, brep: BRepHandle)
        switch identityContext(BodyID(raw: uuid), viewModel.session) {
        case let .ok(body, brep): context = (body, brep)
        case let .reply(reply): return reply
        }
        let placed = OCCTKernel.transformed(context.brep, by: context.body.transform) ?? context.brep
        let n = simd_normalize(normal)
        let pieces = OCCTKernel.sectionPolylines(placed, origin: origin, normal: n, deflection: deflection)
        let frame = SectionKit.frame(normal: n, xAxisHint: xAxisHint)
        let loops = SectionKit.loops(from: pieces, origin: origin, xAxis: frame.xAxis, yAxis: frame.yAxis)
        return .ok([
            "body": context.body.id.raw.uuidString,
            "plane": [
                "origin": [origin.x, origin.y, origin.z],
                "normal": [n.x, n.y, n.z],
                "xAxis": [frame.xAxis.x, frame.xAxis.y, frame.xAxis.z],
                "yAxis": [frame.yAxis.x, frame.yAxis.y, frame.yAxis.z],
            ],
            "count": loops.count,
            "loops": loops.map { loop -> [String: Any] in
                ["closed": loop.closed, "area": loop.area,
                 "points": loop.points.map { [$0.x, $0.y] }]
            },
        ])
    }

    private func listEdges(bodyID: String, on viewModel: EditorViewModel) -> AgentResponse {
        guard let uuid = UUID(uuidString: bodyID) else {
            return execMissing("body", bodyID)
        }
        let session = viewModel.session
        let context: (body: Body, brep: BRepHandle)
        switch identityContext(BodyID(raw: uuid), session) {
        case let .ok(body, brep): context = (body, brep)
        case let .reply(reply): return reply
        }
        let adjacency = OCCTKernel.edgeFaceAdjacency(context.brep)
        let names = freshNames(for: context.body, session)
        let edgeNames = ElementNaming.edgeNames(adjacency: adjacency, names: names)

        // Geometry per kernel edge: which edges get any is decided mesh-side
        // (a crease), the midpoint is the kernel curve's, and nothing
        // depends on the order the mesh edges arrive in
        // (`OCCTKernel.edgeGeometry`).
        let geometry = OCCTKernel.edgeGeometry(
            context.brep,
            meshEdges: EdgeTopology.selectableEdges(from: context.body.render),
            tolerance: OCCTKernel.matchTolerance(for: context.brep))

        let rows = adjacency.sorted { $0.edge < $1.edge }.map { triple -> [String: Any] in
            var row: [String: Any] = [
                "index": triple.edge,
                "faces": [triple.faceA, triple.faceB],
            ]
            if let edge = geometry[triple.edge] {
                // WORLD space, like /v1/state's bounds: the render mesh and
                // the brep are both in the body's local frame, and a body
                // that has been moved (Transform › Move/Rotate, or a
                // feature.transform) carries that move in `transform`. A
                // caller picking "the vertical edges between y=40 and 270"
                // must see the same numbers the bounds report.
                let world = context.body.transform.applying(to: edge.midpoint)
                row["midpoint"] = [world.x, world.y, world.z]
                row["lengthMM"] = edge.length
                row["convex"] = edge.isConvex
            }
            if let name = edgeNames[triple.edge], let encoded = jsonObject(name) {
                row["name"] = encoded
            }
            return row
        }
        return .ok([
            "body": context.body.id.raw.uuidString,
            "count": rows.count,
            "edges": rows,
            "message": "Indices feed feature.fillet/chamfer's args.edges. "
                     + "Edges without a name still blend; ones missing "
                     + "entirely are seams/borders, which never blend.",
        ])
    }


    /// GET /v1/export — the Export menu's bytes. Read-only, so it needs no
    /// `DocumentCommand`; it calls the same exporters `EditorViewModel` does,
    /// but reports failures as typed replies instead of a user-facing alert
    /// an agent cannot see. `bodyIDs` empty = the whole design (hidden bodies
    /// included, as in the menu). `zUp` turns the app's Y-up world a quarter
    /// turn about X, (x, y, z) → (x, −z, y), so a part modelled standing on
    /// the ground plane also stands on a slicer's bed.
    private func export(_ format: AgentExportFormat, bodyIDs: [String], zUp: Bool,
                        from viewModel: EditorViewModel) -> AgentResponse {
        var bodies = viewModel.session.document.bodies
        if !bodyIDs.isEmpty {
            var picked: [Body] = []
            for raw in bodyIDs {
                guard let id = UUID(uuidString: raw) else {
                    return .failure(400, "Bad Request", error: "bad_uuid",
                                    message: "'\(raw)' is not a body id — ids come from /v1/state.")
                }
                guard let body = bodies.first(where: { $0.id.raw == id }) else {
                    return .failure(404, "Not Found", error: "unknown_body",
                                    message: "No body \(raw) in this design — ids come from /v1/state.")
                }
                picked.append(body)
            }
            bodies = picked
        }
        guard !bodies.isEmpty else {
            return .failure(409, "Conflict", error: "nothing_to_export",
                            message: "The design has no solid bodies to export.")
        }
        if zUp {
            var upright = Transform3D()
            upright.rotation = simd_quatd(angle: .pi / 2, axis: SIMD3(1, 0, 0))
            bodies = bodies.map { body in
                var turned = body
                turned.transform = upright.composed(onto: body.transform)
                return turned
            }
        }
        let data: Data
        switch format {
        case .stl: data = STLExporter.binarySTL(bodies: bodies)
        case .obj: data = Data(OBJExporter.obj(bodies: bodies).utf8)
        case .threeMF: data = ThreeMFExporter.threeMF(bodies: bodies)
        case .step:
            switch STEPKit.export(bodies: bodies) {
            case let .success(step, _): data = step
            case .nothingAnalytic:
                return .failure(409, "Conflict", error: "mesh_only_body",
                                message: "None of these bodies has an analytic B-rep, so there is nothing "
                                       + "to write to STEP. Export stl, obj or 3mf instead.")
            case .failed:
                return .failure(500, "Internal Server Error", error: "export_failed",
                                message: "The STEP writer failed on this design.")
            }
        }
        var response = AgentResponse(status: 200, reason: "OK", contentType: format.contentType, body: data)
        // The file's overall size, in the orientation it was written: what an
        // assistant needs to confirm "the 15 cm pot" really is 150 mm tall
        // (the first real follow-up request could not, and said so).
        if let box = MeasureKit.boundingBox(bodies: bodies) {
            let size = box.max - box.min
            response.info["Size-MM"] = [size.x, size.y, size.z].map { String(format: "%.2f", $0) }.joined(separator: " x ")
        }
        response.info["Bodies"] = String(bodies.count)
        return response
    }

    /// GET /v1/sketches — every sketch with its plane and entities, in
    /// sketch (u, v) millimetres. Added while building the SOLIDWORKS
    /// practice sheets by touch (2026-09-04): a polyline that would not close
    /// could only be diagnosed from pixels until the entities themselves were
    /// readable.
    private func listSketches(on viewModel: EditorViewModel) -> AgentResponse {
        func v2(_ p: SIMD2<Double>) -> [Double] { [p.x, p.y] }
        func v3(_ p: SIMD3<Double>) -> [Double] { [p.x, p.y, p.z] }
        let sketches: [[String: Any]] = viewModel.session.document.sketches.map { sketch in
            let entities: [[String: Any]] = sketch.entities.map { entity in
                var row: [String: Any] = ["id": entity.id.uuidString,
                                          "construction": sketch.constructionEntityIDs.contains(entity.id)]
                switch entity {
                case let .line(_, a, b):
                    row["kind"] = "line"; row["a"] = v2(a); row["b"] = v2(b)
                    row["lengthMM"] = simd_length(b - a)
                case let .rect(_, lo, hi):
                    row["kind"] = "rect"; row["min"] = v2(lo); row["max"] = v2(hi)
                case let .circle(_, c, r):
                    row["kind"] = "circle"; row["center"] = v2(c); row["radius"] = r
                case let .arc(_, c, r, a0, a1):
                    row["kind"] = "arc"; row["center"] = v2(c); row["radius"] = r
                    row["startAngle"] = a0; row["endAngle"] = a1
                case let .ellipse(_, c, rx, ry, rot):
                    row["kind"] = "ellipse"; row["center"] = v2(c)
                    row["radiusX"] = rx; row["radiusY"] = ry; row["rotation"] = rot
                case let .polygon(_, c, r, sides, rot):
                    row["kind"] = "polygon"; row["center"] = v2(c); row["radius"] = r
                    row["sides"] = sides; row["rotation"] = rot
                case let .spline(_, points, closed):
                    row["kind"] = "spline"; row["points"] = points.map(v2); row["closed"] = closed
                }
                return row
            }
            let constraints: [[String: Any]] = sketch.constraints.map { c in
                ["kind": "\(c.kind)", "refs": c.refs.map { "\($0)" }]
            }
            return ["id": sketch.id.raw.uuidString, "name": sketch.name,
                    "hidden": sketch.isHidden,
                    "plane": ["origin": v3(sketch.plane.origin), "xAxis": v3(sketch.plane.xAxis),
                              "yAxis": v3(sketch.plane.yAxis)],
                    "entityCount": entities.count, "entities": entities,
                    "constraints": constraints,
                    "dimensionCount": sketch.dimensions.count]
        }
        return .ok(["sketches": sketches, "count": sketches.count])
    }

    private func listFaces(bodyID: String, on viewModel: EditorViewModel) -> AgentResponse {
        guard let uuid = UUID(uuidString: bodyID) else {
            return execMissing("body", bodyID)
        }
        let session = viewModel.session
        let context: (body: Body, brep: BRepHandle)
        switch identityContext(BodyID(raw: uuid), session) {
        case let .ok(body, brep): context = (body, brep)
        case let .reply(reply): return reply
        }
        // KERNEL-SIDE, not the mesh table: the table's triangle sets index
        // the body's RENDER, and for assigned-render bodies (revolve/sweep/
        // loft) that is a DIFFERENT tessellation than the channel's — the
        // vote then produced duplicate/wrong indices for a revolved washer
        // (measured 2026-09-01, two faces both claiming index 1). Face
        // geometry from the brep itself cannot misalign and cannot go stale.
        let names = freshNames(for: context.body, session)
        // Centroids and normals in WORLD space (see listEdges): the brep is
        // local, the body's `transform` carries any move/rotate it has had.
        let placement = context.body.transform
        let rows = OCCTKernel.faceInfo(context.brep).map { info -> [String: Any] in
            let centroid = placement.applying(to: info.centroid)
            let normal = simd_normalize(placement.rotation.act(info.normal))
            var row: [String: Any] = [
                "index": info.index,
                "areaMM2": info.area,
                "centroid": [centroid.x, centroid.y, centroid.z],
                "normal": [normal.x, normal.y, normal.z],
            ]
            switch info.signature?.kind {
            case .planar:
                row["kind"] = "planar"
            case let .cylindrical(radius):
                row["kind"] = "cylindrical"
                row["radiusMM"] = radius
            case nil:
                // Torus/sphere/swept surfaces: listed for discovery, but a
                // FaceRef cannot express them — say so up front.
                row["kind"] = "other"
                row["referenceable"] = false
            }
            if let name = names[info.index], let encoded = jsonObject(name) {
                row["name"] = encoded
            }
            return row
        }
        return .ok([
            "body": context.body.id.raw.uuidString,
            "count": rows.count,
            "faces": rows,
            "message": "Indices feed feature.shell/deleteFace/replaceFace. "
                     + "kind \"other\" faces are listed but not referenceable.",
        ])
    }

    /// feature.fillet / feature.chamfer: mint real EdgeRefs — mesh-side
    /// signature for the fallback, EdgeName for identity — and record the
    /// node through the same path as a hand-picked blend, so the feature
    /// replays identically.
    private func execBlend(body bodyID: BodyID, isFillet: Bool, amount: Double,
                           edgeIndices: [Int],
                           on viewModel: EditorViewModel) -> AgentResponse {
        let session = viewModel.session
        let context: (body: Body, brep: BRepHandle)
        switch identityContext(bodyID, session) {
        case let .ok(body, brep): context = (body, brep)
        case let .reply(reply): return reply
        }
        let adjacency = OCCTKernel.edgeFaceAdjacency(context.brep)
        let known = Set(adjacency.map(\.edge))
        for index in edgeIndices where !known.contains(index) {
            return .failure(404, "Not Found", error: "unknown_edge",
                            message: "No blendable kernel edge \(index) on "
                                   + "'\(context.body.name)'. GET /v1/edges?body=… for the list.")
        }
        let names = freshNames(for: context.body, session)
        let edgeNames = ElementNaming.edgeNames(adjacency: adjacency, names: names)

        // Signatures come from the mesh side, exactly as an interactive pick
        // would mint them — inverse-mapped through the same nearest-edge
        // matching. All-or-nothing: a ref without a signature could not fall
        // back if its name later misses.
        let tolerance = OCCTKernel.matchTolerance(for: context.brep)
        let wanted = Set(edgeIndices)
        var signatureByEdge: [Int: EdgeSignature] = [:]
        for edge in EdgeTopology.selectableEdges(from: context.body.render) {
            let mid = edge.midpoint
            guard let index = OCCTKernel.nearestEdgeIndex(
                context.brep,
                to: SIMD3(Double(mid.x), Double(mid.y), Double(mid.z)),
                tolerance: tolerance),
                wanted.contains(index), signatureByEdge[index] == nil
            else { continue }
            signatureByEdge[index] = EdgeTopology.signature(of: edge)
            if signatureByEdge.count == wanted.count { break }
        }
        let ref = bodyRef(bodyID, session)
        var refs: [EdgeRef] = []
        for index in edgeIndices {
            guard let signature = signatureByEdge[index] else {
                return .failure(409, "Conflict", error: "unaddressable_edge",
                                message: "Kernel edge \(index) has no mesh-side "
                                       + "signature to fall back on — pick a different "
                                       + "edge from /v1/edges.")
            }
            refs.append(EdgeRef(body: ref, signature: signature,
                                faceNames: edgeNames[index]))
        }
        let node = FeatureNode(
            name: isFillet ? "Fillet" : "Chamfer",
            kind: isFillet
                ? .fillet(body: ref, edges: refs, radius: Expr(value: amount))
                : .chamfer(body: ref, edges: refs, setback: Expr(value: amount)),
            outputBodyIDs: [bodyID])
        return record(node, on: viewModel)
    }

    /// feature.shell: open faces by kernel index, minted into FaceRefs with
    /// both signature and name.
    private func execShell(body bodyID: BodyID, thickness: Double,
                           openFaces: [Int],
                           on viewModel: EditorViewModel) -> AgentResponse {
        let session = viewModel.session
        let context: (body: Body, brep: BRepHandle)
        switch identityContext(bodyID, session) {
        case let .ok(body, brep): context = (body, brep)
        case let .reply(reply): return reply
        }
        let ref = bodyRef(bodyID, session)
        let refs: [FaceRef]
        switch mintFaceRefs(openFaces, context: context, bodyRef: ref, session) {
        case let .ok(minted): refs = minted
        case let .reply(reply): return reply
        }
        let node = FeatureNode(
            name: "Shell",
            kind: .shell(body: ref, openFaces: refs,
                         thickness: Expr(value: thickness)),
            outputBodyIDs: [bodyID])
        return record(node, on: viewModel)
    }

    /// The direct-modeling single-face ops (push/pull, move/scale/rotate face)
    /// share this: resolve the identity context, mint a real FaceRef for the
    /// one kernel face index, and record a node the `kind` closure builds from
    /// it. Same face-minting as delete/replace-face; `outputBodyIDs:[bodyID]`
    /// because these modify the body in place.
    private func execSingleFace(body bodyID: BodyID, face: Int, name: String,
                                on viewModel: EditorViewModel,
                                _ kind: (FaceRef) -> FeatureKind) -> AgentResponse {
        let session = viewModel.session
        let context: (body: Body, brep: BRepHandle)
        switch identityContext(bodyID, session) {
        case let .ok(body, brep): context = (body, brep)
        case let .reply(reply): return reply
        }
        let ref = bodyRef(bodyID, session)
        let refs: [FaceRef]
        switch mintFaceRefs([face], context: context, bodyRef: ref, session) {
        case let .ok(minted): refs = minted
        case let .reply(reply): return reply
        }
        return record(FeatureNode(name: name, kind: kind(refs[0]),
                                  outputBodyIDs: [bodyID]), on: viewModel)
    }

    /// feature.deleteFace: remove the named kernel faces and let OCCT heal
    /// over them (spec §4.16) — recorded through the same graph path as the
    /// interactive tool.
    private func execDeleteFace(body bodyID: BodyID, faces: [Int],
                                on viewModel: EditorViewModel) -> AgentResponse {
        let session = viewModel.session
        let context: (body: Body, brep: BRepHandle)
        switch identityContext(bodyID, session) {
        case let .ok(body, brep): context = (body, brep)
        case let .reply(reply): return reply
        }
        let ref = bodyRef(bodyID, session)
        let refs: [FaceRef]
        switch mintFaceRefs(faces, context: context, bodyRef: ref, session) {
        case let .ok(minted): refs = minted
        case let .reply(reply): return reply
        }
        return record(FeatureNode(
            name: "Delete Face",
            kind: .deleteFace(body: ref, faces: refs),
            outputBodyIDs: [bodyID]), on: viewModel)
    }

    /// feature.draftFace: taper an existing face about its intersection with a
    /// world neutral plane (spec: SOLIDWORKS Draft). Recorded as a graph node,
    /// so it replays and shows in History like every other feature.
    private func execDraftFace(body bodyID: BodyID, face: Int,
                               neutralOrigin: SIMD3<Double>,
                               neutralNormal: SIMD3<Double>,
                               degrees: Double,
                               on viewModel: EditorViewModel) -> AgentResponse {
        let session = viewModel.session
        let context: (body: Body, brep: BRepHandle)
        switch identityContext(bodyID, session) {
        case let .ok(body, brep): context = (body, brep)
        case let .reply(reply): return reply
        }
        let ref = bodyRef(bodyID, session)
        let refs: [FaceRef]
        switch mintFaceRefs([face], context: context, bodyRef: ref, session) {
        case let .ok(minted): refs = minted
        case let .reply(reply): return reply
        }
        return record(FeatureNode(
            name: "Draft Face",
            kind: .draftFace(face: refs[0],
                             neutralOrigin: PointWrapper(neutralOrigin),
                             neutralNormal: PointWrapper(neutralNormal),
                             angle: Expr(value: degrees)),
            outputBodyIDs: [bodyID]), on: viewModel)
    }

    /// feature.replaceFace: extend/trim one face onto a world plane
    /// (spec §4.12). The target is a plane, not a ref — the same v1
    /// limitation the interactive tool has, for the same reason.
    private func execReplaceFace(body bodyID: BodyID, face: Int,
                                 targetOrigin: SIMD3<Double>,
                                 targetNormal: SIMD3<Double>, flip: Bool,
                                 on viewModel: EditorViewModel) -> AgentResponse {
        let session = viewModel.session
        let context: (body: Body, brep: BRepHandle)
        switch identityContext(bodyID, session) {
        case let .ok(body, brep): context = (body, brep)
        case let .reply(reply): return reply
        }
        let ref = bodyRef(bodyID, session)
        let refs: [FaceRef]
        switch mintFaceRefs([face], context: context, bodyRef: ref, session) {
        case let .ok(minted): refs = minted
        case let .reply(reply): return reply
        }
        return record(FeatureNode(
            name: "Replace Face",
            kind: .replaceFace(face: refs[0],
                               targetOrigin: PointWrapper(targetOrigin),
                               targetNormal: PointWrapper(targetNormal),
                               flip: flip),
            outputBodyIDs: [bodyID]), on: viewModel)
    }

    /// Mint real FaceRefs (signature + name) for kernel face indices — the
    /// shared back half of shell / deleteFace / replaceFace over exec.
    private enum MintedRefs {
        case ok([FaceRef])
        case reply(AgentResponse)
    }

    private func mintFaceRefs(_ indices: [Int],
                              context: (body: Body, brep: BRepHandle),
                              bodyRef ref: BodyRef,
                              _ session: DocumentSession) -> MintedRefs {
        // KERNEL-SIDE minting: signatures come from the brep's own face
        // geometry (never stale, never misaligned — the mesh-table channel
        // served wrong indices for assigned-render bodies), and names ride
        // along only when the retained maps are fresh.
        let infos = Dictionary(uniqueKeysWithValues:
            OCCTKernel.faceInfo(context.brep).map { ($0.index, $0) })
        let names = freshNames(for: context.body, session)
        var refs: [FaceRef] = []
        for index in indices {
            guard let info = infos[index] else {
                return .reply(.failure(404, "Not Found", error: "unknown_face",
                                       message: "No kernel face \(index) on "
                                              + "'\(context.body.name)'. GET /v1/faces?body=… for the list."))
            }
            guard let signature = info.signature else {
                return .reply(.failure(409, "Conflict", error: "unreferenceable_face",
                                       message: "Kernel face \(index) is a surface kind a FaceRef "
                                              + "cannot express (torus/sphere/swept) — pick a planar "
                                              + "or cylindrical face from /v1/faces."))
            }
            refs.append(FaceRef(body: ref, creator: ref.producer,
                                role: .derived(index: 0), signature: signature,
                                elementName: names[index]))
        }
        return .ok(refs)
    }

    // MARK: - Geometry health (/v1/check — docs/FREECAD_PLAYBOOK.md D1)

    /// Deep validity report per body. Mesh-only bodies are reported as
    /// `meshOnly` rather than silently skipped — losing the brep somewhere in
    /// a chain is itself a finding, and /v1/state's `brep` flag alone won't
    /// tell you WHICH downstream check you can no longer run.
    private func check(bodyID: String?, runBOPCheck: Bool,
                       on viewModel: EditorViewModel) -> AgentResponse {
        let bodies = viewModel.session.document.bodies
        let targets: [Body]
        if let bodyID {
            guard let uuid = UUID(uuidString: bodyID),
                  let body = bodies.first(where: { $0.id.raw == uuid }) else {
                return execMissing("body", bodyID)
            }
            targets = [body]
        } else {
            targets = bodies
        }
        var invalid = 0
        let rows = targets.map { body -> [String: Any] in
            var row: [String: Any] = [
                "id": body.id.raw.uuidString,
                "name": body.name,
            ]
            if let brep = body.brep {
                let health = OCCTKernel.healthReportDictionary(
                    for: brep, runBOPCheck: runBOPCheck)
                if health["valid"] as? Bool != true { invalid += 1 }
                row["health"] = health
            } else {
                row["meshOnly"] = true
            }
            return row
        }
        return .ok([
            "checked": rows.count,
            "invalid": invalid,
            "bopCheckRequested": runBOPCheck,
            "bodies": rows,
        ])
    }

    // MARK: State snapshot

    /// What the agent can see. Deliberately the same numbers the human sees:
    /// `selectionMeasurements` is exactly what `SelectionInfoBar` renders, so
    /// an agent and a person reading over its shoulder never disagree about
    /// what the model measures.
    private func snapshot(of viewModel: EditorViewModel) -> [String: Any] {
        let document = viewModel.session.document

        let bodies = document.bodies.map { body -> [String: Any] in
            [
                "id": body.id.raw.uuidString,
                "name": body.name,
                "hidden": body.isHidden,
                // Exact from the B-rep where there is one (the mesh reads
                // ~0.3% low on curved faces) — same number the info bar shows.
                "volumeMM3": MeasureKit.volume(of: body),
                // Whether this body is still analytic or has been flattened to
                // its tessellation — the distinction the OCCT port exists for.
                "brep": body.brep != nil,
                // World-space extent (mm), so a rebuild can be checked against a
                // reference part's envelope, not just its volume.
                "bounds": MeasureKit.boundingBox(bodies: [body]).map {
                    [[$0.min.x, $0.min.y, $0.min.z], [$0.max.x, $0.max.y, $0.max.z]]
                } ?? [],
            ]
        }

        let measurements = viewModel.selectionMeasurements.map {
            ["label": $0.label, "value": $0.value]
        }

        var state: [String: Any] = [
            "document": documentName ?? "(unnamed)",
            "mode": Self.modeName(viewModel.mode),
            "platform": Self.platformName,
            "selection": viewModel.selection.map(\.raw.uuidString),
            "selectedSketchEntities": viewModel.selectedSketchEntityIDs.count,
            "bodies": bodies,
            "sketchCount": document.sketches.count,
            "featureCount": document.features.nodes.count,
            "canUndo": viewModel.session.undoStack.canUndo,
            "canRedo": viewModel.session.undoStack.canRedo,
            "measurements": measurements,
            "commandSearchActive": viewModel.commandSearchActive,
        ]
        if let title = viewModel.session.undoStack.undoTitle { state["undoTitle"] = title }
        // Items Manager folders (spec §11): the tree as the panel shows it.
        state["itemFolders"] = document.itemFolders.map { folder -> [String: Any] in
            [
                "id": folder.id.raw.uuidString,
                "name": folder.name,
                "parent": folder.parentID.map { $0.raw.uuidString } ?? "",
                "members": folder.members.map { key -> [String: String] in
                    switch key {
                    case .body(let id): return ["kind": "body", "id": id.raw.uuidString]
                    case .sketch(let id): return ["kind": "sketch", "id": id.raw.uuidString]
                    case .plane(let id): return ["kind": "plane", "id": id.raw.uuidString]
                    case .axis(let id): return ["kind": "axis", "id": id.raw.uuidString]
                    case .image(let id): return ["kind": "image", "id": id.raw.uuidString]
                    }
                },
            ]
        }
        if let error = viewModel.errorMessage { state["error"] = error }
        // Per-feature replay failures — the same signal the History badges
        // render. `error` above is the one-shot interactive alert; this is the
        // persistent graph state, so an agent that drove the UI (not /v1/exec)
        // can still see WHICH feature failed without a second channel.
        let evalErrors = viewModel.session.lastEvalErrors
        if !evalErrors.isEmpty {
            state["evalErrors"] = document.features.nodes.compactMap { node -> [String: String]? in
                guard let err = evalErrors[node.id] else { return nil }
                return [
                    "featureID": node.id.raw.uuidString,
                    "feature": node.name,
                    "error": String(describing: err),
                ]
            }
        }
        return state
    }

    /// Case name only, derived rather than switched.
    ///
    /// `EditorMode` has north of twenty cases and gains more with every tool;
    /// a hand-written switch here would be a second list to forget to update,
    /// and its failure mode is reporting a stale mode name — which is worse
}
