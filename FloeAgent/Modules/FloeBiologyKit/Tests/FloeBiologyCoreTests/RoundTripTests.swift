import XCTest
import FloeBiologyCore
import FloeBiologySamples

final class BiologyRoundTripTests:XCTestCase {
    func testDerivedPDBKeepsFixedColumnsModelsAndCoordinates() throws {
        let source=try BiologyImporter.parse(title:"ubiquitin",format:"cif",data:BiologySamples.data(for:.ubiquitinMMCIF))
        let derived=try BiologyExport.asset(source,format:"pdb")
        let recovered=try BiologyImporter.parse(title:"reopened",format:"pdb",data:derived)
        guard case .proteinStructure(let a)=source.payload,case .proteinStructure(let b)=recovered.payload else {return XCTFail("Expected structure")}
        XCTAssertEqual(a.atoms.count,b.atoms.count)
        for (x,y) in zip(a.atoms,b.atoms) {
            XCTAssertEqual(x.name,y.name);XCTAssertEqual(x.residueID,y.residueID);XCTAssertEqual(x.element,y.element)
            XCTAssertEqual(x.x,y.x,accuracy:0.00051);XCTAssertEqual(x.y,y.y,accuracy:0.00051);XCTAssertEqual(x.z,y.z,accuracy:0.00051)
        }
        var second=a.atoms[0];second.model=2;second.id=1001;second.chain="";second.insertionCode="B";second.residueNumber = -12
        let multi=BiologyAsset(title:"models",payload:.proteinStructure(.init(atoms:[a.atoms[0],second])),originalData:Data(),originalFormat:"cif")
        let result=try BiologyImporter.pdb(String(decoding:BiologyExport.asset(multi,format:"pdb"),as:UTF8.self))
        XCTAssertEqual(result.atoms.map(\.model),[1,2]);XCTAssertEqual(result.atoms[1].residueNumber,-12);XCTAssertEqual(result.atoms[1].insertionCode,"B")
        var invalid=second;invalid.x = -1000
        let outside=BiologyAsset(title:"overflow",payload:.proteinStructure(.init(atoms:[invalid])),originalData:Data(),originalFormat:"cif")
        XCTAssertThrowsError(try BiologyExport.asset(outside,format:"pdb"))
    }
    func testMatrixImageNetworkAndTypedJSONReopen() throws {
        for (sample,format,derived) in [(BiologySampleID.expressionCounts,"csv","tsv"),(.microscopy,"json","image.json"),(.reactionNetwork,"json","network.json")] {
            let original=try BiologyImporter.parse(title:"source",format:format,data:BiologySamples.data(for:sample))
            let reopened=try BiologyImporter.parse(title:"exported",format:derived,data:BiologyExport.asset(original,format:derived))
            XCTAssertEqual(original.payload,reopened.payload)
            let typed=try BiologyImporter.parse(title:"typed",format:"json",data:BiologyExport.asset(original,format:"json"))
            XCTAssertEqual(original.payload,typed.payload)
            XCTAssertEqual(try BiologyExport.asset(original,format:"original"),original.originalData)
        }
        let float=BiologyAsset(title:"float",payload:.microscopyImage(.init(width:2,height:1,samples:[-0.5,1.25])),originalData:Data(),originalFormat:"json")
        XCTAssertThrowsError(try BiologyExport.asset(float,format:"pgm"))
    }
    func testAxisOrderAndExplicitProteinAlphabet() throws {
        var image=MicroscopyImage(width:2,height:1,samples:Array(0..<16).map(Double.init));image.frames=2;image.channels=2;image.slices=2
        XCTAssertEqual(try image.plane(channel:1,slice:0,frame:1),[10,11])
        XCTAssertEqual(try image.plane(channel:0,slice:1,frame:0),[4,5])
        let protein=try BiologyImporter.parse(title:"protein",format:"faa",data:Data(">protein\nAGCC\n".utf8))
        XCTAssertNil(try BiologyNativeAnalysis.run(asset:protein,method:"sequence.stats").metrics["GC_percent"])
        XCTAssertThrowsError(try BiologyNativeAnalysis.run(asset:protein,method:"sequence.translate"))
        XCTAssertThrowsError(try BiologyNativeAnalysis.run(asset:protein,method:"sequence.reverseComplement"))
    }
}
