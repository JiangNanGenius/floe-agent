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
// `--ui-test-cad-iges-surface-import` / `--ui-test-cad-iges-surface-export`
// seed an owned workspace `.floecad` package (closed plate + mesh-only body,
// plus one OCCT-written exact open IGES surface for export) and present the
// SHIPPED `FilePreviewView`; the import mode also drafts a real pending import
// proposal through the same host action the assistant uses. See
// `CADIGESSurfaceUIFixture` for the exact fixture provenance.
//

#if DEBUG && canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import Foundation
import FloeCAD

/// X30 recovery UI input. These are DEBUG-only launch choices for the native
/// editor export-recovery qualification; they are never read by product code.
enum CADEditorExportRecoveryFixtureMode: String, Equatable {
    case interrupted
    case completed
    case cancelled
    case empty

    static let resetArgument = "--ui-test-cad-recovery-reset"

    var launchArgument: String { "--ui-test-cad-recovery-\(rawValue)" }

    static func selected(from arguments: [String]) -> Self? {
        if arguments.contains(Self.interrupted.launchArgument) { return .interrupted }
        if arguments.contains(Self.completed.launchArgument) { return .completed }
        if arguments.contains(Self.cancelled.launchArgument) { return .cancelled }
        if arguments.contains(Self.empty.launchArgument) { return .empty }
        return nil
    }
}

/// One-shot scheduling gate for the native Mesh panel UI flow. It delays only
/// the FIRST real detached compute of each heavy action in this launch, so a
/// UI test can act while a real worker is in flight. The hold is a bounded
/// sleep (no semaphore is acquired), so a failed test cannot leave a worker
/// parked indefinitely; result geometry is always the real kernel output.
private final class CADMeshPanelFlowGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed: Set<String> = []

    func claim(_ action: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed.contains(action) else { return false }
        claimed.insert(action)
        return true
    }
}

