// SPDX-License-Identifier: MPL-2.0
// Protocol/storage boundary tests only. Synthetic IFC headers do not stand in
// for IFC geometry, on-device WebKit execution, or full-App UI acceptance.
#if canImport(UIKit) && DEBUG
import Foundation
import UIKit
import XCTest
import FloeCAD
import FloeCore
@testable import FloeApp

@MainActor
final class CADNativeStudyReceiptTests: XCTestCase {
    private var root: URL!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeStudyReceipts-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { if let root { try? FileManager.default.removeItem(at: root) } }
    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: .sortedKeys).write(to: url, options: .atomic)
    }
    private func png(_ width: Int = 64) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: width), format: format).pngData { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0,y: 0,width: width,height: width))
        }
    }
    private func renderFixture(_ image: Data) throws -> (CADOfflineRenderOperation, URL) {
        let source = try folder("Renders/source"), archive = try folder("render-archive")
        let scene = Data("# immutable render fixture\nWorldBegin\n".utf8)
        try scene.write(to: source.appendingPathComponent("scene.pbrt")); try image.write(to: source.appendingPathComponent("render.png"))
        try writeJSON(["backend":"pbrt-v4","revision":CADOfflineRenderCommands.revision,
            "sceneSHA256":FloeDigest.sha256Hex(scene),"imageSHA256":FloeDigest.sha256Hex(image)], to: source.appendingPathComponent("result.json"))
        let operation = CADOfflineRenderOperation(id: UUID(), documentURL: root.appendingPathComponent("Scene.floecad"),
            workspaceRoot: root, conversationID: UUID(), environmentID: "fixture-linux", runID: UUID(),
            relativeDirectory: "Renders/source", payload: Data(), settings: .init(width:64,height:64),
            revision: 0, changeCount: 0, sourceSHA256: "saved-document", inputHashes: ["scene.pbrt":FloeDigest.sha256Hex(scene)],
            warnings: [], state: .rendering, createdAt: Date())
        return (operation, archive)
    }
    func testRenderReceiptCopiesDecodedPixelsAndRejectsChangedScene() throws {
        let image = png(), (operation, archive) = try renderFixture(image)
        XCTAssertEqual(try CADOfflineRenderCenter.verifyAndArchive(operation, archive: archive), FloeDigest.sha256Hex(image))
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("render.png")), image)
        try Data("changed scene".utf8).write(to: root.appendingPathComponent("Renders/source/scene.pbrt"))
        XCTAssertThrowsError(try CADOfflineRenderCenter.verifyAndArchive(operation, archive: archive))
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("render.png")), image)
    }
    func testMatchingDigestDoesNotPromoteFakeOrWrongSizePNG() throws {
        let fake = Data([137,80,78,71,13,10,26,10,0,0,0,0])
        let (operation, archive) = try renderFixture(fake)
        XCTAssertThrowsError(try CADOfflineRenderCenter.verifyAndArchive(operation, archive: archive))
        let (wrongSize, otherArchive) = try renderFixture(png(16))
        XCTAssertThrowsError(try CADOfflineRenderCenter.verifyAndArchive(wrongSize, archive: otherArchive))
    }
    private func buildingFixture() throws -> (CADBuildingProfessionalOperation, URL, [String: Any]) {
        let source = try folder("BuildingStudies/source"), archive = try folder("building-archive")
        let input = Data("{}".utf8), runner = Data("# fixed adapter receipt fixture".utf8)
        try input.write(to: source.appendingPathComponent("input.json")); try runner.write(to: source.appendingPathComponent("runner.py"))
        let ifc = Data("ISO-10303-21;\nHEADER;\nENDSEC;\nDATA;\nENDSEC;\nEND-ISO-10303-21;\n".utf8)
        try ifc.write(to: source.appendingPathComponent("model.ifc"))
        let result: [String: Any] = ["schemaVersion":1,"action":"ifc","sourceSHA256":FloeDigest.sha256Hex(input),
            "sourceRevision":0,"triangles":1,"backendVersions":["ifcopenshell":"0.9.0.post1","ifctester":"0.9.0","PyniteFEA":"3.2.1"],
            "artifacts":["model.ifc":FloeDigest.sha256Hex(ifc)]]
        try writeJSON(result, to: source.appendingPathComponent("result.json"))
        return (CADBuildingProfessionalOperation(id: UUID(), action: .ifc,
            documentURL: root.appendingPathComponent("Building.floecad"), workspaceRoot: root,
            conversationID: UUID(), environmentID: "fixture-linux", runID: UUID(), relativeDirectory: "BuildingStudies/source",
            payload: Data(), sourceSHA256: FloeDigest.sha256Hex(input), structural: nil,
            inputHashes: ["input.json":FloeDigest.sha256Hex(input),"runner.py":FloeDigest.sha256Hex(runner)],
            revision: 0, changeCount: 0, state: .running, createdAt: Date()), archive, result)
    }
    func testBuildingReceiptRejectsWrongActionAndTruncatedIFCEvenWithNewHash() throws {
        let (operation, archive, initial) = try buildingFixture()
        _ = try CADBuildingProfessionalCenter.verifyAndArchive(operation, archive: archive)
        var result = initial; result["action"] = "mep"
        let source = root.appendingPathComponent("BuildingStudies/source")
        try writeJSON(result, to: source.appendingPathComponent("result.json"))
        XCTAssertThrowsError(try CADBuildingProfessionalCenter.verifyAndArchive(operation, archive: archive))
        result = initial
        let truncated = Data("ISO-10303-21;\nHEADER;\n".utf8)
        try truncated.write(to: source.appendingPathComponent("model.ifc"))
        result["artifacts"] = ["model.ifc":FloeDigest.sha256Hex(truncated)]
        try writeJSON(result, to: source.appendingPathComponent("result.json"))
        XCTAssertThrowsError(try CADBuildingProfessionalCenter.verifyAndArchive(operation, archive: archive))
    }
    func testBuildingOutputSymlinkIsRefusedBeforeArchiving() throws {
        let (operation, archive, _) = try buildingFixture()
        let source = root.appendingPathComponent("BuildingStudies/source/model.ifc"), outside = root.appendingPathComponent("outside.ifc")
        try FileManager.default.moveItem(at: source, to: outside)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
        XCTAssertThrowsError(try CADBuildingProfessionalCenter.verifyAndArchive(operation, archive: archive))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.appendingPathComponent("model.ifc").path))
    }
    func testDeviceBuildingReceiptRequiresFrozenInputWithoutTaskBinding() throws {
        let (historical, archive, oldResult) = try buildingFixture()
        let source = root.appendingPathComponent("BuildingStudies/source")
        var operation = historical
        operation.workspaceRoot = nil; operation.conversationID = nil; operation.environmentID = nil; operation.runID = nil
        operation.executionBackend = "device"
        operation.inputHashes = ["input.json": operation.sourceSHA256]
        var result = oldResult; result["schemaVersion"] = 2; result["backendVersions"] = ["web-ifc":"0.0.75"]
        for name in ["input.json", "model.ifc"] {
            try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: archive.appendingPathComponent(name))
        }
        try writeJSON(result, to: archive.appendingPathComponent("result.json"))
        XCTAssertEqual(try CADBuildingProfessionalCenter.verifyAndArchive(operation, archive: archive).schemaVersion, 2)
        try Data("changed local input".utf8).write(to: archive.appendingPathComponent("input.json"))
        XCTAssertThrowsError(try CADBuildingProfessionalCenter.verifyAndArchive(operation, archive: archive))
    }
}
#endif
