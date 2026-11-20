// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloePrintCore

private func fixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else { throw PrintError.invalidArtifact }
    return try Data(contentsOf: url)
}
private func input(_ preset: PrintPreset = .genericMarlinPLA, overrides: [String: Double] = [:]) throws -> PrintInput {
    try PrintInput(mesh: PrintMesh(binarySTL: fixture("cube20.stl")), preset: preset, overrides: overrides)
}
private func request(_ value: PrintInput) -> PrintRequest {
    PrintRequest(identity: PrintRequestIdentity(projectID: UUID(), plateID: UUID(), revision: 4), input: value)
}

@Test func actualGCodeReadback() throws {
    let cube = try GCodeInspector.inspect(fixture("fdm-cube20.gcode"))
    #expect(cube.layerCount == 100)
    #expect(cube.extrusionMoves == 9820)
    #expect(abs(cube.filamentMM-1388.9423) < 0.001)
    #expect(cube.maximum == [129.8,129.8,20])
    let plate = try GCodeInspector.inspect(fixture("fdm-plate-two-solids.gcode"))
    #expect(plate.layerCount == 60)
    #expect(plate.maximum == [164.8,129.8,12])
}

@Test func actualSlicedThreeMFReadback() throws {
    let archive = try fixture("bambu-cube.gcode.3mf")
    let entries = try PrintThreeMF.plateEntries(in: archive)
    #expect(entries.map(\.plateID) == [1])
    #expect(entries[0].name == "Metadata/plate_1.gcode")
    // Selecting a plate inflates exactly that stream.
    let plate = try PrintThreeMF.plate(1, in: archive)
    #expect(plate.id == 1)
    // The embedded stream is the actual sliced plate, not a placeholder.
    let summary = try GCodeInspector.inspect(plate.data)
    #expect(summary.layerCount == 114)
    #expect(abs(summary.maximum[2] - 18) < 0.001)
    let preview = try PrintGCodePreview.read(plate.data)
    #expect(preview.layers.count == 114)
    #expect(preview.summary.extrusionMoves == summary.extrusionMoves)
    // Arcs tessellate: segment count exceeds the raw extrusion-move count.
    let segments = preview.layers.reduce(0) { $0 + $1.segments.count }
    #expect(segments > summary.extrusionMoves)
    #expect(preview.movementSeconds > 0)
}

@Test func modelOnlyThreeMFHasNoPlates() throws {
    let entries = try PrintThreeMF.plateEntries(in: fixture("bambu-cube.3mf"))
    #expect(entries.isEmpty)
    #expect(throws: PrintError.unsupportedFormat) { try PrintThreeMF.plates(in: fixture("bambu-cube.3mf")) }
}

@Test func multiPlateArchiveListsAndExtractsInOrder() throws {
    let first = Data("G90\nM82\nG1 X1 Y1 Z0.2 E1\n".utf8)
    let second = Data("G90\nM82\nG1 X2 Y2 Z0.4 E2\n".utf8)
    let archive = try makeZip(entries: [("Metadata/plate_2.gcode", second), ("Metadata/plate_1.gcode", first)])
    let entries = try PrintThreeMF.plateEntries(in: archive)
    #expect(entries.map(\.plateID) == [1, 2])
    // Whole-archive extraction stays bounded and ordered.
    let plates = try PrintThreeMF.plates(in: archive)
    #expect(plates.map(\.id) == [1, 2])
    #expect(plates[0].data == first && plates[1].data == second)
    // Selecting another plate inflates exactly that stream.
    let chosen = try PrintThreeMF.plate(2, in: archive)
    #expect(chosen.data == second)
    let preview = try PrintGCodePreview.read(chosen.data)
    #expect(preview.layers.count == 1)
    #expect(preview.summary.maximum == [2, 2, 0.4])
    #expect(throws: PrintError.unsupportedFormat) { try PrintThreeMF.plate(3, in: archive) }
}

@Test func duplicatePlateIDsAndBadChecksumsFailClosed() throws {
    let stream = Data("G90\nM82\nG1 X1 Y1 Z0.2 E1\n".utf8)
    let duplicate = try makeZip(entries: [("Metadata/plate_1.gcode", stream), ("Metadata/plate_1.gcode", stream)])
    #expect(throws: PrintError.invalidArtifact) { try PrintThreeMF.plateEntries(in: duplicate) }
    // A CRC mismatch means corrupt bytes, never a preview of the wrong toolpath.
    var corrupted = try makeZip(entries: [("Metadata/plate_1.gcode", stream)])
    guard let payloadIndex = corrupted.range(of: Data("X1 Y1".utf8))?.lowerBound else {
        throw PrintError.invalidArtifact
    }
    corrupted[payloadIndex] = corrupted[payloadIndex] &+ 1
    #expect(throws: PrintError.invalidArtifact) { try PrintThreeMF.plate(1, in: corrupted) }
}

