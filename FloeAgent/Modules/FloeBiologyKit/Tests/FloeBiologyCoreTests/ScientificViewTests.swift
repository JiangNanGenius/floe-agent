import XCTest
import FloeBiologyCore
import FloeBiologySamples
import simd

final class BiologyScientificViewTests:XCTestCase {
    func testNewickQuotedLabelsCommentsMultifurcationsAndMissingLengths() throws {
        let tree=try BiologyTree.parse(Data("('A''s label'[note]:0.1,(B:0.2,C:0.3,D:0.4)Group:0.2)Root;".utf8))
        XCTAssertEqual(tree.leaves.count,4);XCTAssertEqual(tree.leaves[0].label,"A's label");XCTAssertEqual(tree.leaves[0].comments,["note"])
        let points=tree.layout();XCTAssertEqual(points[tree.leaves[0].id].x,0.1,accuracy:1e-12)
        let missing=try BiologyTree.parse(Data("(A,B);".utf8));XCTAssertGreaterThan(missing.layout()[0].x,0)
        for invalid in ["(A,B)","(A:NaN,B);","('broken,B);","(A,B);second;"] {XCTAssertThrowsError(try BiologyTree.parse(Data(invalid.utf8)))}
    }
    func testMRCPhysicalAxesEndianAndSurfaceCoordinates() throws {
        let data=try BiologySamples.data(for:.densityVolume),volume=try BiologyDensityVolume.parse(data)
        XCTAssertEqual(volume.dimensions,SIMD3(24,24,24));XCTAssertEqual(volume.position(.zero).x,-12,accuracy:1e-5)
        let slice=try volume.slice(axis:2,index:12);XCTAssertEqual(slice.values.count,576);XCTAssertGreaterThan(slice.values.max()!,0.9)
        let mesh=try volume.isosurface(value:0.5,stride:2)
        XCTAssertFalse(mesh.vertices.isEmpty);XCTAssertEqual(mesh.vertices.count%3,0)
        XCTAssertTrue(mesh.vertices.allSatisfy{p in p.x.isFinite && p.y.isFinite && p.z.isFinite && abs(p.x)<=12 && abs(p.y)<=12 && abs(p.z)<=12})
        XCTAssertThrowsError(try volume.isosurface(value:0.5,stride:1,maximumTriangles:1))
        var big=data
        for offset in Swift.stride(from:0,to:1024,by:4) where offset != 208 && offset != 212 {big.replaceSubrange(offset..<offset+4,with:data[offset..<offset+4].reversed())}
        for offset in Swift.stride(from:1024,to:data.count,by:4) {big.replaceSubrange(offset..<offset+4,with:data[offset..<offset+4].reversed())}
        big[212]=0x11;big[213]=0x11
        let swapped=try BiologyDensityVolume.parse(big);XCTAssertEqual(swapped.values,volume.values)
        var axes=data
        func set(_ offset:Int,_ value:Int32){var n=value.littleEndian;withUnsafeBytes(of:&n){axes.replaceSubrange(offset..<offset+4,with:$0)}}
        set(64,2);set(68,1)
        let permuted=try BiologyDensityVolume.parse(axes)
        XCTAssertEqual(permuted.values[permuted.index(10,7,12)],volume.values[volume.index(7,10,12)])
        XCTAssertThrowsError(try BiologyDensityVolume.parse(data.prefix(1050)))
    }
    func testDepositedRibbonUsesActualCoordinatesAndRespectsChainBreaks() throws {
        let raw=try BiologySamples.data(for:.ubiquitinPDB),asset=try BiologyImporter.parse(title:"UBQ",format:"pdb",data:raw)
        guard case .proteinStructure(let structure)=asset.payload else{return XCTFail("Structure missing")}
        let classes=BiologyProteinRibbon.depositedClasses(pdb:raw);XCTAssertTrue(classes.values.contains(1));XCTAssertTrue(classes.values.contains(2))
        let cif=try BiologySamples.data(for:.ubiquitinMMCIF),cifClasses=try BiologyImporter.cifSecondaryClasses(String(decoding:cif,as:UTF8.self));XCTAssertEqual(cifClasses,classes)
        let mesh=try BiologyProteinRibbon.build(structure,model:1,deposited:classes)
        XCTAssertFalse(mesh.vertices.isEmpty);XCTAssertTrue(mesh.classes.contains(1));XCTAssertTrue(mesh.classes.contains(2))
        let empty=try BiologyProteinRibbon.build(structure,model:1,chain:"missing",deposited:classes);XCTAssertTrue(empty.vertices.isEmpty)
        XCTAssertTrue(mesh.vertices.allSatisfy{$0.x.isFinite && $0.y.isFinite && $0.z.isFinite})
    }
}
