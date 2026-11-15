// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import FloeInteriorCore

final class CabinetManufacturingPreparationTests:XCTestCase {
    private func input()throws->CabinetManufacturingInput {
        let assembly=try CabinetBuilder.build(InteriorResearchSamples.cabinet())
        let processes=assembly.panels.map{panel -> CabinetPanelProcess in
            let axes:(InteriorAxis,InteriorAxis)
            switch panel.thicknessAxis {case .x:axes=(.z,.y);case .y:axes=(.z,.x);case .z:axes=(.x,.y)}
            return .init(panelID:panel.id,lengthAxis:axes.0,widthAxis:axes.1,sizingRule:.geometryIncludesBands,
                ruleReference:.init(id:"synthetic-rectangular",version:"1"),edges:.unbanded,
                allowance:.init(totalLengthMM:0,totalWidthMM:0),grain:.none,mayRotate90:true)
        }
        let materials=[assembly.recipe.carcassMaterial,assembly.recipe.backMaterial]+(assembly.recipe.fronts.map{[$0.material]} ?? [])
        var unique:[InteriorPanelMaterial]=[]
        for material in materials where !unique.contains(material){unique.append(material)}
        let stocks=unique.enumerated().map{index,material in
            CabinetStockPanel(id:"sheet-"+String(index),version:"1",material:material,kind:.standard,
                lengthMM:3000,widthMM:3000,quantity:10,
                trim:.init(lengthStartMM:10,lengthEndMM:10,widthStartMM:10,widthEndMM:10),grain:.none)
        }
        return .init(assembly:assembly,processes:processes,stocks:stocks,kerfMM:3)
    }
    private func row(_ result:CabinetManufacturingPreparation,_ id:String)throws->CabinetPreparedPart {
        try XCTUnwrap(result.parts.first{$0.id==id})
    }
    func testAllNineteenPanelIdentitiesReachExplicitNestingInput() throws {
        let v=try input(),result=try CabinetManufacturingPlanner.prepare(v)
        XCTAssertEqual(result.parts.count,19);XCTAssertTrue(result.readyForNesting)
        XCTAssertEqual(Set(result.packingGroups.flatMap(\.parts).map(\.panelID)),Set(v.assembly.panels.map(\.id)))
        XCTAssertEqual(result.packingGroups.flatMap(\.parts).reduce(0){$0+$1.quantity},19)
        XCTAssertFalse(result.manufacturingVerified);XCTAssertFalse(result.missingProductionValidation.isEmpty)
    }
    func testFinishedSubstrateAndBlankHaveDifferentExplicitDimensions() throws {
        var v=try input();let id=v.processes[0].panelID
        v.processes[0].edges = .init(lengthStart:.band(materialID:"ABS",version:"1",thicknessMM:1),
            lengthEnd:.band(materialID:"ABS",version:"1",thicknessMM:2),widthStart:.unbanded,widthEnd:.band(materialID:"ABS",version:"1",thicknessMM:0.5))
        v.processes[0].allowance = .init(totalLengthMM:5,totalWidthMM:7)
        let part=try row(CabinetManufacturingPlanner.prepare(v),id),design=try XCTUnwrap(part.designFace)
        XCTAssertEqual(try XCTUnwrap(part.finished).lengthMM,design.lengthMM)
        XCTAssertEqual(try XCTUnwrap(part.substrate).lengthMM,design.lengthMM-3)
        XCTAssertEqual(try XCTUnwrap(part.cuttingBlank).lengthMM,design.lengthMM-3+5)
        XCTAssertEqual(try XCTUnwrap(part.cuttingBlank).widthMM,design.widthMM-0.5+7)
        XCTAssertEqual(part.cuttingBlank?.thicknessMM,design.thicknessMM)
    }
    func testSubstrateGeometryRuleAddsBandsOnlyToFinishedDimensions() throws {
        var v=try input();let id=v.processes[0].panelID;v.processes[0].sizingRule = .geometryIsSubstrate
        v.processes[0].edges.lengthStart = .band(materialID:"ABS",version:"1",thicknessMM:2)
        let p=try row(CabinetManufacturingPlanner.prepare(v),id),d=try XCTUnwrap(p.designFace)
        XCTAssertEqual(p.substrate?.lengthMM,d.lengthMM);XCTAssertEqual(p.cuttingBlank?.lengthMM,d.lengthMM)
        XCTAssertEqual(p.finished?.lengthMM,d.lengthMM+2)
    }
    func testUnknownProcessOrEdgeDoesNotBecomeGuessedProductionDimensions() throws {
        var v=try input();let missing=v.processes.removeFirst().panelID,id=v.processes[0].panelID
        v.processes[0].edges.widthEnd = .unknown
        let result=try CabinetManufacturingPlanner.prepare(v)
        XCTAssertEqual(result.parts.count,19);XCTAssertFalse(result.readyForNesting)
        XCTAssertNil(try row(result,missing).cuttingBlank)
        XCTAssertNil(try row(result,id).cuttingBlank)
        XCTAssertTrue(try row(result,id).issues.contains("edge-treatment-unspecified:width-end"))
    }
    func testUnknownRuleAllowanceAndGrainKeepTheOriginalDesignGeometry() throws {
        var v=try input();let id=v.processes[0].panelID
        v.processes[0].sizingRule=nil;v.processes[0].allowance=nil;v.processes[0].grain = .unknown
        let p=try row(CabinetManufacturingPlanner.prepare(v),id)
        XCTAssertNotNil(p.designFace);XCTAssertNil(p.substrate);XCTAssertNil(p.cuttingBlank)
        XCTAssertTrue(p.issues.contains("grain-unspecified"));XCTAssertTrue(p.issues.contains("sizing-rule-unspecified"))
    }
    func testMaterialVersionAndActualThicknessRemainSeparate() throws {
        var v=try input();var other=v.stocks[0];other.id="other-version";other.material.version="unselected-v2";v.stocks.append(other)
        let result=try CabinetManufacturingPlanner.prepare(v)
        XCTAssertFalse(result.packingGroups.flatMap(\.stocks).contains{$0.source.id==other.id})
        XCTAssertGreaterThan(Set(result.packingGroups.map{$0.material.id+"@"+$0.material.version+"/"+String($0.material.thicknessMM)}).count,1)
    }
    func testGrainControlsWhetherAnOtherwiseFittingPartCanRotate() throws {
        var v=try input();let id=v.processes[0].panelID
        v.processes[0].grain = .length;v.processes[0].mayRotate90=true
        for i in v.stocks.indices{v.stocks[i].grain = .length}
        let result=try CabinetManufacturingPlanner.prepare(v)
        let part=try XCTUnwrap(result.packingGroups.flatMap(\.parts).first{$0.panelID==id})
        XCTAssertTrue(part.allowedDegreesByStockID.values.allSatisfy{$0==[0]})
        v.processes[0].grain = .width
        let rotated=try XCTUnwrap(CabinetManufacturingPlanner.prepare(v).packingGroups.flatMap(\.parts).first{$0.panelID==id})
        XCTAssertTrue(rotated.allowedDegreesByStockID.values.allSatisfy{$0==[90]})
        v.processes[0].mayRotate90=false
        XCTAssertFalse(try CabinetManufacturingPlanner.prepare(v).packingGroups.flatMap(\.parts).contains{$0.panelID==id})
    }
    func testStockTrimQuantityKerfAndOffcutKindAreRetained() throws {
        var v=try input();v.stocks[0].kind = .offcut;v.stocks[0].quantity=1
        let result=try CabinetManufacturingPlanner.prepare(v)
        let stock=try XCTUnwrap(result.packingGroups.flatMap(\.stocks).first{$0.source.id==v.stocks[0].id})
        XCTAssertEqual(stock.source.quantity,1);XCTAssertEqual(stock.source.kind,.offcut)
        XCTAssertEqual(stock.usableLengthMM,2980);XCTAssertEqual(stock.usableWidthMM,2980)
        XCTAssertTrue(result.packingGroups.allSatisfy{$0.kerfMM==3})
    }
    func testOversizedPartsNeverReceiveAnImplicitStockAssignment() throws {
        var v=try input();for i in v.stocks.indices{v.stocks[i].lengthMM=100;v.stocks[i].widthMM=100}
        let result=try CabinetManufacturingPlanner.prepare(v)
        XCTAssertTrue(result.packingGroups.isEmpty);XCTAssertFalse(result.readyForNesting)
        XCTAssertTrue(result.parts.contains{$0.issues.contains("stock-size-or-grain-incompatible")})
    }
    func testMissingStockAndKerfAreNotReplacedWithGenericDefaults() throws {
        var v=try input();v.stocks=[];v.kerfMM=nil
        let result=try CabinetManufacturingPlanner.prepare(v)
        XCTAssertFalse(result.readyForNesting);XCTAssertTrue(result.packingGroups.isEmpty)
        XCTAssertTrue(result.issues.contains("kerf-unspecified"));XCTAssertNotNil(result.parts.first?.cuttingBlank)
        v=try input();v.stocks[0].quantity=0
        XCTAssertTrue(try CabinetManufacturingPlanner.prepare(v).issues.contains("stock-unavailable:"+v.stocks[0].id))
    }
    func testInvalidAxesDuplicateForeignIDsNonfiniteAndCollapsedSizesFail() throws {
        var v=try input();v.processes[0].widthAxis=v.processes[0].lengthAxis;XCTAssertThrowsError(try CabinetManufacturingPlanner.prepare(v))
        v=try input();v.processes.append(v.processes[0]);XCTAssertThrowsError(try CabinetManufacturingPlanner.prepare(v))
        v=try input();v.processes[0].panelID="foreign";XCTAssertThrowsError(try CabinetManufacturingPlanner.prepare(v))
        v=try input();v.kerfMM = .nan;XCTAssertThrowsError(try CabinetManufacturingPlanner.prepare(v))
        v=try input();v.processes[0].allowance = .init(totalLengthMM:-1,totalWidthMM:0);XCTAssertThrowsError(try CabinetManufacturingPlanner.prepare(v))
        v=try input();v.processes[0].edges.lengthStart = .band(materialID:"ABS",version:"1",thicknessMM:1e6);XCTAssertThrowsError(try CabinetManufacturingPlanner.prepare(v))
    }
    func testGeometryMaterialAndProcessChangesInvalidateThePreparation() throws {
        let original=try input(),result=try CabinetManufacturingPlanner.prepare(original)
        var v=original;v.assembly.recipe.widthMM+=100;v.assembly=try CabinetBuilder.build(v.assembly.recipe)
        XCTAssertTrue(try result.isStale(for:v))
        v=original;v.processes[0].allowance?.totalLengthMM=5;XCTAssertTrue(try result.isStale(for:v))
        v=original;v.stocks[0].version="2";XCTAssertTrue(try result.isStale(for:v))
        XCTAssertFalse(try result.isStale(for:original))
    }
    func testRequestOrderIsCanonicalAndSavedDerivedValuesAreValidated() throws {
        let original=try input(),result=try CabinetManufacturingPlanner.prepare(original)
        var reordered=original;reordered.processes.reverse();reordered.stocks.reverse()
        XCTAssertEqual(try CabinetManufacturingPlanner.prepare(reordered),result)
        let copy=try JSONDecoder().decode(CabinetManufacturingPreparation.self,from:JSONEncoder().encode(result))
        try copy.validateDerivedSnapshot(for:original)
        var tampered=copy;tampered.parts[0].cuttingBlank?.lengthMM+=100
        XCTAssertThrowsError(try tampered.validateDerivedSnapshot(for:original))
    }
    func testCSVKeepsSeparateSizeColumnsAndEscapesMaterialIdentity() throws {
        var recipe=InteriorResearchSamples.cabinet();recipe.carcassMaterial.id="Synthetic, \"board\""
        var v=try input();v.assembly=try CabinetBuilder.build(recipe)
        for i in v.processes.indices{v.processes[i].panelID=v.assembly.panels[i].id}
        let csv=try CabinetManufacturingPlanner.prepare(v).dimensionsCSV()
        XCTAssertTrue(csv.contains("finished_length_mm"));XCTAssertTrue(csv.contains("substrate_length_mm"));XCTAssertTrue(csv.contains("blank_length_mm"))
        XCTAssertTrue(csv.contains("\"Synthetic, \"\"board\"\"\""))
        XCTAssertEqual(csv.components(separatedBy:"\r\n").count,21)
    }
}
