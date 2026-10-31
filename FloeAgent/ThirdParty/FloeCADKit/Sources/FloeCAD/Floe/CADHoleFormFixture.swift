//
//  CADHoleFormFixture.swift
//  FloeCADKit
//
//  DEBUG-only H1 native mechanical-hole FORM fixture.
//
//  This is not a second hole implementation and it does not decide a verdict.
//  It builds one real saved package through the production command vocabulary
//  (plate Extrude + one unconsumed circular placement sketch on the plate's top
//  plane), then drives the REAL `EditorViewModel.beginCreate(.hole)` and
//  `handle(.tap(ray:))` path with a ray derived from the sketch's own
//  `SketchPlane.toWorld`/`normal`. The production `HoleOptionsSheet` is what
//  presents; the person/test chooses the type, values and direction and commits
//  through `commitHole`'s ordinary graph transaction.
//
//  A package that already contains the saved hole is reopened unchanged and is
//  NOT armed with a draft, so the same UI test can reopen it in a new process
//  and edit the hole through its real History entry. The small witness JSON
//  records the exact source/profile/body ids and the feature ids that exist at
//  launch; it is engineering evidence in the app's own sandbox, never a product
//  success surface and never user data.
//

#if DEBUG
import Foundation
import simd

@MainActor
public enum CADHoleFormFixture {
    /// The fixed package this fixture owns. `--ui-test-cad-hole-form-reset`
    /// removes only this file; no other fixture or user document is touched.
    public static let packageFileName = "hole-form.floecad"
    public static let witnessFileName = "hole-form-witness.json"

    private static let documentName = "Hole form"
    private static let plateSketchName = "Plate"
    private static let holeSketchName = "Hole placement"
    private static let circleCenter = SIMD2<Double>(50, 30)
    private static let circleRadius = 5.0
    private static let plateThickness = 10.0

    /// Opens (or seeds) the H1 form fixture. When the package has no hole yet
    /// the returned document is already armed with a real `HoleDraft` produced
    /// by the production create/tap route. When a hole exists the document is
    /// left untouched for the real History edit entry.
    public static func open(reset: Bool) async throws -> FloeCADDocument {
        let directory = try fixtureDirectory()
        let url = directory.appendingPathComponent(packageFileName)
        let witnessURL = directory.appendingPathComponent(witnessFileName)

        let document: FloeCADDocument
        if reset {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            document = try await seed(at: url)
        } else if FileManager.default.fileExists(atPath: url.path) {
            document = try await FloeCADDocument.open(at: url)
        } else {
            document = try await seed(at: url)
        }

        do {
            try await prepare(document, witnessURL: witnessURL)
            return document
        } catch {
            document.close()
            throw error
        }
    }

    // MARK: - Seed

