// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import CoreGraphics
import CoreImage
@testable import FloeWorkbench

@Suite("M16 M17 shaped text and actual editable path rendering",.serialized)
struct MediaNativeTextGeometryTests {
    private func image(_ doc:MediaPreparedDocument) async throws -> CGImage {
        let canvas=try #require(doc.canvas)
        return try await WorkbenchImageRenderer().renderPrepared(doc,canvas:.init(width:canvas.width,height:canvas.height),resolveAsset:{_ in nil})
    }
    private func record(_ name:String,_ image:CGImage) throws {
        guard let dir=ProcessInfo.processInfo.environment["FLOE_MEDIA_EXECUTION_EVIDENCE_DIR"] else { return }
        let root=URL(fileURLWithPath:dir,isDirectory:true);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try #require(WorkbenchPNG.encode(image)).write(to:root.appendingPathComponent(name),options:.atomic)
    }
    @Test func multilingualShapedOutlinesMatchTheNativeTextPlacementAndColor() async throws {
        let canvas=MediaCanvas(width:320,height:200),text=ImageTextContent(text:"office 你好",fontSize:26,colorHex:"#3377EE",tracking:1.25)
        let source=MediaPreparedLayer(name:"Text",transform:.init(centerX:0.54,centerY:0.5,scale:1.15,rotationDegrees:13),content:.text(text))
        var doc=MediaPreparedDocument(id:UUID(),kind:.image,name:"Text",canvas:canvas,layers:[source])
        let before=try await image(doc),packed=try MediaNativeTextGeometry.outlineLayer(source,in:doc)
        var result=MediaPreparedLayer(name:"Outlined",content:.vectorPaths(packed.path));result.canvasSpace=packed.canvasSpace
        doc.layers=[result];let after=try await image(doc)
        let a=try MediaNativeSelection.rgba(before).pixels,b=try MediaNativeSelection.rgba(after).pixels
        let mean=Double(zip(a,b).reduce(0){$0+abs(Int($1.0)-Int($1.1))})/Double(a.count)
        #expect(mean<4)
        func pose(_ pixels:[UInt8]) -> ([Int],Double,Double,Double) {
            let indices=(0..<320*200).filter{pixels[$0*4+3]>64}
            let mass=(0..<320*200).reduce(0.0){$0+Double(pixels[$1*4+3])}
            let x=(0..<320*200).reduce(0.0){$0+Double($1%320)*Double(pixels[$1*4+3])}/mass
            let y=(0..<320*200).reduce(0.0){$0+Double($1/320)*Double(pixels[$1*4+3])}/mass
            return ([indices.map{$0%320}.min()!,indices.map{$0/320}.min()!,indices.map{$0%320}.max()!,indices.map{$0/320}.max()!],x,y,mass)
        }
        let first=pose(a),second=pose(b)
        #expect(zip(first.0,second.0).allSatisfy{abs($0-$1)<=2})
        #expect(abs(first.1-second.1)<1 && abs(first.2-second.2)<1)
        let overlap=stride(from:3,to:a.count,by:4).reduce(0.0){$0+Double(min(a[$1],b[$1]))}
        #expect(overlap/min(first.3,second.3)>0.85)
        let beforeBlue=stride(from:0,to:a.count,by:4).filter{a[$0+3]>200 && a[$0+2]>a[$0]}.count
        let afterBlue=stride(from:0,to:b.count,by:4).filter{b[$0+3]>200 && b[$0+2]>b[$0]}.count
        #expect(beforeBlue>100 && abs(afterBlue-beforeBlue)<beforeBlue/3)
        #expect(packed.path.subpaths.count>3 && packed.path.subpaths.flatMap(\.points).contains{$0.controlIn != nil})
        try record("M17-original-native-text.png",before);try record("M17-editable-vector-outlines.png",after)
    }
    @Test func curvedPathTextRemainsTextEditableAndUsesArcLengthAndRealGlyphOrientation() async throws {
        let canvas=MediaCanvas(width:320,height:200),curve=CGMutablePath()
        curve.move(to:.init(x:20,y:45));curve.addCurve(to:.init(x:300,y:80),control1:.init(x:90,y:190),control2:.init(x:220,y:180))
        let packed=try #require(try MediaNativeVectorGeometry.packed(curve,canvas:canvas,fill:nil))
        let layout=MediaTextPathLayout(path:packed.path,referenceCanvas:canvas,pathToCanvas:packed.canvasSpace.transform,startOffset:20,normalOffset:3)
        var text=ImageTextContent(text:"Floe Native",fontSize:26,colorHex:"#EE6633",pathLayout:layout)
        let outline=try MediaNativeTextGeometry.outline(text,canvas:canvas)
        #expect(try MediaNativeTextGeometry.pathLength(layout)>300 && outline.path.boundingBox.height>40)
        var doc=MediaPreparedDocument(id:UUID(),kind:.image,name:"Path text",canvas:canvas,layers:[.init(name:"Editable",content:.text(text))])
        let first=try await image(doc)
        let encoded=try JSONEncoder().encode(text),reloaded=try JSONDecoder().decode(ImageTextContent.self,from:encoded)
        #expect(reloaded.pathLayout==layout && reloaded.text=="Floe Native")
        text.text="Floe AI";doc.layers[0].content = .text(text)
        let edited=try await image(doc)
        #expect(WorkbenchPNG.encode(first) != WorkbenchPNG.encode(edited))
        var reverse=text;reverse.pathLayout?.isReversed=true;doc.layers[0].content = .text(reverse)
        let reversed=try await image(doc)
        #expect(WorkbenchPNG.encode(reversed) != WorkbenchPNG.encode(edited))
        try record("M16-editable-curved-text.png",first);try record("M16-edited-text.png",edited);try record("M16-reversed-path.png",reversed)
    }
    @Test func oldTextJSONStillLoadsAndUnsupportedOrOverflowingTextIsNotSilentlyDropped() throws {
        let old=Data(##"{"text":"Old","fontSize":24,"colorHex":"#000000"}"##.utf8)
        #expect(try JSONDecoder().decode(ImageTextContent.self,from:old).pathLayout==nil)
        let canvas=MediaCanvas(width:320,height:200),line=CGPath(rect:.init(x:20,y:50,width:25,height:1),transform:nil)
        let packed=try #require(try MediaNativeVectorGeometry.packed(line,canvas:canvas,fill:nil))
        let layout=MediaTextPathLayout(path:packed.path,referenceCanvas:canvas,pathToCanvas:packed.canvasSpace.transform)
        #expect(throws:(any Error).self) { try MediaNativeTextGeometry.outline(.init(text:"This text cannot fit",fontSize:40,pathLayout:layout),canvas:canvas) }
        #expect(throws:(any Error).self) { try MediaNativeTextGeometry.outline(.init(text:"Hello\nWorld",pathLayout:layout),canvas:canvas) }
        #expect(throws:(any Error).self) { try MediaNativeTextGeometry.outline(.init(text:"👩‍🔬",fontSize:32),canvas:canvas) }
    }
}
