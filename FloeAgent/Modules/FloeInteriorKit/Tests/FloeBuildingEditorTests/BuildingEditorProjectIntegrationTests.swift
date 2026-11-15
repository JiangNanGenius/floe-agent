// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import Foundation
import XCTest
import FloeCAD
import FloeInteriorCore
import FloeBuildingRecords
import FloeBuildingProject
import FloeBuildingWorkspace
import FloeBuildingUI
import FloeBuildingCAD
@testable import FloeBuildingEditor

@MainActor
final class BuildingEditorProjectIntegrationTests:XCTestCase {
    private enum Injected:Error {case publication}
    private final class FaultSwitch:@unchecked Sendable {
        private let lock=NSLock()
        private var point:BuildingProjectFaultPoint?
        func set(_ value:BuildingProjectFaultPoint?) {lock.lock();point=value;lock.unlock()}
        func visit(_ value:BuildingProjectFaultPoint) throws {
            lock.lock();let fail=point==value;lock.unlock()
            if fail{throw Injected.publication}
        }
    }
    private func fixture(configuration:BuildingProjectConfiguration = .default,
                         _ work:(BuildingEditorProjectSession,URL,URL) async throws->Void) async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("InteriorEditor-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let project=root.appendingPathComponent("Project",isDirectory:true),library=root.appendingPathComponent("Library",isDirectory:true)
        let session=try await BuildingEditorProjectSession.create(at:project,name:"Interior qualification",assetLibraryDirectory:library,
            repositoryConfiguration:configuration)
        do {
            try await work(session,project,library)
            if !session.closed{try await session.close()}
            try FileManager.default.removeItem(at:root)
        } catch {
            if !session.closed{try? await session.close(discardWorkingCopy:false)}
            // Preserve the failed fixture for diagnosis; no retry-to-green.
            throw error
        }
    }

    func testActualRoomSourcesAndNativeIdentityReopenTogether() async throws {
        try await fixture {session,project,library in
            let initial=try await session.recordsSnapshot()
            let roomID=try await session.createRoomRecord(name:"Living",expectedRevision:initial.project.revision)
            let bytes=Data("Measured wall 4012 mm; sketch retained".utf8)
            let source=try await session.importSource(.init(kind:.note,title:"Site note",originalName:"site.txt",mediaType:"text/plain",data:bytes,roomIDs:[roomID]),
                expectedRevision:session.recordsRevision)
            try await session.createInitialRoom(recordsRoomID:roomID,widthMM:4000,depthMM:3000,heightMM:2700,wallThicknessMM:200)
            let nativeRoomID=try XCTUnwrap(session.state.roomLinks.first?.nativeRoomID)
            try await session.checkpoint()
            let identity=try XCTUnwrap(session.published?.identity)
            let generation=try XCTUnwrap(session.published?.generationID)
            try await session.close()
            let reopened=try await BuildingEditorProjectSession.open(at:project,assetLibraryDirectory:library)
            do {
                let metadata=try await reopened.recordsSnapshot()
                XCTAssertEqual(metadata.rooms.map(\.id),[roomID])
                XCTAssertEqual(reopened.state.roomLinks.first?.nativeRoomID,nativeRoomID)
                XCTAssertEqual(reopened.published?.generationID,generation)
                XCTAssertEqual(reopened.nativeDocument.savedIdentity.modelSHA256,identity.cadModelSHA256)
                let content=try await reopened.workspace.sourceContent(source.version.id,projectID:reopened.projectID)
                XCTAssertEqual(content.data,bytes)
                let model=try XCTUnwrap(reopened.cad.building())
                XCTAssertTrue(model.elements.contains{$0.id==nativeRoomID && $0.kind == .space})
                XCTAssertFalse(reopened.hasUnpublishedChanges)
                try await reopened.close()
            } catch {try? await reopened.close(discardWorkingCopy:false);throw error}
        }
    }

