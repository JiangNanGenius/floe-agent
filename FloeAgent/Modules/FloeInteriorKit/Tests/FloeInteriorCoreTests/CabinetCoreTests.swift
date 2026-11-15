// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import FloeInteriorCore

final class CabinetCoreTests: XCTestCase {
    func testCarcassDimensionsAndNoPanelVolumeOverlaps() throws {
        let assembly=try CabinetBuilder.build(InteriorResearchSamples.cabinet())
        XCTAssertEqual(assembly.panels.count,19)
        let top=try XCTUnwrap(assembly.panels.first{$0.role == .top})
        XCTAssertEqual(top.sizeMM,.init(2364,600,18))
        XCTAssertEqual(top.originMM,.init(18,0,2382))
        let shelves=assembly.panels.filter{$0.role == .shelf}
        XCTAssertEqual(shelves.count,9)
        XCTAssertEqual(shelves[0].sizeMM,.init(776,571,18))
        for i in assembly.panels.indices {
            for j in assembly.panels.indices where j>i {
                let a=assembly.panels[i],b=assembly.panels[j]
                let overlap=zip(zip(a.originMM.values,a.sizeMM.values),zip(b.originMM.values,b.sizeMM.values)).map { lhs,rhs in
                    min(lhs.0+lhs.1,rhs.0+rhs.1)-max(lhs.0,rhs.0)
                }
                XCTAssertFalse(overlap.allSatisfy{$0>0.000001},"Overlapping solids: \(a.role), \(b.role)")
            }
        }
    }
    func testResizeRetainsPartIdentityAndChangesDerivedDimensions() throws {
        let original=try CabinetBuilder.build(InteriorResearchSamples.cabinet())
        var recipe=original.recipe; recipe.widthMM=2600
        let resized=try CabinetBuilder.build(recipe)
        XCTAssertEqual(original.panels.map(\.id),resized.panels.map(\.id))
        XCTAssertEqual(resized.panels.first{$0.role == .top}?.sizeMM.x,2564)
        XCTAssertNotEqual(original.geometryFingerprint,resized.geometryFingerprint)
        let a=try CabinetDerivations.drawingPlans(original)
        let b=try CabinetDerivations.drawingPlans(resized)
        XCTAssertTrue(zip(a,b).allSatisfy{$0.fingerprint != $1.fingerprint})
    }
    func testMaterialVersionInvalidatesScheduleWithoutChangingGeometry() throws {
        let original=try CabinetBuilder.build(InteriorResearchSamples.cabinet())
        var recipe=original.recipe; recipe.carcassMaterial.version="2"
        let updated=try CabinetBuilder.build(recipe)
        XCTAssertEqual(original.geometryFingerprint,updated.geometryFingerprint)
        XCTAssertNotEqual(original.scheduleFingerprint,updated.scheduleFingerprint)
        let originalPlans=try CabinetDerivations.drawingPlans(original)
        let updatedPlans=try CabinetDerivations.drawingPlans(updated)
        XCTAssertEqual(originalPlans.first{$0.kind == .front}?.fingerprint,updatedPlans.first{$0.kind == .front}?.fingerprint)
        XCTAssertNotEqual(originalPlans.first{$0.kind == .partsSchedule}?.fingerprint,updatedPlans.first{$0.kind == .partsSchedule}?.fingerprint)
    }
    func testFrontDepthAndNativeCoordinateConventionAreExplicit() throws {
        let assembly=try CabinetBuilder.build(InteriorResearchSamples.cabinet())
        let front=try XCTUnwrap(assembly.panels.first{$0.role == .front})
        XCTAssertEqual(front.originMM.y,-20)
        XCTAssertEqual(assembly.recipe.carcassDepthMM-front.originMM.y,620)
        let drafts=try CabinetDerivations.nativeDrafts(assembly)
        let draft=try XCTUnwrap(drafts.first{$0.panelID==front.id})
        XCTAssertEqual(draft.rectangleMin[1],-20)
        XCTAssertEqual(draft.translationXYZ,[0,2,0])
        XCTAssertEqual(draft.extrusionMM,2396)
    }
    func testLargeCabinetViewBudgetRefusesRatherThanDroppingPanels() throws {
        let assembly=try CabinetBuilder.build(InteriorResearchSamples.cabinet())
        let plans=try CabinetDerivations.drawingPlans(assembly)
        let front=try XCTUnwrap(plans.first{$0.kind == .front})
        XCTAssertEqual(front.panelIDs.count,19)
        XCTAssertTrue(front.issues.contains("native-drawing-source-budget-exceeded"))
        let part=try XCTUnwrap(plans.first{$0.kind == .individualParts})
        XCTAssertEqual(part.panelIDs.count,19)
        XCTAssertEqual(part.status,"design-draft")
        let small=try CabinetBuilder.build(InteriorResearchSamples.cabinet(bayCount:1,shelvesPerBay:2,includeFronts:false))
        XCTAssertEqual(small.panels.count,7)
        XCTAssertTrue(try CabinetDerivations.drawingPlans(small).first{$0.kind == .front}!.issues.isEmpty)
    }
    func testManufacturingInputsRemainUnverifiedAndNoHolesInvented() throws {
        let assembly=try CabinetBuilder.build(InteriorResearchSamples.cabinet())
        XCTAssertFalse(assembly.manufacturingVerified)
        XCTAssertEqual(assembly.missingManufacturingInputs.count,4)
        let plans=try CabinetDerivations.drawingPlans(assembly)
        for kind in [CabinetDrawingKind.edging,.machining,.nesting] {
            XCTAssertEqual(plans.first{$0.kind == kind}?.status,"needs-input-or-adapter")
        }
        let csv=try CabinetDerivations.partsCSV(assembly)
        XCTAssertTrue(csv.contains("design-finished-dimensions"))
        XCTAssertTrue(csv.contains("not-validated"))
    }
    func testInvalidRecipesFailBeforeAnyCommandPlan() throws {
        for value in [Double.nan,Double.infinity,-1,0] {
            var recipe=InteriorResearchSamples.cabinet(); recipe.widthMM=value
            XCTAssertThrowsError(try CabinetBuilder.build(recipe))
        }
        var tooShort=InteriorResearchSamples.cabinet(); tooShort.heightMM=50
        XCTAssertThrowsError(try CabinetBuilder.build(tooShort))
        var tooShallow=InteriorResearchSamples.cabinet(); tooShallow.carcassDepthMM=25
        XCTAssertThrowsError(try CabinetBuilder.build(tooShallow))
        var unknown=InteriorResearchSamples.cabinet(); unknown.constructionRule.version="future"
        XCTAssertThrowsError(try CabinetBuilder.build(unknown))
    }
    func testDuplicateSemanticIDsRefused() throws {
        var recipe=InteriorResearchSamples.cabinet()
        recipe.bays[1].shelfIDs[0]=recipe.bays[0].shelfIDs[0]
        XCTAssertThrowsError(try CabinetBuilder.build(recipe))
    }
    func testSourceSnapshotsAreReproducibleAndFutureVersionsRefused() throws {
        let recipe=InteriorResearchSamples.cabinet()
        let assembly=try CabinetBuilder.build(recipe)
        let data=try InteriorFingerprint.data(assembly)
        let restored=try JSONDecoder().decode(CabinetAssembly.self,from:data)
        XCTAssertEqual(assembly,restored)
        try restored.validateGeneratedSnapshot()
        var future=recipe; future.schemaVersion=2
        XCTAssertThrowsError(try CabinetBuilder.build(future))
    }
    func testAlteredOrStalePanelSnapshotCannotEnterNativeAdapter() throws {
        var assembly=try CabinetBuilder.build(InteriorResearchSamples.cabinet())
        assembly.panels[0].sizeMM.x=99
        XCTAssertThrowsError(try CabinetDerivations.nativeDrafts(assembly))
        XCTAssertThrowsError(try CabinetDerivations.drawingPlans(assembly))
        XCTAssertThrowsError(try CabinetDerivations.partsCSV(assembly))
    }
    func testCSVQuotesAssetIdentifiers() throws {
        var recipe=InteriorResearchSamples.cabinet()
        recipe.carcassMaterial.id="wood,\"oak\""
        let assembly=try CabinetBuilder.build(recipe)
        XCTAssertTrue(try CabinetDerivations.partsCSV(assembly).contains("\"wood,\"\"oak\"\"\""))
    }

