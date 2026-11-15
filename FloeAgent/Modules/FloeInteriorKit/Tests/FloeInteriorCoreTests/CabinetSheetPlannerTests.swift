// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeInteriorCore

final class CabinetSheetPlannerTests: XCTestCase {
    func testCombinationViewsAndDistinctDepthDimensions() throws {
        let assembly=try CabinetBuilder.build(InteriorResearchSamples.cabinet())
        let sheet=try CabinetSheetPlanner.make(assembly)
        XCTAssertEqual(Set(sheet.views.map(\.kind)),Set(CabinetTechnicalView.allCases))
        XCTAssertEqual(sheet.dimensions.first{$0.role=="overall-width"}?.valueMM,2400)
        XCTAssertEqual(sheet.dimensions.first{$0.role=="overall-height"}?.valueMM,2400)
        XCTAssertEqual(sheet.dimensions.first{$0.role=="carcass-depth"}?.valueMM,600)
        XCTAssertEqual(sheet.dimensions.first{$0.role=="overall-depth"}?.valueMM,620)
        XCTAssertEqual(sheet.views.first{$0.kind == .isometric}?.panelIDs.count,19)
        XCTAssertEqual(sheet.status,"native-adapter-budget-pending")
        XCTAssertTrue(sheet.views.allSatisfy{[5.0,10,20,25,50,100,200].contains($0.scaleDenominator)})
    }
    func testResizeRetainsManualContentAndAssociations() throws {
        var recipe=InteriorResearchSamples.cabinet()
        let original=try CabinetBuilder.build(recipe)
        var previous=try CabinetSheetPlanner.make(original)
        let widthID=try XCTUnwrap(previous.dimensions.first{$0.role=="overall-width"}?.id)
        previous.dimensionPresentation=[.init(dimensionID:widthID,paperOffsetMM:.init(2,3),additionalText:"现场复核")]
        previous.manualNotes=[.init(text:"保留现场收口说明",positionMM:.init(10,20))]
        recipe.widthMM=2600
        let changed=try CabinetBuilder.build(recipe),updated=try CabinetSheetPlanner.make(changed,previous:previous)
        XCTAssertEqual(updated.id,previous.id)
        XCTAssertEqual(updated.views.map(\.id),previous.views.map(\.id))
        XCTAssertEqual(updated.dimensions.first{$0.id==widthID}?.valueMM,2600)
        XCTAssertEqual(updated.dimensionPresentation,previous.dimensionPresentation)
        XCTAssertEqual(updated.manualNotes,previous.manualNotes)
        XCTAssertTrue(previous.isStale(for:changed))
        XCTAssertFalse(updated.isStale(for:changed))
        XCTAssertNotEqual(updated.sheetFingerprint,previous.sheetFingerprint)
    }
    func testRemovedPartPresentationBecomesRepairableOrphan() throws {
        var recipe=InteriorResearchSamples.cabinet()
        let old=try CabinetBuilder.build(recipe)
        var page=try CabinetSheetPlanner.make(old)
        let shelf=try XCTUnwrap(old.panels.first{$0.role == .shelf})
        let dimension=try XCTUnwrap(page.dimensions.first{$0.sourceObjectIDs==[shelf.id]})
        page.dimensionPresentation=[.init(dimensionID:dimension.id,additionalText:"保留该板说明")]
        recipe.bays[0].shelfIDs.removeFirst()
        let update=try CabinetSheetPlanner.make(CabinetBuilder.build(recipe),previous:page)
        XCTAssertEqual(update.dimensionPresentation.count,0)
        XCTAssertEqual(update.orphanedPresentation.count,1)
        XCTAssertEqual(update.orphanedPresentation[0].dimensionID,dimension.id)
        XCTAssertEqual(update.orphanedPresentation[0].additionalText,"保留该板说明")
    }
    func testSnapshotForgeryWrongCabinetAndNonfiniteLayoutRejected() throws {
        var assembly=try CabinetBuilder.build(InteriorResearchSamples.cabinet())
        let page=try CabinetSheetPlanner.make(assembly)
        assembly.panels[0].sizeMM.x+=1
        XCTAssertThrowsError(try CabinetSheetPlanner.make(assembly))
        var another=InteriorResearchSamples.cabinet();another.id=UUID()
        XCTAssertThrowsError(try CabinetSheetPlanner.make(CabinetBuilder.build(another),previous:page))
        XCTAssertThrowsError(try CabinetSheetPlanner.make(CabinetBuilder.build(InteriorResearchSamples.cabinet()),paperWidthMM:.nan))
    }
    func testSheetSnapshotRoundTripAndSourceBudgetPreservation() throws {
        let assembly=try CabinetBuilder.build(InteriorResearchSamples.cabinet())
        let page=try CabinetSheetPlanner.make(assembly)
        let reopened=try JSONDecoder().decode(CabinetCombinationSheet.self,from:JSONEncoder().encode(page))
        XCTAssertEqual(reopened,page)
        XCTAssertEqual(reopened.views.first{$0.kind == .isometric}?.panelIDs,assembly.panels.map(\.id))
        XCTAssertTrue(reopened.views.first{$0.kind == .isometric}?.adapterIssues.contains("native-drawing-source-budget-exceeded") == true)
        let underBudget=try CabinetSheetPlanner.make(CabinetBuilder.build(InteriorResearchSamples.cabinet(bayCount:1,shelvesPerBay:1)))
        XCTAssertEqual(underBudget.status,"native-render-and-save-pending")
    }
}