    func testContinuousSaveKeepsSameMountAndRecordsActor() async throws {
        try await fixture {session,_,_ in
            let directory=session.workingCopy.directoryURL,actor=session.workspace
            for name in ["Living","Kitchen"] {
                _=try await session.createRoomRecord(name:name,expectedRevision:session.recordsRevision)
                XCTAssertTrue(session.hasUnpublishedChanges)
                try await session.checkpoint()
                XCTAssertEqual(session.workingCopy.directoryURL,directory)
                XCTAssertTrue(session.workspace === actor)
                XCTAssertEqual(session.workingCopy.baseGenerationID,session.published?.generationID)
                XCTAssertFalse(session.hasUnpublishedChanges)
            }
            let metadata=try await session.recordsSnapshot()
            XCTAssertEqual(Set(metadata.rooms.map(\.name)),["Living","Kitchen"])
        }
    }

    func testExplicitRecoveryRestoresUnpublishedWorkingCopyWithoutPublishingIt() async throws {
        try await fixture {session,project,library in
            let publishedID=try XCTUnwrap(session.published?.generationID)
            let room=try await session.createRoomRecord(name:"Unpublished bedroom",expectedRevision:session.recordsRevision)
            try await session.createInitialRoom(recordsRoomID:room,widthMM:3600,depthMM:3100,heightMM:2700,wallThicknessMM:200)
            let copyID=session.workingCopy.workingCopyID
            try await session.close(discardWorkingCopy:false)
            let options=try await BuildingEditorProjectSession.recoveryOptions(at:project)
            XCTAssertTrue(options.workingCopies.contains{$0.id==copyID})
            let repository=try BuildingProjectRepository.open(at:project)
            XCTAssertEqual(try repository.currentGeneration()?.generationID,publishedID)
            let restored=try await BuildingEditorProjectSession.open(at:project,assetLibraryDirectory:library,choice:.workingCopy(copyID))
            do {
                XCTAssertTrue(restored.hasUnpublishedChanges)
                XCTAssertEqual(restored.workingCopy.workingCopyID,copyID)
                let metadata=try await restored.recordsSnapshot()
                XCTAssertEqual(metadata.rooms.first?.id,room)
                XCTAssertEqual(try repository.currentGeneration()?.generationID,publishedID)
                try await restored.checkpoint()
                XCTAssertNotEqual(try repository.currentGeneration()?.generationID,publishedID)
                try await restored.close()
            } catch {try? await restored.close(discardWorkingCopy:false);throw error}
        }
    }

    func testFailureBeforeManifestRetainsOldGenerationAndRetryableWorkingEdits() async throws {
        let fault=FaultSwitch()
        try await fixture(configuration:.init(faultHooks:.init{try fault.visit($0)})) {session,_,_ in
            let previous=try XCTUnwrap(session.published?.generationID)
            let directory=session.workingCopy.directoryURL
            _=try await session.createRoomRecord(name:"Preserved after failure",expectedRevision:session.recordsRevision)
            fault.set(.beforeManifestPublish)
            do{try await session.checkpoint();XCTFail("An injected pre-publication failure must fail")}catch{}
            XCTAssertEqual(try session.repository.currentGeneration()?.generationID,previous)
            XCTAssertEqual(session.workingCopy.directoryURL,directory)
            XCTAssertTrue(session.hasUnpublishedChanges)
            let metadata=try await session.recordsSnapshot()
            XCTAssertEqual(metadata.rooms.first?.name,"Preserved after failure")
            fault.set(nil)
            try await session.checkpoint()
            XCTAssertNotEqual(session.published?.generationID,previous)
            XCTAssertFalse(session.hasUnpublishedChanges)
        }
    }

