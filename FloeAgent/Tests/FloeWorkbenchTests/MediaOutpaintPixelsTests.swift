// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import CoreGraphics
import CoreImage
@testable import FloeWorkbench

@Suite("M25 actual expanded-canvas pixel and transaction boundaries",.serialized)
struct MediaOutpaintPixelsTests {
    private func source(width:Int=64,height:Int=48,color:CIColor=CIColor(red:0.8,green:0.2,blue:0.1,alpha:0.7)) throws -> CGImage {
        let extent=CGRect(x:0,y:0,width:width,height:height),space=try #require(CGColorSpace(name:CGColorSpace.sRGB))
        return try #require(CIContext(options:[.workingColorSpace:space,.outputColorSpace:space]).createCGImage(CIImage(color:color).cropped(to:extent),from:extent,format:.RGBA8,colorSpace:space))
    }
    private func record(_ name:String,_ image:CGImage) throws {
        guard let dir=ProcessInfo.processInfo.environment["FLOE_MEDIA_EXECUTION_EVIDENCE_DIR"] else { return }
        let root=URL(fileURLWithPath:dir,isDirectory:true);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try #require(WorkbenchPNG.encode(image)).write(to:root.appendingPathComponent(name),options:.atomic)
    }
    @Test func actualReferenceProtectsTheOriginalRectangleAndUsesTheRequestedAnchor() throws {
        let original=try source(color:.clear),layout=try MediaOutpaintLayout(sourceWidth:64,sourceHeight:48,width:97,height:81,anchor:.init(x:0.5,y:0.5))
        #expect(layout.originX==17 && layout.originY==17)
        let mapping=try MediaCanvasLayout.mapping(from:.init(width:64,height:48),to:.init(width:97,height:81),mode:.extendCanvas(anchor:layout.effectiveAnchor))
        #expect(mapping.tx==17 && mapping.ty==16)
        let input=try MediaProviderOutpaintPixels.prepare(original,layout:layout)
        #expect(input.width==97 && input.height==81)
        let mask=try MediaProviderEditPixels.decode(input.maskPNG),pixels=try MediaNativeSelection.rgba(mask).pixels
        for y in 0..<81 { for x in 0..<97 {
            let protected=x>=17 && x<81 && y>=17 && y<65
            #expect(pixels[(y*97+x)*4+3]==(protected ? 255:0))
        } }
        try record("M25-original-transparent-protection.png",mask)
    }
    @Test func generatedMarginsNeverReplaceAnyOriginalPixelIncludingItsAlpha() throws {
        let original=try source(),before=try #require(WorkbenchPNG.encode(original)),layout=try MediaOutpaintLayout(sourceWidth:64,sourceHeight:48,width:96,height:80,anchor:.init(x:1,y:0))
        let generated=try #require(WorkbenchPNG.encode(source(width:96,height:80,color:CIColor(red:0,green:0,blue:1))))
        let margins=try MediaProviderOutpaintPixels.margins(generated,layout:layout),pixels=try MediaNativeSelection.rgba(margins).pixels
        for y in 0..<80 { for x in 0..<96 {
            let protected=x>=32 && y<48,index=(y*96+x)*4
            if protected { #expect(Array(pixels[index..<index+4])==[0,0,0,0]) }
            else { #expect(pixels[index+2]>250 && pixels[index+3]==255) }
        } }
        let placed=CIImage(cgImage:original).transformed(by:.init(translationX:32,y:32))
        let composite=placed.composited(over:CIImage(cgImage:margins)),extent=CGRect(x:0,y:0,width:96,height:80)
        let result=try #require(CIContext().createCGImage(composite,from:extent)),actual=try MediaNativeSelection.rgba(result).pixels,old=try MediaNativeSelection.rgba(original).pixels
        for y in 0..<48 { for x in 0..<64 {
            #expect(Array(actual[((y*96+x+32)*4)..<((y*96+x+32)*4+4)])==Array(old[((y*64+x)*4)..<((y*64+x)*4+4)]))
        } }
        #expect(try WorkbenchPNG.encode(original)==before)
        try record("M25-generated-margin-layer.png",margins);try record("M25-actual-expanded-composite.png",result)
    }
    @Test func boundedReferencesKeepTheRealCanvasAspectAndRejectWrongProviderShape() throws {
        let original=try source(width:1600,height:1200),layout=try MediaOutpaintLayout(sourceWidth:1600,sourceHeight:1200,width:2400,height:1600,anchor:.init(x:0,y:0.5))
        let input=try MediaProviderOutpaintPixels.prepare(original,layout:layout)
        #expect(input.width==1536 && input.height==1024)
        let square=try #require(WorkbenchPNG.encode(source(width:64,height:64)))
        #expect(throws:(any Error).self) { try MediaProviderOutpaintPixels.margins(square,layout:layout) }
        let matching=try #require(WorkbenchPNG.encode(source(width:96,height:64)))
        let actual=try MediaProviderOutpaintPixels.margins(matching,layout:layout)
        #expect(actual.width==2400 && actual.height==1600)
    }
    @Test func modelExampleUsesWholeCanvasDimensionsAndNeverInventsAnObjectOrSelection() throws {
        let doc=MediaPreparedDocument(id:UUID(),kind:.image,name:"Canvas",canvas:.init(width:64,height:48))
        let records=try MediaPreparedToolInputGuide.make(document:doc,implementedToolIDs:["image.outpaint"])
        let record=try #require(records.first),json=try #require(record.inputJSON)
        let input=try #require(JSONSerialization.jsonObject(with:Data(json.utf8)) as? [String:Any])
        #expect(record.executionTool=="studio.media.provider" && input["objectID"]==nil && input["selectionFence"]==nil)
        #expect((input["number"] as? Int)==80 && (input["secondary"] as? Int)==60)
        var locked=doc,layer=MediaPreparedLayer(name:"Locked",content:.raster(.init(source:.solidColor("#FFFFFF"))))
        layer.isLocked=true;locked.layers=[layer]
        let denied=try MediaPreparedToolInputGuide.make(document:locked,implementedToolIDs:["image.outpaint"])
        #expect(denied.first?.inputJSON==nil && denied.first?.unavailableReason != nil)
    }
    @Test func expansionLimitsAndCancellationFailWithoutAProviderOrOutput() async throws {
        #expect(throws:(any Error).self) { try MediaOutpaintLayout(sourceWidth:64,sourceHeight:48,width:64,height:48,anchor:.init(x:0,y:0)) }
        #expect(throws:(any Error).self) { try MediaOutpaintLayout(sourceWidth:64,sourceHeight:48,width:32,height:96,anchor:.init(x:0,y:0)) }
        #expect(throws:(any Error).self) { try MediaOutpaintLayout(sourceWidth:64,sourceHeight:48,width:8192,height:8192,anchor:.init(x:0,y:0)) }
        #expect(throws:(any Error).self) { try MediaOutpaintLayout(sourceWidth:64,sourceHeight:48,width:96,height:80,anchor:.init(x:.nan,y:0)) }
        let original=try source(),layout=try MediaOutpaintLayout(sourceWidth:64,sourceHeight:48,width:96,height:80,anchor:.init(x:0,y:0))
        let worker=Task { try await Task.sleep(for:.milliseconds(5));return try MediaProviderOutpaintPixels.prepare(original,layout:layout) };worker.cancel()
        await #expect(throws:CancellationError.self) { try await worker.value }
    }
    @Test func oneCanvasAndNewBottomLayerTransactionKeepsOriginalLocksAndSurvivesUndoRedo() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("outpaint-transaction-\(UUID())");defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let store=MediaProjectStore(directory:root.appendingPathComponent("Projects")),coordinator=MediaPreparedCoordinator(store:store)
        let project=MediaProject(kind:.image,name:"Expansion",canvas:.init(width:64,height:48));try await store.save(project)
        _ = try await coordinator.upgradeDocument(id:project.id)
        let layer=MediaPreparedLayer(name:"Original editable source",content:.raster(.init(source:.solidColor("#AA442280"))))
        _ = try await coordinator.applyUserOperations([.init(action:.insertLayer(layer:layer,parentID:nil,index:nil))],to:project.id)
        let inserted=try await coordinator.loadDocument(id:project.id)
        let sourceLayer=try #require(inserted.layer(layer.id))
        _ = try await coordinator.applyUserOperations([.init(action:.updateLayerFlags(id:layer.id,expectedRevision:sourceLayer.revision,name:nil,isVisible:nil,isLocked:true,opacity:nil))],to:project.id)
        let before=try await coordinator.loadDocument(id:project.id),original=try #require(before.layer(layer.id))
        let layout=try MediaOutpaintLayout(sourceWidth:64,sourceHeight:48,width:96,height:80,anchor:.init(x:0,y:0))
        let generated=try #require(WorkbenchPNG.encode(source(width:96,height:80,color:CIColor(red:0,green:0,blue:1))))
        let margins=try MediaProviderOutpaintPixels.margins(generated,layout:layout),file=root.appendingPathComponent("margins.png")
        try #require(WorkbenchPNG.encode(margins)).write(to:file)
        let asset=MediaAssetReference(kind:.image,relativePath:"margins.png",originalName:"Generated margins"),marginLayer=MediaPreparedLayer(name:"Generated margins",content:.raster(.init(source:.asset(asset.id))))
        var actions=try MediaCanvasLayout.actions(before,width:96,height:80,mode:.extendCanvas(anchor:layout.effectiveAnchor))
        actions += [.insertAsset(asset),.insertLayer(layer:marginLayer,parentID:nil,index:0)]
        let edit=try await coordinator.applyUserOperations(actions.map{.init(action:$0)},to:project.id)
        let expanded=try await MediaPreparedCoordinator(store:MediaProjectStore(directory:URL(fileURLWithPath:store.storeRootPath,isDirectory:true))).loadDocument(id:project.id)
        #expect(expanded.layers.map(\.id)==[marginLayer.id,layer.id] && expanded.layer(layer.id)?.content==original.content && expanded.layer(layer.id)?.isLocked==true)
        let image=try await WorkbenchImageRenderer().renderPrepared(expanded,canvas:.init(width:96,height:80),resolveAsset:{_ in file})
        let pixels=try MediaNativeSelection.rgba(image).pixels
        #expect(pixels[(12*96+12)*4]>50 && pixels[(12*96+80)*4+2]>250 && pixels[(70*96+12)*4+2]>250)
        _ = try await coordinator.undoGroup(edit.groupID,in:project.id)
        let undone=try await coordinator.loadDocument(id:project.id)
        #expect(undone.canvas==before.canvas && undone.layers.map(\.content)==before.layers.map(\.content) && undone.layer(layer.id)?.isLocked==true)
        _ = try await coordinator.redoGroup(edit.groupID,in:project.id)
        let redone=try await coordinator.loadDocument(id:project.id)
        #expect(redone.canvas==expanded.canvas && redone.layers.map(\.content)==expanded.layers.map(\.content) && redone.layer(layer.id)?.isLocked==true)
        try record("M25-durable-editable-expansion.png",image)
    }
}
