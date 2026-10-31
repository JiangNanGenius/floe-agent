// FloeAppTests — native read-only multi-view observation through the REAL
// bridge/center/tool path.
//
// This is the App-host acceptance suite for VISION5/6's native `.floecad`
// gap. It builds an actual asymmetrical OCCT part (100x60x10 plate, an
// off-centre through hole and a corner notch) through the production typed
// command vocabulary, saves it, then drives `cad.document action=observe`
// exactly as a model would. Every assertion is about actual bytes/identity:
// real non-empty PNGs, strict pixel differences, the committed revision and
// live change count carried by BOTH the frames and the body query page,
// generation pins, cancellation, unsupported selections, read-only refusal,
// verified canvas-cad binding, and the guarantee that observing mutates
// neither package bytes, undo/redo history, camera ownership nor selection.
//
// Root runs this on the pinned Metal-capable iPad Simulator; it is NOT part of
// the bounded source-only checks performed by the private packet.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(SwiftUI) && canImport(UIKit)
import CoreGraphics
import Foundation
import ImageIO
import XCTest
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
import FloeWorkbench
import FloeWorkspace
@testable import FloeApp
@testable import FloeCAD

@MainActor
final class CadNativeObservationTests: XCTestCase {
    private var workspace: URL!

    override func setUp() async throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-native-observe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        let url = workspace.appendingPathComponent("Bracket.floecad")
        if FileManager.default.fileExists(atPath: url.path) {
            await FloeCAD3DBridge.shared.releaseDocument(at: url)
        }
        try? FileManager.default.removeItem(at: workspace)
    }

    // MARK: - Fixtures

    private func makeCenter() -> CadDocumentCenter {
        CadDocumentCenter(nativeProposalStoreFileURL: workspace
            .appendingPathComponent("proposals-\(UUID().uuidString).json"))
    }

    private func makeContext(_ token: CancellationToken = CancellationToken()) -> ToolContext {
        ToolContext(runID: UUID(), toolCallID: "observe-\(UUID().uuidString)",
                    scope: .local, workspaceRootURL: workspace,
                    cancellation: token, environmentID: "env-observe",
                    conversationID: UUID())
    }

    private func decodeArgs(_ object: [String: Any]) throws -> CadDocumentArguments {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try JSONDecoder().decode(CadDocumentArguments.self, from: data)
    }

    @discardableResult
    private func execute(_ tool: CadDocumentTool, _ object: [String: Any],
                         context: ToolContext) async throws -> ToolExecutionOutput {
        let args = try decodeArgs(object)
        try tool.validate(args)
        return try await tool.execute(args, context: context)
    }

    private func payloadString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func observe(_ tool: CadDocumentTool, context: ToolContext,
                         path: String = "Bracket.floecad",
                         payload: [String: Any]) async throws -> ToolExecutionOutput {
        try await execute(tool, [
            "action": "observe",
            "path": path,
            "payload": try payloadString(payload),
        ], context: context)
    }

    private func run(_ document: FloeCADDocument, _ json: String) throws -> [String: Any] {
        let outcome = document.executeJSON(Data(json.utf8))
        XCTAssertTrue(outcome.isOK,
                      "command failed \(outcome.errorCode ?? ""): \(outcome.message ?? "") — \(json)")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: outcome.payload)
            as? [String: Any])
    }

    private func queryRows(_ document: FloeCADDocument, _ scope: String) throws -> [[String: Any]] {
        let outcome = document.nativeQueryJSON(["scope": scope])
        XCTAssertTrue(outcome.isOK, outcome.message ?? "")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: outcome.payload)
            as? [String: Any])
        return try XCTUnwrap(object["rows"] as? [[String: Any]])
    }

    /// Real asymmetrical analytic part: 100x60x10 plate, off-centre Ø12
    /// through hole and a corner notch — all through the production typed
    /// vocabulary. Returns the single body id.
    @discardableResult
    private func populate(_ document: FloeCADDocument) throws -> String {
        let plateSketch = try XCTUnwrap(
            run(document, #"{"op":"sketch.create","args":{"name":"Plate"}}"#)["sketchID"] as? String)
        _ = try run(document, """
        {"op":"sketch.addEntities","args":{"sketchID":"\(plateSketch)",
         "entities":[{"kind":"rect","min":[0,0],"max":[100,60]}]}}
        """)
        let plate = try run(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(plateSketch)","seedPoint":[50,30],"distance":10}}
        """)
        let bodyID = try XCTUnwrap(
            (plate["producedBodyIDs"] as? [String])?.first
                ?? (plate["changedBodyIDs"] as? [String])?.first)
        let holeSketch = try XCTUnwrap(
            run(document, #"{"op":"sketch.create","args":{"name":"Hole"}}"#)["sketchID"] as? String)
        _ = try run(document, """
        {"op":"sketch.addEntities","args":{"sketchID":"\(holeSketch)",
         "entities":[{"kind":"circle","center":[30,20],"radius":6}]}}
        """)
        let hole = try run(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(holeSketch)","seedPoint":[30,20],
         "distance":40,"symmetric":true,"boolean":"subtract","booleanTargets":["\(bodyID)"]}}
        """)
        XCTAssertNotEqual(hole["failed"] as? Bool, true, "the fixture hole must cut cleanly")
        let notchSketch = try XCTUnwrap(
            run(document, #"{"op":"sketch.create","args":{"name":"Notch"}}"#)["sketchID"] as? String)
        _ = try run(document, """
        {"op":"sketch.addEntities","args":{"sketchID":"\(notchSketch)",
         "entities":[{"kind":"rect","min":[62,38],"max":[88,58]}]}}
        """)
        let notch = try run(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(notchSketch)","seedPoint":[70,48],
         "distance":40,"symmetric":true,"boolean":"subtract","booleanTargets":["\(bodyID)"]}}
        """)
        XCTAssertNotEqual(notch["failed"] as? Bool, true, "the fixture notch must cut cleanly")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty,
                      "the observation fixture must rebuild clean: \(document.session.lastEvalErrors)")
        let rows = try queryRows(document, "bodies")
        XCTAssertEqual(rows.count, 1, "plate + hole + notch must stay one analytic body")
        return try XCTUnwrap(rows.first?["id"] as? String)
    }

    private func createFixture(tool: CadDocumentTool, context: ToolContext) async throws
    -> (url: URL, document: FloeCADDocument, bodyID: String) {
        _ = try await execute(tool, ["action": "create", "path": "Bracket.floecad",
                                      "name": "Bracket"], context: context)
        let url = workspace.appendingPathComponent("Bracket.floecad")
        let document = try await FloeCAD3DBridge.shared.openDocument(at: url)
        let bodyID = try populate(document)
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        // Settle any pending debounced autosave before the test pins the
        // committed identity. The observation itself is one synchronous
        // main-actor block, so a save cannot interleave with its renders; this
        // keeps the TEST's before/after identity and package digests stable.
        let settle = try await document.session.settleSaveStateBeforeIdentityPin(
            expectingChangeCount: document.liveChangeCount)
        XCTAssertEqual(settle, .ready)
        return (url, document, bodyID)
    }

    /// Adds one real separate rectangular body through the production typed
    /// vocabulary. The fixture's first body owns the hole/notch; these bodies
    /// are independent extrusions used to exercise scene membership/paging.
    private func addRectBody(_ document: FloeCADDocument, name: String,
                             min: (Double, Double), max: (Double, Double),
                             distance: Double) throws -> String {
        let sketchPayload: [String: Any] = [
            "op": "sketch.create", "args": ["name": name],
        ]
        let sketch = try XCTUnwrap(
            run(document, try payloadString(sketchPayload))["sketchID"] as? String)
        let entitiesPayload: [String: Any] = [
            "op": "sketch.addEntities",
            "args": [
                "sketchID": sketch,
                "entities": [[
                    "kind": "rect",
                    "min": [min.0, min.1],
                    "max": [max.0, max.1],
                ]],
            ],
        ]
        _ = try run(document, try payloadString(entitiesPayload))
        let extrudePayload: [String: Any] = [
            "op": "feature.extrude",
            "args": [
                "sketchID": sketch,
                "seedPoint": [(min.0 + max.0) / 2, (min.1 + max.1) / 2],
                "distance": distance,
                "boolean": "newBody",
            ],
        ]
        let extruded = try run(document, try payloadString(extrudePayload))
        XCTAssertNotEqual(extruded["failed"] as? Bool, true,
                          "the additional body must extrude cleanly")
        return try XCTUnwrap((extruded["producedBodyIDs"] as? [String])?.first)
    }

    /// Query-only observation plus its parsed hierarchy and membership page.
    /// The complete summary is checked against the tool's 24k character cap so
    /// a paged membership block can never silently truncate the JSON.
    private func observeQueryOnly(
        _ tool: CadDocumentTool, context: ToolContext,
        offset: Int = 0, limit: Int = 10
    ) async throws -> (summary: [String: Any],
                       hierarchy: [String: Any],
                       membership: [String: Any]) {
        let output = try await observe(tool, context: context, payload: [
            "includeImages": false,
            "nodeOffset": offset,
            "nodeLimit": limit,
        ])
        let summary = try observeSummary(output)
        XCTAssertLessThan(output.summary.utf8.count, 24_000,
                          "the complete observation summary must not hit the tool cap")
        let hierarchy = try XCTUnwrap(summary["hierarchy"] as? [String: Any])
        let membership = try XCTUnwrap(hierarchy["scene_membership"] as? [String: Any])
        return (summary, hierarchy, membership)
    }

    private func bodyRow(_ hierarchy: [String: Any], id: String) throws -> [String: Any] {
        let rows = try XCTUnwrap(hierarchy["rows"] as? [[String: Any]])
        return try XCTUnwrap(rows.first { $0["id"] as? String == id },
                             "missing body row \(id)")
    }

    // MARK: - Parsing

    private func observeSummary(_ output: ToolExecutionOutput) throws -> [String: Any] {
        let prefix = "cad.document observe: "
        let first = output.summary.split(separator: "\n", omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        XCTAssertTrue(first.hasPrefix(prefix), "unexpected observe summary: \(first)")
        let json = String(first.dropFirst(prefix.count))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8))
            as? [String: Any])
    }

    private func observeReceipts(_ output: ToolExecutionOutput) throws -> [[String: Any]] {
        var receipts: [[String: Any]] = []
        for line in output.summary.split(separator: "\n").dropFirst() {
            let text = String(line)
            guard text.hasPrefix("imageSHA256="), let brace = text.firstIndex(of: "{") else {
                continue
            }
            let object = try JSONSerialization.jsonObject(
                with: Data(text[brace...].utf8)) as? [String: Any]
            if let object { receipts.append(object) }
        }
        return receipts
    }

    private func artifactData(_ artifact: ToolArtifactReference) throws -> Data {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil, create: false)
        let url = support.appendingPathComponent("FloeAgent")
            .appendingPathComponent(artifact.relativePath)
        return try Data(contentsOf: url)
    }

    private func pngSize(_ data: Data) throws -> (Int, Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }

    /// Fraction of pixels whose RGB differs between two same-sized PNGs.
    private func pixelDifference(_ lhs: Data, _ rhs: Data,
                                 width: Int, height: Int) throws -> Double {
        func bytes(_ data: Data) throws -> [UInt8] {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            var drew = false
            pixels.withUnsafeMutableBytes { raw in
                guard let context = CGContext(
                    data: raw.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                drew = true
            }
            XCTAssertTrue(drew, "the PNG could not be drawn for pixel comparison")
            return pixels
        }
        let a = try bytes(lhs)
        let b = try bytes(rhs)
        var differing = 0
        for pixel in stride(from: 0, to: a.count, by: 4) {
            if a[pixel] != b[pixel] || a[pixel + 1] != b[pixel + 1]
                || a[pixel + 2] != b[pixel + 2] {
                differing += 1
            }
        }
        return Double(differing) / Double(max(width * height, 1))
    }

    /// Digest of every regular file under a `.floecad` package (path + bytes).
    private func packageDigest(_ root: URL) throws -> String {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return "" }
        var entries: [(String, String)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            entries.append((relative, FloeDigest.sha256Hex(try Data(contentsOf: url))))
        }
        entries.sort { $0.0 < $1.0 }
        let manifest = entries.map { "\($0.0):\($0.1)" }.joined(separator: "\n")
        return FloeDigest.sha256Hex(Data(manifest.utf8))
    }

    /// Straight-down world ray through a ground-plane point, matching the
    /// production viewport's tap event.
    private static func downwardRay(at point: SIMD2<Double>) -> Ray {
        Ray(origin: SIMD3<Float>(SketchPlane.ground.toWorld(point)) + SIMD3(0, 100, 0),
            direction: SIMD3(0, -1, 0))
    }

    /// Horizontal ray at mid-plate height into a clean side face. Unlike the
    /// holed top face, this face is a simple rectangle, so the production
    /// push/pull preview is a pure replacement test, not a test of face-loop
    /// repair.
    private static func frontSideRay() -> Ray {
        Ray(origin: SIMD3<Float>(50, 5, 100), direction: SIMD3<Float>(0, 0, -1))
    }

    /// Observe images while one production preview is active. Asserts the
    /// exact refusal, that the ONE derived status names this blocker, and that
    /// the refusal changes neither the user's edit nor the document/package.
    private func assertTransientPreviewRefused(
        tool: CadDocumentTool,
        context: ToolContext,
        expectedBlocker: String,
        document: FloeCADDocument,
        model: EditorViewModel,
        selection: Set<BodyID>,
        cameraEpoch: Int,
        undoDepth: Int,
        redoDepth: Int,
        packageURL: URL,
        expectedPackageDigest: String,
        expectedChangeCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let readiness = document.observationFrameReadiness()
        XCTAssertFalse(readiness.isReady,
                       "\(expectedBlocker) must block frame publication",
                       file: file, line: line)
        XCTAssertEqual(readiness.blocker?.rawValue, expectedBlocker,
                       "the derived status must name the precise preview",
                       file: file, line: line)
        XCTAssertTrue(readiness.refusalMessage.contains("includeImages=false"),
                      file: file, line: line)
        let identityBefore = document.observationIdentity()
        do {
            _ = try await observe(tool, context: context, payload: [
                "views": [["azimuthDegrees": 20.0, "elevationDegrees": 15.0,
                           "distanceScale": 1.0]],
                "width": 320,
                "height": 240,
                "includeImages": true,
            ])
            XCTFail("\(expectedBlocker) must refuse image publication",
                    file: file, line: line)
        } catch {
            let text = String(describing: error)
            XCTAssertTrue(text.contains("transient_preview_active"),
                          "unexpected refusal: \(text)", file: file, line: line)
            XCTAssertTrue(text.contains("includeImages=false"),
                          "the refusal must offer the query-only route: \(text)",
                          file: file, line: line)
        }
        XCTAssertEqual(document.observationIdentity(), identityBefore,
                       "the refusal must not change the document identity",
                       file: file, line: line)
        XCTAssertEqual(document.liveChangeCount, expectedChangeCount,
                       file: file, line: line)
        XCTAssertEqual(model.selection, selection,
                       "the refusal must not change the user's selection",
                       file: file, line: line)
        XCTAssertEqual(model.cameraEpoch, cameraEpoch,
                       "the refusal must not move the user's camera",
                       file: file, line: line)
        XCTAssertNil(model.cameraControl,
                     "observation must never take camera ownership",
                     file: file, line: line)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoDepth,
                       file: file, line: line)
        XCTAssertEqual(document.session.undoStack.redoCommands.count, redoDepth,
                       file: file, line: line)
        let digestAfter = try? packageDigest(packageURL)
        XCTAssertEqual(digestAfter, expectedPackageDigest,
                       "observation must not write package bytes",
                       file: file, line: line)
    }

    // MARK: - Main acceptance

    func testRealNativeMultiViewObservationIsIdentityBoundAndNonMutating() async throws {
        let center = makeCenter()
        let tool = CadDocumentTool(host: center)
        let context = makeContext()
        let fixture = try await createFixture(tool: tool, context: context)
        let document = fixture.document

        let identityBefore = document.observationIdentity()
        let packageBefore = try packageDigest(fixture.url)
        let selectionBefore = document.viewModel().selection
        let epochBefore = document.viewModel().cameraEpoch
        let undoBefore = document.session.undoStack.undoCommands.count
        let redoBefore = document.session.undoStack.redoCommands.count
        let unsavedBefore = document.hasUnsavedChanges
        XCTAssertNil(document.viewModel().cameraControl,
                     "an offscreen document must not acquire camera ownership")

        let output = try await observe(tool, context: context, payload: [
            "views": [
                ["azimuthDegrees": 0.0, "elevationDegrees": 0.0, "distanceScale": 1.0],
                ["azimuthDegrees": 90.0, "elevationDegrees": 35.0, "distanceScale": 1.25],
                ["azimuthDegrees": 180.0, "elevationDegrees": 90.0, "distanceScale": 1.0],
                ["azimuthDegrees": 35.0, "elevationDegrees": 20.0, "distanceScale": 1.0],
            ],
            "width": 640,
            "height": 480,
            "includeImages": true,
            "nodeOffset": 0,
            "nodeLimit": 25,
        ])
        let summary = try observeSummary(output)

        // Identity reported by the observation.
        XCTAssertEqual(summary["representation"] as? String, "native_floecad")
        XCTAssertEqual(summary["completed_frames"] as? Int, 4)
        XCTAssertEqual(summary["partial"] as? Bool, false)
        let documentBlock = try XCTUnwrap(summary["document"] as? [String: Any])
        XCTAssertEqual(documentBlock["revision"] as? Int, identityBefore.revision)
        XCTAssertEqual(documentBlock["change_count"] as? Int, identityBefore.changeCount)
        XCTAssertEqual((documentBlock["content_sha256"] as? String)?.lowercased(),
                       identityBefore.contentSHA256.lowercased())
        XCTAssertEqual(documentBlock["unsaved_changes"] as? Bool, false)
        let renderer = try XCTUnwrap(summary["renderer"] as? [String: Any])
        XCTAssertEqual(renderer["id"] as? String, "engineering")
        XCTAssertEqual(renderer["present_pixels"] as? Bool, false)
        let display = try XCTUnwrap(summary["display"] as? [String: Any])
        XCTAssertEqual(display["sectioned"] as? Bool, false)
        XCTAssertEqual(display["isolated"] as? Bool, false)
        XCTAssertEqual(display["display_mode"] as? String, "shaded")
        let recheck = try XCTUnwrap(summary["identity_recheck"] as? [String: Any])
        XCTAssertEqual(recheck["unchanged"] as? Bool, true)
        XCTAssertEqual(recheck["revision"] as? Int, identityBefore.revision)
        XCTAssertEqual(recheck["change_count"] as? Int, identityBefore.changeCount)

        // The real body query page is bound to the same generation.
        let hierarchy = try XCTUnwrap(summary["hierarchy"] as? [String: Any])
        XCTAssertEqual(hierarchy["scope"] as? String, "bodies")
        XCTAssertEqual(hierarchy["revision"] as? Int, identityBefore.revision)
        XCTAssertEqual(hierarchy["change_count"] as? Int, identityBefore.changeCount)
        XCTAssertEqual((hierarchy["content_sha256"] as? String)?.lowercased(),
                       identityBefore.contentSHA256.lowercased())
        XCTAssertEqual(hierarchy["total"] as? Int, 1)
        let rows = try XCTUnwrap(hierarchy["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["id"] as? String, fixture.bodyID)
        let token = try XCTUnwrap(rows.first?["query_token"] as? String)
        XCTAssertFalse(token.isEmpty)
        let generation = try XCTUnwrap(rows.first?["generation"] as? [String: Any])
        XCTAssertEqual(generation["document_revision"] as? Int, identityBefore.revision)
        XCTAssertEqual(generation["change_count"] as? Int, identityBefore.changeCount)
        XCTAssertEqual(generation["query_token"] as? String, token,
                       "the row query_token and its generation token agree")

        // Actual PNG artifacts: correct size, digest, and strict difference.
        XCTAssertEqual(output.artifacts.count, 4)
        var pngs: [Data] = []
        for artifact in output.artifacts {
            XCTAssertEqual(artifact.mimeType, "image/png")
            let data = try artifactData(artifact)
            XCTAssertEqual(data.count, artifact.byteCount)
            XCTAssertEqual(FloeDigest.sha256Hex(data), artifact.sha256.lowercased())
            let size = try pngSize(data)
            XCTAssertEqual(size.0, 640)
            XCTAssertEqual(size.1, 480)
            XCTAssertEqual(data.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
            pngs.append(data)
        }
        XCTAssertEqual(Set(pngs.map { FloeDigest.sha256Hex($0) }).count, 4,
                       "three requested views must produce three distinct images")
        XCTAssertGreaterThan(try pixelDifference(pngs[0], pngs[1],
                                                 width: 640, height: 480), 0.02)
        XCTAssertGreaterThan(try pixelDifference(pngs[1], pngs[2],
                                                 width: 640, height: 480), 0.02)

        // The same pose under an explicit ORTHOGRAPHIC projection is a real
        // different render, not a relabelled perspective frame.
        let orthoOutput = try await observe(tool, context: context, payload: [
            "views": [["azimuthDegrees": 35.0, "elevationDegrees": 20.0, "distanceScale": 1.0]],
            "width": 640,
            "height": 480,
            "includeImages": true,
            "projection": "orthographic",
        ])
        let orthoReceipts = try observeReceipts(orthoOutput)
        XCTAssertEqual(orthoReceipts.count, 1)
        XCTAssertEqual(orthoReceipts.first?["projection"] as? String, "orthographic")
        let orthoPNG = try artifactData(try XCTUnwrap(orthoOutput.artifacts.first))
        XCTAssertNotEqual(FloeDigest.sha256Hex(orthoPNG),
                          FloeDigest.sha256Hex(pngs[3]),
                          "orthographic and perspective of one pose must differ")
        XCTAssertGreaterThan(try pixelDifference(orthoPNG, pngs[3],
                                                 width: 640, height: 480), 0.01)
        let orthoSummary = try observeSummary(orthoOutput)
        XCTAssertEqual(orthoSummary["representation"] as? String, "native_floecad")

        // Per-frame receipts carry the same identity and honest pose data.
        let receipts = try observeReceipts(output)
        XCTAssertEqual(receipts.count, 4)
        for (index, receipt) in receipts.enumerated() {
            XCTAssertEqual((receipt["imageSHA256"] as? String)?.lowercased(),
                           output.artifacts[index].sha256.lowercased())
            XCTAssertEqual(receipt["renderer"] as? String, "engineering")
            XCTAssertEqual(receipt["presentPixels"] as? Bool, false)
            XCTAssertEqual(receipt["revision"] as? Int, identityBefore.revision)
            XCTAssertEqual(receipt["changeCount"] as? Int, identityBefore.changeCount)
            XCTAssertEqual((receipt["contentSHA256"] as? String)?.lowercased(),
                           identityBefore.contentSHA256.lowercased())
            XCTAssertEqual(receipt["projection"] as? String, "perspective")
            XCTAssertNotNil(receipt["distanceMM"] as? Double)
            XCTAssertNotNil(receipt["targetMM"] as? [Double])
            XCTAssertNotNil(receipt["effectiveElevationDegrees"] as? Double)
        }
        let pole = receipts[2]
        XCTAssertEqual(pole["poleView"] as? Bool, true)
        XCTAssertEqual((pole["elevationDegrees"] as? Double) ?? -1, 90, accuracy: 1e-9)
        let up = try XCTUnwrap(pole["upVector"] as? [Double])
        XCTAssertEqual(up.count, 3)
        XCTAssertEqual(up[0], 0, accuracy: 1e-5)
        XCTAssertEqual(up[1], 0, accuracy: 1e-9)
        XCTAssertEqual(up[2], 1, accuracy: 1e-5)

        // Query + measure remain deterministic and address the SAME object.
        let queryOutput = try await execute(
            tool, ["action": "query", "path": "Bracket.floecad", "kind": "bodies"],
            context: context)
        XCTAssertTrue(queryOutput.summary.contains(fixture.bodyID))
        XCTAssertTrue(queryOutput.summary.contains(token),
                      "the query reply must still carry the observation's query_token")
        let measureOutput = try await execute(
            tool, ["action": "measure", "path": "Bracket.floecad", "kind": "body",
                   "handles": ["body:\(fixture.bodyID)"]],
            context: context)
        let measureText = String(
            measureOutput.summary.dropFirst("cad.document measure: ".count))
        let measureObject = try JSONSerialization.jsonObject(
            with: Data(measureText.utf8)) as? [String: Any]
        let measureReply = try XCTUnwrap(measureObject)
        let measured = try XCTUnwrap(measureReply["result"] as? [String: Any])
        XCTAssertEqual(measured["bodyID"] as? String, fixture.bodyID)
        XCTAssertGreaterThan((measured["volumeMM3"] as? Double) ?? 0, 0)

        // Observation changed nothing: identity, package bytes, history,
        // camera ownership and selection are exactly as before.
        XCTAssertEqual(document.observationIdentity(), identityBefore)
        XCTAssertEqual(try packageDigest(fixture.url), packageBefore,
                       "observation must not write package bytes")
        XCTAssertEqual(document.viewModel().selection, selectionBefore)
        XCTAssertEqual(document.viewModel().cameraEpoch, epochBefore)
        XCTAssertNil(document.viewModel().cameraControl)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoBefore)
        XCTAssertEqual(document.session.undoStack.redoCommands.count, redoBefore)
        XCTAssertEqual(document.hasUnsavedChanges, unsavedBefore)
    }

    // MARK: - Transient preview fence

    /// Regression for the confirmed identity seam: a tool/pattern/exploded
    /// preview changes the DISPLAY scene without moving `session.changeCount`,
    /// so frames rendered through it would not describe the body rows queried
    /// at that same generation. Each production preview state must refuse
    /// images while leaving the user's edit, camera, selection and history
    /// untouched. Cancelling it through the ordinary production path must
    /// restore frames; the query-only route must stay available throughout.
    func testTransientDisplayPreviewsFenceFramesWithoutMutatingTheEdit() async throws {
        let center = makeCenter()
        let tool = CadDocumentTool(host: center)
        let context = makeContext()
        let fixture = try await createFixture(tool: tool, context: context)
        let document = fixture.document
        let model = document.viewModel()
        let bodyUUID = try XCTUnwrap(UUID(uuidString: fixture.bodyID))
        let bodyID = try XCTUnwrap(document.session.document.bodies.first {
            $0.id.raw == bodyUUID
        }?.id)

        let packageBefore = try packageDigest(fixture.url)
        let identityBefore = document.observationIdentity()
        let unsavedBefore = document.hasUnsavedChanges
        let undoBefore = document.session.undoStack.undoCommands.count
        let redoBefore = document.session.undoStack.redoCommands.count

        // A real stable baseline through the same public tool path.
        let baseline = try await observe(tool, context: context, payload: [
            "views": [["azimuthDegrees": 20.0, "elevationDegrees": 15.0,
                       "distanceScale": 1.0]],
            "width": 320,
            "height": 240,
            "includeImages": true,
        ])
        let baselineSummary = try observeSummary(baseline)
        XCTAssertEqual(baselineSummary["completed_frames"] as? Int, 1)
        XCTAssertEqual(baseline.artifacts.count, 1)
        let baselinePNG = try artifactData(try XCTUnwrap(baseline.artifacts.first))
        XCTAssertFalse(baselinePNG.isEmpty)
        let baselineReceipts = try observeReceipts(baseline)
        XCTAssertEqual(baselineReceipts.count, 1)
        XCTAssertEqual(baselineReceipts.first?["revision"] as? Int, identityBefore.revision)
        XCTAssertEqual(baselineReceipts.first?["changeCount"] as? Int,
                       identityBefore.changeCount)
        let baselineFence = try XCTUnwrap(baselineSummary["frame_fence"] as? [String: Any])
        XCTAssertEqual(baselineFence["ready"] as? Bool, true)
        XCTAssertEqual(baselineFence["blocker"] as? String, "none")
        let baselineHierarchy = try XCTUnwrap(baselineSummary["hierarchy"] as? [String: Any])
        let baselineRow = try XCTUnwrap(
            (baselineHierarchy["rows"] as? [[String: Any]])?.first)
        let baselineQueryToken = try XCTUnwrap(baselineRow["query_token"] as? String)
        let baselineVolume = try XCTUnwrap(baselineRow["volumeMM3"] as? Double)
        let baselineTriangles = try XCTUnwrap(baselineRow["triangles"] as? Int)

        // 1) ADDITIVE preview: a real Extrude tool armed from the production
        // palette, then a real profile tap and a real distance change. The
        // preview body exists only in the view model; the generation is
        // unchanged.
        model.selection.removeAll()
        model.beginCreate(.extrude)
        model.handle(.tap(ray: Self.downwardRay(at: SIMD2(50, 30))))
        XCTAssertNotNil(model.toolContext,
                        "the production profile tap must arm the Extrude tool")
        model.setExtrudeDistance(6)
        let additivePreview = try XCTUnwrap(model.toolContext?.preview,
                                            "the Extrude preview must be a real body")
        XCTAssertEqual(model.toolContext?.previewReplacesSource, false)
        let additivePreviewRevision = additivePreview.meshRevision
        XCTAssertEqual(document.liveChangeCount, identityBefore.changeCount,
                       "a tool preview must not move the queried generation")

        await assertTransientPreviewRefused(
            tool: tool, context: context, expectedBlocker: "tool_preview",
            document: document, model: model,
            selection: model.selection, cameraEpoch: model.cameraEpoch,
            undoDepth: document.session.undoStack.undoCommands.count,
            redoDepth: document.session.undoStack.redoCommands.count,
            packageURL: fixture.url, expectedPackageDigest: packageBefore,
            expectedChangeCount: identityBefore.changeCount)
        XCTAssertEqual(model.toolContext?.preview?.meshRevision, additivePreviewRevision,
                       "the refusal must leave the user's active preview untouched")

        // Query-only is the honest alternative at this same generation: same
        // real body row, no renderer and no artifact.
        let additiveQuery = try await observe(tool, context: context, payload: [
            "includeImages": false, "nodeLimit": 10,
        ])
        let additiveSummary = try observeSummary(additiveQuery)
        XCTAssertTrue(additiveQuery.artifacts.isEmpty)
        XCTAssertEqual(additiveSummary["completed_frames"] as? Int, 0)
        let additiveFence = try XCTUnwrap(additiveSummary["frame_fence"] as? [String: Any])
        XCTAssertEqual(additiveFence["ready"] as? Bool, false)
        XCTAssertEqual(additiveFence["blocker"] as? String, "tool_preview")
        XCTAssertEqual(additiveFence["query_only"] as? Bool, true)
        let additiveHierarchy = try XCTUnwrap(additiveSummary["hierarchy"] as? [String: Any])
        XCTAssertEqual(additiveHierarchy["change_count"] as? Int,
                       identityBefore.changeCount)
        XCTAssertEqual(additiveHierarchy["revision"] as? Int, identityBefore.revision)
        let additiveRows = try XCTUnwrap(additiveHierarchy["rows"] as? [[String: Any]])
        let additiveRow = try XCTUnwrap(additiveRows.first)
        XCTAssertEqual(additiveRow["id"] as? String, fixture.bodyID)
        XCTAssertEqual(additiveRow["query_token"] as? String, baselineQueryToken,
                       "query-only must describe the same body generation as the baseline")
        let additiveVolume = try XCTUnwrap(additiveRow["volumeMM3"] as? Double)
        XCTAssertEqual(additiveVolume, baselineVolume, accuracy: 1e-9,
                       "the uncommitted tool preview must never enter the queried body")
        XCTAssertEqual(additiveRow["triangles"] as? Int, baselineTriangles)

        // Cancel through the ordinary production path; frames return.
        model.cancelTool()
        XCTAssertNil(model.toolContext)
        let afterAdditive = try await observe(tool, context: context, payload: [
            "views": [["azimuthDegrees": 20.0, "elevationDegrees": 15.0,
                       "distanceScale": 1.0]],
            "width": 320, "height": 240, "includeImages": true,
        ])
        let afterAdditiveSummary = try observeSummary(afterAdditive)
        XCTAssertEqual(afterAdditiveSummary["completed_frames"] as? Int, 1)
        XCTAssertEqual(afterAdditive.artifacts.count, 1)
        XCTAssertEqual((afterAdditiveSummary["frame_fence"] as? [String: Any])?["ready"]
                        as? Bool, true)

        // 2) REPLACEMENT preview: a real body-face tap arms the push/pull; a
        // real distance makes the preview replace the source body in `scene`
        // while the document still holds the committed geometry. The side
        // face is a simple rectangle; the additive test above already covers
        // the holed top face.
        model.handle(.tap(ray: Self.frontSideRay()))
        XCTAssertNotNil(model.toolContext,
                        "the production face tap must arm the face push/pull")
        model.setExtrudeDistance(3)
        let replacementPreview = try XCTUnwrap(model.toolContext?.preview,
                                               "the face pull must have a preview body")
        XCTAssertEqual(model.toolContext?.previewReplacesSource, true)
        let replacementPreviewRevision = replacementPreview.meshRevision
        XCTAssertEqual(document.liveChangeCount, identityBefore.changeCount)
        await assertTransientPreviewRefused(
            tool: tool, context: context, expectedBlocker: "tool_preview",
            document: document, model: model,
            selection: model.selection, cameraEpoch: model.cameraEpoch,
            undoDepth: document.session.undoStack.undoCommands.count,
            redoDepth: document.session.undoStack.redoCommands.count,
            packageURL: fixture.url, expectedPackageDigest: packageBefore,
            expectedChangeCount: identityBefore.changeCount)
        XCTAssertEqual(model.toolContext?.preview?.meshRevision, replacementPreviewRevision,
                       "the refusal must leave the face preview untouched")
        model.cancelTool()
        XCTAssertNil(model.toolContext)
        let afterReplacement = try await observe(tool, context: context, payload: [
            "views": [["azimuthDegrees": 20.0, "elevationDegrees": 15.0,
                       "distanceScale": 1.0]],
            "width": 320, "height": 240, "includeImages": true,
        ])
        XCTAssertEqual(try observeSummary(afterReplacement)["completed_frames"] as? Int, 1)

        // 3) PATTERN ghosts: the production pattern bar draws extra instances
        // that are not model bodies.
        model.selection = [bodyID]
        model.beginPattern()
        if case .patterning = model.mode {
            // expected
        } else {
            XCTFail("the production pattern action must open the pattern bar")
        }
        XCTAssertNotNil(model.patternState)
        XCTAssertEqual(document.liveChangeCount, identityBefore.changeCount,
                       "pattern ghosts must not move the queried generation")
        await assertTransientPreviewRefused(
            tool: tool, context: context, expectedBlocker: "pattern_preview",
            document: document, model: model,
            selection: model.selection, cameraEpoch: model.cameraEpoch,
            undoDepth: document.session.undoStack.undoCommands.count,
            redoDepth: document.session.undoStack.redoCommands.count,
            packageURL: fixture.url, expectedPackageDigest: packageBefore,
            expectedChangeCount: identityBefore.changeCount)
        XCTAssertNotNil(model.patternState,
                        "the refusal must leave the user's pattern bar active")
        model.cancelPattern()
        XCTAssertNil(model.patternState)
        let afterPattern = try await observe(tool, context: context, payload: [
            "views": [["azimuthDegrees": 20.0, "elevationDegrees": 15.0,
                       "distanceScale": 1.0]],
            "width": 320, "height": 240, "includeImages": true,
        ])
        XCTAssertEqual(try observeSummary(afterPattern)["completed_frames"] as? Int, 1)

        // Observation changed nothing: no undo/redo entry, no package bytes,
        // no dirty flag and no camera ownership.
        XCTAssertEqual(document.observationIdentity(), identityBefore)
        XCTAssertEqual(try packageDigest(fixture.url), packageBefore)
        XCTAssertEqual(document.hasUnsavedChanges, unsavedBefore)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoBefore)
        XCTAssertEqual(document.session.undoStack.redoCommands.count, redoBefore)
        XCTAssertNil(model.cameraControl)
    }

    /// A saved exploded view is display-only state: activating it offsets the
    /// viewport/assembly placements without moving `changeCount` or writing
    /// the package. Frames rendered through it would show placements that the
    /// saved occurrence query does not describe, so observation must refuse
    /// images until the preview is reset; the user's view choice is untouched.
    func testTransientExplodedPlacementFencesFramesUntilReset() async throws {
        let center = makeCenter()
        let tool = CadDocumentTool(host: center)
        let context = makeContext()
        let fixture = try await createFixture(tool: tool, context: context)
        let document = fixture.document
        let model = document.viewModel()
        let bodyUUID = try XCTUnwrap(UUID(uuidString: fixture.bodyID))
        let service = CADAssemblyService(document: document)
        let addedInstance = service.handle(action: "addInstance", args: [
            "bodyID": bodyUUID.uuidString,
            "name": "Placed",
        ])
        XCTAssertEqual(addedInstance["ok"] as? Bool, true,
                       addedInstance["message"] as? String ?? "")
        let instanceID = try XCTUnwrap(addedInstance["id"] as? String)
        let addedView = service.handle(action: "addExplodedView", args: [
            "name": "Service",
            "direction": [1, 0, 0],
            "distanceMM": 20,
            "entries": [["instanceID": instanceID, "distanceMM": 25]],
        ])
        XCTAssertEqual(addedView["ok"] as? Bool, true,
                       addedView["message"] as? String ?? "")
        let viewID = try XCTUnwrap(UUID(uuidString: addedView["id"] as? String ?? ""))
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let settle = try await document.session.settleSaveStateBeforeIdentityPin(
            expectingChangeCount: document.liveChangeCount)
        XCTAssertEqual(settle, .ready)

        let packageBefore = try packageDigest(fixture.url)
        let identityBefore = document.observationIdentity()
        let undoDepth = document.session.undoStack.undoCommands.count
        let redoDepth = document.session.undoStack.redoCommands.count

        // A settled assembly still observes images normally.
        let baseline = try await observe(tool, context: context, payload: [
            "views": [["azimuthDegrees": 35.0, "elevationDegrees": 25.0,
                       "distanceScale": 1.0]],
            "width": 320, "height": 240, "includeImages": true,
        ])
        XCTAssertEqual(try observeSummary(baseline)["completed_frames"] as? Int, 1)

        let preview = service.handle(action: "previewExplodedView",
                                     args: ["id": viewID.uuidString])
        XCTAssertEqual(preview["ok"] as? Bool, true,
                       preview["message"] as? String ?? "")
        XCTAssertEqual(preview["mutated"] as? Bool, false)
        XCTAssertEqual(preview["applied"] as? Bool, true)
        XCTAssertEqual(document.liveChangeCount, identityBefore.changeCount,
                       "the exploded preview must not move the queried generation")
        let active = try XCTUnwrap(CADExplodedViewPreview.current(for: document.session))
        XCTAssertEqual(active.viewID, viewID)
        await assertTransientPreviewRefused(
            tool: tool, context: context, expectedBlocker: "exploded_view_preview",
            document: document, model: model,
            selection: model.selection, cameraEpoch: model.cameraEpoch,
            undoDepth: document.session.undoStack.undoCommands.count,
            redoDepth: document.session.undoStack.redoCommands.count,
            packageURL: fixture.url, expectedPackageDigest: packageBefore,
            expectedChangeCount: identityBefore.changeCount)
        XCTAssertEqual(CADExplodedViewPreview.current(for: document.session)?.viewID, viewID,
                       "the refusal must leave the user's saved-view preview active")

        // Query-only keeps the real body rows at the same generation.
        let queryOnly = try await observe(tool, context: context, payload: [
            "includeImages": false, "nodeLimit": 10,
        ])
        let querySummary = try observeSummary(queryOnly)
        XCTAssertTrue(queryOnly.artifacts.isEmpty)
        XCTAssertEqual(querySummary["completed_frames"] as? Int, 0)
        let queryFence = try XCTUnwrap(querySummary["frame_fence"] as? [String: Any])
        XCTAssertEqual(queryFence["ready"] as? Bool, false)
        XCTAssertEqual(queryFence["blocker"] as? String, "exploded_view_preview")
        XCTAssertEqual(queryFence["query_only"] as? Bool, true)
        let queryHierarchy = try XCTUnwrap(querySummary["hierarchy"] as? [String: Any])
        XCTAssertEqual(queryHierarchy["change_count"] as? Int, identityBefore.changeCount)
        let queryRows = try XCTUnwrap(queryHierarchy["rows"] as? [[String: Any]])
        XCTAssertEqual(queryRows.first?["id"] as? String, fixture.bodyID)

        let reset = service.handle(action: "resetExplodedView", args: [:])
        XCTAssertEqual(reset["ok"] as? Bool, true,
                       reset["message"] as? String ?? "")
        XCTAssertNil(CADExplodedViewPreview.current(for: document.session))
        let afterReset = try await observe(tool, context: context, payload: [
            "views": [["azimuthDegrees": 35.0, "elevationDegrees": 25.0,
                       "distanceScale": 1.0]],
            "width": 320, "height": 240, "includeImages": true,
        ])
        let afterSummary = try observeSummary(afterReset)
        XCTAssertEqual(afterSummary["completed_frames"] as? Int, 1)
        XCTAssertEqual((afterSummary["frame_fence"] as? [String: Any])?["ready"] as? Bool,
                       true)

        // Preview, refusal and reset changed neither the document/package nor
        // the history or camera.
        XCTAssertEqual(document.observationIdentity(), identityBefore)
        XCTAssertEqual(try packageDigest(fixture.url), packageBefore)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoDepth)
        XCTAssertEqual(document.session.undoStack.redoCommands.count, redoDepth)
        XCTAssertNil(model.cameraControl)
    }

    // MARK: - Scene membership

    /// Two real bodies: persisted hidden and transient isolate are reported as
    /// scene-membership omissions, with the SAME body ids the body query
    /// returns. Observation reads the current display state and leaves it
    /// untouched; it never claims pixel visibility.
    func testSceneMembershipReportsHiddenAndIsolatedBodies() async throws {
        let center = makeCenter()
        let tool = CadDocumentTool(host: center)
        let context = makeContext()
        let fixture = try await createFixture(tool: tool, context: context)
        let document = fixture.document
        let model = document.viewModel()

        let secondID = try addRectBody(document, name: "Spacer",
                                       min: (200, 0), max: (240, 40),
                                       distance: 8)
        XCTAssertNotEqual(secondID, fixture.bodyID)
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let settle = try await document.session.settleSaveStateBeforeIdentityPin(
            expectingChangeCount: document.liveChangeCount)
        XCTAssertEqual(settle, .ready)

        // Baseline: both real bodies contribute drawable geometry.
        var observation = try await observeQueryOnly(tool, context: context, limit: 10)
        var membership = observation.membership
        XCTAssertEqual(membership["total"] as? Int, 2)
        XCTAssertEqual(membership["included_body_count"] as? Int, 2)
        XCTAssertEqual(membership["omitted_body_count"] as? Int, 0)
        XCTAssertEqual(membership["included_instance_count"] as? Int, 0)
        XCTAssertEqual(membership["editor_preview_count"] as? Int, 0)
        let baselineRows = try XCTUnwrap(membership["rows"] as? [[String: Any]])
        XCTAssertEqual(Set(baselineRows.compactMap { $0["body_id"] as? String }),
                       Set([fixture.bodyID, secondID]))
        for row in baselineRows {
            XCTAssertEqual(row["kind"] as? String, "body")
            XCTAssertEqual(row["included"] as? Bool, true)
            XCTAssertEqual(row["drawable_count"] as? Int, 1)
        }
        for id in [fixture.bodyID, secondID] {
            let row = try bodyRow(observation.hierarchy, id: id)
            let scene = try XCTUnwrap(row["scene"] as? [String: Any])
            XCTAssertEqual(scene["included"] as? Bool, true)
            XCTAssertEqual(scene["drawable_count"] as? Int, 1)
            XCTAssertNil(scene["reason"])
        }
        let display = try XCTUnwrap(observation.summary["display"] as? [String: Any])
        let displayMembership = try XCTUnwrap(
            display["scene_membership"] as? [String: Any])
        XCTAssertEqual(displayMembership["total"] as? Int, 2)

        // Persisted hidden body: the scene omits it with the honest reason.
        let secondUUID = try XCTUnwrap(UUID(uuidString: secondID))
        model.setItemHidden(.body(BodyID(raw: secondUUID)), hidden: true)
        let hiddenSettle = try await document.session.settleSaveStateBeforeIdentityPin(
            expectingChangeCount: document.liveChangeCount)
        XCTAssertEqual(hiddenSettle, .ready)
        let hiddenIdentity = document.observationIdentity()
        observation = try await observeQueryOnly(tool, context: context, limit: 10)
        membership = observation.membership
        XCTAssertEqual(membership["included_body_count"] as? Int, 1)
        XCTAssertEqual(membership["omitted_body_count"] as? Int, 1)
        XCTAssertEqual(membership["revision"] as? Int, hiddenIdentity.revision)
        XCTAssertEqual(membership["change_count"] as? Int, hiddenIdentity.changeCount)
        XCTAssertEqual((membership["content_sha256"] as? String)?.lowercased(),
                       hiddenIdentity.contentSHA256.lowercased())
        let hiddenScene = try XCTUnwrap(
            (try bodyRow(observation.hierarchy, id: secondID))["scene"]
                as? [String: Any])
        XCTAssertEqual(hiddenScene["included"] as? Bool, false)
        XCTAssertEqual(hiddenScene["reason"] as? String, "hidden")
        XCTAssertEqual(hiddenScene["drawable_count"] as? Int, 0)
        let hiddenEntry = try XCTUnwrap(
            (membership["rows"] as? [[String: Any]])?.first(where: {
                $0["body_id"] as? String == secondID
            }))
        XCTAssertEqual(hiddenEntry["included"] as? Bool, false)
        XCTAssertEqual(hiddenEntry["reason"] as? String, "hidden")
        let visibleScene = try XCTUnwrap(
            (try bodyRow(observation.hierarchy, id: fixture.bodyID))["scene"]
                as? [String: Any])
        XCTAssertEqual(visibleScene["included"] as? Bool, true)

        // Restore visibility, then isolate the first body. Isolate is a
        // transient display override; observation must read it, not change it.
        model.setItemHidden(.body(BodyID(raw: secondUUID)), hidden: false)
        let restoredSettle = try await document.session.settleSaveStateBeforeIdentityPin(
            expectingChangeCount: document.liveChangeCount)
        XCTAssertEqual(restoredSettle, .ready)
        let firstBodyID = try XCTUnwrap(
            document.session.document.bodies.first {
                $0.id.raw.uuidString == fixture.bodyID
            }?.id)
        model.selection = [firstBodyID]
        model.enterIsolate()
        XCTAssertTrue(model.isIsolateActive)
        let isolatedIdentity = document.observationIdentity()
        let selectionBefore = model.selection
        let cameraEpochBefore = model.cameraEpoch
        let undoBefore = document.session.undoStack.undoCommands.count
        let redoBefore = document.session.undoStack.redoCommands.count
        let packageBefore = try packageDigest(fixture.url)

        observation = try await observeQueryOnly(tool, context: context, limit: 10)
        membership = observation.membership
        let isolatedDisplay = try XCTUnwrap(
            observation.summary["display"] as? [String: Any])
        XCTAssertEqual(isolatedDisplay["isolated"] as? Bool, true)
        XCTAssertEqual(membership["total"] as? Int, 2)
        XCTAssertEqual(membership["included_body_count"] as? Int, 1)
        XCTAssertEqual(membership["omitted_body_count"] as? Int, 1)
        XCTAssertEqual(membership["revision"] as? Int, isolatedIdentity.revision)
        XCTAssertEqual(membership["change_count"] as? Int, isolatedIdentity.changeCount)
        let isolatedEntry = try XCTUnwrap(
            (membership["rows"] as? [[String: Any]])?.first(where: {
                $0["body_id"] as? String == secondID
            }))
        XCTAssertEqual(isolatedEntry["included"] as? Bool, false)
        XCTAssertEqual(isolatedEntry["reason"] as? String, "outside_isolate")
        let isolatedScene = try XCTUnwrap(
            (try bodyRow(observation.hierarchy, id: secondID))["scene"]
                as? [String: Any])
        XCTAssertEqual(isolatedScene["included"] as? Bool, false)
        XCTAssertEqual(isolatedScene["reason"] as? String, "outside_isolate")
        let includedScene = try XCTUnwrap(
            (try bodyRow(observation.hierarchy, id: fixture.bodyID))["scene"]
                as? [String: Any])
        XCTAssertEqual(includedScene["included"] as? Bool, true)

        // The same isolate state is allowed to render a frame. The per-frame
        // receipt must carry the actual scene membership context, and
        // observation must not reset isolate merely to produce pixels.
        let framed = try await observe(tool, context: context, payload: [
            "views": [["azimuthDegrees": 35.0, "elevationDegrees": 20.0,
                       "distanceScale": 1.0]],
            "width": 320, "height": 240, "includeImages": true,
        ])
        let framedSummary = try observeSummary(framed)
        XCTAssertEqual(framedSummary["completed_frames"] as? Int, 1)
        XCTAssertEqual(framed.artifacts.count, 1)
        let framedFence = try XCTUnwrap(framedSummary["frame_fence"] as? [String: Any])
        XCTAssertEqual(framedFence["ready"] as? Bool, true)
        let framedDisplay = try XCTUnwrap(framedSummary["display"] as? [String: Any])
        XCTAssertEqual(framedDisplay["isolated"] as? Bool, true)
        let framedReceipts = try observeReceipts(framed)
        XCTAssertEqual(framedReceipts.count, 1)
        let framedScene = try XCTUnwrap(framedReceipts[0]["scene"] as? [String: Any])
        XCTAssertEqual(framedScene["isolated"] as? Bool, true)
        XCTAssertEqual(framedScene["sectioned"] as? Bool, false)
        XCTAssertEqual(framedScene["included_body_count"] as? Int, 1)
        XCTAssertEqual(framedScene["omitted_body_count"] as? Int, 1)
        XCTAssertEqual(framedScene["membership_total"] as? Int, 2)

        XCTAssertTrue(model.isIsolateActive,
                      "observation must not reset the user's isolate state")
        XCTAssertEqual(model.selection, selectionBefore)
        XCTAssertEqual(model.cameraEpoch, cameraEpochBefore)
        XCTAssertNil(model.cameraControl)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoBefore)
        XCTAssertEqual(document.session.undoStack.redoCommands.count, redoBefore)
        XCTAssertEqual(try packageDigest(fixture.url), packageBefore)
        XCTAssertEqual(document.observationIdentity(), isolatedIdentity)
        model.exitIsolate()
    }

    /// A real assembly places two instances of the fixture body and hides one.
    /// The paged membership must identify the occurrence ids, keep the source
    /// body id separate, and report the hidden occurrence honestly. The body
    /// query page and the membership page share exact generation pins.
    func testSceneMembershipReportsAssemblyInstancesAndPages() async throws {
        let center = makeCenter()
        let tool = CadDocumentTool(host: center)
        let context = makeContext()
        let fixture = try await createFixture(tool: tool, context: context)
        let document = fixture.document
        let bodyUUID = try XCTUnwrap(UUID(uuidString: fixture.bodyID))
        let service = CADAssemblyService(document: document)
        let first = service.handle(action: "addInstance", args: [
            "bodyID": bodyUUID.uuidString, "name": "First",
        ])
        XCTAssertEqual(first["ok"] as? Bool, true, first["message"] as? String ?? "")
        let firstInstanceID = try XCTUnwrap(first["id"] as? String)
        let second = service.handle(action: "addInstance", args: [
            "bodyID": bodyUUID.uuidString, "name": "Second",
        ])
        XCTAssertEqual(second["ok"] as? Bool, true, second["message"] as? String ?? "")
        let secondInstanceID = try XCTUnwrap(second["id"] as? String)
        let hidden = service.handle(action: "setVisible", args: [
            "id": secondInstanceID, "hidden": true,
        ])
        XCTAssertEqual(hidden["ok"] as? Bool, true, hidden["message"] as? String ?? "")
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let settle = try await document.session.settleSaveStateBeforeIdentityPin(
            expectingChangeCount: document.liveChangeCount)
        XCTAssertEqual(settle, .ready)
        let identity = document.observationIdentity()
        let packageBefore = try packageDigest(fixture.url)

        let page0 = try await observeQueryOnly(tool, context: context,
                                               offset: 0, limit: 1)
        var membership = page0.membership
        XCTAssertEqual(membership["total"] as? Int, 3)
        XCTAssertEqual(membership["offset"] as? Int, 0)
        XCTAssertEqual(membership["requested_limit"] as? Int, 1)
        XCTAssertEqual(membership["returned"] as? Int, 1)
        XCTAssertEqual(membership["next_offset"] as? Int, 1)
        XCTAssertEqual(membership["included_body_count"] as? Int, 1)
        XCTAssertEqual(membership["omitted_body_count"] as? Int, 0)
        XCTAssertEqual(membership["included_instance_count"] as? Int, 1)
        XCTAssertEqual(membership["omitted_instance_count"] as? Int, 1)
        XCTAssertEqual(membership["assembly_present"] as? Bool, true)
        XCTAssertEqual(membership["assembly_decoded"] as? Bool, true)
        XCTAssertEqual(membership["revision"] as? Int, identity.revision)
        XCTAssertEqual(membership["change_count"] as? Int, identity.changeCount)
        XCTAssertEqual((membership["content_sha256"] as? String)?.lowercased(),
                       identity.contentSHA256.lowercased())
        var rows = try XCTUnwrap(membership["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["kind"] as? String, "body")
        XCTAssertEqual(rows[0]["body_id"] as? String, fixture.bodyID)
        XCTAssertEqual(rows[0]["included"] as? Bool, true)
        XCTAssertNil(rows[0]["assembly_instance_id"])
        XCTAssertNil(rows[0]["source_body_id"])

        let page1 = try await observeQueryOnly(tool, context: context,
                                               offset: 1, limit: 1)
        membership = page1.membership
        XCTAssertEqual(membership["offset"] as? Int, 1)
        XCTAssertEqual(membership["returned"] as? Int, 1)
        XCTAssertEqual(membership["next_offset"] as? Int, 2)
        XCTAssertNil(page1.hierarchy["next_offset"] as? Int,
                     "the body page is exhausted while occurrence membership continues")
        rows = try XCTUnwrap(membership["rows"] as? [[String: Any]])
        XCTAssertEqual(rows[0]["kind"] as? String, "assembly_instance")
        XCTAssertEqual(rows[0]["assembly_instance_id"] as? String, firstInstanceID)
        XCTAssertEqual(rows[0]["source_body_id"] as? String, fixture.bodyID)
        XCTAssertEqual(rows[0]["included"] as? Bool, true)
        XCTAssertEqual(rows[0]["drawable_count"] as? Int, 1)
        XCTAssertNil(rows[0]["body_id"])
        XCTAssertNotEqual(rows[0]["assembly_instance_id"] as? String, fixture.bodyID)

        let page2 = try await observeQueryOnly(tool, context: context,
                                               offset: 2, limit: 1)
        membership = page2.membership
        XCTAssertEqual(membership["offset"] as? Int, 2)
        XCTAssertEqual(membership["returned"] as? Int, 1)
        XCTAssertNil(membership["next_offset"] as? Int)
        rows = try XCTUnwrap(membership["rows"] as? [[String: Any]])
        XCTAssertEqual(rows[0]["kind"] as? String, "assembly_instance")
        XCTAssertEqual(rows[0]["assembly_instance_id"] as? String, secondInstanceID)
        XCTAssertEqual(rows[0]["source_body_id"] as? String, fixture.bodyID)
        XCTAssertEqual(rows[0]["included"] as? Bool, false)
        XCTAssertEqual(rows[0]["reason"] as? String, "hidden")
        XCTAssertEqual(rows[0]["drawable_count"] as? Int, 0)

        // Both paged views carry the same exact generation on every page.
        for (hierarchy, membershipPage) in [
            (page0.hierarchy, page0.membership),
            (page1.hierarchy, page1.membership),
            (page2.hierarchy, page2.membership),
        ] {
            XCTAssertEqual(hierarchy["revision"] as? Int, identity.revision)
            XCTAssertEqual(hierarchy["change_count"] as? Int, identity.changeCount)
            XCTAssertEqual((hierarchy["content_sha256"] as? String)?.lowercased(),
                           identity.contentSHA256.lowercased())
            XCTAssertEqual(membershipPage["revision"] as? Int, identity.revision)
            XCTAssertEqual(membershipPage["change_count"] as? Int, identity.changeCount)
            XCTAssertEqual((membershipPage["content_sha256"] as? String)?.lowercased(),
                           identity.contentSHA256.lowercased())
        }

        XCTAssertEqual(document.observationIdentity(), identity)
        XCTAssertEqual(try packageDigest(fixture.url), packageBefore)
        XCTAssertNil(document.viewModel().cameraControl)
    }

    /// Six real bodies page through the body query and the membership block
    /// with nodeLimit=2. Every page parses completely, carries the same
    /// generation pins, and the union of pages covers every body exactly.
    func testSceneMembershipPagesManyBodiesCompletely() async throws {
        let center = makeCenter()
        let tool = CadDocumentTool(host: center)
        let context = makeContext()
        let fixture = try await createFixture(tool: tool, context: context)
        let document = fixture.document
        var expectedIDs = Set([fixture.bodyID])
        for index in 0..<5 {
            let x = 300.0 + Double(index) * 60
            let id = try addRectBody(document, name: "Block \(index + 1)",
                                     min: (x, 0), max: (x + 40, 40),
                                     distance: 6)
            expectedIDs.insert(id)
        }
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let settle = try await document.session.settleSaveStateBeforeIdentityPin(
            expectingChangeCount: document.liveChangeCount)
        XCTAssertEqual(settle, .ready)
        let identity = document.observationIdentity()
        let packageBefore = try packageDigest(fixture.url)
        let query = try queryRows(document, "bodies")
        XCTAssertEqual(query.count, 6)
        XCTAssertEqual(Set(query.compactMap { $0["id"] as? String }), expectedIDs)

        var offset = 0
        var pages = 0
        var collectedBodies = Set<String>()
        var collectedMembershipBodies = Set<String>()
        while true {
            let observation = try await observeQueryOnly(
                tool, context: context, offset: offset, limit: 2)
            let hierarchy = observation.hierarchy
            let membership = observation.membership
            XCTAssertEqual(membership["total"] as? Int, 6)
            XCTAssertEqual(membership["offset"] as? Int, offset)
            XCTAssertEqual(membership["requested_limit"] as? Int, 2)
            XCTAssertLessThanOrEqual((membership["returned"] as? Int) ?? 99, 2)
            XCTAssertEqual(membership["revision"] as? Int, identity.revision)
            XCTAssertEqual(membership["change_count"] as? Int, identity.changeCount)
            XCTAssertEqual((membership["content_sha256"] as? String)?.lowercased(),
                           identity.contentSHA256.lowercased())
            let bodyRows = try XCTUnwrap(hierarchy["rows"] as? [[String: Any]])
            XCTAssertLessThanOrEqual(bodyRows.count, 2)
            for row in bodyRows {
                let id = try XCTUnwrap(row["id"] as? String)
                collectedBodies.insert(id)
                let scene = try XCTUnwrap(row["scene"] as? [String: Any])
                XCTAssertEqual(scene["included"] as? Bool, true)
                XCTAssertEqual(scene["drawable_count"] as? Int, 1)
            }
            let membershipRows = try XCTUnwrap(membership["rows"] as? [[String: Any]])
            XCTAssertLessThanOrEqual(membershipRows.count, 2)
            for row in membershipRows {
                XCTAssertEqual(row["kind"] as? String, "body")
                if let id = row["body_id"] as? String {
                    collectedMembershipBodies.insert(id)
                }
                XCTAssertEqual(row["included"] as? Bool, true)
            }
            pages += 1
            XCTAssertLessThan(pages, 10)
            guard let next = membership["next_offset"] as? Int else { break }
            XCTAssertGreaterThan(next, offset)
            offset = next
        }
        XCTAssertEqual(pages, 3)
        XCTAssertEqual(collectedBodies, expectedIDs)
        XCTAssertEqual(collectedMembershipBodies, expectedIDs)
        XCTAssertEqual(document.observationIdentity(), identity)
        XCTAssertEqual(try packageDigest(fixture.url), packageBefore)
        XCTAssertNil(document.viewModel().cameraControl)
    }

    // MARK: - Generation pins

    func testPinsFenceUnsavedGenerationAndCommittedRevision() async throws {
        let center = makeCenter()
        let tool = CadDocumentTool(host: center)
        let context = makeContext()
        let fixture = try await createFixture(tool: tool, context: context)
        let document = fixture.document
        let revision = document.revision
        let changeCount = document.liveChangeCount
        let contentSHA = document.contentSHA256

        // Exact pins succeed and are echoed.
        let exact = try await observe(tool, context: context, payload: [
            "includeImages": false,
            "expectedRevision": revision,
            "expectedChangeCount": changeCount,
            "expectedSourceSHA256": contentSHA,
        ])
        let exactSummary = try observeSummary(exact)
        let pins = try XCTUnwrap(exactSummary["pins"] as? [String: Any])
        XCTAssertEqual(pins["revision"] as? Int, revision)
        XCTAssertEqual(pins["change_count"] as? Int, changeCount)
        XCTAssertEqual((pins["content_sha256"] as? String)?.lowercased(),
                       contentSHA.lowercased())
        XCTAssertTrue(exact.artifacts.isEmpty,
                      "includeImages=false must not write image artifacts")

        // An UNSAVED draft moves the live generation but not the revision.
        _ = try run(document, #"{"op":"sketch.create","args":{"name":"Draft"}}"#)
        XCTAssertEqual(document.revision, revision)
        XCTAssertGreaterThan(document.liveChangeCount, changeCount)
        let packageBefore = try packageDigest(fixture.url)

        do {
            _ = try await observe(tool, context: context, payload: [
                "includeImages": false,
                "expectedRevision": revision,
                "expectedChangeCount": changeCount,
            ])
            XCTFail("a stale change-count pin must refuse")
        } catch {
            XCTAssertTrue(String(describing: error).contains("change_count_mismatch"),
                          "unexpected error: \(error)")
        }

        // The revision-only pin still resolves, and the summary says the
        // pixels/scene come from an UNSAVED generation without claiming the
        // committed content SHA is a hash of that draft.
        let unsaved = try await observe(tool, context: context, payload: [
            "includeImages": false,
            "expectedRevision": revision,
        ])
        let unsavedSummary = try observeSummary(unsaved)
        let unsavedDocument = try XCTUnwrap(unsavedSummary["document"] as? [String: Any])
        XCTAssertEqual(unsavedDocument["unsaved_changes"] as? Bool, true)
        XCTAssertEqual((unsavedDocument["content_sha256"] as? String)?.lowercased(),
                       contentSHA.lowercased())
        XCTAssertEqual(try packageDigest(fixture.url), packageBefore,
                       "an unsaved observation must not write the package")

        // Commit the draft: the old revision and old content pins now refuse.
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        XCTAssertGreaterThan(document.revision, revision)
        let newRevision = document.revision
        let newContent = document.contentSHA256
        XCTAssertNotEqual(newContent.lowercased(), contentSHA.lowercased())

        for payload in [
            ["includeImages": false, "expectedRevision": revision],
            ["includeImages": false, "expectedSourceSHA256": contentSHA],
        ] as [[String: Any]] {
            do {
                _ = try await observe(tool, context: context, payload: payload)
                XCTFail("a stale committed pin must refuse: \(payload)")
            } catch {
                XCTAssertTrue(String(describing: error).contains("mismatch"),
                              "unexpected error: \(error)")
            }
        }

        // Fresh pins succeed again.
        let fresh = try await observe(tool, context: context, payload: [
            "includeImages": false,
            "expectedRevision": newRevision,
            "expectedChangeCount": document.liveChangeCount,
            "expectedSourceSHA256": newContent,
        ])
        let freshSummary = try observeSummary(fresh)
        let freshDocument = try XCTUnwrap(freshSummary["document"] as? [String: Any])
        XCTAssertEqual(freshDocument["revision"] as? Int, newRevision)
        XCTAssertEqual((freshDocument["content_sha256"] as? String)?.lowercased(),
                       newContent.lowercased())
        XCTAssertEqual(freshDocument["unsaved_changes"] as? Bool, false)
    }

    // MARK: - Refusals / authority

    func testUnsupportedSelectionsReadOnlyAndAuthorityAreRefused() async throws {
        let center = makeCenter()
        let tool = CadDocumentTool(host: center)
        let context = makeContext()
        let fixture = try await createFixture(tool: tool, context: context)

        // Request-level refusals happen BEFORE the host touches a document.
        for payload in [
            ["includeImages": false, "cameraIndex": 0],
            ["includeImages": false, "clipIndex": 0],
            ["includeImages": false, "timeSeconds": 1],
            ["includeImages": false, "sceneIndex": 2],
        ] as [[String: Any]] {
            do {
                _ = try await observe(tool, context: context, payload: payload)
                XCTFail("unsupported native selection must refuse: \(payload)")
            } catch {
                XCTAssertFalse(String(describing: error).isEmpty)
            }
        }
        // The host also refuses a direct call (defense in depth) and points to
        // the animation capture path.
        do {
            _ = try await center.observeModel(
                documentID: "Bracket.floecad",
                request: CadModelObservationRequest(clipIndex: 0, includeImages: false),
                access: CadDocumentAccess(environmentID: "env-observe",
                                          workspacePath: workspace.path,
                                          ownerKind: "chat", ownerID: UUID()))
            XCTFail("the host must refuse a native clip selection")
        } catch {
            XCTAssertTrue(String(describing: error).contains("animation"), "\(error)")
        }

        // A missing document is a structured failure, never an empty image or
        // a fabricated hierarchy.
        do {
            _ = try await observe(tool, context: context, path: "Missing.floecad",
                                  payload: ["includeImages": false])
            XCTFail("a missing native document must refuse")
        } catch {
            XCTAssertFalse(String(describing: error).isEmpty)
        }

        // A read-only package (newer schema) is refused without writing.
        let readOnlyURL = workspace.appendingPathComponent("ReadOnly.floecad")
        try FileManager.default.copyItem(at: fixture.url, to: readOnlyURL)
        let manifestURL = readOnlyURL.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
                as? [String: Any])
        let currentSchema = manifest["schemaVersion"] as? Int
            ?? FloeCADDocument.supportedPackageSchemaVersion
        manifest["schemaVersion"] = max(currentSchema,
                                        FloeCADDocument.supportedPackageSchemaVersion) + 1
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: manifestURL, options: .atomic)
        let readOnlyBefore = try packageDigest(readOnlyURL)
        do {
            _ = try await observe(tool, context: context, path: "ReadOnly.floecad",
                                  payload: ["includeImages": false])
            XCTFail("a read-only package must not be observed as an editable scene")
        } catch {
            // The host's existing document_read_only classification keeps its
            // user-facing wording (no internal code prefix), so match it.
            XCTAssertTrue(String(describing: error).lowercased().contains("read-only"), "\(error)")
        }
        XCTAssertEqual(try packageDigest(readOnlyURL), readOnlyBefore)

        // No workspace access and no canvas owner: denied before any engine
        // work, exactly like the other native actions.
        do {
            _ = try await center.observeModel(
                documentID: "Bracket.floecad",
                request: CadModelObservationRequest(includeImages: false),
                access: CadDocumentAccess(environmentID: "env-observe",
                                          workspacePath: nil,
                                          ownerKind: "workspace", ownerID: nil))
            XCTFail("an ownerless workspace access must be denied")
        } catch {
            XCTAssertTrue(String(describing: error).lowercased().contains("unauthorized"),
                          "\(error)")
        }
    }

    // MARK: - Cancellation

    func testCancellationPublishesNothing() async throws {
        let center = makeCenter()
        let tool = CadDocumentTool(host: center)
        let context = makeContext()
        let fixture = try await createFixture(tool: tool, context: context)
        let packageBefore = try packageDigest(fixture.url)

        let cancelled = CancellationToken()
        cancelled.cancel()
        do {
            _ = try await observe(tool, context: makeContext(cancelled),
                                  payload: ["includeImages": false])
            XCTFail("a cancelled run must refuse")
        } catch {
            XCTAssertTrue(String(describing: error).lowercased().contains("cancel"), "\(error)")
        }
        XCTAssertEqual(try packageDigest(fixture.url), packageBefore)

        // Mid-render cancellation: the engine checks before every frame and
        // returns no partial frame list.
        var checks = 0
        do {
            _ = try fixture.document.captureObservationViews(
                [CADObservationView(azimuthDegrees: 0, elevationDegrees: 0),
                 CADObservationView(azimuthDegrees: 90, elevationDegrees: 20),
                 CADObservationView(azimuthDegrees: 180, elevationDegrees: 20)],
                width: 320, height: 240,
                projection: .perspective,
                shouldCancel: {
                    checks += 1
                    // 1 = entry, 2 = before frame 0, 3 = before frame 1.
                    return checks > 2
                })
            XCTFail("cancellation after the first frame must throw, not return a partial set")
        } catch {
            XCTAssertGreaterThanOrEqual(checks, 3)
            XCTAssertTrue(String(describing: error).contains("cancelled"), "\(error)")
        }
    }

    // MARK: - Canvas binding

    func testVerifiedCanvasBindingObservesTheLiveNativePackage() async throws {
        let canvasID = UUID()
        try WorkspaceCanvasRegistry.createIfNeeded(canvasID: canvasID,
                                                   name: "Observe Canvas",
                                                   workspaceID: nil)
        defer {
            try? WorkspaceCanvasRegistry.delete(canvasID: canvasID)
            CanvasCADStorage.removePackages(canvasID: canvasID)
        }
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let assetStore = CreativeAssetStore(database: database)
        let project = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        let documentID = try XCTUnwrap(project.documents.first?.id)
        let created = await CADCanvasActionBridge.newCADDocumentInCanvas(
            canvasID: canvasID, documentID: documentID,
            position: CanvasPoint(x: 160, y: 160), assetStore: assetStore)
        let nodeID = try XCTUnwrap(created.nodeID, created.message)
        let updated = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        let node = try XCTUnwrap(updated.documents.flatMap(\.nodes).first { $0.id == nodeID })
        let key = try XCTUnwrap(node.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath])
        XCTAssertTrue(CanvasCADStorage.isCanvasOwnedKey(key))
        let packageURL = try XCTUnwrap(CADCanvasActionBridge.packageURL(forSourceKey: key))
        let document = try await FloeCAD3DBridge.shared.openDocument(at: packageURL)
        try populate(document)
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let settle = try await document.session.settleSaveStateBeforeIdentityPin(
            expectingChangeCount: document.liveChangeCount)
        XCTAssertEqual(settle, .ready)
        let packageBefore = try packageDigest(packageURL)
        let identity = document.observationIdentity()

        let center = CadDocumentCenter(nativeProposalStoreFileURL: workspace
            .appendingPathComponent("canvas-proposals-\(UUID().uuidString).json"))
        // A Canvas run has no task workspace; ownership is the verified
        // canvas-cad binding, re-derived by the host from the canvas project.
        let access = CadDocumentAccess(environmentID: "env-canvas",
                                       workspacePath: nil,
                                       ownerKind: "canvas", ownerID: canvasID)
        let request = CadModelObservationRequest(
            views: [.init(azimuthDegrees: 40, elevationDegrees: 25),
                    .init(azimuthDegrees: 220, elevationDegrees: 10)],
            width: 384, height: 288, includeImages: true, nodeLimit: 10)
        let observation = try await center.observeModel(
            documentID: key, request: request, access: access)

        let summary = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(observation.summaryJSON.utf8))
                as? [String: Any])
        XCTAssertEqual(summary["representation"] as? String, "native_floecad")
        XCTAssertEqual(observation.frames.count, 2)
        let frame = try XCTUnwrap(observation.frames.first)
        XCTAssertFalse(frame.pngData.isEmpty)
        XCTAssertEqual(try pngSize(frame.pngData).0, 384)
        XCTAssertNotEqual(FloeDigest.sha256Hex(observation.frames[0].pngData),
                          FloeDigest.sha256Hex(observation.frames[1].pngData))
        let block = try XCTUnwrap(summary["document"] as? [String: Any])
        XCTAssertEqual(block["path"] as? String, key,
                       "the summary reports the caller's verified canvas-cad key")
        XCTAssertEqual(block["revision"] as? Int, identity.revision)
        XCTAssertEqual(block["change_count"] as? Int, identity.changeCount)
        XCTAssertEqual(try packageDigest(packageURL), packageBefore,
                       "canvas observation must not write package bytes")
        XCTAssertEqual(document.observationIdentity(), identity)
        await FloeCAD3DBridge.shared.releaseDocument(at: packageURL)
    }
}
#endif
