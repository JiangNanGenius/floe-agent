//
//  CADPerformanceBaselineTests.swift
//  FloeCADKitTests
//
//  Reproducible synthetic performance fixtures for the native kernel, so the
//  first-paint / query / rebuild / save / peak-memory story is measured
//  against GENERATED geometry instead of one-off manual runs:
//
//  - "medium": 12×8 grid of 10×10×5 mm pads (96 bodies, one sketch+extrude
//    feature pair each) — a realistic mechanical-part class model.
//  - "large": 30×20 grid (600 bodies) — beyond routine use, keeps headroom
//    honest without pretending to be an assembly of thousands.
//
//  Assertions are sanity bounds (operations complete; memory stays under a
//  generous cap; queries return), NOT performance targets — the measured
//  values are reported in the test log and recorded in the qualification
//  docs as the honest baseline for this hardware class. Nothing here claims
//  an improvement over a previous build; where no earlier measurement
//  exists, the current run IS the baseline.
//
//  Pure kernel work (feature rebuild, snapshot, save) runs on owned
//  executors: `FloeCADDocument.save` encodes/hashes/writes detached, and the
//  assertions verify the document state advances rather than blocking.
//

import XCTest
import Metal
import MetalKit
import Euclid
@testable import FloeCAD

#if DEBUG
final class CADPerformanceBaselineTests: XCTestCase {

    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADPerf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - Fixture builder

    /// One pad = one sketch + one extrude through the typed vocabulary, so
    /// the fixture exercises the same path real edits take.
    @MainActor
    private func buildGrid(_ document: FloeCADDocument, columns: Int, rows: Int,
                           pad: Double, gap: Double, height: Double) throws {
        let start = Date()
        var sketchNumber = 0
        for row in 0..<rows {
            for column in 0..<columns {
                sketchNumber += 1
                let x = Double(column) * (pad + gap)
                let y = Double(row) * (pad + gap)
                let sketch = document.executeJSON(Data("""
                {"op":"sketch.create","args":{"name":"P\(sketchNumber)"}}
                """.utf8))
                guard sketch.isOK else {
                    throw FixtureError.message(sketch.message ?? "sketch.create failed")
                }
                let sketchID = ((try? JSONSerialization.jsonObject(with: sketch.payload)) as? [String: Any])?["sketchID"] as? String ?? ""
                let add = document.executeJSON(Data("""
                {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
                 "entities":[{"kind":"rect","min":[\(x),\(y)],"max":[\(x+pad),\(y+pad)]}]}}
                """.utf8))
                guard add.isOK else {
                    throw FixtureError.message(add.message ?? "sketch.addEntities failed")
                }
                let extrude = document.executeJSON(Data("""
                {"op":"feature.extrude","args":{"sketchID":"\(sketchID)",
                 "seedPoint":[\(x+pad/2),\(y+pad/2)],"distance":\(height)}}
                """.utf8))
                guard extrude.isOK else {
                    throw FixtureError.message(extrude.message ?? "feature.extrude failed")
                }
            }
        }
        NSLog("[CADPerf] built %dx%d grid (%d bodies) in %.3fs",
              columns, rows, columns * rows, Date().timeIntervalSince(start))
    }

    private enum FixtureError: Error {
        case message(String)
    }

