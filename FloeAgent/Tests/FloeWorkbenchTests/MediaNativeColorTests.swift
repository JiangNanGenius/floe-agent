// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import CoreImage
import CoreGraphics
@testable import FloeWorkbench

@Suite("M26-M29 native color products",.serialized)
struct MediaNativeColorTests {
    let points:[ImageFreehandStroke.Point]=[.init(x:0,y:0),.init(x:0.25,y:0.5),.init(x:0.5,y:0.75),.init(x:0.75,y:0.9),.init(x:1,y:1)]
    func render(_ image:CIImage,_ adjustment:ImageLayerAdjustment) throws -> CGImage {
        let output=try MediaNativeColor.apply(adjustment,to:image)
        return try #require(CIContext(options:[.cacheIntermediates:false]).createCGImage(output,from:image.extent))
    }
    func record(_ id:String,_ image:CGImage) throws {
        guard let dir=ProcessInfo.processInfo.environment["FLOE_MEDIA_EXECUTION_EVIDENCE_DIR"] else{return}
        let root=URL(fileURLWithPath:dir,isDirectory:true);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try #require(WorkbenchPNG.encode(image)).write(to:root.appendingPathComponent(id+".png"),options:.atomic)
    }
    @Test func redCurveLeavesOtherChannelsAndEmptySelectionUnchanged() throws {
        let source = CIImage(color: CIColor(red: 0.3, green: 0.4, blue: 0.5)).cropped(to: .init(x: 0, y: 0, width: 16, height: 16))
        let original = try MediaNativeSelection.rgba(render(source, .init())).pixels
        let control = ImageLayerAdjustment(channelCurves: .init(red: points))
        let changed = try MediaNativeSelection.rgba(render(source, control)).pixels
        #expect(Int(changed[0]) > Int(original[0]) + 20)
        #expect(abs(Int(changed[1]) - Int(original[1])) <= 2)
        #expect(abs(Int(changed[2]) - Int(original[2])) <= 2)
        var empty = control; empty.effectRegion = ImageSelection()
        #expect(try MediaNativeSelection.rgba(render(source, empty)).pixels == original)
        let histogram = try ImageColorHistogram.measure(render(source, .init()))
        #expect(histogram.red.reduce(0, +) == 16 * 16)
        #expect(histogram.green.reduce(0, +) == 16 * 16)
    }

    @Test func colorActionRetainsTypedContentAndUnrelatedControls() throws {
        let partial = try MediaImageColorEditing.merging(.init(channelCurves: .init(red: points)),
            into: .init(toneCurve: points, channelCurves: .init(blue: points)), tool: "image.curves", selection: nil)
        #expect(partial.toneCurve == points && partial.channelCurves?.blue == points && partial.channelCurves?.red == points)
        let layer = MediaPreparedLayer(name: "Text", transform: .init(centerX: 0.3, rotationDegrees: 20),
            adjustment: .init(exposureEV: 0.5), content: .text(.init(text: "Floe")),
            mask: .init(vector: .init(inverted: true)))
        let controls = try MediaImageColorEditing.merging(.init(toneCurve: points, channelCurves: .init(red: points)),
            into: layer.adjustment, tool: "image.curves", selection: nil)
        #expect(controls.exposureEV == 0.5)
        guard case .updateLayerAdjustment(let id, let revision, let next) = try MediaImageColorEditing.action(layer: layer, controls: controls) else { Issue.record("raster replacement is forbidden"); return }
        #expect(id == layer.id && revision == layer.revision)
        #expect(next.channelCurves?.red == points)
        let adjustment = MediaPreparedLayer(name: "Grade", content: .adjustment(.init()))
        guard case .replaceLayerContent(_, _, .adjustment(let saved)) = try MediaImageColorEditing.action(layer: adjustment, controls: controls) else { Issue.record("adjustment layer lost its typed controls"); return }
        #expect(saved == controls)
        #expect(try JSONDecoder().decode(ImageLayerAdjustment.self, from: JSONEncoder().encode(saved)) == controls)
    }

