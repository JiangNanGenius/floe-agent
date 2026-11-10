// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import CoreGraphics
@testable import FloeWorkbench

@Suite("M06 M08 M09 M10 native paint products",.serialized)
struct MediaNativePaintEffectsTests {
    func image(_ bytes:[UInt8],width:Int = 64,height:Int = 64) throws -> CGImage {
        let provider = try #require(CGDataProvider(data:Data(bytes) as CFData))
        return try #require(CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    }
    func pixel(_ bytes:[UInt8],_ x:Int,_ y:Int) -> [UInt8] { Array(bytes[(y*64+x)*4..<(y*64+x+1)*4]) }
    func record(_ name:String,_ image:CGImage) throws {
        guard let dir = ProcessInfo.processInfo.environment["FLOE_MEDIA_EXECUTION_EVIDENCE_DIR"] else { return }
        let root = URL(fileURLWithPath:dir,isDirectory:true);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try #require(WorkbenchPNG.encode(image)).write(to:root.appendingPathComponent(name+".png"),options:.atomic)
    }
    @Test func linearAndRadialGradientsRespectTheirActualEndpoints() throws {
        let original = try image([UInt8](repeating:0,count:64*64*4))
        let linear = try MediaNativePaintEffects.gradient(original,from:.init(x:0,y:0),to:.init(x:1,y:0),firstColor:"#FF0000",lastColor:"#0000FF")
        let pixels = try MediaNativeSelection.rgba(linear).pixels,a = pixel(pixels,2,32),b = pixel(pixels,61,32)
        #expect(Int(a[0])>Int(b[0])+100 && Int(b[2])>Int(a[2])+100)
        let radial = try MediaNativePaintEffects.gradient(original,from:.init(x:0.5,y:0.5),to:.init(x:1,y:0.5),firstColor:"#FF0000",lastColor:"#0000FF",radial:true)
        let r = try MediaNativeSelection.rgba(radial).pixels
        #expect(pixel(r,32,32)[0]>pixel(r,2,2)[0]+100)
        try record("M06-linear",linear);try record("M06-radial",radial)
        #expect(throws:MediaPreparedCoreError.self) { try MediaNativePaintEffects.gradient(original,from:.init(x:0,y:0),to:.init(x:0,y:0),firstColor:"#FFFFFF",lastColor:"#000000") }
    }
    @Test func blurAndSharpenOnlyModifyTheRealTopLeadingBrushCoverage() throws {
        var bytes = [UInt8](repeating:255,count:64*64*4)
        for y in 0..<64 { for x in 0..<64 {
            let value = UInt8(x<28 ? 80 : x>36 ? 170 : 80+(x-28)*10)
            for channel in 0..<3 { bytes[(y*64+x)*4+channel] = value }
        } }
        let original = try image(bytes),baseline = try MediaNativeSelection.rgba(original).pixels
        for filter in [MediaNativePaintEffects.StrokeFilter.blur,.sharpen] {
            let rendered = try MediaNativePaintEffects.filteredStroke(original,points:[.init(x:0.1,y:0.25),.init(x:0.9,y:0.25)],width:12,amount:filter == .blur ? 6 : 80,filter:filter)
            let result = try MediaNativeSelection.rgba(rendered).pixels
            var topDifference = 0
            for x in 0..<64 {
                topDifference += abs(Int(pixel(result,x,16)[0])-Int(pixel(baseline,x,16)[0]))
                #expect(pixel(result,x,48) == pixel(baseline,x,48))
            }
            #expect(topDifference>15)
            try record(filter == .blur ? "M08-blur-brush" : "M09-sharpen-brush",rendered)
        }
        #expect(try MediaNativeSelection.rgba(original).pixels == baseline)
    }
    @Test func outlineAndOffsetShadowActuallyGrowAlphaWithoutReplacingTheSubject() throws {
        var bytes = [UInt8](repeating:0,count:64*64*4)
        for y in 28..<36 { for x in 28..<36 { bytes[(y*64+x)*4] = 255;bytes[(y*64+x)*4+3] = 255 } }
        let original = try image(bytes)
        let result = try MediaNativePaintEffects.layerEffects(original,outlineWidth:4,outlineColor:"#00FF00",shadowRadius:0,shadowColor:"#0000FF",shadowOffset:.init(x:8,y:0))
        let pixels = try MediaNativeSelection.rgba(result).pixels
        #expect(pixel(pixels,32,32)[0]>200 && pixel(pixels,32,32)[1]<20)
        #expect(pixel(pixels,25,32)[1]>200 && pixel(pixels,25,32)[3]>200)
        #expect(pixel(pixels,42,32)[2]>200 && pixel(pixels,42,32)[3]>200)
        #expect(pixel(pixels,4,4)[3] == 0)
        try record("M10-outline-shadow",result)
    }
}
