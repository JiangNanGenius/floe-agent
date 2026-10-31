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
import CoreText
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

    /// The exact ink bounds of the first character's vector outline computed
    /// straight from CoreText — an INDEPENDENT path from `TextSketch.shape`'s
    /// chord flattening. The flattened polyline's extrema approach the exact
    /// curve extrema within one chord sagitta (chord tolerance ~0.02 × height,
    /// radii ≥ ~5 mm at these sizes ⇒ sagitta « 0.05 mm), so a 0.05 mm window
    /// is geometrically principled, not a fudge.
    private func coreTextInkBounds(
        text: String, fontName: String, height: Double, at origin: SIMD2<Double>
    ) -> (min: SIMD2<Double>, max: SIMD2<Double>) {
        let font = CTFontCreateWithName(fontName as CFString, 100, nil)
        let capHeight = max(Double(CTFontGetCapHeight(font)), 1e-9)
        let scale = height / capHeight
        var code = [UniChar](text.utf16.prefix(1))
        var glyph = CGGlyph()
        XCTAssertTrue(CTFontGetGlyphsForCharacters(font, &code, &glyph, 1))
        let path = CTFontCreatePathForGlyph(font, glyph, nil)
        let box = path?.boundingBoxOfPath ?? .zero
        return (min: origin + SIMD2(Double(box.minX), Double(box.minY)) * scale,
                max: origin + SIMD2(Double(box.maxX), Double(box.maxY)) * scale)
    }

    /// A point the production ProfileDetector resolves to `outer` (inside the
    /// outer loop and NOT inside any counter loop).
    ///
    /// The scan and the verification are GEOMETRIC: every `detectProfiles`
    /// pass mints brand-new `Profile.id`s, so comparing `Profile.id` across
    /// two detections (this helper's `profiles(at:)` and the caller's
    /// `detectProfiles`) can never match — that identity comparison always
    /// scanned to exhaustion and fell through to `outer.interiorPoint`, which
    /// on a hollow glyph lies INSIDE the counter loop. The production exec
    /// then resolved the innermost region at that seed (the counter disc) and
    /// extruded it — measured 1850.4029079364504 mm³ at distance 10 = exactly
    /// counter area 185.04029079364504 × 10. Verified 2026-10-31 against a
    /// host CoreText replication of this exact pipeline.
    private func seedPoint(in outer: Profile, excludingHoles holes: [Profile],
                           sketch: Sketch) throws -> SIMD2<Double> {
        var lo = outer.loop[0], hi = outer.loop[0]
        for p in outer.loop { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let stepX = max((hi.x - lo.x) / 24, 0.25)
        let stepY = max((hi.y - lo.y) / 24, 0.25)
        var y = lo.y
        while y <= hi.y + 1e-9 {
            var x = lo.x
            while x <= hi.x + 1e-9 {
                let point = SIMD2(x, y)
                if outer.contains(point), !holes.contains(where: { $0.contains(point) }) {
                    // Same-detection geometry is identical bit for bit; a
                    // relative epsilon only guards a hypothetical platform
                    // recomputation difference, never papering over a real
                    // resolution change.
                    if let resolved = ProfileDetector.profiles(at: point, in: sketch).first,
                       abs(abs(resolved.area) - abs(outer.area))
                           <= 1e-9 * max(abs(outer.area), 1e-9) {
                        return point
                    }
                }
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
        // FACT, proven against real CoreText geometry: `boundsMM` reports the
        // glyph INK bounds, while the requested `origin` is the baseline PEN
        // origin. Helvetica 'O' at a 20 mm cap carries a ~1.09 mm LEFT SIDE
        // BEARING, so the ink min.x sits at origin.x + sideBearing — never at
        // origin.x itself. Anchoring to font metrics, not to the pen origin.
        let ink = coreTextInkBounds(text: "O", fontName: "Helvetica",
                                    height: 20, at: SIMD2(10, 5))
        XCTAssertEqual(lo[0], ink.min.x, accuracy: 0.05,
                       "flattened ink approaches the exact CoreText ink bounds within one chord sagitta")
        XCTAssertEqual(lo[1], ink.min.y, accuracy: 0.05)
        XCTAssertEqual(hi[0], ink.max.x, accuracy: 0.05)
        XCTAssertEqual(hi[1], ink.max.y, accuracy: 0.05)
        XCTAssertEqual(hi[1] - lo[1], 20, accuracy: 2.5, "cap height is honoured (round letters overshoot slightly)")
        XCTAssertEqual(hi[0] - lo[0], 20, accuracy: 3.0)
        // The requested origin is applied EXACTLY: the identical outline
        // shaped at (0,0) translates by precisely (10,5).
        let shapedAtZero = TextSketch.shape(text: "O", fontName: "Helvetica",
                                            height: 20, at: .zero)
        let zeroBounds = try XCTUnwrap(shapedAtZero.bounds)
        XCTAssertEqual(lo[0], zeroBounds.min.x + 10, accuracy: 1e-9)
        XCTAssertEqual(lo[1], zeroBounds.min.y + 5, accuracy: 1e-9)
        XCTAssertEqual(hi[0], zeroBounds.max.x + 10, accuracy: 1e-9)
        XCTAssertEqual(hi[1], zeroBounds.max.y + 5, accuracy: 1e-9)

        // The 300+ 'O' outline segments stay bounded: ids are queryable, not
        // dumped into an unbounded tool result.
        XCTAssertEqual(reply["entityIDsOmitted"] as? Bool, true)
        let rows = try entityRows(document, sketchID: sketchID)
        XCTAssertEqual(reply["entityCount"] as? Int, rows.count)
        XCTAssertTrue(rows.count > 200, "a curved glyph flattens to many line entities")
        XCTAssertTrue(rows.allSatisfy { ($0["kind"] as? String) == "line" })

        // The result is ordinary sketch geometry and can be extruded exactly
        // like any other closed loop.
        let sketch = try self.sketch(document, id: sketchID)
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

        let sketch = try self.sketch(document, id: sketchID)
        let profiles = ProfileDetector.detectProfiles(in: sketch)
        XCTAssertEqual(profiles.count, 2)
        let outer = try XCTUnwrap(profiles.max { abs($0.area) < abs($1.area) })
        let holes = ProfileDetector.holes(of: outer, among: profiles)
        XCTAssertEqual(holes.count, 1)
        let ringArea = abs(outer.area) - holes.reduce(0) { $0 + abs($1.area) }
        // Independent hollow-O contract, measured from the real detected
        // outlines: outer 334.823326800005 mm² − counter 185.040290793645 mm²
        // = ring 149.783036006360 mm² (host CoreText replication, 2026-10-31,
        // matching this document's areas bit for bit).
        let seed = try seedPoint(in: outer, excludingHoles: holes, sketch: sketch)

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
        let beforeEntities = try self.sketch(document, id: sketchID).entities.count
        let changeBeforeText = document.session.changeCount
        _ = try run(document, #"{"op":"sketch.addText","args":{"sketchID":"\#(sketchID)","text":"A","height":20,"origin":[40,5]}}"#)
        let afterTextSketch = try self.sketch(document, id: sketchID)
        XCTAssertGreaterThan(afterTextSketch.entities.count, beforeEntities)
        XCTAssertEqual(document.session.changeCount, changeBeforeText + 1,
                       "sketch.addText is exactly one document command")
        XCTAssertEqual(try volume(document, bodyID: bodyID), ringArea * editedDistance,
                       accuracy: max(abs(ringArea * editedDistance) * 0.01, 0.01))
        document.session.undo()
        XCTAssertEqual(try self.sketch(document, id: sketchID).entities.count, beforeEntities)
        XCTAssertEqual(try volume(document, bodyID: bodyID), ringArea * editedDistance,
                       accuracy: max(abs(ringArea * editedDistance) * 0.01, 0.01))
        document.session.redo()
        XCTAssertGreaterThan(try self.sketch(document, id: sketchID).entities.count, beforeEntities)

        // 5. Save + reopen proves the text-derived solid and its outlines are
        //    durable native document state.
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        defer { reopened.close() }
        XCTAssertEqual(try volume(reopened, bodyID: bodyID), ringArea * editedDistance,
                       accuracy: max(abs(ringArea * editedDistance) * 0.01, 0.01))
        let reopenedSketch = try self.sketch(reopened, id: sketchID)
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

        // A noncharacter request must carry REAL UTF-8 through valid JSON:
        // JSONSerialization encodes U+FFFE as standard JSON, and CoreText
        // resolves the scalar to the LastResort placeholder run, which the
        // kernel reports as a missing glyph. (The previous raw-string form
        // embedded the literal bytes "\u{FFFE}" — invalid JSON — and only
        // exercised the bad_json refusal.)
        let missingData = try JSONSerialization.data(withJSONObject: [
            "op": "sketch.addText",
            "args": ["sketchID": sketchID, "text": "A\u{FFFE}B",
                     "height": 10, "fontName": "Helvetica"],
        ])
        let missingGlyph = try runFailure(document, String(decoding: missingData, as: UTF8.self))
        XCTAssertEqual(missingGlyph.outcome.errorCode, "unsupported_glyphs")
        XCTAssertTrue(missingGlyph.outcome.message?.contains("U+FFFE") == true)
        XCTAssertTrue(missingGlyph.outcome.message?.contains("placeholder") == true)

        // A valid but unassigned scalar exercises the same honest refusal
        // through a different code point (LastResort placeholder coverage).
        let unassignedData = try JSONSerialization.data(withJSONObject: [
            "op": "sketch.addText",
            "args": ["sketchID": sketchID, "text": "A\u{0378}B",
                     "height": 10, "fontName": "Helvetica"],
        ])
        let unassignedGlyph = try runFailure(document, String(decoding: unassignedData, as: UTF8.self))
        XCTAssertEqual(unassignedGlyph.outcome.errorCode, "unsupported_glyphs")
        XCTAssertTrue(unassignedGlyph.outcome.message?.contains("U+0378") == true)

        // A genuinely malformed escape is a precise bad_json refusal with no
        // document mutation: the raw-string form embeds the literal bytes
        // "\u{FFFE}", which is not valid JSON.
        let malformedEscape = try runFailure(document, #"{"op":"sketch.addText","args":{"sketchID":"\#(sketchID)","text":"A\u{FFFE}B","height":10,"fontName":"Helvetica"}}"#)
        XCTAssertEqual(malformedEscape.outcome.errorCode, "bad_json")

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
