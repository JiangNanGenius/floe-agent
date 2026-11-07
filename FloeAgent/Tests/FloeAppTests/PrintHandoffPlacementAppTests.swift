// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeCAD
import FloePrintCore
@testable import FloeApp

@Suite("Print source placement", .serialized)
@MainActor struct PrintHandoffPlacementAppTests {
    private func box(low: [Float], high: [Float]) throws -> PrintMesh {
        let vertices = [[low[0],low[1],low[2]],[high[0],low[1],low[2]],
            [high[0],high[1],low[2]],[low[0],high[1],low[2]],
            [low[0],low[1],high[2]],[high[0],low[1],high[2]],
            [high[0],high[1],high[2]],[low[0],high[1],high[2]]]
        let faces = [[0,2,1],[0,3,2],[4,5,6],[4,6,7],[0,1,5],[0,5,4],
            [1,2,6],[1,6,5],[2,3,7],[2,7,6],[3,0,4],[3,4,7]]
        return try PrintMesh(positions: faces.flatMap { $0.flatMap { vertices[$0] } })
    }
    private func bounds(_ mesh: PrintMesh) -> (low: [Float], high: [Float]) {
        var low = [Float](repeating: .infinity,count:3), high = [Float](repeating: -.infinity,count:3)
        for i in stride(from:0,to:mesh.positions.count,by:3) {
            for axis in 0..<3 { low[axis] = min(low[axis],mesh.positions[i+axis]); high[axis] = max(high[axis],mesh.positions[i+axis]) }
        }
        return (low,high)
    }
    private func stl(_ mesh: PrintMesh) -> Data {
        var bytes = Data(count:80)
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of:&value) { bytes.append(contentsOf:$0) } }
        u32(UInt32(mesh.triangleCount))
        for i in stride(from:0,to:mesh.positions.count,by:9) {
            for _ in 0..<3 { u32(0) }
            for k in 0..<9 { u32(mesh.positions[i+k].bitPattern) }
            bytes.append(contentsOf:[0,0])
        }
        return bytes
    }
    private func addBox(_ document: FloeCADDocument, offset: Double = 0) async throws {
        let made = document.execute(["op":"sketch.create","args":["name":"Placement source"]])
        try #require(made.isOK)
        let payload = try #require(JSONSerialization.jsonObject(with:made.payload) as? [String:Any])
        let id = try #require(payload["sketchID"] as? String)
        for command: [String:Any] in [
            ["op":"sketch.addEntities","args":["sketchID":id,"entities":[["kind":"rect","min":[offset,offset],"max":[offset+4,offset+6]]]]],
            ["op":"feature.extrude","args":["sketchID":id,"seedPoint":[offset+2,offset+3],"distance":2.0]]
        ] { let result = document.execute(command); try #require(result.isOK) }
        let saved = await document.save(); try #require(saved.succeeded)
    }

    @Test func exchangeFileKeepsItsZUpOrientationAndOriginalWhileBeingPlacedOnTheBed() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("print-placement-\(UUID())")
        try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:temporary) }
        // Unequal dimensions and nonzero height expose an accidental Y/Z swap.
        let original = try box(low:[10,20,30],high:[12,24,36]), bytes = stl(original)
        let sourceURL = temporary.appendingPathComponent("Contract Z-up \(UUID().uuidString.prefix(8)).stl"); try bytes.write(to:sourceURL)
        let service = PersonalContentService.shared
        let record = try await service.importFile(sourceURL,folders:[])
        let request = try await PrintProjectHandoff.personalRequest(record:record,document:nil)
        #expect(request.requiresMeshUnits)
        let child = try await request.prepare("Contract Z-up print \(UUID().uuidString.prefix(8))",1,nil)
        let location = try await service.library().resolve(child.id)
        let disk = PrintProjectDisk(root:location.url.appendingPathComponent("Printing")), saved = try await disk.load()
        let provenance = try #require(saved.sourceSnapshot), placement = try #require(provenance.initialPlacement)
        #expect(provenance.kind == .file && provenance.sourceContentSHA256 == StudioToolOutput.hash(bytes))
        #expect(placement.sourceFrame == .fileCoordinatesZUp)
        #expect(placement.rotationRows == [1,0,0,0,1,0,0,0,1])
        #expect(placement.translationMM == [-11,-22,-30])
        let sourceMesh = try await disk.meshAsset(provenance.geometryAsset), placed = try await disk.mesh(saved)
        #expect(sourceMesh.sha256 == provenance.geometrySHA256)
        #expect(sourceMesh.triangleCount == original.triangleCount && placed.triangleCount == original.triangleCount)
        #expect(bounds(sourceMesh).low == [10,20,30] && bounds(sourceMesh).high == [12,24,36])
        #expect(bounds(placed).low == [-1,-2,0] && bounds(placed).high == [1,2,6])
        #expect(placed == (try placement.applying(to:sourceMesh)))
        #expect(placed.sha256 == placement.geometrySHA256 && saved.meshAsset == placement.geometryAsset)
        _ = try PrintInput(mesh:placed,preset:saved.preset)
        let retained = try await service.originalFile(record.id)
        #expect(try Data(contentsOf:retained) == bytes)
        #expect(try await PrintProjectDisk(root:location.url.appendingPathComponent("Printing")).load().sourceSnapshot?.initialPlacement == placement)
    }

    @Test func initialPlacementNeverScalesOrClipsAnOversizedPartToBypassBedValidation() async throws {
        let source = try box(low:[-150,10,-10],high:[150,18,10]), originalHash = source.sha256
        let prepared = try await PrintInitialPlacement.prepare(source,sourceFrame:.cadWorldYUp)
        #expect(source.sha256 == originalHash)
        #expect(prepared.placement.rotationRows == [1,0,0,0,0,-1,0,1,0])
        #expect(prepared.placement.translationMM == [0,0,-10])
        #expect(bounds(prepared.mesh).low == [-150,-10,0] && bounds(prepared.mesh).high == [150,10,8])
        #expect(prepared.mesh.triangleCount == source.triangleCount)
        #expect(throws:PrintError.outsideBed) { try PrintInput(mesh:prepared.mesh,preset:.genericMarlinPLA) }
        let receipt = try JSONDecoder().decode(PrintInitialPlacement.self,from:JSONEncoder().encode(prepared.placement))
        #expect(receipt == prepared.placement)
        #expect(try receipt.applying(to:source).sha256 == prepared.mesh.sha256)
    }

    @Test func cancellationAndStaleCoverageCannotPublishAChangedCADAsANewPrintOriginal() async throws {
        let service = PersonalContentService.shared, library = try await service.library()
        let source = try await service.create(kind:.cad3D,title:"Contract fenced print source \(UUID().uuidString.prefix(8))")
        let location = try await library.resolve(source.id)
        let document = try await PersonalCADSessions.open(id:source.id,directory:location.url)
        defer { document.close() }
        try await addBox(document)
        let coverage: CADExchangeCoverage, original: Data
        switch document.nativePrintGeometrySnapshot(expectedRevision:document.revision,expectedChangeCount:document.exchangeChangeCount,
            expectedContentSHA256:document.contentSHA256) {
        case .success(let bytes,_,let receipt): original = bytes; coverage = receipt
        default: Issue.record("The actual CAD source has no complete geometry"); return
        }
        let cancelledID = UUID()
        let request = try await PrintProjectHandoff.personalRequest(record:source,document:document,projectID:cancelledID)
        let cancelled = Task { @MainActor in try await request.prepare("Cancelled print \(UUID().uuidString.prefix(8))",1,nil) }
        cancelled.cancel()
        do { _ = try await cancelled.value; Issue.record("Cancelled preparation published a print") }
        catch is CancellationError {}
        #expect(!(try await library.records()).contains { $0.id == cancelledID })
        switch document.nativePrintGeometrySnapshot(expectedRevision:document.revision,expectedChangeCount:document.exchangeChangeCount,
            expectedContentSHA256:document.contentSHA256) {
        case .success(let bytes,_,_): #expect(bytes == original)
        default: Issue.record("Cancellation changed the CAD source")
        }
        let staleID = UUID()
        let stale = try await PrintProjectHandoff.personalRequest(record:source,document:document,projectID:staleID)
        try await addBox(document,offset:20)
        do { _ = try await stale.prepare("Stale print \(UUID().uuidString.prefix(8))",1,coverage); Issue.record("Old source coverage was reused") }
        catch PrintHandoffError.sourceChanged {}
        #expect(!(try await library.records()).contains { $0.id == staleID })
    }
}
#endif