    func testFailureAfterManifestAcknowledgesActualDurableSave() async throws {
        let fault=FaultSwitch()
        try await fixture(configuration:.init(faultHooks:.init{try fault.visit($0)})) {session,_,_ in
            let previous=try XCTUnwrap(session.published?.generationID)
            _=try await session.createRoomRecord(name:"Durable room",expectedRevision:session.recordsRevision)
            fault.set(.afterManifestPublish)
            try await session.checkpoint()
            XCTAssertNotEqual(session.published?.generationID,previous)
            XCTAssertEqual(try session.repository.currentGeneration()?.generationID,session.published?.generationID)
            XCTAssertEqual(session.workingCopy.baseGenerationID,session.published?.generationID)
            XCTAssertNotNil(session.publicationWarning)
            XCTAssertFalse(session.hasUnpublishedChanges)
            fault.set(nil)
        }
    }

    func testTwoRealFurnitureInstancesReopenWithPinnedResourcesWithoutCatalog() async throws {
        try await fixture {session,project,library in
            let furniture=try XCTUnwrap(session.furniture)
            furniture.importStarter();await furniture.waitForIdle();XCTAssertNil(furniture.errorDetails)
            furniture.place();await furniture.waitForIdle();XCTAssertNil(furniture.errorDetails)
            furniture.xText="1200";furniture.place();await furniture.waitForIdle();XCTAssertNil(furniture.errorDetails)
            XCTAssertEqual(session.cad.manifest.furniture.count,2)
            XCTAssertEqual(session.state.assetPins.count,1)
            try await session.checkpoint();try await session.close()
            try FileManager.default.removeItem(at:library)
            let reopened=try await BuildingEditorProjectSession.open(at:project,assetLibraryDirectory:library)
            do {
                XCTAssertEqual(reopened.cad.manifest.furniture.count,2)
                for binding in reopened.cad.manifest.furniture {try reopened.cad.validateFurnitureBinding(binding)}
                XCTAssertEqual(reopened.state.assetPins.count,1)
                try await reopened.close()
            } catch {try? await reopened.close(discardWorkingCopy:false);throw error}
        }
    }

