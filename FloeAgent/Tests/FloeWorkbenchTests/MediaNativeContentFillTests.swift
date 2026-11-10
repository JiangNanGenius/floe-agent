// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import CoreGraphics
@testable import FloeWorkbench

@Suite("M21 M23 real exemplar content filling",.serialized)
struct MediaNativeContentFillTests {
    private func image(_ pixels:[UInt8],width:Int,height:Int) throws -> CGImage {
        let provider=try #require(CGDataProvider(data:Data(pixels) as CFData))
        return try #require(CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    }
    private func record(_ name:String,_ image:CGImage) throws {
        guard let dir=ProcessInfo.processInfo.environment["FLOE_MEDIA_EXECUTION_EVIDENCE_DIR"] else { return }
        let root=URL(fileURLWithPath:dir,isDirectory:true);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try #require(WorkbenchPNG.encode(image)).write(to:root.appendingPathComponent(name),options:.atomic)
    }
    @Test func automaticTextureSearchReconstructsActualBackgroundGradientAndDoesNotChangeOutsidePixels() throws {
        let w=96,h=64
        let oracle=(0..<w*h).flatMap{index->[UInt8] in let x=index%w,y=index/w;return [UInt8(20+x*2),UInt8(30+y*2),80,255]}
        var damaged=oracle,alpha=[UInt8](repeating:0,count:w*h)
        for y in 24..<40 { for x in 40..<56 { let i=y*w+x;damaged.replaceSubrange(i*4..<i*4+4,with:[255,0,0,255]);alpha[i]=255 } }
        let original=try image(damaged,width:w,height:h),source=try #require(WorkbenchPNG.encode(original)),selection=ImageSelection(bitmap:try .init(width:w,height:h,alpha:Data(alpha)))
        let result=try MediaNativeContentFill.fill(original,selection:selection),actual=try MediaNativeSelection.rgba(result).pixels
        let error=(0..<w*h).filter{alpha[$0]>0}.reduce(0){sum,index in sum+(0..<3).reduce(0){$0+abs(Int(actual[index*4+$1])-Int(oracle[index*4+$1]))}}
        #expect(Double(error)/(256*3)<3)
        for index in alpha.indices where alpha[index]==0 { #expect(Array(actual[index*4..<index*4+4])==Array(damaged[index*4..<index*4+4])) }
        #expect(WorkbenchPNG.encode(original)==source)
        try record("M21-source-with-object.png",original);try record("M21-actual-local-object-removal.png",result)
    }
    @Test func exemplarFillingRetainsRealCheckerboardTextureInsteadOfBlurringOrPaintingABox() throws {
        let w=64,h=48
        let oracle=(0..<w*h).flatMap{index->[UInt8] in let x=index%w,y=index/w;return ((x/4+y/4)%2==0) ? [20,40,220,255]:[230,210,30,255]}
        var damaged=oracle,alpha=[UInt8](repeating:0,count:w*h)
        for y in 16..<32 { for x in 20..<36 { let i=y*w+x;damaged.replaceSubrange(i*4..<i*4+4,with:[255,0,0,255]);alpha[i]=255 } }
        let original=try image(damaged,width:w,height:h),selection=ImageSelection(bitmap:try .init(width:w,height:h,alpha:Data(alpha)))
        let result=try MediaNativeContentFill.fill(original,selection:selection,mode:.texture,quality:.detailed),pixels=try MediaNativeSelection.rgba(result).pixels
        let matching=alpha.indices.filter{alpha[$0]>0 && Array(pixels[$0*4..<$0*4+4])==Array(oracle[$0*4..<$0*4+4])}.count
        #expect(matching>=250)
        try record("M23-textured-source.png",original);try record("M23-genuine-texture-fill.png",result)
    }
    @Test func exactSoftCoverageAndProtectedHolesRemainAndExplicitSamplingBoundsAreHonored() throws {
        let w=80,h=48
        var bytes=(0..<w*h).flatMap{index->[UInt8] in index%w<48 ? [0,255,0,255]:[255,255,0,255]},alpha=[UInt8](repeating:0,count:w*h)
        for y in 16..<24 { for x in 16..<24 { let i=y*w+x;bytes.replaceSubrange(i*4..<i*4+4,with:[255,0,0,255]);alpha[i]=128 } }
        let hole=19*w+19;alpha[hole]=0;bytes.replaceSubrange(hole*4..<hole*4+4,with:[0,0,255,255])
        let original=try image(bytes,width:w,height:h),selection=ImageSelection(bitmap:try .init(width:w,height:h,alpha:Data(alpha)))
        let output=try MediaNativeContentFill.fill(original,selection:selection,mode:.texture,samplingBounds:.init(x:0.65,y:0,width:0.35,height:1)),pixels=try MediaNativeSelection.rgba(output).pixels
        #expect(Array(pixels[hole*4..<hole*4+4])==[0,0,255,255])
        let target=(17*w+17)*4
        #expect(pixels[target]==255 && abs(Int(pixels[target+1])-128)<=1 && pixels[target+2]==0)
        for index in alpha.indices where alpha[index]==0 { #expect(Array(pixels[index*4..<index*4+4])==Array(bytes[index*4..<index*4+4])) }
    }
    @Test func noUsableSourceOrCancellationCannotProduceAFakeSuccess() async throws {
        let image=try image([UInt8](repeating:255,count:64*48*4),width:64,height:48)
        #expect(throws:(any Error).self) { try MediaNativeContentFill.fill(image,selection:.init(inverted:true)) }
        #expect(throws:(any Error).self) { try MediaNativeContentFill.fill(image,selection:.init()) }
        let worker=Task { while !Task.isCancelled { await Task.yield() };return try MediaNativeContentFill.fill(image,selection:.init(inverted:true)) };worker.cancel()
        await #expect(throws:CancellationError.self) { try await worker.value }
    }
    @Test func modelExamplesRequireARealVisibleLayerAndFreshNativeSelection() throws {
        let layer=MediaPreparedLayer(name:"Photo",content:.raster(.init(source:.solidColor("#FFFFFF"))))
        let doc=MediaPreparedDocument(id:UUID(),kind:.image,name:"Fill",canvas:.init(width:96,height:64),layers:[layer])
        let missing=try MediaPreparedToolInputGuide.make(document:doc,implementedToolIDs:["image.remove","image.content-fill"])
        #expect(missing.count==2 && missing.allSatisfy{$0.inputJSON==nil && $0.unavailableReason != nil})
        let ready=try MediaPreparedToolInputGuide.make(document:doc,implementedToolIDs:["image.remove","image.content-fill"],selectionFence:String(repeating:"b",count:64),hasImageRegion:true)
        #expect(ready.allSatisfy{$0.inputJSON != nil && $0.executionTool=="studio.media"})
        for value in ready {
            let json=try #require(value.inputJSON)
            let decoded=try JSONSerialization.jsonObject(with:Data(json.utf8))
            let input=try #require(decoded as? [String:Any])
            #expect(input["objectID"] as? String==layer.id.uuidString && input["selectionFence"] as? String==String(repeating:"b",count:64))
        }
    }

}
