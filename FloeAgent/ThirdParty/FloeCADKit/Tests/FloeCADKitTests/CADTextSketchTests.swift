//
//  CADTextSketchTests.swift
//  FloeCADKitTests
//
//  X07 — the existing native TextSketch → sketch → extrude chain exposed as a
//  typed Agent route (`sketch.addText`) with honest font/glyph refusal.
//  Every assertion below drives the production document/session/executor and
//  the production proposal/apply transaction; no renderer or fabricated
//  result is involved. Text geometry is real Core Text outlines (counter
//  loops become holes), never a raster image or a Python/Linux mesh.
//

import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADTextSketchTests: XCTestCase {
    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADTextSketch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - Helpers

    private func makeDocument(
        _ name: String = "TextSketch"
    ) async throws -> (document: FloeCADDocument, url: URL) {
        let url = workDir.appendingPathComponent("\(name)-\(UUID().uuidString).floecad")
        let document = try await FloeCADDocument.create(at: url, name: name)
        return (document, url)
    }

    private func run(_ document: FloeCADDocument, _ json: String,
                     file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let outcome = document.executeJSON(Data(json.utf8))
        XCTAssertTrue(outcome.isOK,
                      "command failed (\(outcome.status)) \(outcome.errorCode ?? ""): "
                        + "\(outcome.message ?? "") — \(json)",
                      file: file, line: line)
        return try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any],
            "the command reply was not a JSON object", file: file, line: line)
    }

    private func runFailure(_ document: FloeCADDocument, _ json: String) throws
        -> (outcome: CADCommandOutcome, payload: [String: Any]) {
        let outcome = document.executeJSON(Data(json.utf8))
        XCTAssertFalse(outcome.isOK, "this command must refuse: \(json)")
        let payload = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any],
            "the refusal reply was not a JSON object")
        return (outcome, payload)
    }

    private func createSketch(_ document: FloeCADDocument, name: String) throws -> String {
        let reply = try run(document, #"{"op":"sketch.create","args":{"name":"\#(name)"}}"#)
        return try XCTUnwrap(reply["sketchID"] as? String)
    }

    private func queryRows(_ document: FloeCADDocument, _ scope: String,
                           file: StaticString = #filePath, line: UInt = #line) throws -> [[String: Any]] {
        let outcome = document.nativeQueryJSON(["scope": scope])
        XCTAssertTrue(outcome.isOK,
                      "query \(scope) failed: \(outcome.errorCode ?? "") \(outcome.message ?? "")",
                      file: file, line: line)
        let object = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any],
            file: file, line: line)
        return try XCTUnwrap(object["rows"] as? [[String: Any]], file: file, line: line)
    }

    private func sketch(_ document: FloeCADDocument, id sketchID: String) throws -> Sketch {
        try XCTUnwrap(document.session.document.sketches.first {
            $0.id.raw.uuidString == sketchID
        })
    }

    private func entityRows(_ document: FloeCADDocument, sketchID: String) throws -> [[String: Any]] {
        let row = try XCTUnwrap(try queryRows(document, "sketches").first {
            ($0["id"] as? String) == sketchID
        })
        return try XCTUnwrap(row["entityRows"] as? [[String: Any]])
    }

    private func firstBodyID(_ document: FloeCADDocument) throws -> String {
        let object = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: document.snapshotJSON())) as? [String: Any])
        let bodies = try XCTUnwrap(object["bodies"] as? [[String: Any]])
        return try XCTUnwrap(bodies.first?["id"] as? String)
    }

    private func volume(_ document: FloeCADDocument, bodyID: String) throws -> Double {
        let outcome = document.measureJSON(["kind": "body", "bodyID": bodyID])
        XCTAssertTrue(outcome.isOK, "measure failed: \(outcome.errorCode ?? "")")
        let object = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any])
        return try XCTUnwrap(object["volumeMM3"] as? Double)
    }

    private func extrudeFeatureID(_ document: FloeCADDocument, sketchID: String) throws -> String {
        let row = try XCTUnwrap(try queryRows(document, "features").first {
            ($0["kind"] as? String) == "extrude"
                && (($0["referencedSketches"] as? [String]) ?? []).contains(sketchID)
        })
        return try XCTUnwrap(row["id"] as? String)
    }

    /// A point the production ProfileDetector resolves to `outer` (inside the
    /// outer loop and NOT inside any counter loop).
    private func seedPoint(in outer: Profile, sketch: Sketch) throws -> SIMD2<Double> {
        var lo = outer.loop[0], hi = outer.loop[0]
        for p in outer.loop { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let stepX = max((hi.x - lo.x) / 24, 0.25)
        let stepY = max((hi.y - lo.y) / 24, 0.25)
        var y = lo.y
        while y <= hi.y + 1e-9 {
            var x = lo.x
            while x <= hi.x + 1e-9 {
                let point = SIMD2(x, y)
                let resolved = ProfileDetector.profiles(at: point, in: sketch).first
                if resolved?.id == outer.id { return point }
                x += stepX
            }
            y += stepY
        }
        XCTFail("no seed point inside the outer text profile was found")
        return outer.interiorPoint
    }

    // MARK: - Discovery / executor parity

    func testAddTextIsAdvertisedParsedAndExecutedWithNativeDiagnostics() throws {
        // Discovery parity: the executor vocabulary and the document-advertised
        // operation list stay the same list, so capabilities never lies.
        XCTAssertTrue(AgentExec.opNames.contains("sketch.addText"))
        XCTAssertEqual(FloeCADDocument.nativeOperationNames, AgentExec.opNames)

        let sketchUUID = UUID()
        let command: [String: Any] = [
            "op": "sketch.addText",
            "args": [
                "sketchID": sketchUUID.uuidString,
                "text": "O",
                "height": 20,
                "fontName": "Helvetica",
                "origin": [10, 5],
            ] as [String: Any],
        ]
        guard case .success(let parsed) = AgentExec.parse(command) else {
            XCTFail("the exact documented sketch.addText example must parse")
            return
        }
        XCTAssertEqual(parsed, .addText(
            sketch: SketchID(raw: sketchUUID), text: "O", height: 20,
            origin: SIMD2(10, 5), fontName: "Helvetica"))

        // Invalid requests are parse failures, never silent geometry.
        let badCommands: [[String: Any]] = [
            ["op": "sketch.addText", "args": ["sketchID": sketchUUID.uuidString, "height": 10]],
            ["op": "sketch.addText", "args": ["sketchID": sketchUUID.uuidString, "text": "", "height": 10]],
            ["op": "sketch.addText", "args": ["sketchID": sketchUUID.uuidString, "text": "A", "height": 0]],
            ["op": "sketch.addText", "args": ["sketchID": sketchUUID.uuidString, "text": "A", "height": 10, "origin": [1, 2, 3]]],
            ["op": "sketch.addText", "args": ["sketchID": sketchUUID.uuidString, "text": "A", "height": 10, "fontName": 42]],
            ["op": "sketch.addText", "args": ["sketchID": sketchUUID.uuidString, "text": String(repeating: "A", count: 300), "height": 10]],
        ]
        for bad in badCommands {
            if case .success = AgentExec.parse(bad) {
                XCTFail("invalid sketch.addText arguments must refuse: \(bad)")
            }
        }
    }

    func testExecutedAddTextReportsRealOutlineGeometryAndOneUndoStep() async throws {
        let (document, _) = try await makeDocument()
        let sketchID = try createSketch(document, name: "Text")

        let reply = try run(document, #"{"op":"sketch.addText","args":{"sketchID":"\#(sketchID)","text":"O","height":20,"fontName":"Helvetica","origin":[10,5]}}"#)
        XCTAssertEqual(reply["action"] as? String, "sketch.addText")
        XCTAssertEqual(reply["units"] as? String, "mm")
        XCTAssertEqual(reply["meshText"] as? Bool, false)
        XCTAssertEqual(reply["undoSteps"] as? Int, 1)
        XCTAssertEqual(reply["glyphCount"] as? Int, 1)
        XCTAssertEqual(reply["outlineLoopCount"] as? Int, 2, "Helvetica 'O' has an outer and a counter loop")
        XCTAssertEqual(reply["heightMM"] as? Double, 20)
        XCTAssertEqual(reply["requestedFontName"] as? String, "Helvetica")
        XCTAssertEqual(reply["resolvedFontNames"] as? [String], ["Helvetica"])
        XCTAssertEqual(reply["fallbackFontNames"] as? [String], [])
        XCTAssertGreaterThan(try XCTUnwrap(reply["advanceWidthMM"] as? Double), 0)

        let bounds = try XCTUnwrap(reply["boundsMM"] as? [[Double]])
        let lo = try XCTUnwrap(bounds.first), hi = try XCTUnwrap(bounds.last)
        XCTAssertEqual(lo.count, 2)
        XCTAssertEqual(hi.count, 2)
        XCTAssertEqual(lo[0], 10, accuracy: 0.75, "origin anchors the glyph baseline start")
        XCTAssertEqual(hi[1] - lo[1], 20, accuracy: 2.5, "cap height is honoured (round letters overshoot slightly)")
        XCTAssertEqual(hi[0] - lo[0], 20, accuracy: 3.0)

        // The 300+ 'O' outline segments stay bounded: ids are queryable, not
        // dumped into an unbounded tool result.
        XCTAssertEqual(reply["entityIDsOmitted"] as? Bool, true)
        let rows = try entityRows(document, sketchID: sketchID)
        XCTAssertEqual(reply["entityCount"] as? Int, rows.count)
        XCTAssertTrue(rows.count > 200, "a curved glyph flattens to many line entities")
        XCTAssertTrue(rows.allSatisfy { ($0["kind"] as? String) == "line" })

        // The result is ordinary sketch geometry and can be extruded exactly
        // like any other closed loop.
        let sketch = try sketch(document, id: sketchID)
        let profiles = ProfileDetector.detectProfiles(in: sketch)
        XCTAssertEqual(profiles.count, 2)
        let outer = try XCTUnwrap(profiles.max { abs($0.area) < abs($1.area) })
        let holes = ProfileDetector.holes(of: outer, among: profiles)
        XCTAssertEqual(holes.count, 1, "the counter loop is reported as a real hole")
    }

    // MARK: - End-to-end model route: create text → extrude → measure → edit → undo → save/reopen

    func testProposeApplyTextExtrudeMeasureEditUndoSaveAndReopen() async throws {
        let (document, url) = try await makeDocument()
        let sketchID = try createSketch(document, name: "Text profile")
        let service = CADProposalService()

        // 1. The Agent proposal route adds native text outlines without
        //    mutating the document during preview.
        let addText = """
        {"op":"sketch.addText","args":{"sketchID":"\(sketchID)","text":"O","height":20,"fontName":"Helvetica","origin":[10,5]}}
        """
        let addProposal = try await service.propose(
            document: document, operationJSON: addText, summary: "Add 20 mm O text outlines")
        XCTAssertFalse(addProposal.preview.failed)
        XCTAssertEqual(addProposal.preview.bodyCountBefore, 0)
        XCTAssertEqual(addProposal.preview.bodyCountAfter, 0)
        let addGrant = try service.issueGrant(proposalID: addProposal.id)
        _ = try await service.apply(document: document, proposalID: addProposal.id, grantID: addGrant)

        let sketch = try sketch(document, id: sketchID)
        let profiles = ProfileDetector.detectProfiles(in: sketch)
        XCTAssertEqual(profiles.count, 2)
        let outer = try XCTUnwrap(profiles.max { abs($0.area) < abs($1.area) })
        let holes = ProfileDetector.holes(of: outer, among: profiles)
        XCTAssertEqual(holes.count, 1)
        let ringArea = abs(outer.area) - holes.reduce(0) { $0 + abs($1.area) }
        let seed = try seedPoint(in: outer, sketch: sketch)

        // 2. Extrude the real text profile (hole included) through the same
        //    propose → apply transaction.
        let distance = 10.0
        let extrude = """
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)","seedPoint":[\(seed.x),\(seed.y)],"distance":\(distance)}}
        """
        let extrudeProposal = try await service.propose(
            document: document, operationJSON: extrude, summary: "Extrude the O text profile")
        XCTAssertFalse(extrudeProposal.preview.failed)
        XCTAssertEqual(extrudeProposal.preview.bodyCountAfter, 1)
        let extrudeGrant = try service.issueGrant(proposalID: extrudeProposal.id)
        let extrudeReceipt = try await service.apply(
            document: document, proposalID: extrudeProposal.id, grantID: extrudeGrant)
        XCTAssertGreaterThan(extrudeReceipt.revision, extrudeProposal.baseRevision)

        let bodyID = try firstBodyID(document)
        let featureID = try extrudeFeatureID(document, sketchID: sketchID)
        let initialVolume = try volume(document, bodyID: bodyID)
        XCTAssertEqual(initialVolume, ringArea * distance,
                       accuracy: max(abs(ringArea * distance) * 0.01, 0.01),
                       "the extruded O volume equals ring area × distance, proving the counter loop is subtracted")

        // 3. Same-document edit of the text-derived feature through the typed
        //    parameter service: one undo step, same body id.
        let editedDistance = 14.0
        let parameterService = CADParameterService(document: document)
        let update = parameterService.handle(action: "update", args: [
            "feature_id": featureID,
            "changes": ["distance": editedDistance],
        ])
        XCTAssertEqual(update["ok"] as? Bool, true, update["message"] as? String ?? "")
        XCTAssertEqual(try volume(document, bodyID: bodyID), ringArea * editedDistance,
                       accuracy: max(abs(ringArea * editedDistance) * 0.01, 0.01))

        document.session.undo()
        XCTAssertEqual(try volume(document, bodyID: bodyID), initialVolume, accuracy: 0.02)
        document.session.redo()
        XCTAssertEqual(try volume(document, bodyID: bodyID), ringArea * editedDistance,
                       accuracy: max(abs(ringArea * editedDistance) * 0.01, 0.01))

        // 4. Adding a second text to the SAME sketch is an ordinary one-step
        //    undoable edit and does not disturb the existing feature's body.
        let beforeEntities = try sketch(document, id: sketchID).entities.count
        let changeBeforeText = document.session.changeCount
        _ = try run(document, #"{"op":"sketch.addText","args":{"sketchID":"\#(sketchID)","text":"A","height":20,"origin":[40,5]}}"#)
        let afterTextSketch = try sketch(document, id: sketchID)
        XCTAssertGreaterThan(afterTextSketch.entities.count, beforeEntities)
        XCTAssertEqual(document.session.changeCount, changeBeforeText + 1,
                       "sketch.addText is exactly one document command")
        XCTAssertEqual(try volume(document, bodyID: bodyID), ringArea * editedDistance,
                       accuracy: max(abs(ringArea * editedDistance) * 0.01, 0.01))
        document.session.undo()
        XCTAssertEqual(try sketch(document, id: sketchID).entities.count, beforeEntities)
        XCTAssertEqual(try volume(document, bodyID: bodyID), ringArea * editedDistance,
                       accuracy: max(abs(ringArea * editedDistance) * 0.01, 0.01))
        document.session.redo()
        XCTAssertGreaterThan(try sketch(document, id: sketchID).entities.count, beforeEntities)

        // 5. Save + reopen proves the text-derived solid and its outlines are
        //    durable native document state.
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        defer { reopened.close() }
        XCTAssertEqual(try volume(reopened, bodyID: bodyID), ringArea * editedDistance,
                       accuracy: max(abs(ringArea * editedDistance) * 0.01, 0.01))
        let reopenedSketch = try sketch(reopened, id: sketchID)
        XCTAssertGreaterThanOrEqual(reopenedSketch.entities.count, beforeEntities)
        XCTAssertTrue(try queryRows(reopened, "features").contains {
            ($0["id"] as? String) == featureID
        }, "the text-derived extrude survives reopen by id")
    }

    // MARK: - Honest unsupported font/glyph behavior

    func testUnsupportedFontAndGlyphsArePreciseRefusalsWithoutPartialText() async throws {
        let (document, _) = try await makeDocument()
        let sketchID = try createSketch(document, name: "Refusals")
        let changeCount = document.session.changeCount
        let revision = document.revision

        let badFont = try runFailure(document, #"{"op":"sketch.addText","args":{"sketchID":"\#(sketchID)","text":"A","height":10,"fontName":"FloeNoSuchFontXYZ"}}"#)
        XCTAssertEqual(badFont.outcome.errorCode, "unsupported_font")
        XCTAssertTrue(badFont.outcome.message?.contains("FloeNoSuchFontXYZ") == true)
        XCTAssertTrue(badFont.outcome.message?.contains("NOT used") == true)

        let missingGlyph = try runFailure(document, #"{"op":"sketch.addText","args":{"sketchID":"\#(sketchID)","text":"A\u{FFFE}B","height":10,"fontName":"Helvetica"}}"#)
        XCTAssertEqual(missingGlyph.outcome.errorCode, "unsupported_glyphs")
        XCTAssertTrue(missingGlyph.outcome.message?.contains("U+FFFE") == true)
        XCTAssertTrue(missingGlyph.outcome.message?.contains("placeholder") == true)

        // A colour/bitmap-only glyph has no vector outline and must refuse too.
        let bitmapOnly = try runFailure(document, #"{"op":"sketch.addText","args":{"sketchID":"\#(sketchID)","text":"😀","height":10,"fontName":"Helvetica"}}"#)
        XCTAssertEqual(bitmapOnly.outcome.errorCode, "unsupported_glyphs")

        let whitespace = try runFailure(document, #"{"op":"sketch.addText","args":{"sketchID":"\#(sketchID)","text":"   ","height":10,"fontName":"Helvetica"}}"#)
        XCTAssertEqual(whitespace.outcome.errorCode, "empty_text")

        let overlong = try runFailure(document, #"{"op":"sketch.addText","args":{"sketchID":"\#(sketchID)","text":"\#(String(repeating: "A", count: 300))","height":10,"fontName":"Helvetica"}}"#)
        XCTAssertEqual(overlong.outcome.errorCode, "invalid_text")

        // None of the refusals may leave partial text or a mutation behind.
        XCTAssertEqual(try entityRows(document, sketchID: sketchID).count, 0)
        XCTAssertEqual(document.session.changeCount, changeCount)
        XCTAssertEqual(document.revision, revision)

        // Direct shaping mirrors the same diagnostics for the UI commit path.
        let shapedMissing = TextSketch.shape(text: "A\u{FFFE}B", fontName: "Helvetica",
                                             height: 10, at: .zero)
        XCTAssertEqual(shapedMissing.missingCharacters, ["U+FFFE"])
        let shapedFont = TextSketch.shape(text: "A", fontName: "FloeNoSuchFontXYZ",
                                          height: 10, at: .zero)
        XCTAssertEqual(shapedFont.unsupportedFontName, "FloeNoSuchFontXYZ")
        XCTAssertTrue(shapedFont.entities.isEmpty)

        // mesh.text remains precisely unavailable, and points at the real route.
        let mesh = CADMeshService(document: document)
        let text = mesh.handle(action: "text", args: ["text": "F", "size": 10, "depth": 2])
        XCTAssertEqual(text["ok"] as? Bool, false)
        XCTAssertEqual(text["error"] as? String, "text_mesh_unavailable")
        XCTAssertTrue((text["message"] as? String)?.contains("sketch.addText") == true)
        XCTAssertEqual(document.session.changeCount, changeCount)
    }
}
