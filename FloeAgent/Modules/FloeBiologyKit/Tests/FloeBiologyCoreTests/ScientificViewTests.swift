import XCTest
import FloeBiologyCore
import FloeBiologySamples
import simd

final class BiologyScientificViewTests:XCTestCase {
    func testPerspectiveFramingUsesWideViewportWithoutClippingAtoms() throws {
        let points:[SIMD3<Float>]=[-2,2].flatMap{x in [-12,12].flatMap{y in [-4,4].map{z in SIMD3(Float(x),Float(y),Float(z))}}}
        let wide=try XCTUnwrap(BiologyViewportFraming.fit(points:points,radius:0.42,aspect:1.6))
        let tall=try XCTUnwrap(BiologyViewportFraming.fit(points:points,radius:0.42,aspect:0.65))
        XCTAssertTrue(wide.quarterTurn);XCTAssertFalse(tall.quarterTurn)
        XCTAssertLessThan(wide.distance,tall.distance*0.75)
        for framing in [wide,tall] {
            let tanV=tan(Float.pi*38/360),aspect:Float=framing.quarterTurn ? 1.6:0.65
            // Check actual sphere boundary points, including front/back depth.
            for p in points {
                for axis in [SIMD3<Float>(1,0,0),SIMD3<Float>(0,1,0),SIMD3<Float>(0,0,1)] {
                    for sign:Float in [-1,1] {
                        let q=p+axis*sign*0.42,depth=framing.distance-q.z
                        let x=framing.quarterTurn ? q.y:q.x,y=framing.quarterTurn ? -q.x:q.y
                        XCTAssertGreaterThan(depth,framing.near);XCTAssertLessThan(depth,framing.far)
                        XCTAssertLessThan(abs(x)/(depth*tanV*aspect),1)
                        XCTAssertLessThan(abs(y)/(depth*tanV),1)
                    }
                }
            }
        }
    }
    func testMeasuredRibbonAndDensityFitAtPortraitAndLandscapeAspects() throws {
        let raw=try BiologySamples.data(for:.ubiquitinPDB),asset=try BiologyImporter.parse(title:"UBQ",format:"pdb",data:raw)
        guard case .proteinStructure(let structure)=asset.payload else{return XCTFail("Structure missing")}
        let ribbon=try BiologyProteinRibbon.build(structure,model:1)
        let density=try BiologyDensityVolume.parse(BiologySamples.data(for:.densityVolume)).isosurface(value:0.5,stride:2)
        for mesh in [ribbon,density] {
            let low=mesh.vertices.reduce(SIMD3<Float>(repeating:.infinity)){simd_min($0,$1)}
            let high=mesh.vertices.reduce(SIMD3<Float>(repeating:-.infinity)){simd_max($0,$1)},offset = -(low+high)/2
            for aspect:Float in [0.65,1.6,2.8] {
                let fit=try XCTUnwrap(BiologyViewportFraming.fit(points:mesh.vertices,offset:offset,aspect:aspect)),tanV=tan(Float.pi*38/360)
                var occupied:Float=0
                for vertex in mesh.vertices {
                    let p=vertex+offset,depth=fit.distance-p.z,x=fit.quarterTurn ? p.y:p.x,y=fit.quarterTurn ? -p.x:p.y
                    let normalized=max(abs(x)/(depth*tanV*aspect),abs(y)/(depth*tanV))
                    XCTAssertLessThan(normalized,1);occupied=max(occupied,normalized)
                }
                XCTAssertGreaterThan(occupied,0.85,"Fit should use the available viewport.")
            }
        }
        XCTAssertEqual(asset.originalData,raw)
    }
    func testFramingRejectsInvalidInputsAndHandlesSinglePoint() throws {
        XCTAssertNil(BiologyViewportFraming.fit(points:[],aspect:1))
        XCTAssertNil(BiologyViewportFraming.fit(points:[.zero],aspect:0))
        XCTAssertNil(BiologyViewportFraming.fit(points:[.init(.nan,0,0)],aspect:1))
        XCTAssertNil(BiologyViewportFraming.fit(points:[.zero],radius:-1,aspect:1))
        let point=try XCTUnwrap(BiologyViewportFraming.fit(points:[.zero],aspect:1))
        XCTAssertFalse(point.quarterTurn);XCTAssertGreaterThan(point.distance,point.near);XCTAssertGreaterThan(point.far,point.distance)
    }
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
    func testBackboneTraceBranchesForProteinNucleicMixedAndNonStandard() throws {
        func atomLine(_ serial:Int,_ name:String,_ residue:String,_ number:Int,_ x:Double,_ y:Double,_ z:Double,_ element:String)->String {
            var line = "ATOM  "
            line += String(format:"%5d",serial)              // cols 7-11
            line += " " + String(format:"%-4s",(name as NSString).utf8String!) // cols 13-16
            line += String(format:"%-4s",(residue as NSString).utf8String!)     // cols 17-20
            line += "A"                                       // col 22 chain
            line += String(format:"%4d",number)               // cols 23-26
            line += "    "                                    // cols 27-30
            line += String(format:"%8.3f",x)                  // cols 31-38
            line += String(format:"%8.3f",y)                  // cols 39-46
            line += String(format:"%8.3f",z)                  // cols 47-54
            line += String(format:"%6.2f",1.0)                // cols 55-60
            line += String(repeating:" ",count:15)            // cols 61-75
            line += String(format:"%2s",(element as NSString).utf8String!)     // cols 77-78
            return line
        }
        // Pure DNA/RNA: phosphate trace, no Cα, P–P links under 8 Å.
        let residues = ["DA","DT","DG","DC"]
        let dnaLines = residues.enumerated().map { i,code in
            atomLine(i+1,"P",code,i+1,Double(i)*6.5,0,0,"P")
        } + residues.enumerated().map { i,code in
            atomLine(i+101,"O5'",code,i+1,Double(i)*6.5+1.5,1,0,"O")
        }
        let dna = try BiologyImporter.parse(title:"DNA",format:"pdb",data:Data((dnaLines.joined(separator:"\n")+"\n").utf8))
        guard case .proteinStructure(let nucleic)=dna.payload else {return XCTFail("Nucleic structure missing")}
        XCTAssertFalse(nucleic.atoms.contains{$0.name=="CA"})
        let nucleicTrace = try XCTUnwrap(nucleic.atoms.backboneTrace)
        XCTAssertEqual(nucleicTrace.count,4)
        XCTAssertTrue(nucleicTrace.allSatisfy{$0.name=="P"})
        XCTAssertEqual(nucleicTrace.backboneLinkedPairs.count,3)
        // Pure protein: Cα trace only, links under 5 Å.
        let raw = try BiologySamples.data(for:.ubiquitinPDB),asset = try BiologyImporter.parse(title:"UBQ",format:"pdb",data:raw)
        guard case .proteinStructure(let protein)=asset.payload else {return XCTFail("Protein structure missing")}
        let proteinTrace = try XCTUnwrap(protein.atoms.backboneTrace)
        XCTAssertGreaterThan(proteinTrace.count,50)
        XCTAssertTrue(proteinTrace.allSatisfy{$0.name=="CA"})
        XCTAssertFalse(proteinTrace.contains{$0.name=="P"})
        // Mixed protein+DNA deposit keeps both backbone classes, and links
        // never cross classes (Cα–P pairs are not linked).
        let mixedText = (dnaLines+[
            atomLine(201,"CA","ALA",11,0,0,0,"C"),
            atomLine(202,"CA","ALA",12,3.8,0,0,"C"),
            atomLine(203,"CA","ALA",13,7.6,0,0,"C"),
        ]).joined(separator:"\n")+"\n"
        let mixed = try BiologyImporter.parse(title:"Mixed",format:"pdb",data:Data(mixedText.utf8))
        guard case .proteinStructure(let hybrid)=mixed.payload else {return XCTFail("Mixed structure missing")}
        let hybridTrace = try XCTUnwrap(hybrid.atoms.backboneTrace)
        XCTAssertEqual(hybridTrace.filter{$0.name=="P"}.count,4)
        XCTAssertEqual(hybridTrace.filter{$0.name=="CA"}.count,3)
        XCTAssertEqual(hybridTrace.backboneLinkedPairs.count,5)
        XCTAssertTrue(hybridTrace.backboneLinkedPairs.allSatisfy{$0.from.name==$0.to.name})
        // Non-standard deposit (no Cα, no phosphate) reports no trace, so the
        // view keeps every atom instead of an empty backbone.
        let sugarOnly = try BiologyImporter.parse(title:"Sugar",format:"pdb",data:Data((residues.enumerated().map { i,code in
            atomLine(i+301,"O5'",code,i+1,Double(i)*4.0,1,0,"O")
        }.joined(separator:"\n")+"\n").utf8))
        guard case .proteinStructure(let sugar)=sugarOnly.payload else {return XCTFail("Non-standard structure missing")}
        XCTAssertNil(sugar.atoms.backboneTrace)
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
    func testRibbonJoinsAtSharedResiduesWithoutChangingSourceCoordinates() throws {
        let raw=try BiologySamples.data(for:.ubiquitinPDB),asset=try BiologyImporter.parse(title:"UBQ",format:"pdb",data:raw)
        guard case .proteinStructure(let structure)=asset.payload else{return XCTFail("Structure missing")}
        let mesh=try BiologyProteinRibbon.build(structure,model:1),alpha=structure.atoms.filter{$0.name=="CA" && !$0.hetero}
        // Both sides of a shared residue meet. This detects the former cracks
        // caused by independently rotating every consecutive ribbon segment.
        for segment in 0..<alpha.count-2 {
            let last=segment*36+30,next=(segment+1)*36
            XCTAssertLessThan(simd_distance(mesh.vertices[last+5],mesh.vertices[next]),1e-5)
            XCTAssertLessThan(simd_distance(mesh.vertices[last+2],mesh.vertices[next+1]),1e-5)
        }
        XCTAssertEqual(asset.originalData,raw)
    }
}
