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
    /// The owning facade for operations that must prepare bytes off-main and
    /// then commit on this actor (E31-R2 `document.import`). Nil for callers
    /// that only use the synchronous query/edit vocabulary.
    let document: FloeCADDocument?

    init(viewModel: EditorViewModel, documentName: String? = nil,
         document: FloeCADDocument? = nil) {
        self.viewModel = viewModel
        self.documentName = documentName
        self.document = document
    }

    /// Run one parsed operation through the same path the interactive tools use.
    /// `document.import` is refused here: it would parse asset bytes on the
    /// MainActor. Use `runAsync` (the real App/AgentExec entry) instead.
    func run(_ op: AgentExecOp) -> AgentResponse {
        if case .importFile = op {
            return .failure(409, "Conflict", error: "import_requires_async",
                            message: "Asset import must run through the async import path so its "
                                + "parse happens off the MainActor; nothing was imported.")
        }
        return execute(op, on: viewModel)
    }

    /// E31-R2: the async entry. Only `document.import` differs; every other
    /// operation keeps the exact synchronous implementation and ordering.
    func runAsync(_ op: AgentExecOp) async -> AgentResponse {
        switch op {
        case .importFile:
            return await executeImportFile(op)
        default:
            return run(op)
        }
    }

    /// The real `document.import` path: read the host file off-main, parse with
    /// the kernel importer under the standard budget/token on a detached
    /// worker, then build bodies on this actor through `importParts` (one undo
    /// step). A cancelled/refused parse never touches the document.
    private func executeImportFile(_ op: AgentExecOp) async -> AgentResponse {
        guard case let .importFile(path, fileName, unitScale) = op else {
            return .failure(400, "Bad Request", error: "bad_import", message: "Not an import op.")
        }
        guard let document else {
            return .failure(409, "Conflict", error: "document_unavailable",
                            message: "The native document facade is not available for this import.")
        }
        let url = URL(fileURLWithPath: path)
        let data: Data
        do {
            data = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url)
            }.value
        } catch {
            return .failure(404, "Not Found", error: "unreadable_path",
                            message: "Could not read \(path).")
        }
        let name = fileName ?? url.lastPathComponent
        let loose = ["obj", "gltf", "blend"].contains(url.pathExtension.lowercased())
        let siblings = loose ? MeshImportKit.folderSiblings(of: url) : [:]
        let token = MeshImportCancellation()
        do {
            let plan = try await CADMeshImportService.parseOffMain(
                data: data, fileName: name, siblings: siblings,
                unitScale: unitScale, cancellation: token)
            if Task.isCancelled { throw CADDocumentError(
                code: "cancelled",
                message: "The import was cancelled; nothing was imported and the source was not changed.") }
            let outcome = try CADMeshImportService.apply(
                plan, to: document, cancellation: token)
            guard outcome.isOK else {
                return .failure(422, "Unprocessable Entity",
                                error: outcome.errorCode ?? "import_failed",
                                message: outcome.message ?? "The import failed.")
            }
            let object = (try? JSONSerialization.jsonObject(with: outcome.payload))
                as? [String: Any] ?? [:]
            let rows = object["imported"] as? [[String: Any]] ?? []
            let ids = rows.compactMap { $0["bodyID"] as? String }
            let names = rows.compactMap { $0["name"] as? String }
            viewModel.errorMessage = nil
            return AgentResponse.ok([
                "bodyIDs": ids,
                "names": names,
                "textured": plan.parts.filter {
                    $0.material?.baseColorTexture != nil
                }.count,
                "triangles": plan.triangleCount,
                "undoSteps": 1,
                "parsed_off_main": plan.parsedOffMain,
            ])
        } catch let error as CADDocumentError {
            return .failure(422, "Unprocessable Entity", error: error.code,
                            message: error.message)
        } catch {
            return .failure(422, "Unprocessable Entity", error: "import_failed",
                            message: "The import failed: \(error.localizedDescription) "
                                + "Nothing was imported; the source and document are unchanged.")
        }
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

        case .importFile:
            // Unreachable from `run` (it refuses the op) and `runAsync`
            // (it routes to `executeImportFile`). Kept explicit so this
            // switch stays exhaustive without a hidden MainActor parse.
            return .failure(409, "Conflict", error: "import_requires_async",
                            message: "Asset import must run through the async import path.")

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

        case let .addText(sketchID, text, height, origin, fontName):
            guard session.document.sketches.contains(where: { $0.id == sketchID }) else {
                return execMissing("sketch", sketchID.raw.uuidString)
            }
            // One shared native shaping pass: the same Core Text outlines the
            // interactive Text tool commits, plus the font/glyph diagnostics an
            // Agent reply must name precisely. A partial word is never added.
            let shaped = TextSketch.shape(
                text: text, fontName: fontName, height: height, at: origin)
            if let unsupported = shaped.unsupportedFontName {
                let resolved = shaped.resolvedFontNames.first ?? "?"
                return .failure(422, "Unprocessable Entity", error: "unsupported_font",
                                message: "Font '\(unsupported)' is not installed; the system substitute "
                                    + "'\(resolved)' was NOT used and nothing was added. Pass an installed "
                                    + "family or PostScript name (for example Helvetica, Avenir Next, "
                                    + "Georgia, or PingFang SC).")
            }
            if shaped.tooComplex {
                return .failure(422, "Unprocessable Entity", error: "text_too_complex",
                                message: "The text would exceed \(TextSketch.maximumOutlineEntities) outline "
                                    + "segments; nothing was added. Use shorter text.")
            }
            if !shaped.missingCharacters.isEmpty {
                let list = Self.missingGlyphList(shaped.missingCharacters)
                let primary = shaped.resolvedFontNames.first ?? "?"
                let fallbacks = shaped.fallbackFontNames.isEmpty
                    ? "no fallback fonts used"
                    : shaped.fallbackFontNames.joined(separator: ", ")
                return .failure(422, "Unprocessable Entity", error: "unsupported_glyphs",
                                message: "No real vector outline for \(list) (primary font '\(primary)'; "
                                    + "fallbacks: \(fallbacks)); nothing was added. Unsupported, missing or "
                                    + "colour/bitmap-only glyphs are refused — a placeholder is never added.")
            }
            guard !shaped.entities.isEmpty else {
                return .failure(422, "Unprocessable Entity", error: "empty_text",
                                message: "The text has no visible glyph outlines; nothing was added.")
            }
            // Ordinary revision/undo/save path: one AddSketchEntitiesCommand,
            // atomically with any dependent-feature rebuild.
            let command = AddSketchEntitiesCommand(
                sketchID: sketchID, entities: shaped.entities, title: "Text")
            guard session.performWithSketchRebuild(command, sketchID: sketchID) else {
                let detail = session.lastRebuildRejection.isEmpty
                    ? "the text edit could not be applied."
                    : "adding the text would break an existing associative feature; the document was left unchanged."
                return .failure(422, "Unprocessable Entity", error: "rebuild_failed",
                                message: "Text was refused: \(detail)")
            }
            var payload: [String: Any] = [
                "action": "sketch.addText",
                "sketchID": sketchID.raw.uuidString,
                "entityCount": shaped.entities.count,
                "glyphCount": shaped.glyphCount,
                "outlineLoopCount": shaped.outlineLoopCount,
                "advanceWidthMM": shaped.advanceWidthMM,
                "heightMM": shaped.heightMM,
                "origin": [origin.x, origin.y],
                "units": "mm",
                "requestedFontName": shaped.requestedFontName ?? NSNull(),
                "resolvedFontNames": shaped.resolvedFontNames,
                "fallbackFontNames": shaped.fallbackFontNames,
                "undoSteps": 1,
                // Honest discovery: this is sketch outline geometry, not a mesh
                // text action and not a raster/external-mesh substitute.
                "meshText": false,
            ]
            if let bounds = shaped.bounds {
                payload["boundsMM"] = [[bounds.min.x, bounds.min.y],
                                       [bounds.max.x, bounds.max.y]]
            }
            // Keep every tool result bounded. Stable ids remain queryable from
            // the sketch query, exactly like every other entity edit.
            if shaped.entities.count <= 64 {
                payload["entityIDs"] = shaped.entities.map { $0.id.uuidString }
            } else {
                payload["entityIDsOmitted"] = true
                payload["entityIDsAvailableVia"] = shaped.entities.count <= 512
                    ? "query kind=sketches (entityRows)"
                    : "query kind=sketches (entityRows; page with offset/limit)"
            }
            return execOK(viewModel, payload)

        case let .extrude(sketchID, seed, requested, symmetric, taperDegrees, booleanOp, targets, end):
            guard let sketch = session.document.sketches.first(where: { $0.id == sketchID }) else {
                return execMissing("sketch", sketchID.raw.uuidString)
            }
            if let bad = missingBody(targets, session) { return bad }
            if booleanOp != .newBody,
               let refusal = exactSurfaceRefusal(targets, operation: "Extrude boolean",
                                                 session) { return refusal }
            let intent = BooleanIntent(op: booleanOp, resolvedTargets: targets.map { bodyRef($0, session) })
            // An end condition resolves to the distance it stands for, from
            // the boolean's targets (or every body when there are none),
            // along the plane normal in the requested sign's direction.
            var distance = requested
            var termination: ExtrudeEndDefinition?
            if let end {
                let candidates = targets.isEmpty
                    ? session.document.bodies
                    : session.document.bodies.filter { targets.contains($0.id) }
                do {
                    let inputs = ExtrudeEndDefinition.inputs(bodies: candidates, graph: session.document.features,
                        tables: session.lastFaceTables)
                    let bound = try ExtrudeEndDefinition.bind(end, plane: sketch.plane, seed: seed,
                        reversed: requested < 0, inputs: inputs)
                    distance = try bound.resolvedDistance(plane: sketch.plane, seed: seed,
                        symmetric: symmetric, inputs: inputs, naming: SignatureNaming())
                    termination = bound
                } catch {
                    return .failure(422, "Unprocessable Entity", error: "no_end_found",
                                    message: error.localizedDescription)
                }
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
                    extraProfiles: [], termination: termination),
                outputBodyIDs: [BodyID()]), on: viewModel)

        case let .revolve(sketchID, seed, axis, angleDegrees, booleanOp, targets):
            guard session.document.sketches.contains(where: { $0.id == sketchID }) else {
                return execMissing("sketch", sketchID.raw.uuidString)
            }
            if let bad = missingBody(targets, session) { return bad }
            if booleanOp != .newBody,
               let refusal = exactSurfaceRefusal(targets, operation: "Revolve boolean",
                                                 session) { return refusal }
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

        case let .hole(sketchID, seed, targetID, spec):
            return execHole(sketch: sketchID, seed: seed, targetID: targetID,
                            spec: spec, on: viewModel)

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
            if let refusal = exactSurfaceRefusal([target] + tools, operation: "Boolean",
                                                 session) { return refusal }
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

        case let .sweep(sketchID, seed, spine, booleanOp, targets, helix, path):
            guard session.document.sketches.contains(where: { $0.id == sketchID }) else {
                return execMissing("sketch", sketchID.raw.uuidString)
            }
            if let bad = missingBody(targets, session) { return bad }
            if booleanOp != .newBody,
               let refusal = exactSurfaceRefusal(targets, operation: "Sweep boolean",
                                                 session) { return refusal }
            let intent = BooleanIntent(op: booleanOp, resolvedTargets: targets.map { bodyRef($0, session) })
            let resolvedSpine: [SIMD3<Double>]
            do {
                resolvedSpine = try path?.resolvedSpine { id in
                    session.document.sketches.first(where: { $0.id == id })
                } ?? spine
            } catch {
                return .failure(400, "Bad Request", error: "invalid_sweep_path", message: error.localizedDescription)
            }
            return record(FeatureNode(
                name: helix == nil ? "Sweep" : "Helix Sweep",
                kind: .sweep(
                    profile: execProfileRef(sketchID: sketchID, seed: seed,
                                            in: session),
                    plane: PlaneRef(source: .sketch(sketchID)),
                    spine: resolvedSpine.map(PointWrapper.init),
                    boolean: intent,
                    helix: helix, path: path),
                outputBodyIDs: [BodyID()]), on: viewModel)

        case let .loft(sections, booleanOp, targets):
            for section in sections where !session.document.sketches.contains(where: { $0.id == section.sketch }) {
                return execMissing("sketch", section.sketch.raw.uuidString)
            }
            if let bad = missingBody(targets, session) { return bad }
            if booleanOp != .newBody,
               let refusal = exactSurfaceRefusal(targets, operation: "Loft boolean",
                                                 session) { return refusal }
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
            if radial { return execRadialOffset(body: bodyID, face: face, distance: distance, on: viewModel) }
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

        case let .draftFace(bodyID, face, neutralOrigin, neutralNormal, angleDegrees, referencePlane):
            return execDraftFace(body: bodyID, face: face, neutralOrigin: neutralOrigin,
                                 neutralNormal: neutralNormal, degrees: angleDegrees,
                                 referencePlane: referencePlane,
                                 on: viewModel)
        case let .replaceFace(bodyID, face, origin, normal, flip, referencePlane):
            return execReplaceFace(body: bodyID, face: face,
                                   targetOrigin: origin, targetNormal: normal,
                                   flip: flip, referencePlane: referencePlane, on: viewModel)

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
    private func record(_ node: FeatureNode, on viewModel: EditorViewModel,
                        details: [String: Any] = [:], prefix: [FeatureNode] = []) -> AgentResponse {
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
        let checkpoint = session.captureEditCheckpoint()
        session.recordAndRebuild(prefix + [node], title: node.name)

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
        for (key, value) in details { payload[key] = value }
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
            session.restoreEditCheckpoint(checkpoint)
            payload["failed"] = true
            payload["message"] = "\(node.name) could not be completed: \(mine). The document was preserved."
            payload["error"] = "feature_failed"
            payload["ok"] = false
            payload["undoSteps"] = 0
            return .json(422, "Unprocessable Entity", payload)
        } else if !session.lastRebuildRejection.isEmpty {
            // An associative rejection never applies the appended node. Do not
            // report a success that the document does not contain.
            session.restoreEditCheckpoint(checkpoint)
            payload["failed"] = true
            payload["message"] = "\(node.name) would break an associative dependency. The document was preserved."
            payload["error"] = "rebuild_failed"
            payload["ok"] = false
            payload["undoSteps"] = 0
            return .json(422, "Unprocessable Entity", payload)
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

    /// Refuse a closed-solid operation aimed at an exact OPEN surface BEFORE a
    /// feature node is recorded. Replay cannot see imported bodies, so without
    /// this preflight the caller would get a generic unresolved-target error;
    /// with it the refusal names the real limitation and the document, history,
    /// undo/redo stacks and the exact surface handle stay untouched. This is a
    /// capability boundary, not a new approval/tool policy.
    private func exactSurfaceRefusal(_ ids: [BodyID], operation: String,
                                     _ session: DocumentSession) -> AgentResponse? {
        for id in ids {
            guard let body = session.document.body(with: id),
                  body.surfaceBRep != nil else { continue }
            return .failure(422, "Unprocessable Entity",
                            error: "exact_surface_needs_solid",
                            message: ExactSurfaceBoundary.refusal(operation, bodyName: body.name))
        }
        return nil
    }

    private func execMissing(_ what: String, _ id: String) -> AgentResponse {
        .failure(404, "Not Found", error: "unknown_\(what)",
                 message: "No \(what) with id \(id) in this document. GET /v1/state for what exists.")
    }

    private static func missingGlyphList(_ characters: [String]) -> String {
        let shown = characters.prefix(16).joined(separator: " ")
        return characters.count > 16
            ? "\(shown)… (and \(characters.count - 16) more code points)"
            : shown
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
        // stale map refuses new persistent references, never wrong geometry. (The
        // old blanket stale_identity 409 made every undo a dead end.)
        return .ok(body: body, brep: brep)
    }

    /// The body's kernel-face names ONLY when they describe its current
    /// revision — the same staleness rule the interactive mint sites use. A
    /// stale map yields [:], so a new persistent edit must refuse rather
    /// than manufacture a name-less reference.
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
    ///
    /// `format=obj` here is the legacy TRUE single-file OBJ: geometry and UVs,
    /// never MTL/materials/textures (the response says so). The complete
    /// appearance is the native `obj_bundle` export, not a ZIP disguised as
    /// this response's OBJ body.
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
        if format == .obj {
            // The legacy single-file OBJ deliberately carries geometry + UVs
            // only. Say so instead of implying the applied appearance is there;
            // the native obj_bundle export is the complete MTL/texture path.
            response.info["Materials"] = "not included (single-file OBJ: geometry and UVs only)"
            response.info["MaterialBundle"] = "use the native obj_bundle export for model.mtl and textures"
        }
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
        // The blend commits atomically. Report every requested index, including
        // failures before feature recording, without claiming partial success.
        var seen = Set<Int>()
        let uniqueIndices = edgeIndices.filter { seen.insert($0).inserted }
        func report(_ response: AgentResponse) -> AgentResponse {
            guard var payload = (try? JSONSerialization.jsonObject(with: response.body))
                    as? [String: Any] else { return response }
            let succeeded = (200..<300).contains(response.status)
                && payload["ok"] as? Bool == true && payload["failed"] as? Bool != true
            payload["edgeProcessing"] = [
                "requested": edgeIndices,
                "processed": succeeded ? uniqueIndices : [],
                "rejected": succeeded ? [] : uniqueIndices,
                "atomic": true,
            ] as [String: Any]
            var result = AgentResponse.json(response.status, response.reason, payload)
            result.info = response.info
            return result
        }
        guard !edgeIndices.isEmpty else {
            return report(.failure(400, "Bad Request", error: "empty_edge_selection",
                                   message: "Select at least one edge to blend."))
        }
        let session = viewModel.session
        let context: (body: Body, brep: BRepHandle)
        if let refusal = exactSurfaceRefusal(
            [bodyID], operation: isFillet ? "Fillet" : "Chamfer", session) {
            return report(refusal)
        }
        switch identityContext(bodyID, session) {
        case let .ok(body, brep): context = (body, brep)
        case let .reply(reply): return report(reply)
        }
        let adjacency = OCCTKernel.edgeFaceAdjacency(context.brep)
        let known = Set(adjacency.map(\.edge))
        for index in edgeIndices where !known.contains(index) {
            return report(.failure(404, "Not Found", error: "unknown_edge",
                            message: "No blendable kernel edge \(index) on "
                                   + "'\(context.body.name)'. GET /v1/edges?body=… for the list."))
        }
        let names = freshNames(for: context.body, session)
        let edgeNames = ElementNaming.edgeNames(adjacency: adjacency, names: names)

        // Signatures come from the mesh side, exactly as an interactive pick
        // would mint them — inverse-mapped through the same nearest-edge
        // matching. Named references remain bound to their names on replay;
        // signatures retain compatibility for genuinely unnamed legacy refs.
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
                return report(.failure(409, "Conflict", error: "unaddressable_edge",
                                message: "Kernel edge \(index) has no mesh-side "
                                       + "selection fingerprint — pick a different "
                                       + "edge from /v1/edges."))
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
        return report(record(node, on: viewModel))
    }

    /// feature.hole: one locating circle + typed hole semantics. Validates the
    /// actual pilot diameter before recording, so a counterbore/sink smaller
    /// than the pilot is refused without touching the document. The recorded
    /// node uses the target's existing BodyID (an in-place exact subtract).
    private func execHole(sketch sketchID: SketchID, seed: SIMD2<Double>,
                          targetID: BodyID, spec: HoleSpec,
                          on viewModel: EditorViewModel) -> AgentResponse {
        let session = viewModel.session
        guard let sketch = session.document.sketches.first(where: { $0.id == sketchID }) else {
            return execMissing("sketch", sketchID.raw.uuidString)
        }
        guard let target = session.document.body(with: targetID) else {
            return .failure(404, "Not Found", error: "unknown_target",
                            message: "No target body with id \(targetID.raw.uuidString) in this document.")
        }
        if let refusal = exactSurfaceRefusal([targetID], operation: "Hole", session) {
            return refusal
        }
        guard target.brep != nil else {
            return .failure(409, "Conflict", error: "hole_requires_brep",
                            message: "Holes need an analytic B-rep target; '\(target.name)' is mesh-only.")
        }
        let detected = ProfileDetector.detectProfiles(in: sketch)
        guard let region = ProfileDetector.profiles(at: seed, in: sketch).first,
              case let .circle(center, radius) = region.kind,
              ProfileDetector.holes(of: region, among: detected).isEmpty else {
            return .failure(422, "Unprocessable Entity", error: "not_circle",
                            message: "The hole placement must resolve to exactly one circular region "
                                   + "with no inner loops at seedPoint.")
        }
        if let issue = HoleKit.validationIssue(spec, pilotDiameter: radius * 2) {
            return .failure(422, "Unprocessable Entity", error: "invalid_hole", message: issue)
        }
        let profile = ProfileRef(sketchID: sketchID,
                                 entityIDs: Array(region.sourceEntityIDs),
                                 holeEntityIDs: [],
                                 seedPoint: center)
        let node = FeatureNode(
            name: "Hole",
            kind: .hole(target: bodyRef(targetID, session), profile: profile,
                        plane: PlaneRef(source: .sketch(sketchID)), spec: spec),
            outputBodyIDs: [targetID])
        var parameters: [String: Any] = [
            "type": spec.kind.rawValue,
            "reversed": spec.reversed,
            "pilotDiameter": radius * 2,
        ]
        if let depth = spec.depth { parameters["depth"] = depth.value }
        if let diameter = spec.counterboreDiameter {
            parameters["counterboreDiameter"] = diameter.value
        }
        if let depth = spec.counterboreDepth {
            parameters["counterboreDepth"] = depth.value
        }
        if let diameter = spec.countersinkDiameter {
            parameters["countersinkDiameter"] = diameter.value
        }
        if let angle = spec.countersinkAngle {
            parameters["countersinkAngle"] = angle.value
        }
        return record(node, on: viewModel, details: [
            "targetBodyID": targetID.raw.uuidString,
            "pilotDiameter": radius * 2,
            "type": spec.kind.rawValue,
            "parameters": parameters,
        ])
    }

    /// feature.shell: open faces by kernel index, minted into FaceRefs with
    /// both signature and name.
    private func execShell(body bodyID: BodyID, thickness: Double,
                           openFaces: [Int],
                           on viewModel: EditorViewModel) -> AgentResponse {
        let session = viewModel.session
        let context: (body: Body, brep: BRepHandle)
        if let refusal = exactSurfaceRefusal([bodyID], operation: "Shell", session) {
            return refusal
        }
        switch identityContext(bodyID, session) {
        case let .ok(body, brep): context = (body, brep)
        case let .reply(reply): return reply
        }
        var ref = bodyRef(bodyID, session)
        let refs: [FaceRef]
        let prefix: [FeatureNode]
        switch mintFaceRefs(openFaces, context: context, bodyRef: ref, session) {
        case let .ok(minted, owner, sources): refs = minted; ref = owner; prefix = sources
        case let .reply(reply): return reply
        }
        let node = FeatureNode(
            name: "Shell",
            kind: .shell(body: ref, openFaces: refs,
                         thickness: Expr(value: thickness)),
            outputBodyIDs: [bodyID])
        return record(node, on: viewModel, prefix: prefix)
    }

    /// The direct-modeling single-face ops (push/pull, move/scale/rotate face)
    /// share this: resolve the identity context, mint a real FaceRef for the
    /// one kernel face index, and record a node the `kind` closure builds from
    /// it. Same face-minting as delete/replace-face; `outputBodyIDs:[bodyID]`
    /// because these modify the body in place.
    private func execRadialOffset(body bodyID: BodyID, face: Int, distance: Double,
                                  on viewModel: EditorViewModel) -> AgentResponse {
        let session = viewModel.session
        let body: Body, solid: BRepHandle
        switch identityContext(bodyID, session) {
        case let .ok(found, handle): body = found; solid = handle
        case let .reply(reply): return reply
        }
        guard let info = OCCTKernel.faceInfo(solid).first(where: { $0.index == face }),
              let signature = info.signature, case let .cylindrical(radius) = signature.kind,
              distance.isFinite, abs(distance) > 1e-9, radius + distance > 1e-7 else {
            return .failure(422, "Unprocessable Entity", error: "bad_radial_offset",
                message: "Select an existing cylindrical face and a non-zero offset that keeps its radius positive.")
        }
        let ref: FaceRef
        let prefix: [FeatureNode]
        switch mintFaceRefs([face], context: (body, solid), bodyRef: bodyRef(bodyID, session), session) {
        case let .ok(refs, _, sources): ref = refs[0]; prefix = sources
        case let .reply(reply): return reply
        }
        return record(FeatureNode(name: FloeCADStrings.text("cad.feature.radialOffset", "Radial offset"),
            kind: .pushPull(face: ref, distance: Expr(value: distance), mode: .cylinderRadial),
            outputBodyIDs: [bodyID]), on: viewModel,
            details: ["mode": "cylinderRadial", "radialOffsetMM": distance,
                "importSourceCaptured": !prefix.isEmpty], prefix: prefix)
    }

    private func execSingleFace(body bodyID: BodyID, face: Int, name: String,
                                on viewModel: EditorViewModel,
                                _ kind: (FaceRef) -> FeatureKind) -> AgentResponse {
        let session = viewModel.session
        let context: (body: Body, brep: BRepHandle)
        if let refusal = exactSurfaceRefusal([bodyID], operation: name, session) {
            return refusal
        }
        switch identityContext(bodyID, session) {
        case let .ok(body, brep): context = (body, brep)
        case let .reply(reply): return reply
        }
        var ref = bodyRef(bodyID, session)
        let refs: [FaceRef]
        let prefix: [FeatureNode]
        switch mintFaceRefs([face], context: context, bodyRef: ref, session) {
        case let .ok(minted, owner, sources): refs = minted; ref = owner; prefix = sources
        case let .reply(reply): return reply
        }
        let feature = kind(refs[0])
        // Refuse the known unsupported exact edits before a speculative
        // rebuild, preserving clean/undo/redo state as well as the B-rep.
        let refusal: KernelOps.ExactEditError?
        switch feature {
        case .scaleFace: refusal = .unsupported("Face scaling")
        case .rotateFace: refusal = .unsupported("Face rotation")
        case .pushPull(_, _, .cylinderRadial): refusal = .unsupported("Radial face movement")
        case let .moveFace(_, delta) where abs(delta.point.x) > 1e-7 || abs(delta.point.y) > 1e-7:
            refusal = .unsupported("Tangential face movement")
        default: refusal = nil
        }
        if let refusal {
            return .failure(422, "Unprocessable Entity", error: "exact_edit_unsupported", message: refusal.message)
        }
        return record(FeatureNode(name: name, kind: feature,
                                  outputBodyIDs: [bodyID]), on: viewModel, prefix: prefix)
    }

    /// feature.deleteFace: remove the named kernel faces and let OCCT heal
    /// over them (spec §4.16) — recorded through the same graph path as the
    /// interactive tool.
    private func execDeleteFace(body bodyID: BodyID, faces: [Int],
                                on viewModel: EditorViewModel) -> AgentResponse {
        let session = viewModel.session
        let context: (body: Body, brep: BRepHandle)
        if let refusal = exactSurfaceRefusal([bodyID], operation: "Delete Face", session) {
            return refusal
        }
        switch identityContext(bodyID, session) {
        case let .ok(body, brep): context = (body, brep)
        case let .reply(reply): return reply
        }
        var ref = bodyRef(bodyID, session)
        let refs: [FaceRef]
        let prefix: [FeatureNode]
        switch mintFaceRefs(faces, context: context, bodyRef: ref, session) {
        case let .ok(minted, owner, sources): refs = minted; ref = owner; prefix = sources
        case let .reply(reply): return reply
        }
        return record(FeatureNode(
            name: "Delete Face",
            kind: .deleteFace(body: ref, faces: refs),
            outputBodyIDs: [bodyID]), on: viewModel, prefix: prefix)
    }

    /// Direct edits share trusted face minting, frozen target capture and the
    /// same one-undo transaction used by every other feature command.
    private struct PreparedPlaneEdit {
        let face: FaceRef
        let reference: FeaturePlaneReference?
        let plane: SketchPlane?
        let prefix: [FeatureNode]
    }
    private enum PlaneEditPreparation {
        case ok(PreparedPlaneEdit)
        case reply(AgentResponse)
    }

    private func preparePlaneEdit(body bodyID: BodyID, face: Int,
                                  selection: AgentExecPlaneSelection?, operation: String,
                                  session: DocumentSession) -> PlaneEditPreparation {
        if let refusal = exactSurfaceRefusal([bodyID], operation: operation, session) { return .reply(refusal) }
        let context: (body: Body, brep: BRepHandle)
        switch identityContext(bodyID, session) {
        case let .ok(body, brep): context = (body, brep)
        case let .reply(reply): return .reply(reply)
        }
        var indices = [face]
        if case let .face(targetBody, targetIndex)? = selection, targetBody == bodyID { indices.append(targetIndex) }
        let refs: [FaceRef]
        var prefix: [FeatureNode]
        switch mintFaceRefs(indices, context: context, bodyRef: bodyRef(bodyID, session), session) {
        case let .ok(minted, _, sources): refs = minted; prefix = sources
        case let .reply(reply): return .reply(reply)
        }
        guard let selection else {
            return .ok(PreparedPlaneEdit(face: refs[0], reference: nil, plane: nil, prefix: prefix))
        }
        let reference: FeaturePlaneReference
        let plane: SketchPlane
        switch selection {
        case let .plane(id):
            guard let value = session.document.planes.first(where: { $0.id == id }) else {
                return .reply(execMissing("plane", id.raw.uuidString))
            }
            reference = FeaturePlaneReference(source: .plane(PlaneRef(source: .construction(id))))
            plane = value.plane
        case let .sketch(id):
            guard let value = session.document.sketches.first(where: { $0.id == id }) else {
                return .reply(execMissing("sketch", id.raw.uuidString))
            }
            reference = FeaturePlaneReference(source: .plane(PlaneRef(source: .sketch(id))))
            plane = value.plane
        case let .face(targetBody, targetIndex):
            let target: (body: Body, brep: BRepHandle)
            let targetRef: FaceRef
            if targetBody == bodyID {
                target = context
                targetRef = refs[1]
            } else {
                switch identityContext(targetBody, session) {
                case let .ok(body, brep): target = (body, brep)
                case let .reply(reply): return .reply(reply)
                }
                switch mintFaceRefs([targetIndex], context: target,
                                     bodyRef: bodyRef(targetBody, session), session) {
                case let .ok(minted, _, sources): targetRef = minted[0]; prefix += sources
                case let .reply(reply): return .reply(reply)
                }
            }
            guard let info = OCCTKernel.faceInfo(target.brep).first(where: { $0.index == targetIndex }),
                  case .planar? = info.signature?.kind else {
                return .reply(.failure(409, "Conflict", error: "planar_target_required",
                    message: "Choose one named planar face for the target or neutral plane."))
            }
            do {
                let axis = abs(info.normal.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
                let frame = try PlaneAttachmentFrame.make(faceCentroid: info.centroid,
                    faceNormal: info.normal, referenceXAxis: axis, anchorPoint: info.centroid)
                let definition = OffsetPlaneDefinition(source: targetRef,
                    sourceVersion: GeometryVersionRef(bodyID: targetBody, writer: targetRef.body.producer),
                    distance: Expr(value: 0), attachment: frame)
                plane = try definition.resolvedPlane(face: SourceFaceGeometry(bodyID: targetBody,
                    centroid: info.centroid, normal: info.normal), bodyTransform: target.body.transform)
                reference = FeaturePlaneReference(source: .face(definition))
            } catch {
                return .reply(.failure(422, "Unprocessable Entity", error: "invalid_reference_plane",
                    message: error.localizedDescription))
            }
        }
        return .ok(PreparedPlaneEdit(face: refs[0], reference: reference, plane: plane, prefix: prefix))
    }

    private func execDraftFace(body bodyID: BodyID, face: Int,
                               neutralOrigin: SIMD3<Double>, neutralNormal: SIMD3<Double>, degrees: Double,
                               referencePlane: AgentExecPlaneSelection?, on viewModel: EditorViewModel) -> AgentResponse {
        switch preparePlaneEdit(body: bodyID, face: face, selection: referencePlane,
                                operation: "Draft Face", session: viewModel.session) {
        case let .reply(reply): return reply
        case let .ok(value):
            return record(FeatureNode(name: "Draft Face", kind: .draftFace(face: value.face,
                neutralOrigin: PointWrapper(value.plane?.origin ?? neutralOrigin),
                neutralNormal: PointWrapper(value.plane?.normal ?? neutralNormal), angle: Expr(value: degrees),
                planeReference: value.reference), outputBodyIDs: [bodyID]), on: viewModel, prefix: value.prefix)
        }
    }

    private func execReplaceFace(body bodyID: BodyID, face: Int,
                                 targetOrigin: SIMD3<Double>, targetNormal: SIMD3<Double>, flip: Bool,
                                 referencePlane: AgentExecPlaneSelection?, on viewModel: EditorViewModel) -> AgentResponse {
        switch preparePlaneEdit(body: bodyID, face: face, selection: referencePlane,
                                operation: "Replace Face", session: viewModel.session) {
        case let .reply(reply): return reply
        case let .ok(value):
            return record(FeatureNode(name: "Replace Face", kind: .replaceFace(face: value.face,
                targetOrigin: PointWrapper(value.plane?.origin ?? targetOrigin),
                targetNormal: PointWrapper(value.plane?.normal ?? targetNormal), flip: flip,
                planeReference: value.reference), outputBodyIDs: [bodyID]), on: viewModel, prefix: value.prefix)
        }
    }

    /// Mint real FaceRefs (signature + name) for kernel face indices — the
    /// shared back half of shell / deleteFace / replaceFace over exec.
    private enum MintedRefs {
        case ok([FaceRef], BodyRef, [FeatureNode])
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
        let reference: BodyRef
        let prefix: [FeatureNode]
        let names: [Int: ElementName]
        if session.document.features.nodes.contains(where: { $0.outputBodyIDs.contains(context.body.id) }) {
            // Never flatten an existing parametric body to fabricate names.
            reference = BodyRef(producer: session.lastBodyWriters[context.body.id] ?? ref.producer,
                bodyID: context.body.id)
            prefix = []
            names = freshNames(for: context.body, session)
        } else {
            do {
                let source = try NativeBodySource(capturing: context.body)
                let base = FeatureNode(name: FloeCADStrings.text("cad.feature.importedBody", "Imported body"),
                    kind: .baseSolid(source: source), outputBodyIDs: [context.body.id])
                names = try source.names(forCurrentFaces: indices, on: context.body, creator: base.id)
                reference = BodyRef(producer: base.id, bodyID: context.body.id)
                prefix = [base]
            } catch {
                return .reply(.failure(422, "Unprocessable Entity", error: "source_preservation_failed",
                    message: error.localizedDescription))
            }
        }
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
            guard let name = names[index], name.isStableFaceIdentity else {
                return .reply(.failure(409, "Conflict", error: "face_identity_unavailable",
                    message: "This face has no preserved source identity. Reselect a named face or edit the existing feature parameters."))
            }
            refs.append(FaceRef(body: reference, creator: name.creator,
                                role: .derived(index: 0), signature: signature, elementName: name))
        }
        return .ok(refs, reference, prefix)
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