    private static func seed(at url: URL) async throws -> FloeCADDocument {
        let document = try await FloeCADDocument.create(at: url, name: documentName)
        do {
            let plateSketch = try run(document, #"{"op":"sketch.create","args":{"name":"Plate"}}"#)
            let plateSketchID = try text(plateSketch, "sketchID")
            try run(document, """
            {"op":"sketch.addEntities","args":{"sketchID":"\(plateSketchID)",
             "entities":[{"kind":"rect","min":[0,0],"max":[100,60]}]}}
            """)
            let extrude = try run(document, """
            {"op":"feature.extrude","args":{"sketchID":"\(plateSketchID)",
             "seedPoint":[50,30],"distance":\(plateThickness)}}
            """)
            guard let bodyIDs = extrude["producedBodyIDs"] as? [String], bodyIDs.count == 1 else {
                throw fixtureError("The plate Extrude did not produce exactly one body.")
            }

            // The placement circle lives on the plate's top plane. Both axes
            // and the origin go through the ordinary explicit-plane command;
            // no screen-space position or guessed axis is used.
            let holeSketch = try run(document, """
            {"op":"sketch.create","args":{"name":"\(holeSketchName)",
             "origin":[0,\(plateThickness),0],"xAxis":[1,0,0],"yAxis":[0,0,-1]}}
            """)
            let holeSketchID = try text(holeSketch, "sketchID")
            let entities = try run(document, """
            {"op":"sketch.addEntities","args":{"sketchID":"\(holeSketchID)",
             "entities":[{"kind":"circle","center":[\(circleCenter.x),\(circleCenter.y)],
                          "radius":\(circleRadius)}]}}
            """)
            guard let entityIDs = entities["entityIDs"] as? [String], entityIDs.count == 1 else {
                throw fixtureError("The placement sketch did not report exactly one circle entity.")
            }

            let save = await document.save()
            guard save.succeeded else {
                throw fixtureError(save.error ?? "The H1 hole-form fixture package could not be saved.")
            }
            return document
        } catch {
            document.close()
            throw error
        }
    }

    // MARK: - Real form route

    private static func prepare(_ document: FloeCADDocument, witnessURL: URL) async throws {
        let model = document.viewModel()
        let state = document.session.document

        guard let holeSketch = state.sketches.first(where: { $0.name == holeSketchName }) else {
            throw fixtureError("The placement sketch is missing from the H1 fixture package.")
        }
        guard let circle = holeSketch.entities.compactMap({ entity -> (UUID, SIMD2<Double>, Double)? in
            guard case let .circle(id, center, radius) = entity else { return nil }
            return (id, center, radius)
        }).first(where: {
            abs($0.1.x - circleCenter.x) < 1e-9
                && abs($0.1.y - circleCenter.y) < 1e-9
                && abs($0.2 - circleRadius) < 1e-9
        }) else {
            throw fixtureError("The placement sketch does not contain the seeded circle.")
        }
        guard let body = state.bodies.first(where: { $0.brep != nil }) else {
            throw fixtureError("The H1 fixture package has no analytic target body.")
        }
        let existingHoles = state.features.nodes.compactMap { node -> (FeatureID, HoleSpec)? in
            guard case let .hole(_, _, _, spec) = node.kind else { return nil }
            return (node.id, spec)
        }

        if existingHoles.isEmpty {
            guard state.bodies.filter({ $0.brep != nil }).count == 1 else {
                throw fixtureError("The create-form fixture must start with exactly one analytic body.")
            }
            model.beginCreate(.hole)

            let plane = holeSketch.plane
            let world = plane.toWorld(circle.1)
            let normal = simd_normalize(plane.normal)
            let origin = world + normal * 200
            let ray = Ray(
                origin: SIMD3<Float>(Float(origin.x), Float(origin.y), Float(origin.z)),
                direction: SIMD3<Float>(Float(-normal.x), Float(-normal.y), Float(-normal.z)))
            model.handle(.tap(ray: ray))

            guard model.pendingCreateTool == nil else {
                throw fixtureError("The real create route left an unconsumed pending tool.")
            }
            guard let draft = model.holeDraft else {
                throw fixtureError(
                    "The real beginCreate/tap route did not produce a Hole draft"
                        + (model.errorMessage.map { ": \($0)" } ?? "."))
            }
            guard draft.sketchID == holeSketch.id else {
                throw fixtureError("The Hole draft names a different source sketch.")
            }
            guard Set(draft.profileRef.entityIDs) == Set([circle.0]) else {
                throw fixtureError("The Hole draft names different profile entities.")
            }
            guard draft.plane == holeSketch.plane else {
                throw fixtureError("The Hole draft names a different placement plane.")
            }
            guard let seed = draft.profileRef.seedPoint,
                  abs(seed.x - circle.1.x) < 1e-9,
                  abs(seed.y - circle.1.y) < 1e-9
            else {
                throw fixtureError("The Hole draft seed point does not match the placement circle.")
            }
            guard draft.targetBodyID == body.id else {
                throw fixtureError("The Hole draft names a different target body.")
            }
            guard abs(draft.pilotRadius - circle.2) < 1e-9 else {
                throw fixtureError("The Hole draft pilot radius does not match the placement circle.")
            }
            guard draft.type == .throughAll, draft.reversed == false else {
                throw fixtureError("The Hole draft did not start from the sheet's default type/direction.")
            }
            guard !document.session.document.features.nodes.contains(where: {
                if case .hole = $0.kind { return true }
                return false
            }) else {
                throw fixtureError("The tap created a hole feature; the form must open on a draft only.")
            }
        } else {
            guard existingHoles.count == 1 else {
                throw fixtureError("The reopened H1 fixture must contain exactly one saved hole.")
            }
            guard model.holeDraft == nil, model.editingHoleFeatureID == nil else {
                throw fixtureError("A saved-hole reopen must not arm a second draft.")
            }
        }

        try writeWitness(document: document,
                         witnessURL: witnessURL,
                         holeSketch: holeSketch,
                         circle: circle,
                         draft: model.holeDraft,
                         holes: existingHoles)
    }

    // MARK: - Witness

    private nonisolated struct FixtureWitness: Codable {
        nonisolated struct Draft: Codable {
            let sketchID: String
            let profileEntityIDs: [String]
            let targetBodyID: String?
            let pilotRadius: Double
            let type: String
            let depth: Double
            let counterboreDiameter: Double
            let counterboreDepth: Double
            let countersinkDiameter: Double
            let countersinkAngle: Double
            let reversed: Bool
        }

        nonisolated struct SavedHole: Codable {
            let featureID: String
            let type: String
            let depth: Double?
            let counterboreDiameter: Double?
            let counterboreDepth: Double?
            let countersinkDiameter: Double?
            let countersinkAngle: Double?
            let reversed: Bool
        }

        let schema: Int
        let fixture: String
        let mode: String
        let documentURL: String
        let revision: Int
        let contentSHA256: String
        let modelSHA256: String
        let bodyIDs: [String]
        let holeSketchID: String
        let placementCircleEntityID: String
        let placementCircleCenter: [Double]
        let placementCircleRadius: Double
        let draft: Draft?
        let savedHoles: [SavedHole]
        let wroteAt: String
    }

    private static func writeWitness(
        document: FloeCADDocument,
        witnessURL: URL,
        holeSketch: Sketch,
        circle: (UUID, SIMD2<Double>, Double),
        draft: EditorViewModel.HoleDraft?,
        holes: [(FeatureID, HoleSpec)]
    ) throws {
        let witness = FixtureWitness(
            schema: 1,
            fixture: "h1-native-hole-form",
            mode: holes.isEmpty ? "armed-draft" : "reopen-saved-hole",
            documentURL: document.url.path,
            revision: document.revision,
            contentSHA256: document.contentSHA256,
            modelSHA256: document.modelSHA256,
            bodyIDs: document.session.document.bodies
                .filter { $0.brep != nil }
                .map { $0.id.raw.uuidString },
            holeSketchID: holeSketch.id.raw.uuidString,
            placementCircleEntityID: circle.0.uuidString,
            placementCircleCenter: [circle.1.x, circle.1.y],
            placementCircleRadius: circle.2,
            draft: draft.map {
                FixtureWitness.Draft(
                    sketchID: $0.sketchID.raw.uuidString,
                    profileEntityIDs: $0.profileRef.entityIDs.map(\.uuidString),
                    targetBodyID: $0.targetBodyID?.raw.uuidString,
                    pilotRadius: $0.pilotRadius,
                    type: $0.type.rawValue,
                    depth: $0.depth,
                    counterboreDiameter: $0.counterboreDiameter,
                    counterboreDepth: $0.counterboreDepth,
                    countersinkDiameter: $0.countersinkDiameter,
                    countersinkAngle: $0.countersinkAngle,
                    reversed: $0.reversed)
            },
            savedHoles: holes.map { hole in
                let (id, spec) = hole
                return FixtureWitness.SavedHole(
                    featureID: id.raw.uuidString,
                    type: spec.kind.rawValue,
                    depth: spec.depth?.value,
                    counterboreDiameter: spec.counterboreDiameter?.value,
                    counterboreDepth: spec.counterboreDepth?.value,
                    countersinkDiameter: spec.countersinkDiameter?.value,
                    countersinkAngle: spec.countersinkAngle?.value,
                    reversed: spec.reversed)
            },
            wroteAt: ISO8601DateFormatter().string(from: Date()))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(witness).write(to: witnessURL, options: .atomic)
    }

    // MARK: - Helpers

    @MainActor
    private static func fixtureDirectory() throws -> URL {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil,
                                                    create: true)
            .appendingPathComponent("FloeAgent/CADFixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    private static func run(_ document: FloeCADDocument, _ json: String) throws -> [String: Any] {
        let outcome = document.executeJSON(Data(json.utf8))
        guard outcome.isOK,
              let object = (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any]
        else {
            throw fixtureError(outcome.message ?? "Fixture operation failed: \(json)")
        }
        return object
    }

    private static func text(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String else {
            throw fixtureError("Fixture reply lacks \(key).")
        }
        return value
    }

    private static func fixtureError(_ message: String) -> CADDocumentError {
        CADDocumentError(code: "hole_form_fixture", message: message)
    }
}
#endif
