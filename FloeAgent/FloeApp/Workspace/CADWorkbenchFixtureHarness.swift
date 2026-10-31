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

#if DEBUG && canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCAD

enum CADQualificationFixture {
    /// Builds (or rebuilds, deterministically) the qualification package and
    /// opens it. Expected volume: 60000 − 250π mm³.
    @MainActor
    static func openPlateHole() async throws -> FloeCADDocument {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
            .appendingPathComponent("FloeAgent/CADFixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("plate-100x60x10.floecad")
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
            if interferenceFixture {
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
                let clip = try document.createAnimationClip(name: "Camera orbit", duration: 0.5)
                let track = try document.addAnimationTrack(clipID: clip.id, target: .camera)
                _ = try document.setAnimationKeyframe(
                    clipID: clip.id, trackID: track.id, time: 0,
                    camera: CADAnimationCameraValue(target: SIMD3(100, 0, 30), distance: 400,
                                                    azimuthRadians: 0.5, elevationRadians: 0.4,
                                                    fovYDegrees: 60))
                _ = try document.setAnimationKeyframe(
                    clipID: clip.id, trackID: track.id, time: 0.5,
                    camera: CADAnimationCameraValue(target: SIMD3(100, 0, 30), distance: 400,
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
                document = try await CADQualificationFixture.openPlateHole()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
#endif
