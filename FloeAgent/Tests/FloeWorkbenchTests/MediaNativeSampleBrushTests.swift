// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import CoreGraphics
@testable import FloeWorkbench

@Suite("M07 M19 actual sampled brushes",.serialized)
struct MediaNativeSampleBrushTests {
    func image(_ pixels:[UInt8]) throws -> CGImage {
        let provider = try #require(CGDataProvider(data:Data(pixels) as CFData))
        return try #require(CGImage(width:64,height:64,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:256,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    }
    func pixels() -> [UInt8] {
        var p = [UInt8](repeating:0,count:64*64*4)
        for y in 0..<64 { for x in 0..<64 { let i = (y*64+x)*4;p[i+(x<32 ? 0 : 2)] = 255;p[i+3] = 255 } }
        return p
    }
    func record(_ name:String,_ image:CGImage) throws {
        guard let dir = ProcessInfo.processInfo.environment["FLOE_MEDIA_EXECUTION_EVIDENCE_DIR"] else { return }
        let root = URL(fileURLWithPath:dir,isDirectory:true);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try #require(WorkbenchPNG.encode(image)).write(to:root.appendingPathComponent(name+".png"),options:.atomic)
    }
    @Test func smudgeReallyTransportsRedPixelsAcrossTheBlueBoundary() throws {
        let source = try image(pixels()),original = try MediaNativeSelection.rgba(source).pixels
        let output = try MediaNativeSampleBrush.render(source,points:[.init(x:0.25,y:0.5),.init(x:0.75,y:0.5)],width:12,strength:1,hardness:1,mode:.smudge)
        let result = try MediaNativeSelection.rgba(output).pixels
        #expect(result[(31*64+45)*4]>200 && original[(31*64+45)*4] == 0)
        #expect(Array(result[(48*64+45)*4..<(48*64+45)*4+4]) == Array(original[(48*64+45)*4..<(48*64+45)*4+4]))
        #expect(try MediaNativeSelection.rgba(source).pixels == original)
        try record("M07-smudge",output)
    }
    @Test func cloneCopiesTheAnchorFootprintAndHonorsStrengthAndTransparentSources() throws {
        let source = try image(pixels())
        let destination = ImageFreehandStroke.Point(x:0.75,y:0.75),anchor = ImageFreehandStroke.Point(x:0.25,y:0.25)
        let output = try MediaNativeSampleBrush.render(source,points:[destination],width:12,strength:1,hardness:1,mode:.clone(source:anchor))
        let p = try MediaNativeSelection.rgba(output).pixels,i = (47*64+47)*4
        #expect(p[i]>240 && p[i+2]<20)
        #expect(p[(60*64+60)*4+2]>240)
        let half = try MediaNativeSampleBrush.render(source,points:[destination],width:12,strength:0.5,hardness:1,mode:.clone(source:anchor))
        let hp = try MediaNativeSelection.rgba(half).pixels
        #expect((120...136).contains(hp[i]) && (120...136).contains(hp[i+2]))
        var transparent = pixels()
        for y in 0..<32 { for x in 0..<32 { for channel in 0..<4 { transparent[(y*64+x)*4+channel] = 0 } } }
        let emptySource = try image(transparent)
        let noErase = try MediaNativeSampleBrush.render(emptySource,points:[destination],width:12,strength:1,hardness:1,mode:.clone(source:anchor))
        let unchanged = try MediaNativeSelection.rgba(noErase).pixels
        #expect(unchanged[i+2] == 255 && unchanged[i+3] == 255)
        try record("M19-clone",output);try record("M19-half-strength",half)
    }
    @Test func longWorkIsRejectedBeforeMutationAndCancellationReachesTheNativeBrush() async throws {
        let source = try image(pixels()),before = try #require(WorkbenchPNG.encode(source))
        let points = (0..<10_000).map { ImageFreehandStroke.Point(x:$0%2 == 0 ? 0 : 1,y:$0%2 == 0 ? 0 : 1) }
        #expect(throws:MediaPreparedCoreError.self) { try MediaNativeSampleBrush.render(source,points:points,width:200,mode:.smudge) }
        #expect(try WorkbenchPNG.encode(source) == before)
        let worker = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return try MediaNativeSampleBrush.render(source,points:[.init(x:0.2,y:0.5),.init(x:0.8,y:0.5)],width:12,mode:.smudge)
        }
        worker.cancel()
        do { _ = try await worker.value;Issue.record("Cancelled native brush returned a result") }
        catch { #expect(error is CancellationError) }
        #expect(try WorkbenchPNG.encode(source) == before)
    }
}
