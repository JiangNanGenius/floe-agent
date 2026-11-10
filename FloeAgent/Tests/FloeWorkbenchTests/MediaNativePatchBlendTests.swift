// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import CoreGraphics
@testable import FloeWorkbench

@Suite("M18 M20 actual gradient-domain repair",.serialized)
struct MediaNativePatchBlendTests {
    func source() throws -> CGImage {
        var bytes = [UInt8](repeating:255,count:64*64*4)
        for y in 0..<64 { for x in 0..<64 {
            let value = UInt8(x<32 && y<32 ? 160+(x+y)%2*40 : 80)
            for c in 0..<3 { bytes[(y*64+x)*4+c] = value }
        } }
        let provider = try #require(CGDataProvider(data:Data(bytes) as CFData))
        return try #require(CGImage(width:64,height:64,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:256,space:CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    }
    func selection(hole:Bool = false) -> ImageSelection {
        var shapes: [ImageSelectionShape] = [.init(kind:.rectangle,points:[.init(x:0.625,y:0.625),.init(x:0.875,y:0.875)])]
        if hole { shapes.append(.init(kind:.rectangle,operation:.subtract,points:[.init(x:0.72,y:0.72),.init(x:0.78,y:0.78)])) }
        return .init(shapes:shapes)
    }
    func record(_ name:String,_ image:CGImage) throws {
        guard let dir = ProcessInfo.processInfo.environment["FLOE_MEDIA_EXECUTION_EVIDENCE_DIR"] else { return }
        let root = URL(fileURLWithPath:dir,isDirectory:true);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try #require(WorkbenchPNG.encode(image)).write(to:root.appendingPathComponent(name+".png"),options:.atomic)
    }
    @Test func patchKeepsSourceTextureButAdaptsItsBrightnessAndPreservesTheSelectionHole() throws {
        let image = try source(),original = try MediaNativeSelection.rgba(image).pixels
        let result = try MediaNativePatchBlend.patch(image,selection:selection(hole:true),sourceCenter:.init(x:0.25,y:0.25))
        let pixels = try MediaNativeSelection.rgba(result).pixels
        let samples = (42..<46).flatMap { y in (42..<46).map { x in Double(pixels[(y*64+x)*4]) } }
        let mean = samples.reduce(0,+)/Double(samples.count),span = samples.max()!-samples.min()!
        #expect((50...120).contains(mean) && span>20)
        #expect(pixels[(48*64+48)*4] == original[(48*64+48)*4])
        #expect(Array(pixels[0..<32*4]) == Array(original[0..<32*4]))
        #expect(try MediaNativeSelection.rgba(image).pixels == original)
        try record("M20-patch-with-hole",result)
        let dragged = try MediaNativePatchBlend.patchDragging(image,selection:selection(),from:.init(x:0.75,y:0.75),to:.init(x:0.25,y:0.25))
        try record("M20-dragged-patch",dragged)
    }
    @Test func healingBrushUsesItsActualStrokeAndSourceAnchor() throws {
        let image = try source(),original = try MediaNativeSelection.rgba(image).pixels
        let result = try MediaNativePatchBlend.healStroke(image,points:[.init(x:0.75,y:0.75)],width:12,sourceAnchor:.init(x:0.25,y:0.25))
        let pixels = try MediaNativeSelection.rgba(result).pixels
        let samples = (46..<50).flatMap { y in (46..<50).map { x in Int(pixels[(y*64+x)*4]) } }
        #expect(samples.max()!-samples.min()!>20)
        #expect(pixels[(10*64+50)*4] == original[(10*64+50)*4])
        #expect(stride(from:3,to:pixels.count,by:4).allSatisfy { pixels[$0] == original[$0] })
        try record("M18-heal-brush",result)
    }
    @Test func invalidSourceAndCancellationPreserveOriginalBytes() async throws {
        let image = try source(),before = try #require(WorkbenchPNG.encode(image))
        #expect(throws:MediaPreparedCoreError.self) { try MediaNativePatchBlend.patch(image,selection:selection(),sourceCenter:.init(x:0,y:0)) }
        #expect(try WorkbenchPNG.encode(image) == before)
        let selected = selection(),worker = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return try MediaNativePatchBlend.patch(image,selection:selected,sourceCenter:.init(x:0.25,y:0.25))
        }
        worker.cancel()
        do { _ = try await worker.value;Issue.record("Cancelled patch returned output") } catch { #expect(error is CancellationError) }
        #expect(try WorkbenchPNG.encode(image) == before)
    }
}
