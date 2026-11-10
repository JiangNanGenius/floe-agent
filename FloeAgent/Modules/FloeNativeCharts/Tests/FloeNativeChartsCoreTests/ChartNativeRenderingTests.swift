#if canImport(CoreGraphics)
import Foundation
import Testing
import CoreGraphics
import ImageIO
import FloeNativeChartsCore
import FloeNativeChartsUI

@Suite("Native chart PNG/PDF/JSON products",.serialized)
struct ChartNativeRenderingTests {
    @Test("Every CH produces a real raster, readable PDF and lossless source JSON")
    func fortyProducts() throws {
        let evidence=ProcessInfo.processInfo.environment["FLOE_NATIVE_CHART_EVIDENCE_DIR"].map{URL(fileURLWithPath:$0,isDirectory:true)}
        var receipts:[[String:Any]]=[]
        for kind in ChartKind.allCases {
            let source=ChartCoreTests.fixture(kind),chart=try ChartValidator.prepare(source),id=chart.descriptor.requirementID
            let scene=try NativeChartSceneBuilder.build(chart),png=try NativeChartExporter.png(scene),pdf=try NativeChartExporter.pdf([scene]),json=try NativeChartExporter.json(chart)
            let imageSource=try #require(CGImageSourceCreateWithData(png as CFData,nil)),image=try #require(CGImageSourceCreateImageAtIndex(imageSource,0,nil))
            #expect(image.width==960 && image.height==640)
            #expect(png.count>1000)
            let provider=try #require(CGDataProvider(data:pdf as CFData)),document=try #require(CGPDFDocument(provider))
            #expect(document.numberOfPages==1 && document.page(at:1) != nil)
            guard case .v2(let roundtrip)=try ChartDocumentCodec.decode(json) else{Issue.record("Lost v2 \(id)");continue}
            #expect(roundtrip.document==source)
            var readValue=false
            let tester=NativeChartHitTester(scene:scene)
            for hit in scene.hits {
                let center=ChartPoint(x:hit.bounds.x+hit.bounds.width/2,y:hit.bounds.y+hit.bounds.height/2)
                if tester.readout(at:center) != nil{readValue=true;break}
            }
            // Some ring/ribbon hit bounds contain a hole; probe actual curve
            // locations instead of treating the bounding box as the shape.
            if !readValue {for y in stride(from:50.0,to:590.0,by:20){for x in stride(from:50.0,to:910.0,by:20){if tester.readout(at:.init(x:x,y:y)) != nil{readValue=true;break}};if readValue{break}}}
            #expect(readValue,"Native read-value hit missing for \(id)")
            if let evidence {
                let folder=evidence.appendingPathComponent(id,isDirectory:true);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                try png.write(to:folder.appendingPathComponent("render.png"),options:.atomic)
                try pdf.write(to:folder.appendingPathComponent("render.pdf"),options:.atomic)
                try json.write(to:folder.appendingPathComponent("roundtrip.json"),options:.atomic)
                receipts.append(["id":id,"type":kind.rawValue,"pngBytes":png.count,"pdfBytes":pdf.count,"jsonBytes":json.count,"primitives":scene.layout.primitives.count,"hits":scene.hits.count,"nativeReadValue":readValue,"pdfPages":document.numberOfPages])
            }
        }
        if let evidence {try JSONSerialization.data(withJSONObject:receipts,options:[.prettyPrinted,.sortedKeys]).write(to:evidence.appendingPathComponent("PRODUCTS.json"),options:.atomic)}
    }
    @Test("Filters alter only the displayed snapshot, including percentages and hierarchy")
    func filterAndSource() throws {
        for kind in ChartKind.allCases {
            let source=try ChartValidator.prepare(ChartCoreTests.fixture(kind)),options=ChartDisplayFilter.options(for:source)
            #expect(!options.isEmpty)
            let before=try NativeChartExporter.json(source)
            let selection=Set(options.prefix(max(1,options.count-1)).map(\.id))
            if let snapshot=ChartDisplayFilter.apply(selection,to:source) {
                let scene:NativeChartScene
                do{scene=try snapshot.scene(width:1280,height:960)}catch{throw ChartIssue(path:kind.rawValue+".filter",problem:String(describing:error))}
                #expect(scene.layout.primitives.count>0)
                #expect(snapshot.source.document==source.document)
            }
            #expect(try NativeChartExporter.json(source)==before)
            #expect(ChartDisplayFilter.apply([],to:source)==nil)
        }
    }
    @Test("Native exports honor size and cancellation boundaries")
    func exportBoundaries() async throws {
        let scene=try NativeChartSceneBuilder.build(ChartValidator.prepare(ChartCoreTests.fixture(.line)))
        #expect(throws:ChartIssue.self){try NativeChartExporter.png(scene,scale:100)}
        #expect(throws:ChartIssue.self){try NativeChartExporter.pdf(Array(repeating:scene,count:17))}
        let task=Task{withUnsafeCurrentTask{$0?.cancel()};return try NativeChartExporter.png(scene)}
        do{_=try await task.value;Issue.record("Cancelled export succeeded")}catch{#expect(error is CancellationError)}
    }
}
#endif