@Test func hostileZipEntriesFailClosed() throws {
    let traversal = try makeZip(entries: [("Metadata/../plate_1.gcode", Data("G1 X1 E1\n".utf8))])
    #expect(throws: PrintError.invalidArtifact) { try PrintThreeMF.plateEntries(in: traversal) }
    let absolute = try makeZip(entries: [("/plate_1.gcode", Data("G1 X1 E1\n".utf8))])
    #expect(throws: PrintError.invalidArtifact) { try PrintThreeMF.plateEntries(in: absolute) }
    let windows = try makeZip(entries: [("Metadata\\plate_1.gcode", Data("G1 X1 E1\n".utf8))])
    #expect(throws: PrintError.invalidArtifact) { try PrintThreeMF.plateEntries(in: windows) }
    let truncated = try fixture("bambu-cube.gcode.3mf")[0..<40]
    #expect(throws: PrintError.invalidArtifact) { try PrintThreeMF.plateEntries(in: Data(truncated)) }
}

@Test func layerMovesWithoutExtrusionStillAdvanceLayers() throws {
    // Regression: the claimed-one CAD print child (2 mm box at 0.25 mm
    // layers) emits Z-only layer moves. Travels must advance the coordinate
    // state or every layer collapses to z=0.
    let bytes = try fixture("cad-child-2mm-box.gcode")
    let summary = try GCodeInspector.inspect(bytes)
    #expect(summary.layerCount == 8)
    #expect(abs(summary.maximum[2] - 2.005) < 0.001)
    let preview = try PrintGCodePreview.read(bytes)
    #expect(preview.layers.count == 8)
    #expect(abs(preview.layers.last!.z - 2.005) < 0.001)
}

@Test func extremeArcParametersNeverTrap() throws {
    let text = """
    G90
    M83
    G1 Z0.4 F600
    G1 X1 Y0 E0.5
    G3 Z0.6 I1 J0 P1e300 E0.5
    G2 X5 Y5 I1e300 J0 E0.5
    G3 X0 Y0 R1e300 E0.5
    G3 X0 Y0 R0 E0.5
    """
    // Parses cleanly: degenerate centres/radii fall back to linear motion,
    // giant P clamps without trapping Int conversion.
    let preview = try PrintGCodePreview.read(Data(text.utf8))
    #expect(preview.layers.count == 2)
    let inspected = try GCodeInspector.inspect(Data(text.utf8))
    #expect(inspected.layerCount == 2)
    // The degenerate R0 arc extrudes in place: no motion, so it is not
    // counted as an extrusion move (matching linear-move semantics).
    #expect(abs(inspected.filamentMM - 2.0) < 1e-9)
}

@Test func arcAndHelicalMovesTessellate() throws {
    // Helical full-circle arc in Bambu form (Z + IJ + P, no XY), plus a
    // partial XY arc with IJ and an R-form arc. Extruding helical steps all
    // bucket to the commanded destination layer.
    let text = """
    G90
    M83
    G1 Z0.4 F600
    G1 X1 Y0 E0.5
    G3 Z0.6 I1.217 J0 P1 F42000 E0.5
    G1 X10 Y0 E1
    G2 X20 Y0 I5 J0 E1
    G3 X20 Y10 R5 E1
    """
    let preview = try PrintGCodePreview.read(Data(text.utf8))
    #expect(preview.layers.count == 2)
    #expect(preview.summary.layerCount == 2)
    let lower = preview.layers[0].segments, upper = preview.layers[1].segments
    #expect(abs(preview.layers[0].z - 0.4) < 1e-9)
    #expect(abs(preview.layers[1].z - 0.6) < 1e-9)
    #expect(lower.count == 1 && abs(lower[0].end[2] - 0.4) < 1e-6)
    #expect(upper.count > 10) // helical tessellation + planar arcs
    #expect(abs(preview.summary.maximum[2] - 0.6) < 1e-9)
    #expect(abs(preview.summary.filamentMM - 4.0) < 1e-9)
    #expect(upper.contains { abs($0.end[2] - 0.6) < 1e-6 })
}

