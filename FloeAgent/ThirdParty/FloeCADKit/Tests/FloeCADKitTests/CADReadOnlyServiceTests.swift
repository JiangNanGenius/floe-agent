import Foundation
import XCTest
@testable import FloeCAD

@MainActor
final class CADReadOnlyServiceTests: XCTestCase {
    private var directory: URL!
    private var document: FloeCADDocument!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpaqueServices-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        document?.close()
        document = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
    private func opaquePackage(drawing: Bool = false) async throws -> URL {
        let url = directory.appendingPathComponent("synthetic.floecad")
        try await CADAssociativeFormatFixture.basicPackage(at: url, drawing: drawing)
        if drawing {
            try CADAssociativeFormatFixture.rewrite(url, schema: 1) { record in
                var set = try CADDrawingSet.decode(from: record.drawings)
                for index in set.pages.indices {
                    set.pages[index].modelRevision = 0
                    set.pages[index].sourceFingerprint = nil
                }
                record.drawings = try set.encoded()
            }
        }
        try CADAssociativeFormatFixture.makeOpaque(url, kind: .definitionKind)
        document = try await FloeCADDocument.open(at: url)
        XCTAssertTrue(document.isReadOnly)
        return url
    }
    private func refused(_ reply: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(reply["ok"] as? Bool, false, "\(reply)", file: file, line: line)
        XCTAssertEqual(reply["error"] as? String, "read_only", "\(reply)", file: file, line: line)
        XCTAssertEqual(reply["mutated"] as? Bool, false, file: file, line: line)
    }

    func testEveryDirectServiceMutationRefusesBeforeSuccessAndPreservesPackage() async throws {
        let url = try await opaquePackage()
        let bytes = try CADAssociativeFormatFixture.bytes(url)
        let changeCount = document.liveChangeCount
        let undo = document.session.undoStack.undoCommands.count
        let material = CADMaterialService(document: document)
        for action in ["create", "update", "remove", "apply", "applyFaces", "reassignFaces", "mapping", "textures", "libraryImport", "environment.update", "undo", "redo"] {
            refused(material.handle(action: action, args: [:]))
        }
        let parameters = CADParameterService(document: document)
        for action in CADParameterService.actions where action != "list" && !CADThreadService.reads.contains(action) {
            refused(parameters.handle(action: action, args: [:]))
        }
        for action in CADThreadService.reads {
            XCTAssertEqual(parameters.handle(action: action, args: [:])["ok"] as? Bool, true)
        }
        let assembly = CADAssemblyService(document: document)
        for action in CADServiceOperations.mutatingAssemblyActions {
            refused(assembly.handle(action: action, args: [:]))
            refused(await assembly.handleAsync(action: action, args: [:]))
        }
        let drawing = CADDrawingService(document: document)
        for action in CADServiceOperations.mutatingDrawingActions { refused(drawing.handle(action: action, args: [:])) }
        let mesh = CADMeshService(document: document)
        for action in CADServiceOperations.mutatingMeshActions { refused(mesh.handle(action: action, args: [:])) }
        let script = CADScriptService(document: document)
        for action in CADServiceOperations.mutatingScriptActions { refused(await script.handle(action: action, args: [:])) }
        XCTAssertEqual(document.liveChangeCount, changeCount)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undo)
        XCTAssertEqual(try CADAssociativeFormatFixture.bytes(url), bytes)
        document.close()
        XCTAssertEqual(try CADAssociativeFormatFixture.bytes(url), bytes)
    }

    func testReadsLibraryPayloadExportAndDrawingProjectionDoNotPersistMetadata() async throws {
        let url = try await opaquePackage(drawing: true)
        let bytes = try CADAssociativeFormatFixture.bytes(url)
        let changeCount = document.liveChangeCount
        let drawings = document.session.document.drawingsData
        let material = CADMaterialService(document: document)
        for action in ["list", "libraryList", "libraryExport", "environment.read"] {
            let response = material.handle(action: action, args: [:])
            XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        }
        XCTAssertEqual(CADParameterService(document: document).handle(action: "list", args: [:])["ok"] as? Bool, true)
        XCTAssertEqual(CADAssemblyService(document: document).handle(action: "instances", args: [:])["ok"] as? Bool, true)
        let script = await CADScriptService(document: document).handle(action: "list", args: [:])
        XCTAssertEqual(script["ok"] as? Bool, true)
        let body = try XCTUnwrap(document.session.document.bodies.first)
        let boundary = CADMeshService(document: document).handle(action: "boundary", args: ["bodyID": body.id.raw.uuidString])
        XCTAssertEqual(boundary["ok"] as? Bool, true, "\(boundary)")
        let service = CADDrawingService(document: document)
        let set = try CADDrawingSet.decode(from: drawings)
        let page = try XCTUnwrap(set.pages.first)
        XCTAssertNil(page.sourceFingerprint, "fixture must need a fingerprint refresh")
        let projection = service.handle(action: "project", args: ["pageID": page.id.uuidString])
        XCTAssertEqual(projection["ok"] as? Bool, true, "\(projection)")
        XCTAssertEqual(projection["mutated"] as? Bool, false)
        XCTAssertEqual(document.session.document.drawingsData, drawings,
                       "a read-classified projection may compute current geometry but cannot write fingerprint metadata")
        XCTAssertEqual(document.liveChangeCount, changeCount)
        XCTAssertEqual(try CADAssociativeFormatFixture.bytes(url), bytes)
    }
}
