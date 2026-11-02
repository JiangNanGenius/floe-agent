//
//  CADDebugFixtures.swift
//  FloeCADKit
//
//  DEBUG-only deterministic scenario data for the native CAD workbench
//  qualification host. These are FIXED fixture packages, not a general model
//  writer: the app's `--ui-test-cad-*` launch arguments select one scenario,
//  the records are built with the SAME `Sketch`/`FeatureNode` types and
//  document commands the editor uses, and the entire file is absent from a
//  Release build.
//
//  Nothing here substitutes a solver verdict or a rendered UI state. The
//  workbench, constraint solver, feature replay and package save/reopen remain
//  the production path. The only thing the fixture decides is which saved
//  document the UI test starts from (the same way a user's package would).
//

#if DEBUG
import Foundation
import simd

@MainActor
public enum CADDebugFixtures {
    /// One fixed qualification scenario. Keep this list small and explicit:
    /// these are not a public model-editing surface.
    public enum Scenario: Sendable {
        /// Closed arc + spline section, welded and G1-tangent at both
        /// junctions, one driving radius, arc centre Locked, and one real
        /// Extrude consuming it. Report: 2 remaining DOF, no conflict.
        case closedArcSplineLoop
        /// The same section with two contradictory radius dimensions plus an
        /// unrelated satisfied line dimension. The saved system is conflicting;
        /// attribution must name exactly the two radius dimensions.
        case conflictingArcSplineLoop
        /// A mesh-only holed loft with a 30° face-rotation feature, so the
        /// History row can display/edit that real parameter.
        case meshFaceRotation
        /// Open crossing triangles plus one degenerate facet, for the real
        /// cleanup preview and remaining-issues UI. No verdict is injected.
        case meshRepairIssues
    }

    public static func seed(_ scenario: Scenario, in document: FloeCADDocument) throws {
        switch scenario {
        case .closedArcSplineLoop:
            try seedArcSplineLoop(in: document, conflicting: false)
        case .conflictingArcSplineLoop:
            try seedArcSplineLoop(in: document, conflicting: true)
        case .meshFaceRotation:
            try seedMeshFaceRotation(in: document)
        case .meshRepairIssues:
            let positions: [SIMD3<Float>] = [
                [-10, 0, 0], [10, 0, 0], [0, 10, 0],
                [0, 2, -10], [0, 2, 10], [0, -5, 0],
                [20, 0, 0], [21, 0, 0], [22, 0, 0]]
            let render = RenderMesh(positions: positions,
                normals: Array(repeating: [0, 0, 1], count: positions.count),
                indices: [0, 1, 2, 3, 4, 5, 6, 7, 8])
            document.session.perform(AddBodyCommand(
                body: Body(id: BodyID(), name: "Inspection mesh", transform: .identity,
                           primitive: nil, render: render, revision: 1), title: "Add inspection mesh"))
        }
    }

    // Stable ids keep the produced package byte-deterministic for the same
    // scenario (they are local to this document, never global registrations).
    private static let loopSketchUUID =
        UUID(uuidString: "0A11CE00-0000-4000-8000-000000000001")!
    private static let loopArcUUID =
        UUID(uuidString: "0A11CE00-0000-4000-8000-000000000002")!
    private static let loopSplineUUID =
        UUID(uuidString: "0A11CE00-0000-4000-8000-000000000003")!
    private static let cleanLineUUID =
        UUID(uuidString: "0A11CE00-0000-4000-8000-000000000004")!

    // MARK: - Arc + spline section