    @Test func curveAndTonalBalanceChangeRealPixels() throws {
        let source=CIImage(color:CIColor(red:0.3,green:0.3,blue:0.3)).cropped(to:.init(x:0,y:0,width:32,height:24))
        let original=try MediaNativeSelection.rgba(render(source,.init())).pixels
        let curve=try render(source,.init(toneCurve:points)),a=try MediaNativeSelection.rgba(curve).pixels
        #expect(Int(a[0])>Int(original[0])+20);try record("M26",curve)
        let balance=try render(source,.init(colorBalance:.init(midtones:.init(red:0.8),preserveLuminance:false))),b=try MediaNativeSelection.rgba(balance).pixels
        #expect(Int(b[0])>Int(b[1])+20);try record("M27",balance)
        let partial=try JSONDecoder().decode(ImageColorBalance.self,from:Data(#"{"midtones":{"red":0.5}}"#.utf8))
        #expect(partial.midtones.red==0.5 && partial.midtones.green==0 && partial.shadows == .init())
    }
    @Test func cubeParserAndRealFilterHonorSampleOrderAndRejectFalseSizes() throws {
        var text="TITLE \"Invert red\"\nLUT_3D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n"
        for blue in 0...1{for green in 0...1{for red in 0...1{text += "\(1-red) \(green) \(blue)\n"}}}
        let lut=try ImageColorLUT.parseCube(text),source=CIImage(color:CIColor(red:0.2,green:0.4,blue:0.6)).cropped(to:.init(x:0,y:0,width:32,height:24))
        let original=try MediaNativeSelection.rgba(render(source,.init())).pixels
        let image=try render(source,.init(colorLUT:lut)),output=try MediaNativeSelection.rgba(image).pixels
        #expect(Int(output[0])>Int(original[0])+40)
        #expect(abs(Int(output[1])-Int(original[1]))<5 && abs(Int(output[2])-Int(original[2]))<5)
        try record("M28",image)
        #expect(throws:MediaPreparedCoreError.self){try ImageColorLUT.parseCube(text+"0 0 0\n")}
        #expect(throws:MediaPreparedCoreError.self){try ImageColorLUT.parseCube("LUT_3D_SIZE 34\n")}
        #expect(try JSONDecoder().decode(ImageColorLUT.self,from:JSONEncoder().encode(lut))==lut)
    }
    @Test func denoiseProducesActualReducedNoiseWithBoundedAlpha() throws {
        let w=64,h=64;var bytes=Data(count:w*h*4)
        bytes.withUnsafeMutableBytes{buffer in let p=buffer.bindMemory(to:UInt8.self);for i in 0..<w*h{let noise=(i*7919%19)-9,v=UInt8(100+noise);p[i*4]=v;p[i*4+1]=v;p[i*4+2]=v;p[i*4+3]=255}}
        let provider=try #require(CGDataProvider(data:bytes as CFData)),image=try #require(CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        let source=CIImage(cgImage:image),original=try MediaNativeSelection.rgba(render(source,.init())).pixels
        let clean=try render(source,.init(noiseReduction:1)),output=try MediaNativeSelection.rgba(clean).pixels
        func variance(_ pixels:[UInt8])->Double{let values=stride(from:0,to:pixels.count,by:4).map{Double(pixels[$0])},mean=values.reduce(0,+)/Double(values.count);return values.reduce(0){$0+pow($1-mean,2)}/Double(values.count)}
        #expect(variance(output)<variance(original));#expect(stride(from:3,to:output.count,by:4).allSatisfy{output[$0]==255});try record("M29",clean)
    }
    @Test func colorSettingsPersistReopenAndUndoThroughCanonicalHistory() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("media-color-\(UUID())");defer{try? FileManager.default.removeItem(at:root)}
        let store=MediaProjectStore(directory:root),p=MediaProject(kind:.image,name:"Color",canvas:.init(width:32,height:24)),coordinator=MediaPreparedCoordinator(store:store)
        try await store.save(p);_=try await coordinator.upgradeDocument(id:p.id)
        let layer=MediaPreparedLayer(name:"Source",content:.raster(.init(source:.solidColor("#666666"))))
        _=try await coordinator.applyUserOperations([.init(action:.insertLayer(layer:layer,parentID:nil,index:nil))],to:p.id)
        let current=try await coordinator.loadDocument(id:p.id)
        let edit=try await coordinator.applyUserOperations([.init(action:.updateLayerAdjustment(id:layer.id,expectedRevision:current.layer(layer.id)!.revision,adjustment:.init(toneCurve:points)))],to:p.id)
        let reopened=try #require(try await MediaProjectStore(directory:root).loadProject(id:p.id))
        #expect(reopened.prepared?.layer(layer.id)?.adjustment.toneCurve==points)
        try MediaPreparedIntegrity.validateEnvelope(reopened)
        _=try await coordinator.undoGroup(edit.groupID,in:p.id)
        #expect(try await store.loadProject(id:p.id)?.prepared?.layer(layer.id)?.adjustment.isIdentity==true)
        _=try await coordinator.redoGroup(edit.groupID,in:p.id)
        #expect(try await store.loadProject(id:p.id)?.prepared?.layer(layer.id)?.adjustment.toneCurve==points)
    }
}
