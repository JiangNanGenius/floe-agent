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
@Test func sourceSTLPlanesAndRightAnglesAreNotSmoothed() throws {
    let mesh=try PrintMesh(binarySTL:fixture("cube20.stl"))
    let points=stride(from:0,to:mesh.positions.count,by:3).map { i in
        [mesh.positions[i],mesh.positions[i+1],mesh.positions[i+2]]
    }
    for axis in 0..<3 {
        let expected:ClosedRange<Float> = axis == 2 ? 0...20 : -10...10
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
    #expect(PrintInput.adapterVersion == "floe-print-p0-2")
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