    /// Seed the exact M02 section used by `CADCurveConstraintSolvingTests`.
    /// The 3-point open spline renders as two straight spans (the production
    /// Catmull-Rom degenerate rule), and placing its middle fit point on the
    /// intersection of the two arc tangents makes the SEEDED geometry already
    /// G1. The UI edit then exercises the real solver from a healthy start.
    private static func seedArcSplineLoop(in document: FloeCADDocument,
                                          conflicting: Bool) throws {
        let sketchID = SketchID(raw: loopSketchUUID)
        let name = conflicting ? "Spline conflict" : "Spline loop"
        document.session.perform(AddSketchCommand(
            sketch: Sketch(id: sketchID, name: name, plane: .ground),
            title: "Add \(name)"))

        let center = SIMD2<Double>(60, 0)
        let radius = 25.0
        let startAngle = 200.0 * Double.pi / 180
        let endAngle = 340.0 * Double.pi / 180
        let start = SketchEntity.arcPoint(center: center, radius: radius, angle: startAngle)
        let end = SketchEntity.arcPoint(center: center, radius: radius, angle: endAngle)
        // Intersection of the 200°/340° tangents: (60, −r / sin 20°).
        let apex = SIMD2<Double>(60, -radius / sin(20 * Double.pi / 180))
        let arc = SketchEntity.arc(id: loopArcUUID, center: center, radius: radius,
                                   startAngle: startAngle, endAngle: endAngle)
        let spline = SketchEntity.spline(id: loopSplineUUID, points: [start, apex, end],
                                         closed: false)
        document.session.perform(AddSketchEntitiesCommand(
            sketchID: sketchID, entities: [arc, spline]))

        let loopConstraints = [
            SketchConstraint(kind: .coincident, refs: [
                ConstraintRef(entityID: loopArcUUID, role: .endpointA),
                ConstraintRef(entityID: loopSplineUUID, role: .endpointA),
            ]),
            SketchConstraint(kind: .coincident, refs: [
                ConstraintRef(entityID: loopArcUUID, role: .endpointB),
                ConstraintRef(entityID: loopSplineUUID, role: .endpointB),
            ]),
            SketchConstraint(kind: .tangent, refs: [
                ConstraintRef(entityID: loopArcUUID, role: .endpointA),
                ConstraintRef(entityID: loopSplineUUID, role: .endpointA),
            ]),
            SketchConstraint(kind: .tangent, refs: [
                ConstraintRef(entityID: loopArcUUID, role: .endpointB),
                ConstraintRef(entityID: loopSplineUUID, role: .endpointB),
            ]),
        ]
        for constraint in loopConstraints {
            document.session.perform(AddSketchConstraintCommand(
                sketchID: sketchID, constraint: constraint))
        }

        if conflicting {
            // A real, exactly satisfied relation OUTSIDE the clash: its label
            // must stay a normal DimensionLabel while the two radius rows are
            // highlighted. This is what makes "not all red" an assertion.
            let line = SketchEntity.line(id: cleanLineUUID,
                                         a: SIMD2<Double>(0, 20),
                                         b: SIMD2<Double>(60, 20))
            document.session.perform(AddSketchEntitiesCommand(
                sketchID: sketchID, entities: [line]))
            document.session.perform(AddSketchDimensionCommand(
                sketchID: sketchID,
                dimension: SketchDimension(
                    kind: .distance,
                    refs: [ConstraintRef(entityID: cleanLineUUID, role: .endpointA),
                           ConstraintRef(entityID: cleanLineUUID, role: .endpointB)],
                    value: 60)))
            // Two driving values for one radius. Stored through the SAME
            // command the editor commits; this is how a saved contradictory
            // package is loaded, not a solver bypass. The production gate
            // still refuses further writes and the production attribution
            // still names the two real dimension ids.
            for value in [radius, 40.0] {
                document.session.perform(AddSketchDimensionCommand(
                    sketchID: sketchID,
                    dimension: SketchDimension(
                        kind: .radius,
                        refs: [ConstraintRef(entityID: loopArcUUID, role: .whole)],
                        value: value)))
            }
            return
        }

        document.session.perform(AddSketchConstraintCommand(
            sketchID: sketchID,
            constraint: SketchConstraint(
                kind: .fixed,
                refs: [ConstraintRef(entityID: loopArcUUID, role: .center)])))
        document.session.perform(AddSketchDimensionCommand(
            sketchID: sketchID,
            dimension: SketchDimension(
                kind: .radius,
                refs: [ConstraintRef(entityID: loopArcUUID, role: .whole)],
                value: radius)))

        // One real solid consumes the section, so the UI test can prove the
        // profile still resolves after the driven edit instead of trusting a
        // label. The seed is inside the closed lens at BOTH radii (the lens is
        // between the arc at y=−r and the spline apex at y≈−2.924r).
        guard let sketch = document.session.document.sketches.first(where: { $0.id == sketchID })
        else {
            throw fixtureError("The seeded arc+spline sketch could not be read back.")
        }
        let seed = SIMD2<Double>(60, -radius * 2.2)
        let profiles = ProfileDetector.profiles(at: seed, in: sketch)
        guard profiles.count == 1,
              profiles[0].sourceEntityIDs == Set([loopArcUUID, loopSplineUUID])
        else {
            throw fixtureError(
                "The seeded arc+spline section did not resolve as exactly one closed profile.")
        }
        _ = try run(document, [
            "op": "feature.extrude",
            "args": [
                "sketchID": sketchID.raw.uuidString,
                "seedPoint": [seed.x, seed.y],
                // Extruded AWAY from the camera-side of the sketch plane so
                // the real solid cannot hide the section the UI test edits;
                // the dependent geometry is still a real solid rebuild.
                "distance": -10.0,
            ],
        ])
        guard document.session.lastEvalErrors.isEmpty else {
            throw fixtureError("The seeded closed profile extruded with feature errors.")
        }
    }

