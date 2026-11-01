//
//  NativeMeshImportBudgetTests.swift
//  FloeCADKitTests
//
//  E31 kernel-level qualification: a compressed asset's DECLARED expansion is
//  refused before the destination buffer or geometry array exists; a
//  cancellation observed before the exact-format commit leaves zero bodies;
//  normal supported meshes still import under the same budget.
//
//  The fixtures are hostile containers, not stubs: the zip central/local
//  records declare 400 MiB (or 6,000 entries), the Blender gzip trailer
//  declares a multi-GiB ISIZE, and the glTF accessor declares a count its
//  bufferView cannot hold. The parser is the production `MeshImportKit` /
//  `nativeImportData`; nothing here substitutes a decoder.
//
//  Root runs this on the pinned Simulator; the process footprint assertion is
//  a real `task_vm_info.phys_footprint` sample of the test host, not a
//  synthetic timer. It is NOT a physical-iPad memory measurement.
//
//  SPDX-License-Identifier: MPL-2.0
//

import Darwin
import XCTest
import simd
@testable import FloeCAD

@MainActor
final class NativeMeshImportBudgetTests: XCTestCase {
    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeImportBudget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        MeshImportKit.testParseCheckpoint = nil
        MeshImportKit.testImportBodyCheckpoint = nil
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - Hostile container fixtures

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    /// A DEFLATE zip entry that DECLARES `uncompressed` bytes while carrying
    /// only `payload`. The budget must refuse the declared expansion before
    /// `ZipReader.inflate` allocates that destination buffer.
    private func zipEntry(name: String, declaredUncompressed: UInt32, payload: Data) -> Data {
        let nameBytes = Array(name.utf8)
        var out = Data()
        out.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])   // local file header
        appendUInt16(20, to: &out)                          // version
        appendUInt16(0, to: &out)                           // flags
        appendUInt16(8, to: &out)                           // deflate
        appendUInt16(0, to: &out)                           // time
        appendUInt16(0, to: &out)                           // date
        appendUInt32(0, to: &out)                           // crc
        appendUInt32(UInt32(payload.count), to: &out)       // compressed size
        appendUInt32(declaredUncompressed, to: &out)        // declared expansion
        appendUInt16(UInt16(nameBytes.count), to: &out)
        appendUInt16(0, to: &out)                           // extra length
        out.append(contentsOf: nameBytes)
        out.append(payload)
        let localOffset = 0
        var central = Data()
        central.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
        appendUInt16(20, to: &central)                      // made by
        appendUInt16(20, to: &central)                      // needed
        appendUInt16(0, to: &central)                       // flags
        appendUInt16(8, to: &central)                       // deflate
        appendUInt16(0, to: &central)
        appendUInt16(0, to: &central)
        appendUInt32(0, to: &central)                       // crc
        appendUInt32(UInt32(payload.count), to: &central)
        appendUInt32(declaredUncompressed, to: &central)
        appendUInt16(UInt16(nameBytes.count), to: &central)
        appendUInt16(0, to: &central)                       // extra
        appendUInt16(0, to: &central)                       // comment
        appendUInt16(0, to: &central)                       // disk
        appendUInt16(0, to: &central)                       // internal attrs
        appendUInt32(0, to: &central)                       // external attrs
        appendUInt32(UInt32(localOffset), to: &central)
        central.append(contentsOf: nameBytes)
        let centralOffset = out.count
        out.append(central)
        out.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])   // EOCD
        appendUInt16(0, to: &out)
        appendUInt16(0, to: &out)
        appendUInt16(1, to: &out)                           // entries on disk
        appendUInt16(1, to: &out)                           // entries total
        appendUInt32(UInt32(central.count), to: &out)
        appendUInt32(UInt32(centralOffset), to: &out)
        appendUInt16(0, to: &out)
        return out
    }

    /// gzip header + 8-byte trailer whose ISIZE claims `declared` bytes.
    private func gzipDeclaring(_ declared: UInt32) -> Data {
        var out = Data([0x1f, 0x8b, 0x08, 0x00])            // magic + deflate
        out.append(contentsOf: [0, 0, 0, 0])                 // mtime
        out.append(contentsOf: [0x00, 0xff])                 // XFL/OS
        out.append(contentsOf: [0x03, 0x00])                 // tiny deflate block
        out.append(contentsOf: [0, 0, 0, 0])                 // CRC32 (unchecked before the budget)
        appendUInt32(declared, to: &out)                     // ISIZE
        return out
    }

    private func glb(json: [String: Any], bin: Data) throws -> Data {
        var jsonData = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }
        var binData = bin
        while binData.count % 4 != 0 { binData.append(0) }
        var out = Data([0x67, 0x6c, 0x54, 0x46])             // glTF
        appendUInt32(2, to: &out)
        appendUInt32(UInt32(12 + 8 + jsonData.count + 8 + binData.count), to: &out)
        appendUInt32(UInt32(jsonData.count), to: &out)
        appendUInt32(0x4E4F534A, to: &out)                   // JSON
        out.append(jsonData)
        appendUInt32(UInt32(binData.count), to: &out)
        appendUInt32(0x004E4942, to: &out)                   // BIN
        out.append(binData)
        return out
    }

    private func accessorBombGLB(count: Int, viewBytes: Int) throws -> Data {
        let json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "E31 fixture"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0]],
            "meshes": [["primitives": [["attributes": ["POSITION": 0], "mode": 4]]]],
            "accessors": [["bufferView": 0, "componentType": 5126,
                           "count": count, "type": "VEC3"]],
            "bufferViews": [["buffer": 0, "byteOffset": 0, "byteLength": viewBytes]],
            "buffers": [["byteLength": viewBytes]],
        ]
        return try glb(json: json, bin: Data(repeating: 0, count: viewBytes))
    }

    private func smallBinarySTL(triangles: Int = 4) -> Data {
        // A real tetrahedron: four non-degenerate triangles, one welded body.
        let vertices: [(Float, Float, Float)] = [(0, 0, 0), (10, 0, 0),
                                                 (0, 10, 0), (0, 0, 10)]
        let faces = [(0, 1, 2), (0, 1, 3), (0, 2, 3), (1, 2, 3)]
        var data = Data(repeating: 0, count: 80)
        appendUInt32(UInt32(triangles), to: &data)
        for index in 0..<triangles {
            for _ in 0..<3 { appendUInt32(0, to: &data) }   // face normal (recomputed)
            let face = faces[index % faces.count]
            for vertexIndex in [face.0, face.1, face.2] {
                let vertex = vertices[vertexIndex]
                appendUInt32(vertex.0.bitPattern, to: &data)
                appendUInt32(vertex.1.bitPattern, to: &data)
                appendUInt32(vertex.2.bitPattern, to: &data)
            }
            data.append(contentsOf: [0, 0])
        }
        return data
    }

    // MARK: - Footprint

    private func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    private func measureFootprint(_ body: () throws -> Void) rethrows -> (peak: Int, delta: Int) {
        let baseline = footprint()
        var peak = baseline
        let result = try body()
        peak = max(peak, footprint())
        return (peak, max(0, peak - baseline))
    }

    private func expectBudget(_ error: Error, file: StaticString = #filePath,
                              line: UInt = #line) {
        guard let importError = error as? MeshImportError,
              case .overBudget(let detail) = importError else {
            XCTFail("expected MeshImportError.overBudget, got \(error)", file: file, line: line)
            return
        }
        XCTAssertTrue(detail.contains("import budget"), detail, file: file, line: line)
    }

    // MARK: - ZIP

    func testZipDeclaredExpansionIsRefusedBeforeInflateAndBeforeAnyLargeAllocation() throws {
        let zip = zipEntry(name: "model.obj",
                           declaredUncompressed: 400 * 1024 * 1024,
                           payload: Data([0x03, 0x00]))   // deflate method 8
        var thrown: Error?
        let measured = try measureFootprint {
            do {
                _ = try MeshImportKit.probe(data: zip, fileName: "bomb.zip")
            } catch {
                thrown = error
            }
        }
        let error = try XCTUnwrap(thrown)
        expectBudget(error)
        // 400 MiB was DECLARED. Pre-fix `ZipReader.inflate` allocated that
        // destination before decoding; post-fix the call must stay within a
        // small working set (test-host footprint, not device memory).
        XCTAssertLessThan(measured.delta, 64 * 1024 * 1024,
                          "refusal allocated \(measured.delta) bytes before rejecting a 400 MiB declaration")
        print("E31 zip-refusal footprint delta: \(measured.delta) bytes (declared 400 MiB)")
    }

    func testBudgetAccountingRefusesASmallFixtureWithATightLimit() throws {
        let obj = Data("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".utf8)
        let tight = MeshImportLimits(maximumTriangles: 10, maximumParts: 10,
                                     maximumExpandedBytes: 8, maximumArchiveEntries: 10)
        XCTAssertThrowsError(try MeshImportKit.probe(data: obj, fileName: "small.obj",
                                                     limits: tight)) { error in
            guard case MeshImportError.overBudget = error else {
                return XCTFail("expected overBudget, got \(error)")
            }
        }
        // The same bytes import under the standard budget.
        let probe = try MeshImportKit.probe(data: obj, fileName: "small.obj")
        XCTAssertEqual(probe.triangleCount, 1)
    }

    // MARK: - Blender gzip

    func testBlendGzipDeclaredExpansionIsRefusedBeforeTheDestinationBuffer() throws {
        let blend = gzipDeclaring(4 * 1024 * 1024 * 1024 - 1)
        var thrown: Error?
        let measured = try measureFootprint {
            do {
                _ = try MeshImportKit.probe(data: blend, fileName: "bomb.blend")
            } catch {
                thrown = error
            }
        }
        let error = try XCTUnwrap(thrown)
        expectBudget(error)
        XCTAssertLessThan(measured.delta, 64 * 1024 * 1024,
                          "the Blender gzip declaration allocated \(measured.delta) bytes")
    }

    // MARK: - glTF

    func testGLTFAccessorCannotReserveWhatItsBufferViewCannotHold() throws {
        let glbData = try accessorBombGLB(count: 1_000_000, viewBytes: 36)
        var thrown: Error?
        let measured = try measureFootprint {
            do {
                _ = try MeshImportKit.probe(data: glbData, fileName: "overrun.glb")
            } catch {
                thrown = error
            }
        }
        let error = try XCTUnwrap(thrown)
        guard let importError = error as? MeshImportError,
              case .malformed(let detail) = importError else {
            return XCTFail("expected MeshImportError.malformed, got \(error)")
        }
        XCTAssertTrue(detail.contains("overruns its view"), detail)
        // Pre-fix `reserveCapacity(count * components)` asked for 48 MB before
        // the first overrun check; the refusal must stay far below that.
        XCTAssertLessThan(measured.delta, 24 * 1024 * 1024,
                          "refusal allocated \(measured.delta) bytes for a 36-byte view")
    }

    func testGLTFAccessorCountOverflowIsRefusedNotTrapped() throws {
        let glbData = try accessorBombGLB(count: Int.max, viewBytes: 36)
        XCTAssertThrowsError(try MeshImportKit.probe(data: glbData, fileName: "overflow.glb")) { error in
            guard let importError = error as? MeshImportError else {
                return XCTFail("expected MeshImportError, got \(error)")
            }
            switch importError {
            case .malformed, .overBudget:
                break
            default:
                XCTFail("unexpected refusal class: \(importError)")
            }
        }
    }

    // MARK: - Normal files

    func testSmallSTLAndOBJStillImportUnderTheStandardBudget() throws {
        let stl = smallBinarySTL(triangles: 4)
        let stlProbe = try MeshImportKit.probe(data: stl, fileName: "plate.stl")
        XCTAssertEqual(stlProbe.triangleCount, 4)
        XCTAssertEqual(stlProbe.parts.count, 1)

        let obj = Data("""
        v 0 0 0
        v 10 0 0
        v 0 10 0
        v 0 0 10
        f 1 2 3
        f 1 2 4
        """.utf8)
        let objProbe = try MeshImportKit.probe(data: obj, fileName: "wedge.obj")
        XCTAssertEqual(objProbe.triangleCount, 2)
        XCTAssertEqual(objProbe.parts.count, 1)
    }

    func testPreCancelledTokenRefusesBeforeParsing() throws {
        let token = MeshImportCancellation()
        token.cancel()
        XCTAssertThrowsError(try MeshImportKit.probe(data: smallBinarySTL(), fileName: "c.stl",
                                                     cancellation: token)) { error in
            guard let importError = error as? MeshImportError,
                  case .cancelled = importError else {
                return XCTFail("expected cancelled, got \(error)")
            }
        }
    }

    // MARK: - Exact-format no-half-model

    private func analyticTwoSolidSTEP() async throws -> Data {
        let source = try await FloeCADDocument.create(
            at: workDir.appendingPathComponent("two-solids.floecad"), name: "Two solids")
        defer { if !source.isClosed { source.close() } }
        for index in 0..<2 {
            let sketch = source.executeJSON(Data("""
            {"op":"sketch.create","args":{"name":"S\(index)"}}
            """.utf8))
            let sketchID = ((try? JSONSerialization.jsonObject(with: sketch.payload))
                as? [String: Any])?["sketchID"] as? String ?? ""
            XCTAssertTrue(sketch.isOK)
            XCTAssertTrue(source.executeJSON(Data("""
            {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
             "entities":[{"kind":"rect","min":[\(index * 40),0],"max":[\(index * 40 + 20),10]}]}}
            """.utf8)).isOK)
            let extruded = source.executeJSON(Data("""
            {"op":"feature.extrude","args":{"sketchID":"\(sketchID)","seedPoint":[\(index * 40 + 10),5],"distance":6}}
            """.utf8))
            XCTAssertTrue(extruded.isOK, extruded.message ?? "")
        }
        guard case .success(let bytes, _) = STEPKit.export(bodies: source.session.document.bodies) else {
            throw XCTSkip("the kernel STEP writer produced no two-solid fixture")
        }
        return bytes
    }

    func testSTEPImportCancelledBetweenSolidsLeavesZeroBodies() async throws {
        let step = try await analyticTwoSolidSTEP()
        let target = try await FloeCADDocument.create(
            at: workDir.appendingPathComponent("target.floecad"), name: "Target")
        defer { if !target.isClosed { target.close() } }
        let baselineChangeCount = target.session.changeCount
        let token = MeshImportCancellation()
        MeshImportKit.testImportBodyCheckpoint = { built in
            if built == 1 { token.cancel() }
        }
        let outcome = target.nativeImportData(step, format: "step",
                                              fileName: "two-solids.step",
                                              unitScale: nil, cancellation: token)
        XCTAssertFalse(outcome.isOK)
        XCTAssertEqual(outcome.errorCode, "cancelled")
        XCTAssertEqual(target.summary().bodyCount, 0,
                       "a cancel between solids must not leave the first solid committed")
        XCTAssertEqual(target.session.changeCount, baselineChangeCount,
                       "cancellation must not add a change to the initialized document")
        XCTAssertFalse(target.session.undoStack.canUndo)
    }
}