@Test func nonXYPlaneArcsFailClearly() throws {
    // G17 (XY) arcs are preserved; G18/G19 arcs would render wrong geometry
    // and are rejected, not approximated.
    let xy = """
    G90
    M83
    G17
    G1 Z0.2 F600
    G2 X5 Y0 I2.5 J0 E1
    """
    #expect(try GCodeInspector.inspect(Data(xy.utf8)).layerCount == 1)
    #expect(try PrintGCodePreview.read(Data(xy.utf8)).layers.count == 1)
    let zx = """
    G90
    M83
    G1 Z0.2 F600
    G18
    G2 Z2 X5 I0 K2.5 E1
    """
    #expect(throws: PrintError.unsupportedFormat) { try GCodeInspector.inspect(Data(zx.utf8)) }
    #expect(throws: PrintError.unsupportedFormat) { try PrintGCodePreview.read(Data(zx.utf8)) }
    // G17 restores XY arcs after a G18 excursion.
    let restored = """
    G90
    M83
    G18
    G17
    G1 Z0.2 F600
    G2 X5 Y0 I2.5 J0 E1
    """
    #expect(try GCodeInspector.inspect(Data(restored.utf8)).layerCount == 1)
}

@Test func arcSolverCentresAndSweeps() throws {
    // IJ: quarter arc from (10,0) around origin to (0,10).
    let ccw = PrintArcGeometry.solve(startX: 10, startY: 0, endX: 0, endY: 10,
                                     i: -10, j: 0, r: nil, clockwise: false, repeats: 1)
    #expect(ccw != nil)
    if let ccw {
        #expect(abs(ccw.centerX) < 1e-9 && abs(ccw.centerY) < 1e-9)
        #expect(abs(ccw.radius - 10) < 1e-9)
        #expect(abs(ccw.sweep - .pi / 2) < 1e-9)
    }
    // CW takes the complementary direction with the same geometry.
    let cw = PrintArcGeometry.solve(startX: 10, startY: 0, endX: 0, endY: 10,
                                    i: -10, j: 0, r: nil, clockwise: true, repeats: 1)
    #expect(cw.map { abs($0.sweep + 1.5 * .pi) < 1e-9 } == true)
    // Full circle: end equals start, IJ given, P1 → one whole revolution.
    let full = PrintArcGeometry.solve(startX: 1, startY: 0, endX: 1, endY: 0,
                                      i: -1, j: 0, r: nil, clockwise: false, repeats: 1)
    #expect(full.map { abs(abs($0.sweep) - 2 * .pi) < 1e-9 } == true)
    // R minor vs major around the same chord.
    let minor = PrintArcGeometry.solve(startX: 1, startY: 0, endX: 0, endY: 1,
                                       i: nil, j: nil, r: 1, clockwise: false, repeats: 1)
    let major = PrintArcGeometry.solve(startX: 1, startY: 0, endX: 0, endY: 1,
                                       i: nil, j: nil, r: -1, clockwise: false, repeats: 1)
    #expect(minor.map { abs($0.sweep - .pi / 2) < 1e-9 } == true)
    #expect(major.map { abs($0.sweep - 1.5 * .pi) < 1e-9 } == true)
    // Degenerate: R with no chord cannot describe a circle.
    #expect(PrintArcGeometry.solve(startX: 1, startY: 0, endX: 1, endY: 0,
                                   i: nil, j: nil, r: 5, clockwise: false, repeats: 1) == nil)
}