    // MARK: - Mesh face rotation

    /// Same construction as `CADParameterCorrectnessTests.makeMeshRotation`:
    /// two holed rectangles loft into a deliberately mesh-only body (the
    /// supported face-rotation path), then a real `.rotateFace` node is
    /// recorded at 30°. The History panel then shows the production parameter.
    private static func seedMeshFaceRotation(in document: FloeCADDocument) throws {
        let first = try addRectangleSketch(document, y: 0)
        let last = try addRectangleSketch(document, y: 10)
        _ = try run(document, [
            "op": "feature.loft",
            "args": [
                "sections": [
                    ["sketchID": first, "seedPoint": [5, 5]],
                    ["sketchID": last, "seedPoint": [5, 5]],
                ],
            ],
        ])
        guard let source = document.session.document.features.nodes.last else {
            throw fixtureError("The face-rotation fixture loft produced no feature node.")
        }
        guard let current = document.session.document.bodies.first else {
            throw fixtureError("The face-rotation fixture loft produced no body.")
        }
        guard current.brep == nil else {
            throw fixtureError(
                "The face-rotation fixture must exercise the supported mesh-only path.")
        }
        guard let table = document.session.lastFaceTables[current.id],
              let top = table.entries.max(by: { $0.signature.normal.y < $1.signature.normal.y }),
              top.signature.normal.y > 0.99,
              top.elementName?.isStableFaceIdentity == true else {
            throw fixtureError("The face-rotation fixture found no planar top face.")
        }
        let ref = FaceRef(body: BodyRef(producer: source.id, bodyID: current.id),
                          creator: source.id, role: top.role, signature: top.signature,
                          elementName: top.elementName)
        let node = FeatureNode(
            name: "Rotate Face",
            kind: .rotateFace(face: ref,
                              angle: Expr(value: 30 * Double.pi / 180),
                              axis: PointWrapper(SIMD3(1, 0, 0))),
            outputBodyIDs: [current.id])
        document.session.recordAndRebuild([node], title: "Rotate Face")
        guard document.session.lastEvalErrors.isEmpty else {
            throw fixtureError(
                "The seeded 30° face rotation failed to evaluate: "
                    + "\(document.session.lastEvalErrors)")
        }
    }

    private static func addRectangleSketch(_ document: FloeCADDocument,
                                           y: Double) throws -> String {
        let created = try run(document, [
            "op": "sketch.create",
            "args": ["origin": [0, y, 0], "xAxis": [1, 0, 0], "yAxis": [0, 0, -1]],
        ])
        guard let id = created["sketchID"] as? String else {
            throw fixtureError("sketch.create returned no sketchID.")
        }
        _ = try run(document, [
            "op": "sketch.addEntities",
            "args": [
                "sketchID": id,
                "entities": [
                    ["kind": "rect", "min": [0, 0], "max": [40, 20]],
                    ["kind": "rect", "min": [10, 5], "max": [30, 15]],
                ],
            ],
        ])
        return id
    }

    // MARK: - Explicit fault-injected inputs

    /// Deliberately break ONE saved face-material binding so the X31 negative
    /// UI fixture starts from an explicitly malformed document instead of
    /// relying on a normal reopen losing its face ranges.
    ///
    /// This is an INPUT fault injection, not an exporter/renderer override: it
    /// writes an ordinary (undoable) material command whose stored signature
    /// names a face this body does not have. The product still resolves the
    /// binding, builds its own coverage receipt and decides what to paint. The
    /// whole file, including this helper, is absent from Release builds.
    public static func injectStaleFaceBinding(bodyID: UUID,
                                              in document: FloeCADDocument) throws {
        guard let body = document.session.document.body(with: BodyID(raw: bodyID)),
              let binding = body.materialFaceBindings.first else {
            throw fixtureError("The stale-face fixture needs a body with a saved face material.")
        }
        let wrong = FaceSignature(
            kind: .planar,
            normal: SIMD3(0, 1, 0),
            centroid: SIMD3(10_000, 10_000, 10_000),
            area: 1,
            planeOffset: 10_000)
        var bindings = body.materialFaceBindings
        bindings[0] = CADFaceMaterialBinding(
            key: CADFaceKey(signature: wrong,
                            capturedIndex: binding.key.capturedIndex),
            material: binding.material,
            assignedAt: binding.assignedAt)
        document.session.perform(SetMaterialAppearanceCommand(
            title: "Inject stale face material",
            bodyIDs: [body.id],
            after: [body.id: .init(material: body.material,
                                   faceBindings: bindings)],
            document: document.session.document))
    }