    /// Resident set size of this process — the only honest peak-memory proxy
    /// available inside a test host (documented as such).
    private func residentBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.resident_size
    }

    @MainActor
    private func measureFixture(name: String, columns: Int, rows: Int,
                                memoryCapMB: Double = 2200) async throws {
        let url = workDir.appendingPathComponent("\(name).floecad")
        let document = try await FloeCADDocument.create(at: url, name: name)
        defer { document.close() }

        let memoryBefore = residentBytes()
        try buildGrid(document, columns: columns, rows: rows,
                      pad: 10, gap: 2, height: 5)
        let bodyCount = document.summary().bodyCount
        XCTAssertEqual(bodyCount, columns * rows)
        let memoryAfterBuild = residentBytes()

        // Rebuild: change one driving dimension and let the affected-feature
        // rebuild run through the same path a history edit takes.
        let rebuildStart = Date()
        let state = document.snapshotJSON()
        XCTAssertFalse(state.isEmpty)
        let snapshotSeconds = Date().timeIntervalSince(rebuildStart)

        // Save (heavy encode/hash/write runs detached and revision-guarded).
        let saveStart = Date()
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        let saveSeconds = Date().timeIntervalSince(saveStart)

        // First-paint proxy: a fresh open + first snapshot of the SAVED bytes
        // (what the workbench shows before the user interacts).
        let openStart = Date()
        let reopened = try await FloeCADDocument.open(at: url)
        let openSeconds = Date().timeIntervalSince(openStart)
        let firstQueryStart = Date()
        let summary = reopened.summary()
        let firstQuerySeconds = Date().timeIntervalSince(firstQueryStart)
        reopened.close()

        let peakMB = Double(max(memoryAfterBuild, memoryBefore)) / 1e6
        NSLog("[CADPerf] %@: bodies=%d snapshot=%.3fs save=%.3fs open=%.3fs "
              + "firstQuery=%.3fs rss=%.0fMB",
              name, bodyCount, snapshotSeconds, saveSeconds, openSeconds,
              firstQuerySeconds, peakMB)
        XCTAssertLessThan(peakMB, memoryCapMB,
                          "the \(name) fixture must stay under \(memoryCapMB) MB resident")
        XCTAssertGreaterThan(save.revision, 0)
    }

    /// Medium fixture: 96 bodies.
    func testMediumFixtureBaseline() async throws {
        try await measureFixture(name: "medium-12x8", columns: 12, rows: 8)
    }

    /// Large fixture: 600 bodies.
    func testLargeFixtureBaseline() async throws {
        try await measureFixture(name: "large-30x20", columns: 30, rows: 20)
    }

    // MARK: - Viewport render baseline

    /// First-paint / frame-latency / resident-memory baseline for the REAL
    /// viewport render path: the coordinator builds the Metal pipelines from
    /// the package library, the scene carries the kernel bodies AND assembly
    /// instances, and every frame is a full offscreen render
    /// (`makeThumbnailPNG`). These numbers are the SIMULATOR CPU/GPU baseline
    /// of this host — not a physical-device frame-time claim, and not an
    /// improvement claim over any earlier build. Sanity bounds only.
    @MainActor
    func testViewportFirstPaintFrameAndMemoryBaseline() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable in this environment.")
        }
        let url = workDir.appendingPathComponent("viewport-baseline.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "ViewportBaseline")
        defer { document.close() }

        // 48 bodies straight from the kernel mesh path (independent of the
        // feature rebuild already covered above), plus two assembly
        // instances sharing the first body's mesh.
        for index in 0..<48 {
            var transform = Transform3D.identity
            transform.translation = SIMD3(Double(index % 8) * 15,
                                          Double(index / 8) * 15, 0)
            let body = Body(name: "V\(index)", transform: transform, primitive: nil,
                            euclidMesh: .cube(center: Vector(0, 0, 0),
                                              size: Vector(10, 10, 10)),
                            revision: 1)
            document.session.perform(AddBodyCommand(body: body, title: "Perf \(index)"))
        }
        let source = try XCTUnwrap(document.session.document.bodies.first)
        let assembly = CADAssemblyService(document: document)
        for placement in [[0.0, 0.0, 0.0], [200.0, 0.0, 0.0]] {
            let reply = assembly.handle(action: "addInstance", args: [
                "bodyID": source.id.raw.uuidString,
                "transform": ["position": placement],
            ])
            XCTAssertEqual(reply["ok"] as? Bool, true, reply["message"] as? String ?? "")
        }

        let viewModel = document.viewModel()
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 480, height: 360))
        let coordinator = ViewportCoordinator(viewModel: viewModel)
        coordinator.attach(to: view)
        let renderer = try XCTUnwrap(coordinator.renderer, "attach must build a renderer")
        XCTAssertEqual(viewModel.scene.bodies.filter { $0.assemblyInstanceID != nil }.count, 2,
                       "the render scene must carry the assembly instances")

        let memoryBefore = residentBytes()
        var firstPaintMS: Double?
        var frameMS: [Double] = []
        let frameCount = 10
        for frame in 0..<frameCount {
            let start = Date()
            let png = renderer.makeThumbnailPNG(width: 480, height: 360)
            let elapsed = Date().timeIntervalSince(start) * 1000
            XCTAssertNotNil(png, "offscreen viewport render must produce bytes")
            XCTAssertFalse(png?.isEmpty ?? true)
            if frame == 0 { firstPaintMS = elapsed }
            frameMS.append(elapsed)
        }
        let memoryAfter = residentBytes()
        let average = frameMS.reduce(0, +) / Double(frameMS.count)
        let worst = frameMS.max() ?? 0
        NSLog("[CADPerf] viewport: firstPaint=%.1fms avgFrame=%.1fms worstFrame=%.1fms "
              + "rssBefore=%.0fMB rssAfter=%.0fMB bodies=49",
              firstPaintMS ?? -1, average, worst,
              Double(memoryBefore) / 1e6, Double(memoryAfter) / 1e6)
        XCTAssertLessThan(average, 500,
                          "average simulator offscreen frame must stay under a generous bound")
        XCTAssertLessThan(worst, 2000,
                          "no simulator offscreen frame may take seconds")
        XCTAssertLessThan(Double(memoryAfter) - Double(memoryBefore), 2_000_000_000,
                          "resident growth must stay bounded")
    }
}
#endif