    func testArchitecturalDrawingFramesUseNativeHorizontalAxisAndYUp() throws {
        let expected:[InteriorDrawingView:([Double],[Double])] = [
            .frontElevation: ([0,0,1],[1,0,0]),
            .sideSection: ([1,0,0],[0,0,-1]),
            .horizontalPlan: ([0,1,0],[1,0,0])
        ]
        for view in InteriorDrawingView.allCases {
            let frame=try InteriorDrawingFrame(view:view,originMM:.init(200,300,700))
            XCTAssertEqual(frame.nativeOriginMM.values,[200,700,-300])
            XCTAssertEqual(frame.nativeNormal.values,expected[view]!.0)
            XCTAssertEqual(frame.nativeHorizontalAxis.values,expected[view]!.1)
        }
    }

    func testDrawingFrameRoundTripAndNonFiniteOriginRefusal() throws {
        let frame=try InteriorDrawingFrame(view:.sideSection,originMM:.init(1200,300,1050))
        XCTAssertEqual(try JSONDecoder().decode(InteriorDrawingFrame.self,
            from:InteriorFingerprint.data(frame)),frame)
        XCTAssertThrowsError(try InteriorDrawingFrame(view:.frontElevation,originMM:.init(.nan,0,0)))
        let decoder=JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity:"Infinity",negativeInfinity:"-Infinity",nan:"NaN")
        let input=Data(#"{"view":"frontElevation","originMM":{"x":"NaN","y":0,"z":0}}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(InteriorDrawingFrame.self,from:input))
    }
}
