// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import FloeInteriorCore

final class FurniturePlacementTests:XCTestCase {
    private func sample()->FurniturePlacementInput {
        .init(instanceID:UUID(uuidString:"785d6c5e-bfb4-4e09-aa11-40d6b5681dfb")!,roomID:nil,
              assetID:"synthetic-box",assetVersion:"1",sourceSHA256:String(repeating:"a",count:64),
              dependencySHA256:[:],sourceBounds:.init(minimum:.init(1,2,3),maximum:.init(3,6,9)),
              orientation:.cadYUp,sizing:.sourceUnits(millimetresPerUnit:10),
              pose:.init(planXMM:1000,planYMM:800,floorElevationMM:200,elevationAboveFloorMM:100,
                         yawDegrees:0,anchor:.bottomCenter))
    }
    private func assertPoint(_ actual:InteriorVector3,_ expected:InteriorVector3,file:StaticString=#filePath,line:UInt=#line){
        for (a,b) in zip(actual.values,expected.values){XCTAssertEqual(a,b,accuracy:1e-7,file:file,line:line)}
    }
    func testExplicitUnitsBottomAnchorAndBuildingToNativeFrame() throws {
        let p=try FurniturePlacementPlanner.make(sample())
        XCTAssertEqual(p.dimensionsMM,.init(widthMM:20,depthMM:60,heightMM:40))
        assertPoint(try p.nativePointMM(fromSource:.init(2,2,6)),.init(1000,300,-800))
        assertPoint(p.envelopeInNativeMM.minimum,.init(990,300,-830))
        assertPoint(p.envelopeInNativeMM.maximum,.init(1010,340,-770))
        XCTAssertEqual(p.sourceMillimetresPerUnit,10)
        XCTAssertFalse(p.nativeGeometryVerified);XCTAssertFalse(p.manufacturingVerified)
    }
    func testFrontLeftAnchorAndYawHaveCorrectHandedness() throws {
        var v=sample();v.pose.anchor = .bottomFrontLeft;v.pose.yawDegrees=90
        let p=try FurniturePlacementPlanner.make(v)
        assertPoint(try p.nativePointMM(fromSource:.init(1,2,9)),.init(1000,300,-800))
        assertPoint(try p.nativePointMM(fromSource:.init(1,2,3)),.init(940,300,-800))
        assertPoint(p.envelopeInNativeMM.extent,.init(60,40,20))
    }
    func testSourceZUpRotationIsAppliedBeforeDimensionsAndAnchoring() throws {
        var v=sample();v.orientation = .rotation3x3([1,0,0,0,0,-1,0,1,0]);v.sizing = .sourceUnits(millimetresPerUnit:1)
        let p=try FurniturePlacementPlanner.make(v)
        XCTAssertEqual(p.dimensionsMM,.init(widthMM:2,depthMM:4,heightMM:6))
        assertPoint(try p.nativePointMM(fromSource:.init(2,4,3)),.init(1000,300,-800))
    }
    func testRealPinnedCC0ArmchairCatalogFitIsNotMislabelledAsSourceUnits() throws {
        var v=sample();v.assetID="Blend Swap CC-0#armchair";v.assetVersion="1.9.3"
        v.sourceSHA256="4da2ca4ee1b573dfd5feaee4b689794a362f8da6df2f89adb79886c4ab8cd0ce"
        v.dependencySHA256=["armchair.mtl":"84bc77ecd7fff853255c51c5022707814e8a588dc53cb22be5db63b74e445223"]
        v.sourceBounds = .init(minimum:.init(-32.007305,0.141129,-42.7187),maximum:.init(33.058857,115.15596,25.961786))
        v.sizing = .catalogDimensions(.init(widthMM:594,depthMM:627,heightMM:1050),allowNonUniformScaling:true)
        let p=try FurniturePlacementPlanner.make(v)
        XCTAssertEqual(p.dimensionsMM.widthMM,594,accuracy:1e-7)
        XCTAssertEqual(p.dimensionsMM.depthMM,627,accuracy:1e-7)
        XCTAssertEqual(p.dimensionsMM.heightMM,1050,accuracy:1e-7)
        XCTAssertNil(p.sourceMillimetresPerUnit);XCTAssertEqual(p.sizeBasis,"catalog-declared-size")
        XCTAssertEqual(p.envelopeInNativeMM.minimum.y,300,accuracy:1e-7)
        var explicit=v;explicit.sizing = .sourceUnits(millimetresPerUnit:10)
        XCTAssertGreaterThan(abs(try FurniturePlacementPlanner.make(explicit).dimensionsMM.heightMM-1050),100)
    }
    func testCatalogDistortionRequiresExplicitSizingChoice() throws {
        var v=sample();v.sizing = .catalogDimensions(.init(widthMM:100,depthMM:100,heightMM:100),allowNonUniformScaling:false)
        XCTAssertThrowsError(try FurniturePlacementPlanner.make(v)){XCTAssertEqual($0 as? FurniturePlacementError,.disproportionateCatalogFit)}
        v.sizing = .catalogDimensions(.init(widthMM:20,depthMM:60,heightMM:40),allowNonUniformScaling:false)
        XCTAssertEqual(try FurniturePlacementPlanner.make(v).dimensionsMM,.init(widthMM:20,depthMM:60,heightMM:40))
    }
    func testSourceIdentityPoseAndDependenciesInvalidatePlansSeparately() throws {
        let original=sample(),p=try FurniturePlacementPlanner.make(original)
        var next=original;next.assetVersion="2";XCTAssertTrue(try p.isStale(for:next))
        next=original;next.dependencySHA256=["texture.png":String(repeating:"b",count:64)];XCTAssertTrue(try p.isStale(for:next))
        next=original;next.pose.planXMM+=10;XCTAssertTrue(try p.isStale(for:next))
        next=original;next.sourceBounds.maximum.x+=1;XCTAssertTrue(try p.isStale(for:next))
        XCTAssertFalse(try p.isStale(for:original))
    }
    func testTwoInstancesKeepTheirOwnPlacementsAndShareOneAssetVersion() throws {
        let a=sample();var b=a;b.instanceID=UUID();b.pose.planXMM+=500
        let first=try FurniturePlacementPlanner.make(a),second=try FurniturePlacementPlanner.make(b)
        XCTAssertEqual(first.assetID,second.assetID);XCTAssertEqual(first.assetVersion,second.assetVersion)
        XCTAssertNotEqual(first.instanceID,second.instanceID)
        XCTAssertEqual(second.envelopeInNativeMM.minimum.x-first.envelopeInNativeMM.minimum.x,500,accuracy:1e-7)
    }
    func testInvalidRotationsCoordinatesUnitsAndSourcePinsFail() throws {
        var v=sample();v.orientation = .rotation3x3([1,0,0,0.1,1,0,0,0,1]);XCTAssertThrowsError(try FurniturePlacementPlanner.make(v))
        v=sample();v.orientation = .rotation3x3([-1,0,0,0,1,0,0,0,1]);XCTAssertThrowsError(try FurniturePlacementPlanner.make(v))
        v=sample();v.sourceBounds.maximum.x=v.sourceBounds.minimum.x;XCTAssertThrowsError(try FurniturePlacementPlanner.make(v))
        v=sample();v.pose.floorElevationMM = .nan;XCTAssertThrowsError(try FurniturePlacementPlanner.make(v))
        v=sample();v.sizing = .sourceUnits(millimetresPerUnit:0);XCTAssertThrowsError(try FurniturePlacementPlanner.make(v))
        v=sample();v.sourceSHA256="unknown";XCTAssertThrowsError(try FurniturePlacementPlanner.make(v))
        v=sample();v.dependencySHA256=["x":"missing"];XCTAssertThrowsError(try FurniturePlacementPlanner.make(v))
    }
    func testUntrustedDecodedInputStillPassesValidationAndSourceOrderDoesNotChangeFingerprint() throws {
        var v=sample();v.dependencySHA256=["b":String(repeating:"b",count:64),"a":String(repeating:"c",count:64)]
        let p=try FurniturePlacementPlanner.make(v)
        v.dependencySHA256=["a":String(repeating:"c",count:64),"b":String(repeating:"b",count:64)]
        XCTAssertEqual(try FurniturePlacementPlanner.make(v),p)
        let data=try JSONEncoder().encode(v),decoded=try JSONDecoder().decode(FurniturePlacementInput.self,from:data)
        XCTAssertEqual(try FurniturePlacementPlanner.make(decoded),p)
        var bad=decoded;bad.sourceBounds.minimum.z=bad.sourceBounds.maximum.z+1
        XCTAssertThrowsError(try FurniturePlacementPlanner.make(bad))
    }
    func testSavedPlanRoundtripAndTamperedDerivedMatrixAreDetected() throws {
        let v=sample(),p=try FurniturePlacementPlanner.make(v)
        let data=try JSONEncoder().encode(p),roundtrip=try JSONDecoder().decode(FurniturePlacementPlan.self,from:data)
        try roundtrip.validateDerivedSnapshot(for:v)
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        json["nativeMatrixColumnMajor"]=[1.0,2]
        let tampered=try JSONDecoder().decode(FurniturePlacementPlan.self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertThrowsError(try tampered.nativePointMM(fromSource:.init(1,2,3)))
        XCTAssertThrowsError(try tampered.validateDerivedSnapshot(for:v))
    }
}