    func testGeneratedFilesAndManualNoteSurviveWholeProjectReopen() async throws {
        try await fixture {session,project,library in
            let recipe=InteriorResearchSamples.cabinet(bayCount:3,shelvesPerBay:3,includeFronts:true)
            let note=CabinetManualSheetNote(text:"Verify site dimensions",positionMM:.init(30,25))
            let design=BuildingCabinetDesign(recipe:recipe,manualNotes:[note])
            _=try await session.workspace.saveComponent(.cabinet,payload:JSONEncoder().encode(design),projectID:session.projectID,
                expectedRevision:session.recordsRevision)
            _=try await session.recordsSnapshot()
            try await session.applyCabinet(.init(projectID:session.projectID,recordsRevision:session.recordsRevision,cabinetRecipe:recipe,cabinetNotes:[note]))
            let drawingWorkspace=try XCTUnwrap(session.deliveries)
            drawingWorkspace.selectedCabinetID=recipe.id
            drawingWorkspace.makeSheets();await drawingWorkspace.waitForIdle()
            XCTAssertNil(drawingWorkspace.errorDetails)
            XCTAssertEqual(drawingWorkspace.projectPages.count,1,
                           "Generated project pages must appear without a second manual refresh")
            let (directory,receipt)=try await session.exportCabinet(cabinetID:recipe.id)
            XCTAssertTrue(directory.pathComponents.contains("Deliverables"))
            XCTAssertTrue(receipt.files.contains{$0.format=="pdf" && $0.verified})
            XCTAssertEqual(receipt.pages?.count,4)
            XCTAssertEqual(Set(receipt.files.filter{$0.format=="floecad-package"}.map(\.role)),["native-2d","native-3d"])
            XCTAssertGreaterThan(receipt.native2D?.entityCount ?? 0,0)
            let svg=try String(contentsOf:directory.appendingPathComponent("CabinetCombination.svg"),encoding:.utf8)
            XCTAssertTrue(svg.contains("Verify site dimensions"))
            let originalRecord=BuildingDeliveryRecord(id:try XCTUnwrap(UUID(uuidString:directory.lastPathComponent)),
                                                      directory:directory,receipt:receipt)
            var originalKeys:[String:String]=[:]
            for file in receipt.files where BuildingIndependentCADHandoff.kind(for:file) != nil {
                let request=try await BuildingIndependentCADHandoff.prepare(record:originalRecord,file:file,projectID:session.projectID)
                originalKeys[file.role]=request.idempotencyKey
            }
            try await session.checkpoint();try await session.close()
            let reopened=try await BuildingEditorProjectSession.open(at:project,assetLibraryDirectory:library)
            do {
                let delivery=try XCTUnwrap(reopened.deliveries)
                delivery.reload();await delivery.waitForIdle();XCTAssertNil(delivery.errorDetails)
                XCTAssertEqual(delivery.records.count,1)
                XCTAssertEqual(try reopened.projectDrawingPages().count,1)
                let record=try XCTUnwrap(delivery.records.first)
                XCTAssertTrue(record.receipt.files.allSatisfy{record.fileURL($0) != nil})
                XCTAssertEqual(reopened.cad.manifest.sheet(cabinetID:recipe.id)?.manualNotes,[note])
                let space=project.deletingLastPathComponent().appendingPathComponent("registered-space",isDirectory:true)
                try FileManager.default.createDirectory(at:space,withIntermediateDirectories:true)
                var registered:[String:URL]=[:]
                var kinds=Set<BuildingIndependentCADKind>()
                let panelCount=try CabinetBuilder.build(recipe).panels.count
                let register:@MainActor (BuildingIndependentCADHandoff) async throws->Void = { request in
                    XCTAssertEqual(request.sourceProjectID,reopened.projectID)
                    kinds.insert(request.kind)
                    guard registered[request.idempotencyKey]==nil else{return}
                    let target=space.appendingPathComponent(UUID().uuidString+".floecad",isDirectory:true)
                    try FileManager.default.copyItem(at:request.packageURL,to:target)
                    let stored=await FloeCADDocument.storedIdentity(at:target)
                    let identity=try XCTUnwrap(stored)
                    XCTAssertEqual(identity.contentSHA256,request.packageIdentity.contentSHA256)
                    let document=try await FloeCADDocument.open(at:target)
                    let summary=document.summary();document.close()
                    if request.kind == .twoD {
                        XCTAssertEqual(summary.bodyCount,0);XCTAssertGreaterThan(summary.sketchCount,0)
                    } else {XCTAssertEqual(summary.bodyCount,panelCount)}
                    registered[request.idempotencyKey]=target
                }
                let nativeFiles=record.receipt.files.filter{BuildingIndependentCADHandoff.kind(for:$0) != nil}
                XCTAssertEqual(nativeFiles.count,2)
                for file in nativeFiles {
                    delivery.registerIndependentProject(record:record,file:file,projectID:reopened.projectID,using:register)
                    await delivery.waitForIdle();XCTAssertNil(delivery.errorDetails)
                    let request=try await BuildingIndependentCADHandoff.prepare(record:record,file:file,projectID:reopened.projectID)
                    XCTAssertEqual(request.idempotencyKey,originalKeys[file.role])
                    XCTAssertNotEqual(request.packageURL.standardizedFileURL,
                                      directory.appendingPathComponent(file.relativePath).standardizedFileURL,
                                      "A new working mount must retain the same handoff identity")
                    try await register(request)
                }
                XCTAssertEqual(kinds,[.twoD,.threeD]);XCTAssertEqual(registered.count,2)
                var staleFile=try XCTUnwrap(nativeFiles.first)
                staleFile.sha256=String(repeating:"0",count:64)
                var staleReceipt=record.receipt;staleReceipt.files=[staleFile]
                let stale=BuildingDeliveryRecord(id:record.id,directory:record.directory,receipt:staleReceipt)
                do {
                    _=try await BuildingIndependentCADHandoff.prepare(record:stale,file:staleFile,projectID:reopened.projectID)
                    XCTFail("A receipt with the wrong native content identity must not reach Space")
                } catch BuildingProjectStateError.identityOrSchema {}
                let pdf=try XCTUnwrap(record.receipt.files.first{$0.format=="pdf"})
                delivery.registerIndependentProject(record:record,file:pdf,projectID:reopened.projectID,using:register)
                await delivery.waitForIdle();XCTAssertNotNil(delivery.errorDetails)
                XCTAssertEqual(registered.count,2,"Drawing files must not be registered as CAD projects")
                try await reopened.close()
            } catch {try? await reopened.close(discardWorkingCopy:false);throw error}
        }
    }

