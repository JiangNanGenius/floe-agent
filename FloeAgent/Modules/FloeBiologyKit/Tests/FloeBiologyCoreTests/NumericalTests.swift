import XCTest
import FloeBiologyCore
import FloeBiologySamples

final class BiologyNumericalTests: XCTestCase {
    func sample(_ id:BiologySampleID,_ format:String) throws -> BiologyAsset {
        try BiologyImporter.parse(title:id.rawValue,format:format,data:BiologySamples.data(for:id))
    }
    func testSequenceKnownTranslationAndAlignment() throws {
        let a=try sample(.sequenceComparison,"fasta")
        let stats=try BiologyNativeAnalysis.run(asset:a,method:"sequence.stats")
        XCTAssertEqual(stats.metrics["length"],30)
        let t=try BiologyNativeAnalysis.run(asset:a,method:"sequence.translate")
        XCTAssertEqual(t.text,"MADEFYGAK*")
        let align=try BiologyNativeAnalysis.run(asset:a,method:"sequence.align.global")
        XCTAssertEqual(align.metrics["alignedColumns"],30)
        XCTAssertEqual(align.metrics["score"],57)
        XCTAssertEqual(try BiologyNativeAnalysis.reverseComplement("ACGTRYN"),"NRYACGT")
        XCTAssertEqual(try BiologyNativeAnalysis.translate("ATAAGATGA",code:2),"M*W")
    }
    func testOfficialPDBAndMMCIFAgree() throws {
        let pdb=try sample(.ubiquitinPDB,"pdb"),cif=try sample(.ubiquitinMMCIF,"cif")
        let a=try BiologyNativeAnalysis.run(asset:pdb,method:"structure.geometry")
        let b=try BiologyNativeAnalysis.run(asset:cif,method:"structure.geometry")
        XCTAssertEqual(a.metrics["polymerAtoms"],602)
        XCTAssertEqual(a.metrics["residues"],76)
        XCTAssertEqual(a.metrics["atoms"],b.metrics["atoms"])
        XCTAssertEqual(a.metrics["geometricGyration_A"]!,b.metrics["geometricGyration_A"]!,accuracy:1e-8)
    }
    func testQuantitativeSegmentationAndCalibration() throws {
        let a=try sample(.microscopy,"json")
        let r=try BiologyNativeAnalysis.run(asset:a,method:"image.segment",options:.object(["threshold":.number(10)]))
        XCTAssertEqual(r.metrics["objects"],2)
        XCTAssertEqual(r.rows.map{$0[1]}.sorted(),[37.25,63.25])
        XCTAssertEqual(r.labels.count,4096)
        let binary=try sample(.microscopyPGM,"pgm")
        XCTAssertEqual(binary.originalData,try BiologySamples.data(for:.microscopyPGM))
        let uncalibrated=try BiologyNativeAnalysis.run(asset:binary,method:"image.segment",options:.object(["threshold":.number(10)]))
        XCTAssertEqual(uncalibrated.details["areaUnit"],"px²")
        XCTAssertEqual(uncalibrated.rows.map{$0[0]}.sorted(),[149,253])
    }
    func testMatrixNormalizationPreservesCounts() throws {
        let a=try sample(.expressionCounts,"csv")
        let r=try BiologyNativeAnalysis.run(asset:a,method:"matrix.normalize")
        for j in 0..<8 { XCTAssertEqual(r.rows.reduce(0){$0+$1[j]},10_000,accuracy:1e-7) }
        XCTAssertEqual(r.rowNames.last,"GENE_F")
        XCTAssertEqual(r.rows.last!,Array(repeating:0,count:8))
        let qc=try BiologyNativeAnalysis.run(asset:a,method:"matrix.qc")
        XCTAssertEqual(qc.metrics["genes"],6);XCTAssertEqual(qc.metrics["cells"],8)
    }
    func testNetworkAnalyticalSolutionAndConservation() throws {
        let a=try sample(.reactionNetwork,"json")
        let r=try BiologyNativeAnalysis.run(asset:a,method:"network.simulate")
        XCTAssertEqual(r.metrics["final_A"]!,100*exp(-3),accuracy:1e-6)
        for row in r.rows { XCTAssertEqual(row[1]+row[2],100,accuracy:1e-9) }
        // h=30 gives a negative B amount for this k=0.1 RK4 step; h=20
        // stays nonnegative and is not a valid negative-state fixture.
        XCTAssertThrowsError(try BiologyNativeAnalysis.run(asset:a,method:"network.simulate",options:.object(["step":.number(100)])))
    }
    func testMalformedInputAndBudgets() throws {
        XCTAssertThrowsError(try BiologyImporter.parse(title:"bad",format:"csv",data:Data("gene,a,b\nG,1\n".utf8)))
        XCTAssertThrowsError(try BiologyImporter.parse(title:"bad",format:"fastq",data:Data("@A\nACGT\n+\n!!\n".utf8)))
        XCTAssertThrowsError(try BiologyImporter.pgm(Data("P5\n9999999 9999999\n255\n".utf8)))
        XCTAssertThrowsError(try BiologyNativeAnalysis.align(String(repeating:"A",count:3000),String(repeating:"A",count:3000)))
        XCTAssertThrowsError(try BiologyNativeAnalysis.translate("ATG",frame:0))
    }
    func testMultiFramePlaneSelection() throws {
        var image=MicroscopyImage(width:2,height:1,samples:[0,0,12,24]);image.frames=2
        let a=BiologyAsset(title:"time series",payload:.microscopyImage(image),originalData:Data(),originalFormat:"json")
        let r=try BiologyNativeAnalysis.run(asset:a,method:"image.statistics",options:.object(["frame":.number(1)]))
        XCTAssertEqual(r.metrics["mean"],18)
    }
}