/// Builds a minimal single-disk ZIP from stored (method 0) entries so plate
/// listing and hostile-path rejection are tested without a fixture per case.
/// CRC32 values are real: the reader verifies them on extraction.
private func makeZip(entries: [(name: String, data: Data)]) throws -> Data {
    var archive = Data()
    var central = Data()
    for entry in entries {
        let offset = archive.count
        let nameBytes = [UInt8](entry.name.utf8)
        let crc = PrintThreeMF.crc32(entry.data)
        var local = Data()
        local.append(contentsOf: [0x50, 0x4b, 0x03, 0x04])
        local.append(UInt16(20).leBytes)          // version needed
        local.append(UInt16(0).leBytes)           // flags
        local.append(UInt16(0).leBytes)           // method: stored
        local.append(UInt16(0).leBytes)           // mod time
        local.append(UInt16(0).leBytes)           // mod date
        local.append(contentsOf: crc.leBytes)
        local.append(UInt32(entry.data.count).leBytes)
        local.append(UInt32(entry.data.count).leBytes)
        local.append(UInt16(nameBytes.count).leBytes)
        local.append(UInt16(0).leBytes)           // extra length
        local.append(contentsOf: nameBytes)
        local.append(entry.data)
        archive.append(local)
        var record = Data()
        record.append(contentsOf: [0x50, 0x4b, 0x01, 0x02])
        record.append(UInt16(20).leBytes)
        record.append(UInt16(20).leBytes)
        record.append(UInt16(0).leBytes)
        record.append(UInt16(0).leBytes)
        record.append(UInt16(0).leBytes)
        record.append(UInt16(0).leBytes)
        record.append(contentsOf: crc.leBytes)
        record.append(UInt32(entry.data.count).leBytes)
        record.append(UInt32(entry.data.count).leBytes)
        record.append(UInt16(nameBytes.count).leBytes)
        record.append(UInt16(0).leBytes)
        record.append(UInt16(0).leBytes)
        record.append(UInt16(0).leBytes)
        record.append(UInt16(0).leBytes)
        record.append(UInt32(0).leBytes)
        record.append(UInt32(offset).leBytes)
        record.append(contentsOf: nameBytes)
        central.append(record)
    }
    let centralOffset = archive.count
    archive.append(central)
    archive.append(contentsOf: [0x50, 0x4b, 0x05, 0x06])
    archive.append(UInt16(0).leBytes)
    archive.append(UInt16(0).leBytes)
    archive.append(UInt16(entries.count).leBytes)
    archive.append(UInt16(entries.count).leBytes)
    archive.append(UInt32(central.count).leBytes)
    archive.append(UInt32(centralOffset).leBytes)
    archive.append(UInt16(0).leBytes)
    return archive
}

private extension UInt16 {
    var leBytes: Data { Data([UInt8(truncatingIfNeeded: self), UInt8(truncatingIfNeeded: self >> 8)]) }
}
private extension UInt32 {
    var leBytes: Data { Data([UInt8(truncatingIfNeeded: self), UInt8(truncatingIfNeeded: self >> 8),
                              UInt8(truncatingIfNeeded: self >> 16), UInt8(truncatingIfNeeded: self >> 24)]) }
}

@Test func actualCTBReadback() throws {
    let header = try CTBHeader.inspect(fixture("sla-cube20.ctb"))
    #expect(header.version == 3 && header.layerCount == 200)
    #expect(header.widthPixels == 960 && header.heightPixels == 544)
    #expect(header.exposureSeconds == 2.5 && header.bottomExposureSeconds == 25)
    let artifact = try PrintArtifact(request: request(input(.genericCTBV3)), data: fixture("sla-cube20.ctb"))
    #expect(artifact.layerCount == 200 && artifact.sha256.count == 64)
}

@Test func actualBinarySTLAndFingerprint() throws {
    let a = try input(), b = try input()
    #expect(a.mesh.triangleCount == 12)
    #expect(a.fingerprint == b.fingerprint)
    #expect(try input(overrides:["sliceHeight":0.2]).fingerprint == a.fingerprint)
    #expect(request(a).identity != request(b).identity)
    #expect(try input(overrides: ["sliceHeight":0.3]).fingerprint != a.fingerprint)
    #expect(try input(.genericCTBV3).fingerprint != a.fingerprint)
    #expect(a.mesh.sha256.count == 64)
}

// R10 source-only regression; execution belongs to the collecting mainline.
// The pinned fixture cube is corner-based: every axis spans 0...20 mm.
@Test func sourceSTLPlanesAndRightAnglesAreNotSmoothed() throws {
    let mesh=try PrintMesh(binarySTL:fixture("cube20.stl"))
    let points=stride(from:0,to:mesh.positions.count,by:3).map { i in
        [mesh.positions[i],mesh.positions[i+1],mesh.positions[i+2]]
    }
    for axis in 0..<3 {
        let expected:ClosedRange<Float> = 0...20
        #expect(points.map { $0[axis] }.min() == expected.lowerBound)
        #expect(points.map { $0[axis] }.max() == expected.upperBound)
    }
    for start in stride(from:0,to:points.count,by:3) {
        #expect((0..<3).contains { axis in
            points[start][axis] == points[start+1][axis] && points[start][axis] == points[start+2][axis]
        })
    }
    let raw:[Float]=[3,4,0,8,4,0,3,9,0]
    #expect(try PrintMesh(positions:raw).positions == raw)
    #expect(PrintInput.adapterVersion == "floe-print-app-5")
}