    func testLateAssistantMutationAfterCloseCannotRecreateDiscardedWork() async throws {
        try await fixture {session,_,_ in
            let directory=session.workingCopy.directoryURL
            try await session.close()
            do{_=try await session.createRoomRecord(name:"Late",expectedRevision:session.recordsRevision);XCTFail("Closed mount accepted a mutation")}
            catch BuildingEditorProjectError.closed {}
            XCTAssertFalse(FileManager.default.fileExists(atPath:directory.path))
        }
    }
    func testLinkedRoomRenamesPropagateAtCheckpointAndConflictsPreserveBothValues() async throws {
        try await fixture {session,_,_ in
            let room=try await session.createRoomRecord(name:"Living",expectedRevision:session.recordsRevision)
            try await session.createInitialRoom(recordsRoomID:room,widthMM:4000,depthMM:3000,heightMM:2700,wallThicknessMM:200)
            let link=try XCTUnwrap(session.state.roomLinks.first)
            _=try await session.workspace.renameRoom(room,name:"Lounge",projectID:session.projectID,expectedRevision:session.recordsRevision)
            _=try await session.recordsSnapshot();try await session.checkpoint(expectedRecordsRevision:session.recordsRevision)
            var model=try XCTUnwrap(session.cad.building())
            let index=try XCTUnwrap(model.elements.firstIndex{$0.id==link.nativeRoomID})
            XCTAssertEqual(model.elements[index].name,"Lounge")
            model.elements[index].name="Family"
            _=try await session.cad.applyBuilding(model,expectedChangeCount:session.nativeDocument.buildingChangeCount)
            try await session.checkpoint(expectedRecordsRevision:session.recordsRevision)
            var metadata=try await session.recordsSnapshot()
            XCTAssertEqual(metadata.rooms.first?.name,"Family")
            _=try await session.workspace.renameRoom(room,name:"Record choice",projectID:session.projectID,expectedRevision:metadata.project.revision)
            model=try XCTUnwrap(session.cad.building());model.elements[index].name="Model choice"
            _=try await session.cad.applyBuilding(model,expectedChangeCount:session.nativeDocument.buildingChangeCount)
            _=try await session.recordsSnapshot()
            do{try await session.checkpoint(expectedRecordsRevision:session.recordsRevision);XCTFail("Divergent names must not overwrite one another")}
            catch BuildingEditorProjectError.roomNameConflict(let id){XCTAssertEqual(id,room)}
            metadata=try await session.recordsSnapshot()
            XCTAssertEqual(metadata.rooms.first?.name,"Record choice")
            XCTAssertEqual(try session.cad.building()?.elements[index].name,"Model choice")
            try await session.useRecordedRoomName(room)
            try await session.checkpoint()
            XCTAssertEqual(try session.cad.building()?.elements[index].name,"Record choice")
        }
    }
    func testOldAssistantContextCannotFollowReopenedMountAndOldRevisionCannotHideDirtyWork() async throws {
        try await fixture {session,_,_ in
            let old=session.assistantContext(),oldDirectory=session.workingCopy.directoryURL
            let oldDocument=try old.nativeDocument
            let baseline=session.recordsRevision
            _=try await old.createRoomRecord(name:"Unpublished",expectedRevision:baseline)
            let currentRevision=session.recordsRevision
            session.noteRecordsRevision(projectID:session.projectID,revision:baseline)
            XCTAssertEqual(session.recordsRevision,currentRevision)
            XCTAssertTrue(session.hasUnpublishedChanges)
            try await session.reopenSavedMount()
            XCTAssertTrue(oldDocument.isClosed)
            XCTAssertFalse(FileManager.default.fileExists(atPath:oldDirectory.path))
            do{_=try await old.createRoomRecord(name:"Late old assistant",expectedRevision:baseline);XCTFail("Retired context followed a replacement mount")}
            catch BuildingEditorProjectError.closed {}
            do{_=try old.nativeDocument;XCTFail("Retired context exposed a replacement CAD document")}
            catch BuildingEditorProjectError.closed {}
            let fresh=session.assistantContext()
            let initial=try await fresh.recordsSnapshot()
            XCTAssertTrue(initial.rooms.isEmpty)
            _=try await fresh.createRoomRecord(name:"New mount",expectedRevision:initial.project.revision)
            let metadata=try await fresh.recordsSnapshot()
            XCTAssertEqual(metadata.rooms.map(\.name),["New mount"])
        }
    }
    func testOneApartmentWorkflowPublishesRoomsSourcesFurnitureCabinetAndDeliverablesTogether() async throws {
        try await fixture {session,project,library in
            let room=try await session.createRoomRecord(name:"Living",expectedRevision:session.recordsRevision)
            let original=Data("Site sketch: living room, measured wall 4012 mm".utf8)
            let imported=try await session.importSource(.init(kind:.sketch,title:"Site sketch notes",originalName:"site-sketch.txt",mediaType:"text/plain",data:original,roomIDs:[room]),expectedRevision:session.recordsRevision)
            try await session.createInitialRoom(recordsRoomID:room,widthMM:4000,depthMM:3000,heightMM:2700,wallThicknessMM:200)
            session.selectFurnitureRoom(room)
            let furniture=try XCTUnwrap(session.furniture)
            furniture.importStarter();await furniture.waitForIdle();XCTAssertNil(furniture.errorDetails)
            furniture.xText="1000";furniture.yText="1000";furniture.place();await furniture.waitForIdle()
            XCTAssertNil(furniture.errorDetails)
            let recipe=InteriorResearchSamples.cabinet(bayCount:3,shelvesPerBay:3,includeFronts:true)
            try await session.applyCabinet(.init(projectID:session.projectID,recordsRevision:session.recordsRevision,selectedRoomID:room,cabinetRecipe:recipe))
            try await session.makeSheets(cabinetID:recipe.id)
            let (_,receipt)=try await session.exportCabinet(cabinetID:recipe.id)
            XCTAssertEqual(receipt.pages?.count,4)
            XCTAssertEqual(receipt.files.count,14)
            XCTAssertGreaterThan(receipt.native2D?.entityCount ?? 0,0)
            try await session.checkpoint()
            let generation=try XCTUnwrap(session.published?.generationID)
            try await session.close()
            try FileManager.default.removeItem(at:library)
            let restored=try await BuildingEditorProjectSession.open(at:project,assetLibraryDirectory:library)
            do {
                XCTAssertEqual(restored.published?.generationID,generation)
                let records=try await restored.recordsSnapshot()
                XCTAssertEqual(records.rooms.map(\.id),[room])
                let content=try await restored.sourceContent(imported.version.id)
                XCTAssertEqual(content.data,original)
                XCTAssertEqual(restored.cad.manifest.cabinets.first?.panelBindings.count,19)
                XCTAssertEqual(restored.cad.manifest.sheets.first?.detailSheets?.count,3)
                let placed=try XCTUnwrap(restored.cad.manifest.furniture.first)
                XCTAssertEqual(placed.placementInput.roomID,restored.state.roomLinks.first?.nativeRoomID)
                try restored.cad.validateFurnitureBinding(placed)
                let outputs=try XCTUnwrap(restored.deliveries)
                outputs.reload();await outputs.waitForIdle();XCTAssertNil(outputs.errorDetails)
                XCTAssertEqual(outputs.records.first?.receipt.files.count,14)
                XCTAssertFalse(restored.hasUnpublishedChanges)
                try await restored.close()
            } catch {try? await restored.close(discardWorkingCopy:false);throw error}
        }
    }
}
#endif
