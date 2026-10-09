// SPDX-License-Identifier: MPL-2.0
// FloeApp — deterministic native CAD fixture for simulator/CUA acceptance.
//
// `-ui-testing --ui-test-cad-fixture` opens the REAL CAD workbench on a
// synthetic 100×60×10 mm plate with a fully internal Ø10 through-hole, built
// through the same typed command vocabulary the product uses. Debug only:
// there is no release code path that can create or open this fixture, and no
// secret/credential configuration is involved.
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
                FloeCADWorkbenchView(document: document)
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
