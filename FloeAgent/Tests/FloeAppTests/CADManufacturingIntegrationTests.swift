// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import XCTest
import FloeCAD
import FloeManufacturingCore
import FloeWorkspace
@testable import FloeApp

@MainActor
final class CADManufacturingIntegrationTests: XCTestCase {
    private func addBox(_ document: FloeCADDocument, min: [Double], max: [Double], height: Double) throws {
        let sketch = document.execute(["op":"sketch.create", "args":["name":"Machining source"]])
        XCTAssertTrue(sketch.isOK, sketch.message ?? "")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sketch.payload) as? [String:Any])
        let id = try XCTUnwrap(object["sketchID"] as? String)
        for command: [String:Any] in [
            ["op":"sketch.addEntities", "args":["sketchID":id,"entities":[["kind":"rect","min":min,"max":max]]]],
            ["op":"feature.extrude", "args":["sketchID":id,"seedPoint":[(min[0]+max[0])/2,(min[1]+max[1])/2],"distance":height]]
        ] {
            let result = document.execute(command)
            XCTAssertTrue(result.isOK, result.message ?? "")
        }
    }

    func testActualCADMeshSurvivesSaveAndRejectsChangedGeometry() async throws {
        var stage = "create CAD source"
        do {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cad-machining-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("Manufacturing"), owner = UUID()
        defer { try? ManufacturingSessions.prepareForCADMove(directory:directory); try? FileManager.default.removeItem(at:root) }
        let document = try await FloeCADDocument.create(at: root.appendingPathComponent("Document.floecad"), name: "20 mm cube")
        defer { document.close() }
        XCTAssertNil(try ManufacturingSessions.readExistingCAD(document:document,directory:directory,ownerID:owner))
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.path), "Read-only discovery must not create a draft or sample.")
        try addBox(document,min:[-10,-10],max:[10,10],height:20)
        stage = "capture actual CAD mesh"
        let model = try await ManufacturingSessions.openCAD(document:document,directory:directory,ownerID:owner)
        // Native ground is XZ, normal +Y (SketchTypes.swift). Manufacturing
        // keeps that actual world frame; only printing performs a frame change.
        XCTAssertEqual(model.study.stock.bounds.min,[-10,0,-10])
        XCTAssertEqual(model.study.stock.bounds.max,[10,20,10])
        XCTAssertEqual(model.study.source.documentID,"cad:"+owner.uuidString.lowercased())
        XCTAssertFalse(try XCTUnwrap(model.study.cam?.partMesh).triangles.isEmpty)
        XCTAssertFalse(model.study.turning.enabled)
        XCTAssertTrue(model.study.cam?.operations.isEmpty == true)
        stage = "save machining draft"
        try model.saveDraft()
        let before = model.study.source.contentSHA256
        stage = "save CAD document"
        let save = await document.save()
        XCTAssertTrue(save.succeeded,save.error ?? "")
        stage = "validate unchanged geometry after save"
        try await ManufacturingSessions.validateCADSource(document:document,model:model,ownerID:owner)
        XCTAssertEqual(model.study.source.contentSHA256,before)
        stage = "change CAD geometry"
        try addBox(document,min:[20,20],max:[24,24],height:3)
        do {
            try await ManufacturingSessions.validateCADSource(document:document,model:model,ownerID:owner)
            XCTFail("Changed CAD geometry was accepted as the calculated source.")
        } catch ManufacturingError.stale {}
        } catch { XCTFail("CAD source stage [\(stage)]: \(String(reflecting:type(of:error))) — \(error)") }
    }

    func testPersonalCADMoveKeepsStableOwnerAndSavedMachiningDraft() async throws {
        var stage = "create personal CAD"
        do {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cad-machining-move-\(UUID().uuidString)")
        let original = root.appendingPathComponent("Original"), moved = root.appendingPathComponent("Moved"), owner = UUID()
        let originalCAM = original.appendingPathComponent("Manufacturing"), movedCAM = moved.appendingPathComponent("Manufacturing")
        defer {
            try? ManufacturingSessions.prepareForCADMove(directory:originalCAM)
            try? ManufacturingSessions.prepareForCADMove(directory:movedCAM)
            try? FileManager.default.removeItem(at:root)
        }
        let document = try await FloeCADDocument.create(at:original.appendingPathComponent("Document.floecad"),name:"Moved part")
        try addBox(document,min:[-4,-4],max:[4,4],height:8)
        stage = "capture personal CAD"
        let model = try await ManufacturingSessions.openCAD(document:document,directory:originalCAM,ownerID:owner)
        stage = "configure personal machining"
        let configured = try model.study.applyingMachineSetup(.init(kind:.milling3Axis,coordinateFrame:.init(originMM:[0,0,8])))
        try model.replaceStudy(configured,expectedFingerprint:model.study.fingerprint())
        let save = await document.save(); XCTAssertTrue(save.succeeded,save.error ?? "")
        document.close()
        try ManufacturingSessions.prepareForCADMove(directory:originalCAM)
        stage = "move personal project"
        try FileManager.default.moveItem(at:original,to:moved)
        let reopened = try await FloeCADDocument.open(at:moved.appendingPathComponent("Document.floecad"))
        defer { reopened.close() }
        stage = "restore moved machining"
        let restored = try XCTUnwrap(ManufacturingSessions.readExistingCAD(document:reopened,directory:movedCAM,ownerID:owner))
        XCTAssertEqual(restored.study.machineSetup,configured.machineSetup)
        XCTAssertEqual(restored.study.source.documentID,"cad:"+owner.uuidString.lowercased())
        try await ManufacturingSessions.validateCADSource(document:reopened,model:restored,ownerID:owner)
        XCTAssertThrowsError(try ManufacturingSessions.readExistingCAD(document:reopened,directory:movedCAM,ownerID:UUID()))
        } catch { XCTFail("Personal CAD move stage [\(stage)]: \(String(reflecting:type(of:error))) — \(error)") }
    }

    func testGuardedWorkspaceMoveAndCopyCarryMachiningWithoutReusingOldResults() async throws {
        var stage = "create workspace CAD"
        do {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-cad-machining-\(UUID().uuidString)")
        let original = root.appendingPathComponent("Original/Part.floecad"), moved = root.appendingPathComponent("Moved/Renamed.floecad"), copied = root.appendingPathComponent("Copies/Copy.floecad")
        let originalCAM = CADMachiningCompanion.directory(forCADURL:original), movedCAM = CADMachiningCompanion.directory(forCADURL:moved), copiedCAM = CADMachiningCompanion.directory(forCADURL:copied)
        defer {
            for directory in [originalCAM,movedCAM,copiedCAM] { try? ManufacturingSessions.prepareForCADMove(directory:directory) }
            try? FileManager.default.removeItem(at:root)
        }
        let document = try await FloeCADDocument.create(at:original,name:"Workspace part")
        try addBox(document,min:[-4,-4],max:[4,4],height:8)
        let save = await document.save(); XCTAssertTrue(save.succeeded,save.error ?? "")
        stage = "capture workspace CAD"
        let model = try await ManufacturingSessions.openCAD(document:document,directory:originalCAM)
        var configured = try model.study.applyingMachineSetup(.init(kind:.milling3Axis,coordinateFrame:.init(originMM:[0,0,8])))
        let tool = ManufacturingCAM.Tool.researchExample(id:"workspace-mill")
        var operation = ManufacturingCAM.Operation(id:"workspace-face",name:"Face",strategy:"face",toolID:tool.id)
        operation.frame.originMM = [0,0,8]; operation.minUVMM = [-4,-4]; operation.maxUVMM = [4,4]
        configured.cam?.tools = [tool]; configured.cam?.operations = [operation]
        try model.replaceStudy(configured,expectedFingerprint:model.study.fingerprint())
        stage = "calculate native machining"
        _ = try await model.calculateAndWait()
        let archiveBytes = try Data(contentsOf:model.archiveURL)
        let service = WorkspaceFileService(guard:WorkspacePathGuard(rootURL:root))
        var activeLease:AnyObject? = try CADMachiningCompanion.storageLease(cadURL:original,directory:originalCAM)
        stage = "reject move during held workbench lease"
        try withExtendedLifetime(activeLease) {
            XCTAssertThrowsError(try service.move("Original/Part.floecad",to:"Moved/Renamed.floecad"))
        }
        activeLease = nil
        document.close()
        stage = "move workspace CAD and machining"
        try service.move("Original/Part.floecad",to:"Moved/Renamed.floecad")
        XCTAssertFalse(FileManager.default.fileExists(atPath:original.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:originalCAM.path))
        XCTAssertEqual(try Data(contentsOf:movedCAM.appendingPathComponent("latest.floemanufacturing")),archiveBytes)
        XCTAssertThrowsError(try model.saveDraft(),"An old cached owner must not recreate its moved directory.")
        let reopened = try await FloeCADDocument.open(at:moved)
        defer { reopened.close() }
        let restored = try XCTUnwrap(ManufacturingSessions.readExistingCAD(document:reopened,directory:movedCAM))
        XCTAssertEqual(restored.study.id,configured.id)
        XCTAssertNotNil(restored.artifact)
        try await ManufacturingSessions.validateCADSource(document:reopened,model:restored)
        stage = "copy workspace CAD and machining"
        try service.copy("Moved/Renamed.floecad",to:"Copies/Copy.floecad")
        let copyDocument = try await FloeCADDocument.open(at:copied)
        defer { copyDocument.close() }
        let clone = try XCTUnwrap(ManufacturingSessions.readExistingCAD(document:copyDocument,directory:copiedCAM))
        XCTAssertNotEqual(clone.study.id,restored.study.id)
        XCTAssertNotEqual(clone.study.source.documentID,restored.study.source.documentID)
        XCTAssertEqual(clone.study.source.contentSHA256,restored.study.source.contentSHA256)
        XCTAssertNil(clone.artifact,"The prior identity's toolpath must not become a new identity's calculated result.")
        XCTAssertEqual(try Data(contentsOf:copiedCAM.appendingPathComponent("recovery/original-job/latest.floemanufacturing")),archiveBytes)
        try await ManufacturingSessions.validateCADSource(document:copyDocument,model:clone)
        var updated = restored.study; updated.name = "Latest settings after move"
        try restored.replaceStudy(updated,expectedFingerprint:restored.study.fingerprint())
        reopened.close()
        stage = "move back without reviving cached writer"
        try service.move("Moved/Renamed.floecad",to:"Original/Part.floecad")
        let returnedDocument = try await FloeCADDocument.open(at:original)
        defer { returnedDocument.close() }
        let returned = try XCTUnwrap(ManufacturingSessions.readExistingCAD(document:returnedDocument,directory:originalCAM))
        XCTAssertEqual(returned.study.name,"Latest settings after move")
        XCTAssertThrowsError(try model.saveDraft(),"A rename back must not revive the old cached writer.")
        } catch { XCTFail("Workspace CAD transfer stage [\(stage)]: \(String(reflecting:type(of:error))) — \(error)") }
    }

    func testOrdinaryModelFileOpensAsActualCADBeforeManufacturing() async throws {
        var stage = "create import source"
        do {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("file-to-cad-\(UUID().uuidString)")
        var machiningDirectory:URL?
        defer {
            if let machiningDirectory { try? ManufacturingSessions.prepareForCADMove(directory:machiningDirectory) }
            try? FileManager.default.removeItem(at:root)
        }
        let sourceCAD = try await FloeCADDocument.create(at:root.appendingPathComponent("Source.floecad"),name:"Native source")
        defer { sourceCAD.close() }
        try addBox(sourceCAD,min:[-3,-3],max:[3,3],height:6)
        let bytes:Data
        switch sourceCAD.nativePrintGeometrySnapshot(expectedRevision:sourceCAD.revision,expectedChangeCount:sourceCAD.exchangeChangeCount,expectedContentSHA256:sourceCAD.contentSHA256) {
        case .success(let data,_,_): bytes = data
        default: throw PersonalContentError.invalidProject
        }
        let sourceFile = root.appendingPathComponent("Cube.stl")
        try bytes.write(to:sourceFile)
        let service = PersonalContentService(root:root.appendingPathComponent("Library"))
        stage = "import original into personal files"
        let original = try await service.importFile(sourceFile,folders:[])
        stage = "convert original into native CAD"
        let copy = try await PersonalCADImport.open(record:original,title:"Editable cube",unitScale:1,cancellation:.init(),service:service)
        XCTAssertEqual(copy.kind,.cad3D)
        XCTAssertNotEqual(copy.id,original.id)
        let retainedOriginal = try await service.originalFile(original.id)
        XCTAssertEqual(try Data(contentsOf:retainedOriginal),bytes)
        let location = try await service.library().resolve(copy.id)
        let document = try await FloeCADDocument.open(at:location.url.appendingPathComponent("Document.floecad"))
        defer { document.close() }
        XCTAssertEqual(document.summary().bodyCount,1)
        let directory = location.url.appendingPathComponent("Manufacturing")
        machiningDirectory = directory
        stage = "capture imported CAD for machining"
        let model = try await ManufacturingSessions.openCAD(document:document,directory:directory,ownerID:copy.id)
        // This STL was exported from the same Y-up CAD world. Import must
        // retain its actual coordinates, rather than silently rotate to Z-up.
        XCTAssertEqual(model.study.stock.bounds.min,[-3,0,-3])
        XCTAssertEqual(model.study.stock.bounds.max,[3,6,3])
        } catch { XCTFail("File-to-CAD stage [\(stage)]: \(String(reflecting:type(of:error))) — \(error)") }
    }

}
#endif
