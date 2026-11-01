// SPDX-License-Identifier: MPL-2.0
// FloeApp — deterministic native CAD fixture for simulator/CUA acceptance.
//
// `-ui-testing --ui-test-cad-fixture` opens the REAL CAD workbench on a
// synthetic 100×60×10 mm plate with a fully internal Ø10 through-hole, built
// through the same typed command vocabulary the product uses. Debug only:
// there is no release code path that can create or open this fixture, and no
// secret/credential configuration is involved.
//
// `--ui-test-cad-assembly-interference` keeps that real document but replaces
// the two default separated occurrences with three real occurrences for the
// native interference inspector UI flow (A/B overlap, C separate).
//
// `--ui-test-cad-hole-form` reuses this host for H1 native hole FORM acceptance:
// the FloeCAD fixture seeds a real unconsumed placement circle and arms the
// production create/tap route, so the shipped HoleOptionsSheet and the real
// History edit/save/reopen path are what the UI test exercises.
//

#if DEBUG && canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCAD

enum CADQualificationFixture {
    /// Builds (or rebuilds, deterministically) the qualification package and
    /// opens it. Expected volume: 60000 − 250π mm³.
    @MainActor
    static func openPlateHole(reopen: Bool = false) async throws -> FloeCADDocument {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
            .appendingPathComponent("FloeAgent/CADFixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("plate-100x60x10.floecad")
        if reopen {
            // Lifecycle qualification must reopen the exact owned package,
            // never recreate a seed and mistake it for recovered data.
            return try await FloeCADDocument.open(at: url)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let document = try await FloeCADDocument.create(at: url, name: "PlateHole")
        do {
            let plateSketch = try run(document, #"{"op":"sketch.create","args":{"name":"Plate"}}"#)
            let plateSketchID = try text(plateSketch, "sketchID")
            try run(document, """
            {"op":"sketch.addEntities","args":{"sketchID":"\(plateSketchID)",
             "entities":[{"kind":"rect","min":[0,0],"max":[100,60]}]}}
            """)
            let extrude = try run(document, """
            {"op":"feature.extrude","args":{"sketchID":"\(plateSketchID)","seedPoint":[50,30],"distance":10}}
            """)
            guard let bodyID = (extrude["producedBodyIDs"] as? [String])?.first else {
                throw CADDocumentError(code: "fixture_failed", message: "The plate extrude produced no body.")
            }
            let holeSketch = try run(document, #"{"op":"sketch.create","args":{"name":"Hole"}}"#)
            let holeSketchID = try text(holeSketch, "sketchID")
            try run(document, """
            {"op":"sketch.addEntities","args":{"sketchID":"\(holeSketchID)",
             "entities":[{"kind":"circle","center":[50,30],"radius":5}]}}
            """)
            try run(document, """
            {"op":"feature.extrude","args":{"sketchID":"\(holeSketchID)","seedPoint":[50,30],
             "distance":40,"symmetric":true,"boolean":"subtract","booleanTargets":["\(bodyID)"]}}
            """)
            // Real assembly occurrences of the same immutable source body
            // (shared mesh/B-rep, own transforms). The default two are
            // separated so the primary CUA can see placement, selection and
            // hide/update behavior. The interference launch argument instead
            // places the documented three-instance subset used by the native
            // assembly interference UI flow: A at the origin, B overlapping by
            // 50 mm along X, and C at X=250 (100 mm clear of B's right edge,
            // 150 mm clear of A). The actual service result is one positive
            // common (A/B) and two clearances.
            let assembly = CADAssemblyService(document: document)
            let interferenceFixture = ProcessInfo.processInfo.arguments
                .contains("--ui-test-cad-assembly-interference")
            if ProcessInfo.processInfo.arguments.contains("--ui-test-cad-uninstanced") {
                // X20 exercises the genuine first face pick on an unpainted
                // source body. Keep the real holed B-rep but add no occurrence
                // or face material, so the UI cannot pass via a painted group.
            } else if interferenceFixture {
                let placements: [(name: String, x: Double)] = [
                    ("Plate A", 0.0),
                    ("Plate B", 50.0),
                    ("Plate C", 250.0),
                ]
                for placement in placements {
                    let reply = assembly.handle(action: "addInstance", args: [
                        "bodyID": bodyID,
                        "name": placement.name,
                        "transform": ["position": [placement.x, 0.0, 0.0]],
                    ])
                    guard reply["ok"] as? Bool == true else {
                        throw CADDocumentError(
                            code: "fixture_assembly_failed",
                            message: "The interference fixture assembly instances could not be placed.")
                    }
                }
            } else {
                let first = assembly.handle(action: "addInstance", args: [
                    "bodyID": bodyID,
                    "name": "Plate A",
                    "transform": ["position": [0.0, 0.0, 0.0]],
                ])
                let second = assembly.handle(action: "addInstance", args: [
                    "bodyID": bodyID,
                    "name": "Plate B",
                    "transform": ["position": [140.0, 0.0, 0.0]],
                ])
                guard first["ok"] as? Bool == true, second["ok"] as? Bool == true else {
                    throw CADDocumentError(code: "fixture_assembly_failed",
                                           message: "The fixture assembly instances could not be placed.")
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-test-cad-shared-sheet") {
                let sheet = CADDrawingService(document: document).handle(action: "multiViewSheet", args: [
                    "bodyID": bodyID, "title": "Plate drawing", "paper": "a3",
                ])
                guard sheet["ok"] as? Bool == true else {
                    throw CADDocumentError(code: "fixture_drawing_failed",
                                           message: sheet["message"] as? String ?? "The fixture sheet could not be created.")
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-test-cad-animation") {
                let duration = ProcessInfo.processInfo.arguments
                    .contains("--ui-test-cad-animation-long") ? 10.0 : 0.5
                let clip = try document.createAnimationClip(name: "Camera orbit", duration: duration)
                let track = try document.addAnimationTrack(clipID: clip.id, target: .camera)
                _ = try document.setAnimationKeyframe(
                    clipID: clip.id, trackID: track.id, time: 0,
                    // Animation cameras use presentation metres; geometry
                    // and assembly placement above use model millimetres.
                    camera: CADAnimationCameraValue(target: SIMD3(0.1, 0, 0.03), distance: 0.4,
                                                    azimuthRadians: 0.5, elevationRadians: 0.4,
                                                    fovYDegrees: 60))
                _ = try document.setAnimationKeyframe(
                    clipID: clip.id, trackID: track.id, time: duration,
                    camera: CADAnimationCameraValue(target: SIMD3(0.1, 0, 0.03), distance: 0.4,
                                                    azimuthRadians: 0.7, elevationRadians: 0.4,
                                                    fovYDegrees: 60))
            }
            let save = await document.save()
            guard save.succeeded else {
                throw CADDocumentError(code: "fixture_save_failed",
                                       message: save.error ?? "The fixture could not be saved.")
            }
            return document
        } catch {
            document.close()
            throw error
        }
    }

    /// M02 native UI fixture: a real closed arc+spline section (welded and
    /// G1-tangent at both junctions) with one driving radius, a locked arc
    /// centre and one real Extrude consuming it. This is a saved package built
    /// through `CADDebugFixtures`, not a UI-only mock; the workbench, solver
    /// and dependent feature rebuild are the production ones.
    @MainActor
    static func openSplineLoop() async throws -> FloeCADDocument {
        try await openSeededFixture(fileName: "sketch-loop.floecad",
                                    name: "Spline loop",
                                    scenario: .closedArcSplineLoop)
    }

    /// M06 native UI fixture: the same section with two contradictory radius
    /// dimensions plus one unrelated satisfied line dimension. The conflict is
    /// a real saved model state; its attribution/highlight is production.
    @MainActor
    static func openSplineConflict() async throws -> FloeCADDocument {
        try await openSeededFixture(fileName: "sketch-conflict.floecad",
                                    name: "Spline conflict",
                                    scenario: .conflictingArcSplineLoop)
    }

    /// M19 native UI fixture: a mesh-only holed loft with a real 30°
    /// `.rotateFace` feature. `reset` re-seeds the deterministic package; the
    /// second launch opens the first launch's saved 45° package unchanged.
    @MainActor
    static func openFaceRotation(reset: Bool) async throws -> FloeCADDocument {
        let url = try fixtureURL("face-rotation.floecad")
        if reset {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } else if FileManager.default.fileExists(atPath: url.path) {
            return try await FloeCADDocument.open(at: url)
        }
        guard reset else {
            throw CADDocumentError(
                code: "fixture_missing",
                message: "The saved face-rotation fixture is missing; the first launch must reseed it.")
        }
        let document = try await FloeCADDocument.create(at: url, name: "Face rotation")
        do {
            try CADDebugFixtures.seed(.meshFaceRotation, in: document)
            let save = await document.save()
            guard save.succeeded else {
                throw CADDocumentError(code: "fixture_save_failed",
                                       message: save.error ?? "The fixture could not be saved.")
            }
            return document
        } catch {
            document.close()
            throw error
        }
    }

    /// E29/X31 native OBJ options coverage fixture: two real saved bodies where
    /// one body carries a face-material binding whose saved face range is no
    /// longer trusted in the reopened generation. The package is saved and
    /// reopened exactly like a user reopening a design, so the app's own shared
    /// coverage receipt reports the real partial state ("face material ranges
    /// are stale") and the real OBJ preflight falls back with its own warning.
    /// Nothing here fabricates an invalid mesh or a renderer verdict: the two
    /// bodies are ordinary Extrudes built through the typed command vocabulary,
    /// and the face material is applied through `CADMaterialService` with a
    /// fresh `query_token` from the real faces query.
    @MainActor
    static func openOBJCoverage() async throws -> FloeCADDocument {
        let url = try fixtureURL("obj-coverage.floecad")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let document = try await FloeCADDocument.create(at: url, name: "OBJ coverage")
        do {
            let plate = try makeExtrudedBody(document, name: "Plate",
                                             min: [0, 0], max: [100, 60], distance: 10)
            _ = try makeExtrudedBody(document, name: "Block",
                                     min: [130, 0], max: [150, 20], distance: 10)
            let top = try horizontalPlanarFace(of: plate, in: document)
            let reply = CADMaterialService(document: document).handle(
                action: "applyFaces",
                args: ["bodyID": plate,
                       "faces": [top.index],
                       "query_token": top.token,
                       "color": [0.82, 0.24, 0.18, 1.0]])
            guard reply["ok"] as? Bool == true else {
                throw CADDocumentError(
                    code: reply["error"] as? String ?? "fixture_material_failed",
                    message: reply["message"] as? String
                        ?? "The OBJ coverage fixture could not apply its face material.")
            }
            let save = await document.save()
            guard save.succeeded else {
                throw CADDocumentError(code: "fixture_save_failed",
                                       message: save.error ?? "The fixture could not be saved.")
            }
        } catch {
            document.close()
            throw error
        }
        document.close()
        return try await FloeCADDocument.open(at: url)
    }

    /// E29/X31 native OBJ refusal fixture: one real body whose material was
    /// applied through the production material service with an emission
    /// strength the service accepts (0…100) but the OBJ bundle correctly
    /// refuses to represent (> 1). The shared coverage receipt and the real
    /// preflight must both show the loss before any file exists.
    @MainActor
    static func openOBJRefusal() async throws -> FloeCADDocument {
        let url = try fixtureURL("obj-refusal.floecad")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let document = try await FloeCADDocument.create(at: url, name: "OBJ refusal")
        do {
            let plate = try makeExtrudedBody(document, name: "Plate",
                                             min: [0, 0], max: [100, 60], distance: 10)
            let reply = CADMaterialService(document: document).handle(
                action: "apply",
                args: ["bodyID": plate,
                       "color": [0.8, 0.3, 0.2, 1.0],
                       "emissive": [1.0, 1.0, 1.0],
                       "emissive_strength": 2.0])
            guard reply["ok"] as? Bool == true else {
                throw CADDocumentError(
                    code: reply["error"] as? String ?? "fixture_material_failed",
                    message: reply["message"] as? String
                        ?? "The OBJ refusal fixture could not apply its material.")
            }
            let save = await document.save()
            guard save.succeeded else {
                throw CADDocumentError(code: "fixture_save_failed",
                                       message: save.error ?? "The fixture could not be saved.")
            }
            return document
        } catch {
            document.close()
            throw error
        }
    }

    /// One rectangular plate Extrude through the same typed command vocabulary
    /// the product uses. Returns the produced body id.
    @MainActor
    private static func makeExtrudedBody(_ document: FloeCADDocument, name: String,
                                         min: [Double], max: [Double],
                                         distance: Double) throws -> String {
        let sketch = try run(document,
                             #"{"op":"sketch.create","args":{"name":"\#(name)"}}"#)
        let sketchID = try text(sketch, "sketchID")
        try run(document, """
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[\(min[0]),\(min[1])],
                      "max":[\(max[0]),\(max[1])]}]}}
        """)
        let extrude = try run(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)",
         "seedPoint":[\((min[0] + max[0]) / 2),\((min[1] + max[1]) / 2)],
         "distance":\(distance)}}
        """)
        guard let bodyID = (extrude["producedBodyIDs"] as? [String])?.first else {
            throw CADDocumentError(code: "fixture_failed",
                                   message: "The \(name) Extrude produced no body.")
        }
        return bodyID
    }

    /// The largest horizontal planar face (normal along the sketch axis),
    /// with the exact query generation token the material service requires for
    /// an index-based face application. This is the same query/token contract
    /// the Material inspector uses; the index alone is never trusted as
    /// identity, and the normal's sign is kernel orientation (not identity).
    @MainActor
    private static func horizontalPlanarFace(of bodyID: String,
                                             in document: FloeCADDocument) throws
        -> (index: Int, token: String) {
        let outcome = document.nativeQueryJSON(["scope": "faces"])
        guard outcome.isOK,
              let object = (try? JSONSerialization.jsonObject(with: outcome.payload))
                as? [String: Any],
              let rows = object["rows"] as? [[String: Any]] else {
            throw CADDocumentError(
                code: outcome.errorCode ?? "fixture_face_query_failed",
                message: outcome.message ?? "The fixture could not query the document faces.")
        }
        func number(_ value: Any?) -> Double? {
            (value as? NSNumber)?.doubleValue
        }
        let own = rows.filter { row in
            guard let id = row["bodyID"] as? String else { return false }
            return id.caseInsensitiveCompare(bodyID) == .orderedSame
        }
        let tops = own.filter { row in
            guard (row["kind"] as? String) == "planar",
                  let normal = row["normal"] as? [Any], normal.count == 3,
                  let z = number(normal[2]) else { return false }
            return abs(z) > 0.99
        }
        guard let top = tops.max(by: { lhs, rhs in
            (number(lhs["areaMM2"]) ?? 0) < (number(rhs["areaMM2"]) ?? 0)
        }),
        let index = (top["index"] as? NSNumber)?.intValue,
        let token = top["query_token"] as? String else {
            throw CADDocumentError(code: "fixture_face_query_failed",
                                   message: "The fixture found no top planar face to paint.")
        }
        return (index, token)
    }

    @MainActor
    private static func openSeededFixture(
        fileName: String, name: String, scenario: CADDebugFixtures.Scenario
    ) async throws -> FloeCADDocument {
        let url = try fixtureURL(fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let document = try await FloeCADDocument.create(at: url, name: name)
        do {
            try CADDebugFixtures.seed(scenario, in: document)
            let save = await document.save()
            guard save.succeeded else {
                throw CADDocumentError(code: "fixture_save_failed",
                                       message: save.error ?? "The fixture could not be saved.")
            }
            return document
        } catch {
            document.close()
            throw error
        }
    }

    /// Each scenario owns its own fixed synthetic package under the app's
    /// Application Support; nothing global is reset or shared.
    @MainActor
    private static func fixtureURL(_ fileName: String) throws -> URL {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
            .appendingPathComponent("FloeAgent/CADFixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName)
    }

    @discardableResult
    @MainActor
    private static func run(_ document: FloeCADDocument, _ json: String) throws -> [String: Any] {
        let outcome = document.executeJSON(Data(json.utf8))
        guard outcome.isOK,
              let object = (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any] else {
            throw CADDocumentError(code: outcome.errorCode ?? "fixture_failed",
                                   message: outcome.message ?? "Fixture operation failed: \(json)")
        }
        return object
    }

    @MainActor
    private static func text(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String else {
            throw CADDocumentError(code: "fixture_failed", message: "Fixture reply lacks \(key).")
        }
        return value
    }
}

/// The harness view the launch argument presents. It owns the fixture document
/// for the lifetime of the scene.
struct CADWorkbenchFixtureHarness: View {
    @State private var document: FloeCADDocument?
    @State private var error: String?

    var body: some View {
        Group {
            if let document {
                // Mirror the real FilePreview host: the workbench's title and
                // toolbar chrome (undo/redo, views, history, variables, items,
                // import/export, tools, settings) only render inside a
                // navigation context. Every real host embeds the workbench in
                // a NavigationStack (inspector column, thread sheet, IDE tab,
                // workspace-picker sheet); the fixture must present the SAME
                // chrome or CUA accepts a workbench that does not exist in
                // the product. The editor sets its own inline navigation
                // title (the document name), exactly as it does in-product.
                NavigationStack {
                    // No identifier on this container: an accessibility id
                    // on a view with children merges the whole workbench into
                    // one element and hides the tool palette from tests.
                    // The SAME Floe-level chrome modifier the production
                    // FilePreview host applies (save status + fullscreen) is
                    // present here, so CUA always reviews the product
                    // surface, not a reduced copy.
                    FloeCADWorkbenchView(document: document)
                        .modifier(FloeCADHostChrome(document: document))
                }
            } else if let error {
                VStack(spacing: 12) {
                    Text("CAD fixture failed")
                        .font(.headline)
                    Text(error)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            } else {
                ProgressView("Preparing CAD fixture…")
            }
        }
        // Reuse the canonical iPad for a narrow, large-text layout check of
        // the same production workbench, without creating another Simulator.
        .frame(maxWidth: ProcessInfo.processInfo.arguments.contains("--ui-test-cad-compact") ? 390 : .infinity)
        .transformEnvironment(\.horizontalSizeClass) { value in
            if ProcessInfo.processInfo.arguments.contains("--ui-test-cad-compact") {
                value = .compact
            }
        }
        .transformEnvironment(\.dynamicTypeSize) { value in
            if ProcessInfo.processInfo.arguments.contains("--ui-test-cad-large-text") {
                value = .accessibility1
            }
        }
        .accessibilityIdentifier("CADFixtureHarness")
        .task {
            guard document == nil, error == nil else { return }
            do {
                let arguments = ProcessInfo.processInfo.arguments
                if arguments.contains("--ui-test-cad-hole-form") {
                    // H1 mechanical-hole FORM acceptance. The FloeCAD fixture
                    // seeds a real unconsumed placement circle, arms the real
                    // `beginCreate(.hole)` + viewport-tap route, and presents
                    // the production HoleOptionsSheet. A package that already
                    // contains the saved hole opens without arming a new draft,
                    // so the same test can reopen it through History.
                    document = try await CADHoleFormFixture.open(
                        reset: arguments.contains("--ui-test-cad-hole-form-reset"))
                } else if arguments.contains("--ui-test-cad-sketch-loop") {
                    document = try await CADQualificationFixture.openSplineLoop()
                } else if arguments.contains("--ui-test-cad-sketch-conflict") {
                    document = try await CADQualificationFixture.openSplineConflict()
                } else if arguments.contains("--ui-test-cad-face-rotation") {
                    document = try await CADQualificationFixture.openFaceRotation(
                        reset: arguments.contains("--ui-test-cad-face-rotation-reset"))
                } else if arguments.contains("--ui-test-cad-obj-coverage") {
                    // E29/X31 native OBJ options: real mixed valid/stale
                    // material-range receipt, saved and reopened.
                    document = try await CADQualificationFixture.openOBJCoverage()
                } else if arguments.contains("--ui-test-cad-obj-refusal") {
                    // E29/X31 native OBJ options: real unsupported-material
                    // refusal from the production preflight.
                    document = try await CADQualificationFixture.openOBJRefusal()
                } else {
                    document = try await CADQualificationFixture.openPlateHole(
                        reopen: arguments.contains("--ui-test-cad-reopen"))
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
#endif