@Test func hostileOrInvalidInputsAreRejected() throws {
    #expect(throws: PrintError.invalidSetting("gcodePre")) { try input(overrides:["gcodePre":1]) }
    #expect(throws: PrintError.invalidSetting("sliceHeight")) { try input(overrides:["sliceHeight":.nan]) }
    #expect(throws: PrintError.invalidArtifact) { try GCodeInspector.inspect(Data("G90\nM82\nG1 X1e300 Z1e300 E1\n".utf8)) }
    #expect(throws: PrintError.invalidMesh) { try PrintMesh(positions:[Float](repeating:0,count:9)) }
    #expect(throws: PrintError.invalidMesh) { try PrintMesh(positions:[0,0,0,1,0,0,0,1,.infinity]) }
    #expect(throws: PrintError.invalidMesh) { try PrintMesh(binarySTL:Data(repeating:0,count:83)) }
    let mesh = try PrintMesh(positions:[1000,0,0,1001,0,0,1000,1,1])
    #expect(throws: PrintError.outsideBed) { try PrintInput(mesh:mesh,preset:.genericMarlinPLA) }
}

@Test func unavailableFormatsAndWrongVersionFailClosed() throws {
    #expect(throws: PrintError.unsupportedFormat) { try PrintFormat(fileExtension:"goo") }
    #expect(throws: PrintError.unsupportedFormat) { try PrintFormat(fileExtension:"ctb") }
    #expect(throws: PrintError.unsupportedFormat) { try PrintFormat(fileExtension:"ctb",version:4) }
    var data = try fixture("sla-cube20.ctb"); data[4] = 4
    #expect(throws: PrintError.unsupportedFormat) { try CTBHeader.inspect(data) }
}

@Test func artifactRejectsBadOffsetsAndMismatchedSettings() throws {
    var data = try fixture("sla-cube20.ctb")
    data[0x40] = 255; data[0x41] = 255; data[0x42] = 255; data[0x43] = 127
    #expect(throws: PrintError.invalidArtifact) { try CTBHeader.inspect(data) }
    let changed = try input(.genericCTBV3,overrides:["slaLayerOn":3])
    #expect(throws: PrintError.invalidArtifact) { try PrintArtifact(request:request(changed),data:fixture("sla-cube20.ctb")) }
    #expect(throws: PrintError.invalidArtifact) { try GCodeInspector.inspect(Data("G21\nG1 X10 Y10\n".utf8)) }
}

private actor HeldBackend: PrintSlicingBackend {
    var entered = false
    var waiters: [CheckedContinuation<Void,Never>] = []
    var completion: CheckedContinuation<Data,any Error>?
    var cancellationCount = 0
    func waitForStart() async {
        if entered { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func slice(_ request: PrintRequest, progress: @escaping @Sendable (PrintProgress) async -> Void) async throws -> Data {
        entered = true; waiters.forEach { $0.resume() }; waiters = []
        return try await withCheckedThrowingContinuation { completion = $0 }
    }
    func cancel(jobID:UUID) async { cancellationCount += 1 }
    func finish(_ data:Data) { completion?.resume(returning:data); completion = nil }
}

@Test func cancelHoldsSlotAndRejectsLateSuccess() async throws {
    let backend = HeldBackend(), service = PrintSlicingService(backend:backend), value = try request(input())
    let running = Task { try await service.slice(value) }
    await backend.waitForStart()
    await #expect(throws: PrintError.busy) { try await service.slice(value) }
    await service.cancel(jobID:UUID())
    #expect(await backend.cancellationCount == 0)
    await service.cancel(jobID:value.identity.jobID)
    #expect(await backend.cancellationCount == 1)
    await #expect(throws: PrintError.busy) { try await service.slice(value) }
    await backend.finish(try fixture("fdm-cube20.gcode"))
    await #expect(throws: PrintError.cancelled) { try await running.value }
}

private struct FixtureBackend: PrintSlicingBackend {
    let data:Data
    func slice(_ request:PrintRequest,progress:@escaping @Sendable(PrintProgress) async -> Void) async throws -> Data { data }
    func cancel(jobID:UUID) async {}
}

@Test func nativeServiceReturnsOwnedVerifiedArtifact() async throws {
    let value = try request(input())
    let service = PrintSlicingService(backend:FixtureBackend(data:try fixture("fdm-cube20.gcode")))
    let artifact = try await service.slice(value)
    #expect(artifact.identity == value.identity)
    #expect(artifact.inputFingerprint == value.input.fingerprint && artifact.layerCount == 100)
}