    // MARK: - Native App UI scheduling seam

    /// Installs the existing `CADMeshService.testHeavyComputeProbe` for the
    /// native App's `--ui-test-cad-mesh-panel-flow` UI qualification. The
    /// closure may only delay real detached compute; it must never synthesize
    /// geometry. `nil` removes the seam. This whole file is DEBUG-only, so a
    /// Release build contains neither this helper nor the probe call site.
    public static func installMeshPanelComputeProbe(
        _ probe: (@Sendable (String, Int) -> Void)?
    ) {
        CADMeshService.testHeavyComputeProbe = probe
    }

    /// DEBUG-only seam for the E31 UI fixture: the closure runs on the real
    /// import parse thread at its first large budget charge (charged bytes so
    /// far), BEFORE the array/buffer is allocated. It lets the fixture cancel
    /// deterministically during real work. Never installed in production.
    public static func installImportParseCheckpoint(
        _ probe: (@Sendable (Int) -> Void)?
    ) {
        MeshImportKit.testParseCheckpoint = probe.map { callback in
            { checkpoint in callback(checkpoint.chargedBytes) }
        }
    }

    /// E31-R2: install the REAL exact (STEP/IGES) parse checkpoint. The probe
    /// fires on the worker (begin/locked/read/body) and on the document actor
    /// (commit/committed); it never replaces the parser or the commit.
    public static func installExactImportCheckpoint(
        _ probe: (@Sendable (CADExactImportCheckpoint) -> Void)?
    ) {
        CADExactImportService.testCheckpoint = probe
    }

    /// E31-R2 manual-import UI trigger: the App fixture seeds a real file and
    /// asks the real Workbench editor to import it exactly as the Import menu
    /// does (the system picker cannot be driven by XCUITest). DEBUG only.
    public static var pendingManualImportPath: String?

    public static func consumePendingManualImportPath() -> String? {
        let path = pendingManualImportPath
        pendingManualImportPath = nil
        return path
    }

    // MARK: - E26 IGES open-surface native UI fixture

    /// DEBUG-only native UI fixture support: real IGES bytes for ONE
    /// standalone exact face taken from the native box primitive. The bytes
    /// come from OCCT's own IGES writer (`brepMode: true`), so the App's
    /// import proposal reads a legitimate open-sheet exchange file — never a
    /// hand-authored string, a renamed mesh or a copied glTF payload.
    ///
    /// `offset` moves the donor box so the sheet sits clear of the fixture's
    /// plate in the viewport; it changes only the fixture's placement, not
    /// the kind of geometry. The temporary file lives for this call only and
    /// is removed before returning, so nothing is written into the user's
    /// workspace here. This file is DEBUG-only; Release has neither this
    /// helper nor any call site.
    public static func openSurfaceIGES(width: Double = 60,
                                       depth: Double = 40,
                                       height: Double = 4,
                                       offset: SIMD3<Double> = .zero) throws -> Data {
        let placement = Transform3D(
            translation: offset,
            rotation: .init(ix: 0, iy: 0, iz: 0, r: 1),
            scale: 1)
        guard let box = OCCTKernel.primitiveShape(
            .box(width: width, depth: depth, height: height),
            placement: placement) else {
            throw fixtureError("The OCCT box primitive for the IGES UI fixture was not created.")
        }
        guard let face = OCCTKernel.debugStandaloneFace(from: box) else {
            throw fixtureError("The OCCT fixture box yielded no standalone open face.")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-e26-open-surface-\(UUID().uuidString).igs")
        defer { try? FileManager.default.removeItem(at: url) }
        guard OCCTKernel.debugWriteIGES([face], to: url, brepMode: true) else {
            throw fixtureError("OCCT's IGES writer refused the open-surface UI fixture.")
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            throw fixtureError("The IGES open-surface UI fixture produced no bytes.")
        }
        return data
    }

    // MARK: - Helpers

    private static func run(_ document: FloeCADDocument,
                            _ object: [String: Any]) throws -> [String: Any] {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw fixtureError("The debug fixture produced a non-JSON command.")
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        let outcome = document.executeJSON(data)
        guard outcome.isOK else {
            throw fixtureError(
                "Fixture command failed (\(outcome.status) "
                    + "\(outcome.errorCode ?? "")): \(outcome.message ?? "")")
        }
        guard let reply = (try? JSONSerialization.jsonObject(with: outcome.payload))
            as? [String: Any] else {
            throw fixtureError("The fixture command reply was not a JSON object.")
        }
        return reply
    }

    private static func fixtureError(_ message: String) -> CADDocumentError {
        CADDocumentError(code: "fixture_failed", message: message)
    }
}
#endif
