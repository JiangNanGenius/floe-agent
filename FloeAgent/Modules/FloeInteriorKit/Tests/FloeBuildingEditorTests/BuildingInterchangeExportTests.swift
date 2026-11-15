// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import XCTest
import CoreGraphics
import CryptoKit
import FloeCAD
import FloeBuildingEditor

@MainActor final class BuildingInterchangeExportTests: XCTestCase {
    func testOneChosenSolidAcrossFormatsAndNoReplacementOnFailure() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("BuildingInterchange-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let document = try await FloeCADDocument.create(at: root.appendingPathComponent("Building.floecad"), name: "Building")
        defer { document.close() }
        var building = CADBuildingDocument(name: "Two storeys")
        let ground = CADBuildingStorey(name: "Ground"), upper = CADBuildingStorey(name: "Upper", elevationMM: 4200)
        building.storeys = [ground, upper]
        let wall = CADBuildingElement(storeyID: ground.id, kind: .wall, name: "OnlyGround", a: [0, 0], b: [5000, 0])
        let beam = CADBuildingElement(storeyID: upper.id, kind: .beam, name: "OnlyUpper", a: [10000, 300], b: [13000, 300],
                                      thicknessMM: 200, heightMM: 800)
        building.elements = [wall, beam]
        try document.setBuilding(building)
        let identity = await document.save()
        XCTAssertTrue(identity.succeeded, identity.error ?? "")
        for format in [BuildingInterchangeFormat.obj, .stl, .glb, .step, .pdf, .dxf] {
            let destination = root.appendingPathComponent("OnlyUpper." + format.rawValue)
            let receipt = try await BuildingInterchangeExport.write(document: document, scope: .elements([beam.id]), format: format, to: destination)
            let data = try Data(contentsOf: destination)
            XCTAssertEqual(receipt.byteCount, data.count)
            XCTAssertEqual(receipt.sha256, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            switch format {
            case .obj:
                let obj = String(decoding: data, as: UTF8.self)
                XCTAssertTrue(obj.contains("o OnlyUpper")); XCTAssertFalse(obj.contains("OnlyGround"))
                XCTAssertEqual(obj.components(separatedBy: "\nf ").count - 1, 12)
            case .stl:
                let triangles = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self).littleEndian }
                XCTAssertEqual(triangles, 12)
            case .glb:
                let length = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self).littleEndian }
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data.subdata(in: 20..<(20 + Int(length)))) as? [String: Any])
                let meshes = try XCTUnwrap(json["meshes"] as? [[String: Any]])
                XCTAssertEqual(meshes.count, 1)
                let names = (json["nodes"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
                XCTAssertTrue(names.contains("OnlyUpper")); XCTAssertFalse(names.contains("OnlyGround"))
            case .pdf:
                XCTAssertEqual(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: data as CFData)))?.numberOfPages, 1)
            case .dxf:
                let plan = String(decoding: data, as: UTF8.self)
                XCTAssertTrue(plan.contains("OnlyUpper")); XCTAssertFalse(plan.contains("OnlyGround"))
                XCTAssertTrue(plan.contains("\n30\n4200.0\n"))
            case .step:
                let step = String(decoding: data, as: UTF8.self)
                XCTAssertEqual(step.components(separatedBy: "MANIFOLD_SOLID_BREP").count - 1, 1)
            default: XCTFail("Unexpected fixture format")
            }
        }
        let existing = root.appendingPathComponent("Retained.stl")
        let retained = Data("Original bytes".utf8)
        try retained.write(to: existing)
        do {
            _ = try await BuildingInterchangeExport.write(document: document, scope: .wholeProject, format: .stl, to: existing)
            XCTFail("An existing destination was overwritten.")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: existing), retained)
        for format in [BuildingInterchangeFormat.dwg, .ifc] {
            let destination = root.appendingPathComponent("Failed." + format.rawValue)
            do {
                _ = try await BuildingInterchangeExport.write(document: document, scope: .elements([beam.id]), format: format, to: destination,
                                                            encodeDWG: { _ in Data("incomplete".utf8) }, encodeIFC: { _ in Data("incomplete".utf8) })
                XCTFail("Invalid encoder output was accepted.")
            } catch {}
            XCTAssertFalse(fm.fileExists(atPath: destination.path))
        }
        let disk = await FloeCADDocument.storedIdentity(at: document.url)
        XCTAssertEqual(disk?.revision, identity.revision)
        XCTAssertEqual(disk?.contentSHA256, identity.contentSHA256)
    }
}
#endif
