// SPDX-License-Identifier: MPL-2.0
#if DEBUG
import XCTest
import Foundation
@testable import FloeCAD

@MainActor final class CADM30SelectionAndGeometryContractTests: XCTestCase {
    func testHoleStableSelectionSingleTransactionUndoAndColdReopen() async throws { try await geometry(.hole) }
    func testThreadStableSelectionSingleTransactionUndoAndColdReopen() async throws { try await geometry(.thread) }
    func testSurfaceStableSelectionSingleTransactionUndoAndColdReopen() async throws { try await geometry(.surface) }
    func testDatumWithoutBodyStableSelectionSingleTransactionUndoAndColdReopen() async throws { try await geometry(.datum) }
    private func geometry(_ target: CADM30TargetDescriptor.Target) async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("M30-contract-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url=directory.appendingPathComponent("Target.floecad")
        let (doc,d)=try await CADM30SelectedTargetFixture.seed(target, at: url)
        defer { if !doc.isClosed { doc.close() } }
        let vm=doc.viewModel()
        XCTAssertTrue(doc.assistantSelectionContext().isEmpty, "Fixture must not preselect a target")
        if target == .datum { vm.selectHistoryPlane(.init(raw: try XCTUnwrap(UUID(uuidString: d.targetID)))) }
        else { vm.selectFeature(.init(raw: try XCTUnwrap(UUID(uuidString: d.targetID)))) }
        let before=doc.assistantSelectionContext()
        XCTAssertFalse(before.isEmpty)
        XCTAssertGreaterThan(before.historySelectionGeneration,0)
        if target == .datum {
            XCTAssertEqual(before.datumPlane?.id,d.targetID); XCTAssertTrue(before.bodies.isEmpty)
            XCTAssertTrue(before.features.isEmpty, "Do not forge a FeatureID for construction data")
        } else { XCTAssertEqual(before.features.map(\.id),[d.targetID]); XCTAssertFalse(before.bodies.isEmpty) }
        let other=try await FloeCADDocument.create(at:directory.appendingPathComponent("Other.floecad"),name:"Other owner")
        XCTAssertTrue(other.assistantSelectionContext().isEmpty, "Never share selection across editors")
        other.close()
        let depth=doc.session.undoStack.undoCommands.count, revision=doc.revision, model=doc.modelSHA256
        let raw=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(d.editPayloadJSON.utf8)) as? [String:Any])
        var args=raw;let action=try XCTUnwrap(args.removeValue(forKey:"action") as? String)
        let result=CADParameterService(document:doc).handle(action:action,args:args)
        XCTAssertEqual(result["ok"] as? Bool,true,"\(result)")
        XCTAssertEqual(doc.session.undoStack.undoCommands.count,depth+1,"One source edit = one Undo")
        XCTAssertNotEqual(doc.assistantSelectionContext().observationKey,before.observationKey,"Old selection context must be stale after rebuild")
        _=try CADM30SelectedTargetFixture.inspect(doc,descriptor:d,edited:true)
        let editedSave=await doc.save(); XCTAssertTrue(editedSave.succeeded)
        XCTAssertGreaterThan(doc.revision,revision); XCTAssertNotEqual(doc.modelSHA256,model)
        let stepURL=directory.appendingPathComponent("edited.step")
        switch doc.nativeExportData(format:"step", pageID:nil) {
        case .success(let output):try output.0.write(to:stepURL)
        case .failure(let error):throw error
        }
        _=try CADM30SelectedTargetFixture.inspect(doc,descriptor:d,edited:true,stepURL:stepURL)
        doc.session.undo()
        _=try CADM30SelectedTargetFixture.inspect(doc,descriptor:d,edited:false)
        let restored=await doc.save();XCTAssertTrue(restored.succeeded)
        XCTAssertEqual(doc.modelSHA256,model,"Undo must restore the exact canonical model")
        doc.close()
        let reopened=try await FloeCADDocument.open(at:url);defer {reopened.close()}
        XCTAssertEqual(reopened.modelSHA256,model)
        XCTAssertTrue(reopened.assistantSelectionContext().isEmpty,"Reopen cannot restore ephemeral UI selection")
        _=try CADM30SelectedTargetFixture.inspect(reopened,descriptor:d,edited:false)
    }
    func testPresentationAndItemsPicksReplaceFeatureIdentityButInvalidPickPreservesIt() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("M30-picks-\(UUID())")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:directory)}
        let(doc,d)=try await CADM30SelectedTargetFixture.seed(.hole,at:directory.appendingPathComponent("Pick.floecad"));defer{doc.close()}
        let vm=doc.viewModel(),feature=FeatureID(raw:try XCTUnwrap(UUID(uuidString:d.targetID)))
        let body=BodyID(raw:try XCTUnwrap(UUID(uuidString:d.bodyID)))
        vm.selectFeature(feature)
        XCTAssertFalse(vm.selectPresentation(bodyID:BodyID()))
        XCTAssertEqual(doc.assistantSelectionContext().features.map(\.id),[d.targetID])
        XCTAssertTrue(vm.selectPresentation(bodyID:body))
        XCTAssertTrue(doc.assistantSelectionContext().features.isEmpty)
        XCTAssertEqual(doc.assistantSelectionContext().bodies.map(\.id),[d.bodyID])
        vm.selectFeature(feature);vm.selectItemBody(body)
        XCTAssertTrue(doc.assistantSelectionContext().features.isEmpty,"Same-body Items pick must not retain History identity")
    }
    func testDeletedDatumDropsTypedSelectionWithoutRestoringAnotherDocument() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("M30-datum-drop-\(UUID())")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:directory)}
        let(doc,d)=try await CADM30SelectedTargetFixture.seed(.datum,at:directory.appendingPathComponent("Datum.floecad"));defer{doc.close()}
        let vm=doc.viewModel();vm.selectHistoryPlane(.init(raw:try XCTUnwrap(UUID(uuidString:d.targetID))))
        XCTAssertNotNil(doc.assistantSelectionContext().datumPlane)
        vm.undo() // remove dependent child, one real transaction
        vm.undo() // remove the actual construction plane
        XCTAssertNil(vm.selectedPlane)
        XCTAssertNil(doc.assistantSelectionContext().datumPlane)
    }
}
#endif