private enum CADMeshPanelFlowTiming {
    /// Interaction windows, not performance measurements. The service's real
    /// 10 s compute deadline starts only after the probe returns. The UI test's
    /// `latePublicationDeadline` (38 s) is the 30 s repair hold plus margin.
    static let holdSeconds: [String: TimeInterval] = [
        "repair": 30,
        "simplify": 4,
        "combine": 30,
        "boolean": 30,
    ]
}

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
            } else if ProcessInfo.processInfo.arguments.contains("--ui-test-cad-joints") {
                try CADAssemblyJointUIFixture.prepare(document, bodyID: bodyID)
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

    @MainActor static func openTexturePaint(reset:Bool)async throws->FloeCADDocument {
        try await CADTexturePaintUIFixture.open(at:fixtureURL("texture-paint-bake.floecad"),reset:reset)
    }

    /// M17 native form fixture. Seeds two real open sketch lines ONLY.
    /// No loft/surface/thickness command or callback is run by the fixture.
    @MainActor
    static func openSurfaceForm(reset: Bool) async throws -> FloeCADDocument {
        let url=try fixtureURL("surface-form.floecad")
        if reset,FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) }
        if FileManager.default.fileExists(atPath:url.path) { return try await FloeCADDocument.open(at:url) }
        let document=try await FloeCADDocument.create(at:url,name:"Surface form")
        do {
            for (name,z) in [("Open A",0.0),("Open B",10.0)] {
                let result=try run(document,"""
                {"op":"sketch.create","args":{"name":"\(name)","origin":[0,0,\(z)],"xAxis":[1,0,0],"yAxis":[0,1,0]}}
                """)
                let sketch=try text(result,"sketchID")
                _=try run(document,"""
                {"op":"sketch.addEntities","args":{"sketchID":"\(sketch)","entities":[{"kind":"line","a":[0,0],"b":[20,0]}]}}
                """)
            }
            let saved=await document.save()
            guard saved.succeeded else { throw CADDocumentError(code:"fixture_save_failed",message:saved.error ?? "Surface input fixture save failed.") }
            return document
        } catch { document.close();throw error }
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

    @MainActor
    static func openMeshRepairIssues() async throws -> FloeCADDocument {
        try await openSeededFixture(fileName: "mesh-inspection.floecad", name: "Mesh inspection",
                                    scenario: .meshRepairIssues)
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

    /// X30 native editor export-recovery UI fixture. It owns one real saved
    /// package and one real `NativeCADTaskRegistry` file under its own
    /// `EditorExportRecovery` root. The only deletion path is the explicit
    /// `--ui-test-cad-recovery-reset` launch argument, and it removes only this
    /// fixture root. A first launch seeds one record through the production
    /// App adapter (`beginAnimationExport`); a later launch reopens the exact
    /// package and record without reseeding.
    ///
    /// `interrupted` leaves the record running on disk. Reading it through a
    /// new registry instance applies the production load-time downgrade to
    /// interrupted. `completed`/`cancelled` record terminal input states; they
    /// deliberately create no video and do not represent a rendered result.
    @MainActor
    static func openEditorExportRecovery(
        mode: CADEditorExportRecoveryFixtureMode,
        reset: Bool
    ) async throws -> FloeCADDocument {
        let root = try editorExportRecoveryRoot()
        let documentURL = root.appendingPathComponent("editor-export-recovery.floecad")
        let registryURL = root.appendingPathComponent("native-tasks.json")
        if reset {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        } else if !FileManager.default.fileExists(atPath: documentURL.path) {
            throw CADDocumentError(
                code: "fixture_missing",
                message: "The saved editor export-recovery fixture is missing; the first launch must reseed it.")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let shouldSeed = !FileManager.default.fileExists(atPath: documentURL.path)
        let document: FloeCADDocument
        if shouldSeed {
            document = try await createEditorExportRecoveryDocument(at: documentURL)
        } else {
            document = try await FloeCADDocument.open(at: documentURL)
        }
        if shouldSeed, mode != .empty {
            try await seedEditorExportRecoveryRecord(
                mode: mode, document: document, registryURL: registryURL)
        }
        // Always install the REAL App adapter, backed by the fixture-root
        // registry, on the actual document the workbench presents.
        let registry = NativeCADTaskRegistry(fileURL: registryURL)
        let adapter = NativeCADEditorAnimationExportRecovery(
            documentURL: document.url, registry: registry)
        document.installAnimationExportRecoverySink(adapter)
        return document
    }

    @MainActor
    private static func createEditorExportRecoveryDocument(
        at url: URL
    ) async throws -> FloeCADDocument {
        let document = try await FloeCADDocument.create(
            at: url, name: "Recovery animation")
        do {
            _ = try makeExtrudedBody(document, name: "Plate",
                                     min: [0, 0], max: [100, 60], distance: 10)
            let clip = try document.createAnimationClip(
                name: "Recovery orbit", duration: 1.5)
            let track = try document.addAnimationTrack(
                clipID: clip.id, target: .camera)
            _ = try document.setAnimationKeyframe(
                clipID: clip.id, trackID: track.id, time: 0,
                camera: CADAnimationCameraValue(
                    target: SIMD3(0.1, 0, 0.03), distance: 0.4,
                    azimuthRadians: 0.5, elevationRadians: 0.4,
                    fovYDegrees: 60))
            _ = try document.setAnimationKeyframe(
                clipID: clip.id, trackID: track.id, time: clip.duration,
                camera: CADAnimationCameraValue(
                    target: SIMD3(0.1, 0, 0.03), distance: 0.4,
                    azimuthRadians: 0.7, elevationRadians: 0.4,
                    fovYDegrees: 60))
            let save = await document.save()
            guard save.succeeded else {
                throw CADDocumentError(
                    code: "fixture_save_failed",
                    message: save.error ?? "The editor export-recovery fixture could not be saved.")
            }
            return document
        } catch {
            document.close()
            throw error
        }
    }

    @MainActor
    private static func seedEditorExportRecoveryRecord(
        mode: CADEditorExportRecoveryFixtureMode,
        document: FloeCADDocument,
        registryURL: URL
    ) async throws {
        guard let clip = document.animationLoadState().activeClip else {
            throw CADDocumentError(
                code: "fixture_animation_missing",
                message: "The editor export-recovery fixture has no active clip.")
        }
        // Exact native UI choices used by the notice and the restored sheet:
        // portrait, 720p (720x1280), 24 fps, HEVC and Higher quality.
        let options = CADAnimationExportOptions(
            orientation: .portrait, resolution: .p720, frameRate: .fps24,
            codec: .hevc, quality: .higher)
        let request = CADAnimationExportRecoveryRequest(
            documentURL: document.url,
            options: options.recoveryOptions,
            sourceRevision: document.revision,
            sourceContentSHA256: document.contentSHA256,
            sourceChangeCount: document.liveChangeCount,
            clipID: clip.id,
            clipDuration: clip.duration,
            suggestedFilename: "Recovery animation.mp4")
        let registry = NativeCADTaskRegistry(fileURL: registryURL)
        let adapter = NativeCADEditorAnimationExportRecovery(
            documentURL: document.url, registry: registry)
        let id = try await adapter.beginAnimationExport(request)
        switch mode {
        case .interrupted, .empty:
            // Leave the on-disk state exactly as beginAnimationExport wrote
            // it. A fresh registry instance later performs the real downgrade.
            break
        case .completed:
            await adapter.finishAnimationExport(
                id: id, outcome: .completed,
                detail: "fixture terminal completed record; no renderer ran")
        case .cancelled:
            await adapter.finishAnimationExport(
                id: id, outcome: .cancelled,
                detail: "fixture terminal cancelled record; no renderer ran")
        }
    }

    /// The fixture registry and package share one dedicated directory; no
    /// shared production file is read, written or deleted.
    @MainActor
    private static func editorExportRecoveryRoot() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory,
                                    in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent(
                "FloeAgent/CADFixtures/EditorExportRecovery", isDirectory: true)
    }

    /// E29/X31 NEGATIVE native OBJ options fixture: two real saved bodies where
    /// one body's saved face-material binding was DELIBERATELY broken before the
    /// save. This is an explicitly labeled fault-injected INPUT, not a claim
    /// that an ordinary reopen loses face ranges: the positive E29 path keeps
    /// real ranges across reopen, so only a genuinely malformed binding may
    /// produce the partial state. The package is saved and reopened exactly
    /// like a user's design, and the app's own shared coverage receipt still
    /// reports the real loss and the real OBJ preflight still falls back.
    /// Nothing here fabricates an invalid mesh or a renderer verdict: the two
    /// bodies are ordinary Extrudes built through the typed command vocabulary,
    /// the face material is applied through `CADMaterialService` with a fresh
    /// `query_token` from the real faces query, and then
    /// `CADDebugFixtures.injectStaleFaceBinding` writes the malformed snapshot
    /// through the ordinary material command.
    @MainActor
    static func openOBJStaleFaceCoverage() async throws -> FloeCADDocument {
        let url = try fixtureURL("obj-stale-face-coverage.floecad")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let document = try await FloeCADDocument.create(at: url, name: "OBJ stale face coverage")
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
            guard let plateID = UUID(uuidString: plate) else {
                throw CADDocumentError(code: "fixture_failed",
                                       message: "The fixture body id was not a UUID.")
            }
            try CADDebugFixtures.injectStaleFaceBinding(bodyID: plateID, in: document)
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

    /// The largest horizontal planar cap, with the exact query generation
    /// token the material service requires for an index-based face
    /// application. The default `SketchPlane.ground` is XZ with +Y up, so an
    /// Extrude's cap normal is ±Y (not ±Z); selecting by the world Y axis is
    /// what makes this a cap rather than a side wall. This is the same
    /// query/token contract the Material inspector uses; the index alone is
    /// never trusted as identity, and the normal's sign is kernel orientation
    /// (not identity).
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
                  let y = number(normal[1]) else { return false }
            return abs(y) > 0.99
        }
        guard let top = tops.max(by: { lhs, rhs in
            (number(lhs["areaMM2"]) ?? 0) < (number(rhs["areaMM2"]) ?? 0)
        }),
        let index = (top["index"] as? NSNumber)?.intValue,
        let token = top["query_token"] as? String else {
            throw CADDocumentError(code: "fixture_face_query_failed",
                                   message: "The fixture found no horizontal planar cap to paint.")
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
    @EnvironmentObject private var environment: AppEnvironment
    @State private var document: FloeCADDocument?
    @State private var error: String?
    /// E26: set when the fixture seeded a workspace-owned .floecad package and
    /// a real pending import proposal; the product FilePreviewView is then the
    /// only surface presented, so the shipped banner/export sheet are real.
    @State private var igesPreview: CADIGESSurfaceUIFixture.Prepared?
    /// E31: the real import-limit flow. Accepted presents the shipped file
    /// preview (banner); rejected/cancelled present the fixture's read-back
    /// diagnostic because the product refusal/cancel has no banner.
    @State private var importLimits: CADImportLimitsUIFixture.Prepared?
    /// M07 r3: the real native angle / three-point datum form. The readback
    /// panel is shown only for these DEBUG launch choices and never on an
    /// ordinary product/CUA screen.
    @State private var datumMode: CADDatumPlaneFormFixture.Mode?
    /// Set only by `--ui-test-cad-datum-cleanup`; removes the fixture-owned
    /// datum packages and then presents a tiny status surface.
    @State private var datumCleanupStatus: String?

    /// The App fixture cannot reach FloeCAD's internal `testHeavyComputeProbe`.
    /// This DEBUG-only launch choice installs the one existing scheduling seam
    /// through the public debug-fixture surface. It is absent unless the flag
    /// is present, and there is no Release build of this file.
    @MainActor
    private static func installMeshPanelFlowProbeIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--ui-test-cad-mesh-panel-flow") else {
            return
        }
        let gate = CADMeshPanelFlowGate()
        CADDebugFixtures.installMeshPanelComputeProbe { action, _ in
            guard let hold = CADMeshPanelFlowTiming.holdSeconds[action], hold > 0,
                  gate.claim(action) else { return }
            Thread.sleep(forTimeInterval: hold)
        }
    }

    var body: some View {
        Group {
            if let datumCleanupStatus {
                VStack(spacing: 12) {
                    Text("Datum fixture cleanup")
                        .font(.headline)
                    Text(datumCleanupStatus)
                        .font(.footnote)
                        .accessibilityIdentifier("CADDatumFixtureCleanup")
                }
            } else if let importLimits {
                if importLimits.presentWorkbench {
                    if let document {
                        NavigationStack {
                            FloeCADWorkbenchView(document: document)
                                .modifier(FloeCADHostChrome(document: document))
                        }
                    } else {
                        ProgressView("Preparing CAD fixture…")
                    }
                } else if let status = importLimits.status {
                    VStack(spacing: 12) {
                        Text("E31 import-limit fixture")
                            .font(.headline)
                        Text(status)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .padding()
                            .accessibilityIdentifier("cad.importLimits.fixtureStatus")
                    }
                } else {
                    NavigationStack {
                        FilePreviewView(relativePath: importLimits.workspaceRelativePath,
                                        center: environment.workspaceCenter,
                                        conversationID: importLimits.conversationID)
                    }
                }
            } else if let igesPreview {
                // E26: the SHIPPED workspace preview. The pre-Apply import
                // banner and the part-scope IGES exchange sheet are the
                // product views; this branch only selects the real file.
                NavigationStack {
                    FilePreviewView(relativePath: igesPreview.workspaceRelativePath,
                                    center: environment.workspaceCenter,
                                    conversationID: igesPreview.conversationID)
                }
            } else if let document {
                // Mirror the real FilePreview host: the workbench's title and
                // toolbar chrome (undo/redo, views, history, variables, items,
                // import/export, tools, settings) only render inside a
                // navigation context. Every real host embeds the workbench in
                // a NavigationStack (inspector column, thread sheet, IDE tab,
                // workspace-picker sheet); the fixture must present the SAME
                // chrome or CUA accepts a workbench that does not exist in
                // the product. The editor sets its own inline navigation
                // title (the document name), exactly as it does in-product.
                if ProcessInfo.processInfo.arguments.contains(CADTextureImportUIFixture.argument) {
                    ZStack(alignment: .topTrailing) {
                        workbench(document)
                        CADTextureImportReadbackPanel(document: document)
                            .padding(.top, 6).padding(.trailing, 6)
                    }
                } else if let datumMode,
                   !ProcessInfo.processInfo.arguments.contains("--ui-test-cad-compact") {
                    ZStack(alignment: .topLeading) {
                        workbench(document)
                        CADDatumPlaneFormReadbackPanel(document: document,
                                                       focus: datumMode.focus)
                            .padding(.top, 6)
                            .padding(.leading, 6)
                    }
                } else if ProcessInfo.processInfo.arguments.contains("--ui-test-cad-joints") {
                    ZStack(alignment: .topTrailing) {
                        workbench(document)
                        CADAssemblyJointReadbackPanel(document: document)
                            .padding(.top, 6).padding(.trailing, 6)
                    }
                } else if ProcessInfo.processInfo.arguments.contains("--ui-test-cad-exact-curves") {
                    ZStack(alignment: .topTrailing) {
                        workbench(document)
                        CADExactCurveReadbackPanel(document: document)
                            .padding(.top, 6).padding(.trailing, 6)
                    }
                } else if ProcessInfo.processInfo.arguments.contains("--ui-test-cad-projection") {
                    ZStack(alignment: .topTrailing) {
                        workbench(document)
                        CADExternalProjectionReadbackPanel(document: document)
                            .padding(.top, 6).padding(.trailing, 6)
                    }
                } else {
                    workbench(document)
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
        .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--ui-test-cad-dark") ? .dark : nil)
        // Group is transparent. Give the harness its own accessibility
        // container so this marker does not overwrite the real readback,
        // slider and menu identifiers below it.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CADFixtureHarness")
        .task {
            guard document == nil, igesPreview == nil, importLimits == nil,
                  error == nil, datumMode == nil, datumCleanupStatus == nil else { return }
            Self.installMeshPanelFlowProbeIfRequested()
            do {
                let arguments = ProcessInfo.processInfo.arguments
                if arguments.contains("--ui-test-cad-texture-paint") {
                    document=try await CADQualificationFixture.openTexturePaint(reset:arguments.contains("--ui-test-cad-texture-paint-reset"))
                } else if arguments.contains(CADTextureImportUIFixture.argument) {
                    document = try await CADTextureImportUIFixture.open(
                        reset: arguments.contains(CADTextureImportUIFixture.resetArgument),
                        reopen: arguments.contains(CADTextureImportUIFixture.reopenArgument))
                } else if arguments.contains(CADDatumPlaneFormFixture.Mode.cleanupArgument) {
                    let removed = CADDatumPlaneFormFixture.removeAllFixtures()
                    datumCleanupStatus = removed ? "removed" : "removal_failed"
                } else if arguments.contains("--ui-test-cad-projection") {
                    document = try await CADExternalProjectionUIFixture.open(
                        broken: arguments.contains("--ui-test-cad-projection-broken"))
                } else if let mode = CADDatumPlaneFormFixture.Mode.selected(from: arguments) {
                    // M07 r3: the real native angle / three-point form. The
                    // package is built through the production command path;
                    // the UI test drives the shipped bar/sheets/Items/History.
                    datumMode = mode
                    document = try await CADDatumPlaneFormFixture.open(
                        mode: mode,
                        reset: arguments.contains(CADDatumPlaneFormFixture.Mode.resetArgument),
                        reopen: arguments.contains(CADDatumPlaneFormFixture.Mode.reopenArgument))
                } else if let mode = CADImportLimitsUIFixture.Mode.selected(from: arguments) {
                    let prepared = try await CADImportLimitsUIFixture.prepare(
                        mode: mode, in: environment)
                    importLimits = prepared
                    if prepared.presentWorkbench,
                       let root = environment.workspaceCenter.currentRootURL {
                        // The manual Workbench path: the real editor consumes
                        // the fixture's pending exact-import trigger on appear.
                        document = try await FloeCADDocument.open(
                            at: root.appendingPathComponent(prepared.workspaceRelativePath))
                    }
                } else if let mode = CADIGESSurfaceUIFixture.Mode.selected(from: arguments) {
                    igesPreview = try await CADIGESSurfaceUIFixture.prepare(
                        mode: mode, in: environment)
                } else if arguments.contains("--ui-test-cad-hole-form") {
                    // H1 mechanical-hole FORM acceptance. The FloeCAD fixture
                    // seeds a real unconsumed placement circle, arms the real
                    // `beginCreate(.hole)` + viewport-tap route, and presents
                    // the production HoleOptionsSheet. A package that already
                    // contains the saved hole opens without arming a new draft,
                    // so the same test can reopen it through History.
                    document = try await CADHoleFormFixture.open(
                        reset: arguments.contains("--ui-test-cad-hole-form-reset"))
                } else if arguments.contains("--ui-test-cad-exact-curves") {
                    document = try await CADExactCurveUIFixture.open(
                        reopen: arguments.contains("--ui-test-cad-exact-curves-reopen"))
                } else if arguments.contains("--ui-test-cad-surface-form") {
                    document=try await CADQualificationFixture.openSurfaceForm(
                        reset:arguments.contains("--ui-test-cad-surface-form-reset"))
                } else if arguments.contains("--ui-test-cad-sketch-loop") {
                    document = try await CADQualificationFixture.openSplineLoop()
                } else if arguments.contains("--ui-test-cad-sketch-conflict") {
                    document = try await CADQualificationFixture.openSplineConflict()
                } else if arguments.contains("--ui-test-cad-mesh-integrity") {
                    document = try await CADQualificationFixture.openMeshRepairIssues()
                } else if arguments.contains("--ui-test-cad-face-rotation") {
                    document = try await CADQualificationFixture.openFaceRotation(
                        reset: arguments.contains("--ui-test-cad-face-rotation-reset"))
                } else if let recoveryMode = CADEditorExportRecoveryFixtureMode.selected(
                    from: arguments) {
                    // X30 exact native editor export recovery: real document,
                    // real App adapter, fixture-root registry, no auto export.
                    document = try await CADQualificationFixture.openEditorExportRecovery(
                        mode: recoveryMode,
                        reset: arguments.contains(
                            CADEditorExportRecoveryFixtureMode.resetArgument))
                } else if arguments.contains("--ui-test-cad-obj-coverage") {
                    // E29/X31 native OBJ options: real mixed valid/stale
                    // material-range receipt, saved and reopened.
                    document = try await CADQualificationFixture.openOBJStaleFaceCoverage()
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

    /// The product workbench chrome shared by every fixture branch. No
    /// identifier on this container: an accessibility id on a view with
    /// children merges the whole workbench into one element and hides the
    /// tool palette from tests. The SAME Floe-level chrome modifier the
    /// production FilePreview host applies (save status + fullscreen) is
    /// present here, so CUA always reviews the product surface, not a
    /// reduced copy.
    @ViewBuilder
    private func workbench(_ document: FloeCADDocument) -> some View {
        NavigationStack {
            FloeCADWorkbenchView(document: document)
                .modifier(FloeCADHostChrome(document: document))
        }
    }
}
#endif
